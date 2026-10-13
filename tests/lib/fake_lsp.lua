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
-- Returns the client id once attached, or nil (after printing the SKIP line)
-- when it did not attach within 2s.
function M.start(opts)
  local handle = opts.handle or function(_, _, _) end
  local cid = vim.lsp.start({
    name = opts.name,
    cmd = function(dispatchers)
      local closing, next_id = false, 0
      local server = {
        request = function(method, params)
          return dispatchers.server_request(method, params)
        end,
      }
      return {
        request = function(method, params, callback)
          next_id = next_id + 1
          if method == "initialize" then
            callback(nil, { capabilities = opts.capabilities })
          else
            handle(method, params, callback, server)
          end
          return true, next_id
        end,
        notify = function()
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
  return cid
end

return M
