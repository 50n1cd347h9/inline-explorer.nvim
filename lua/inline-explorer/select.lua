-- A floating list picker over a real buffer: every normal-mode motion moves,
-- <CR> chooses, <Esc> or q cancels. The plugin uses it instead of
-- vim.ui.select, which is inputlist() unless a UI plugin replaces it, so the
-- docs could not say which keys work.
local M = {}

-- The open picker's state, or nil. A module field so tests can drive it.
M._state = nil

local function finish(st, item, idx)
  if not st or st.done then
    return
  end
  st.done = true
  if M._state == st then
    M._state = nil
  end
  if vim.api.nvim_win_is_valid(st.win) then
    vim.api.nvim_win_close(st.win, true)
  end
  st.on_choice(item, idx)
end

function M._accept()
  local st = M._state
  if not st then
    return
  end
  local row = vim.api.nvim_win_get_cursor(st.win)[1]
  finish(st, st.items[row], row)
end

function M._cancel()
  finish(M._state, nil, nil)
end

local TITLE_PAD = 2 -- the title is drawn as " title "
local RIGHT_PAD = 2

local function window_size(lines, title)
  local width = vim.fn.strdisplaywidth(title) + TITLE_PAD
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local max_width = math.max(40, math.floor(vim.o.columns * 0.9))
  local max_height = math.max(3, vim.o.lines - 6)
  return math.min(width + RIGHT_PAD, max_width), math.min(#lines, max_height)
end

-- Takes the arguments of vim.ui.select; of `opts`, only prompt and
-- format_item are used. `on_choice` fires exactly once: with (item, idx) on a
-- choice, and with (nil, nil) on a cancel, however the window is closed.
---@return integer win
function M.open(items, opts, on_choice)
  opts = opts or {}
  local lines = {}
  for i, it in ipairs(items) do
    lines[i] = opts.format_item and opts.format_item(it) or tostring(it)
  end
  local title = opts.prompt or ""
  local width, height = window_size(lines, title)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title ~= "" and (" " .. title .. " ") or nil,
  })
  vim.wo[win].cursorline = true
  -- Colorschemes style PmenuSel as a selected entry; CursorLine is often too
  -- subtle for a picker.
  vim.wo[win].winhighlight = "CursorLine:PmenuSel"

  -- Cancel a picker still open, so its caller still gets on_choice(nil, nil).
  finish(M._state, nil, nil)
  local st = { buf = buf, win = win, items = items, on_choice = on_choice, done = false }
  M._state = st

  -- Buffer-local, so M._state is this picker whenever they fire.
  vim.keymap.set("n", "<CR>", M._accept, { buffer = buf, nowait = true })
  for _, lhs in ipairs({ "<Esc>", "q" }) do
    vim.keymap.set("n", lhs, M._cancel, { buffer = buf, nowait = true })
  end
  -- Finishes st, not M._state, so that a window closing late never cancels a
  -- newer picker.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      finish(st, nil, nil)
    end,
  })
  return win
end

return M
