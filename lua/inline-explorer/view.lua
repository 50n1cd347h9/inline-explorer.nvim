-- View: a read-only copy of the source file where expansions are inserted as
-- real (cursor-navigable) text, so they can be expanded again in turn.
local M = {}

M.ns = vim.api.nvim_create_namespace("inline_explorer")

-- view_bufnr -> { source_bufnr, nodes = { { name, s_mark, e_mark }, ... } }
M.state = {}

-- Open a reading view for the current buffer and switch to it.
function M.open()
  local src = vim.api.nvim_get_current_buf()
  if M.state[src] then
    vim.notify("[inline-explorer] already in a reading view", vim.log.levels.INFO)
    return
  end

  local name = vim.api.nvim_buf_get_name(src)
  local ft = vim.bo[src].filetype
  local lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
  local cursor = vim.api.nvim_win_get_cursor(0)

  local view = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(view, 0, -1, false, lines)
  vim.bo[view].filetype = ft
  vim.bo[view].buftype = "nofile"
  vim.bo[view].bufhidden = "wipe"
  vim.bo[view].modifiable = false
  pcall(vim.api.nvim_buf_set_name, view, "inline-explorer://" .. vim.fn.fnamemodify(name, ":t"))

  -- The view is a detached copy, so no language server attaches and its
  -- semantic-token highlighting is absent. Start tree-sitter explicitly so the
  -- buffer keeps rich highlighting instead of falling back to bare regex syntax.
  local lang = vim.treesitter.language.get_lang(ft) or ft
  pcall(vim.treesitter.start, view, lang)

  M.state[view] = { source_bufnr = src, nodes = {} }

  vim.api.nvim_set_current_buf(view)
  vim.wo.foldmethod = "manual"
  vim.wo.foldenable = true
  pcall(vim.api.nvim_win_set_cursor, 0, cursor)
  return view
end

-- Close the reading view the cursor is in.
function M.close()
  local view = vim.api.nvim_get_current_buf()
  if not M.state[view] then
    vim.notify("[inline-explorer] not in a reading view", vim.log.levels.WARN)
    return
  end
  M.state[view] = nil
  vim.api.nvim_buf_delete(view, { force = true })
end

-- Return the state for the current buffer, or nil if it is not a view.
function M.current()
  return M.state[vim.api.nvim_get_current_buf()]
end

return M
