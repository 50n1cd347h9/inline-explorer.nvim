-- Macro expansion through clangd. A macro has no type or structured body for
-- tree-sitter to work with, so we ask clangd, which runs the real
-- preprocessor (include paths, #define, #ifdef).
--
-- Preferred path: the ExpandMacro tweak. We send textDocument/codeAction, then
-- workspace/executeCommand with the tweak's command. clangd answers by sending
-- us a workspace/applyEdit request. We intercept that request and take its
-- newText as the expansion, instead of applying it to the buffer.
--
-- Fallback (older clangd, a tweak failure, or no answer within
-- TWEAK_TIMEOUT_MS): read the expansion from the textDocument/hover markdown.
--
-- Terms: a "fetch" is one expansion request through the tweak. It registers a
-- "claim" so that the interceptor can recognize its applyEdit. When the fetch
-- ends, its claim becomes a "tombstone", which catches and discards a
-- matching applyEdit for GRACE_MS more (the "grace window"). So a reply that
-- arrives shortly after the timeout does not edit the buffer.

-- csrc.parse caches trees by source text, so a source that another module has
-- already parsed is not parsed again here.
local csrc = require("inline-explorer.csrc")
local profile = require("inline-explorer.profile")
-- resolver.client_request calls client.request in the form that the running
-- Neovim uses (a dot call on 0.10, a colon call on 0.11).
local resolver = require("inline-explorer.resolver")
local simplify = require("inline-explorer.simplify")
local util = require("inline-explorer.util")

local M = {}

-- `lines` without leading and trailing whitespace-only lines (in place).
local function trim_blank_lines(lines)
  while lines[1] and lines[1]:match("^%s*$") do
    table.remove(lines, 1)
  end
  while lines[#lines] and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  return lines
end

-- Hover.contents (MarkupContent | MarkedString | MarkedString[]) as one
-- markdown string. Language-tagged MarkedStrings come back fenced, which is
-- the shape expansion_lines reads.
local function hover_markdown(contents)
  return table.concat(vim.lsp.util.convert_input_to_markdown_lines(contents), "\n")
end

-- The expansion lines in clangd's hover markdown for a macro, or nil when the
-- hover shows no expansion. clangd puts the `#define` and the expansion in
-- fenced code, separated by an "Expands to" marker. The marker is either a
-- plain markdown line or a `// Expands to` comment inside the same block. The
-- code after the marker is the expansion.
local function expansion_lines(md)
  local in_code, seen_marker = false, false
  local after = {}
  for _, l in ipairs(vim.split(md, "\n", { plain = true })) do
    if l:match("^%s*```") then
      in_code = not in_code
    elseif l:lower():find("expands to", 1, true) then -- plain-text search
      seen_marker = true -- the marker line itself is dropped
    elseif in_code and seen_marker then
      after[#after + 1] = l
    end
  end
  -- Without the marker and code after it, this is not a macro expansion (the
  -- hover may show a function signature, for example), and it must not be
  -- spliced in.
  if not (seen_marker and #after > 0) then
    return nil
  end
  return trim_blank_lines(after)
end

-- The macro use at (row, col): the whole call_expression for a function-like
-- macro, otherwise the identifier. Returns invocation, is_statement (whether
-- the use is an expression statement of its own), or nil when there is no
-- identifier at (row, col).
local function find_invocation(root, row, col)
  local node = csrc.ancestor_at(root, row, col, "identifier")
  if not node then
    return nil
  end
  local invocation = node
  local parent = node:parent()
  if parent and parent:type() == "call_expression" then
    local callee = parent:field("function")[1]
    -- `node` is the name being called, so the use is the whole call.
    if callee and csrc.start_byte(callee) == csrc.start_byte(node) then
      invocation = parent
    end
  end
  local outer = invocation:parent()
  local is_statement = outer ~= nil and outer:type() == "expression_statement"
  return invocation, is_statement
end

-- Replace the macro use at (row, col) of `src` with the expansion `exp_lines`.
-- `root` is src's tree, when the caller already has it. Returns the new
-- source, or nil and an error message.
function M.replace_in_src(src, row, col, exp_lines, root)
  local invocation, is_statement = find_invocation(root or csrc.parse(src), row, col)
  if not invocation then
    return nil, "no macro use under the cursor"
  end
  -- A copy, so that indenting it below leaves the caller's exp_lines unchanged.
  local parts = {}
  for i, l in ipairs(exp_lines) do
    parts[i] = l
  end
  if #parts > 1 then
    -- Indent continuation lines to the leading whitespace of the use's line,
    -- not to everything before the macro (that would repeat `foo = ` on each line).
    local indent = csrc.line_indent(src, invocation)
    for i = 2, #parts do
      parts[i] = indent .. parts[i]
    end
  end
  -- simplify.parens turns `((X))` into `(X)`, which removes the `(({ ... }))`
  -- nests that kernel macros put around their bodies. Trim after it, because
  -- the grouped check below is anchored at both ends, and clangd's text can
  -- start with a space.
  local exp = vim.trim(simplify.parens(table.concat(parts, "\n")))
  local rep = exp
  if not is_statement then
    -- In an expression, wrap the expansion to keep its precedence, unless it
    -- already is one balanced (...) or ({...}) group. Then collapse the double
    -- parentheses that the wrap may have created.
    if not exp:match("^%b()$") then
      rep = "(" .. exp .. ")"
    end
    rep = simplify.parens(rep)
  end
  return src:sub(1, csrc.start_byte(invocation)) .. rep .. src:sub(csrc.end_byte(invocation) + 1)
end

-- How long the tweak path may take before we give up and fall back to hover.
local TWEAK_TIMEOUT_MS = 2000

-- clangd's "Expand macro" tweak in a codeAction response, as the Command to
-- execute; nil when the response has none.
local function pick_expand_action(actions)
  if type(actions) ~= "table" then
    return nil
  end
  for _, action in ipairs(actions) do
    if type(action) == "table" and type(action.title) == "string" and action.title:find("^Expand macro") then
      -- The protocol allows two shapes. A CodeAction holds its Command table
      -- in `.command`. A bare Command has a command-id string there and is
      -- itself what we execute.
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

-- Whether LSP position `a` is at or after position `b`.
local function at_or_after(a, b)
  if a.line ~= b.line then
    return (a.line or 0) > (b.line or 0)
  end
  return (a.character or 0) >= (b.character or 0)
end

-- Whether `pos` is inside `range`, both ends included.
local function pos_in_range(pos, range)
  if type(range) ~= "table" or type(range.start) ~= "table" or type(range["end"]) ~= "table" then
    return false
  end
  return at_or_after(pos, range.start) and at_or_after(range["end"], pos)
end

-- The text edits of `workspace_edit` when it touches document `uri` and
-- nothing else; nil when it also touches another document, or carries a
-- create, rename or delete operation.
local function edits_only_for(workspace_edit, uri)
  local edits
  if type(workspace_edit.changes) == "table" then
    for k, v in pairs(workspace_edit.changes) do
      if k ~= uri then
        return nil -- a second document: not ours
      end
      edits = v
    end
  elseif type(workspace_edit.documentChanges) == "table" then
    for _, dc in ipairs(workspace_edit.documentChanges) do
      if type(dc) ~= "table" or type(dc.textDocument) ~= "table" or dc.textDocument.uri ~= uri then
        return nil -- a foreign uri, or a create/rename/delete operation: not ours
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

-- Whether `workspace_edit` looks like the ExpandMacro edit for the macro use
-- at `pos` in document `uri`: it touches that document only, and one of its
-- ranges contains `pos`. Other edits (a rename across files, another plugin's
-- code action, an edit elsewhere in the file) fail one of the two tests.
local function edit_matches(workspace_edit, uri, pos)
  if type(workspace_edit) ~= "table" or type(uri) ~= "string" or type(pos) ~= "table" then
    return false
  end
  local edits = edits_only_for(workspace_edit, uri)
  if type(edits) ~= "table" then
    return false
  end
  for _, e in ipairs(edits) do
    if type(e) == "table" and pos_in_range(pos, e.range) then
      return true
    end
  end
  return false
end

-- The expansion in the tweak's edit: the newText of the first edit for `uri`,
-- as lines without leading and trailing blank lines. nil when there is no
-- such text. Unlike edit_matches, it does not reject an edit that also
-- touches other documents; it reads only edits that edit_matches accepted.
local function edit_lines(workspace_edit, uri)
  if type(workspace_edit) ~= "table" then
    return nil
  end
  local edits
  if type(workspace_edit.changes) == "table" and workspace_edit.changes[uri] then
    edits = workspace_edit.changes[uri]
  elseif type(workspace_edit.documentChanges) == "table" then
    for _, dc in ipairs(workspace_edit.documentChanges) do
      if type(dc) == "table" and dc.textDocument and dc.textDocument.uri == uri and type(dc.edits) == "table" then
        edits = dc.edits
        break
      end
    end
  end
  if type(edits) ~= "table" or #edits == 0 or type(edits[1].newText) ~= "string" then
    return nil
  end
  local out = trim_blank_lines(vim.split(edits[1].newText, "\n", { plain = true }))
  if #out == 0 then
    return nil
  end
  return out
end

-- After a fetch has finished, an applyEdit that still matches its claim is
-- discarded (not passed on to the previous handler) for GRACE_MS more.
--
-- Known limitation: within this window, a genuine single-document edit whose
-- range contains the fetch position (a rename of that very macro, say) is
-- discarded too, and answered { applied = true }. applyEdit carries no id
-- that links it to the executeCommand that caused it, so the two cannot be
-- told apart. The window is kept short for that reason.
local GRACE_MS = 3000

-- client.id -> list of claims, one per fetch: { uri, pos, on_edit, expires },
-- where uri and pos locate the macro use in LSP terms.
--   in flight: on_edit is set; the fetch is waiting for its applyEdit.
--   tombstone: on_edit is nil; a matching applyEdit is discarded until
--              `expires` (a vim.uv.now() time in milliseconds).
-- Overlapping fetches on one client each keep their own claim, so each one
-- leaves its own tombstone.
local claims_by_client = {}

-- client.id -> the interceptor installed on that client, to tell whether
-- another plugin has replaced it since.
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

-- Remove the tombstones in `claims` whose grace window has passed.
local function drop_expired(claims, now)
  for i = #claims, 1, -1 do
    local claim = claims[i]
    if claim.expires and now >= claim.expires then
      table.remove(claims, i)
    end
  end
end

-- The newest claim in `claims` that matches `edit` and is in flight (when
-- `in_flight` is true) or a tombstone (when it is false); nil when none is.
local function newest_match(claims, edit, in_flight)
  for i = #claims, 1, -1 do
    local claim = claims[i]
    if is_in_flight(claim) == in_flight and edit_matches(edit, claim.uri, claim.pos) then
      return claim
    end
  end
  return nil
end

-- Install a workspace/applyEdit handler on `client` that
--   1. drops tombstones whose grace window has passed,
--   2. gives a matching edit to the newest in-flight claim,
--   3. discards an edit that matches a tombstone,
--   4. passes anything else to the handler installed before it (or to the
--      global one).
-- It is never removed, because putting the previous handler back could undo
-- a handler that another plugin installed later. Calling this again does
-- nothing while our handler is still installed. If another plugin has
-- replaced it, a new one is installed on top of that plugin's handler.
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
      -- An in-flight claim wins over a tombstone, so a new fetch at a
      -- position that an older fetch also covered still gets its answer.
      local claim = newest_match(claims, edit, true)
      if claim then
        -- The claim stays, as a tombstone, so a duplicate applyEdit for the
        -- same tweak is discarded instead of applied.
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

-- Drop the claims and interceptor records of clients that no longer exist,
-- so a restarted clangd leaves no dead entries behind. Client ids are never
-- reused, so this is only housekeeping. Each fetch runs it.
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

-- Whether `client` advertises clangd's applyTweak command (ExpandMacro).
-- :checkhealth reports the same check.
function M.supports_tweak(client)
  local provider = (client.server_capabilities or {}).executeCommandProvider
  if type(provider) ~= "table" or type(provider.commands) ~= "table" then
    return false
  end
  return vim.tbl_contains(provider.commands, "clangd.applyTweak")
end

-- The LSP position of byte column `col` on line `row` of buffer `bufnr`, in
-- `client`'s position encoding (the cursor counts bytes; the server counts
-- in whatever units it negotiated).
local function source_position(bufnr, row, col, client)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  return { line = row, character = util.lsp_col(line, col, client.offset_encoding) }
end

-- Fetch the expansion through the ExpandMacro tweak. Calls cb(lines) exactly
-- once: with the applyEdit's newText lines on success, or with nil on any
-- failure (no clangd, no tweak support, no tweak at this position, a request
-- error, or the timeout), so that the caller can fall back.
local function fetch_via_tweak(bufnr, row, col, cb)
  prune_dead_clients()
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "clangd" })[1]
  if not client then
    return cb(nil)
  end
  if not M.supports_tweak(client) then
    return cb(nil)
  end

  install_interceptor(client)

  local uri = vim.uri_from_bufnr(bufnr)
  local pos = source_position(bufnr, row, col, client)

  local claim -- set when the codeAction reply offers the tweak; nil before that
  local finished = false
  -- finish(lines) ends the fetch, and calls after the first do nothing. The
  -- success path, every error path and the timeout call it. It turns this
  -- fetch's claim into a tombstone, so that a late applyEdit is discarded,
  -- and calls cb. When the interceptor has taken the edit, the claim is a
  -- tombstone already.
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
  vim.defer_fn(function()
    finish(nil)
  end, TWEAK_TIMEOUT_MS)

  local code_action_params = {
    textDocument = { uri = uri },
    range = { start = pos, ["end"] = pos },
    context = { diagnostics = {} },
  }
  local sent = resolver.client_request(client, "textDocument/codeAction", code_action_params, function(err, actions)
    if finished then
      return
    end
    if err then
      return finish(nil)
    end
    local cmd = pick_expand_action(actions)
    if not cmd then
      return finish(nil)
    end

    -- Claim the applyEdit that the tweak will send back, so that the
    -- interceptor hands it to on_edit.
    claim = {
      uri = uri,
      pos = pos,
      on_edit = function(edit)
        finish(edit_lines(edit, uri))
      end,
    }
    add_claim(client.id, claim)

    local exec_sent = resolver.client_request(client, "workspace/executeCommand", {
      command = cmd.command,
      arguments = cmd.arguments,
    }, function(exec_err)
      -- A successful reply carries no edit: the applyEdit (or the timeout)
      -- finishes the fetch.
      if exec_err then
        finish(nil)
      end
    end, bufnr)
    if not exec_sent then
      finish(nil) -- the request never went out; do not wait for the timeout
    end
  end, bufnr)
  if not sent then
    finish(nil)
  end
end

-- Fetch the expansion from clangd's hover at (row, col). This works with any
-- clangd, but reads the expansion out of markdown. Calls cb(lines) once, with
-- nil when the hover shows no expansion.
local function fetch_via_hover(bufnr, row, col, cb)
  -- clangd must be attached: its position encoding is needed below, and with
  -- no client attached, buf_request_all would never call our handler, so cb
  -- would never run.
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "clangd" })[1]
  if not client then
    return cb(nil)
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = source_position(bufnr, row, col, client),
  }
  vim.lsp.buf_request_all(bufnr, "textDocument/hover", params, function(results)
    local md
    for _, r in pairs(results or {}) do
      if r.result and r.result.contents then
        md = hover_markdown(r.result.contents)
        break
      end
    end
    local lines
    if md and md ~= "" then
      lines = expansion_lines(md)
    end
    cb(lines)
  end)
end

-- Fetch the expansion of the macro use at (row, col) of the source file: the
-- ExpandMacro tweak first, hover as the fallback. Calls cb(lines) exactly
-- once, with nil when neither works. `st` is the explorer view state; only
-- st.source_bufnr (the buffer of the original C file) is used. A nil row
-- means the caller could not map its position back to the source (the macro
-- use is on inserted text), so there is nothing to ask.
function M.fetch_expansion(st, row, col, cb)
  if row == nil then
    return cb(nil)
  end
  local bufnr = st.source_bufnr
  -- profile.start() returns a stop function. Calling it with a label records
  -- the time since start() under that label.
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
