-- Undo and redo in a reading view: Neovim's own :undo and :redo, after which
-- view.restore_blocks() rebuilds the expansion blocks.
local view = require("inline-explorer.view")
local util = require("inline-explorer.util")

local M = {}

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
