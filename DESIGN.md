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
depth N. Once resolved, the server's `textDocument/documentSymbol` supplies the
definition's full range; tree-sitter extraction only takes over as a fallback
when the server doesn't provide a usable range.

## Components

- **View** (`view.lua`) — open/close the copy buffer, track per-view expansion
  nodes (extmarks).
- **Resolver** (`resolver.lua`) — `name -> definition location` via the attached
  server's `workspace/symbol` (any language), then `location -> body lines` via
  the server's `textDocument/documentSymbol` full range (tree-sitter, then a
  brace heuristic, as fallbacks when no server range is available).
- **Expander** (`expander.lua`) — splice the body below the call line, indent,
  wrap in a fold, guard against self-recursion.
- **Config / init** — options, user commands, keymaps.

## Inline substitution (C-only)

A second, stronger mode (`substitute.lua` + `inliner.lua`): instead of pasting the
definition below the call, rewrite the call into the effect of the body — true
compiler-style inlining — so the surrounding statement reads on its own.

Decisions (from brainstorming): C-only, `goto` allowed, no fallback to
block-paste, rigour level X (compile-correct).

Since the 2026-07 restructuring the engine is a pipeline: `analyze_callee`
resolves the callee into a small IR, `analyze_context` resolves the call
site, and a single `decide()` picks one of three layout-only printers
(pretty hoist / canonical statement expression / readable-multi). The
canonical form is the semantic baseline — legal in any expression context —
and prettier output is only chosen when the analysis proves it safe.

Mechanism:

- Parameters bind by reconstructing each parameter's declared type (arrays
  decay to pointers), so a NULL/`0` argument keeps the right pointer type;
  `__auto_type` is a fallback for exotic declarators (e.g. function pointers).
  This preserves call-by-value.
- Straight-line single-return functions render as a *pretty hoist* (setup lifted
  above the call statement, return expression spliced in, parenthesised).
- Everything else renders as a GNU statement expression `({ ... })` with each
  `return E;` rewritten to `{ __ie_retN = E; goto __ie_endN; }` and the
  reconstructed declared return type as `__ie_retN`'s value slot. This makes
  *any* function inlinable as an expression, so there is no block-paste fallback.
- Callee labels (function-scoped) and hoisted locals that collide with the caller
  scope are suffixed `name__ieN`, keyed by a per-expansion id N, so repeated and
  nested inlining stays correct.
- Truly non-inlinable cases (variadic, macros) report an error rather than
  producing wrong code.

Output modes (`mode` option, toggle with `:InlineExplorerToggleMode`):

- **correct** (default) — guaranteed to compile. Hoisting only when the call is
  reached unconditionally in a plain statement; block-wrap after case/goto labels
  (a declaration cannot follow a bare label); GNU statement expression + `goto`
  for everything else. Parameter bindings reconstruct the declared parameter type
  (arrays decay to pointers) so NULL/`0` arguments keep the right pointer type;
  the result slot uses the reconstructed return type.
- **readable** — never emits `({...})`/`goto`; hoists the body with `return`→
  assignment. Cleaner, but not guaranteed to compile or preserve semantics for
  early-return / labelled / short-circuit code.

Guarantee: `tests/substitute_spec.lua` (shaped cases) and
`tests/real_cjson_spec.lua` (every in-file static call in real cJSON) have gcc
compile and run each correct-mode transform against the originals' semantics.
These real-source tests drove out several bugs: `__typeof__` of the return
expression referencing body locals, `__typeof__`/`__auto_type` mistyping NULL
pointer arguments, missed collisions on array/pointer declarations, and hoisting
across a `switch` `case` label.

## Macro expansion (C-only)

Macros have no type and no guaranteed statement/expression structure, so the
substitution engine cannot handle them — a faithful expansion means running the
preprocessor. `macro.lua` therefore delegates to the live clangd, preferring its
`ExpandMacro` tweak: the tweak is discovered via `textDocument/codeAction`,
executed via `workspace/executeCommand`, and the `workspace/applyEdit` it sends
back is intercepted — kept out of the real file (a reply straggling past the
timeout + grace window, ~5 s, is the one exception) — with its `newText` taken
as the expansion. When the tweak is unavailable (older clangd, no action at the
position, errors, timeout) the fallback scrapes `textDocument/hover` markdown
(clangd puts `#define` and the expansion in one code block separated by an
"Expands to" marker; we take the part after it).

The smart `ei` action splices that expansion **in place** of the macro use (the
same fetch→replace path as functions, with the fetch preferring the tweak and
falling back to hover only if it's unavailable); explicit `ee` block-pastes the
macro definition instead. There is no separate macro command. The query
(codeAction or hover) runs against the original source at the cursor, exact at
depth 0; large line shifts can misalign it. The `ExpandMacro` tweak path
implements exactly the interception that an earlier revision of this document
described as a future step.
