# inline-explorer.nvim

Read large codebases by **expanding function, type, and macro definitions
inline**, right where they are called — and expanding again inside what you just
expanded. No window-hopping, no floating peek windows.

Built for reading the Linux kernel, but **language-agnostic**: it works for any
language whose server implements `workspace/symbol`, and reads best with a
tree-sitter parser installed too (C/C++, TypeScript/JavaScript, Python, Rust,
Go, Lua, …).

Expansions happen in a dedicated **read-only copy** of the file, so your real
source is never touched. Each expansion is a real block of text you can move the
cursor into and expand further, and every block is a fold you can collapse when
you want the big picture back.

![Expanding a call inline, then expanding again inside the body, in the Linux kernel](assets/inline-explorer-demo.gif)

```
ret = do_work(x);
  /* v do_work (function_definition) */
  static int do_work(int x)
  {
      return helper(x) + 1;
        /* v helper (function_definition) */
        static int helper(int x) { return x << 1; }
        /* ^ helper */
  }
  /* ^ do_work */
```

## Requirements

- Neovim 0.10+
- **A language server** attached to your files that implements `workspace/symbol`
  (clangd, ts_ls / vtsls, pyright, rust-analyzer, gopls, lua_ls, …). Resolution is
  powered by its index.
- **The tree-sitter parser for your language** (`:TSInstall <lang>`, or via
  `nvim-treesitter`). It powers **highlighting the reading view**
  (see [Syntax highlighting](#syntax-highlighting-in-the-view)), C inline
  substitution (`:InlineExplorerInline`), and serves as the extraction fallback
  when the server yields no usable range.
- For C specifically, a `compile_commands.json` clangd can find — essential for
  the kernel:
  ```sh
  make defconfig
  ./scripts/clang-tools/gen_compile_commands.py
  ```

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "50n1cd347h9/inline-explorer.nvim",
  dependencies = { "neovim/nvim-lspconfig" },
  opts = {}, -- calls setup()
}
```

or manually:

```lua
require("inline-explorer").setup()
```

## Setup & verification

Getting the plugin *installed* and getting its *keymaps* to fire are two separate
things. Work through these in order.

**1. Confirm it is installed.** Any one of:

```vim
:Lazy                                       " look for inline-explorer.nvim, no ✗
:lua print(pcall(require, "inline-explorer"))  " prints  true
:InlineExplorer<Tab>                        " completes to the commands
```

**2. Set your leader key BEFORE plugins load.** The keymaps bind to whatever
`mapleader` is *at the moment `setup()` runs*. Put this at the **top** of your
`init.lua`, before `require("lazy").setup(...)`:

```lua
vim.g.mapleader = " "       -- note the spelling: map + leader
vim.g.maplocalleader = " "
```

Two things that silently break the `<leader>ee` maps (the commands still work):

- A typo in the variable name (`mapledaer`, `maploeader`, …) leaves `mapleader`
  at the default `\`, so the maps bind to `\ee` instead of `<space>ee`.
- Setting `mapleader` *after* the plugin loads. Reorder and restart.

Check it with:

```vim
:lua print(vim.inspect(vim.g.mapleader))    " expect  " "
```

If you would rather not depend on leader timing at all, bind explicit maps
yourself — these are independent of `mapleader`:

```lua
vim.keymap.set("n", "<space>eo", "<cmd>InlineExplorerOpen<cr>")
vim.keymap.set("n", "<space>ee", "<cmd>InlineExplorerExpand<cr>")
vim.keymap.set("n", "<space>ei", "<cmd>InlineExplorerInline<cr>")
vim.keymap.set("n", "<space>ec", "za")
vim.keymap.set("n", "<space>eq", "<cmd>InlineExplorerClose<cr>")
```

**3. Confirm a language server is attached.** Open a file and run `:LspInfo` (or
`:checkhealth lsp`). You should see a server attached (clangd, ts_ls, pyright, …).
If not, expansion fails with `no language server attached to the source buffer`.

## Usage

Open a file (with a language server attached), then:

| Keymap        | Command                     | Action                                              |
| ------------- | --------------------------- | --------------------------------------------------- |
| `<leader>eo`  | `:InlineExplorerOpen`       | Open a reading view for the current file            |
| `<leader>ee`  | `:InlineExplorerExpand`     | Block-expand the symbol under the cursor (any lang) |
| `<leader>ei`  | `:InlineExplorerInline`     | Inline in place: functions inlined, macros expanded (C) |
| `<leader>ec`  | (`za`)                      | Fold / unfold the expansion under the cursor        |
| `u` / `<C-r>` | —                           | Undo / redo the last expansion (inside the view)    |
| `]e` / `[e`   | `:InlineExplorerNext`/`Prev`| Jump to the next / previous expansion block         |
| `<leader>el`  | `:InlineExplorerList`       | Expansion blocks in the location list               |
| `<leader>eq`  | `:InlineExplorerClose`      | Close the reading view                              |

Expansions nest: move the cursor onto any function/macro inside an expanded body
(block) or inlined fragment (substitution) and expand again. `u`/`<C-r>` are
buffer-local snapshots of the view, so they undo/redo whole expansions without
touching your real files (native undo does not apply — the view is read-only).

Put the cursor on a function call or macro and expand it. Its body is spliced in
below, indented and folded-open. Move into that body and expand again to go
deeper. Folding a block collapses its subtree; unfolding reopens it — nothing is
re-fetched.

For deep sessions, `require("inline-explorer").breadcrumb()` returns the chain
of expansions the cursor is inside (`do_work > helper`), empty outside a view —
drop it into your statusline.

> Tip: until your keymaps are sorted, drive it entirely by command
> (`:InlineExplorerOpen`, then `:InlineExplorerExpand` on a symbol). The commands
> never depend on `mapleader`.

## Inline substitution (C)

`:InlineExplorerInline` (`<leader>ei`) does more than paste the definition
below the call — it **rewrites the call into the effect of the function body**,
the way a compiler inlines it, so the surrounding statement reads on its own. This
is C-only and requires the tree-sitter `c` parser.

Given `return snap != acquire(c);`, inlining `acquire` produces:

```c
int cpu = (c);
struct ct *p = per_cpu_ptr(CT, cpu);
return snap != (p->state & MASK);
```

How it works:

- **Parameters** are bound to their declared type (`int cpu = (c);`), reconstructed
  from the definition so arrays decay to pointers and a `0`/NULL argument keeps the
  right pointer type; `__auto_type` is a fallback for exotic declarators.
- **Simple functions** (straight-line, single trailing return) are rendered as a
  *pretty hoist*: setup statements lifted above the call, the returned expression
  spliced in place (parenthesised, so precedence is preserved).
- **Anything else** (early returns, loops, control flow) is rendered as a GNU
  **statement expression** `({ ... })`, with each `return E;` rewritten to
  `{ __ie_retN = E; goto __ie_endN; }`. There is no fallback to block-paste.
- **Callee labels** and **locals that would collide** with the caller scope are
  suffixed `name__ieN` so repeated/nested inlining stays correct.

### correct vs. readable

The `mode` option chooses the output style (toggle live with
`:InlineExplorerToggleMode`):

- **`correct`** (default) — the result is guaranteed to compile. Complex functions
  become GNU statement expressions with `return`→`goto`, and hoists are wrapped in
  a block after labels. Faithful to the original's semantics.
- **`readable`** — favours clean output: never emits `({...})` or `goto`, hoists
  the body top-to-bottom. Prettier, but **not guaranteed to compile or preserve
  semantics** for functions with early returns / labels / short-circuits.

```lua
require("inline-explorer").setup({ mode = "correct" }) -- or "readable"
```

### Tested against real source

Correctness is verified on **real OSS**, not just hand-written snippets:

- `tests/real_cjson_spec.lua` clones [cJSON](https://github.com/DaveGamble/cJSON)
  and, for **every** in-file call to a same-file static function, applies
  correct-mode substitution then has gcc **rebuild and run cJSON's test suite**.
  Every transform the engine accepts must compile and pass.
- `tests/substitute_spec.lua` compiles+runs a focused set of shaped cases
  (pointers, early returns, labels, collisions, void, a kernel-style accessor).
- `tests/properties_spec.lua` and `tests/pbt_spec.lua` add **property-based
  testing** on top: a deterministic generator (`tests/lib/gen.lua`) builds
  UB-free random callees and splices them into nine caller contexts. The fast
  layer checks tree-sitter invariants over ~300 cases per run; the gcc layer
  builds and runs each program before and after substitution and requires
  byte-identical stdout — and whenever the engine chooses the pretty form, the
  canonical form of the same call must agree too. Failures shrink to a minimal
  counterexample and print their seed (`IE_PBT_SEED` / `IE_PBT_CASES` /
  `IE_PROP_CASES` control reproduction and budget). A zero-argument call
  wrapped as `(f()) & k` parses as a cast in tree-sitter-c (no semantic type
  info), so the engine's rejection of that shape is expected and exempted by
  the property layers.

```sh
nvim --headless --clean -u NONE -c "luafile tests/real_cjson_spec.lua" -c "qa!"
nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!"
nvim --headless --clean -u NONE -c "luafile tests/properties_spec.lua" -c "qa!"
IE_PBT_CASES=100 IE_PBT_SEED=42 \
  nvim --headless --clean -u NONE -c "luafile tests/pbt_spec.lua" -c "qa!"
```

Limitations: macros and variadic functions are not inlinable this way; the current
action rewrites the whole view buffer, so it resets any block-expansion folds in
the view.

## Macros

Macros have no type or structured body, so they cannot be transformed like
functions. Two ways to see one, under the same keys as functions:

- **`<leader>ei`** (smart inline) replaces the macro use **in place** with its
  expansion, fetched from the **live clangd** -- preferring the `ExpandMacro`
  tweak (its `workspace/applyEdit` is intercepted and kept out of the real
  file), with `textDocument/hover` scraping as the fallback -- so it respects
  your include paths, `#define`s and `#ifdef` state. The query runs against the
  original source: the view line is mapped back to the file line it came from,
  so it stays exact however far prior expansions have shifted things. A macro
  use sitting on inserted text (inside an expanded body) has no source
  position and falls back to block expansion.
- **`<leader>ee`** (block expand) drops the macro's definition below the use as a
  folded block, like any other symbol.

Both are read-only — your real file is not edited. (One theoretical exception:
a tweak reply straggling in seconds late, past the ~5 s interception window,
would reach Neovim's default `applyEdit` handler.)

## Configuration

Defaults:

```lua
require("inline-explorer").setup({
  keymaps = {
    substitute = "<leader>ei", -- smart inline (in place); the primary action
    expand = "<leader>ee",     -- explicit block-paste (also the fallback)
    toggle_fold = "<leader>ec",
    open = "<leader>eo",
    close = "<leader>eq",
    undo = "u",                -- buffer-local to the view
    redo = "<C-r>",            -- buffer-local to the view
  },
  indent = "  ", -- indent added per expansion level
  header = true, -- wrap each expansion in /* v name */ ... /* ^ name */
  mode = "correct", -- inline-substitution output: "correct" | "readable"
})
```

Set any keymap to `false` to skip it. Keymap strings are bound at `setup()` time,
so `<leader>` here follows the same timing rule as above.

## Syntax highlighting in the view

The reading view is a detached copy that no language server is attached to, so
its **semantic-token** highlighting (the server-driven colors) is not available
there. To keep the view from falling back to bare regex syntax, the plugin starts
**tree-sitter** highlighting on the view buffer explicitly. Install the parser for
your language (`:TSInstall <lang>`) and the view stays richly highlighted.

Note that once you expand a body mid-file the buffer is no longer valid C as a
whole; tree-sitter is error-tolerant and still highlights recognizable tokens,
but expect the odd imperfectly-colored region deep in a nesting.

## Measuring latency

If an expansion feels slow, let the plugin tell you where the time goes rather
than guessing:

```vim
:InlineExplorerProfile on     " start recording (off by default, free when off)
" ... use <leader>ee / <leader>ei a few times ...
:InlineExplorerProfile        " report
```

```
span                       n     total     mean      max     last
----------------------------------------------------------------
extract:cold               2      768ms     384ms     568ms     200ms
expand (total)             1      575ms     575ms     575ms     575ms
inline (total, macro)      1      320ms     320ms     320ms     320ms
macro:tweak                1      108ms     108ms     108ms     108ms
locate                     2       10ms       5ms       7ms       3ms
view.rewrite               1        2ms       2ms       2ms       2ms
```

`extract:cold` is the server building the definition header's preamble the
first time that header is touched — on the Linux kernel that is ~0.5s for a
big header like `net/sock.h`, while `extract:cached` for a later symbol in the
same header is ~20ms. The plugin keeps the last few definition files attached
for exactly that reason (`:InlineExplorerProfile clear` between experiments).

Enable it permanently with `setup({ profile = true })`.

## Buildroot / cross-compiled kernel

The plugin itself does not change — the work is getting clangd happy against a
cross build.

1. **compile_commands.json for the kernel** lives in the Buildroot build tree.
   After building, run the kernel's own generator there:
   ```sh
   cd output/build/linux-<version>
   ./scripts/clang-tools/gen_compile_commands.py
   ```
2. **Teach clangd the cross toolchain.** The compile commands reference
   Buildroot's cross gcc, so clangd needs `--query-driver` to trust it and pull
   the built-in include paths — otherwise you get missing-header errors:
   ```lua
   require("lspconfig").clangd.setup({
     cmd = { "clangd", "--query-driver=/abs/path/to/output/host/bin/*", "--background-index" },
   })
   ```
3. **Other C packages** (`output/build/<pkg>-<ver>/`): CMake packages emit
   `compile_commands.json` when `CMAKE_EXPORT_COMPILE_COMMANDS=ON`; for
   autotools/Makefile packages wrap the build with [`bear`](https://github.com/rizsotto/Bear):
   `bear -- make`.

## Troubleshooting

| Symptom                              | Cause / fix                                                        |
| ------------------------------------ | ----------------------------------------------------------------- |
| `<leader>ee` does nothing, commands work | `mapleader` not set to space before load, or a typo. See [Setup](#setup--verification). |
| `open a reading view first`          | Run `:InlineExplorerOpen` first.                                  |
| `no language server attached ...`    | No server attached — check `:LspInfo`.                          |
| `no symbol named 'x'`                | The server's index does not cover it (for C, check `compile_commands.json`). |
| View looks washed out                | Install the tree-sitter parser for the language (`:TSInstall <lang>`). |

## How it works

- **View** — a scratch copy of the source buffer, `nomodifiable`,
  `foldmethod=manual`, with tree-sitter highlighting started explicitly.
- **Resolver** — looks the symbol up by name via the server's `workspace/symbol`,
  then asks the server for the definition's full range via
  `textDocument/documentSymbol` (tree-sitter extraction and a brace heuristic
  remain as fallbacks when no server range is available). Name-based lookup is
  what makes nesting possible: inserted text has no real file position to query by.
- **Expander** — splices the body below the call line, tracks it with extmarks,
  and wraps it in a fold.

## Known limitations

- **No server semantic highlighting in the view** — tree-sitter is used instead
  (see above).
- **Name-based resolution.** Symbols that share a name (C `static` functions in
  different files, TS overloads / re-exports, …) may resolve to the wrong one. The
  exact-name match picks the server's first hit.
- **Coverage depends on the server.** A definition is only found if the server's
  `workspace/symbol` returns it, and its exact extent comes from the server's
  `textDocument/documentSymbol`. Without a usable server range, a tree-sitter
  parser (if installed) or a C-family brace heuristic takes over.
- **C macros show their `#define` body**, not a fully flattened expansion — which
  is usually what you want when exploring, since you can keep expanding identifiers
  inside it.
- **Recursion guard is ancestor-only**: a symbol will not expand inside its own
  body, but mutual recursion across siblings is not detected.

## TODO
- test with Linux Kernel

## License

MIT
