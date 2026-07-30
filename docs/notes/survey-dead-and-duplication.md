# デッドコード・重複ロジック サーベイ

対象コミット: `27d4f95`（`origin/main`、PR #4 のマージコミット。件名「zlib を実ソース回帰に追加し、それが暴いたエンジン欠陥とハーネスの偽グリーンを修正 (#4)」）。

対象範囲: `lua/` 以下の全モジュール、および `tests/`（`tests/lib/real_source.lua` を含むハーネス本体）。このリポジトリには `plugin/` や `doc/` ディレクトリは存在せず、`.github/workflows/test.yml` にはロジックと呼べるものは無い（CI ジョブ定義のみ）ため、実質的な調査対象は `lua/` と `tests/` の Lua ファイル群である。

調査方法: 各モジュールを全文読み、名前が近い関数・フィールドについては `grep -rn` でリポジトリ全体（`lua/`・`tests/`・`docs/`・`.github/`）を横断的に検索し、呼び出し元をひとつずつ確認した。テストのみから呼ばれているシンボルは「デッドではない」ものとして別枠で明記する。動作の一致・不一致は該当コードを並べて手で突き合わせて判定した。

---

## 1. 【最重要・重複】ツリーシッター基礎ヘルパー（parse / text / query_nodes / バイト範囲アクセサ）の三重実装

**何か**: `lua/inline-explorer/csrc.lua` が定義する「文字列をCとしてパースする」「ノードの開始/終了バイトを取る」「ノードのテキストを取る」「クエリでノード集合を取る」という4種の基礎操作が、正典であるはずの `csrc.lua` の他に、少なくとも2箇所で独立に再実装されている。

**正典（canonical）**: `lua/inline-explorer/csrc.lua:5-30`
```lua
function M.parse(src)
  return vim.treesitter.get_string_parser(src, "c"):parse()[1]:root()
end
function M.sb(node)
  return (select(3, node:range(true)))
end
function M.eb(node)
  return (select(6, node:range(true)))
end
function M.scol(node)
  return (select(2, node:range(true)))
end
function M.text(node, src)
  return src:sub(M.sb(node) + 1, M.eb(node))
end
function M.query_nodes(node, src, q)
  local out = {}
  for _, n in vim.treesitter.query.parse("c", q):iter_captures(node, src) do
    out[#out + 1] = n
  end
  return out
end
```
`canalyze.lua`・`cprint.lua`・`substitute.lua` はすべて `local C = require("inline-explorer.csrc")` 経由でこれらを使っており、この経路では単一の実装しかない。

**コピー1**: `lua/inline-explorer/macro.lua:11-22`
```lua
local function parse(src)
  return vim.treesitter.get_string_parser(src, "c"):parse()[1]:root()
end
local function sb(n)
  return (select(3, n:range(true)))
end
local function eb(n)
  return (select(6, n:range(true)))
end
local function scol(n)
  return (select(2, n:range(true)))
end
```
`macro.lua` はファイル冒頭で `inline-explorer.csrc` を一切 `require` していない（`grep -n "^local.*require" lua/inline-explorer/macro.lua` はヒットなし）。つまり最初から csrc に頼らず独立に書かれている。この `parse`/`sb`/`eb`/`scol` は `find_invocation`（78-92行目）と `replace_in_src`（95-121行目）の内部で使われており、生きたコードである。

**コピー2**: `tests/lib/real_source.lua:82-97`
```lua
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
```
このファイルは11行目で `local S = require("inline-explorer.substitute")` を行っており、`inline-explorer.csrc` を直接 `require` することは技術的に何の障害もない（テストハーネスが内部モジュールに手を伸ばすのは珍しくない）にもかかわらず、`root_of`/`text`/`captures` という別名で `csrc.parse`/`csrc.text`/`csrc.query_nodes` と同一の処理を書き直している。実際に308・312・318・321・326・331・344・345行目などで多用されており、`real_source_lib_spec.lua`・`real_zlib_spec.lua`・`real_cjson_spec.lua` という3本の実ソース回帰テストの基盤になっている（テストのみから使われる部類だが、テスト用途としては死んでいない）。

**コピー3（部分的・インライン）**: `lua/inline-explorer/simplify.lua:43-44`
```lua
local _, _, sb = node:range(true)
local _, _, _, _, _, eb = node:range(true)
```
こちらは名前付き関数としてではなく、括弧の入れ子を畳み込む `walk` 関数の中で直接 `range(true)` を分解している。`simplify.lua` も `csrc` を `require` していない。計算内容は `csrc.sb`/`csrc.eb` と完全に同じ（3番目の戻り値が開始バイト、6番目が終了バイト）。

**一致 or 乖離の判定**: 上記4箇所（csrc本体、macro.lua、real_source.lua、simplify.lua）を1行ずつ突き合わせた結果、**現時点ではバイトオフセットの計算式・パース呼び出しとも完全に一致しており、挙動の乖離（ドリフト）は確認できなかった**。つまり今すぐ誤動作を起こしている箇所ではない。

**行動への影響**: 現状はゼロだが、リスクは実在する。たとえば将来 Neovim の `TSNode:range(true)` の仕様が変わる、あるいは csrc 側にマルチバイト文字や CRLF 対応などの補正が入った場合、その修正は `csrc.lua` にしか反映されず、`macro.lua`・`simplify.lua`・`tests/lib/real_source.lua` の3つのコピーは黙って古い挙動のまま取り残される。これは「まだ顕在化していないが、直すなら今が一番安い」典型的な重複である。

**推奨アクション**: `macro.lua` と `simplify.lua` は `local C = require("inline-explorer.csrc")` に置き換えて `C.parse`/`C.sb`/`C.eb`/`C.scol` を使う。`tests/lib/real_source.lua` も同様に `local C = require("inline-explorer.csrc")` を追加し、`root_of`/`text`/`captures` の3関数を `C.parse`/`C.text`/`C.query_nodes` の薄いラッパ（あるいは呼び出し側の書き換え）に置き換える。挙動が完全に同一であることは今回の突き合わせで確認済みなので、置き換えは振る舞いを変えない安全なリファクタになる。

---

## 2. 【重複】展開ブロックのextmark解決ループが3箇所で独立に書かれている

**何か**: 読み取りビュー（`view.lua`）が保持する `st.nodes`（各展開ブロックの開始/終了 extmark と名前のリスト）から、生きている（削除されていない）ブロックの実際の行番号を求める「extmarkをIDで引いて `s[1]`/`e[1]` の有無を確認する」というループが、用途の異なる3つのモジュールでほぼ同じ形で書かれている。

**インスタンス1**: `lua/inline-explorer/expander.lua:11-21`（`ancestor_names` — カーソル行を含むブロック名の集合を作る。再帰防止のため）
```lua
local function ancestor_names(st, bufnr, lnum)
  local names = {}
  for _, node in ipairs(st.nodes) do
    local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, view.ns, node.s_mark, {})
    local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, view.ns, node.e_mark, {})
    if s[1] and e[1] and lnum >= s[1] and lnum <= e[1] then
      names[node.name] = true
    end
  end
  return names
end
```

**インスタンス2**: `lua/inline-explorer/nav.lua:13-26`（`blocks` — 生きているブロックを `{s, e, name}` のソート済みリストにする。`next`/`prev`/`list`/`breadcrumb` が使う）
```lua
local function blocks(st, bufnr)
  local out = {}
  for _, node in ipairs(st.nodes) do
    local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, view.ns, node.s_mark, {})
    local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, view.ns, node.e_mark, {})
    if s[1] and e[1] then
      out[#out + 1] = { s = s[1], e = e[1], name = node.name }
    end
  end
  table.sort(out, function(a, b) return a.s < b.s end)
  return out
end
```
この `blocks` はモジュールローカルで `nav.lua` の外から呼べない。

**インスタンス3**: `lua/inline-explorer/view.lua:157-164`（`rewrite` 内、行番号の付け替え後にどのブロックが生き残ったか判定する部分）
```lua
local surviving = {}
for _, node in ipairs(st.nodes) do
  local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, node.s_mark, {})
  local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, node.e_mark, {})
  if s[1] and e[1] and rowmap[s[1]] and rowmap[e[1]] then
    surviving[#surviving + 1] = { name = node.name, s = rowmap[s[1]], e = rowmap[e[1]] }
  end
end
```

**一致 or 乖離の判定**: 3箇所とも「`s[1]`・`e[1]` が真であること（＝extmarkがまだ生きていること）を確認してから使う」という核心のガードは完全に一致しており、ここにも今のところドリフトは無い。差分は上に載せたフィルタ条件（範囲内判定の有無、`rowmap` 経由の追加フィルタ）だけで、これは用途の違いによる正当な差である。

**行動への影響**: 現状バグはないが、`st.nodes` の extmark 解決という同じ土台のコピーが3つあるため、たとえば「extmark取得の3番目の戻り値仕様が変わった」「無効なnode.s_markを弾く条件を強化したい」といった変更をするとき、3ファイルすべてを揃って直す必要がある。1箇所直し忘れると即座に3つの経路（recursion guard・ナビゲーション・undo後の再アンカリング）のうちどれかだけが古い挙動になる、という意味で構造的なリスクを抱えている。

**推奨アクション**: `view.lua`（extmark名前空間 `M.ns` と `st.nodes` の両方を握っているモジュール）に `M.live_nodes(st, bufnr)` のような共有ヘルパーを1つ用意し、`{s, e, name}` のリストを返すようにする。`nav.blocks` はこれにソートを足すだけ、`expander.ancestor_names` はこれに範囲判定を足すだけ、`view.rewrite` はこれに `rowmap` 越しのフィルタを足すだけになり、核心のextmark解決ロジックは1箇所に集約できる。

---

## 3. 【デッドコード】`macro.lua` の `M._markup` はどこからも呼ばれていない

**何か**: `lua/inline-explorer/macro.lua:25-37` にホバーの `MarkupContent | MarkedString | MarkedString[]` を平坦化するローカル関数 `markup` があり、これは `fetch_via_hover`（462行目、`md = markup(r.result.contents)`）から実際に呼ばれている生きたコードである。しかし73行目でこれをテストフックとして `M._markup = markup` の形でエクスポートしているにもかかわらず、この `M._markup` という名前は `lua/`・`tests/` のどこからも一度も参照されていない。

**証拠**: `grep -rn 'markup' tests/*.lua tests/lib/*.lua lua/inline-explorer/*.lua` の結果、`_markup` が現れるのは定義箇所（73行目）だけで、他のどのテストファイル（`macro_spec.lua` など）にも呼び出しが無い。兄弟のテストフック `M._expansion_lines`（74行目）は `tests/macro_spec.lua:34,36,39` から実際に呼ばれているのと対照的である。`docs/superpowers/plans/2026-07-28-macro-expandmacro-tweak.md:18` に「hover 経路（`_markup` / `_expansion_lines` とその挙動）は無変更で存続」という記述はあるが、これは計画メモであってコードからの参照ではない。

**行動への影響**: なし。`markup`（小文字、非公開）自体は生きているので機能に影響は無い。`M._markup` という公開名だけが誰にも使われずぶら下がっている。

**推奨アクション**: `M._markup = markup` の行を削除する。テストで内部の平坦化ロジックを直接検証したくなった場合はそのとき復活させれば良い。

---

## 4. 【参考・デッドではない】`init.lua` の `M.breadcrumb` はリポジトリ内に呼び出し元が無い

**何か**: `lua/inline-explorer/init.lua:74-79` の `M.breadcrumb()` は、コメントに書かれている通り `require("inline-explorer").breadcrumb()` としてユーザーの statusline 設定から呼ばれることを想定した公開APIである。`grep -rn 'require("inline-explorer")\b'` はリポジトリ内のどこにもヒットせず、`lua/`・`tests/` のいかなる場所からもこの経路は呼ばれていない（`nav.lua` の `M.breadcrumb` 自体は `tests/expander_spec.lua:124` から直接呼ばれて検証されている）。

**判定**: これは「デッドコード」ではない。プラグインのトップレベルモジュールが提供する公開APIは、定義上そのプラグインの利用者（ユーザーのNeovim設定）から呼ばれるものであり、リポジトリ内に呼び出し元が無いのは意図した姿である。実際、`M.setup` も同様に repo 内から一度も呼ばれていないが、これはプラグインのエントリポイントとして当然である。参考情報として記載するに留め、対処不要と判断した。

---

## 検討したが「クリーン」と判断した項目（サーベイの網羅性のために記載）

- `csrc.lua` 内の `decl_name`（35-50行目）と `build_bind`（317-340行目）はどちらも宣言子（declarator）ツリーを歩く点で似ているが、`build_bind` が関数ポインタ等の「エキゾチックな」宣言子で意図的に `__auto_type` フォールバックへ抜けるのは仕様であり、`tests/substitute_spec.lua:438-452`（case15、"function-pointer param falls back to __auto_type, name kept"）で明示的にテスト・固定されている。重複ではなく意図された非対称。
- `canalyze.lua` の `enclosing_statement`（58-74行目）、`substitute.lua` の `call_at`（81-87行目）、`macro.lua` の `find_invocation`（78-92行目）は、いずれも `:parent()` を辿る木登りだが、それぞれ止まる条件・対象ノード種別が異なり（文/宣言の境界、`call_expression`、識別子）、同じ計算の重複ではなく別々の判定である。
- `resolver.lua` の `FUNCTION_KINDS`（[6]=Method, [9]=Constructor, [12]=Function）のうち Constructor(9) は `tests/resolver_spec.lua` に直接のテストは無いが、このモジュールはC専用ではなく汎用のLSPシンボル解決器として設計されている（コメント参照）ため、「どの入力からも到達できない分岐」であるとは断定できない。デッド認定を見送った。
- `config.lua` の `M.defaults` のキー一覧と `check()` 内の `types` テーブルは並行して保守する必要があるが、これは設定バリデーションとしてごく一般的な形であり、実際に壊れている・振る舞いが食い違っている箇所ではないため報告対象から除外した。
- `M._probe`・`M._render`・`M._rebase`・`M._common_ws_prefix`（`substitute.lua`）、`M._install_interceptor`・`M._pending`・`M._edit_matches`・`M._pick_expand_action`・`M._edit_lines`・`M._prune_dead_clients`・`M._expansion_lines`（`macro.lua`）、`M._symbol_range`・`M._timeout_ms`・`M._attach_cache_n`（`resolver.lua`）、`M._remap_rows`（`view.lua`）は、いずれもテストスペックから実際に呼ばれていることを確認済み。**プロダクションコードからは呼ばれずテストのみから呼ばれるシンボル**であり、指示の通り「デッドではない」ものとして明示的に区別する。
- `config` の各キーマップ項目（`substitute`/`expand`/`toggle_fold`/`open`/`close`/`undo`/`redo`/`next_block`/`prev_block`/`list_blocks`）、`indent`/`header`/`mode`/`profile` の各オプション、`profile.max_events`/`view.FETCH_GUARD_MS`/`resolver._attach_cache_n` などの調整可能フィールドは、すべて実際の呼び出し元（`init.lua`・`view.lua`・各スペック）を確認済みで生きている。
- `canalyze.decide()` の4分岐（`wrap_unsafe` → canonical / `simple` かつ readable-or-unconditional → pretty / readable → readable_multi / それ以外 → canonical）は、`tests/ir_spec.lua`・`tests/substitute_spec.lua` の該当ケース（case12, case27 など）でそれぞれ個別に踏まれていることを確認した。到達不能な分岐ではない。
- 実ソース回帰テストの下回り（`tests/lib/gen.lua` と `tests/fixtures/bench/gen.lua`）は名前が似ているが、前者はプロパティテスト用のランダムC式生成器、後者は性能回帰ベンチマーク用の大規模フィクスチャ生成器であり、役割が異なるため重複とはみなさなかった。

---

## まとめ

- デッドコード候補: **1件**（`macro.lua` の `M._markup`。参考として `init.lua` の `M.breadcrumb` を1件、意図的な公開APIとして別枠で記載）。
- 重複ロジック候補: **2件**（ツリーシッター基礎ヘルパーの三重実装、extmark解決ループの三重実装）。いずれも突き合わせの結果、現時点でのドリフト（挙動の食い違い）は確認されなかったが、将来ドリフトしうる構造的リスクとして報告する。
- 最も価値の高い指摘: 1番目の「ツリーシッター基礎ヘルパーの三重実装」。`csrc.lua`・`macro.lua`・`tests/lib/real_source.lua` の3箇所が同じバイトオフセット計算を独立に持っており、今は挙動が一致しているものの、修正が1箇所にしか反映されない構造になっている。
