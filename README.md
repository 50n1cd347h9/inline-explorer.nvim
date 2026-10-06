# inline-explorer.nvim

Read large codebases by **expanding definitions where they are used**. Press
a key on a function call, type or macro and its definition appears below
the line; move into it and expand again, as deep as you like. No
window-hopping, and your files are never modified.

Built for the Linux kernel, but works with any language server that
supports `workspace/symbol` (clangd, ts_ls, pyright, rust-analyzer, gopls,
lua_ls, ...).

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
- A language server attached to the files you read
- Recommended: the tree-sitter parser for the language (`:TSInstall <lang>`);
  required for C inline substitution
- For C, a `compile_commands.json` clangd can find. For the kernel:
  `make defconfig && ./scripts/clang-tools/gen_compile_commands.py`

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "50n1cd347h9/inline-explorer.nvim", opts = {} }
```

Otherwise call `require("inline-explorer").setup()`. Set `vim.g.mapleader`
**before** `setup()` runs, since the keymaps use `<leader>`. Then run
`:checkhealth inline-explorer` in a file you want to read.

## Usage

1. `<leader>eo` opens the **reading view**, a read-only copy of the file.
2. On a function call, `<leader>ee` expands its definition below the line.
3. Move into the definition and expand again to go deeper.

| Keymap            | Command                        | Action |
| ----------------- | ------------------------------ | ------ |
| `<leader>eo`      | `:InlineExplorerOpen`          | Open a reading view |
| `<leader>ee`      | `:InlineExplorerExpand`        | Expand the definition below the line |
| `<leader>ei`      | `:InlineExplorerInline`        | C: inline the call or expand the macro in place |
| `<leader>ec`      | (`za`)                         | Fold / unfold the expansion |
| `u` / `<C-r>`     |                                | Undo / redo |
| `]e` / `[e`       | `:InlineExplorerNext` / `Prev` | Next / previous expansion |
| `<leader>el`      | `:InlineExplorerList`          | List expansions in the location list |
| `gd`              |                                | Open the definition in its own view |
| `<leader>eu`      | `:InlineExplorerCallers`       | Pick a caller and go there |
| `<C-o>` / `<C-i>` |                                | Back / forward between views |
|                   | `:InlineExplorerTrail`         | List the visited views |
| `<leader>eq`      | `:InlineExplorerClose`         | Close the reading view |
|                   | `:InlineExplorerToggleMode`    | Switch inline mode (`correct` / `readable`) |
|                   | `:InlineExplorerProfile`       | Latency profiling |

`<leader>eo`, `ee`, `ei`, `ec` and `eq` are global; the other maps exist
only inside a reading view. Undo there never touches your file's own undo
history.

For the statusline, `require("inline-explorer").breadcrumb()` returns the
expansions around the cursor (`do_work > helper`):

```lua
vim.o.statusline = "%f %{v:lua.require'inline-explorer'.breadcrumb()} %=%l:%c"
```

### Navigating

The last 8 views you visited keep their expansions as you move with
`<C-o>` / `<C-i>`. Callers come from the language
server (`[lsp]`) or, if it cannot list them, from `rg`/`grep` confirmed by
tree-sitter (`[grep]`, which cannot tell same-named `static` functions
apart).

## Inline substitution (C)

`<leader>ei` **rewrites the call into what the function body does**, as a
compiler would. Given `return snap != acquire(c);`:

```c
int cpu = (c);
struct ct *p = per_cpu_ptr(CT, cpu);
return snap != (p->state & MASK);
```

Calls that cannot be inlined (variadic functions) fall back to
`<leader>ee`.

The `mode` option sets the style:

- **`correct`** (default): always compiles and behaves like the original.
- **`readable`**: avoids `({ ... })` and `goto`, but functions with early
  returns or labels may no longer compile or behave the same.

## Macros

`<leader>ei` replaces a macro use with the expansion **your running clangd**
computes, so include paths and `#ifdef` state apply. Inside an expanded
block it falls back to `<leader>ee`, which shows the `#define` below the
use.

## Configuration

Defaults; pass only what you change. Set a keymap to `false` to disable it.

```lua
require("inline-explorer").setup({
  keymaps = {
    substitute = "<leader>ei",
    expand = "<leader>ee",
    toggle_fold = "<leader>ec",
    open = "<leader>eo",
    close = "<leader>eq",
    undo = "u",
    redo = "<C-r>",
    next_block = "]e",
    prev_block = "[e",
    list_blocks = "<leader>el",
    callers = "<leader>eu",
    goto_def = "gd",
    trail_back = "<C-o>",
    trail_forward = "<C-i>",
  },
  indent = "  ",    -- indent per expansion level
  header = true,    -- wrap expansions in /* v name */ ... /* ^ name */
  mode = "correct", -- inline style: "correct" or "readable"
  profile = false,  -- record latency from startup
})
```

## Cross-compiled kernels (Buildroot)

1. Generate `compile_commands.json` in `output/build/linux-<version>` with
   `./scripts/clang-tools/gen_compile_commands.py`.
2. Let clangd query the cross compiler for its include paths:
   ```lua
   require("lspconfig").clangd.setup({
     cmd = { "clangd", "--query-driver=/abs/path/to/output/host/bin/*", "--background-index" },
   })
   ```
3. For other packages, use `CMAKE_EXPORT_COMPILE_COMMANDS=ON` or
   [`bear`](https://github.com/rizsotto/Bear) `-- make`.

## Troubleshooting

Start with `:checkhealth inline-explorer`.

| Symptom | Fix |
| ------- | --- |
| Keymaps do nothing, commands work | Set `vim.g.mapleader` before `setup()` runs |
| `no language server attached ...` | Check `:checkhealth lsp` |
| `no symbol named 'x'` | The server's index lacks it; for C, check `compile_commands.json` |
| `no answer within ...; extracted locally` | The server was slow on the definition's file; looking again uses it |

If expansions feel slow, `:InlineExplorerProfile on`, expand a few things,
then `:InlineExplorerProfile` for a report (`open` shows the full log).
Please attach the log to performance reports.

## Known limitations

- Definitions are looked up **by name**, so with several same-named
  definitions (e.g. `static` functions in different files) the first match
  may be the wrong one.
- No semantic highlighting in the view; tree-sitter is used instead.
- Mutual recursion (`a` → `b` → `a`) is not detected; direct recursion is.
- Inline substitution is C only. Inlining on the first or last line of an
  expansion stops it being tracked as a block (no fold, `]e` or
  breadcrumb). Some calls are still rejected or do not compile, e.g.
  a callee using a helper defined later in the file, or a `va_list`
  parameter.

## Contributing

See [docs/development.md](docs/development.md) and [DESIGN.md](DESIGN.md).

## License

MIT
