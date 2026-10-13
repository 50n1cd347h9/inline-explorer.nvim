-- An in-process fake LSP server: vim.lsp.start's `cmd` as a Lua function, so
-- a spec can script exactly what a server answers (or does not answer)
-- without a real one installed.
local M = {}

-- Start a fake server (vim.lsp.start attaches it to the CURRENT buffer) and
-- wait for it to show up on `opts.buf`.
--
--   opts.name          client name (also what the attach wait filters on)
--   opts.buf           buffer the client must attach to
--   opts.root_dir      root_dir for vim.lsp.start
--   opts.capabilities  server capabilities answered to `initialize`
--   opts.handle        function(method, params, callback, server) for every
--                      request but `initialize`. Not calling `callback` leaves
--                      the request unanswered forever -- the way a wedged
--                      server behaves. Omit it to swallow every such request.
--                      server.request(method, params) sends a request to the
--                      client (workspace/applyEdit, say) and returns its reply.
--   opts.skip          what is skipped if the server never attaches; printed
--                      as "SKIP  <skip>"
--
-- Like a real transport, a reply reaches the client on a later turn of the
-- event loop, and a request the client cancels ($/cancelRequest) while it is
-- unanswered is acknowledged and gets no reply: its `callback` does nothing.
--
-- Returns the client id once attached, or nil (after printing the SKIP line)
-- when it did not attach within 2s. The second value is the server's log:
--   log.requests       { method, id, params } for every request but initialize
--   log.notifications  { method, params } for every notification
function M.start(opts)
  local handle = opts.handle or function(_, _, _) end
  local log = { requests = {}, notifications = {} }
  local cid = vim.lsp.start({
    name = opts.name,
    cmd = function(dispatchers)
      local closing, next_id = false, 0
      -- Request id -> what to call once it is answered: the client's
      -- notify_reply, which ends the request's "pending" state.
      local unanswered = {}
      local function answer(id)
        local notify_reply = unanswered[id]
        unanswered[id] = nil
        if type(notify_reply) == "function" then
          notify_reply(id)
        end
      end
      local server = {
        request = function(method, params)
          return dispatchers.server_request(method, params)
        end,
      }
      return {
        request = function(method, params, callback, notify_reply)
          next_id = next_id + 1
          local id = next_id
          if method == "initialize" then
            callback(nil, { capabilities = opts.capabilities })
            return true, id
          end
          log.requests[#log.requests + 1] = { method = method, id = id, params = params }
          unanswered[id] = notify_reply or true
          handle(method, params, function(err, result)
            vim.schedule(function()
              if unanswered[id] then
                answer(id)
                callback(err, result)
              end
            end)
          end, server)
          return true, id
        end,
        notify = function(method, params)
          log.notifications[#log.notifications + 1] = { method = method, params = params }
          if method == "$/cancelRequest" and unanswered[params.id] then
            vim.schedule(function()
              answer(params.id)
            end)
          end
          return true
        end,
        is_closing = function()
          return closing
        end,
        terminate = function()
          closing = true
          dispatchers.on_exit(0, 0)
        end,
      }
    end,
    root_dir = opts.root_dir,
  })
  local function attached()
    return #vim.lsp.get_clients({ bufnr = opts.buf, name = opts.name }) > 0
  end
  vim.wait(2000, function()
    return cid ~= nil and attached()
  end, 20)
  if not attached() then
    print("SKIP  " .. opts.skip)
    return nil
  end
  return cid, log
end

-- How many entries of `list` (log.requests or log.notifications) are for
-- `method`.
function M.count(list, method)
  local n = 0
  for _, e in ipairs(list) do
    if e.method == method then
      n = n + 1
    end
  end
  return n
end

return M
