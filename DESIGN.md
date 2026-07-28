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

clangd is not attached to the copy buffer, and nested expansions sit on inserted
text that has no position in any real file. So the symbol under the cursor is
resolved by **name** (`workspace/symbol`), which works identically at depth 0 and
depth N. tree-sitter then extracts the exact definition node from the target file.

## Components

- **View** (`view.lua`) — open/close the copy buffer, track per-view expansion
  nodes (extmarks).
- **Resolver** (`resolver.lua`) — `name -> definition location` via clangd, then
  `location -> body lines` via tree-sitter (brace/continuation heuristic fallback).
- **Expander** (`expander.lua`) — splice the body below the call line, indent,
  wrap in a fold, guard against self-recursion.
- **Config / init** — options, user commands, keymaps.
