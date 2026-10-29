-- The plugin's keymaps: the global ones, and those local to a reading view,
-- which a view gets when view.open fires User InlineExplorerViewOpen.
local config = require("inline-explorer.config")
local expander = require("inline-explorer.expander")
local history = require("inline-explorer.history")
local inliner = require("inline-explorer.inliner")
local nav = require("inline-explorer.nav")
local pick = require("inline-explorer.pick")
local trail = require("inline-explorer.trail")
local view = require("inline-explorer.view")

local M = {}

-- The keymaps local to view `buf`.
---@param buf integer
local function set_view_keymaps(buf)
  local km = config.options.keymaps or {}
  local maps = {
    { key = km.undo, fn = history.undo, desc = "undo expansion" },
    { key = km.redo, fn = history.redo, desc = "redo expansion" },
    { key = km.next_block, fn = nav.next, desc = "next expansion block" },
    { key = km.prev_block, fn = nav.prev, desc = "previous expansion block" },
    { key = km.list_blocks, fn = nav.list, desc = "list expansion blocks" },
    {
      key = km.callers,
      fn = function()
        pick.callers()
      end,
      desc = "callers of the function under the cursor",
    },
    {
      key = km.goto_def,
      fn = function()
        pick.definition()
      end,
      desc = "go to the definition, in a view of its file",
    },
    { key = km.trail_back, fn = trail.back, desc = "back along the trail" },
    { key = km.trail_forward, fn = trail.forward, desc = "forward along the trail" },
  }
  for _, map in ipairs(maps) do
    if map.key then
      vim.keymap.set("n", map.key, map.fn, { buffer = buf, desc = "Inline Explorer: " .. map.desc })
    end
  end
end

-- Maps the global keymaps of `keymaps` (config's), and has every reading
-- view opened from now on get its own.
---@param keymaps table
function M.setup(keymaps)
  local map = vim.keymap.set
  if keymaps.open then
    map("n", keymaps.open, view.open, { desc = "Inline Explorer: open reading view" })
  end
  if keymaps.close then
    map("n", keymaps.close, trail.close, { desc = "Inline Explorer: close reading view" })
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

  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("inline_explorer_keymaps", { clear = true }),
    pattern = "InlineExplorerViewOpen",
    callback = function(ev)
      set_view_keymaps(ev.data.buf)
    end,
  })
end

return M
