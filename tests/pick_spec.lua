-- Picker glue: vim.ui.select is stubbed; what is asserted is what the user
-- would have seen (title, labels) and where a choice takes the window.
--   nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/pick_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))

require("inline-explorer").setup()
local pick = require("inline-explorer.pick")
local callers = require("inline-explorer.callers")
local trail = require("inline-explorer.trail")
local view = require("inline-explorer.view")

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and ("  " .. tostring(d)) or ""))
  end
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function write(rel, text)
  local f = assert(io.open(dir .. "/" .. rel, "w"))
  f:write(text)
  f:close()
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
  vim.wait(10000, function() return select_ui._state ~= nil end, 10)
  local st = select_ui._state
  check("picker: a floating list window opened", st ~= nil and vim.api.nvim_win_is_valid(st.win))
  check("picker: the selected row borrows PmenuSel, not the subtle CursorLine",
    st ~= nil and vim.wo[st.win].cursorline
      and vim.wo[st.win].winhighlight:find("CursorLine:PmenuSel", 1, true) ~= nil,
    st and vim.wo[st.win].winhighlight)
  local title = st and vim.api.nvim_win_get_config(st.win).title
  local title_text = ""
  if type(title) == "table" then
    for _, part in ipairs(title) do
      title_text = title_text .. (type(part) == "table" and part[1] or tostring(part))
    end
  elseif title then
    title_text = tostring(title)
  end
  check("picker: title carries name, count and source",
    title_text:find("tgt", 1, true) ~= nil and title_text:find("2", 1, true) ~= nil
      and title_text:find("grep", 1, true) ~= nil, title_text)

  -- j moves DOWN one row -- the point of this picker -- then <CR> chooses
  -- the SECOND caller (use2.c; items are file-sorted, use1 before use2).
  vim.api.nvim_win_set_cursor(st.win, { 1, 0 })
  vim.api.nvim_feedkeys("j", "x", false)
  check("picker: j moved the cursor to row 2",
    vim.api.nvim_win_get_cursor(st.win)[1] == 2, vim.api.nvim_win_get_cursor(st.win)[1])
  select_ui._accept()
  vim.wait(10000, function() return done end, 10)
  check("picker: choosing row 2 switches the view to the SECOND caller's file",
    view.state[vim.api.nvim_get_current_buf()] ~= nil
      and vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()):find("use2", 1, true) ~= nil,
    vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
  check("picker: the view we left is on the trail",
    #trail._stack >= 1 and trail._stack[#trail._stack].buf == v, #trail._stack)
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
  vim.wait(2000, function() return done end, 10)
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
  pick.callers(function()
    done = true
  end, "no_such_function_xyz")
  vim.wait(10000, function() return done end, 10)
  vim.notify = orig
  check("picker: zero callers -> no picker, an explicit notification",
    select_ui._state == nil and notified ~= nil and notified:find("no_such_function_xyz", 1, true) ~= nil,
    tostring(notified))
end

print("")
print(fails == 0 and "ALL PICK TESTS PASSED" or (fails .. " FAILURE(S)"))
if fails > 0 then vim.cmd("cq") end
vim.cmd("qa!")
