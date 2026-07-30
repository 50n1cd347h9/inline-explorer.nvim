-- Snapshot-based undo/redo for the reading view. The view is nomodifiable, so
-- native undo does not apply; instead every mutation (block expand, inline
-- substitute) snapshots the whole buffer first, and `u`/`<C-r>` restore snapshots.
local view = require("inline-explorer.view")

local M = {}

local function content(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- A snapshot carries the buffer lines AND the line-origin bookkeeping, so
-- undo/redo keep view->source mapping consistent.
local function snap(st, bufnr)
  return { lines = content(bufnr), origin = st.origin and vim.deepcopy(st.origin) or nil }
end

local function restore(st, bufnr, s)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, s.lines)
  vim.bo[bufnr].modifiable = false
  st.origin = s.origin
  -- A wholesale restore invalidates block-expansion extmarks and manual folds.
  vim.api.nvim_buf_clear_namespace(bufnr, view.ns, 0, -1)
  st.nodes = {}
  pcall(vim.cmd, "silent! normal! zE")
end

-- Snapshots are FULL buffer copies (plus the origin array), and nothing
-- trimmed them: measured 10.1 MB retained after 50 expansions of a
-- 10k-line view, and kernel-scale files are this plugin's stated use
-- case. Bounded like every other cache here; a module field so tests can
-- shrink it. Oldest snapshots go first -- undo depth beyond 32 mutations
-- of one view is a trade nobody has asked for at the price it costs.
M._cap = 32

-- Record the current buffer before a mutation; clears the redo stack.
function M.snapshot(st, bufnr)
  st.undo = st.undo or {}
  st.redo = {}
  st.undo[#st.undo + 1] = snap(st, bufnr)
  while #st.undo > M._cap do
    table.remove(st.undo, 1)
  end
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
  st.redo[#st.redo + 1] = snap(st, bufnr)
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
  st.undo[#st.undo + 1] = snap(st, bufnr)
  restore(st, bufnr, table.remove(st.redo))
end

return M
