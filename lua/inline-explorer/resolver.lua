-- Resolver: given an identifier name, ask the language server where it is
-- defined, then extract the full definition text with tree-sitter (heuristic
-- fallback).
--
-- Resolution is name-based (workspace/symbol) on purpose: the reading view is a
-- copy buffer no server is attached to, and nested expansions live on inserted
-- text with no real file position. A name lookup works at any depth, and
-- workspace/symbol + tree-sitter are both language-agnostic, so nothing here is
-- tied to a single language or server.
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

-- Tree-sitter node types that name a definition, across languages. This is a
-- fast/precise allow-list; anything not listed still matches via NODE_PATTERNS.
local DEFINITION_NODES = {
  -- C / C++
  function_definition = true,
  preproc_def = true,
  preproc_function_def = true,
  declaration = true,
  type_definition = true,
  struct_specifier = true,
  enum_specifier = true,
  union_specifier = true,
  class_specifier = true,
  template_declaration = true,
  -- JavaScript / TypeScript
  function_declaration = true,
  generator_function_declaration = true,
  function_expression = true,
  arrow_function = true,
  method_definition = true,
  class_declaration = true,
  lexical_declaration = true,
  variable_declaration = true,
  type_alias_declaration = true,
  interface_declaration = true,
  enum_declaration = true,
  -- Python
  class_definition = true,
  decorated_definition = true,
  -- Rust
  function_item = true,
  struct_item = true,
  enum_item = true,
  trait_item = true,
  impl_item = true,
  mod_item = true,
  macro_definition = true,
  const_item = true,
  static_item = true,
  type_item = true,
  let_declaration = true,
  -- Go
  method_declaration = true,
  type_declaration = true,
  const_declaration = true,
  var_declaration = true,
  -- Java / C#
  field_declaration = true,
  constructor_declaration = true,
  -- Lua
  local_function = true,
  assignment_statement = true,
  -- Ruby
  method = true,
  singleton_method = true,
  module = false, -- explicitly excluded: too broad (whole-file container)
}

-- Suffix patterns that generically identify a definition node in the long tail
-- of languages not covered above. Deliberately anchored to endings so that
-- whole-file containers (module, program, source_file, translation_unit,
-- chunk, ...) never match.
local NODE_PATTERNS = { "_definition$", "_declaration$", "_item$", "_def$" }

local function is_definition(node_type)
  local known = DEFINITION_NODES[node_type]
  if known ~= nil then
    return known -- honour explicit true/false (e.g. module = false)
  end
  for _, pat in ipairs(NODE_PATTERNS) do
    if node_type:find(pat) then
      return true
    end
  end
  return false
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

-- Extract the full definition body at `loc`. Returns (lines, label).
function M.extract(loc)
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
        while node do
          if is_definition(node:type()) then
            local a, _, b, _ = node:range()
            return vim.api.nvim_buf_get_lines(bufnr, a, b + 1, false), node:type()
          end
          node = node:parent()
        end
        break -- parsed fine but no definition node here
      end
    end
  end

  return M.extract_heuristic(bufnr, srow), "heuristic"
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
