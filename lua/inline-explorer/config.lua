-- Options: the defaults, their validation, and the options in effect.
local util = require("inline-explorer.util")

local M = {}

M.defaults = {
  keymaps = {
    -- Global keymaps, which init.lua's setup() maps.

    -- Inline the call or macro under the cursor in place (C only), else expand.
    substitute = "<leader>ei",
    -- Insert the definition of the symbol under the cursor below its statement,
    -- as a foldable block (any language, macros too).
    expand = "<leader>ee",
    toggle_fold = "<leader>ec", -- fold or unfold the expansion under the cursor
    open = "<leader>eo", -- open a reading view for the current file
    close = "<leader>eq", -- close the reading view

    -- Keymaps local to a reading view.

    undo = "u", -- undo the last expansion or inline
    redo = "<C-r>", -- redo what undo took back
    next_block = "]e", -- jump to the next expansion block
    prev_block = "[e", -- jump to the previous expansion block
    list_blocks = "<leader>el", -- list the expansion blocks in the location list
    callers = "<leader>eu", -- pick a caller of the function under the cursor and go there
    -- The language server's hover for the name under the cursor, as K is in a file.
    hover = "K",
    -- Go to the definition, in a reading view of its file; the view you leave
    -- goes on the navigation trail.
    goto_def = "gd",
    trail_back = "<C-o>", -- back along the navigation trail
    trail_forward = "<C-i>", -- forward along the navigation trail
  },
  indent = "  ", -- extra indent of an expansion, relative to its statement
  header = true, -- wrap each expansion in `/* v name (label) */ ... /* ^ name */`
  -- Inline substitution style. "correct" uses ({...}), goto and block wrapping
  -- where needed, aiming for output that compiles and behaves like the call.
  -- "readable" avoids ({...}) and goto, and with early returns, labels or
  -- short-circuits may not compile or behave the same.
  mode = "correct",
  profile = false, -- record how long each stage takes; see :InlineExplorerProfile
}

-- The options in effect; setup() replaces the table.
M.options = vim.deepcopy(M.defaults)

local function check(opts)
  local types = { keymaps = "table", indent = "string", header = "boolean", profile = "boolean" }
  for name, expected in pairs(types) do
    vim.validate("inline-explorer." .. name, opts[name], expected, true)
  end
  vim.validate("inline-explorer.mode", opts.mode, function(v)
    return v == "correct" or v == "readable"
  end, true, '"correct" or "readable"')
  for k in pairs(opts) do
    if M.defaults[k] == nil then
      util.notify(("unknown option '%s' (typo?)"):format(k), vim.log.levels.WARN)
    end
  end
  for k in pairs(type(opts.keymaps) == "table" and opts.keymaps or {}) do
    if M.defaults.keymaps[k] == nil then
      util.notify(("unknown keymap '%s' (typo?)"):format(k), vim.log.levels.WARN)
    end
  end
end

-- Switches the inline mode between "correct" and "readable".
function M.toggle_mode()
  M.options.mode = M.options.mode == "correct" and "readable" or "correct"
  util.notify("substitution mode = " .. M.options.mode)
end

---@param opts? table
---@return table options
function M.setup(opts)
  opts = opts or {}
  check(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  return M.options
end

return M
