-- Generates the C project the benchmark drives clangd against.
--
-- The point of the heavy include chain is that opening ANY of the c*.h /
-- w1.h headers as its own document forces the server to build a non-trivial
-- preamble -- that is the cost that dominates a cold expansion in a real
-- codebase, and without it the cold/warm distinction would sit in the noise.
-- compile_commands.json contains absolute paths, so it is generated here
-- rather than committed.
local M = {}

M.HEAVY_DEPTH = 20 -- headers in the include chain
M.HEAVY_PER_FILE = 200 -- static inline functions per chain header
M.COLD_HEADERS = 24 -- distinct headers, each touched once by the cold scenario
M.WARM_SYMBOLS = 24 -- symbols in the single header the warm scenario reuses

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

function M.generate(dir)
  vim.fn.mkdir(dir, "p")

  -- Include chain: heavy_0.h pulls heavy_1.h ... so any header including
  -- heavy_0.h costs a full preamble build.
  for i = 0, M.HEAVY_DEPTH - 1 do
    local out = { ("#ifndef BENCH_HEAVY_%d_H"):format(i), ("#define BENCH_HEAVY_%d_H"):format(i) }
    if i < M.HEAVY_DEPTH - 1 then
      out[#out + 1] = ('#include "heavy_%d.h"'):format(i + 1)
    end
    for j = 1, M.HEAVY_PER_FILE do
      out[#out + 1] = ("static inline int heavy_%d_%d(int x)\n{\n    int t = x + %d;\n    return t;\n}"):format(i, j, j)
    end
    out[#out + 1] = "#endif"
    write(("%s/heavy_%d.h"):format(dir, i), table.concat(out, "\n") .. "\n")
  end

  -- One symbol per cold header: the scenario touches each header exactly once.
  local cold = {}
  for i = 1, M.COLD_HEADERS do
    cold[i] = ("c%d_f"):format(i)
    write(("%s/c%d.h"):format(dir, i), table.concat({
      ("#ifndef BENCH_C%d_H"):format(i),
      ("#define BENCH_C%d_H"):format(i),
      '#include "heavy_0.h"',
      ("static inline int c%d_f(int x)"):format(i),
      "{",
      ("    int t = x + %d;"):format(i),
      "    return t;",
      "}",
      "#endif",
    }, "\n") .. "\n")
  end

  -- Many symbols in ONE header: after the first touch every further symbol
  -- resolves out of an already-attached document.
  local warm, w = {}, { "#ifndef BENCH_W1_H", "#define BENCH_W1_H", '#include "heavy_0.h"' }
  for i = 1, M.WARM_SYMBOLS do
    warm[i] = ("w1_f%d"):format(i)
    w[#w + 1] = ("static inline int w1_f%d(int x)\n{\n    int t = x + %d;\n    return t;\n}"):format(i, i)
  end
  w[#w + 1] = "#endif"
  write(dir .. "/w1.h", table.concat(w, "\n") .. "\n")

  local main = { '#include "w1.h"' }
  for i = 1, M.COLD_HEADERS do
    main[#main + 1] = ('#include "c%d.h"'):format(i)
  end
  vim.list_extend(main, {
    "",
    "#define BENCH_TWICE(x) ((x) + (x))",
    "",
    "struct bench_pair {",
    "    int lo;",
    "    int hi;",
    "};",
    "",
    -- A definition in the file the user is editing: expanding it must never
    -- be reported as a cold extraction, because nothing new gets opened.
    "static int same_file_helper(int x)",
    "{",
    "    int t = x + 1;",
    "    return t;",
    "}",
    "",
    "static int cold_calls(void)",
    "{",
    "    int acc = 0;",
  })
  for i = 1, M.COLD_HEADERS do
    main[#main + 1] = ("    acc += c%d_f(%d);"):format(i, i)
  end
  vim.list_extend(main, { "    return acc;", "}", "", "static int warm_calls(void)", "{", "    int acc = 0;" })
  for i = 1, M.WARM_SYMBOLS do
    main[#main + 1] = ("    acc += w1_f%d(%d);"):format(i, i)
  end
  vim.list_extend(main, {
    "    return acc;",
    "}",
    "",
    "int main(void)",
    "{",
    "    struct bench_pair pair = { 1, 2 };",
    "    int a = same_file_helper(3);",
    "    int b = BENCH_TWICE(4);",
    "    return cold_calls() + warm_calls() + a + b + pair.lo;",
    "}",
  })
  local main_path = dir .. "/main.c"
  write(main_path, table.concat(main, "\n") .. "\n")

  write(dir .. "/compile_commands.json", vim.json.encode({
    {
      directory = dir,
      file = main_path,
      arguments = { "cc", "-std=gnu11", "-c", main_path, "-o", dir .. "/main.o" },
    },
  }))

  return {
    dir = dir,
    main = main_path,
    cold = cold,
    warm = warm,
    same_file = "same_file_helper",
    macro_call = "BENCH_TWICE",
    struct_name = "bench_pair",
    fn_call = "c1_f",
  }
end

return M
