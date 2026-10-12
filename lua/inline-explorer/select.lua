-- A small floating list picker with the keys a vim user's hands expect:
-- j/k (and every other normal-mode motion) to move, <CR> to choose, <Esc>
-- or q to cancel.
--
-- The plugin's pickers use this instead of vim.ui.select. Stock
-- vim.ui.select is inputlist() (type a number at a prompt), and anything
-- better depends on which UI plugin is installed, so the docs could not say
-- which keys work. This picker is a real window over a real buffer: j/k are
-- not implemented, they simply work, along with gg, G, / search, and counts.
--
-- M.open takes the arguments of vim.ui.select(items, opts, on_choice).
-- on_choice fires exactly once: with (item, idx) on a choice, and with
-- (nil, nil) on a cancel, including when the window is closed any other way
-- (:q, :close).
local M = {}

-- The state of the picker that is open right now (nil when none). It is a
-- module field so tests can drive and inspect it. Callbacks that may fire
-- late (WinClosed) capture their own picker's state instead, so they never
-- touch a newer picker.
M._state = nil

-- Close picker `st` and call its on_choice(item, idx), unless it has
-- already finished.
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

-- Choose the entry under the cursor in the open picker.
function M._accept()
  local st = M._state
  if not st then
    return
  end
  local row = vim.api.nvim_win_get_cursor(st.win)[1]
  finish(st, st.items[row], row)
end

-- Cancel the open picker.
function M._cancel()
  finish(M._state, nil, nil)
end

local TITLE_PAD = 2 -- the title is drawn as " title "
local RIGHT_PAD = 2 -- spare columns after the widest line

-- The window size for the entry texts `lines` and the title `title`. The
-- width fits the widest entry (or the padded title) plus RIGHT_PAD, up to 90%
-- of the editor's width but never less than 40 columns. The height is one row
-- per entry, up to the editor's height minus 6 but never less than 3.
local function window_size(lines, title)
  local width = vim.fn.strdisplaywidth(title) + TITLE_PAD
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local max_width = math.max(40, math.floor(vim.o.columns * 0.9))
  local max_height = math.max(3, vim.o.lines - 6)
  return math.min(width + RIGHT_PAD, max_width), math.min(#lines, max_height)
end

-- Open a picker over `items` and return its window. `opts.prompt` is the
-- title, and `opts.format_item(item)` gives an entry's text (tostring() by
-- default).
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
  -- Highlight the cursor line with PmenuSel: colorschemes style that group as
  -- the selected entry, while CursorLine is often too subtle for a picker.
  vim.wo[win].winhighlight = "CursorLine:PmenuSel"

  -- Before this picker takes over M._state, cancel the one still open (if
  -- any), so its caller still gets on_choice(nil, nil).
  finish(M._state, nil, nil)
  local st = { buf = buf, win = win, items = items, on_choice = on_choice, done = false }
  M._state = st

  -- These maps are local to this picker's buffer, so M._state is this picker
  -- whenever they fire.
  vim.keymap.set("n", "<CR>", M._accept, { buffer = buf, nowait = true })
  for _, lhs in ipairs({ "<Esc>", "q" }) do
    vim.keymap.set("n", lhs, M._cancel, { buffer = buf, nowait = true })
  end
  -- Any other way the window closes (:q, :close, a WinClosed from elsewhere)
  -- still delivers the cancel, because callers rely on on_choice firing
  -- exactly once. The autocmd uses this picker's own state, so a stale
  -- window that closes late never cancels a newer picker.
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
