-- Navigation across expansion blocks: jump to the next/previous block start,
-- list every block in the location list, and a breadcrumb of the expansions
-- the cursor is inside (outermost first) for statuslines.
local view = require("inline-explorer.view")
local util = require("inline-explorer.util")

local M = {}

local function notify(msg)
  util.notify(msg, vim.log.levels.INFO)
end

-- Live blocks as sorted { s, e, name } (0-based rows, extmark-tracked).
local function blocks(st, bufnr)
  local out = view.block_ranges(st, bufnr)
  table.sort(out, function(a, b)
    return a.s < b.s
  end)
  return out
end

-- The view state, its buffer, and the cursor row (0-based); nil outside a view.
local function ctx()
  local st = view.current()
  if not st then
    return nil
  end
  return st, vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1] - 1
end

function M.next()
  local st, bufnr, row = ctx()
  if not st then
    return notify("not in a reading view")
  end
  for _, b in ipairs(blocks(st, bufnr)) do
    if b.s > row then
      return vim.api.nvim_win_set_cursor(0, { b.s + 1, 0 })
    end
  end
  notify("no expansion below")
end

function M.prev()
  local st, bufnr, row = ctx()
  if not st then
    return notify("not in a reading view")
  end
  local bs = blocks(st, bufnr)
  for i = #bs, 1, -1 do
    if bs[i].s < row then
      return vim.api.nvim_win_set_cursor(0, { bs[i].s + 1, 0 })
    end
  end
  notify("no expansion above")
end

-- Populate the location list with every expansion block.
function M.list()
  local st, bufnr = ctx()
  if not st then
    return notify("not in a reading view")
  end
  local items = {}
  for _, b in ipairs(blocks(st, bufnr)) do
    items[#items + 1] = {
      bufnr = bufnr,
      lnum = b.s + 1,
      text = string.format("%s (%d lines)", b.name, b.e - b.s + 1),
    }
  end
  if #items == 0 then
    return notify("no expansions")
  end
  vim.fn.setloclist(0, {}, " ", { title = "inline-explorer expansions", items = items })
  vim.cmd.lopen()
end

-- Names of the expansions containing the cursor, outermost first, joined
-- with " > ". Empty string outside a view -- statusline-safe.
function M.breadcrumb()
  local st, bufnr, row = ctx()
  if not st then
    return ""
  end
  local names = {}
  for _, b in ipairs(blocks(st, bufnr)) do
    if row >= b.s and row <= b.e then
      names[#names + 1] = b.name
    end
  end
  return table.concat(names, " > ")
end

return M
