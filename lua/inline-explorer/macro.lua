-- Macro expansion: a macro has no type or structured body to transform, so we
-- ask the live clangd. Preferred path: the ExpandMacro tweak (codeAction ->
-- executeCommand), whose workspace/applyEdit we intercept -- the edit is never
-- applied to the real file, we only take its newText as the expansion. clangd
-- runs the real preprocessor, so the result respects include paths / #define /
-- #ifdef. Fallback: scrape the expansion from textDocument/hover markdown
-- (older clangd, tweak failure, timeout).
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
  local exp = table.concat(parts, "\n")
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

-- client.request became a colon-method in 0.11; 0.10 uses the dot form.
local function client_request(client, method, params, handler, bufnr)
  if vim.fn.has("nvim-0.11") == 1 then
    return client:request(method, params, handler, bufnr)
  end
  return client.request(method, params, handler, bufnr)
end

-- Fetch the expansion via the ExpandMacro tweak. Calls cb(lines|nil) exactly
-- once: on success with the applyEdit's newText lines, on any failure -- no
-- clangd, no tweak support, no action at this position, request error, or
-- timeout -- with nil so the caller can fall back.
local function fetch_via_tweak(st, row, col, cb)
  local client = vim.lsp.get_clients({ bufnr = st.source_bufnr, name = "clangd" })[1]
  if not client then
    return cb(nil)
  end
  local provider = (client.server_capabilities or {}).executeCommandProvider
  local cmds = (type(provider) == "table" and type(provider.commands) == "table") and provider.commands or {}
  if not vim.tbl_contains(cmds, "clangd.applyTweak") then
    return cb(nil)
  end

  local uri = vim.uri_from_bufnr(st.source_bufnr)
  local pos = { line = row, character = col }

  -- Exactly-once guard shared by the success path, every error path, and the
  -- timeout; also restores the intercepted applyEdit handler.
  local finished = false
  local prev_handler
  local function finish(lines)
    if finished then
      return
    end
    finished = true
    if prev_handler ~= nil or client.handlers["workspace/applyEdit"] ~= nil then
      client.handlers["workspace/applyEdit"] = prev_handler
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
  client_request(client, "textDocument/codeAction", ca_params, function(err, actions)
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

    -- Intercept the applyEdit this tweak will send back. Per-client handlers
    -- take precedence over the global vim.lsp.handlers, so only this client's
    -- applyEdit is diverted, and finish() restores the previous handler.
    prev_handler = client.handlers["workspace/applyEdit"]
    client.handlers["workspace/applyEdit"] = function(_, apply_params)
      finish(M._edit_lines(apply_params and apply_params.edit, uri))
      -- Tell the server the edit was applied -- it was, to our reading view.
      return { applied = true }
    end

    client_request(client, "workspace/executeCommand", {
      command = cmd.command,
      arguments = cmd.arguments,
    }, function(cerr)
      if cerr then
        finish(nil)
      end
      -- On success the reply carries no edit; the applyEdit interception (or
      -- the timeout) is what finishes the fetch.
    end, st.source_bufnr)
  end, st.source_bufnr)
end

-- Fetch a macro's expansion from clangd hover at (row, col). cb(lines|nil).
-- Fallback path: works on any clangd, but scrapes markdown.
local function fetch_via_hover(st, row, col, cb)
  if #vim.lsp.get_clients({ name = "clangd" }) == 0 then
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
