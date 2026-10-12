-- Options: the defaults, their validation, and the options in effect.
local util = require("inline-explorer.util")

local M = {}

M.defaults = {
  keymaps = {
    -- Global keymaps, set by setup().

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

-- Checked by hand: vim.validate's 0.11 form does not exist in 0.10, and its
-- 0.10 form is deprecated in 0.11.
local function check(opts)
  local types = { keymaps = "table", indent = "string", header = "boolean", mode = "string", profile = "boolean" }
  for name, expected in pairs(types) do
    if opts[name] ~= nil and type(opts[name]) ~= expected then
      error(("inline-explorer: option '%s' must be a %s"):format(name, expected), 0)
    end
  end
  if opts.mode ~= nil and opts.mode ~= "correct" and opts.mode ~= "readable" then
    error('inline-explorer: mode must be "correct" or "readable"', 0)
  end
  for k in pairs(opts) do
    if M.defaults[k] == nil then
      util.notify(("unknown option '%s' (typo?)"):format(k), vim.log.levels.WARN)
    end
  end
end

function M.setup(opts)
  opts = opts or {}
  check(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  return M.options
end

return M
