-- Expander: resolve the symbol under the cursor and splice its definition into
-- the reading view as a folded, indented block below the call's statement.
local config = require("inline-explorer.config")
local resolver = require("inline-explorer.resolver")
local view = require("inline-explorer.view")
local util = require("inline-explorer.util")

local M = {}

-- Names of expansions whose extmark range currently contains `lnum` (0-indexed).
-- Used to stop a symbol from being expanded inside its own body (recursion).
local function ancestor_names(st, bufnr, lnum)
  local names = {}
  for _, node in ipairs(view.live_nodes(st, bufnr)) do
    if lnum >= node.s and lnum <= node.e then
      names[node.name] = true
    end
  end
  return names
end

local function notify(msg, level)
  util.notify(msg, level or vim.log.levels.WARN)
end

-- Node types that own a body: a statement holding one ends with the body,
-- and the expansion belongs above it, not after its closing brace.
local BODY = {
  compound_statement = true, -- C
  block = true, -- Lua, Python, Rust, Go
  statement_block = true, -- JavaScript, TypeScript
  field_declaration_list = true, -- C struct/union bodies
}

local function is_statement(node_type)
  return node_type:match("statement$") ~= nil or node_type:match("declaration$") ~= nil
end

-- The innermost statement holding (row, col). nil when there is no
-- parser, when the walk up reaches a body before any statement, or when
-- the tree has errors there.
local function statement_at(bufnr, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end
  parser:parse() -- the view changes between expansions; never read a stale tree
  local node = parser:named_node_for_range({ row, col, row, col }, { ignore_injections = true })
  while node do
    local t = node:type()
    if BODY[t] then
      return nil -- checked first: compound_statement is a body, not a statement
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

-- The last row of statement `node`, but no earlier than `row`. A body --
-- a block, or the lone statement of a braceless if/for -- caps the
-- statement at the end of what precedes it: `if (f(x)) {` keeps the
-- expansion right below the condition.
local function statement_end(node, row)
  local _, _, last, last_col = node:range()
  if last_col == 0 and last > row then
    last = last - 1 -- end-exclusive at column 0 of the next row
  end
  for _, child in ipairs(node:named_children()) do
    local t = child:type()
    if BODY[t] or t:match("statement$") then
      local prev = child:prev_sibling()
      local cap = prev and select(3, prev:range()) or child:start()
      if cap >= row then
        last = math.min(last, cap)
      end
    end
  end
  return math.max(last, row)
end

-- The row to splice below for a call at (row, col): the last row of the
-- statement holding it. A call spread over several lines --
--   areq = af_alg_alloc_areq(sk, sizeof(...) +
--                            crypto_aead_reqsize(tfm));
-- -- put the expansion between its lines when it went below the cursor's
-- row. Without a statement, the cursor's row, as before. Second value:
-- the row whose indent the expansion follows -- the statement's first,
-- not a continuation line.
local function splice_row(bufnr, row, col)
  local node = statement_at(bufnr, row, col)
  if not node then
    return row, row
  end
  return statement_end(node, row), math.min(node:start(), row)
end

-- Splice `body` into `bufnr` just below row `at`, indented one level past
-- row `indent_row`, wrapped in a fold that starts open.
local function insert(st, bufnr, at, indent_row, name, body, label)
  local opts = config.options
  local call_line = vim.api.nvim_buf_get_lines(bufnr, indent_row, indent_row + 1, false)[1] or ""
  local pad = (call_line:match("^%s*") or "") .. opts.indent

  local out = {}
  if opts.header then
    out[#out + 1] = pad .. "/* v " .. name .. " (" .. label .. ") */"
  end
  for _, l in ipairs(body) do
    out[#out + 1] = (l == "") and "" or (pad .. l)
  end
  if opts.header then
    out[#out + 1] = pad .. "/* ^ " .. name .. " */"
  end

  view.change(st, bufnr, function()
    view.set_lines(bufnr, at + 1, at + 1, out)
    view.add_node(st, bufnr, name, at + 1, at + #out)
  end)
end

-- Block-expand the symbol under the cursor.
--
-- `prefetched` ({ name, body, label }) lets a caller that ALREADY resolved the
-- symbol hand the result over instead of making us repeat the round trip --
-- the inliner does this when it falls back to block-pasting. Anything without
-- a `body` is ignored, so the plain command/keymap callbacks (which are
-- invoked with their own argument tables) behave exactly as before. The
-- prefetched path is instrumented like the fetching one: it still records its
-- own `total:expand` span around the splice, so every completed expansion --
-- prefetched or not -- ends with a terminal `total:` span for the harness to
-- wait on.
function M.expand(prefetched)
  local st = view.current()
  if not st then
    return notify("open a reading view first (:InlineExplorerOpen)", vim.log.levels.INFO)
  end

  local pre = (type(prefetched) == "table" and prefetched.body and #prefetched.body > 0) and prefetched or nil
  local name = pre and pre.name or vim.fn.expand("<cword>")
  if not name or name == "" then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum = cursor[1] - 1

  if ancestor_names(st, bufnr, lnum)[name] then
    return notify("'" .. name .. "' is already expanded above (recursion guard)", vim.log.levels.INFO)
  end
  local at, indent_row = splice_row(bufnr, lnum, cursor[2])

  if pre then
    -- Deliberately does NOT number a new action. This branch is only ever
    -- reached as the continuation of an inline that fell back to block
    -- paste, so the work belongs to the action already in progress.
    -- Numbering here split one keypress across two ids in the log --
    -- `#7 total:block-fallback 133.0ms` followed by a stray
    -- `#8 total:expand 0.6ms` -- which is exactly the grouping the ids
    -- exist to make reliable.
    local pre_span = require("inline-explorer.profile").start()
    insert(st, bufnr, at, indent_row, name, pre.body, pre.label)
    pre_span("total:expand", name)
    return
  end

  if not view.begin_fetch(st) then
    return notify("a lookup is already in flight", vim.log.levels.INFO)
  end

  local pf2 = require("inline-explorer.profile")
  pf2.begin_action()
  local span = pf2.start()
  resolver.fetch(name, st.source_bufnr, function(body, label, err)
    vim.schedule(function()
      view.end_fetch(st)
      if not body or #body == 0 then
        span("total:expand-failed", name)
        return notify(err or ("could not extract a body for '" .. name .. "'"))
      end
      insert(st, bufnr, at, indent_row, name, body, label)
      span("total:expand", ("%s (%dL, %s)"):format(name, #body, tostring(label)))
    end)
  end)
end

return M
