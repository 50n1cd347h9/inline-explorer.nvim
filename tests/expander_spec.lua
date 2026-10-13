-- Expander smoke test with a stubbed resolver: verifies the async
-- locate -> extract -> splice pipeline, indentation, header comments,
-- recursion-guard bookkeeping and undo -- all without an LSP.
--   nvim --headless --clean -u NONE -c "luafile tests/expander_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local H = require("tests.lib.harness")

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

local check = H.check

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
check("one expansion block tracked", #view.current().blocks == 1)

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

-- Undo takes the expansion back; redo brings it back as a block -- the
-- snapshot undo this replaced dropped every block on undo and redo alike,
-- so the breadcrumb, the recursion guard and the folds forgot it.
require("inline-explorer.history").undo()
check("undo restores the original view", vim.api.nvim_buf_line_count(vbuf) == 4)
require("inline-explorer.history").redo()
check("redo brings the expansion back", vim.api.nvim_buf_line_count(vbuf) == before)
check("redo brings it back as a tracked block", #view.current().blocks == 1, #view.current().blocks)
require("inline-explorer.history").undo()

-- Line-origin bookkeeping: after undo the map is identity again; a splice
-- marks the inserted rows as origin-less and shifts the tail; a rewrite keeps
-- origins for unchanged lines and re-anchors surviving expansion blocks.
do
  local st = view.current()
  -- The source row of every view row ("-" for none), for failure messages.
  local function origins()
    local out = {}
    for row = 0, vim.api.nvim_buf_line_count(st.bufnr) - 1 do
      out[#out + 1] = tostring(view.src_line(st, row) or "-")
    end
    return table.concat(out, " ")
  end
  check("origin: identity after undo", view.src_line(st, 0) == 0 and view.src_line(st, 3) == 3, origins())

  vim.api.nvim_win_set_cursor(0, { 3, col })
  expander.expand()
  vim.wait(1000, function()
    return vim.api.nvim_buf_line_count(vbuf) > 4
  end, 10)
  local inserted = vim.api.nvim_buf_line_count(vbuf) - 4
  check(
    "origin: spliced rows have no source line",
    view.src_line(st, 3) == nil and view.src_line(st, 2 + inserted) == nil,
    origins()
  )
  check("origin: tail shifted to its old source line", view.src_line(st, 3 + inserted) == 3, origins())

  -- Rewrite that only touches the call line: unchanged lines keep their
  -- origins and the expansion block survives with its rows intact.
  local lines_now = vim.api.nvim_buf_get_lines(vbuf, 0, -1, false)
  lines_now[3] = "    int r = (0);"
  view.rewrite(st, vbuf, table.concat(lines_now, "\n"), 2)
  check("rewrite: block survives an unrelated line change", #st.blocks == 1, #st.blocks)
  check("rewrite: changed line loses its origin", view.src_line(st, 2) == nil, origins())
  check(
    "rewrite: unchanged lines keep origins",
    view.src_line(st, 0) == 0 and view.src_line(st, 3 + inserted) == 3,
    origins()
  )

  -- Undoing the rewrite gives the changed line its origin back; redoing it
  -- takes it away again. The block survives both.
  require("inline-explorer.history").undo()
  check("undo of a rewrite restores the line's origin", view.src_line(st, 2) == 2, view.src_line(st, 2))
  check("undo of a rewrite keeps the block", #st.blocks == 1, #st.blocks)
  require("inline-explorer.history").redo()
  check("redo of a rewrite drops the origin again", view.src_line(st, 2) == nil, view.src_line(st, 2))
  check("redo of a rewrite keeps the block", #st.blocks == 1, #st.blocks)

  -- A rewrite replaces only the lines that differ.
  check(
    "rewrite: the text is exactly the new source",
    table.concat(vim.api.nvim_buf_get_lines(vbuf, 0, -1, false), "\n") == table.concat(lines_now, "\n")
  )

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

-- Prefetched body: a caller that already resolved the symbol (the inliner,
-- when it falls back to block-pasting) hands the result over instead of
-- making us repeat the round trip. Argument tables that carry no body -- the
-- ones nvim passes to command callbacks -- must be ignored.
do
  local st = view.current()
  require("inline-explorer.history").undo() -- back to the bare file
  local located = 0
  local saved_locate = resolver.locate
  resolver.locate = function(name, _, cb)
    located = located + 1
    saved_locate(name, _, cb)
  end

  vim.api.nvim_win_set_cursor(0, { 3, ("    int r = helper(1);"):find("helper") - 1 })
  local before_lines = vim.api.nvim_buf_line_count(vbuf)

  -- The prefetched path must record its own total:expand span, exactly like
  -- the fetching one -- otherwise the harness (and any caller waiting on a
  -- final total: span) has no way to know this completion ever finished.
  local profile = require("inline-explorer.profile")
  profile.logfile = false
  profile.enabled = true
  profile.clear()

  expander.expand({
    name = "prefetched_fn",
    body = { "static int prefetched_fn(void)", "{", "    return 7;", "}" },
    label = "function_definition",
  })
  check(
    "prefetched body splices without a lookup",
    located == 0 and vim.api.nvim_buf_line_count(vbuf) > before_lines,
    ("located=%d lines=%d->%d"):format(located, before_lines, vim.api.nvim_buf_line_count(vbuf))
  )
  check(
    "prefetched body is what got spliced",
    table.concat(vim.api.nvim_buf_get_lines(vbuf, 0, -1, false), "\n"):find("prefetched_fn(void)", 1, true) ~= nil
  )
  check("prefetched splice is tracked as a block", #st.blocks >= 1, #st.blocks)
  check(
    "prefetched expand records a total:expand span",
    (function()
      for _, e in ipairs(profile.events) do
        if e.name == "total:expand" then
          return true
        end
      end
      return false
    end)(),
    vim.inspect(profile.events)
  )

  profile.enabled = false
  profile.clear()

  -- A command-callback style table (no body) must fall through to a lookup.
  require("inline-explorer.history").undo()
  vim.api.nvim_win_set_cursor(0, { 3, ("    int r = helper(1);"):find("helper") - 1 })
  expander.expand({ name = "InlineExplorerExpand", args = "", fargs = {} })
  vim.wait(1000, function()
    return located > 0
  end, 10)
  check("bodyless argument table falls through to a real lookup", located == 1, located)
  resolver.locate = saved_locate
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
  -- Keep the real user log out of the test run.
  profile.logfile = vim.fn.tempname() .. ".log"
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
  check("report names the span", profile.report():find("total:expand", 1, true) ~= nil, profile.report())

  -- The log file is the durable record: spans land there too, clear(true)
  -- truncates it, and logfile = false keeps everything in memory.
  local logpath = profile.logfile
  local function logtext()
    local fh = io.open(logpath, "r")
    if not fh then
      return ""
    end
    local s = fh:read("*a")
    fh:close()
    return s
  end
  check("span appended to the log file", logtext():find("total:expand", 1, true) ~= nil, logtext())
  check("report points at the log file", profile.report():find(profile.logfile, 1, true) ~= nil)
  profile.clear(true)
  check("clear(true) truncates the log file", logtext() == "", logtext())
  profile.logfile = false
  run_expand()
  check("logfile = false keeps it in memory only", logtext() == "" and #profile.events > 0, #profile.events)
  profile.logfile = logpath

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

-- The view's fold settings belong to the view. Set with plain vim.wo they
-- acted like `:set` -- the global value changed too, so every window
-- opened afterwards, and every buffer shown in one, lost the user's own
-- foldmethod (indent/expr folding silently became manual).
do
  vim.cmd("enew")
  local src = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(src, 0, -1, false, { "int f(void)", "{", "    return 1;", "}" })
  vim.o.foldmethod = "indent"
  local v = view.open()
  check("fold options: the view itself folds manually", vim.wo.foldmethod == "manual", vim.wo.foldmethod)
  check("fold options: the global foldmethod is untouched", vim.go.foldmethod == "indent", vim.go.foldmethod)
  vim.api.nvim_set_current_buf(src)
  check(
    "fold options: the source buffer keeps its foldmethod in the same window",
    vim.wo.foldmethod == "indent",
    vim.wo.foldmethod
  )
  vim.cmd("new")
  check(
    "fold options: a window opened afterwards keeps the user's foldmethod",
    vim.wo.foldmethod == "indent",
    vim.wo.foldmethod
  )
  vim.cmd("close")
  -- Leaving the view wiped it (bufhidden=wipe); nothing to close.
  check("fold options: the abandoned view is gone", not vim.api.nvim_buf_is_valid(v))
  vim.o.foldmethod = "manual"
end

-- An expansion goes below the call's STATEMENT, not the cursor's row. A
-- call spread over lines --
--   areq = af_alg_alloc_areq(sk, sizeof(struct af_alg_async_req) +
--                            crypto_aead_reqsize(tfm));
-- -- had its expansion spliced between the two lines, splitting the
-- statement. A statement with a body stops where the body begins.
do
  local function expand_at(src, row, word)
    vim.cmd("enew")
    vim.bo.filetype = "c"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, src)
    local v = view.open()
    vim.api.nvim_win_set_cursor(0, { row, src[row]:find(word, 1, true) - 1 })
    local n = vim.api.nvim_buf_line_count(v)
    expander.expand()
    vim.wait(1000, function()
      return vim.api.nvim_buf_line_count(v) > n
    end, 10)
    local out = vim.api.nvim_buf_get_lines(v, 0, -1, false)
    for i, l in ipairs(out) do
      if l:find("/* v " .. word, 1, true) then
        return i, l:match("^%s*"), out
      end
    end
    return nil, nil, out
  end

  local stmt = {
    "int main(void)",
    "{",
    "    areq = alloc(sk, sizeof(x) +",
    "                 reqsize(tfm));",
    "    if (cond(a) &&",
    "        other(b)) {",
    "        work();",
    "    }",
    "}",
  }
  local at, pad, out = expand_at(stmt, 3, "alloc")
  check("statement: a multi-line call expands below its last line", at == 5, out)
  check("statement: indented from the statement's first line", pad == "      ", out)
  at, pad, out = expand_at(stmt, 4, "reqsize")
  check("statement: from a continuation line, the same place and indent", at == 5 and pad == "      ", out)
  at, pad, out = expand_at(stmt, 5, "cond")
  check("statement: an if expands below its condition, inside the braces", at == 7 and pad == "      ", out)
  at, pad, out = expand_at(stmt, 7, "work")
  check("statement: a one-line statement keeps the row below", at == 8 and pad == "          ", out)
  view.close()
end

H.finish("EXPANDER")
