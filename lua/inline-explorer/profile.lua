-- Opt-in latency instrumentation. Off by default and near-free when off: the
-- span factory hands back a no-op, so instrumented call sites cost one table
-- lookup and one call.
--
-- Enable with :InlineExplorerProfile on (or profile = true in setup), drive
-- the plugin, then :InlineExplorerProfile to see where the time went. Every
-- span is also appended to a log file (:InlineExplorerProfile path) so a slow
-- session can be inspected afterwards -- or tailed live from another shell.
local M = {}

M.enabled = false
M.max_events = 200

-- Ring buffer of { name, ms, at } for the most recent spans (the report reads
-- this; the log file keeps everything).
M.events = {}

-- Where spans are appended. Set to false to keep profiling in memory only.
M.logfile = vim.fs.joinpath(vim.fn.stdpath("log"), "inline-explorer-profile.log")

local function noop() end

-- Monotonically increasing id for one user action, so spans can be grouped
-- from the log with certainty instead of by adjacency. os.date resolves to
-- whole seconds, and a whole action often lands inside one -- the ordering
-- that mattered had to be inferred from the order lines happened to be
-- written in.
M.action = 0

function M.begin_action()
  M.action = M.action + 1
  return M.action
end

local function append(name, ms, detail)
  if not M.logfile then
    return
  end
  local f = io.open(M.logfile, "a")
  if not f then
    return
  end
  -- Seconds and milliseconds must come from the SAME clock. Taking the
  -- seconds from os.date and the fraction from hrtime's nanosecond part --
  -- which is what this did first -- pairs a wall clock with an unrelated
  -- monotonic one, and the result runs backwards within an action:
  -- extract:attach at .544 followed by extract:cold at .036. gettimeofday
  -- gives both halves of one reading.
  local sec, usec = vim.uv.gettimeofday()
  f:write(("%s.%03d #%-4d %-26s %9.1fms%s\n"):format(
    os.date("%Y-%m-%dT%H:%M:%S", sec), math.floor(usec / 1000), M.action, name, ms,
    detail and ("  " .. detail) or ""))
  f:close()
end

-- Start a span. The returned function stops it and records the elapsed time
-- under the name given AT STOP TIME, so a call site can label itself by what
-- actually happened (e.g. "extract:cached" vs "extract:cold").
function M.start()
  if not M.enabled then
    return noop
  end
  local t0 = vim.uv.hrtime()
  -- `detail` is free-form context -- which symbol, which file, how big --
  -- recorded in the log but NOT part of the aggregation key, so identifying
  -- the slow site does not fragment the report into one row per symbol.
  -- Without it a 4-second extract and a 240ms one are indistinguishable
  -- rows, and the first question anyone asks (which header was that?) has
  -- no answer in the data.
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

-- Clear the in-memory ring. The log file is left alone (it is the durable
-- record); pass true to truncate it too.
function M.clear(also_logfile)
  M.events = {}
  if also_logfile and M.logfile then
    local f = io.open(M.logfile, "w")
    if f then
      f:close()
    end
  end
end

-- Aggregate the recorded spans: one row per name, slowest total first.
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
  lines[#lines + 1] = string.rep("-", 64)
  for _, name in ipairs(order) do
    local a = agg[name]
    lines[#lines + 1] = ("%-22s %5d %8.0fms %7.0fms %7.0fms %7.0fms"):format(
      name, a.n, a.total, a.total / a.n, a.max, a.last)
  end
  -- The aggregate answers "which stage costs most across the session"; it
  -- cannot answer "which single call was the 4-second one", which is the
  -- question a slow session actually raises. List the worst individual
  -- spans, with their detail, alongside it.
  local worst = {}
  for _, e in ipairs(M.events) do
    worst[#worst + 1] = e
  end
  table.sort(worst, function(x, y)
    return x.ms > y.ms
  end)
  if #worst > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("%-6s %-26s %9s  %s"):format("action", "span", "ms", "detail")
    lines[#lines + 1] = string.rep("-", 78)
    for i = 1, math.min(8, #worst) do
      local e = worst[i]
      lines[#lines + 1] = ("#%-5d %-26s %8.1fms  %s"):format(
        e.action or 0, e.name, e.ms, e.detail or "")
    end
  end
  if M.logfile then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "log: " .. M.logfile
  end
  return table.concat(lines, "\n")
end

return M
