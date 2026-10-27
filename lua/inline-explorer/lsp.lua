-- Language server plumbing that the lookups share: loading a file and
-- attaching a client to it for a request, and putting it back as it was
-- once it has not been used for a while; which server a request about a
-- location goes to, and the position to send.
local util = require("inline-explorer.util")

local M = {}

local function source_buf(source_bufnr)
  if source_bufnr and vim.api.nvim_buf_is_valid(source_bufnr) then
    return source_bufnr
  end
  return 0
end

-- Files this module loaded, or attached a client to, keyed by bufnr: `ids`
-- are the clients it attached, `loaded` says whether it loaded the buffer.
-- A client stays attached after its request, because re-attaching a file
-- makes the server rebuild its preamble. Eviction puts
-- the file back as it was: the clients this module attached are detached,
-- and a buffer it loaded is unloaded, which closes the file in every server,
-- also in one that a FileType autostart attached during the load.
M._attach_cache_max = 8
---@type table<integer, {ids: integer[], loaded: boolean, at: integer}>
M._attach_cache = {}

-- Buffers that something reads through its clients, with how many times
-- each is pinned: a reading view pins its source buffer (see M.pin).
---@type table<integer, integer>
M._pins = {}

-- Keeps buf's clients and contents while it is pinned, however long ago it
-- was used: eviction passes it over.
---@param buf integer
function M.pin(buf)
  M._pins[buf] = (M._pins[buf] or 0) + 1
end

---@param buf integer
function M.unpin(buf)
  local n = (M._pins[buf] or 0) - 1
  M._pins[buf] = n > 0 and n or nil
end

-- Whether a window shows buf, or something pinned it.
local function in_use(buf)
  return #vim.fn.win_findbuf(buf) > 0 or M._pins[buf] ~= nil
end

local function release(buf, entry)
  if not vim.api.nvim_buf_is_valid(buf) or in_use(buf) then
    return
  end
  if entry.loaded and not vim.bo[buf].modified and not vim.bo[buf].buflisted then
    pcall(vim.api.nvim_buf_delete, buf, { unload = true })
    return
  end
  for _, id in ipairs(entry.ids) do
    -- The client may be gone, or detached by someone else.
    if vim.lsp.buf_is_attached(buf, id) then
      vim.lsp.buf_detach_client(buf, id)
    end
  end
end

-- Marks target's entry as just used, recording that this module loaded the
-- buffer or attached `attached_id`, and evicts the least recently used
-- entries past the cap. A buffer this module did nothing to is not recorded.
-- hrtime, not the loop's millisecond clock: a tie with an older entry could
-- evict the file in use.
local function remember(target, loaded, attached_id)
  local entry = M._attach_cache[target]
  if not entry and (loaded or attached_id) then
    entry = { ids = {}, loaded = false, at = 0 }
    M._attach_cache[target] = entry
  end
  if entry then
    entry.at = vim.uv.hrtime()
    entry.loaded = entry.loaded or loaded
    if attached_id then
      entry.ids[#entry.ids + 1] = attached_id
    end
  end
  util.evict_lru(M._attach_cache, M._attach_cache_max, release)
end

-- Loads target, unless it is loaded. True when this call loaded it.
---@param target integer
---@return boolean
function M.load_buffer(target)
  local loaded = not vim.api.nvim_buf_is_loaded(target)
  if loaded then
    vim.fn.bufload(target)
  end
  remember(target, loaded, nil)
  return loaded
end

-- Attaches client to target, which must be loaded, unless it is attached.
-- True when this call attached it.
---@param target integer
---@param client vim.lsp.Client
---@return boolean
function M.attach_client(target, client)
  local attached = not client.attached_buffers[target]
  if attached then
    vim.lsp.buf_attach_client(target, client.id)
  end
  remember(target, false, attached and client.id or nil)
  return attached
end

-- Attaches `client` to uri's file, loading it if needed. Called right
-- before a request about the file: clangd answers position requests only
-- about documents it has open.
---@param uri string
---@param client vim.lsp.Client
---@return integer target the file's bufnr
function M.ensure_attached(uri, client)
  local target = vim.uri_to_bufnr(uri)
  M.load_buffer(target)
  M.attach_client(target, client)
  return target
end

-- Where requests about loc go: to the server that found it, else to the
-- first one on the source buffer that supports `method`. nil when the server
-- that found it does not: another server's ranges, encoding and index need
-- not agree with the loc.
---@param loc inline_explorer.Loc
---@param source_bufnr integer? nil or invalid counts as the current buffer
---@param method string
---@return vim.lsp.Client?
function M.client_for(loc, source_bufnr, method)
  local clients = vim.lsp.get_clients({ bufnr = source_buf(source_bufnr), method = method })
  if not loc.client_id then
    return clients[1]
  end
  for _, c in ipairs(clients) do
    if c.id == loc.client_id then
      return c
    end
  end
  return nil
end

-- A file a jump opens gets the clients of the file the jump came from when
-- it has none, as a FileType autostart would give it: lookups from its view
-- go through them. They are recorded like the clients a lookup attaches,
-- so they are detached again once the file is no longer used.
---@param from integer
---@param to integer
function M.share_clients(from, to)
  if from == to or #vim.lsp.get_clients({ bufnr = to }) > 0 then
    return
  end
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = from })) do
    M.attach_client(to, client)
  end
end

-- Where loc.name appears as a whole word in the 4 lines from loc's start
-- line, else loc.range.start. A position request needs the identifier, and
-- loc.range.start may sit on a keyword such as `void`.
---@param target integer bufnr of loc.uri
---@param loc inline_explorer.Loc
---@param out_encoding string encoding of the server the position is sent to
---@return lsp.Position
function M.name_position(target, loc, out_encoding)
  local from = loc.range.start.line
  local lines = vim.api.nvim_buf_get_lines(target, from, from + 4, false)
  if loc.name then
    for i, l in ipairs(lines) do
      local start1 = l:find("%f[%w_]" .. vim.pesc(loc.name) .. "%f[^%w_]")
      if start1 then
        return { line = from + i - 1, character = util.lsp_col(l, start1 - 1, out_encoding) }
      end
    end
  end
  local l = lines[1] or ""
  local byte = util.byte_col(l, loc.range.start.character, loc.encoding)
  return { line = from, character = util.lsp_col(l, byte, out_encoding) }
end

return M
