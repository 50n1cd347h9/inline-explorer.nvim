# Design

The approved design from brainstorming.

## Goal

Read Linux kernel C source by expanding function/macro bodies inline at their
call sites, and expanding again inside those bodies (arbitrary depth), without
leaving the file or using floating windows.

## Decisions

1. **Deep, nested expansion** — expand within an expansion, not just one level.
2. **Dedicated read-only view** — expansions happen in a copy buffer; the real
   source file is never modified.
3. **View seeds from a full copy** of the current file, so surrounding context is
   preserved ("the same file, but explorable").
4. **Fold-based collapse** — collapsing hides an expansion via a fold and keeps
   it; reopening re-shows it with no re-fetch.

## Why real text, not virtual lines

`virt_lines` extmarks cannot host the cursor, so you cannot expand something
*inside* a virtual expansion. Nested expansion requires the inserted body to be
real, cursor-navigable buffer text. The copy buffer makes that safe.

## Why name-based resolution

No server is attached to the copy buffer, and nested expansions sit on inserted
text that has no position in any real file. So the symbol under the cursor is
resolved by **name** (`workspace/symbol`), which works identically at depth 0 and
depth N. Once resolved, the definition's lines come from tree-sitter first for
C/C++ (it finds the same range without waiting for the server to build the
file's preamble), and from the server's `textDocument/documentSymbol` range
first for other languages; each falls back to the other, then to a brace
heuristic.

## Components

- **View** (`view.lua`) — open/close the copy buffer, track per-view expansion
  blocks (extmarks), map source rows to view rows, undo and redo. It requires
  nothing above it: it fires `User InlineExplorerViewOpen` when a view opens.
- **LSP plumbing** (`lsp.lua`) — load a file and attach a client to it for a
  request, and put it back as it was once unused; pick the server for a
  location and the position to send. A view pins its source buffer here.
- **Resolver** (`resolver.lua`) — `name -> definition location` via the attached
  server's `workspace/symbol` (any language), then `location -> body lines`:
  tree-sitter first for C/C++, the server's `textDocument/documentSymbol` range
  first for other languages, a brace heuristic last. It only looks up: what to
  tell the user is its callers' call.
- **Expander** (`expander.lua`) — splice the body below the call's statement, indent,
  wrap in a fold, guard against self-recursion.
- **Navigation** (`nav.lua`, `pick.lua`, `trail.lua`, `select.lua`) — move
  between blocks, jump to a definition or a caller, the trail of views those
  jumps leave, and the picker.
- **Config / init / keymaps** — options, user commands, the global keymaps and
  those a view gets when it opens.

## Inline substitution (C-only)

A second, stronger mode (`substitute.lua` + `inliner.lua`; the engine is
`canalyze.lua`, which makes every judgement, `cprint.lua`, which writes the C,
and `csrc.lua`, the tree-sitter helpers): instead of pasting the
definition below the call, rewrite the call into the effect of the body — true
compiler-style inlining — so the surrounding statement reads on its own.

Decisions (from brainstorming): C-only, `goto` allowed, block-paste only for
calls the analysis rejects, rigour level X (compile-correct).

Since the 2026-07 restructuring the engine is a pipeline: `analyze_callee`
resolves the callee into a small IR, `analyze_context` resolves the call
site, and a single `decide()` picks one of three layout-only printers
(pretty hoist / canonical statement expression / readable-multi). The
canonical form is the semantic baseline — legal in any expression context —
and prettier output is only chosen when the analysis proves it safe.

Mechanism:

- Parameters bind as the callee declares them, with an array or function
  declarator next to the name adjusted to a pointer as C adjusts parameters
  (`int m[][4]` binds as `int (*m)[4]`), so a NULL/`0` argument keeps the
  right pointer type and inner qualifiers survive; `__auto_type` is the
  fallback for an unnamed parameter. This preserves call-by-value.
- A callee whose only `return` is its last statement and carries a value
  renders as a *pretty hoist* (setup lifted above the call statement, return
  expression spliced in, parenthesised) when the call runs unconditionally;
  readable mode uses it either way. A declaration that lines cannot be inserted
  above gets the canonical form in both modes, since wrapping it in a block
  would end its scope early, and so does a statement that does not parse
  cleanly, since a macro in it may hide an `if`.
- Everything else renders as a GNU statement expression `({ ... })` with each
  `return E;` rewritten to `{ __ie_retN = E; goto __ie_endN; }`, and
  `__ie_retN` declared as the value slot with the callee's own declarator
  around it (`char (*__ie_ret1)` for `char (*f(void))`). This makes *any*
  function inlinable as an expression.
- Callee labels (function-scoped) are suffixed `name__ieN`, keyed by a
  per-expansion id N, and so are its parameters and top-level locals
  (typedefs and enumerators included) whose name appears anywhere in the
  caller's function, so repeated and nested inlining stays correct. A rename
  takes along only the uses the callee's own declarations bind: a read of a
  global ahead of a local of the same name keeps the global's name.
- Calls the analysis rejects (variadic functions, a callee that reads a name
  the caller's function declares too, which a rename cannot keep apart, a
  callee with an `#include` in its body or a `return` that does not parse as
  one, a call that does not parse cleanly) are not rewritten: the inliner
  falls back to block-paste (`<leader>ee`) rather than produce wrong code.
  Macros are expanded through clangd instead.

Output modes (`mode` option, toggle with `:InlineExplorerToggleMode`):

- **correct** (default) — guaranteed to compile. Hoisting only when the call is
  reached unconditionally in a plain statement, outside any operand that is
  never evaluated (`sizeof`, `_Generic`, `typeof`, `__builtin_constant_p`, ...)
  and with nothing in the statement sequenced before it (a comma's left side,
  an earlier declarator), in a statement that parses cleanly; block-wrap
  after case/goto labels (a declaration cannot follow a bare label); GNU
  statement expression + `goto` for everything else. Parameter bindings and
  the result slot keep the callee's declared types (see Mechanism).
- **readable** — hoists the body with `return`→ assignment and avoids
  `({...})`/`goto`, except where only they keep the meaning: a declaration
  that cannot be wrapped in a block, and a statement that does not parse
  cleanly, get the correct-mode form. Cleaner, but not guaranteed to compile
  or preserve semantics for early-return / labelled / short-circuit code.

Guarantee: `tests/substitute_spec.lua` (shaped cases) and
`tests/real_cjson_spec.lua` (every in-file static call in real cJSON) have gcc
compile and run each correct-mode transform against the originals' semantics.
These real-source tests drove out several bugs: `__typeof__` of the return
expression referencing body locals, `__typeof__`/`__auto_type` mistyping NULL
pointer arguments, missed collisions on array/pointer declarations, and hoisting
across a `switch` `case` label.

On top of the shaped and real-source suites, `tests/properties_spec.lua` and
`tests/pbt_spec.lua` run property-based tests over a deterministic random
generator (`tests/lib/gen.lua`): tree-sitter invariants (clean re-parse, call
count, unique injected names, safe rejection) on ~300 cases per run, and a gcc
differential that requires byte-identical stdout before and after substitution,
including canonical-vs-pretty agreement whenever the analysis picked the pretty
form. Counterexamples shrink greedily and reproduce from a printed seed.

## Macro expansion (C-only)

Macros have no type and no guaranteed statement/expression structure, so the
substitution engine cannot handle them — a faithful expansion means running the
preprocessor. `macro.lua` therefore delegates to the live clangd (reading its
replies with `macro_reply.lua`; `substitute.replace_macro_use` splices the
result), preferring its
`ExpandMacro` tweak: the tweak is discovered via `textDocument/codeAction`,
executed via `workspace/executeCommand`, and the `workspace/applyEdit` it sends
back is intercepted — kept out of the real file (a reply straggling past the
timeout + grace window, ~5 s, is the one exception) — with the `newText` of its
edit at the macro use taken as the expansion (clangd formats the result, so the
other edits only change whitespace). When the tweak finds no action at the
position, errors or times out, the fallback scrapes the same server's
`textDocument/hover` markdown (clangd puts `#define` and the expansion in one
code block separated by an "Expands to" marker; we take the part after it).
Both go only to the server that offers the tweak, whatever its name.

The smart `ei` action splices that expansion **in place** of the macro use (the
same fetch→replace path as functions, with the fetch preferring the tweak and
falling back to hover only if it's unavailable); explicit `ee` block-pastes the
macro definition instead. There is no separate macro command. The query
(codeAction or hover) runs against the original source: every source line
carries an extmark naming its row (Neovim moves it with splices, invalidates
it when a rewrite replaces the line, and restores it on undo), so the cursor
position is translated to the exact file line however far prior expansions
have shifted things; a macro use on inserted text has no origin and falls back
to block expansion. The `ExpandMacro` tweak path implements exactly the
interception that an earlier revision of this document described as a future
step.
