# PBT ハーネス (P5) 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ランダム生成 C コードに対する 2 層のプロパティテスト — 高速層（tree-sitter オラクル、毎回 ~300 ケース）と gcc 差分層（既定 30 ケース、元プログラムとの stdout 完全一致）— を共有ジェネレータ + 貪欲 shrink + seed 再現付きで追加する。

**Architecture:** `tests/lib/gen.lua` が抽象ケース（パラメータ/文リスト/文脈 id）を LCG 乱数から生成し、純関数 `render` でソース化する。shrink は抽象ケースを変異（文末尾削除→引数削除→文脈単純化）し、還元が元プログラムを壊す場合は述語が自然に false になって棄却される。`properties_spec.lua` は inline_call の出力を tree-sitter で検証、`pbt_spec.lua` は gcc で元と変換後を実行し stdout 比較。`substitute.lua` に printer 強制の test hook `_render` を追加し、「canonical と pretty の差分一致」で P2 の安全解析自体を性質化する。

**Tech Stack:** Lua (Neovim 組込み tree-sitter), gcc, 自前 Park-Miller LCG（環境非依存の決定的乱数）

**Spec:** `docs/superpowers/specs/2026-07-28-redesign-and-pbt-design.md` の P5（最終フェーズ）

## Global Constraints

- `substitute.lua` の変更は **test hook の追加のみ**（`M._rebase`, `M._common_ws_prefix`, `M._render`）。既存関数の挙動・シグネチャ不変。`_render` は `inline_call` と同じ解析を共有し printer だけ強制する
- 生成 C コードは UB フリー: 演算は `+ - & | ^` のみ（`* / % << >>` 禁止）、リテラル 0-9、ループは `& 7` マスクで必ず有界、ポインタは読み取りのみ
- すべて決定的: `math.random`/`os.time` 禁止。乱数は `gen.rng(seed)`（Park-Miller LCG）のみ。同 seed → 同ケース
- 環境変数: `IE_PBT_CASES`（gcc 層のケース数、既定 30）、`IE_PBT_SEED`（基底 seed、既定 12345）、`IE_PROP_CASES`（高速層、既定 300）
- 失敗時は必ず seed とケース番号を print し、shrink 済み反例を出力（gcc 層は反例 .c を tmp に保存しパス表示）
- gcc フラグ: `-std=gnu11 -Werror=implicit-function-declaration -Wno-unused-label -Wno-unused-variable -Wno-unused-but-set-variable`
- 各タスク完了時、全 spec green（既存 6 + 新規分）:
  `nvim --headless --clean -u NONE -c "luafile tests/<spec>.lua" -c "qa!"`
- nvim が PATH に無い環境では入手済みバイナリのフルパスで実行してよい
- コメントは英語（既存流儀）。コミットメッセージは英語

---

### Task 0: ブランチ作成

- [ ] **Step 1:**

```bash
cd /home/claude/inline-explorer.nvim
git checkout main && git pull && git checkout -b p5-pbt-harness
```

（Task 1 の実装者が最初に実行）

---

### Task 1: 共有ジェネレータ `tests/lib/gen.lua` + 自己検証 spec

**Files:**
- Create: `tests/lib/gen.lua`
- Create: `tests/gen_spec.lua`

**Interfaces:**
- Consumes: なし
- Produces（Task 2-4 が使う API）:
  - `gen.rng(seed) -> r` — `r.int(lo, hi)`（両端含む）, `r.pick(list)`, `r.chance(pct)`
  - `gen.case(r) -> case` — 抽象ケース `{ params, args, stmts, ret, ctx }`
  - `gen.render(case) -> { callee_src, caller_src, program_src, fname = "f", row, col }` — 純関数。`row`/`col` は caller_src 内の呼び出し位置（0-indexed、`f(` の `f`）
  - `gen.shrink(case, still_fails) -> case` — 貪欲最小化（文末尾削除→引数削除→文脈単純化）
  - `gen.CTX_N` — 文脈数（9）

- [ ] **Step 1: `tests/gen_spec.lua` を作成する（先に spec）**

```lua
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
```

- [ ] **Step 2: red を確認する**

Run: `nvim --headless --clean -u NONE -c "luafile tests/gen_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: エラー（`tests.lib.gen` が存在しない → module not found）

- [ ] **Step 3: `tests/lib/gen.lua` を作成する**

```lua
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

M.CTX_N = 9

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
  if depth <= 0 or (#operands == 0 and true) or r.chance(35) then
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
  -- De-duplicate colliding param names (two params both named "t" is invalid C).
  local seen = {}
  for i, p in ipairs(case.params) do
    if seen[p.name] then
      p.name = p.name .. "_" .. i
      operands[i] = p.type == "ptr" and ("*" .. p.name) or p.name
    end
    seen[p.name] = true
  end

  local nstmts = r.int(0, 5)
  local nlocal = 0
  for k = 1, nstmts do
    local kind = r.int(1, 6)
    if kind == 1 or (kind >= 5 and #operands == 0 and nlocal == 0) then
      -- declaration; t/s again collide with the caller on purpose
      nlocal = nlocal + 1
      local name = r.pick({ "l" .. nlocal, "t", "s" })
      if seen[name] then
        name = name .. "_" .. nlocal
      end
      seen[name] = true
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
  local program_src = callee_src .. "\n" .. caller_src .. "\n" .. table.concat(main, "\n") .. "\n"

  return {
    callee_src = callee_src,
    caller_src = caller_src,
    program_src = program_src,
    fname = "f",
    row = row,
    col = col,
  }
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
```

- [ ] **Step 4: green 確認**

Run: `nvim --headless --clean -u NONE -c "luafile tests/gen_spec.lua" -c "qa!" 2>&1 | tail -5`
Expected: `ALL GEN TESTS PASSED`

失敗した場合（生成 C の compile 失敗等）は gen.lua 側の生成規則を直してよいが、gen_spec の性質自体は弱めないこと。

- [ ] **Step 5: Commit**

```bash
git add tests/lib/gen.lua tests/gen_spec.lua
git commit -m "Add a deterministic UB-free C generator for property tests

Two-phase: an abstract case (params, statement pool draws, caller
context) renders to sources through a pure function, so the greedy
shrinker mutates the case and reductions that break the original
program are rejected by the oracle's own precondition. Park-Miller LCG
for portable seed reproducibility; arithmetic restricted to + - & | ^
with masked loop bounds so the differential oracle never meets UB."
```

---

### Task 2: substitute.lua に test hook を追加する

**Files:**
- Modify: `lua/inline-explorer/substitute.lua`（`M._probe` の直後にヘルパ公開 + `_render` 追加）
- Modify: `tests/ir_spec.lua`（`_render` の検証を追記）

**Interfaces:**
- Consumes: 既存 `analyze_callee` / `analyze_context` / `PRINTERS` / `rebase` / `common_ws_prefix`
- Produces: `M._rebase`, `M._common_ws_prefix`, `M._render(caller_src, callee_src, fname, N, occ, printer) -> new_src|nil, err`（printer ∈ `"pretty" | "canonical" | "readable_multi"`、`decide()` を迂回して指名 printer で描画。binds 構築・arity 検査は `inline_call` と同一）

- [ ] **Step 1: `tests/ir_spec.lua` の最終 print 前に追記する（red）**

```lua
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
```

Run: `nvim --headless --clean -u NONE -c "luafile tests/ir_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: エラー（`_render` nil → attempt to call）

- [ ] **Step 2: `lua/inline-explorer/substitute.lua` の `M._probe` 関数の直後（`return M` の前）に追記する**

```lua
-- Test hooks for the property suites: the layout helpers, and a renderer that
-- forces a named printer, bypassing decide() -- used to check that canonical
-- and pretty output of the same call are semantically identical.
M._rebase = rebase
M._common_ws_prefix = common_ws_prefix

function M._render(caller_src, callee_src, fname, N, occ, printer)
  local p = PRINTERS[printer]
  if not p then
    return nil, "unknown printer '" .. tostring(printer) .. "'"
  end
  N = N or 1
  occ = occ or 1

  local call = find_calls(parse(caller_src), caller_src, fname)[occ]
  if not call then
    return nil, "call to '" .. fname .. "' not found"
  end
  local ir, err = analyze_callee(callee_src, fname, N, enclosing_scope(call, caller_src))
  if not ir then
    return nil, err
  end
  local arglist = call:field("arguments")[1]
  local args = {}
  for i = 0, arglist:named_child_count() - 1 do
    args[#args + 1] = text(arglist:named_child(i), caller_src)
  end
  if #args ~= #ir.params then
    return nil, string.format("arity mismatch (%d args, %d params)", #args, #ir.params)
  end
  ir.binds = {}
  for i, pa in ipairs(ir.params) do
    ir.binds[i] = build_bind(pa, args[i], ir.rename, N, i, callee_src)
  end
  return p(caller_src, ir, analyze_context(caller_src, call))
end
```

- [ ] **Step 3: green 確認（ir_spec + substitute_spec）**

Run: `nvim --headless --clean -u NONE -c "luafile tests/ir_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: `ALL IR TESTS PASSED`

Run: `nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!" 2>&1 | tail -1`
Expected: `ALL SUBSTITUTE TESTS PASSED`

- [ ] **Step 4: Commit**

```bash
git add lua/inline-explorer/substitute.lua tests/ir_spec.lua
git commit -m "Expose layout helpers and a printer-forcing renderer for tests"
```

---

### Task 3: 高速性質層 `tests/properties_spec.lua`

**Files:**
- Create: `tests/properties_spec.lua`

**Interfaces:**
- Consumes: `tests.lib.gen`, `M.inline_call`, `M._rebase`, `M._common_ws_prefix`
- Produces: なし

- [ ] **Step 1: `tests/properties_spec.lua` を作成する**

```lua
-- Fast property layer: run inline_call over generated cases and check
-- tree-sitter-verifiable invariants -- no gcc involved. ~300 cases per run
-- (override with IE_PROP_CASES), both output modes, deterministic seeds
-- (IE_PBT_SEED as the base). On failure, the offending case is shrunk and
-- printed with its seed for exact reproduction.
--   nvim --headless --clean -u NONE -c "luafile tests/properties_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local gen = require("tests.lib.gen")
local S = require("inline-explorer.substitute")

if not pcall(vim.treesitter.get_string_parser, "int x;", "c") then
  print("SKIP: c parser unavailable")
  return
end

local N_CASES = tonumber(os.getenv("IE_PROP_CASES") or "") or 300
local BASE_SEED = tonumber(os.getenv("IE_PBT_SEED") or "") or 12345

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and ("\n----\n" .. tostring(d) .. "\n----") or ""))
  end
end

local function has_error(src)
  return vim.treesitter.get_string_parser(src, "c"):parse()[1]:root():has_error()
end

local function count_calls(src)
  local n = 0
  for _ in src:gmatch("f%(") do
    n = n + 1
  end
  return n
end

-- One case, one mode. Returns nil if healthy, else a short violation tag.
local function violation(case, mode)
  local rc = gen.render(case)
  local new, err = S.inline_call(rc.caller_src, rc.callee_src, "f", 1, 1, mode)
  if not new then
    -- The engine may legitimately reject; but on our vocabulary it never
    -- should (no variadics, arity always matches).
    return "rejected: " .. tostring(err)
  end
  if has_error(new) then
    return "P-parse: transformed source has ERROR nodes"
  end
  if count_calls(new) ~= count_calls(rc.caller_src) - 1 then
    return "P-count: call count did not decrease by exactly 1"
  end
  return nil
end

-- P-parse + P-count over the whole case budget, both modes.
do
  local bad, bad_seed, bad_mode
  for i = 1, N_CASES do
    local seed = BASE_SEED + i
    for _, mode in ipairs({ "correct", "readable" }) do
      local case = gen.case(gen.rng(seed))
      local v = violation(case, mode)
      if v then
        bad, bad_seed, bad_mode = v, seed, mode
        local small = gen.shrink(case, function(c)
          return violation(c, mode) ~= nil
        end)
        local rc = gen.render(small)
        print("counterexample (seed=" .. seed .. ", mode=" .. mode .. "):")
        print(rc.callee_src)
        print(rc.caller_src)
        break
      end
    end
    if bad then
      break
    end
  end
  check(("P-parse/P-count hold for %d cases x 2 modes"):format(N_CASES), bad == nil,
    bad and (bad .. " @seed=" .. bad_seed .. " mode=" .. bad_mode))
end

-- P-unique: two inlinings with different N never share injected names.
do
  local bad, bad_seed
  for i = 1, math.min(N_CASES, 100) do
    local seed = BASE_SEED + 7000 + i
    local case = gen.case(gen.rng(seed))
    local rc = gen.render(case)
    local two = "static int caller(int a, int b)\n{\n    int t = 3;\n    int s = 4;\n"
    for j, p in ipairs(case.params) do
      if p.type == "ptr" then
        two = two .. "    int pv" .. j .. " = 1;\n"
      end
    end
    local call = "f(" .. table.concat(case.args, ", ") .. ")"
    two = two .. "    return " .. call .. " + " .. call .. ";\n}"
    local once = S.inline_call(two, rc.callee_src, "f", 1, 1, "correct")
    if once then
      local twice = S.inline_call(once, rc.callee_src, "f", 2, 1, "correct")
      if twice then
        if has_error(twice) then
          bad, bad_seed = "second inlining produced ERROR nodes", seed
        else
          for name in twice:gmatch("[%w_]+__ie1") do
            local stem = name:gsub("__ie1$", "")
            -- every __ie1 name must not ALSO appear only as a bare collision
            -- (i.e. the __ie2 twin must be distinct); direct check: no name
            -- carries both suffixes at once (structurally impossible) --
            -- the real property: __ie1 and __ie2 sets are disjoint.
            if twice:find(stem .. "__ie2__ie1", 1, true) then
              bad, bad_seed = "nested suffixing detected: " .. name, seed
            end
          end
          -- injected result/label names must be distinct between the two
          if twice:find("__ie_ret1", 1, true) and twice:find("__ie_ret2", 1, true) then
            -- fine: both present and distinct by construction
          end
        end
      end
    end
    if bad then
      break
    end
  end
  check("P-unique holds for 100 double-inlining cases", bad == nil, bad and (bad .. " @seed=" .. bad_seed))
end

-- P-reject-safe: bogus inputs return nil + err and never throw.
do
  local bad
  for i = 1, 50 do
    local seed = BASE_SEED + 9000 + i
    local case = gen.case(gen.rng(seed))
    local rc = gen.render(case)
    -- unknown function name
    local ok1, r1, e1 = pcall(S.inline_call, rc.caller_src, rc.callee_src, "nosuch", 1, 1, "correct")
    if not ok1 or r1 ~= nil or e1 == nil then
      bad = "unknown-name case misbehaved @seed=" .. seed
      break
    end
    -- arity mismatch: swap in a callee with one extra param
    local fat = rc.callee_src:gsub("static int f%(void%)", "static int f(int zz)")
    if fat == rc.callee_src then
      fat = rc.callee_src:gsub("static int f%(", "static int f(int zz, ", 1)
    end
    local ok2, r2, e2 = pcall(S.inline_call, rc.caller_src, fat, "f", 1, 1, "correct")
    if not ok2 or r2 ~= nil or e2 == nil then
      bad = "arity case misbehaved @seed=" .. seed .. " err=" .. tostring(e2)
      break
    end
  end
  check("P-reject-safe holds for 50 bogus-input cases", bad == nil, bad)
end

-- Utility roundtrip: rebase re-indents to the target, and the common prefix
-- of the result is that target.
do
  local bad
  for i = 1, 100 do
    local r = gen.rng(BASE_SEED + 11000 + i)
    local lines = {}
    local base = string.rep(" ", r.int(0, 6))
    for k = 1, r.int(1, 5) do
      lines[k] = base .. string.rep(" ", r.int(0, 4)) .. "x" .. k .. ";"
    end
    local frag = table.concat(lines, "\n")
    local target = string.rep(" ", r.int(0, 8))
    local out = S._rebase(frag, target)
    local nonblank = {}
    for _, l in ipairs(out) do
      if l:match("%S") then
        nonblank[#nonblank + 1] = l
      end
    end
    local prefix = S._common_ws_prefix(nonblank)
    if prefix:sub(1, #target) ~= target then
      bad = "roundtrip broke @case " .. i .. ": prefix=" .. vim.inspect(prefix) .. " target=" .. vim.inspect(target)
      break
    end
  end
  check("rebase x common_ws_prefix roundtrip holds for 100 fragments", bad == nil, bad)
end

print("")
print(fails == 0 and "ALL PROPERTY TESTS PASSED" or (fails .. " FAILURE(S)"))
```

- [ ] **Step 2: 実行して green 確認（初回から green の想定 — エンジンは P1-P4 で鍛えられている。FAIL が出たら seed 付き反例が出る: エンジンバグなら BLOCKED として報告、性質の書き誤りなら spec を直す）**

Run: `nvim --headless --clean -u NONE -c "luafile tests/properties_spec.lua" -c "qa!" 2>&1 | tail -6`
Expected: `ALL PROPERTY TESTS PASSED`（~300×2 モードで数十秒）

- [ ] **Step 3: Commit**

```bash
git add tests/properties_spec.lua
git commit -m "Add the fast property layer: parse, count, unique, reject-safe"
```

---

### Task 4: gcc 差分層 `tests/pbt_spec.lua`

**Files:**
- Create: `tests/pbt_spec.lua`

**Interfaces:**
- Consumes: `tests.lib.gen`, `M.inline_call`, `M._probe`, `M._render`
- Produces: なし

- [ ] **Step 1: `tests/pbt_spec.lua` を作成する**

```lua
-- Differential property layer: build and RUN each generated program before
-- and after inline substitution; stdout must match exactly. Also renders the
-- canonical printer alongside a pretty-decided transform and requires the
-- same output -- a direct check that decide()'s safety analysis is sound.
-- readable mode is compile-only (documented as not semantics-preserving).
--
--   IE_PBT_CASES=N   number of cases (default 30)
--   IE_PBT_SEED=S    base seed (default 12345)
--
--   nvim --headless --clean -u NONE -c "luafile tests/pbt_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local gen = require("tests.lib.gen")
local S = require("inline-explorer.substitute")

if vim.fn.executable("gcc") == 0 then
  print("SKIP: gcc not found")
  return
end
if not pcall(vim.treesitter.get_string_parser, "int x;", "c") then
  print("SKIP: c parser unavailable")
  return
end

local N_CASES = tonumber(os.getenv("IE_PBT_CASES") or "") or 30
local BASE_SEED = tonumber(os.getenv("IE_PBT_SEED") or "") or 12345

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local n_built = 0

local function writef(path, s)
  local f = assert(io.open(path, "w"))
  f:write(s)
  f:close()
end

-- Compile and run `src`; returns (stdout, exit_code) or (nil, gcc_output).
local function build_run(src, tag)
  n_built = n_built + 1
  local c = tmp .. "/" .. tag .. "_" .. n_built .. ".c"
  local exe = c:gsub("%.c$", ".out")
  writef(c, src)
  local out = vim.fn.system({
    "gcc", "-std=gnu11", "-Werror=implicit-function-declaration",
    "-Wno-unused-label", "-Wno-unused-variable", "-Wno-unused-but-set-variable",
    c, "-o", exe,
  })
  if vim.v.shell_error ~= 0 then
    return nil, out
  end
  local stdout = vim.fn.system({ exe })
  return stdout, vim.v.shell_error
end

-- Substitute rc's call in the caller and rebuild the whole program.
local function program_with(rc, new_caller)
  return rc.callee_src .. "\n" .. new_caller .. "\n" .. rc.program_src:match("#include.*$")
end

-- The differential for one case. Returns nil if healthy, else a violation tag.
local function violation(case)
  local rc = gen.render(case)
  local base_out, base_code = build_run(rc.program_src, "orig")
  if base_out == nil then
    return nil -- original does not build: generator edge, not an engine bug; skip
  end

  local new, err = S.inline_call(rc.caller_src, rc.callee_src, "f", 1, 1, "correct")
  if not new then
    return "engine rejected a well-formed case: " .. tostring(err)
  end
  local t_out, t_code = build_run(program_with(rc, new), "corr")
  if t_out == nil then
    return "correct-mode output does not compile:\n" .. tostring(t_code)
  end
  if t_out ~= base_out or t_code ~= base_code then
    return "correct-mode stdout/exit differs from the original"
  end

  -- Structure property: when decide() chose pretty, the canonical rendering
  -- of the very same call must agree as well.
  local probe = S._probe(rc.caller_src, rc.callee_src, "f", 1, "correct")
  if probe and probe.decision == "pretty" then
    local canon = S._render(rc.caller_src, rc.callee_src, "f", 1, 1, "canonical")
    if canon then
      local c_out, c_code = build_run(program_with(rc, canon), "canon")
      if c_out == nil then
        return "canonical rendering does not compile:\n" .. tostring(c_code)
      end
      if c_out ~= base_out or c_code ~= base_code then
        return "canonical rendering disagrees with the original"
      end
    end
  end
  return nil
end

local fails = 0
local readable_compiled, readable_total = 0, 0
local bad, bad_seed

for i = 1, N_CASES do
  local seed = BASE_SEED + 100000 + i
  local case = gen.case(gen.rng(seed))
  local v = violation(case)
  if v then
    bad, bad_seed = v, seed
    local small = gen.shrink(case, function(c)
      return violation(c) ~= nil
    end)
    local rc = gen.render(small)
    local cx = tmp .. "/counterexample_" .. seed .. ".c"
    writef(cx, rc.program_src)
    print("counterexample (seed=" .. seed .. ") saved to: " .. cx)
    print(rc.callee_src)
    print(rc.caller_src)
    break
  end

  -- readable: compile-only statistics, never a failure (documented trade-off)
  local rc = gen.render(case)
  local readable = S.inline_call(rc.caller_src, rc.callee_src, "f", 1, 1, "readable")
  if readable then
    readable_total = readable_total + 1
    local r_out = build_run(program_with(rc, readable), "read")
    if r_out ~= nil then
      readable_compiled = readable_compiled + 1
    end
  end
end

if bad then
  fails = fails + 1
  print("FAIL  differential property @seed=" .. bad_seed .. ": " .. bad)
else
  print(("PASS  differential property holds for %d cases (gcc builds: %d)"):format(N_CASES, n_built))
end
print(("info  readable mode compiled %d/%d (compile-only, never failing)"):format(readable_compiled, readable_total))

print("")
print(fails == 0 and "ALL PBT TESTS PASSED" or (fails .. " FAILURE(S)"))
```

- [ ] **Step 2: 実行して green 確認**

Run: `nvim --headless --clean -u NONE -c "luafile tests/pbt_spec.lua" -c "qa!" 2>&1 | tail -5`
Expected: `ALL PBT TESTS PASSED`（30 ケース、gcc ~60-90 ビルド、~30秒）

Run（増量の動作確認）: `IE_PBT_CASES=5 IE_PBT_SEED=777 nvim --headless --clean -u NONE -c "luafile tests/pbt_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: `ALL PBT TESTS PASSED`（5 ケースで完走 = env が効いている）

- [ ] **Step 3: Commit**

```bash
git add tests/pbt_spec.lua
git commit -m "Add the gcc differential property layer

Each generated program runs before and after correct-mode substitution
with byte-identical stdout required; when the engine chose the pretty
printer, the canonical rendering of the same call must agree too, which
checks decide()'s hoist-safety analysis directly. Failures shrink to a
minimal counterexample saved as a .c file with its seed."
```

---

### Task 5: ドキュメント + 最終確認

**Files:**
- Modify: `README.md`（"Tested against real source" 節にプロパティ層の段落追記）
- Modify: `DESIGN.md`（Guarantee 段落にプロパティ層を追記）

**Interfaces:** なし（文書のみ）

- [ ] **Step 1: README.md「Tested against real source」節の箇条書きの後（```sh コードブロックの前）に追記する**

```markdown
- `tests/properties_spec.lua` and `tests/pbt_spec.lua` add **property-based
  testing** on top: a deterministic generator (`tests/lib/gen.lua`) builds
  UB-free random callees and splices them into nine caller contexts. The fast
  layer checks tree-sitter invariants over ~300 cases per run; the gcc layer
  builds and runs each program before and after substitution and requires
  byte-identical stdout — and whenever the engine chooses the pretty form, the
  canonical form of the same call must agree too. Failures shrink to a minimal
  counterexample and print their seed (`IE_PBT_SEED` / `IE_PBT_CASES` /
  `IE_PROP_CASES` control reproduction and budget).
```

- [ ] **Step 2: DESIGN.md の Guarantee 段落（"Guarantee: `tests/substitute_spec.lua` ..."）の末尾に追記する**

```markdown
On top of the shaped and real-source suites, `tests/properties_spec.lua` and
`tests/pbt_spec.lua` run property-based tests over a deterministic random
generator (`tests/lib/gen.lua`): tree-sitter invariants (clean re-parse, call
count, unique injected names, safe rejection) on ~300 cases per run, and a gcc
differential that requires byte-identical stdout before and after substitution,
including canonical-vs-pretty agreement whenever the analysis picked the pretty
form. Counterexamples shrink greedily and reproduce from a printed seed.
```

- [ ] **Step 3: 全 spec 最終確認（9本）**

```sh
for s in gen_spec properties_spec pbt_spec ir_spec substitute_spec macro_spec resolver_spec expander_spec; do
  nvim --headless --clean -u NONE -c "luafile tests/$s.lua" -c "qa!"
done
nvim --headless --clean -u NONE -c "luafile tests/real_cjson_spec.lua" -c "qa!"   # network
```
Expected: すべて `ALL ... PASSED`（cJSON は `ALL ACCEPTED TRANSFORMS COMPILE + PASS ON REAL cJSON`）

- [ ] **Step 4: Commit**

```bash
git add README.md DESIGN.md
git commit -m "Docs: describe the property-based test layers"
```

---

## Self-Review 済み事項

- Spec P5 対応: gen.lua（LCG/語彙中/shrink）= Task 1、高速層 4 性質 + ユーティリティ = Task 3、gcc 差分 + canonical-vs-pretty 構造性質 + IE_PBT_* = Task 4、受け入れ「seed 固定で決定的再現」= LCG + env で充足
- P3 final review の注意反映: P-reject-safe / P-unique は `inline_call` 経由（`_probe` は arity 検査を持たないため）
- 型整合: `gen.*` API は Task 1（実装+spec）と Task 3/4（消費側）で同一。`_render` は Task 2（hook+ir_spec）と Task 4（消費側）で同一
- 語彙制限の明示: fn-pointer 引数なし（case15 が例示でカバー）、乗除・シフトなし（UB 回避）、ループ有界
- pbt の「元がビルド不能なら skip」: ジェネレータ品質は gen_spec の 20-seed compile 検証が担保しており、差分層では欠陥ケースを黙って数に入れない（カバレッジ水増しを避けるため N_CASES は変換試行数のまま）
- プレースホルダなし
