-- Options: the defaults, their validation, and the options in effect.
local util = require("inline-explorer.util")

local M = {}

M.defaults = {
  keymaps = {
    -- Global keymaps, set by setup().

    -- Inline the call or macro under the cursor in place (C only). Where that
    -- is not possible, and in other languages, does what `expand` does.
    substitute = "<leader>ei",
    -- Insert the definition of the symbol under the cursor as a folded block
    -- below its statement (any language, macros too).
    expand = "<leader>ee",
    toggle_fold = "<leader>ec", -- fold or unfold the expansion under the cursor
    open = "<leader>eo", -- open a reading view for the current file
    close = "<leader>eq", -- close the reading view

    -- Keymaps local to a reading view, set when the view opens.

    undo = "u", -- undo the last expansion or inline
    redo = "<C-r>", -- redo what undo took back
    next_block = "]e", -- jump to the next expansion block
    prev_block = "[e", -- jump to the previous expansion block
    list_blocks = "<leader>el", -- list the expansion blocks in the location list
    callers = "<leader>eu", -- pick a caller of the function under the cursor (also :InlineExplorerCallers)
    -- Go to the definition of the symbol under the cursor, shown in a reading
    -- view of its file; the view you leave goes on the navigation trail.
    goto_def = "gd",
    trail_back = "<C-o>", -- back along the navigation trail
    trail_forward = "<C-i>", -- forward along the navigation trail
  },
  indent = "  ", -- indent prepended to each expansion level
  header = true, -- wrap each expansion in `/* v name */ ... /* ^ name */`
  -- How inline substitution writes its output. "correct" always compiles: it
  -- uses ({...}), goto and block wrapping where needed. "readable" avoids
  -- ({...}) and goto for cleaner output, and may not compile in edge cases
  -- (early returns, labels, short-circuits).
  mode = "correct",
  -- Record how long each stage takes; see :InlineExplorerProfile. While off,
  -- an instrumented call site costs one table lookup and one no-op call.
  profile = false,
}

-- The options in effect. setup() replaces this table with the defaults
-- merged with the user's options.
M.options = vim.deepcopy(M.defaults)

-- Check `opts` by hand, because vim.validate changed its signature between
-- 0.10 and 0.11. A wrong type or an unknown mode raises an error; an unknown
-- key only warns, so a typo is not silently ignored.
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

-- Validate `opts`, merge them over the defaults into a new M.options, and
-- return that table.
function M.setup(opts)
  opts = opts or {}
  check(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  return M.options
end

return M
