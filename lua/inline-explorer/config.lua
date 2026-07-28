local M = {}

M.defaults = {
  keymaps = {
    expand = "<leader>ee", -- expand the symbol under the cursor (block, any language)
    substitute = "<leader>ei", -- inline-substitute the call under the cursor (C only)
    expand_macro = "<leader>em", -- expand the macro under the cursor via clangd (C)
    toggle_fold = "<leader>ec", -- fold / unfold the expansion under the cursor
    open = "<leader>eo", -- open a reading view for the current file
    close = "<leader>eq", -- close the reading view
    undo = "u", -- undo the last expansion (buffer-local to the view)
    redo = "r", -- redo (buffer-local to the view)
  },
  indent = "  ", -- indent prepended to each expansion level
  header = true, -- wrap each expansion in `/* v name */ ... /* ^ name */`
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
