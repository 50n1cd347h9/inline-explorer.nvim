-- Trail: the reading views that the window has visited through definition
-- and caller jumps, kept as a stack so that back() and forward() can step
-- through them like a browser's history. (Moving between expansion blocks
-- inside one view is nav.lua's job.)
--
-- goto_location() switches the window to the reading view of a target file
-- and pushes the view it leaves. A view on the stack stays alive
-- (bufhidden=hide) when no window shows it, so going back shows the same
-- buffer with its expansions, folds and undo history intact. The trail wipes
-- a view only when the view's last entry is evicted from a full stack or
-- when clear() empties the trail, and never while a window shows it.
local view = require("inline-explorer.view")
local util = require("inline-explorer.util")

local M = {}

-- Entries are { buf = view_bufnr, cursor = { row, col } }, oldest first, with
-- the cursor as nvim_win_get_cursor() returns it (1-based row, 0-based col).
-- A view is pushed when the window leaves it, so right after goto_location()
-- the view on screen is not on the stack, and _pos is the entry just left
-- (the top one). back() first pushes the view on screen if it is not there
-- yet; from then on, while stepping back and forward, _pos is the entry on
-- screen and the entries above it are forward history.
M._stack = {}
M._pos = 0
-- The most entries the stack holds; a push beyond it evicts the oldest
-- entry. It is a module field so that tests can lower it.
M._stack_max = 8

-- Forget view `buf` and wipe its buffer, unless a window shows it. A buffer
-- that no longer exists just loses its state entry.
local function wipe_unless_shown(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    view.forget(buf)
    return
  end
  if #vim.fn.win_findbuf(buf) == 0 then
    view.forget(buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

-- Empty the trail and wipe every reading view that no window shows. This
-- covers all of view.state, not only the views on the stack: a view dropped
-- from forward history is still in view.state, and would otherwise outlive
-- the trail it belonged to.
function M.clear()
  for v in pairs(view.state) do
    wipe_unless_shown(v)
  end
  local cur = vim.api.nvim_get_current_buf()
  M._stack, M._pos = {}, 0
  -- The view on screen is not wiped here (closing it is view.close's job),
  -- but the stack no longer protects it: go back to bufhidden=wipe, so that
  -- it is wiped once the window leaves it.
  if view.is_view(cur) then
    vim.bo[cur].bufhidden = "wipe"
  end
end

-- The existing view of source buffer `source_buf`, if there is one. Visiting
-- a file that already has a view reuses that buffer (expansions intact) but
-- still pushes a new entry; it does not jump back to the old one. So one
-- buffer can sit at several stack positions.
local function view_of(source_buf)
  for v, st in pairs(view.state) do
    if st.source_bufnr == source_buf and vim.api.nvim_buf_is_valid(v) then
      return v
    end
  end
end

-- Whether any stack entry is for buffer `buf`.
local function on_stack(buf)
  for _, entry in ipairs(M._stack) do
    if entry.buf == buf then
      return true
    end
  end
  return false
end

-- Push the view on screen: drop forward history, keep the view alive while
-- it is stacked, and evict from the bottom beyond _stack_max. Does nothing if
-- the current buffer is not a view.
local function push_current()
  local cur = vim.api.nvim_get_current_buf()
  if not view.is_view(cur) then
    return
  end
  -- Navigating after going back drops forward history, as in a browser or
  -- the jumplist. Only the entries go; the buffers stay, so a dropped view is
  -- reused (expansions intact) if its file is visited again. clear() wipes
  -- the ones never revisited.
  for i = #M._stack, M._pos + 1, -1 do
    table.remove(M._stack, i)
  end
  vim.bo[cur].bufhidden = "hide" -- keep the buffer when the window leaves it
  M._stack[#M._stack + 1] = { buf = cur, cursor = vim.api.nvim_win_get_cursor(0) }
  M._pos = #M._stack
  while #M._stack > M._stack_max do
    local evicted = table.remove(M._stack, 1)
    M._pos = M._pos - 1
    -- One buffer can be stacked more than once: wipe it only when its last
    -- entry is gone.
    if not on_stack(evicted.buf) then
      wipe_unless_shown(evicted.buf)
    end
  end
end

-- Show the view of `entry` in the current window, at the entry's cursor.
-- Returns false if the buffer no longer exists.
local function show(entry)
  if not vim.api.nvim_buf_is_valid(entry.buf) then
    return false
  end
  vim.api.nvim_set_current_buf(entry.buf)
  pcall(vim.api.nvim_win_set_cursor, 0, entry.cursor)
  return true
end

-- Switch the window to the reading view of `loc`'s file, with the cursor at
-- `loc`, push the view the window leaves, and return true. `loc` is
-- { uri, range, encoding }: an LSP Location plus the position encoding of the
-- server that sent it (nil means byte columns). If the file cannot be read,
-- return false and leave the window and the stack as they are.
function M.goto_location(loc)
  local path = vim.uri_to_fname(loc.uri)
  if vim.fn.filereadable(path) == 0 then
    util.notify("cannot read " .. path, vim.log.levels.WARN)
    return false
  end

  -- If the current buffer is a plain file, open its view first, so that
  -- push_current() puts the file on the stack and back() can return to it.
  local cur = vim.api.nvim_get_current_buf()
  if not view.is_view(cur) and vim.api.nvim_buf_get_name(cur) ~= "" then
    view.open()
  end
  push_current()

  local src_buf = vim.fn.bufadd(path)
  vim.fn.bufload(src_buf)
  local target = view_of(src_buf) or view.open(src_buf)
  vim.api.nvim_set_current_buf(target)
  -- Stacked or only shown, a view on the trail must survive buffer switches.
  vim.bo[target].bufhidden = "hide"
  -- LSP columns are counted in the server's position encoding; the cursor
  -- needs a byte column.
  local row = loc.range.start.line
  local line = vim.api.nvim_buf_get_lines(src_buf, row, row + 1, false)[1] or ""
  pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, util.byte_col(line, loc.range.start.character, loc.encoding) })
  return true
end

-- Move `delta` entries along the stack (-1 is back, +1 is forward), show that
-- entry's view, and return true. At either end of the stack, notify
-- `edge_msg` and return false; also return false if that view is gone.
local function step(delta, edge_msg)
  local target = M._pos + delta
  if target < 1 or target > #M._stack then
    util.notify(edge_msg, vim.log.levels.INFO)
    return false
  end
  -- Save the cursor of the entry on screen, so that returning to it restores
  -- the position. (back() has already pushed it if it was not on the stack.)
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

-- Step back along the trail. Returns true if the window moved.
function M.back()
  -- If the view on screen is not the entry at _pos (as right after
  -- goto_location(), since views are pushed when left), push it with
  -- push_current(), as goto_location() does, so forward() can return to it.
  local cur = vim.api.nvim_get_current_buf()
  if M._stack[M._pos] == nil or M._stack[M._pos].buf ~= cur then
    push_current()
  end
  return step(-1, "already at the start of the trail")
end

-- Step forward along the trail. Returns true if the window moved.
function M.forward()
  return step(1, "already at the end of the trail")
end

-- Show the trail in the location list, each entry under its source file's
-- name; "> " marks the entry at _pos.
function M.list()
  local items = {}
  for i, entry in ipairs(M._stack) do
    if vim.api.nvim_buf_is_valid(entry.buf) then
      local st = view.state[entry.buf]
      local name = st and vim.api.nvim_buf_get_name(st.source_bufnr) or vim.api.nvim_buf_get_name(entry.buf)
      items[#items + 1] = {
        bufnr = entry.buf,
        lnum = entry.cursor[1],
        col = entry.cursor[2] + 1,
        text = ((i == M._pos) and "> " or "  ") .. vim.fn.fnamemodify(name, ":t"),
      }
    end
  end
  vim.fn.setloclist(0, items)
  vim.cmd("lopen")
end

return M
