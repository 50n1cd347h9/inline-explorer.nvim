-- Analysis layer: resolves the callee into a small IR, the call site into
-- a ctx, and decide() picks a printer -- the single judgement point of the
-- whole engine. Layout is left entirely to inline-explorer.cprint.
local C = require("inline-explorer.csrc")

local M = {}

-- Declarator identifier names visible where the call sits.
--
-- Normally that is the caller's enclosing function. When tree-sitter cannot
-- build one -- a preprocessor conditional straddling braces turns the region
-- into an ERROR node, which is ordinary kernel style -- there is no
-- function_definition ancestor to scope by. Returning nothing there would
-- switch collision renaming off silently, and a callee parameter sharing a
-- name with a caller variable would be emitted as `T name = (name);`, whose
-- initialiser C resolves to the new, uninitialised local. So fall back to the
-- whole translation unit: this narrows that common silent defect at the cost
-- of renaming more aggressively than strictly necessary. That trade is only
-- safe because the rename pass below is total over the callee body -- every
-- occurrence of a renamed name, call position included, is renamed with it,
-- so a name the callee declares consistently means the callee's own
-- declaration everywhere it appears, never a stale reference to whatever it
-- shadowed.
function M.enclosing_scope(call, src)
  local scope = call
  while scope and scope:type() ~= "function_definition" do
    local parent = scope:parent()
    if not parent then
      break -- no enclosing function: `scope` is now the root, use it
    end
    scope = parent
  end
  local set = {}
  -- One combined query, one walk. Three separate iter_captures passes over
  -- the same scope measured 71.3ms against 26.9ms combined (p50/11, 20k-line
  -- file, whole-TU fallback scope) -- 2.65x for a semantically identical
  -- match set, since tree-sitter matches all of a query's patterns in a
  -- single traversal. The declaration pattern still covers array/pointer
  -- declarators, not just plain identifiers.
  local q = [[
    (parameter_declaration declarator: (_) @d)
    (init_declarator declarator: (_) @d)
    (declaration declarator: (_) @d)
  ]]
  for _, d in ipairs(C.query_nodes(scope, src, q)) do
    local nm = C.decl_name(d, src)
    if nm then
      set[nm] = true
    end
  end
  return set
end

-- Innermost enclosing statement (or declaration) that contains the call.
-- A `for`-loop's initializer/condition/update clauses are grammatically a
-- `declaration`/expression directly parented by `for_statement`, not a
-- standalone statement in a statement list -- if the climb lands on one of
-- those, keep climbing to the `for_statement` itself so it is treated as a
-- loop header (see analyze_context's `unconditional`), not as an ordinary
-- statement to hoist above. The for's unbraced `body` child IS a legitimate
-- statement target and must still be returned as-is.
local function enclosing_statement(call)
  local n = call
  while n do
    local t = n:type()
    if t:match("_statement$") or t == "declaration" then
      local parent = n:parent()
      if parent and parent:type() == "for_statement" and parent:field("body")[1] ~= n then
        n = parent -- for-header clause: keep climbing, re-check the for_statement itself
      else
        return n
      end
    else
      n = n:parent()
    end
  end
  return call
end

-- ---------------------------------------------------------------------------
-- Analysis: resolve the callee into a small IR and the call site into a ctx,
-- so that a single decision point picks one of three "dumb" printers. The
-- printers do layout only; every judgement lives in analyze_* / decide.
-- ---------------------------------------------------------------------------

-- Names hoisted into the caller scope -- the callee's parameters and its
-- top-level body locals -- that would collide with a name the caller
-- already has in `scope`, each mapped to name__ieN.
local function plan_renames(params, stmts, callee_src, scope, N)
  local rename = {}
  local function maybe_rename(nm)
    if nm and scope[nm] then
      rename[nm] = nm .. "__ie" .. N
    end
  end
  for _, p in ipairs(params) do
    maybe_rename(p.name)
  end
  for _, s in ipairs(stmts) do
    if s:type() == "declaration" then
      -- Every declarator shape, as enclosing_scope collects them: an
      -- uninitialized `int *p;` or `int a[2];` sits directly under the
      -- declaration as a pointer/array declarator, and missing it left the
      -- name unrenamed -- a redeclaration when the caller had it in scope.
      for _, d in ipairs(C.query_nodes(s, callee_src, "(declaration declarator: (_) @d)")) do
        maybe_rename(C.decl_name(d, callee_src))
      end
    end
  end
  return rename
end

-- Body edits on callee_src (absolute bytes): label suffixing + collision
-- renames. Disjoint from the return edits the printers make.
local function plan_body_edits(body, callee_src, rename, N)
  local edits = {}
  local function suffix_label(n)
    edits[#edits + 1] = { C.sb(n), C.eb(n), C.text(n, callee_src) .. "__ie" .. N }
  end
  for _, n in ipairs(C.query_nodes(body, callee_src, "(labeled_statement label: (statement_identifier) @l)")) do
    suffix_label(n)
  end
  for _, n in ipairs(C.query_nodes(body, callee_src, "(goto_statement label: (statement_identifier) @g)")) do
    suffix_label(n)
  end
  if next(rename) then
    for _, id in ipairs(C.query_nodes(body, callee_src, "(identifier) @i")) do
      local r = rename[C.text(id, callee_src)]
      -- rename's keys are names the callee itself declares (its params and
      -- top-level body locals), so a renamed name shadows any same-named
      -- caller-scope function -- every occurrence in the body, including
      -- `name(...)` in call position, refers to the callee's own
      -- declaration and must be renamed along with it.
      if r then
        edits[#edits + 1] = { C.sb(id), C.eb(id), r }
      end
    end
  end
  return edits
end

-- IR: everything the printers need to know about the callee.
--   params/rename   parameter list and planned collision renames (name__ieN)
--   stmts/returns   body statement nodes and return_statement nodes
--   body_edits      label-suffix + rename edits on callee_src (absolute bytes)
--   ret_type        reconstructed declared return type text
--   has_value       whether returns carry an expression
--   simple          straight-line body with a single trailing return
--   ret_var/end_label  injected names, unique per expansion id N
--   binds           bound-parameter lines, populated by inline_call after the
--                   arity check (nil in _probe results)
function M.analyze_callee(callee_src, fname, N, scope)
  local fdef, fd = C.find_function_def(C.parse(callee_src), callee_src, fname)
  if not fdef then
    return nil, "definition of '" .. fname .. "' not found"
  end
  local params, variadic = C.get_params(fd, callee_src)
  if variadic then
    return nil, "cannot inline variadic function '" .. fname .. "'"
  end

  local body = fdef:field("body")[1]
  local stmts = {}
  for i = 0, body:named_child_count() - 1 do
    stmts[#stmts + 1] = body:named_child(i)
  end
  if #stmts == 0 then
    return nil, "empty function body"
  end
  local returns = C.query_nodes(body, callee_src, "(return_statement) @r")

  local rename = plan_renames(params, stmts, callee_src, scope, N)
  local body_edits = plan_body_edits(body, callee_src, rename, N)

  local last = stmts[#stmts]
  return {
    src = callee_src,
    params = params,
    rename = rename,
    stmts = stmts,
    returns = returns,
    body_edits = body_edits,
    ret_type = C.return_type(fdef, callee_src),
    has_value = returns[1] ~= nil and returns[1]:named_child_count() > 0,
    simple = #returns == 1 and last:type() == "return_statement" and last:named_child_count() > 0,
    ret_var = "__ie_ret" .. N,
    end_label = "__ie_end" .. N,
  }
end

-- Whether binary expression `n` is a `&&` or `||`: its right operand runs
-- only sometimes.
local function short_circuits(n, src)
  for i = 0, n:child_count() - 1 do
    local ch = n:child(i)
    if not ch:named() and (C.text(ch, src) == "&&" or C.text(ch, src) == "||") then
      return true
    end
  end
  return false
end

-- Whether the call runs whenever its statement `target` does: `target` is
-- a plain statement (not a loop or if header), and no ?: arm or &&/||
-- lies between the call and it.
local function is_unconditional(call, target, caller_src)
  local t = target:type()
  if t ~= "return_statement" and t ~= "expression_statement" and t ~= "declaration" then
    return false
  end
  local n = call
  while n and n ~= target do
    local ty = n:type()
    if ty == "conditional_expression" then
      return false
    end
    if ty == "binary_expression" and short_circuits(n, caller_src) then
      return false
    end
    n = n:parent()
  end
  return true
end

-- ctx: everything the printers need to know about the call site.
--   braced          lines may be inserted directly above the enclosing
--                   statement: it sits directly inside a {} block AND starts
--                   its own line. If not, hoisting printers wrap the statement
--                   in a block instead -- a declaration cannot follow an
--                   unbraced if body, and after a bare label (goto or case) a
--                   declaration is a constraint violation gcc accepts by
--                   default and diagnoses only under -Wpedantic; a statement
--                   sharing its line has nothing to insert above but its
--                   neighbour's line.
--   wrap_unsafe     wrapping would change meaning, so no hoisting printer may
--                   run at all: the target is a declaration that cannot be
--                   hoisted above, either because it does not start its own
--                   line or because its parent is not a compound_statement
--                   (it follows a bare label instead), and a declaration's
--                   scope is the block it sits in, so enclosing it in one
--                   hides the declared name from the rest of the block (see
--                   decide).
--   unconditional   the call is reached unconditionally in a plain statement
--                   (not in a loop/if header, ?: arm, or after &&/||)
--   stmt_bol/indent/unit  layout facts; the source's tabs/spaces are preserved
function M.analyze_context(caller_src, call)
  local target = enclosing_statement(call)
  local t = target:type()
  local unconditional = is_unconditional(call, target, caller_src)
  local stmt_bol = C.bol(target)
  local prefix = caller_src:sub(stmt_bol + 1, C.sb(target))
  -- Indentation is the leading space/tab run (form feed and vertical tab are C
  -- whitespace too, but are not treated as indentation here). Anything else on
  -- the line before the statement -- `hits++; f(x);`, `case 1: f(x);`,
  -- `else f(x);` -- is code, and `indent` taking only space and tab is what
  -- stops it being copied onto every hoisted line. That copy was a real defect
  -- for `hits++; f(x);`, where it compiled and re-ran the increment once per
  -- hoisted line; for the label and `else` shapes the parent is a
  -- case_statement / if_statement, so `braced` was already false and the
  -- wrapping printer handled them.
  --
  -- `starts_line` is the separate half, and it only bites when the parent IS a
  -- compound_statement: a statement sharing its line has no line of its own to
  -- insert above, and inserting at the line's start would put the hoisted
  -- setup BEFORE the neighbouring statement -- reading an argument the
  -- neighbour goes on to mutate. So it is not a hoist target: treat it like an
  -- unbraced body and let the wrapping printer replace it in place.
  local starts_line = prefix:match("^[ \t]*$") ~= nil
  local indent = prefix:match("^[ \t]*")
  local parent_t = target:parent() and target:parent():type()
  local braced = starts_line and parent_t == "compound_statement"
  return {
    call = call,
    target = target,
    braced = braced,
    wrap_unsafe = t == "declaration" and not braced,
    unconditional = unconditional,
    stmt_bol = stmt_bol,
    indent = indent,
    unit = indent:find("\t") and "\t" or "    ",
  }
end

-- The single decision point: which printer renders this expansion.
--   pretty          simple callee, and hoisting is provably safe (or the user
--                   asked for readable output, which tolerates the risk)
--   readable_multi  readable mode for everything else: no ({...})/goto, may
--                   not preserve semantics (documented trade-off)
--   canonical       the always-correct GNU statement expression + goto form
function M.decide(ir, ctx, mode)
  -- Both hoisting printers fall back to wrapping the target in a block when it
  -- is not `braced`, and that is scope-neutral for a statement but not for a
  -- declaration: the declared name would become local to the new block and the
  -- rest of the enclosing block would see whatever it shadowed instead --
  -- compiling silently, running differently. The canonical printer splices
  -- `({ ... })` where the call was and never moves the declaration, so it is
  -- the only safe rendering -- and canonical form is not just `({...})`: it
  -- always rewrites every `return` via `goto __ie_endN;` / `__ie_endN:;` to
  -- reach the result, regardless of how many returns the callee has. This
  -- holds in readable mode too: readable's contract is that it never emits
  -- `({...})` OR `goto`, and this is its one exception, suspending the whole
  -- no-statement-expression-and-no-goto guarantee for this one case, because
  -- the alternative is wrong rather than merely ugly.
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

-- Full analysis for one call: locate the occurrence, build the IR (including
-- binds, so arity is checked here) and the ctx. Shared by inline_call and the
-- _render test hook so the two can never drift apart.
function M.analyze_call(caller_src, callee_src, fname, N, occ)
  -- find_calls stops at the occ-th match instead of materializing every
  -- call in the file: occ=1 (the default) paid the whole-file walk --
  -- 28.9ms of analyze_call's 28.2ms p50 on a 22k-line kernel file,
  -- against 0.7ms stopping early.
  local call = C.find_calls(C.parse(caller_src), caller_src, fname, occ)[occ]
  if not call then
    return nil, nil, "call to '" .. fname .. "' not found"
  end
  return M.analyze_call_node(caller_src, callee_src, fname, N, call)
end

-- analyze_call for a call node already located (the cursor's).
function M.analyze_call_node(caller_src, callee_src, fname, N, call)
  local ir, err = M.analyze_callee(callee_src, fname, N, M.enclosing_scope(call, caller_src))
  if not ir then
    return nil, nil, err
  end

  local arglist = call:field("arguments")[1]
  local args = {}
  for i = 0, arglist:named_child_count() - 1 do
    args[#args + 1] = C.text(arglist:named_child(i), caller_src)
  end
  if #args ~= #ir.params then
    return nil, nil, string.format("arity mismatch (%d args, %d params)", #args, #ir.params)
  end
  ir.binds = {}
  for i, p in ipairs(ir.params) do
    ir.binds[i] = C.build_bind(p, args[i], ir.rename, N, i, callee_src)
  end

  return ir, M.analyze_context(caller_src, call)
end

return M
