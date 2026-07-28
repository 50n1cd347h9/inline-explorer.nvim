-- Self-checks for the PBT generator: determinism, structural sanity of the
-- rendered sources, and (with gcc) that ORIGINAL generated programs compile
-- and run -- a generator that emits invalid C would poison every property.
--   nvim --headless --clean -u NONE -c "luafile tests/gen_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local gen = require("tests.lib.gen")

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
    print("FAIL  " .. l .. (d and ("\n----\n" .. tostring(d) .. "\n----") or ""))
  end
end

-- Determinism: same seed, same case, same rendering.
do
  local a = gen.render(gen.case(gen.rng(42)))
  local b = gen.render(gen.case(gen.rng(42)))
  check("determinism: same seed -> identical program", a.program_src == b.program_src)
  local c = gen.render(gen.case(gen.rng(43)))
  check("determinism: different seed -> different program", a.program_src ~= c.program_src)
end

-- Structural sanity over many seeds.
do
  local parse_ok, callpos_ok, ctx_seen = 0, 0, {}
  local N = 100
  for seed = 1, N do
    local case = gen.case(gen.rng(seed))
    ctx_seen[case.ctx] = true
    local rc = gen.render(case)
    local root = vim.treesitter.get_string_parser(rc.program_src, "c"):parse()[1]:root()
    if not root:has_error() then
      parse_ok = parse_ok + 1
    end
    -- (row, col) must sit on the callee's name at a call site.
    local lines = vim.split(rc.caller_src, "\n", { plain = true })
    local line = lines[rc.row + 1] or ""
    if line:sub(rc.col + 1, rc.col + 2) == "f(" then
      callpos_ok = callpos_ok + 1
    end
  end
  check("all rendered programs parse without ERROR nodes", parse_ok == N, parse_ok .. "/" .. N)
  check("call position always lands on 'f('", callpos_ok == N, callpos_ok .. "/" .. N)
  local n_ctx = 0
  for _ in pairs(ctx_seen) do
    n_ctx = n_ctx + 1
  end
  check("all " .. gen.CTX_N .. " contexts reachable in 100 seeds", n_ctx == gen.CTX_N, n_ctx)
end

-- Shrink: dropping everything droppable still yields a valid, renderable case,
-- and a predicate that always fails shrinks to the minimum shape.
do
  local case = gen.case(gen.rng(7))
  local small = gen.shrink(case, function()
    return true
  end)
  check("shrink with always-true predicate reaches 0 stmts", #small.stmts == 0, #small.stmts)
  check("shrink reaches 0 params", #small.params == 0, #small.params)
  check("shrink reaches ctx 1", small.ctx == 1, small.ctx)
  local rc = gen.render(small)
  local root = vim.treesitter.get_string_parser(rc.program_src, "c"):parse()[1]:root()
  check("fully shrunk case still renders parseable C", not root:has_error(), rc.program_src)
end

-- With gcc: original programs must compile AND run (exit 0) for 20 seeds.
if vim.fn.executable("gcc") == 1 then
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local bad
  for seed = 1, 20 do
    local rc = gen.render(gen.case(gen.rng(seed)))
    local cpath, exe = tmp .. "/g" .. seed .. ".c", tmp .. "/g" .. seed .. ".out"
    local fh = assert(io.open(cpath, "w"))
    fh:write(rc.program_src)
    fh:close()
    local out = vim.fn.system({
      "gcc", "-std=gnu11", "-Werror=implicit-function-declaration",
      "-Wno-unused-label", "-Wno-unused-variable", "-Wno-unused-but-set-variable",
      cpath, "-o", exe,
    })
    if vim.v.shell_error ~= 0 then
      bad = "seed " .. seed .. " compile:\n" .. out .. "\n" .. rc.program_src
      break
    end
    vim.fn.system({ exe })
    if vim.v.shell_error ~= 0 then
      bad = "seed " .. seed .. " runtime exit " .. vim.v.shell_error
      break
    end
  end
  check("20 original programs compile and run", bad == nil, bad)
else
  print("SKIP  gcc checks (gcc not found)")
end

print("")
print(fails == 0 and "ALL GEN TESTS PASSED" or (fails .. " FAILURE(S)"))
