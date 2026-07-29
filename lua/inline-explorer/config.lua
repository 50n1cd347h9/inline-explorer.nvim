local M = {}

M.defaults = {
  keymaps = {
    substitute = "<leader>ei", -- primary: smart inline (functions inlined, macros expanded in place; else block)
    expand = "<leader>ee", -- explicit block-paste (any language, incl. macros; also the fallback)
    toggle_fold = "<leader>ec", -- fold / unfold the expansion under the cursor
    open = "<leader>eo", -- open a reading view for the current file
    close = "<leader>eq", -- close the reading view
    undo = "u", -- undo the last expansion (buffer-local to the view)
    redo = "<C-r>", -- redo (buffer-local to the view)
    next_block = "]e", -- jump to the next expansion block (buffer-local)
    prev_block = "[e", -- jump to the previous expansion block (buffer-local)
    list_blocks = "<leader>el", -- expansion blocks in the location list
  },
  indent = "  ", -- indent prepended to each expansion level
  header = true, -- wrap each expansion in `/* v name */ ... /* ^ name */`
  -- Inline-substitution output: "correct" always compiles (uses ({...})/goto and
  -- block wrapping where needed); "readable" favours clean output (no ({...})/goto)
  -- and may not compile in edge cases (early returns, labels, short-circuits).
  mode = "correct",
  -- Record per-stage latencies; see :InlineExplorerProfile. Off by default
  -- (instrumented call sites cost a table lookup and a no-op call when off).
  profile = false,
}

M.options = vim.deepcopy(M.defaults)

-- Version-stable by-hand validation (vim.validate changed shape across 0.10
-- and 0.11): wrong types error loudly, unknown keys warn instead of being
-- silently ignored.
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
      vim.notify(("[inline-explorer] unknown option '%s' (typo?)"):format(k), vim.log.levels.WARN)
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
