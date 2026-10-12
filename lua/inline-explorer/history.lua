-- Undo and redo in the reading view, built on Neovim's own undo tree.
-- view.change() makes each edit of the view one undo step. The view buffer is
-- 'nomodifiable', so step() makes it modifiable only while :undo or :redo
-- runs. Neovim restores the text and the origin marks (the extmarks that tie
-- each view line to its source line); view.restore_blocks() then rebuilds
-- the expansion blocks recorded for the undo state reached.
local view = require("inline-explorer.view")
local util = require("inline-explorer.util")

local M = {}

-- Run `cmd` ("undo" or "redo") in the current view and rebuild its blocks.
-- When the undo state does not move, report `nothing_to_do_msg` instead.
local function step(cmd, nothing_to_do_msg)
  local st = view.current()
  if not st then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local before = vim.fn.undotree().seq_cur
  vim.bo[bufnr].modifiable = true
  pcall(vim.cmd, "silent " .. cmd)
  vim.bo[bufnr].modifiable = false
  if vim.fn.undotree().seq_cur == before then
    util.notify(nothing_to_do_msg, vim.log.levels.INFO)
    return
  end
  view.restore_blocks(st, bufnr)
end

function M.undo()
  step("undo", "nothing to undo")
end

function M.redo()
  step("redo", "nothing to redo")
end

return M
