-- Opt-in latency instrumentation. Off by default and near-free when off: the
-- span factory hands back a no-op, so instrumented call sites cost one table
-- lookup and one call.
--
-- Enable with :InlineExplorerProfile on (or profile = true in setup), drive
-- the plugin, then :InlineExplorerProfile to see where the time went.
local M = {}

M.enabled = false
M.max_events = 200

-- Ring buffer of { name, ms, at } for the most recent spans.
M.events = {}

local function noop() end

-- Start a span. The returned function stops it and records the elapsed time
-- under the name given AT STOP TIME, so a call site can label itself by what
-- actually happened (e.g. "extract:cached" vs "extract:cold").
function M.start()
  if not M.enabled then
    return noop
  end
  local t0 = vim.uv.hrtime()
  return function(name)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    M.events[#M.events + 1] = { name = name, ms = ms, at = vim.uv.now() }
    if #M.events > M.max_events then
      table.remove(M.events, 1)
    end
    return ms
  end
end

function M.clear()
  M.events = {}
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
  return table.concat(lines, "\n")
end

return M
