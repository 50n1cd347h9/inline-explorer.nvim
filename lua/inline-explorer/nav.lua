-- Moving between the expansion blocks of a reading view: next and previous,
-- the location list, and the statusline breadcrumb.
local view = require("inline-explorer.view")
local util = require("inline-explorer.util")

local M = {}

local function notify(msg)
  util.notify(msg, vim.log.levels.INFO)
end

-- view.block_ranges, sorted by first row.
local function sorted_blocks(st, bufnr)
  local blocks = view.block_ranges(st, bufnr)
  table.sort(blocks, function(a, b)
    return a.s < b.s
  end)
  return blocks
end

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
    if block.s > cursor_row then
      vim.api.nvim_win_set_cursor(0, { block.s + 1, 0 })
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
    if blocks[i].s < cursor_row then
      vim.api.nvim_win_set_cursor(0, { blocks[i].s + 1, 0 })
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
      lnum = block.s + 1,
      text = string.format("%s (%d lines)", block.name, block.e - block.s + 1),
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
---@return string
function M.breadcrumb()
  local st, bufnr, cursor_row = cursor_in_view()
  if not st then
    return ""
  end
  local names = {}
  for _, block in ipairs(view.blocks_at(st, bufnr, cursor_row)) do
    names[#names + 1] = block.name
  end
  return table.concat(names, " > ")
end

return M
