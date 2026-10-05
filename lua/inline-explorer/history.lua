-- Snapshot-based undo/redo for the reading view. The view is nomodifiable, so
-- native undo does not apply; instead every mutation (block expand, inline
-- substitute) snapshots the whole buffer first, and `u`/`<C-r>` restore snapshots.
local view = require("inline-explorer.view")
local util = require("inline-explorer.util")

local M = {}

local function content(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- A snapshot carries the buffer lines AND the line-origin bookkeeping, so
-- undo/redo keep view->source mapping consistent.
local function snap(st, bufnr)
  return { lines = content(bufnr), origin = vim.deepcopy(st.origin) }
end

local function restore(st, bufnr, s)
  view.set_lines(bufnr, 0, -1, s.lines)
  st.origin = s.origin
  -- A wholesale restore invalidates block-expansion extmarks and manual folds.
  view.reset_marks(st, bufnr)
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
  st.redo = {}
  st.undo[#st.undo + 1] = snap(st, bufnr)
  while #st.undo > M._cap do
    table.remove(st.undo, 1)
  end
end

-- Move one snapshot from stack `from` to the buffer, pushing the current
-- buffer onto stack `to`: undo is step("undo", "redo"), redo the reverse.
local function step(from, to)
  local st = view.current()
  if not st then
    return
  end
  if #st[from] == 0 then
    return util.notify("nothing to " .. from, vim.log.levels.INFO)
  end
  local bufnr = vim.api.nvim_get_current_buf()
  st[to][#st[to] + 1] = snap(st, bufnr)
  restore(st, bufnr, table.remove(st[from]))
end

function M.undo()
  step("undo", "redo")
end

function M.redo()
  step("redo", "undo")
end

return M
