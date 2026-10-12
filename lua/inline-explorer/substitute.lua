-- C inline substitution: replace a call `f(args)` with the effect of f's body,
-- as a compilable source transform (GNU C).
--
--   * parameters
--       -> one binding `T name = (arg);` each, declared with the parameter's
--          own type (arrays decay to pointers). Other declarators (function
--          pointers, for example) and unnamed parameters use `__auto_type`.
--   * a call that runs whenever its statement does, to a callee whose only
--     return is a final `return E;`
--       -> "pretty" hoist: the bindings and the other statements are lifted
--          above the call's statement, and `(E)` replaces the call.
--   * any other call
--       -> a GNU statement expression `({ ... })` replaces the call.
--          `__ie_retN` is declared with the callee's return type, and each
--          `return E;` becomes `{ __ie_retN = E; goto __ie_endN; }`.
--   * the callee's labels
--       -> renamed `label__ieN`.
--   * the callee's parameters and top-level locals that clash with a name in
--     the caller's scope
--       -> renamed `name__ieN`.
--
-- canalyze.decide has the exact rules for which layout is used, including
-- the readable mode's. The transform works on text and tree-sitter trees
-- only, and is specific to C. `N` is a per-expansion id that keeps injected
-- and renamed names unique.
--
-- csrc: tree-sitter/text helpers. canalyze: builds the callee IR and the
-- call-site ctx; decide() chooses the printer. cprint: renders one of three
-- layouts (pretty, canonical, readable_multi). This module wires them together
-- and exposes the public API and test hooks.
local csrc = require("inline-explorer.csrc")
local canalyze = require("inline-explorer.canalyze")
local cprint = require("inline-explorer.cprint")

local M = {}

-- Render an analysed call with the printer decide() picks. `mode` is
-- "correct" (the default: the output always compiles and behaves like the
-- call) or "readable" (no ({...}) or goto, but no such guarantee; see
-- canalyze.decide). Returns the new caller source.
local function print_call(caller_src, ir, ctx, mode)
  local printer_name = canalyze.decide(ir, ctx, mode or "correct")
  return cprint.PRINTERS[printer_name](caller_src, ir, ctx)
end

-- Inline the occ-th call (1-based, default 1) to `fname` in caller_src.
-- callee_src holds fname's definition, N is the expansion id (default 1), and
-- mode is as for print_call. Returns the new caller source, or nil and a
-- reason.
function M.inline_call(caller_src, callee_src, fname, N, occ, mode)
  local ir, ctx, err = canalyze.analyze_call(caller_src, callee_src, fname, N or 1, occ or 1)
  if not ir then
    return nil, err
  end
  return print_call(caller_src, ir, ctx, mode)
end

-- Test hook: analyse the occ-th call to fname without printing it. Unlike
-- analyze_call it stops before binding the arguments, so there is no arity
-- check and ir.binds stays nil. Returns { ir, ctx, decision }, or nil and a
-- reason.
function M._probe(caller_src, callee_src, fname, occ, mode)
  occ = occ or 1
  -- find_calls returns the matches up to the occ-th one.
  local call = csrc.find_calls(csrc.parse(caller_src), caller_src, fname, occ)[occ]
  if not call then
    return nil, "call to '" .. fname .. "' not found"
  end
  local expansion_id = 1
  local caller_names = canalyze.names_in_scope(call, caller_src)
  local ir, err = canalyze.analyze_callee(callee_src, fname, expansion_id, caller_names)
  if not ir then
    return nil, err
  end
  local ctx = canalyze.analyze_context(caller_src, call)
  return { ir = ir, ctx = ctx, decision = canalyze.decide(ir, ctx, mode or "correct") }
end

-- The property suites test csrc's layout helpers through these hooks.
M._rebase = csrc.reindent
M._common_ws_prefix = csrc.common_ws_prefix

-- Test hook: inline the occ-th call to fname with the printer named
-- printer_name ("pretty", "canonical" or "readable_multi"), bypassing
-- decide(). The suites use it to check that the canonical and the pretty
-- output of one call behave the same. Returns the new caller source, or nil
-- and a reason.
function M._render(caller_src, callee_src, fname, N, occ, printer_name)
  local printer = cprint.PRINTERS[printer_name]
  if not printer then
    return nil, "unknown printer '" .. tostring(printer_name) .. "'"
  end
  local ir, ctx, err = canalyze.analyze_call(caller_src, callee_src, fname, N or 1, occ or 1)
  if not ir then
    return nil, err
  end
  return printer(caller_src, ir, ctx)
end

-- Finds the innermost call at (row, col) and the name it calls. Returns
-- (call_node, callee_name), or (nil, reason) when there is no call there or
-- its target is not a plain function name. `root`, when given, is the tree of
-- caller_src (a buffer's own parse); otherwise caller_src is parsed.
local function named_call_at(caller_src, row, col, root)
  local call = csrc.ancestor_at(root or csrc.parse(caller_src), row, col, "call_expression")
  if not call then
    return nil, "no call under the cursor"
  end
  local fn = call:field("function")[1]
  if not fn or fn:type() ~= "identifier" then
    return nil, "call target is not a plain function name"
  end
  return call, csrc.text(fn, caller_src)
end

-- Returns the name of the function called at (row, col), or nil.
function M.call_name_at(caller_src, row, col, root)
  local call, name_or_reason = named_call_at(caller_src, row, col, root)
  if not call then
    return nil
  end
  return name_or_reason
end

-- Inline the call under the cursor (row and col are 0-based). The call node
-- found here goes straight to analyze_call_node, so the file is not searched
-- for it again. N and mode are as for inline_call, and root as for
-- named_call_at. Returns the new caller source, or nil and a reason.
function M.inline_in_buffer(caller_src, row, col, callee_src, N, mode, root)
  local call, name_or_reason = named_call_at(caller_src, row, col, root)
  if not call then
    return nil, name_or_reason
  end
  local fname = name_or_reason
  local ir, ctx, err = canalyze.analyze_call_node(caller_src, callee_src, fname, N or 1, call)
  if not ir then
    return nil, err
  end
  return print_call(caller_src, ir, ctx, mode)
end

return M
