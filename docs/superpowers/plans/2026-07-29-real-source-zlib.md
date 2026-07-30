# 実ソース回帰に zlib を追加 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 実ソース回帰テストの母体を cJSON 一本から広げ、性質の異なる C（状態機械・`goto` によるエラー処理・ビット操作）で substitute エンジンを検証する。

**Architecture:** `real_cjson_spec.lua` の中身（clone → baseline 検証 → 呼び出し site 列挙 → 1件ずつ変換して再ビルド+テスト → 復元）を `tests/lib/real_source.lua` に抽出し、プロジェクト固有部分（URL・セットアップ・検証コマンド・対象ファイル）だけを設定として渡す形にする。cJSON はその設定として書き直し、zlib を追加する。

**Tech Stack:** Lua (Neovim 0.10+), git, gcc, make

## 計測済みの前提（この計画の根拠、推測ではない）

- zlib のライブラリ本体 11 ファイルで **呼び出し site 239 / エンジン受理 235**（cJSON は 188）
- 1 反復（1 ファイル書き換え → `make -s test`）が **約 0.87 秒** → 235 件で約 3.4 分
- `make test` は失敗を伝播する（`teststatic` の `else ... false`）。**非対称な破壊（`uncompress` の出力 1 バイトを XOR）で exit 2 + `*** zlib test FAILED ***` を実測確認**
- ただし zlib のテストは **round-trip の自己検証**なので、圧縮側と伸長側が同じように壊れる **対称な破壊は検出できない**（`adler32` を定数にしても両側が同じ値を使うため一致して通る、を実測）。1 ファイルずつ変換する本テストでは通常は非対称になるが、両経路が使う `adler32.c` / `crc32.c` / `zutil.c` は検出力が落ちる。この限界は spec のコメントに明記する

## Global Constraints

- **プロダクションコード（`lua/`）は変更しない。** 本計画はテストのみ
- `real_cjson_spec.lua` の書き直しは **結果が変わってはならない**: 現行と同じ `sites=188 engine-accepted=188 compiled+passed=188` を再現すること。これが抽出が正しいことの唯一の証拠
- ネットワーク・git・gcc が無い場合は `SKIP:` を出して正常終了（既存の流儀）
- 各タスク完了時、既存 10 スイートが緑のままであること
- nvim が PATH に無い環境では入手済みバイナリのフルパスで実行してよい
- コメントは英語。コミットメッセージは英語

---

### Task 0: ブランチ作成

- [ ] **Step 1:**

```bash
cd /home/claude/inline-explorer.nvim
git checkout main && git pull && git checkout -b real-source-zlib
```

---

### Task 1: 共有ハーネス抽出 + cJSON 書き直し（結果不変が受け入れ条件）

**Files:**
- Create: `tests/lib/real_source.lua`
- Modify: `tests/real_cjson_spec.lua`（設定だけの薄い spec に）

**Interfaces:**
- Produces: `real_source.run(cfg)` — `cfg = { name, url, requires, sources, setup?, verify, oracle_note? }`
  - `requires`: clone 後に存在すべき相対パス（レイアウト検証）
  - `sources`: 呼び出し site を列挙し書き換える相対パス（複数可）
  - `setup(dir) -> ok, detail`: 一度だけ実行（省略可）
  - `verify(dir) -> ok, detail`: ビルド + テスト。真偽と失敗時の詳細
  - `oracle_note`: レポートに印字する、そのプロジェクトのテストが何を検出できないかの注記

- [ ] **Step 1: `tests/lib/real_source.lua` を作成する**

```lua
-- Shared harness for the real-source regression specs: clone a real OSS C
-- project, verify it builds and passes its own tests, then for every in-file
-- call to a same-file function apply correct-mode inline substitution and
-- require the project to still build AND still pass.
--
-- The contract is deliberately narrow: whenever the engine RETURNS a
-- transform, that transform must compile and the project's own tests must
-- still pass. Rejections are counted, not failures -- the engine is allowed
-- to decline (variadic functions, arity it cannot match); it is not allowed
-- to produce something that breaks.
local S = require("inline-explorer.substitute")

local M = {}

local function run(cmd, cwd)
  local out = vim.fn.system(cmd, nil)
  if cwd then
    out = vim.fn.system({ "bash", "-lc", "cd " .. vim.fn.shellescape(cwd) .. " && " .. table.concat(cmd, " ") })
  end
  return vim.v.shell_error == 0, out
end

M.sh = function(script, cwd)
  local out = vim.fn.system({ "bash", "-lc", "cd " .. vim.fn.shellescape(cwd) .. " && " .. script })
  return vim.v.shell_error == 0, out
end

local function read(p)
  local f = assert(io.open(p, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function write(p, s)
  local f = assert(io.open(p, "w"))
  f:write(s)
  f:close()
end

local function root_of(s)
  return vim.treesitter.get_string_parser(s, "c"):parse()[1]:root()
end

local function text(n, s)
  local _, _, a, _, _, b = n:range(true)
  return s:sub(a + 1, b)
end

local function captures(node, s, q)
  local o = {}
  for _, n in vim.treesitter.query.parse("c", q):iter_captures(node, s) do
    o[#o + 1] = n
  end
  return o
end

-- Every in-file function definition, and every call to one of them.
local function enumerate(src)
  local root = root_of(src)
  local defs = {}
  for _, nm in ipairs(captures(root, src, "(function_declarator declarator: (identifier) @n)")) do
    local fn = nm
    while fn and fn:type() ~= "function_definition" do
      fn = fn:parent()
    end
    if fn then
      local name = text(nm, src)
      defs[name] = defs[name] or text(fn, src)
    end
  end
  local calls = {}
  for _, f in ipairs(captures(root, src, "(call_expression function: (identifier) @f)")) do
    local name = text(f, src)
    if defs[name] then
      local r, c = f:range(true)
      calls[#calls + 1] = { name = name, row = r, col = c }
    end
  end
  return defs, calls
end

function M.run(cfg)
  local function skip(msg)
    print("SKIP: " .. msg)
  end

  if vim.fn.executable("git") == 0 or vim.fn.executable("gcc") == 0 then
    return skip("git or gcc not available")
  end

  local work = vim.fn.tempname()
  vim.fn.mkdir(work, "p")
  local dir = work .. "/" .. cfg.name
  local ok, out = run({ "git", "clone", "--depth", "1", cfg.url, dir })
  if not ok then
    return skip("clone failed (offline?)\n" .. out)
  end
  for _, rel in ipairs(cfg.requires) do
    if vim.fn.filereadable(dir .. "/" .. rel) == 0 then
      return skip("unexpected " .. cfg.name .. " layout: missing " .. rel)
    end
  end

  if cfg.setup then
    local sok, sout = cfg.setup(dir)
    if not sok then
      return skip("setup failed\n" .. tostring(sout))
    end
  end

  -- The baseline must build and pass before any comparison means anything.
  local bok, bout = cfg.verify(dir)
  if not bok then
    return skip("baseline build/test failed\n" .. tostring(bout))
  end

  local max_sites = tonumber(os.getenv("IE_REAL_MAX_SITES") or "") or math.huge
  local attempted, accepted, passed, failures = 0, 0, 0, {}

  for _, rel in ipairs(cfg.sources) do
    local path = dir .. "/" .. rel
    if vim.fn.filereadable(path) == 1 then
      local src0 = read(path)
      local defs, calls = enumerate(src0)
      for i, call in ipairs(calls) do
        if attempted >= max_sites then
          break
        end
        attempted = attempted + 1
        local sok, new = pcall(S.inline_in_buffer, src0, call.row, call.col, defs[call.name], i, "correct")
        if sok and new and new ~= src0 then
          accepted = accepted + 1
          write(path, new)
          local vok, vout = cfg.verify(dir)
          if vok then
            passed = passed + 1
          else
            failures[#failures + 1] = { rel, call.name, tostring(vout):sub(1, 400) }
          end
          write(path, src0)
        end
      end
    end
  end

  print(("real %s: sites=%d  engine-accepted=%d  built+passed=%d"):format(
    cfg.name, attempted, accepted, passed))
  if cfg.oracle_note then
    print("note: " .. cfg.oracle_note)
  end
  if #failures > 0 then
    print(#failures .. " FAILURE(S):")
    for _, f in ipairs(failures) do
      print(("  * %s %s -> %s"):format(f[1], f[2], f[3]))
    end
  else
    print(("ALL ACCEPTED TRANSFORMS COMPILE + PASS ON REAL %s"):format(cfg.name:upper()))
  end
end

return M
```

- [ ] **Step 2: `tests/real_cjson_spec.lua` を書き直す**

```lua
-- Real-source compile-correctness test: clone cJSON and, for every in-file
-- call to a same-file function, apply "correct"-mode inline substitution,
-- then rebuild AND run the project's tests. The contract: whenever the engine
-- returns a transform, the result must compile and pass.
--
-- Requires: git + network + gcc. Skips cleanly if any is missing.
--
--   nvim --headless --clean -u NONE -c "luafile tests/real_cjson_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local real = require("tests.lib.real_source")

real.run({
  name = "cJSON",
  url = "https://github.com/DaveGamble/cJSON.git",
  requires = { "cJSON.c", "test.c" },
  sources = { "cJSON.c" },
  verify = function(dir)
    return real.sh(
      "gcc -std=c99 -Werror=implicit-function-declaration -Wno-unused-label"
        .. " cJSON.c test.c -o ie_check -lm && ./ie_check",
      dir
    )
  end,
})
```

- [ ] **Step 3: 結果が不変であることを確認する（このタスクの受け入れ条件）**

Run: `nvim --headless --clean -u NONE -c "luafile tests/real_cjson_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n' | tail -3`
Expected: `real cJSON: sites=188  engine-accepted=188  built+passed=188` と
`ALL ACCEPTED TRANSFORMS COMPILE + PASS ON REAL CJSON`

数字が 188/188/188 と一致しないなら抽出が等価でない。**spec を数字に合わせて書き換えるのではなく、ハーネスの列挙・変換順序を調べ直すこと。**

- [ ] **Step 4: 既存 10 スイートが緑か確認する**

`gen_spec` / `properties_spec` / `pbt_spec` / `ir_spec` / `substitute_spec` / `macro_spec` / `resolver_spec` / `expander_spec` / `bench_lib_spec` を実行。
Expected: すべて `ALL ... PASSED`

- [ ] **Step 5: Commit**

```bash
git add tests/lib/real_source.lua tests/real_cjson_spec.lua
git commit -m "Extract the real-source harness from the cJSON spec

Clone, baseline, enumerate, transform one call at a time, rebuild, run,
restore -- none of that is cJSON-specific; only the URL, the files whose
call sites get rewritten, and the build-and-test command are. Adding a
second project is now a config block. Verified equivalent: the cJSON
run still reports 188 sites, 188 accepted, 188 built and passed."
```

---

### Task 2: zlib spec を追加する

**Files:**
- Create: `tests/real_zlib_spec.lua`

**Interfaces:**
- Consumes: Task 1 の `real_source.run`

- [ ] **Step 1: `tests/real_zlib_spec.lua` を作成する**

```lua
-- Real-source compile-correctness test on zlib: a different flavour of C
-- from cJSON -- state machines, goto-based error handling, bit manipulation,
-- and functions declared through zlib's own `local` (static) macro.
--
-- Only the library's own translation units are rewritten, because those are
-- what `make test` actually rebuilds and exercises. Measured surface: 239
-- in-file call sites, 235 of which the engine accepts.
--
-- Oracle limitation, verified experimentally: zlib's `make test` is a
-- ROUND-TRIP self-test (compress then decompress and compare). An asymmetric
-- break is caught loudly -- XOR-ing one byte of uncompress()'s output makes
-- it exit 2 with "*** zlib test FAILED ***" -- but a SYMMETRIC break is not:
-- making adler32() return a constant leaves both the writer and the reader
-- agreeing on the same wrong checksum, and the suite passes. Rewriting one
-- file at a time is normally asymmetric, but adler32.c / crc32.c / zutil.c
-- are used by both directions, so detection there rests on the compile step
-- more than on the run.
--
-- Requires: git + network + gcc + make. Skips cleanly if any is missing.
--
--   nvim --headless --clean -u NONE -c "luafile tests/real_zlib_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local real = require("tests.lib.real_source")

if vim.fn.executable("make") == 0 then
  print("SKIP: make not available")
  return
end

real.run({
  name = "zlib",
  url = "https://github.com/madler/zlib.git",
  requires = { "deflate.c", "inflate.c", "configure", "Makefile.in" },
  sources = {
    "adler32.c",
    "compress.c",
    "crc32.c",
    "deflate.c",
    "gzlib.c",
    "gzread.c",
    "gzwrite.c",
    "inflate.c",
    "inftrees.c",
    "trees.c",
    "uncompr.c",
  },
  setup = function(dir)
    return real.sh("./configure > /dev/null 2>&1", dir)
  end,
  verify = function(dir)
    -- `make test` propagates failure: its teststatic recipe ends in `false`
    -- when the round trip does not reproduce the input.
    return real.sh("make -s test 2>&1", dir)
  end,
  oracle_note = "zlib's tests are a round trip, so a symmetric break (both directions wrong the same way) is invisible; asymmetric breaks exit non-zero.",
})
```

- [ ] **Step 2: 少数の site で通ることを先に確認する（全件は約 3.4 分）**

Run: `IE_REAL_MAX_SITES=15 nvim --headless --clean -u NONE -c "luafile tests/real_zlib_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n' | tail -4`
Expected: `real zlib: sites=15  engine-accepted=<15前後>  built+passed=<accepted と同数>` と
`ALL ACCEPTED TRANSFORMS COMPILE + PASS ON REAL ZLIB`

- [ ] **Step 3: オラクルが本当に効いていることを確かめる**

ハーネスが「常に緑」でないことを実証する。`tests/lib/real_source.lua` の `S.inline_in_buffer` の呼び出しを一時的に、変換結果を壊すものに差し替える（例: `new = new:gsub("return ", "return !", 1)` を挿入して不正な C にする）。

Run: `IE_REAL_MAX_SITES=3 nvim --headless --clean -u NONE -c "luafile tests/real_zlib_spec.lua" -c "qa!" 2>&1 | tail -5`
Expected: `FAILURE(S)` が出ること。確認後、**必ず元に戻す**（`git checkout -- tests/lib/real_source.lua`）。

戻したことを確認: `git status --porcelain tests/lib/real_source.lua` が空。

- [ ] **Step 4: 全件を実行する**

Run: `time nvim --headless --clean -u NONE -c "luafile tests/real_zlib_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n' | tail -6`
Expected: `sites=239` 前後、`engine-accepted=235` 前後、`built+passed` が accepted と同数、
`ALL ACCEPTED TRANSFORMS COMPILE + PASS ON REAL ZLIB`

**FAILURE が出た場合は、これがこのテストを追加した目的である。** テストを緩めず、失敗した変換を最小再現に落として報告すること（どのファイルのどの関数か、生成された C のどこが壊れているか）。

- [ ] **Step 5: Commit**

```bash
git add tests/real_zlib_spec.lua
git commit -m "Add zlib to the real-source regression suite

cJSON is a parser; zlib is state machines, goto-based cleanup and bit
twiddling, declared through its own `local` static macro -- 239 in-file
call sites against cJSON's 188, and a different set of C idioms for the
substitution engine to survive. The spec records what zlib's round-trip
tests cannot see: a symmetric break passes, so for the files both
directions share, detection leans on the compile step."
```

---

### Task 3: CI + ドキュメント

**Files:**
- Modify: `.github/workflows/test.yml`
- Modify: `README.md`

- [ ] **Step 1: CI の `real-cjson` ジョブを 2 プロジェクトに広げる**

`.github/workflows/test.yml` の `real-cjson` ジョブを次に置き換える（ジョブ名も改める）:

```yaml
  real-source:
    runs-on: ubuntu-latest
    if: github.event_name == 'push'
    strategy:
      fail-fast: false
      matrix:
        spec: [real_cjson_spec, real_zlib_spec]
    steps:
      - uses: actions/checkout@v4
      - name: Install Neovim
        run: |
          curl -sL https://github.com/neovim/neovim/releases/download/v0.11.3/nvim-linux-x86_64.tar.gz | tar xz
          echo "$PWD/nvim-linux-x86_64/bin" >> "$GITHUB_PATH"
      - name: Real-source regression (${{ matrix.spec }})
        run: |
          out=$(nvim --headless --clean -u NONE -c "luafile tests/${{ matrix.spec }}.lua" -c "qa!" 2>&1 | tr '\r' '\n')
          echo "$out"
          echo "$out" | grep -Eq "ALL ACCEPTED TRANSFORMS COMPILE \+ PASS|SKIP:" || { echo "FAILED: ${{ matrix.spec }}"; exit 1; }
          if echo "$out" | grep -q "FAILURE"; then echo "FAILED"; exit 1; fi
```

`fail-fast: false` は、片方が落ちたときにもう片方の結果を捨てないため。
`SKIP:` の許容は残す（この 2 ジョブはネットワークに依存する）。

- [ ] **Step 2: README の「Tested against real source」節を更新する**

cJSON の項目のあとに zlib の項目を足し、書き方は既存の箇条書きに合わせる:

```markdown
- `tests/real_zlib_spec.lua` does the same against
  [zlib](https://github.com/madler/zlib) — 239 in-file call sites of a very
  different flavour of C: state machines, `goto`-based cleanup, bit twiddling.
  Note what its oracle cannot see: zlib's tests are a round trip, so a
  symmetric break (compressor and decompressor wrong the same way) passes;
  for the files both directions share, detection leans on the compile step.
```

- [ ] **Step 3: 全スイート最終確認**

fast 系 9 本 + `bench_spec` + `real_cjson_spec` + `real_zlib_spec`。
Expected: すべて緑（bench は `IE_BENCH_CLANGD` が要る）。

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/test.yml README.md
git commit -m "Run both real-source specs in CI as a matrix"
```

---

## Self-Review 済み事項

- Task 1 の受け入れ条件は「188/188/188 の再現」であり、抽出が等価であることの証拠になっている
- Task 2 Step 3 で、ハーネスが赤にもなることを実証してから全件を回す（緑になるだけのテストを信用しない）
- zlib のオラクルの限界（対称な破壊を検出できない）は実測に基づき、spec のコメントと README の両方に書く
- 数字（239 site / 235 受理 / 0.87 秒per反復 / 約 3.4 分）はすべて計画前に実測済み
- プレースホルダなし
