-- Resolver: identifier name -> the lines of its definition.
--
--   M.locate(name)  asks the source buffer's servers where `name` is
--                   defined (workspace/symbol) and returns a loc.
--   M.extract(loc)  returns the definition's lines and label, from the
--                   first of these sources that has them:
--                     C/C++:  tree-sitter -> server -> brace counter
--                     others: server -> tree-sitter -> brace counter
--                   "server" means the symbol's full range in a
--                   textDocument/documentSymbol reply. Results are cached.
--   M.locate_definition, M.fetch
--                   run locate, then extract. When the lines are only a
--                   declaration, they also chase it to the definition.
--
-- Terms used throughout:
--   loc               { uri, range, kind, name, encoding }: where a symbol
--                     is. kind is an LSP SymbolKind, and range is in
--                     `encoding` units (the answering server's
--                     offset_encoding).
--   label             what the lines are: a tree-sitter node type such as
--                     "function_definition" or "declaration", "heuristic"
--                     for the brace counter, or a server symbol's kind (see
--                     kind_label).
--   local extraction  M.extract_sync: tree-sitter, or the brace counter
--                     (M.extract_heuristic) when tree-sitter finds nothing.
--                     It needs no server.
--   cold              this M.extract call attached the server to the
--                     definition file, so the server must build that file's
--                     preamble before it can answer.
--   chase             following a declaration to its definition with
--                     textDocument/definition (M._chase_definition).
--
-- Lookups go by name, not position: the reading view is a copy buffer with
-- no server attached, and nested expansions have no real file position.

-- profile.start() returns span(label, detail), which records the time since
-- start() under `label`. profile.identify(client) logs the client's server
-- (name, version, command) once. Both do nothing while profiling is off.
local profile = require("inline-explorer.profile")
local util = require("inline-explorer.util")

local M = {}

-- How long one LSP round trip may take. After that, extract falls back to
-- local extraction, while locate and the chase report failure, so a wedged
-- server degrades visibly instead of hanging the keypress. It is a module
-- field so tests can shorten it.
M._timeout_ms = 4000

-- Budget for a cold extract, which waits for the server to build the
-- definition file's preamble. Healthy builds finish well within it, and
-- builds that do not usually outlast _timeout_ms too, so a longer wait
-- would only delay the same local extraction. Timing out is cheap: the
-- local result is shown but not cached, and the background retry in
-- M.extract caches the server's answer for the next look.
M._cold_timeout_ms = 2000

-- For C/C++, M.extract tries local extraction before the server (step 4
-- there). It is a module field so tests can turn it off and exercise the
-- server path.
M._local_first = true

-- Neovim 0.11 made request a method: client:request(method, ...). 0.10 has
-- the plain function client.request(method, ...), without self. Client
-- requests in every module go through this shim so 0.10 keeps working.
function M.client_request(client, method, params, handler, bufnr)
  if vim.fn.has("nvim-0.11") == 1 then
    return client:request(method, params, handler, bufnr)
  end
  return client.request(method, params, handler, bufnr)
end

-- Returns `finish`. The first call to finish(...) forwards its arguments to
-- `cb`, and later calls are ignored. If finish has not been called after
-- `ms` (default _timeout_ms), on_timeout() runs and cb receives its return
-- values instead: an on_timeout that returns nil, "timeout" becomes
-- cb(nil, "timeout"). A reply that arrives after that is dropped.
local function once_with_timeout(cb, on_timeout, ms)
  return require("inline-explorer.async").once_with_timeout(cb, on_timeout, ms or M._timeout_ms)
end

-- Result caches, each an LRU (util.evict_lru) bounded by its *_max field:
--   _locate_cache:  client ids + name -> loc
--   _extract_cache: uri + range       -> { lines = ..., label = ... }
-- An entry stays valid while its definition file's changedtick does not
-- change. Neither cache is cleared on LspAttach or LspDetach: the client
-- set is part of the locate key, and M.extract's own attaching would clear
-- them otherwise. (M._attach_cache, further down, is different: it keeps
-- attachments alive so the server does not rebuild preambles.)
M._locate_cache_max = 64
M._extract_cache_max = 64
M._locate_cache = {}
M._extract_cache = {}

-- Declarations whose chase found no definition: chase_miss_key(loc) -> the
-- vim.uv.now() of the miss. M.locate_definition skips the chase for
-- _chase_miss_ttl_ms after a miss, so repeated lookups cost no round trip,
-- and a background index that finishes later is noticed once the miss
-- expires.
M._chase_miss = {}
M._chase_miss_ttl_ms = 5 * 60 * 1000

-- Empty the result caches and the chase misses (the attach cache is left
-- alone). Only tests call this, to isolate cases.
function M.clear_caches()
  M._locate_cache = {}
  M._extract_cache = {}
  M._chase_miss = {}
end

-- Returns bufnr's changedtick, or nil when bufnr is nil, invalid or not
-- loaded.
local function tick_of(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_changedtick(bufnr)
  end
  return nil
end

-- Returns the value cached under key, or nil. An entry is valid only while
-- `tick` (its file's current tick) equals the tick stored with it; two nils
-- count as equal. A stale entry is dropped.
local function cache_get(cache, key, tick)
  local e = cache[key]
  if not e then
    return nil
  end
  if e.tick ~= tick then
    cache[key] = nil
    return nil
  end
  e.at = vim.uv.now() -- last use: util.evict_lru evicts the oldest
  return e.value
end

local function cache_put(cache, key, value, tick, cap)
  cache[key] = { value = value, tick = tick, at = vim.uv.now() }
  util.evict_lru(cache, cap)
end

-- The ids of bufnr's clients, sorted so the key does not depend on
-- get_clients' order. The client set decides what a name resolves to, so it
-- is part of the locate key rather than a reason to clear the cache.
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

-- The buffer whose LSP clients we ask: source_bufnr while it is valid, else
-- the current buffer (0).
local function source_buf(source_bufnr)
  if source_bufnr and vim.api.nvim_buf_is_valid(source_bufnr) then
    return source_bufnr
  end
  return 0
end

-- The file's existing buffer, or nil. Unlike vim.uri_to_bufnr, it never
-- creates a buffer.
local function existing_buf(uri)
  local bufnr = vim.fn.bufnr(vim.uri_to_fname(uri))
  if bufnr == -1 then
    return nil
  end
  return bufnr
end

-- cache_get for _locate_cache. The tick is the definition file's, not the
-- source buffer's: typing in the file you read from does not move a
-- definition, but editing the definition file can, and a stale range would
-- make extract return the wrong lines. An entry stored while that file had
-- no loaded buffer has a nil tick and stays valid while the file stays
-- unloaded (a file nobody has opened cannot have been edited). Once the file
-- is loaded and unmodified, the entry adopts its tick: the file was opened,
-- not edited.
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

-- Store loc under key with its definition file's current tick (nil while
-- that file has no loaded buffer; see locate_cache_get).
local function locate_cache_put(key, loc)
  cache_put(M._locate_cache, key, loc, tick_of(existing_buf(loc.uri)), M._locate_cache_max)
end

local function extract_cache_put(key, lines, label, tick)
  cache_put(M._extract_cache, key, { lines = lines, label = label }, tick, M._extract_cache_max)
end

-- "name @ file.c": how span details name a location.
local function describe(name, uri)
  return (name or "?") .. " @ " .. vim.fn.fnamemodify(vim.uri_to_fname(uri), ":t")
end

-- Ask the source buffer's servers where `name` is defined (workspace/symbol,
-- exact name only). Calls cb(loc, nil) or cb(nil, err), where
-- loc = { uri, range, kind, name, encoding } as described at the top of the
-- file. Found locations are cached (see locate_cache_get).
function M.locate(name, source_bufnr, cb)
  local bufnr = source_buf(source_bufnr)
  if #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
    return cb(nil, "no language server attached to the source buffer")
  end

  local key = locate_key(bufnr, name)
  local cached = locate_cache_get(key)
  if cached then
    local span = profile.start()
    span("locate:cached", name)
    return cb(cached, nil)
  end

  local span = profile.start()
  local finish = once_with_timeout(function(loc, err)
    if loc then
      span("locate:ok", describe(loc.name or name, loc.uri))
      locate_cache_put(key, loc)
    else
      span("locate:miss", name)
    end
    cb(loc, err)
  end, function()
    return nil, "workspace/symbol timed out (server busy or stuck?)"
  end)
  vim.lsp.buf_request_all(bufnr, "workspace/symbol", { query = name }, function(results)
    -- Each symbol keeps its server's offset encoding: its range is in that
    -- server's units, not in bytes (see util.byte_col).
    local all, encoding_of = {}, {}
    for client_id, r in pairs(results or {}) do
      local client = vim.lsp.get_client_by_id(client_id)
      for _, s in ipairs(r.result or {}) do
        all[#all + 1] = s
        encoding_of[s] = client and client.offset_encoding
      end
    end
    if #all == 0 then
      return finish(nil, "no symbol named '" .. name .. "'")
    end

    -- Accept only an exact name match. workspace/symbol matches fuzzily, and
    -- its first suggestion can be an unrelated symbol whose lines would be
    -- shown without warning. The error names the closest match instead,
    -- which points at the likely cause: an index that does not know the name.
    local pick
    for _, s in ipairs(all) do
      if s.name == name then
        pick = s
        break
      end
    end
    if not pick then
      return finish(
        nil,
        ("no symbol named exactly '%s' (closest: %s -- index incomplete?)"):format(name, all[1].name or "?")
      )
    end

    local loc = pick.location
    finish({ uri = loc.uri, range = loc.range, kind = pick.kind, name = pick.name, encoding = encoding_of[pick] }, nil)
  end)
end

-- The label for a server symbol's LSP SymbolKind. Function-like kinds become
-- "function_definition", the label tree-sitter gives a C function, because
-- the inliner substitutes a call only for lines labelled that way. Other
-- kinds become the lowercase kind name ("struct", "variable", ...).
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

local function le(a, b) -- position a <= b
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

-- Returns range, label: the deepest symbol in a documentSymbol reply whose
-- range contains `ref_range`, and its kind_label (nil, nil when none does).
-- It handles both reply shapes:
--   DocumentSymbol[] (hierarchical: range and children). Its range is the
--     full range by spec, so a range equal to ref_range is a valid match.
--   SymbolInformation[] (flat: location.range). Some servers put just the
--     name's range there, so an entry whose range equals ref_range is taken
--     to be the bare name and skipped. Entries must also match `name`, and
--     `uri` when one is given (such replies can span files).
function M._symbol_range(symbols, ref_range, name, uri)
  local best, best_label
  local function consider(range, kind)
    if contains(range, ref_range) then
      if not best or contains(best, range) then
        best, best_label = range, kind_label(kind)
      end
    end
  end
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
      if s.range then -- hierarchical DocumentSymbol
        consider(s.range, s.kind)
        walk(s.children)
      elseif s.location and s.location.range then -- flat SymbolInformation
        if flat_entry_matches(s) then
          consider(s.location.range, s.kind)
        end
      end
    end
  end
  walk(symbols)
  return best, best_label
end

-- Lines of the definition at `loc`, read from `target` (the definition
-- file's buffer) using the range in a buf_request_all documentSymbol reply.
-- The first client whose symbols contain loc.range wins. Returns lines,
-- label, or nil, nil. It raises on a malformed reply, so callers pcall it.
-- Both the main request in M.extract and its retry after a timeout use it.
local function lines_from_symbols(results, loc, target)
  local range, label
  for _, r in pairs(results or {}) do
    if r.result then
      range, label = M._symbol_range(r.result, loc.range, loc.name, loc.uri)
      if range then
        break
      end
    end
  end
  if not range then
    return nil, nil
  end
  -- LSP ranges are end-exclusive; end.character == 0 on a line after
  -- start means that line's content is not actually part of the range.
  local erow = range["end"].line
  if range["end"].character == 0 and erow > range.start.line then
    erow = erow - 1
  end
  local ls = vim.api.nvim_buf_get_lines(target, range.start.line, erow + 1, false)
  if #ls == 0 then
    return nil, nil
  end
  return ls, label
end

-- Resolve the tree-sitter language for a buffer. A buffer that was only
-- `bufload`ed (e.g. a header the definition lives in) often has no filetype yet,
-- so fall back to matching on its file name.
local function buffer_lang(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == "" then
    ft = vim.filetype.match({ buf = bufnr, filename = vim.api.nvim_buf_get_name(bufnr) }) or ""
  end
  return vim.treesitter.language.get_lang(ft) or ft
end

-- Wrapper nodes whose own range is never a definition: preprocessor
-- conditionals (such as include guards), extern "C" blocks and the
-- declaration lists inside them. outermost_in_window stops at one.
local CONTAINER_NODES = {
  preproc_ifdef = true,
  preproc_if = true,
  preproc_else = true,
  preproc_elif = true,
  linkage_specification = true,
  declaration_list = true,
}

-- The label of lines found by the brace counter rather than tree-sitter.
local HEURISTIC = "heuristic"

-- The outermost ancestor of the node at (srow, scol) that starts 0-3 rows
-- above srow, or nil. The window allows for a return type or attributes on
-- lines of their own. The outermost node is the one wanted: when the
-- parameter list spans lines, the innermost multi-line node is just the
-- declarator. The walk stops below the whole-file root and at a
-- CONTAINER_NODES ancestor, so a guard or an extern "C" block is never
-- returned.
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

-- Local extraction: the definition at `loc`, found without a server.
-- Returns lines, label: the lines of the node outermost_in_window finds and
-- the node's type, or extract_heuristic's lines and HEURISTIC when no
-- parser is available or the parser finds nothing.
function M.extract_sync(loc)
  local bufnr = vim.uri_to_bufnr(loc.uri)
  vim.fn.bufload(bufnr)
  local srow = loc.range.start.line
  local sline = vim.api.nvim_buf_get_lines(bufnr, srow, srow + 1, false)[1] or ""
  local scol = util.byte_col(sline, loc.range.start.character, loc.encoding)

  -- `.h` headers are often detected as C++ while only the C parser is
  -- installed, so try the detected language, then C, then C++. The first
  -- language that has a parser decides.
  local seen = {}
  for _, lang in ipairs({ buffer_lang(bufnr), "c", "cpp" }) do
    if lang and lang ~= "" and not seen[lang] then
      seen[lang] = true
      local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
      if ok and parser then
        local node = outermost_in_window(parser:parse()[1]:root(), srow, scol)
        if node then
          local start_row, _, end_row = node:range()
          return vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false), node:type()
        end
        break -- this parser found nothing: use the brace counter, not the next parser
      end
    end
  end

  return M.extract_heuristic(bufnr, srow), HEURISTIC
end

-- extract_heuristic reads at most this many lines, so a missing closing
-- brace cannot pull in the rest of the file.
local MAX_SCAN_LINES = 500

-- The brace counter: local extraction's last resort when tree-sitter is
-- unavailable or finds nothing at srow. Returns a #define with its
-- continuation lines, the lines from srow to the brace that closes the
-- first one opened, or, when a ';' comes before any brace, the lines up to
-- it (a prototype). It only really helps C-family languages.
function M.extract_heuristic(bufnr, srow)
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

-- Attachments this module created: definition-file bufnr -> { ids = the
-- client ids we attached, at = last use }. They outlive the request because
-- re-attaching a header makes the server rebuild its preamble.
M._attach_cache_max = 8
M._attach_cache = {}

-- Record target's attachment (or refresh its recency), then evict entries
-- beyond _attach_cache_max. For each evicted buffer that is not shown in
-- any window, detach the clients we attached to it. A buffer whose clients
-- were all attached already is not recorded, so it is never detached here.
local function cache_attachment(target, newly_attached)
  local cache = M._attach_cache
  if cache[target] then
    cache[target].at = vim.uv.now() -- refresh recency; ids already recorded
  elseif #newly_attached > 0 then
    cache[target] = { ids = newly_attached, at = vim.uv.now() }
  end
  util.evict_lru(cache, M._attach_cache_max, function(evicted_buf, entry)
    if vim.api.nvim_buf_is_valid(evicted_buf) and #vim.fn.win_findbuf(evicted_buf) == 0 then
      for _, id in ipairs(entry.ids) do
        pcall(vim.lsp.buf_detach_client, evicted_buf, id)
      end
    end
  end)
end

-- Load `target` and attach `clients` to it, through the attach cache.
-- Returns the ids this call newly attached (empty when all were attached).
local function attach_clients(target, clients)
  vim.fn.bufload(target)
  local newly_attached = {}
  for _, c in ipairs(clients) do
    local already_attached = c.attached_buffers and c.attached_buffers[target]
    vim.lsp.buf_attach_client(target, c.id)
    if not already_attached then
      newly_attached[#newly_attached + 1] = c.id
    end
  end
  cache_attachment(target, newly_attached)
  return newly_attached
end

-- Load uri's file and attach source_bufnr's clients to it through the
-- attach cache, so that position requests about the file (such as the
-- callers module's callHierarchy) work: a server answers only about
-- documents it has open. Returns the target bufnr, or nil when source_bufnr
-- has no LSP clients.
function M.ensure_attached(uri, source_bufnr)
  local clients = vim.lsp.get_clients({ bufnr = source_buf(source_bufnr) })
  if #clients == 0 then
    return nil
  end
  local target = vim.uri_to_bufnr(uri)
  attach_clients(target, clients)
  return target
end

-- Step 4 of M.extract: local extraction for a C or C++ file, accepted only
-- when tree-sitter found a node (not the brace counter). Returns lines,
-- label, or nil when M.extract should ask the server.
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

-- Extract the definition at `loc` (see the top of the file). Calls
-- cb(lines, label) exactly once on every path, possibly synchronously.
-- The steps, in order:
--   1. no client on source_bufnr -> local extraction
--   2. load the definition file and attach the source buffer's clients
--   3. cached lines              -> done
--   4. C/C++                     -> local extraction, if tree-sitter finds a node
--   5. no documentSymbol client  -> local extraction
--   6. ask the server. Use local extraction when the reply has no usable
--      range, and on timeout (then retry in the background).
function M.extract(loc, source_bufnr, cb)
  local span = profile.start()
  local clients = vim.lsp.get_clients({ bufnr = source_buf(source_bufnr) })
  for _, c in ipairs(clients) do
    profile.identify(c)
  end

  -- 1. No client: local extraction.
  if #clients == 0 then
    local lines, label = M.extract_sync(loc)
    span("extract:no-lsp")
    return cb(lines, label)
  end

  -- 2. Load the definition file and attach the clients.
  local target = vim.uri_to_bufnr(loc.uri)

  -- Spans from here on name the symbol, its file and the file's length, so
  -- a slow span in the log can be traced to its file.
  local function detail()
    local where = describe(loc.name, loc.uri)
    if not vim.api.nvim_buf_is_loaded(target) then
      return where
    end
    return ("%s (%dL)"):format(where, vim.api.nvim_buf_line_count(target))
  end

  -- Time the disk load apart from the server's preamble build: the first is
  -- our I/O, the second is server work we only wait for.
  local load_span = profile.start()
  local was_loaded = vim.api.nvim_buf_is_loaded(target)
  vim.fn.bufload(target)
  if not was_loaded then
    load_span("extract:bufload", detail())
  end

  -- Attach even when step 3 finds the lines cached: the macro path needs the
  -- definition file attached before clangd runs its ExpandMacro tweak.
  local attach_span = profile.start()
  local newly_attached = attach_clients(target, clients)
  local cold = #newly_attached > 0
  if cold then
    attach_span("extract:attach", detail())
  end

  -- 3. Cached lines, valid while the definition file's tick is unchanged.
  local key = extract_key(loc)
  local tick = tick_of(target)
  if tick then
    local hit = cache_get(M._extract_cache, key, tick)
    if hit then
      span("extract:cached", detail())
      return cb(hit.lines, hit.label)
    end
  end

  -- 4. C/C++: local extraction first. A documentSymbol request on a file the
  -- server has not opened makes clangd build its preamble, which can take
  -- seconds, while tree-sitter finds the same range without a round trip. A
  -- brace counter result is not trusted here; the server is asked instead.
  if M._local_first then
    local ts_lines, ts_label = extract_local(loc, target)
    if ts_lines then
      if tick then
        extract_cache_put(key, ts_lines, ts_label, tick)
      end
      span("extract:local", detail())
      return cb(ts_lines, ts_label)
    end
  end

  -- 5. buf_request_all calls its handler once every client that is attached
  -- to target and supports documentSymbol has replied. With no such client
  -- it would never call it, so use local extraction now instead of waiting.
  if #vim.lsp.get_clients({ bufnr = target, method = "textDocument/documentSymbol" }) == 0 then
    local lines, label = M.extract_sync(loc)
    span("extract:no-capability", detail())
    return cb(lines, label)
  end

  -- 6. Ask the server, and stop waiting after `budget`.
  local params = { textDocument = { uri = loc.uri } } -- the retry sends the same request
  local budget = cold and M._cold_timeout_ms or M._timeout_ms
  -- Set by on_timeout before once_with_timeout hands its result (local
  -- extraction's, not the server's) to on_reply. It keeps that result out
  -- of the cache and labels its span "extract:timeout".
  local timed_out = false

  local function on_reply(lines, label)
    -- After a timeout the elapsed time is the budget, not the server's
    -- latency, so the span must not read as a cold or warm answer.
    if timed_out then
      span("extract:timeout", detail())
    elseif cold then
      span("extract:cold", detail())
    else
      span("extract:warm", detail())
    end
    -- Cache what was shown, including local extraction's result when the
    -- reply had no usable range, but never the result of a timeout.
    if lines and tick and not timed_out then
      extract_cache_put(key, lines, label, tick)
    end
    cb(lines, label)
  end

  -- Re-send the request in the background. If the late reply has the
  -- definition, cache it so the next look gets the server's lines without
  -- waiting. With profiling on, also time it: a fast retry means the server
  -- was still building the preamble, and a slow one means this file is
  -- expensive for the server and no budget would help.
  local function retry_in_background()
    local probe = profile.enabled and profile.start() or nil
    vim.lsp.buf_request_all(target, "textDocument/documentSymbol", params, function(results)
      local ok, lines, label = pcall(lines_from_symbols, results, loc, target)
      if ok and lines then
        local now_tick = tick_of(target)
        if now_tick then
          extract_cache_put(key, lines, label, now_tick)
        end
      end
      if probe then
        probe(lines and "extract:retry-after-timeout" or "extract:retry-failed", detail())
      end
    end)
  end

  local function on_timeout()
    timed_out = true
    retry_in_background()
    -- Name the file, and tell the user that looking again will use the
    -- server: the retry caches the server's answer when it arrives.
    util.notify(
      ("%s: no answer within %dms for %s; extracted locally. Looking again will use the server."):format(
        loc.name or "?",
        budget,
        vim.fn.fnamemodify(vim.uri_to_fname(loc.uri), ":t")
      ),
      vim.log.levels.WARN
    )
    return M.extract_sync(loc) -- once_with_timeout passes these to on_reply
  end

  local finish = once_with_timeout(on_reply, on_timeout, budget)
  vim.lsp.buf_request_all(target, "textDocument/documentSymbol", params, function(results)
    -- pcall so that a malformed reply cannot leave cb uncalled.
    local ok, lines, label = pcall(lines_from_symbols, results, loc, target)
    if ok and lines then
      finish(lines, label)
    else
      finish(M.extract_sync(loc))
    end
  end)
end

-- Position of loc.name, as a whole word, within the first 4 lines of its
-- declaration in `target`, or loc.range.start when the name is not there.
-- loc.range.start may sit on a keyword such as `void`, where a position
-- request finds nothing. loc.range is in loc.encoding; the result is in
-- `out_encoding`, the encoding of the server it will be sent to.
function M.name_position(target, loc, out_encoding)
  local from = loc.range.start.line
  local lines = vim.api.nvim_buf_get_lines(target, from, from + 4, false)
  if loc.name then
    for i, l in ipairs(lines) do
      local start1 = l:find("%f[%w_]" .. vim.pesc(loc.name) .. "%f[^%w_]") -- 1-based byte index
      if start1 then
        return { line = from + i - 1, character = util.lsp_col(l, start1 - 1, out_encoding) }
      end
    end
  end
  local l = lines[1] or ""
  local byte = util.byte_col(l, loc.range.start.character, loc.encoding)
  return { line = from, character = util.lsp_col(l, byte, out_encoding) }
end

-- Chase a declaration to its definition with one textDocument/definition
-- request. workspace/symbol often answers with a declaration (kfree is
-- declared in slab.h but defined in mm/slub.c), and extract returns the
-- lines at whatever loc it is given. Calls cb(dloc), or cb(nil) when no
-- definition elsewhere is found: the declaration's file has no buffer or no
-- client that answers definition requests, the index lacks the definition,
-- or the declaration is the definition.
function M._chase_definition(loc, cb)
  local target = existing_buf(loc.uri)
  if not target then
    return cb(nil)
  end
  local clients = vim.lsp.get_clients({ bufnr = target, method = "textDocument/definition" })
  if #clients == 0 then
    return cb(nil)
  end
  -- Aim at the identifier itself (see M.name_position).
  local encoding = clients[1].offset_encoding
  local pos = M.name_position(target, loc, encoding)

  local span = profile.start()
  -- On a miss, `why` says what happened (an error, an empty answer, the
  -- declaration itself, or a timeout), and the span records it.
  local finish = once_with_timeout(function(dloc, why)
    local where = describe(loc.name, loc.uri)
    if dloc then
      span("locate:definition-chase", where)
    else
      span("locate:chase-miss", where .. " (" .. (why or "?") .. ")")
    end
    cb(dloc)
  end, function()
    return nil, "timeout"
  end)
  M.client_request(clients[1], "textDocument/definition", {
    textDocument = { uri = loc.uri },
    position = pos,
  }, function(err, result)
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
    -- Location or LocationLink; normalize to { uri, range }.
    local uri = first.uri or first.targetUri
    local range = first.range or first.targetSelectionRange or first.targetRange
    if not uri or not range then
      return finish(nil, "no location in the answer")
    end
    -- An answer that points back at the declaration is a miss. A server
    -- answers this way when its index has never seen the defining file, for
    -- example when the source root has no compile database (as with an
    -- out-of-tree build such as buildroot).
    if uri == loc.uri and range.start.line == pos.line then
      return finish(nil, "self -- the index does not know the defining file (compile_commands.json missing?)")
    end
    finish({ uri = uri, range = range, kind = loc.kind, name = loc.name, encoding = encoding })
  end, target)
end

-- Replace the cached location for `name` with the chased definition, so a
-- repeat lookup goes straight to the definition without chasing again. The
-- entry gets the definition file's tick, as in M.locate.
function M._locate_cache_replace(name, source_bufnr, dloc)
  locate_cache_put(locate_key(source_buf(source_bufnr), name), dloc)
end

-- name -> cb(loc, lines, label, err): locate, then extract. When the lines
-- are only a declaration (label "declaration", tree-sitter's node type for a
-- C prototype), chase it once and extract the definition instead. loc is
-- where the lines came from: the definition, or the declaration when the
-- chase fails. When locate fails, loc and lines are nil and err says why
-- (extract itself always returns lines). M.fetch and go-to-definition both
-- use this, so they reach the same definition.
function M.locate_definition(name, source_bufnr, cb)
  M.locate(name, source_bufnr, function(loc, err)
    if not loc then
      return cb(nil, nil, nil, err or "not found")
    end
    M.extract(loc, source_bufnr, function(lines, label)
      if label ~= "declaration" then
        return cb(loc, lines, label, nil)
      end
      local function keep_declaration()
        return cb(loc, lines, label, nil)
      end
      -- Skip the chase while a recent chase for this declaration missed.
      local miss_key = chase_miss_key(loc)
      local miss_at = M._chase_miss[miss_key]
      if miss_at and (vim.uv.now() - miss_at) < M._chase_miss_ttl_ms then
        return keep_declaration()
      end
      -- The extract above attached the declaration's file, which the chase's
      -- definition request needs.
      M._chase_definition(loc, function(dloc)
        if not dloc then
          M._chase_miss[miss_key] = vim.uv.now()
          return keep_declaration()
        end
        M.extract(dloc, source_bufnr, function(def_lines, def_label)
          if not def_lines or def_label == "declaration" then
            return keep_declaration()
          end
          M._locate_cache_replace(name, source_bufnr, dloc)
          cb(dloc, def_lines, def_label, nil)
        end)
      end)
    end)
  end)
end

-- name -> definition lines: cb(lines, label, err). See M.locate_definition.
function M.fetch(name, source_bufnr, cb)
  M.locate_definition(name, source_bufnr, function(_, lines, label, err)
    cb(lines, label, err)
  end)
end

return M
