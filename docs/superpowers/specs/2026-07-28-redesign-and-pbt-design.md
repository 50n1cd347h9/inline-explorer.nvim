# 再設計 + テスト拡充 設計書

日付: 2026-07-28
状態: 承認済み（ブレインストーミング経由）

## 背景と動機

テスト拡充の作業中に、次の問題が明らかになった。

1. **実バグ**: 関数ポインタ引数のパラメータ束縛で名前が消失する
   （`parenthesized_declarator` に `declarator` フィールドが無く、
   `decl_name` が nil を返すため `__ie_argN` フォールバックに落ち、
   本体の `fp(x)` が未定義参照になる。gcc 13 では暗黙宣言の警告どまりで
   コンパイルが通ってしまい、実行結果が壊れる）。
2. **構造的問題**: プラグイン全体に「ケースの個別列挙」が 3 箇所あり、
   ケース追加のたびに判断行列が膨張し、上記のような漏れを生みやすい。
   - `substitute.lua`: {simple, general} × {hoist_safe, unsafe} ×
     {braced, wrap} × {correct, readable} の判断が 3 つの emitter に
     分散して埋め込まれている。
   - `resolver.lua`: 言語別ノード型の手書き allow-list（約 50 行）+
     サフィックスパターン + brace ヒューリスティック。
   - `macro.lua`: clangd の hover markdown から "Expands to" を
     文字列スクレイピングしており、出力形式の変更に脆い。

外部ツールへの委譲は不可能であることを確認済み: C の関数インラインを
ソースレベルで行う既製ツールは存在しない（clangd tweak に無し、
LibTooling は C++ バイナリの配布が必要になり pure-Lua の利点を失う、
`gcc -E` はマクロのみ、GIMPLE ダンプは可読な C にならない）。
したがって変換ロジックは自前のまま、その構造化が本題となる。

## 設計方針

外部 API（`inline_call(caller_src, callee_src, fname, N, occ, mode)`、
ユーザーコマンド、キーマップ）は一切変えない。既存のテスト
（substitute_spec case1-18、real_cjson_spec、resolver_spec、macro_spec）を
黒箱の安全網として、フェーズごとに全 spec green を維持しながら進める。

## フェーズ

### P1: 即時バグ修正（リファクタ前に安全網を緑にする）

- `substitute.lua` の `decl_name` と `func_declarator`:
  `field("declarator")` が空で、ノード型が `parenthesized_declarator` の
  場合は `named_child(0)` にフォールバックする（各 1 行）。
- テスト側の自己バグ 2 件を修正:
  - case15 array: 束縛判定パターンの誤り。
  - case18: 変換結果と `#include` の連結で改行が欠け
    `}#include <string.h>` になっていた。include はファイル先頭に置く。
- すべての `compiles()` / ビルドに `-Werror=implicit-function-declaration`
  を追加する。名前消失系のバグを gcc 13 でも確実にエラーとして検出する。

### P2: substitute.lua 再構築（mini-IR + 判定 1 箇所 + dumb printer）

現状の byte-offset 編集（`apply_edits`）のパッチワークをやめ、
次のパイプラインにする。

```
parse(callee)  → IR  { binds[], stmts[], returns[], labels[], ret_type }
parse(caller)  → ctx { stmt_type, braced, unconditional }
決定（1 箇所）  → printer の選択
printer（無知）→ pretty hoist / canonical stmt-expr / readable-multi
```

- **canonical stmt-expr** が意味論上の基準形: `({ ... })` + `return E;` →
  `{ __ie_retN = E; goto __ie_endN; }`。あらゆる式文脈で合法なので、
  文脈判定に失敗しても正しさは崩れない（安全側デフォルト）。
- **pretty hoist** は「simple（直線 + 単一末尾 return）かつ
  ctx.unconditional かつ文が braced」のときだけ選ばれる。
  ラベル直後などの wrap 判断も ctx に集約する。
- **readable モード** は readable-multi printer の選択を許可するだけの
  フラグになる（意味論非保証の仕様は現状どおり）。
- 名前衝突リネーム・ラベルサフィックスは IR 構築時に一度だけ解決する。
- 期待効果: 判断が 1 箇所に集中し、printer は判断を持たない。
  ケース追加 = ctx かデシジョンテーブルの 1 行追加になる。

### P3: resolver.lua 再構築（documentSymbol 化）

- `workspace/symbol` で位置を得たあと、対象ファイルに
  `textDocument/documentSymbol` を投げ、シンボルの **range**
  （定義の全範囲）をサーバから直接取得する。
- これにより言語別 `DEFINITION_NODES` 表（約 50 行）と
  サフィックスパターンを削除する。
- tree-sitter 抽出と brace ヒューリスティックは、サーバが range を
  返さない場合のフォールバックに降格して残す。

### P4: macro.lua 再構築（ExpandMacro tweak 化）

- clangd の `ExpandMacro` tweak を `workspace/executeCommand` で起動し、
  返ってくる `workspace/applyEdit` を**インターセプト**して実ファイルには
  当てず、view バッファへの編集に読み替える。
- 正確な in-place 編集がプロトコルとして返るため、hover markdown の
  スクレイピングと、展開多発後の位置ずれ問題が解消する。
- hover 方式は古い clangd 向けフォールバックとして残す。

### P5: PBT ハーネス（2 層 + 簡易 shrink）

#### tests/lib/gen.lua（共有ジェネレータ）

```
gen.rng(seed)                 -- 自前 LCG（環境非依存の決定的 PRNG）
gen.callee(rng)               -- ランダム callee 生成
gen.caller(rng, callee)       -- 文脈 9 種から 1 つ、call 位置付き
gen.shrink(case, still_fails) -- 貪欲最小化
```

- callee 語彙（「中」）: 引数 `int` / `int*` を 0-3 個。文プール =
  宣言 / 算術代入 / if-else / 上限付き while / 早期 return / goto+label。
  必ず値を return して終端する。
- caller 文脈 9 種: 単純代入 / `return f(x)+k` / 宣言初期化 /
  `a && f(x)` / `c ? f(x) : k` / if ヘッダ / 波括弧なし if 本体 /
  case ラベル後 / for ヘッダ。
- 変数名プールに caller と衝突する名前（`t`, `s` など)を意図的に混入し、
  リネーム経路を常時刺激する。
- 関数ポインタ引数は語彙に入れない（例示テスト case15 でカバー）。
- shrink: callee 文を末尾から削除 → 引数削除 → 文脈単純化、の貪欲ループ。

#### tests/properties_spec.lua（高速層、gcc 不要、毎回 ~300 ケース）

correct / readable 両モードで:

1. **P-parse**: 変換後ソースを tree-sitter で再パースし ERROR ノード 0。
2. **P-count**: 対象呼び出しの出現数がちょうど 1 減る。
3. **P-unique**: N を変えて 2 回インラインしたとき注入名
   （`__ie_*`, `*__ieN`）がすべて相異なる。
4. **P-reject-safe**: `inline_call` が nil を返すとき err が非 nil で、
   元ソースは無変更（部分書き換えが起きない）。
5. ユーティリティ単体性質: `rebase` × `common_ws_prefix` の
   ラウンドトリップ（P2 後も printer のインデント処理として残る）。
   ほかに P2 を生き残ったヘルパがあれば同様に単体性質を追加する。

失敗時は seed + 生成ソース + shrink 済み反例を print する。

#### tests/pbt_spec.lua（gcc 差分層、既定 30 ケース）

- オラクル: 元の caller+callee+main（固定入力集合の結果を stdout 出力）を
  gcc でビルド・実行し、変換版と **stdout 完全一致** を要求する。
- correct モードのみ差分対象。readable は「コンパイルが通れば良し、
  通らなくても不問」（仕様どおり意味論非保証のため）。
- `IE_PBT_CASES` で増量、`IE_PBT_SEED` で再現。
  失敗時は shrink 後の反例 .c を tmp に保存しパスを表示する。
- **P2 の構造を性質化**: canonical printer の出力と pretty printer の
  出力を両方ビルドし、gcc 差分一致を検証する
  （simplifier が意味論を変えていないことの直接検証）。

## 却下した代替案

- **外部ツール委譲**: 上記のとおりツールが存在しない。
- **substitute の現状維持 + テストのみ**: ケース行列の膨張と
  バグ温床が残るため、ユーザー判断で再設計を選択。
- **caller 文脈の語彙「大」**（switch / 関数ポインタ / ネスト呼び出しの
  ランダム生成): ジェネレータ自体のバグリスクと偽陽性デバッグコストが
  増えるため「中」に抑え、例示テストで補完する。

## 受け入れ条件

- 各フェーズ完了時に全 spec が green
  （substitute_spec, real_cjson_spec, resolver_spec, macro_spec,
  properties_spec, pbt_spec）。
- P2 完了時: `substitute.lua` から `hoist_safe` 相当の判定が
  emitter 内から消え、決定箇所が 1 つになっている。
- P3 完了時: `DEFINITION_NODES` 表が削除されている。
- P5 完了時: seed 固定で全層が決定的に再現できる。

## テスト実行方法（全 spec 共通）

```sh
nvim --headless --clean -u NONE -c "luafile tests/<spec>.lua" -c "qa!"
```
