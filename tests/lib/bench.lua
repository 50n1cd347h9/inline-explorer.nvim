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
-- With the instrumentation as it stands today, the plugin records nothing
-- after an action's final `total:` span (the inliner records total after
-- the rewrite, the expander after the splice, and the resolver's/macro's
-- timeout guards drop late responses without recording a span at all), so
-- window attribution above is exact, not merely approximate. If that ever
-- changes -- an instrumented call after the final total: gets added -- this
-- becomes approximate and would need revisiting.
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

-- End-to-end latency of one captured action, derived from the span
-- timestamps rather than from any single span. A multi-phase action's last
-- total: span covers only its last phase -- for a block-paste fallback that
-- is the splice alone, which does not move at all when the resolve it
-- followed gets slower -- so reading one span's duration is not end to end.
-- Each event carries `at` (when it stopped) and `ms` (how long it took), so
-- the action began at `first.at - first.ms` and ended at `last.at`.
function M.elapsed_ms(spans)
  if #spans == 0 then
    return nil
  end
  local first, last = spans[1], spans[#spans]
  return last.at - (first.at - first.ms)
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

-- The LAST `^total:` span's ms, not the first. A two-phase action (e.g. a
-- block-paste fallback reached via `inliner.smart`'s failed initial resolve)
-- emits an intermediate `total:block-fallback` and then, once its own
-- independent `expander.expand` round trip finishes, a final `total:expand`
-- -- the end-to-end latency the harness cares about is that final one, not
-- the intermediate span that only marks a handoff.
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
