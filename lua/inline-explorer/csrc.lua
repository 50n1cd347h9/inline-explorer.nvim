-- Tree-sitter and text helpers for C source. Byte offsets are 0-based and
-- ranges end-exclusive, as tree-sitter reports them.
local util = require("inline-explorer.util")

local M = {}

-- Trees by exact source text: one inline action parses the same source several
-- times, and an edited source is a new key, so it never gets a stale tree. A
-- root node keeps its tree alive; `parser` and `tree` are only a precaution.
M._parse_cache_max = 4
M._parse_cache = {}

---@param src string
---@return TSNode root
function M.parse(src)
  local entry = M._parse_cache[src]
  if entry then
    entry.at = vim.uv.hrtime()
    return entry.root
  end
  local parser = vim.treesitter.get_string_parser(src, "c")
  local tree = parser:parse()[1]
  local root = tree:root()
  M._parse_cache[src] = { parser = parser, tree = tree, root = root, at = vim.uv.hrtime() }
  util.evict_lru(M._parse_cache, M._parse_cache_max)
  return root
end

-- A tree of `src` that stays out of the cache, for throwaway text that would
-- evict the trees worth keeping; nil when the C parser is missing.
---@param src string
---@return TSNode?
function M.parse_once(src)
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, "c")
  if not ok or not parser then
    return nil
  end
  return parser:parse()[1]:root()
end

-- Whether the tree-sitter C parser is installed.
---@return boolean
function M.has_parser()
  return M.parse_once("int __ie;") ~= nil
end

---@param node TSNode
---@return integer
function M.start_byte(node)
  local _, _, start_byte = node:range(true)
  return start_byte
end

---@param node TSNode
---@return integer
function M.end_byte(node)
  local _, _, _, _, _, end_byte = node:range(true)
  return end_byte
end

---@param node TSNode
---@return integer col 0-based, in bytes
local function start_col(node)
  local _, col = node:range(true)
  return col
end

---@param node TSNode
---@return integer
function M.line_start_byte(node)
  return M.start_byte(node) - start_col(node)
end

---@param src string
---@param node TSNode
---@return string
function M.line_indent(src, node)
  return src:match("^[ \t]*", M.line_start_byte(node) + 1)
end

-- The innermost node of type `ty` that encloses (row, col).
---@param root TSNode
---@param row integer 0-based
---@param col integer 0-based, in bytes
---@param ty string
---@return TSNode?
function M.ancestor_at(root, row, col, ty)
  local node = root:named_descendant_for_range(row, col, row, col)
  while node and node:type() ~= ty do
    node = node:parent()
  end
  return node
end

---@param node TSNode
---@param src string
---@return string
function M.text(node, src)
  local _, _, start_byte, _, _, end_byte = node:range(true)
  return src:sub(start_byte + 1, end_byte)
end

---@param node TSNode
---@param src string
---@param query_text string
---@return TSNode[]
function M.query_nodes(node, src, query_text)
  local out = {}
  for _, n in vim.treesitter.query.parse("c", query_text):iter_captures(node, src) do
    out[#out + 1] = n
  end
  return out
end

-- The named children of `node` without the extras: tree-sitter-c makes a
-- comment a named child wherever it sits, as in `return /* c */ x;`.
---@param node TSNode
---@return TSNode[]
function M.code_children(node)
  local out = {}
  for i = 0, node:named_child_count() - 1 do
    local child = node:named_child(i)
    ---@cast child -nil
    if not child:extra() then
      out[#out + 1] = child
    end
  end
  return out
end

-- tree-sitter-c gives parenthesized_declarator no `declarator` field. The
-- child that stands in for one can follow a comment or a calling convention,
-- as in `(__stdcall *fp)`.
---@param d TSNode
---@return TSNode?
function M.inner_declarator(d)
  if d:type() ~= "parenthesized_declarator" then
    return d:field("declarator")[1]
  end
  for _, child in ipairs(M.code_children(d)) do
    local t = child:type()
    if t == "identifier" or t == "type_identifier" or t:match("declarator$") then
      return child
    end
  end
end

-- The name node of declarator `decl`: `p` in `*p`, `p[4]`, `(*p)(int)` or
-- `p = 0`, and the type_identifier a typedef declares.
---@param decl TSNode
---@return TSNode? name nil for a declarator without one, such as the `*` of `char *`
function M.decl_identifier(decl)
  local d = decl
  while d and d:type() ~= "identifier" and d:type() ~= "type_identifier" do
    d = M.inner_declarator(d)
  end
  return d
end

-- The text of decl_identifier.
---@param decl TSNode
---@param src string
---@return string? name
function M.decl_name(decl, src)
  local d = M.decl_identifier(decl)
  if d then
    return M.text(d, src)
  end
  return nil
end

-- The function_declarator with which `decl` declares a function: the one
-- next to the name, through `*`, `[]`, `()` and parentheses, as `f(int k)` in
-- `(*f(int k))(int)` or `f(void)` in `(*f(void))[4]`; nil when anything else
-- wraps it.
---@param decl TSNode
---@return TSNode?
function M.func_declarator(decl)
  local found
  local d = decl
  while d and d:type() ~= "identifier" do
    local t = d:type()
    if t == "function_declarator" then
      found = d
    elseif t ~= "pointer_declarator" and t ~= "parenthesized_declarator" and t ~= "array_declarator" then
      return nil
    end
    d = M.inner_declarator(d)
  end
  if not d then
    return nil
  end
  return found
end

-- Both are nil when func_declarator returns nil for `def`'s declarator.
---@param def TSNode
---@param src string
---@return string? name
---@return TSNode? func_decl
function M.function_name(def, src)
  local func_decl = M.func_declarator(def:field("declarator")[1])
  if not func_decl then
    return nil, nil
  end
  return M.decl_name(func_decl:field("declarator")[1], src), func_decl
end

-- The child of `root` that defines function `name`, and its
-- function_declarator. Only direct children are searched, not `#if` blocks.
---@param root TSNode
---@param src string
---@param name string
---@return TSNode? def
---@return TSNode? func_decl
function M.find_function_def(root, src, name)
  for i = 0, root:named_child_count() - 1 do
    local child = root:named_child(i)
    ---@cast child -nil
    if child:type() == "function_definition" then
      local child_name, func_decl = M.function_name(child, src)
      if child_name == name then
        return child, func_decl
      end
    end
  end
end

-- The call_expressions that call `name` under `root`, in document order; at
-- most `limit` when given. Not query_nodes: iter_captures is lazy, so the walk
-- stops at the limit.
---@param root TSNode
---@param src string
---@param name string
---@param limit? integer
---@return TSNode[]
function M.find_calls(root, src, name, limit)
  local calls = {}
  local query = vim.treesitter.query.parse("c", "(call_expression function: (identifier) @f)")
  for _, callee in query:iter_captures(root, src) do
    if M.text(callee, src) == name then
      calls[#calls + 1] = callee:parent()
      if limit and #calls >= limit then
        break
      end
    end
  end
  return calls
end

---@class inline_explorer.Param
---@field name string|false|nil unnamed: false for `int`, nil for `char *`
---@field node TSNode the parameter_declaration

-- The `void` of `f(void)` gives no entry.
---@param func_decl TSNode
---@param src string
---@return inline_explorer.Param[] params
---@return boolean is_variadic
function M.get_params(func_decl, src)
  local params, is_variadic = {}, false
  local param_list = func_decl:field("parameters")[1]
  for i = 0, param_list:named_child_count() - 1 do
    local child = param_list:named_child(i)
    ---@cast child -nil
    if child:type() == "variadic_parameter" then
      is_variadic = true
    elseif child:type() == "parameter_declaration" then
      local decl = child:field("declarator")[1]
      if decl then
        params[#params + 1] = { name = M.decl_name(decl, src), node = child }
      else
        local ty = child:field("type")[1]
        local is_void = ty ~= nil and M.text(ty, src) == "void"
        if not is_void then
          params[#params + 1] = { name = false, node = child }
        end
      end
    end
  end
  return params, is_variadic
end

-- `{ start_byte, end_byte, replacement }`, with absolute offsets in the source.
---@alias inline_explorer.Edit { [1]: integer, [2]: integer, [3]: string }

-- The text of bytes [s, e) of `src`, with the `edits` that lie wholly inside
-- that range applied.
---@param src string
---@param s integer
---@param e integer
---@param edits inline_explorer.Edit[]
---@return string
function M.apply_edits(src, s, e, edits)
  local within = {}
  for _, ed in ipairs(edits) do
    if ed[1] >= s and ed[2] <= e then
      within[#within + 1] = ed
    end
  end
  table.sort(within, function(a, b)
    return a[1] > b[1]
  end)
  local region = src:sub(s + 1, e)
  for _, ed in ipairs(within) do
    local from, to = ed[1] - s, ed[2] - s
    region = region:sub(1, from) .. ed[3] .. region:sub(to + 1)
  end
  return region
end

-- The leading spaces and tabs that all non-blank `lines` share.
---@param lines string[]
---@return string
function M.common_ws_prefix(lines)
  local prefix
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local ws = l:match("^[ \t]*")
      if not prefix then
        prefix = ws
      else
        local i = 1
        while i <= #prefix and prefix:sub(i, i) == ws:sub(i, i) do
          i = i + 1
        end
        prefix = prefix:sub(1, i - 1)
      end
    end
  end
  return prefix or ""
end

-- The lines of `fragment` with their common indent replaced by `target`;
-- blank lines become empty.
---@param fragment string
---@param target string
---@return string[]
function M.reindent(fragment, target)
  local lines = vim.split(fragment, "\n", { plain = true })
  local strip_len = #M.common_ws_prefix(lines)
  local out = {}
  for _, l in ipairs(lines) do
    if l:match("%S") then
      out[#out + 1] = target .. l:sub(strip_len + 1)
    else
      out[#out + 1] = ""
    end
  end
  return out
end

return M
