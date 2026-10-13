-- Benchmark support: percentile statistics, a repetition runner that discards
-- warmup, a noise-floor measurement, and capture of the profile spans one
-- user action produced.
--
-- Deliberately has no mean(): latency distributions are right-skewed, so a
-- mean (and a standard deviation around it) misleads. Everything here is
-- percentile-based.
local profile = require("inline-explorer.profile")

local M = {}

-- Percentile summary of `samples` (a list of numbers, any order).
function M.stats(samples)
  local s = {}
  for i, v in ipairs(samples) do
    s[i] = v
  end
  table.sort(s)
  local n = #s
  if n == 0 then
    return { n = 0 }
  end
  local function q(p)
    return s[math.min(n, math.max(1, math.ceil(p * n)))]
  end
  local p50 = q(0.5)
  local dev = {}
  for i, v in ipairs(s) do
    dev[i] = math.abs(v - p50)
  end
  table.sort(dev)
  return {
    n = n,
    min = s[1],
    max = s[n],
    p50 = p50,
    p90 = q(0.9),
    mad = dev[math.min(n, math.max(1, math.ceil(0.5 * n)))],
  }
end

-- Run `action(i)` warmup+reps times, keeping only the post-warmup results.
-- `action` returns the elapsed milliseconds, or nil for a rep that did not
-- produce a usable measurement (skipped, not counted as zero).
function M.run(action, opts)
  opts = opts or {}
  local warmup = opts.warmup or 3
  local reps = opts.reps or 15
  local out = {}
  for i = 1, warmup + reps do
    local ms = action(i)
    if i > warmup and ms then
      out[#out + 1] = ms
    end
  end
  return out
end

-- The harness's own reproducibility: run the same action as two independent
-- populations and report the gap between their medians. A measured difference
-- smaller than this is not a difference.
function M.noise_floor(action, opts)
  local a = M.stats(M.run(action, opts))
  local b = M.stats(M.run(action, opts))
  if a.n == 0 or b.n == 0 then
    return math.huge, a, b
  end
  return math.abs(a.p50 - b.p50), a, b
end

-- Spans produced by one user action, attributed by time window: capture owns
-- the ring from before `fn` is called until the settle below finishes -- `fn`
-- itself usually returns immediately, having only started an async chain, so
-- the window that matters is the settle, not the call. Everything recorded in
-- that window is taken as this action's.
--
-- `profile.events` is a ring buffer (`profile.max_events`, default 200) that
-- evicts from the FRONT via `table.remove(events, 1)` once full. An
-- index-based slice (snapshot the length before, take everything after)
-- silently loses spans as soon as the ring has filled and started evicting,
-- because every push after that shifts surviving indices down -- a captured
-- three-span action can come back as one, with no error and a total_ms that
-- still resolves, so the result looks plausible instead of obviously broken.
-- To avoid that, capture takes ownership of the ring instead: it clears it
-- before running `fn`, so every span present afterwards belongs to this
-- action (a single action produces well under `max_events` spans, so no
-- eviction can happen within one capture). `profile.clear()` with no
-- argument only resets the in-memory ring and leaves the log file alone,
-- which is what we want. Callers must not expect the profile report to
-- survive a capture -- it owns the ring for the duration of the call.
--
-- Window attribution is exact for every action that does not hit an
-- extract timeout. One instrumented call CAN land after the final
-- `total:` span: the resolver's retry-after-timeout probe fires a
-- background documentSymbol whose extract:retry-* span arrives late by
-- design (a real log shows it printing after total:inline-function).
-- That is reachable only when an extract timed out, which never happens
-- against the healthy in-process fixtures here -- and if it did, the
-- late span would land in this capture's settle window and flip
-- `complete` false, failing the scenario loudly rather than skewing a
-- number silently. An earlier version of this paragraph claimed nothing
-- is ever recorded after total:, which the retry probe had already made
-- false.
--
-- `opts.settle_cap_ms` (default 300, floored at 120ms) is the settle wait
-- below -- the observation window for a multi-phase action such as a
-- block-paste fallback, whose second phase (the handoff to
-- `expander.expand`) can legitimately land well after the first `total:`
-- span. capture observes for exactly this long, unconditionally: an earlier
-- version of this wait tried to be clever and return early once the span
-- count looked stable, but "stable" is indistinguishable from "the next
-- phase hasn't started yet" when the first phase's own span already matches
-- `^total:` (as `total:block-fallback` does) -- that is precisely how a
-- genuinely-violating multi-phase action can look complete before it is. So
-- there is no shortcut in general: this is a real limitation, not just a
-- tuning knob. A phase that lands LATER than `settle_cap_ms` after `fn` was
-- called is not captured here at all -- it is silently attributed to the
-- NEXT capture instead (whose ring gets cleared out from under it once that
-- capture starts, or which picks it up as a foreign span if it arrives after
-- that clear). Callers whose action can have a phase landing near or past
-- the default 300ms after its first total: must pass a larger
-- `settle_cap_ms` explicitly; there is no way for `capture` to detect that
-- this happened after the fact.
--
-- `opts.until_span` (a Lua pattern) lets the CALLER declare what its own
-- action's terminal span looks like, so the settle can exit as soon as one
-- appears (and >=120ms has passed) instead of always waiting out
-- settle_cap_ms. It is caller-declared on purpose: a list of handoff names
-- kept here would silently stop working the day another handoff span is
-- added, and nothing would catch it.
--
-- Returns `spans, complete`. `complete` is true iff the LAST span in the
-- list matches `^total:` -- i.e. the action ran to its own end within
-- `timeout` rather than being cut off mid-flight. This is deliberately not a
-- count of `total:` spans: a single user action can legitimately produce
-- more than one. For example `inliner.smart`'s block-paste fallback, reached
-- when the initial resolve fails to locate anything, itself emits
-- `total:block-fallback` and then hands off to `expander.expand`, which
-- performs its own independent round trip and emits its own `total:expand`
-- (or `total:expand-failed`) when that finishes. That is one user action
-- producing two `total:` spans, and it is exactly as complete as a
-- one-`total:` action -- there is no "extra" span here to be suspicious of.
-- What actually indicates trouble is an action that never reaches a
-- `total:` span at all within the timeout; `complete` is false in that case
-- and the caller must not treat the returned spans as usable for anything
-- that depends on the action having finished (e.g. `M.total_ms`).
function M.capture(fn, timeout, opts)
  opts = opts or {}
  local settle_cap_ms = opts.settle_cap_ms or 300
  local until_span = opts.until_span
  profile.clear()
  fn()
  vim.wait(timeout or 20000, function()
    for i = 1, #profile.events do
      if profile.events[i].name:find("^total:") then
        return true
      end
    end
    return false
  end, 5)
  -- Settle wait: observe for `settle_cap_ms` (floored at 120ms, see above)
  -- with no early exit. This used to poll for the span count to go quiet and
  -- return as soon as it looked stable -- fast in the common case, but
  -- unsound for exactly the case this option exists for: a multi-phase
  -- action's first phase (e.g. `total:block-fallback`) itself matches
  -- `^total:`, so the ring can go quiet -- and LOOK finished -- well before
  -- the second phase has even started, let alone landed. A stability check
  -- cannot tell "genuinely done" from "the next phase hasn't started yet";
  -- only waiting long enough can. So there is no shortcut here: this always
  -- observes for the full window, and whatever lands inside it is this
  -- capture's; whatever lands after belongs to whichever capture is running
  -- when it arrives. When the caller declared `until_span`, exit as soon as
  -- a span matching it has appeared AND the 120ms floor has elapsed --
  -- still no early exit on stability alone, just on the caller's own
  -- declared terminal span, which is a judgment only the caller can make.
  local settle_ms = math.max(settle_cap_ms, 120)
  if until_span then
    local settle_start = vim.uv.now()
    vim.wait(settle_ms, function()
      if vim.uv.now() - settle_start < 120 then
        return false
      end
      for i = 1, #profile.events do
        if profile.events[i].name:find(until_span) then
          return true
        end
      end
      return false
    end, 5)
  else
    vim.wait(settle_ms)
  end
  local out = {}
  for i = 1, #profile.events do
    out[i] = profile.events[i]
  end
  local complete = #out > 0 and out[#out].name:find("^total:") ~= nil
  return out, complete
end

-- End-to-end latency of one captured action: the SUM of its `total:` spans'
-- own `ms` values.
--
-- Why the sum, and why only `total:` spans. Each `total:` span already covers
-- one whole phase of the action, end to end: `expander.expand` starts its
-- span immediately before `resolver.fetch` and stops it after the splice, and
-- `inliner.smart` starts its `total:` span (`action.finish_total`) before its own fetch and stops it after the
-- rewrite. A single-phase action therefore has exactly one `total:` span
-- whose ms IS the latency; a multi-phase action's phases run one after
-- another and never overlap (the block-paste fallback stops
-- `total:block-fallback` and only then hands off to `expander.expand`, which
-- starts a fresh span and emits `total:expand`), so adding the phases up
-- covers the whole action. Non-`total:` spans (`locate:`, `extract:`,
-- `substitute:`, `macro:`) are nested INSIDE a `total:` span and would be
-- double-counted if they were included.
--
-- Why not the timestamps. Every span also carries `at`, but `at` is
-- `vim.uv.now()` -- libuv's CACHED loop time, an integral millisecond
-- refreshed once per event-loop iteration. Several `uv.now()` calls within
-- one tick return the same number, so a difference of `at` values measures
-- how many tick boundaries an action crossed, not how long it took: a 10ms
-- busy-spin inside a synchronous callback moves it by zero. `ms`, by
-- contrast, is `vim.uv.hrtime()`-derived (see `profile.start`), nanosecond
-- resolution. Summing `ms` is hrtime throughout -- no wall clock is read at
-- all, so there is no clock mixing and no millisecond quantization.
--
-- What this does NOT cover. `inliner.smart` does its whole-buffer concat and
-- its `substitute.call_name_at` tree-sitter parse BEFORE starting its `total:`
-- span, so an `ei` (smart-inline) measurement EXCLUDES that parse -- measured
-- at roughly 7ms on a large real file, i.e. not negligible. Read an
-- `inline:*` number as "from the fetch onwards", not as the whole keypress.
-- The scheduler hop between two phases (the `vim.schedule` inside
-- `block_fallback`) falls between spans and is likewise not counted.
--
-- Returns nil when the action produced no `total:` span at all (an incomplete
-- capture -- see `assert_complete`), so a caller cannot mistake "never
-- finished" for "took 0ms".
function M.elapsed_ms(spans)
  local sum, seen = 0, false
  for _, s in ipairs(spans) do
    if s.name:find("^total:") then
      sum = sum + s.ms
      seen = true
    end
  end
  return seen and sum or nil
end

function M.count(spans, pattern)
  local n = 0
  for _, s in ipairs(spans) do
    if s.name:find(pattern) then
      n = n + 1
    end
  end
  return n
end

-- Same contract as `capture`'s `complete` return, phrased for callers that
-- want to print something useful: `complete, reason` where `reason` is nil
-- when complete, else a short human-readable explanation of why the action
-- did not finish.
function M.assert_complete(spans)
  if #spans == 0 then
    return false, "no spans recorded"
  end
  local last = spans[#spans]
  if last.name:find("^total:") then
    return true, nil
  end
  return false, ("action did not finish within the timeout (last span: %s)"):format(last.name)
end

-- The LAST `^total:` span's ms, not the first. This is a SINGLE-PHASE
-- convenience -- a diagnostic for "how long did the final phase take" -- and
-- is NOT the harness's latency metric. `M.elapsed_ms` is: it sums every
-- `total:` span, so it stays correct when one user action produces several.
--
-- Concretely, a two-phase action (e.g. a block-paste fallback reached via
-- `inliner.smart`'s failed initial resolve) emits an intermediate
-- `total:block-fallback` and then, once `expander.expand` has spliced the
-- prefetched body, a final `total:expand` that covers the splice ALONE. That
-- last span does not move at all when the resolve preceding it gets slower,
-- so reading it as the action's latency understates a real regression. Use it
-- to attribute time to a phase; use `elapsed_ms` to measure the action.
function M.total_ms(spans)
  local ms = nil
  for _, s in ipairs(spans) do
    if s.name:find("^total:") then
      ms = s.ms
    end
  end
  return ms
end

function M.names(spans)
  local out = {}
  for i, s in ipairs(spans) do
    out[i] = ("%s(%.0fms)"):format(s.name, s.ms)
  end
  return table.concat(out, " ")
end

return M
