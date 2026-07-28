# macro ExpandMacro tweak 化 (P4) 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** マクロ展開の取得を clangd hover markdown のスクレイピングから clangd の ExpandMacro tweak（`codeAction` → `executeCommand` → `applyEdit` インターセプト）に置き換える。hover は fallback に降格。

**Architecture:** `macro.fetch_expansion(st, row, col, cb)` の署名・cb 契約（展開行 or nil）は不変 — 内部で tweak 経路を先に試し、失敗/タイムアウト/未対応時に既存 hover 経路へ。applyEdit は client のハンドラ一時差替えでインターセプトし、実ファイルには当てず `newText` だけ取り出す。view への splice（`replace_in_src`）は無変更。inliner も無変更。

**Tech Stack:** Lua (Neovim 0.10+), vim.lsp (codeAction / executeCommand / applyEdit), clangd (実機; テストはフィクスチャ)

**Spec:** `docs/superpowers/specs/2026-07-28-redesign-and-pbt-design.md` の P4（本 plan の範囲。P5 は別 plan）

## Global Constraints

- ユーザー向け API・キーマップ・コマンド不変。`macro.fetch_expansion(st, row, col, cb)` / `macro.replace_in_src(src, row, col, exp_lines)` の署名・契約不変（inliner.lua は触らない）
- cb は**正確に1回**呼ばれる（tweak 経路のタイムアウト・エラー・二重応答すべてで保証 — P3 レビューの教訓）
- tweak 経路はタイムアウト付き（既定 2000ms）。タイムアウト/失敗 → hover fallback → それも空なら cb(nil)（呼び出し側の block-paste fallback が発火、現行どおり）
- hover 経路（`_markup` / `_expansion_lines` とその挙動）は無変更で存続
- 実 clangd との end-to-end は自動テスト範囲外（ヘッドレスで clangd なし）。純粋関数（action 選択・edit 抽出）をフィクスチャで検証し、配線はコードレビューで担保 — P3 と同じ扱い
- 各タスク完了時、全 6 spec green:
  `nvim --headless --clean -u NONE -c "luafile tests/<spec>.lua" -c "qa!"`
  対象: macro_spec, resolver_spec, expander_spec, ir_spec, substitute_spec（+ Task 3 以降も同じ）
- nvim が PATH に無い環境では入手済みバイナリのフルパスで実行してよい
- コメントは英語（既存流儀）。コミットメッセージは英語

---

### Task 0: ブランチ作成

- [ ] **Step 1:**

```bash
cd /home/claude/inline-explorer.nvim
git checkout main && git pull && git checkout -b p4-macro-expandmacro
```

（Task 1 の実装者が最初に実行）

---

### Task 1: macro_spec に tweak 純粋関数の spec を先に書く（TDD red）

**Files:**
- Modify: `tests/macro_spec.lua`（末尾の print 前に追記）

**Interfaces:**
- Consumes: なし（テストのみ）
- Produces: Task 2 が満たす内部 API 仕様:
  - `M._pick_expand_action(actions) -> command|nil` — codeAction 応答（`Command` 直置き / `CodeAction` ラップの両形式）から、title が `Expand macro` で始まるものの実行可能 command（`{ command = string, arguments = ... }` を持つ table）を返す。無ければ nil。非 table 要素・title 無しは無視
  - `M._edit_lines(workspace_edit, uri) -> lines|nil` — `WorkspaceEdit` の `changes[uri]` または `documentChanges[]`（`textDocument.uri == uri`）から先頭 TextEdit の `newText` を行配列にして返す（前後の空行 trim）。該当 uri なし / newText 空 → nil

- [ ] **Step 1: `tests/macro_spec.lua` の最終 `print("")` の直前に追記する**

```lua
-- _pick_expand_action: choose clangd's "Expand macro" tweak from a codeAction
-- response, in both shapes the protocol allows.
do
  local as_code_action = {
    { title = "Inline function", kind = "refactor.inline", command = { command = "clangd.applyTweak", arguments = { { tweakID = "InlineFunction" } } } },
    { title = "Expand macro READ_ONCE", kind = "refactor", command = { command = "clangd.applyTweak", arguments = { { tweakID = "ExpandMacro" } } } },
  }
  local cmd = macro._pick_expand_action(as_code_action)
  check("pick: CodeAction shape -> inner command", cmd ~= nil and cmd.command == "clangd.applyTweak", cmd and vim.inspect(cmd))
  check("pick: picks the Expand macro action, not Inline", cmd ~= nil and cmd.arguments[1].tweakID == "ExpandMacro", cmd and vim.inspect(cmd))

  local as_command = {
    { title = "Expand macro FOO", command = "clangd.applyTweak", arguments = { { tweakID = "ExpandMacro" } } },
  }
  local cmd2 = macro._pick_expand_action(as_command)
  check("pick: bare Command shape accepted", cmd2 ~= nil and cmd2.command == "clangd.applyTweak", cmd2 and vim.inspect(cmd2))

  check("pick: no expand action -> nil", macro._pick_expand_action({
    { title = "Add include", kind = "quickfix" },
  }) == nil)
  check("pick: garbage input tolerated", macro._pick_expand_action({ 42, "x", {} }) == nil)
  check("pick: nil input tolerated", macro._pick_expand_action(nil) == nil)
end

-- _edit_lines: extract the expansion text from the applyEdit a tweak sends.
do
  local uri = "file:///src/x.c"
  local range = { start = { line = 3, character = 8 }, ["end"] = { line = 3, character = 12 } }

  local changes_shape = { changes = { [uri] = { { range = range, newText = "(0x3U << 0)" } } } }
  check("edit: changes shape -> lines", table.concat(macro._edit_lines(changes_shape, uri) or {}, "\n") == "(0x3U << 0)")

  local doc_changes_shape = {
    documentChanges = {
      { textDocument = { uri = "file:///other.c", version = 1 }, edits = { { range = range, newText = "WRONG" } } },
      { textDocument = { uri = uri, version = 1 }, edits = { { range = range, newText = "({\n    do { } while (0);\n    v;\n})" } } },
    },
  }
  local lines = macro._edit_lines(doc_changes_shape, uri)
  check("edit: documentChanges shape, uri-matched", lines ~= nil and lines[1] == "({" and lines[#lines] == "})", lines and vim.inspect(lines))

  check("edit: wrong uri -> nil", macro._edit_lines(changes_shape, "file:///nope.c") == nil)
  check("edit: empty newText -> nil", macro._edit_lines({ changes = { [uri] = { { range = range, newText = "" } } } }, uri) == nil)
  check("edit: nil input tolerated", macro._edit_lines(nil, uri) == nil)
end
```

- [ ] **Step 2: 失敗を確認する**

Run: `nvim --headless --clean -u NONE -c "luafile tests/macro_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: エラー（`macro._pick_expand_action` が nil → attempt to call）。新 API 不在で red 確認

- [ ] **Step 3: Commit**

```bash
git add tests/macro_spec.lua
git commit -m "Add failing spec for the ExpandMacro tweak helpers"
```

---

### Task 2: macro.lua に tweak 経路を実装する

**Files:**
- Modify: `lua/inline-explorer/macro.lua`（`M.fetch_expansion` を置換、ヘルパ追加、モジュールコメント更新）

**Interfaces:**
- Consumes: 既存 `markup` / `expansion_lines`（無変更）
- Produces: `M._pick_expand_action` / `M._edit_lines`（Task 1 仕様）、`M.fetch_expansion`（署名不変、内部 tweak→hover）

- [ ] **Step 1: モジュール冒頭コメント（`macro.lua:1-4`）を次に置き換える**

```lua
-- Macro expansion: a macro has no type or structured body to transform, so we
-- ask the live clangd. Preferred path: the ExpandMacro tweak (codeAction ->
-- executeCommand), whose workspace/applyEdit we intercept -- the edit is never
-- applied to the real file, we only take its newText as the expansion. clangd
-- runs the real preprocessor, so the result respects include paths / #define /
-- #ifdef. Fallback: scrape the expansion from textDocument/hover markdown
-- (older clangd, tweak failure, timeout).
```

- [ ] **Step 2: 既存 `M.fetch_expansion`（`macro.lua:117-136`）を削除し、同じ位置に以下を挿入する**

```lua
-- How long the tweak path may take before we give up and fall back to hover.
local TWEAK_TIMEOUT_MS = 2000

-- Pick clangd's "Expand macro" tweak out of a codeAction response. The
-- protocol allows two shapes: a bare Command, or a CodeAction wrapping one.
function M._pick_expand_action(actions)
  if type(actions) ~= "table" then
    return nil
  end
  for _, a in ipairs(actions) do
    if type(a) == "table" and type(a.title) == "string" and a.title:find("^Expand macro") then
      local cmd = (type(a.command) == "table") and a.command or a
      if type(cmd.command) == "string" and cmd.command ~= "" then
        return cmd
      end
    end
  end
  return nil
end

-- Extract the expansion text the tweak's applyEdit carries for `uri`, as
-- trimmed lines. Handles both WorkspaceEdit shapes (changes / documentChanges).
function M._edit_lines(workspace_edit, uri)
  if type(workspace_edit) ~= "table" then
    return nil
  end
  local edits
  if type(workspace_edit.changes) == "table" and workspace_edit.changes[uri] then
    edits = workspace_edit.changes[uri]
  elseif type(workspace_edit.documentChanges) == "table" then
    for _, dc in ipairs(workspace_edit.documentChanges) do
      if type(dc) == "table" and dc.textDocument and dc.textDocument.uri == uri and type(dc.edits) == "table" then
        edits = dc.edits
        break
      end
    end
  end
  if type(edits) ~= "table" or #edits == 0 or type(edits[1].newText) ~= "string" then
    return nil
  end
  local out = vim.split(edits[1].newText, "\n", { plain = true })
  while out[1] and out[1]:match("^%s*$") do
    table.remove(out, 1)
  end
  while out[#out] and out[#out]:match("^%s*$") do
    table.remove(out)
  end
  if #out == 0 then
    return nil
  end
  return out
end

-- client.request became a colon-method in 0.11; 0.10 uses the dot form.
local function client_request(client, method, params, handler, bufnr)
  if vim.fn.has("nvim-0.11") == 1 then
    return client:request(method, params, handler, bufnr)
  end
  return client.request(method, params, handler, bufnr)
end

-- Fetch the expansion via the ExpandMacro tweak. Calls cb(lines|nil) exactly
-- once: on success with the applyEdit's newText lines, on any failure -- no
-- clangd, no tweak support, no action at this position, request error, or
-- timeout -- with nil so the caller can fall back.
local function fetch_via_tweak(st, row, col, cb)
  local client = vim.lsp.get_clients({ bufnr = st.source_bufnr, name = "clangd" })[1]
  if not client then
    return cb(nil)
  end
  local provider = (client.server_capabilities or {}).executeCommandProvider
  local cmds = (type(provider) == "table" and type(provider.commands) == "table") and provider.commands or {}
  if not vim.tbl_contains(cmds, "clangd.applyTweak") then
    return cb(nil)
  end

  local uri = vim.uri_from_bufnr(st.source_bufnr)
  local pos = { line = row, character = col }

  -- Exactly-once guard shared by the success path, every error path, and the
  -- timeout; also restores the intercepted applyEdit handler.
  local finished = false
  local prev_handler
  local function finish(lines)
    if finished then
      return
    end
    finished = true
    if prev_handler ~= nil or client.handlers["workspace/applyEdit"] ~= nil then
      client.handlers["workspace/applyEdit"] = prev_handler
    end
    cb(lines)
  end
  vim.defer_fn(function()
    finish(nil)
  end, TWEAK_TIMEOUT_MS)

  local ca_params = {
    textDocument = { uri = uri },
    range = { start = pos, ["end"] = pos },
    context = { diagnostics = {} },
  }
  client_request(client, "textDocument/codeAction", ca_params, function(err, actions)
    if finished then
      return
    end
    if err then
      return finish(nil)
    end
    local cmd = M._pick_expand_action(actions)
    if not cmd then
      return finish(nil)
    end

    -- Intercept the applyEdit this tweak will send back. Per-client handlers
    -- take precedence over the global vim.lsp.handlers, so only this client's
    -- applyEdit is diverted, and finish() restores the previous handler.
    prev_handler = client.handlers["workspace/applyEdit"]
    client.handlers["workspace/applyEdit"] = function(_, apply_params)
      finish(M._edit_lines(apply_params and apply_params.edit, uri))
      -- Tell the server the edit was applied -- it was, to our reading view.
      return { applied = true }
    end

    client_request(client, "workspace/executeCommand", {
      command = cmd.command,
      arguments = cmd.arguments,
    }, function(cerr)
      if cerr then
        finish(nil)
      end
      -- On success the reply carries no edit; the applyEdit interception (or
      -- the timeout) is what finishes the fetch.
    end, st.source_bufnr)
  end, st.source_bufnr)
end

-- Fetch a macro's expansion from clangd hover at (row, col). cb(lines|nil).
-- Fallback path: works on any clangd, but scrapes markdown.
local function fetch_via_hover(st, row, col, cb)
  if #vim.lsp.get_clients({ name = "clangd" }) == 0 then
    return cb(nil)
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(st.source_bufnr) },
    position = { line = row, character = col },
  }
  vim.lsp.buf_request_all(st.source_bufnr, "textDocument/hover", params, function(results)
    local md
    for _, r in pairs(results or {}) do
      if r.result and r.result.contents then
        md = markup(r.result.contents)
        break
      end
    end
    cb(md and md ~= "" and expansion_lines(md) or nil)
  end)
end

-- Fetch a macro's expansion at (row, col): ExpandMacro tweak first, hover as
-- fallback. cb(lines|nil), called exactly once.
function M.fetch_expansion(st, row, col, cb)
  fetch_via_tweak(st, row, col, function(lines)
    if lines and #lines > 0 then
      return cb(lines)
    end
    fetch_via_hover(st, row, col, cb)
  end)
end
```

- [ ] **Step 3: macro_spec green 確認**

Run: `nvim --headless --clean -u NONE -c "luafile tests/macro_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: `ALL MACRO TESTS PASSED`（既存 7 + 新 12 checks）

- [ ] **Step 4: 他 spec 無傷確認（resolver / expander / ir / substitute）**

Run（4本）: それぞれ `luafile tests/<spec>.lua`
Expected: すべて `ALL ... PASSED`

- [ ] **Step 5: Commit**

```bash
git add lua/inline-explorer/macro.lua
git commit -m "Fetch macro expansions via clangd's ExpandMacro tweak

Ask for the tweak through textDocument/codeAction and execute it via
workspace/executeCommand, intercepting the workspace/applyEdit it sends
back -- the edit is never applied to the real file; its newText becomes
the expansion spliced into the reading view. Exactly-once callback with
a timeout, falling back to the existing hover-markdown path (older
clangd, no tweak at the position, errors)."
```

---

### Task 3: ドキュメント更新 + 最終確認

**Files:**
- Modify: `README.md`（Macros 節 第1ビュレット）
- Modify: `DESIGN.md`（Macro expansion 節の hover 説明 + future-step 文）

**Interfaces:**
- Consumes: なし
- Produces: なし（文書のみ）

- [ ] **Step 1: README.md「Macros」節の `<leader>ei` ビュレットを置き換える**

現在の

```markdown
- **`<leader>ei`** (smart inline) replaces the macro use **in place** with its
  expansion, fetched from the **live clangd** (`textDocument/hover`), so it
  respects your include paths, `#define`s and `#ifdef` state. The query runs
  against the original source at the cursor, reliable at depth 0; large line
  shifts from prior expansions can misalign it.
```

を次に置き換える:

```markdown
- **`<leader>ei`** (smart inline) replaces the macro use **in place** with its
  expansion, fetched from the **live clangd** -- preferring the `ExpandMacro`
  tweak (its `workspace/applyEdit` is intercepted, never applied to the real
  file), with `textDocument/hover` scraping as the fallback -- so it respects
  your include paths, `#define`s and `#ifdef` state. The query runs against the
  original source at the cursor, reliable at depth 0; large line shifts from
  prior expansions can misalign it.
```

- [ ] **Step 2: DESIGN.md「Macro expansion (C-only)」節を更新する**

現在の

```markdown
Macros have no type and no guaranteed statement/expression structure, so the
substitution engine cannot handle them — a faithful expansion means running the
preprocessor. `macro.lua` therefore delegates to the live clangd:
`textDocument/hover` at the macro (read-only, no buffer edits), and the expansion
is pulled from the hover markdown (clangd puts `#define` and the expansion in one
code block separated by an "Expands to" marker; we take the part after it).
```

を次に置き換える:

```markdown
Macros have no type and no guaranteed statement/expression structure, so the
substitution engine cannot handle them — a faithful expansion means running the
preprocessor. `macro.lua` therefore delegates to the live clangd, preferring its
`ExpandMacro` tweak: the tweak is discovered via `textDocument/codeAction`,
executed via `workspace/executeCommand`, and the `workspace/applyEdit` it sends
back is intercepted — never applied to the real file — with its `newText` taken
as the expansion. When the tweak is unavailable (older clangd, no action at the
position, errors, timeout) the fallback scrapes `textDocument/hover` markdown
(clangd puts `#define` and the expansion in one code block separated by an
"Expands to" marker; we take the part after it).
```

さらに同節末尾の

```markdown
it. A future step could use clangd's `ExpandMacro` tweak for precise in-place
edits, at the cost of intercepting the `workspace/applyEdit` it would apply to the
real file.
```

を次に置き換える（前の行 `original source at the cursor, exact at depth 0; large line shifts can misalign` に続く形を保つ）:

```markdown
it. The `ExpandMacro` tweak path implements exactly the interception that an
earlier revision of this document described as a future step.
```

- [ ] **Step 3: 全 6 spec 最終確認**

```sh
nvim --headless --clean -u NONE -c "luafile tests/macro_spec.lua" -c "qa!"
nvim --headless --clean -u NONE -c "luafile tests/resolver_spec.lua" -c "qa!"
nvim --headless --clean -u NONE -c "luafile tests/expander_spec.lua" -c "qa!"
nvim --headless --clean -u NONE -c "luafile tests/ir_spec.lua" -c "qa!"
nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!"
```
Expected: すべて `ALL ... PASSED`

- [ ] **Step 4: Commit**

```bash
git add README.md DESIGN.md
git commit -m "Docs: macro expansion now prefers the ExpandMacro tweak"
```

---

## Self-Review 済み事項

- Spec P4 対応: tweak 起動 = Task 2、applyEdit インターセプト = `client.handlers` 一時差替え + `{ applied = true }` 応答、hover fallback 存続、位置ずれ制限は現状どおり文書化
- cb exactly-once: `finished` ガードが 成功 / codeAction エラー / action 不在 / executeCommand エラー / タイムアウト / 二重 applyEdit の全経路を覆う。ハンドラ復元は `finish()` に集約
- 型整合: `_pick_expand_action` / `_edit_lines` は Task 1（テスト）と Task 2（実装）で同一仕様
- 実 clangd 未検証の限界: codeAction の position-only range で ExpandMacro が返るか、applyEdit が単一 TextEdit か、は clangd 実機依存 — 純粋関数はフィクスチャで固定し、配線は fallback で守る設計。実機確認は手動 TODO
- inliner.lua 無修正（`fetch_expansion` 契約不変）
- プレースホルダなし
