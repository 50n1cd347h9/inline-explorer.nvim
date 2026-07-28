-- Snapshot-based undo/redo for the reading view. The view is nomodifiable, so
-- native undo does not apply; instead every mutation (block expand, inline
-- substitute) snapshots the whole buffer first, and `u`/`<C-r>` restore snapshots.
local view = require("inline-explorer.view")

local M = {}

local function content(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function restore(st, bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  -- A wholesale restore invalidates block-expansion extmarks and manual folds.
  vim.api.nvim_buf_clear_namespace(bufnr, view.ns, 0, -1)
  st.nodes = {}
  pcall(vim.cmd, "silent! normal! zE")
end

-- Record the current buffer before a mutation; clears the redo stack.
function M.snapshot(st, bufnr)
  st.undo = st.undo or {}
  st.redo = {}
  st.undo[#st.undo + 1] = content(bufnr)
end

function M.undo()
  local st = view.current()
  if not st then
    return
  end
  st.undo = st.undo or {}
  if #st.undo == 0 then
    return vim.notify("[inline-explorer] nothing to undo", vim.log.levels.INFO)
  end
  local bufnr = vim.api.nvim_get_current_buf()
  st.redo = st.redo or {}
  st.redo[#st.redo + 1] = content(bufnr)
  restore(st, bufnr, table.remove(st.undo))
end

function M.redo()
  local st = view.current()
  if not st then
    return
  end
  st.redo = st.redo or {}
  if #st.redo == 0 then
    return vim.notify("[inline-explorer] nothing to redo", vim.log.levels.INFO)
  end
  local bufnr = vim.api.nvim_get_current_buf()
  st.undo = st.undo or {}
  st.undo[#st.undo + 1] = content(bufnr)
  restore(st, bufnr, table.remove(st.redo))
end

return M
