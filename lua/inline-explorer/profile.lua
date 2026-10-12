-- Profile: opt-in latency instrumentation. A span times one stage of the
-- work: `local stop_timer = profile.start()` starts it, and
-- `stop_timer(name, detail)` stops it and records it under `name`.
-- Profiling is off by default, and then start() returns a function that does
-- nothing, so an instrumented call site costs one table lookup and one call.
--
-- Enable it with :InlineExplorerProfile on (or profile = true in setup), use
-- the plugin, then run :InlineExplorerProfile to see where the time went.
-- Every span is also appended to a log file (:InlineExplorerProfile path),
-- which can be read afterwards or followed live from another shell.
local M = {}

-- Whether spans are recorded. setup() sets it from the `profile` option, and
-- :InlineExplorerProfile on/off changes it.
M.enabled = false

-- The most recent spans, oldest first. Once the list holds max_events spans,
-- each new span drops the oldest. A span is { name, ms, at, detail, action },
-- where `at` is vim.uv.now() when it stopped and `action` is M.action then.
-- The report reads this list; the log file keeps every span.
M.max_events = 200
M.events = {}

-- Where spans are appended. Set to false to keep profiling in memory only.
M.logfile = vim.fs.joinpath(vim.fn.stdpath("log"), "inline-explorer-profile.log")

-- Id of the current user action. Every span records it, so all the spans of
-- one keypress can be grouped in the log. begin_action() starts a new one.
M.action = 0

function M.begin_action()
  M.action = M.action + 1
  return M.action
end

-- Append a span to the log file, if there is one. A line looks like this
-- (time, action id, span name, duration, detail):
--   2026-01-31T12:00:00.123 #7    extract:cold                    35.2ms  foo.h
-- The seconds and the milliseconds come from one gettimeofday() reading, so
-- the timestamp never mixes two clocks.
local function append(name, ms, detail)
  if not M.logfile then
    return
  end
  local f = io.open(M.logfile, "a")
  if not f then
    return
  end
  local sec, usec = vim.uv.gettimeofday()
  f:write(
    ("%s.%03d #%-4d %-26s %9.1fms%s\n"):format(
      os.date("%Y-%m-%dT%H:%M:%S", sec),
      math.floor(usec / 1000),
      M.action,
      name,
      ms,
      detail and ("  " .. detail) or ""
    )
  )
  f:close()
end

-- What start() returns when profiling is off.
local function noop() end

-- Start a span. Returns a function, stop_timer(name, detail), that stops the
-- timer, records the span under `name`, and returns its duration in ms. The
-- name is given when stopping, so a call site can name the span after what
-- actually happened (e.g. "extract:cached" or "extract:cold").
function M.start()
  if not M.enabled then
    return noop
  end
  local t0 = vim.uv.hrtime()
  -- detail: optional free-form context (symbol, file, size). It is written to
  -- the log and the list of slowest spans, but is not part of the aggregation
  -- key.
  return function(name, detail)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    M.events[#M.events + 1] = { name = name, ms = ms, at = vim.uv.now(), detail = detail, action = M.action }
    if #M.events > M.max_events then
      table.remove(M.events, 1)
    end
    append(name, ms, detail)
    return ms
  end
end

-- Ids of the clients that identify() has logged.
M._identified = {}

-- Log each LSP client's name, version and command line once per session, so
-- that a log from another machine shows which server setup produced it.
function M.identify(client)
  if not M.enabled or not client or M._identified[client.id] then
    return
  end
  M._identified[client.id] = true
  local info = client.server_info or {}
  local cmd = client.config and client.config.cmd
  local cmdstr
  if type(cmd) == "table" then
    cmdstr = table.concat(cmd, " ")
  elseif type(cmd) == "function" then
    cmdstr = "<in-process>"
  else
    cmdstr = tostring(cmd)
  end
  -- Recorded as a span of about zero length, so it shows up in the log and
  -- the report like the others.
  local stop_timer = M.start()
  stop_timer("server", ("%s %s | %s"):format(info.name or client.name or "?", info.version or "?", cmdstr))
end

-- Forget the recorded spans (M.events). The log file is the durable record
-- and is kept, unless `also_logfile` is true: then it is emptied too.
function M.clear(also_logfile)
  M.events = {}
  if also_logfile and M.logfile then
    local f = io.open(M.logfile, "w")
    if f then
      f:close()
    end
  end
end

-- How many of the slowest single spans the report lists.
local WORST_SHOWN = 8

-- The report, as text with two tables: the totals per span name (slowest
-- total first), then the WORST_SHOWN slowest single spans with their detail.
function M.report()
  if #M.events == 0 then
    return M.enabled and "[inline-explorer] profiling on, no spans recorded yet"
      or "[inline-explorer] profiling is off (:InlineExplorerProfile on)"
  end
  local agg, order = {}, {}
  for _, e in ipairs(M.events) do
    local a = agg[e.name]
    if not a then
      a = { n = 0, total = 0, max = 0, last = 0 }
      agg[e.name] = a
      order[#order + 1] = e.name
    end
    a.n = a.n + 1
    a.total = a.total + e.ms
    a.last = e.ms
    if e.ms > a.max then
      a.max = e.ms
    end
  end
  table.sort(order, function(x, y)
    return agg[x].total > agg[y].total
  end)

  local lines = { ("%-22s %5s %9s %8s %8s %8s"):format("span", "n", "total", "mean", "max", "last") }
  lines[#lines + 1] = string.rep("-", 64) -- a rule under the header
  for _, name in ipairs(order) do
    local a = agg[name]
    lines[#lines + 1] = ("%-22s %5d %8.0fms %7.0fms %7.0fms %7.0fms"):format(
      name,
      a.n,
      a.total,
      a.total / a.n,
      a.max,
      a.last
    )
  end
  -- The totals show which stage costs most over the session, but not which
  -- single call was slow. The slowest single spans, with their detail, show
  -- that.
  local worst = {}
  for _, e in ipairs(M.events) do
    worst[#worst + 1] = e
  end
  table.sort(worst, function(x, y)
    return x.ms > y.ms
  end)
  -- worst is not empty: report() returned early when there were no events.
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("%-6s %-26s %9s  %s"):format("action", "span", "ms", "detail")
  lines[#lines + 1] = string.rep("-", 78) -- a rule under the header
  for i = 1, math.min(WORST_SHOWN, #worst) do
    local e = worst[i]
    lines[#lines + 1] = ("#%-5d %-26s %8.1fms  %s"):format(e.action or 0, e.name, e.ms, e.detail or "")
  end
  if M.logfile then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "log: " .. M.logfile
  end
  return table.concat(lines, "\n")
end

return M
