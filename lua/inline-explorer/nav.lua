-- Moving between the expansion blocks of a reading view: next and previous,
-- the location list, and the statusline breadcrumb.
local view = require("inline-explorer.view")
local util = require("inline-explorer.util")

local M = {}

local function notify(msg)
  util.notify(msg, vim.log.levels.INFO)
end

-- view.block_ranges, sorted by first row. Rows are 0-based and inclusive.
---@return { name: string, first_row: integer, last_row: integer }[]
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

---@return inline_explorer.ViewState? st nil outside a reading view
---@return integer? bufnr
---@return integer? cursor_row 0-based
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
  vim.fn.setloclist(0, {}, " ", { title = "inline-explorer expansions", items = items })
  vim.cmd.lopen()
end

-- The names of the blocks around the cursor, outermost first, joined with
-- " > "; "" outside a reading view.
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
