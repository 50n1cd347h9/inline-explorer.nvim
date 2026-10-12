-- Analysis layer: resolves the callee into a small IR and the call site into
-- a ctx, and decide() picks the printer from them. Every judgement the engine
-- makes is here; layout is left entirely to inline-explorer.cprint.
local csrc = require("inline-explorer.csrc")

local M = {}

-- Returns the set of names declared in the caller's enclosing function (its
-- parameters and locals), which the callee's names are checked against for
-- collisions. Without an enclosing function_definition (an #ifdef straddling
-- braces can turn it into an ERROR node), every name declared in the
-- translation unit is collected instead. A missed collision compiles to
-- wrong code, such as a binding `int x = (x);` that reads the new,
-- uninitialised x, while an extra rename is harmless (see plan_body_edits).
function M.names_in_scope(call, src)
  local scope = call
  while scope and scope:type() ~= "function_definition" do
    local parent = scope:parent()
    if not parent then
      break -- no enclosing function: `scope` is now the root, use it
    end
    scope = parent
  end
  local names = {}
  -- One query with three patterns, so `scope` is walked once. The `(_)`
  -- declarator also matches pointer and array declarators, and decl_name
  -- extracts the identifier from them.
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

-- Returns renames for the names hoisted into the caller (the callee's
-- parameters and top-level locals) that collide with caller_names, as
-- name -> name__ieN.
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
      -- Match every declarator shape, as names_in_scope does: `int *p;` and
      -- `int a[2];` put a pointer or array declarator directly under the
      -- declaration.
      for _, d in ipairs(csrc.query_nodes(s, callee_src, "(declaration declarator: (_) @d)")) do
        maybe_rename(csrc.decl_name(d, callee_src))
      end
    end
  end
  return rename
end

-- Returns edits on callee_src, each { start_byte, end_byte, replacement },
-- that suffix the body's labels and apply `rename`. They never overlap the
-- edits cprint makes to `return` keywords and semicolons.
local function plan_body_edits(body, callee_src, rename, N)
  local edits = {}
  -- Labels have function scope, so a second expansion into the same caller
  -- would otherwise define them again.
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
    -- rename's keys are names the callee declares itself, so in its body
    -- every occurrence refers to that declaration and is renamed with it,
    -- `name(...)` in call position included.
    for _, id in ipairs(csrc.query_nodes(body, callee_src, "(identifier) @i")) do
      local r = rename[csrc.text(id, callee_src)]
      if r then
        edits[#edits + 1] = { csrc.start_byte(id), csrc.end_byte(id), r }
      end
    end
  end
  return edits
end

-- Analyse fname's definition in callee_src. caller_names is the set from
-- names_in_scope, and N the expansion id. Returns the IR, or nil and a
-- reason. The IR holds everything the printers need to know about the
-- callee:
--   src         callee_src, which the nodes and byte offsets below refer to
--   params      the parameters, as csrc.get_params returns them
--   rename      collision renames for parameters and top-level locals,
--               name -> name__ieN
--   stmts       the body's top-level statement nodes
--   returns     every return_statement node in the body
--   body_edits  the label-suffix and rename edits on src (see plan_body_edits)
--   ret_type    the declared return type, reconstructed as text
--   has_value   whether the returns carry a value (judged by the first one;
--               false when there is none)
--   simple      exactly one return, which is the last top-level statement
--               and has a value
--   ret_var     the variable that holds the result, __ie_retN
--   end_label   the label the returns jump to, __ie_endN
--   binds       one binding line per parameter, `T name = (arg);`. It is set
--               by analyze_call_node after the arity check, so _probe results
--               have none.
function M.analyze_callee(callee_src, fname, N, caller_names)
  local fn_def, fn_declarator = csrc.find_function_def(csrc.parse(callee_src), callee_src, fname)
  if not fn_def then
    return nil, "definition of '" .. fname .. "' not found"
  end
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
    has_value = returns[1] ~= nil and returns[1]:named_child_count() > 0,
    simple = #returns == 1 and last:type() == "return_statement" and last:named_child_count() > 0,
    ret_var = "__ie_ret" .. N,
    end_label = "__ie_end" .. N,
  }
end

-- Returns the innermost statement or declaration that contains the call, or
-- the call itself when nothing does. The clauses of a for header do not
-- count: in `for (int i = f(x); ...)` the initializer is a `declaration`
-- whose parent is the for_statement, so the climb goes on to the
-- for_statement, a loop header (see is_unconditional). The for's unbraced
-- body is a real statement and is returned as it is.
local function enclosing_statement(call)
  local n = call
  while n do
    local node_type = n:type()
    if node_type:match("_statement$") or node_type == "declaration" then
      local parent = n:parent()
      if parent and parent:type() == "for_statement" and parent:field("body")[1] ~= n then
        n = parent -- a for-header clause: check the for_statement itself next
      else
        return n
      end
    else
      n = n:parent()
    end
  end
  return call
end

-- Returns whether binary expression `n` is a `&&` or `||`, whose right
-- operand runs only sometimes.
local function short_circuits(n, src)
  for i = 0, n:child_count() - 1 do
    local ch = n:child(i)
    if not ch:named() and (csrc.text(ch, src) == "&&" or csrc.text(ch, src) == "||") then
      return true
    end
  end
  return false
end

-- Returns whether the call runs whenever its statement `target` does:
-- `target` is a plain statement (not a loop or if header), and no ?: arm or
-- &&/|| lies between the call and it.
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

-- Analyse the call site. Returns the ctx, which holds everything the printers
-- need to know about it:
--   call              the call_expression node
--   target            the statement or declaration that contains the call
--                     (see enclosing_statement)
--   can_insert_above  hoisted lines can go on new lines directly above the
--                     target. If not, the hoisting printers wrap the target
--                     in a new block instead.
--   wrap_unsafe       the target is a declaration that lines cannot be
--                     inserted above, so it must not be wrapped (see decide)
--   unconditional     the call runs whenever the target does
--                     (see is_unconditional)
--   stmt_bol          the byte offset of the start of the target's line
--   indent            the leading spaces and tabs of that line
--   indent_unit       one level of indentation: a tab if indent has one,
--                     else four spaces
function M.analyze_context(caller_src, call)
  local target = enclosing_statement(call)
  local target_type = target:type()
  local unconditional = is_unconditional(call, target, caller_src)
  local stmt_bol = csrc.line_start_byte(target)
  -- prefix is the text from the start of the target's line up to the target.
  local prefix = caller_src:sub(stmt_bol + 1, csrc.start_byte(target))
  -- Only the leading spaces and tabs are indentation. Anything else before
  -- the target on its line (`hits++;`, `case 1:`, `else`) is code, which must
  -- not be copied onto every hoisted line.
  local indent = prefix:match("^[ \t]*")
  -- Lines can go directly above the target only if it starts its own line;
  -- otherwise they would also land above, and run before, the code ahead of
  -- it on that line. The target must also sit directly in a {} block: lines
  -- inserted above an unbraced if body would become that body, and C does
  -- not allow a declaration directly after a label (gcc only diagnoses it
  -- under -Wpedantic).
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

-- Returns the name of the printer that renders the expansion. In correct
-- mode it is "pretty" for a simple callee (see the IR) whose call runs
-- unconditionally, and "canonical" (a GNU statement expression with goto,
-- valid in any expression context) otherwise. Readable mode avoids ({...})
-- and goto: it picks "pretty" for any simple callee and "readable_multi" for
-- the rest, and its output may not compile or keep the callee's meaning
-- (early returns, labels, short-circuits).
function M.decide(ir, ctx, mode)
  -- A declaration that lines cannot be inserted above would be wrapped in a
  -- new block, which changes its scope: the rest of the enclosing block would
  -- see whatever it shadowed rather than the declaration. Canonical splices
  -- ({...}) in place of the call and leaves the declaration where it is. This
  -- applies in readable mode too: it is the one case where readable output
  -- contains ({...}) and goto, because the alternative is wrong code.
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

-- Full analysis of the occ-th call to fname in caller_src. Returns ir (with
-- binds) and ctx, or nil, nil and a reason. inline_call and the _render test
-- hook share it, so the two cannot drift apart.
function M.analyze_call(caller_src, callee_src, fname, N, occ)
  -- find_calls stops at the occ-th match and returns the matches so far.
  local call = csrc.find_calls(csrc.parse(caller_src), caller_src, fname, occ)[occ]
  if not call then
    return nil, nil, "call to '" .. fname .. "' not found"
  end
  return M.analyze_call_node(caller_src, callee_src, fname, N, call)
end

-- analyze_call for a call node already located (the one under the cursor).
-- It builds the IR, binds the call's arguments to the parameters, and builds
-- the ctx. Returns ir and ctx, or nil, nil and a reason.
function M.analyze_call_node(caller_src, callee_src, fname, N, call)
  local caller_names = M.names_in_scope(call, caller_src)
  local ir, err = M.analyze_callee(callee_src, fname, N, caller_names)
  if not ir then
    return nil, nil, err
  end

  local arglist = call:field("arguments")[1]
  local args = {}
  for i = 0, arglist:named_child_count() - 1 do
    args[#args + 1] = csrc.text(arglist:named_child(i), caller_src)
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
