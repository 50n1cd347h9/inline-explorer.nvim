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
local util = require("inline-explorer.util")

local M = {}

-- Entries are { buf = view_bufnr, cursor = { row, col } }. _pos is the
-- index of the entry the window currently shows; entries above _pos are
-- forward history. Capacity is a module field so tests can shrink it.
M._stack = {}
M._pos = 0
M._stack_max = 8

local function wipe(buf)
  -- The state entry goes unconditionally: an INVALID buffer's entry is
  -- exactly the leak -- the buffer died (e.g. a :b switch wiped a fresh
  -- view) but the entry, with its full origin array and undo snapshots,
  -- stayed behind a validity guard that skipped it forever.
  if not vim.api.nvim_buf_is_valid(buf) then
    view.forget(buf)
    return
  end
  if #vim.fn.win_findbuf(buf) == 0 then
    view.forget(buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

-- Drop everything and wipe every view that is not on screen -- including
-- views that fell out of forward history and so appear in view.state but
-- no longer on the stack. Without sweeping view.state those would outlive
-- the journey they belonged to.
function M.clear()
  for v in pairs(view.state) do
    wipe(v)
  end
  local cur = vim.api.nvim_get_current_buf()
  M._stack, M._pos = {}, 0
  -- The view being looked at survives clear(); closing it is view.close's
  -- job, not the trail's.
  if view.is_view(cur) then
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
  if not view.is_view(cur) then
    return
  end
  -- A new navigation from a back-state drops forward history -- browser and
  -- jumplist rule. The ENTRIES are dropped; the buffers are not wiped. The
  -- spec wipes only on depth eviction and on close, and for good reason: a
  -- view that fell out of forward history is still the reuse target the
  -- next time its file is visited, expansions intact. clear() reclaims
  -- whatever never gets revisited.
  for i = #M._stack, M._pos + 1, -1 do
    table.remove(M._stack, i)
  end
  vim.bo[cur].bufhidden = "hide" -- survives leaving the window while stacked
  local c = vim.api.nvim_win_get_cursor(0)
  M._stack[#M._stack + 1] = { buf = cur, cursor = c }
  M._pos = #M._stack
  -- Depth cap: evict from the bottom. An evicted buffer may still appear
  -- higher in the stack (buffer reuse), so only wipe it when it does not.
  while #M._stack > M._stack_max do
    local e = table.remove(M._stack, 1)
    M._pos = M._pos - 1
    local still_referenced = false
    for _, r in ipairs(M._stack) do
      if r.buf == e.buf then
        still_referenced = true
        break
      end
    end
    -- wipe() spares any buffer on screen, the current one included.
    if not still_referenced then
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
    util.notify("cannot read " .. path, vim.log.levels.WARN)
    return false
  end

  -- Entering trail-land from a plain buffer opens its view first, so the
  -- journey is view-to-view from the very first hop.
  local cur = vim.api.nvim_get_current_buf()
  if not view.is_view(cur) and vim.api.nvim_buf_get_name(cur) ~= "" then
    view.open()
  end
  push_current()

  local sb = vim.fn.bufadd(path)
  vim.fn.bufload(sb)
  local target = view_of(sb) or view.open(sb)
  vim.api.nvim_set_current_buf(target)
  vim.bo[target].bufhidden = "hide" -- stacked or shown, it must survive switches
  -- An LSP location counts in its server's encoding; the cursor in bytes.
  local row = loc.range.start.line
  local line = vim.api.nvim_buf_get_lines(sb, row, row + 1, false)[1] or ""
  pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, util.byte_col(line, loc.range.start.character, loc.encoding) })
  return true
end

local function step(delta, edge_msg)
  local target = M._pos + delta
  if target < 1 or target > #M._stack then
    util.notify(edge_msg, vim.log.levels.INFO)
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
    util.notify("that view is gone", vim.log.levels.WARN)
    return false
  end
  M._pos = target
  return true
end

function M.back()
  -- The shown view may sit ABOVE _pos (it was never pushed -- pushing
  -- happens on leaving). Entering back-navigation pushes it so forward can
  -- return to it.
  -- It is the same push as leaving's, depth cap included; a hand copy here
  -- once skipped the cap and grew a full stack past it.
  local cur = vim.api.nvim_get_current_buf()
  if M._stack[M._pos] == nil or M._stack[M._pos].buf ~= cur then
    push_current()
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
