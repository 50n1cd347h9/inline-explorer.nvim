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
  -- action land?" directly, and keeps the window in which a straggler from
  -- this action could still be in flight (and bleed into the next capture)
  -- as short as possible.
  do
    local stable = 0
    local last = #profile.events
    for _ = 1, 15 do
      vim.wait(20)
      local n = #profile.events
      if n == last then
        stable = stable + 1
        if stable >= 3 then
          break
        end
      else
        stable = 0
        last = n
      end
    end
  end
  local out = {}
  for i = 1, #profile.events do
    out[i] = profile.events[i]
  end
  return out
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
