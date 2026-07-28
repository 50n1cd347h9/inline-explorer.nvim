-- Navigation across expansion blocks: jump to the next/previous block start,
-- list every block in the location list, and a breadcrumb of the expansions
-- the cursor is inside (outermost first) for statuslines.
local view = require("inline-explorer.view")

local M = {}

local function notify(msg)
  vim.notify("[inline-explorer] " .. msg, vim.log.levels.INFO)
end

-- Live blocks as sorted { s, e, name } (0-based rows, extmark-tracked).
local function blocks(st, bufnr)
  local out = {}
  for _, node in ipairs(st.nodes) do
    local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, view.ns, node.s_mark, {})
    local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, view.ns, node.e_mark, {})
    if s[1] and e[1] then
      out[#out + 1] = { s = s[1], e = e[1], name = node.name }
    end
  end
  table.sort(out, function(a, b)
    return a.s < b.s
  end)
  return out
end

function M.next()
  local st = view.current()
  if not st then
    return notify("not in a reading view")
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for _, b in ipairs(blocks(st, bufnr)) do
    if b.s > row then
      return vim.api.nvim_win_set_cursor(0, { b.s + 1, 0 })
    end
  end
  notify("no expansion below")
end

function M.prev()
  local st = view.current()
  if not st then
    return notify("not in a reading view")
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
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
  local st = view.current()
  if not st then
    return notify("not in a reading view")
  end
  local bufnr = vim.api.nvim_get_current_buf()
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
  local st = view.current()
  if not st then
    return ""
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local names = {}
  for _, b in ipairs(blocks(st, bufnr)) do
    if row >= b.s and row <= b.e then
      names[#names + 1] = b.name
    end
  end
  return table.concat(names, " > ")
end

return M
