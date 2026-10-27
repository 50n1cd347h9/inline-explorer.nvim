-- Trail: the reading views visited through definition and caller jumps, as a
-- stack that back() and forward() step through like a browser's history.
-- Stacked views stay alive (bufhidden=hide) while hidden, so going back finds
-- their expansions, folds and undo history intact. The trail wipes a view only
-- when its last entry is evicted or on clear(), never while a window shows it.
local view = require("inline-explorer.view")
local util = require("inline-explorer.util")

local M = {}

---@class inline_explorer.TrailEntry
---@field buf integer the view buffer
---@field cursor integer[] { row, col }, 1-based row and 0-based col

-- The stack, oldest first. A revisited file reuses its view, so one buffer can
-- have several entries. A view is pushed when the window leaves it: right after
-- goto_location(), _pos is the top entry, the view just left, not the one on
-- screen. back() first pushes the view on screen; from then on _pos is the
-- entry on screen, and the entries above it are forward history.
---@type inline_explorer.TrailEntry[]
M._stack = {}
M._pos = 0
-- The most entries; a module field so that tests can lower it.
M._stack_max = 8

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

-- Empty the trail and wipe every view in view.state that no window shows, not
-- only the stacked ones: a view dropped from forward history would otherwise
-- outlive the trail.
function M.clear()
  for v in pairs(view.state) do
    wipe_unless_shown(v)
  end
  local cur = vim.api.nvim_get_current_buf()
  M._stack, M._pos = {}, 0
  -- The stack no longer protects the view on screen: let it be wiped once the
  -- window leaves it.
  if view.is_view(cur) then
    vim.bo[cur].bufhidden = "wipe"
  end
end

local function view_of(source_buf)
  for v, st in pairs(view.state) do
    if st.source_bufnr == source_buf and vim.api.nvim_buf_is_valid(v) then
      return v
    end
  end
end

local function on_stack(buf)
  for _, entry in ipairs(M._stack) do
    if entry.buf == buf then
      return true
    end
  end
  return false
end

local function push_current()
  local cur = vim.api.nvim_get_current_buf()
  if not view.is_view(cur) then
    return
  end
  -- Pushing after going back drops forward history, as in a browser. Only the
  -- entries go: their views are reused if their file is visited again.
  for i = #M._stack, M._pos + 1, -1 do
    table.remove(M._stack, i)
  end
  vim.bo[cur].bufhidden = "hide"
  M._stack[#M._stack + 1] = { buf = cur, cursor = vim.api.nvim_win_get_cursor(0) }
  M._pos = #M._stack
  while #M._stack > M._stack_max do
    local evicted = table.remove(M._stack, 1)
    M._pos = M._pos - 1
    if not on_stack(evicted.buf) then
      wipe_unless_shown(evicted.buf)
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

-- A file a jump opens gets the servers of the file the jump came from when
-- it has none, as a FileType autostart would give it: lookups from its view
-- go through them.
local function share_clients(from, to)
  if from == to or #vim.lsp.get_clients({ bufnr = to }) > 0 then
    return
  end
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = from })) do
    vim.lsp.buf_attach_client(to, client.id)
  end
end

-- Show the reading view of `loc`'s file in the current window, on the view
-- row that holds `loc`'s source row, and push the view the window leaves.
---@param loc inline_explorer.Loc|inline_explorer.CallerItem
---@return boolean ok false, changing nothing, if the file cannot be read
function M.goto_location(loc)
  local path = vim.uri_to_fname(loc.uri)
  if vim.fn.filereadable(path) == 0 then
    util.notify("cannot read " .. path, vim.log.levels.WARN)
    return false
  end

  -- From a plain file, open its view first, so that push_current() stacks the
  -- file and back() can return to it.
  local cur = vim.api.nvim_get_current_buf()
  local from = view.state[cur] and view.state[cur].source_bufnr or cur
  if not view.is_view(cur) and vim.api.nvim_buf_get_name(cur) ~= "" then
    view.open()
  end
  push_current()

  local src_buf = vim.fn.bufadd(path)
  vim.fn.bufload(src_buf)
  share_clients(from, src_buf)
  local target = view_of(src_buf) or view.open(src_buf)
  vim.api.nvim_set_current_buf(target)
  -- Stacked or only shown, a view on the trail must survive buffer switches.
  vim.bo[target].bufhidden = "hide"
  -- Expansions above loc's line in a reused view move it down.
  local row = view.view_row(view.state[target], loc.range.start.line)
  local line = vim.api.nvim_buf_get_lines(target, row, row + 1, false)[1] or ""
  pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, util.byte_col(line, loc.range.start.character, loc.encoding) })
  return true
end

local function step(delta, edge_msg)
  local target = M._pos + delta
  if target < 1 or target > #M._stack then
    util.notify(edge_msg, vim.log.levels.INFO)
    return false
  end
  -- Save the cursor of the entry on screen, to restore it on return.
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

---@return boolean moved
function M.back()
  -- So that forward() can return to the view on screen (see M._stack).
  local cur = vim.api.nvim_get_current_buf()
  if M._stack[M._pos] == nil or M._stack[M._pos].buf ~= cur then
    push_current()
  end
  return step(-1, "already at the start of the trail")
end

---@return boolean moved
function M.forward()
  return step(1, "already at the end of the trail")
end

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
