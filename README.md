# inline-explorer.nvim

Read large C codebases (the Linux kernel, in particular) by **expanding function
and macro definitions inline**, right where they are called — and expanding again
inside what you just expanded. No window-hopping, no floating peek windows.

Expansions happen in a dedicated **read-only copy** of the file, so your real
source is never touched. Each expansion is a real block of text you can move the
cursor into and expand further, and every block is a fold you can collapse when
you want the big picture back.

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
- Recommended: the tree-sitter `c` parser (`nvim-treesitter`) for exact
  definition extraction. Without it a brace-matching fallback is used.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "50n1cd347h9/inline-explorer.nvim",
  opts = {},
}
```

or manually:

```lua
require("inline-explorer").setup()
```

## Usage

Open a C file (with clangd attached), then:

| Keymap        | Command                  | Action                                         |
| ------------- | ------------------------ | ---------------------------------------------- |
| `<leader>eo`  | `:InlineExplorerOpen`    | Open a reading view for the current file       |
| `<leader>ee`  | `:InlineExplorerExpand`  | Expand the symbol under the cursor             |
| `<leader>ec`  | (`za`)                   | Fold / unfold the expansion under the cursor   |
| `<leader>eq`  | `:InlineExplorerClose`   | Close the reading view                         |

Put the cursor on a function call or macro and press `<leader>ee`. Its body is
spliced in below, indented and folded-open. Move into that body and press
`<leader>ee` again to go deeper. `<leader>ec` collapses a subtree; press it again
to reopen — nothing is re-fetched.

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

Set any keymap to `false` to skip it.

## How it works

- **View** — a scratch copy of the source buffer, `nomodifiable`, `foldmethod=manual`.
- **Resolver** — looks the symbol up by name via clangd `workspace/symbol`, then
  extracts the exact definition with tree-sitter. Name-based lookup is what makes
  nesting possible: inserted text has no real file position to query by.
- **Expander** — splices the body below the call line, tracks it with extmarks,
  and wraps it in a fold.

## Known limitations

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
