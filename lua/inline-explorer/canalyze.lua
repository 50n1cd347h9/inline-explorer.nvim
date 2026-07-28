-- Analysis layer: resolves the callee into a small IR, the call site into
-- a ctx, and decide() picks a printer -- the single judgement point of the
-- whole engine. Layout is left entirely to inline-explorer.cprint.
local C = require("inline-explorer.csrc")

local M = {}

-- Collect declarator identifier names visible in the caller's enclosing function.
function M.enclosing_scope(call, src)
  local fn = call
  while fn and fn:type() ~= "function_definition" do
    fn = fn:parent()
  end
  local set = {}
  if not fn then
    return set
  end
  local qs = {
    "(parameter_declaration declarator: (_) @d)",
    "(init_declarator declarator: (_) @d)",
    "(declaration declarator: (_) @d)", -- covers array/pointer declarators, not just plain identifiers
  }
  for _, q in ipairs(qs) do
    for _, d in ipairs(C.query_nodes(fn, src, q)) do
      local nm = d:type() == "identifier" and C.text(d, src) or C.decl_name(d, src)
      if nm then
        set[nm] = true
      end
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

  -- Names hoisted into the caller scope; rename those that would collide.
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
      for _, d in ipairs(C.query_nodes(s, callee_src, "(init_declarator declarator: (_) @d)")) do
        maybe_rename(C.decl_name(d, callee_src))
      end
      for _, d in ipairs(C.query_nodes(s, callee_src, "(declaration declarator: (identifier) @d)")) do
        maybe_rename(C.text(d, callee_src))
      end
    end
  end

  -- Body edits: label suffixing + collision renames (disjoint from return edits).
  local body_edits = {}
  local function suffix_label(n)
    body_edits[#body_edits + 1] = { C.sb(n), C.eb(n), C.text(n, callee_src) .. "__ie" .. N }
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
      -- Do not rename the callee of a call (function names live in caller scope).
      local parent = id:parent()
      local is_callee = parent and parent:type() == "call_expression" and parent:field("function")[1] == id
      if r and not is_callee then
        body_edits[#body_edits + 1] = { C.sb(id), C.eb(id), r }
      end
    end
  end

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

-- ctx: everything the printers need to know about the call site.
--   braced          the enclosing statement sits directly inside a {} block
--                   (if not, hoisting printers must wrap in a block: a
--                   declaration cannot follow a bare label / unbraced if body)
--   unconditional   the call is reached unconditionally in a plain statement
--                   (not in a loop/if header, ?: arm, or after &&/||)
--   stmt_bol/indent/unit  layout facts; the source's tabs/spaces are preserved
function M.analyze_context(caller_src, call)
  local target = enclosing_statement(call)
  local t = target:type()
  local unconditional = t == "return_statement" or t == "expression_statement" or t == "declaration"
  if unconditional then
    local n = call
    while n and n ~= target do
      local ty = n:type()
      if ty == "conditional_expression" then
        unconditional = false
      elseif ty == "binary_expression" then
        for i = 0, n:child_count() - 1 do
          local ch = n:child(i)
          if not ch:named() and (C.text(ch, caller_src) == "&&" or C.text(ch, caller_src) == "||") then
            unconditional = false
          end
        end
      end
      n = n:parent()
    end
  end
  local stmt_bol = C.sb(target) - C.scol(target)
  local indent = caller_src:sub(stmt_bol + 1, C.sb(target))
  local parent_t = target:parent() and target:parent():type()
  return {
    call = call,
    target = target,
    braced = parent_t == "compound_statement",
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
  local call = C.find_calls(C.parse(caller_src), caller_src, fname)[occ]
  if not call then
    return nil, nil, "call to '" .. fname .. "' not found"
  end

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
