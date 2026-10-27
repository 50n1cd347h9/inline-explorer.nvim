-- Printers: the text of the three forms canalyze.decide picks from. The
-- analysis has made every judgement, the names included; a printer writes
-- the C for them: the declarations that bind the arguments and hold the
-- result, each `return` rewritten for its form, and the layout.
local csrc = require("inline-explorer.csrc")
local simplify = require("inline-explorer.simplify")

local M = {}

-- Declarations: the result variable, of the callee's return type, and one
-- line per parameter that binds its argument.

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
  local ty_text = csrc.text(ty, src)
  if ty:type() == "sized_type_specifier" then
    return base_type_from_run(ty_text)
  end
  if ty:type() == "type_identifier" and not TYPE_KEYWORDS[ty_text] then
    local sib = ty:next_sibling()
    if sib and sib:type() == "ERROR" then
      local sib_text = csrc.text(sib, src)
      local sib_has_keyword = contains_type_keyword(sib_text)
      local macro_before_typedef = KNOWN_LEADING_MACROS[ty_text] and not is_single_known_decorator(sib_text)
      if sib_has_keyword or macro_before_typedef then
        return base_type_from_run(sib_text)
      end
    end
  end
  return ty_text
end

-- The pointer_declarator that makes `func_decl`'s result a pointer, as the
-- `*const` of `char *const f(void)`, if any.
local function result_pointer(func_decl)
  local p = func_decl:parent()
  while p and p:type() == "parenthesized_declarator" do
    p = p:parent()
  end
  if p and p:type() == "pointer_declarator" then
    return p
  end
  return nil
end

-- The declaration of a variable `name` of `def`'s return type: `def`'s
-- declarator with `name` in place of the function's own, as `char (*name)`
-- for `char (*f(void))` or `int (*name)(int)` for `int (*f(int k))(int)`.
-- Extras in it, as zlib's ZEXPORT in `char * ZEXPORT f(void)`, are left out,
-- and so is a qualifier on the pointer returned: the variable is assigned.
---@param def TSNode a function_definition that csrc.func_declarator finds a function in
---@param src string
---@param name string
---@return string
local function result_decl(def, src, name)
  local decl = def:field("declarator")[1]
  local func_decl = csrc.func_declarator(decl)
  ---@cast func_decl -nil
  local edits = { { csrc.start_byte(func_decl), csrc.end_byte(func_decl), name } }
  local top_pointer = result_pointer(func_decl)
  local d = decl
  while d and d ~= func_decl do
    for child in d:iter_children() do
      if child:extra() or (d == top_pointer and child:type() == "type_qualifier") then
        local stop = csrc.end_byte(child)
        edits[#edits + 1] = { csrc.start_byte(child), stop + #src:match("^%s*", stop + 1), "" }
      end
    end
    d = csrc.inner_declarator(d)
  end
  local declarator = csrc.apply_edits(src, csrc.start_byte(decl), csrc.end_byte(decl), edits):gsub("%s+", " ")
  return return_base_type(def, src) .. " " .. declarator
end

-- The edit that turns parameter name `ident` into `name` and adjusts its
-- type as C adjusts a parameter's: an array declarator next to the name
-- becomes a pointer, keeping the qualifiers in its brackets (`m[][4]` ->
-- `(*m)[4]`, `a[const 4]` -> `*const a`), and a function declarator next to
-- it a function pointer (`f(int)` -> `(*f)(int)`).
local function decay_edit(ident, name, src)
  local adj = ident:parent()
  if adj and adj:type() == "array_declarator" and adj:field("declarator")[1] == ident then
    local ptr = { "*" }
    for _, child in ipairs(csrc.code_children(adj)) do
      if child:type() == "type_qualifier" then
        ptr[#ptr + 1] = csrc.text(child, src) .. " "
      end
    end
    ptr[#ptr + 1] = name
    local outer = adj:parent()
    local postfix = outer and (outer:type() == "array_declarator" or outer:type() == "function_declarator")
    local text = table.concat(ptr)
    return { csrc.start_byte(adj), csrc.end_byte(adj), postfix and "(" .. text .. ")" or text }
  end
  if adj and adj:type() == "function_declarator" and adj:field("declarator")[1] == ident then
    return { csrc.start_byte(ident), csrc.end_byte(ident), "(*" .. name .. ")" }
  end
  return { csrc.start_byte(ident), csrc.end_byte(ident), name }
end

-- The line `<param type> <name> = (<arg>);` that binds one argument: the
-- parameter's own declaration, adjusted by decay_edit, so a NULL or 0
-- argument keeps a pointer type and `const char *const argv[]` its inner
-- const. A parameter without an identifier gets an __auto_type line.
---@param param inline_explorer.Param
---@param arg string the argument's text at the call site
---@param name string the name to declare it as (see canalyze's bind_names)
---@param rename table<string, string> parameter name -> its new name, for the other parameters its type names
---@param src string the callee's source
---@return string
local function build_bind(param, arg, name, rename, src)
  local decl = param.node:field("declarator")[1]
  local ident = decl and csrc.decl_identifier(decl)
  if not ident or ident:type() ~= "identifier" then
    return string.format("__auto_type %s = (%s);", name, arg)
  end
  local edit = decay_edit(ident, name, src)
  local edits = { edit }
  -- Another parameter's name in the type, as the n of `int m[][n]`.
  for _, id in ipairs(csrc.query_nodes(param.node, src, "(identifier) @i")) do
    local r = rename[csrc.text(id, src)]
    if r and (csrc.end_byte(id) <= edit[1] or csrc.start_byte(id) >= edit[2]) then
      edits[#edits + 1] = { csrc.start_byte(id), csrc.end_byte(id), r }
    end
  end
  local text = csrc.apply_edits(src, csrc.start_byte(param.node), csrc.end_byte(param.node), edits)
  return string.format("%s = (%s);", text, arg)
end

-- The lines that bind ir's arguments to its parameters.
---@param ir inline_explorer.IR with args
---@return string[]
local function binds(ir)
  local out = {}
  for i, p in ipairs(ir.params) do
    out[i] = build_bind(p, ir.args[i], ir.bind_names[i], ir.param_rename, ir.src)
  end
  return out
end

-- The declaration of ir.ret_var, without its `;`.
---@param ir inline_explorer.IR
---@return string
function M.ret_decl(ir)
  return result_decl(ir.fn_def, ir.src, ir.ret_var)
end

-- One level of indentation, in the style of `indent`.
---@param indent string
---@return string
function M.indent_unit(indent)
  return indent:find("\t") and "\t" or "    "
end

local function splice(caller_src, edits)
  return csrc.apply_edits(caller_src, 0, #caller_src, edits)
end

-- Edits on ir.src that rewrite each `return`. Only the `return` keyword and,
-- for "goto", the `;` are replaced, so E stays in place with its body_edits:
--   "goto":    `return E;` -> `{ __ie_retN = E; goto __ie_endN; }`
--              `return;`   -> `{ goto __ie_endN; }`
--   "assign":  `return E;` -> `__ie_retN = E;`
--              `return;`   -> `(void)0;`
local function return_edits(ir, style)
  local edits = {}
  local function replace(node, text)
    edits[#edits + 1] = { csrc.start_byte(node), csrc.end_byte(node), text }
  end
  for _, r in ipairs(ir.returns) do
    local keyword = r:child(0)
    local semicolon = r:child(r:child_count() - 1)
    local has_expr = #csrc.code_children(r) > 0
    if style == "assign" then
      replace(keyword, has_expr and (ir.ret_var .. " =") or "(void)0")
    elseif has_expr then
      replace(keyword, "{ " .. ir.ret_var .. " =")
      replace(semicolon, "; goto " .. ir.end_label .. "; }")
    else
      replace(keyword, "{ goto " .. ir.end_label .. ";")
      replace(semicolon, " }")
    end
  end
  return edits
end

-- Statements 1..last_i with ir.body_edits and `extra` applied, from the start
-- of the first one's line, so that csrc.reindent sees the callee's
-- indentation; but from the statement itself when code precedes it on that
-- line, as the signature of `static int f(int x) { return x; }` does.
local function body_text(ir, last_i, extra)
  local edits = {}
  vim.list_extend(edits, ir.body_edits)
  vim.list_extend(edits, extra or {})
  local first = ir.stmts[1]
  local from = csrc.line_start_byte(first)
  if not ir.src:sub(from + 1, csrc.start_byte(first)):match("^[ \t]*$") then
    from = csrc.start_byte(first)
  end
  -- A bare `struct s { ... };` or `enum { A };` leaves its `;` to the block.
  local last = ir.stmts[last_i]
  local after = last:next_sibling()
  local stop = csrc.end_byte((after and after:type() == ";") and after or last)
  return csrc.apply_edits(ir.src, from, stop, edits)
end

-- print_hoisted with placement "wrap": a new block replaces target and holds
-- the `hoist` lines, then target.
local function print_wrapped(caller_src, ctx, hoist, replacement)
  local target_start = csrc.start_byte(ctx.target)
  local target_end = csrc.end_byte(ctx.target)
  local call_edit = { csrc.start_byte(ctx.call), csrc.end_byte(ctx.call), replacement }
  local modified = csrc.apply_edits(caller_src, target_start, target_end, { call_edit })
  local inner = ctx.indent .. M.indent_unit(ctx.indent)
  local out = { "{" }
  for _, l in ipairs(hoist) do
    out[#out + 1] = inner .. l
  end
  -- target's first line starts at its first character; the lines after it
  -- carry target's own indent, which inner replaces.
  for i, l in ipairs(vim.split(modified, "\n", { plain = true })) do
    if i > 1 and l:sub(1, #ctx.indent) == ctx.indent then
      l = l:sub(#ctx.indent + 1)
    end
    out[#out + 1] = inner .. l
  end
  out[#out + 1] = ctx.indent .. "}"
  return splice(caller_src, { { target_start, target_end, table.concat(out, "\n") } })
end

-- The `hoist` lines where canalyze.decide's `placement` puts them, and
-- `replacement` for the call.
local function print_hoisted(caller_src, ctx, placement, hoist, replacement)
  if placement == "wrap" then
    return print_wrapped(caller_src, ctx, hoist, replacement)
  end
  local block = {}
  for _, l in ipairs(hoist) do
    block[#block + 1] = ctx.indent .. l
  end
  return splice(caller_src, {
    { ctx.stmt_bol, ctx.stmt_bol, table.concat(block, "\n") .. "\n" },
    { csrc.start_byte(ctx.call), csrc.end_byte(ctx.call), replacement },
  })
end

-- Pretty: the bindings and all statements but the last are hoisted above
-- target, and E of the final `return E;`, parenthesised to keep its
-- precedence, replaces the call. Only for a simple callee (see decide).
---@param caller_src string
---@param ir inline_explorer.IR with args
---@param ctx inline_explorer.Ctx
---@param placement "above"|"wrap"
---@return string new_src
local function print_pretty(caller_src, ir, ctx, placement)
  local hoist = {}
  vim.list_extend(hoist, binds(ir))
  if #ir.stmts >= 2 then
    vim.list_extend(hoist, csrc.reindent(body_text(ir, #ir.stmts - 1), ""))
  end
  local expr = csrc.code_children(ir.stmts[#ir.stmts])[1]
  local expr_text = csrc.apply_edits(ir.src, csrc.start_byte(expr), csrc.end_byte(expr), ir.body_edits)
  local replacement = simplify.parens("(" .. expr_text .. ")")
  return print_hoisted(caller_src, ctx, placement, hoist, replacement)
end

-- Canonical: a GNU statement expression replaces the call, every return
-- becoming a goto to its end. It hoists nothing, so it has no placement.
---@param caller_src string
---@param ir inline_explorer.IR with args
---@param ctx inline_explorer.Ctx
---@return string new_src
local function print_canonical(caller_src, ir, ctx)
  local inner = ctx.indent .. M.indent_unit(ctx.indent)
  local parts = { "({" }
  for _, b in ipairs(binds(ir)) do
    parts[#parts + 1] = inner .. b
  end
  if ir.has_value then
    parts[#parts + 1] = inner .. M.ret_decl(ir) .. ";"
  end
  vim.list_extend(parts, csrc.reindent(body_text(ir, #ir.stmts, return_edits(ir, "goto")), inner))
  parts[#parts + 1] = inner .. ir.end_label .. ":;"
  if ir.has_value then
    parts[#parts + 1] = inner .. ir.ret_var .. ";"
  end
  parts[#parts + 1] = ctx.indent .. "})"
  return splice(caller_src, { { csrc.start_byte(ctx.call), csrc.end_byte(ctx.call), table.concat(parts, "\n") } })
end

-- Readable: the body is hoisted with every return turned into an assignment,
-- and __ie_retN replaces the call. An early return no longer stops the rest
-- of the body, so this is unfaithful to a callee that has one.
---@param caller_src string
---@param ir inline_explorer.IR with args
---@param ctx inline_explorer.Ctx
---@param placement "above"|"wrap"
---@return string new_src
local function print_readable_multi(caller_src, ir, ctx, placement)
  local hoist = {}
  vim.list_extend(hoist, binds(ir))
  if ir.has_value then
    hoist[#hoist + 1] = M.ret_decl(ir) .. ";"
  end
  vim.list_extend(hoist, csrc.reindent(body_text(ir, #ir.stmts, return_edits(ir, "assign")), ""))
  return print_hoisted(caller_src, ctx, placement, hoist, ir.ret_var)
end

M.PRINTERS = {
  pretty = print_pretty,
  canonical = print_canonical,
  readable_multi = print_readable_multi,
}

return M
