-- Macro expansion: a macro has no type or structured body to transform, so we
-- ask the live clangd for the expansion via `textDocument/hover` (read-only) and
-- splice it in place of the macro use. clangd runs the real preprocessor, so the
-- result respects include paths / #define / #ifdef.
local view = require("inline-explorer.view")

local M = {}

local function notify(msg, level)
  vim.notify("[inline-explorer] " .. msg, level or vim.log.levels.WARN)
end

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
    -- Indent continuation lines under the use's own line.
    local bol = sb(inv) - scol(inv)
    local indent = src:sub(bol + 1, sb(inv))
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

-- Fetch a macro's expansion from clangd hover at (row, col). cb(lines|nil).
function M.fetch_expansion(st, row, col, cb)
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

-- Explicit in-place macro expansion (command / keymap).
function M.expand()
  local st = view.current()
  if not st then
    return notify("open a reading view first (:InlineExplorerOpen)", vim.log.levels.INFO)
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1] - 1, cur[2]
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

  M.fetch_expansion(st, row, col, function(exp)
    vim.schedule(function()
      if not exp or #exp == 0 then
        return notify("no macro expansion available at the cursor")
      end
      local ok, new = pcall(M.replace_in_src, src, row, col, exp)
      if not ok or not new then
        return notify("could not place the expansion: " .. tostring(new))
      end
      view.rewrite(st, bufnr, new, row)
    end)
  end)
end

return M
