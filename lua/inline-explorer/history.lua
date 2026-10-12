-- Undo/redo for the reading view, on Neovim's own undo. Every change to the
-- view goes through view.change, which makes it one undo step; the view is
-- nomodifiable, so `u`/`<C-r>` lift that for the duration of the undo.
-- Undo restores the text and the origin marks; the expansion blocks are
-- rebuilt from what view.change recorded for the undo state reached.
local view = require("inline-explorer.view")
local util = require("inline-explorer.util")

local M = {}

-- Run `:undo` or `:redo` in the current view. Reports when there was
-- nothing to do -- the undo state did not move.
local function step(cmd, nothing)
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
    return util.notify(nothing, vim.log.levels.INFO)
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
