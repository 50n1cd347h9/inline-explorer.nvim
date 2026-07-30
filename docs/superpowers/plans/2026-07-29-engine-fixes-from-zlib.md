# zlib が暴いたエンジン欠陥の修正 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** zlib を実ソース回帰に追加して見つかった 3 つのエンジン欠陥（うち 2 つは静かに誤ったコードを生成する）を直し、zlib spec を land できる状態にする。

**Architecture:** 3 件はいずれも独立した局所修正。E1 は `canalyze.enclosing_scope` のフォールバック、E5 は `canalyze.analyze_context` のインデント算出と文脈判定、E4 は `csrc.return_type` の型再構築。プロダクションコードを直すので、各修正は失敗するテストを先に書いてから入れる。

**Tech Stack:** Lua (Neovim 0.10+), gcc（生成コードの検証）

## 背景 — なぜこれを直すのか（すべて実測・最小再現済み）

zlib の実ソース回帰は 182 変換中 25 失敗した。レビュアーが各主張を独立に裁定した結果:

- **E1 が 17 件の原因**（当初診断の ~10 件は過少）。さらに 26 箇所が同じ未定義動作を生成しており、うち 9 箇所は「たまたま動いている」だけ
- **E5 は今この瞬間に静かに誤コンパイルする**。`hits++; step(a, n);` を 1 行に書いた caller で `hits` が 7 回実行される（正解 1 回）。当初「括弧なしループ本体のマイナーな問題」と診断されたが、根本原因は別
- **E4 は現在 0 件の原因**だが潜在 80 箇所。gcc 13 では implicit-int が警告どまりのため表に出ていないだけで、`-pedantic-errors` で確認済みのハードエラー、gcc 14 の C23 既定でも同様の見込み

E1・E5 は実プラグインが実際に受け取る入力（利用者の生バッファ）で起きる。カーネルは関数途中の `#ifdef` が標準的な書き方なので、E1 の影響は特に大きい。

## Global Constraints

- 各修正は **失敗するテストを先に**書き、それが赤であることを確認してから実装する
- 生成された C は **gcc でコンパイルし実行して**元の意味論と一致することを確認する（既存 `substitute_spec` の `compiles` / `run_ok` の流儀）
- 既存 10 スイートが緑のままであること。特に `real_cjson_spec` が **188/188/188 を維持**すること — cJSON は今回の欠陥に当たっていないので、数字が動いたら退行
- `tests/lib/real_source.lua` と `tests/real_zlib_spec.lua` は Task 4 まで触らない
- nvim が PATH に無い環境では入手済みバイナリのフルパスで実行してよい
- コメントは英語。コミットメッセージは英語

---

### Task 0: ブランチ

現在 `real-source-zlib` ブランチで作業中（zlib spec は commit 済み、25 件失敗の状態）。そのまま続ける。新しいブランチは切らない。

---

### Task 1: E1 — ERROR ノードで衝突検出が無効化される

**Files:**
- Modify: `tests/substitute_spec.lua`（回帰ケース追加）
- Modify: `lua/inline-explorer/canalyze.lua`（`enclosing_scope`）

**欠陥:** `enclosing_scope` は `call` から親を辿って `function_definition` を探すが、caller に関数途中の `#ifdef` があると tree-sitter がその領域を `ERROR` ノードにするため見つからず、**空スコープを返す**。空スコープでは衝突リネームが一切効かないので、callee の引数名が caller の変数名と衝突していると `T *name = (name);` を生成する。C の宣言スコープ規則により右辺は宣言中の未初期化ローカルを指す。

- [ ] **Step 1: 回帰ケースを `tests/substitute_spec.lua` の最終 print 前に追加する**

```lua
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
  check("case22 colliding param renamed despite an ERROR ancestor",
    t:find("s__ie1", 1, true) ~= nil and not t:find("int %*s = %(s%);"), t)

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
```

- [ ] **Step 2: red を確認する**

Run: `nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n' | grep -E "case22|FAILURE"`
Expected: `FAIL  case22 colliding param renamed despite an ERROR ancestor`（生成物に `int *s = (s);` が出ている）

- [ ] **Step 3: `lua/inline-explorer/canalyze.lua` の `enclosing_scope` を直す**

現在の「`function_definition` が見つからなければ空集合を返す」を、**木の根まで遡って同じ問い合わせを掛ける**フォールバックに置き換える。名前を余分に集めることは安全側に倒れる（余計にリネームしても `build_bind` はリネーム後の名前を使うので意味は変わらず、むしろ caller のファイルスコープ名を隠さなくなる）。

`enclosing_scope` を次に置き換える:

```lua
-- Declarator identifier names visible where the call sits.
--
-- Normally that is the caller's enclosing function. When tree-sitter cannot
-- build one -- a preprocessor conditional straddling braces turns the region
-- into an ERROR node, which is ordinary kernel style -- there is no
-- function_definition ancestor to scope by. Returning nothing there would
-- switch collision renaming off silently, and a callee parameter sharing a
-- name with a caller variable would be emitted as `T name = (name);`, whose
-- initialiser C resolves to the new, uninitialised local. So fall back to the
-- whole translation unit: over-approximating the scope only ever renames more
-- than strictly necessary, which is harmless, while under-approximating it
-- produces code that reads uninitialised memory.
local function enclosing_scope(call, src)
  local scope = call
  while scope and scope:type() ~= "function_definition" do
    local parent = scope:parent()
    if not parent then
      break -- no enclosing function: `scope` is now the root, use it
    end
    scope = parent
  end
  local set = {}
  if not scope then
    return set
  end
  local qs = {
    "(parameter_declaration declarator: (_) @d)",
    "(init_declarator declarator: (_) @d)",
    "(declaration declarator: (_) @d)", -- covers array/pointer declarators, not just plain identifiers
  }
  for _, q in ipairs(qs) do
    for _, d in ipairs(C.query_nodes(scope, src, q)) do
      local nm = d:type() == "identifier" and C.text(d, src) or C.decl_name(d, src)
      if nm then
        set[nm] = true
      end
    end
  end
  return set
end
```

（`C` は `canalyze.lua` 冒頭の `require("inline-explorer.csrc")` のローカル名。既存の記述に合わせること。）

- [ ] **Step 4: green と、既存が壊れていないことを確認する**

Run: `nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n' | tail -2`
Expected: `ALL SUBSTITUTE TESTS PASSED`

Run（残り 8 本）: `gen_spec` / `properties_spec` / `pbt_spec` / `ir_spec` / `macro_spec` / `resolver_spec` / `expander_spec` / `bench_lib_spec`
Expected: すべて `ALL ... PASSED`

Run: `nvim --headless --clean -u NONE -c "luafile tests/real_cjson_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n' | tail -2`
Expected: `engine-accepted=188  built+passed=188`（変化なし）

- [ ] **Step 5: zlib の失敗が減ったことを測る**

Run: `nvim --headless --clean -u NONE -c "luafile tests/real_zlib_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n' | grep -E "^real zlib:|FAILURE"`
修正前は `built+passed=157` / `25 FAILURE(S)`。**減った数を報告すること**（予測 17 件減）。予測と大きく違うなら、その差分を調べて報告する。

- [ ] **Step 6: Commit**

```bash
git add lua/inline-explorer/canalyze.lua tests/substitute_spec.lua
git commit -m "Scope by the whole file when there is no enclosing function

A preprocessor conditional straddling braces -- ordinary kernel style --
makes tree-sitter emit an ERROR node instead of a function_definition, so
the walk for the caller's scope found nothing and returned an empty set.
That switched collision renaming off without a word, and a callee
parameter sharing a name with a caller variable came out as
`T name = (name);` -- an initialiser C binds to the new, uninitialised
local. Real zlib hit this at 152 of inflate.c's 170 call sites. Falling
back to the translation unit over-approximates the scope, which only
renames more than needed; the alternative reads uninitialised memory."
```

---

### Task 2: E5 — 行頭にない文へのインデント算出

**Files:**
- Modify: `tests/substitute_spec.lua`
- Modify: `lua/inline-explorer/canalyze.lua`（`analyze_context`）

**欠陥:** `analyze_context` は `indent` を「行頭から対象文の開始まで」の**テキストそのまま**で取る。対象文が行頭から始まらない場合（`hits++; step(a, n);`、`case 1: f(n);`、`else f(n);`、`lbl: f(n);`）、その「インデント」に先行するコードが含まれ、hoist した各行の先頭に複製される。生成物はコンパイルが通ることがあり、その場合**静かに誤った回数だけ実行される**。

- [ ] **Step 1: 回帰ケースを追加する**

```lua
-- Case 23: the call's statement does not start its own line. The text before
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
  check("case23 does not duplicate the preceding statement",
    select(2, t:gsub("hits%+%+;", "")) == 1, t)
  check("case23 compiles", (compiles(callee .. "\n" .. t .. main, "c23")), t)
  check("case23 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c23")))

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
  check("case23 labelled statement compiles", (compiles(callee .. "\n" .. t2 .. main2, "c23b")), t2)
  check("case23 labelled statement runs equal", (run_ok(callee .. "\n" .. t2 .. main2, "c23b")))
end
```

- [ ] **Step 2: red を確認する**

Run: `nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n' | grep -E "case23|FAILURE"`
Expected: `FAIL  case23 does not duplicate the preceding statement`

- [ ] **Step 3: `analyze_context` を直す**

二点を直す。`indent` は**空白だけ**を取ること、そして対象文が行頭から始まらない場合は**行の前に挿入できない**のだから `braced` を偽として扱い、包む方の printer に回すこと。

`analyze_context` 内の該当箇所を次のように置き換える:

```lua
  local stmt_bol = C.sb(target) - C.scol(target)
  local prefix = caller_src:sub(stmt_bol + 1, C.sb(target))
  -- Only whitespace is indentation. When something else precedes the
  -- statement on its line -- `hits++; f(x);`, `case 1: f(x);`, `else f(x);` --
  -- that text is code, and copying it onto each hoisted line ran it once per
  -- line (it compiled, so it ran wrong rather than failing). A statement that
  -- does not start its line also cannot have lines inserted above it, so it
  -- is not a hoist target either: treat it like an unbraced body and let the
  -- wrapping printer replace the statement in place.
  local starts_line = prefix:match("^[ \t]*$") ~= nil
  local indent = prefix:match("^[ \t]*")
  local parent_t = target:parent() and target:parent():type()
  return {
    call = call,
    target = target,
    braced = starts_line and parent_t == "compound_statement",
    unconditional = unconditional,
    stmt_bol = stmt_bol,
    indent = indent,
    unit = indent:find("\t") and "\t" or "    ",
  }
```

- [ ] **Step 4: green と既存確認**

Step 1 の 5 チェックが緑になり、`ALL SUBSTITUTE TESTS PASSED`。
`ir_spec` は `ctx.braced` をフィクスチャで固定しているので必ず実行すること。既存 10 スイート + `real_cjson_spec` が 188/188/188。

- [ ] **Step 5: zlib の差分を測る**

Run: `nvim --headless --clean -u NONE -c "luafile tests/real_zlib_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n' | grep -E "^real zlib:|FAILURE"`
Task 1 後の値からさらに減った数を報告する（予測 1 件）。

- [ ] **Step 6: Commit**

```bash
git add lua/inline-explorer/canalyze.lua tests/substitute_spec.lua
git commit -m "Take only whitespace as indentation

The text between the start of the line and the call's statement was used
as indentation and prefixed to every hoisted line. When the statement did
not start its own line -- `hits++; f(x);`, `case 1: f(x);`, `else f(x);`
-- that text is code, and it got copied onto each hoisted line: it
compiled, and ran the preceding statement once per line. A statement that
does not start its line cannot have lines inserted above it either, so it
now goes to the wrapping printer instead of the hoisting one."
```

---

### Task 3: E4 — マクロ由来の記憶域指定子を戻り型と誤認

**Files:**
- Modify: `tests/substitute_spec.lua`
- Modify: `lua/inline-explorer/csrc.lua`（`return_type`）

**欠陥:** zlib は `#define local static` を使う。`local int f(...)` を tree-sitter に食わせると型フィールドが `local`（`type_identifier`）になり、本当の型 `int` は `ERROR` ノードに降格する。`return_type` は型フィールドをそのまま使うので、statement-expression の結果スロットが `local __ie_retN;` になり、**本当の型が失われる**。gcc 13 では implicit-int 警告どまりだが `-pedantic-errors` ではエラー。

- [ ] **Step 1: 実際のノード形状を調べる（推測で直さない）**

次を実行し、`local int` / `local unsigned long` / `static int` / `int` / `ZEXTERN int ZEXPORT` の各形で、`function_definition` の子ノードがどうなるか、`field("type")` が何を返すかを記録する:

```sh
nvim --headless --clean -u NONE -c 'lua vim.opt.rtp:append(".")
local C = require("inline-explorer.csrc")
for _, s in ipairs({
  "local int f(int x) { return x; }",
  "local unsigned long f(int x) { return x; }",
  "static int f(int x) { return x; }",
  "int f(int x) { return x; }",
  "ZEXTERN int ZEXPORT f(int x) { return x; }",
}) do
  local root = C.parse(s)
  local fd = root:named_child(0)
  print("--- " .. s)
  print("  node=" .. fd:type() .. "  return_type=" .. vim.inspect(C.return_type(fd, s)))
  for i = 0, fd:child_count() - 1 do
    local ch = fd:child(i)
    print(("    child %d: %-24s %q"):format(i, ch:type(), C.text(ch, s)))
  end
end' -c "qa!"
```

観察結果を報告に記録すること。以降の実装はこの観察に基づくこと。

- [ ] **Step 2: 回帰ケースを追加する**

```lua
-- Case 24: a project-defined macro in type position (zlib's `#define local
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
  check("case24 result slot keeps the real type, not the macro",
    t:find("int __ie_ret1;", 1, true) ~= nil and not t:find("local __ie_ret1;", 1, true), t)

  local prelude = "#define local static\n"
  local main = "int main(void){ return (caller(-3)==4 && caller(0)==5 && caller(9)==6)?0:1; }\n"
  check("case24 compiles", (compiles(prelude .. callee .. "\n" .. t .. main, "c24")), t)
  check("case24 runs equal to original", (run_ok(prelude .. callee .. "\n" .. t .. main, "c24")))
  -- The whole point is that gcc's default only warns; pin it as an error.
  check("case24 compiles under -pedantic-errors",
    (function()
      local p = tmp .. "/c24p.c"
      writef(p, prelude .. callee .. "\n" .. t .. main)
      vim.fn.system({ "gcc", "-std=gnu11", "-fsyntax-only", "-pedantic-errors",
        "-Wno-unused-label", "-Wno-unused-variable", p })
      return vim.v.shell_error == 0
    end)(), t)
end
```

- [ ] **Step 3: red を確認する**

Expected: `FAIL  case24 result slot keeps the real type, not the macro`（`local __ie_ret1;` が出ている）

- [ ] **Step 4: `csrc.lua` の `return_type` を直す**

Step 1 の観察に基づいて実装する。方針は「型として妥当でない先頭トークンを落とす」:

- `function_definition` の開始から declarator の開始までのテキストが、記憶域指定子と型を合わせた前置き全体
- 先頭トークンが C の型・型修飾子の開始語（`void char short int long float double signed unsigned _Bool struct union enum const volatile`）でなく、かつトークンが 2 つ以上あるなら、先頭を落として繰り返す
- 1 トークンだけになったらそれを型とする（`int` 単独や、本当に型名 1 語の場合）
- ポインタ深さの再構築（既存のロジック）はそのまま

`ERROR` ノードに降格した本当の型も、この前置きテキストには含まれているので拾える。既存の `fdef:field("type")` 経由の取得より前置きテキストの方が頑健。

実装後、Step 1 のスクリプトを再実行し、5 形すべてで妥当な型が返ることを確認して報告に記録すること。

- [ ] **Step 5: green と既存確認**

`substitute_spec` の case24 が緑、`ALL SUBSTITUTE TESTS PASSED`。既存 10 スイート + `real_cjson_spec` 188/188/188。

- [ ] **Step 6: zlib の差分を測る**

Task 2 後の値と比較する。**E4 は現在 0 件の失敗原因**なので失敗数は変わらない見込み。ただし生成物から `local __ie_ret` が消えることを確認すること:

```sh
nvim --headless --clean -u NONE -c "luafile tests/real_zlib_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n' | grep -c "local __ie_ret" || echo "0 occurrences (good)"
```

- [ ] **Step 7: Commit**

```bash
git add lua/inline-explorer/csrc.lua tests/substitute_spec.lua
git commit -m "Do not mistake a macro in type position for the return type

zlib writes `local int f(...)` behind `#define local static`. tree-sitter
reports `local` as the type and demotes `int` to an ERROR node, so the
statement-expression's result slot became `local __ie_retN;` -- implicit
int, with the real type gone. gcc 13 only warns, so 80 sites shipped that
way; -pedantic-errors rejects it. The type is now reconstructed from the
text before the declarator, dropping leading tokens that cannot begin a
type."
```

---

### Task 4: skip 規則を狭める + ハーネスの計測欠陥 + 再測定

**Files:**
- Modify: `tests/lib/real_source.lua`
- Modify: `tests/real_zlib_spec.lua`（陳腐化したヘッダコメント）

**Task 2 レビューが指摘したハーネス側の問題:**

1. **skip 規則が広すぎる。** 「単一定義だが `#if` の中」を一律に落としているが、その `#if` が**有効な**分岐なら実プラグインは LSP で解決してインライン化する。実測: 単一定義かつ `#if` 内の 50 件のうち 33 件は無効分岐（変換しても無害＝無意味）、16 件は同名マクロが存在する正当な辞退、**1 件（`gzwrite.c/gzvprintf`）は有効分岐で、辞退すべきでない**。狭めた規則は「同名のマクロ定義がファイル内にある、または定義が複数ある」場合のみ辞退とする
2. **`IE_REAL_MAX_SITES` の集計が壊れている。** cap は内側ループしか止めないので `skipped` は全ファイル分積算され、`sites=72 skipped=57 accepted=15` のような読めない出力になる
3. **失敗詳細が先頭 400 文字**。gcc の警告で埋まり、末尾の実エラー（`Segmentation fault` / `*** zlib test FAILED ***`）が切れる。**これが誤帰属の原因だった。** 末尾側を取ること

- [ ] **Step 1: skip 規則を狭める**

`enumerate` の判定を「名前がファイル内で複数回定義されている、**または** 同名の関数形式マクロ定義（`preproc_function_def` / `preproc_def`）がファイル内にある」に変える。「`#if` の中にある」だけでは辞退しない。理由をコメントに書く（無効分岐なら変換は無害、有効分岐なら実プラグインは解決できる、危険なのは同名マクロと多重定義だけ）。

- [ ] **Step 2: 集計と失敗詳細を直す**

- cap は全体で効くようにする（`attempted + skipped` ではなく、走査した site 数で数える。`sites` は「見た呼び出し site」、`skipped` はそのうち辞退した数、という関係が cap の下でも保たれること）
- 失敗詳細は `tostring(vout):sub(-1500)`（末尾）にする

- [ ] **Step 3: `real_zlib_spec.lua` のヘッダコメントを実測値に合わせる**

現在「239 in-file call sites, 235 of which the engine accepts」と書いてあるが、skip 規則導入後の実測と食い違う。Task 4 実行時点の実測値に更新すること。

- [ ] **Step 4: 再測定**

Run: `nvim --headless --clean -u NONE -c "luafile tests/real_zlib_spec.lua" -c "qa!" 2>&1 | tr '\r' '\n' | grep -E "^real zlib:|FAILURE|^  \* "`

`gzvprintf`（`va_list` 引数のコピー初期化）が復活して失敗するはず。これは既知の第 6 の欠陥で、このタスクでは直さない。残った失敗を **(file, callee) の一覧として報告すること** — Task 5 の pin の入力になる。

Run: cJSON も再測定し 188/188/188 を確認。

- [ ] **Step 5: Commit**

```bash
git add tests/lib/real_source.lua tests/real_zlib_spec.lua
git commit -m "Decline only what cannot be resolved without a preprocessor

A single definition inside a conditional is not ambiguous: if the branch
is inactive the transform is inert, and if it is active the plugin's
language server resolves it. What the harness genuinely cannot resolve is
a name with several definitions, or one that is also a macro -- zlib's
check_match is a function under ZLIB_DEBUG and an empty macro otherwise.
Narrowing to those recovers gzvprintf, which is real code the plugin
would inline. Also: the site cap counted skips across every file, and
failure detail kept the leading 400 characters -- compiler warnings --
while the actual error sat at the end, which is how seven failures got
attributed to the wrong cause."
```

---

### Task 5: 残存失敗の pin + 決定的コンパイル関門 + CI + README

**Files:**
- Modify: `tests/lib/real_source.lua`
- Modify: `tests/real_zlib_spec.lua`
- Modify: `.github/workflows/test.yml`
- Modify: `README.md`

- [ ] **Step 1: clone をタグ固定する**

`real_source.run` の clone を、設定に `ref` があればそれを使う形にする（`git clone --depth 1 --branch <ref>`）。zlib spec は `ref = "v1.3.1"` を指定する。固定しないと上流の変更で件数も失敗集合も動き、pin が腐る。

- [ ] **Step 2: 決定的なコンパイル関門を足す**

`make test` は round-trip の自己検証なので弱い（対称な破壊が見えない、未初期化スタックの中身で結果が揺れる）。各変換に対して、プロジェクトのテストとは別に **`gcc -fsyntax-only` を走らせる**関門を設定できるようにする（`cfg.syntax_check(dir, file)`）。zlib では
`gcc -fsyntax-only -I. -Werror=implicit-function-declaration -Werror=implicit-int <file>` を使う。これは E3・E4 系を決定的に捕まえる。

- [ ] **Step 3: 残存失敗を厳密集合として pin する**

`cfg.known_failures` を導入する。要素は `{ file, callee, occurrence, why }`。`occurrence` は同一 (file, callee) が複数回現れるため必要（`inflateStateCheck` は 4 回出る）。

判定は **両方向**:
- 一覧に無い失敗 → FAIL（新しい退行）
- 一覧にあるのに成功した → FAIL（直ったのでリストを更新せよ、というメッセージ）

Task 4 で得た実測の一覧をここに書く。各要素の `why` には、レビュアーが特定した分類（E2 マクロ本体の識別子直書き / E3 後方定義 / E6 `va_list` コピー初期化）を書く。

- [ ] **Step 4: CI**

`.github/workflows/test.yml` の `real-cjson` ジョブを matrix 化して 2 spec を回す。**zlib ジョブは `SKIP:` を成功として扱わない**（clone / configure / baseline の失敗が緑になってしまう）。cJSON 側は現行どおり `SKIP:` を許容してよい（ネットワーク依存）。

- [ ] **Step 5: README**

「Tested against real source」節に zlib の項目を足す。書くべきこと: 何を追加したか、オラクルの限界（round-trip なので対称な破壊は見えない）、既知失敗を厳密集合で pin していること、そして **zlib を足したことでエンジンの実欠陥が 3 件見つかり修正されたこと**（この節の価値の説明として最も正直）。

- [ ] **Step 6: 全スイート最終確認**

fast 9 本 + `bench_spec`（`IE_BENCH_CLANGD` 要）+ `real_cjson_spec` + `real_zlib_spec`。

- [ ] **Step 7: Commit**

```bash
git add tests/lib/real_source.lua tests/real_zlib_spec.lua .github/workflows/test.yml README.md
git commit -m "Pin zlib's residual failures as an exact set

The three defects zlib found are fixed; what remains are engine limits
rather than bugs -- a macro body that hardcodes the identifiers a rename
must reach, a callee that calls a helper defined later in the file, and a
va_list parameter that cannot be copy-initialised. Those are pinned as an
exact set against a tagged clone, so an unlisted failure is red and a
listed one that starts passing is also red; a suppression list nobody has
to update stops meaning anything. A gcc -fsyntax-only pass runs alongside
zlib's own tests, which are a round trip and cannot see a symmetric
break."
```

---

## Self-Review 済み事項

- 3 件の修正はいずれも「失敗するテストを先に」で、E1・E5 は生成コードを gcc で実行して意味論一致まで確認する
- E4 は現在 gcc 13 で警告どまりなので、`-pedantic-errors` でのコンパイルをテストに含めて実効性を担保した
- Task 3 Step 1 で実際のノード形状を観察してから実装させている（推測で直させない）
- Task 4 の skip 規則の狭め方は、レビュアーが 50 件を個別にビルドして得た 33/16/1 の内訳に基づく
- Task 5 の pin は両方向判定。片方向の抑制リストは腐るという指摘に対応
- cJSON の 188/188/188 維持を全タスクの回帰判定に使っている
- プレースホルダなし
