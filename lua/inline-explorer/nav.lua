-- Navigation across expansion blocks: jump to the next or previous block's
-- first line, list every block in the location list, and name the blocks the
-- cursor is inside (outermost first) for statuslines.
local view = require("inline-explorer.view")
local util = require("inline-explorer.util")

local M = {}

local function notify(msg)
  util.notify(msg, vim.log.levels.INFO)
end

-- The expansion blocks still in the buffer (those whose first and last lines
-- were not replaced), sorted by first row. Each is
-- { name = expanded symbol, first_row, last_row }, with 0-based rows;
-- last_row is the block's last line, not the one after it.
local function sorted_blocks(st, bufnr)
  local blocks = {}
  for _, range in ipairs(view.block_ranges(st, bufnr)) do
    blocks[#blocks + 1] = { name = range.name, first_row = range.s, last_row = range.e }
  end
  table.sort(blocks, function(a, b)
    return a.first_row < b.first_row
  end)
  return blocks
end

-- The reading view the cursor is in. Returns its state, its buffer and the
-- cursor's row (0-based), or nil when the current buffer is not a view.
local function cursor_in_view()
  local st = view.current()
  if not st then
    return nil
  end
  return st, vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1] - 1
end

function M.next()
  local st, bufnr, cursor_row = cursor_in_view()
  if not st then
    notify("not in a reading view")
    return
  end
  for _, block in ipairs(sorted_blocks(st, bufnr)) do
    if block.first_row > cursor_row then
      vim.api.nvim_win_set_cursor(0, { block.first_row + 1, 0 })
      return
    end
  end
  notify("no expansion below")
end

function M.prev()
  local st, bufnr, cursor_row = cursor_in_view()
  if not st then
    notify("not in a reading view")
    return
  end
  local blocks = sorted_blocks(st, bufnr)
  for i = #blocks, 1, -1 do
    if blocks[i].first_row < cursor_row then
      vim.api.nvim_win_set_cursor(0, { blocks[i].first_row + 1, 0 })
      return
    end
  end
  notify("no expansion above")
end

-- Fill the location list with every expansion block and open it.
function M.list()
  local st, bufnr = cursor_in_view()
  if not st then
    notify("not in a reading view")
    return
  end
  local items = {}
  for _, block in ipairs(sorted_blocks(st, bufnr)) do
    items[#items + 1] = {
      bufnr = bufnr,
      lnum = block.first_row + 1,
      text = string.format("%s (%d lines)", block.name, block.last_row - block.first_row + 1),
    }
  end
  if #items == 0 then
    notify("no expansions")
    return
  end
  -- " " creates a new location list instead of replacing the current one.
  vim.fn.setloclist(0, {}, " ", { title = "inline-explorer expansions", items = items })
  vim.cmd.lopen()
end

-- The names of the blocks that contain the cursor, outermost first, joined
-- with " > ". Returns "" outside a reading view, so a statusline can call it
-- anywhere.
function M.breadcrumb()
  local st, bufnr, cursor_row = cursor_in_view()
  if not st then
    return ""
  end
  local names = {}
  for _, block in ipairs(sorted_blocks(st, bufnr)) do
    if cursor_row >= block.first_row and cursor_row <= block.last_row then
      names[#names + 1] = block.name
    end
  end
  return table.concat(names, " > ")
end

return M
