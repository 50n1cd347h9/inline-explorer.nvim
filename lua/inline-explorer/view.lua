-- View: a read-only copy of the source file where expansions are inserted as
-- real (cursor-navigable) text, so they can be expanded again in turn.
local util = require("inline-explorer.util")

local M = {}

M.block_ns = vim.api.nvim_create_namespace("inline_explorer")
-- One extmark per line of the source, id = source row + 1, placed when the
-- view opens. Neovim moves them with every edit, invalidates the ones on
-- lines that get replaced, and restores them on undo -- which is exactly
-- "which source line is this view line", with no bookkeeping of our own.
M.origin_ns = vim.api.nvim_create_namespace("inline_explorer_origin")

-- view_bufnr -> {
--   bufnr, source_bufnr,
--   blocks = { { name, s_mark, e_mark }, ... }  -- live expansion blocks
--   ranges_at = { [undo seq] = { { name, s, e }, ... } }
-- }
-- Undo is Neovim's own (see history.lua). It restores the text and the
-- origin marks, but a block's marks do not come back on redo, so the
-- blocks are recorded per undo state and rebuilt from there.
M.state = {}

-- Open a reading view and switch to it. `src` selects the source buffer;
-- omitted, the current buffer is used. The guard is not decoration: user
-- commands (InlineExplorerOpen) call this with the command-opts TABLE as
-- the first argument, so anything that is not a buffer number must mean
-- "current buffer".
function M.open(src)
  if type(src) ~= "number" then
    src = vim.api.nvim_get_current_buf()
  end
  if M.state[src] then
    util.notify("already in a reading view", vim.log.levels.INFO)
    return
  end

  local name = vim.api.nvim_buf_get_name(src)
  local ft = vim.bo[src].filetype
  local lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
  local cursor = vim.api.nvim_win_get_cursor(0)

  local view = vim.api.nvim_create_buf(false, true)
  -- Loading the copy is not an undoable change: undo stops at the file.
  vim.bo[view].undolevels = -1
  vim.api.nvim_buf_set_lines(view, 0, -1, false, lines)
  vim.bo[view].undolevels = 1000
  for i = 0, #lines - 1 do
    vim.api.nvim_buf_set_extmark(view, M.origin_ns, i, 0, { id = i + 1, invalidate = true })
  end
  vim.bo[view].filetype = ft
  vim.bo[view].buftype = "nofile"
  vim.bo[view].bufhidden = "wipe"
  vim.bo[view].modifiable = false
  pcall(vim.api.nvim_buf_set_name, view, "inline-explorer://" .. vim.fn.fnamemodify(name, ":t"))

  -- The view is a detached copy, so no language server attaches and its
  -- semantic-token highlighting is absent. Start tree-sitter explicitly so the
  -- buffer keeps rich highlighting instead of falling back to bare regex syntax.
  local lang = vim.treesitter.language.get_lang(ft) or ft
  pcall(vim.treesitter.start, view, lang)

  M.state[view] = { bufnr = view, source_bufnr = src, blocks = {}, ranges_at = { [0] = {} } }
  -- The state entry dies with the buffer. Without this, a view abandoned
  -- by a plain buffer switch (bufhidden=wipe) left its entry in M.state
  -- forever: close() requires the view to be current, and the trail's
  -- sweep skipped invalid buffers.
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = view,
    once = true,
    callback = function()
      M.state[view] = nil
    end,
  })

  vim.api.nvim_set_current_buf(view)
  -- Local to the view in this window (`:setlocal`). Plain vim.wo acts like
  -- `:set` and changed the user's global foldmethod too.
  vim.wo[0][0].foldmethod = "manual"
  vim.wo[0][0].foldenable = true
  pcall(vim.api.nvim_win_set_cursor, 0, cursor)

  -- Buffer-local undo/redo, so `u`/`<C-r>` only rebind inside the view.
  local hist = require("inline-explorer.history")
  local km = require("inline-explorer.config").options.keymaps or {}
  if km.undo then
    vim.keymap.set("n", km.undo, hist.undo, { buffer = view, desc = "Inline Explorer: undo expansion" })
  end
  if km.redo then
    vim.keymap.set("n", km.redo, hist.redo, { buffer = view, desc = "Inline Explorer: redo expansion" })
  end
  local nav = require("inline-explorer.nav")
  if km.next_block then
    vim.keymap.set("n", km.next_block, nav.next, { buffer = view, desc = "Inline Explorer: next expansion block" })
  end
  if km.prev_block then
    vim.keymap.set("n", km.prev_block, nav.prev, { buffer = view, desc = "Inline Explorer: previous expansion block" })
  end
  if km.list_blocks then
    vim.keymap.set("n", km.list_blocks, nav.list, { buffer = view, desc = "Inline Explorer: list expansion blocks" })
  end
  local trail = require("inline-explorer.trail")
  local pick = require("inline-explorer.pick")
  if km.callers then
    vim.keymap.set("n", km.callers, function()
      pick.callers()
    end, { buffer = view, desc = "Inline Explorer: callers of the function under the cursor" })
  end
  if km.goto_def then
    vim.keymap.set("n", km.goto_def, function()
      pick.definition()
    end, { buffer = view, desc = "Inline Explorer: jump the view to the definition" })
  end
  if km.trail_back then
    vim.keymap.set("n", km.trail_back, trail.back, { buffer = view, desc = "Inline Explorer: back along the trail" })
  end
  if km.trail_forward then
    vim.keymap.set(
      "n",
      km.trail_forward,
      trail.forward,
      { buffer = view, desc = "Inline Explorer: forward along the trail" }
    )
  end
  return view
end

-- Close the reading view the cursor is in.
function M.close()
  local view = vim.api.nvim_get_current_buf()
  if not M.state[view] then
    util.notify("not in a reading view", vim.log.levels.WARN)
    return
  end
  -- Closing the view ends the journey: every stacked view goes with it.
  require("inline-explorer.trail").clear()
  M.state[view] = nil
  vim.api.nvim_buf_delete(view, { force = true })
end

-- Return the state for the current buffer, or nil if it is not a view.
function M.current()
  return M.state[vim.api.nvim_get_current_buf()]
end

-- Whether `buf` is a reading view.
function M.is_view(buf)
  return M.state[buf] ~= nil
end

-- Drop the state of view `buf`; the buffer itself is left alone.
function M.forget(buf)
  M.state[buf] = nil
end

-- Source line (0-based) a view line originates from, or nil for inserted
-- or rewritten text.
function M.src_line(st, row)
  local marks = vim.api.nvim_buf_get_extmarks(st.bufnr, M.origin_ns, { row, 0 }, { row, -1 }, { details = true })
  for _, m in ipairs(marks) do
    if not m[4].invalid then
      return m[1] - 1
    end
  end
  return nil
end

-- Expansion blocks whose extmarks are both still valid, as { name, s, e }
-- (0-based rows), in st.blocks order. A block whose first or last line was
-- replaced has an invalid mark.
local function node_range(bufnr, node)
  local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.block_ns, node.s_mark, { details = true })
  local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.block_ns, node.e_mark, { details = true })
  if s[1] and e[1] and not s[3].invalid and not e[3].invalid then
    return s[1], e[1]
  end
end

function M.block_ranges(st, bufnr)
  local out = {}
  for _, node in ipairs(st.blocks) do
    local s, e = node_range(bufnr, node)
    if s then
      out[#out + 1] = { name = node.name, s = s, e = e }
    end
  end
  return out
end

-- The undo state `bufnr` is in (undotree() of that buffer).
local function undo_seq(bufnr)
  return vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.undotree().seq_cur
  end)
end

-- The view is nomodifiable; every write goes through here.
function M.set_lines(bufnr, s, e, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, s, e, false, lines)
  vim.bo[bufnr].modifiable = false
end

-- Forget every expansion block: extmarks, manual folds, and the node list.
function M.reset_marks(st, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.block_ns, 0, -1)
  pcall(vim.cmd, "silent! normal! zE")
  st.blocks = {}
end

local function fold_open(s, e)
  pcall(vim.cmd, string.format("%d,%dfold", s + 1, e + 1))
  pcall(vim.cmd, string.format("%d,%dfoldopen", s + 1, e + 1))
end

-- Track rows s..e (0-based) as expansion block `name`, folded and open.
-- The fold commands act on the current window, which shows `bufnr`.
function M.add_block(st, bufnr, name, s, e)
  st.blocks[#st.blocks + 1] = {
    name = name,
    s_mark = vim.api.nvim_buf_set_extmark(bufnr, M.block_ns, s, 0, { invalidate = true }),
    e_mark = vim.api.nvim_buf_set_extmark(bufnr, M.block_ns, e, 0, { invalidate = true }),
  }
  fold_open(s, e)
end

-- One undoable change to the view: `fn` edits it (set_lines, add_block).
-- Starts a new undo step first -- edits made from separate callbacks would
-- otherwise join the previous one -- and afterwards records the blocks
-- that are live in the resulting undo state.
function M.change(st, bufnr, fn)
  vim.bo[bufnr].undolevels = vim.bo[bufnr].undolevels -- closes the previous undo step
  fn()
  local nodes, live = {}, {}
  for _, node in ipairs(st.blocks) do
    local s, e = node_range(bufnr, node)
    if s then
      nodes[#nodes + 1] = node
      live[#live + 1] = { name = node.name, s = s, e = e }
    end
  end
  st.blocks = nodes
  st.ranges_at[undo_seq(bufnr)] = live
end

-- After undo/redo: rebuild the blocks recorded for the undo state the
-- buffer is now in.
function M.restore_blocks(st, bufnr)
  M.reset_marks(st, bufnr)
  for _, node in ipairs(st.ranges_at[undo_seq(bufnr)] or {}) do
    M.add_block(st, bufnr, node.name, node.s, node.e)
  end
end

-- Re-entrancy guard: one resolver round trip per view at a time, so two quick
-- keypresses on a slow server cannot interleave their splices. The stamp
-- goes stale after FETCH_GUARD_MS so a leaked flag cannot wedge the view
-- forever -- but the stale-out must outlast the resolver's WORST case, not
-- its typical one. fetch chains up to four sequential budgets (locate,
-- extract, definition chase, second extract), so the previous fixed 5000ms
-- re-armed the guard mid-flight: measured 9.6s on a stubbed slow server,
-- with the guard re-granted at 5.2s -- reopening the exact interleaved-
-- splice hazard it exists to prevent. Derived, not guessed, so a timeout
-- tuning cannot silently outgrow it again. M.FETCH_GUARD_MS, when set, is
-- an override -- the stale-out tests use it to force expiry without
-- waiting sixteen real seconds; production leaves it nil and derives.
M.FETCH_GUARD_MS = nil

function M.fetch_guard_ms()
  if M.FETCH_GUARD_MS then
    return M.FETCH_GUARD_MS
  end
  local r = require("inline-explorer.resolver")
  return 3 * r._timeout_ms + math.max(r._cold_timeout_ms, r._timeout_ms) + 1000
end

function M.begin_fetch(st)
  local now = vim.uv.now()
  if st.fetch_started and (now - st.fetch_started) < M.fetch_guard_ms() then
    return false
  end
  st.fetch_started = now
  return true
end

function M.end_fetch(st)
  st.fetch_started = nil
end

-- Turn the view's text into `new_src` (used by in-place transforms) by
-- replacing only the lines that differ, bottom-up so earlier hunks keep
-- their row numbers. Untouched lines keep their extmarks: their origin,
-- and the blocks around them. A block whose first or last line is
-- replaced is dropped.
function M.rewrite(st, bufnr, new_src, row)
  local span = require("inline-explorer.profile").start()
  local old_src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local new_lines = vim.split(new_src, "\n", { plain = true })
  local hunks = vim.diff(old_src .. "\n", new_src .. "\n", { result_type = "indices" }) or {}
  M.change(st, bufnr, function()
    for i = #hunks, 1, -1 do
      local sa, ca, sb, cb = unpack(hunks[i])
      -- A count of 0 means "insert after line start".
      local first = ca > 0 and sa - 1 or sa
      M.set_lines(bufnr, first, first + ca, vim.list_slice(new_lines, sb, sb + cb - 1))
    end
  end)
  -- Manual folds do not follow line replacements reliably; rebuild them
  -- for the blocks that survived.
  pcall(vim.cmd, "silent! normal! zE")
  for _, node in ipairs(M.block_ranges(st, bufnr)) do
    fold_open(node.s, node.e)
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  pcall(vim.api.nvim_win_set_cursor, 0, { math.min((row or 0) + 1, n), 0 })
  span("rewrite")
end

return M
