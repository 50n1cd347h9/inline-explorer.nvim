-- C inline substitution: rewrites a call `f(args)` into the effect of f's
-- body, as a GNU C source transform on text and tree-sitter trees, and a
-- macro use into clangd's expansion of it (replace_macro_use). canalyze
-- analyses the call and decides on a layout, cprint prints it, and this module
-- holds the public API. `N`, an id unique to each expansion, suffixes the
-- names it injects or renames. See DESIGN.md. The specs reach the analysis
-- and the printers through tests/lib/inline.lua.
local csrc = require("inline-explorer.csrc")
local canalyze = require("inline-explorer.canalyze")
local cprint = require("inline-explorer.cprint")
local simplify = require("inline-explorer.simplify")

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
    return nil, canalyze.refuse("no-call", "no call under the cursor")
  end
  local fn = call:field("function")[1]
  if not fn or fn:type() ~= "identifier" then
    return nil, canalyze.refuse("not-plain", "call target is not a plain function name")
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
---@return inline_explorer.Refusal? err
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

-- The macro use at (row, col), and whether it is a whole expression statement.
-- The use is the call_expression when the identifier there is its callee, else
-- the identifier.
local function find_invocation(root, row, col)
  local node = csrc.ancestor_at(root, row, col, "identifier")
  if not node then
    return nil
  end
  local invocation = node
  local parent = node:parent()
  if parent and parent:type() == "call_expression" then
    local callee = parent:field("function")[1]
    if callee and csrc.start_byte(callee) == csrc.start_byte(node) then
      invocation = parent
    end
  end
  local outer = invocation:parent()
  local is_statement = outer ~= nil and outer:type() == "expression_statement"
  return invocation, is_statement
end

-- `src` with the macro use at (row, col) replaced by `exp_lines`, its
-- expansion (see macro.fetch_expansion). `root` is
-- src's parsed root, when the caller has it.
---@param src string
---@param row integer 0-based
---@param col integer 0-based, in bytes
---@param exp_lines string[]
---@param root? TSNode
---@return string? new_src
---@return inline_explorer.Refusal? err
function M.replace_macro_use(src, row, col, exp_lines, root)
  local invocation, is_statement = find_invocation(root or csrc.parse(src), row, col)
  if not invocation then
    return nil, canalyze.refuse("no-macro", "no macro use under the cursor")
  end
  local parts = {}
  for i, l in ipairs(exp_lines) do
    parts[i] = l
  end
  if #parts > 1 then
    -- The indent of the use's line, not all text before the use, which would
    -- repeat `foo = ` on each line.
    local indent = csrc.line_indent(src, invocation)
    for i = 2, #parts do
      parts[i] = indent .. parts[i]
    end
  end
  -- Trimmed because clangd's text can start with a space, which would fail
  -- the anchored `^%b()$` check below.
  local exp = vim.trim(simplify.parens(table.concat(parts, "\n")))
  local rep = exp
  if not is_statement then
    -- Parenthesized to keep its precedence in an expression; simplify.parens
    -- then drops a pair if the wrap doubled one.
    if not exp:match("^%b()$") then
      rep = "(" .. exp .. ")"
    end
    rep = simplify.parens(rep)
  end
  return src:sub(1, csrc.start_byte(invocation)) .. rep .. src:sub(csrc.end_byte(invocation) + 1)
end

return M
