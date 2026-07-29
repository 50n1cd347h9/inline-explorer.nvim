local config = require("inline-explorer.config")
local view = require("inline-explorer.view")
local expander = require("inline-explorer.expander")
local inliner = require("inline-explorer.inliner")

local M = {}

function M.setup(opts)
  local o = config.setup(opts)

  vim.api.nvim_create_user_command("InlineExplorerOpen", view.open, { desc = "Open a reading view for the current file" })
  vim.api.nvim_create_user_command("InlineExplorerClose", view.close, { desc = "Close the reading view" })
  vim.api.nvim_create_user_command("InlineExplorerInline", inliner.smart, { desc = "Smart inline: substitute in place, else block-paste" })
  vim.api.nvim_create_user_command("InlineExplorerExpand", expander.expand, { desc = "Block-expand the symbol under the cursor (explicit; also macros)" })
  vim.api.nvim_create_user_command("InlineExplorerToggleMode", function()
    config.options.mode = (config.options.mode == "correct") and "readable" or "correct"
    vim.notify("[inline-explorer] substitution mode = " .. config.options.mode)
  end, { desc = "Toggle inline-substitution output between correct and readable" })
  local profile = require("inline-explorer.profile")
  profile.enabled = o.profile and true or false
  vim.api.nvim_create_user_command("InlineExplorerProfile", function(a)
    local arg = a.args ~= "" and a.args or "report"
    if arg == "on" or arg == "off" then
      profile.enabled = arg == "on"
      profile.clear()
      vim.notify(("[inline-explorer] profiling %s%s"):format(
        arg, (arg == "on" and profile.logfile) and (" -> " .. profile.logfile) or ""))
    elseif arg == "clear" then
      profile.clear(true) -- ring AND log file
      vim.notify("[inline-explorer] profile cleared")
    elseif arg == "path" then
      vim.notify("[inline-explorer] " .. (profile.logfile or "logging to file is disabled"))
    elseif arg == "open" then
      if profile.logfile then
        vim.cmd.tabedit(vim.fn.fnameescape(profile.logfile))
      else
        vim.notify("[inline-explorer] logging to file is disabled", vim.log.levels.WARN)
      end
    else
      vim.api.nvim_echo({ { profile.report() } }, true, {})
    end
  end, {
    nargs = "?",
    complete = function()
      return { "on", "off", "clear", "report", "path", "open" }
    end,
    desc = "Latency profile: on | off | clear | report (default) | path | open",
  })

  local nav = require("inline-explorer.nav")
  vim.api.nvim_create_user_command("InlineExplorerNext", nav.next, { desc = "Jump to the next expansion block" })
  vim.api.nvim_create_user_command("InlineExplorerPrev", nav.prev, { desc = "Jump to the previous expansion block" })
  vim.api.nvim_create_user_command("InlineExplorerList", nav.list, { desc = "List expansion blocks in the location list" })

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
  if km.toggle_fold then
    map("n", km.toggle_fold, "za", { desc = "Inline Explorer: toggle fold" })
  end
end

-- Statusline helper: names of the expansions the cursor is inside,
-- outermost first ("" outside a view). E.g.:
--   require("inline-explorer").breadcrumb()
function M.breadcrumb()
  return require("inline-explorer.nav").breadcrumb()
end

return M
