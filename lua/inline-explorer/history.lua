-- The undo and redo keys of a reading view: view.undo_step runs Neovim's own
-- :undo and :redo and rebuilds the expansion blocks; this says when there is
-- nothing to undo or redo.
local view = require("inline-explorer.view")
local util = require("inline-explorer.util")

local M = {}

local function step(cmd, nothing_to_do_msg)
  local st = view.current()
  if not st then
    return
  end
  if not view.undo_step(st, vim.api.nvim_get_current_buf(), cmd) then
    util.notify(nothing_to_do_msg, vim.log.levels.INFO)
  end
end

function M.undo()
  step("undo", "nothing to undo")
end

function M.redo()
  step("redo", "nothing to redo")
end

return M
