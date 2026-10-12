local M = {}

-- The first call to the returned `finish(...)` passes its arguments to `cb`,
-- and later calls are ignored. If `finish` has not been called within `ms`
-- milliseconds, `on_timeout()` runs and `cb` gets its return values instead.
---@return fun(...) finish
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
    if not finished then
      finish(on_timeout())
    end
  end, ms)
  return finish
end

return M
