-- clangd's replies about a macro use, read: the "Expand macro" action in a
-- codeAction reply, the edit in the workspace/applyEdit that its command
-- sends back, and the expansion a hover shows. Pure functions of the
-- replies; macro.lua sends the requests.

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
function M.hover_markdown(contents)
  return table.concat(vim.lsp.util.convert_input_to_markdown_lines(contents), "\n")
end

-- clangd's hover for a macro shows the `#define` and the expansion in fenced
-- code, split by an "Expands to" marker: a markdown line, or a `// Expands to`
-- comment inside the block.
---@param md string
---@return string[]? lines nil when the hover shows no expansion, {} when it is only blank lines
function M.expansion_lines(md)
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

---@param actions any
---@return lsp.Command? cmd the command of the "Expand macro" action in a codeAction reply
function M.pick_expand_action(actions)
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
function M.edit_matches(workspace_edit, uri, pos)
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
function M.edit_lines(workspace_edit, uri, pos)
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

return M
