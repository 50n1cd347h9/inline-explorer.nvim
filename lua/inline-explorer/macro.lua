-- Macro expansion: unlike functions, a macro has no type or structured body to
-- transform, so we do not expand it ourselves. Instead we ask the live clangd
-- for the expansion via `textDocument/hover` (read-only, no buffer edits) and
-- drop the result into the view as a folded block, reusing the block-expander.
--
-- The hover query runs against the original source buffer at the cursor's
-- coordinates, so it is reliable while the view still lines up with the source
-- (depth 0); large line shifts from prior expansions can misalign it.
local view = require("inline-explorer.view")
local expander = require("inline-explorer.expander")

local M = {}

local function notify(msg, level)
  vim.notify("[inline-explorer] " .. msg, level or vim.log.levels.WARN)
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

-- Extract the expansion from clangd's macro hover markdown: prefer the fenced
-- code block after an "Expands to" marker, else the last code block, else text.
local function expansion_lines(md)
  local lines = vim.split(md, "\n", { plain = true })
  local expands_at
  for i, l in ipairs(lines) do
    if l:lower():find("expands to", 1, true) then
      expands_at = i
      break
    end
  end

  local blocks, cur, startln = {}, nil, nil
  for i, l in ipairs(lines) do
    if l:match("^%s*```") then
      if cur then
        blocks[#blocks + 1] = { startln, cur }
        cur = nil
      else
        cur, startln = {}, i
      end
    elseif cur then
      cur[#cur + 1] = l
    end
  end

  if expands_at then
    for _, b in ipairs(blocks) do
      if b[1] > expands_at then
        return b[2]
      end
    end
  end
  if #blocks > 0 then
    return blocks[#blocks][2]
  end
  local out = {}
  for _, l in ipairs(lines) do
    if l:match("%S") then
      out[#out + 1] = l
    end
  end
  return out
end

M._markup = markup
M._expansion_lines = expansion_lines

function M.expand()
  local st = view.current()
  if not st then
    return notify("open a reading view first (:InlineExplorerOpen)", vim.log.levels.INFO)
  end
  if #vim.lsp.get_clients({ name = "clangd" }) == 0 then
    return notify("macro expansion needs a live clangd")
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1] - 1, cur[2]
  local name = vim.fn.expand("<cword>")
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
    vim.schedule(function()
      if not md or md == "" then
        return notify("no expansion available at the cursor")
      end
      local lines = expansion_lines(md)
      if not lines or #lines == 0 then
        return notify("could not extract a macro expansion")
      end
      expander._insert(st, bufnr, row, name, lines, "macro")
    end)
  end)
end

return M
