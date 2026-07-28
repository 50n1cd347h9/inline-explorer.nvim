-- Macro expansion: a macro has no type or structured body to transform, so we
-- ask the live clangd. Preferred path: the ExpandMacro tweak (codeAction ->
-- executeCommand), whose workspace/applyEdit we intercept (for the fetch and
-- a 3s grace window after -- a reply straggling past ~5s would fall through
-- to the default handler instead) -- we only take its newText as the
-- expansion. clangd runs the real preprocessor, so the result respects
-- include paths / #define / #ifdef. Fallback: scrape the expansion from
-- textDocument/hover markdown (older clangd, tweak failure, timeout).
local M = {}

local function parse(src)
  return vim.treesitter.get_string_parser(src, "c"):parse()[1]:root()
end
local function sb(n)
  return (select(3, n:range(true)))
end
local function eb(n)
  return (select(6, n:range(true)))
end
local function scol(n)
  return (select(2, n:range(true)))
end

-- Flatten LSP Hover.contents (MarkupContent | MarkedString | MarkedString[]).
local function markup(contents)
  if type(contents) ~= "table" then
    return contents or ""
  end
  if contents.value then
    return contents.value
  end
  local parts = {}
  for _, c in ipairs(contents) do
    parts[#parts + 1] = type(c) == "table" and (c.value or "") or c
  end
  return table.concat(parts, "\n")
end

-- Extract the expansion from clangd's macro hover markdown. clangd puts the
-- `#define` and the expansion in fenced code, separated by an "Expands to"
-- marker that may be plain markdown OR a `// Expands to` comment inside the same
-- block. Take the code that follows the marker (falling back to all code).
local function expansion_lines(md)
  local incode, seen = false, false
  local after, all = {}, {}
  for _, l in ipairs(vim.split(md, "\n", { plain = true })) do
    if l:match("^%s*```") then
      incode = not incode
    elseif l:lower():find("expands to", 1, true) then
      seen = true -- marker line itself is dropped
    elseif incode then
      all[#all + 1] = l
      if seen then
        after[#after + 1] = l
      end
    end
  end
  -- Only treat it as a macro expansion when clangd actually showed one; a plain
  -- function-signature hover (no "Expands to") must NOT be spliced in.
  if not (seen and #after > 0) then
    return nil
  end
  local out = after
  while out[1] and out[1]:match("^%s*$") do
    table.remove(out, 1)
  end
  while out[#out] and out[#out]:match("^%s*$") do
    table.remove(out)
  end
  return out
end

M._markup = markup
M._expansion_lines = expansion_lines

-- The macro use under (row, col): the whole call_expression for a function-like
-- macro, else the identifier. Also whether it sits in statement position.
local function find_invocation(root, row, col)
  local node = root:named_descendant_for_range(row, col, row, col)
  while node and node:type() ~= "identifier" do
    node = node:parent()
  end
  if not node then
    return nil
  end
  local inv, p = node, node:parent()
  if p and p:type() == "call_expression" and p:field("function")[1] and sb(p:field("function")[1]) == sb(node) then
    inv = p
  end
  local stmt = inv:parent() and inv:parent():type() == "expression_statement"
  return inv, stmt
end

-- Replace the macro use under the cursor with `exp_lines`. Returns new_src, err.
function M.replace_in_src(src, row, col, exp_lines)
  local inv, stmt_ctx = find_invocation(parse(src), row, col)
  if not inv then
    return nil, "no macro use under the cursor"
  end
  local parts = {}
  for i, l in ipairs(exp_lines) do
    parts[i] = l
  end
  if #parts > 1 then
    -- Indent continuation lines to the leading whitespace of the use's line
    -- (NOT everything before the macro, which would repeat `foo = ` on each line).
    local bol = sb(inv) - scol(inv)
    local indent = src:sub(bol + 1):match("^[ \t]*")
    for i = 2, #parts do
      parts[i] = indent .. parts[i]
    end
  end
  -- Collapse the redundant paren nests kernel macros wrap their bodies in
  -- (`(({ ... }))` and friends) before deciding on our own parenthesisation.
  local exp = require("inline-explorer.simplify").parens(table.concat(parts, "\n"))
  -- Parenthesise in expression context to preserve precedence, unless the
  -- expansion is already a single balanced (...) or ({...}) group.
  local already_grouped = exp:match("^%b()$") ~= nil
  local rep = (stmt_ctx or already_grouped) and exp or ("(" .. exp .. ")")
  return src:sub(1, sb(inv)) .. rep .. src:sub(eb(inv) + 1)
end

-- How long the tweak path may take before we give up and fall back to hover.
local TWEAK_TIMEOUT_MS = 2000

-- Pick clangd's "Expand macro" tweak out of a codeAction response. The
-- protocol allows two shapes: a bare Command, or a CodeAction wrapping one.
function M._pick_expand_action(actions)
  if type(actions) ~= "table" then
    return nil
  end
  for _, a in ipairs(actions) do
    if type(a) == "table" and type(a.title) == "string" and a.title:find("^Expand macro") then
      local cmd = (type(a.command) == "table") and a.command or a
      if type(cmd.command) == "string" and cmd.command ~= "" then
        return cmd
      end
    end
  end
  return nil
end

-- Extract the expansion text the tweak's applyEdit carries for `uri`, as
-- trimmed lines. Handles both WorkspaceEdit shapes (changes / documentChanges).
function M._edit_lines(workspace_edit, uri)
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
  local out = vim.split(edits[1].newText, "\n", { plain = true })
  while out[1] and out[1]:match("^%s*$") do
    table.remove(out, 1)
  end
  while out[#out] and out[#out]:match("^%s*$") do
    table.remove(out)
  end
  if #out == 0 then
    return nil
  end
  return out
end

-- How long after a fetch ends a straggling applyEdit for that same macro is
-- still swallowed rather than delegated (a slow tweak that lands after the
-- timeout must never reach the real buffer).
--
-- Honest residual: within this window, a genuine single-document edit whose
-- range happens to contain the fetch position -- a rename of that very macro,
-- say -- is swallowed and falsely answered { applied = true }. That is the
-- price of keeping a late tweak edit out of the real file: applyEdit carries no
-- correlation id back to the executeCommand that caused it, so there is no way
-- to tell the two apart. The window is kept short for that reason.
local GRACE_MS = 3000

-- client.id -> LIST of claims, each { uri, pos, on_edit = fn|nil, expires = nil|uv-ms }.
-- on_edit set   : a fetch is in flight and wants the matching edit.
-- on_edit nil   : tombstone -- that fetch is over (or already consumed its
--                 edit), swallow a further match until `expires`, then prune.
-- One claim PER FETCH, never one slot per client: overlapping fetches each keep
-- their own claim, so a superseded fetch still gets a tombstone and its late
-- edit can never fall through to the real buffer.
local pending = {}
-- client.id -> the interceptor closure we installed, so we can detect another
-- plugin replacing it and chain-reinstall on top.
local our_handler = {}

-- Is `pos` inside `range` (inclusive on both ends)?
local function pos_in_range(pos, range)
  if type(range) ~= "table" or type(range.start) ~= "table" or type(range["end"]) ~= "table" then
    return false
  end
  local function ge(a, b)
    if a.line ~= b.line then
      return (a.line or 0) > (b.line or 0)
    end
    return (a.character or 0) >= (b.character or 0)
  end
  return ge(pos, range.start) and ge(range["end"], pos)
end

-- Does this WorkspaceEdit look like OUR ExpandMacro tweak's edit? True iff it
-- touches exactly the one document `uri` (nothing else) AND at least one of its
-- ranges contains `pos` -- i.e. it rewrites the macro invocation we asked
-- about. Foreign edits (a rename spanning several files, another plugin's code
-- action, an edit elsewhere in this file) fail one of the two tests and are
-- delegated to the original handler untouched.
function M._edit_matches(workspace_edit, uri, pos)
  if type(workspace_edit) ~= "table" or type(uri) ~= "string" or type(pos) ~= "table" then
    return false
  end
  local edits
  if type(workspace_edit.changes) == "table" then
    for k, v in pairs(workspace_edit.changes) do
      if k ~= uri then
        return false -- a second document -> not ours
      end
      edits = v
    end
  elseif type(workspace_edit.documentChanges) == "table" then
    for _, dc in ipairs(workspace_edit.documentChanges) do
      if type(dc) ~= "table" or type(dc.textDocument) ~= "table" or dc.textDocument.uri ~= uri then
        return false -- a foreign uri, or a create/rename/delete op -> not ours
      end
      if type(dc.edits) == "table" then
        edits = edits or {}
        for _, e in ipairs(dc.edits) do
          edits[#edits + 1] = e
        end
      end
    end
  end
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

-- Install the workspace/applyEdit interceptor on `client`.
--
-- It is deliberately NEVER uninstalled. The handler present at install time is
-- captured as `prev`, and every applyEdit that matches no claim is delegated to
-- it (or to the global handler), so the interceptor is transparent: renames,
-- other plugins' code actions and edits elsewhere in the file all behave exactly
-- as before, even while a fetch is in flight. Nothing is ever restored-to-nil,
-- so no foreign handler can be wiped out by a restore; a late edit is swallowed
-- as long as its claim's grace window lasts, and only past that (~5s) would it
-- fall through to the delegate instead.
--
-- Calling this again is a no-op while our closure is still the installed
-- handler. If another plugin has replaced it since, we install a fresh
-- interceptor that captures THAT handler as `prev` -- chaining onto it rather
-- than fighting it, and restoring our coverage.
local function install_interceptor(client)
  local mine = our_handler[client.id]
  if mine ~= nil and client.handlers["workspace/applyEdit"] == mine then
    return
  end
  local prev = client.handlers["workspace/applyEdit"]
  local handler = function(err, params, ctx, config)
    local claims = pending[client.id]
    local edit = params and params.edit
    if claims then
      local now = vim.uv.now()
      -- Drop tombstones whose grace window has passed: edits matching them are
      -- no longer plausibly ours and must reach the real handler again.
      for i = #claims, 1, -1 do
        local c = claims[i]
        if c.expires and now >= c.expires then
          table.remove(claims, i)
        end
      end
      -- Prefer an in-flight fetch (newest first) over a tombstone, so a fresh
      -- fetch at a position an older one also covered still gets its answer.
      local hit
      for i = #claims, 1, -1 do
        if claims[i].on_edit and M._edit_matches(edit, claims[i].uri, claims[i].pos) then
          hit = claims[i]
          break
        end
      end
      if hit then
        -- Consume, and downgrade IN PLACE rather than removing the claim: a
        -- duplicate applyEdit for the same tweak then hits the tombstone below
        -- instead of being delegated and applied for real.
        local on_edit = hit.on_edit
        hit.on_edit = nil
        hit.expires = now + GRACE_MS
        on_edit(edit)
        return { applied = true }
      end
      for i = #claims, 1, -1 do
        if M._edit_matches(edit, claims[i].uri, claims[i].pos) then
          -- A live tombstone: that fetch is over, but this is still its edit --
          -- swallow it so the expansion never lands in the real source buffer.
          return { applied = true }
        end
      end
    end
    local fallback = prev or vim.lsp.handlers["workspace/applyEdit"]
    return fallback(err, params, ctx, config)
  end
  client.handlers["workspace/applyEdit"] = handler
  our_handler[client.id] = handler
end

M._install_interceptor = install_interceptor
M._pending = pending

-- client.request became a colon-method in 0.11; 0.10 uses the dot form.
local function client_request(client, method, params, handler, bufnr)
  if vim.fn.has("nvim-0.11") == 1 then
    return client:request(method, params, handler, bufnr)
  end
  return client.request(method, params, handler, bufnr)
end

-- Drop claim lists and interceptor bookkeeping for clients that no longer
-- exist (ids are monotonic, so no reuse hazard -- this is pure housekeeping,
-- run on each fetch so a restarted clangd doesn't leave dead entries behind).
function M._prune_dead_clients()
  for id in pairs(pending) do
    if not vim.lsp.get_client_by_id(id) then
      pending[id] = nil
      our_handler[id] = nil
    end
  end
  for id in pairs(our_handler) do
    if not vim.lsp.get_client_by_id(id) then
      our_handler[id] = nil
    end
  end
end

-- Fetch the expansion via the ExpandMacro tweak. Calls cb(lines|nil) exactly
-- once: on success with the applyEdit's newText lines, on any failure -- no
-- clangd, no tweak support, no action at this position, request error, or
-- timeout -- with nil so the caller can fall back.
local function fetch_via_tweak(st, row, col, cb)
  M._prune_dead_clients()
  local client = vim.lsp.get_clients({ bufnr = st.source_bufnr, name = "clangd" })[1]
  if not client then
    return cb(nil)
  end
  local provider = (client.server_capabilities or {}).executeCommandProvider
  local cmds = (type(provider) == "table" and type(provider.commands) == "table") and provider.commands or {}
  if not vim.tbl_contains(cmds, "clangd.applyTweak") then
    return cb(nil)
  end

  install_interceptor(client)

  local uri = vim.uri_from_bufnr(st.source_bufnr)
  local pos = { line = row, character = col }

  -- Exactly-once guard shared by the success path, every error path, and the
  -- timeout. Instead of removing the interception it downgrades THIS fetch's own
  -- claim, in place, to a swallow-only tombstone, so an applyEdit that arrives
  -- after we have given up is discarded rather than written to the real file.
  -- Other fetches' claims in the list are never touched. If the claim is already
  -- a tombstone the interceptor consumed the edit and dated it -- leave it be.
  local finished = false
  local claim
  local function finish(lines)
    if finished then
      return
    end
    finished = true
    if claim and claim.on_edit then
      claim.on_edit = nil
      claim.expires = vim.uv.now() + GRACE_MS
    end
    cb(lines)
  end
  vim.defer_fn(function()
    finish(nil)
  end, TWEAK_TIMEOUT_MS)

  local ca_params = {
    textDocument = { uri = uri },
    range = { start = pos, ["end"] = pos },
    context = { diagnostics = {} },
  }
  local ca_ok = client_request(client, "textDocument/codeAction", ca_params, function(err, actions)
    if finished then
      return
    end
    if err then
      return finish(nil)
    end
    local cmd = M._pick_expand_action(actions)
    if not cmd then
      return finish(nil)
    end

    -- Claim the applyEdit this tweak will send back. The interceptor is already
    -- installed; this only tells it which edit is ours. The claim is APPENDED:
    -- a concurrent fetch on the same client keeps its own claim, so both are
    -- answered and both leave a tombstone behind.
    claim = { uri = uri, pos = pos, on_edit = function(edit)
      finish(M._edit_lines(edit, uri))
    end }
    local claims = pending[client.id]
    if not claims then
      claims = {}
      pending[client.id] = claims
    end
    claims[#claims + 1] = claim

    local ok = client_request(client, "workspace/executeCommand", {
      command = cmd.command,
      arguments = cmd.arguments,
    }, function(cerr)
      if cerr then
        finish(nil)
      end
      -- On success the reply carries no edit; the applyEdit interception (or
      -- the timeout) is what finishes the fetch.
    end, st.source_bufnr)
    if not ok then
      finish(nil) -- request never went out; don't sit out the timeout
    end
  end, st.source_bufnr)
  if not ca_ok then
    finish(nil)
  end
end

-- Fetch a macro's expansion from clangd hover at (row, col). cb(lines|nil).
-- Fallback path: works on any clangd, but scrapes markdown.
local function fetch_via_hover(st, row, col, cb)
  -- Filter by the source buffer: buf_request_all never invokes its handler
  -- when the buffer has no attached clients, which would starve cb entirely.
  if #vim.lsp.get_clients({ bufnr = st.source_bufnr, name = "clangd" }) == 0 then
    return cb(nil)
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(st.source_bufnr) },
    position = { line = row, character = col },
  }
  vim.lsp.buf_request_all(st.source_bufnr, "textDocument/hover", params, function(results)
    local md
    for _, r in pairs(results or {}) do
      if r.result and r.result.contents then
        md = markup(r.result.contents)
        break
      end
    end
    cb(md and md ~= "" and expansion_lines(md) or nil)
  end)
end

-- Fetch a macro's expansion at (row, col): ExpandMacro tweak first, hover as
-- fallback. cb(lines|nil), called exactly once.
function M.fetch_expansion(st, row, col, cb)
  fetch_via_tweak(st, row, col, function(lines)
    if lines and #lines > 0 then
      return cb(lines)
    end
    fetch_via_hover(st, row, col, cb)
  end)
end

return M
