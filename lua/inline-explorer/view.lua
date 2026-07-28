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

  -- origin[view_row + 1] = source row (0-based) the line came from, or false
  -- for inserted text. Kept current across splices, rewrites and undo, so a
  -- view position can be mapped back to the real file at any depth.
  local origin = {}
  for i = 1, #lines do
    origin[i] = i - 1
  end
  M.state[view] = { source_bufnr = src, nodes = {}, undo = {}, redo = {}, origin = origin }

  vim.api.nvim_set_current_buf(view)
  vim.wo.foldmethod = "manual"
  vim.wo.foldenable = true
  pcall(vim.api.nvim_win_set_cursor, 0, cursor)

  -- Buffer-local undo/redo, so `u`/`<C-r>` only rebind inside the view.
  local hist = require("inline-explorer.history")
  local km = require("inline-explorer.config").options.keymaps or {}
  if km.undo then
    vim.keymap.set("n", km.undo, hist.undo, { buffer = view, desc = "Inline Explorer: undo expansion" })
  end
  if km.redo then
    vim.keymap.set("n", km.redo, hist.redo, { buffer = view, desc = "Inline Explorer: redo expansion" })
  end
  local nav = require("inline-explorer.nav")
  if km.next_block then
    vim.keymap.set("n", km.next_block, nav.next, { buffer = view, desc = "Inline Explorer: next expansion block" })
  end
  if km.prev_block then
    vim.keymap.set("n", km.prev_block, nav.prev, { buffer = view, desc = "Inline Explorer: previous expansion block" })
  end
  if km.list_blocks then
    vim.keymap.set("n", km.list_blocks, nav.list, { buffer = view, desc = "Inline Explorer: list expansion blocks" })
  end
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

-- Source line (0-based) a view line originates from, or nil for inserted text.
function M.src_line(st, row)
  local o = st.origin and st.origin[row + 1]
  if o == false or o == nil then
    return nil
  end
  return o
end

-- Diff old vs new text into map[old_row_0] = new_row_0 for lines that
-- survived unchanged (changed/inserted lines are absent).
function M._remap_rows(old_src, new_src)
  local hunks = vim.diff(old_src, new_src, { result_type = "indices" }) or {}
  local map = {}
  local old_n = #vim.split(old_src, "\n", { plain = true })
  local new_n = #vim.split(new_src, "\n", { plain = true })
  local oi, ni = 1, 1
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    -- count == 0 means "insertion after line start", so the first affected
    -- line is start + 1 in that buffer.
    local a_start = ca > 0 and sa or sa + 1
    local b_start = cb > 0 and sb or sb + 1
    while oi < a_start and ni < b_start do
      map[oi - 1] = ni - 1
      oi, ni = oi + 1, ni + 1
    end
    oi = a_start + ca
    ni = b_start + cb
  end
  while oi <= old_n and ni <= new_n do
    map[oi - 1] = ni - 1
    oi, ni = oi + 1, ni + 1
  end
  return map
end

-- Re-entrancy guard: one resolver round trip per view at a time, so two quick
-- keypresses on a slow server cannot interleave their splices. The stamp goes
-- stale after FETCH_GUARD_MS, so a leaked flag can never wedge the view
-- permanently (the resolver's own timeout fires well before that).
M.FETCH_GUARD_MS = 5000

function M.begin_fetch(st)
  local now = vim.uv.now()
  if st.fetch_started and (now - st.fetch_started) < M.FETCH_GUARD_MS then
    return false
  end
  st.fetch_started = now
  return true
end

function M.end_fetch(st)
  st.fetch_started = nil
end

-- Replace the whole view buffer with `new_src` (used by in-place transforms).
-- Snapshots for undo first. Lines that survive the rewrite unchanged (per
-- vim.diff) keep their origin bookkeeping, and block-expansion nodes whose
-- endpoints both survive are re-anchored with their folds re-created instead
-- of being dropped wholesale.
function M.rewrite(st, bufnr, new_src, row)
  require("inline-explorer.history").snapshot(st, bufnr)

  local old_src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local rowmap = M._remap_rows(old_src, new_src)

  local surviving = {}
  for _, node in ipairs(st.nodes) do
    local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, node.s_mark, {})
    local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, node.e_mark, {})
    if s[1] and e[1] and rowmap[s[1]] and rowmap[e[1]] then
      surviving[#surviving + 1] = { name = node.name, s = rowmap[s[1]], e = rowmap[e[1]] }
    end
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)

  local new_origin = {}
  if st.origin then
    for old_row, new_row in pairs(rowmap) do
      new_origin[new_row + 1] = st.origin[old_row + 1]
    end
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(new_src, "\n", { plain = true }))
  vim.bo[bufnr].modifiable = false
  local n = vim.api.nvim_buf_line_count(bufnr)
  for i = 1, n do
    if new_origin[i] == nil then
      new_origin[i] = false
    end
  end
  st.origin = new_origin

  pcall(vim.cmd, "silent! normal! zE")
  st.nodes = {}
  for _, node in ipairs(surviving) do
    st.nodes[#st.nodes + 1] = {
      name = node.name,
      s_mark = vim.api.nvim_buf_set_extmark(bufnr, M.ns, node.s, 0, {}),
      e_mark = vim.api.nvim_buf_set_extmark(bufnr, M.ns, node.e, 0, {}),
    }
    pcall(vim.cmd, string.format("%d,%dfold", node.s + 1, node.e + 1))
    pcall(vim.cmd, string.format("%d,%dfoldopen", node.s + 1, node.e + 1))
  end

  pcall(vim.api.nvim_win_set_cursor, 0, { math.min((row or 0) + 1, n), 0 })
end

return M
