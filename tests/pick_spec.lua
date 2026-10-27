-- Picker glue: vim.ui.select is stubbed; what is asserted is what the user
-- would have seen (title, labels) and where a choice takes the window.
--   nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/pick_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local H = require("tests.lib.harness")

require("inline-explorer").setup()
local pick = require("inline-explorer.pick")
local trail = require("inline-explorer.trail")
local view = require("inline-explorer.view")

local check = H.check

local dir = H.tmpdir()
local function write(rel, text)
  H.writef(dir .. "/" .. rel, text)
end
write("lib.c", "int tgt(int a)\n{\n    return a + 1;\n}\n")
write("use1.c", "int tgt(int);\nint u1(void)\n{\n    return tgt(1);\n}\n")
write("use2.c", "int tgt(int);\nint u2(void)\n{\n    return tgt(2);\n}\n")

vim.cmd.edit(dir .. "/lib.c")
vim.api.nvim_win_set_cursor(0, { 1, 5 }) -- on `tgt`
local v = view.open()

-- The picker is the plugin's own floating list now (select.lua): a real
-- window, so j and k are ordinary cursor motions. The test drives it the
-- way fingers would -- j to the second row, <CR> to choose -- via the
-- select module's state, then asserts where the window went.
local select_ui = require("inline-explorer.select")

do
  local done = false
  pick.callers(function()
    done = true
  end)
  vim.wait(10000, function()
    return select_ui._state ~= nil
  end, 10)
  local st = select_ui._state
  check("picker: a floating list window opened", st ~= nil and vim.api.nvim_win_is_valid(st.win))
  check(
    "picker: the selected row borrows PmenuSel, not the subtle CursorLine",
    st ~= nil and vim.wo[st.win].cursorline and vim.wo[st.win].winhighlight:find("CursorLine:PmenuSel", 1, true) ~= nil,
    st and vim.wo[st.win].winhighlight
  )
  local title = st and vim.api.nvim_win_get_config(st.win).title
  local title_text = ""
  if type(title) == "table" then
    for _, part in ipairs(title) do
      title_text = title_text .. (type(part) == "table" and part[1] or tostring(part))
    end
  elseif title then
    title_text = tostring(title)
  end
  check(
    "picker: title carries name, count and source",
    title_text:find("tgt", 1, true) ~= nil
      and title_text:find("2", 1, true) ~= nil
      and title_text:find("grep", 1, true) ~= nil,
    title_text
  )

  -- j moves DOWN one row -- the point of this picker -- then <CR> chooses
  -- the SECOND caller (use2.c; items are file-sorted, use1 before use2).
  vim.api.nvim_win_set_cursor(st.win, { 1, 0 })
  vim.api.nvim_feedkeys("j", "x", false)
  check(
    "picker: j moved the cursor to row 2",
    vim.api.nvim_win_get_cursor(st.win)[1] == 2,
    vim.api.nvim_win_get_cursor(st.win)[1]
  )
  select_ui._accept()
  vim.wait(10000, function()
    return done
  end, 10)
  check(
    "picker: choosing row 2 switches the view to the SECOND caller's file",
    view.state[vim.api.nvim_get_current_buf()] ~= nil
      and vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()):find("use2", 1, true) ~= nil,
    vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  )
  check(
    "picker: the view we left is on the trail",
    #trail._stack >= 1 and trail._stack[#trail._stack].buf == v,
    #trail._stack
  )
end

-- A second picker opening while the first is up must CANCEL the first --
-- delivering its nil -- and the first window's late WinClosed must not
-- touch the second. Before the fix, A's callback never fired and A's
-- autocmd cancelled B: "A fired 0 times; B fired 1 times (nil)".
do
  local a_fired, a_val, b_fired, b_val = 0, "unset", 0, "unset"
  select_ui.open({ "a1", "a2" }, { prompt = "A" }, function(item)
    a_fired = a_fired + 1
    a_val = item
  end)
  local a_win = select_ui._state.win
  select_ui.open({ "b1", "b2" }, { prompt = "B" }, function(item)
    b_fired = b_fired + 1
    b_val = item
  end)
  check(
    "second picker: the first callback fired exactly once, with nil",
    a_fired == 1 and a_val == nil,
    ("fired=%d val=%s"):format(a_fired, tostring(a_val))
  )
  check("second picker: the first window is gone", not vim.api.nvim_win_is_valid(a_win))
  -- late WinClosed for A (if any queued) must not cancel B
  vim.wait(100)
  check(
    "second picker: B is still open and choosable",
    select_ui._state ~= nil and vim.api.nvim_win_is_valid(select_ui._state.win)
  )
  select_ui._accept()
  vim.wait(500, function()
    return b_fired > 0
  end, 10)
  check(
    "second picker: B delivers its own choice exactly once",
    b_fired == 1 and b_val == "b1",
    ("fired=%d val=%s"):format(b_fired, tostring(b_val))
  )
end

-- Cancelling must fire the callback exactly once, as nil.
do
  local done, chose = false, "unset"
  select_ui.open({ "a", "b" }, { prompt = "t" }, function(item)
    chose = item
    done = true
  end)
  vim.api.nvim_feedkeys("j", "x", false)
  select_ui._cancel()
  vim.wait(2000, function()
    return done
  end, 10)
  check("picker: cancel delivers nil exactly once", done and chose == nil, tostring(chose))
end

-- Zero results: no picker, a notification instead.
do
  local notified
  local orig = vim.notify
  vim.notify = function(msg)
    notified = msg
  end
  local done = false
  local prev_buf = vim.api.nvim_get_current_buf()
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "no_such_function_xyz();" })
  vim.api.nvim_set_current_buf(scratch)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  pick.callers(function()
    done = true
  end)
  vim.wait(10000, function()
    return done
  end, 10)
  vim.notify = orig
  vim.api.nvim_set_current_buf(prev_buf)
  check(
    "picker: zero callers -> no picker, an explicit notification",
    select_ui._state == nil and notified ~= nil and notified:find("no_such_function_xyz", 1, true) ~= nil,
    tostring(notified)
  )
end

H.finish("PICK")
