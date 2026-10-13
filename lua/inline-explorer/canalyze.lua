-- Analysis: the callee becomes an IR, the call site a ctx, and decide() picks
-- the printer from them. Every judgement is made here.
local csrc = require("inline-explorer.csrc")

local M = {}

-- The names declared in the caller's enclosing function, or in the whole file
-- without one (an #ifdef straddling braces can make it an ERROR node). Extra
-- names only cost a rename (see plan_body_edits); a missed one compiles to
-- wrong code: a binding `int x = (x);` reads the new, uninitialised x.
---@param call TSNode
---@param src string
---@return table<string, true>
function M.names_in_scope(call, src)
  local scope = call
  while scope and scope:type() ~= "function_definition" do
    local parent = scope:parent()
    if not parent then
      break
    end
    scope = parent
  end
  local names = {}
  -- `(_)`, not `(identifier)`: `int *p;` and `int a[2];` put a pointer or
  -- array declarator there, and decl_name digs the name out.
  local q = [[
    (parameter_declaration declarator: (_) @d)
    (init_declarator declarator: (_) @d)
    (declaration declarator: (_) @d)
  ]]
  for _, d in ipairs(csrc.query_nodes(scope, src, q)) do
    local nm = csrc.decl_name(d, src)
    if nm then
      names[nm] = true
    end
  end
  return names
end

-- Builds ir.rename. Only parameters and top-level locals count: those are the
-- names a hoist declares in the caller's block. Locals inside a top-level #if
-- block are hoisted too but not checked yet, so they can collide.
local function plan_renames(params, stmts, callee_src, caller_names, N)
  local rename = {}
  local function maybe_rename(nm)
    if nm and caller_names[nm] then
      rename[nm] = nm .. "__ie" .. N
    end
  end
  for _, p in ipairs(params) do
    maybe_rename(p.name)
  end
  for _, s in ipairs(stmts) do
    if s:type() == "declaration" then
      -- `(_)`: see names_in_scope.
      for _, d in ipairs(csrc.query_nodes(s, callee_src, "(declaration declarator: (_) @d)")) do
        maybe_rename(csrc.decl_name(d, callee_src))
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
    edits[#edits + 1] = { csrc.start_byte(n), csrc.end_byte(n), csrc.text(n, callee_src) .. "__ie" .. N }
  end
  for _, n in ipairs(csrc.query_nodes(body, callee_src, "(labeled_statement label: (statement_identifier) @l)")) do
    suffix_label(n)
  end
  for _, n in ipairs(csrc.query_nodes(body, callee_src, "(goto_statement label: (statement_identifier) @g)")) do
    suffix_label(n)
  end
  if next(rename) then
    -- Every occurrence, `name(...)` included: in the callee's body the keys
    -- mean its own declarations. Not so a use ahead of a top-level local's
    -- declaration that means an outer name: renamed too, it refers to nothing.
    for _, id in ipairs(csrc.query_nodes(body, callee_src, "(identifier) @i")) do
      local r = rename[csrc.text(id, callee_src)]
      if r then
        edits[#edits + 1] = { csrc.start_byte(id), csrc.end_byte(id), r }
      end
    end
  end
  return edits
end

---@class inline_explorer.IR
---@field src string callee_src, which the nodes and byte offsets below refer to
---@field params inline_explorer.Param[]
---@field rename table<string, string> colliding parameter or top-level local -> name__ieN; not yet those in #if blocks
---@field stmts TSNode[] the body's top-level named nodes, comments and preprocessor blocks included
---@field returns TSNode[] every return_statement in the body
---@field body_edits inline_explorer.Edit[] the label suffixes and renames on src (see plan_body_edits)
---@field ret_type string the declared return type, rebuilt as text
---@field has_value boolean whether the first return carries a value (false when there is none)
---@field simple boolean exactly one return, carrying a value and last of stmts: a trailing comment makes it false
---@field ret_var string __ie_retN, which holds the result
---@field end_label string __ie_endN, which the returns jump to
---@field binds string[]? one `T name = (arg);` per parameter, set by analyze_call_node after the arity check

---@param callee_src string
---@param fname string
---@param N integer
---@param caller_names table<string, true> see names_in_scope
---@return inline_explorer.IR? ir without binds
---@return string? err
function M.analyze_callee(callee_src, fname, N, caller_names)
  local fn_def, fn_declarator = csrc.find_function_def(csrc.parse(callee_src), callee_src, fname)
  if not fn_def then
    return nil, "definition of '" .. fname .. "' not found"
  end
  ---@cast fn_declarator -nil
  local params, variadic = csrc.get_params(fn_declarator, callee_src)
  if variadic then
    return nil, "cannot inline variadic function '" .. fname .. "'"
  end

  local body = fn_def:field("body")[1]
  local stmts = {}
  for i = 0, body:named_child_count() - 1 do
    stmts[#stmts + 1] = body:named_child(i)
  end
  if #stmts == 0 then
    return nil, "empty function body"
  end
  local returns = csrc.query_nodes(body, callee_src, "(return_statement) @r")

  local rename = plan_renames(params, stmts, callee_src, caller_names, N)
  local body_edits = plan_body_edits(body, callee_src, rename, N)

  local last = stmts[#stmts]
  return {
    src = callee_src,
    params = params,
    rename = rename,
    stmts = stmts,
    returns = returns,
    body_edits = body_edits,
    ret_type = csrc.return_type(fn_def, callee_src),
    has_value = returns[1] ~= nil and #csrc.code_children(returns[1]) > 0,
    simple = #returns == 1 and last:type() == "return_statement" and #csrc.code_children(last) > 0,
    ret_var = "__ie_ret" .. N,
    end_label = "__ie_end" .. N,
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

-- Whether the call surely runs whenever target does. Only a return, expression
-- statement or declaration qualifies: a loop header may run the call any
-- number of times, and if and switch headers are excluded as well. A call
-- anywhere inside a ?:, && or || does not, even in the operand that always runs.
local function is_unconditional(call, target, caller_src)
  local target_type = target:type()
  if target_type ~= "return_statement" and target_type ~= "expression_statement" and target_type ~= "declaration" then
    return false
  end
  local n = call
  while n and n ~= target do
    local node_type = n:type()
    if node_type == "conditional_expression" then
      return false
    end
    if node_type == "binary_expression" and short_circuits(n, caller_src) then
      return false
    end
    n = n:parent()
  end
  return true
end

---@class inline_explorer.Ctx
---@field call TSNode the call_expression
---@field target TSNode the statement or declaration that holds the call (see enclosing_statement)
---@field can_insert_above boolean lines can go directly above target; if not, a hoist wraps target in a new block
---@field wrap_unsafe boolean target is a declaration that lines cannot go above, so it must not be wrapped (see decide)
---@field unconditional boolean target is a return, expression statement or declaration that surely runs the call
---@field stmt_bol integer the byte offset of the start of target's line
---@field indent string the leading spaces and tabs of that line
---@field indent_unit string one level of indentation

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
    unconditional = unconditional,
    stmt_bol = stmt_bol,
    indent = indent,
    indent_unit = indent:find("\t") and "\t" or "    ",
  }
end

-- The name of the printer to use. A declaration that cannot be wrapped
-- (ctx.wrap_unsafe) gets "canonical" in both modes. Otherwise correct mode
-- picks "pretty" for a simple callee whose call is unconditional, else
-- "canonical", which is valid in any expression context; readable mode avoids
-- ({...}) and goto: "pretty" for any simple callee, else "readable_multi".
---@param ir inline_explorer.IR
---@param ctx inline_explorer.Ctx
---@param mode "correct"|"readable"
---@return "pretty"|"canonical"|"readable_multi"
function M.decide(ir, ctx, mode)
  -- Wrapping a declaration in a block would end its scope early: later code
  -- would see whatever it shadowed. Canonical leaves it in place.
  if ctx.wrap_unsafe then
    return "canonical"
  end
  if ir.simple and (mode == "readable" or ctx.unconditional) then
    return "pretty"
  end
  if mode == "readable" then
    return "readable_multi"
  end
  return "canonical"
end

-- analyze_call_node for the occ-th call to fname in caller_src.
---@param caller_src string
---@param callee_src string
---@param fname string
---@param N integer
---@param occ integer
---@return inline_explorer.IR? ir
---@return inline_explorer.Ctx? ctx
---@return string? err
function M.analyze_call(caller_src, callee_src, fname, N, occ)
  local call = csrc.find_calls(csrc.parse(caller_src), caller_src, fname, occ)[occ]
  if not call then
    return nil, nil, "call to '" .. fname .. "' not found"
  end
  return M.analyze_call_node(caller_src, callee_src, fname, N, call)
end

---@param caller_src string
---@param callee_src string
---@param fname string
---@param N integer
---@param call TSNode
---@return inline_explorer.IR? ir with binds
---@return inline_explorer.Ctx? ctx nil when ir is
---@return string? err
function M.analyze_call_node(caller_src, callee_src, fname, N, call)
  local caller_names = M.names_in_scope(call, caller_src)
  local ir, err = M.analyze_callee(callee_src, fname, N, caller_names)
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
  ir.binds = {}
  for i, p in ipairs(ir.params) do
    ir.binds[i] = csrc.build_bind(p, args[i], ir.rename, N, i, callee_src)
  end

  return ir, M.analyze_context(caller_src, call)
end

return M
