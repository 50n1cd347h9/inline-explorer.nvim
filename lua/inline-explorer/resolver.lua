-- Resolver: given an identifier name, find where clangd says it is defined,
-- then extract the full definition text with tree-sitter (heuristic fallback).
--
-- Resolution is name-based (workspace/symbol) on purpose: the reading view is a
-- copy buffer that clangd is NOT attached to, and nested expansions live on
-- inserted text with no real file position. A name lookup works at any depth.
local M = {}

-- Ask clangd (via any buffer it is attached to) where `name` is defined.
-- Calls cb(location, err) where location = { uri, range, kind, name }.
function M.locate(name, source_bufnr, cb)
  if #vim.lsp.get_clients({ name = "clangd" }) == 0 then
    return cb(nil, "clangd is not running")
  end
  local bufnr = (source_bufnr and vim.api.nvim_buf_is_valid(source_bufnr)) and source_bufnr or 0

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

    -- Prefer an exact-name match; clangd fuzzy-matches otherwise.
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

-- Tree-sitter node types that represent an expandable definition.
local DEFINITION_NODES = {
  function_definition = true,
  preproc_def = true,
  preproc_function_def = true,
  declaration = true,
  type_definition = true,
  struct_specifier = true,
  enum_specifier = true,
  union_specifier = true,
}

-- Extract the full definition body at `loc`. Returns (lines, label).
function M.extract(loc)
  local bufnr = vim.uri_to_bufnr(loc.uri)
  vim.fn.bufload(bufnr)
  local srow = loc.range.start.line
  local scol = loc.range.start.character

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "c")
  if ok and parser then
    local root = parser:parse()[1]:root()
    local node = root:named_descendant_for_range(srow, scol, srow, scol)
    while node do
      if DEFINITION_NODES[node:type()] then
        local a, _, b, _ = node:range()
        return vim.api.nvim_buf_get_lines(bufnr, a, b + 1, false), node:type()
      end
      node = node:parent()
    end
  end

  return M.extract_heuristic(bufnr, srow), "heuristic"
end

-- Fallback when tree-sitter is unavailable: macros follow `\` continuations,
-- functions are captured by naive brace matching.
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
