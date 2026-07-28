# substitute.lua 再設計 (P1+P2) 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 関数ポインタ束縛バグを修正し、substitute.lua を「mini-IR + 判定 1 箇所 + 無知な printer 3 種」構造に再構築する。外部 API は不変。

**Architecture:** `analyze_callee` が callee を IR（binds / stmts / returns / rename / ret_type …）に、`analyze_context` が呼び出し文脈を ctx（braced / unconditional / indent …）に解決し、`decide` が唯一の判定点として printer（pretty / canonical / readable_multi）を選ぶ。printer は判断を持たない。

**Tech Stack:** Lua (Neovim 0.10+ 組込み tree-sitter)、gcc (テスト)、既存テストハーネス（headless nvim + luafile）

**Spec:** `docs/superpowers/specs/2026-07-28-redesign-and-pbt-design.md`（本 plan はそのうち P1+P2。P3/P4/P5 は別 plan）

## Global Constraints

- 外部 API 不変: `M.inline_call(caller_src, callee_src, fname, N, occ, mode)` / `M.inline_in_buffer(caller_src, row, col, callee_src, N, mode)` / `M.call_name_at(caller_src, row, col)`
- 各タスク完了時、以下すべて green:
  `nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!"`
  同様に `tests/macro_spec.lua`, `tests/resolver_spec.lua`（cJSON はネットワーク要のため Task 4 でのみ必須）
- テスト実行の nvim が PATH に無い環境では、入手済みバイナリのフルパスで実行してよい
- コードのコメントは既存ファイルの流儀（英語）に合わせる
- コミットメッセージは既存リポジトリの流儀（英語、subject のみ or subject+body）

---

### Task 1: P1 — fn-pointer 束縛バグ修正 + テスト自己バグ修正 + -Werror 強化

**Files:**
- Modify: `lua/inline-explorer/substitute.lua:48-73`（`decl_name`, `func_declarator`）
- Modify: `tests/substitute_spec.lua`（`compiles`, `run_ok`, case15 array パターン, case18）
- Modify: `tests/real_cjson_spec.lua:101`（変換版ビルドに -Werror 追加）

**Interfaces:**
- Consumes: 既存 `decl_name(decl, src)` / `func_declarator(decl)`
- Produces: 同名同シグネチャ（`parenthesized_declarator` を降下できるようになる）

**背景:** tree-sitter C の `parenthesized_declarator` には `declarator` フィールドが**無い**（確認済み）。`int (*fp)(int)` のパラメータで `decl_name` が nil を返し、束縛が `__auto_type __ie_arg1_1 = (add2);` になって本体の `fp(x)` が未定義参照になる。gcc 13 は暗黙宣言を警告で通すため、コンパイルが通って実行が壊れる。

- [ ] **Step 1: 失敗を確認する（テストは既に書かれている）**

Run: `nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!" 2>&1 | grep -E "case15 function-pointer|case15 fn-pointer|case18"`

Expected: `FAIL  case15 function-pointer param falls back to __auto_type`、`FAIL  case15 fn-pointer runs equal`、`FAIL  case18 compiles` ほか（case18 はテスト側バグ）

- [ ] **Step 2: `decl_name` と `func_declarator` を修正する**

`lua/inline-explorer/substitute.lua` の 2 関数を次に置き換える:

```lua
-- Descend a declarator to its identifier name (through pointer/array/fn wrappers).
-- NOTE: parenthesized_declarator has no `declarator` field in tree-sitter-c, so
-- fall through it via its first named child (e.g. `int (*fp)(int)`).
local function decl_name(decl, src)
  local n = decl
  while n do
    if n:type() == "identifier" then
      return text(n, src)
    end
    local d = n:field("declarator")[1]
    if not d and n:type() == "parenthesized_declarator" then
      d = n:named_child(0)
    end
    if not d then
      return nil
    end
    n = d
  end
end

-- Unwrap a function definition's declarator to the function_declarator node.
local function func_declarator(decl)
  local n = decl
  while n and n:type() ~= "function_declarator" do
    if n:type() == "pointer_declarator" then
      n = n:field("declarator")[1]
    elseif n:type() == "parenthesized_declarator" then
      n = n:field("declarator")[1] or n:named_child(0)
    else
      return nil
    end
  end
  return n
end
```

- [ ] **Step 3: case15 の期待を実バインドに合わせる**

修正後の正しい束縛は `__auto_type fp = (add2);`（名前が残る）。case15 fn-pointer の check は既にそれを期待しているので変更不要。array の check だけパターンが冗長なので単純化する。`tests/substitute_spec.lua` の

```lua
  check("case15 array param decays to pointer", t2:find("int %*first_a__?i?e?1? =") ~= nil or t2:find("int %*a = %(arr%);") ~= nil, t2)
```

を

```lua
  check("case15 array param decays to pointer", t2:find("int %*a = %(arr%);") ~= nil, t2)
```

に置き換える。

- [ ] **Step 4: case18 のテスト自己バグを修正する**

原因: `callee .. "\n" .. t .. main` で `t` が改行なしで終わり `}#include <string.h>` に連結されていた。include をソース先頭に移す。`tests/substitute_spec.lua` case18 の

```lua
  local t = transform(caller, callee, "pick", { { N = 1 } })
  local main = "#include <string.h>\nint main(void){ return (strcmp(caller(1),\"x\")==0 && strcmp(caller(0),\"y\")==0)?0:1; }\n"
  check("case18 result slot keeps pointer depth", t:find("char %*%* ?__ie_ret1;") ~= nil, t)
  check("case18 compiles (char ** return)", (compiles(callee .. "\n" .. t .. main, "c18")), t)
  check("case18 runs equal to original", (run_ok(callee .. "\n" .. t .. main, "c18")))
```

を

```lua
  local t = transform(caller, callee, "pick", { { N = 1 } })
  local main = "int main(void){ return (strcmp(caller(1),\"x\")==0 && strcmp(caller(0),\"y\")==0)?0:1; }\n"
  local src18 = "#include <string.h>\n" .. callee .. "\n" .. t .. "\n" .. main
  check("case18 result slot keeps pointer depth", t:find("char %*%* ?__ie_ret1;") ~= nil, t)
  check("case18 compiles (char ** return)", (compiles(src18, "c18")), t)
  check("case18 runs equal to original", (run_ok(src18, "c18")))
```

に置き換える。

- [ ] **Step 5: gcc 呼び出しに -Werror=implicit-function-declaration を追加する**

`tests/substitute_spec.lua` の `compiles` / `run_ok`:

```lua
local function compiles(src, name)
  local p = tmp .. "/" .. name .. ".c"
  writef(p, src)
  local out = vim.fn.system({
    "gcc", "-std=gnu11", "-fsyntax-only", "-Werror=implicit-function-declaration",
    "-Wno-unused-label", "-Wno-unused-function", "-Wno-unused-variable", p,
  })
  return vim.v.shell_error == 0, out
end

local function run_ok(src, name)
  local c, exe = tmp .. "/" .. name .. ".c", tmp .. "/" .. name .. ".out"
  writef(c, src)
  local out = vim.fn.system({
    "gcc", "-std=gnu11", "-Werror=implicit-function-declaration",
    "-Wno-unused-label", "-Wno-unused-function", c, "-o", exe,
  })
  if vim.v.shell_error ~= 0 then
    return false, out
  end
  vim.fn.system({ exe })
  return vim.v.shell_error == 0, ""
end
```

`tests/real_cjson_spec.lua` の変換版ビルド（101 行付近）:

```lua
    local build = vim.fn.system({ "gcc", "-std=c99", "-Werror=implicit-function-declaration", "-Wno-unused-label", cfile, dir .. "/test.c", "-o", work .. "/v", "-lm" })
```

- [ ] **Step 6: 全テストが green か確認する**

Run: `nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: `ALL SUBSTITUTE TESTS PASSED`

Run: `nvim --headless --clean -u NONE -c "luafile tests/macro_spec.lua" -c "qa!" 2>&1 | tail -1`
Expected: `ALL MACRO TESTS PASSED`

Run: `nvim --headless --clean -u NONE -c "luafile tests/resolver_spec.lua" -c "qa!" 2>&1 | tail -1`
Expected: `ALL RESOLVER TESTS PASSED`

- [ ] **Step 7: Commit**

```bash
git add lua/inline-explorer/substitute.lua tests/substitute_spec.lua tests/real_cjson_spec.lua
git commit -m "Fix param-name loss through parenthesized declarators

tree-sitter-c's parenthesized_declarator has no declarator field, so
decl_name returned nil for function-pointer parameters and the binding
fell back to a synthetic __ie_argN name, leaving the body's uses
dangling (gcc 13 only warns on implicit declarations, so it compiled
but misbehaved). Descend via the first named child instead, and promote
implicit-function-declaration to an error in the test builds so this
class of bug fails loudly. Also fix two test-side bugs in case15/18."
```

---

### Task 2: ir_spec — IR / ctx / decide の単体テストを先に書く

**Files:**
- Create: `tests/ir_spec.lua`

**Interfaces:**
- Consumes: なし（このタスクはテストのみ。実装は Task 3）
- Produces: Task 3 が満たすべき内部 API 仕様:
  `M._probe(caller_src, callee_src, fname, occ?, mode?) -> { ir, ctx, decision } | nil, err`
  - `ir`: `{ binds (Task3 では未設定で良い: probe は args 不要), params, rename (table), simple (boolean), has_value (boolean), ret_type (string), ret_var (string), end_label (string), stmts, returns, body_edits, src }`
  - `ctx`: `{ call, target, braced (boolean), unconditional (boolean), stmt_bol (number), indent (string), unit (string) }`
  - `decision`: `"pretty" | "canonical" | "readable_multi"`

- [ ] **Step 1: `tests/ir_spec.lua` を作成する**

```lua
-- Unit tests for the substitute engine's analysis layer: the callee IR, the
-- call-site context, and the single printer decision (M._probe).
--   nvim --headless --clean -u NONE -c "luafile tests/ir_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local S = require("inline-explorer.substitute")

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
    print("FAIL  " .. l .. (d and ("\n----\n" .. vim.inspect(d) .. "\n----") or ""))
  end
end

local simple_callee = [[static int acc(int x)
{
    int t = x + 1;
    return t * 2;
}]]
local multi_callee = [[static int cls(int x)
{
    if (x < 0)
        return -1;
    return x ? 1 : 0;
}]]

-- Simple callee in a plain statement -> pretty.
do
  local p = assert(S._probe([[static int caller(int n)
{
    return acc(n) + 1;
}]], simple_callee, "acc"))
  check("simple+plain: ir.simple", p.ir.simple == true, p.ir)
  check("simple+plain: ctx.unconditional", p.ctx.unconditional == true, p.ctx)
  check("simple+plain: ctx.braced", p.ctx.braced == true, p.ctx)
  check("simple+plain: decision pretty", p.decision == "pretty", p.decision)
  check("ir.ret_type reconstructed", p.ir.ret_type == "int", p.ir.ret_type)
  check("ir.has_value", p.ir.has_value == true)
end

-- Same callee under && -> not unconditional -> canonical.
do
  local p = assert(S._probe([[static int caller(int a, int b)
{
    return a && acc(b);
}]], simple_callee, "acc"))
  check("short-circuit: ctx.unconditional false", p.ctx.unconditional == false, p.ctx)
  check("short-circuit: decision canonical", p.decision == "canonical", p.decision)
end

-- Ternary arm -> canonical.
do
  local p = assert(S._probe([[static int caller(int c, int n)
{
    return c ? acc(n) : 0;
}]], simple_callee, "acc"))
  check("ternary: decision canonical", p.decision == "canonical", p.decision)
end

-- Multi-return callee -> canonical in correct mode, readable_multi in readable.
do
  local caller = [[static int caller(int n)
{
    int r = cls(n);
    return r;
}]]
  local p = assert(S._probe(caller, multi_callee, "cls"))
  check("multi-return: ir.simple false", p.ir.simple == false)
  check("multi-return: decision canonical", p.decision == "canonical", p.decision)
  local pr = assert(S._probe(caller, multi_callee, "cls", 1, "readable"))
  check("multi-return readable: decision readable_multi", pr.decision == "readable_multi", pr.decision)
end

-- Simple callee in readable mode is pretty even where hoisting is unsafe.
do
  local p = assert(S._probe([[static int caller(int a, int b)
{
    return a && acc(b);
}]], simple_callee, "acc", 1, "readable"))
  check("readable overrides unsafe hoist: pretty", p.decision == "pretty", p.decision)
end

-- Unbraced if body -> ctx.braced false (printer must wrap).
do
  local p = assert(S._probe([[static int caller(int a)
{
    if (a > 0)
        return acc(a);
    return 0;
}]], simple_callee, "acc"))
  check("unbraced if: ctx.braced false", p.ctx.braced == false, p.ctx)
  check("unbraced if: still pretty (wrap is layout, not decision)", p.decision == "pretty", p.decision)
end

-- Caller locals colliding with callee locals -> rename planned in the IR.
do
  local p = assert(S._probe([[static int caller(int t)
{
    int r = g(t);
    return r;
}]], [[static int g(int x)
{
    int t = x * 2;
    return t + 1;
}]], "g"))
  check("collision: rename planned", p.ir.rename.t == "t__ie1", p.ir.rename)
end

-- Tab-indented caller -> unit is a tab.
do
  local p = assert(S._probe("static int caller(int n)\n{\n\treturn acc(n) + 1;\n}", simple_callee, "acc"))
  check("tab caller: ctx.unit is tab", p.ctx.unit == "\t", p.ctx.unit)
end

-- Errors surface as nil, err.
do
  local _, err = S._probe("static int caller(int n)\n{\n    return f(n);\n}", "static int f(int x, ...)\n{\n    return x;\n}", "f")
  check("variadic: nil + err", err ~= nil and tostring(err):find("variadic") ~= nil, tostring(err))
end

print("")
print(fails == 0 and "ALL IR TESTS PASSED" or (fails .. " FAILURE(S)"))
```

- [ ] **Step 2: 失敗を確認する**

Run: `nvim --headless --clean -u NONE -c "luafile tests/ir_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: エラー（`S._probe` が nil → `attempt to call field '_probe'`）。ハーネスの都合で FAIL 表示でなくスタックトレースでも可 — 「_probe 不在で全滅」が確認できれば良い

- [ ] **Step 3: Commit**

```bash
git add tests/ir_spec.lua
git commit -m "Add failing unit spec for the substitute analysis layer"
```

---

### Task 3: substitute.lua を IR + 判定 1 箇所 + printer 3 種に再構築する

**Files:**
- Modify: `lua/inline-explorer/substitute.lua`（`enclosing_statement` 以降、`inline_call` までを置換。`M.call_name_at` / `M.inline_in_buffer` は不変）

**Interfaces:**
- Consumes: 既存ヘルパ `parse, sb, eb, scol, text, query_nodes, decl_name, func_declarator, return_type, find_function_def, find_calls, get_params, build_bind, apply_edits, common_ws_prefix, rebase, enclosing_scope, enclosing_statement`（すべて現行のまま）
- Produces: `M.inline_call`（API 不変）、`M._probe`（Task 2 の仕様どおり）

- [ ] **Step 1: 現行 `M.inline_call`（`-- Build the transform.` コメントから関数 `end` まで、`substitute.lua:263-546`）を削除し、以下に置き換える**

```lua
-- ---------------------------------------------------------------------------
-- Analysis: resolve the callee into a small IR and the call site into a ctx,
-- so that a single decision point picks one of three "dumb" printers. The
-- printers do layout only; every judgement lives in analyze_* / decide.
-- ---------------------------------------------------------------------------

-- IR: everything the printers need to know about the callee.
--   params/rename   parameter list and planned collision renames (name__ieN)
--   stmts/returns   body statement nodes and return_statement nodes
--   body_edits      label-suffix + rename edits on callee_src (absolute bytes)
--   ret_type        reconstructed declared return type text
--   has_value       whether returns carry an expression
--   simple          straight-line body with a single trailing return
--   ret_var/end_label  injected names, unique per expansion id N
local function analyze_callee(callee_src, fname, N, scope)
  local fdef, fd = find_function_def(parse(callee_src), callee_src, fname)
  if not fdef then
    return nil, "definition of '" .. fname .. "' not found"
  end
  local params, variadic = get_params(fd, callee_src)
  if variadic then
    return nil, "cannot inline variadic function '" .. fname .. "'"
  end

  local body = fdef:field("body")[1]
  local stmts = {}
  for i = 0, body:named_child_count() - 1 do
    stmts[#stmts + 1] = body:named_child(i)
  end
  if #stmts == 0 then
    return nil, "empty function body"
  end
  local returns = query_nodes(body, callee_src, "(return_statement) @r")

  -- Names hoisted into the caller scope; rename those that would collide.
  local rename = {}
  local function maybe_rename(nm)
    if nm and scope[nm] then
      rename[nm] = nm .. "__ie" .. N
    end
  end
  for _, p in ipairs(params) do
    maybe_rename(p.name)
  end
  for _, s in ipairs(stmts) do
    if s:type() == "declaration" then
      for _, d in ipairs(query_nodes(s, callee_src, "(init_declarator declarator: (_) @d)")) do
        maybe_rename(decl_name(d, callee_src))
      end
      for _, d in ipairs(query_nodes(s, callee_src, "(declaration declarator: (identifier) @d)")) do
        maybe_rename(text(d, callee_src))
      end
    end
  end

  -- Body edits: label suffixing + collision renames (disjoint from return edits).
  local body_edits = {}
  local function suffix_label(n)
    body_edits[#body_edits + 1] = { sb(n), eb(n), text(n, callee_src) .. "__ie" .. N }
  end
  for _, n in ipairs(query_nodes(body, callee_src, "(labeled_statement label: (statement_identifier) @l)")) do
    suffix_label(n)
  end
  for _, n in ipairs(query_nodes(body, callee_src, "(goto_statement label: (statement_identifier) @g)")) do
    suffix_label(n)
  end
  if next(rename) then
    for _, id in ipairs(query_nodes(body, callee_src, "(identifier) @i")) do
      local r = rename[text(id, callee_src)]
      -- Do not rename the callee of a call (function names live in caller scope).
      local parent = id:parent()
      local is_callee = parent and parent:type() == "call_expression" and parent:field("function")[1] == id
      if r and not is_callee then
        body_edits[#body_edits + 1] = { sb(id), eb(id), r }
      end
    end
  end

  local last = stmts[#stmts]
  return {
    src = callee_src,
    params = params,
    rename = rename,
    stmts = stmts,
    returns = returns,
    body_edits = body_edits,
    ret_type = return_type(fdef, callee_src),
    has_value = returns[1] ~= nil and returns[1]:named_child_count() > 0,
    simple = #returns == 1 and last:type() == "return_statement" and last:named_child_count() > 0,
    ret_var = "__ie_ret" .. N,
    end_label = "__ie_end" .. N,
  }
end

-- ctx: everything the printers need to know about the call site.
--   braced          the enclosing statement sits directly inside a {} block
--                   (if not, hoisting printers must wrap in a block: a
--                   declaration cannot follow a bare label / unbraced if body)
--   unconditional   the call is reached unconditionally in a plain statement
--                   (not in a loop/if header, ?: arm, or after &&/||)
--   stmt_bol/indent/unit  layout facts; the source's tabs/spaces are preserved
local function analyze_context(caller_src, call)
  local target = enclosing_statement(call)
  local t = target:type()
  local unconditional = t == "return_statement" or t == "expression_statement" or t == "declaration"
  if unconditional then
    local n = call
    while n and n ~= target do
      local ty = n:type()
      if ty == "conditional_expression" then
        unconditional = false
      elseif ty == "binary_expression" then
        for i = 0, n:child_count() - 1 do
          local ch = n:child(i)
          if not ch:named() and (text(ch, caller_src) == "&&" or text(ch, caller_src) == "||") then
            unconditional = false
          end
        end
      end
      n = n:parent()
    end
  end
  local stmt_bol = sb(target) - scol(target)
  local indent = caller_src:sub(stmt_bol + 1, sb(target))
  local parent_t = target:parent() and target:parent():type()
  return {
    call = call,
    target = target,
    braced = parent_t == "compound_statement",
    unconditional = unconditional,
    stmt_bol = stmt_bol,
    indent = indent,
    unit = indent:find("\t") and "\t" or "    ",
  }
end

-- The single decision point: which printer renders this expansion.
--   pretty          simple callee, and hoisting is provably safe (or the user
--                   asked for readable output, which tolerates the risk)
--   readable_multi  readable mode for everything else: no ({...})/goto, may
--                   not preserve semantics (documented trade-off)
--   canonical       the always-correct GNU statement expression + goto form
local function decide(ir, ctx, mode)
  if ir.simple and (mode == "readable" or ctx.unconditional) then
    return "pretty"
  end
  if mode == "readable" then
    return "readable_multi"
  end
  return "canonical"
end

-- ---------------------------------------------------------------------------
-- Printers: pure layout. Each receives (caller_src, ir, ctx) and returns the
-- transformed caller source. No judgements here beyond mechanical wrapping.
-- ---------------------------------------------------------------------------

local function splice(caller_src, edits)
  return apply_edits(caller_src, 0, #caller_src, edits)
end

-- Rewrite `return E;` inside the body region.
-- style "goto":   `return E;` -> `{ ret = E; goto end; }` (self-contained)
-- style "assign": `return E;` -> `ret = E;`               (no control flow)
local function return_edits(ir, style)
  local eds = {}
  for _, r in ipairs(ir.returns) do
    local kw = r:child(0)
    local semi = r:child(r:child_count() - 1)
    local has_expr = r:named_child_count() > 0
    if style == "assign" then
      eds[#eds + 1] = { sb(kw), eb(kw), has_expr and (ir.ret_var .. " =") or "(void)0" }
    elseif has_expr then
      eds[#eds + 1] = { sb(kw), eb(kw), "{ " .. ir.ret_var .. " =" }
      eds[#eds + 1] = { sb(semi), eb(semi), "; goto " .. ir.end_label .. "; }" }
    else
      eds[#eds + 1] = { sb(kw), eb(kw), "{ goto " .. ir.end_label .. ";" }
      eds[#eds + 1] = { sb(semi), eb(semi), " }" }
    end
  end
  return eds
end

-- Body statements [1..last_i] with `extra` edits applied, dedented to "".
local function body_text(ir, last_i, extra)
  local edits = {}
  vim.list_extend(edits, ir.body_edits)
  vim.list_extend(edits, extra or {})
  local rstart = sb(ir.stmts[1]) - scol(ir.stmts[1])
  return apply_edits(ir.src, rstart, eb(ir.stmts[last_i]), edits)
end

-- Replace the whole target statement with `{ hoist...; modified target }`.
local function print_wrapped(caller_src, ir, ctx, hoist, replacement)
  local ttext = text(ctx.target, caller_src)
  local off = sb(ctx.call) - sb(ctx.target)
  local modified = ttext:sub(1, off) .. replacement .. ttext:sub(eb(ctx.call) - sb(ctx.target) + 1)
  local inner = ctx.indent .. ctx.unit
  local out = { "{" }
  for _, l in ipairs(hoist) do
    out[#out + 1] = inner .. l
  end
  for _, l in ipairs(vim.split(modified, "\n", { plain = true })) do
    out[#out + 1] = inner .. l
  end
  out[#out + 1] = ctx.indent .. "}"
  return splice(caller_src, { { sb(ctx.target), eb(ctx.target), table.concat(out, "\n") } })
end

-- Insert `hoist` lines above the target statement and swap the call for
-- `replacement`; wraps in a block when the target is not directly braced.
local function print_hoisted(caller_src, ir, ctx, hoist, replacement)
  if not ctx.braced then
    return print_wrapped(caller_src, ir, ctx, hoist, replacement)
  end
  local block = {}
  for _, l in ipairs(hoist) do
    block[#block + 1] = ctx.indent .. l
  end
  return splice(caller_src, {
    { ctx.stmt_bol, ctx.stmt_bol, table.concat(block, "\n") .. "\n" },
    { sb(ctx.call), eb(ctx.call), replacement },
  })
end

-- Pretty hoist: setup lifted above the statement, the returned expression
-- spliced in place (parenthesised, so precedence is preserved).
local function print_pretty(caller_src, ir, ctx)
  local hoist = {}
  vim.list_extend(hoist, ir.binds)
  if #ir.stmts >= 2 then
    vim.list_extend(hoist, rebase(body_text(ir, #ir.stmts - 1), ""))
  end
  local expr = ir.stmts[#ir.stmts]:named_child(0)
  local expr_text = apply_edits(ir.src, sb(expr), eb(expr), ir.body_edits)
  return print_hoisted(caller_src, ir, ctx, hoist, "(" .. expr_text .. ")")
end

-- Canonical form: GNU statement expression + return->goto. Legal in any
-- expression context, so it needs no wrapping and no safety analysis.
local function print_canonical(caller_src, ir, ctx)
  local inner = ctx.indent .. ctx.unit
  local parts = { "({" }
  for _, b in ipairs(ir.binds) do
    parts[#parts + 1] = inner .. b
  end
  if ir.has_value then
    parts[#parts + 1] = inner .. ir.ret_type .. " " .. ir.ret_var .. ";"
  end
  vim.list_extend(parts, rebase(body_text(ir, #ir.stmts, return_edits(ir, "goto")), inner))
  parts[#parts + 1] = inner .. ir.end_label .. ":;"
  if ir.has_value then
    parts[#parts + 1] = inner .. ir.ret_var .. ";"
  end
  parts[#parts + 1] = ctx.indent .. "})"
  return splice(caller_src, { { sb(ctx.call), eb(ctx.call), table.concat(parts, "\n") } })
end

-- Readable general form: body hoisted with return -> assignment, no ({})/goto.
-- Reads top-to-bottom; not faithful for functions with early returns.
local function print_readable_multi(caller_src, ir, ctx)
  local hoist = {}
  vim.list_extend(hoist, ir.binds)
  if ir.has_value then
    hoist[#hoist + 1] = ir.ret_type .. " " .. ir.ret_var .. ";"
  end
  vim.list_extend(hoist, rebase(body_text(ir, #ir.stmts, return_edits(ir, "assign")), ""))
  return print_hoisted(caller_src, ir, ctx, hoist, ir.ret_var)
end

local PRINTERS = {
  pretty = print_pretty,
  canonical = print_canonical,
  readable_multi = print_readable_multi,
}

-- Build the transform. Returns (new_caller_src, err).
-- mode: "correct" (default, guaranteed to compile) or "readable" (cleaner
-- output that skips ({...})/goto and may not compile in edge cases).
function M.inline_call(caller_src, callee_src, fname, N, occ, mode)
  N = N or 1
  occ = occ or 1
  mode = mode or "correct"

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
  for i, p in ipairs(ir.params) do
    ir.binds[i] = build_bind(p, args[i], ir.rename, N, i, callee_src)
  end

  local ctx = analyze_context(caller_src, call)
  return PRINTERS[decide(ir, ctx, mode)](caller_src, ir, ctx)
end

-- Test/introspection hook: run the analysis without printing.
function M._probe(caller_src, callee_src, fname, occ, mode)
  local call = find_calls(parse(caller_src), caller_src, fname)[occ or 1]
  if not call then
    return nil, "call to '" .. fname .. "' not found"
  end
  local ir, err = analyze_callee(callee_src, fname, 1, enclosing_scope(call, caller_src))
  if not ir then
    return nil, err
  end
  local ctx = analyze_context(caller_src, call)
  return { ir = ir, ctx = ctx, decision = decide(ir, ctx, mode or "correct") }
end
```

ファイル冒頭のモジュールコメント（`substitute.lua:1-18`）の箇条書きに、構造の説明を 1 行追加する:

```lua
-- Structure: analyze_callee -> IR, analyze_context -> ctx, decide (the single
-- decision point) -> one of three layout-only printers (pretty / canonical
-- statement-expression / readable-multi).
```

- [ ] **Step 2: ir_spec が green になったか確認する**

Run: `nvim --headless --clean -u NONE -c "luafile tests/ir_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: `ALL IR TESTS PASSED`

- [ ] **Step 3: 既存黒箱テストが green のままか確認する**

Run: `nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!" 2>&1 | tail -3`
Expected: `ALL SUBSTITUTE TESTS PASSED`

Run: `nvim --headless --clean -u NONE -c "luafile tests/macro_spec.lua" -c "qa!" 2>&1 | tail -1`
Expected: `ALL MACRO TESTS PASSED`

- [ ] **Step 4: 旧コードの残骸が無いか確認する**

Run: `grep -nE "hoist_safe|emit_pretty|emit_stmt_expr|emit_readable_multi|callee_simple" lua/inline-explorer/substitute.lua`
Expected: 出力なし（旧 emitter・旧判定は完全に消えている）

- [ ] **Step 5: Commit**

```bash
git add lua/inline-explorer/substitute.lua
git commit -m "Restructure substitute into IR + single decision + dumb printers

Replace the interleaved emitter closures with a pipeline: analyze_callee
resolves the callee into a small IR (binds, statements, returns, renames,
return type), analyze_context resolves the call site (braced,
unconditionally-reached, indentation), and decide() is the one place
that picks a printer. The three printers (pretty hoist, canonical
statement expression, readable-multi) do layout only. External API is
unchanged; M._probe exposes the analysis for unit tests."
```

---

### Task 4: 実ソース回帰（cJSON）+ 仕上げ

**Files:**
- Test: `tests/real_cjson_spec.lua`（実行のみ、変更なし）
- Modify: `DESIGN.md`（構造の 1 段落追記）

**Interfaces:**
- Consumes: Task 3 の `M.inline_call`
- Produces: なし（検証と文書化）

- [ ] **Step 1: cJSON 実ソース回帰を実行する（ネットワーク必要）**

Run: `nvim --headless --clean -u NONE -c "luafile tests/real_cjson_spec.lua" -c "qa!" 2>&1 | tail -5`
Expected: `ALL ACCEPTED TRANSFORMS COMPILE + PASS ON REAL cJSON`（`engine-accepted` 件数が従前と同水準であること。激減していたら decide/printer の退行を疑う）

ネットワーク不可なら SKIP 表示を確認し、その旨をコミットメッセージに残す。

- [ ] **Step 2: DESIGN.md に新構造を反映する**

`DESIGN.md` の「Inline substitution (C-only)」節の "Mechanism:" の直前に追記:

```markdown
Since the 2026-07 restructuring the engine is a pipeline: `analyze_callee`
resolves the callee into a small IR, `analyze_context` resolves the call
site, and a single `decide()` picks one of three layout-only printers
(pretty hoist / canonical statement expression / readable-multi). The
canonical form is the semantic baseline — legal in any expression context —
and prettier output is only chosen when the analysis proves it safe.
```

- [ ] **Step 3: 全 spec 最終確認**

Run（4 本すべて）:
```sh
nvim --headless --clean -u NONE -c "luafile tests/ir_spec.lua" -c "qa!"
nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!"
nvim --headless --clean -u NONE -c "luafile tests/macro_spec.lua" -c "qa!"
nvim --headless --clean -u NONE -c "luafile tests/resolver_spec.lua" -c "qa!"
```
Expected: すべて `ALL ... PASSED`

- [ ] **Step 4: Commit**

```bash
git add DESIGN.md
git commit -m "DESIGN: document the IR + single-decision engine structure"
```

---

## Self-Review 済み事項

- Spec 対応: P1 = Task 1、P2 = Task 2-4。P3/P4/P5 は本 plan の範囲外（別 plan）
- 型整合: `M._probe` の戻り値仕様は Task 2（テスト）と Task 3（実装）で同一
- `ir.binds` は `_probe` では未設定（args 不要のため）。ir_spec は binds を検証しない
- プレースホルダなし。全ステップに実コード・実コマンド・期待出力あり
