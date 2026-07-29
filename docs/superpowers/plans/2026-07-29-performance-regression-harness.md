# パフォーマンス退化検知ハーネス 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 利用者が計測作業を一切行わなくても性能退化が自動検知される状態にする。判定は構造不変量が主、実時間は反復統計として記録し限定的にのみ失敗させる。

**Architecture:** `tests/lib/bench.lua` が統計（p50/p90/MAD）・反復ランナー・ノイズフロア測定・プロファイルスパン捕捉を提供する純粋層。`tests/fixtures/bench/gen.lua` が実 clangd 用フィクスチャ（重ヘッダ連鎖 + 呼び出し site + マクロ）を一時ディレクトリに生成。`tests/bench_spec.lua` が実 clangd を起動し、5 シナリオを反復実行して構造不変量を検証、時間をベースラインと比較する。

**Tech Stack:** Lua (Neovim 0.10+), 実 clangd（`IE_BENCH_CLANGD` または PATH）

**Spec:** `docs/superpowers/specs/2026-07-29-performance-regression-harness-design.md`

## Global Constraints

- **プロダクションコード（`lua/`）は変更しない。** 本計画はテストハーネスのみ。既存の `profile.lua` のスパン名に依存する
- 依存するスパン名（現行の実装が出すもの、変更禁止）:
  `locate:ok` / `locate:miss` / `extract:cold` / `extract:warm` / `extract:no-lsp` / `extract:no-capability` / `macro:tweak` / `macro:tweak-miss` / `macro:hover` / `macro:hover-miss` / `substitute:ok` / `substitute:rejected-*` / `rewrite` / `total:expand` / `total:inline-function` / `total:inline-macro` / `total:block-fallback` / `total:expand-failed` / `total:macro-splice-failed`
- 統計は平均を使わない。p50 / p90 / MAD のみ
- 単発測定を書かない。すべて `bench.run` 経由（既定 warmup 3 + reps 15）
- clangd 不在時は `SKIP:` を出して正常終了（既存 spec の流儀）
- 各タスク完了時、既存 8 スイートが緑のままであること:
  `nvim --headless --clean -u NONE -c "luafile tests/<spec>.lua" -c "qa!"`
- nvim が PATH に無い環境では入手済みバイナリのフルパスで実行してよい
- コメントは英語（既存流儀）。コミットメッセージは英語

---

### Task 0: ブランチ作成

- [ ] **Step 1:**

```bash
cd /home/claude/inline-explorer.nvim
git checkout main && git pull && git checkout -b perf-regression-harness
```

（Task 1 の実装者が最初に実行）

---

### Task 1: `tests/lib/bench.lua` + 純粋層の単体 spec

**Files:**
- Create: `tests/bench_lib_spec.lua`
- Create: `tests/lib/bench.lua`

**Interfaces:**
- Consumes: `inline-explorer.profile`（スパン捕捉のみ）
- Produces（Task 3/4 が使う）:
  - `bench.stats(samples) -> { n, min, max, p50, p90, mad }`（空なら `{ n = 0 }`）
  - `bench.run(action, opts) -> samples` — `action(i)` は経過 ms か nil。`opts.warmup`(既定3) 個を破棄、`opts.reps`(既定15) 個を返す
  - `bench.noise_floor(action, opts) -> ms, stats_a, stats_b` — 同一 action の独立2母集団の p50 差
  - `bench.capture(fn, timeout) -> spans` — `fn()` 実行後 `total:` で始まるスパンが出るまで待ち、その回に増えたスパン列を返す
  - `bench.count(spans, pattern) -> n` / `bench.total_ms(spans) -> ms|nil` / `bench.names(spans) -> string`

- [ ] **Step 1: `tests/bench_lib_spec.lua` を作成する（red 先行）**

```lua
-- Unit tests for the benchmark support layer. Pure: no clangd, no LSP.
--   nvim --headless --clean -u NONE -c "luafile tests/bench_lib_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local bench = require("tests.lib.bench")
local profile = require("inline-explorer.profile")

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and ("\n----\n" .. tostring(d) .. "\n----") or ""))
  end
end

-- stats: percentiles, not means. 1..10 has mean 5.5 but p50 5.
do
  local s = bench.stats({ 5, 1, 3, 2, 4, 6, 7, 8, 9, 10 })
  check("stats: n", s.n == 10, s.n)
  check("stats: min/max", s.min == 1 and s.max == 10, vim.inspect(s))
  check("stats: p50 is a percentile, not a mean", s.p50 == 5, s.p50)
  check("stats: p90", s.p90 == 9, s.p90)
  -- A single huge outlier moves a mean a lot and p50 not at all.
  local skewed = bench.stats({ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1000 })
  check("stats: p50 resists a right-tail outlier", skewed.p50 == 1, skewed.p50)
  check("stats: p90 does not hide it entirely", skewed.p90 >= 1, skewed.p90)
  check("stats: mad reported", type(skewed.mad) == "number", vim.inspect(skewed))
  check("stats: empty input is safe", bench.stats({}).n == 0)
end

-- run: warmup samples are discarded, the rest returned in order.
do
  local seen = {}
  local samples = bench.run(function(i)
    seen[#seen + 1] = i
    return i * 10
  end, { warmup = 3, reps = 5 })
  check("run: action called warmup+reps times", #seen == 8, #seen)
  check("run: warmup discarded", #samples == 5 and samples[1] == 40, vim.inspect(samples))
  -- a rep that returns nil is skipped, not counted as zero
  local sparse = bench.run(function(i)
    return (i % 2 == 0) and 1 or nil
  end, { warmup = 0, reps = 4 })
  check("run: nil reps are skipped, not zero-filled", #sparse == 2, vim.inspect(sparse))
end

-- noise_floor: two independent populations of the same action.
do
  local n = 0
  local floor, a, b = bench.noise_floor(function()
    n = n + 1
    return 100 -- perfectly stable action
  end, { warmup = 1, reps = 4 })
  check("noise_floor: zero for a perfectly stable action", floor == 0, floor)
  check("noise_floor: ran two populations", n == 10, n)
  check("noise_floor: returns both populations", a.n == 4 and b.n == 4, vim.inspect({ a, b }))

  local seq, idx = { 10, 10, 10, 10, 30, 30, 30, 30 }, 0
  local floor2 = bench.noise_floor(function()
    idx = idx + 1
    return seq[idx]
  end, { warmup = 0, reps = 4 })
  check("noise_floor: reports the p50 gap between populations", floor2 == 20, floor2)
end

-- capture: collects the spans a call produced, waiting for the total: span.
do
  profile.enabled = true
  profile.logfile = false
  profile.clear()
  profile.start()("stale:before") -- must not be captured

  local spans = bench.capture(function()
    profile.start()("locate:ok")
    profile.start()("extract:warm")
    profile.start()("total:expand")
  end, 1000)
  check("capture: only this call's spans", #spans == 3, bench.names(spans))
  check("capture: excludes earlier spans", bench.count(spans, "^stale") == 0, bench.names(spans))
  check("capture: count by pattern", bench.count(spans, "^extract:") == 1, bench.names(spans))
  check("capture: total_ms reads the total: span", type(bench.total_ms(spans)) == "number", vim.inspect(spans))
  check("capture: names joins for diagnostics", bench.names(spans):find("total:expand", 1, true) ~= nil, bench.names(spans))

  -- No total: span -> capture gives up at the timeout and returns what it saw.
  local partial = bench.capture(function()
    profile.start()("locate:ok")
  end, 300)
  check("capture: returns partial spans when no total: arrives", #partial == 1, bench.names(partial))

  profile.enabled = false
  profile.clear()
end

print("")
print(fails == 0 and "ALL BENCH LIB TESTS PASSED" or (fails .. " FAILURE(S)"))
```

- [ ] **Step 2: red を確認する**

Run: `nvim --headless --clean -u NONE -c "luafile tests/bench_lib_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: `module 'tests.lib.bench' not found` 系のエラー

- [ ] **Step 3: `tests/lib/bench.lua` を作成する**

```lua
-- Benchmark support: percentile statistics, a repetition runner that discards
-- warmup, a noise-floor measurement, and capture of the profile spans one
-- user action produced.
--
-- Deliberately has no mean(): latency distributions are right-skewed, so a
-- mean (and a standard deviation around it) misleads. Everything here is
-- percentile-based.
local profile = require("inline-explorer.profile")

local M = {}

-- Percentile summary of `samples` (a list of numbers, any order).
function M.stats(samples)
  local s = {}
  for i, v in ipairs(samples) do
    s[i] = v
  end
  table.sort(s)
  local n = #s
  if n == 0 then
    return { n = 0 }
  end
  local function q(p)
    return s[math.min(n, math.max(1, math.ceil(p * n)))]
  end
  local p50 = q(0.5)
  local dev = {}
  for i, v in ipairs(s) do
    dev[i] = math.abs(v - p50)
  end
  table.sort(dev)
  return {
    n = n,
    min = s[1],
    max = s[n],
    p50 = p50,
    p90 = q(0.9),
    mad = dev[math.min(n, math.max(1, math.ceil(0.5 * n)))],
  }
end

-- Run `action(i)` warmup+reps times, keeping only the post-warmup results.
-- `action` returns the elapsed milliseconds, or nil for a rep that did not
-- produce a usable measurement (skipped, not counted as zero).
function M.run(action, opts)
  opts = opts or {}
  local warmup = opts.warmup or 3
  local reps = opts.reps or 15
  local out = {}
  for i = 1, warmup + reps do
    local ms = action(i)
    if i > warmup and ms then
      out[#out + 1] = ms
    end
  end
  return out
end

-- The harness's own reproducibility: run the same action as two independent
-- populations and report the gap between their medians. A measured difference
-- smaller than this is not a difference.
function M.noise_floor(action, opts)
  local a = M.stats(M.run(action, opts))
  local b = M.stats(M.run(action, opts))
  if a.n == 0 or b.n == 0 then
    return math.huge, a, b
  end
  return math.abs(a.p50 - b.p50), a, b
end

-- Spans produced by one user action. Every instrumented action ends with a
-- `total:` span, so that is the settle signal; without one we return whatever
-- was recorded before the timeout (the caller can then see it is incomplete).
function M.capture(fn, timeout)
  local n0 = #profile.events
  fn()
  vim.wait(timeout or 20000, function()
    for i = n0 + 1, #profile.events do
      if profile.events[i].name:find("^total:") then
        return true
      end
    end
    return false
  end, 5)
  vim.wait(120) -- let a trailing span scheduled alongside the total: one land
  local out = {}
  for i = n0 + 1, #profile.events do
    out[#out + 1] = profile.events[i]
  end
  return out
end

function M.count(spans, pattern)
  local n = 0
  for _, s in ipairs(spans) do
    if s.name:find(pattern) then
      n = n + 1
    end
  end
  return n
end

function M.total_ms(spans)
  for _, s in ipairs(spans) do
    if s.name:find("^total:") then
      return s.ms
    end
  end
  return nil
end

function M.names(spans)
  local out = {}
  for i, s in ipairs(spans) do
    out[i] = ("%s(%.0fms)"):format(s.name, s.ms)
  end
  return table.concat(out, " ")
end

return M
```

- [ ] **Step 4: green 確認**

Run: `nvim --headless --clean -u NONE -c "luafile tests/bench_lib_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: `ALL BENCH LIB TESTS PASSED`

- [ ] **Step 5: Commit**

```bash
git add tests/lib/bench.lua tests/bench_lib_spec.lua
git commit -m "Add benchmark support: percentiles, warmup, noise floor

Percentile-only by construction -- no mean, because latency distributions
are right-skewed and a mean with a standard deviation around it misleads.
The runner discards warmup reps, and noise_floor runs the same action as
two independent populations so a measured difference can be checked
against the harness's own reproducibility before it is believed."
```

---

### Task 2: フィクスチャ生成器

**Files:**
- Create: `tests/fixtures/bench/gen.lua`
- Modify: `tests/bench_lib_spec.lua`（生成器の自己検査を追記）

**Interfaces:**
- Consumes: なし
- Produces:
  - `fixture.generate(dir) -> meta` — ディレクトリに C プロジェクトを生成し、
    `meta = { main = <path>, cold = { "c1_f", ... }, warm = { "w1_f1", ... }, same_file = "same_file_helper", macro_call = "BENCH_TWICE", struct_name = "bench_pair", fn_call = "c1_f" }` を返す
  - `fixture.HEAVY_DEPTH` / `fixture.HEAVY_PER_FILE` / `fixture.COLD_HEADERS` / `fixture.WARM_SYMBOLS`

- [ ] **Step 1: `tests/bench_lib_spec.lua` の最終 print 前に自己検査を追記する（red）**

```lua
-- Fixture generation is pure file IO and checkable without clangd.
do
  local fixture = require("tests.fixtures.bench.gen")
  local dir = vim.fn.tempname()
  local meta = fixture.generate(dir)

  check("fixture: main.c written", vim.fn.filereadable(meta.main) == 1, meta.main)
  check("fixture: heavy chain written",
    vim.fn.filereadable(dir .. "/heavy_0.h") == 1 and vim.fn.filereadable(dir .. "/heavy_" .. (fixture.HEAVY_DEPTH - 1) .. ".h") == 1)
  check("fixture: enough distinct cold headers for a full run",
    #meta.cold >= 18 and vim.fn.filereadable(dir .. "/c1.h") == 1, #meta.cold)
  check("fixture: enough warm symbols in one header", #meta.warm >= 18, #meta.warm)

  local main = table.concat(vim.fn.readfile(meta.main), "\n")
  check("fixture: one call site per cold symbol on its own line",
    main:find("acc %+= " .. meta.cold[1] .. "%(") ~= nil and main:find("acc %+= " .. meta.cold[18] .. "%(") ~= nil)
  check("fixture: one call site per warm symbol on its own line",
    main:find("acc %+= " .. meta.warm[18] .. "%(") ~= nil)
  check("fixture: same-file definition present", main:find("static int " .. meta.same_file .. "%(") ~= nil)
  check("fixture: macro use present", main:find(meta.macro_call .. "%(") ~= nil)
  check("fixture: struct for the non-inlinable path", main:find("struct " .. meta.struct_name) ~= nil)

  local cc = table.concat(vim.fn.readfile(dir .. "/compile_commands.json"), "\n")
  check("fixture: compile_commands has an absolute file path", cc:find(vim.pesc(meta.main), 1, true) ~= nil, cc:sub(1, 200))
  check("fixture: compile_commands is valid json", pcall(vim.json.decode, cc))

  -- Generation is deterministic: same input, same bytes.
  local dir2 = vim.fn.tempname()
  fixture.generate(dir2)
  check("fixture: generation is deterministic",
    table.concat(vim.fn.readfile(dir .. "/c1.h"), "\n") == table.concat(vim.fn.readfile(dir2 .. "/c1.h"), "\n"))
end
```

Run: `nvim --headless --clean -u NONE -c "luafile tests/bench_lib_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: `module 'tests.fixtures.bench.gen' not found`

- [ ] **Step 2: `tests/fixtures/bench/gen.lua` を作成する**

```lua
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
```

- [ ] **Step 3: green 確認**

Run: `nvim --headless --clean -u NONE -c "luafile tests/bench_lib_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: `ALL BENCH LIB TESTS PASSED`

生成された C が本当にコンパイルできるかも確認する（生成器が壊れた C を吐くと以降すべてが無意味になる）:

```sh
nvim --headless --clean -u NONE -c 'lua vim.opt.rtp:append(".") local d = vim.fn.tempname() local m = require("tests.fixtures.bench.gen").generate(d) print(d) print(vim.fn.system({ "gcc", "-fsyntax-only", "-std=gnu11", m.main })) print("gcc exit=" .. vim.v.shell_error)' -c "qa!"
```
Expected: `gcc exit=0`

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/bench/gen.lua tests/bench_lib_spec.lua
git commit -m "Add the benchmark fixture generator

A heavy include chain behind every header, so opening one as its own
document costs a real preamble build -- without that the cold/warm
distinction the harness asserts on would sit inside the noise. Absolute
paths mean compile_commands.json is generated, never committed."
```

---

### Task 3: `tests/bench_spec.lua` — 実 clangd + 構造不変量（判定の主軸）

**Files:**
- Create: `tests/bench_spec.lua`

**Interfaces:**
- Consumes: `tests.lib.bench`, `tests.fixtures.bench.gen`, `inline-explorer.{view,expander,inliner,profile,resolver}`
- Produces: なし（Task 4 が同ファイルに時間レポートを追記する）

- [ ] **Step 1: `tests/bench_spec.lua` を作成する**

```lua
-- Performance regression harness. Drives the REAL user actions against a real
-- clangd and asserts structural invariants -- how many round trips an action
-- costs, and whether the attach cache is doing its job. These hold regardless
-- of machine speed, which is why they are the pass/fail gate; timings are
-- reported separately (see the report section below).
--
--   nvim --headless --clean -u NONE -c "luafile tests/bench_spec.lua" -c "qa!"
--
-- Env: IE_BENCH_CLANGD (clangd path), IE_BENCH_REPS, IE_BENCH_WARMUP
local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":h:h")
vim.opt.rtp:append(root)

local bench = require("tests.lib.bench")
local fixture = require("tests.fixtures.bench.gen")
local profile = require("inline-explorer.profile")
local view = require("inline-explorer.view")
local expander = require("inline-explorer.expander")
local inliner = require("inline-explorer.inliner")
local history = require("inline-explorer.history")
local resolver = require("inline-explorer.resolver")

local clangd = os.getenv("IE_BENCH_CLANGD") or "clangd"
if vim.fn.executable(clangd) == 0 then
  print("SKIP: clangd not found (set IE_BENCH_CLANGD)")
  return
end

local REPS = tonumber(os.getenv("IE_BENCH_REPS") or "") or 15
local WARMUP = tonumber(os.getenv("IE_BENCH_WARMUP") or "") or 3

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and ("\n----\n" .. tostring(d) .. "\n----") or ""))
  end
end

require("inline-explorer").setup({ profile = true })
profile.logfile = false -- the report is the output; no user log from a bench

-- ---------------------------------------------------------------------------
-- Fixture + server
-- ---------------------------------------------------------------------------
local dir = vim.fn.tempname()
local meta = fixture.generate(dir)

vim.cmd.edit(meta.main)
local sbuf = vim.api.nvim_get_current_buf()
vim.lsp.start({ name = "clangd", cmd = { clangd, "--background-index" }, root_dir = dir })
vim.wait(15000, function()
  return #vim.lsp.get_clients({ bufnr = sbuf, name = "clangd" }) > 0
end, 50)
if #vim.lsp.get_clients({ bufnr = sbuf, name = "clangd" }) == 0 then
  print("SKIP: clangd did not attach")
  return
end

-- Wait until the background index can answer for a symbol that lives in a
-- header -- that is the precondition for every scenario below.
local indexed = false
for _ = 1, 120 do
  local done = false
  resolver.locate(meta.warm[1], sbuf, function(loc)
    indexed, done = loc ~= nil, true
  end)
  vim.wait(3000, function()
    return done
  end, 20)
  if indexed then
    break
  end
  vim.wait(500)
end
if not indexed then
  print("SKIP: clangd index never answered workspace/symbol")
  return
end

local vbuf = view.open()
local st = view.current()

-- ---------------------------------------------------------------------------
-- Driving helpers
-- ---------------------------------------------------------------------------

-- Put the cursor on the first occurrence of `pat` in the view. Returns false
-- when the pattern is absent (a scenario that cannot run must say so rather
-- than silently measure the wrong thing).
local function goto_pattern(pat)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(vbuf, 0, -1, false)) do
    local c = l:find(pat)
    if c then
      vim.api.nvim_win_set_cursor(0, { i, c - 1 })
      return true
    end
  end
  return false
end

-- Run one action on `pat` and hand back its spans, leaving the view as it was
-- (every action mutates the buffer; undo keeps reps independent).
local function act(pat, fn)
  if not goto_pattern(pat) then
    return nil
  end
  local spans = bench.capture(fn, 30000)
  history.undo()
  return spans
end

local function expand_on(pat)
  return act(pat, expander.expand)
end
local function inline_on(pat)
  return act(pat, inliner.smart)
end

-- ---------------------------------------------------------------------------
-- Structural invariants -- the gate
-- ---------------------------------------------------------------------------
print("=== structural invariants ===")

-- 1. One expansion costs exactly one locate and one extract.
do
  local spans = expand_on(meta.cold[1] .. "%(")
  check("one expand = one locate + one extract",
    spans ~= nil and bench.count(spans, "^locate:") == 1 and bench.count(spans, "^extract:") == 1,
    spans and bench.names(spans))
end

-- 2. A second symbol from an already-attached header is warm, not cold.
do
  local first = expand_on(meta.warm[1] .. "%(")
  local second = expand_on(meta.warm[2] .. "%(")
  check("first touch of a header is cold",
    first ~= nil and bench.count(first, "^extract:cold") == 1, first and bench.names(first))
  check("second symbol from the same header is warm",
    second ~= nil and bench.count(second, "^extract:warm") == 1, second and bench.names(second))
end

-- 3. Falling back to block-paste must not re-resolve: the inliner already has
--    the body and hands it over.
do
  local spans = inline_on("struct " .. meta.struct_name)
  check("block fallback happened",
    spans ~= nil and bench.count(spans, "^total:block%-fallback") == 1, spans and bench.names(spans))
  check("block fallback costs no second lookup",
    spans ~= nil and bench.count(spans, "^locate:") == 1 and bench.count(spans, "^extract:") == 1,
    spans and bench.names(spans))
end

-- 4. A definition in the file being edited opens nothing new.
do
  local spans = expand_on(meta.same_file .. "%(3%)")
  check("same-file definition is never a cold extraction",
    spans ~= nil and bench.count(spans, "^extract:cold") == 0 and bench.count(spans, "^extract:") == 1,
    spans and bench.names(spans))
end

-- 5. A macro resolves through the tweak; the hover scrape is a fallback for
--    servers that cannot do better, and must not be reached here.
do
  local spans = inline_on(meta.macro_call .. "%(")
  check("macro uses the ExpandMacro tweak",
    spans ~= nil and bench.count(spans, "^macro:tweak$") == 1, spans and bench.names(spans))
  check("macro does not fall back to hover scraping",
    spans ~= nil and bench.count(spans, "^macro:hover") == 0, spans and bench.names(spans))
end

print("")
print(fails == 0 and "ALL BENCH TESTS PASSED" or (fails .. " FAILURE(S)"))
```

- [ ] **Step 2: 実行して全不変量が緑になることを確認する**

Run: `IE_BENCH_CLANGD=<clangd path> nvim --headless --clean -u NONE -c "luafile tests/bench_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n' | grep -E "PASS|FAIL|SKIP|PASSED|FAILURE"`
Expected: 8 個の PASS と `ALL BENCH TESTS PASSED`

FAIL が出た場合は、まず不変量の記述ではなく **実装が本当にその性質を持っているか** を疑うこと（このハーネスの目的は実装の退化検知であり、テストを実装に合わせて緩めるのは本末転倒）。ただし `goto_pattern` がパターンを見つけられない等のハーネス側の不具合であれば直してよい。

- [ ] **Step 3: 既存 8 スイートが緑のままか確認する**

Run（8本）: `gen_spec` / `properties_spec` / `pbt_spec` / `ir_spec` / `substitute_spec` / `macro_spec` / `resolver_spec` / `expander_spec`
Expected: すべて `ALL ... PASSED`

- [ ] **Step 4: Commit**

```bash
git add tests/bench_spec.lua
git commit -m "Assert performance invariants against a real clangd

Five structural properties that hold regardless of machine speed: an
expansion costs exactly one locate and one extract, a second symbol from
an attached header is warm, a block fallback does not re-resolve, a
same-file definition opens nothing, and a macro resolves through the
tweak rather than the hover scrape. These are the gate; timings are
reported but rarely fail (CI wall-clock varies 2-3x)."
```

---

### Task 4: 反復計測・ノイズフロア・ベースライン比較

**Files:**
- Modify: `tests/bench_spec.lua`（最終 print の前にレポート部を追加）
- Create: `tests/bench_baseline.json`

**Interfaces:**
- Consumes: Task 1 の `bench.run` / `bench.stats` / `bench.noise_floor`
- Produces: なし

- [ ] **Step 1: `tests/bench_spec.lua` の最終 print の直前にレポート部を追加する**

```lua
-- ---------------------------------------------------------------------------
-- Timing -- reported always, fails only on a change bigger than the noise
-- ---------------------------------------------------------------------------
print("")
print("=== timing (p50/p90 over " .. REPS .. " reps, " .. WARMUP .. " discarded) ===")

-- Each scenario is its own population; cold and warm are never mixed. The
-- cold reps walk distinct headers (touching each exactly once) rather than
-- restarting the server, which is cheaper and means the same thing.
local scenarios = {
  {
    name = "expand:cold",
    action = function(i)
      local sym = meta.cold[((i - 1) % #meta.cold) + 1]
      local spans = expand_on(sym .. "%(")
      if spans and bench.count(spans, "^extract:cold") == 1 then
        return bench.total_ms(spans)
      end
      return nil -- not actually cold: do not pollute the population
    end,
  },
  {
    name = "expand:warm",
    action = function(i)
      local sym = meta.warm[((i - 1) % #meta.warm) + 1]
      local spans = expand_on(sym .. "%(")
      if spans and bench.count(spans, "^extract:warm") == 1 then
        return bench.total_ms(spans)
      end
      return nil
    end,
  },
  {
    name = "inline:function",
    action = function()
      local spans = inline_on(meta.fn_call .. "%(")
      return spans and bench.count(spans, "^total:inline%-function") == 1 and bench.total_ms(spans) or nil
    end,
  },
  {
    name = "inline:macro",
    action = function()
      local spans = inline_on(meta.macro_call .. "%(")
      return spans and bench.count(spans, "^total:inline%-macro") == 1 and bench.total_ms(spans) or nil
    end,
  },
  {
    name = "expand:same-file",
    action = function()
      local spans = expand_on(meta.same_file .. "%(3%)")
      return spans and bench.total_ms(spans) or nil
    end,
  },
}

local measured = {}
for _, sc in ipairs(scenarios) do
  measured[sc.name] = bench.stats(bench.run(sc.action, { warmup = WARMUP, reps = REPS }))
end

-- The harness's own reproducibility, measured now rather than assumed: the
-- same scenario run as two independent populations. A difference smaller
-- than this is not a difference.
local noise = bench.noise_floor(scenarios[2].action, { warmup = WARMUP, reps = REPS })

print(("%-18s %4s %9s %9s %9s %9s"):format("scenario", "n", "p50", "p90", "mad", "max"))
print(string.rep("-", 64))
for _, sc in ipairs(scenarios) do
  local s = measured[sc.name]
  if s.n > 0 then
    print(("%-18s %4d %8.1fms %8.1fms %8.1fms %8.1fms"):format(sc.name, s.n, s.p50, s.p90, s.mad, s.max))
  else
    print(("%-18s %4d  (no usable samples)"):format(sc.name, 0))
  end
end
print(("noise floor: %.1fms (p50 gap between two runs of expand:warm)"):format(noise))

-- Baseline comparison. The tolerance is derived from the measured noise, not
-- hardcoded, so a slow CI runner widens the band instead of failing.
local baseline_path = root .. "/tests/bench_baseline.json"
if os.getenv("IE_BENCH_WRITE_BASELINE") == "1" then
  local out = { recorded = os.date("%Y-%m-%d"), noise_floor_ms = noise, scenarios = {} }
  for name, s in pairs(measured) do
    if s.n > 0 then
      out.scenarios[name] = { p50 = s.p50 }
    end
  end
  local f = assert(io.open(baseline_path, "w"))
  f:write(vim.json.encode(out))
  f:close()
  print("baseline written: " .. baseline_path)
elseif vim.fn.filereadable(baseline_path) == 1 then
  local base = vim.json.decode(table.concat(vim.fn.readfile(baseline_path), "\n"))
  print("")
  print("=== vs baseline recorded " .. tostring(base.recorded) .. " ===")
  if noise > (base.noise_floor_ms or 0) * 4 + 20 then
    print(("WARN  this run is noisy (%.1fms vs %.1fms when recorded); timings below are unreliable")
      :format(noise, base.noise_floor_ms or 0))
  end
  for name, s in pairs(measured) do
    local b = base.scenarios and base.scenarios[name]
    if b and s.n > 0 then
      local tolerance = math.max(3 * noise, b.p50 * 0.25)
      local delta = s.p50 - b.p50
      local line = ("%-18s %8.1fms -> %8.1fms  (%+.1fms, tolerance %.1fms)"):format(name, b.p50, s.p50, delta, tolerance)
      if delta > tolerance then
        fails = fails + 1
        print("FAIL  " .. line)
      else
        print("ok    " .. line)
      end
    end
  end
else
  print("")
  print("no baseline yet: re-run with IE_BENCH_WRITE_BASELINE=1 to record one")
end
```

- [ ] **Step 2: 実行してレポートが出ることを確認する**

Run: `IE_BENCH_CLANGD=<clangd path> nvim --headless --clean -u NONE -c "luafile tests/bench_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n' | tail -25`
Expected: 5 シナリオの p50/p90/mad/max、ノイズフロア、`no baseline yet` の行、そして `ALL BENCH TESTS PASSED`

**確認すべきこと**: `expand:cold` の p50 が `expand:warm` の p50 より明確に大きいこと。そうでなければフィクスチャの重ヘッダ連鎖が軽すぎるので `fixture.HEAVY_DEPTH` / `HEAVY_PER_FILE` を増やす。またノイズフロアが `expand:warm` の p50 を超えている場合、その計測は無意味なので同様に調整すること。

- [ ] **Step 3: ベースラインを記録して commit する**

```sh
IE_BENCH_WRITE_BASELINE=1 IE_BENCH_CLANGD=<clangd path> nvim --headless --clean -u NONE -c "luafile tests/bench_spec.lua" -c "qa!"
```

続けて比較モードで再実行し、記録したばかりのベースラインに対して緑になることを確認する:

Run: `IE_BENCH_CLANGD=<clangd path> nvim --headless --clean -u NONE -c "luafile tests/bench_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n' | tail -12`
Expected: `=== vs baseline recorded ... ===` の下がすべて `ok`、`ALL BENCH TESTS PASSED`

- [ ] **Step 4: Commit**

```bash
git add tests/bench_spec.lua tests/bench_baseline.json
git commit -m "Report bench timings as percentiles against a measured baseline

Fifteen reps per scenario with three discarded, p50/p90/MAD rather than
a mean, and cold and warm kept as separate populations. The regression
tolerance comes from a noise floor the harness measures on the spot --
the p50 gap between two independent runs of the same scenario -- so a
slow runner widens the band instead of failing, and a run noisier than
the one that recorded the baseline says so."
```

---

### Task 5: 検知力の実証 + CI + ドキュメント

**Files:**
- Modify: `.github/workflows/test.yml`
- Modify: `README.md`
- Create: `.superpowers/sdd/bench-detection-report.md`（検証記録、リポジトリには commit しない）

**Interfaces:** なし

このタスクの目的は、ハーネスが**実際に退化を捕まえること**を実証することである。緑になるハーネスを書くのは簡単だが、赤にならないハーネスは無価値である。

- [ ] **Step 1: 三つの既知の退化を一時的に再導入し、それぞれが赤になることを確認する**

以下を **一つずつ** 適用し、そのつど `tests/bench_spec.lua` を実行して、どの不変量が FAIL になるかを記録する。確認後は必ず `git checkout -- lua/` で元に戻すこと。

(a) 二重取得の再導入 — `lua/inline-explorer/inliner.lua` の `block_fallback` を
`expander.expand(prefetched)` ではなく引数なしの `expander.expand()` を呼ぶよう戻す。
Expected: 不変量 3「block fallback costs no second lookup」が FAIL（locate/extract が 2 になる）

(b) attach キャッシュの無効化 — `lua/inline-explorer/resolver.lua` の
`M._attach_cache_n` を `0` にする。
Expected: 不変量 2「second symbol from the same header is warm」が FAIL、
かつ `expand:warm` の p50 が `expand:cold` 並みに上がる

(c) cold ラベルの退化 — `lua/inline-explorer/resolver.lua` の
`local stage = #newly_attached > 0 and "extract:cold" or "extract:warm"` を
`local stage = M._attach_cache[target] and "extract:warm" or "extract:cold"` に戻す。
Expected: 不変量 4「same-file definition is never a cold extraction」が FAIL

- [ ] **Step 2: 検証結果を記録する**

`.superpowers/sdd/bench-detection-report.md` に、(a)(b)(c) それぞれについて
「どの check が FAIL したか」と実際の出力行を記録する。三つとも赤にならなかった
場合は、そのハーネスは目的を果たしていないので Task 3/4 に戻ること。

- [ ] **Step 3: `lua/` が元に戻っていることを確認する**

Run: `git status --porcelain lua/`
Expected: 出力なし

Run: `IE_BENCH_CLANGD=<clangd path> nvim --headless --clean -u NONE -c "luafile tests/bench_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: `ALL BENCH TESTS PASSED`

- [ ] **Step 4: CI にベンチジョブを追加する**

`.github/workflows/test.yml` の末尾に追記する（既存の 2 ジョブは変更しない）:

```yaml
  perf-regression:
    runs-on: ubuntu-latest
    if: github.event_name == 'push'
    steps:
      - uses: actions/checkout@v4
      - name: Install Neovim
        run: |
          curl -sL https://github.com/neovim/neovim/releases/download/v0.11.3/nvim-linux-x86_64.tar.gz | tar xz
          echo "$PWD/nvim-linux-x86_64/bin" >> "$GITHUB_PATH"
      - name: Install clangd
        run: |
          curl -sL -o clangd.zip https://github.com/clangd/clangd/releases/download/18.1.3/clangd-linux-18.1.3.zip
          unzip -q clangd.zip
          echo "IE_BENCH_CLANGD=$PWD/clangd_18.1.3/bin/clangd" >> "$GITHUB_ENV"
      - name: Benchmark support unit tests
        run: |
          out=$(nvim --headless --clean -u NONE -c "luafile tests/bench_lib_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n')
          echo "$out"
          echo "$out" | grep -q "ALL BENCH LIB TESTS PASSED" || { echo "FAILED"; exit 1; }
      - name: Performance regression harness
        run: |
          out=$(nvim --headless --clean -u NONE -c "luafile tests/bench_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n')
          echo "$out"
          echo "$out" | grep -Eq "ALL BENCH TESTS PASSED|SKIP:" || { echo "FAILED"; exit 1; }
          if echo "$out" | grep -q "FAILURE"; then echo "FAILED"; exit 1; fi
```

あわせて既存の `fast-suites` ジョブのスイート一覧に `bench_lib_spec` を追加する
（純粋層なので clangd 不要、毎 push で回す価値がある）:

```yaml
          for s in gen_spec properties_spec pbt_spec ir_spec substitute_spec macro_spec resolver_spec expander_spec bench_lib_spec; do
```

- [ ] **Step 5: README に追記する**

`## Measuring latency` 節の末尾（`## Buildroot / cross-compiled kernel` の直前）に追記する:

```markdown
### Regression testing

Latency is not left to whoever happens to notice. `tests/bench_spec.lua`
drives the real actions against a real clangd on a generated fixture and
asserts the properties that hold regardless of machine speed — an expansion
costs exactly one lookup and one extraction, a second symbol from an
already-open header is warm, a block-paste fallback does not re-resolve, a
definition in the current file opens nothing, and a macro resolves through the
tweak rather than the hover scrape. Those are the pass/fail gate.

Timings are reported alongside as percentiles (p50/p90/MAD over 15 reps with 3
discarded, cold and warm kept as separate populations) and compared against
`tests/bench_baseline.json`. The tolerance is derived from a noise floor the
harness measures on the spot — the median gap between two independent runs of
the same scenario — so a slow CI runner widens the band rather than failing,
and a run noisier than the baseline's says so instead of pretending.

```sh
IE_BENCH_CLANGD=/path/to/clangd \
  nvim --headless --clean -u NONE -c "luafile tests/bench_spec.lua" -c "qa!"
```

`IE_BENCH_REPS` / `IE_BENCH_WARMUP` adjust the sample size;
`IE_BENCH_WRITE_BASELINE=1` records a new baseline.
```

- [ ] **Step 6: 最終確認**

既存 8 スイート + `bench_lib_spec` + `bench_spec` をすべて実行し、緑を確認する。

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/test.yml README.md
git commit -m "Run the perf harness in CI; document what it guarantees

Also records that the harness actually catches the three regressions it
was built for: re-introducing the double fetch, disabling the attach
cache, and restoring the old cold-label rule each turn a specific
invariant red (see the detection report)."
```

---

## Self-Review 済み事項

- Spec の受け入れ条件 4 点すべてに対応: 構造不変量 5 つ = Task 3、修正前コードで赤になることの実証 = Task 5 Step 1-2、p50/p90/MAD + ノイズフロア = Task 4、CI ジョブ = Task 5 Step 4
- 型整合: `bench.*` の API は Task 1（実装 + spec）と Task 3/4（消費側）で同一。`fixture.generate` の返す `meta` のキーは Task 2 と Task 3/4 で同一
- 統計の規約違反がないこと: `mean` はどこにも登場しない。単発測定は Task 3 の構造アサーション（時間を測っていない）のみ
- `lua/` を変更しないという制約は Task 5 Step 1 の一時的な revert のみ例外とし、Step 3 で元に戻ったことを確認する
- プレースホルダなし。全ステップに実コード・実コマンド・期待出力あり
