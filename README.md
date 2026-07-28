# inline-explorer.nvim

Read large codebases by **expanding function, type, and macro definitions
inline**, right where they are called — and expanding again inside what you just
expanded. No window-hopping, no floating peek windows.

Built for reading the Linux kernel, but **language-agnostic**: it works for any
language whose server implements `workspace/symbol` and that has a tree-sitter
parser installed (C/C++, TypeScript/JavaScript, Python, Rust, Go, Lua, …).

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
  `nvim-treesitter`). It is used for two things: extracting exact definition
  bodies, and **highlighting the reading view**
  (see [Syntax highlighting](#syntax-highlighting-in-the-view)).
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
| `<leader>ei`  | `:InlineExplorerSubstitute` | Inline in place: functions inlined, macros expanded (C) |
| `<leader>ec`  | (`za`)                      | Fold / unfold the expansion under the cursor        |
| `u` / `r`     | —                           | Undo / redo the last expansion (inside the view)    |
| `<leader>eq`  | `:InlineExplorerClose`      | Close the reading view                              |

Expansions nest: move the cursor onto any function/macro inside an expanded body
(block) or inlined fragment (substitution) and expand again. `u`/`r` are
buffer-local snapshots of the view, so they undo/redo whole expansions without
touching your real files (native undo does not apply — the view is read-only).

Put the cursor on a function call or macro and expand it. Its body is spliced in
below, indented and folded-open. Move into that body and expand again to go
deeper. Folding a block collapses its subtree; unfolding reopens it — nothing is
re-fetched.

> Tip: until your keymaps are sorted, drive it entirely by command
> (`:InlineExplorerOpen`, then `:InlineExplorerExpand` on a symbol). The commands
> never depend on `mapleader`.

## Inline substitution (C)

`:InlineExplorerSubstitute` (`<leader>ei`) does more than paste the definition
below the call — it **rewrites the call into the effect of the function body**,
the way a compiler inlines it, so the surrounding statement reads on its own. This
is C-only and requires the tree-sitter `c` parser.

Given `return snap != acquire(c);`, inlining `acquire` produces:

```c
__typeof__(c) cpu = (c);
struct ct *p = per_cpu_ptr(CT, cpu);
return snap != (p->state & MASK);
```

How it works:

- **Parameters** become `__typeof__(arg) param = (arg);` bindings — correct
  call-by-value semantics with no type reconstruction.
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

```sh
nvim --headless --clean -u NONE -c "luafile tests/real_cjson_spec.lua" -c "qa!"
nvim --headless --clean -u NONE -c "luafile tests/substitute_spec.lua" -c "qa!"
```

Limitations: macros and variadic functions are not inlinable this way; the current
action rewrites the whole view buffer, so it resets any block-expansion folds in
the view.

## Macros

Macros have no type or structured body, so they cannot be transformed like
functions. Two ways to see one, under the same keys as functions:

- **`<leader>ei`** (smart inline) replaces the macro use **in place** with its
  expansion, fetched from the **live clangd** (`textDocument/hover`), so it
  respects your include paths, `#define`s and `#ifdef` state. The query runs
  against the original source at the cursor, reliable at depth 0; large line
  shifts from prior expansions can misalign it.
- **`<leader>ee`** (block expand) drops the macro's definition below the use as a
  folded block, like any other symbol.

Both are read-only — your real file is never edited.

## Configuration

Defaults:

```lua
require("inline-explorer").setup({
  keymaps = {
    expand = "<leader>ee",
    toggle_fold = "<leader>ec",
    open = "<leader>eo",
    close = "<leader>eq",
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
  then extracts the exact definition with tree-sitter (a language-agnostic node
  matcher, with a brace heuristic as last resort). Name-based lookup is what makes
  nesting possible: inserted text has no real file position to query by.
- **Expander** — splices the body below the call line, tracks it with extmarks,
  and wraps it in a fold.

## Known limitations

- **No server semantic highlighting in the view** — tree-sitter is used instead
  (see above).
- **Name-based resolution.** Symbols that share a name (C `static` functions in
  different files, TS overloads / re-exports, …) may resolve to the wrong one. The
  exact-name match picks the server's first hit.
- **Coverage depends on the server and parser.** A definition is only found if the
  server's `workspace/symbol` returns it and a tree-sitter parser is installed for
  the language; without a parser the brace-based fallback only handles C-family
  syntax.
- **C macros show their `#define` body**, not a fully flattened expansion — which
  is usually what you want when exploring, since you can keep expanding identifiers
  inside it.
- **Recursion guard is ancestor-only**: a symbol will not expand inside its own
  body, but mutual recursion across siblings is not detected.

## TODO
- test with Linux Kernel

## License

MIT
