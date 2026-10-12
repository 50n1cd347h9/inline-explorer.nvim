-- C inline substitution: rewrites a call `f(args)` into the effect of f's
-- body, as a GNU C source transform on text and tree-sitter trees. canalyze
-- analyses the call and decides on a layout, cprint prints it, and this module
-- holds the public API and the test hooks. `N`, an id unique to each
-- expansion, suffixes the names it injects or renames. See DESIGN.md.
local csrc = require("inline-explorer.csrc")
local canalyze = require("inline-explorer.canalyze")
local cprint = require("inline-explorer.cprint")

local M = {}

---@param mode? "correct"|"readable" see canalyze.decide
local function print_call(caller_src, ir, ctx, mode)
  local printer_name = canalyze.decide(ir, ctx, mode or "correct")
  return cprint.PRINTERS[printer_name](caller_src, ir, ctx)
end

-- Inlines the occ-th call to fname in caller_src; callee_src holds fname's
-- definition.
---@return string? new_src
---@return string? err
function M.inline_call(caller_src, callee_src, fname, N, occ, mode)
  local ir, ctx, err = canalyze.analyze_call(caller_src, callee_src, fname, N or 1, occ or 1)
  if not ir then
    return nil, err
  end
  return print_call(caller_src, ir, ctx, mode)
end

-- Test hook: analyses the occ-th call to fname without printing it. Unlike
-- analyze_call it binds no arguments: no arity check, and ir.binds is nil.
---@return { ir: inline_explorer.IR, ctx: inline_explorer.Ctx, decision: string }?
---@return string? err
function M._probe(caller_src, callee_src, fname, occ, mode)
  occ = occ or 1
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

-- Test hook: inline_call with the printer named printer_name, not decide()'s.
---@return string? new_src
---@return string? err
function M._render(caller_src, callee_src, fname, N, occ, printer_name)
  local printer = cprint.PRINTERS[printer_name]
  if not printer then
    return nil, "unknown printer '" .. tostring(printer_name) .. "'"
  end
  local ir, ctx, err = canalyze.analyze_call(caller_src, callee_src, fname, N or 1, occ or 1)
  if not ir then
    return nil, err
  end
  ---@cast ctx -nil
  return printer(caller_src, ir, ctx)
end

-- The innermost call at (row, col), 0-based with col in bytes, and the name
-- it calls. `root`, if given, is caller_src's tree.
---@return TSNode? call nil if there is no call there or it calls no plain name
---@return string name_or_reason
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

-- The name of the function called at (row, col), or nil.
function M.call_name_at(caller_src, row, col, root)
  local call, name_or_reason = named_call_at(caller_src, row, col, root)
  if not call then
    return nil
  end
  return name_or_reason
end

-- inline_call for the call at (row, col); see named_call_at.
---@return string? new_src
---@return string? err
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
