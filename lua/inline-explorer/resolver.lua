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
-- tables. tree-sitter (a generic two-pass ancestor walk that skips a small
-- set of transparent container nodes) and a brace counter remain as
-- fallbacks when no server range is available.
local M = {}

-- Ask whichever server is attached to the source buffer where `name` is defined.
-- Calls cb(location, err) where location = { uri, range, kind, name }.
function M.locate(name, source_bufnr, cb)
  local bufnr = (source_bufnr and vim.api.nvim_buf_is_valid(source_bufnr)) and source_bufnr or 0
  if #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
    return cb(nil, "no language server attached to the source buffer")
  end

  vim.lsp.buf_request_all(bufnr, "workspace/symbol", { query = name }, function(results)
    local all = {}
    for _, r in pairs(results or {}) do
      for _, s in ipairs(r.result or {}) do
        all[#all + 1] = s
      end
    end
    if #all == 0 then
      return cb(nil, "no symbol named '" .. name .. "'")
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
    cb({ uri = loc.uri, range = loc.range, kind = pick.kind, name = pick.name }, nil)
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
-- ancestors, two candidates are tracked in a single pass, stopping (without
-- recording it) at the first CONTAINER_NODES ancestor -- e.g. an #ifndef
-- guard or an `extern "C"` block -- so a definition near the top of a
-- guarded header never comes back as the whole guarded region:
--   1. first_spanning: the FIRST (innermost) ancestor that starts within
--      [srow-3, srow] (return types / attributes on their own line) and
--      either spans multiple lines or ends after srow. This is the usual
--      case and wins when present.
--   2. outermost_in_window: the OUTERMOST ancestor starting within that
--      same window, below the container reached (if any). This is the
--      fallback for single-line definitions, where nothing satisfies (1).
-- For C functions this naturally yields the node type "function_definition"
-- as the label. Without a parser, the brace heuristic is the last resort.
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
        local first_spanning, outermost_in_window
        while node and node:parent() do -- stop before the whole-file root
          if CONTAINER_NODES[node:type()] then
            break -- a bigger container reached; keep what was found below it
          end
          local a, _, b = node:range()
          if a >= srow - 3 and a <= srow then
            outermost_in_window = node
            if not first_spanning and (b > a or b > srow) then
              first_spanning = node
            end
          end
          node = node:parent()
        end
        local best = first_spanning or outermost_in_window
        if best then
          local a, _, b, _ = best:range()
          return vim.api.nvim_buf_get_lines(bufnr, a, b + 1, false), best:type()
        end
        break -- parsed fine but nothing plausible here
      end
    end
  end

  return M.extract_heuristic(bufnr, srow), "heuristic"
end

-- Whether `c` advertises textDocument/documentSymbol support for `bufnr`.
-- Guarded with pcall: the exact shape of Client:supports_method has moved
-- around across 0.10/0.11, and an unknown shape must not be treated as
-- support -- an unsupported client would otherwise leave buf_request_all's
-- handler uncalled (an LSP error response, or never invoked at all).
local function supports_document_symbol(c, bufnr)
  local ok, does = pcall(c.supports_method, c, "textDocument/documentSymbol", bufnr)
  return ok and does == true
end

-- Extract the definition at `loc`. Asks the server attached to `source_bufnr`
-- for the target document's symbols and uses the returned full range; falls
-- back to extract_sync when there is no server, no client actually supports
-- documentSymbol, the target buffer never attaches to a client, the request
-- errors, or there is no usable range. cb(lines, label) is called exactly
-- once on every path -- possibly synchronously (fallback path).
function M.extract(loc, source_bufnr, cb)
  local bufnr = (source_bufnr and vim.api.nvim_buf_is_valid(source_bufnr)) and source_bufnr or 0
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return cb(M.extract_sync(loc))
  end

  -- The definition file may not be open anywhere; load it and attach the
  -- source buffer's clients so the server learns about the document.
  -- buf_attach_client can return false (e.g. the target ends up with no
  -- real clients), and a client that never attaches or does not support
  -- documentSymbol would otherwise mean buf_request_all's handler is either
  -- never called or called with an error -- either way cb would never fire.
  -- Only proceed with the async round trip once at least one client is
  -- confirmed both attached and capable; otherwise fall back immediately.
  local target = vim.uri_to_bufnr(loc.uri)
  vim.fn.bufload(target)
  local usable = false
  for _, c in ipairs(clients) do
    if vim.lsp.buf_attach_client(target, c.id) and supports_document_symbol(c, target) then
      usable = true
    end
  end
  if not usable then
    return cb(M.extract_sync(loc))
  end

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
      cb(lines, label)
    else
      cb(M.extract_sync(loc))
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

return M
