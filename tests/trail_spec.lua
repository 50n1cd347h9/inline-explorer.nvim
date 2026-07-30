-- Trail: the navigation stack behind callers/definition jumps.
-- Counts and states only -- no timing assertions.
--   nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/trail_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))

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

-- Three tiny real files to travel between.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local paths = {}
for i = 1, 3 do
  paths[i] = ("%s/f%d.c"):format(dir, i)
  local f = assert(io.open(paths[i], "w"))
  f:write(("int f%d(void)\n{\n    return %d;\n}\n"):format(i, i))
  f:close()
end
local function loc_of(i)
  return { uri = vim.uri_from_fname(paths[i]),
    range = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 6 } } }
end

-- Start inside a view of f1 (trail is a view-world feature).
vim.cmd.edit(paths[1])
local v1 = view.open()
check("setup: view.open returns the view bufnr", type(v1) == "number" and view.state[v1] ~= nil)

-- goto_location pushes and switches.
trail.goto_location(loc_of(2))
local v2 = vim.api.nvim_get_current_buf()
check("goto: lands in a DIFFERENT view buffer", v2 ~= v1 and view.state[v2] ~= nil, v2)
check("goto: cursor at the target range", vim.api.nvim_win_get_cursor(0)[1] == 1)
check("goto: previous view still alive (bufhidden=hide while stacked)",
  vim.api.nvim_buf_is_valid(v1) and vim.bo[v1].bufhidden == "hide", vim.bo[v1].bufhidden)

-- back restores the SAME buffer -- identity, not a recreation.
check("back: returns true when there is history", trail.back() == true)
check("back: the very same buffer is shown again", vim.api.nvim_get_current_buf() == v1)
check("back at the bottom: returns false, stays put",
  trail.back() == false and vim.api.nvim_get_current_buf() == v1)

-- forward re-enters v2; a NEW navigation from a back-state drops forward history.
check("forward: returns true", trail.forward() == true)
check("forward: lands back in v2", vim.api.nvim_get_current_buf() == v2)
trail.back()
trail.goto_location(loc_of(3))
check("new navigation from a back-state: forward history is dropped",
  trail.forward() == false)

-- Reuse: navigating to a file whose view exists reuses THE BUFFER.
local v3 = vim.api.nvim_get_current_buf()
trail.goto_location(loc_of(2))
check("reuse: an existing view buffer is reused, not recreated",
  vim.api.nvim_get_current_buf() == v2)

-- Eviction: shrink the cap and overflow it; evicted buffers are wiped.
trail.clear()
check("clear: stack empty and stacked views wiped",
  #trail._stack == 0 and not vim.api.nvim_buf_is_valid(v1), tostring(vim.api.nvim_buf_is_valid(v1)))

local saved_n = trail._stack_n
trail._stack_n = 2
vim.cmd.edit(paths[1])
local a = view.open()
trail.goto_location(loc_of(2))
local b = vim.api.nvim_get_current_buf()
trail.goto_location(loc_of(3))
trail.goto_location(loc_of(1)) -- pushes b's entry beyond the cap? no: pushes v3's; a's entry evicted
check("eviction: depth never exceeds the cap", #trail._stack <= 2, #trail._stack)
check("eviction: the oldest stacked view was wiped",
  not vim.api.nvim_buf_is_valid(a), tostring(vim.api.nvim_buf_is_valid(a)))
check("eviction: newer stacked views survive", vim.api.nvim_buf_is_valid(b))
trail._stack_n = saved_n
trail.clear()

-- Abandoning a fresh view by a plain buffer switch must not leak its
-- state entry. bufhidden=wipe kills the buffer; before the fix the entry
-- -- origin array plus undo snapshots -- stayed in view.state forever,
-- because close() requires the view to be current and the trail sweep
-- skipped invalid buffers.
do
  trail.clear()
  vim.cmd.edit(paths[1])
  local src = vim.api.nvim_get_current_buf()
  local v = view.open()
  check("leak: view registered", view.state[v] ~= nil)
  vim.api.nvim_set_current_buf(src)
  vim.wait(500, function() return view.state[v] == nil end, 10)
  check("leak: abandoning the view by a buffer switch drops its state entry",
    view.state[v] == nil and not vim.api.nvim_buf_is_valid(v),
    ("state=%s valid=%s"):format(tostring(view.state[v] ~= nil), tostring(vim.api.nvim_buf_is_valid(v))))
end

-- Undo snapshots are capped: full-buffer copies measured 10.1 MB after 50
-- expansions of a 10k-line view before the cap existed.
do
  local history = require("inline-explorer.history")
  vim.cmd.edit(paths[2])
  local v = view.open()
  local st = view.state[v]
  local saved = history._cap
  history._cap = 5
  for _ = 1, 12 do
    history.snapshot(st, v)
  end
  check("undo cap: depth bounded by the cap", #st.undo <= 5, #st.undo)
  history._cap = saved
  view.close()
end

print("")
print(fails == 0 and "ALL TRAIL TESTS PASSED" or (fails .. " FAILURE(S)"))
if fails > 0 then vim.cmd("cq") end
vim.cmd("qa!")
