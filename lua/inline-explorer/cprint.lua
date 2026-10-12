-- Printers: pure layout for the three expansion forms (pretty, canonical
-- statement expression, readable_multi). They make no judgements; canalyze
-- has already made them all.
local csrc = require("inline-explorer.csrc")
local simplify = require("inline-explorer.simplify")

local M = {}

-- Applies edits, each { start_byte, end_byte, text }, to the whole caller
-- source and returns the result.
local function splice(caller_src, edits)
  return csrc.apply_edits(caller_src, 0, #caller_src, edits)
end

-- Returns edits on ir.src that rewrite each `return` in the body. Only the
-- `return` keyword and, in the "goto" style, the `;` are replaced: the
-- returned expression E stays where it is.
--   "goto":    `return E;` -> `{ __ie_retN = E; goto __ie_endN; }`
--              `return;`   -> `{ goto __ie_endN; }`
--   "assign":  `return E;` -> `__ie_retN = E;`
--              `return;`   -> `(void)0;`
local function return_edits(ir, style)
  local edits = {}
  local function replace(node, text)
    edits[#edits + 1] = { csrc.start_byte(node), csrc.end_byte(node), text }
  end
  for _, r in ipairs(ir.returns) do
    local keyword = r:child(0)
    local semicolon = r:child(r:child_count() - 1)
    local has_expr = r:named_child_count() > 0
    if style == "assign" then
      replace(keyword, has_expr and (ir.ret_var .. " =") or "(void)0")
    elseif has_expr then
      replace(keyword, "{ " .. ir.ret_var .. " =")
      replace(semicolon, "; goto " .. ir.end_label .. "; }")
    else
      replace(keyword, "{ goto " .. ir.end_label .. ";")
      replace(semicolon, " }")
    end
  end
  return edits
end

-- Returns the text of body statements 1..last_i, from the start of the first
-- one's line, with ir.body_edits and `extra` applied. The indentation is the
-- callee's own; callers re-indent the text with csrc.reindent.
local function body_text(ir, last_i, extra)
  local edits = {}
  vim.list_extend(edits, ir.body_edits)
  vim.list_extend(edits, extra or {})
  local from = csrc.line_start_byte(ir.stmts[1])
  return csrc.apply_edits(ir.src, from, csrc.end_byte(ir.stmts[last_i]), edits)
end

-- Replaces the whole target statement with a new block that holds the
-- `hoist` lines and then the target, its call replaced by `replacement`.
local function print_wrapped(caller_src, ctx, hoist, replacement)
  local target_start = csrc.start_byte(ctx.target)
  local target_end = csrc.end_byte(ctx.target)
  -- modified is the target's text with the call replaced.
  local call_edit = { csrc.start_byte(ctx.call), csrc.end_byte(ctx.call), replacement }
  local modified = csrc.apply_edits(caller_src, target_start, target_end, { call_edit })
  local inner = ctx.indent .. ctx.indent_unit
  -- The block takes the target's place on its line, so `{` needs no indent
  -- of its own; `}` starts a new line, indented like the target's line.
  local out = { "{" }
  for _, l in ipairs(hoist) do
    out[#out + 1] = inner .. l
  end
  for _, l in ipairs(vim.split(modified, "\n", { plain = true })) do
    out[#out + 1] = inner .. l
  end
  out[#out + 1] = ctx.indent .. "}"
  return splice(caller_src, { { target_start, target_end, table.concat(out, "\n") } })
end

-- Inserts the `hoist` lines above the target statement and replaces the call
-- with `replacement`. When lines cannot be inserted above the target,
-- print_wrapped puts both in a new block instead.
local function print_hoisted(caller_src, ctx, hoist, replacement)
  if not ctx.can_insert_above then
    return print_wrapped(caller_src, ctx, hoist, replacement)
  end
  local block = {}
  for _, l in ipairs(hoist) do
    block[#block + 1] = ctx.indent .. l
  end
  -- The first edit is empty, so it inserts the block at the start of the
  -- target's line.
  return splice(caller_src, {
    { ctx.stmt_bol, ctx.stmt_bol, table.concat(block, "\n") .. "\n" },
    { csrc.start_byte(ctx.call), csrc.end_byte(ctx.call), replacement },
  })
end

-- Pretty hoist: the setup is lifted above the statement, and the returned
-- expression, parenthesised to keep its precedence, replaces the call.
local function print_pretty(caller_src, ir, ctx)
  local hoist = {}
  vim.list_extend(hoist, ir.binds)
  if #ir.stmts >= 2 then
    vim.list_extend(hoist, csrc.reindent(body_text(ir, #ir.stmts - 1), ""))
  end
  -- decide() picks pretty only for a simple callee, so the last statement is
  -- `return E;`, and its first named child is E.
  local expr = ir.stmts[#ir.stmts]:named_child(0)
  local expr_text = csrc.apply_edits(ir.src, csrc.start_byte(expr), csrc.end_byte(expr), ir.body_edits)
  -- The precedence parens double up when the return expression was already
  -- parenthesised; collapse the redundant nest (semantics-preserving).
  local replacement = simplify.parens("(" .. expr_text .. ")")
  return print_hoisted(caller_src, ctx, hoist, replacement)
end

-- Canonical form: a GNU statement expression replaces the call, with every
-- return turned into a goto. It is legal in any expression context, so it
-- needs no wrapping and no safety analysis.
local function print_canonical(caller_src, ir, ctx)
  local inner = ctx.indent .. ctx.indent_unit
  local parts = { "({" }
  for _, b in ipairs(ir.binds) do
    parts[#parts + 1] = inner .. b
  end
  if ir.has_value then
    parts[#parts + 1] = inner .. ir.ret_type .. " " .. ir.ret_var .. ";"
  end
  vim.list_extend(parts, csrc.reindent(body_text(ir, #ir.stmts, return_edits(ir, "goto")), inner))
  parts[#parts + 1] = inner .. ir.end_label .. ":;"
  if ir.has_value then
    parts[#parts + 1] = inner .. ir.ret_var .. ";"
  end
  parts[#parts + 1] = ctx.indent .. "})"
  return splice(caller_src, { { csrc.start_byte(ctx.call), csrc.end_byte(ctx.call), table.concat(parts, "\n") } })
end

-- Readable general form: the body is hoisted with each return turned into an
-- assignment, and without ({...}) or goto. It reads top to bottom, but an
-- early return does not stop the rest of the body from running, so it is not
-- faithful for functions that have one.
local function print_readable_multi(caller_src, ir, ctx)
  local hoist = {}
  vim.list_extend(hoist, ir.binds)
  if ir.has_value then
    hoist[#hoist + 1] = ir.ret_type .. " " .. ir.ret_var .. ";"
  end
  vim.list_extend(hoist, csrc.reindent(body_text(ir, #ir.stmts, return_edits(ir, "assign")), ""))
  return print_hoisted(caller_src, ctx, hoist, ir.ret_var)
end

M.PRINTERS = {
  pretty = print_pretty,
  canonical = print_canonical,
  readable_multi = print_readable_multi,
}

return M
