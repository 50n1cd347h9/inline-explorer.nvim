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
function M.start_col(node)
  local _, start_col = node:range(true)
  return start_col
end

---@param node TSNode
---@return integer
function M.line_start_byte(node)
  return M.start_byte(node) - M.start_col(node)
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
  return src:sub(M.start_byte(node) + 1, M.end_byte(node))
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
local function inner_declarator(d)
  if d:type() ~= "parenthesized_declarator" then
    return d:field("declarator")[1]
  end
  for _, child in ipairs(M.code_children(d)) do
    local t = child:type()
    if t == "identifier" or t:match("declarator$") then
      return child
    end
  end
end

-- The name that declarator `decl` declares: "p" for `*p`, `p[4]`, `(*p)(int)`
-- or `p = 0`.
---@param decl TSNode
---@param src string
---@return string? name nil for a declarator without one, such as the `*` of `char *`
function M.decl_name(decl, src)
  local d = decl
  while d and d:type() ~= "identifier" do
    d = inner_declarator(d)
  end
  if d then
    return M.text(d, src)
  end
  return nil
end

-- The function_declarator inside `decl`, through `*` and parentheses as in
-- `*f(void)` or `(*f(void))`; nil when anything else wraps it.
---@param decl TSNode
---@return TSNode?
function M.func_declarator(decl)
  local d = decl
  while d and d:type() ~= "function_declarator" do
    local t = d:type()
    if t ~= "pointer_declarator" and t ~= "parenthesized_declarator" then
      return nil
    end
    d = inner_declarator(d)
  end
  return d
end

local TYPE_KEYWORDS = {
  void = true,
  char = true,
  short = true,
  int = true,
  long = true,
  float = true,
  double = true,
  signed = true,
  unsigned = true,
  ["_Bool"] = true,
  struct = true,
  union = true,
  enum = true,
  const = true,
  volatile = true,
}

local TAG_KEYWORDS = { struct = true, union = true, enum = true }

local function tokenize(text)
  local tokens = {}
  for tok in text:gmatch("%S+") do
    tokens[#tokens + 1] = tok
  end
  return tokens
end

local function contains_type_keyword(text)
  for tok in text:gmatch("%S+") do
    if TYPE_KEYWORDS[tok] then
      return true
    end
  end
  return false
end

-- The base type in a run of tokens: from the first type keyword (else the
-- first token) through the keywords and struct/union/enum tag after it. In
-- `local unsigned long ZEXPORT`, that is "unsigned long".
local function base_type_from_run(text)
  local tokens = tokenize(text)
  if #tokens == 0 then
    return "int" -- C's implicit int
  end
  local first = 1
  for i, tok in ipairs(tokens) do
    if TYPE_KEYWORDS[tok] then
      first = i
      break
    end
  end
  local last = first
  while last < #tokens and (TYPE_KEYWORDS[tokens[last + 1]] or TAG_KEYWORDS[tokens[last]]) do
    last = last + 1
  end
  return table.concat(tokens, " ", first, last)
end

-- Identifiers that a project #defines to a storage class, such as zlib's
-- `#define local static`. See return_base_type.
local KNOWN_LEADING_MACROS = { ["local"] = true }

-- Calling-convention and export macros, which are not types.
local KNOWN_DECORATOR_MACROS = { ZEXPORT = true, WINAPI = true }

local function is_single_known_decorator(text)
  local tokens = tokenize(text)
  return #tokens == 1 and KNOWN_DECORATOR_MACROS[tokens[1]] == true
end

-- The base of `def`'s return type, without the declarator's `*`s. The type
-- field is right as it is (even for `CJSON_PUBLIC(cJSON *) f()`), except
-- around zlib's macros. A sized_type_specifier absorbs one on either side, as
-- in `local unsigned long f()` or `unsigned long ZEXPORT f()`, so every
-- sized_type_specifier is rescanned. In `local block_state f()`, the type is
-- `local` and the real one is in the ERROR node after it. That is used if it
-- has a type keyword, or if the type is a known leading macro and the ERROR is
-- not a lone known decorator: `local WINAPI f()` parses the same way, and
-- there `local` may be a real typedef. An unlisted decorator, as in
-- `local DLLEXPORT f()`, is taken for the type.
local function return_base_type(def, src)
  local ty = def:field("type")[1]
  if not ty then
    return "int" -- C's implicit int
  end
  local ty_text = M.text(ty, src)
  if ty:type() == "sized_type_specifier" then
    return base_type_from_run(ty_text)
  end
  if ty:type() == "type_identifier" and not TYPE_KEYWORDS[ty_text] then
    local sib = ty:next_sibling()
    if sib and sib:type() == "ERROR" then
      local sib_text = M.text(sib, src)
      local sib_has_keyword = contains_type_keyword(sib_text)
      local macro_before_typedef = KNOWN_LEADING_MACROS[ty_text] and not is_single_known_decorator(sib_text)
      if sib_has_keyword or macro_before_typedef then
        return base_type_from_run(sib_text)
      end
    end
  end
  return ty_text
end

-- How many `*` the declarator `decl` adds to the return type. A
-- parenthesized_declarator ends the count: `char (*f(void))` gives 0, not 1.
local function pointer_depth(decl)
  local depth, d = 0, decl
  while d and d:type() == "pointer_declarator" do
    depth = depth + 1
    d = inner_declarator(d)
  end
  return depth
end

-- `def`'s declared return type as text, such as "unsigned long *".
---@param def TSNode
---@param src string
---@return string
function M.return_type(def, src)
  local base = return_base_type(def, src)
  local depth = pointer_depth(def:field("declarator")[1])
  if depth > 0 then
    return base .. " " .. string.rep("*", depth)
  end
  return base
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

-- For a declarator of only `*` and `[]` around a name, such as `*a[]`: its
-- identifier and one `*` per level ("**"), as an array parameter is a pointer;
-- nil for any other shape. Only the `[]` next to the name decays, so `m[][4]`
-- wrongly gives `**`.
local function pointer_target(decl)
  local stars, d = "", decl
  while d and (d:type() == "pointer_declarator" or d:type() == "array_declarator") do
    stars = stars .. "*"
    d = inner_declarator(d)
  end
  if d and d:type() == "identifier" then
    return d, stars
  end
  return nil
end

-- The line `<param type> <name> = (<arg>);` that binds one argument. The
-- declared type is rebuilt because __auto_type would deduce `int` from a 0
-- argument and `void *` from NULL. Other declarators and unnamed parameters
-- get an __auto_type line.
---@param param inline_explorer.Param
---@param arg string the argument's text at the call site
---@param rename table<string, string> a name the caller uses -> the name to declare
---@param N integer the expansion's id, which keeps generated names unique
---@param idx integer param's 1-based position, which names it when it has no name
---@param src string the callee's source
---@return string
function M.build_bind(param, arg, rename, N, idx, src)
  local decl = param.node:field("declarator")[1]
  local ident, stars = pointer_target(decl)
  if ident then
    -- The text, not the type field: tree-sitter-c puts `const` outside it.
    local spec = src:sub(M.start_byte(param.node) + 1, M.start_byte(decl)):gsub("%s+$", "")
    local ident_name = M.text(ident, src)
    local name = rename[ident_name] or ident_name
    return string.format("%s %s%s = (%s);", spec, stars, name, arg)
  end
  local name
  if param.name then
    name = rename[param.name] or param.name
  else
    name = "__ie_arg" .. idx .. "_" .. N
  end
  return string.format("__auto_type %s = (%s);", name, arg)
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
