# inline-explorer.nvim

Read large codebases by **expanding definitions right where they are used**.
Put the cursor on a function call, a type, or a macro, press a key, and its
definition appears in place, below the line you are reading. Move into what
just appeared and expand again, as deep as you like. No window-hopping, no
floating peek windows.

It was built for reading the Linux kernel, but it works with any language
whose language server supports `workspace/symbol` (clangd, ts_ls / vtsls,
pyright, rust-analyzer, gopls, lua_ls, ...).

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

## Features

- **Nested expansion.** Every expansion is real text in the buffer, so you
  can put the cursor inside it and expand again.
- **Your files are never modified.** Expansions happen in a read-only copy
  of the file, the *reading view*.
- **Folds.** Each expansion is a fold: collapse it for the big picture, and
  reopen it without fetching anything again.
- **Undo and redo** for whole expansions inside the view.
- **Inline substitution for C.** Instead of pasting the definition below
  the call, rewrite the call into what the function body does, the way a
  compiler inlines it. Macros are replaced in place by clangd's own
  expansion.
- **Navigation.** Jump to a definition, pick one of the callers of a
  function, and walk back and forth along the views you visited, with
  their expansions intact.

## Requirements

- Neovim 0.10 or later.
- A **language server** attached to the files you read, supporting
  `workspace/symbol`. Definitions are found through its index.
- Recommended: the **tree-sitter parser** for your language
  (`:TSInstall <lang>`). It highlights the reading view and is needed for C
  inline substitution.
- For C, a `compile_commands.json` that clangd can find. For the Linux
  kernel:
  ```sh
  make defconfig
  ./scripts/clang-tools/gen_compile_commands.py
  ```
  For a cross-compiled kernel, see [Buildroot / cross-compiled
  kernels](#buildroot--cross-compiled-kernels).
- Optional: `rg` (ripgrep) or `grep`, used to find callers when the language
  server cannot list them.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "50n1cd347h9/inline-explorer.nvim",
  dependencies = { "neovim/nvim-lspconfig" },
  opts = {}, -- calls setup()
}
```

With any other plugin manager, call `setup()` after the plugin is loaded:

```lua
require("inline-explorer").setup()
```

The default keymaps use `<leader>`, which is read **when `setup()` runs**.
Set it at the very top of your `init.lua`, before your plugin manager loads
anything:

```lua
vim.g.mapleader = " "
```

Then run `:checkhealth inline-explorer` in a file you want to read. It
checks the Neovim version, whether a language server is attached and what
it supports, whether a tree-sitter parser is installed, and (for C) whether
a `compile_commands.json` can be found.

## Quick start

1. Open a source file that has a language server attached.
2. `<leader>eo` opens the **reading view**, a read-only copy of the file.
3. Put the cursor on a function call and press `<leader>ee`. The function's
   definition appears below the line, indented and wrapped in
   `/* v name */ ... /* ^ name */` markers.
4. Move into the definition and press `<leader>ee` on another call to go one
   level deeper.
5. `<leader>ec` folds or unfolds the expansion under the cursor, and `u`
   undoes the last expansion.
6. `<leader>eq` closes the reading view.

Everything is also available as a command, so you can try it with
`:InlineExplorerOpen` and `:InlineExplorerExpand` before you set up any
keymaps.

## Keymaps and commands

| Keymap            | Command                        | Action |
| ----------------- | ------------------------------ | ------ |
| `<leader>eo`      | `:InlineExplorerOpen`          | Open a reading view of the current file |
| `<leader>ee`      | `:InlineExplorerExpand`        | Expand the definition under the cursor below the line (any language) |
| `<leader>ei`      | `:InlineExplorerInline`        | C: inline the function call, or expand the macro, in place (falls back to `<leader>ee`) |
| `<leader>ec`      | (`za`)                         | Fold or unfold the expansion under the cursor |
| `u` / `<C-r>`     |                                | Undo / redo the last expansion |
| `]e` / `[e`       | `:InlineExplorerNext` / `Prev` | Jump to the next / previous expansion |
| `<leader>el`      | `:InlineExplorerList`          | List all expansions in the location list |
| `gd`              |                                | Show the definition under the cursor in its own view |
| `<leader>eu`      | `:InlineExplorerCallers`       | Pick a caller of the function under the cursor and go there |
| `<C-o>` / `<C-i>` | `:InlineExplorerTrail`         | Go back / forward between views; the command lists the trail |
| `<leader>eq`      | `:InlineExplorerClose`         | Close the reading view |
|                   | `:InlineExplorerToggleMode`    | Switch inline substitution between `correct` and `readable` |
|                   | `:InlineExplorerProfile`       | Latency profiling (see [Troubleshooting](#troubleshooting)) |

The `<leader>e` keymaps are global. All the others (`u`, `<C-r>`, `]e`, `[e`,
`gd`, `<C-o>`, `<C-i>`, `<leader>el`, `<leader>eu`) exist only inside a
reading view, so your usual `u`, `gd` and `<C-o>` keep working everywhere
else.

## Using the reading view

Expansions are inserted as plain text, so everything you normally do to
read code works inside them: search, motions, folds, and expanding again.
Folding an expansion hides everything nested in it; unfolding brings it
back exactly as it was.

`u` and `<C-r>` undo and redo whole expansions. They only affect the
reading view; your source file and its undo history are untouched.

A function is never expanded inside its own body, so recursion cannot run
away.

### Breadcrumb in the statusline

`require("inline-explorer").breadcrumb()` returns the chain of expansions
the cursor is inside, such as `do_work > helper`, and an empty string
outside a reading view. For example, with the built-in statusline:

```lua
vim.o.statusline = "%f %{v:lua.require'inline-explorer'.breadcrumb()} %=%l:%c"
```

## Navigating between files

Expanding reads downward in place. Two more moves take you elsewhere:

- `gd` opens the definition under the cursor in its own reading view.
- `<leader>eu` lists the callers of the function under the cursor. Choose
  one and the view switches to that caller.

Each jump remembers the view you left. `<C-o>` and `<C-i>` go back and
forward, and the views you return to still have their expansions, folds and
cursor position. The last 8 views are kept.

The caller list is a small floating window: move with `j`/`k` (or `gg`, `G`,
`/`, counts), choose with `<CR>`, cancel with `<Esc>` or `q`. Each list is
labelled with where it came from:

- `[lsp]`: the language server's call hierarchy. It tells same-named
  functions apart, but can be incomplete while the server is still indexing.
- `[grep]`: a text search, confirmed with tree-sitter. It also finds calls
  hidden inside macros, but cannot tell two `static` functions with the
  same name apart.

When no callers are found you get a message instead of an empty list,
because "no callers" and "the index is not ready yet" look the same.

## Inline substitution (C)

`<leader>ei` does more than paste the definition. It **rewrites the call
into what the function body does**, the way a compiler inlines it, so the
surrounding statement reads on its own. It needs the tree-sitter `c`
parser.

Given `return snap != acquire(c);`, inlining `acquire` produces:

```c
int cpu = (c);
struct ct *p = per_cpu_ptr(CT, cpu);
return snap != (p->state & MASK);
```

- **Parameters** become local variables of their declared type
  (`int cpu = (c);`).
- **Simple functions** (straight-line code ending in one `return`) are
  inlined as above: the setup lines go above the statement, and the
  returned expression replaces the call, in parentheses.
- **Anything else** (early returns, loops, labels) becomes a GNU C
  statement expression `({ ... })`, with each `return` turned into a jump to
  its end.
- **Name clashes** with the caller's variables, and the callee's labels, get
  a `__ieN` suffix, so inlining the same function twice stays correct.

If the call cannot be inlined (a variadic function, for example), the
definition is expanded below the line as with `<leader>ee` instead.

### `correct` and `readable`

The `mode` option chooses the output style. Switch at any time with
`:InlineExplorerToggleMode`.

- **`correct`** (default): the result always compiles and behaves like the
  original. Complex functions become statement expressions with `goto`.
- **`readable`**: never uses `({ ... })` or `goto` and lays the body out top
  to bottom. Nicer to read, but functions with early returns, labels or
  short-circuit conditions may **no longer compile or behave the same**.
  One case still uses a statement expression in this mode: a call inside a
  declaration that cannot be moved to its own lines, because moving it
  would change what the declared name refers to.

```lua
require("inline-explorer").setup({ mode = "readable" })
```

The engine is tested by inlining every eligible call in real projects
([cJSON](https://github.com/DaveGamble/cJSON) and
[zlib](https://github.com/madler/zlib)) and rebuilding and running each
project's own test suite. See [docs/development.md](docs/development.md).

## Macros

Macros have no body to transform, so the two keys do different things:

- **`<leader>ei`** replaces the macro use in place with its expansion, as
  computed by **your running clangd**. It respects your include paths,
  `#define`s and `#ifdef` state. A macro inside an expanded block has no
  position in the real file, so there it falls back to `<leader>ee`.
- **`<leader>ee`** shows the macro's `#define` below the use, like any other
  definition. That is often what you want while exploring, because you can
  keep expanding the names inside it.

Neither one edits your file. (clangd delivers its expansion as an edit,
which the plugin intercepts. The one theoretical exception is a reply that
arrives more than about 5 seconds late, which would reach Neovim's default
handler instead.)

## Configuration

These are the defaults. Pass only what you want to change.

```lua
require("inline-explorer").setup({
  keymaps = {
    substitute = "<leader>ei",  -- inline in place (C), else expand below
    expand = "<leader>ee",      -- expand the definition below the line
    toggle_fold = "<leader>ec", -- fold / unfold the expansion under the cursor
    open = "<leader>eo",        -- open a reading view
    close = "<leader>eq",       -- close the reading view
    undo = "u",                 -- undo the last expansion
    redo = "<C-r>",             -- redo
    next_block = "]e",          -- next expansion
    prev_block = "[e",          -- previous expansion
    list_blocks = "<leader>el", -- expansions in the location list
    callers = "<leader>eu",     -- pick a caller
    goto_def = "gd",            -- open the definition in its own view
    trail_back = "<C-o>",       -- back to the previous view
    trail_forward = "<C-i>",    -- forward again
  },
  indent = "  ",    -- added in front of each expansion level
  header = true,    -- wrap expansions in /* v name */ ... /* ^ name */
  mode = "correct", -- inline substitution style: "correct" or "readable"
  profile = false,  -- record latency from the start (:InlineExplorerProfile)
})
```

Set a keymap to `false` to leave it unmapped. Unknown option names produce a
warning, so typos do not go unnoticed.

If you prefer keymaps that do not depend on `<leader>`, disable the ones
you want to replace and map the commands yourself:

```lua
vim.keymap.set("n", "<space>eo", "<cmd>InlineExplorerOpen<cr>")
vim.keymap.set("n", "<space>ee", "<cmd>InlineExplorerExpand<cr>")
vim.keymap.set("n", "<space>ei", "<cmd>InlineExplorerInline<cr>")
```

## Buildroot / cross-compiled kernels

The plugin works the same; the work is making clangd understand the cross
build.

1. **Generate `compile_commands.json`** in the kernel's build tree after
   building:
   ```sh
   cd output/build/linux-<version>
   ./scripts/clang-tools/gen_compile_commands.py
   ```
2. **Let clangd use the cross toolchain.** The compile commands name
   Buildroot's cross gcc, so clangd needs `--query-driver` to ask it for its
   built-in include paths; otherwise you get missing-header errors:
   ```lua
   require("lspconfig").clangd.setup({
     cmd = { "clangd", "--query-driver=/abs/path/to/output/host/bin/*", "--background-index" },
   })
   ```
3. **Other C packages** (`output/build/<pkg>-<ver>/`): CMake packages write
   `compile_commands.json` with `CMAKE_EXPORT_COMPILE_COMMANDS=ON`; for
   autotools or plain Makefile packages, build with
   [`bear`](https://github.com/rizsotto/Bear): `bear -- make`.

## Troubleshooting

Start with `:checkhealth inline-explorer`.

| Symptom | Cause and fix |
| ------- | ------------- |
| `<leader>ee` does nothing, but the commands work | `mapleader` was set after the plugin loaded, or misspelled. Set `vim.g.mapleader` at the top of `init.lua` and restart; `:lua print(vim.inspect(vim.g.mapleader))` shows the current value. |
| `open a reading view first` | Run `:InlineExplorerOpen` (`<leader>eo`) first. |
| `no language server attached to the source buffer` | No server is attached to the file. Check `:checkhealth lsp`. |
| `no symbol named 'x'` | The server's index does not know the name. For C, make sure clangd finds a `compile_commands.json` that covers the file. |
| `no answer within ...; extracted locally` | The server was slow, usually opening a large header for the first time. The definition was found locally; the next look uses the server. |
| The view has no colors | Install the tree-sitter parser for the language (`:TSInstall <lang>`). |
| An expansion shows the wrong function | Several definitions share the name (for example `static` functions in different files). See [Known limitations](#known-limitations). |

### Expansions feel slow

The plugin can measure where the time goes:

```vim
:InlineExplorerProfile on     " start recording
" ... expand a few things ...
:InlineExplorerProfile        " show the report
:InlineExplorerProfile open   " open the full log in a tab (also: off, clear, path)
```

The log is written to `stdpath("log")/inline-explorer-profile.log`. Each
line names the symbol and file it was about, which makes it easy to spot
the one slow header. Lines starting with `extract:cold` are the language
server opening a file for the first time, which is usually the expensive
part. [docs/development.md](docs/development.md#measuring-latency) explains
every label. Please include this log when you report a performance problem.

## Known limitations

- **Names, not positions.** Definitions are looked up by name, which is what
  allows expanding inside expansions (that text has no position in a real
  file). When several definitions share a name, such as `static` functions in
  different files, the server's first exact match is used and may be the
  wrong one.
- **Only what the server knows.** A definition is found only if the
  language server's index contains it.
- **No semantic highlighting in the view.** No language server is attached
  to the copy, so tree-sitter highlighting is used instead. Once a body is
  expanded mid-file the buffer is no longer valid code as a whole, and
  deeply nested regions may be colored imperfectly.
- **Recursion guard.** A function is not expanded inside its own body, but
  mutual recursion (`a` calls `b` calls `a`) is not detected.
- **Inline substitution** is C only. It cannot inline variadic functions or
  macros (macros are expanded instead). It rewrites the whole view, so
  expansions whose lines change are dropped. In `correct` mode some calls
  are still rejected or produce code that does not build, for example a
  function that uses a helper defined later in the same file, or one that
  takes a `va_list`.

## Contributing

How the plugin works, how it is tested, and how to run the tests are in
[docs/development.md](docs/development.md). The design is described in
[DESIGN.md](DESIGN.md).

## License

MIT
