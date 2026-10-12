-- Entry point. setup() validates the options, defines the user commands and
-- sets the global keymaps; breadcrumb() is the statusline helper.
local config = require("inline-explorer.config")
local view = require("inline-explorer.view")
local expander = require("inline-explorer.expander")
local inliner = require("inline-explorer.inliner")
local nav = require("inline-explorer.nav")
local pick = require("inline-explorer.pick")
local trail = require("inline-explorer.trail")
local profile = require("inline-explorer.profile")
local util = require("inline-explorer.util")

local M = {}

-- :InlineExplorerToggleMode switches config.options.mode, which the inliner
-- reads each time it substitutes.
local function toggle_mode()
  if config.options.mode == "correct" then
    config.options.mode = "readable"
  else
    config.options.mode = "correct"
  end
  util.notify("substitution mode = " .. config.options.mode)
end

-- :InlineExplorerProfile [on | off | clear | report | path | open]
local function run_profile_command(cmd)
  local sub = cmd.args
  if sub == "" then
    sub = "report"
  end
  if sub == "on" or sub == "off" then
    profile.enabled = sub == "on"
    -- Start the report afresh; the log file keeps its history.
    profile.clear()
    local msg = "profiling " .. sub
    if sub == "on" and profile.logfile then
      msg = msg .. " -> " .. profile.logfile
    end
    util.notify(msg)
  elseif sub == "clear" then
    -- true: empty the log file as well as the recorded spans.
    profile.clear(true)
    util.notify("profile cleared")
  elseif sub == "path" then
    util.notify(profile.logfile or "logging to file is disabled")
  elseif sub == "open" then
    if profile.logfile then
      vim.cmd.tabedit(vim.fn.fnameescape(profile.logfile))
    else
      util.notify("logging to file is disabled", vim.log.levels.WARN)
    end
  else -- "report", the default; an unknown argument also gets the report
    vim.api.nvim_echo({ { profile.report() } }, true, {})
  end
end

function M.setup(opts)
  -- The validated options merged over the defaults: the table config.options holds.
  local options = config.setup(opts)
  profile.enabled = options.profile

  local command = vim.api.nvim_create_user_command
  command("InlineExplorerOpen", view.open, { desc = "Open a reading view for the current file" })
  command("InlineExplorerClose", view.close, { desc = "Close the reading view" })
  command("InlineExplorerInline", inliner.smart, {
    desc = "Inline the call or macro under the cursor in place (C only); else do what InlineExplorerExpand does",
  })
  command("InlineExplorerExpand", expander.expand, {
    desc = "Insert the definition of the symbol under the cursor as a block below its statement (macros too)",
  })
  command("InlineExplorerToggleMode", toggle_mode, {
    desc = "Toggle inline output between correct (always compiles; may use ({...}) and goto)"
      .. " and readable (avoids both; may not compile)",
  })
  command("InlineExplorerProfile", run_profile_command, {
    nargs = "?",
    complete = function()
      return { "on", "off", "clear", "report", "path", "open" }
    end,
    desc = "Latency profile: on | off | clear | report (default) | path | open",
  })
  command("InlineExplorerNext", nav.next, { desc = "Jump to the next expansion block" })
  command("InlineExplorerPrev", nav.prev, { desc = "Jump to the previous expansion block" })
  command("InlineExplorerList", nav.list, { desc = "List expansion blocks in the location list" })
  -- Wrapped: pick.callers takes a completion callback as its first parameter,
  -- so it must not receive the command's argument table.
  command("InlineExplorerCallers", function()
    pick.callers()
  end, { desc = "Pick a caller of the function under the cursor and go there" })
  command("InlineExplorerTrail", trail.list, { desc = "List the navigation trail in the location list" })

  -- Global keymaps only. The keymaps that work inside a reading view (undo,
  -- block navigation, callers, gd, the trail) are set by view.open().
  local map = vim.keymap.set
  local keymaps = options.keymaps
  if keymaps.open then
    map("n", keymaps.open, view.open, { desc = "Inline Explorer: open reading view" })
  end
  if keymaps.close then
    map("n", keymaps.close, view.close, { desc = "Inline Explorer: close reading view" })
  end
  if keymaps.substitute then
    map("n", keymaps.substitute, inliner.smart, { desc = "Inline Explorer: inline in place, else expand as a block" })
  end
  if keymaps.expand then
    map("n", keymaps.expand, expander.expand, { desc = "Inline Explorer: expand the definition as a block" })
  end
  if keymaps.toggle_fold then
    map("n", keymaps.toggle_fold, "za", { desc = "Inline Explorer: toggle fold" })
  end
end

-- Statusline helper: the names of the expansion blocks that contain the
-- cursor, outermost first, joined with " > " (for example "outer > inner").
-- Returns "" outside a reading view. Call it as
-- require("inline-explorer").breadcrumb().
function M.breadcrumb()
  return nav.breadcrumb()
end

return M
