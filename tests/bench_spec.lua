-- Performance regression harness. Drives the REAL user actions against a real
-- clangd and asserts structural invariants -- how many round trips an action
-- costs, and whether the attach cache is doing its job. These hold regardless
-- of machine speed, which is why they are the pass/fail gate; timings are
-- reported separately (see the report section below).
--
--   nvim --headless --clean -u NONE -c "luafile tests/bench_spec.lua" -c "qa!"
--
-- Env: IE_BENCH_CLANGD (clangd path), IE_BENCH_REPS, IE_BENCH_WARMUP
local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":h:h")
vim.opt.rtp:append(root)

local bench = require("tests.lib.bench")
local fixture = require("tests.fixtures.bench.gen")
local profile = require("inline-explorer.profile")
local view = require("inline-explorer.view")
local expander = require("inline-explorer.expander")
local inliner = require("inline-explorer.inliner")
local history = require("inline-explorer.history")
local resolver = require("inline-explorer.resolver")

local clangd = os.getenv("IE_BENCH_CLANGD") or "clangd"
if vim.fn.executable(clangd) == 0 then
  print("SKIP: clangd not found (set IE_BENCH_CLANGD)")
  return
end

local REPS = tonumber(os.getenv("IE_BENCH_REPS") or "") or 15
local WARMUP = tonumber(os.getenv("IE_BENCH_WARMUP") or "") or 3

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and ("\n----\n" .. tostring(d) .. "\n----") or ""))
  end
end

require("inline-explorer").setup({ profile = true })
profile.logfile = false -- the report is the output; no user log from a bench

-- ---------------------------------------------------------------------------
-- Fixture + server
-- ---------------------------------------------------------------------------
local dir = vim.fn.tempname()
local meta = fixture.generate(dir)

vim.cmd.edit(meta.main)
local sbuf = vim.api.nvim_get_current_buf()
vim.lsp.start({ name = "clangd", cmd = { clangd, "--background-index" }, root_dir = dir })
vim.wait(15000, function()
  return #vim.lsp.get_clients({ bufnr = sbuf, name = "clangd" }) > 0
end, 50)
if #vim.lsp.get_clients({ bufnr = sbuf, name = "clangd" }) == 0 then
  print("SKIP: clangd did not attach")
  return
end

-- Wait until the background index can answer for a symbol that lives in a
-- header -- that is the precondition for every scenario below.
local indexed = false
for _ = 1, 120 do
  local done = false
  resolver.locate(meta.warm[1], sbuf, function(loc)
    indexed, done = loc ~= nil, true
  end)
  vim.wait(3000, function()
    return done
  end, 20)
  if indexed then
    break
  end
  vim.wait(500)
end
if not indexed then
  print("SKIP: clangd index never answered workspace/symbol")
  return
end

local vbuf = view.open()
local st = view.current()

-- ---------------------------------------------------------------------------
-- Driving helpers
-- ---------------------------------------------------------------------------

-- Put the cursor on the first occurrence of `pat` in the view. Returns false
-- when the pattern is absent (a scenario that cannot run must say so rather
-- than silently measure the wrong thing).
local function goto_pattern(pat)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(vbuf, 0, -1, false)) do
    local c = l:find(pat)
    if c then
      vim.api.nvim_win_set_cursor(0, { i, c - 1 })
      return true
    end
  end
  return false
end

-- Run one action on `pat` and hand back its spans, leaving the view as it was
-- (every action mutates the buffer; undo keeps reps independent).
-- Returns (spans, complete). `complete` is false when the action never
-- reached its own final total: span within the timeout. Callers must not
-- read counts off an incomplete capture.
local function act(pat, fn)
  if not goto_pattern(pat) then
    return nil, false
  end
  local spans, complete = bench.capture(fn, 30000)
  history.undo()
  return spans, complete
end

local function expand_on(pat)
  return act(pat, expander.expand)
end
local function inline_on(pat)
  return act(pat, inliner.smart)
end

-- ---------------------------------------------------------------------------
-- Structural invariants -- the gate
-- ---------------------------------------------------------------------------
print("=== structural invariants ===")

-- 1. One expansion costs exactly one locate and one extract.
do
  local spans, complete = expand_on(meta.cold[1] .. "%(")
  check("capture completed within the timeout", complete == true,
    spans and (bench.names(spans) .. " -- " .. tostring(select(2, bench.assert_complete(spans)))))
  check("one expand = one locate + one extract",
    complete and bench.count(spans, "^locate:") == 1 and bench.count(spans, "^extract:") == 1,
    spans and bench.names(spans))
end

-- 2. A second symbol from an already-attached header is warm, not cold.
do
  local first, first_complete = expand_on(meta.warm[1] .. "%(")
  local second, second_complete = expand_on(meta.warm[2] .. "%(")
  check("first touch of a header is cold",
    first_complete and bench.count(first, "^extract:cold") == 1, first and bench.names(first))
  check("second symbol from the same header is warm",
    second_complete and bench.count(second, "^extract:warm") == 1, second and bench.names(second))
end

-- 3. Falling back to block-paste must not re-resolve: the inliner already has
--    the body and hands it over.
do
  -- Cursor must land on the type name itself so <cword> resolves the struct
  -- symbol, not on a preceding "struct " keyword (which <cword> would read
  -- as the C keyword "struct", not a resolvable name).
  local spans, complete = inline_on(meta.struct_name)
  check("block fallback happened",
    complete and bench.count(spans, "^total:block%-fallback") == 1, spans and bench.names(spans))
  check("block fallback costs no second lookup",
    complete and bench.count(spans, "^locate:") == 1 and bench.count(spans, "^extract:") == 1,
    spans and bench.names(spans))
end

-- 4. A definition in the file being edited opens nothing new.
do
  local spans, complete = expand_on(meta.same_file .. "%(3%)")
  check("same-file definition is never a cold extraction",
    complete and bench.count(spans, "^extract:cold") == 0 and bench.count(spans, "^extract:") == 1,
    spans and bench.names(spans))
end

-- 5. A macro resolves through the tweak; the hover scrape is a fallback for
--    servers that cannot do better, and must not be reached here.
do
  -- "%(" alone matches the #define line itself (earlier in the generated
  -- file than the call site); disambiguate with the call's argument, same
  -- idiom as the same-file scenario above, so the cursor lands on the actual
  -- invocation in main() where the ExpandMacro tweak applies.
  local spans, complete = inline_on(meta.macro_call .. "%(4%)")
  check("macro uses the ExpandMacro tweak",
    complete and bench.count(spans, "^macro:tweak$") == 1, spans and bench.names(spans))
  check("macro does not fall back to hover scraping",
    complete and bench.count(spans, "^macro:hover") == 0, spans and bench.names(spans))
end

print("")
print(fails == 0 and "ALL BENCH TESTS PASSED" or (fails .. " FAILURE(S)"))
