-- Macro expansion through clangd, which runs the real preprocessor. Preferred:
-- textDocument/codeAction offers the ExpandMacro tweak, executeCommand runs
-- it, and clangd sends back a workspace/applyEdit, which we intercept and read
-- instead of applying. Fallback: the expansion that textDocument/hover shows.
-- A fetch is one tweak request; its claim lets the interceptor recognize its
-- applyEdit. When the fetch ends, the claim becomes a tombstone, which for
-- GRACE_MS (the grace window) discards a late matching applyEdit rather than
-- let it edit the source buffer.

local async = require("inline-explorer.async")
local csrc = require("inline-explorer.csrc")
local profile = require("inline-explorer.profile")
local simplify = require("inline-explorer.simplify")
local util = require("inline-explorer.util")

local M = {}

local function trim_blank_lines(lines)
  while lines[1] and lines[1]:match("^%s*$") do
    table.remove(lines, 1)
  end
  while lines[#lines] and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  return lines
end

---@param contents lsp.MarkedString|lsp.MarkedString[]|lsp.MarkupContent
---@return string
local function hover_markdown(contents)
  return table.concat(vim.lsp.util.convert_input_to_markdown_lines(contents), "\n")
end

-- clangd's hover for a macro shows the `#define` and the expansion in fenced
-- code, split by an "Expands to" marker: a markdown line, or a `// Expands to`
-- comment inside the block.
---@param md string
---@return string[]? lines nil when the hover shows no expansion, {} when it is only blank lines
local function expansion_lines(md)
  local in_code, seen_marker = false, false
  local after = {}
  for _, l in ipairs(vim.split(md, "\n", { plain = true })) do
    if l:match("^%s*```") then
      in_code = not in_code
    elseif l:lower():find("expands to", 1, true) then
      seen_marker = true
    elseif in_code and seen_marker then
      after[#after + 1] = l
    end
  end
  if not (seen_marker and #after > 0) then
    return nil
  end
  return trim_blank_lines(after)
end

-- The macro use at (row, col), and whether it is a whole expression statement.
-- The use is the call_expression when the identifier there is its callee, else
-- the identifier.
local function find_invocation(root, row, col)
  local node = csrc.ancestor_at(root, row, col, "identifier")
  if not node then
    return nil
  end
  local invocation = node
  local parent = node:parent()
  if parent and parent:type() == "call_expression" then
    local callee = parent:field("function")[1]
    if callee and csrc.start_byte(callee) == csrc.start_byte(node) then
      invocation = parent
    end
  end
  local outer = invocation:parent()
  local is_statement = outer ~= nil and outer:type() == "expression_statement"
  return invocation, is_statement
end

-- `src` with the macro use at (row, col) replaced by `exp_lines`. `root` is
-- src's parsed root, when the caller has it.
---@param src string
---@param row integer 0-based
---@param col integer 0-based, in bytes
---@param exp_lines string[]
---@param root? TSNode
---@return string? new_src
---@return string? err
function M.replace_in_src(src, row, col, exp_lines, root)
  local invocation, is_statement = find_invocation(root or csrc.parse(src), row, col)
  if not invocation then
    return nil, "no macro use under the cursor"
  end
  local parts = {}
  for i, l in ipairs(exp_lines) do
    parts[i] = l
  end
  if #parts > 1 then
    -- The indent of the use's line, not all text before the use, which would
    -- repeat `foo = ` on each line.
    local indent = csrc.line_indent(src, invocation)
    for i = 2, #parts do
      parts[i] = indent .. parts[i]
    end
  end
  -- Trimmed because clangd's text can start with a space, which would fail
  -- the anchored `^%b()$` check below.
  local exp = vim.trim(simplify.parens(table.concat(parts, "\n")))
  local rep = exp
  if not is_statement then
    -- Parenthesized to keep its precedence in an expression; simplify.parens
    -- then drops a pair if the wrap doubled one.
    if not exp:match("^%b()$") then
      rep = "(" .. exp .. ")"
    end
    rep = simplify.parens(rep)
  end
  return src:sub(1, csrc.start_byte(invocation)) .. rep .. src:sub(csrc.end_byte(invocation) + 1)
end

-- Budget for the tweak (codeAction through applyEdit), and again for the hover.
local TIMEOUT_MS = 2000

---@param actions any
---@return lsp.Command? cmd the command of the "Expand macro" action in a codeAction reply
local function pick_expand_action(actions)
  if type(actions) ~= "table" then
    return nil
  end
  for _, action in ipairs(actions) do
    if type(action) == "table" and type(action.title) == "string" and action.title:find("^Expand macro") then
      -- A CodeAction holds its Command in `.command`; a bare Command has a
      -- string there.
      local cmd = action
      if type(action.command) == "table" then
        cmd = action.command
      end
      if type(cmd.command) == "string" and cmd.command ~= "" then
        return cmd
      end
    end
  end
  return nil
end

local function at_or_after(a, b)
  if a.line ~= b.line then
    return (a.line or 0) > (b.line or 0)
  end
  return (a.character or 0) >= (b.character or 0)
end

-- Both ends of `range` count as inside.
local function pos_in_range(pos, range)
  if type(range) ~= "table" or type(range.start) ~= "table" or type(range["end"]) ~= "table" then
    return false
  end
  return at_or_after(pos, range.start) and at_or_after(range["end"], pos)
end

-- The edit that replaces the text at `pos`, else one that ends or inserts
-- there. clangd formats the tweak's output, so the expansion can come with
-- whitespace edits around it, and an edit's place in the list means nothing.
local function edit_at(edits, pos)
  local touching
  for _, e in ipairs(edits) do
    if type(e) == "table" and pos_in_range(pos, e.range) then
      if not at_or_after(pos, e.range["end"]) then
        return e
      end
      touching = touching or e
    end
  end
  return touching
end

-- The text edits of `workspace_edit`, if it edits document `uri` and nothing
-- else: no other document, and no file created, renamed or deleted.
local function edits_only_for(workspace_edit, uri)
  local edits
  if type(workspace_edit.changes) == "table" then
    for k, v in pairs(workspace_edit.changes) do
      if k ~= uri then
        return nil
      end
      edits = v
    end
  elseif type(workspace_edit.documentChanges) == "table" then
    for _, dc in ipairs(workspace_edit.documentChanges) do
      if type(dc) ~= "table" or type(dc.textDocument) ~= "table" or dc.textDocument.uri ~= uri then
        return nil
      end
      if type(dc.edits) == "table" then
        edits = edits or {}
        for _, e in ipairs(dc.edits) do
          edits[#edits + 1] = e
        end
      end
    end
  end
  return edits
end

-- Whether `workspace_edit` can be the ExpandMacro edit for the macro use at
-- `pos`: it edits document `uri` only, and one of its ranges contains `pos`.
---@param workspace_edit lsp.WorkspaceEdit?
---@param uri string
---@param pos lsp.Position
---@return boolean
local function edit_matches(workspace_edit, uri, pos)
  if type(workspace_edit) ~= "table" or type(uri) ~= "string" or type(pos) ~= "table" then
    return false
  end
  local edits = edits_only_for(workspace_edit, uri)
  if type(edits) ~= "table" then
    return false
  end
  return edit_at(edits, pos) ~= nil
end

-- The newText of the edit at `pos` in document `uri` (see edit_at), without
-- blank edge lines. Like edits_only_for, it reads every documentChanges
-- entry for `uri`, so an edit edit_matches accepted is found here too, in
-- whichever entry it is; edits to other documents are passed over, as
-- edit_matches has already refused them.
---@param workspace_edit lsp.WorkspaceEdit?
---@param uri string
---@param pos lsp.Position
---@return string[]? lines nil when there is no text
local function edit_lines(workspace_edit, uri, pos)
  if type(workspace_edit) ~= "table" then
    return nil
  end
  local edits
  if type(workspace_edit.changes) == "table" and workspace_edit.changes[uri] then
    edits = workspace_edit.changes[uri]
  elseif type(workspace_edit.documentChanges) == "table" then
    for _, dc in ipairs(workspace_edit.documentChanges) do
      if type(dc) == "table" and dc.textDocument and dc.textDocument.uri == uri and type(dc.edits) == "table" then
        edits = edits or {}
        vim.list_extend(edits, dc.edits)
      end
    end
  end
  local edit = type(edits) == "table" and edit_at(edits, pos)
  if not edit or type(edit.newText) ~= "string" then
    return nil
  end
  local out = trim_blank_lines(vim.split(edit.newText, "\n", { plain = true }))
  if #out == 0 then
    return nil
  end
  return out
end

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
    if is_in_flight(claim) == in_flight and edit_matches(edit, claim.uri, claim.pos) then
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
    local cmd = not err and pick_expand_action(actions)
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
        finish(edit_lines(edit, uri, pos))
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

-- Calls cb(lines) once, with expansion_lines' result, or nil with no hover,
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
    local md = contents and hover_markdown(contents)
    if md and md ~= "" then
      return cb(expansion_lines(md))
    end
    cb(nil)
  end)
end

-- Calls cb(lines) exactly once: nil when neither the tweak nor the hover has
-- an expansion, {} when the hover's is only blank lines. (row, col) is in the
-- source buffer; a nil row (a use with no source line) gives cb(nil) at once.
---@param st inline_explorer.ViewState
---@param row integer? 0-based
---@param col integer 0-based, in bytes
---@param cb fun(lines: string[]?)
function M.fetch_expansion(st, row, col, cb)
  if row == nil then
    return cb(nil)
  end
  local bufnr = st.source_bufnr
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

-- Internals exposed for tests.
M._expansion_lines = expansion_lines
M._hover_markdown = hover_markdown
M._pick_expand_action = pick_expand_action
M._edit_lines = edit_lines
M._edit_matches = edit_matches
M._install_interceptor = install_interceptor
M._pending = claims_by_client
M._prune_dead_clients = prune_dead_clients

return M
