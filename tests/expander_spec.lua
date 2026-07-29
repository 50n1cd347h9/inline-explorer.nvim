-- Expander smoke test with a stubbed resolver: verifies the async
-- locate -> extract -> splice pipeline, indentation, header comments,
-- recursion-guard bookkeeping and undo -- all without an LSP.
--   nvim --headless --clean -u NONE -c "luafile tests/expander_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))

local resolver = require("inline-explorer.resolver")
local view = require("inline-explorer.view")
local expander = require("inline-explorer.expander")
-- Config validation: bad values error, unknown keys warn, then reset clean.
do
  local config = require("inline-explorer.config")
  local ok = pcall(config.setup, { mode = "bogus" })
  assert(not ok, "config.setup accepted an invalid mode")
  local ok2 = pcall(config.setup, { indent = 4 })
  assert(not ok2, "config.setup accepted a non-string indent")
end
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

-- Line-origin bookkeeping: after undo the map is identity again; a splice
-- marks the inserted rows as origin-less and shifts the tail; a rewrite keeps
-- origins for unchanged lines and re-anchors surviving expansion nodes.
do
  local st = view.current()
  check("origin: identity after undo", view.src_line(st, 0) == 0 and view.src_line(st, 3) == 3, vim.inspect(st.origin))

  local col = ("    int r = helper(1);"):find("helper") - 1
  vim.api.nvim_win_set_cursor(0, { 3, col })
  expander.expand()
  vim.wait(1000, function()
    return vim.api.nvim_buf_line_count(vbuf) > 4
  end, 10)
  local inserted = vim.api.nvim_buf_line_count(vbuf) - 4
  check("origin: spliced rows have no source line", view.src_line(st, 3) == nil and view.src_line(st, 2 + inserted) == nil, vim.inspect(st.origin))
  check("origin: tail shifted to its old source line", view.src_line(st, 3 + inserted) == 3, vim.inspect(st.origin))

  -- Rewrite that only touches the call line: unchanged lines keep their
  -- origins and the expansion node survives with its rows intact.
  local lines_now = vim.api.nvim_buf_get_lines(vbuf, 0, -1, false)
  lines_now[3] = "    int r = (0);"
  view.rewrite(st, vbuf, table.concat(lines_now, "\n"), 2)
  check("rewrite: node survives an unrelated line change", #st.nodes == 1, #st.nodes)
  check("rewrite: changed line loses its origin", view.src_line(st, 2) == nil, vim.inspect(st.origin))
  check("rewrite: unchanged lines keep origins", view.src_line(st, 0) == 0 and view.src_line(st, 3 + inserted) == 3, vim.inspect(st.origin))

  -- Restore the original call line so the guard tests below can find `helper`.
  lines_now[3] = "    int r = helper(1);"
  view.rewrite(st, vbuf, table.concat(lines_now, "\n"), 2)
end

-- Navigation: jump to the surviving block, breadcrumb inside it, loclist.
do
  local nav = require("inline-explorer.nav")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  nav.next()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  check("nav.next lands on the block start", row == 3, row)
  check("breadcrumb names the containing expansion", nav.breadcrumb() == "helper", nav.breadcrumb())

  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(vbuf), 0 })
  nav.prev()
  check("nav.prev lands on the block start", vim.api.nvim_win_get_cursor(0)[1] - 1 == 3)

  nav.list()
  local ll = vim.fn.getloclist(0)
  check("loclist lists the expansion", #ll == 1 and ll[1].text:find("helper", 1, true) ~= nil, vim.inspect(ll))
  vim.cmd.lclose()
  -- lopen switched windows; return to the view for the guard tests below.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == vbuf then
      vim.api.nvim_set_current_win(win)
      break
    end
  end
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
end

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

-- Profiling: off by default records nothing; on, the real expand path
-- contributes a span that shows up in the report.
do
  local profile = require("inline-explorer.profile")
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

  local function run_expand()
    local n = vim.api.nvim_buf_line_count(vbuf)
    vim.api.nvim_win_set_cursor(0, { 3, ("    int r = helper(1);"):find("helper") - 1 })
    expander.expand()
    vim.wait(1000, function()
      return vim.api.nvim_buf_line_count(vbuf) > n
    end, 10)
  end

  profile.enabled = false
  profile.clear()
  run_expand()
  check("profile off records nothing", #profile.events == 0, #profile.events)
  check("report says profiling is off", profile.report():find("off", 1, true) ~= nil, profile.report())

  profile.enabled = true
  profile.clear()
  run_expand()
  check("profile on records the expand span", #profile.events > 0, #profile.events)
  check("report names the span", profile.report():find("expand (total)", 1, true) ~= nil, profile.report())

  -- Ring buffer stays bounded.
  profile.max_events = 3
  for _ = 1, 10 do
    profile.start()("synthetic")
  end
  check("event ring is bounded by max_events", #profile.events == 3, #profile.events)
  profile.max_events = 200
  profile.enabled = false
  profile.clear()
end

print("")
print(fails == 0 and "ALL EXPANDER TESTS PASSED" or (fails .. " FAILURE(S)"))
