-- Entry point: setup(), which registers the commands and the keymaps, and
-- the statusline helper breadcrumb().
local config = require("inline-explorer.config")
local view = require("inline-explorer.view")
local expander = require("inline-explorer.expander")
local inliner = require("inline-explorer.inliner")
local keymaps = require("inline-explorer.keymaps")
local nav = require("inline-explorer.nav")
local pick = require("inline-explorer.pick")
local trail = require("inline-explorer.trail")
local profile = require("inline-explorer.profile")
local util = require("inline-explorer.util")

local M = {}

---@param opts? table overrides of config.defaults
function M.setup(opts)
  if vim.fn.has("nvim-0.11") == 0 then
    util.notify("Neovim 0.11+ is required", vim.log.levels.ERROR)
    return
  end
  local options = config.setup(opts)
  profile.enabled = options.profile

  local command = vim.api.nvim_create_user_command
  command("InlineExplorerOpen", view.open, { desc = "Open a reading view for the current file" })
  command("InlineExplorerClose", trail.close, { desc = "Close the reading view" })
  command("InlineExplorerInline", inliner.smart, {
    desc = "Inline the call or macro under the cursor in place (C only); else do what InlineExplorerExpand does",
  })
  command("InlineExplorerExpand", expander.expand, {
    desc = "Insert the definition of the symbol under the cursor as a block below its statement (macros too)",
  })
  command("InlineExplorerToggleMode", config.toggle_mode, {
    desc = "Toggle inline output between correct (always compiles; may use ({...}) and goto)"
      .. " and readable (avoids both; may not compile)",
  })
  command("InlineExplorerProfile", function(cmd)
    profile.command(cmd.args)
  end, {
    nargs = "?",
    complete = function()
      return { "on", "off", "clear", "report", "path", "open" }
    end,
    desc = "Latency profile: on | off | clear | report (default) | path | open",
  })
  command("InlineExplorerNext", nav.next, { desc = "Jump to the next expansion block" })
  command("InlineExplorerPrev", nav.prev, { desc = "Jump to the previous expansion block" })
  command("InlineExplorerList", nav.list, { desc = "List expansion blocks in the location list" })
  -- Wrapped, so that pick.callers does not take the command's argument table as done_cb.
  command("InlineExplorerCallers", function()
    pick.callers()
  end, { desc = "Pick a caller of the function under the cursor and go there" })
  command("InlineExplorerTrail", trail.list, { desc = "List the navigation trail in the location list" })

  keymaps.setup(options.keymaps)
end

-- See nav.breadcrumb.
---@return string
function M.breadcrumb()
  return nav.breadcrumb()
end

return M
