-- Unit tests for the substitute engine's analysis layer: the callee IR, the
-- call-site context, and the single printer decision (tests/lib/inline.lua's probe).
--   nvim --headless --clean -u NONE -c "luafile tests/ir_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local H = require("tests.lib.harness")
local T = require("tests.lib.inline")
local cprint = require("inline-explorer.cprint")

if not H.require_c_parser() then
  return
end

local check = H.check

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
  local p = assert(T.probe(
    [[static int caller(int n)
{
    return acc(n) + 1;
}]],
    simple_callee,
    "acc"
  ))
  check("simple+plain: ir.simple", p.ir.simple == true, p.ir)
  check("simple+plain: ctx.unconditional", p.ctx.unconditional == true, p.ctx)
  check("simple+plain: ctx.can_insert_above", p.ctx.can_insert_above == true, p.ctx)
  check("simple+plain: decision pretty", p.decision == "pretty", p.decision)
  check("ret_decl reconstructed", cprint.ret_decl(p.ir) == "int __ie_ret1", cprint.ret_decl(p.ir))
  check("ir.has_value", p.ir.has_value == true)
end

-- Same callee under && -> not unconditional -> canonical.
do
  local p = assert(T.probe(
    [[static int caller(int a, int b)
{
    return a && acc(b);
}]],
    simple_callee,
    "acc"
  ))
  check("short-circuit: ctx.unconditional false", p.ctx.unconditional == false, p.ctx)
  check("short-circuit: decision canonical", p.decision == "canonical", p.decision)
end

-- Ternary arm -> canonical.
do
  local p = assert(T.probe(
    [[static int caller(int c, int n)
{
    return c ? acc(n) : 0;
}]],
    simple_callee,
    "acc"
  ))
  check("ternary: decision canonical", p.decision == "canonical", p.decision)
end

-- A call that may not run, or runs after other code in its statement, is not
-- hoisted. An argument of an ordinary call still is.
do
  local shapes = {
    { "int r = sizeof(acc(n));", "canonical" },
    { "int r = _Generic(acc(n), int: 1, default: 0);", "canonical" },
    { "int r = (n = 1, acc(n));", "canonical" },
    { "int a = n, r = acc(a);", "canonical" },
    { "int r = __builtin_constant_p(acc(n));", "canonical" },
    { "__typeof__(acc(n) + 1) *p = 0;", "canonical" },
    { "int r = acc(n), s = 1;", "pretty" },
    { "int r = __builtin_expect(acc(n), 1);", "pretty" },
  }
  for _, sh in ipairs(shapes) do
    local p =
      assert(T.probe(("static int caller(int n)\n{\n    %s\n    return 0;\n}"):format(sh[1]), simple_callee, "acc"))
    check(("hoist guard: `%s` -> %s"):format(sh[1], sh[2]), p.decision == sh[2], p.decision)
  end
end

-- A target that does not parse cleanly gets the in-place form in both modes:
-- WHEN may hide an `if`.
do
  local caller = "static int caller(int n)\n{\n    int x = 0;\n    WHEN(n > 0) x = acc(n);\n    return x;\n}"
  for _, mode in ipairs({ "correct", "readable" }) do
    local p = assert(T.probe(caller, simple_callee, "acc", 1, mode))
    check("misparsed target, " .. mode .. ": ctx.parse_error", p.ctx.parse_error == true, p.ctx)
    check("misparsed target, " .. mode .. ": decision canonical", p.decision == "canonical", p.decision)
  end
end

-- Multi-return callee -> canonical in correct mode, readable_multi in readable.
do
  local caller = [[static int caller(int n)
{
    int r = cls(n);
    return r;
}]]
  local p = assert(T.probe(caller, multi_callee, "cls"))
  check("multi-return: ir.simple false", p.ir.simple == false)
  check("multi-return: decision canonical", p.decision == "canonical", p.decision)
  local pr = assert(T.probe(caller, multi_callee, "cls", 1, "readable"))
  check("multi-return readable: decision readable_multi", pr.decision == "readable_multi", pr.decision)
end

-- Simple callee in readable mode is pretty even where hoisting is unsafe.
do
  local p = assert(T.probe(
    [[static int caller(int a, int b)
{
    return a && acc(b);
}]],
    simple_callee,
    "acc",
    1,
    "readable"
  ))
  check("readable overrides unsafe hoist: pretty", p.decision == "pretty", p.decision)
end

-- Unbraced if body -> ctx.can_insert_above false (printer must wrap).
do
  local p = assert(T.probe(
    [[static int caller(int a)
{
    if (a > 0)
        return acc(a);
    return 0;
}]],
    simple_callee,
    "acc"
  ))
  check("unbraced if: ctx.can_insert_above false", p.ctx.can_insert_above == false, p.ctx)
  check("unbraced if: still pretty (wrap is layout, not decision)", p.decision == "pretty", p.decision)
end

-- Caller locals colliding with callee locals -> rename planned in the IR.
do
  local p = assert(T.probe(
    [[static int caller(int t)
{
    int r = g(t);
    return r;
}]],
    [[static int g(int x)
{
    int t = x * 2;
    return t + 1;
}]],
    "g"
  ))
  check("collision: rename planned", p.ir.rename.t == "t__ie1", p.ir.rename)
end

-- Tab-indented caller -> its indent unit is a tab.
do
  local p = assert(T.probe("static int caller(int n)\n{\n\treturn acc(n) + 1;\n}", simple_callee, "acc"))
  check("tab caller: the indent unit is a tab", cprint.indent_unit(p.ctx.indent) == "\t", p.ctx.indent)
end

-- Errors surface as nil, err.
do
  local _, err =
    T.probe("static int caller(int n)\n{\n    return f(n);\n}", "static int f(int x, ...)\n{\n    return x;\n}", "f")
  check("variadic: nil + err", err ~= nil and tostring(err):find("variadic") ~= nil, tostring(err))
end

-- render: force a specific printer, bypassing decide().
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
  local pretty = assert(T.render(caller, callee, "acc", 1, 1, "pretty"))
  local canon = assert(T.render(caller, callee, "acc", 1, 1, "canonical"))
  check(
    "render pretty == inline_call on a pretty-decided case",
    pretty == (T.inline_call(caller, callee, "acc", 1, 1, "correct")),
    pretty
  )
  check("render canonical emits a statement expression", canon:find("({", 1, true) ~= nil, canon)
  check("render canonical differs from pretty", canon ~= pretty)
  local _, err = T.render(caller, callee, "acc", 1, 1, "bogus")
  check("render rejects unknown printer", err ~= nil and tostring(err):find("printer") ~= nil, tostring(err))
end

H.finish("IR")
