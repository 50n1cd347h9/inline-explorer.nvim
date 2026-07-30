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

vim.cmd.edit(dir .. "/lib.c")
vim.api.nvim_win_set_cursor(0, { 1, 5 }) -- on `tgt`
local v = view.open()

-- Stub the selector: capture prompt+items, choose the first entry.
local seen_prompt, seen_n
vim.ui.select = function(items, opts, on_choice)
  seen_prompt, seen_n = opts and opts.prompt, #items
  on_choice(items[1], 1)
end

do
  local done = false
  pick.callers(function()
    done = true
  end)
  vim.wait(10000, function() return done end, 10)
  check("picker: prompt carries name, count and source",
    seen_prompt ~= nil and seen_prompt:find("tgt", 1, true) ~= nil
      and seen_prompt:find("1", 1, true) ~= nil and seen_prompt:find("grep", 1, true) ~= nil,
    tostring(seen_prompt))
  check("picker: choosing switches the view to the caller's file",
    view.state[vim.api.nvim_get_current_buf()] ~= nil
      and vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()):find("use1", 1, true) ~= nil,
    vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
  check("picker: the view we left is on the trail",
    #trail._stack >= 1 and trail._stack[#trail._stack].buf == v, #trail._stack)
end

-- Zero results: no picker, a notification instead.
do
  seen_prompt = nil
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
    seen_prompt == nil and notified ~= nil and notified:find("no_such_function_xyz", 1, true) ~= nil,
    tostring(notified))
end

print("")
print(fails == 0 and "ALL PICK TESTS PASSED" or (fails .. " FAILURE(S)"))
if fails > 0 then vim.cmd("cq") end
vim.cmd("qa!")
