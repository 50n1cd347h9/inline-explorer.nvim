-- Real-kernel regression spec.
--
-- This plugin exists to read kernel source, so the kernel is not an optional
-- extra workload -- it is the workload. Everything else in the suite is a
-- proxy, and the proxies hid a real defect for the whole life of the
-- project: resolution results were never memoized, so every keystroke
-- reissued workspace/symbol and documentSymbol for a name already resolved.
-- On synthetic fixtures and on zlib a repeat lookup costs under a
-- millisecond, so nothing failed. On linux-6.12's kernel/sched/core.c the
-- same repeat walk cost p50 54.6ms, p90 166.0ms and 567.5ms at worst -- the
-- same as the first pass, because there was no second pass to speak of.
--
-- What this spec pins is therefore STRUCTURAL, not a timing threshold: the
-- second lookup of a name must not reach the server at all. That is asserted
-- by counting profile spans (`locate:cached` / `extract:cached` against
-- `locate:ok` / `extract:cold` / `extract:warm`), which is machine-speed
-- independent. Timings are reported alongside for information only, so a
-- slow machine cannot turn this red.
--
-- Requires a kernel tree with a compile_commands.json that actually covers
-- the file below. Point IE_KERNEL_DIR at it:
--
--   make kernel/sched/core.o
--   python3 scripts/clang-tools/gen_compile_commands.py -d . -o compile_commands.json
--   IE_KERNEL_DIR=/path/to/linux nvim --headless --clean -u NONE \
--     -c "set rtp+=." -c "luafile tests/real_kernel_spec.lua" -c "qa!"
--
-- A missing tree prints SKIP. As with the zlib spec, CI must NOT treat that
-- SKIP as green -- a real-source spec that quietly did nothing is
-- indistinguishable from one that passed, which is the exact failure this
-- suite has spent its history removing.
-- Same idiom as the other real-source specs: the documented invocation is
-- `--clean -u NONE`, which leaves the plugin off the runtimepath, so the
-- spec puts it there itself rather than depending on the caller.
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))

local profile = require("inline-explorer.profile")
local resolver = require("inline-explorer.resolver")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("  " .. tostring(detail)) or ""))
  end
end

local K = vim.env.IE_KERNEL_DIR
local TARGET = vim.env.IE_KERNEL_FILE or "kernel/sched/core.c"

local function bail(why)
  print("SKIP: " .. why)
  print("real kernel: skipped")
  vim.cmd("qa!")
end

if not K or K == "" then
  bail("IE_KERNEL_DIR not set")
  return
end
if vim.fn.isdirectory(K) == 0 then
  bail("IE_KERNEL_DIR is not a directory: " .. K)
  return
end
if vim.fn.executable("clangd") == 0 then
  bail("clangd not found on PATH")
  return
end

local cc = K .. "/compile_commands.json"
if vim.fn.filereadable(cc) == 0 then
  bail("no compile_commands.json in " .. K)
  return
end

-- A compile database that does not cover the target file would leave clangd
-- guessing flags, and every measurement below would describe something other
-- than kernel code. The pre-existing database in this project's sandbox had
-- 18 entries, all host tools, covering no kernel source at all -- so this is
-- checked rather than assumed.
do
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(cc), "\n"))
  local covered = false
  if ok and type(decoded) == "table" then
    for _, e in ipairs(decoded) do
      if type(e) == "table" and type(e.file) == "string" and e.file:find(TARGET, 1, true) then
        covered = true
        break
      end
    end
  end
  if not covered then
    bail(("compile_commands.json does not cover %s (a database of host tools only will not do)"):format(TARGET))
    return
  end
end

local path = K .. "/" .. TARGET
if vim.fn.filereadable(path) == 0 then
  bail("target not readable: " .. path)
  return
end

vim.lsp.config("clangd", {
  cmd = { "clangd", "--background-index=false", "--compile-commands-dir=" .. K, "--log=error" },
  root_dir = K,
  filetypes = { "c", "cpp" },
})
vim.lsp.enable("clangd")

vim.cmd("edit " .. vim.fn.fnameescape(path))
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = "c"

-- Ready means the server answers for THIS buffer, not merely that a client
-- object exists: clangd accepts the connection long before it has built this
-- translation unit's preamble, and a lookup issued in between measures the
-- preamble, not the lookup.
local READY_MS = tonumber(vim.env.IE_KERNEL_READY_MS or "") or 300000
local t0 = vim.uv.hrtime()
local ready = false
do
  local deadline = vim.uv.hrtime() + READY_MS * 1e6
  while vim.uv.hrtime() < deadline do
    local cs = vim.lsp.get_clients({ bufnr = buf })
    if #cs > 0 and cs[1].initialized then
      local r = cs[1]:request_sync("textDocument/documentSymbol",
        { textDocument = vim.lsp.util.make_text_document_params(buf) }, 30000, buf)
      if r and r.result then
        ready = true
        break
      end
    end
    vim.wait(200)
  end
end
local attach_ms = (vim.uv.hrtime() - t0) / 1e6

if not ready then
  bail(("clangd never became ready for %s within %dms"):format(TARGET, READY_MS))
  return
end
print(("clangd ready for %s in %.0fms"):format(TARGET, attach_ms))

-- Distinct callees in source order. A handful is enough: this asserts a
-- structural property, and each miss costs a real server round trip.
local WANT = tonumber(vim.env.IE_KERNEL_SITES or "") or 12
local names = {}
do
  local src = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local root = vim.treesitter.get_string_parser(src, "c"):parse()[1]:root()
  local q = vim.treesitter.query.parse("c", "(call_expression function: (identifier) @f)")
  local seen = {}
  for _, n in q:iter_captures(root, src) do
    local _, _, a, _, _, b = n:range(true)
    local nm = src:sub(a + 1, b)
    if not seen[nm] then
      seen[nm] = true
      names[#names + 1] = nm
    end
    if #names >= WANT * 4 then
      break
    end
  end
end

local function fetch(name)
  local done, lines = false, nil
  local t = vim.uv.hrtime()
  resolver.fetch(name, buf, function(l)
    lines = l
    done = true
  end)
  vim.wait(30000, function()
    return done
  end, 5)
  return (vim.uv.hrtime() - t) / 1e6, lines
end

local function span_counts()
  local c = { cached = 0, server = 0 }
  for _, e in ipairs(profile.events or {}) do
    local n = e.name or ""
    if n == "locate:cached" or n == "extract:cached" then
      c.cached = c.cached + 1
    elseif n == "locate:ok" or n == "extract:cold" or n == "extract:warm" then
      c.server = c.server + 1
    end
  end
  return c
end

-- First pass: whatever resolves, resolves. Names that do not resolve here
-- (macros, header inlines clangd cannot see without a background index) are
-- dropped rather than counted -- a decline is not a cache miss.
profile.enabled = true
profile.max_events = 4000
local resolved, first_ms = {}, {}
for _, nm in ipairs(names) do
  local ms, lines = fetch(nm)
  if lines then
    resolved[#resolved + 1] = nm
    first_ms[#first_ms + 1] = ms
  end
  if #resolved >= WANT then
    break
  end
end

check(("resolved at least %d callees in %s"):format(math.min(WANT, 4), TARGET),
  #resolved >= math.min(WANT, 4), ("resolved=%d of %d tried"):format(#resolved, #names))

if #resolved == 0 then
  print("real kernel: nothing resolved; cannot assert the cache invariant")
  print(fails == 0 and "1 FAILURE(S)" or (fails .. " FAILURE(S)"))
  vim.cmd("cq")
  return
end

-- Second pass over exactly the same names, with the span log cleared so the
-- counts below describe this pass only.
profile.clear()
local second_ms = {}
for _, nm in ipairs(resolved) do
  local ms, lines = fetch(nm)
  second_ms[#second_ms + 1] = ms
  if not lines then
    check("repeat fetch of " .. nm .. " still returns a body", false)
  end
end
local c = span_counts()

check("repeat lookups are served from cache, not the server",
  c.server == 0 and c.cached > 0,
  ("cached spans=%d server spans=%d over %d repeat lookups"):format(c.cached, c.server, #resolved))

-- Editing the DEFINITION's file must retire the entries rather than serve a
-- stale body. Deliberately not the source buffer: entries are keyed on the
-- definition file's state, so editing the file you are reading from does not
-- (and should not) invalidate anything -- and in this file most callees are
-- defined in this same file, so an edit here would pass for the wrong reason
-- and the check would prove nothing about the guard it names.
do
  local probe = resolved[1]
  local def_loc
  do
    local done = false
    resolver.locate(probe, buf, function(l)
      def_loc = l
      done = true
    end)
    vim.wait(30000, function()
      return done
    end, 5)
  end

  if not def_loc then
    check("located the definition to probe invalidation with", false, probe)
  else
    local def_buf = vim.uri_to_bufnr(def_loc.uri)
    vim.fn.bufload(def_buf)
    profile.clear()
    vim.api.nvim_buf_set_lines(def_buf, 0, 0, false, { "/* inline-explorer cache invalidation probe */" })
    local _, after_edit = fetch(probe)
    local ce = span_counts()
    check("an edit to the definition's file retires the cached lookup",
      ce.server > 0,
      ("probe=%s def=%s cached=%d server=%d"):format(probe, vim.uri_to_fname(def_loc.uri), ce.cached, ce.server))
    check("the lookup after an edit still returns a body", after_edit ~= nil)
    vim.api.nvim_buf_set_lines(def_buf, 0, 1, false, {})
  end
end

local function pct(t, p)
  local s = vim.deepcopy(t)
  table.sort(s)
  return s[math.max(1, math.ceil(#s * p / 100))]
end
print(("\nreal kernel: %s  attach=%.0fms  first p50=%.1fms p90=%.1fms  repeat p50=%.1fms p90=%.1fms  n=%d")
  :format(TARGET, attach_ms, pct(first_ms, 50), pct(first_ms, 90),
    pct(second_ms, 50), pct(second_ms, 90), #resolved))
print("(timings are reported, not asserted -- the pass/fail gate above is span-shaped)")

print("")
if fails == 0 then
  print("ALL REAL KERNEL TESTS PASSED")
  vim.cmd("qa!")
else
  print(fails .. " FAILURE(S)")
  vim.cmd("cq")
end
