local config = require("inline-explorer.config")
local view = require("inline-explorer.view")
local expander = require("inline-explorer.expander")

local M = {}

function M.setup(opts)
  local o = config.setup(opts)

  vim.api.nvim_create_user_command("InlineExplorerOpen", view.open, { desc = "Open a reading view for the current file" })
  vim.api.nvim_create_user_command("InlineExplorerClose", view.close, { desc = "Close the reading view" })
  vim.api.nvim_create_user_command("InlineExplorerExpand", expander.expand, { desc = "Expand the symbol under the cursor" })

  local map = vim.keymap.set
  local km = o.keymaps
  if km.open then
    map("n", km.open, view.open, { desc = "Inline Explorer: open reading view" })
  end
  if km.close then
    map("n", km.close, view.close, { desc = "Inline Explorer: close reading view" })
  end
  if km.expand then
    map("n", km.expand, expander.expand, { desc = "Inline Explorer: expand symbol" })
  end
  if km.toggle_fold then
    map("n", km.toggle_fold, "za", { desc = "Inline Explorer: toggle fold" })
  end
end

return M
