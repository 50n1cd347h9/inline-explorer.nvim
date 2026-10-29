-- Compile-correctness tests for the C inline-substitution engine.
--
-- Run from the repo root:
--   nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!"
--
-- Requires: gcc on PATH and the tree-sitter `c` parser (bundled with Neovim).
-- Each case transforms a call, then gcc compiles AND runs the result, asserting
-- it matches the original function's semantics.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":h:h")
vim.opt.rtp:append(root)
local H = require("tests.lib.harness")
local S = require("inline-explorer.substitute")
local T = require("tests.lib.inline")

if vim.fn.executable("gcc") == 0 then
  print("SKIP: gcc not found")
  return
end

local cc = require("tests.lib.cc")
local tmp = H.tmpdir()

-- gcc -fsyntax-only accepts it. Returns (ok, gcc_output).
local function compiles(src, name)
  return cc.syntax_ok(tmp .. "/" .. name .. ".c", src)
end

-- It builds and exits 0. Returns (ok, gcc_output_or_empty).
local function run_ok(src, name)
  local out, code = cc.build_run(src, tmp .. "/" .. name .. ".c", tmp .. "/" .. name .. ".out")
  if out == nil then
    return false, code
  end
  return code == 0, ""
end

local function transform(caller, callee, fname, seq)
  local src = caller
  for _, step in ipairs(seq) do
    local new, err = T.inline_call(src, callee, fname, step.N, step.occ or 1, step.mode)
    assert(new, ("inline_call failed (N=%d): %s"):format(step.N, tostring(err)))
    src = new
  end
  return src
end

local check = H.check

-- Case 1: simple accessor, value context, pointer param (pretty hoist)
do
  local prelude = [[
struct ct { int state; };
static struct ct CT[4] = {{5},{6},{7},{8}};
static struct ct *per_cpu_ptr(struct ct *base, int cpu) { return &base[cpu]; }
#define MASK 0xf
static int acquire(int cpu)
{
    struct ct *p = per_cpu_ptr(CT, cpu);
    return p->state & MASK;
}
]]
  local callee = [[static int acquire(int cpu)
{
    struct ct *p = per_cpu_ptr(CT, cpu);
    return p->state & MASK;
}]]
  local caller = [[static int caller(int snap, int c)
{
    return snap != acquire(c);
}]]
  local t = transform(caller, callee, "acquire", { { N = 1 } })
  local main = "int main(void){ return (caller(7,2)==0 && caller(3,2)==1)?0:1; }\n"
  check("case1 compiles (pretty hoist, pointer param)", (compiles(prelude .. t .. main, "c1")))
  check("case1 runs equal to original", (run_ok(prelude .. t .. main, "c1")))
  check("case1 stays a plain hoist (no statement expr)", not t:find("({", 1, true), t)
end

-- Case 2: early return -> general statement expression + goto
do
  local callee = [[static int classify(int x)
{
    if (x < 0)
        return -1;
    return x ? 1 : 0;
}]]
  local caller = [[static int caller(int n)
{
    return classify(n) + 5;
}]]
  local t = transform(caller, callee, "classify", { { N = 1 } })
  local main = "int main(void){ return (caller(-3)==4 && caller(0)==5 && caller(9)==6)?0:1; }\n"
  check("case2 compiles (statement expr, early return)", (compiles(callee .. "\n" .. t .. main, "c2")))
  check("case2 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c2")))
  check("case2 used a statement expression", t:find("({", 1, true) ~= nil, t)
end

-- Case 3: callee with label/goto, inlined twice (unique renaming)
do
  local callee = [[static int f(int x)
{
    int s = 0;
loop:
    if (x > 0) { s += x; x--; goto loop; }
    return s;
}]]
  local caller = [[static int caller(int a, int b)
{
    return f(a) + f(b);
}]]
  local t = transform(caller, callee, "f", { { N = 1 }, { N = 2 } })
  local main = "int main(void){ return (caller(3,4)==16)?0:1; }\n"
  check("case3 compiles (label rename, inlined twice)", (compiles(callee .. "\n" .. t .. main, "c3")))
  check("case3 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c3")))
  check("case3 renamed labels uniquely", t:find("loop__ie1") and t:find("loop__ie2"), t)
end

-- Case 4: callee local collides with caller local -> rename
do
  local callee = [[static int g(int x)
{
    int t = x * 2;
    return t + 1;
}]]
  local caller = [[static int caller(int t)
{
    int r = g(t);
    return r;
}]]
  local t = transform(caller, callee, "g", { { N = 1 } })
  local main = "int main(void){ return (caller(10)==21)?0:1; }\n"
  check("case4 compiles (collision rename)", (compiles(callee .. "\n" .. t .. main, "c4")))
  check("case4 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c4")))
  check("case4 renamed the colliding local", t:find("t__ie1") ~= nil, t)
end

-- Case 5: void function in statement context
do
  local callee = [[static void inc(int *p)
{
    *p += 1;
}]]
  local caller = [[static int caller(void)
{
    int x = 5;
    inc(&x);
    return x;
}]]
  local t = transform(caller, callee, "inc", { { N = 1 } })
  local main = "int main(void){ return (caller()==6)?0:1; }\n"
  check("case5 compiles (void, statement context)", (compiles(callee .. "\n" .. t .. main, "c5")))
  check("case5 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c5")))
end

-- Case 6: position entry point picks the correct occurrence
do
  local callee = [[static int sq(int x)
{
    return x * x;
}]]
  local caller = [[static int caller(int a, int b)
{
    return sq(a) + sq(b);
}]]
  local col2 = ("    return sq(a) + sq(b);"):find("sq%(b") - 1
  local new = assert(S.inline_at(caller, 2, col2, callee, 1))
  local main = "int main(void){ return (caller(3,4)==25)?0:1; }\n"
  check("case6 inlined only the 2nd call", select(2, new:gsub("sq%(", "")) == 1, new)
  check("case6 compiles", (compiles(callee .. "\n" .. new .. main, "c6")))
  check("case6 runs equal to original", (run_ok(callee .. "\n" .. new .. main, "c6")))
end

-- Case 7: kernel-shaped accessor (mirrors ct_rcu_watching_cpu_acquire): a
-- __always_inline function with a macro-based per-cpu access, used inside a
-- larger expression via a struct member argument.
do
  local prelude = [[
#define __always_inline inline __attribute__((always_inline))
#define per_cpu_ptr(p, cpu) (&(p)[cpu])
#define CT_RCU_WATCHING_MASK 0x3
struct context_tracking { int state; };
static struct context_tracking ctx[4];
static int atomic_read_acquire(int *p) { return *p; }
struct rcu_data { int cpu; };
static __always_inline int ct_rcu_watching_cpu_acquire(int cpu)
{
    struct context_tracking *ct = per_cpu_ptr(ctx, cpu);
    return atomic_read_acquire(&ct->state) & CT_RCU_WATCHING_MASK;
}
]]
  local callee = [[static __always_inline int ct_rcu_watching_cpu_acquire(int cpu)
{
    struct context_tracking *ct = per_cpu_ptr(ctx, cpu);
    return atomic_read_acquire(&ct->state) & CT_RCU_WATCHING_MASK;
}]]
  local caller = [[static int caller(int snap, struct rcu_data *rdp)
{
    return snap != ct_rcu_watching_cpu_acquire(rdp->cpu);
}]]
  local t = transform(caller, callee, "ct_rcu_watching_cpu_acquire", { { N = 1 } })
  local main = "int main(void){ ctx[2].state = 5; struct rcu_data d = { .cpu = 2 };"
    .. " return (caller(5,&d)==1 && caller(1,&d)==0)?0:1; }\n"
  check("case7 compiles (kernel-shaped __always_inline accessor)", (compiles(prelude .. t .. main, "c7")))
  check("case7 runs equal to original", (run_ok(prelude .. t .. main, "c7")))
  check("case7 pretty-hoisted (no statement expr)", not t:find("({", 1, true), t)
end

-- Case 8: inline into an unbraced `if` body (single-return callee). The hoist
-- must be wrapped in a block, not spliced between the `if` and its statement.
do
  local callee = "static int acc(int x)\n{\n    int t = x + 1;\n    return t * 2;\n}"
  local caller = "static int caller(int a)\n{\n    if (a > 0)\n        return acc(a);\n    return 0;\n}"
  local t = transform(caller, callee, "acc", { { N = 1 } })
  local main = "int main(void){ return (caller(3)==8 && caller(-1)==0)?0:1; }\n"
  check("case8 compiles (unbraced if, single-return)", (compiles(callee .. "\n" .. t .. main, "c8")), t)
  check("case8 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c8")))
end

-- Case 9: inline a multi-return callee into an unbraced `if` body.
do
  local callee = "static int cls(int x)\n{\n    if (x < 0)\n        return -1;\n    return x ? 1 : 0;\n}"
  local caller = "static int caller(int n)\n{\n    if (n > 10)\n        return cls(n);\n    return 99;\n}"
  local t = transform(caller, callee, "cls", { { N = 1 } })
  local main = "int main(void){ return (caller(20)==1 && caller(5)==99 && caller(-1)==99)?0:1; }\n"
  check("case9 compiles (unbraced if, multi-return)", (compiles(callee .. "\n" .. t .. main, "c9")), t)
  check("case9 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c9")))
end

-- Case 10: readable mode, multi-statement single-return callee -> pretty hoist,
-- and never a statement expression / goto.
do
  local callee = [[static int calc(int x)
{
    int a = x + 1;
    int b = a * 2;
    return a + b;
}]]
  local caller = [[static int caller(int n)
{
    return calc(n) - 1;
}]]
  local t = transform(caller, callee, "calc", { { N = 1, mode = "readable" } })
  local main = "int main(void){ return (caller(3)==11)?0:1; }\n"
  check("case10 readable never emits ({...}) or goto", not t:find("({", 1, true) and not t:find("goto", 1, true), t)
  check("case10 compiles (readable, pretty hoist)", (compiles(callee .. "\n" .. t .. main, "c10")))
  check("case10 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c10")))
end

-- Case 11: readable mode, if/else returns (no fallthrough conflict) -> hoisted
-- with return -> assignment; still compiles and preserves semantics here.
do
  local callee = [[static int sign(int x)
{
    if (x >= 0)
        return 1;
    else
        return -1;
}]]
  local caller = [[static int caller(int n)
{
    int s = sign(n);
    return s * 10;
}]]
  local t = transform(caller, callee, "sign", { { N = 1, mode = "readable" } })
  local main = "int main(void){ return (caller(5)==10 && caller(-5)==-10)?0:1; }\n"
  check(
    "case11 readable multi-return has no ({...})/goto",
    not t:find("({", 1, true) and not t:find("goto", 1, true),
    t
  )
  check("case11 rewrote returns to assignments", t:find("__ie_ret1 =") ~= nil, t)
  check("case11 compiles (readable, multi-return)", (compiles(callee .. "\n" .. t .. main, "c11")))
  check("case11 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c11")))
end

-- Case 12: hoist is unsafe under short-circuit / ternary / if-header, even for a
-- simple callee -> correct mode must fall back to a statement expression, and
-- short-circuit behaviour (skipping the side effect) must be preserved.
do
  local prelude = [[
static int cnt = 0;
static int bump(void)
{
    int one = 1;
    return cnt += one;
}
]]
  local callee = [[static int bump(void)
{
    int one = 1;
    return cnt += one;
}]]

  local caller_and = [[static int caller(int a)
{
    return a && bump();
}]]
  local t = transform(caller_and, callee, "bump", { { N = 1 } })
  local main = "int main(void){ cnt = 0; if (caller(0) != 0) return 1; if (cnt != 0) return 2;"
    .. " if (caller(1) != 1) return 3; if (cnt != 1) return 4; return 0; }\n"
  check("case12 && operand uses a statement expr (no unsafe hoist)", t:find("({", 1, true) ~= nil, t)
  check("case12 compiles (short-circuit)", (compiles(prelude .. t .. main, "c12a")))
  check("case12 short-circuit still skips the side effect", (run_ok(prelude .. t .. main, "c12a")))

  local caller_tern = [[static int caller(int c)
{
    return c ? bump() : 7;
}]]
  local t2 = transform(caller_tern, callee, "bump", { { N = 1 } })
  check("case12 ternary arm uses a statement expr", t2:find("({", 1, true) ~= nil, t2)
  local main2 = "int main(void){ cnt = 0; if (caller(0) != 7) return 1; if (cnt != 0) return 2; return 0; }\n"
  check("case12 ternary compiles and skips untaken arm", (run_ok(prelude .. t2 .. main2, "c12b")))

  local caller_if = [[static int caller(int a)
{
    if (bump() == a)
        return 1;
    return 0;
}]]
  local t3 = transform(caller_if, callee, "bump", { { N = 1 } })
  check("case12 if-header call uses a statement expr", t3:find("({", 1, true) ~= nil, t3)
  local main3 = "int main(void){ cnt = 0; return (caller(1)==1 && caller(5)==0 && cnt==2)?0:1; }\n"
  check("case12 if-header compiles and runs", (run_ok(prelude .. t3 .. main3, "c12c")))
end

-- Case 13: statement after a case/goto label is not directly inside braces ->
-- the hoist must be wrapped in a block (a declaration cannot follow a bare label).
do
  local callee = [[static int dbl(int x)
{
    int t = x * 2;
    return t;
}]]

  local caller_case = [[static int caller(int n)
{
    switch (n) {
    case 1:
        return dbl(n);
    default:
        return 0;
    }
}]]
  local t = transform(caller_case, callee, "dbl", { { N = 1 } })
  local main = "int main(void){ return (caller(1)==2 && caller(9)==0)?0:1; }\n"
  check("case13 compiles (hoist after case label wrapped)", (compiles(callee .. "\n" .. t .. main, "c13a")), t)
  check("case13 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c13a")))

  local caller_goto = [[static int caller(int n)
{
    if (n < 0)
        goto out;
    return 0;
out:
    return dbl(n);
}]]
  local t2 = transform(caller_goto, callee, "dbl", { { N = 1 } })
  local main2 = "int main(void){ return (caller(-3)==-6 && caller(3)==0)?0:1; }\n"
  check("case13 compiles (hoist after goto label wrapped)", (compiles(callee .. "\n" .. t2 .. main2, "c13b")), t2)
  check("case13 goto-label variant runs equal", (run_ok(callee .. "\n" .. t2 .. main2, "c13b")))
end

-- Case 14: non-inlinable / invalid inputs report errors instead of producing code.
do
  local caller = "static int caller(int n)\n{\n    return f(n);\n}"

  local variadic = "static int f(int x, ...)\n{\n    return x;\n}"
  local new, err = T.inline_call(caller, variadic, "f", 1, 1)
  check("case14 variadic -> error", new == nil and tostring(err):find("variadic") ~= nil, tostring(err))

  local two_params = "static int f(int a, int b)\n{\n    return a + b;\n}"
  new, err = T.inline_call(caller, two_params, "f", 1, 1)
  check("case14 arity mismatch -> error", new == nil and tostring(err):find("arity") ~= nil, tostring(err))

  local empty = "static int f(int x)\n{\n}"
  new, err = T.inline_call(caller, empty, "f", 1, 1)
  check("case14 empty body -> error", new == nil and tostring(err):find("empty") ~= nil, tostring(err))

  local ok_callee = "static int g(int x)\n{\n    return x;\n}"
  new, err = T.inline_call(caller, ok_callee, "g", 1, 1)
  check("case14 no call in caller -> error", new == nil and tostring(err):find("not found") ~= nil, tostring(err))
end

-- Case 15: parameter bindings reconstruct the declared type: a NULL/0 argument
-- keeps its pointer type, arrays decay to pointers, and a function pointer
-- keeps its declarator.
do
  local callee_null = [[static int isnull(char *p)
{
    if (p)
        return 0;
    return 1;
}]]
  local caller_null = [[static int caller(void)
{
    return isnull(0);
}]]
  local t = transform(caller_null, callee_null, "isnull", { { N = 1 } })
  local main = "int main(void){ return (caller()==1)?0:1; }\n"
  check("case15 NULL arg bound with declared pointer type", t:find("char %*p = %(0%);") ~= nil, t)
  check("case15 NULL-arg compiles", (compiles(callee_null .. "\n" .. t .. main, "c15a")))
  check("case15 NULL-arg runs equal", (run_ok(callee_null .. "\n" .. t .. main, "c15a")))

  local callee_arr = [[static int first(int a[])
{
    return a[0];
}]]
  local caller_arr = [[static int caller(void)
{
    int arr[3] = { 42, 1, 2 };
    return first(arr);
}]]
  local t2 = transform(caller_arr, callee_arr, "first", { { N = 1 } })
  local main2 = "int main(void){ return (caller()==42)?0:1; }\n"
  check("case15 array param decays to pointer", t2:find("int %*a = %(arr%);") ~= nil, t2)
  check("case15 array-param compiles", (compiles(callee_arr .. "\n" .. t2 .. main2, "c15b")))
  check("case15 array-param runs equal", (run_ok(callee_arr .. "\n" .. t2 .. main2, "c15b")))

  local callee_fp = [[static int apply(int (*fp)(int), int x)
{
    int r = fp(x);
    return r + 1;
}]]
  local caller_fp = [[static int add2(int v) { return v + 2; }
static int caller(int n)
{
    return apply(add2, n);
}]]
  local t3 = transform(caller_fp, callee_fp, "apply", { { N = 1 } })
  local main3 = "int main(void){ return (caller(4)==7)?0:1; }\n"
  check("case15 function-pointer param keeps its declarator", t3:find("int (*fp)(int) = (add2);", 1, true) ~= nil, t3)
  check("case15 fn-pointer compiles", (compiles(callee_fp .. "\n" .. t3 .. main3, "c15c")))
  check("case15 fn-pointer runs equal", (run_ok(callee_fp .. "\n" .. t3 .. main3, "c15c")))
end

-- Case 16: nested inlining -- inline f, then inline the call to g that f's body
-- brought with it (the cursor-position path a user would take in the view).
do
  local callee_g = [[static int g(int x)
{
    int t = x + 10;
    return t;
}]]
  local callee_f = [[static int f(int x)
{
    int y = g(x) * 2;
    return y + 1;
}]]
  local caller = [[static int caller(int n)
{
    int r = f(n);
    return r;
}]]
  local t = transform(caller, callee_f, "f", { { N = 1 } })
  check("case16 first inline exposed the inner call", t:find("g(", 1, true) ~= nil, t)

  -- Locate the spliced g(...) call and inline it from that cursor position.
  local grow, gcol
  for i, l in ipairs(vim.split(t, "\n", { plain = true })) do
    local c = l:find("g%(")
    if c then
      grow, gcol = i - 1, c - 1
      break
    end
  end
  local t2 = assert(S.inline_at(t, grow, gcol, callee_g, 2))
  local main = "int main(void){ return (caller(5)==31)?0:1; }\n"
  check("case16 nested inline removed the inner call", not t2:find("g(", 1, true), t2)
  check("case16 compiles (nested inline)", (compiles(callee_g .. "\n" .. callee_f .. "\n" .. t2 .. main, "c16")), t2)
  check("case16 runs equal to original", (run_ok(callee_g .. "\n" .. callee_f .. "\n" .. t2 .. main, "c16")))
end

-- Case 17: tab-indented caller -> hoisted lines and wrapping use tabs.
do
  local callee = "static int dbl(int x)\n{\n\tint t = x * 2;\n\treturn t;\n}"
  local caller = "static int caller(int n)\n{\n\treturn dbl(n) + 1;\n}"
  local t = transform(caller, callee, "dbl", { { N = 1 } })
  local main = "int main(void){ return (caller(3)==7)?0:1; }\n"
  check("case17 hoisted lines keep the caller's tab indent", t:find("\n\tint t = ") ~= nil, t)
  check("case17 compiles (tab indent)", (compiles(callee .. "\n" .. t .. main, "c17")))
  check("case17 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c17")))
end

-- Case 18: pointer-returning callee with early returns -> the statement-expr
-- result slot reconstructs the full pointer depth (char **).
do
  local callee = [[static char **pick(char **a, char **b, int c)
{
    if (c)
        return a;
    return b;
}]]
  local caller = [[static char *caller(int c)
{
    static char *x = "x", *y = "y";
    static char *ap[1], *bp[1];
    ap[0] = x; bp[0] = y;
    return pick(ap, bp, c)[0];
}]]
  local t = transform(caller, callee, "pick", { { N = 1 } })
  local main = 'int main(void){ return (strcmp(caller(1),"x")==0 && strcmp(caller(0),"y")==0)?0:1; }\n'
  local src18 = "#include <string.h>\n" .. callee .. "\n" .. t .. "\n" .. main
  check("case18 result slot keeps pointer depth", t:find("char %*%* ?__ie_ret1;") ~= nil, t)
  check("case18 compiles (char ** return)", (compiles(src18, "c18")), t)
  check("case18 runs equal to original", (run_ok(src18, "c18")))
end

-- Case 19: call inside a for-loop initializer. The enclosing "statement" is
-- the for-init declaration, which must NOT be treated as a hoist target: the
-- engine climbs to the for_statement itself, so correct mode renders an
-- in-place statement expression and readable hoists above the whole loop.
do
  local callee = [[static int lim(int x)
{
    int t = x + 1;
    return t & 7;
}]]
  local caller = [[static int caller(int a)
{
    int acc = 0;
    for (int i = lim(a); i > 0; i--)
        acc = acc + 1;
    return acc;
}]]
  local t = transform(caller, callee, "lim", { { N = 1 } })
  local main = "int main(void){ return (caller(6)==7 && caller(-1)==0)?0:1; }\n"
  check("case19 compiles (call in for-init, correct)", (compiles(callee .. "\n" .. t .. main, "c19a")), t)
  check("case19 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c19a")))

  local tr = transform(caller, callee, "lim", { { N = 1, mode = "readable" } })
  check("case19 readable compiles (hoist above the loop)", (compiles(callee .. "\n" .. tr .. main, "c19b")), tr)
  check("case19 readable runs equal", (run_ok(callee .. "\n" .. tr .. main, "c19b")))
  check("case19 readable has no ({...})/goto", not tr:find("({", 1, true) and not tr:find("goto", 1, true), tr)
end

-- Case 20: call in an UNBRACED for body whose argument depends on the loop
-- variable. The body child of a for_statement is a legitimate statement
-- target (the climb must stop there, not at the for), so hoisting wraps the
-- body in a block and stays INSIDE the loop -- hoisting above the loop would
-- lift a loop-variant expression out (and reference `i` before it exists).
-- Pins the `parent:field("body")[1] ~= n` guard in enclosing_statement.
do
  local callee = [[static int lim(int x)
{
    int t = x + 1;
    return t & 7;
}]]
  local caller = [[static int caller(int a)
{
    int acc = 0;
    for (int i = 0; i < 3; i++)
        acc = acc + lim(a + i);
    return acc;
}]]
  local t = transform(caller, callee, "lim", { { N = 1 } })
  local main = "int main(void){ return (caller(1)==(2&7)+(3&7)+(4&7))?0:1; }\n"
  check("case20 compiles (unbraced for body, correct)", (compiles(callee .. "\n" .. t .. main, "c20a")), t)
  check("case20 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c20a")))

  local tr = transform(caller, callee, "lim", { { N = 1, mode = "readable" } })
  check("case20 readable compiles (hoist stays inside the loop)", (compiles(callee .. "\n" .. tr .. main, "c20b")), tr)
  check("case20 readable runs equal", (run_ok(callee .. "\n" .. tr .. main, "c20b")))
end

-- Case 21: a callee whose return expression is already parenthesised must not
-- get a second precedence pair from the pretty printer (`((x + 1))`).
do
  local callee = [[static int wrapped(int x)
{
    int t = x * 2;
    return (t + 1);
}]]
  local caller = [[static int caller(int n)
{
    return wrapped(n) - 1;
}]]
  local t = transform(caller, callee, "wrapped", { { N = 1 } })
  local main = "int main(void){ return (caller(3)==6)?0:1; }\n"
  check(
    "case21 no doubled precedence parens",
    not t:find("((t + 1))", 1, true) and t:find("(t + 1)", 1, true) ~= nil,
    t
  )
  check("case21 compiles", (compiles(callee .. "\n" .. t .. main, "c21")))
  check("case21 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c21")))
end

-- Case 22: a caller whose parse tree has an ERROR ancestor -- a preprocessor
-- conditional that straddles braces, which is ordinary kernel style -- must
-- still get collision renaming. Without it the binding comes out as
-- `int *s = (s);`, and C's declaration-scope rule makes that read the new
-- uninitialised local, not the argument.
do
  local callee = [[static int deref(int *s)
{
    return *s + 1;
}]]
  local caller = [[static int caller(int *s)
{
#ifdef SOMETHING_UNDEFINED
    if (s) {
#endif
    int r = deref(s);
    return r;
}]]
  local t = transform(caller, callee, "deref", { { N = 1 } })
  check(
    "case22 colliding param renamed despite an ERROR ancestor",
    t:find("s__ie1", 1, true) ~= nil and not t:find("int %*s = %(s%);"),
    t
  )

  -- And the same shape without the conditional must be unchanged in kind.
  local plain_caller = [[static int caller(int *s)
{
    int r = deref(s);
    return r;
}]]
  local pt = transform(plain_caller, callee, "deref", { { N = 1 } })
  local main = "int main(void){ int v = 41; return (caller(&v)==42)?0:1; }\n"
  check("case22 control case still renames", pt:find("s__ie1", 1, true) ~= nil, pt)
  check("case22 control compiles", (compiles(callee .. "\n" .. pt .. main, "c22")), pt)
  check("case22 control runs equal to original", (run_ok(callee .. "\n" .. pt .. main, "c22")))
end

-- Case 23: a callee's own local shadows a same-named file-scope function in
-- the caller's file. `rename`'s keys are names the CALLEE declares, so they
-- shadow any same-named caller-scope function -- every occurrence in the
-- body, call position included, must be renamed along with the declaration.
-- Renaming only the declaration and leaving `name(...)` alone is worse than
-- renaming nothing: it deletes the block-scope binding that was shadowing
-- the caller's function, so the untouched call falls through to it instead.
-- An #ifdef straddling braces forces the ERROR-node path, widening the scope
-- to the whole translation unit so the caller's file-scope `add` is visible
-- for collision renaming in the first place -- that is what exposes the bug.
do
  local callee = [[static int apply_add(int x)
{
    int (*add)(int) = add1;
    int r = add(x) + x;
    return r;
}]]

  local caller = [[static int add(int a);
static int add(int a) { return a + 1000; }
static int caller(int x)
{
#ifdef SOMETHING_UNDEFINED
    if (x) {
#endif
    int r = apply_add(x);
    return r;
}
]]
  local t = transform(caller, callee, "apply_add", { { N = 1 } })
  check(
    "case23 renames the call position too, not just the declaration",
    t:find("add__ie1(x__ie1)", 1, true) ~= nil and not t:find("add(x__ie1)", 1, true),
    t
  )

  -- Control: the same callee/caller shape without the #ifdef produces
  -- balanced output regardless of scope -- compile it AND run it, so a wrong
  -- value fails the test, not just a suspicious-looking string in the text.
  local add1_def = "static int add1(int v) { return v + 1; }\n"
  local plain_caller = [[static int add(int a);
static int add(int a) { return a + 1000; }
static int caller(int x)
{
    int r = apply_add(x);
    return r;
}
]]
  local pt = transform(plain_caller, callee, "apply_add", { { N = 1 } })
  local main = "int main(void){ return (caller(5)==11)?0:1; }\n"
  check("case23 control compiles", (compiles(add1_def .. callee .. "\n" .. pt .. main, "c23")), pt)
  check("case23 control runs equal to original", (run_ok(add1_def .. callee .. "\n" .. pt .. main, "c23")))
end

-- Case 24: the call's statement does not start its own line. The text before
-- it is not indentation, and hoisting must not copy it onto every hoisted
-- line -- doing so compiled cleanly and ran the preceding statement once per
-- hoisted line.
do
  local callee = [[static int step(int a, int n)
{
    int t = a + n;
    return t * 2;
}]]
  local caller = [[static int caller(int a)
{
    int acc = 0;
    int hits = 0;
    for (int n = 0; n < 3; n++) {
        hits++; acc += step(a, n);
    }
    return acc * 10 + hits;
}]]
  local t = transform(caller, callee, "step", { { N = 1 } })
  local main = "int main(void){ return (caller(1)==(2+4+6)*10+3)?0:1; }\n"
  check("case24 does not duplicate the preceding statement", select(2, t:gsub("hits%+%+;", "")) == 1, t)
  check("case24 compiles", (compiles(callee .. "\n" .. t .. main, "c24")), t)
  check("case24 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c24")))

  -- A labelled statement is the same shape.
  local labelled = [[static int caller2(int a)
{
    int acc = 0;
    switch (a) {
    case 1: acc = step(a, 2); break;
    default: acc = 0;
    }
    return acc;
}]]
  local t2 = transform(labelled, callee, "step", { { N = 1 } })
  local main2 = "int main(void){ return (caller2(1)==6 && caller2(9)==0)?0:1; }\n"
  check("case24 labelled statement compiles", (compiles(callee .. "\n" .. t2 .. main2, "c24b")), t2)
  check("case24 labelled statement runs equal", (run_ok(callee .. "\n" .. t2 .. main2, "c24b")))
end

-- Case 25: the call sits in a DECLARATION that shares its line with the
-- opening brace, and the declared name shadows an outer one. Such a
-- declaration cannot be hoisted above (there is no line of its own to insert
-- into) -- but it must not be wrapped in a block either: a declaration's scope
-- is the block it sits in, so enclosing it hides the inner `v` from the rest
-- of the body and `return v ...` silently reads the OUTER v. That compiles
-- without a warning, so only running it catches the change. The declaration
-- must render in place instead (statement expression), in both modes.
do
  local callee = [[static int step(int a, int n)
{
    int t = a + n;
    return t * 2;
}]]

  local shadow = [[static int caller(int a)
{
    int v = 50;
    if (a > 0) { int v = step(a, 2); return v * 1000 + 50; }
    return v;
}]]
  local main = "int main(void){ return (caller(1)==6050 && caller(-1)==50)?0:1; }\n"
  local t = transform(shadow, callee, "step", { { N = 1 } })
  check("case25 does not brace-wrap the shadowing declaration", t:find("({", 1, true) ~= nil, t)
  check("case25 compiles", (compiles(callee .. "\n" .. t .. main, "c25a")), t)
  check("case25 runs equal to original (inner v still shadows)", (run_ok(callee .. "\n" .. t .. main, "c25a")), t)

  local tr = transform(shadow, callee, "step", { { N = 1, mode = "readable" } })
  check("case25 readable compiles", (compiles(callee .. "\n" .. tr .. main, "c25b")), tr)
  check(
    "case25 readable runs equal (scope beats the no-({...}) promise)",
    (run_ok(callee .. "\n" .. tr .. main, "c25b")),
    tr
  )

  -- Same shape inside a braced loop body: the declaration shadows an outer
  -- name that the NEXT statement in the same block reads.
  local loop = [[static int caller(int a)
{
    int n = 7; int acc = 0;
    for (int i = 0; i < 3; i++) { int n = step(a, i); acc += n; }
    return acc * 100 + n;
}]]
  local t2 = transform(loop, callee, "step", { { N = 1 } })
  local main2 = "int main(void){ return (caller(1)==1207)?0:1; }\n"
  check("case25 loop-body declaration not brace-wrapped", t2:find("({", 1, true) ~= nil, t2)
  check("case25 loop-body compiles", (compiles(callee .. "\n" .. t2 .. main2, "c25c")), t2)
  check("case25 loop-body runs equal to original", (run_ok(callee .. "\n" .. t2 .. main2, "c25c")), t2)
end

-- Case 26: the statement preceding the call on the same line MUTATES one of
-- the call's arguments. Hoisting the argument binds above the line would
-- capture the argument before the mutation -- and it compiles clean, so the
-- only signal is the value. Pins the `starts_line` half of the hoist guard:
-- with it removed (`braced = parent_t == "compound_statement"`) the binds land
-- above `n++` and caller(0) yields 2 instead of 4.
do
  local callee = [[static int step(int a, int n)
{
    int t = a + n;
    return t * 2;
}]]
  local caller = [[static int caller(int a)
{
    int n = 1;
    int acc = 0;
    n++; acc = step(a, n);
    return acc;
}]]
  local t = transform(caller, callee, "step", { { N = 1 } })
  local main = "int main(void){ return (caller(0)==4 && caller(2)==8)?0:1; }\n"
  check(
    "case26 setup lands after the mutation, not above the line",
    (t:find("n%+%+;") or 0) < (t:find("int t =", 1, false) or 0),
    t
  )
  check("case26 compiles", (compiles(callee .. "\n" .. t .. main, "c26")), t)
  check(
    "case26 runs equal to original (argument read after the mutation)",
    (run_ok(callee .. "\n" .. t .. main, "c26")),
    t
  )
end

-- Case 27: a declaration STARTS its own line (so the narrow `wrap_unsafe`
-- guard does not fire) but its PARENT is not a compound_statement -- it
-- follows a bare `goto` label or a `case` label instead. `braced` is false
-- there too, so the old guard (`not starts_line and t == "declaration"`)
-- let it reach the wrapping printer, which wraps the declaration in `{ }`
-- and reparents its scope exactly like case25's shared-line shape. With a
-- file-scope variable of the same name in view, `return g;` after the
-- synthetic block silently reads the file-scope one instead of the local.
do
  local callee = [[static int step(int a, int n)
{
    int t = a - n;
    return t;
}]]

  local caller_goto = [[static int g = 500;
static int caller(int a)
{
    goto L;
L:
    int g = step(a, 2);
    return g;
}]]
  local t = transform(caller_goto, callee, "step", { { N = 1 } })
  local main = "int main(void){ return (caller(0)==-2)?0:1; }\n"
  check("case27 compiles (declaration after a goto label)", (compiles(callee .. "\n" .. t .. main, "c27a")), t)
  check(
    "case27 runs equal to original (goto-label local still shadows)",
    (run_ok(callee .. "\n" .. t .. main, "c27a")),
    t
  )

  local caller_case = [[static int g = 500;
static int caller(int a)
{
    switch (a) {
    case 0:
        int g = step(a, 2);
        return g;
    default:
        return -1;
    }
}]]
  local t2 = transform(caller_case, callee, "step", { { N = 1 } })
  local main2 = "int main(void){ return (caller(0)==-2 && caller(9)==-1)?0:1; }\n"
  check("case27 compiles (declaration after a case label)", (compiles(callee .. "\n" .. t2 .. main2, "c27b")), t2)
  check(
    "case27 runs equal to original (case-label local still shadows)",
    (run_ok(callee .. "\n" .. t2 .. main2, "c27b")),
    t2
  )
end

-- Case 28: a project-defined macro in type position (zlib's `#define local
-- static`) must not be mistaken for the return type. Tree-sitter reports it
-- as the type and demotes the real one, so the statement-expression's result
-- slot came out as `local __ie_retN;` -- implicit int, and the real type
-- gone. gcc 13 only warns, so this shipped silently.
do
  local callee = [[local int classify(int x)
{
    if (x < 0)
        return -1;
    return x ? 1 : 0;
}]]
  local caller = [[static int caller(int n)
{
    return classify(n) + 5;
}]]
  local t = transform(caller, callee, "classify", { { N = 1 } })
  check(
    "case28 result slot keeps the real type, not the macro",
    t:find("int __ie_ret1;", 1, true) ~= nil and not t:find("local __ie_ret1;", 1, true),
    t
  )

  local prelude = "#define local static\n"
  local main = "int main(void){ return (caller(-3)==4 && caller(0)==5 && caller(9)==6)?0:1; }\n"
  check("case28 compiles", (compiles(prelude .. callee .. "\n" .. t .. main, "c28")), t)
  check("case28 runs equal to original", (run_ok(prelude .. callee .. "\n" .. t .. main, "c28")))
  -- Confirmed experimentally (see task-3-report.md): under -pedantic-errors,
  -- the unfixed engine emitted TWO diagnostics for this input --
  -- `-Wimplicit-int` on `__ie_ret1` (gcc 13's default-build warning, pinned
  -- to an error here) AND `-Wpedantic`'s "ISO C forbids braced-groups within
  -- expressions" for the `({ ... })` statement-expression the engine always
  -- emits. The second one is orthogonal to this defect -- it fires for every
  -- substitution this whole suite produces, fixed or not, because GNU
  -- statement-expressions are never ISO C -- so a plain `shell_error == 0`
  -- check can never pass here regardless of this fix. What this fix removes
  -- is the first diagnostic: assert the implicit-int/`__ie_ret1` complaint is
  -- gone from -pedantic-errors output, not that the whole file is pedantic-clean.
  check(
    "case28 -pedantic-errors no longer flags the result slot as implicit int",
    (function()
      local p = tmp .. "/c28p.c"
      H.writef(p, prelude .. callee .. "\n" .. t .. main)
      local out = vim.fn.system({
        "gcc",
        "-std=gnu11",
        "-fsyntax-only",
        "-pedantic-errors",
        "-Wno-unused-label",
        "-Wno-unused-variable",
        p,
      })
      return not out:find("__ie_ret1", 1, true)
    end)(),
    t
  )
end

-- Case 29 (regression: code review of commit 22befb5, finding 1): the removed
-- `return_type()` branch spliced the return type from an unrelated preceding
-- top-level sibling in callee_src whenever that sibling ended in
-- tree-sitter's synthesized ("missing") ';' -- regardless of whether the
-- callee's OWN field("type") needed any correction at all. Here `bar`'s own
-- type is already the correct type_identifier `MyType` (no ERROR sibling,
-- nothing ambiguous about it); the only reason the old code touched it was
-- that `int FOO` -- a wholly unrelated declaration one line above, with no
-- semantic connection to `bar` -- happens to parse with a missing ';'. The
-- old code took that as license to overwrite `MyType` with `int`, so the
-- statement-expression's result slot became `int __ie_ret1;` and a `long`
-- return value silently truncated. This compiled with zero warnings, which
-- is exactly why the review called for a test that builds AND runs.
--
-- `int FOO` above is a probe shape fed only to the analyzer (via
-- callee_src/`transform`, below) to reproduce the exact tree shape the
-- finding describes; it is not itself valid standalone C, so the compiled
-- program instead defines `bar` cleanly (`callee_def`) -- the transformed
-- caller (`t`) never embeds `int FOO` itself, only text sliced from bar's
-- own signature and body.
do
  local callee_probe = [[int FOO
MyType bar(MyType x)
{
    if (x < 0)
        return -1;
    return x;
}]]
  local caller = [[static long caller(long n)
{
    return bar(n) + 5;
}]]
  local t = transform(caller, callee_probe, "bar", { { N = 1 } })
  check(
    "case29 result slot keeps the callee's own type, not an unrelated sibling's",
    t:find("MyType __ie_ret1;", 1, true) ~= nil and not t:find("int __ie_ret1;", 1, true),
    t
  )

  local callee_def = [[typedef long MyType;
MyType bar(MyType x)
{
    if (x < 0)
        return -1;
    return x;
}]]
  local main = "int main(void){ long v = caller(1234567890123L); return (v == 1234567890128L) ? 0 : 1; }\n"
  check("case29 compiles", (compiles(callee_def .. "\n" .. t .. main, "c29")), t)
  check(
    "case29 runs equal to original (long value not truncated to int)",
    (run_ok(callee_def .. "\n" .. t .. main, "c29")),
    t
  )
end

-- Case 30 (regression: code review of commit 22befb5, finding 2): the
-- KNOWN_LEADING_MACROS allowlist keyed off the literal spelling "local"
-- regardless of context, so it always took the ERROR sibling as the return
-- type whenever field("type") read "local" -- even when `local` is itself a
-- genuine project typedef (`typedef long local;`) and the ERROR sibling is
-- an unrelated trailing decorator macro that expands to nothing
-- (`#define WINAPI`, zlib/Windows calling-convention style). Before commit
-- 22befb5, `local __ie_ret1;` was emitted and compiled correctly (it IS the
-- real type). The unpatched allowlist instead emitted `WINAPI __ie_ret1;`,
-- which fails to compile once WINAPI expands away -- a new compile failure
-- introduced by that commit, not present in its parent (bac2545).
do
  local callee = [[local WINAPI f(int x)
{
    if (x)
        return x;
    return 0;
}]]
  local caller = [[static int caller(int n)
{
    return f(n) + 1;
}]]
  local t = transform(caller, callee, "f", { { N = 1 } })
  check(
    "case30 result slot keeps the real typedef, not the decorator macro",
    t:find("local __ie_ret1;", 1, true) ~= nil and not t:find("WINAPI __ie_ret1;", 1, true),
    t
  )

  local prelude = "typedef long local;\n#define WINAPI\n"
  local main = "int main(void){ return (caller(0)==1 && caller(5)==6) ? 0 : 1; }\n"
  check("case30 compiles", (compiles(prelude .. callee .. "\n" .. t .. main, "c30")), t)
  check("case30 runs equal to original", (run_ok(prelude .. callee .. "\n" .. t .. main, "c30")))
end

-- Case 31 (regression: adversarial re-review of commit 4a71a69's own fix for
-- case30/finding 2): looks_like_bare_decorator's fix treated ANY bare,
-- single, ALL-CAPS token in the ERROR sibling as *proof* it is an unrelated
-- decorator macro (ZEXPORT/WINAPI-style) -- purely by capitalization shape,
-- with no name-list involved. But an ordinary ALL-CAPS single-word typedef
-- is a widespread C convention well outside zlib (Windows SDK style: DWORD,
-- BOOL, U32; embedded/systems style: STATUS, single-letter T), so whenever
-- the real return type happens to be spelled that way, the shape-only guard
-- fired on the wrong side: field("type") = "local" was left untouched
-- instead of being corrected to the real type. Since zlib's own
-- `#define local static` is in scope, `local DWORD f(...)` still compiles
-- clean (`local` -> `static`, implicit-int warning only) and silently
-- truncates/mangles the return value at runtime -- the exact defect class
-- 22befb5/4a71a69 exist to eliminate, reintroduced by the code meant to
-- prevent it, for this input shape.
do
  local callee = [[local DWORD f(int x)
{
    if (x)
        return 5000000000UL;
    return 0;
}]]
  local caller = [[static long caller(int n)
{
    return f(n);
}]]
  local t = transform(caller, callee, "f", { { N = 1 } })
  check(
    "case31 result slot keeps the real ALL-CAPS typedef, not a decorator guess",
    t:find("DWORD __ie_ret1;", 1, true) ~= nil and not t:find("local __ie_ret1;", 1, true),
    t
  )

  local prelude = "typedef unsigned long DWORD;\n#define local static\n"
  local main = "int main(void){ return (caller(1) == 5000000000L) ? 0 : 1; }\n"
  check("case31 compiles", (compiles(prelude .. callee .. "\n" .. t .. main, "c31")), t)
  check(
    "case31 runs equal to original (DWORD-typed return value not truncated)",
    (run_ok(prelude .. callee .. "\n" .. t .. main, "c31"))
  )
end

-- Case 32: case4's collision rename for every declarator shape. The callee's
-- own declaration query only matched plain identifiers and init_declarators,
-- so an uninitialized `int *t;` or `int t[2];` (a pointer/array declarator
-- sitting directly under the declaration) was never renamed and came out as
-- a redeclaration of the caller's parameter `t` -- a compile error.
do
  local shapes = {
    { "ptr", "int *t;", "int v = x * 2; t = &v; return *t + 1;" },
    { "array", "int t[2];", "t[0] = x * 2; return t[0] + 1;" },
    { "ptr-array", "int *t[1];", "int v = x * 2; t[0] = &v; return *t[0] + 1;" },
  }
  local caller = [[static int caller(int t)
{
    int r = g(t);
    return r;
}]]
  local main = "int main(void){ return (caller(10)==21)?0:1; }\n"
  for _, sh in ipairs(shapes) do
    local callee = ("static int g(int x)\n{\n    %s\n    %s\n}"):format(sh[2], sh[3])
    local t = transform(caller, callee, "g", { { N = 1 } })
    local label = "case32 " .. sh[1]
    check(label .. " renamed the colliding local", t:find("t__ie1", 1, true) ~= nil, t)
    check(label .. " compiles", (compiles(callee .. "\n" .. t .. main, "c32" .. sh[1])), t)
    check(label .. " runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c32" .. sh[1])))
  end
end

-- Case 33: tree-sitter-c makes a comment a named child wherever it sits. Read
-- as code, it became the returned expression (`int r = (/* c */);`), a void
-- callee's return value (`void __ie_ret1;`), the declarator inside parens
-- (so the caller's `v` was missed and redeclared), or an argument.
do
  local twice = [[static int twice(int v)
{
    int x = v * 2;
    return /* doubled */ x;
}]]
  local caller = [[static int caller(int n)
{
    int r = twice(n);
    return r;
}]]
  local t = transform(caller, twice, "twice", { { N = 1 } })
  local main = "int main(void){ return (caller(21)==42)?0:1; }\n"
  check("case33 comment before the returned value compiles", (compiles(twice .. "\n" .. t .. main, "c33a")), t)
  check("case33 comment before the returned value runs equal", (run_ok(twice .. "\n" .. t .. main, "c33a")), t)

  local set = [[static void set(int v)
{
    if (v < 0)
        return /* nothing to do */;
    g = v;
}]]
  local set_caller = [[static int caller(int n)
{
    set(n);
    return g;
}]]
  local prelude = "static int g;\n"
  local t2 = transform(set_caller, set, "set", { { N = 1 } })
  local main2 = "int main(void){ g = 3; return (caller(-1)==3 && caller(5)==5)?0:1; }\n"
  check("case33 void callee's commented return has no value", not t2:find("__ie_ret1", 1, true), t2)
  check("case33 void callee compiles", (compiles(prelude .. set .. "\n" .. t2 .. main2, "c33b")), t2)
  check("case33 void callee runs equal", (run_ok(prelude .. set .. "\n" .. t2 .. main2, "c33b")), t2)

  local inc = [[static int inc(int v)
{
    int w = v + 1;
    return w;
}]]
  local id = "#define __stdcall\nstatic int id(int q) { return q; }\n"
  local main3 = "int main(void){ return (caller(41)==49)?0:1; }\n"
  for i, decl in ipairs({ "int (/* fn */ *v)(int) = id;", "int (__stdcall *v)(int) = id;" }) do
    local caller3 = ("static int caller(int n)\n{\n    %s\n    int r = inc(n);\n    return r + v(7);\n}"):format(decl)
    local t3 = transform(caller3, inc, "inc", { { N = 1 } })
    local label = "case33 caller's `" .. decl .. "`"
    check(label .. " renames the parameter", t3:find("int v__ie1 = (n);", 1, true) ~= nil, t3)
    check(label .. " compiles", (compiles(id .. inc .. "\n" .. t3 .. main3, "c33c" .. i)), t3)
    check(label .. " runs equal", (run_ok(id .. inc .. "\n" .. t3 .. main3, "c33c" .. i)), t3)
  end

  local add = "static int add(int a, int b)\n{\n    return a + b;\n}"
  local add_caller = "static int caller(void)\n{\n    int r = add(1, /* two */ 2);\n    return r;\n}"
  local t4, err4 = T.inline_call(add_caller, add, "add", 1, 1)
  check("case33 a comment between arguments is not an argument", t4 ~= nil, tostring(err4))
  local main4 = "int main(void){ return (caller()==3)?0:1; }\n"
  check("case33 commented argument list runs equal", t4 ~= nil and (run_ok(add .. "\n" .. t4 .. main4, "c33d")), t4)
end

-- Case 34: a call that runs never, or only after other code in its
-- statement, must not be hoisted above it. Each site is inlined in turn and
-- the whole program must print what the original prints. Hoisted, sizeof's
-- operand ran, the comma's left side ran too late, and the later declarator
-- read the global a2 instead of the local.
do
  local sites = {
    { "s_sizeof", "int r = sizeof(bump(a));", "r + counter" },
    { "s_sizeof_bare", "int r = sizeof bump(a);", "r + counter" },
    { "s_generic", "int r = _Generic(bump(a), int: 1, default: 0);", "r + counter" },
    { "s_comma", "int r = (counter = 10, bump(a));", "r" },
    { "s_later", "int a2 = a * 2, r = bump(a2);", "r" },
    { "s_typeof", "__typeof__(bump(a) + 1) *p = 0;", "(p == 0) + counter" },
    { "s_constant_p", "int r = __builtin_constant_p(bump(a));", "r + counter" },
    { "s_choose", "int r = __builtin_choose_expr(1, 7, bump(a));", "r + counter" },
    { "s_classify", "int r = __builtin_classify_type(bump(a));", "r + counter" },
    { "s_object_size", "char buf[8];\n    int r = (int)__builtin_object_size(buf + bump(a), 0);", "r + counter" },
    { "s_first", "int r = bump(a), s = 2;", "r + s" },
  }
  local parts = {
    "#include <stdio.h>\nstatic int counter;\nstatic int a2 = 1000;\n",
    "static int bump(int x)\n{\n    counter++;\n    return x + counter;\n}\n",
  }
  local names = {}
  for _, site in ipairs(sites) do
    parts[#parts + 1] = ("static int %s(int a)\n{\n    %s\n    return %s;\n}\n"):format(site[1], site[2], site[3])
    names[#names + 1] = site[1]
  end
  parts[#parts + 1] = "int main(void)\n{\n    int (*sites[])(int) = { "
    .. table.concat(names, ", ")
    .. " };\n"
    .. "    for (unsigned i = 0; i < sizeof sites / sizeof sites[0]; i++) {\n"
    .. '        counter = 0;\n        printf("%u %d\\n", i, sites[i](1));\n    }\n    return 0;\n}\n'
  local program = table.concat(parts)
  local C = require("inline-explorer.csrc")
  local tree = C.parse(program)
  local callee = C.text((C.find_function_def(tree, program, "bump")), program)
  local want = cc.build_run(program, tmp .. "/c34.c", tmp .. "/c34.out")
  local n_calls = #C.find_calls(tree, program, "bump")
  check("case34 original builds, one call per site", want ~= nil and n_calls == #sites, n_calls)
  for occ = 1, n_calls do
    local t, err = T.inline_call(program, callee, "bump", 1, occ)
    local got = t and cc.build_run(t, tmp .. "/c34_" .. occ .. ".c", tmp .. "/c34_" .. occ .. ".out")
    check(("case34 %s prints what the original prints"):format(sites[occ][1]), got ~= nil and got == want, t or err)
  end
end

-- Case 35: names in the caller's function. Renaming only the names it
-- declared missed three silent cases: a hoisted callee local hid the global
-- the caller reads after the call, a parameter named like a global argument
-- bound `int scale = (scale);`, and a callee's local typedef and enumerator
-- captured the caller's later uses. Any name the caller spells is renamed.
do
  local prelude = "typedef char dim;\nenum { SCALE = 3 };\nstatic int limit = 5;\nstatic int scale = 3;\n"
  local clamp = [[static int clamp(int v)
{
    int limit = 100;
    return v > limit ? limit : v;
}]]
  local caller = [[static int caller(int x)
{
    int r = clamp(x) + limit;
    return r;
}]]
  local t = transform(caller, clamp, "clamp", { { N = 1 } })
  local main = "int main(void){ return (caller(50)==55 && caller(500)==105)?0:1; }\n"
  check("case35 hoisted local renamed away from the caller's global", t:find("int limit__ie1 = 100;", 1, true), t)
  check("case35 hoisted local runs equal", (run_ok(prelude .. clamp .. "\n" .. t .. main, "c35a")), t)

  local twice = "static int twice(int scale)\n{\n    return scale * 2;\n}"
  local caller2 = "static int caller(void)\n{\n    int r = twice(scale);\n    return r;\n}"
  local main2 = "int main(void){ return (caller()==6)?0:1; }\n"
  for _, printer in ipairs({ "pretty", "canonical" }) do
    local t2 = assert(T.render(caller2, twice, "twice", 1, 1, printer))
    check(
      "case35 " .. printer .. " binds the argument to a renamed parameter",
      t2:find("int scale__ie1 = (scale);", 1, true),
      t2
    )
    check(
      "case35 " .. printer .. " argument runs equal",
      (run_ok(prelude .. twice .. "\n" .. t2 .. main2, "c35b" .. printer)),
      t2
    )
  end

  local area = [[static int area(int w)
{
    typedef int dim;
    enum { SCALE = 2 };
    dim v = w * SCALE;
    return v;
}]]
  local caller3 = [[static int caller(int w)
{
    int r = area(w);
    dim d = SCALE;
    return r * 10 + (int)sizeof(d) + d;
}]]
  local t3 = transform(caller3, area, "area", { { N = 1 } })
  local main3 = "int main(void){ return (caller(4)==84)?0:1; }\n"
  check(
    "case35 callee typedef and enumerator renamed",
    t3:find("dim__ie1 v", 1, true) and t3:find("SCALE__ie1 = 2", 1, true),
    t3
  )
  check("case35 callee typedef and enumerator run equal", (run_ok(prelude .. area .. "\n" .. t3 .. main3, "c35c")), t3)

  local by = "static int scale_by(int LIMIT)\n{\n    return LIMIT * 2;\n}"
  local caller4 =
    "static int caller(void)\n{\n    enum { LIMIT = 10 };\n    int r = scale_by(3);\n    return r + LIMIT;\n}"
  local t4 = transform(caller4, by, "scale_by", { { N = 1 } })
  local main4 = "int main(void){ return (caller()==16)?0:1; }\n"
  check("case35 parameter named like a caller enumerator compiles", (compiles(by .. "\n" .. t4 .. main4, "c35d")), t4)
  check("case35 parameter named like a caller enumerator runs equal", (run_ok(by .. "\n" .. t4 .. main4, "c35d")), t4)

  -- tree-sitter-c leaves the name of `int ret __maybe_unused = ...;` in an
  -- ERROR node; it is still the name the hoist declares.
  local attr = "#define __maybe_unused __attribute__((unused))\nstatic int ret = 40;\n"
  local doubled = "static int doubled(int x)\n{\n    int ret __maybe_unused = x * 2;\n    return ret + 1;\n}"
  local caller5 = "static int caller(int n)\n{\n    int r = doubled(n);\n    return r + ret;\n}"
  local t5 = transform(caller5, doubled, "doubled", { { N = 1 } })
  local main5 = "int main(void){ return (caller(1)==43)?0:1; }\n"
  check("case35 local named inside an ERROR node renamed", t5:find("int ret__ie1 __maybe_unused", 1, true), t5)
  check(
    "case35 local named inside an ERROR node runs equal",
    (run_ok(attr .. doubled .. "\n" .. t5 .. main5, "c35e")),
    t5
  )
end

-- Case 36: a caller local named like a global the callee reads would capture
-- that read, renamed or not, so the inline is refused (block paste). Only a
-- use no declaration around it binds counts: the callee's own block-local
-- `limit` does not cover the read after its block.
do
  local caller = [[static int caller(int x)
{
    int limit = 7;
    int i = 0;
    return f(x) + limit + i;
}]]
  local callees = {
    { "reads a global", "static int f(int x)\n{\n    return limit + x;\n}" },
    {
      "reads it after its own block-local one",
      "static int f(int x)\n{\n    {\n        int limit = 3;\n        x += limit;\n    }\n    return x + limit;\n}",
    },
  }
  for _, c in ipairs(callees) do
    local new, err = T.inline_call(caller, c[2], "f", 1, 1)
    check(
      "case36 refused: callee " .. c[1],
      new == nil and tostring(err):find("'limit'", 1, true) ~= nil,
      new or tostring(err)
    )
  end
  local attr_caller = caller:gsub("int limit = 7;", "u32 __maybe_unused limit = 7;")
  local new, err = T.inline_call(attr_caller, callees[1][2], "f", 1, 1)
  check(
    "case36 refused: the caller's name sits in an ERROR node",
    new == nil and tostring(err):find("'limit'", 1, true) ~= nil,
    new or tostring(err)
  )

  -- An annotation macro such as zlib's FAR lands in an ERROR node of a
  -- declaration on both sides; the caller does not declare it.
  local far = "#define FAR\nstruct st { int v; };\n"
  local peek = "static int peek(struct st FAR *q)\n{\n    struct st FAR *r = q;\n    return r->v;\n}"
  local far_caller = "static int caller(struct st *s)\n{\n    struct st FAR *p = s;\n    return peek(p) + p->v;\n}"
  local tf, ferr = T.inline_call(far_caller, peek, "peek", 1, 1)
  local far_main = "int main(void){ struct st s = { 4 }; return (caller(&s)==8)?0:1; }\n"
  check("case36 a macro both sides misparse is no reason to refuse", tf ~= nil, tostring(ferr))
  check(
    "case36 misparsed macro runs equal",
    tf ~= nil and (run_ok(far .. peek .. "\n" .. tf .. far_main, "c36far")),
    tf
  )

  -- Without a function node around the call (an #ifdef straddling braces),
  -- the declarations that count are those of the function's ERROR node, not
  -- the file's: a global the callee reads is fine, a local named like it is
  -- not.
  local get = "static int get(void)\n{\n    return limit;\n}"
  local wrapped = "static int limit = 5;\n"
    .. get
    .. "\nstatic int caller(int x)\n{\n#ifdef SOMETHING_UNDEFINED\n    if (x) {\n#endif\n%s    int r = get() + x;\n    return r;\n}\n"
  local tw, werr = T.inline_call(wrapped:format(""), get, "get", 1, 1)
  check("case36 a file-scope global is no reason to refuse", tw ~= nil, tostring(werr))
  local wrapped_main = "int main(void){ return (caller(1)==6)?0:1; }\n"
  check("case36 file-scope global runs equal", tw ~= nil and (run_ok(tw .. wrapped_main, "c36wrap")), tw)
  local tl, lerr = T.inline_call(wrapped:format("    int limit = 7;\n"), get, "get", 1, 1)
  check(
    "case36 refused: a local of a function without a function node",
    tl == nil and tostring(lerr):find("'limit'", 1, true) ~= nil,
    tl or tostring(lerr)
  )

  -- Its own declarations do not count, wherever they sit.
  local own = [[static int f(int x)
{
    int s = 0;
    for (int i = 0; i < x; i++)
        s += i;
    {
        int limit = 2;
        s *= limit;
    }
    return s;
}]]
  local t = transform(caller, own, "f", { { N = 1 } })
  local main = "int main(void){ return (caller(4)==19)?0:1; }\n"
  check(
    "case36 callee's own locals are no reason to refuse",
    (run_ok("static int limit = 5;\n" .. own .. "\n" .. t .. main, "c36")),
    t
  )
end

-- Case 37: a callee local declared in a top-level #if block is hoisted like
-- any other, so it needs the rename too: unrenamed, `int t` shadowed the
-- caller's parameter `t` for the rest of its block, and `sel(t) + t` read the
-- callee's t. A caller's own declarations in #if blocks count as well.
do
  local blocks = {
    { "#ifdef/#else", "#ifdef FAST\n    int t = v * 2;\n#else\n    int t = v * 3;\n#endif" },
    {
      "#if/#elif/#else",
      "#if defined(FAST)\n    int t = v * 2;\n#elif defined(MEDIUM)\n    int t = v * 4;\n#else\n    int t = v * 3;\n#endif",
    },
  }
  local caller = [[static int caller(int t)
{
    int r = 0;
    if (t > 0) {
        r = sel(t) + t;
    }
    return r;
}]]
  local main = "int main(void){ return (caller(2)==9 && caller(-1)==0)?0:1; }\n"
  for i, b in ipairs(blocks) do
    local callee = ("static int sel(int v)\n{\n%s\n    return t + 1;\n}"):format(b[2])
    for _, mode in ipairs({ "correct", "readable" }) do
      local t = transform(caller, callee, "sel", { { N = 1, mode = mode } })
      local label = ("case37 %s local, %s mode,"):format(b[1], mode)
      check(label .. " renamed in every branch", select(2, t:gsub("int t__ie1 = v", "")) == (i + 1), t)
      check(label .. " runs equal", (run_ok(callee .. "\n" .. t .. main, "c37" .. i .. mode)), t)
    end
  end

  -- zlib's fixedtables declares its tables in one branch and #includes them
  -- in the other: the included names cannot be renamed along with the rest.
  local tables = [[static int fixed(int v)
{
#ifdef BUILDFIXED
    static int lenfix[2] = { 1, 2 };
#else
#   include "inffixed.h"
#endif
    return lenfix[v];
}]]
  local tables_caller = "static int caller(int v)\n{\n    int lenfix = fixed(v);\n    return lenfix;\n}"
  local tnew, terr = T.inline_call(tables_caller, tables, "fixed", 1, 1)
  check(
    "case37 refused: an #include in the callee's body",
    tnew == nil and tostring(terr):find("#include", 1, true) ~= nil,
    tnew or tostring(terr)
  )

  local get = "static int get(void)\n{\n    return limit;\n}"
  local caller2 =
    "static int caller(int x)\n{\n#ifdef WIDE\n    long limit = 7;\n#else\n    int limit = 7;\n#endif\n    return get() + limit + x;\n}"
  local new, err = T.inline_call(caller2, get, "get", 1, 1)
  check(
    "case37 refused: the caller declares the name in an #if block",
    new == nil and tostring(err):find("'limit'", 1, true) ~= nil,
    new or tostring(err)
  )
end

-- Case 38: types rebuilt from the callee's declarators. Only the array
-- declarator next to a parameter's name decays (`int m[][4]` bound as
-- `int **m` read the wrong memory), the declarator text keeps an inner const,
-- a parameter's type follows another parameter's rename, the result slot is
-- the callee's declarator around __ie_retN (`char (*f(void))` gave a `char`
-- slot), and the parameters are those next to the name, not those of a
-- returned function pointer. Each site must print what the original prints.
do
  local program = [[#include <stdio.h>
#define ZEXPORT
static int sum_row(int m[][4], int i)
{
    int s = 0;
    for (int j = 0; j < 4; j++)
        s += m[i][j];
    return s;
}
static int count(const char *const argv[])
{
    int k = 0;
    while (argv[k])
        k++;
    return k;
}
static int first(const int a[const 4], int b[static 2])
{
    int s = a[0];
    return s + b[1];
}
static int apply(int fn(int), int x)
{
    if (!fn)
        return -1;
    return fn(x);
}
static int vla_row(int n, int m[][n])
{
    int s = 0;
    for (int j = 0; j < n; j++)
        s += m[1][j];
    return s;
}
static char(*skip(char *s))
{
    if (*s == ' ')
        return s + 1;
    return s;
}
static int (*pick(int k))(int)
{
    (void)k;
    return 0;
}
static char *const keep(char *s)
{
    if (!s)
        return 0;
    return s;
}
static int (*row(int (*g)[4], int i))[4]
{
    if (i < 0)
        return 0;
    return g + i;
}
static const char * ZEXPORT version(void)
{
    if (0)
        return 0;
    return "1.3";
}
static int twice(int v)
{
    return v * 2;
}
int main(void)
{
    int grid[2][4] = {{1, 2, 3, 4}, {5, 6, 7, 8}};
    const char *const names[] = {"a", "b", 0};
    const int arr[4] = {7, 8, 9, 10};
    int n = 4;
    int small[2][2] = {{1, 2}, {3, 4}};
    char text[] = " x";
    int r = sum_row(grid, 1);
    int c = count(names);
    int f = first(arr, grid[0]);
    int a1 = n > 0 ? apply(twice, 5) : 0;
    int a2 = n > 0 ? apply(0, 5) : 0;
    int v = vla_row(2, small);
    char *p = n > 0 ? skip(text) : 0;
    int (*fp)(int) = pick(1);
    char *q = n > 0 ? keep(text) : 0;
    int (*g)[4] = n > 0 ? row(grid, 1) : 0;
    const char *ver = n > 0 ? version() : 0;
    printf("%d %d %d %d %d %d %c %d %c %d %s\n", r, c, f, a1, a2, v, *p, fp == 0, *q, (*g)[0], ver);
    return 0;
}
]]
  local C = require("inline-explorer.csrc")
  local tree = C.parse(program)
  local want = cc.build_run(program, tmp .. "/c38.c", tmp .. "/c38.out")
  check("case38 original builds", want ~= nil)
  local expect = {
    sum_row = "int (*m)[4] = (grid);",
    count = "const char *const *argv = (names);",
    first = "const int *const a = (arr);",
    vla_row = "int (*m)[n__ie1] = (small);",
    skip = "char (*__ie_ret1);",
    pick = "int k = (1);",
    keep = "char *__ie_ret1;",
    row = "int (*__ie_ret1)[4];",
    version = "char * __ie_ret1;",
  }
  for _, fname in ipairs({ "sum_row", "count", "first", "apply", "vla_row", "skip", "pick", "keep", "row", "version" }) do
    local def = C.find_function_def(tree, program, fname)
    check("case38 " .. fname .. " definition found", def ~= nil)
    local callee = def and C.text(def, program) or ""
    for occ = 1, #C.find_calls(tree, program, fname) do
      local label = ("case38 %s (call %d)"):format(fname, occ)
      local t, err = T.inline_call(program, callee, fname, 1, occ)
      if expect[fname] then
        check(
          label .. " writes `" .. expect[fname] .. "`",
          t ~= nil and t:find(expect[fname], 1, true) ~= nil,
          t or err
        )
      end
      local got = t
        and cc.build_run(t, tmp .. "/c38_" .. fname .. occ .. ".c", tmp .. "/c38_" .. fname .. occ .. ".out")
      check(label .. " prints what the original prints", got ~= nil and got == want, t or err)
    end
  end
end

-- Case 39: code tree-sitter cannot parse cleanly. A callee whose `return`
-- error recovery read as a declared name was spliced with that `return`
-- raw, returning from the caller. A misparsed caller statement hid an `if`
-- in a macro, and hoisting ran the callee whatever the condition. A call
-- with an ERROR among its arguments lost one of them.
do
  local stray = [[static int f(int v)
{
    if (!v)
        goto out;
    return 1;
out: __maybe_unused
    return 0;
}]]
  local caller = "static int caller(int v)\n{\n    int r = f(v);\n    return r + 1;\n}"
  local new, err = T.inline_call(caller, stray, "f", 1, 1)
  check(
    "case39 refused: a `return` that is not a return statement",
    new == nil and tostring(err):find("return", 1, true) ~= nil,
    new or tostring(err)
  )

  local prelude = "#define WHEN(c) if (c)\n#define ADD + 1\nstatic int counter;\n"
  local step = [[static int step(int a, int n)
{
    counter++;
    return a - n;
}]]
  local when = [[static int caller(int a)
{
    int x = 0;
    WHEN(a > 0) x = step(a, 2);
    return x * 100 + counter;
}]]
  local main = "int main(void){ counter = 0; if (caller(-1) != 0) return 1; return (caller(5) == 301)?0:1; }\n"
  for _, mode in ipairs({ "correct", "readable" }) do
    local t = transform(when, step, "step", { { N = 1, mode = mode } })
    check("case39 misparsed caller statement, " .. mode .. " mode, stays in place", t:find("({", 1, true) ~= nil, t)
    check(
      "case39 misparsed caller statement, " .. mode .. " mode, runs equal",
      (run_ok(prelude .. step .. "\n" .. t .. main, "c39" .. mode)),
      t
    )
  end

  local added = "static int caller(int a)\n{\n    int r = step(a, 2 ADD);\n    return r;\n}"
  local new2, err2 = T.inline_call(added, step, "step", 1, 1)
  check(
    "case39 refused: a call with an ERROR among its arguments",
    new2 == nil and tostring(err2):find("parse", 1, true) ~= nil,
    new2 or tostring(err2)
  )
end

-- Case 40: a callee written on one line. The body was taken from the start
-- of its first statement's line, which is the signature, so the canonical,
-- readable and pretty forms all pasted `static int twice(int x) { ...`.
do
  local twice = "static int twice(int x) { return x * 2; }"
  local tern = "static int caller(int c, int n)\n{\n    return c ? twice(n) : 0;\n}"
  local t = transform(tern, twice, "twice", { { N = 1 } })
  local main = "int main(void){ return (caller(1, 4)==8 && caller(0, 4)==0)?0:1; }\n"
  check("case40 canonical leaves the signature out", not t:find("static int twice", 1, true), t)
  check("case40 canonical runs equal", (run_ok(twice .. "\n" .. t .. main, "c40a")), t)

  local inc2 = "static int inc2(int x) { int t = x + 1; return t * 2; }"
  local decl = "static int caller(int n)\n{\n    int r = inc2(n);\n    return r;\n}"
  local t2 = transform(decl, inc2, "inc2", { { N = 1 } })
  local main2 = "int main(void){ return (caller(4)==10)?0:1; }\n"
  check("case40 pretty leaves the signature out", not t2:find("static int inc2", 1, true), t2)
  check("case40 pretty runs equal", (run_ok(inc2 .. "\n" .. t2 .. main2, "c40b")), t2)

  local sgn = "static int sgn(int x) { if (x < 0) return -1; return x > 0; }"
  local t3 = transform(decl:gsub("inc2", "sgn"), sgn, "sgn", { { N = 1, mode = "readable" } })
  check("case40 readable leaves the signature out", not t3:find("static int sgn", 1, true), t3)
  check("case40 readable compiles", (compiles(sgn .. "\n" .. t3 .. main2, "c40c")), t3)
end

-- Case 41: a bare `enum { ... };` or `struct s { ... };` keeps its `;` as a
-- token of the block, not of the statement, so hoisted last it came out as
-- `enum { A = 2 }` and the caller did not compile.
do
  local caller = "static int caller(int n)\n{\n    int r = f(n);\n    return r;\n}"
  local main = "int main(void){ return (caller(3)==6)?0:1; }\n"
  for i, body in ipairs({
    "enum { A = 2 };\n    return x * A;",
    "struct pt { int a; };\n    return x * (int)sizeof(struct pt) / 2;",
  }) do
    local callee = ("static int f(int x)\n{\n    %s\n}"):format(body)
    local t = transform(caller, callee, "f", { { N = 1 } })
    local kind = body:match("^%a+")
    check("case41 hoisted bare " .. kind .. " keeps its ;", t:find("}%s*;") ~= nil, t)
    check("case41 hoisted bare " .. kind .. " runs equal", (run_ok(callee .. "\n" .. t .. main, "c41" .. i)), t)
  end
end

-- Case 42: a renamed callee local takes along the uses its declaration
-- binds, no others. Renamed by spelling, a read of the global `acc` ahead of
-- the callee's own `int acc` became `acc__ie1`, which nothing declares
-- there; so did a read past a block-local's block, and one in an earlier
-- declarator of the same declaration. A local whose name tree-sitter-c
-- leaves in an ERROR node is the callee's own too: a caller declaring that
-- name is no reason to refuse.
do
  local prelude = "#define __maybe_unused __attribute__((unused))\nstatic int acc = 5;\n"
  local caller = "static int caller(void)\n{\n    int r = f(acc);\n    return r;\n}"
  local callees = {
    {
      "ahead of the local",
      "static int f(int x)\n{\n    int y = acc + x;\n    int acc = y * 2;\n    return acc;\n}",
      "int y = acc + x;",
      20,
    },
    {
      "in an earlier declarator",
      "static int f(int x)\n{\n    int y = acc + x, acc = y * 2;\n    return acc;\n}",
      "int y = acc + x, acc__ie1 = y * 2;",
      20,
    },
    {
      "past a block-local's block",
      "static int f(int x)\n{\n    {\n        int acc = 1;\n        x += acc;\n    }\n    x += acc;\n    int acc = x * 2;\n    return acc;\n}",
      "x += acc;",
      22,
    },
  }
  for i, c in ipairs(callees) do
    local main = ("int main(void){ return (caller()==%d)?0:1; }\n"):format(c[4])
    for _, printer in ipairs({ "pretty", "canonical" }) do
      local t = assert(S._render(caller, c[2], "f", 1, 1, printer))
      local label = ("case42 global read %s, %s,"):format(c[1], printer)
      check(label .. " keeps its name", t:find(c[3], 1, true) ~= nil, t)
      check(label .. " runs equal", (run_ok(prelude .. c[2] .. "\n" .. t .. main, "c42" .. i .. printer)), t)
    end
  end

  local doubled = "static int doubled(int x)\n{\n    int ret __maybe_unused = x * 2;\n    return ret + 1;\n}"
  local caller2 = "static int caller(int n)\n{\n    int ret = doubled(n);\n    return ret;\n}"
  local t2, err = S.inline_call(caller2, doubled, "doubled", 1, 1)
  local main2 = "int main(void){ return (caller(1)==3)?0:1; }\n"
  check("case42 a local named inside an ERROR node is no reason to refuse", t2 ~= nil, tostring(err))
  check(
    "case42 local named inside an ERROR node, caller declaring it, runs equal",
    t2 ~= nil and (run_ok(prelude .. doubled .. "\n" .. t2 .. main2, "c42e")),
    t2
  )
end

-- A buffer's own tree stands in for parsing the caller text. The inliner
-- hands over the view's tree (kept parsed by its highlighter); the result
-- must be the same as parsing the string, and the caller text must not be
-- string-parsed at all -- on a large file that parse is the cost.
do
  local C = require("inline-explorer.csrc")
  local callee = [[static int g(int x)
{
    return x * 2;
}]]
  local caller = [[static int caller(int t)
{
    int a = g(t);
    int b = g(a);
    return b;
}]]
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(caller, "\n", { plain = true }))
  local tree = vim.treesitter.get_parser(buf, "c"):parse()[1]:root()
  local col = ("    int b = g(a);"):find("g%(") - 1

  local from_string = S.inline_at(caller, 3, col, callee, 1)
  local real = vim.treesitter.get_string_parser
  local parsed = {}
  vim.treesitter.get_string_parser = function(text, ...)
    parsed[#parsed + 1] = text
    return real(text, ...)
  end
  C._parse_cache = {}
  local from_tree = S.inline_at(caller, 3, col, callee, 1, nil, tree)
  local name_from_tree = S.call_name_at(caller, 3, col, tree)
  vim.treesitter.get_string_parser = real
  check("buffer tree: same transform as parsing the text", from_tree ~= nil and from_tree == from_string, from_tree)
  check("buffer tree: call_name_at finds the call", name_from_tree == "g", name_from_tree)
  check(
    "buffer tree: the caller text is never string-parsed",
    not vim.tbl_contains(parsed, caller),
    ("%d string parses"):format(#parsed)
  )
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- The parse cache: a second parse of the same source must not re-parse, and
-- a different source must not be answered from the first. Counted by
-- instrumenting the tree-sitter entry point rather than by timing -- a cache
-- that merely got lucky would pass a timing assertion. Smart-inline used to
-- parse the same caller source three times (call_name_at, inline_at,
-- analyze_call), which on a 15,005-line file measured 154.0ms without the
-- cache against 40.6ms with it; it now hands over the view's own tree, and
-- the cache serves string callers -- the real-source and property suites,
-- which inline hundreds of sites in one text.
do
  local C = require("inline-explorer.csrc")
  local real = vim.treesitter.get_string_parser
  local parses = 0
  vim.treesitter.get_string_parser = function(...)
    parses = parses + 1
    return real(...)
  end

  local src_a = "int f(int a) { return a + 1; }\nint g(void) { return f(1); }\n"
  local src_b = "int h(int a) { return a + 2; }\n"

  C._parse_cache = {}
  parses = 0
  local r1 = C.parse(src_a)
  check("parse cache: first parse of a source reaches tree-sitter", parses == 1, parses)
  local r2 = C.parse(src_a)
  check("parse cache: the same source is not parsed again", parses == 1, parses)
  check("parse cache: the same source yields the same root", r1 == r2)

  C.parse(src_b)
  check("parse cache: a different source is parsed", parses == 2, parses)
  check("parse cache: the first source is still usable after another", C.parse(src_a) == r1 and parses == 2, parses)

  -- Nodes from a cached root must still be usable: a root kept without its
  -- tree would hand back nodes whose tree had been collected.
  collectgarbage("collect")
  collectgarbage("collect")
  local cached_root = C.parse(src_a)
  local calls = C.find_calls(cached_root, src_a, "f")
  check(
    "parse cache: nodes from a cached root survive a collection",
    #calls == 1 and C.text(calls[1]:field("function")[1], src_a) == "f",
    ("#calls=%d"):format(#calls)
  )

  -- Capacity is honoured rather than growing without bound.
  local saved = C._parse_cache_max
  C._parse_cache_max = 2
  C._parse_cache = {}
  for i = 1, 5 do
    C.parse(("int f%d(void) { return %d; }\n"):format(i, i))
  end
  local n = 0
  for _ in pairs(C._parse_cache) do
    n = n + 1
  end
  check("parse cache: bounded by its capacity", n <= 2, ("entries=%d"):format(n))
  C._parse_cache_max = saved
  C._parse_cache = {}

  vim.treesitter.get_string_parser = real
end

-- A target that spans lines, in an `if` without braces, is wrapped in a new
-- block. Its lines after the first keep their place relative to the first:
-- they carry the target's own indent, which the block's indent replaces.
do
  local callee = "static int f(int x)\n{\n    int t = x + 1;\n    return t;\n}"
  local caller = "int g(int a)\n{\n    if (a)\n        a = f(a) +\n            1;\n    return a;\n}"
  for _, mode in ipairs({ "correct", "readable" }) do
    local new = T.inline_call(caller, callee, "f", 1, 1, mode) or ""
    check(
      "wrapped target: a continuation line keeps its place (" .. mode .. ")",
      new:find("\n            a = %(t%) %+\n                1;\n        }") ~= nil,
      new
    )
  end
end

-- A refusal carries a stable code, which the inliner's profile labels use,
-- besides its message: rewording a message used to change the label.
do
  local caller = "int g(int a)\n{\n    return f(a, 1);\n}"
  local _, variadic = T.inline_call(caller, "static int f(int x, ...)\n{\n    return x;\n}", "f", 1, 1)
  local _, arity = T.inline_call(caller, "static int f(int x)\n{\n    return x;\n}", "f", 1, 1)
  local _, none = S.inline_at(caller, 0, 0, "static int f(int x)\n{\n    return x;\n}", 1)
  check("refusal: variadic code", type(variadic) == "table" and variadic.code == "variadic", variadic)
  check("refusal: arity code", type(arity) == "table" and arity.code == "arity", arity)
  check("refusal: no call under the cursor", type(none) == "table" and none.code == "no-call", none)
  check(
    "refusal: reads as its message",
    tostring(variadic):find("variadic function 'f'", 1, true) ~= nil
      and ("x: " .. arity):find("arity mismatch", 1, true),
    tostring(variadic)
  )
end

H.finish("SUBSTITUTE")
