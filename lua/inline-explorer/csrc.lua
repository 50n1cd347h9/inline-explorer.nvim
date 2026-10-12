-- Low-level tree-sitter and text helpers for C source: parsing, node byte
-- ranges, declarator and type reconstruction, and edit application. Byte
-- offsets are 0-based and ranges are end-exclusive, as tree-sitter reports
-- them, so a node's text is src:sub(start_byte + 1, end_byte).
local util = require("inline-explorer.util")

local M = {}

-- Parsed trees, keyed on the exact source text. Several steps of one inline
-- action parse the same source, and a parse takes time in proportion to the
-- whole file. Editing the buffer changes the text, so a stale tree is never
-- returned. Lua interns strings, so the long key costs no hashing per lookup.
--
-- At most _parse_cache_max entries are kept. An entry's `at` is the
-- vim.uv.hrtime() of its last use, which util.evict_lru reads to drop the
-- least recently used entries. The entry also holds the parser and the tree.
-- A root node keeps its tree alive by itself, so these are only a precaution.
M._parse_cache_max = 4
M._parse_cache = {}

-- The root node of `src` parsed as C.
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

-- Node positions come from node:range(true), which returns
--   start_row, start_col, start_byte, end_row, end_col, end_byte
-- where a column is a byte offset within its row.
function M.start_byte(node)
  local _, _, start_byte = node:range(true)
  return start_byte
end

function M.end_byte(node)
  local _, _, _, _, _, end_byte = node:range(true)
  return end_byte
end

function M.start_col(node)
  local _, start_col = node:range(true)
  return start_col
end

-- Byte offset of the start of the line that `node` starts on.
function M.line_start_byte(node)
  return M.start_byte(node) - M.start_col(node)
end

-- The leading spaces and tabs of the line that `node` starts on.
function M.line_indent(src, node)
  return src:match("^[ \t]*", M.line_start_byte(node) + 1)
end

-- The innermost node of type `ty` enclosing (row, col), or nil.
function M.ancestor_at(root, row, col, ty)
  local node = root:named_descendant_for_range(row, col, row, col)
  while node and node:type() ~= ty do
    node = node:parent()
  end
  return node
end

-- The source text of `node`.
function M.text(node, src)
  return src:sub(M.start_byte(node) + 1, M.end_byte(node))
end

-- All nodes under `node` that `query_text`, a C tree-sitter query, captures.
function M.query_nodes(node, src, query_text)
  local out = {}
  for _, n in vim.treesitter.query.parse("c", query_text):iter_captures(node, src) do
    out[#out + 1] = n
  end
  return out
end

-- The declarator one level inside declarator `d`, or nil. tree-sitter-c gives
-- parenthesized_declarator no `declarator` field, so its first named child is
-- used instead: `(*fp)` holds `*fp`.
local function inner_declarator(d)
  if d:type() == "parenthesized_declarator" then
    return d:named_child(0)
  end
  return d:field("declarator")[1]
end

-- The name that declarator `decl` declares: "p" for `*p`, `p[4]`, `(*p)(int)`
-- or `p = 0`. nil when no name is found, as for the `*` of an unnamed
-- `char *` parameter.
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

-- The function_declarator inside the declarator `decl` of a function
-- definition, looking through pointer and parenthesized declarators
-- (`*f(void)`, `(f)(void)`). nil when anything else wraps it.
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

-- C keywords that can make up a base type: type specifiers and qualifiers.
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

-- Keywords that are followed by a tag name, as in `struct foo`.
local TAG_KEYWORDS = { struct = true, union = true, enum = true }

-- The whitespace-separated tokens of `text`.
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

-- The base type in `text`, a run of tokens such as `local unsigned long` or
-- `block_state`. The type starts at the first type keyword (tokens before it
-- are macros like zlib's `local`), or at the first token when there is no
-- keyword. It goes on while the next token is a type keyword or the tag after
-- struct/union/enum, so a trailing macro such as `ZEXPORT` is left out.
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

-- Identifiers that a project #defines to a storage-class keyword, such as
-- zlib's `#define local static`. In `local block_state f(...)`, tree-sitter
-- takes such a macro for the return type (see return_base_type).
local KNOWN_LEADING_MACROS = { ["local"] = true }

-- Calling-convention and export macros that expand to nothing, such as the
-- `WINAPI` in `local WINAPI f(...)`. Other such macros are not recognized.
local KNOWN_DECORATOR_MACROS = { ZEXPORT = true, WINAPI = true }

-- Whether `text` is a single token that is in KNOWN_DECORATOR_MACROS.
local function is_single_known_decorator(text)
  local tokens = tokenize(text)
  return #tokens == 1 and KNOWN_DECORATOR_MACROS[tokens[1]] == true
end

-- The base of the return type of function_definition `def`, without the
-- `*`s of its declarator. field("type") is used as-is (it already handles
-- shapes like `CJSON_PUBLIC(cJSON *) f()`), except where tree-sitter misreads
-- zlib's leading `local` macro:
--
--   `local unsigned long f()`  The type node is one sized_type_specifier
--                              holding all three words. The text of every
--                              sized_type_specifier is rescanned.
--   `local block_state f()`    The type node is `local`, and the real type is
--                              in the ERROR node after it. That text is used
--                              if it contains a type keyword, or if the type
--                              node is in KNOWN_LEADING_MACROS and the ERROR
--                              node is not a lone KNOWN_DECORATOR_MACROS name.
--
-- The decorator check is needed because `local WINAPI f()` parses the same
-- way, and there `local` may be a real typedef. An unlisted decorator, as in
-- `local DLLEXPORT f()`, is taken for the type. `z_size_t ZEXPORT f()` keeps
-- z_size_t: ZEXPORT holds no keyword, and z_size_t is not a known macro.
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

-- How many `*` the declarator `decl` adds to the return type: 2 for
-- `char **f(void)`. Only pointer_declarators are walked, so a
-- parenthesized_declarator ends the count: `char (*f(void))` gives 0.
local function pointer_depth(decl)
  local depth, d = 0, decl
  while d and d:type() == "pointer_declarator" do
    depth = depth + 1
    d = inner_declarator(d)
  end
  return depth
end

-- The declared return type of function_definition `def` as text: the base
-- type plus one `*` per pointer level, e.g. "unsigned long *".
function M.return_type(def, src)
  local base = return_base_type(def, src)
  local depth = pointer_depth(def:field("declarator")[1])
  if depth > 0 then
    return base .. " " .. string.rep("*", depth)
  end
  return base
end

-- Returns name, func_decl: the name of function_definition `def` and its
-- function_declarator. Both are nil when the declarator is not a plain
-- (possibly pointer-returning) function.
function M.function_name(def, src)
  local func_decl = M.func_declarator(def:field("declarator")[1])
  if not func_decl then
    return nil, nil
  end
  return M.decl_name(func_decl:field("declarator")[1], src), func_decl
end

-- Returns def, func_decl: the top-level function_definition named `name`
-- under `root`, and its function_declarator. nil when there is none.
function M.find_function_def(root, src, name)
  for i = 0, root:named_child_count() - 1 do
    local child = root:named_child(i)
    if child:type() == "function_definition" then
      local child_name, func_decl = M.function_name(child, src)
      if child_name == name then
        return child, func_decl
      end
    end
  end
end

-- Calls to the function `name` under `root`, as call_expression nodes. With
-- `limit`, the search stops after that many matches. iter_captures is lazy,
-- so the rest of the tree is not walked (query_nodes would collect every
-- capture first).
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

-- Returns params, is_variadic for function_declarator `func_decl`.
--   params:      one { name = ..., node = <parameter_declaration> } per
--                parameter. name is false or nil when the parameter has none
--                (`int`, `char *`). The `void` of `f(void)` gives no entry.
--   is_variadic: whether the parameters include `...`.
function M.get_params(func_decl, src)
  local params, is_variadic = {}, false
  local param_list = func_decl:field("parameters")[1]
  for i = 0, param_list:named_child_count() - 1 do
    local child = param_list:named_child(i)
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

-- For a parameter declarator built only from `*` and `[]` around a name, such
-- as `*a[]`: the name's identifier node, and one `*` per level ("**"), since
-- an array parameter is a pointer. nil for any other shape, such as a
-- function pointer.
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
-- parameter's declared type is rebuilt (arrays decay to pointers), so a NULL
-- or 0 argument keeps the right pointer type, where __typeof__ or __auto_type
-- of the argument would deduce `int`. Other declarators (function pointers)
-- and unnamed parameters get an __auto_type line instead.
--   param:  an entry from get_params
--   arg:    the argument's expression text at the call site
--   rename: parameter name -> the name to declare instead, for a name that
--           the caller already uses
--   N:      the id of this inline expansion, which keeps generated names unique
--   idx:    the parameter's 1-based position, used in a generated name
--   src:    the callee's source text
function M.build_bind(param, arg, rename, N, idx, src)
  local decl = param.node:field("declarator")[1]
  local ident, stars = pointer_target(decl)
  if ident then
    -- The declaration specifiers, such as `const char`: all text before the declarator.
    local spec = src:sub(M.start_byte(param.node) + 1, M.start_byte(decl)):gsub("%s+$", "")
    local ident_name = M.text(ident, src)
    local name = rename[ident_name] or ident_name
    return string.format("%s %s%s = (%s);", spec, stars, name, arg)
  end
  local name
  if param.name then
    name = rename[param.name] or param.name
  else
    name = "__ie_arg" .. idx .. "_" .. N -- unnamed parameter
  end
  return string.format("__auto_type %s = (%s);", name, arg)
end

-- The text of the region [s, e) of `src` after applying the `edits` that lie
-- inside it. Each edit is { start_byte, end_byte, replacement }, in absolute
-- offsets of `src`. Edits outside the region are ignored.
function M.apply_edits(src, s, e, edits)
  local within = {}
  for _, ed in ipairs(edits) do
    if ed[1] >= s and ed[2] <= e then
      within[#within + 1] = ed
    end
  end
  -- Apply from the end, so the offsets of earlier edits stay valid.
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

-- The longest run of leading spaces and tabs that all non-blank lines share.
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

-- The lines of `fragment`, with their common indent replaced by `target`.
-- Relative nesting, and the source's mix of tabs and spaces, are kept. Blank
-- lines become empty.
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
