# inline-explorer.nvim

Read large C codebases (the Linux kernel, in particular) by **expanding function
and macro definitions inline**, right where they are called — and expanding again
inside what you just expanded. No window-hopping, no floating peek windows.

Expansions happen in a dedicated **read-only copy** of the file, so your real
source is never touched. Each expansion is a real block of text you can move the
cursor into and expand further, and every block is a fold you can collapse when
you want the big picture back.

![Expanding a function inline, then expanding a struct inside it, in the kernel's rmnet_config.c](assets/demo.gif)

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
- **clangd** attached to your C files (resolution is powered by its index)
- A `compile_commands.json` clangd can find — essential for the kernel:
  ```sh
  make defconfig
  ./scripts/clang-tools/gen_compile_commands.py
  ```
- **The tree-sitter `c` parser** (`:TSInstall c`, or via `nvim-treesitter`).
  It is used for two things: extracting exact definition bodies, and
  **highlighting the reading view** (see [Syntax highlighting](#syntax-highlighting-in-the-view)).

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

**3. Confirm clangd is attached.** Open a C file and run `:LspInfo` (or
`:checkhealth lsp`). You should see **clangd** attached. If not, expansion fails
with `clangd is not running`.

## Usage

Open a C file (with clangd attached), then:

| Keymap        | Command                  | Action                                         |
| ------------- | ------------------------ | ---------------------------------------------- |
| `<leader>eo`  | `:InlineExplorerOpen`    | Open a reading view for the current file       |
| `<leader>ee`  | `:InlineExplorerExpand`  | Expand the symbol under the cursor             |
| `<leader>ec`  | (`za`)                   | Fold / unfold the expansion under the cursor   |
| `<leader>eq`  | `:InlineExplorerClose`   | Close the reading view                         |

Put the cursor on a function call or macro and expand it. Its body is spliced in
below, indented and folded-open. Move into that body and expand again to go
deeper. Folding a block collapses its subtree; unfolding reopens it — nothing is
re-fetched.

> Tip: until your keymaps are sorted, drive it entirely by command
> (`:InlineExplorerOpen`, then `:InlineExplorerExpand` on a symbol). The commands
> never depend on `mapleader`.

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
})
```

Set any keymap to `false` to skip it. Keymap strings are bound at `setup()` time,
so `<leader>` here follows the same timing rule as above.

## Syntax highlighting in the view

The reading view is a detached copy that clangd is **not** attached to, so its
**semantic-token** highlighting (the clangd-driven colors) is not available there.
To keep the view from falling back to bare regex syntax, the plugin starts
**tree-sitter** highlighting on the view buffer explicitly. Install the `c`
parser (`:TSInstall c`) and the view stays richly highlighted.

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
| `clangd is not running`              | clangd not attached — check `:LspInfo`.                          |
| `no symbol named 'x'`                | clangd's index does not cover it — check `compile_commands.json`. |
| View looks washed out                | Install the tree-sitter `c` parser (`:TSInstall c`).             |

## How it works

- **View** — a scratch copy of the source buffer, `nomodifiable`,
  `foldmethod=manual`, with tree-sitter highlighting started explicitly.
- **Resolver** — looks the symbol up by name via clangd `workspace/symbol`, then
  extracts the exact definition with tree-sitter. Name-based lookup is what makes
  nesting possible: inserted text has no real file position to query by.
- **Expander** — splices the body below the call line, tracks it with extmarks,
  and wraps it in a fold.

## Known limitations

- **No clangd semantic highlighting in the view** — tree-sitter is used instead
  (see above).
- **Name-based resolution.** Two `static` functions sharing a name in different
  files may resolve to the wrong one. The exact-name match picks clangd's first
  hit.
- **Macros show their `#define` body**, not a fully flattened expansion — which is
  usually what you want when exploring, since you can keep expanding identifiers
  inside it.
- **Recursion guard is ancestor-only**: a symbol will not expand inside its own
  body, but mutual recursion across siblings is not detected.

## License

MIT
