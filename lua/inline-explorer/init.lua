local config = require("inline-explorer.config")
local view = require("inline-explorer.view")
local expander = require("inline-explorer.expander")
local inliner = require("inline-explorer.inliner")
local macro = require("inline-explorer.macro")

local M = {}

function M.setup(opts)
  local o = config.setup(opts)

  vim.api.nvim_create_user_command("InlineExplorerOpen", view.open, { desc = "Open a reading view for the current file" })
  vim.api.nvim_create_user_command("InlineExplorerClose", view.close, { desc = "Close the reading view" })
  vim.api.nvim_create_user_command("InlineExplorerExpand", expander.expand, { desc = "Expand the symbol under the cursor" })
  vim.api.nvim_create_user_command("InlineExplorerSubstitute", inliner.substitute, { desc = "Inline-substitute the call under the cursor (C only)" })
  vim.api.nvim_create_user_command("InlineExplorerExpandMacro", macro.expand, { desc = "Expand the macro under the cursor via clangd (C)" })

  local map = vim.keymap.set
  local km = o.keymaps
  if km.open then
    map("n", km.open, view.open, { desc = "Inline Explorer: open reading view" })
  end
  if km.close then
    map("n", km.close, view.close, { desc = "Inline Explorer: close reading view" })
  end
  if km.expand then
    map("n", km.expand, expander.expand, { desc = "Inline Explorer: expand symbol (block)" })
  end
  if km.substitute then
    map("n", km.substitute, inliner.substitute, { desc = "Inline Explorer: inline-substitute call (C)" })
  end
  if km.expand_macro then
    map("n", km.expand_macro, macro.expand, { desc = "Inline Explorer: expand macro (C)" })
  end
  if km.toggle_fold then
    map("n", km.toggle_fold, "za", { desc = "Inline Explorer: toggle fold" })
  end
end

return M
