-- View (a "reading view"): a read-only copy of the source file where
-- expansions are inserted as real (cursor-navigable) text, so they can be
-- expanded again in turn.
local config = require("inline-explorer.config")
local profile = require("inline-explorer.profile")
local util = require("inline-explorer.util")
-- history, nav, pick and trail require this module, so this file requires
-- them inside the functions that use them: requiring them here would be a
-- require loop.

local M = {}

-- Two extmarks per expansion block, on its first and last row (see
-- M.add_block).
M.block_ns = vim.api.nvim_create_namespace("inline_explorer")

-- One extmark per source line, placed when the view opens. Its id is the
-- source row + 1, because extmark ids must be positive. Neovim moves these
-- marks with edits, invalidates a mark when its line is replaced, and
-- restores it on undo, so M.src_line() can read a view line's source row
-- from its mark without any bookkeeping of our own.
M.origin_ns = vim.api.nvim_create_namespace("inline_explorer_origin")

-- One entry per open view, keyed by the view's bufnr:
--   bufnr          the view buffer (the same as the key)
--   source_bufnr   the buffer the view was opened from
--   blocks         the expansion blocks, each { name, s_mark, e_mark }, where
--                  s_mark and e_mark are extmark ids in M.block_ns
--   ranges_at      the blocks of each undo state as rows, keyed by undo
--                  sequence number: { [seq] = { { name, s, e }, ... } }, with
--                  0-based inclusive rows. [0] is the state the view opened in.
--   fetch_started  vim.uv.now() when the lookup in flight began, or nil
--                  (see M.begin_fetch)
--   subst_n        how many function calls have been inlined in this view (set
--                  by inliner.lua, which numbers the names it injects with it)
-- Undo and redo are Neovim's own (history.lua runs them). They restore the
-- text and the origin marks, but not the block marks: a block's marks sit on
-- the lines its change inserted, and redo inserts those lines again without
-- them. So M.change() records the blocks of each undo state in ranges_at, and
-- M.restore_blocks() rebuilds them after an undo or redo.
M.state = {}

-- Whether `buf` is a reading view.
function M.is_view(buf)
  return M.state[buf] ~= nil
end

-- The state entry of the current buffer, or nil if it is not a view.
function M.current()
  return M.state[vim.api.nvim_get_current_buf()]
end

-- Drop the state entry of view `buf`; the buffer itself is left alone.
function M.forget(buf)
  M.state[buf] = nil
end

-- Create the view buffer for buffer `src` and return its bufnr. The buffer
-- holds a copy of src's lines with an origin mark on each line, has src's
-- filetype, and is highlighted by tree-sitter. It is not shown yet.
local function create_view_buffer(src)
  local name = vim.api.nvim_buf_get_name(src)
  local ft = vim.bo[src].filetype
  local lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)

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

  -- The view is a detached copy, so no language server attaches and it has
  -- no semantic-token highlighting. Start tree-sitter explicitly, so the
  -- buffer keeps rich highlighting instead of falling back to regex syntax.
  local lang = vim.treesitter.language.get_lang(ft) or ft
  pcall(vim.treesitter.start, view, lang)
  return view
end

-- Set the view's buffer-local keymaps. A key that the config leaves unset is
-- skipped.
local function set_keymaps(view)
  local hist = require("inline-explorer.history")
  local nav = require("inline-explorer.nav")
  local trail = require("inline-explorer.trail")
  local pick = require("inline-explorer.pick")
  local km = config.options.keymaps or {}
  local maps = {
    { key = km.undo, fn = hist.undo, desc = "undo expansion" },
    { key = km.redo, fn = hist.redo, desc = "redo expansion" },
    { key = km.next_block, fn = nav.next, desc = "next expansion block" },
    { key = km.prev_block, fn = nav.prev, desc = "previous expansion block" },
    { key = km.list_blocks, fn = nav.list, desc = "list expansion blocks" },
    -- pick.callers and pick.definition take optional arguments (a callback
    -- that tests use), so they are called through a wrapper that passes none.
    {
      key = km.callers,
      fn = function()
        pick.callers()
      end,
      desc = "callers of the function under the cursor",
    },
    {
      key = km.goto_def,
      fn = function()
        pick.definition()
      end,
      desc = "go to the definition, in a view of its file",
    },
    { key = km.trail_back, fn = trail.back, desc = "back along the trail" },
    { key = km.trail_forward, fn = trail.forward, desc = "forward along the trail" },
  }
  for _, map in ipairs(maps) do
    if map.key then
      vim.keymap.set("n", map.key, map.fn, { buffer = view, desc = "Inline Explorer: " .. map.desc })
    end
  end
end

-- Open a reading view of buffer `src` (default: the current buffer), switch
-- the window to it, and return its bufnr. If `src` is itself a view, notify
-- and return nothing. User commands pass their opts table as the first
-- argument, so anything that is not a number means the current buffer.
function M.open(src)
  if type(src) ~= "number" then
    src = vim.api.nvim_get_current_buf()
  end
  if M.is_view(src) then
    util.notify("already in a reading view", vim.log.levels.INFO)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local view = create_view_buffer(src)

  M.state[view] = { bufnr = view, source_bufnr = src, blocks = {}, ranges_at = { [0] = {} } }
  -- Drop the state entry when the buffer is wiped, including when the user
  -- just switches away (bufhidden=wipe) without calling close().
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = view,
    once = true,
    callback = function()
      M.forget(view)
    end,
  })

  vim.api.nvim_set_current_buf(view)
  -- Set the fold options for this buffer in this window only, like
  -- :setlocal (plain vim.wo would also change the global value).
  vim.wo[0][0].foldmethod = "manual"
  vim.wo[0][0].foldenable = true
  pcall(vim.api.nvim_win_set_cursor, 0, cursor)

  set_keymaps(view)
  return view
end

-- Close the reading view in the current window.
function M.close()
  local view = vim.api.nvim_get_current_buf()
  if not M.is_view(view) then
    util.notify("not in a reading view", vim.log.levels.WARN)
    return
  end
  -- Also clear the trail (see trail.lua): every other reading view that no
  -- window shows is wiped.
  require("inline-explorer.trail").clear()
  M.forget(view)
  vim.api.nvim_buf_delete(view, { force = true })
end

-- The source row (0-based) that view row `row` comes from, or nil for
-- inserted or rewritten text.
function M.src_line(st, row)
  local marks = vim.api.nvim_buf_get_extmarks(st.bufnr, M.origin_ns, { row, 0 }, { row, -1 }, { details = true })
  for _, mark in ipairs(marks) do
    local id, details = mark[1], mark[4]
    if not details.invalid then
      return id - 1 -- the id is the source row + 1 (see M.origin_ns)
    end
  end
  return nil
end

-- Expansion blocks. Functions below that take (st, bufnr) get a view's state
-- entry and that view's buffer, so bufnr is always st.bufnr.

-- The row of extmark `id` in M.block_ns, or nil if the mark does not exist
-- or its line has been replaced.
local function mark_row(bufnr, id)
  local row, _, details = unpack(vim.api.nvim_buf_get_extmark_by_id(bufnr, M.block_ns, id, { details = true }))
  if row and not details.invalid then
    return row
  end
  return nil
end

-- The 0-based first and last row of `block`, or nil if either of those lines
-- has been replaced.
local function block_range(bufnr, block)
  local s, e = mark_row(bufnr, block.s_mark), mark_row(bufnr, block.e_mark)
  if s and e then
    return s, e
  end
  return nil
end

-- The blocks whose first and last lines are both still there, as ranges
-- { name, s, e } (0-based inclusive rows), in st.blocks order.
function M.block_ranges(st, bufnr)
  local out = {}
  for _, block in ipairs(st.blocks) do
    local s, e = block_range(bufnr, block)
    if s then
      out[#out + 1] = { name = block.name, s = s, e = e }
    end
  end
  return out
end

-- The sequence number of the undo state that `bufnr` is in.
local function undo_seq(bufnr)
  return vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.undotree().seq_cur
  end)
end

-- Replace rows [s, e) of view `bufnr` with `lines`, as nvim_buf_set_lines
-- does. The view is nomodifiable, so every write goes through here.
function M.set_lines(bufnr, s, e, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, s, e, false, lines)
  vim.bo[bufnr].modifiable = false
end

-- Fold helpers. They act on the current window, which must show the view.
-- Folding is best effort: if a fold command fails (for example in a window
-- that does not fold manually), the error is ignored.

-- Delete every fold in the current window (zE).
local function delete_folds()
  pcall(vim.cmd, "silent! normal! zE")
end

-- Create a fold over rows s..e (0-based) in the current window, and open it.
local function create_open_fold(s, e)
  pcall(vim.cmd, string.format("%d,%dfold", s + 1, e + 1))
  pcall(vim.cmd, string.format("%d,%dfoldopen", s + 1, e + 1))
end

-- Forget every expansion block: delete the block extmarks and the folds of
-- the current window (which must show bufnr), and empty st.blocks.
local function clear_blocks(st, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.block_ns, 0, -1)
  delete_folds()
  st.blocks = {}
end

-- Record rows s..e (0-based, inclusive) as expansion block `name`, and give
-- it an open fold in the current window, which must show bufnr.
function M.add_block(st, bufnr, name, s, e)
  st.blocks[#st.blocks + 1] = {
    name = name,
    s_mark = vim.api.nvim_buf_set_extmark(bufnr, M.block_ns, s, 0, { invalidate = true }),
    e_mark = vim.api.nvim_buf_set_extmark(bufnr, M.block_ns, e, 0, { invalidate = true }),
  }
  create_open_fold(s, e)
end

-- Close the current undo block, so that the next edit starts a new undo
-- step. Setting 'undolevels' does that even when the value stays the same
-- (:help undo-blocks).
local function start_undo_step(bufnr)
  vim.bo[bufnr].undolevels = vim.bo[bufnr].undolevels
end

-- Make one undoable change to the view: `fn` edits it with M.set_lines and
-- M.add_block. A new undo step is started first, because edits made from
-- separate callbacks would otherwise join the previous step.
function M.change(st, bufnr, fn)
  start_undo_step(bufnr)
  fn()
  -- Forget the blocks whose first or last line fn() replaced, then record
  -- where the remaining ones are in the undo state the buffer is now in.
  local kept = {}
  for _, block in ipairs(st.blocks) do
    if block_range(bufnr, block) then
      kept[#kept + 1] = block
    end
  end
  st.blocks = kept
  st.ranges_at[undo_seq(bufnr)] = M.block_ranges(st, bufnr)
end

-- After an undo or redo, rebuild the blocks recorded for the undo state the
-- buffer is now in.
function M.restore_blocks(st, bufnr)
  clear_blocks(st, bufnr)
  for _, range in ipairs(st.ranges_at[undo_seq(bufnr)] or {}) do
    M.add_block(st, bufnr, range.name, range.s, range.e)
  end
end

-- Re-entrancy guard. While a lookup is in flight for a view, begin_fetch()
-- refuses to start another one, so two quick keypresses cannot interleave
-- their splices. If end_fetch() is never called, the guard expires after
-- guard_ms(), so a view cannot stay locked forever.

-- When set, the guard's duration in ms, used instead of the one guard_ms()
-- computes. Tests set it to make the guard expire quickly; it is nil
-- otherwise.
M.FETCH_GUARD_MS = nil

-- How long the guard holds, in ms. A lookup makes up to four requests in a
-- row (locate, extract, definition chase, second extract). The guard allows
-- the resolver's timeout for three of them and the longer of that timeout
-- and the cold-start timeout for the fourth, plus one second of slack.
local function guard_ms()
  if M.FETCH_GUARD_MS then
    return M.FETCH_GUARD_MS
  end
  local r = require("inline-explorer.resolver")
  return 3 * r._timeout_ms + math.max(r._cold_timeout_ms, r._timeout_ms) + 1000
end

-- Start a lookup for view `st`: record its start in st.fetch_started and
-- return true, or return false while an earlier lookup holds the guard.
function M.begin_fetch(st)
  local now = vim.uv.now()
  if st.fetch_started and (now - st.fetch_started) < guard_ms() then
    return false
  end
  st.fetch_started = now
  return true
end

-- Release the guard once the lookup has finished, whatever its outcome.
function M.end_fetch(st)
  st.fetch_started = nil
end

-- Replace the view's text with `new_src`, changing only the lines that
-- differ (inliner.lua uses this to substitute a call or a macro in place).
-- Lines left alone keep their extmarks: their origin, and the blocks around
-- them. A block whose first or last line is replaced is dropped. Then put
-- the cursor on `cursor_row` (0-based, default 0).
function M.rewrite(st, bufnr, new_src, cursor_row)
  local stop_timer = profile.start()
  local old_src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local new_lines = vim.split(new_src, "\n", { plain = true })
  -- End both texts with a newline. The diff tells a last line without one
  -- apart from the same line with one, so text added at the end would
  -- otherwise also replace the old last line and drop its extmarks.
  local hunks = vim.diff(old_src .. "\n", new_src .. "\n", { result_type = "indices" }) or {}
  M.change(st, bufnr, function()
    -- Apply the hunks bottom-up, so that each one leaves the rows of the
    -- hunks above it unchanged.
    for i = #hunks, 1, -1 do
      local old_start, old_count, new_start, new_count = unpack(hunks[i])
      -- vim.diff rows are 1-based. A pure insertion (old_count == 0) goes
      -- after line old_start, so old_start is already the 0-based row to
      -- insert at.
      local first
      if old_count == 0 then
        first = old_start
      else
        first = old_start - 1
      end
      M.set_lines(bufnr, first, first + old_count, vim.list_slice(new_lines, new_start, new_start + new_count - 1))
    end
  end)
  -- Manual folds do not follow line replacements reliably, so rebuild them
  -- for the blocks that survived.
  delete_folds()
  for _, range in ipairs(M.block_ranges(st, bufnr)) do
    create_open_fold(range.s, range.e)
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  pcall(vim.api.nvim_win_set_cursor, 0, { math.min((cursor_row or 0) + 1, line_count), 0 })
  stop_timer("rewrite")
end

return M
