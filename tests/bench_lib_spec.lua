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

-- elapsed_ms: end-to-end latency derived from span timestamps, not from any
-- single span's own duration.
do
  -- Two-phase action: the first span covers a slow phase (started at 500,
  -- stopped -- and so recorded with at=1000, ms=500); the second span
  -- covers a fast phase that starts right after and stops at at=1500 with
  -- an own duration of just 5ms. The true end-to-end is 500..1500 = 1000ms
  -- -- elapsed_ms must report that, not the last span's own 5ms, which is
  -- exactly what a block-paste fallback's final splice span would look like
  -- if the resolve before it got ten times slower: the splice's own ms
  -- barely moves, but the action's true latency does.
  local spans = {
    { name = "total:block-fallback", ms = 500, at = 1000 },
    { name = "total:expand", ms = 5, at = 1500 },
  }
  check("elapsed_ms: reports the whole action's span, not the last span's own ms",
    bench.elapsed_ms(spans) == 1000, bench.elapsed_ms(spans))
  check("elapsed_ms: differs from the last span's own (far smaller) duration",
    bench.elapsed_ms(spans) ~= spans[#spans].ms, bench.elapsed_ms(spans))
  check("elapsed_ms: empty list is safe and returns nil",
    bench.elapsed_ms({}) == nil, bench.elapsed_ms({}))
end

-- capture: collects the spans a call produced, waiting for the total: span.
do
  profile.enabled = true
  profile.logfile = false
  profile.clear()
  profile.start()("stale:before") -- must not be captured

  local spans, complete = bench.capture(function()
    profile.start()("locate:ok")
    profile.start()("extract:warm")
    profile.start()("total:expand")
  end, 1000)
  check("capture: only this call's spans", #spans == 3, bench.names(spans))
  check("capture: excludes earlier spans", bench.count(spans, "^stale") == 0, bench.names(spans))
  check("capture: count by pattern", bench.count(spans, "^extract:") == 1, bench.names(spans))
  check("capture: total_ms reads the total: span", type(bench.total_ms(spans)) == "number", vim.inspect(spans))
  check("capture: names joins for diagnostics", bench.names(spans):find("total:expand", 1, true) ~= nil, bench.names(spans))

  -- complete: true for a normal action whose last span is a total: one, and
  -- assert_complete agrees with a nil reason.
  check("capture: complete true for a normal action", complete == true, complete)
  local ok1, reason1 = bench.assert_complete(spans)
  check("assert_complete: true, nil reason for a normal action", ok1 == true and reason1 == nil, tostring(reason1))

  -- No total: span -> capture gives up at the timeout and returns what it saw,
  -- and reports itself as not complete (the action never finished).
  local partial, partial_complete = bench.capture(function()
    profile.start()("locate:ok")
  end, 300)
  check("capture: returns partial spans when no total: arrives", #partial == 1, bench.names(partial))
  check("capture: complete false when no total: span arrives", partial_complete == false, partial_complete)
  local ok2, reason2 = bench.assert_complete(partial)
  check(
    "assert_complete: false with a 'did not finish' reason",
    ok2 == false and reason2 ~= nil and reason2:find("did not finish", 1, true) ~= nil,
    tostring(reason2)
  )

  -- Empty action: no spans at all within a short timeout -> not complete,
  -- and the reason says so distinctly from "did not finish".
  local empty, empty_complete = bench.capture(function() end, 300)
  check("capture: no spans at all for an empty action", #empty == 0, bench.names(empty))
  check("capture: complete false for an empty action", empty_complete == false, empty_complete)
  local ok_empty, reason_empty = bench.assert_complete(empty)
  check(
    "assert_complete: false with a 'no spans' reason for an empty action",
    ok_empty == false and reason_empty ~= nil and reason_empty:find("no spans", 1, true) ~= nil,
    tostring(reason_empty)
  )

  -- Two-phase action: inliner.smart's block-paste fallback (reached when the
  -- initial resolve fails to locate anything) emits total:block-fallback and
  -- then hands off to expander.expand, which performs its own independent
  -- round trip and emits its own total:expand. That is ONE user action
  -- legitimately producing TWO total: spans -- complete must be true (this is
  -- not an error), and total_ms must read the LAST total:, not the first, so
  -- the end-to-end number reflects the whole two-phase action.
  local twophase, twophase_complete = bench.capture(function()
    profile.start()("locate:ok")
    -- A span's ms is the time between profile.start() and invoking the
    -- returned closure, so delaying only the first total:'s invocation
    -- deterministically makes its ms bigger than the second's -- the test
    -- really pins "last, not first" rather than tying on ~0ms for both.
    local first = profile.start()
    vim.wait(30)
    first("total:block-fallback")
    local second = profile.start()
    second("total:expand")
  end, 1000)
  check("capture: two-phase action is complete, not an error", twophase_complete == true, twophase_complete)
  local ok_two, reason_two = bench.assert_complete(twophase)
  check("assert_complete: true for a two-phase action", ok_two == true and reason_two == nil, tostring(reason_two))
  check("capture: two-phase action has both total: spans", bench.count(twophase, "^total:") == 2, bench.names(twophase))
  do
    local first_ms, last_ms
    for _, s in ipairs(twophase) do
      if s.name:find("^total:") then
        if not first_ms then
          first_ms = s.ms
        end
        last_ms = s.ms
      end
    end
    check(
      "total_ms: reads the LAST total: span, and it differs from the first",
      bench.total_ms(twophase) == last_ms and last_ms ~= first_ms,
      ("total_ms=%s first=%s last=%s"):format(tostring(bench.total_ms(twophase)), tostring(first_ms), tostring(last_ms))
    )
  end

  -- Ring pressure: profile.events evicts from the front once full, so an
  -- index-based slice loses spans as soon as the ring is full. capture
  -- clears the ring before running the action instead, so what was already
  -- in it (however full) cannot leak into or crowd out this capture.
  profile.max_events = 8
  for _ = 1, 8 do
    profile.start()("filler")
  end
  local ring_spans = bench.capture(function()
    profile.start()("locate:ok")
    profile.start()("extract:warm")
    profile.start()("total:expand")
  end, 1000)
  check("capture: exactly this call's spans even with a full ring", #ring_spans == 3, bench.names(ring_spans))
  check("capture: extract count survives a full ring", bench.count(ring_spans, "^extract:") == 1, bench.names(ring_spans))
  local has_filler = false
  for _, s in ipairs(ring_spans) do
    if s.name == "filler" then
      has_filler = true
    end
  end
  check("capture: no filler span leaks into the capture", not has_filler, bench.names(ring_spans))
  profile.max_events = 200

  -- Settle wait: capture observes for the full settle window (default
  -- 300ms) regardless of when the ring last changed, so a straggler span
  -- landing shortly after total: (e.g. scheduled via vim.defer_fn) is still
  -- within that window and gets captured.
  local q_spans = bench.capture(function()
    profile.start()("locate:ok")
    profile.start()("extract:warm")
    profile.start()("total:expand")
    vim.defer_fn(function()
      profile.start()("extract:late")
    end, 40)
  end, 1000)
  check("capture: waits out a straggler span scheduled past total:", #q_spans == 4, bench.names(q_spans))
  check("capture: the straggler span itself is present", bench.count(q_spans, "^extract:late") == 1, bench.names(q_spans))

  -- Settle floor: the settle wait must never observe for less time than the
  -- flat 120ms wait it replaced, so a span deferred to ~90ms (comfortably
  -- inside the floor) must still be caught even though nothing else happens
  -- in between.
  local floor_spans = bench.capture(function()
    profile.start()("total:expand")
    vim.defer_fn(function()
      profile.start()("extract:late")
    end, 90)
  end, 1000)
  check("capture: settle floor still catches a span deferred ~90ms out", #floor_spans == 2, bench.names(floor_spans))
  check(
    "capture: settle floor -- the deferred span itself is present",
    bench.count(floor_spans, "^extract:late") == 1,
    bench.names(floor_spans)
  )

  -- settle_cap_ms: a multi-phase action (e.g. inliner.smart's block-fallback
  -- handing off to expander.expand) can have its second phase land well past
  -- the default 300ms cap. With the default, that second total: span is not
  -- captured at all -- capture stops observing before it arrives, and the
  -- span silently lands in whatever capture runs next. Passing an explicit,
  -- larger settle_cap_ms is the only way to actually see it.
  do
    local default_spans = bench.capture(function()
      profile.start()("total:block-fallback")
      vim.defer_fn(function()
        profile.start()("total:expand")
      end, 600)
    end, 1000)
    check("capture: default settle_cap_ms does NOT catch a phase deferred ~600ms out",
      #default_spans == 1 and bench.count(default_spans, "^total:expand") == 0, bench.names(default_spans))

    -- Drain the straggler total:expand that the previous capture's clear()
    -- did not wait for, so it cannot leak into the next capture below.
    vim.wait(700, function()
      return false
    end, 50)
    profile.clear()

    local capped_spans = bench.capture(function()
      profile.start()("total:block-fallback")
      vim.defer_fn(function()
        profile.start()("total:expand")
      end, 600)
    end, 2000, { settle_cap_ms = 3000 })
    check("capture: settle_cap_ms = 3000 catches a phase deferred ~600ms out",
      #capped_spans == 2 and bench.count(capped_spans, "^total:expand") == 1, bench.names(capped_spans))
    check("capture: with the larger cap, the action reports complete",
      capped_spans[#capped_spans] and capped_spans[#capped_spans].name:find("^total:") ~= nil, bench.names(capped_spans))
  end

  -- until_span: the caller declares its own action's terminal span so the
  -- settle can exit as soon as one appears (and the 120ms floor has
  -- elapsed), instead of always waiting out settle_cap_ms.
  do
    -- The terminal span is emitted synchronously, so once the 120ms floor
    -- passes, until_span should match immediately -- wall time should land
    -- near the floor, nowhere close to the generous 3000ms cap given here.
    local start = vim.uv.now()
    local spans, complete = bench.capture(function()
      profile.start()("total:expand")
    end, 1000, { settle_cap_ms = 3000, until_span = "^total:expand" })
    local elapsed = vim.uv.now() - start
    check("until_span: a matching terminal span exits well under settle_cap_ms",
      elapsed < 1000, elapsed)
    check("until_span: still respects the 120ms floor even on early exit",
      elapsed >= 120, elapsed)
    check("until_span: the terminal span is still present in the result",
      complete == true and bench.count(spans, "^total:expand") == 1, bench.names(spans))

    -- A pattern that never matches must wait out the full settle_cap_ms --
    -- until_span is caller-declared, not a promise that capture can detect
    -- "nothing more is coming" on its own.
    local start2 = vim.uv.now()
    local never_spans = bench.capture(function()
      profile.start()("total:block-fallback")
    end, 1000, { settle_cap_ms = 500, until_span = "^total:expand" })
    local elapsed2 = vim.uv.now() - start2
    check("until_span: a pattern that never matches waits out the full cap",
      elapsed2 >= 500, elapsed2)
    check("until_span: no total:expand span appears when it never matched",
      bench.count(never_spans, "^total:expand") == 0, bench.names(never_spans))
  end

  profile.enabled = false
  profile.clear()
end

-- Fixture generation is pure file IO and checkable without clangd.
do
  local fixture = require("tests.fixtures.bench.gen")
  local dir = vim.fn.tempname()
  local meta = fixture.generate(dir)

  check("fixture: main.c written", vim.fn.filereadable(meta.main) == 1, meta.main)
  check("fixture: heavy chain written",
    vim.fn.filereadable(dir .. "/heavy_0.h") == 1 and vim.fn.filereadable(dir .. "/heavy_" .. (fixture.HEAVY_DEPTH - 1) .. ".h") == 1)
  check("fixture: enough distinct cold headers for a full run",
    #meta.cold >= 18 and vim.fn.filereadable(dir .. "/c1.h") == 1, #meta.cold)
  check("fixture: enough warm symbols in one header", #meta.warm >= 18, #meta.warm)

  local main = table.concat(vim.fn.readfile(meta.main), "\n")
  check("fixture: one call site per cold symbol on its own line",
    main:find("acc %+= " .. meta.cold[1] .. "%(") ~= nil and main:find("acc %+= " .. meta.cold[18] .. "%(") ~= nil)
  check("fixture: one call site per warm symbol on its own line",
    main:find("acc %+= " .. meta.warm[18] .. "%(") ~= nil)
  check("fixture: same-file definition present", main:find("static int " .. meta.same_file .. "%(") ~= nil)
  check("fixture: macro use present", main:find(meta.macro_call .. "%(") ~= nil)
  check("fixture: struct for the non-inlinable path", main:find("struct " .. meta.struct_name) ~= nil)

  local cc = table.concat(vim.fn.readfile(dir .. "/compile_commands.json"), "\n")
  check("fixture: compile_commands has an absolute file path", cc:find(meta.main, 1, true) ~= nil, cc:sub(1, 200))
  check("fixture: compile_commands is valid json", pcall(vim.json.decode, cc))

  -- Generation is deterministic: same input, same bytes.
  local dir2 = vim.fn.tempname()
  fixture.generate(dir2)
  check("fixture: generation is deterministic",
    table.concat(vim.fn.readfile(dir .. "/c1.h"), "\n") == table.concat(vim.fn.readfile(dir2 .. "/c1.h"), "\n"))
end

print("")
print(fails == 0 and "ALL BENCH LIB TESTS PASSED" or (fails .. " FAILURE(S)"))
