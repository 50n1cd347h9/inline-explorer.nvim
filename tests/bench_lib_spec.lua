-- Unit tests for the benchmark support layer. Pure: no clangd, no LSP.
--   nvim --headless --clean -u NONE -c "luafile tests/bench_lib_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local bench = require("tests.lib.bench")
local profile = require("inline-explorer.profile")

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and ("\n----\n" .. tostring(d) .. "\n----") or ""))
  end
end

-- stats: percentiles, not means. 1..10 has mean 5.5 but p50 5.
do
  local s = bench.stats({ 5, 1, 3, 2, 4, 6, 7, 8, 9, 10 })
  check("stats: n", s.n == 10, s.n)
  check("stats: min/max", s.min == 1 and s.max == 10, vim.inspect(s))
  check("stats: p50 is a percentile, not a mean", s.p50 == 5, s.p50)
  check("stats: p90", s.p90 == 9, s.p90)
  -- A single huge outlier moves a mean a lot and p50 not at all.
  local skewed = bench.stats({ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1000 })
  check("stats: p50 resists a right-tail outlier", skewed.p50 == 1, skewed.p50)
  check("stats: p90 does not hide it entirely", skewed.p90 >= 1, skewed.p90)
  check("stats: mad reported", type(skewed.mad) == "number", vim.inspect(skewed))
  check("stats: empty input is safe", bench.stats({}).n == 0)
end

-- run: warmup samples are discarded, the rest returned in order.
do
  local seen = {}
  local samples = bench.run(function(i)
    seen[#seen + 1] = i
    return i * 10
  end, { warmup = 3, reps = 5 })
  check("run: action called warmup+reps times", #seen == 8, #seen)
  check("run: warmup discarded", #samples == 5 and samples[1] == 40, vim.inspect(samples))
  -- a rep that returns nil is skipped, not counted as zero
  local sparse = bench.run(function(i)
    return (i % 2 == 0) and 1 or nil
  end, { warmup = 0, reps = 4 })
  check("run: nil reps are skipped, not zero-filled", #sparse == 2, vim.inspect(sparse))
end

-- noise_floor: two independent populations of the same action.
do
  local n = 0
  local floor, a, b = bench.noise_floor(function()
    n = n + 1
    return 100 -- perfectly stable action
  end, { warmup = 1, reps = 4 })
  check("noise_floor: zero for a perfectly stable action", floor == 0, floor)
  check("noise_floor: ran two populations", n == 10, n)
  check("noise_floor: returns both populations", a.n == 4 and b.n == 4, vim.inspect({ a, b }))

  local seq, idx = { 10, 10, 10, 10, 30, 30, 30, 30 }, 0
  local floor2 = bench.noise_floor(function()
    idx = idx + 1
    return seq[idx]
  end, { warmup = 0, reps = 4 })
  check("noise_floor: reports the p50 gap between populations", floor2 == 20, floor2)
end

-- capture: collects the spans a call produced, waiting for the total: span.
do
  profile.enabled = true
  profile.logfile = false
  profile.clear()
  profile.start()("stale:before") -- must not be captured

  local spans = bench.capture(function()
    profile.start()("locate:ok")
    profile.start()("extract:warm")
    profile.start()("total:expand")
  end, 1000)
  check("capture: only this call's spans", #spans == 3, bench.names(spans))
  check("capture: excludes earlier spans", bench.count(spans, "^stale") == 0, bench.names(spans))
  check("capture: count by pattern", bench.count(spans, "^extract:") == 1, bench.names(spans))
  check("capture: total_ms reads the total: span", type(bench.total_ms(spans)) == "number", vim.inspect(spans))
  check("capture: names joins for diagnostics", bench.names(spans):find("total:expand", 1, true) ~= nil, bench.names(spans))

  -- No total: span -> capture gives up at the timeout and returns what it saw.
  local partial = bench.capture(function()
    profile.start()("locate:ok")
  end, 300)
  check("capture: returns partial spans when no total: arrives", #partial == 1, bench.names(partial))

  profile.enabled = false
  profile.clear()
end

print("")
print(fails == 0 and "ALL BENCH LIB TESTS PASSED" or (fails .. " FAILURE(S)"))
