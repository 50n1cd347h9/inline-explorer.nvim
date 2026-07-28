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
local S = require("inline-explorer.substitute")

if vim.fn.executable("gcc") == 0 then
  print("SKIP: gcc not found")
  return
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local fails = 0

local function writef(path, s)
  local f = assert(io.open(path, "w"))
  f:write(s)
  f:close()
end

local function compiles(src, name)
  local p = tmp .. "/" .. name .. ".c"
  writef(p, src)
  local out = vim.fn.system({
    "gcc", "-std=gnu11", "-fsyntax-only", "-Werror=implicit-function-declaration",
    "-Wno-unused-label", "-Wno-unused-function", "-Wno-unused-variable", p,
  })
  return vim.v.shell_error == 0, out
end

local function run_ok(src, name)
  local c, exe = tmp .. "/" .. name .. ".c", tmp .. "/" .. name .. ".out"
  writef(c, src)
  local out = vim.fn.system({
    "gcc", "-std=gnu11", "-Werror=implicit-function-declaration",
    "-Wno-unused-label", "-Wno-unused-function", c, "-o", exe,
  })
  if vim.v.shell_error ~= 0 then
    return false, out
  end
  vim.fn.system({ exe })
  return vim.v.shell_error == 0, ""
end

local function transform(caller, callee, fname, seq)
  local src = caller
  for _, step in ipairs(seq) do
    local new, err = S.inline_call(src, callee, fname, step.N, step.occ or 1, step.mode)
    assert(new, ("inline_call failed (N=%d): %s"):format(step.N, tostring(err)))
    src = new
  end
  return src
end

local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n----\n" .. detail .. "\n----") or ""))
  end
end

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
  local new = assert(S.inline_in_buffer(caller, 2, col2, callee, 1))
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
  check("case11 readable multi-return has no ({...})/goto", not t:find("({", 1, true) and not t:find("goto", 1, true), t)
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
  local new, err = S.inline_call(caller, variadic, "f", 1, 1)
  check("case14 variadic -> error", new == nil and tostring(err):find("variadic") ~= nil, tostring(err))

  local two_params = "static int f(int a, int b)\n{\n    return a + b;\n}"
  new, err = S.inline_call(caller, two_params, "f", 1, 1)
  check("case14 arity mismatch -> error", new == nil and tostring(err):find("arity") ~= nil, tostring(err))

  local empty = "static int f(int x)\n{\n}"
  new, err = S.inline_call(caller, empty, "f", 1, 1)
  check("case14 empty body -> error", new == nil and tostring(err):find("empty") ~= nil, tostring(err))

  local ok_callee = "static int g(int x)\n{\n    return x;\n}"
  new, err = S.inline_call(caller, ok_callee, "g", 1, 1)
  check("case14 no call in caller -> error", new == nil and tostring(err):find("not found") ~= nil, tostring(err))
end

-- Case 15: parameter bindings reconstruct the declared type: a NULL/0 argument
-- keeps its pointer type, arrays decay to pointers, and exotic declarators
-- (function pointers) fall back to __auto_type.
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
  check("case15 function-pointer param falls back to __auto_type, name kept", t3:find("__auto_type fp =") ~= nil, t3)
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
  local t2 = assert(S.inline_in_buffer(t, grow, gcol, callee_g, 2))
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
  local main = "int main(void){ return (strcmp(caller(1),\"x\")==0 && strcmp(caller(0),\"y\")==0)?0:1; }\n"
  local src18 = "#include <string.h>\n" .. callee .. "\n" .. t .. "\n" .. main
  check("case18 result slot keeps pointer depth", t:find("char %*%* ?__ie_ret1;") ~= nil, t)
  check("case18 compiles (char ** return)", (compiles(src18, "c18")), t)
  check("case18 runs equal to original", (run_ok(src18, "c18")))
end

print("")
print(fails == 0 and "ALL SUBSTITUTE TESTS PASSED" or (fails .. " FAILURE(S)"))
