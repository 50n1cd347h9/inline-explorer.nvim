local M = {}

-- The first call to the returned `finish(...)` passes its arguments to `cb`,
-- and later calls are ignored. If `finish` has not been called within `ms`
-- milliseconds, `on_timeout()` runs and `cb` gets its return values instead.
---@param cb fun(...)
---@param on_timeout fun(): ...
---@param ms integer
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

-- Cancels request `id` of `client` if the server has not answered it yet:
-- Neovim logs an error for an id that is no longer pending.
---@param client vim.lsp.Client
---@param id integer?
function M.cancel(client, id)
  if id == nil then
    return
  end
  local request = client.requests[id]
  if request and request.type == "pending" then
    client:cancel_request(id)
  end
end

-- Sends `method` to `client` alone and calls `cb(err, result)` once: with the
-- reply, with an error at once if the request cannot be sent, or with an
-- error after `ms` milliseconds. A timeout cancels the request so that the
-- server can drop the work; a reply that still comes is ignored.
---@param client vim.lsp.Client
---@param method string
---@param params table
---@param bufnr integer
---@param ms integer
---@param cb fun(err: lsp.ResponseError?, result: any)
function M.request(client, method, params, bufnr, ms, cb)
  local id
  local finish = M.once_with_timeout(cb, function()
    M.cancel(client, id)
    local message = ("%s: no answer within %dms"):format(method, ms)
    return { code = vim.lsp.protocol.ErrorCodes.RequestCancelled, message = message }, nil
  end, ms)
  local sent, request_id = client:request(method, params, finish, bufnr)
  id = request_id
  if not sent then
    finish({ code = vim.lsp.protocol.ErrorCodes.UnknownErrorCode, message = method .. ": not sent" }, nil)
  end
end

return M
