-- Profile: opt-in latency instrumentation (usage: docs/development.md). A span
-- times one stage of the work (see M.start); while profiling is off, the
-- default, it costs two calls, plus the stop call's arguments, which the call
-- site still evaluates.
local M = {}

M.enabled = false

-- The last max_events spans, oldest first, for the report; the log file keeps
-- every span. `at` is vim.uv.now() when the span stopped.
M.max_events = 200
---@type { name: string, ms: number, at: integer, detail?: string, action: integer }[]
M.events = {}

-- Where spans are appended; false keeps profiling in memory only.
M.logfile = vim.fs.joinpath(vim.fn.stdpath("log"), "inline-explorer-profile.log")

-- Id of the current user action. Every span records it, so that the spans of
-- one keypress can be grouped in the log.
M.action = 0

function M.begin_action()
  M.action = M.action + 1
  return M.action
end

-- Append a span to the log file as a line like
--   2026-01-31T12:00:00.123 #7    extract:cold                    35.2ms  foo.h
-- Seconds and milliseconds come from one gettimeofday() reading, so the
-- timestamp never mixes two clocks.
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

local function noop() end

---@alias inline_explorer.StopTimer fun(name: string, detail?: string): number?

-- Start a span. The function returned (a no-op while profiling is off) stops
-- and records it and returns its duration in ms. Naming the span there lets
-- the name say what happened ("extract:cached", "extract:cold"). `detail`
-- (symbol, file, size) goes to the log and the slowest spans, not the totals.
---@return inline_explorer.StopTimer
function M.start()
  if not M.enabled then
    return noop
  end
  local t0 = vim.uv.hrtime()
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
  -- A span of about zero length, so it shows in the log and the report.
  local stop_timer = M.start()
  stop_timer("server", ("%s %s | %s"):format(info.name or client.name or "?", info.version or "?", cmdstr))
end

-- Forget the recorded spans; with `also_logfile`, empty the log file too.
function M.clear(also_logfile)
  M.events = {}
  if also_logfile and M.logfile then
    local f = io.open(M.logfile, "w")
    if f then
      f:close()
    end
  end
end

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
  lines[#lines + 1] = string.rep("-", 64)
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
  local worst = {}
  for _, e in ipairs(M.events) do
    worst[#worst + 1] = e
  end
  table.sort(worst, function(x, y)
    return x.ms > y.ms
  end)
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("%-6s %-26s %9s  %s"):format("action", "span", "ms", "detail")
  lines[#lines + 1] = string.rep("-", 78)
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
