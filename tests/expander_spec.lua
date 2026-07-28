-- Expander smoke test with a stubbed resolver: verifies the async
-- locate -> extract -> splice pipeline, indentation, header comments,
-- recursion-guard bookkeeping and undo -- all without an LSP.
--   nvim --headless --clean -u NONE -c "luafile tests/expander_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))

local resolver = require("inline-explorer.resolver")
local view = require("inline-explorer.view")
local expander = require("inline-explorer.expander")
require("inline-explorer.config").setup({})

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and ("\n----\n" .. tostring(d) .. "\n----") or ""))
  end
end

-- Stub the resolver: cb-style, immediate, no LSP involved.
resolver.locate = function(name, _, cb)
  cb({
    uri = "file:///fake.c",
    range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 6 } },
    kind = 12,
    name = name,
  })
end
resolver.extract = function(_, _, cb)
  cb({ "static int helper(int x)", "{", "    return x + 1;", "}" }, "function_definition")
end

-- Source buffer -> reading view.
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "int main(void)", "{", "    int r = helper(1);", "}" })
vim.bo.filetype = "c"
local vbuf = view.open()
check("view opened", view.current() ~= nil)

-- Expand the call under the cursor.
local col = ("    int r = helper(1);"):find("helper") - 1
vim.api.nvim_win_set_cursor(0, { 3, col })
expander.expand()
local done = vim.wait(1000, function()
  return vim.api.nvim_buf_line_count(vbuf) > 4
end, 10)
check("expansion spliced", done)

local lines = vim.api.nvim_buf_get_lines(vbuf, 0, -1, false)
local text = table.concat(lines, "\n")
check("header comment present", text:find("/* v helper (function_definition) */", 1, true) ~= nil, text)
check("footer comment present", text:find("/* ^ helper */", 1, true) ~= nil, text)
check("body indented one level past the call line", text:find("\n      static int helper", 1, true) ~= nil, text)
check("view stays nomodifiable", vim.bo[vbuf].modifiable == false)
check("one expansion node tracked", #view.current().nodes == 1)

-- Recursion guard: cursor inside the expansion, same name -> no second splice.
local before = vim.api.nvim_buf_line_count(vbuf)
for i, l in ipairs(lines) do
  local c = l:find("static int helper", 1, true)
  if c then
    vim.api.nvim_win_set_cursor(0, { i, l:find("helper", 1, true) - 1 })
    break
  end
end
expander.expand()
vim.wait(200, function()
  return false
end, 50)
check("recursion guard blocks re-expansion", vim.api.nvim_buf_line_count(vbuf) == before)

-- Undo restores the pre-expansion snapshot.
require("inline-explorer.history").undo()
check("undo restores the original view", vim.api.nvim_buf_line_count(vbuf) == 4)

-- Re-entrancy guard: while a resolver round trip is in flight, a second
-- expand is refused; the stamp goes stale after FETCH_GUARD_MS so a leaked
-- flag self-heals.
do
  resolver.locate = function() end -- swallow: the fetch never completes
  view.FETCH_GUARD_MS = 200
  local col2 = ("    int r = helper(1);"):find("helper") - 1
  vim.api.nvim_win_set_cursor(0, { 3, col2 })

  local notes = {}
  local old_notify = vim.notify
  vim.notify = function(msg)
    notes[#notes + 1] = tostring(msg)
  end
  expander.expand() -- occupies the guard (locate swallows the callback)
  expander.expand() -- must be refused
  vim.notify = old_notify
  local refused = false
  for _, m in ipairs(notes) do
    if m:find("already in flight", 1, true) then
      refused = true
    end
  end
  check("second expand refused while a fetch is in flight", refused, table.concat(notes, " | "))

  vim.wait(250, function()
    return false
  end, 50)
  notes = {}
  vim.notify = function(msg)
    notes[#notes + 1] = tostring(msg)
  end
  expander.expand() -- stale stamp: must proceed to locate again, no refusal
  vim.notify = old_notify
  local refused_again = false
  for _, m in ipairs(notes) do
    if m:find("already in flight", 1, true) then
      refused_again = true
    end
  end
  check("stale guard self-heals after FETCH_GUARD_MS", not refused_again, table.concat(notes, " | "))
end

print("")
print(fails == 0 and "ALL EXPANDER TESTS PASSED" or (fails .. " FAILURE(S)"))
