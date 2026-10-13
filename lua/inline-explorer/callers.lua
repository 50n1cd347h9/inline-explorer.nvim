-- Callers of a function: the language server's call hierarchy, else a grep of
-- the source tree confirmed with tree-sitter. Each answer names its provider,
-- because the two fail differently: the server sees only what it has indexed,
-- while grep sees calls written anywhere, in #if 0 blocks and macro arguments
-- too (but not in #define bodies), and cannot tell same-named static functions
-- apart.
local async = require("inline-explorer.async")
local csrc = require("inline-explorer.csrc")
local resolver = require("inline-explorer.resolver")

local M = {}

-- One call site.
---@class inline_explorer.CallerItem
---@field name string the calling function, "?" if unknown
---@field uri string the file of the call
---@field range lsp.Range the call, in `encoding` units
---@field text string the call's line, trimmed
---@field encoding? string the server's offset encoding; nil (grep) means bytes

-- How long the call hierarchy requests may take, together, before grep
-- answers instead.
M._timeout_ms = 4000
-- The most grep hits checked; with more, the answer is marked as truncated.
M._grep_max = 200

local function sort_items(items)
  table.sort(items, function(a, b)
    if a.uri ~= b.uri then
      return a.uri < b.uri
    end
    if a.range.start.line ~= b.range.start.line then
      return a.range.start.line < b.range.start.line
    end
    return a.range.start.character < b.range.start.character
  end)
  return items
end

local function trimmed_line(path, lnum0)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    local text = vim.api.nvim_buf_get_lines(buf, lnum0, lnum0 + 1, false)[1]
    return text and vim.trim(text) or ""
  end
  local lnum1 = lnum0 + 1
  local text = vim.fn.readfile(path, "", lnum1)[lnum1]
  return text and vim.trim(text) or ""
end

-- The 1-based columns of the hits on one line of grep output: rg --vimgrep
-- prints file:line:col:text, one line per match; grep -rnw prints
-- file:line:text, one line per matching line, so every match in the text
-- is a hit.
local function grep_line(line, name)
  local file, lnum, col = line:match("^(.-):(%d+):(%d+):")
  if file then
    return file, lnum, { tonumber(col) }
  end
  local text
  file, lnum, text = line:match("^(.-):(%d+):(.*)$")
  if not file then
    return nil, nil, {}
  end
  local cols = {}
  for start in text:gmatch("()%f[%w_]" .. vim.pesc(name) .. "%f[^%w_]") do
    cols[#cols + 1] = start
  end
  return file, lnum, cols
end

-- The hits by path, with 0-based lines and byte columns. Keeps the first
-- M._grep_max hits; `truncated` says whether there were more.
local function parse_grep_output(stdout, name)
  local hits_by_file, count = {}, 0
  for line in stdout:gmatch("[^\n]+") do
    local file, lnum, cols = grep_line(line, name)
    if file then
      for _, col in ipairs(cols) do
        count = count + 1
        if count > M._grep_max then
          return hits_by_file, true
        end
        hits_by_file[file] = hits_by_file[file] or {}
        table.insert(hits_by_file[file], { lnum = tonumber(lnum) - 1, col = col - 1 })
      end
    end
  end
  return hits_by_file, false
end

-- Adds to `items` the hits that are the callee of a call of `name`. A hit
-- elsewhere in a call (in an argument, a comment or a string) is not one.
local function add_confirmed_calls(items, file, hits, name)
  local read_ok, file_lines = pcall(vim.fn.readfile, file)
  if not read_ok then
    return
  end
  local src = table.concat(file_lines, "\n")
  local parsed, tree_root = pcall(csrc.parse, src)
  if not parsed then
    return
  end
  local callee_at = {}
  for _, call in ipairs(csrc.find_calls(tree_root, src, name)) do
    local row, col = call:field("function")[1]:start()
    callee_at[row .. ":" .. col] = true
  end
  for _, hit in ipairs(hits) do
    if callee_at[hit.lnum .. ":" .. hit.col] then
      local caller_def = csrc.ancestor_at(tree_root, hit.lnum, hit.col, "function_definition")
      items[#items + 1] = {
        name = caller_def and csrc.function_name(caller_def, src) or "?",
        uri = vim.uri_from_fname(file),
        range = {
          start = { line = hit.lnum, character = hit.col },
          ["end"] = { line = hit.lnum, character = hit.col + #name },
        },
        text = vim.trim(file_lines[hit.lnum + 1] or ""),
      }
    end
  end
end

-- The grep fallback over `root_dir`. Calls cb as M.get does.
local function grep_callers(name, root_dir, cb)
  local search = "grep -rnw"
  if vim.fn.executable("rg") == 1 then
    -- --max-count 50: at most 50 hits per file, dropped without the truncated note.
    search = "rg --vimgrep --word-regexp --max-count 50"
  end
  -- Cap the output with head, not in Lua, so that rg stops early on SIGPIPE
  -- (huge trees). One line past M._grep_max tells parse_grep_output it was cut.
  local shellcmd = ("%s %s %s | head -n %d"):format(
    search,
    vim.fn.shellescape(name),
    vim.fn.shellescape(root_dir),
    M._grep_max + 1
  )
  vim.system({ "sh", "-c", shellcmd }, { text = true }, function(out)
    local hits_by_file, truncated = parse_grep_output(out.stdout or "", name)
    -- vim.fn.readfile cannot run in vim.system's callback (a fast event).
    vim.schedule(function()
      local items = {}
      for file, hits in pairs(hits_by_file) do
        add_confirmed_calls(items, file, hits, name)
      end
      local note
      if truncated then
        note = "truncated at " .. M._grep_max .. " matches"
      end
      cb(sort_items(items), "grep", note)
    end)
  end)
end

local function grep_root(bufnr)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if client.config and client.config.root_dir then
      return client.config.root_dir
    end
  end
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname ~= "" then
    return vim.fn.fnamemodify(bufname, ":h")
  end
  return vim.fn.getcwd()
end

local function items_from_calls(calls, encoding)
  local items = {}
  for _, call in ipairs(calls) do
    local from = call.from
    local path = vim.uri_to_fname(from.uri)
    for _, range in ipairs(call.fromRanges or {}) do
      items[#items + 1] = {
        name = from.name or "?",
        uri = from.uri,
        range = range,
        encoding = encoding,
        text = trimmed_line(path, range.start.line),
      }
    end
  end
  return items
end

-- prepareCallHierarchy, then incomingCalls. Grep answers instead on an error,
-- an empty answer or a timeout, which also cancels the request. Calls cb once.
local function call_hierarchy(client, target_bufnr, params, name, root_dir, cb)
  local deadline = vim.uv.now() + M._timeout_ms
  local function fall_back_to_grep()
    grep_callers(name, root_dir, cb)
  end
  local function on_incoming_calls(err, calls)
    if err or type(calls) ~= "table" or #calls == 0 then
      return fall_back_to_grep()
    end
    cb(sort_items(items_from_calls(calls, client.offset_encoding)), "lsp", nil)
  end
  local function on_prepared(err, items)
    if err or type(items) ~= "table" or #items == 0 then
      return fall_back_to_grep()
    end
    local request = { item = items[1] }
    local remaining = math.max(deadline - vim.uv.now(), 0)
    async.request(client, "callHierarchy/incomingCalls", request, target_bufnr, remaining, on_incoming_calls)
  end
  async.request(client, "textDocument/prepareCallHierarchy", params, target_bufnr, M._timeout_ms, on_prepared)
end

-- Find the call sites of function `name` with the language server that
-- finds it from `bufnr`, or with grep when no server offers call hierarchy or
-- the lookup fails (see call_hierarchy). Calls `cb` once, with the items
-- sorted by file, line and column, and `note` a message to show with them,
-- or nil.
---@param name string
---@param bufnr integer
---@param cb fun(items: inline_explorer.CallerItem[], provider: "lsp"|"grep", note: string?)
function M.get(name, bufnr, cb)
  local method = "textDocument/prepareCallHierarchy"
  local root_dir = grep_root(bufnr)
  if #vim.lsp.get_clients({ bufnr = bufnr, method = method }) == 0 then
    grep_callers(name, root_dir, cb)
    return
  end
  -- Ask about the symbol's own location, found by name, not the cursor's: the
  -- cursor may be in a reading view, which no server has open.
  -- locate, not locate_definition: call hierarchy accepts a declaration, so no
  -- extract or chase is needed.
  resolver.locate(name, bufnr, function(loc)
    local client = loc and resolver.client_for(loc, bufnr, method)
    if not (loc and client) then
      grep_callers(name, root_dir, cb)
      return
    end
    local target_bufnr = resolver.ensure_attached(loc.uri, client)
    local params = {
      textDocument = { uri = loc.uri },
      position = resolver.name_position(target_bufnr, loc, client.offset_encoding),
    }
    call_hierarchy(client, target_bufnr, params, name, root_dir, cb)
  end)
end

return M
