-- C inline substitution as the specs drive it: by a function's name and
-- the occurrence of its call, rather than by a cursor position as
-- substitute.inline_in_buffer, and through the analysis and printers
-- directly, to test them one at a time. `N`, an id unique to each
-- expansion, suffixes the names the engine injects or renames.
local csrc = require("inline-explorer.csrc")
local canalyze = require("inline-explorer.canalyze")
local cprint = require("inline-explorer.cprint")

local M = {}

-- Inlines the occ-th call to fname in caller_src; callee_src holds fname's
-- definition.
---@param caller_src string
---@param callee_src string
---@param fname string
---@param N? integer default 1
---@param occ? integer default 1
---@param mode? "correct"|"readable" default "correct"
---@return string? new_src
---@return string? err
function M.inline_call(caller_src, callee_src, fname, N, occ, mode)
  local ir, ctx, err = canalyze.analyze_call(caller_src, callee_src, fname, N or 1, occ or 1)
  if not ir then
    return nil, err
  end
  ---@cast ctx -nil
  return cprint.PRINTERS[canalyze.decide(ir, ctx, mode or "correct")](caller_src, ir, ctx)
end

-- The analysis of the occ-th call to fname, without printing it. Unlike
-- analyze_call it binds no arguments: no arity check, and ir.binds is nil.
---@param caller_src string
---@param callee_src string
---@param fname string
---@param occ? integer default 1
---@param mode? "correct"|"readable" default "correct"
---@return { ir: inline_explorer.IR, ctx: inline_explorer.Ctx, decision: string }?
---@return string? err
function M.probe(caller_src, callee_src, fname, occ, mode)
  occ = occ or 1
  local call = csrc.find_calls(csrc.parse(caller_src), caller_src, fname, occ)[occ]
  if not call then
    return nil, "call to '" .. fname .. "' not found"
  end
  local expansion_id = 1
  local ir, err = canalyze.analyze_callee(callee_src, fname, expansion_id, canalyze.caller_names(call, caller_src))
  if not ir then
    return nil, err
  end
  local ctx = canalyze.analyze_context(caller_src, call)
  return { ir = ir, ctx = ctx, decision = canalyze.decide(ir, ctx, mode or "correct") }
end

-- inline_call with the printer named printer_name, not decide()'s.
---@param caller_src string
---@param callee_src string
---@param fname string
---@param N? integer default 1
---@param occ? integer default 1
---@param printer_name string
---@return string? new_src
---@return string? err
function M.render(caller_src, callee_src, fname, N, occ, printer_name)
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

return M
