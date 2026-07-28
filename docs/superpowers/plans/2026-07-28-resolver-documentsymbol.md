# resolver documentSymbol 化 (P3) 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** resolver の定義範囲抽出を言語別ノード表から LSP `textDocument/documentSymbol` に置き換え、`DEFINITION_NODES` 表とサフィックスパターンを削除する。tree-sitter / brace ヒューリスティックはフォールバックに降格。

**Architecture:** `M.locate`（workspace/symbol、不変）→ 新 `M.extract(loc, source_bufnr, cb)`（非同期）: 定義ファイルに documentSymbol を投げ、`M._symbol_range` が階層型 DocumentSymbol / フラット SymbolInformation の両形式から定義の全 range を選ぶ。サーバ不在・range 不能時は `M.extract_sync`（表なし tree-sitter 同一行祖先ヒューリスティック → brace カウンタ）へ。extract の非同期化に伴い呼び出し側 expander/inliner を cb ネストに変更。

**Tech Stack:** Lua (Neovim 0.10+), vim.lsp（documentSymbol / buf_attach_client）, tree-sitter（フォールバックのみ）

**Spec:** `docs/superpowers/specs/2026-07-28-redesign-and-pbt-design.md` の P3（このplanの範囲。P4/P5 は別 plan）

## Global Constraints

- ユーザー向け API（コマンド・キーマップ・`setup()`）不変
- `M.locate(name, source_bufnr, cb)` のシグネチャ・挙動 不変
- `M.extract` は `(loc, source_bufnr, cb)` の非同期 cb 形式に変更（内部 API）。cb は **同期的に呼ばれる場合がある**（LSP 不在フォールバック）— 呼び出し側は戻り値に依存しない
- inliner の関数判定は文字列 `"function_definition"` キー — LSP 経路では Function/Method/Constructor kind をこのラベルにマップして互換維持
- P3 受け入れ（spec）: `DEFINITION_NODES` 表とサフィックスパターン（`NODE_PATTERNS`/`is_definition`）が削除されている
- 各タスク完了時、全 spec green:
  `nvim --headless --clean -u NONE -c "luafile tests/<spec>.lua" -c "qa!"`
  対象: resolver_spec, expander_spec(Task 3 以降), ir_spec, substitute_spec, macro_spec
- nvim が PATH に無い環境では入手済みバイナリのフルパスで実行してよい
- コメントは英語（既存流儀）。コミットメッセージは英語

---

### Task 0: ブランチ作成

- [ ] **Step 1:**

```bash
cd /home/claude/inline-explorer.nvim
git checkout main && git pull && git checkout -b p3-resolver-documentsymbol
```

（Task 1 の実装者が最初に実行。以降のタスクはこのブランチ上で作業）

---

### Task 1: resolver 単体 spec を先に書く（TDD red）

**Files:**
- Modify: `tests/resolver_spec.lua`（全面書き換え）

**Interfaces:**
- Consumes: なし（テストのみ）
- Produces: Task 2 が満たす内部 API 仕様:
  - `M._symbol_range(symbols, ref_range, name) -> range|nil, label|nil` — documentSymbol 応答（階層型/フラット両対応）から定義の全 range を選ぶ。ref_range を包含し **かつ ref_range より広い** 最深シンボルが勝ち。ref_range と同一の range（名前だけの range）は拒否して nil
  - `M.extract_sync(loc) -> lines, label` — 表なし同期フォールバック。tree-sitter で「位置の祖先のうち、シンボル行から3行以内で始まる最外の named ノード」を定義とみなし、その `node:type()` をラベルに。パーサ不能時は既存 brace/`#define` ヒューリスティック（label `"heuristic"`）
  - `M.extract(loc, source_bufnr, cb)` — LSP 不在時は `extract_sync` の結果で cb を同期呼び出し
  - kind→label: Method(6)/Constructor(9)/Function(12) → `"function_definition"`、他は SymbolKind 名の小文字（例 Struct(23) → `"struct"`）

- [ ] **Step 1: `tests/resolver_spec.lua` を次の内容に全面置換する**

```lua
-- Resolver unit tests: LSP documentSymbol range selection (_symbol_range) and
-- the table-free tree-sitter fallback (extract_sync / async extract).
--   nvim --headless --clean -u NONE -c "luafile tests/resolver_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local resolver = require("inline-explorer.resolver")

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
    print("FAIL  " .. l .. (d and (" (" .. vim.inspect(d) .. ")") or ""))
  end
end

local function range(sl, sc, el, ec)
  return { start = { line = sl, character = sc }, ["end"] = { line = el, character = ec } }
end

-- _symbol_range: hierarchical DocumentSymbol[] -- the deepest symbol containing
-- the reference wins, and function-ish kinds map to "function_definition".
do
  local symbols = {
    {
      name = "MyClass",
      kind = 5, -- Class
      range = range(0, 0, 20, 1),
      selectionRange = range(0, 6, 0, 13),
      children = {
        { name = "method", kind = 6, range = range(2, 2, 5, 3), selectionRange = range(2, 6, 2, 12) },
      },
    },
  }
  local ref = range(2, 6, 2, 12) -- workspace/symbol points at the method's name
  local r, label = resolver._symbol_range(symbols, ref, "method")
  check("hierarchical: deepest symbol range wins", r and r.start.line == 2 and r["end"].line == 5, r)
  check("hierarchical: Method kind -> function_definition", label == "function_definition", label)
end

-- _symbol_range: non-function kinds keep a lowercase kind label.
do
  local symbols = {
    { name = "S", kind = 23, range = range(0, 0, 3, 1), selectionRange = range(0, 7, 0, 8), children = {} },
  }
  local r, label = resolver._symbol_range(symbols, range(0, 7, 0, 8), "S")
  check("hierarchical: Struct kind -> 'struct' label", label == "struct", label)
  check("hierarchical: struct full range", r and r["end"].line == 3, r)
end

-- _symbol_range: flat SymbolInformation[] -- name-matched containing range;
-- a range identical to the reference (name-only) is rejected.
do
  local flat = {
    { name = "other", kind = 12, location = { uri = "file:///x.c", range = range(0, 0, 4, 1) } },
    { name = "f", kind = 12, location = { uri = "file:///x.c", range = range(6, 0, 9, 1) } },
  }
  local r = resolver._symbol_range(flat, range(6, 11, 6, 12), "f")
  check("flat: name-matched containing range", r and r.start.line == 6 and r["end"].line == 9, r)
  local name_only = { { name = "g", kind = 12, location = { uri = "file:///x.c", range = range(3, 4, 3, 5) } } }
  check("flat: name-only range rejected", resolver._symbol_range(name_only, range(3, 4, 3, 5), "g") == nil)
end

-- extract_sync: header-defined function (no LSP, no node-type table) must
-- still extract the full definition with label "function_definition".
do
  local hpath = vim.fn.tempname() .. ".h"
  local f = assert(io.open(hpath, "w"))
  f:write("static __always_inline int acc(int cpu)\n{\n    return per_cpu(cpu) & MASK;\n}\n")
  f:close()
  local col = ("static __always_inline int acc(int cpu)"):find("acc") - 1
  local lines, label = resolver.extract_sync({ uri = vim.uri_from_fname(hpath), range = range(0, col, 0, col) })
  check("extract_sync: header function -> function_definition", label == "function_definition", tostring(label))
  check("extract_sync: body includes the return", table.concat(lines, "\n"):find("return per_cpu", 1, true) ~= nil)
end

-- extract_sync: macro definition -> a preproc node type, continuation kept.
do
  local cpath = vim.fn.tempname() .. ".c"
  local f = assert(io.open(cpath, "w"))
  f:write("#define TWICE(x) \\\n    ((x) + (x))\nint y;\n")
  f:close()
  local lines, label = resolver.extract_sync({ uri = vim.uri_from_fname(cpath), range = range(0, 8, 0, 13) })
  check("extract_sync: macro label is a preproc node", type(label) == "string" and label:find("preproc") ~= nil, label)
  check("extract_sync: continuation line kept", table.concat(lines, "\n"):find("(x) + (x)", 1, true) ~= nil)
end

-- extract (async wrapper): with no LSP attached it falls back to extract_sync
-- and calls cb synchronously.
do
  local hpath = vim.fn.tempname() .. ".h"
  local f = assert(io.open(hpath, "w"))
  f:write("static int one(void)\n{\n    return 1;\n}\n")
  f:close()
  local got_lines, got_label
  resolver.extract({ uri = vim.uri_from_fname(hpath), range = range(0, 11, 0, 14) }, 0, function(lines, label)
    got_lines, got_label = lines, label
  end)
  vim.wait(200, function()
    return got_lines ~= nil
  end, 10)
  check("extract: no-LSP path falls back", got_label == "function_definition", tostring(got_label))
  check("extract: fallback returned the body", got_lines ~= nil and table.concat(got_lines, "\n"):find("return 1", 1, true) ~= nil)
end

print("")
print(fails == 0 and "ALL RESOLVER TESTS PASSED" or (fails .. " FAILURE(S)"))
```

- [ ] **Step 2: 失敗を確認する**

Run: `nvim --headless --clean -u NONE -c "luafile tests/resolver_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: エラー（`resolver._symbol_range` が nil → attempt to call）。「新 API 不在で red」が確認できれば良い

- [ ] **Step 3: Commit**

```bash
git add tests/resolver_spec.lua
git commit -m "Add failing spec for documentSymbol-based extraction"
```

---

### Task 2: resolver.lua を documentSymbol 化する

**Files:**
- Modify: `lua/inline-explorer/resolver.lua`（全面書き換え）

**Interfaces:**
- Consumes: なし（このモジュールは自己完結）
- Produces: `M.locate`（不変）、`M._symbol_range` / `M.extract_sync` / `M.extract(loc, source_bufnr, cb)` / `M.extract_heuristic`（Task 1 の仕様どおり）。Task 3 の expander/inliner がこの `M.extract` を使う

- [ ] **Step 1: `lua/inline-explorer/resolver.lua` を次の内容に全面置換する**

```lua
-- Resolver: given an identifier name, ask the language server where it is
-- defined, then ask it for the definition's full range.
--
-- Resolution is name-based (workspace/symbol) on purpose: the reading view is a
-- copy buffer no server is attached to, and nested expansions live on inserted
-- text with no real file position. A name lookup works at any depth, and both
-- requests are language-agnostic, so nothing here is tied to a single server.
--
-- Extraction asks the same server for textDocument/documentSymbol on the
-- definition's file and takes the symbol's full range -- no per-language node
-- tables. tree-sitter (a generic same-line-ancestor heuristic) and a brace
-- counter remain as fallbacks when no server range is available.
local M = {}

-- Ask whichever server is attached to the source buffer where `name` is defined.
-- Calls cb(location, err) where location = { uri, range, kind, name }.
function M.locate(name, source_bufnr, cb)
  local bufnr = (source_bufnr and vim.api.nvim_buf_is_valid(source_bufnr)) and source_bufnr or 0
  if #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
    return cb(nil, "no language server attached to the source buffer")
  end

  vim.lsp.buf_request_all(bufnr, "workspace/symbol", { query = name }, function(results)
    local all = {}
    for _, r in pairs(results or {}) do
      for _, s in ipairs(r.result or {}) do
        all[#all + 1] = s
      end
    end
    if #all == 0 then
      return cb(nil, "no symbol named '" .. name .. "'")
    end

    -- Prefer an exact-name match; servers fuzzy-match otherwise.
    local pick
    for _, s in ipairs(all) do
      if s.name == name then
        pick = s
        break
      end
    end
    pick = pick or all[1]

    local loc = pick.location
    cb({ uri = loc.uri, range = loc.range, kind = pick.kind, name = pick.name }, nil)
  end)
end

-- Map an LSP SymbolKind to the label consumers expect: function-ish kinds
-- become "function_definition" (the inliner keys its function path off that
-- exact string); anything else becomes the lowercase kind name.
local FUNCTION_KINDS = { [6] = true, [9] = true, [12] = true } -- Method, Constructor, Function

local function kind_label(kind)
  if FUNCTION_KINDS[kind] then
    return "function_definition"
  end
  local name = vim.lsp.protocol.SymbolKind[kind]
  return type(name) == "string" and name:lower() or "symbol"
end

local function le(a, b) -- position a <= b
  return a.line < b.line or (a.line == b.line and a.character <= b.character)
end

local function contains(outer, inner)
  return le(outer.start, inner.start) and le(inner["end"], outer["end"])
end

local function same_range(a, b)
  return a.start.line == b.start.line
    and a.start.character == b.start.character
    and a["end"].line == b["end"].line
    and a["end"].character == b["end"].character
end

-- Pick the definition's full range out of a documentSymbol response. Handles
-- both shapes: hierarchical DocumentSymbol[] (range + children) and flat
-- SymbolInformation[] (location.range, name-matched). The deepest symbol whose
-- range contains -- and is wider than -- `ref_range` wins; a range identical
-- to ref_range is a name-only range and is rejected so extraction falls back
-- to tree-sitter instead of splicing a bare name. Returns (range, label).
function M._symbol_range(symbols, ref_range, name)
  local best, best_label
  local function consider(range, kind)
    if contains(range, ref_range) and not same_range(range, ref_range) then
      if not best or contains(best, range) then
        best, best_label = range, kind_label(kind)
      end
    end
  end
  local function walk(list)
    for _, s in ipairs(list or {}) do
      if s.range then -- hierarchical DocumentSymbol
        consider(s.range, s.kind)
        walk(s.children)
      elseif s.location and s.location.range and (name == nil or s.name == name) then
        consider(s.location.range, s.kind) -- flat SymbolInformation
      end
    end
  end
  walk(symbols)
  return best, best_label
end

-- Resolve the tree-sitter language for a buffer. A buffer that was only
-- `bufload`ed (e.g. a header the definition lives in) often has no filetype yet,
-- so fall back to matching on its file name.
local function buffer_lang(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == "" then
    ft = vim.filetype.match({ buf = bufnr, filename = vim.api.nvim_buf_get_name(bufnr) }) or ""
  end
  return vim.treesitter.language.get_lang(ft) or ft
end

-- Synchronous fallback extraction, used when no server range is available.
-- Table-free: the definition node is taken to be the outermost named ancestor
-- of the location that starts on the located line (or up to 3 lines above, for
-- return types / attributes on their own line). For C functions this naturally
-- yields the node type "function_definition" as the label. Without a parser,
-- the brace heuristic is the last resort.
function M.extract_sync(loc)
  local bufnr = vim.uri_to_bufnr(loc.uri)
  vim.fn.bufload(bufnr)
  local srow = loc.range.start.line
  local scol = loc.range.start.character

  -- `.h` headers are often detected as C++ while only the C parser is installed,
  -- so try the detected language, then fall back to C / C++.
  local seen = {}
  for _, lang in ipairs({ buffer_lang(bufnr), "c", "cpp" }) do
    if lang and lang ~= "" and not seen[lang] then
      seen[lang] = true
      local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
      if ok and parser then
        local root = parser:parse()[1]:root()
        local node = root:named_descendant_for_range(srow, scol, srow, scol)
        local best
        while node and node:parent() do -- stop before the whole-file root
          local a = node:range()
          if a >= srow - 3 and a <= srow then
            best = node
          end
          node = node:parent()
        end
        if best then
          local a, _, b, _ = best:range()
          return vim.api.nvim_buf_get_lines(bufnr, a, b + 1, false), best:type()
        end
        break -- parsed fine but nothing plausible here
      end
    end
  end

  return M.extract_heuristic(bufnr, srow), "heuristic"
end

-- Extract the definition at `loc`. Asks the server attached to `source_bufnr`
-- for the target document's symbols and uses the returned full range; falls
-- back to extract_sync when there is no server, no response, or no usable
-- range. Calls cb(lines, label) -- possibly synchronously (fallback path).
function M.extract(loc, source_bufnr, cb)
  local bufnr = (source_bufnr and vim.api.nvim_buf_is_valid(source_bufnr)) and source_bufnr or 0
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return cb(M.extract_sync(loc))
  end

  -- The definition file may not be open anywhere; load it and attach the
  -- source buffer's clients so the server learns about the document.
  local target = vim.uri_to_bufnr(loc.uri)
  vim.fn.bufload(target)
  for _, c in ipairs(clients) do
    vim.lsp.buf_attach_client(target, c.id)
  end

  local params = { textDocument = { uri = loc.uri } }
  vim.lsp.buf_request_all(target, "textDocument/documentSymbol", params, function(results)
    local range, label
    for _, r in pairs(results or {}) do
      if r.result then
        range, label = M._symbol_range(r.result, loc.range, loc.name)
        if range then
          break
        end
      end
    end
    if range then
      local lines = vim.api.nvim_buf_get_lines(target, range.start.line, range["end"].line + 1, false)
      if #lines > 0 then
        return cb(lines, label)
      end
    end
    cb(M.extract_sync(loc))
  end)
end

-- Last resort when no tree-sitter parser is available. Brace-oriented, so it
-- only really helps C-family languages; anything else needs a parser installed.
function M.extract_heuristic(bufnr, srow)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local first = vim.api.nvim_buf_get_lines(bufnr, srow, srow + 1, false)[1] or ""

  if first:match("^%s*#%s*define") then
    local out = {}
    for i = srow, total - 1 do
      local l = vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1] or ""
      out[#out + 1] = l
      if not l:match("\\%s*$") then
        break
      end
    end
    return out
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, srow, math.min(total, srow + 500), false)
  local depth, started, out = 0, false, {}
  for _, l in ipairs(lines) do
    out[#out + 1] = l
    for c in l:gmatch(".") do
      if c == "{" then
        depth, started = depth + 1, true
      elseif c == "}" then
        depth = depth - 1
      end
    end
    if started and depth <= 0 then
      break
    end
    if not started and l:find(";") then
      break -- prototype / forward declaration, no body
    end
  end
  return out
end

return M
```

- [ ] **Step 2: resolver_spec green 確認**

Run: `nvim --headless --clean -u NONE -c "luafile tests/resolver_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: `ALL RESOLVER TESTS PASSED`

- [ ] **Step 3: 表が消えたことを確認**

Run: `grep -nE "DEFINITION_NODES|NODE_PATTERNS|is_definition" lua/inline-explorer/resolver.lua`
Expected: 出力なし

- [ ] **Step 4: 他 spec が壊れていないことを確認（expander/inliner は Task 3 で更新するため、この時点で旧 extract 呼び出しが残っているが、それらは LSP 必須経路でありヘッドレステストに現れない）**

Run: `nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!" 2>&1 | tail -1`
Expected: `ALL SUBSTITUTE TESTS PASSED`

Run: `nvim --headless --clean -u NONE -c "luafile tests/ir_spec.lua" -c "qa!" 2>&1 | tail -1`
Expected: `ALL IR TESTS PASSED`

Run: `nvim --headless --clean -u NONE -c "luafile tests/macro_spec.lua" -c "qa!" 2>&1 | tail -1`
Expected: `ALL MACRO TESTS PASSED`

- [ ] **Step 5: Commit**

```bash
git add lua/inline-explorer/resolver.lua
git commit -m "Resolve definition ranges via textDocument/documentSymbol

Ask the server for the definition's full range instead of matching
tree-sitter node types against a hand-written per-language table.
DEFINITION_NODES and the suffix patterns are gone; tree-sitter (a
generic same-line-ancestor heuristic) and the brace counter remain as
fallbacks when no server range is available. extract is now async
(cb-style) since documentSymbol is an LSP round trip; call sites are
updated in the next commit."
```

---

### Task 3: 呼び出し側の非同期化 + expander smoke spec

**Files:**
- Create: `tests/expander_spec.lua`
- Modify: `lua/inline-explorer/expander.lua:44-58`（`M.expand` の locate コールバック内）
- Modify: `lua/inline-explorer/inliner.lua:47-81`（`M.smart` の locate コールバック内）

**Interfaces:**
- Consumes: Task 2 の `resolver.extract(loc, source_bufnr, cb)`（cb は同期呼び出しの可能性あり）
- Produces: なし（外部挙動は不変。expander_spec が resolver を stub して splice 経路を検証）

- [ ] **Step 1: `tests/expander_spec.lua` を作成する（TDD red — 現行の同期 extract 呼び出しでは stub が機能せず splice されない）**

```lua
-- Expander smoke test with a stubbed resolver: verifies the async
-- locate -> extract -> splice pipeline, indentation, header comments,
-- recursion-guard bookkeeping and undo -- all without an LSP.
--   nvim --headless --clean -u NONE -c "luafile tests/expander_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))

local resolver = require("inline-explorer.resolver")
local view = require("inline-explorer.view")
local expander = require("inline-explorer.expander")
require("inline-explorer.config").setup({})

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and ("\n----\n" .. tostring(d) .. "\n----") or ""))
  end
end

-- Stub the resolver: cb-style, immediate, no LSP involved.
resolver.locate = function(name, _, cb)
  cb({
    uri = "file:///fake.c",
    range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 6 } },
    kind = 12,
    name = name,
  })
end
resolver.extract = function(_, _, cb)
  cb({ "static int helper(int x)", "{", "    return x + 1;", "}" }, "function_definition")
end

-- Source buffer -> reading view.
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "int main(void)", "{", "    int r = helper(1);", "}" })
vim.bo.filetype = "c"
local vbuf = view.open()
check("view opened", view.current() ~= nil)

-- Expand the call under the cursor.
local col = ("    int r = helper(1);"):find("helper") - 1
vim.api.nvim_win_set_cursor(0, { 3, col })
expander.expand()
local done = vim.wait(1000, function()
  return vim.api.nvim_buf_line_count(vbuf) > 4
end, 10)
check("expansion spliced", done)

local lines = vim.api.nvim_buf_get_lines(vbuf, 0, -1, false)
local text = table.concat(lines, "\n")
check("header comment present", text:find("/* v helper (function_definition) */", 1, true) ~= nil, text)
check("footer comment present", text:find("/* ^ helper */", 1, true) ~= nil, text)
check("body indented one level past the call line", text:find("\n      static int helper", 1, true) ~= nil, text)
check("view stays nomodifiable", vim.bo[vbuf].modifiable == false)
check("one expansion node tracked", #view.current().nodes == 1)

-- Recursion guard: cursor inside the expansion, same name -> no second splice.
local before = vim.api.nvim_buf_line_count(vbuf)
for i, l in ipairs(lines) do
  local c = l:find("static int helper", 1, true)
  if c then
    vim.api.nvim_win_set_cursor(0, { i, l:find("helper", 1, true) - 1 })
    break
  end
end
expander.expand()
vim.wait(200, function()
  return false
end, 50)
check("recursion guard blocks re-expansion", vim.api.nvim_buf_line_count(vbuf) == before)

-- Undo restores the pre-expansion snapshot.
require("inline-explorer.history").undo()
check("undo restores the original view", vim.api.nvim_buf_line_count(vbuf) == 4)

print("")
print(fails == 0 and "ALL EXPANDER TESTS PASSED" or (fails .. " FAILURE(S)"))
```

- [ ] **Step 2: red を確認する**

Run: `nvim --headless --clean -u NONE -c "luafile tests/expander_spec.lua" -c "qa!" 2>&1 | grep -E "FAIL|PASSED|FAILURE"`
Expected: `FAIL  expansion spliced` を含む（現行 expander は `local body, label = resolver.extract(loc)` と同期呼び出しのため、cb-style stub からは nil が返り splice されない）

- [ ] **Step 3: `lua/inline-explorer/expander.lua` の `M.expand` 内 locate コールバックを cb ネストに変更する**

現在の

```lua
  resolver.locate(name, st.source_bufnr, function(loc, err)
    if not loc then
      return vim.schedule(function()
        notify(err or "not found")
      end)
    end
    local body, label = resolver.extract(loc)
    vim.schedule(function()
      if not body or #body == 0 then
        return notify("could not extract a body for '" .. name .. "'")
      end
      M._insert(st, bufnr, lnum, name, body, label)
    end)
  end)
```

を次に置き換える:

```lua
  resolver.locate(name, st.source_bufnr, function(loc, err)
    if not loc then
      return vim.schedule(function()
        notify(err or "not found")
      end)
    end
    resolver.extract(loc, st.source_bufnr, function(body, label)
      vim.schedule(function()
        if not body or #body == 0 then
          return notify("could not extract a body for '" .. name .. "'")
        end
        M._insert(st, bufnr, lnum, name, body, label)
      end)
    end)
  end)
```

- [ ] **Step 4: `lua/inline-explorer/inliner.lua` の `M.smart` 内 locate コールバックを cb ネストに変更する**

現在の

```lua
  resolver.locate(ident, st.source_bufnr, function(loc)
    if not loc then
      return block_fallback() -- expander.expand re-resolves and reports if unknown
    end
    local lines, label = resolver.extract(loc)

    if fname and label == "function_definition" then
```

から関数末尾までを次に置き換える（内側のロジックは無変更、`resolver.extract` の cb で包むだけ）:

```lua
  resolver.locate(ident, st.source_bufnr, function(loc)
    if not loc then
      return block_fallback() -- expander.expand re-resolves and reports if unknown
    end
    resolver.extract(loc, st.source_bufnr, function(lines, label)
      if fname and label == "function_definition" then
        local N = (st.subst_n or 0) + 1
        local ok, new = pcall(substitute.inline_in_buffer, src, row, col, table.concat(lines or {}, "\n"), N, config.options.mode)
        if ok and new then
          return vim.schedule(function()
            st.subst_n = N
            view.rewrite(st, bufnr, new, row)
          end)
        end
        return block_fallback() -- e.g. variadic function
      end

      -- Not a confirmed function (macro, or heuristic-extracted from a header):
      -- try an in-place macro expansion via clangd hover; block-paste only if that
      -- yields nothing (so a plain function-signature hover never gets spliced).
      macro.fetch_expansion(st, row, col, function(exp)
        if not exp or #exp == 0 then
          return block_fallback()
        end
        vim.schedule(function()
          local ok, new = pcall(macro.replace_in_src, src, row, col, exp)
          if ok and new then
            view.rewrite(st, bufnr, new, row)
          else
            expander.expand()
          end
        end)
      end)
    end)
  end)
```

- [ ] **Step 5: green 確認（expander_spec + 全既存 spec）**

Run: `nvim --headless --clean -u NONE -c "luafile tests/expander_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: `ALL EXPANDER TESTS PASSED`

Run（残り4本）: resolver_spec / ir_spec / substitute_spec / macro_spec
Expected: すべて `ALL ... PASSED`

- [ ] **Step 6: 同期 extract 呼び出しの残骸が無いか確認**

Run: `grep -n "resolver.extract(loc)" lua/inline-explorer/*.lua`
Expected: 出力なし

- [ ] **Step 7: Commit**

```bash
git add tests/expander_spec.lua lua/inline-explorer/expander.lua lua/inline-explorer/inliner.lua
git commit -m "Adopt async extract in expander/inliner; add expander smoke spec

The smoke spec stubs the resolver (cb-style, no LSP) and exercises the
full expand pipeline headlessly: splice, indentation, header comments,
extmark bookkeeping, the recursion guard, and snapshot undo."
```

---

### Task 4: ドキュメント更新 + 最終確認

**Files:**
- Modify: `README.md`（How it works の Resolver 項、Known limitations の Coverage 項）
- Modify: `DESIGN.md`（Components の Resolver 項）

**Interfaces:**
- Consumes: なし
- Produces: なし（文書のみ）

- [ ] **Step 1: README.md の "How it works" Resolver 項を置き換える**

現在の

```markdown
- **Resolver** — looks the symbol up by name via the server's `workspace/symbol`,
  then extracts the exact definition with tree-sitter (a language-agnostic node
  matcher, with a brace heuristic as last resort). Name-based lookup is what makes
  nesting possible: inserted text has no real file position to query by.
```

を次に置き換える:

```markdown
- **Resolver** — looks the symbol up by name via the server's `workspace/symbol`,
  then asks the server for the definition's full range via
  `textDocument/documentSymbol` (tree-sitter extraction and a brace heuristic
  remain as fallbacks when no server range is available). Name-based lookup is
  what makes nesting possible: inserted text has no real file position to query by.
```

- [ ] **Step 2: README.md の "Known limitations" Coverage 項を置き換える**

現在の

```markdown
- **Coverage depends on the server and parser.** A definition is only found if the
  server's `workspace/symbol` returns it and a tree-sitter parser is installed for
  the language; without a parser the brace-based fallback only handles C-family
  syntax.
```

を次に置き換える:

```markdown
- **Coverage depends on the server.** A definition is only found if the server's
  `workspace/symbol` returns it, and its exact extent comes from the server's
  `textDocument/documentSymbol`. Without a usable server range, a tree-sitter
  parser (if installed) or a C-family brace heuristic takes over.
```

- [ ] **Step 3: DESIGN.md の Components Resolver 項を置き換える**

現在の

```markdown
- **Resolver** (`resolver.lua`) — `name -> definition location` via the attached
  server's `workspace/symbol` (any language), then `location -> body lines` via
  tree-sitter with a language-agnostic node matcher (brace heuristic fallback).
```

を次に置き換える:

```markdown
- **Resolver** (`resolver.lua`) — `name -> definition location` via the attached
  server's `workspace/symbol` (any language), then `location -> body lines` via
  the server's `textDocument/documentSymbol` full range (tree-sitter, then a
  brace heuristic, as fallbacks when no server range is available).
```

- [ ] **Step 4: 全 spec 最終確認（5本）**

```sh
nvim --headless --clean -u NONE -c "luafile tests/resolver_spec.lua" -c "qa!"
nvim --headless --clean -u NONE -c "luafile tests/expander_spec.lua" -c "qa!"
nvim --headless --clean -u NONE -c "luafile tests/ir_spec.lua" -c "qa!"
nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!"
nvim --headless --clean -u NONE -c "luafile tests/macro_spec.lua" -c "qa!"
```
Expected: すべて `ALL ... PASSED`

- [ ] **Step 5: Commit**

```bash
git add README.md DESIGN.md
git commit -m "Docs: resolver now takes definition ranges from documentSymbol"
```

---

## Self-Review 済み事項

- Spec P3 対応: documentSymbol 化 = Task 2、表削除 = Task 2 Step 3 で grep 検証、フォールバック降格 = extract_sync/extract_heuristic、受け入れ条件充足
- 型整合: `M.extract(loc, source_bufnr, cb)` は Task 1（spec）・Task 2（実装）・Task 3（呼び出し側）で同一。`_symbol_range(symbols, ref_range, name)` も同一
- ラベル互換: inliner の `label == "function_definition"` 判定は LSP 経路（kind マップ）・fallback 経路（tree-sitter node type）の両方で成立
- 実 LSP（clangd）相手の end-to-end は自動テスト外（ヘッドレスで clangd 起動はスコープ外）。`_symbol_range` のフィクスチャテスト + フォールバック実測 + 実機確認は今後の手動確認事項として残る — README/DESIGN に嘘は書いていない
- プレースホルダなし。全ステップ実コード・実コマンド・期待出力付き
