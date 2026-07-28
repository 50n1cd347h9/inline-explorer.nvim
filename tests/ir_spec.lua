-- Unit tests for the substitute engine's analysis layer: the callee IR, the
-- call-site context, and the single printer decision (M._probe).
--   nvim --headless --clean -u NONE -c "luafile tests/ir_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local S = require("inline-explorer.substitute")

if not pcall(vim.treesitter.get_string_parser, "int x;", "c") then
  print("SKIP: c parser unavailable")
  return
end

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and ("\n----\n" .. vim.inspect(d) .. "\n----") or ""))
  end
end

local simple_callee = [[static int acc(int x)
{
    int t = x + 1;
    return t * 2;
}]]
local multi_callee = [[static int cls(int x)
{
    if (x < 0)
        return -1;
    return x ? 1 : 0;
}]]

-- Simple callee in a plain statement -> pretty.
do
  local p = assert(S._probe([[static int caller(int n)
{
    return acc(n) + 1;
}]], simple_callee, "acc"))
  check("simple+plain: ir.simple", p.ir.simple == true, p.ir)
  check("simple+plain: ctx.unconditional", p.ctx.unconditional == true, p.ctx)
  check("simple+plain: ctx.braced", p.ctx.braced == true, p.ctx)
  check("simple+plain: decision pretty", p.decision == "pretty", p.decision)
  check("ir.ret_type reconstructed", p.ir.ret_type == "int", p.ir.ret_type)
  check("ir.has_value", p.ir.has_value == true)
end

-- Same callee under && -> not unconditional -> canonical.
do
  local p = assert(S._probe([[static int caller(int a, int b)
{
    return a && acc(b);
}]], simple_callee, "acc"))
  check("short-circuit: ctx.unconditional false", p.ctx.unconditional == false, p.ctx)
  check("short-circuit: decision canonical", p.decision == "canonical", p.decision)
end

-- Ternary arm -> canonical.
do
  local p = assert(S._probe([[static int caller(int c, int n)
{
    return c ? acc(n) : 0;
}]], simple_callee, "acc"))
  check("ternary: decision canonical", p.decision == "canonical", p.decision)
end

-- Multi-return callee -> canonical in correct mode, readable_multi in readable.
do
  local caller = [[static int caller(int n)
{
    int r = cls(n);
    return r;
}]]
  local p = assert(S._probe(caller, multi_callee, "cls"))
  check("multi-return: ir.simple false", p.ir.simple == false)
  check("multi-return: decision canonical", p.decision == "canonical", p.decision)
  local pr = assert(S._probe(caller, multi_callee, "cls", 1, "readable"))
  check("multi-return readable: decision readable_multi", pr.decision == "readable_multi", pr.decision)
end

-- Simple callee in readable mode is pretty even where hoisting is unsafe.
do
  local p = assert(S._probe([[static int caller(int a, int b)
{
    return a && acc(b);
}]], simple_callee, "acc", 1, "readable"))
  check("readable overrides unsafe hoist: pretty", p.decision == "pretty", p.decision)
end

-- Unbraced if body -> ctx.braced false (printer must wrap).
do
  local p = assert(S._probe([[static int caller(int a)
{
    if (a > 0)
        return acc(a);
    return 0;
}]], simple_callee, "acc"))
  check("unbraced if: ctx.braced false", p.ctx.braced == false, p.ctx)
  check("unbraced if: still pretty (wrap is layout, not decision)", p.decision == "pretty", p.decision)
end

-- Caller locals colliding with callee locals -> rename planned in the IR.
do
  local p = assert(S._probe([[static int caller(int t)
{
    int r = g(t);
    return r;
}]], [[static int g(int x)
{
    int t = x * 2;
    return t + 1;
}]], "g"))
  check("collision: rename planned", p.ir.rename.t == "t__ie1", p.ir.rename)
end

-- Tab-indented caller -> unit is a tab.
do
  local p = assert(S._probe("static int caller(int n)\n{\n\treturn acc(n) + 1;\n}", simple_callee, "acc"))
  check("tab caller: ctx.unit is tab", p.ctx.unit == "\t", p.ctx.unit)
end

-- Errors surface as nil, err.
do
  local _, err = S._probe("static int caller(int n)\n{\n    return f(n);\n}", "static int f(int x, ...)\n{\n    return x;\n}", "f")
  check("variadic: nil + err", err ~= nil and tostring(err):find("variadic") ~= nil, tostring(err))
end

-- _render: force a specific printer, bypassing decide().
do
  local callee = [[static int acc(int x)
{
    int t = x + 1;
    return t * 2;
}]]
  local caller = [[static int caller(int n)
{
    return acc(n) + 1;
}]]
  local S2 = require("inline-explorer.substitute")
  local pretty = assert(S2._render(caller, callee, "acc", 1, 1, "pretty"))
  local canon = assert(S2._render(caller, callee, "acc", 1, 1, "canonical"))
  check("_render pretty == inline_call on a pretty-decided case", pretty == (S2.inline_call(caller, callee, "acc", 1, 1, "correct")), pretty)
  check("_render canonical emits a statement expression", canon:find("({", 1, true) ~= nil, canon)
  check("_render canonical differs from pretty", canon ~= pretty)
  local _, err = S2._render(caller, callee, "acc", 1, 1, "bogus")
  check("_render rejects unknown printer", err ~= nil and tostring(err):find("printer") ~= nil, tostring(err))

  check("_rebase/_common_ws_prefix exported", type(S2._rebase) == "function" and type(S2._common_ws_prefix) == "function")
end

print("")
print(fails == 0 and "ALL IR TESTS PASSED" or (fails .. " FAILURE(S)"))
