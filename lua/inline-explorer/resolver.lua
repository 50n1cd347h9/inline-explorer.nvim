-- Resolver: identifier name -> the lines of its definition. M.locate finds
-- where a name is declared or defined (workspace/symbol), and M.extract reads
-- the lines there from the first source that has them:
--   C/C++:  tree-sitter -> server -> brace counter
--   others: server -> tree-sitter -> brace counter
-- "server" is the symbol's full range in a textDocument/documentSymbol reply.
-- A definition file is loaded, and a client attached to it, through lsp.lua,
-- which puts the file back as it was once it is no longer used.
--
-- Terms:
--   label             what the lines are: a tree-sitter node type such as
--                     "function_definition" or "declaration", "heuristic" for
--                     the brace counter, or a server symbol's kind_label.
--   local extraction  M.extract_sync: tree-sitter, else the brace counter
--                     (extract_heuristic). It needs no server.
--   cold              step 6 of M.extract newly attached its client to the
--                     definition file, so the server must build that file's
--                     preamble before it can answer. A FileType autostart
--                     (vim.lsp.enable, lspconfig) can attach first, during
--                     the bufload of M.extract's step 2, and such a first
--                     touch counts as warm.
--   chase             following a declaration to its definition with
--                     textDocument/definition (workspace/symbol often answers
--                     with a declaration).

-- A loc says where a symbol is.
---@class inline_explorer.Loc
---@field uri string
---@field range lsp.Range in `encoding` units
---@field kind? lsp.SymbolKind
---@field name? string
---@field encoding? string offset_encoding of the server that answered; nil counts as bytes
---@field client_id? integer the server that answered; requests about the loc go to it

local async = require("inline-explorer.async")
local lsp = require("inline-explorer.lsp")
local profile = require("inline-explorer.profile")
local util = require("inline-explorer.util")

local M = {}

-- Budget for one LSP round trip. Past it, extract falls back to local
-- extraction, and locate and the chase give up, so a wedged server cannot
-- stall a lookup.
M._timeout_ms = 4000

-- Budget for a cold extract (see "cold" above). Healthy preamble builds
-- finish well within it, and slower ones usually outlast _timeout_ms too, so
-- a longer wait would only delay the same local extraction.
M._cold_timeout_ms = 2000

-- Step 4 of M.extract. Tests turn it off to reach the server path.
M._local_first = true

-- LRU caches (util.evict_lru), each bounded by its *_max field. Locate keys
-- are client ids + name, extract keys uri + range. An entry is valid while
-- its definition file's changedtick is unchanged. LspAttach and LspDetach do
-- not clear them: the client ids are part of the locate key, and M.extract's
-- own attaching would clear them otherwise.
M._locate_cache_max = 64
M._extract_cache_max = 64
---@type table<string, {value: inline_explorer.Loc, tick: integer?, at: integer}>
M._locate_cache = {}
---@type table<string, {value: {lines: string[], label: string}, tick: integer, at: integer}>
M._extract_cache = {}

-- Chases that got no location other than the declaration itself, including
-- an error or a timeout, keyed by chase_miss_key(loc) with the vim.uv.now()
-- of the miss. M.locate_definition skips the chase for _chase_miss_ttl_ms
-- after a miss, so repeats cost no round trip, and a background index that
-- finishes later is noticed once the miss expires. A chase that lands on
-- another declaration is not recorded, so it is retried on every lookup.
---@type table<string, integer>
M._chase_miss = {}
M._chase_miss_ttl_ms = 5 * 60 * 1000

function M.clear_caches()
  M._locate_cache = {}
  M._extract_cache = {}
  M._chase_miss = {}
end

local function tick_of(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_changedtick(bufnr)
  end
  return nil
end

local function cache_get(cache, key, tick)
  local e = cache[key]
  if not e then
    return nil
  end
  if e.tick ~= tick then
    cache[key] = nil
    return nil
  end
  e.at = vim.uv.now()
  return e.value
end

local function cache_put(cache, key, value, tick, cap)
  cache[key] = { value = value, tick = tick, at = vim.uv.now() }
  util.evict_lru(cache, cap)
end

local function client_key(bufnr)
  local ids = {}
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    ids[#ids + 1] = c.id
  end
  table.sort(ids)
  return table.concat(ids, ",")
end

local function locate_key(bufnr, name)
  return client_key(bufnr) .. "\1" .. name
end

local function extract_key(loc)
  local s, e = loc.range.start, loc.range["end"]
  return loc.uri .. "\1" .. s.line .. ":" .. s.character .. "\1" .. e.line .. ":" .. e.character
end

local function chase_miss_key(loc)
  return loc.uri .. "\1" .. loc.range.start.line
end

local function source_buf(source_bufnr)
  if source_bufnr and vim.api.nvim_buf_is_valid(source_bufnr) then
    return source_bufnr
  end
  return 0
end

-- Unlike vim.uri_to_bufnr, never creates a buffer.
local function existing_buf(uri)
  local bufnr = vim.fn.bufnr(vim.uri_to_fname(uri))
  if bufnr == -1 then
    return nil
  end
  return bufnr
end

-- An entry stored while its definition file was not loaded has a nil tick:
-- it stays valid while the file stays unloaded, and adopts the file's tick
-- once the file is loaded and unmodified (taken as opened, not edited).
local function locate_cache_get(key)
  local e = M._locate_cache[key]
  if not e then
    return nil
  end
  local def_buf = existing_buf(e.value.uri)
  local now_tick = tick_of(def_buf)
  if e.tick == nil and now_tick ~= nil and not vim.bo[def_buf].modified then
    e.tick = now_tick
  end
  return cache_get(M._locate_cache, key, now_tick)
end

local function locate_cache_put(key, loc)
  cache_put(M._locate_cache, key, loc, tick_of(existing_buf(loc.uri)), M._locate_cache_max)
end

local function extract_cache_put(key, lines, label, tick)
  cache_put(M._extract_cache, key, { lines = lines, label = label }, tick, M._extract_cache_max)
end

local function describe(name, uri)
  return (name or "?") .. " @ " .. vim.fn.fnamemodify(vim.uri_to_fname(uri), ":t")
end

-- Why `method` cannot be sent from bufnr: no server, or none that supports it.
local function unsupported(bufnr, method)
  local names = {}
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    names[#names + 1] = c.name
  end
  if #names == 0 then
    return "no language server attached to the source buffer"
  end
  return ("no language server attached to the source buffer supports %s (attached: %s)"):format(
    method,
    table.concat(names, ", ")
  )
end

-- The first exact match in the replies, taken in client order. workspace/symbol
-- matches fuzzily, and its first result can be an unrelated symbol whose
-- lines would be shown without warning.
local function pick_symbol(name, clients, replies)
  local closest
  for i, client in ipairs(clients) do
    local symbols = replies[i]
    for _, s in ipairs(type(symbols) == "table" and symbols or {}) do
      if s.name == name then
        local l = s.location
        return {
          uri = l.uri,
          range = l.range,
          kind = s.kind,
          name = s.name,
          encoding = client.offset_encoding,
          client_id = client.id,
        }
      end
      closest = closest or s.name or "?"
    end
  end
  if not closest then
    return nil, "no symbol named '" .. name .. "'"
  end
  return nil, ("no symbol named exactly '%s' (closest: %s -- index incomplete?)"):format(name, closest)
end

-- Only an exact name match counts. Every server that supports
-- workspace/symbol is asked; the answer comes once all have replied, or at
-- the deadline from the replies that have arrived, so a server that hangs
-- cannot hide another's answer. Requests still out once the answer is known
-- are cancelled. A deadline without a match cancels nothing: a match that
-- arrives later goes to the cache, so the next lookup gets it at once.
---@param name string
---@param source_bufnr integer? nil or invalid counts as the current buffer
---@param cb fun(loc: inline_explorer.Loc?, err: string?)
function M.locate(name, source_bufnr, cb)
  local bufnr = source_buf(source_bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "workspace/symbol" })
  if #clients == 0 then
    return cb(nil, unsupported(bufnr, "workspace/symbol"))
  end

  local key = locate_key(bufnr, name)
  local cached = locate_cache_get(key)
  if cached then
    local span = profile.start()
    span("locate:cached", name)
    return cb(cached, nil)
  end

  local span = profile.start()
  local replies, ids = {}, {}
  -- Set when the deadline finds no match: a reply can still bring one.
  local late_span
  local settled = false -- the answer is known; no reply can change it

  local function settle(loc)
    settled = true
    locate_cache_put(key, loc)
    for i, client in ipairs(clients) do
      if replies[i] == nil then
        async.cancel(client, ids[i])
      end
    end
  end

  local finish = async.once_with_timeout(function(loc, err)
    if loc then
      span("locate:ok", describe(loc.name or name, loc.uri))
      settle(loc)
    else
      span(late_span and "locate:timeout" or "locate:miss", name)
    end
    cb(loc, err)
  end, function()
    local loc = pick_symbol(name, clients, replies)
    if loc then
      return loc, nil
    end
    late_span = profile.start()
    return nil, "workspace/symbol timed out (server busy or stuck?)"
  end, M._timeout_ms)

  local unanswered = #clients
  local function on_reply(i, result)
    if settled or replies[i] ~= nil then
      return
    end
    replies[i] = result or {}
    unanswered = unanswered - 1
    if late_span then
      local loc = pick_symbol(name, clients, replies)
      if loc then
        late_span("locate:late", describe(loc.name, loc.uri))
        settle(loc)
      end
    elseif unanswered == 0 then
      finish(pick_symbol(name, clients, replies))
    end
  end
  for i, client in ipairs(clients) do
    local sent, id = client:request("workspace/symbol", { query = name }, function(_, result)
      on_reply(i, result)
    end, bufnr)
    ids[i] = id
    if not sent then
      on_reply(i, nil)
    end
  end
end

-- Function-like kinds get the label tree-sitter gives a C function,
-- "function_definition", because the inliner substitutes a call only for
-- lines labelled that way.
local function kind_label(kind)
  local SymbolKind = vim.lsp.protocol.SymbolKind
  if kind == SymbolKind.Method or kind == SymbolKind.Constructor or kind == SymbolKind.Function then
    return "function_definition"
  end
  local name = SymbolKind[kind]
  if type(name) == "string" then
    return name:lower()
  end
  return "symbol"
end

local function le(a, b)
  return a.line < b.line or (a.line == b.line and a.character <= b.character)
end

local function contains(outer, inner)
  return le(outer.start, inner.start) and le(inner["end"], outer["end"])
end

local function same_range(a, b)
  return a.start.line == b.start.line
    and a.start.character == b.start.character
    and a["end"].line == b["end"].line
    and a["end"].character == b["end"].character
end

-- The innermost symbol in a documentSymbol reply whose range contains
-- ref_range.
---@param symbols lsp.DocumentSymbol[]|lsp.SymbolInformation[]
---@param ref_range lsp.Range
---@param name string? when set, SymbolInformation entries with another name are skipped
---@param uri string? when set, SymbolInformation entries in another file are skipped
---@return lsp.Range? range
---@return string? label
function M._symbol_range(symbols, ref_range, name, uri)
  local best, best_label
  local function consider(range, kind)
    if contains(range, ref_range) then
      if not best or contains(best, range) then
        best, best_label = range, kind_label(kind)
      end
    end
  end
  -- Some servers put only the name's range in a SymbolInformation, so an
  -- entry whose range equals ref_range is taken for the bare name and skipped.
  local function flat_entry_matches(s)
    return (name == nil or s.name == name)
      and (uri == nil or s.location.uri == nil or s.location.uri == uri)
      and not same_range(s.location.range, ref_range)
  end
  local function walk(list)
    if type(list) ~= "table" then -- vim.NIL / absent children
      return
    end
    for _, s in ipairs(list) do
      if s.range then -- DocumentSymbol, whose range is the full range by spec
        consider(s.range, s.kind)
        walk(s.children)
      elseif s.location and s.location.range then -- SymbolInformation
        if flat_entry_matches(s) then
          consider(s.location.range, s.kind)
        end
      end
    end
  end
  walk(symbols)
  return best, best_label
end

-- The last row a range covers. Ranges end exclusively, so one that takes its
-- last line's newline, as a #define's node does, ends at column 0 of the
-- next row, which it leaves out.
local function last_row(start_row, end_row, end_col)
  if end_col == 0 and end_row > start_row then
    return end_row - 1
  end
  return end_row
end

-- Raises on a malformed reply.
local function lines_from_symbols(symbols, loc, target)
  if type(symbols) ~= "table" then
    return nil, nil
  end
  local range, label = M._symbol_range(symbols, loc.range, loc.name, loc.uri)
  if not range then
    return nil, nil
  end
  local erow = last_row(range.start.line, range["end"].line, range["end"].character)
  local ls = vim.api.nvim_buf_get_lines(target, range.start.line, erow + 1, false)
  if #ls == 0 then
    return nil, nil
  end
  return ls, label
end

-- The filetype is empty when no detection ran on load (detection off, or
-- autocommands suppressed); then match on the file name.
local function buffer_lang(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == "" then
    ft = vim.filetype.match({ buf = bufnr, filename = vim.api.nvim_buf_get_name(bufnr) }) or ""
  end
  return vim.treesitter.language.get_lang(ft) or ft
end

-- Wrappers whose range is never a definition: preprocessor conditionals
-- (include guards), extern "C" blocks, and the declaration lists that are
-- the bodies of extern "C" blocks and namespaces.
local CONTAINER_NODES = {
  preproc_ifdef = true,
  preproc_if = true,
  preproc_else = true,
  preproc_elif = true,
  linkage_specification = true,
  declaration_list = true,
}

local HEURISTIC = "heuristic"

-- The outermost node at (srow, scol) that starts 0-3 rows above srow. The
-- window allows for a return type or attributes on lines of their own, and
-- the outermost node is wanted because, when the parameter list spans
-- lines, the innermost multi-line node is just the declarator.
local function outermost_in_window(root, srow, scol)
  local node = root:named_descendant_for_range(srow, scol, srow, scol)
  local found
  while node and node:parent() do -- stop before the whole-file root
    if CONTAINER_NODES[node:type()] then
      break
    end
    local start_row = node:range()
    if start_row >= srow - 3 and start_row <= srow then
      found = node
    end
    node = node:parent()
  end
  return found
end

-- The brace counter, defined below.
local extract_heuristic

---@param loc inline_explorer.Loc
---@return string[] lines
---@return string label
function M.extract_sync(loc)
  local bufnr = vim.uri_to_bufnr(loc.uri)
  lsp.load_buffer(bufnr)
  local srow = loc.range.start.line
  local sline = vim.api.nvim_buf_get_lines(bufnr, srow, srow + 1, false)[1] or ""
  local scol = util.byte_col(sline, loc.range.start.character, loc.encoding)

  -- A `.h` file is detected as C++ by default, but Neovim bundles the C parser
  -- and not the C++ one, so try the detected language, then C, then C++.
  local seen = {}
  for _, lang in ipairs({ buffer_lang(bufnr), "c", "cpp" }) do
    if lang and lang ~= "" and not seen[lang] then
      seen[lang] = true
      local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
      if ok and parser then
        local node = outermost_in_window(parser:parse()[1]:root(), srow, scol)
        if node then
          local start_row, _, end_row, end_col = node:range()
          local erow = last_row(start_row, end_row, end_col)
          return vim.api.nvim_buf_get_lines(bufnr, start_row, erow + 1, false), node:type()
        end
        break -- this parser found nothing: use the brace counter, not the next parser
      end
    end
  end

  return extract_heuristic(bufnr, srow), HEURISTIC
end

local MAX_SCAN_LINES = 500 -- so an unclosed brace cannot pull in the rest of the file

-- The brace counter. From srow: a #define with its continuation lines, or
-- the lines through the brace that closes the first one opened.
---@param bufnr integer
---@param srow integer 0-based
---@return string[] lines
function extract_heuristic(bufnr, srow)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local first = vim.api.nvim_buf_get_lines(bufnr, srow, srow + 1, false)[1] or ""

  if first:match("^%s*#%s*define") then
    local out = {}
    for i = srow, total - 1 do
      local l = vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1] or ""
      out[#out + 1] = l
      if not l:match("\\%s*$") then
        break
      end
    end
    return out
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, srow, math.min(total, srow + MAX_SCAN_LINES), false)
  local depth, started, out = 0, false, {}
  for _, l in ipairs(lines) do
    out[#out + 1] = l
    for c in l:gmatch(".") do
      if c == "{" then
        depth, started = depth + 1, true
      elseif c == "}" then
        depth = depth - 1
      end
    end
    if started and depth <= 0 then
      break
    end
    if not started and l:find(";") then
      break -- prototype / forward declaration, no body
    end
  end
  return out
end

local function extract_local(loc, target)
  local tlang = buffer_lang(target)
  if tlang ~= "c" and tlang ~= "cpp" then
    return nil
  end
  local lines, label = M.extract_sync(loc)
  if lines and #lines > 0 and label ~= HEURISTIC then
    return lines, label
  end
  return nil
end

-- Calls cb exactly once on every path, possibly synchronously.
-- The steps, in order:
--   1. no client on source_bufnr -> local extraction
--   2. load the definition file
--   3. cached lines              -> done
--   4. C/C++                     -> local extraction, if tree-sitter finds a node
--   5. no documentSymbol client  -> local extraction (see M.client_for)
--   6. attach that client to the file and ask it. Use local extraction when
--      the reply has no usable range, and on timeout (a late reply then
--      fills the cache).
---@param loc inline_explorer.Loc
---@param source_bufnr integer? nil or invalid counts as the current buffer
---@param cb fun(lines: string[], label: string, note: string?) `note` says the server did not answer in time
function M.extract(loc, source_bufnr, cb)
  local span = profile.start()
  local src = source_buf(source_bufnr)
  local clients = vim.lsp.get_clients({ bufnr = src })
  for _, c in ipairs(clients) do
    profile.identify(c)
  end

  if #clients == 0 then
    local lines, label = M.extract_sync(loc)
    span("extract:no-lsp")
    return cb(lines, label)
  end

  local target = vim.uri_to_bufnr(loc.uri)

  local function detail()
    local where = describe(loc.name, loc.uri)
    if not vim.api.nvim_buf_is_loaded(target) then
      return where
    end
    return ("%s (%dL)"):format(where, vim.api.nvim_buf_line_count(target))
  end

  local load_span = profile.start()
  if lsp.load_buffer(target) then
    load_span("extract:bufload", detail())
  end

  local key = extract_key(loc)
  local tick = tick_of(target)
  if tick then
    local hit = cache_get(M._extract_cache, key, tick)
    if hit then
      span("extract:cached", detail())
      return cb(hit.lines, hit.label)
    end
  end

  -- 4. Tree-sitter finds the same range without a round trip, while clangd
  -- answers documentSymbol on a newly opened file only after building its
  -- preamble, which can take seconds.
  if M._local_first then
    local ts_lines, ts_label = extract_local(loc, target)
    if ts_lines then
      ---@cast ts_label -nil
      if tick then
        extract_cache_put(key, ts_lines, ts_label, tick)
      end
      span("extract:local", detail())
      return cb(ts_lines, ts_label)
    end
  end

  local client = lsp.client_for(loc, src, "textDocument/documentSymbol")
  if not client then
    local lines, label = M.extract_sync(loc)
    span("extract:no-capability", detail())
    return cb(lines, label)
  end

  -- 6. Attached only now: a file read locally needs no server.
  local attach_span = profile.start()
  local cold = lsp.attach_client(target, client)
  if cold then
    attach_span("extract:attach", detail())
  end

  local params = { textDocument = { uri = loc.uri } }
  local budget = cold and M._cold_timeout_ms or M._timeout_ms
  -- Started at the timeout, so it is set once the deadline has passed. With
  -- profiling on, it shows how much longer than the budget the server needed.
  local late_span

  local function on_reply(lines, label, note)
    if late_span then
      span("extract:timeout", detail())
    elseif cold then
      span("extract:cold", detail())
    else
      span("extract:warm", detail())
    end
    -- Also caches the local result for a reply without a usable range, but
    -- not the timeout's: the server's own lines are still to come.
    if lines and tick and not late_span then
      extract_cache_put(key, lines, label, tick)
    end
    cb(lines, label, note)
  end

  -- The caller decides whether to show `note`: this module only looks up.
  local function on_timeout()
    late_span = profile.start()
    local lines, label = M.extract_sync(loc)
    local note = ("%s: no answer within %dms for %s; extracted locally. Looking again will use the server."):format(
      loc.name or "?",
      budget,
      vim.fn.fnamemodify(vim.uri_to_fname(loc.uri), ":t")
    )
    return lines, label, note
  end

  -- The request is neither cancelled nor sent again on timeout: its reply,
  -- however late, goes to the cache for the next look. Like a reply in time,
  -- it is stored under the changedtick it was asked about, so an edit made
  -- meanwhile keeps it from being served.
  local function on_late_reply(lines, label)
    if lines and tick then
      extract_cache_put(key, lines, label, tick)
    end
    late_span(lines and "extract:late" or "extract:late-unusable", detail())
  end

  local finish = async.once_with_timeout(on_reply, on_timeout, budget)
  local sent = client:request("textDocument/documentSymbol", params, function(_, result)
    -- pcall: a malformed reply counts as one without a usable range.
    local ok, lines, label = pcall(lines_from_symbols, result, loc, target)
    if not ok then
      lines, label = nil, nil
    end
    if late_span then
      on_late_reply(lines, label)
    elseif lines then
      finish(lines, label)
    else
      finish(M.extract_sync(loc))
    end
  end, target)
  if not sent then
    finish(M.extract_sync(loc))
  end
end

---@param loc inline_explorer.Loc a declaration
---@param source_bufnr integer? nil or invalid counts as the current buffer
---@param cb fun(dloc: inline_explorer.Loc?) nil on no client or answer, an error, a timeout, or loc itself
function M._chase_definition(loc, source_bufnr, cb)
  local client = lsp.client_for(loc, source_bufnr, "textDocument/definition")
  if not client then
    return cb(nil)
  end
  local target = lsp.ensure_attached(loc.uri, client)
  local encoding = client.offset_encoding
  local pos = lsp.name_position(target, loc, encoding)

  local span = profile.start()
  local function finish(dloc, why)
    local where = describe(loc.name, loc.uri)
    if dloc then
      span("locate:definition-chase", where)
    else
      span("locate:chase-miss", where .. " (" .. (why or "?") .. ")")
    end
    cb(dloc)
  end
  local params = { textDocument = { uri = loc.uri }, position = pos }
  async.request(client, "textDocument/definition", params, target, M._timeout_ms, function(err, result)
    if err then
      return finish(nil, "err: " .. tostring(err.message or err):sub(1, 60))
    end
    if not result then
      return finish(nil, "nil result")
    end
    local first = result
    if vim.islist(result) then
      first = result[1]
    end
    if not first then
      return finish(nil, "empty -- the index has no answer for this position")
    end
    local uri = first.uri or first.targetUri
    -- A LocationLink's targetSelectionRange is the name; its targetRange may
    -- start at a leading comment, and extraction from there returns the
    -- comment.
    local range = first.range or first.targetSelectionRange or first.targetRange
    if not uri or not range then
      return finish(nil, "no location in the answer")
    end
    if uri == loc.uri and range.start.line == pos.line then
      return finish(nil, "self -- the index does not know the defining file (compile_commands.json missing?)")
    end
    finish({ uri = uri, range = range, kind = loc.kind, name = loc.name, encoding = encoding, client_id = client.id })
  end)
end

-- Caches the chased definition under `name`, so a repeat lookup skips the
-- chase.
---@param name string
---@param source_bufnr integer? nil or invalid counts as the current buffer
---@param dloc inline_explorer.Loc
local function locate_cache_replace(name, source_bufnr, dloc)
  locate_cache_put(locate_key(source_buf(source_bufnr), name), dloc)
end

-- Locates `name` and extracts its lines. When they are only a declaration
-- (label "declaration"), chases it once and extracts the definition instead.
-- loc is where the lines came from: the definition, or the declaration when
-- the chase fails. When locate fails, only err is set. M.fetch and
-- go-to-definition share this so both reach the same definition.
---@param name string
---@param source_bufnr integer? nil or invalid counts as the current buffer
-- `note`: see M.extract.
---@param cb fun(loc: inline_explorer.Loc?, lines: string[]?, label: string?, err: string?, note: string?)
function M.locate_definition(name, source_bufnr, cb)
  M.locate(name, source_bufnr, function(loc, err)
    if not loc then
      return cb(nil, nil, nil, err or "not found")
    end
    M.extract(loc, source_bufnr, function(lines, label, note)
      if label ~= "declaration" then
        return cb(loc, lines, label, nil, note)
      end
      local function keep_declaration()
        return cb(loc, lines, label, nil, note)
      end
      local miss_key = chase_miss_key(loc)
      local miss_at = M._chase_miss[miss_key]
      if miss_at and (vim.uv.now() - miss_at) < M._chase_miss_ttl_ms then
        return keep_declaration()
      end
      M._chase_definition(loc, source_bufnr, function(dloc)
        if not dloc then
          M._chase_miss[miss_key] = vim.uv.now()
          return keep_declaration()
        end
        M.extract(dloc, source_bufnr, function(def_lines, def_label, def_note)
          if not def_lines or def_label == "declaration" then
            return keep_declaration()
          end
          locate_cache_replace(name, source_bufnr, dloc)
          cb(dloc, def_lines, def_label, nil, def_note)
        end)
      end)
    end)
  end)
end

-- M.locate_definition without the loc.
---@param name string
---@param source_bufnr integer? nil or invalid counts as the current buffer
---@param cb fun(lines: string[]?, label: string?, err: string?, note: string?) note: see M.extract
function M.fetch(name, source_bufnr, cb)
  M.locate_definition(name, source_bufnr, function(_, lines, label, err, note)
    cb(lines, label, err, note)
  end)
end

return M
