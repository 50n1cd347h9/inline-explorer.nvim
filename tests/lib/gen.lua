-- Random C generator for the property-based tests: small callees drawn from a
-- UB-free statement pool, spliced into one of 9 caller contexts, plus greedy
-- shrinking. Everything is deterministic: the only randomness source is the
-- Park-Miller LCG below, so a seed fully reproduces a case.
--
-- Two-phase design: gen.case(rng) builds an ABSTRACT case (params, statement
-- texts, context id); gen.render(case) is a PURE function from that case to
-- sources. Shrinking mutates the abstract case; a reduction that breaks the
-- original program simply fails the caller-supplied predicate (the oracle
-- needs the original to build), so no use-def tracking is required.
local M = {}

M.CTX_N = 11

-- Park-Miller LCG. Deterministic and portable; math.random is neither.
function M.rng(seed)
  local state = seed % 2147483647
  if state <= 0 then
    state = state + 2147483646
  end
  local r = {}
  function r.int(lo, hi)
    state = (state * 48271) % 2147483647
    return lo + state % (hi - lo + 1)
  end
  function r.pick(list)
    return list[r.int(1, #list)]
  end
  function r.chance(pct)
    return r.int(1, 100) <= pct
  end
  return r
end

-- Integer expression over the given operand names. UB-free by construction:
-- ops are + - & | ^ only, literals 0..9, depth <= 2.
local OPS = { "+", "-", "&", "|", "^" }

local function iexpr(r, operands, depth)
  if depth <= 0 or #operands == 0 or r.chance(35) then
    if #operands > 0 and r.chance(70) then
      return r.pick(operands)
    end
    return tostring(r.int(0, 9))
  end
  return "(" .. iexpr(r, operands, depth - 1) .. " " .. r.pick(OPS) .. " " .. iexpr(r, operands, depth - 1) .. ")"
end

-- Build an abstract case:
--   params  list of { type = "int" | "ptr", name = ... }
--   args    caller-side argument snippets, aligned with params ("&pv1" for ptr)
--   stmts   pre-rendered callee statement texts (each self-contained)
--   ret     the final `return <expr>;` expression text
--   ctx     caller context id, 1..CTX_N
function M.case(r)
  local case = { params = {}, args = {}, stmts = {}, ret = nil, ctx = r.int(1, M.CTX_N) }

  local nparams = r.int(0, 3)
  local operands = {}
  for i = 1, nparams do
    if r.chance(25) then
      case.params[i] = { type = "ptr", name = "p" .. i }
      case.args[i] = "&pv" .. i
      operands[#operands + 1] = "*p" .. i
    else
      -- x/t/s: t and s deliberately collide with the caller's locals to keep
      -- the rename machinery under constant pressure.
      case.params[i] = { type = "int", name = r.pick({ "x" .. i, "t", "s" }) }
      case.args[i] = r.pick({ "a", "b", "t", "s", tostring(r.int(0, 9)) })
      operands[#operands + 1] = case.params[i].name
    end
  end
  -- De-duplicate colliding names (two declarations sharing a name in function
  -- scope is invalid C). Loop until the candidate is genuinely free: a single
  -- "_<i>" suffix can itself collide with a later independent "_<n>" rename.
  local seen = {}
  local function unique(base)
    local name, k = base, 0
    while seen[name] do
      k = k + 1
      name = base .. "_" .. k
    end
    seen[name] = true
    return name
  end
  for i, p in ipairs(case.params) do
    p.name = unique(p.name)
    operands[i] = p.type == "ptr" and ("*" .. p.name) or p.name
  end

  local nstmts = r.int(0, 5)
  local nlocal = 0
  for k = 1, nstmts do
    local kind = r.int(1, 6)
    if kind == 1 or (kind >= 5 and #operands == 0 and nlocal == 0) then
      -- declaration; t/s again collide with the caller on purpose
      nlocal = nlocal + 1
      local name = unique(r.pick({ "l" .. nlocal, "t", "s" }))
      case.stmts[#case.stmts + 1] = "int " .. name .. " = " .. iexpr(r, operands, 2) .. ";"
      operands[#operands + 1] = name
    elseif kind == 2 then
      -- assignment to a mutable int (declared local or int param)
      local tgt = {}
      for _, o in ipairs(operands) do
        if not o:find("%*") then
          tgt[#tgt + 1] = o
        end
      end
      if #tgt > 0 then
        case.stmts[#case.stmts + 1] = r.pick(tgt) .. " = " .. iexpr(r, operands, 2) .. ";"
      end
    elseif kind == 3 then
      local tgt = {}
      for _, o in ipairs(operands) do
        if not o:find("%*") then
          tgt[#tgt + 1] = o
        end
      end
      if #tgt > 0 then
        local v = r.pick(tgt)
        case.stmts[#case.stmts + 1] = "if (" .. iexpr(r, operands, 1) .. ") { " .. v .. " = " .. iexpr(r, operands, 1) .. "; } else { " .. v .. " = " .. iexpr(r, operands, 1) .. "; }"
      end
    elseif kind == 4 then
      local tgt = {}
      for _, o in ipairs(operands) do
        if not o:find("%*") then
          tgt[#tgt + 1] = o
        end
      end
      if #tgt > 0 then
        -- bounded loop: the (& 7) mask guarantees termination
        case.stmts[#case.stmts + 1] = "{ int i" .. k .. " = (" .. iexpr(r, operands, 1) .. ") & 7; while (i" .. k .. " > 0) { i" .. k .. " = i" .. k .. " - 1; " .. r.pick(tgt) .. " = " .. r.pick(tgt) .. " + 1; } }"
      end
    elseif kind == 5 then
      case.stmts[#case.stmts + 1] = "if (" .. iexpr(r, operands, 1) .. ") return " .. iexpr(r, operands, 1) .. ";"
    else
      local tgt = {}
      for _, o in ipairs(operands) do
        if not o:find("%*") then
          tgt[#tgt + 1] = o
        end
      end
      if #tgt > 0 then
        -- self-contained label block: forward goto, function-scoped label
        case.stmts[#case.stmts + 1] = "{ if (" .. iexpr(r, operands, 1) .. ") goto lab" .. k .. "; " .. r.pick(tgt) .. " = " .. r.pick(tgt) .. " + 1; lab" .. k .. ": ; }"
      end
    end
  end

  case.ret = iexpr(r, operands, 2)
  return case
end

-- The 9 caller contexts. CALL is replaced by the call expression.
local CONTEXTS = {
  "    int r = CALL;\n    return r;",
  "    return CALL + 1;",
  "    s = CALL;\n    return s;",
  "    return a && CALL;",
  "    return a ? CALL : t;",
  "    if (CALL)\n        return 1;\n    return 0;",
  "    if (a > 0)\n        return CALL;\n    return t;",
  "    switch (a) {\n    case 1:\n        return CALL;\n    default:\n        return s;\n    }",
  "    {\n        int acc = 0;\n        for (int i = (CALL) & 7; i > 0; i--)\n            acc = acc + 1;\n        return acc;\n    }",
  -- for-CONDITION: the call is re-evaluated each iteration; masked so the
  -- bound is finite either way.
  "    {\n        int acc = 0;\n        for (int i = 0; i < ((CALL) & 3); i++)\n            acc = acc + 1;\n        return acc;\n    }",
  -- for-UPDATE: the decrement is at least 1, so termination is guaranteed.
  "    {\n        int acc = 0;\n        for (int i = 6; i > 0; i = i - (1 + ((CALL) & 1)))\n            acc = acc + 1;\n        return acc;\n    }",
}

-- Render the abstract case to sources. Pure: same case, same strings.
function M.render(case)
  local plist = {}
  for _, p in ipairs(case.params) do
    plist[#plist + 1] = (p.type == "ptr") and ("int *" .. p.name) or ("int " .. p.name)
  end
  local callee = { "static int f(" .. (#plist > 0 and table.concat(plist, ", ") or "void") .. ")", "{" }
  for _, s in ipairs(case.stmts) do
    callee[#callee + 1] = "    " .. s
  end
  callee[#callee + 1] = "    return " .. case.ret .. ";"
  callee[#callee + 1] = "}"
  local callee_src = table.concat(callee, "\n")

  local call = "f(" .. table.concat(case.args, ", ") .. ")"
  local ptr_decls = {}
  for i, p in ipairs(case.params) do
    if p.type == "ptr" then
      ptr_decls[#ptr_decls + 1] = "    int pv" .. i .. " = " .. (i * 3 % 10) .. ";"
    end
  end
  local body = CONTEXTS[case.ctx]:gsub("CALL", (call:gsub("%%", "%%%%")))
  local caller = { "static int caller(int a, int b)", "{", "    int t = 3;", "    int s = 4;" }
  for _, d in ipairs(ptr_decls) do
    caller[#caller + 1] = d
  end
  for _, l in ipairs(vim.split(body, "\n", { plain = true })) do
    caller[#caller + 1] = l
  end
  caller[#caller + 1] = "}"
  local caller_src = table.concat(caller, "\n")

  -- Locate the call: first occurrence of "f(" in the rendered caller.
  local row, col
  for i, l in ipairs(vim.split(caller_src, "\n", { plain = true })) do
    local c = l:find("f%(")
    if c then
      row, col = i - 1, c - 1
      break
    end
  end

  local main = {
    '#include <stdio.h>',
    "int main(void)",
    "{",
    "    int inputs[5] = { -3, 0, 1, 2, 7 };",
    "    for (int i = 0; i < 5; i++)",
    "        for (int j = 0; j < 5; j++)",
    '            printf("%d\\n", caller(inputs[i], inputs[j]));',
    "    return 0;",
    "}",
  }
  local main_src = table.concat(main, "\n") .. "\n"
  local program_src = callee_src .. "\n" .. caller_src .. "\n" .. main_src

  return {
    callee_src = callee_src,
    caller_src = caller_src,
    main_src = main_src,
    program_src = program_src,
    fname = "f",
    row = row,
    col = col,
  }
end

-- A caller invoking the SAME call twice (`f(...) + f(...)`), for the
-- double-inlining uniqueness properties.
function M.render_double(case)
  local call = "f(" .. table.concat(case.args, ", ") .. ")"
  local lines = { "static int caller(int a, int b)", "{", "    int t = 3;", "    int s = 4;" }
  for i, p in ipairs(case.params) do
    if p.type == "ptr" then
      lines[#lines + 1] = "    int pv" .. i .. " = 1;"
    end
  end
  lines[#lines + 1] = "    return " .. call .. " + " .. call .. ";"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

-- Greedy shrink: repeatedly try dropping callee statements (from the tail),
-- then dropping params (with their argument), then simplifying the context to
-- the plain declaration-init form. A reduction is kept only while
-- still_fails(case) holds -- reductions that break the original program make
-- the oracle's precondition fail and are therefore rejected automatically.
function M.shrink(case, still_fails)
  local changed = true
  while changed do
    changed = false
    for i = #case.stmts, 1, -1 do
      local saved = table.remove(case.stmts, i)
      if still_fails(case) then
        changed = true
      else
        table.insert(case.stmts, i, saved)
      end
    end
    for i = #case.params, 1, -1 do
      local p = table.remove(case.params, i)
      local a = table.remove(case.args, i)
      if still_fails(case) then
        changed = true
      else
        table.insert(case.params, i, p)
        table.insert(case.args, i, a)
      end
    end
    if case.ctx ~= 1 then
      local old = case.ctx
      case.ctx = 1
      if still_fails(case) then
        changed = true
      else
        case.ctx = old
      end
    end
  end
  return case
end

return M
