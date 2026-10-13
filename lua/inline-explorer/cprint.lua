-- Printers: layout only, for the three forms canalyze.decide picks from.
local csrc = require("inline-explorer.csrc")
local simplify = require("inline-explorer.simplify")

local M = {}

local function splice(caller_src, edits)
  return csrc.apply_edits(caller_src, 0, #caller_src, edits)
end

-- Edits on ir.src that rewrite each `return`. Only the `return` keyword and,
-- for "goto", the `;` are replaced, so E stays in place with its body_edits:
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
    local has_expr = #csrc.code_children(r) > 0
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

-- Statements 1..last_i with ir.body_edits and `extra` applied, from the start
-- of the first one's line, so that csrc.reindent sees the callee's
-- indentation; but from the statement itself when code precedes it on that
-- line, as the signature of `static int f(int x) { return x; }` does.
local function body_text(ir, last_i, extra)
  local edits = {}
  vim.list_extend(edits, ir.body_edits)
  vim.list_extend(edits, extra or {})
  local first = ir.stmts[1]
  local from = csrc.line_start_byte(first)
  if not ir.src:sub(from + 1, csrc.start_byte(first)):match("^[ \t]*$") then
    from = csrc.start_byte(first)
  end
  -- A bare `struct s { ... };` or `enum { A };` leaves its `;` to the block.
  local last = ir.stmts[last_i]
  local after = last:next_sibling()
  local stop = csrc.end_byte((after and after:type() == ";") and after or last)
  return csrc.apply_edits(ir.src, from, stop, edits)
end

-- print_hoisted where lines cannot go above target: a new block replaces
-- target and holds the `hoist` lines, then target.
local function print_wrapped(caller_src, ctx, hoist, replacement)
  local target_start = csrc.start_byte(ctx.target)
  local target_end = csrc.end_byte(ctx.target)
  local call_edit = { csrc.start_byte(ctx.call), csrc.end_byte(ctx.call), replacement }
  local modified = csrc.apply_edits(caller_src, target_start, target_end, { call_edit })
  local inner = ctx.indent .. ctx.indent_unit
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

local function print_hoisted(caller_src, ctx, hoist, replacement)
  if not ctx.can_insert_above then
    return print_wrapped(caller_src, ctx, hoist, replacement)
  end
  local block = {}
  for _, l in ipairs(hoist) do
    block[#block + 1] = ctx.indent .. l
  end
  return splice(caller_src, {
    { ctx.stmt_bol, ctx.stmt_bol, table.concat(block, "\n") .. "\n" },
    { csrc.start_byte(ctx.call), csrc.end_byte(ctx.call), replacement },
  })
end

-- Pretty: the bindings and all statements but the last are hoisted above
-- target, and E of the final `return E;`, parenthesised to keep its
-- precedence, replaces the call. Only for a simple callee (see decide).
---@param caller_src string
---@param ir inline_explorer.IR with binds
---@param ctx inline_explorer.Ctx
---@return string new_src
local function print_pretty(caller_src, ir, ctx)
  local hoist = {}
  vim.list_extend(hoist, ir.binds)
  if #ir.stmts >= 2 then
    vim.list_extend(hoist, csrc.reindent(body_text(ir, #ir.stmts - 1), ""))
  end
  local expr = csrc.code_children(ir.stmts[#ir.stmts])[1]
  local expr_text = csrc.apply_edits(ir.src, csrc.start_byte(expr), csrc.end_byte(expr), ir.body_edits)
  local replacement = simplify.parens("(" .. expr_text .. ")")
  return print_hoisted(caller_src, ctx, hoist, replacement)
end

-- Canonical: a GNU statement expression replaces the call, every return
-- becoming a goto to its end.
---@param caller_src string
---@param ir inline_explorer.IR with binds
---@param ctx inline_explorer.Ctx
---@return string new_src
local function print_canonical(caller_src, ir, ctx)
  local inner = ctx.indent .. ctx.indent_unit
  local parts = { "({" }
  for _, b in ipairs(ir.binds) do
    parts[#parts + 1] = inner .. b
  end
  if ir.has_value then
    parts[#parts + 1] = inner .. ir.ret_decl .. ";"
  end
  vim.list_extend(parts, csrc.reindent(body_text(ir, #ir.stmts, return_edits(ir, "goto")), inner))
  parts[#parts + 1] = inner .. ir.end_label .. ":;"
  if ir.has_value then
    parts[#parts + 1] = inner .. ir.ret_var .. ";"
  end
  parts[#parts + 1] = ctx.indent .. "})"
  return splice(caller_src, { { csrc.start_byte(ctx.call), csrc.end_byte(ctx.call), table.concat(parts, "\n") } })
end

-- Readable: the body is hoisted with every return turned into an assignment,
-- and __ie_retN replaces the call. An early return no longer stops the rest
-- of the body, so this is unfaithful to a callee that has one.
---@param caller_src string
---@param ir inline_explorer.IR with binds
---@param ctx inline_explorer.Ctx
---@return string new_src
local function print_readable_multi(caller_src, ir, ctx)
  local hoist = {}
  vim.list_extend(hoist, ir.binds)
  if ir.has_value then
    hoist[#hoist + 1] = ir.ret_decl .. ";"
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
