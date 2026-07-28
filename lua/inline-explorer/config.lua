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
  },
  indent = "  ", -- indent prepended to each expansion level
  header = true, -- wrap each expansion in `/* v name */ ... /* ^ name */`
  -- Inline-substitution output: "correct" always compiles (uses ({...})/goto and
  -- block wrapping where needed); "readable" favours clean output (no ({...})/goto)
  -- and may not compile in edge cases (early returns, labels, short-circuits).
  mode = "correct",
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
