-- Small async helpers shared by the LSP-facing modules.
local M = {}

-- Wrap `cb` so it fires exactly once: either with the real response (via the
-- returned `finish`) or, after `ms` milliseconds, with whatever `on_timeout`
-- returns. Calls to `finish` after the first are dropped silently.
function M.once_with_timeout(cb, on_timeout, ms)
  local finished = false
  local function finish(...)
    if finished then
      return
    end
    finished = true
    cb(...)
  end
  vim.defer_fn(function()
    -- Skip on_timeout() entirely when the real response already arrived.
    if not finished then
      finish(on_timeout())
    end
  end, ms)
  return finish
end

return M
