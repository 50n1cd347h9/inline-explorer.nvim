-- C inline substitution: replace a call `f(args)` with the effect of f's body,
-- as a compilable source transform (GNU C).
--
--   * parameters      -> bindings that reconstruct each parameter's declared
--                        type (arrays decay to pointers, handles pointers/
--                        fn-ptrs); falls back to `__auto_type` for exotic
--                        declarators
--   * single-return    -> "pretty" hoist: setup statements lifted above the call
--     straight-line       statement, the returned expression spliced in place
--   * anything else    -> GNU statement expression `({ ... })` with each
--                        `return E;` rewritten to `{ __ie_retN = E; goto end; }`
--                        and the reconstructed declared return type as
--                        `__ie_retN`'s slot
--   * callee labels    -> suffixed `label__ieN` (labels are function-scoped, so
--                        inlining twice would otherwise collide)
--   * name collisions  -> hoisted locals that clash with the caller scope are
--                        suffixed `name__ieN`
--
-- The transform is pure text/tree-sitter and language-specific to C. `N` is a
-- per-expansion id that keeps injected/renamed names unique.
--
-- Structure: csrc (tree-sitter/text helpers) -> canalyze (analyze_callee -> IR,
-- analyze_context -> ctx, the single decide()) -> cprint (one of three
-- layout-only printers: pretty / canonical statement-expression /
-- readable-multi). This module is the facade: it keeps the public API and
-- test hooks stable while delegating to those three.
local C = require("inline-explorer.csrc")
local A = require("inline-explorer.canalyze")
local P = require("inline-explorer.cprint")

local M = {}

-- Build the transform. Returns (new_caller_src, err).
-- mode: "correct" (default, guaranteed to compile) or "readable" (cleaner
-- output that skips ({...})/goto and may not compile in edge cases).
local function print_call(caller_src, ir, ctx, err, mode)
  if not ir then
    return nil, err
  end
  return P.PRINTERS[A.decide(ir, ctx, mode or "correct")](caller_src, ir, ctx)
end

function M.inline_call(caller_src, callee_src, fname, N, occ, mode)
  local ir, ctx, err = A.analyze_call(caller_src, callee_src, fname, N or 1, occ or 1)
  return print_call(caller_src, ir, ctx, err, mode)
end

-- Test/introspection hook: run the analysis without printing.
function M._probe(caller_src, callee_src, fname, occ, mode)
  local call = C.find_calls(C.parse(caller_src), caller_src, fname, occ or 1)[occ or 1]
  if not call then
    return nil, "call to '" .. fname .. "' not found"
  end
  local ir, err = A.analyze_callee(callee_src, fname, 1, A.enclosing_scope(call, caller_src))
  if not ir then
    return nil, err
  end
  local ctx = A.analyze_context(caller_src, call)
  return { ir = ir, ctx = ctx, decision = A.decide(ir, ctx, mode or "correct") }
end

-- Test hooks for the property suites: the layout helpers, and a renderer that
-- forces a named printer, bypassing decide() -- used to check that canonical
-- and pretty output of the same call are semantically identical.
M._rebase = C.rebase
M._common_ws_prefix = C.common_ws_prefix

function M._render(caller_src, callee_src, fname, N, occ, printer)
  local p = P.PRINTERS[printer]
  if not p then
    return nil, "unknown printer '" .. tostring(printer) .. "'"
  end
  local ir, ctx, err = A.analyze_call(caller_src, callee_src, fname, N or 1, occ or 1)
  if not ir then
    return nil, err
  end
  return p(caller_src, ir, ctx)
end

-- The innermost call at (row, col) and the plain function name it calls;
-- nil and a reason when there is no call or its target is not a name.
-- `root`, when given, is caller_src's tree already (a buffer's own parse);
-- otherwise caller_src is parsed.
local function named_call_at(caller_src, row, col, root)
  local call = C.ancestor_at(root or C.parse(caller_src), row, col, "call_expression")
  if not call then
    return nil, "no call under the cursor"
  end
  local fn = call:field("function")[1]
  if not fn or fn:type() ~= "identifier" then
    return nil, "call target is not a plain function name"
  end
  return call, C.text(fn, caller_src)
end

-- Name of the function called at (row, col), or nil.
function M.call_name_at(caller_src, row, col, root)
  local call, fname = named_call_at(caller_src, row, col, root)
  return call and fname or nil
end

-- Inline the call under the cursor (row, col are 0-indexed). The located
-- call node goes straight to the analysis; numbering it as an occurrence
-- only for analyze_call to walk the file again and find it was a second
-- and third search for a node already in hand.
function M.inline_in_buffer(caller_src, row, col, callee_src, N, mode, root)
  local call, fname = named_call_at(caller_src, row, col, root)
  if not call then
    return nil, fname
  end
  local ir, ctx, err = A.analyze_call_node(caller_src, callee_src, fname, N or 1, call)
  return print_call(caller_src, ir, ctx, err, mode)
end

return M
