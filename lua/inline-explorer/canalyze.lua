-- Analysis: the callee becomes an IR, the call site a ctx, and decide() picks
-- the printer from them. Every judgement is made here.
local csrc = require("inline-explorer.csrc")

local M = {}

-- The names an expansion injects or renames to. N, an id unique to each
-- expansion, keeps them apart.
local INJECTED = {
  renamed = function(name, N)
    return name .. "__ie" .. N
  end,
  ret_var = function(N)
    return "__ie_ret" .. N
  end,
  end_label = function(N)
    return "__ie_end" .. N
  end,
  -- A parameter without a name, by its position.
  arg = function(idx, N)
    return "__ie_arg" .. idx .. "_" .. N
  end,
}

local NAMES = "[(identifier) (type_identifier)] @i"

-- Struct, union and enum tags are a namespace of their own.
local TAG_PARENTS = { struct_specifier = true, union_specifier = true, enum_specifier = true }

-- The identifiers and type names under `node`, tags left out.
local function ordinary_names(node, src)
  local out = {}
  for _, id in ipairs(csrc.query_nodes(node, src, NAMES)) do
    local parent = id:parent()
    if not (parent and TAG_PARENTS[parent:type()]) then
      out[#out + 1] = id
    end
  end
  return out
end

-- `(_)`, not `(identifier)`: `int *p;` and `int a[2];` put a pointer or array
-- declarator there, and decl_name digs the name out.
local LOCAL_DECLARATIONS = [[
  (declaration declarator: (_) @d)
  (type_definition declarator: (_) @d)
  (enumerator name: (identifier) @d)
]]
local DECLARATIONS = LOCAL_DECLARATIONS .. "(parameter_declaration declarator: (_) @d)"

-- { name, byte } for each identifier that error recovery left in an ERROR
-- node of a declaration under `nodes`. It is the name declared, as `limit`
-- in `u32 __maybe_unused limit = 7;`, or an annotation macro, as FAR in
-- `struct state FAR *s;`; misparsed_names tells them apart.
local function error_held(nodes, src)
  local held = {}
  for _, node in ipairs(nodes) do
    local errors = node:has_error() and csrc.query_nodes(node, src, "(ERROR (identifier) @e)") or {}
    for _, id in ipairs(errors) do
      local holder = id:parent():parent()
      if holder and (holder:type() == "declaration" or holder:type():match("declarator$")) then
        held[#held + 1] = { csrc.text(id, src), csrc.start_byte(id) }
      end
    end
  end
  return held
end

-- The error_held names under `nodes` that an expression there also uses
-- outside any ERROR node: an annotation macro is not used as a value,
-- though tree-sitter-c may read it as a type elsewhere. Each is
-- { name, byte }.
local function misparsed_names(nodes, src)
  local held = error_held(nodes, src)
  if #held == 0 then
    return held
  end
  local used = {}
  for _, node in ipairs(nodes) do
    for _, id in ipairs(csrc.query_nodes(node, src, "(identifier) @i")) do
      if id:parent():type() ~= "ERROR" then
        used[csrc.text(id, src)] = true
      end
    end
  end
  local out = {}
  for _, h in ipairs(held) do
    if used[h[1]] then
      out[#out + 1] = h
    end
  end
  return out
end

local function holds_function_head(n)
  if n:type() == "function_definition" then
    return true
  end
  for _, child in ipairs(csrc.code_children(n)) do
    if child:type() == "function_declarator" then
      return true
    end
  end
  return false
end

-- The top-level nodes that hold the caller's function when tree-sitter gave
-- it no function_definition around the call: an #ifdef straddling braces
-- can turn the whole function into an ERROR node, or close it early so that
-- the call lands in a later top-level node. Then the nodes from the one with
-- the function's head through the one with the call.
local function function_remnants(call)
  local top = call
  while top:parent() and top:parent():parent() do
    top = top:parent() --[[@as TSNode]]
  end
  local nodes = { top }
  local n = top
  while not holds_function_head(n) do
    n = n:prev_named_sibling()
    if not n then
      return { top }
    end
    nodes[#nodes + 1] = n
  end
  return nodes
end

-- The names in the caller's function (see caller_names).
---@class inline_explorer.CallerNames
---@field spelled table<string, true> every identifier and type name in it: a callee name among them is renamed
---@field declared table<string, true> the names it declares: the callee must not use one it does not declare

-- The names of the caller's function. A spelled name the callee also
-- declares is renamed: extra names only cost a rename, but a missed one is
-- wrong code, such as the binding `int x = (x);`, which reads the new,
-- uninitialised x, or a hoisted local hiding the global the rest of the
-- caller reads. Without a function_definition around the call, the spelled
-- names are those of the whole file, and the declared ones those of
-- function_remnants.
---@param call TSNode
---@param src string
---@return inline_explorer.CallerNames
function M.caller_names(call, src)
  local fn = call:parent()
  while fn and fn:type() ~= "function_definition" do
    fn = fn:parent()
  end
  local declaring = fn and { fn } or function_remnants(call)
  local declared = {}
  for _, node in ipairs(declaring) do
    for _, d in ipairs(csrc.query_nodes(node, src, DECLARATIONS)) do
      local nm = csrc.decl_name(d, src)
      if nm then
        declared[nm] = true
      end
    end
  end
  for _, h in ipairs(misparsed_names(declaring, src)) do
    declared[h[1]] = true
  end
  -- Tags too, unlike ordinary_names: that costs a rename at most, and the
  -- whole-file case is slow enough.
  local spelled = {}
  for _, id in ipairs(csrc.query_nodes(fn or call:tree():root(), src, NAMES)) do
    spelled[csrc.text(id, src)] = true
  end
  return { spelled = spelled, declared = declared }
end

-- Where the name declared by `d` is visible: the nearest block or for
-- statement around it, or the prototype that lists it as a parameter. The
-- callee's own parameters are visible in the whole definition.
local function decl_scope(d, def, own_params)
  local n = d:parent()
  while n and n ~= def do
    local t = n:type()
    if t == "parameter_list" then
      return n == own_params and def or n
    end
    if t == "compound_statement" or t == "for_statement" then
      return n
    end
    n = n:parent()
  end
  return def
end

-- name -> the places it is declared in `def`: its scope, and the byte its
-- declarator starts at.
local function callee_declarations(def, fn_declarator, src)
  local own_params = fn_declarator:field("parameters")[1]
  local decls = {}
  for _, d in ipairs(csrc.query_nodes(def, src, DECLARATIONS)) do
    local nm = csrc.decl_name(d, src)
    if nm then
      decls[nm] = decls[nm] or {}
      table.insert(decls[nm], { scope = decl_scope(d, def, own_params), from = csrc.start_byte(d) })
    end
  end
  return decls
end

local function is_bound(id, decls)
  local at = csrc.start_byte(id)
  for _, d in ipairs(decls or {}) do
    if d.from <= at and csrc.start_byte(d.scope) <= at and at < csrc.end_byte(d.scope) then
      return true
    end
  end
  return false
end

-- The names `def` uses without declaring them first in a scope around the
-- use, in document order: globals, functions, macros and typedefs from
-- elsewhere. The function's own name is left out.
local function free_names(def, fn_declarator, src)
  local decls = callee_declarations(def, fn_declarator, src)
  local own_name = csrc.decl_identifier(fn_declarator:field("declarator")[1])
  local free, seen = {}, {}
  for _, id in ipairs(ordinary_names(def, src)) do
    local nm = csrc.text(id, src)
    if not seen[nm] and id ~= own_name and not is_bound(id, decls[nm]) then
      seen[nm] = true
      free[#free + 1] = nm
    end
  end
  return free
end

-- The top-level statements that declare names; `enum { A, B };` is a bare
-- enum_specifier.
local TOP_LEVEL_DECLARING = { declaration = true, type_definition = true, enum_specifier = true }

local PREPROC_BLOCKS = {
  preproc_if = true,
  preproc_ifdef = true,
  preproc_elif = true,
  preproc_elifdef = true,
  preproc_else = true,
}

-- `stmts` with the statements of every #if, #ifdef, #elif and #else block
-- among them in place of the block: those share the top-level scope.
local function flatten_preproc(stmts, out)
  for _, s in ipairs(stmts) do
    if PREPROC_BLOCKS[s:type()] then
      flatten_preproc(csrc.code_children(s), out)
    else
      out[#out + 1] = s
    end
  end
  return out
end

-- Builds ir.rename. Only parameters and top-level locals count, those in
-- #if blocks included: those are the names a hoist declares in the caller's
-- block.
local function plan_renames(params, stmts, body, callee_src, spelled, N)
  local rename = {}
  local function maybe_rename(nm)
    if nm and spelled[nm] then
      rename[nm] = INJECTED.renamed(nm, N)
    end
  end
  for _, p in ipairs(params) do
    maybe_rename(p.name)
  end
  local misparsed = misparsed_names({ body }, callee_src)
  for _, s in ipairs(flatten_preproc(stmts, {})) do
    if TOP_LEVEL_DECLARING[s:type()] then
      for _, d in ipairs(csrc.query_nodes(s, callee_src, LOCAL_DECLARATIONS)) do
        maybe_rename(csrc.decl_name(d, callee_src))
      end
      for _, h in ipairs(misparsed) do
        if h[2] >= csrc.start_byte(s) and h[2] < csrc.end_byte(s) then
          maybe_rename(h[1])
        end
      end
    end
  end
  return rename
end

-- Edits on callee_src that suffix the body's labels and apply `rename`. None
-- overlaps cprint's edits of `return` keywords and semicolons.
local function plan_body_edits(body, callee_src, rename, N)
  local edits = {}
  -- Labels have function scope, so the callee's could clash with the caller's
  -- own labels or with another expansion's.
  local function suffix_label(n)
    edits[#edits + 1] = { csrc.start_byte(n), csrc.end_byte(n), INJECTED.renamed(csrc.text(n, callee_src), N) }
  end
  for _, n in ipairs(csrc.query_nodes(body, callee_src, "(labeled_statement label: (statement_identifier) @l)")) do
    suffix_label(n)
  end
  for _, n in ipairs(csrc.query_nodes(body, callee_src, "(goto_statement label: (statement_identifier) @g)")) do
    suffix_label(n)
  end
  if next(rename) then
    -- Every occurrence, `name(...)` and a typedef's uses included: in the
    -- callee's body the keys mean its own declarations. Not so a use ahead of
    -- a top-level local's declaration that means an outer name: renamed too,
    -- it refers to nothing.
    for _, id in ipairs(ordinary_names(body, callee_src)) do
      local r = rename[csrc.text(id, callee_src)]
      if r then
        edits[#edits + 1] = { csrc.start_byte(id), csrc.end_byte(id), r }
      end
    end
  end
  return edits
end

-- Error recovery can leave a `return` outside any return_statement, as the
-- declared name in `out: __maybe_unused return 0;`: pasted as it is, it
-- would return from the caller.
local function has_stray_return(body, src)
  local query = '([(identifier) (type_identifier)] @r (#eq? @r "return")) ("return" @k)'
  for _, n in ipairs(csrc.query_nodes(body, src, query)) do
    local parent = n:parent()
    if n:named() or not parent or parent:type() ~= "return_statement" then
      return true
    end
  end
  return false
end

---@class inline_explorer.IR
---@field src string callee_src, which the nodes and byte offsets below refer to
---@field params inline_explorer.Param[]
---@field rename table<string, string> parameter or top-level local, #if blocks included, in caller.spelled -> name__ieN
---@field stmts TSNode[] the body's top-level named nodes, comments and preprocessor blocks included
---@field returns TSNode[] every return_statement in the body
---@field body_edits inline_explorer.Edit[] the label suffixes and renames on src (see plan_body_edits)
---@field fn_def TSNode the callee's function_definition in src
---@field has_value boolean whether the first return carries a value (false when there is none)
---@field simple boolean exactly one return, carrying a value and last of stmts: a trailing comment makes it false
---@field ret_var string __ie_retN, which holds the result
---@field end_label string __ie_endN, which the returns jump to
---@field args string[]? each parameter's argument text, set by analyze_call_node after the arity check
---@field param_rename table<string, string>? the parameters' renames: only parameters are in scope in their types
---@field bind_names string[]? each parameter's declared name: its new name, its own, or one made up for it

---@param callee_src string
---@param fname string
---@param N integer
---@param caller inline_explorer.CallerNames
---@return inline_explorer.IR? ir without binds
---@return string? err
function M.analyze_callee(callee_src, fname, N, caller)
  local fn_def, fn_declarator = csrc.find_function_def(csrc.parse(callee_src), callee_src, fname)
  if not fn_def then
    return nil, "definition of '" .. fname .. "' not found"
  end
  ---@cast fn_declarator -nil
  local params, variadic = csrc.get_params(fn_declarator, callee_src)
  if variadic then
    return nil, "cannot inline variadic function '" .. fname .. "'"
  end
  -- What it declares is out of sight: no name in it can be checked or renamed.
  if #csrc.query_nodes(fn_def, callee_src, "(preproc_include) @i") > 0 then
    return nil, fname .. " has an #include in its body"
  end
  local body = fn_def:field("body")[1]
  if has_stray_return(body, callee_src) then
    return nil, "a `return` in " .. fname .. " does not parse as a return statement"
  end
  -- Pasted into the caller, such a use would mean the caller's declaration.
  for _, nm in ipairs(free_names(fn_def, fn_declarator, callee_src)) do
    if caller.declared[nm] then
      return nil, ("'%s' in %s would mean the caller's own '%s'"):format(nm, fname, nm)
    end
  end

  local stmts = {}
  for i = 0, body:named_child_count() - 1 do
    stmts[#stmts + 1] = body:named_child(i)
  end
  if #stmts == 0 then
    return nil, "empty function body"
  end
  local returns = csrc.query_nodes(body, callee_src, "(return_statement) @r")

  local rename = plan_renames(params, stmts, body, callee_src, caller.spelled, N)
  local body_edits = plan_body_edits(body, callee_src, rename, N)

  local last = stmts[#stmts]
  return {
    src = callee_src,
    params = params,
    rename = rename,
    stmts = stmts,
    returns = returns,
    body_edits = body_edits,
    fn_def = fn_def,
    has_value = returns[1] ~= nil and #csrc.code_children(returns[1]) > 0,
    simple = #returns == 1 and last:type() == "return_statement" and #csrc.code_children(last) > 0,
    ret_var = INJECTED.ret_var(N),
    end_label = INJECTED.end_label(N),
  }
end

-- The innermost statement or declaration that holds the call, else the call.
-- A for header's clause, such as the declaration in `for (int i = f(x); ...)`,
-- does not count: the climb goes on to the for_statement. Its body does count.
local function enclosing_statement(call)
  local n = call
  while n do
    local node_type = n:type()
    if node_type:match("_statement$") or node_type == "declaration" then
      local parent = n:parent()
      if parent and parent:type() == "for_statement" and parent:field("body")[1] ~= n then
        n = parent
      else
        return n
      end
    else
      n = n:parent()
    end
  end
  return call
end

local function short_circuits(n, src)
  for i = 0, n:child_count() - 1 do
    local ch = n:child(i)
    if not ch:named() and (csrc.text(ch, src) == "&&" or csrc.text(ch, src) == "||") then
      return true
    end
  end
  return false
end

-- Operands that may run never, or only after another part of the node.
local GUARDING_TYPES = {
  conditional_expression = true,
  comma_expression = true,
  sizeof_expression = true,
  alignof_expression = true,
  offsetof_expression = true,
  generic_expression = true,
  macro_type_specifier = true, -- `typeof(f(x)) v;`
}

-- Calls that do not evaluate their arguments (__builtin_choose_expr: all but
-- the chosen one), checked with gcc, and typeof, which tree-sitter-c reads as
-- a call in `__typeof__(f(x) + 1) *p;`.
local UNEVALUATED_CALLS = {
  __builtin_constant_p = true,
  __builtin_choose_expr = true,
  __builtin_types_compatible_p = true,
  __builtin_object_size = true,
  __builtin_dynamic_object_size = true,
  __builtin_classify_type = true,
  __builtin_has_attribute = true,
  typeof = true,
  __typeof = true,
  __typeof__ = true,
  typeof_unqual = true,
  __typeof_unqual = true,
  __typeof_unqual__ = true,
}

-- Whether `n`, an ancestor of the call within target, keeps the code under
-- `child` (its child on the way to the call) from running exactly once, or
-- runs other code first.
local function guards(n, child, caller_src)
  local node_type = n:type()
  if GUARDING_TYPES[node_type] then
    return true
  end
  if node_type == "binary_expression" then
    return short_circuits(n, caller_src)
  end
  if node_type == "call_expression" and child ~= n:field("function")[1] then
    local fn = n:field("function")[1]
    return fn:type() == "identifier" and UNEVALUATED_CALLS[csrc.text(fn, caller_src)] == true
  end
  -- A later declarator runs after the earlier ones, and may read them.
  return node_type == "declaration" and child ~= n:field("declarator")[1]
end

-- Whether the call surely runs, once, whenever target does, with nothing in
-- target due to run before it: only then may it be hoisted. Only a return,
-- expression statement or declaration qualifies: a loop header may run the
-- call any number of times, and if and switch headers are excluded as well.
-- Within target, see guards: a call under ?:, && or || does not qualify even
-- in the operand that always runs.
local function is_unconditional(call, target, caller_src)
  local target_type = target:type()
  if target_type ~= "return_statement" and target_type ~= "expression_statement" and target_type ~= "declaration" then
    return false
  end
  local child = call
  while child ~= target do
    local n = child:parent()
    if not n or guards(n, child, caller_src) then
      return false
    end
    child = n
  end
  return true
end

---@class inline_explorer.Ctx
---@field call TSNode the call_expression
---@field target TSNode the statement or declaration that holds the call (see enclosing_statement)
---@field can_insert_above boolean lines can go directly above target; if not, a hoist wraps target in a new block
---@field wrap_unsafe boolean target is a declaration that lines cannot go above, so it must not be wrapped (see decide)
---@field parse_error boolean target does not parse cleanly, so what lines above or around it would do is unknown
---@field unconditional boolean hoisting the call above target keeps its meaning (see is_unconditional)
---@field stmt_bol integer the byte offset of the start of target's line
---@field indent string the leading spaces and tabs of that line

---@param caller_src string
---@param call TSNode
---@return inline_explorer.Ctx
function M.analyze_context(caller_src, call)
  local target = enclosing_statement(call)
  local target_type = target:type()
  local unconditional = is_unconditional(call, target, caller_src)
  local stmt_bol = csrc.line_start_byte(target)
  local prefix = caller_src:sub(stmt_bol + 1, csrc.start_byte(target))
  -- Only spaces and tabs: anything else before target on its line (`hits++;`,
  -- `case 1:`, `else`) is code, which must not be copied onto every hoisted line.
  local indent = prefix:match("^[ \t]*")
  -- Lines go directly above target only if it starts its line, or they would
  -- run before the code ahead of it there. Target must also sit directly in a
  -- {} block: above an unbraced body the first line would become that body,
  -- and before C23 a declaration cannot directly follow a label.
  local starts_line = prefix:match("^[ \t]*$") ~= nil
  local parent_type = target:parent() and target:parent():type()
  local can_insert_above = starts_line and parent_type == "compound_statement"
  return {
    call = call,
    target = target,
    can_insert_above = can_insert_above,
    wrap_unsafe = target_type == "declaration" and not can_insert_above,
    parse_error = target:has_error(),
    unconditional = unconditional,
    stmt_bol = stmt_bol,
    indent = indent,
  }
end

-- The name of the printer to use. A declaration that cannot be wrapped
-- (ctx.wrap_unsafe) and a target that does not parse cleanly
-- (ctx.parse_error) get "canonical" in both modes. Otherwise correct mode
-- picks "pretty" for a simple callee whose call is unconditional, else
-- "canonical", which is valid in any expression context; readable mode avoids
-- ({...}) and goto: "pretty" for any simple callee, else "readable_multi".
--
-- The second value says where the hoisting forms, "pretty" and
-- "readable_multi", put their lines: "above" target, or "wrap", in a new
-- block that holds them and then target (see M.placement).
---@param ir inline_explorer.IR
---@param ctx inline_explorer.Ctx
---@param mode "correct"|"readable"
---@return "pretty"|"canonical"|"readable_multi" printer
---@return "above"|"wrap" placement
function M.decide(ir, ctx, mode)
  local placement = M.placement(ctx)
  -- Wrapping a declaration in a block would end its scope early: later code
  -- would see whatever it shadowed. Canonical leaves it in place. So it does
  -- with a misparsed target, such as `WHEN(c) x = f(a);` where WHEN expands
  -- to an `if`: hoisted, f would run whatever c is.
  if ctx.wrap_unsafe or ctx.parse_error then
    return "canonical", placement
  end
  if ir.simple and (mode == "readable" or ctx.unconditional) then
    return "pretty", placement
  end
  if mode == "readable" then
    return "readable_multi", placement
  end
  return "canonical", placement
end

-- Where hoisted lines go: directly "above" target where they can, else
-- "wrap": a new block replaces target, holding them and then target.
---@param ctx inline_explorer.Ctx
---@return "above"|"wrap"
function M.placement(ctx)
  return ctx.can_insert_above and "above" or "wrap"
end

-- Analyses `call`, a call to fname in caller_src, with callee_src as
-- fname's definition: the callee's IR with the arguments bound, and the call
-- site's ctx.
---@param caller_src string
---@param callee_src string
---@param fname string
---@param N integer
---@param call TSNode
---@return inline_explorer.IR? ir with binds
---@return inline_explorer.Ctx? ctx nil when ir is
---@return string? err
function M.analyze_call_node(caller_src, callee_src, fname, N, call)
  -- Its arguments cannot be told apart: in `f(a, 2 ADD)` the 2 is in an
  -- ERROR node.
  if call:has_error() then
    return nil, nil, "the call to " .. fname .. " does not parse cleanly"
  end
  local ir, err = M.analyze_callee(callee_src, fname, N, M.caller_names(call, caller_src))
  if not ir then
    return nil, nil, err
  end

  local args = {}
  for _, arg in ipairs(csrc.code_children(call:field("arguments")[1])) do
    args[#args + 1] = csrc.text(arg, caller_src)
  end
  if #args ~= #ir.params then
    return nil, nil, string.format("arity mismatch (%d args, %d params)", #args, #ir.params)
  end
  -- Only the parameters are in scope in a parameter's declaration.
  local param_rename = {}
  for _, p in ipairs(ir.params) do
    if p.name then
      param_rename[p.name] = ir.rename[p.name]
    end
  end
  local bind_names = {}
  for i, p in ipairs(ir.params) do
    bind_names[i] = p.name and (param_rename[p.name] or p.name) or INJECTED.arg(i, N)
  end
  ir.args, ir.param_rename, ir.bind_names = args, param_rename, bind_names

  return ir, M.analyze_context(caller_src, call)
end

return M
