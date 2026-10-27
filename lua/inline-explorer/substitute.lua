-- C inline substitution: rewrites a call `f(args)` into the effect of f's
-- body, as a GNU C source transform on text and tree-sitter trees. canalyze
-- analyses the call and decides on a layout, cprint prints it, and this module
-- holds the public API. `N`, an id unique to each expansion, suffixes the
-- names it injects or renames. See DESIGN.md. The specs reach the analysis
-- and the printers through tests/lib/inline.lua.
local csrc = require("inline-explorer.csrc")
local canalyze = require("inline-explorer.canalyze")
local cprint = require("inline-explorer.cprint")

local M = {}

-- The caller's text with the analysed call printed in the form, and at the
-- placement, canalyze.decide picks for `mode`.
---@param caller_src string
---@param ir inline_explorer.IR with args
---@param ctx inline_explorer.Ctx
---@param mode? "correct"|"readable" default "correct"
---@return string new_src
function M.print(caller_src, ir, ctx, mode)
  local printer_name, placement = canalyze.decide(ir, ctx, mode or "correct")
  return cprint.PRINTERS[printer_name](caller_src, ir, ctx, placement)
end

-- The innermost call at (row, col) and the name it calls, or nil and the
-- reason when there is no call there or it calls no plain name.
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
---@param caller_src string
---@param row integer 0-based
---@param col integer 0-based, in bytes
---@param root? TSNode caller_src's tree, if already parsed
---@return string?
function M.call_name_at(caller_src, row, col, root)
  local call, name_or_reason = named_call_at(caller_src, row, col, root)
  if not call then
    return nil
  end
  return name_or_reason
end

-- Inlines the call at (row, col), see named_call_at; callee_src holds the
-- definition of the function it calls.
---@param caller_src string
---@param row integer 0-based
---@param col integer 0-based, in bytes
---@param callee_src string
---@param N? integer default 1
---@param mode? "correct"|"readable" default "correct"
---@param root? TSNode caller_src's tree, if already parsed
---@return string? new_src
---@return string? err
function M.inline_at(caller_src, row, col, callee_src, N, mode, root)
  local call, name_or_reason = named_call_at(caller_src, row, col, root)
  if not call then
    return nil, name_or_reason
  end
  local fname = name_or_reason
  local ir, ctx, err = canalyze.analyze_call_node(caller_src, callee_src, fname, N or 1, call)
  if not ir then
    return nil, err
  end
  return M.print(caller_src, ir, ctx, mode)
end

return M
