-- Expander: resolve the symbol under the cursor and splice its definition into
-- the reading view as a foldable, indented block below the call's statement.
local config = require("inline-explorer.config")
local profile = require("inline-explorer.profile")
local resolver = require("inline-explorer.resolver")
local view = require("inline-explorer.view")
local util = require("inline-explorer.util")

local M = {}

-- The names of the blocks that contain row `row` (0-based), as a set.
local function ancestor_names(st, bufnr, row)
  local names = {}
  for _, range in ipairs(view.block_ranges(st, bufnr)) do
    if row >= range.s and row <= range.e then
      names[range.name] = true
    end
  end
  return names
end

local function notify(msg, level)
  util.notify(msg, level or vim.log.levels.WARN)
end

-- Node types of a statement's body, such as the { ... } of an if or a struct.
local BODY_TYPES = {
  compound_statement = true, -- C
  block = true, -- Lua, Python, Rust, Go
  statement_block = true, -- JavaScript, TypeScript
  field_declaration_list = true, -- C struct/union bodies
}

local function is_statement(node_type)
  return node_type:match("statement$") ~= nil or node_type:match("declaration$") ~= nil
end

-- The innermost statement node around (row, col), or nil: without a parser,
-- when the walk up meets a body or the root first, or on a syntax error.
local function statement_at(bufnr, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end
  parser:parse()
  local node = parser:named_node_for_range({ row, col, row, col }, { ignore_injections = true })
  while node do
    local t = node:type()
    -- Bodies first: compound_statement is a body, though it ends in "statement".
    if BODY_TYPES[t] then
      return nil
    end
    if is_statement(t) then
      break
    end
    node = node:parent()
  end
  if node and node:has_error() then
    return nil
  end
  return node
end

-- The last row of statement `node`, but never above `row` (the call's row).
-- A body (a block, or the lone statement of a braceless if/for) that comes
-- after the call ends the statement early, at the last row of what precedes
-- the body: in `if (f(x)) {`, that is the condition's row.
local function statement_end(node, row)
  local _, _, last, last_col = node:range()
  if last_col == 0 and last > row then
    last = last - 1 -- the end is exclusive: column 0 means the row before
  end
  for _, child in ipairs(node:named_children()) do
    local t = child:type()
    if BODY_TYPES[t] or t:match("statement$") then
      local cap
      local prev = child:prev_sibling()
      if prev then
        local _, _, prev_end_row = prev:range()
        cap = prev_end_row
      else
        local child_start_row = child:start()
        cap = child_start_row
      end
      -- cap < row means that the body comes before the call, as in
      -- `do { ... } while (f(x));`. Such a body does not end the statement.
      if cap >= row then
        last = math.min(last, cap)
      end
    end
  end
  return math.max(last, row)
end

-- Where to put the expansion of the call at (row, col), as 0-based rows.
-- Without a statement around the call (see statement_at), both are `row`.
---@return integer at insert below this row: where the statement ends, so it is not split (see statement_end)
---@return integer indent_row copy this row's indentation: the statement's first row, not a continuation
local function splice_row(bufnr, row, col)
  local node = statement_at(bufnr, row, col)
  if not node then
    return row, row
  end
  local stmt_start_row = node:start()
  return statement_end(node, row), math.min(stmt_start_row, row)
end

-- Splice `body` below row `at` as a block, indented one level past `indent_row`.
local function insert(st, bufnr, at, indent_row, name, body, label)
  local opts = config.options
  local indent_line = vim.api.nvim_buf_get_lines(bufnr, indent_row, indent_row + 1, false)[1] or ""
  local pad = (indent_line:match("^%s*") or "") .. opts.indent

  local out = {}
  if opts.header then
    out[#out + 1] = pad .. "/* v " .. name .. " (" .. label .. ") */"
  end
  for _, line in ipairs(body) do
    if line == "" then
      out[#out + 1] = "" -- no trailing whitespace on blank lines
    else
      out[#out + 1] = pad .. line
    end
  end
  if opts.header then
    out[#out + 1] = pad .. "/* ^ " .. name .. " */"
  end

  view.change(st, bufnr, function()
    view.set_lines(bufnr, at + 1, at + 1, out)
    view.add_block(st, bufnr, name, at + 1, at + #out)
  end)
end

-- `prefetched` ({ name, body, label }) is a definition that inliner.lua has
-- already fetched: it is inserted without a lookup. A user command passes its
-- opts table here instead, so a table without a non-empty `body` is ignored.
function M.expand(prefetched)
  local st = view.current()
  if not st then
    return notify("open a reading view first (:InlineExplorerOpen)", vim.log.levels.INFO)
  end

  if not (type(prefetched) == "table" and prefetched.body and #prefetched.body > 0) then
    prefetched = nil
  end
  local name
  if prefetched and prefetched.name then
    name = prefetched.name
  else
    name = vim.fn.expand("<cword>")
  end
  if not name or name == "" then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]

  if ancestor_names(st, bufnr, row)[name] then
    return notify("'" .. name .. "' is already expanded above (recursion guard)", vim.log.levels.INFO)
  end
  local at, indent_row = splice_row(bufnr, row, col)

  if prefetched then
    -- No profile.begin_action(): this is the block fallback of an inline
    -- (inliner.lua), whose action this span belongs to.
    local stop_timer = profile.start()
    insert(st, bufnr, at, indent_row, name, prefetched.body, prefetched.label)
    -- Every expansion ends with a `total:` span: tests/lib/bench.lua waits for it.
    stop_timer("total:expand", name)
    return
  end

  if not view.begin_fetch(st) then
    return notify("a lookup is already in flight", vim.log.levels.INFO)
  end

  profile.begin_action()
  local stop_timer = profile.start()
  resolver.fetch(name, st.source_bufnr, function(body, label, err)
    vim.schedule(function()
      view.end_fetch(st)
      if not body or #body == 0 then
        stop_timer("total:expand-failed", name)
        return notify(err or ("could not extract a body for '" .. name .. "'"))
      end
      insert(st, bufnr, at, indent_row, name, body, label)
      stop_timer("total:expand", ("%s (%dL, %s)"):format(name, #body, tostring(label)))
    end)
  end)
end

return M
