# Navigation Layer (callers, definition jump, history) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add upward navigation (callers picker), definition jump, and a back/forward history stack to the reading view, per `docs/superpowers/specs/2026-07-30-navigation-layer-design.md`.

**Architecture:** One new primitive, `trail.goto_location(loc)`, switches the window to a reading view for the target file while pushing the current view onto a bidirectional stack. Views stay alive (`bufhidden=hide`) while stacked, so going back restores expansions exactly — nothing is snapshotted or restored, it simply is not destroyed. Callers come from LSP `callHierarchy` with a labelled grep+tree-sitter fallback; definition jump reuses `resolver.locate` unchanged.

**Tech Stack:** Lua (Neovim 0.10+), tree-sitter c parser, LSP callHierarchy, `rg`/`grep`, `vim.ui.select`. No new dependencies.

## Global Constraints

- Neovim 0.10+; run every spec headless: `nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/<spec>.lua" -c "qa!"` (nvim is NOT on PATH in this sandbox: use `/tmp/claude-1001/-home-claude/8eec540c-6e2a-4002-b843-1a0deff3457d/scratchpad/nvim-linux-x86_64/bin/nvim`)
- Do NOT modify `lua/inline-explorer/nav.lua` (existing block navigation), `resolver.lua`, or `expander.lua`. `view.lua` gets exactly the two changes named in Task 1 and Task 3.
- Tests assert COUNTS and STATES, never elapsed time (project measurement discipline).
- Every code comment must be true of the code as shipped — this branch has had nine comment-overclaim review findings; scope every claim to what you verified.
- Existing suites must stay green: resolver, expander, substitute, macro, ir, gen, properties, pbt, bench_lib, real_source_lib, bench (needs clangd on PATH), real_kernel (needs IE_KERNEL_DIR).
- Commits: repo-local git config already attributes to claude; do not touch it. No user email anywhere.
- git worktree 経由での隔離実行を推奨（superpowers:using-git-worktrees）。

---

### Task 1: trail.lua — the stack and goto_location

**Files:**
- Create: `lua/inline-explorer/trail.lua`
- Modify: `lua/inline-explorer/view.lua` — `M.open()` gains an optional `src` bufnr parameter (guarded, see below)
- Test: `tests/trail_spec.lua`

**Interfaces:**
- Consumes: `view.open(src?) -> view_bufnr` (after this task's modification), `view.state` (map view_bufnr -> { source_bufnr, ... })
- Produces (later tasks rely on these exact names):
  - `trail.goto_location(loc)` — loc = `{ uri, range = { start = { line, character }, ["end"] = ... } }`; switches to (or creates) the reading view for `loc.uri`, cursor at `range.start`; pushes the previous view.
  - `trail.back()` / `trail.forward()` — return `true` on movement, `false` (plus a notify) at the ends.
  - `trail.list()` — populates the location list with the stack.
  - `trail.clear()` — wipes all stacked views; called by `view.close` in Task 3.
  - `trail._stack_n` (default 8), `trail._stack`, `trail._pos` — module fields, tests may read/shrink them.

- [ ] **Step 1: Write the failing test**

Create `tests/trail_spec.lua`:

```lua
-- Trail: the navigation stack behind callers/definition jumps.
-- Counts and states only -- no timing assertions.
--   nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/trail_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))

local trail = require("inline-explorer.trail")
local view = require("inline-explorer.view")

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and ("  " .. tostring(d)) or ""))
  end
end

-- Three tiny real files to travel between.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local paths = {}
for i = 1, 3 do
  paths[i] = ("%s/f%d.c"):format(dir, i)
  local f = assert(io.open(paths[i], "w"))
  f:write(("int f%d(void)\n{\n    return %d;\n}\n"):format(i, i))
  f:close()
end
local function loc_of(i)
  return { uri = vim.uri_from_fname(paths[i]),
    range = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 6 } } }
end

-- Start inside a view of f1 (trail is a view-world feature).
vim.cmd.edit(paths[1])
local v1 = view.open()
check("setup: view.open returns the view bufnr", type(v1) == "number" and view.state[v1] ~= nil)

-- goto_location pushes and switches.
trail.goto_location(loc_of(2))
local v2 = vim.api.nvim_get_current_buf()
check("goto: lands in a DIFFERENT view buffer", v2 ~= v1 and view.state[v2] ~= nil, v2)
check("goto: cursor at the target range", vim.api.nvim_win_get_cursor(0)[1] == 1)
check("goto: previous view still alive (bufhidden=hide while stacked)",
  vim.api.nvim_buf_is_valid(v1) and vim.bo[v1].bufhidden == "hide", vim.bo[v1].bufhidden)

-- back restores the SAME buffer -- identity, not a recreation.
check("back: returns true when there is history", trail.back() == true)
check("back: the very same buffer is shown again", vim.api.nvim_get_current_buf() == v1)
check("back at the bottom: returns false, stays put",
  trail.back() == false and vim.api.nvim_get_current_buf() == v1)

-- forward re-enters v2; a NEW navigation from a back-state drops forward history.
check("forward: returns true", trail.forward() == true)
check("forward: lands back in v2", vim.api.nvim_get_current_buf() == v2)
trail.back()
trail.goto_location(loc_of(3))
check("new navigation from a back-state: forward history is dropped",
  trail.forward() == false)

-- Reuse: navigating to a file whose view exists reuses THE BUFFER.
local v3 = vim.api.nvim_get_current_buf()
trail.goto_location(loc_of(2))
check("reuse: an existing view buffer is reused, not recreated",
  vim.api.nvim_get_current_buf() == v2)

-- Eviction: shrink the cap and overflow it; evicted buffers are wiped.
trail.clear()
check("clear: stack empty and stacked views wiped",
  #trail._stack == 0 and not vim.api.nvim_buf_is_valid(v1), tostring(vim.api.nvim_buf_is_valid(v1)))

local saved_n = trail._stack_n
trail._stack_n = 2
vim.cmd.edit(paths[1])
local a = view.open()
trail.goto_location(loc_of(2))
local b = vim.api.nvim_get_current_buf()
trail.goto_location(loc_of(3))
trail.goto_location(loc_of(1)) -- pushes b's entry beyond the cap? no: pushes v3's; a's entry evicted
check("eviction: depth never exceeds the cap", #trail._stack <= 2, #trail._stack)
check("eviction: the oldest stacked view was wiped",
  not vim.api.nvim_buf_is_valid(a), tostring(vim.api.nvim_buf_is_valid(a)))
check("eviction: newer stacked views survive", vim.api.nvim_buf_is_valid(b))
trail._stack_n = saved_n
trail.clear()

print("")
print(fails == 0 and "ALL TRAIL TESTS PASSED" or (fails .. " FAILURE(S)"))
if fails > 0 then vim.cmd("cq") end
vim.cmd("qa!")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/trail_spec.lua" -c "qa!"`
Expected: `E5113 ... module 'inline-explorer.trail' not found`

- [ ] **Step 3: Modify view.open to accept an optional src**

In `lua/inline-explorer/view.lua`, change the head of `M.open`:

```lua
-- Open a reading view and switch to it. `src` selects the source buffer;
-- omitted, the current buffer is used. The guard is not decoration: user
-- commands (InlineExplorerOpen) call this with the command-opts TABLE as
-- the first argument, so anything that is not a buffer number must mean
-- "current buffer".
function M.open(src)
  if type(src) ~= "number" then
    src = vim.api.nvim_get_current_buf()
  end
```

and delete the old `local src = vim.api.nvim_get_current_buf()` line. Everything below is unchanged; `M.open` already ends in `return view`.

Note: when `src` is not the current buffer, the `cursor` captured from the current window is not meaningful for the new view — that is fine; `trail.goto_location` sets the cursor after switching. Do not try to fix it inside `view.open`.

- [ ] **Step 4: Write trail.lua**

Create `lua/inline-explorer/trail.lua`:

```lua
-- Trail: the navigation stack behind callers and definition jumps.
--
-- One primitive -- goto_location -- switches the window to a reading view
-- for a target file and pushes the view it left. Views stay alive
-- (bufhidden=hide) while they are on the stack, so going back shows the
-- same buffer with its expansions, folds and undo history intact: nothing
-- is snapshotted, it simply is not destroyed. Views fall out of the stack
-- (depth cap, or clear()) before they are wiped.
--
-- Named trail because nav.lua already exists (block navigation inside one
-- view); this module never touches it.
local view = require("inline-explorer.view")

local M = {}

-- Entries are { buf = view_bufnr, cursor = { row, col } }. _pos is the
-- index of the entry the window currently shows; entries above _pos are
-- forward history. Capacity is a module field so tests can shrink it.
M._stack = {}
M._pos = 0
M._stack_n = 8

local function wipe(buf)
  if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
    view.state[buf] = nil
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

-- Drop everything and wipe every stacked view that is not on screen.
function M.clear()
  for _, e in ipairs(M._stack) do
    wipe(e.buf)
  end
  local cur = vim.api.nvim_get_current_buf()
  M._stack, M._pos = {}, 0
  -- The view being looked at survives clear(); closing it is view.close's
  -- job, not the trail's.
  if view.state[cur] then
    vim.bo[cur].bufhidden = "wipe"
  end
end

-- The view buffer for a source file, if one already exists. Reuse is by
-- BUFFER: the same view (with its expansions) is shown again. It is not a
-- rewind -- the stack may hold the same buffer at several positions.
local function view_of(source_buf)
  for v, st in pairs(view.state) do
    if st.source_bufnr == source_buf and vim.api.nvim_buf_is_valid(v) then
      return v
    end
  end
end

local function push_current()
  local cur = vim.api.nvim_get_current_buf()
  if not view.state[cur] then
    return
  end
  -- A new navigation from a back-state drops forward history -- browser and
  -- jumplist rule. Entries dropped here may hold the only reference to a
  -- stacked view; those are wiped.
  for i = #M._stack, M._pos + 1, -1 do
    local e = table.remove(M._stack, i)
    if e.buf ~= cur then
      wipe(e.buf)
    end
  end
  vim.bo[cur].bufhidden = "hide" -- survives leaving the window while stacked
  local c = vim.api.nvim_win_get_cursor(0)
  M._stack[#M._stack + 1] = { buf = cur, cursor = c }
  M._pos = #M._stack
  -- Depth cap: evict from the bottom. An evicted buffer may still appear
  -- higher in the stack (buffer reuse), so only wipe it when it does not.
  while #M._stack > M._stack_n do
    local e = table.remove(M._stack, 1)
    M._pos = M._pos - 1
    local still_referenced = false
    for _, r in ipairs(M._stack) do
      if r.buf == e.buf then
        still_referenced = true
        break
      end
    end
    if not still_referenced and e.buf ~= vim.api.nvim_get_current_buf() then
      wipe(e.buf)
    end
  end
end

local function show(entry)
  if not vim.api.nvim_buf_is_valid(entry.buf) then
    return false
  end
  vim.api.nvim_set_current_buf(entry.buf)
  pcall(vim.api.nvim_win_set_cursor, 0, entry.cursor)
  return true
end

-- Switch to the reading view for `loc` ({ uri, range }), pushing the view
-- we leave. Files that cannot be read leave the current view and the stack
-- untouched.
function M.goto_location(loc)
  local path = vim.uri_to_fname(loc.uri)
  if vim.fn.filereadable(path) == 0 then
    vim.notify("[inline-explorer] cannot read " .. path, vim.log.levels.WARN)
    return false
  end

  -- Entering trail-land from a plain buffer opens its view first, so the
  -- journey is view-to-view from the very first hop.
  local cur = vim.api.nvim_get_current_buf()
  if not view.state[cur] and vim.api.nvim_buf_get_name(cur) ~= "" then
    view.open()
  end
  push_current()

  local sb = vim.fn.bufadd(path)
  vim.fn.bufload(sb)
  local target = view_of(sb) or view.open(sb)
  vim.api.nvim_set_current_buf(target)
  vim.bo[target].bufhidden = "hide" -- stacked or shown, it must survive switches
  pcall(vim.api.nvim_win_set_cursor, 0, { loc.range.start.line + 1, loc.range.start.character })
  return true
end

local function step(delta, edge_msg)
  local target = M._pos + delta
  if target < 1 or target > #M._stack then
    vim.notify("[inline-explorer] " .. edge_msg, vim.log.levels.INFO)
    return false
  end
  -- Where we are now must be re-enterable from the other direction, so the
  -- current position's cursor is refreshed in place (the entry already
  -- exists at _pos when moving back; moving forward from the top entry
  -- means _pos points at the shown buffer's own entry).
  local cur = vim.api.nvim_get_current_buf()
  if M._stack[M._pos] and M._stack[M._pos].buf == cur then
    M._stack[M._pos].cursor = vim.api.nvim_win_get_cursor(0)
  end
  if not show(M._stack[target]) then
    vim.notify("[inline-explorer] that view is gone", vim.log.levels.WARN)
    return false
  end
  M._pos = target
  return true
end

function M.back()
  -- The shown view may sit ABOVE _pos (it was never pushed -- pushing
  -- happens on leaving). Entering back-navigation pushes it so forward can
  -- return to it.
  local cur = vim.api.nvim_get_current_buf()
  if view.state[cur] and (M._stack[M._pos] == nil or M._stack[M._pos].buf ~= cur) then
    vim.bo[cur].bufhidden = "hide"
    M._stack[#M._stack + 1] = { buf = cur, cursor = vim.api.nvim_win_get_cursor(0) }
    M._pos = #M._stack
  end
  return step(-1, "already at the start of the trail")
end

function M.forward()
  return step(1, "already at the end of the trail")
end

-- The whole trail in the location list -- the vertical counterpart of the
-- breadcrumb.
function M.list()
  local items = {}
  for i, e in ipairs(M._stack) do
    if vim.api.nvim_buf_is_valid(e.buf) then
      local st = view.state[e.buf]
      local name = st and vim.api.nvim_buf_get_name(st.source_bufnr) or vim.api.nvim_buf_get_name(e.buf)
      items[#items + 1] = {
        bufnr = e.buf,
        lnum = e.cursor[1],
        col = e.cursor[2] + 1,
        text = ((i == M._pos) and "> " or "  ") .. vim.fn.fnamemodify(name, ":t"),
      }
    end
  end
  vim.fn.setloclist(0, items)
  vim.cmd("lopen")
end

return M
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/trail_spec.lua" -c "qa!"`
Expected: `ALL TRAIL TESTS PASSED`

- [ ] **Step 6: Run the neighbouring suites (view is shared state)**

Run for each of `expander`, `substitute`, `macro`, `resolver`: `nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/<s>_spec.lua" -c "qa!"`
Expected: all end in `ALL ... PASSED`

- [ ] **Step 7: Commit**

```bash
git add lua/inline-explorer/trail.lua lua/inline-explorer/view.lua tests/trail_spec.lua
git commit -m "A trail that keeps what it walked through

Views stay alive while stacked, so going back restores expansions by
identity rather than by snapshot: nothing is saved because nothing is
destroyed."
```

---

### Task 2: callers.lua — LSP callHierarchy with a labelled grep fallback

**Files:**
- Create: `lua/inline-explorer/callers.lua`
- Test: `tests/callers_spec.lua`

**Interfaces:**
- Consumes: nothing from Task 1 (independent).
- Produces (Task 3 relies on these exact names):
  - `callers.get(name, bufnr, cb)` — async; `cb(items, source, err)`.
    - `items`: list of `{ name = <enclosing fn or "?">, uri, range = lsp-range of the call site, text = <call line, trimmed> }`, sorted by (uri, line).
    - `source`: `"lsp"` or `"grep"`; `items` empty + `err` string when both produced nothing.
  - `callers._timeout_ms` (default 4000, module field for tests).
  - `callers._grep_max` (default 200): grep candidate cap; when the cap is hit, `err` carries a note even on success (`"truncated at 200 matches"`) so the UI can say the list may be incomplete.

- [ ] **Step 1: Write the failing test**

Create `tests/callers_spec.lua`:

```lua
-- Callers: LSP callHierarchy first, grep+tree-sitter fallback, source
-- always labelled. Counts, not timings.
--   nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/callers_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))

local callers = require("inline-explorer.callers")

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and ("  " .. tostring(d)) or ""))
  end
end

-- A tiny project on disk: two callers of `target_fn` in two files, plus a
-- same-named STATIC in a third file whose call must NOT be attributed to
-- our target (the multiple-definition ambiguity the real-source harness
-- taught us): grep cannot tell them apart, and the test pins that the
-- fallback reports the textual truth (3 call sites) -- over-approximation
-- is the fallback's documented contract, not a bug; the label tells the
-- user which contract they are looking at.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function write(rel, text)
  local f = assert(io.open(dir .. "/" .. rel, "w"))
  f:write(text)
  f:close()
end
write("lib.c", "int target_fn(int a)\n{\n    return a + 1;\n}\n")
write("use1.c", "int target_fn(int);\nint u1(void)\n{\n    return target_fn(1);\n}\n")
write("use2.c", "int target_fn(int);\nint u2(void)\n{\n    int x = target_fn(2);\n    return x;\n}\n")
write("other.c", "static int target_fn(int a) { return a; }\nint u3(void) { return target_fn(3); }\n")
-- a non-call textual mention that tree-sitter must reject:
write("doc.c", "// target_fn is documented here, not called\nint unrelated(void) { return 0; }\n")

vim.cmd.edit(dir .. "/lib.c")
local buf = vim.api.nvim_get_current_buf()

-- 1. No LSP attached at all: get() must fall back to grep, labelled so.
do
  local done, items, source, err = false, nil, nil, nil
  callers.get("target_fn", buf, function(i, s, e)
    items, source, err = i, s, e
    done = true
  end)
  vim.wait(10000, function() return done end, 10)
  check("grep fallback: fires when no LSP is attached", done and source == "grep", tostring(source))
  check("grep fallback: finds the three textual call sites",
    items ~= nil and #items == 3, items and #items)
  check("grep fallback: the doc-comment mention is rejected by tree-sitter",
    (function()
      for _, it in ipairs(items or {}) do
        if it.uri:find("doc%.c") then return false end
      end
      return true
    end)())
  check("grep fallback: enclosing function names resolved",
    (function()
      local names = {}
      for _, it in ipairs(items or {}) do names[it.name] = true end
      return names["u1"] and names["u2"] and names["u3"]
    end)(), vim.inspect(items))
  check("grep fallback: items sorted by file then line",
    (function()
      for i = 2, #(items or {}) do
        local a, b = items[i - 1], items[i]
        if a.uri > b.uri then return false end
        if a.uri == b.uri and a.range.start.line > b.range.start.line then return false end
      end
      return true
    end)())
end

-- 2. In-process LSP server with callHierarchy: LSP wins, labelled so.
do
  local uri1 = vim.uri_from_fname(vim.fn.resolve(dir .. "/use1.c"))
  local prepare_count, incoming_count = 0, 0
  local cid = vim.lsp.start({
    name = "hier",
    cmd = function(dispatchers)
      local closing, next_id = false, 0
      return {
        request = function(method, _, callback)
          next_id = next_id + 1
          if method == "initialize" then
            callback(nil, { capabilities = { callHierarchyProvider = true } })
          elseif method == "textDocument/prepareCallHierarchy" then
            prepare_count = prepare_count + 1
            callback(nil, { { name = "target_fn", kind = 12, uri = uri1,
              range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 10 } },
              selectionRange = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 13 } } } })
          elseif method == "callHierarchy/incomingCalls" then
            incoming_count = incoming_count + 1
            callback(nil, { {
              from = { name = "u1", kind = 12, uri = uri1,
                range = { start = { line = 1, character = 0 }, ["end"] = { line = 4, character = 1 } },
                selectionRange = { start = { line = 1, character = 4 }, ["end"] = { line = 1, character = 6 } } },
              fromRanges = { { start = { line = 3, character = 11 }, ["end"] = { line = 3, character = 20 } } },
            } })
          else
            callback(nil, nil)
          end
          return true, next_id
        end,
        notify = function() return true end,
        is_closing = function() return closing end,
        terminate = function() closing = true; dispatchers.on_exit(0, 0) end,
      }
    end,
    root_dir = dir,
  })
  vim.wait(2000, function()
    return cid ~= nil and #vim.lsp.get_clients({ bufnr = buf, name = "hier" }) > 0
  end, 20)
  if #vim.lsp.get_clients({ bufnr = buf, name = "hier" }) == 0 then
    print("SKIP  LSP callers checks (in-process server unavailable)")
  else
    local done, items, source = false, nil, nil
    callers.get("target_fn", buf, function(i, s)
      items, source = i, s
      done = true
    end)
    vim.wait(5000, function() return done end, 10)
    check("lsp: source labelled lsp", done and source == "lsp", tostring(source))
    check("lsp: both round trips issued", prepare_count == 1 and incoming_count == 1,
      ("prepare=%d incoming=%d"):format(prepare_count, incoming_count))
    check("lsp: one caller with its fromRange as the call site",
      items and #items == 1 and items[1].name == "u1" and items[1].range.start.line == 3,
      vim.inspect(items))
    check("lsp: call line text extracted",
      items and items[1].text ~= nil and items[1].text:find("target_fn", 1, true) ~= nil,
      items and items[1].text)
    vim.lsp.stop_client(cid, true)
    vim.wait(1000, function() return #vim.lsp.get_clients({ bufnr = buf }) == 0 end, 20)
  end
end

print("")
print(fails == 0 and "ALL CALLERS TESTS PASSED" or (fails .. " FAILURE(S)"))
if fails > 0 then vim.cmd("cq") end
vim.cmd("qa!")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/callers_spec.lua" -c "qa!"`
Expected: `module 'inline-explorer.callers' not found`

- [ ] **Step 3: Write callers.lua**

Create `lua/inline-explorer/callers.lua`:

```lua
-- Callers of a function: LSP callHierarchy when the server offers it, a
-- grep + tree-sitter fallback when it does not or returns nothing. The
-- source is always reported to the caller of this module and always shown
-- to the user -- an indexing server returns INCOMPLETE results silently,
-- and "0 callers" must never be allowed to read as "nobody calls this".
--
-- The two sources have different contracts, both honest: LSP resolves
-- identity (which target_fn) but sees only what its index has; grep sees
-- every textual call, including through macros the AST cannot follow, but
-- cannot tell two same-named statics apart. The label is what tells the
-- user which contract they are looking at.
local M = {}

M._timeout_ms = 4000
M._grep_max = 200

local function sort_items(items)
  table.sort(items, function(a, b)
    if a.uri ~= b.uri then
      return a.uri < b.uri
    end
    return a.range.start.line < b.range.start.line
  end)
  return items
end

local function line_text(path, lnum0)
  local lines = vim.fn.readfile(path, "", lnum0 + 2)
  local l = lines[lnum0 + 1]
  return l and vim.trim(l) or ""
end

-- grep fallback: rg (or grep -rn) for the identifier, then tree-sitter
-- confirms each hit is the callee of a call_expression and names the
-- enclosing function. Parsed per FILE, not per hit.
local function grep_callers(name, root, cb)
  local cmd
  if vim.fn.executable("rg") == 1 then
    cmd = { "rg", "--vimgrep", "--word-regexp", "--max-count", "50", name, root }
  else
    cmd = { "grep", "-rnw", name, root }
  end
  vim.system(cmd, { text = true }, function(out)
    local hits_by_file, n, truncated = {}, 0, false
    for line in (out.stdout or ""):gmatch("[^\n]+") do
      -- rg --vimgrep: file:line:col:text   grep -rnw: file:line:text
      local file, lnum, col = line:match("^(.-):(%d+):(%d+):")
      if not file then
        file, lnum = line:match("^(.-):(%d+):")
        col = "1"
      end
      if file then
        n = n + 1
        if n > M._grep_max then
          truncated = true
          break
        end
        hits_by_file[file] = hits_by_file[file] or {}
        table.insert(hits_by_file[file], { lnum = tonumber(lnum) - 1, col = tonumber(col) - 1 })
      end
    end
    vim.schedule(function()
      local items = {}
      for file, hits in pairs(hits_by_file) do
        local ok, src = pcall(function()
          return table.concat(vim.fn.readfile(file), "\n")
        end)
        if ok then
          local pok, root_node = pcall(function()
            return vim.treesitter.get_string_parser(src, "c"):parse()[1]:root()
          end)
          if pok then
            for _, h in ipairs(hits) do
              local node = root_node:named_descendant_for_range(h.lnum, h.col, h.lnum, h.col)
              -- climb to the call_expression whose callee is this identifier
              local is_call = false
              local nd = node
              while nd do
                if nd:type() == "call_expression" then
                  local fn = nd:field("function")[1]
                  if fn then
                    local _, _, a, _, _, b = fn:range(true)
                    if src:sub(a + 1, b) == name then
                      is_call = true
                    end
                  end
                  break
                end
                nd = nd:parent()
              end
              if is_call then
                -- enclosing function name, "?" when there is none
                local encl = "?"
                local up = node
                while up do
                  if up:type() == "function_definition" then
                    local C = require("inline-explorer.csrc")
                    local fd = C.func_declarator(up:field("declarator")[1])
                    encl = (fd and C.decl_name(fd:field("declarator")[1], src)) or "?"
                    break
                  end
                  up = up:parent()
                end
                items[#items + 1] = {
                  name = encl,
                  uri = vim.uri_from_fname(file),
                  range = { start = { line = h.lnum, character = h.col },
                    ["end"] = { line = h.lnum, character = h.col + #name } },
                  text = line_text(file, h.lnum),
                }
              end
            end
          end
        end
      end
      cb(sort_items(items), "grep", truncated and ("truncated at " .. M._grep_max .. " matches") or nil)
    end)
  end)
end

local function grep_root(bufnr)
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if c.config and c.config.root_dir then
      return c.config.root_dir
    end
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fn.fnamemodify(name, ":h") or vim.fn.getcwd()
end

-- Async: cb(items, source, err). Falls back to grep when the server lacks
-- callHierarchy, errors, times out, or answers with nothing.
function M.get(name, bufnr, cb)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/prepareCallHierarchy" })
  local root = grep_root(bufnr)
  if #clients == 0 then
    return grep_callers(name, root, cb)
  end

  local finish = require("inline-explorer.async").once_with_timeout(function(items, source, err)
    cb(items, source, err)
  end, function()
    -- The timeout hands control to grep; grep's own answer then arrives
    -- through a DIFFERENT callback invocation, so this path returns nothing
    -- itself and lets grep call cb.
    grep_callers(name, root, function(items, source, err)
      cb(items, source, err)
    end)
    return nil, "__handled__"
  end, M._timeout_ms)
  -- once_with_timeout fires cb exactly once; the timeout branch above calls
  -- cb through grep instead, so the sentinel return is dropped:
  local real_finish = finish
  finish = function(items, source, err)
    if source == "__handled__" or err == "__handled__" then
      return
    end
    return real_finish(items, source, err)
  end

  local params = vim.lsp.util.make_position_params(0, clients[1].offset_encoding)
  -- The cursor may not be on the symbol (picker can be invoked anywhere), so
  -- position params are only a hint; prepareCallHierarchy is driven off the
  -- definition when the resolver knows it. Task 3 passes a position; here
  -- the buffer's cursor is used as-is.
  clients[1]:request("textDocument/prepareCallHierarchy", params, function(err, result)
    if err or not result or #result == 0 then
      return grep_callers(name, root, function(items, source, gerr)
        finish(items, source, gerr)
      end)
    end
    local item = result[1]
    clients[1]:request("callHierarchy/incomingCalls", { item = item }, function(ierr, calls)
      if ierr or not calls or #calls == 0 then
        return grep_callers(name, root, function(items, source, gerr)
          finish(items, source, gerr)
        end)
      end
      local items = {}
      for _, call in ipairs(calls) do
        local from = call.from
        local path = vim.uri_to_fname(from.uri)
        for _, r in ipairs(call.fromRanges or {}) do
          items[#items + 1] = {
            name = from.name or "?",
            uri = from.uri,
            range = r,
            text = line_text(path, r.start.line),
          }
        end
      end
      finish(sort_items(items), "lsp", nil)
    end, bufnr)
  end, bufnr)
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/callers_spec.lua" -c "qa!"`
Expected: `ALL CALLERS TESTS PASSED`

If the `once_with_timeout` sentinel plumbing proves awkward in practice, simplify it — a plain `did_answer` boolean guard with a `vim.defer_fn` timeout is acceptable — but the behaviour under test must not change: exactly one `cb`, grep on timeout.

- [ ] **Step 5: Commit**

```bash
git add lua/inline-explorer/callers.lua tests/callers_spec.lua
git commit -m "Ask who calls this, and say where the answer came from

An indexing server returns incomplete results silently, so the source
label is part of the answer: lsp resolves identity but sees only its
index; grep sees every textual call, macros included, but cannot tell
two same-named statics apart."
```

---

### Task 3: Wiring — picker, keymaps, commands

**Files:**
- Modify: `lua/inline-explorer/config.lua` — four new keymap defaults
- Modify: `lua/inline-explorer/init.lua` — commands `InlineExplorerCallers`, `InlineExplorerTrail`
- Modify: `lua/inline-explorer/view.lua` — buffer-local keymaps in `M.open`, `trail.clear()` in `M.close`
- Create: `lua/inline-explorer/pick.lua` (the picker glue; small on purpose)
- Test: `tests/pick_spec.lua`

**Interfaces:**
- Consumes: `trail.goto_location`, `trail.back`, `trail.forward`, `trail.list`, `trail.clear` (Task 1); `callers.get` (Task 2); `resolver.locate(name, bufnr, cb)` (existing).
- Produces: `pick.callers()` (current word / view-aware), `pick.definition()` — both usable as keymap callbacks and from user commands.

- [ ] **Step 1: Write the failing test**

Create `tests/pick_spec.lua`:

```lua
-- Picker glue: vim.ui.select is stubbed; what is asserted is what the user
-- would have seen (title, labels) and where a choice takes the window.
--   nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/pick_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))

require("inline-explorer").setup()
local pick = require("inline-explorer.pick")
local callers = require("inline-explorer.callers")
local trail = require("inline-explorer.trail")
local view = require("inline-explorer.view")

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and ("  " .. tostring(d)) or ""))
  end
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function write(rel, text)
  local f = assert(io.open(dir .. "/" .. rel, "w"))
  f:write(text)
  f:close()
end
write("lib.c", "int tgt(int a)\n{\n    return a + 1;\n}\n")
write("use1.c", "int tgt(int);\nint u1(void)\n{\n    return tgt(1);\n}\n")

vim.cmd.edit(dir .. "/lib.c")
vim.api.nvim_win_set_cursor(0, { 1, 5 }) -- on `tgt`
local v = view.open()

-- Stub the selector: capture prompt+items, choose the first entry.
local seen_prompt, seen_n
vim.ui.select = function(items, opts, on_choice)
  seen_prompt, seen_n = opts and opts.prompt, #items
  on_choice(items[1], 1)
end

do
  local done = false
  pick.callers(function()
    done = true
  end)
  vim.wait(10000, function() return done end, 10)
  check("picker: prompt carries name, count and source",
    seen_prompt ~= nil and seen_prompt:find("tgt", 1, true) ~= nil
      and seen_prompt:find("1", 1, true) ~= nil and seen_prompt:find("grep", 1, true) ~= nil,
    tostring(seen_prompt))
  check("picker: choosing switches the view to the caller's file",
    view.state[vim.api.nvim_get_current_buf()] ~= nil
      and vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()):find("use1", 1, true) ~= nil,
    vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
  check("picker: the view we left is on the trail",
    #trail._stack >= 1 and trail._stack[#trail._stack].buf == v, #trail._stack)
end

-- Zero results: no picker, a notification instead.
do
  seen_prompt = nil
  local notified
  local orig = vim.notify
  vim.notify = function(msg)
    notified = msg
  end
  local done = false
  pick.callers(function()
    done = true
  end, "no_such_function_xyz")
  vim.wait(10000, function() return done end, 10)
  vim.notify = orig
  check("picker: zero callers -> no picker, an explicit notification",
    seen_prompt == nil and notified ~= nil and notified:find("no_such_function_xyz", 1, true) ~= nil,
    tostring(notified))
end

print("")
print(fails == 0 and "ALL PICK TESTS PASSED" or (fails .. " FAILURE(S)"))
if fails > 0 then vim.cmd("cq") end
vim.cmd("qa!")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/pick_spec.lua" -c "qa!"`
Expected: `module 'inline-explorer.pick' not found`

- [ ] **Step 3: Write pick.lua**

Create `lua/inline-explorer/pick.lua`:

```lua
-- Picker glue: callers.get / resolver.locate on one side,
-- trail.goto_location on the other, vim.ui.select in the middle. Kept
-- deliberately thin -- a dressing.nvim / telescope override of
-- vim.ui.select upgrades this UI without this module knowing.
local callers = require("inline-explorer.callers")
local trail = require("inline-explorer.trail")

local M = {}

local function word_under_cursor()
  return vim.fn.expand("<cword>")
end

-- The buffer to resolve against: a view's queries go through its source
-- buffer (which has the LSP clients); a plain buffer is its own source.
local function source_buf()
  local cur = vim.api.nvim_get_current_buf()
  local st = require("inline-explorer.view").state[cur]
  return st and st.source_bufnr or cur
end

-- opts_name overrides the word under the cursor (tests, command args).
-- done_cb fires exactly once, after the flow settles (tests need a seam;
-- interactive use passes nothing).
function M.callers(done_cb, opts_name)
  local name = opts_name or word_under_cursor()
  local function done()
    if done_cb then
      done_cb()
    end
  end
  if name == "" then
    vim.notify("[inline-explorer] no identifier under the cursor", vim.log.levels.WARN)
    return done()
  end
  callers.get(name, source_buf(), function(items, source, err)
    if #items == 0 then
      -- Never an empty picker: "0 callers" must not read as "nobody calls
      -- this" -- the index may simply not have finished.
      vim.notify(("[inline-explorer] no callers of '%s' found%s (the server's index may be incomplete)"):format(
        name, err and (" -- " .. err) or ""), vim.log.levels.INFO)
      return done()
    end
    local title = ("callers of %s — %d [%s]%s"):format(name, #items, source,
      err and (" (" .. err .. ")") or "")
    vim.ui.select(items, {
      prompt = title,
      format_item = function(it)
        return ("%s  %s:%d  │ %s"):format(it.name,
          vim.fn.fnamemodify(vim.uri_to_fname(it.uri), ":t"),
          it.range.start.line + 1, it.text)
      end,
    }, function(choice)
      if choice then
        trail.goto_location(choice)
      end
      done()
    end)
  end)
end

function M.definition(done_cb)
  local name = word_under_cursor()
  local function done()
    if done_cb then
      done_cb()
    end
  end
  if name == "" then
    vim.notify("[inline-explorer] no identifier under the cursor", vim.log.levels.WARN)
    return done()
  end
  require("inline-explorer.resolver").locate(name, source_buf(), function(loc, err)
    if not loc then
      vim.notify("[inline-explorer] " .. (err or ("no definition found for '" .. name .. "'")),
        vim.log.levels.INFO)
      return done()
    end
    trail.goto_location(loc)
    done()
  end)
end

return M
```

- [ ] **Step 4: Wire config, init, view**

`lua/inline-explorer/config.lua` — add to `M.defaults.keymaps` (after `list_blocks`):

```lua
    callers = "<leader>eu", -- callers picker (view-local; also :InlineExplorerCallers)
    goto_def = "gd", -- jump the VIEW to the definition under the cursor (view-local)
    trail_back = "<C-o>", -- back along the navigation trail (view-local)
    trail_forward = "<C-i>", -- forward along the navigation trail (view-local)
```

`lua/inline-explorer/init.lua` — after the `InlineExplorerList` command:

```lua
  local pick = require("inline-explorer.pick")
  local trail = require("inline-explorer.trail")
  vim.api.nvim_create_user_command("InlineExplorerCallers", function()
    pick.callers()
  end, { desc = "Pick a caller of the function under the cursor and go there" })
  vim.api.nvim_create_user_command("InlineExplorerTrail", trail.list,
    { desc = "The navigation trail in the location list" })
```

`lua/inline-explorer/view.lua` — in `M.open`, after the `list_blocks` keymap block:

```lua
  local trail = require("inline-explorer.trail")
  local pick = require("inline-explorer.pick")
  if km.callers then
    vim.keymap.set("n", km.callers, function() pick.callers() end,
      { buffer = view, desc = "Inline Explorer: callers of the function under the cursor" })
  end
  if km.goto_def then
    vim.keymap.set("n", km.goto_def, function() pick.definition() end,
      { buffer = view, desc = "Inline Explorer: jump the view to the definition" })
  end
  if km.trail_back then
    vim.keymap.set("n", km.trail_back, trail.back,
      { buffer = view, desc = "Inline Explorer: back along the trail" })
  end
  if km.trail_forward then
    vim.keymap.set("n", km.trail_forward, trail.forward,
      { buffer = view, desc = "Inline Explorer: forward along the trail" })
  end
```

and in `M.close`, before `M.state[view] = nil`:

```lua
  -- Closing the view ends the journey: every stacked view goes with it.
  require("inline-explorer.trail").clear()
```

- [ ] **Step 5: Run the new test and every fast suite**

Run: `nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/pick_spec.lua" -c "qa!"`
Expected: `ALL PICK TESTS PASSED`

Then all of: trail, callers, resolver, expander, substitute, macro, ir, gen, properties, pbt, bench_lib, real_source_lib.
Expected: every one ends `ALL ... PASSED`

- [ ] **Step 6: Commit**

```bash
git add lua/inline-explorer/pick.lua lua/inline-explorer/config.lua lua/inline-explorer/init.lua lua/inline-explorer/view.lua tests/pick_spec.lua
git commit -m "Wire the trail to keys: callers picker, gd, C-o/C-i

An empty result never opens an empty picker: the index may simply not
have finished, and 0 callers must not read as nobody-calls-this."
```

---

### Task 4: Real-kernel integration, README, spec conformance sweep

**Files:**
- Modify: `tests/real_kernel_spec.lua` — one new section
- Modify: `README.md` — document the four keymaps, the two commands, the source labels, the 0-callers caveat
- Modify: `.github/workflows/test.yml` — add `trail`, `callers`, `pick` to the fast-suites list (check how fast-suites enumerates specs first; follow its existing pattern)

**Interfaces:**
- Consumes: everything from Tasks 1-3.
- Produces: nothing new — this task proves the feature on the workload the plugin exists for.

- [ ] **Step 1: Extend real_kernel_spec**

Append before the final summary print in `tests/real_kernel_spec.lua` (it already has clangd ready on a real kernel buffer `buf` for `kernel/sched/core.c`; reuse that):

```lua
-- Navigation on the real workload: callHierarchy against real clangd, and
-- the trail preserving a view across a switch. Span/count gates only.
do
  local callers = require("inline-explorer.callers")
  local trail = require("inline-explorer.trail")
  local view = require("inline-explorer.view")

  -- resched_curr is defined and called in this file many times.
  local done, items, source = false, nil, nil
  vim.api.nvim_set_current_buf(buf)
  local defline = nil
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:match("^void resched_curr") or l:match("^static.*resched_curr") then
      defline = i
      break
    end
  end
  if defline then
    vim.api.nvim_win_set_cursor(0, { defline, 6 })
  end
  callers.get("resched_curr", buf, function(i2, s2)
    items, source = i2, s2
    done = true
  end)
  vim.wait(60000, function() return done end, 20)
  check("kernel callers: non-empty from real clangd or labelled grep",
    done and items ~= nil and #items > 0, ("source=%s n=%s"):format(tostring(source), items and #items))

  -- Trail across a real switch: the origin view must come back by identity.
  local v0 = view.open(buf)
  local before = vim.api.nvim_buf_line_count(v0)
  if items and #items > 0 then
    trail.goto_location(items[1])
    local v1 = vim.api.nvim_get_current_buf()
    check("kernel trail: switch lands in a view", view.state[v1] ~= nil)
    trail.back()
    check("kernel trail: back restores the SAME buffer",
      vim.api.nvim_get_current_buf() == v0)
    check("kernel trail: line count unchanged across the round trip",
      vim.api.nvim_buf_line_count(v0) == before)
  end
  trail.clear()
end
```

Note: `view.open(buf)` — if the current buffer IS `buf`, plain `view.open()` is equivalent; the explicit form documents intent. If `real_kernel_spec`'s existing structure makes the insertion point ambiguous, put this section immediately after the cache-invalidation checks and before the timing summary, and say so in the report.

- [ ] **Step 2: Run it against the local kernel tree**

Run: `IE_KERNEL_DIR=/tmp/claude-1001/-home-claude/8eec540c-6e2a-4002-b843-1a0deff3457d/scratchpad/kernel/linux-6.12 nvim --headless --clean -u NONE -c "luafile tests/real_kernel_spec.lua" -c "qa!"` (clangd on PATH: `/tmp/claude-1001/-home-claude/8eec540c-6e2a-4002-b843-1a0deff3457d/scratchpad/clangd_18.1.3/bin`)
Expected: existing checks plus the three new ones all PASS. With `--background-index=false` clangd may return no incoming calls — then the grep fallback label must appear; the check accepts either source but not emptiness.

- [ ] **Step 3: README**

Add to the Usage table:

```markdown
| `<leader>eu`  | `:InlineExplorerCallers`    | Pick a caller of the function under the cursor; the view switches there |
| `gd`          | —                           | Jump the view to the definition under the cursor (view-local)          |
| `<C-o>` / `<C-i>` | `:InlineExplorerTrail`  | Back / forward along the navigation trail (view-local); the command lists it |
```

And a short section after "Usage" (normal prose, English like the rest of the README):

```markdown
## Moving, not just expanding

Expansion reads downward in place. Two more movements complete the set:
`gd` jumps the whole view to a definition, and `<leader>eu` lists who calls
the function under the cursor — pick one and the view switches to that
caller. Both pushes the view you left onto a trail; `<C-o>`/`<C-i>` walk it,
and every view on the trail stays alive, so going back restores your
expansions exactly as you left them.

Caller lists are labelled with their source: `[lsp]` is clangd's index
(resolves identity, but silently incomplete while indexing), `[grep]` is a
text search confirmed by tree-sitter (sees calls through macros, but cannot
tell two same-named statics apart). Zero callers never opens an empty
picker — you get a notification instead, because "no callers found" and
"the index has not finished" are indistinguishable and the UI must not
pretend otherwise.
```

- [ ] **Step 4: CI**

Open `.github/workflows/test.yml`, find how `fast-suites` runs the spec files (a loop or an explicit list). Add `trail`, `callers`, `pick` following the existing pattern exactly. If the job globs `tests/*_spec.lua` automatically, no change is needed — verify and say which in the commit message.

- [ ] **Step 5: Full local verification**

Run every fast suite, bench (clangd on PATH), and real_kernel (IE_KERNEL_DIR set) as in Global Constraints.
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add tests/real_kernel_spec.lua README.md .github/workflows/test.yml
git commit -m "Prove the trail on the kernel, and document the moving set

The callers check accepts either source label but never emptiness:
0 callers and an unfinished index are indistinguishable, and the test
must not pretend otherwise any more than the UI may."
```

---

## Self-Review Notes

- Spec coverage: architecture/goto_location/生存管理/履歴 → Task 1; caller picker 取得/不完全性/表示/キー → Tasks 2-3; 定義ジャンプ → Task 3 (`pick.definition`); 履歴キーとコマンド → Task 3; エラー処理 → Tasks 1-3 (unreadable file, zero callers, timeout→grep); テスト方針の5項目 → trail_spec (stack unit), pick_spec (ui.select stub), callers_spec (fake server + ambiguity fixture), real_kernel_spec (integration). Spec's `InlineExplorerTrail` = Task 3. All covered.
- The spec's in-view `<C-o>`/`<C-i>` note: `<C-i>` equals `<Tab>` in some terminals; the keymap is buffer-local to the view, so a user who objects overrides `keymaps.trail_forward`. Documented via config comment.
- Type consistency: `callers.get(name, bufnr, cb)` / `cb(items, source, err)` used identically in Tasks 2, 3, 4; `trail.goto_location(loc)` takes `{uri, range}` in all uses; items carry `{name, uri, range, text}` everywhere.
