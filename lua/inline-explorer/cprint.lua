-- Printers: pure layout for the three expansion forms (pretty / canonical
-- statement-expression / readable-multi). No judgements here.
local C = require("inline-explorer.csrc")

local M = {}

local function splice(caller_src, edits)
  return C.apply_edits(caller_src, 0, #caller_src, edits)
end

-- Rewrite `return E;` inside the body region.
-- style "goto":   `return E;` -> `{ ret = E; goto end; }` (self-contained)
-- style "assign": `return E;` -> `ret = E;`               (no control flow)
local function return_edits(ir, style)
  local eds = {}
  for _, r in ipairs(ir.returns) do
    local kw = r:child(0)
    local semi = r:child(r:child_count() - 1)
    local has_expr = r:named_child_count() > 0
    if style == "assign" then
      eds[#eds + 1] = { C.sb(kw), C.eb(kw), has_expr and (ir.ret_var .. " =") or "(void)0" }
    elseif has_expr then
      eds[#eds + 1] = { C.sb(kw), C.eb(kw), "{ " .. ir.ret_var .. " =" }
      eds[#eds + 1] = { C.sb(semi), C.eb(semi), "; goto " .. ir.end_label .. "; }" }
    else
      eds[#eds + 1] = { C.sb(kw), C.eb(kw), "{ goto " .. ir.end_label .. ";" }
      eds[#eds + 1] = { C.sb(semi), C.eb(semi), " }" }
    end
  end
  return eds
end

-- Body statements [1..last_i] with `extra` edits applied, dedented to "".
local function body_text(ir, last_i, extra)
  local edits = {}
  vim.list_extend(edits, ir.body_edits)
  vim.list_extend(edits, extra or {})
  local rstart = C.sb(ir.stmts[1]) - C.scol(ir.stmts[1])
  return C.apply_edits(ir.src, rstart, C.eb(ir.stmts[last_i]), edits)
end

-- Replace the whole target statement with `{ hoist...; modified target }`.
local function print_wrapped(caller_src, ir, ctx, hoist, replacement)
  local ttext = C.text(ctx.target, caller_src)
  local off = C.sb(ctx.call) - C.sb(ctx.target)
  local modified = ttext:sub(1, off) .. replacement .. ttext:sub(C.eb(ctx.call) - C.sb(ctx.target) + 1)
  local inner = ctx.indent .. ctx.unit
  local out = { "{" }
  for _, l in ipairs(hoist) do
    out[#out + 1] = inner .. l
  end
  for _, l in ipairs(vim.split(modified, "\n", { plain = true })) do
    out[#out + 1] = inner .. l
  end
  out[#out + 1] = ctx.indent .. "}"
  return splice(caller_src, { { C.sb(ctx.target), C.eb(ctx.target), table.concat(out, "\n") } })
end

-- Insert `hoist` lines above the target statement and swap the call for
-- `replacement`; wraps in a block when the target is not directly braced.
local function print_hoisted(caller_src, ir, ctx, hoist, replacement)
  if not ctx.braced then
    return print_wrapped(caller_src, ir, ctx, hoist, replacement)
  end
  local block = {}
  for _, l in ipairs(hoist) do
    block[#block + 1] = ctx.indent .. l
  end
  return splice(caller_src, {
    { ctx.stmt_bol, ctx.stmt_bol, table.concat(block, "\n") .. "\n" },
    { C.sb(ctx.call), C.eb(ctx.call), replacement },
  })
end

-- Pretty hoist: setup lifted above the statement, the returned expression
-- spliced in place (parenthesised, so precedence is preserved).
local function print_pretty(caller_src, ir, ctx)
  local hoist = {}
  vim.list_extend(hoist, ir.binds)
  if #ir.stmts >= 2 then
    vim.list_extend(hoist, C.rebase(body_text(ir, #ir.stmts - 1), ""))
  end
  local expr = ir.stmts[#ir.stmts]:named_child(0)
  local expr_text = C.apply_edits(ir.src, C.sb(expr), C.eb(expr), ir.body_edits)
  -- The precedence parens double up when the return expression was already
  -- parenthesised; collapse the redundant nest (semantics-preserving).
  local replacement = require("inline-explorer.simplify").parens("(" .. expr_text .. ")")
  return print_hoisted(caller_src, ir, ctx, hoist, replacement)
end

-- Canonical form: GNU statement expression + return->goto. Legal in any
-- expression context, so it needs no wrapping and no safety analysis.
local function print_canonical(caller_src, ir, ctx)
  local inner = ctx.indent .. ctx.unit
  local parts = { "({" }
  for _, b in ipairs(ir.binds) do
    parts[#parts + 1] = inner .. b
  end
  if ir.has_value then
    parts[#parts + 1] = inner .. ir.ret_type .. " " .. ir.ret_var .. ";"
  end
  vim.list_extend(parts, C.rebase(body_text(ir, #ir.stmts, return_edits(ir, "goto")), inner))
  parts[#parts + 1] = inner .. ir.end_label .. ":;"
  if ir.has_value then
    parts[#parts + 1] = inner .. ir.ret_var .. ";"
  end
  parts[#parts + 1] = ctx.indent .. "})"
  return splice(caller_src, { { C.sb(ctx.call), C.eb(ctx.call), table.concat(parts, "\n") } })
end

-- Readable general form: body hoisted with return -> assignment, no ({})/goto.
-- Reads top-to-bottom; not faithful for functions with early returns.
local function print_readable_multi(caller_src, ir, ctx)
  local hoist = {}
  vim.list_extend(hoist, ir.binds)
  if ir.has_value then
    hoist[#hoist + 1] = ir.ret_type .. " " .. ir.ret_var .. ";"
  end
  vim.list_extend(hoist, C.rebase(body_text(ir, #ir.stmts, return_edits(ir, "assign")), ""))
  return print_hoisted(caller_src, ir, ctx, hoist, ir.ret_var)
end

M.PRINTERS = {
  pretty = print_pretty,
  canonical = print_canonical,
  readable_multi = print_readable_multi,
}

return M
