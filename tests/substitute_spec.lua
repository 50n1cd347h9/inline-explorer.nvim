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
    "gcc", "-std=gnu11", "-fsyntax-only",
    "-Wno-unused-label", "-Wno-unused-function", "-Wno-unused-variable", p,
  })
  return vim.v.shell_error == 0, out
end

local function run_ok(src, name)
  local c, exe = tmp .. "/" .. name .. ".c", tmp .. "/" .. name .. ".out"
  writef(c, src)
  local out = vim.fn.system({ "gcc", "-std=gnu11", "-Wno-unused-label", "-Wno-unused-function", c, "-o", exe })
  if vim.v.shell_error ~= 0 then
    return false, out
  end
  vim.fn.system({ exe })
  return vim.v.shell_error == 0, ""
end

local function transform(caller, callee, fname, seq)
  local src = caller
  for _, step in ipairs(seq) do
    local new, err = S.inline_call(src, callee, fname, step.N, step.occ or 1)
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

print("")
print(fails == 0 and "ALL SUBSTITUTE TESTS PASSED" or (fails .. " FAILURE(S)"))
