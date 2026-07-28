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
  vim.api.nvim_create_user_command("InlineExplorerInline", inliner.smart, { desc = "Smart inline: substitute in place, else block-paste" })
  vim.api.nvim_create_user_command("InlineExplorerExpand", expander.expand, { desc = "Block-expand the symbol under the cursor (explicit)" })
  vim.api.nvim_create_user_command("InlineExplorerExpandMacro", macro.expand, { desc = "Expand the macro under the cursor in place via clangd (C)" })
  vim.api.nvim_create_user_command("InlineExplorerToggleMode", function()
    config.options.mode = (config.options.mode == "correct") and "readable" or "correct"
    vim.notify("[inline-explorer] substitution mode = " .. config.options.mode)
  end, { desc = "Toggle inline-substitution output between correct and readable" })

  local map = vim.keymap.set
  local km = o.keymaps
  if km.open then
    map("n", km.open, view.open, { desc = "Inline Explorer: open reading view" })
  end
  if km.close then
    map("n", km.close, view.close, { desc = "Inline Explorer: close reading view" })
  end
  if km.substitute then
    map("n", km.substitute, inliner.smart, { desc = "Inline Explorer: smart inline (substitute, else block)" })
  end
  if km.expand then
    map("n", km.expand, expander.expand, { desc = "Inline Explorer: block-expand (explicit)" })
  end
  if km.expand_macro then
    map("n", km.expand_macro, macro.expand, { desc = "Inline Explorer: expand macro in place (C)" })
  end
  if km.toggle_fold then
    map("n", km.toggle_fold, "za", { desc = "Inline Explorer: toggle fold" })
  end
end

return M
