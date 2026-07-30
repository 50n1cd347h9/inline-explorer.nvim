-- Resolver: given an identifier name, ask the language server where it is
-- defined, then ask it for the definition's full range.
--
-- Resolution is name-based (workspace/symbol) on purpose: the reading view is a
-- copy buffer no server is attached to, and nested expansions live on inserted
-- text with no real file position. A name lookup works at any depth, and both
-- requests are language-agnostic, so nothing here is tied to a single server.
--
-- Extraction asks the same server for textDocument/documentSymbol on the
-- definition's file and takes the symbol's full range -- no per-language node
-- tables. tree-sitter (a generic outermost-in-window ancestor walk that skips
-- a small set of transparent container nodes) and a brace counter remain as
-- fallbacks when no server range is available.
local profile = require("inline-explorer.profile")

local M = {}

-- How long an LSP round trip may take before we stop waiting: extraction
-- falls back to the local path and location lookup reports failure. A wedged
-- server (cold index, huge TU) must degrade visibly, not hang the keypress
-- forever. Exposed as a module field so tests can shorten it.
M._timeout_ms = 4000

-- A separate, SHORTER budget for the first touch of a definition file, where
-- the server has to build that file's preamble before it can answer.
--
-- One number cannot serve both cases. Measured in a real kernel session:
-- an already-attached file answers in 6.6ms, and a first touch usually costs
-- 380-650ms (mm_types.h 379.9, mm.h 635.5) -- but occasionally a small
-- header blows past everything (err.h, 127 lines, and list.h both exceeded
-- 4000ms). Against that distribution a 4000ms budget is far longer than any
-- healthy answer needs, and its only effect on the pathological ones was to
-- make the user wait four seconds and THEN get the tree-sitter fallback.
--
-- Cutting it is safe because of two properties this code already has: the
-- attachment survives a timeout, and a timed-out result is deliberately not
-- cached. So the next touch of that file asks the server again, against a
-- preamble it has meanwhile finished building -- measured at 1.3ms and then
-- 0.5ms after a forced timeout on the first. The user gets an instant
-- fallback now and the server's own answer on the next look, instead of a
-- four-second wait for the same fallback.
M._cold_timeout_ms = 1200

local function once_with_timeout(cb, on_timeout)
  return require("inline-explorer.async").once_with_timeout(cb, on_timeout, M._timeout_ms)
end

-- Result caches. The attach cache further down keeps the SERVER from
-- rebuilding a preamble; these keep US from asking the same question twice.
-- They are separate problems and neither substitutes for the other: measured
-- on linux-6.12 with real clangd, walking the same 29 callees in
-- kernel/sched/core.c a second time cost the same as the first (p50 54.6ms
-- then 54.0ms, p90 166.0ms then 160.6ms, worst 567.5ms), because every
-- invocation reissued workspace/symbol and documentSymbol from scratch. On
-- zlib the same repeat costs under 1ms, which is why this never showed up
-- until the plugin was pointed at the source it was written for.
--
-- Capacities are module fields so tests can shrink them.
M._locate_cache_n = 64
M._extract_cache_n = 64
M._locate_cache = {}
M._extract_cache = {}

-- Drop everything. Called on LspAttach/LspDetach (below) because a changed
-- client set can change what a name resolves to, and exposed for tests.
function M.clear_caches()
  M._locate_cache = {}
  M._extract_cache = {}
end

-- A buffer's changedtick, or nil when the buffer is not loaded. A cached
-- answer about a file is only reusable while that file is unchanged; an
-- unloaded target has no tick to compare, so entries recorded against one
-- are not reused rather than trusted.
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
  -- Recorded against a file state we can no longer confirm, or one that has
  -- since been edited: forget it rather than answer from it.
  if e.tick ~= tick then
    cache[key] = nil
    return nil
  end
  e.at = vim.uv.now()
  return e.value
end

local function cache_put(cache, key, value, tick, cap)
  cache[key] = { value = value, tick = tick, at = vim.uv.now() }
  local n, entries = 0, {}
  for k, e in pairs(cache) do
    n = n + 1
    entries[n] = { k = k, at = e.at }
  end
  if n <= cap then
    return
  end
  table.sort(entries, function(a, b)
    return a.at < b.at
  end)
  for i = 1, n - cap do
    cache[entries[i].k] = nil
  end
end

-- The client set decides what a name can resolve to, so it is part of the
-- key rather than something to invalidate on. Sorted so the key does not
-- depend on get_clients' ordering.
local function client_key(bufnr)
  local ids = {}
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    ids[#ids + 1] = c.id
  end
  table.sort(ids)
  return table.concat(ids, ",")
end

-- Deliberately NOT invalidated on LspAttach/LspDetach. That was the first
-- thing tried and it was self-defeating: `extract` attaches the source
-- buffer's clients to each definition file it opens, which fires LspAttach,
-- which would clear the very entry the next call is about to want. Measured
-- on linux-6.12, an LspAttach-clearing version left kernel/sched/core.c's
-- repeat walk at p50 53.1ms against 54.0ms uncached -- no improvement at all
-- -- while mm/memory.c, whose few resolvable callees live in the file
-- already open, went to 0.1ms. The client set is part of the key instead
-- (see client_key), so a changed set produces a different key rather than
-- needing a sweep, and content changes are caught by the changedtick guard.

-- Ask whichever server is attached to the source buffer where `name` is defined.
-- Calls cb(location, err) where location = { uri, range, kind, name }.
function M.locate(name, source_bufnr, cb)
  local bufnr = (source_bufnr and vim.api.nvim_buf_is_valid(source_bufnr)) and source_bufnr or 0
  if #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
    return cb(nil, "no language server attached to the source buffer")
  end

  -- Keyed on the client set (which decides what a name can resolve to) plus
  -- the name, and validated against the DEFINITION file's state rather than
  -- the source buffer's.
  --
  -- Guarding on the source buffer's changedtick was the first attempt and it
  -- guards the wrong file twice over. It is too strict for the common case:
  -- a name's definition does not move because you typed a character in the
  -- file you are reading from, yet every keystroke would throw the whole
  -- cache away, which is precisely the editing session the cache is for. And
  -- it is too weak for the case that matters: if the DEFINITION moves, the
  -- cached range goes stale, extract re-requests documentSymbol with that
  -- stale range as its reference, `_symbol_range` picks whatever now
  -- contains it, and the wrong body is spliced -- a wrong answer, not a slow
  -- one. The definition file's tick catches exactly that.
  local key = client_key(bufnr) .. "\1" .. name
  local function loc_tick(loc)
    -- Only consult a buffer that already exists; uri_to_bufnr would create
    -- one, and a definition file nobody has opened cannot have been edited
    -- in this session anyway.
    local b = vim.fn.bufnr(vim.uri_to_fname(loc.uri))
    return b ~= -1 and tick_of(b) or nil
  end

  do
    local e = M._locate_cache[key]
    if e then
      local now_tick = loc_tick(e.value)
      -- An entry recorded before the definition file was loaded carries no
      -- tick, and `extract` loads that file moments later -- so by the next
      -- lookup a tick exists where none was stored. That is a file being
      -- OPENED, not changed, and treating it as a change threw away roughly
      -- half of all repeats: CI reported 8 of 12 repeat lookups going back
      -- to the server while every local run, where the definitions happened
      -- to live in an already-loaded buffer, hit every time. Adopt the tick
      -- instead -- but only when the buffer is unmodified, because then its
      -- content is still what is on disk and therefore still what the server
      -- indexed when it gave us this range. A buffer with unsaved edits gets
      -- no such benefit and is retired.
      if e.tick == nil and now_tick ~= nil then
        local b = vim.fn.bufnr(vim.uri_to_fname(e.value.uri))
        if b ~= -1 and not vim.bo[b].modified then
          e.tick = now_tick
        end
      end
      if e.tick == now_tick then
        e.at = vim.uv.now()
        local span = profile.start()
        span("locate:cached", name)
        return cb(e.value, nil)
      end
      M._locate_cache[key] = nil
    end
  end

  local span = profile.start()
  local finish = once_with_timeout(function(loc, err)
    span(loc and "locate:ok" or "locate:miss",
      loc and ("%s @ %s"):format(loc.name or name, vim.fn.fnamemodify(vim.uri_to_fname(loc.uri), ":t")) or name)
    if loc then
      cache_put(M._locate_cache, key, loc, loc_tick(loc), M._locate_cache_n)
    end
    cb(loc, err)
  end, function()
    return nil, "workspace/symbol timed out (server busy or stuck?)"
  end)
  vim.lsp.buf_request_all(bufnr, "workspace/symbol", { query = name }, function(results)
    local all = {}
    for _, r in pairs(results or {}) do
      for _, s in ipairs(r.result or {}) do
        all[#all + 1] = s
      end
    end
    if #all == 0 then
      return finish(nil, "no symbol named '" .. name .. "'")
    end

    -- Prefer an exact-name match; servers fuzzy-match otherwise.
    local pick
    for _, s in ipairs(all) do
      if s.name == name then
        pick = s
        break
      end
    end
    pick = pick or all[1]

    local loc = pick.location
    finish({ uri = loc.uri, range = loc.range, kind = pick.kind, name = pick.name }, nil)
  end)
end

-- Map an LSP SymbolKind to the label consumers expect: function-ish kinds
-- become "function_definition" (the inliner keys its function path off that
-- exact string); anything else becomes the lowercase kind name.
local FUNCTION_KINDS = { [6] = true, [9] = true, [12] = true } -- Method, Constructor, Function

local function kind_label(kind)
  if FUNCTION_KINDS[kind] then
    return "function_definition"
  end
  local name = vim.lsp.protocol.SymbolKind[kind]
  return type(name) == "string" and name:lower() or "symbol"
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

-- Pick the definition's full range out of a documentSymbol response. Handles
-- both shapes: hierarchical DocumentSymbol[] (range + children) and flat
-- SymbolInformation[] (location.range, name-matched, optionally uri-matched).
-- The deepest symbol whose range contains `ref_range` wins. DocumentSymbol
-- .range is full-range by spec, so a hierarchical symbol whose range equals
-- ref_range is a normal, valid match. SymbolInformation.location.range has
-- no such guarantee -- some servers report just the name -- so for the flat
-- shape only, a range identical to ref_range is rejected as name-only and
-- extraction falls back to tree-sitter instead of splicing a bare name.
-- `uri`, when given, additionally restricts flat entries to the requested
-- document (workspace/symbol-shaped responses can span files). Returns
-- (range, label).
function M._symbol_range(symbols, ref_range, name, uri)
  local best, best_label
  local function consider(range, kind)
    if contains(range, ref_range) then
      if not best or contains(best, range) then
        best, best_label = range, kind_label(kind)
      end
    end
  end
  local function walk(list)
    if type(list) ~= "table" then -- vim.NIL / absent children
      return
    end
    for _, s in ipairs(list) do
      if s.range then -- hierarchical DocumentSymbol
        consider(s.range, s.kind)
        walk(s.children)
      elseif
        s.location
        and s.location.range
        and (name == nil or s.name == name)
        and (uri == nil or s.location.uri == nil or s.location.uri == uri)
        and not same_range(s.location.range, ref_range)
      then
        consider(s.location.range, s.kind) -- flat SymbolInformation
      end
    end
  end
  walk(symbols)
  return best, best_label
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

-- Small set of transparent container nodes the ancestor walk below must
-- never select, and must stop ascending past. This is NOT a revival of the
-- old per-language definition table: it does not say what a definition
-- looks like, only lists a handful of wrapper nodes (include guards,
-- linkage blocks, and the declaration list they hold) whose *own* range is
-- never the right answer, no matter the language.
local CONTAINER_NODES = {
  preproc_ifdef = true,
  preproc_if = true,
  preproc_else = true,
  preproc_elif = true,
  linkage_specification = true,
  declaration_list = true,
}

-- Synchronous fallback extraction, used when no server range is available.
-- Table-free: starting at the located node and walking up through its
-- ancestors, the OUTERMOST ancestor starting within [srow-3, srow] (return
-- types / attributes on their own line) wins, stopping the ascent (without
-- ever recording it) at the first CONTAINER_NODES ancestor -- e.g. an
-- #ifndef guard or an `extern "C"` block -- so a definition near the top of
-- a guarded header never comes back as the whole guarded region. There is
-- deliberately no "innermost ancestor that spans multiple lines" shortcut:
-- when a parameter list spans lines, the innermost multi-line ancestor is
-- just the declarator (signature only, body dropped), so outermost-in-window
-- is the only rule -- the container denylist alone is what keeps it from
-- also swallowing the guard. For C functions this naturally yields the node
-- type "function_definition" as the label. Without a parser, the brace
-- heuristic is the last resort.
function M.extract_sync(loc)
  local bufnr = vim.uri_to_bufnr(loc.uri)
  vim.fn.bufload(bufnr)
  local srow = loc.range.start.line
  local scol = loc.range.start.character

  -- `.h` headers are often detected as C++ while only the C parser is installed,
  -- so try the detected language, then fall back to C / C++.
  local seen = {}
  for _, lang in ipairs({ buffer_lang(bufnr), "c", "cpp" }) do
    if lang and lang ~= "" and not seen[lang] then
      seen[lang] = true
      local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
      if ok and parser then
        local root = parser:parse()[1]:root()
        local node = root:named_descendant_for_range(srow, scol, srow, scol)
        local outermost_in_window
        while node and node:parent() do -- stop before the whole-file root
          if CONTAINER_NODES[node:type()] then
            break -- a bigger container reached; keep what was found below it
          end
          local a = node:range()
          if a >= srow - 3 and a <= srow then
            outermost_in_window = node
          end
          node = node:parent()
        end
        if outermost_in_window then
          local a, _, b, _ = outermost_in_window:range()
          return vim.api.nvim_buf_get_lines(bufnr, a, b + 1, false), outermost_in_window:type()
        end
        break -- parsed fine but nothing plausible here
      end
    end
  end

  return M.extract_heuristic(bufnr, srow), "heuristic"
end

-- LRU cache of definition-file attachments (target bufnr -> { ids, at }).
-- Capacity is a module field so tests can shrink it.
M._attach_cache_n = 8
M._attach_cache = {}

local function cache_attachment(target, newly_attached)
  local cache = M._attach_cache
  if cache[target] then
    cache[target].at = vim.uv.now() -- refresh recency; ids already recorded
  elseif #newly_attached > 0 then
    cache[target] = { ids = newly_attached, at = vim.uv.now() }
  end
  local entries = {}
  for b, e in pairs(cache) do
    entries[#entries + 1] = { b = b, at = e.at }
  end
  table.sort(entries, function(a, b)
    return a.at < b.at
  end)
  for i = 1, #entries - M._attach_cache_n do
    local b = entries[i].b
    local e = cache[b]
    cache[b] = nil
    if vim.api.nvim_buf_is_valid(b) and #vim.fn.win_findbuf(b) == 0 then
      for _, id in ipairs(e.ids) do
        pcall(vim.lsp.buf_detach_client, b, id)
      end
    end
  end
end

-- Extract the definition at `loc`. Asks the server attached to `source_bufnr`
-- for the target document's symbols and uses the returned full range; falls
-- back to extract_sync when there is no server, no client actually supports
-- documentSymbol, the target buffer never attaches to a client, the request
-- errors, or there is no usable range. cb(lines, label) is called exactly
-- once on every path -- possibly synchronously (fallback path).
function M.extract(loc, source_bufnr, cb)
  local span = profile.start()
  local bufnr = (source_bufnr and vim.api.nvim_buf_is_valid(source_bufnr)) and source_bufnr or 0
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  for _, c in ipairs(clients) do
    profile.identify(c)
  end
  if #clients == 0 then
    local lines, label = M.extract_sync(loc)
    span("extract:no-lsp")
    return cb(lines, label)
  end

  -- The definition file may not be open anywhere; load it and attach the
  -- source buffer's clients so the server learns about the document.
  -- buf_attach_client can return false (e.g. the target ends up with no
  -- real clients), and a client that never attaches or does not support
  -- documentSymbol would otherwise mean buf_request_all's handler is either
  -- never called or called with an error -- either way cb would never fire.
  -- The capability check below is the exact same predicate buf_request_all
  -- uses to compute its `remaining` response count (get_clients filtered by
  -- bufnr + method, which itself filters by attached_buffers and
  -- client:supports_method), so it cannot drift out of sync with nvim's own
  -- bookkeeping: if it reports zero, buf_request_all's handler is guaranteed
  -- never to fire and we must fall back immediately instead of waiting.
  local target = vim.uri_to_bufnr(loc.uri)

  -- Identity and size travel with every span from here on. A four-second
  -- extract and a 240ms one are the same row without them, and the first
  -- question a slow log raises -- which file was that, and how big -- had no
  -- answer in the data.
  local function detail()
    local n = vim.api.nvim_buf_is_loaded(target) and vim.api.nvim_buf_line_count(target) or -1
    return ("%s @ %s%s"):format(
      loc.name or "?",
      vim.fn.fnamemodify(vim.uri_to_fname(loc.uri), ":t"),
      n >= 0 and (" (" .. n .. "L)") or "")
  end

  -- Reading the definition file off disk is not the same cost as the
  -- server's preamble, and both used to land inside one `extract:cold`. On
  -- a large header they are minutes apart in character: one is I/O we do,
  -- the other is work the server does that we only wait for.
  local load_span = profile.start()
  local was_loaded = vim.api.nvim_buf_is_loaded(target)
  vim.fn.bufload(target)
  if not was_loaded then
    load_span("extract:bufload", detail())
  end

  -- Cache key computed here, but NOT consulted until after the attachment
  -- block below. Attaching the definition file is a side effect other code
  -- depends on -- the macro path needs the target attached before clangd
  -- will run its ExpandMacro tweak -- so a cache hit skips the
  -- documentSymbol round trip and nothing else. Ordering this way is a
  -- precaution about that dependency, not a fix for an observed break.
  local ekey = loc.uri .. "\1" .. loc.range.start.line .. ":" .. loc.range.start.character
    .. "\1" .. loc.range["end"].line .. ":" .. loc.range["end"].character
  -- Attachments WE create are cached, not dropped when the request settles:
  -- re-attaching a definition header makes clangd rebuild its whole preamble.
  -- Re-measured 2026-07-30 on linux-6.12 (defconfig, clangd 18.1.3, reading
  -- kernel/sched/core.c, probing include/linux/sched.h, 12 reps after 3
  -- discarded, our own result caches disabled so this is the server's cost
  -- and not ours): p50 178.4ms with an immediate detach against 11.0ms with
  -- the attachment kept -- 16.2x. The figure this comment carried before
  -- (~470ms against ~16ms) came from an earlier run on a different header
  -- and had never been reproduced; the ratio holds, the absolute numbers
  -- did not, so they are replaced with ones that can be re-derived from the
  -- method above. The least
  -- recently used entries beyond _attach_cache_n are detached instead, so a
  -- long session stays bounded without repaying the preamble every keypress.
  -- A buffer the user actually has in a window is never detached.
  local attach_span = profile.start()
  local newly_attached = {}
  for _, c in ipairs(clients) do
    local pre = c.attached_buffers and c.attached_buffers[target]
    vim.lsp.buf_attach_client(target, c.id)
    if not pre then
      newly_attached[#newly_attached + 1] = c.id
    end
  end
  cache_attachment(target, newly_attached)
  if #newly_attached > 0 then
    attach_span("extract:attach", detail())
  end

  -- Now that the attachment side effect has happened, a cached body may
  -- stand in for the documentSymbol round trip. Invalidated by the
  -- definition file's own changedtick: editing the definition must produce
  -- the new body, not the one spliced last time. bufload above guarantees
  -- the tick is available, unlike in locate.
  local etick = tick_of(target)
  if etick then
    local hit = cache_get(M._extract_cache, ekey, etick)
    if hit then
      span("extract:cached", detail())
      return cb(hit[1], hit[2])
    end
  end
  -- The span says whether WE made the server open a new document, which is
  -- what actually costs a preamble build. "already open" covers both our own
  -- attachment cache and a file the user has open anyway (a definition in the
  -- current file is the common case, and is always fast).
  local stage = #newly_attached > 0 and "extract:cold" or "extract:warm"
  if #vim.lsp.get_clients({ bufnr = target, method = "textDocument/documentSymbol" }) == 0 then
    local lines, label = M.extract_sync(loc)
    span("extract:no-capability", detail())
    return cb(lines, label)
  end

  -- A wedged server must not hang the keypress: after the timeout, extract
  -- locally and say so (the late response, if any, is dropped by the guard).
  -- once_with_timeout routes the timeout's own result through the SAME
  -- callback as a real response, so without this flag a degraded, locally
  -- extracted answer produced because the server was momentarily busy would
  -- be cached and then served for the rest of the session. The flag is set
  -- before on_timeout's value reaches the callback.
  local timed_out = false
  local budget = #newly_attached > 0 and M._cold_timeout_ms or M._timeout_ms
  local finish = require("inline-explorer.async").once_with_timeout(function(lines, label)
    -- A timeout is not a measurement of the server. once_with_timeout routes
    -- its own result through this same callback, so labelling by `stage`
    -- recorded a wedged request as a successful `extract:cold` whose
    -- duration was really just _timeout_ms -- a real log showed
    -- `extract:cold 4030.0ms` against a 4000ms timeout, which reads as "the
    -- server took four seconds" when what it means is "we stopped waiting
    -- and extracted locally, and the true cost is unknown but at least
    -- four seconds".
    span(timed_out and "extract:timeout" or stage, detail())
    -- A real response is cached on the way out, fallback label included:
    -- whatever the user was shown is what they get again, and the
    -- changedtick guard retires it as soon as the file changes.
    if lines and etick and not timed_out then
      cache_put(M._extract_cache, ekey, { lines, label }, etick, M._extract_cache_n)
    end
    cb(lines, label)
  end, function()
    timed_out = true
    -- Re-issue the SAME request in the background and log how long it takes.
    -- This is the one measurement that separates the two families of cause,
    -- and it can only be taken on the machine that has the problem: a fast
    -- retry means the server was building this file's preamble and has now
    -- finished (a timing problem, which the shortened cold budget already
    -- handles); a retry that is also slow means something about this file is
    -- structurally expensive for this server -- inferred flags, a config we
    -- cannot see -- and no budget will fix it.
    --
    -- Costs nothing when profiling is off: the whole block is skipped.
    if profile.enabled then
      local probe = profile.start()
      local answered = false
      vim.lsp.buf_request_all(target, "textDocument/documentSymbol", params, function(res)
        for _, r in pairs(res or {}) do
          if r.result then
            answered = true
          end
        end
        probe(answered and "extract:retry-after-timeout" or "extract:retry-failed", detail())
      end)
    end
    -- Name the file and say what happens next. "timed out" alone left the
    -- user with no way to tell a server that is wedged from one that is
    -- merely building a preamble for a file it has not seen -- and no
    -- reason to believe a second attempt would behave differently.
    vim.notify(("[inline-explorer] %s: no answer within %dms for %s; extracted locally. Looking again will use the server."):format(
      loc.name or "?", budget, vim.fn.fnamemodify(vim.uri_to_fname(loc.uri), ":t")), vim.log.levels.WARN)
    return M.extract_sync(loc)
  end, budget)

  local params = { textDocument = { uri = loc.uri } }
  vim.lsp.buf_request_all(target, "textDocument/documentSymbol", params, function(results)
    -- pcall so a malformed/unexpected response shape can't leave cb unfired.
    local ok, lines, label = pcall(function()
      local range, lbl
      for _, r in pairs(results or {}) do
        if r.result then
          range, lbl = M._symbol_range(r.result, loc.range, loc.name, loc.uri)
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
      return ls, lbl
    end)
    if ok and lines then
      finish(lines, label)
    else
      finish(M.extract_sync(loc))
    end
  end)
end

-- Last resort when no tree-sitter parser is available. Brace-oriented, so it
-- only really helps C-family languages; anything else needs a parser installed.
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

  local lines = vim.api.nvim_buf_get_lines(bufnr, srow, math.min(total, srow + 500), false)
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

-- Composed lookup: name -> definition body. locate then extract, one
-- callback: cb(lines, label, err). On failure lines is nil and err carries
-- the reason (extract itself always yields something via its fallbacks, so a
-- nil here means location failed).
function M.fetch(name, source_bufnr, cb)
  M.locate(name, source_bufnr, function(loc, err)
    if not loc then
      return cb(nil, nil, err or "not found")
    end
    M.extract(loc, source_bufnr, function(lines, label)
      cb(lines, label, nil)
    end)
  end)
end

return M
