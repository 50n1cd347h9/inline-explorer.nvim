-- A small floating list picker with the keys a vim user's hands expect:
-- j/k (and every other normal-mode motion) to move, <CR> to choose,
-- <Esc>/q to cancel.
--
-- This replaces vim.ui.select for the plugin's pickers on purpose. The
-- stock vim.ui.select is inputlist() -- type a number at a prompt -- and
-- whether something better appears depends on which UI plugin happens to
-- be installed. A picker whose basic motions depend on the user's plugin
-- inventory is not a picker the docs can describe, so this one is owned
-- here. It is a real window over a real buffer: j/k are not implemented,
-- they simply work, along with gg/G//search and counts.
--
-- Same signature as vim.ui.select(items, opts, on_choice); on_choice
-- fires exactly once -- (item, idx) on choice, (nil, nil) on cancel,
-- including when the window is closed by any other means (:q, WinClosed).
local M = {}

-- The open picker's state, a module field so tests can drive and inspect
-- it without simulating keystrokes.
M._state = nil

local function finish(item, idx)
  local st = M._state
  if not st or st.done then
    return
  end
  st.done = true
  M._state = nil
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
  finish(st.items[row], row)
end

function M._cancel()
  finish(nil, nil)
end

function M.open(items, opts, on_choice)
  opts = opts or {}
  local lines = {}
  local width = 0
  for i, it in ipairs(items) do
    lines[i] = opts.format_item and opts.format_item(it) or tostring(it)
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]))
  end
  local title = opts.prompt or ""
  width = math.max(width, vim.fn.strdisplaywidth(title) + 2)
  width = math.min(width + 2, math.max(40, math.floor(vim.o.columns * 0.9)))
  local height = math.min(#lines, math.max(3, vim.o.lines - 6))

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
  -- The stock CursorLine is designed to be subtle -- fine in a file, too
  -- quiet for a picker, where the highlighted row IS the answer to "what
  -- happens when I press enter". PmenuSel is the group every colorscheme
  -- designs to read as "the selected entry", so borrow it for exactly that
  -- meaning here.
  vim.wo[win].winhighlight = "CursorLine:PmenuSel"

  M._state = { buf = buf, win = win, items = items, on_choice = on_choice, done = false }

  for _, lhs in ipairs({ "<CR>" }) do
    vim.keymap.set("n", lhs, M._accept, { buffer = buf, nowait = true })
  end
  for _, lhs in ipairs({ "<Esc>", "q" }) do
    vim.keymap.set("n", lhs, M._cancel, { buffer = buf, nowait = true })
  end
  -- Any other way the window dies (:q, :close, a WinClosed from elsewhere)
  -- must still deliver the cancel -- on_choice firing exactly once is the
  -- contract callers rely on for their own done-callbacks.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = M._cancel,
  })
  return win
end

return M
