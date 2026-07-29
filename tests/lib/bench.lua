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

-- Spans produced by one user action. Every instrumented action ends with a
-- `total:` span, so that is the settle signal; without one we return whatever
-- was recorded before the timeout (the caller can then see it is incomplete).
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
-- Returns `spans, clean`. Every instrumented action ends with EXACTLY ONE
-- `total:` span and nothing after it (the inliner records total after the
-- rewrite, the expander after the splice, and the resolver's/macro's timeout
-- guards drop late responses without recording a span). `clean` is true iff
-- the captured list contains exactly one `^total:` span. Zero means the
-- action did not complete within `timeout`; two-plus means a straggler from
-- an earlier capture bled into this one (its settle wait exited before that
-- span landed). Either way the span list is NOT one clean action, and the
-- caller must not treat counts derived from it (e.g. `M.count`) as trustworthy
-- -- capture does not silently drop the extra spans, it hands them back and
-- lets `clean` say so.
function M.capture(fn, timeout)
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
  -- Quiescence wait: poll for the span count to stop changing instead of
  -- guessing a fixed trailing delay. This answers "did every span for this
  -- action land?" directly. It floors at 120ms: the flat trailing wait this
  -- replaced was always 120ms, and this must never observe for less time
  -- than that fixed wait did, or a straggler the old wait would have caught
  -- exits this settle early and silently lands in the NEXT capture instead
  -- (e.g. a rep's span list gaining a foreign `extract:` span). So: poll
  -- every 20ms and keep going until the span count has been stable for 3
  -- consecutive polls AND at least 120ms has elapsed since this wait began,
  -- subject to the existing 300ms hard cap.
  do
    local start = vim.loop.now()
    local stable = 0
    local last = #profile.events
    while vim.loop.now() - start < 300 do
      vim.wait(20)
      local n = #profile.events
      if n == last then
        stable = stable + 1
      else
        stable = 0
        last = n
      end
      if stable >= 3 and vim.loop.now() - start >= 120 then
        break
      end
    end
  end
  local out = {}
  for i = 1, #profile.events do
    out[i] = profile.events[i]
  end
  local clean = M.count(out, "^total:") == 1
  return out, clean
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

-- Same contract as `capture`'s `clean` return, phrased for callers that want
-- to print something useful: `clean, reason` where `reason` is nil when
-- clean, else a short human-readable explanation of why the span list is
-- not one trustworthy action.
function M.assert_one_action(spans)
  local n = M.count(spans, "^total:")
  if n == 1 then
    return true, nil
  elseif n == 0 then
    return false, "no total: span (action did not finish)"
  else
    return false, ("%d total: spans (straggler from an earlier capture)"):format(n)
  end
end

function M.total_ms(spans)
  for _, s in ipairs(spans) do
    if s.name:find("^total:") then
      return s.ms
    end
  end
  return nil
end

function M.names(spans)
  local out = {}
  for i, s in ipairs(spans) do
    out[i] = ("%s(%.0fms)"):format(s.name, s.ms)
  end
  return table.concat(out, " ")
end

return M
