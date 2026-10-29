-- Macro expansion through clangd, which runs the real preprocessor. Preferred:
-- textDocument/codeAction offers the ExpandMacro tweak, executeCommand runs
-- it, and clangd sends back a workspace/applyEdit, which we intercept and read
-- instead of applying. Fallback: the expansion that textDocument/hover shows.
-- A fetch is one tweak request; its claim lets the interceptor recognize its
-- applyEdit. When the fetch ends, the claim becomes a tombstone, which for
-- GRACE_MS (the grace window) discards a late matching applyEdit rather than
-- let it edit the source buffer.

local async = require("inline-explorer.async")
local profile = require("inline-explorer.profile")
local reply = require("inline-explorer.macro_reply")
local util = require("inline-explorer.util")

local M = {}

-- Budget for the tweak (codeAction through applyEdit), and again for the hover.
local TIMEOUT_MS = 2000

-- The grace window's cost: a genuine edit that matches a tombstone (the user
-- running a clangd tweak on that same macro use, say) is discarded too, and
-- answered { applied = true }. applyEdit carries no id that links it to our
-- executeCommand, so the two cannot be told apart. Hence the short window.
local GRACE_MS = 3000

---@class inline_explorer.Claim
---@field uri string
---@field pos lsp.Position the macro use
---@field on_edit? fun(edit: lsp.WorkspaceEdit) set while in flight; nil on a tombstone
---@field expires? integer the tombstone's end, in vim.uv.now() milliseconds

-- client.id -> claims, one per fetch, so overlapping fetches each leave their
-- own tombstone.
---@type table<integer, inline_explorer.Claim[]>
local claims_by_client = {}

-- client.id -> our interceptor, to tell whether another plugin replaced it.
local interceptor_by_client = {}

local function is_in_flight(claim)
  return claim.on_edit ~= nil
end

local function to_tombstone(claim, now)
  claim.on_edit = nil
  claim.expires = now + GRACE_MS
end

local function add_claim(client_id, claim)
  local claims = claims_by_client[client_id]
  if not claims then
    claims = {}
    claims_by_client[client_id] = claims
  end
  claims[#claims + 1] = claim
end

local function drop_expired(claims, now)
  for i = #claims, 1, -1 do
    local claim = claims[i]
    if claim.expires and now >= claim.expires then
      table.remove(claims, i)
    end
  end
end

local function newest_match(claims, edit, in_flight)
  for i = #claims, 1, -1 do
    local claim = claims[i]
    if is_in_flight(claim) == in_flight and reply.edit_matches(edit, claim.uri, claim.pos) then
      return claim
    end
  end
  return nil
end

-- Installs a workspace/applyEdit handler on `client` that drops expired
-- tombstones, gives a matching edit to the newest in-flight claim, discards
-- one that matches a tombstone, and passes anything else to the handler it
-- replaced (or the global one). It is never removed, since restoring the old
-- handler could undo one that another plugin installed later. A repeat call
-- does nothing while ours is still installed.
---@param client vim.lsp.Client
local function install_interceptor(client)
  local installed = interceptor_by_client[client.id]
  if installed ~= nil and client.handlers["workspace/applyEdit"] == installed then
    return
  end
  local prev = client.handlers["workspace/applyEdit"]
  local handler = function(err, params, ctx, config)
    local claims = claims_by_client[client.id]
    local edit = params and params.edit
    if claims then
      local now = vim.uv.now()
      drop_expired(claims, now)
      -- In-flight claims first, so a new fetch at a position that an older
      -- fetch's tombstone covers still gets its edit.
      local claim = newest_match(claims, edit, true)
      if claim then
        -- Kept as a tombstone, so a duplicate applyEdit is discarded too.
        local on_edit = claim.on_edit
        to_tombstone(claim, now)
        on_edit(edit)
        return { applied = true }
      end
      if newest_match(claims, edit, false) then
        return { applied = true }
      end
    end
    local fallback = prev or vim.lsp.handlers["workspace/applyEdit"]
    return fallback(err, params, ctx, config)
  end
  client.handlers["workspace/applyEdit"] = handler
  interceptor_by_client[client.id] = handler
end

-- Housekeeping only: client ids are never reused.
local function prune_dead_clients()
  for id in pairs(claims_by_client) do
    if not vim.lsp.get_client_by_id(id) then
      claims_by_client[id] = nil
    end
  end
  for id in pairs(interceptor_by_client) do
    if not vim.lsp.get_client_by_id(id) then
      interceptor_by_client[id] = nil
    end
  end
end

---@param client vim.lsp.Client
---@return boolean
function M.supports_tweak(client)
  local provider = (client.server_capabilities or {}).executeCommandProvider
  if type(provider) ~= "table" or type(provider.commands) ~= "table" then
    return false
  end
  return vim.tbl_contains(provider.commands, "clangd.applyTweak")
end

-- `col` is a byte column; the position is in `client`'s encoding.
local function source_position(bufnr, row, col, client)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  return { line = row, character = util.lsp_col(line, col, client.offset_encoding) }
end

-- The server with the tweak (clangd), if it supports `method`. Only its hover
-- shows an expansion, and other servers' replies could hide it.
local function expansion_client(bufnr, method)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, method = method })) do
    if M.supports_tweak(client) then
      return client
    end
  end
  return nil
end

-- Calls cb(lines) exactly once, with nil on any failure (no clangd or tweak, a
-- request error, the timeout) so that the caller can fall back.
local function fetch_via_tweak(bufnr, row, col, cb)
  prune_dead_clients()
  local client = expansion_client(bufnr, "textDocument/codeAction")
  if not client then
    return cb(nil)
  end

  install_interceptor(client)

  local uri = vim.uri_from_bufnr(bufnr)
  local pos = source_position(bufnr, row, col, client)
  local deadline = vim.uv.now() + TIMEOUT_MS

  local claim -- set once codeAction offers the tweak
  local finished = false
  -- Every outcome (the edit, an error, the timeout) ends here.
  local function finish(lines)
    if finished then
      return
    end
    finished = true
    if claim and is_in_flight(claim) then
      to_tombstone(claim, vim.uv.now())
    end
    cb(lines)
  end

  local function on_actions(err, actions)
    local cmd = not err and reply.pick_expand_action(actions)
    if not cmd then
      return finish(nil)
    end
    -- Before executeCommand: clangd sends the applyEdit first and replies
    -- only once it is answered, so the reply comes after our claim took the
    -- edit, if it did, and ends the fetch either way.
    claim = {
      uri = uri,
      pos = pos,
      on_edit = function(edit)
        finish(reply.edit_lines(edit, uri, pos))
      end,
    }
    add_claim(client.id, claim)
    local exec_params = { command = cmd.command, arguments = cmd.arguments }
    local remaining = math.max(deadline - vim.uv.now(), 0)
    async.request(client, "workspace/executeCommand", exec_params, bufnr, remaining, function()
      finish(nil)
    end)
  end

  local code_action_params = {
    textDocument = { uri = uri },
    range = { start = pos, ["end"] = pos },
    context = { diagnostics = {} },
  }
  async.request(client, "textDocument/codeAction", code_action_params, bufnr, TIMEOUT_MS, on_actions)
end

-- Calls cb(lines) once, with macro_reply.expansion_lines' result, or nil with no hover,
-- an error or the timeout.
local function fetch_via_hover(bufnr, row, col, cb)
  local client = expansion_client(bufnr, "textDocument/hover")
  if not client then
    return cb(nil)
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = source_position(bufnr, row, col, client),
  }
  async.request(client, "textDocument/hover", params, bufnr, TIMEOUT_MS, function(err, result)
    local contents = not err and type(result) == "table" and result.contents
    local md = contents and reply.hover_markdown(contents)
    if md and md ~= "" then
      return cb(reply.expansion_lines(md))
    end
    cb(nil)
  end)
end

-- Calls cb(lines) exactly once: nil when neither the tweak nor the hover has
-- an expansion, {} when the hover's is only blank lines. (row, col) is in the
-- source buffer; a nil row (a use with no source line) gives cb(nil) at once.
---@param bufnr integer the source buffer, whose clients are asked
---@param row integer? 0-based
---@param col integer 0-based, in bytes
---@param cb fun(lines: string[]?)
function M.fetch_expansion(bufnr, row, col, cb)
  if row == nil then
    return cb(nil)
  end
  local stop_tweak_timer = profile.start()
  fetch_via_tweak(bufnr, row, col, function(lines)
    if lines and #lines > 0 then
      stop_tweak_timer("macro:tweak")
      return cb(lines)
    end
    stop_tweak_timer("macro:tweak-miss")
    local stop_hover_timer = profile.start()
    fetch_via_hover(bufnr, row, col, function(hover_lines)
      if hover_lines and #hover_lines > 0 then
        stop_hover_timer("macro:hover")
      else
        stop_hover_timer("macro:hover-miss")
      end
      cb(hover_lines)
    end)
  end)
end

-- The interceptor and its claims, for tests: they are the state the fetches
-- share, and a spec drives them directly.
M._install_interceptor = install_interceptor
M._claims_by_client = claims_by_client
M._prune_dead_clients = prune_dead_clients

return M
