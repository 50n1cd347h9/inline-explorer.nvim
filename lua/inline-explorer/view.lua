-- View (a "reading view"): a read-only copy of the source file where
-- expansions are inserted as real (cursor-navigable) text, so they can be
-- expanded again in turn.
local config = require("inline-explorer.config")
local lsp = require("inline-explorer.lsp")
local profile = require("inline-explorer.profile")
local util = require("inline-explorer.util")
-- history, nav, pick and trail require this module, so they are required
-- where they are used: requiring them here would be a require loop.

---@class inline_explorer.Block
---@field name string the expanded symbol
---@field s_mark integer extmark id in M.block_ns, on the block's first row
---@field e_mark integer extmark id in M.block_ns, on the block's last row

---@class inline_explorer.BlockRange
---@field name string
---@field s integer first row, 0-based
---@field e integer last row, 0-based, inclusive

---@class inline_explorer.ViewState
---@field bufnr integer the view buffer
---@field source_bufnr integer the buffer the view was opened from
---@field blocks inline_explorer.Block[]
---@field ranges_at table<integer, inline_explorer.BlockRange[]> the blocks of each undo state, by seq (see M.change)
---@field fetch_started? integer vim.uv.now() when the lookup in flight began (see M.begin_fetch)
---@field subst_n? integer calls inlined so far; inliner.lua numbers the names it injects with it

local M = {}

M.block_ns = vim.api.nvim_create_namespace("inline_explorer")

-- One mark per source line, placed when the view opens, with id = source
-- row + 1 (ids must be positive). Neovim moves the marks with edits,
-- invalidates one when its line is replaced and restores it on undo, so a
-- view line's source row needs no bookkeeping of our own (see M.src_line).
M.origin_ns = vim.api.nvim_create_namespace("inline_explorer_origin")

-- Open views, by view bufnr.
---@type table<integer, inline_explorer.ViewState>
M.state = {}

---@param buf integer
---@return boolean
function M.is_view(buf)
  return M.state[buf] ~= nil
end

---@return inline_explorer.ViewState?
function M.current()
  return M.state[vim.api.nvim_get_current_buf()]
end

---@param buf integer
function M.forget(buf)
  local st = M.state[buf]
  if st then
    lsp.unpin(st.source_bufnr)
  end
  M.state[buf] = nil
end

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
  -- Fails (E95) while another view has this name: same file name, other directory.
  pcall(vim.api.nvim_buf_set_name, view, "inline-explorer://" .. vim.fn.fnamemodify(name, ":t"))

  -- No language server attaches to the copy (no semantic tokens), so start
  -- tree-sitter rather than leave its highlighting to regex syntax.
  local lang = vim.treesitter.language.get_lang(ft) or ft
  pcall(vim.treesitter.start, view, lang)
  return view
end

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

-- Open a reading view of `src` in the current window.
---@param src? integer|vim.api.keyset.create_user_command.command_args a table or nil means the current buffer
---@return integer? view nil if `src` is itself a view
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
  -- Lookups from the view go through the source buffer's clients.
  lsp.pin(src)
  -- bufhidden=wipe also wipes the view, without M.close(), once it is hidden.
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = view,
    once = true,
    callback = function()
      M.forget(view)
    end,
  })

  vim.api.nvim_set_current_buf(view)
  vim.wo[0][0].foldmethod = "manual"
  vim.wo[0][0].foldenable = true
  pcall(vim.api.nvim_win_set_cursor, 0, cursor)

  set_keymaps(view)
  return view
end

function M.close()
  local view = vim.api.nvim_get_current_buf()
  if not M.is_view(view) then
    util.notify("not in a reading view", vim.log.levels.WARN)
    return
  end
  require("inline-explorer.trail").clear()
  M.forget(view)
  vim.api.nvim_buf_delete(view, { force = true })
end

-- The source row of view row `row`.
---@param st inline_explorer.ViewState
---@param row integer 0-based
---@return integer? src_row 0-based; nil for inserted or rewritten text
function M.src_line(st, row)
  local marks = vim.api.nvim_buf_get_extmarks(st.bufnr, M.origin_ns, { row, 0 }, { row, -1 }, { details = true })
  for _, mark in ipairs(marks) do
    local id, details = mark[1], mark[4]
    if not details.invalid then
      return id - 1 -- see M.origin_ns
    end
  end
  return nil
end

-- The view row of source row `src_row`: where its line is now, else, when
-- that line has been rewritten, where the next source line still there is.
---@param st inline_explorer.ViewState
---@param src_row integer 0-based
---@return integer row 0-based
function M.view_row(st, src_row)
  local last = vim.api.nvim_buf_line_count(st.bufnr) - 1
  local src_count = vim.api.nvim_buf_line_count(st.source_bufnr)
  for id = src_row + 1, src_count do
    local row, _, details = unpack(vim.api.nvim_buf_get_extmark_by_id(st.bufnr, M.origin_ns, id, { details = true }))
    if row and not details.invalid then
      return math.min(row, last)
    end
  end
  return math.min(src_row, last)
end

-- Expansion blocks. In functions that take (st, bufnr), bufnr is st.bufnr.

local function mark_row(bufnr, id)
  local row, _, details = unpack(vim.api.nvim_buf_get_extmark_by_id(bufnr, M.block_ns, id, { details = true }))
  if row and not details.invalid then
    return row
  end
  return nil
end

-- `block`'s first and last rows, or nil if either line has been replaced.
local function block_range(bufnr, block)
  local s, e = mark_row(bufnr, block.s_mark), mark_row(bufnr, block.e_mark)
  if s and e then
    return s, e
  end
  return nil
end

-- The blocks whose first and last lines are both still there, in st.blocks order.
---@param st inline_explorer.ViewState
---@param bufnr integer
---@return inline_explorer.BlockRange[]
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

local function undo_seq(bufnr)
  return vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.undotree().seq_cur
  end)
end

-- The view is 'nomodifiable', so every write goes through here.
---@param bufnr integer
---@param s integer first row, 0-based
---@param e integer end row, 0-based, exclusive
---@param lines string[]
function M.set_lines(bufnr, s, e, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, s, e, false, lines)
  vim.bo[bufnr].modifiable = false
end

-- Fold helpers act on the current window, which must show the view. They are
-- best effort: fold commands fail, for example, where 'foldmethod' is not manual.

local function delete_folds()
  pcall(vim.cmd, "silent! normal! zE")
end

local function create_open_fold(s, e)
  pcall(vim.cmd, string.format("%d,%dfold", s + 1, e + 1))
  pcall(vim.cmd, string.format("%d,%dfoldopen", s + 1, e + 1))
end

local function clear_blocks(st, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.block_ns, 0, -1)
  delete_folds()
  st.blocks = {}
end

-- Record rows s..e as block `name`, with an open fold in the current window,
-- which must show bufnr.
---@param st inline_explorer.ViewState
---@param bufnr integer
---@param name string
---@param s integer first row, 0-based
---@param e integer last row, 0-based, inclusive
function M.add_block(st, bufnr, name, s, e)
  st.blocks[#st.blocks + 1] = {
    name = name,
    s_mark = vim.api.nvim_buf_set_extmark(bufnr, M.block_ns, s, 0, { invalidate = true }),
    e_mark = vim.api.nvim_buf_set_extmark(bufnr, M.block_ns, e, 0, { invalidate = true }),
  }
  create_open_fold(s, e)
end

-- Setting 'undolevels', even to its own value, closes the undo block, so the
-- next edit starts a new undo step (:help undo-blocks).
local function start_undo_step(bufnr)
  vim.bo[bufnr].undolevels = vim.bo[bufnr].undolevels
end

-- Make what `fn` does with M.set_lines and M.add_block one undo step, and drop
-- the blocks whose first or last line it replaced. The new step is started
-- first: edits from separate callbacks would otherwise join the previous one.
--
-- Neovim's undo and redo (run by history.lua) restore the text and the origin
-- marks, but not st.blocks: redo re-inserts a block's lines without its marks,
-- and undo does not bring back the blocks dropped here. So the blocks of each
-- undo state are recorded in st.ranges_at, for M.restore_blocks().
---@param st inline_explorer.ViewState
---@param bufnr integer
---@param fn fun()
function M.change(st, bufnr, fn)
  start_undo_step(bufnr)
  fn()
  local kept = {}
  for _, block in ipairs(st.blocks) do
    if block_range(bufnr, block) then
      kept[#kept + 1] = block
    end
  end
  st.blocks = kept
  st.ranges_at[undo_seq(bufnr)] = M.block_ranges(st, bufnr)
end

-- After an undo or redo, rebuild the blocks recorded for the undo state reached.
---@param st inline_explorer.ViewState
---@param bufnr integer
function M.restore_blocks(st, bufnr)
  clear_blocks(st, bufnr)
  for _, range in ipairs(st.ranges_at[undo_seq(bufnr)] or {}) do
    M.add_block(st, bufnr, range.name, range.s, range.e)
  end
end

-- Re-entrancy guard: while a lookup is in flight for a view, M.begin_fetch()
-- refuses another, so two quick keypresses cannot interleave their splices.
-- It expires after guard_ms(), so a missed M.end_fetch() cannot lock a view.

-- Tests set this (ms) to override guard_ms().
M.FETCH_GUARD_MS = nil

-- resolver.fetch makes up to four requests in a row (locate, extract, chase,
-- extract), and either extract can be cold. 3 * timeout + max(cold, timeout)
-- covers them while cold <= timeout (the defaults are 2000 and 4000); one
-- second of slack is added. An inline that goes on to macro.fetch_expansion
-- adds up to 2000ms each for the tweak and the hover, which fits because
-- only a declaration is chased, and the inliner asks for no expansion of one.
local function guard_ms()
  if M.FETCH_GUARD_MS then
    return M.FETCH_GUARD_MS
  end
  local r = require("inline-explorer.resolver")
  return 3 * r._timeout_ms + math.max(r._cold_timeout_ms, r._timeout_ms) + 1000
end

---@param st inline_explorer.ViewState
---@return boolean taken false while an earlier lookup holds the guard
function M.begin_fetch(st)
  local now = vim.uv.now()
  if st.fetch_started and (now - st.fetch_started) < guard_ms() then
    return false
  end
  st.fetch_started = now
  return true
end

---@param st inline_explorer.ViewState
function M.end_fetch(st)
  st.fetch_started = nil
end

-- Replace the view's text with `new_src`, changing only the lines that
-- differ, so the others keep their origin and block marks. Then put the
-- cursor on `cursor_row`.
---@param st inline_explorer.ViewState
---@param bufnr integer
---@param new_src string
---@param cursor_row? integer 0-based, default 0
function M.rewrite(st, bufnr, new_src, cursor_row)
  local stop_timer = profile.start()
  local old_src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local new_lines = vim.split(new_src, "\n", { plain = true })
  -- vim.diff tells a last line without "\n" from the same line with one, so
  -- without the final "\n" appending would also replace the old last line.
  local hunks = vim.diff(old_src .. "\n", new_src .. "\n", { result_type = "indices" }) or {}
  M.change(st, bufnr, function()
    -- Bottom-up, so each hunk leaves the rows of the hunks above it unchanged.
    for i = #hunks, 1, -1 do
      local old_start, old_count, new_start, new_count = unpack(hunks[i])
      -- vim.diff counts rows from 1, but a pure insertion's old_start is the
      -- row it goes below (0: the top).
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
