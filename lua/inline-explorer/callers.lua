-- Callers of a function: the language server's call hierarchy, else a grep of
-- the source tree confirmed with tree-sitter. Each answer names its provider,
-- because the two fail differently: the server sees only what it has indexed,
-- while grep sees calls written anywhere, in #if 0 blocks and macro arguments
-- too (but not in #define bodies), and cannot tell same-named static functions
-- apart.
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

-- How long the call hierarchy requests may take before grep starts as well.
M._timeout_ms = 4000
-- The most grep hits checked; with more, the answer is marked as truncated.
M._grep_max = 200

local function sort_items(items)
  table.sort(items, function(a, b)
    if a.uri ~= b.uri then
      return a.uri < b.uri
    end
    return a.range.start.line < b.range.start.line
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

-- The hits by path, with 0-based lines and byte columns. Keeps the first
-- M._grep_max hits; `truncated` says whether there were more.
local function parse_grep_output(stdout, name)
  local hits_by_file, count, truncated = {}, 0, false
  for line in stdout:gmatch("[^\n]+") do
    -- rg --vimgrep prints file:line:col:text; grep -rnw prints file:line:text.
    local file, lnum, col = line:match("^(.-):(%d+):(%d+):")
    if not file then
      local text
      file, lnum, text = line:match("^(.-):(%d+):(.*)$")
      -- grep prints no column, and tree-sitter confirmation needs one inside the
      -- call (column 1 of an indented line is whitespace), so find the name.
      if file and text then
        local start = text:find("%f[%w_]" .. vim.pesc(name) .. "%f[^%w_]")
        col = start or 1 -- 1-based, like rg's column
      end
    end
    if file then
      count = count + 1
      if count > M._grep_max then
        truncated = true
        break
      end
      hits_by_file[file] = hits_by_file[file] or {}
      table.insert(hits_by_file[file], { lnum = tonumber(lnum) - 1, col = tonumber(col) - 1 })
    end
  end
  return hits_by_file, truncated
end

-- Adds to `items` the hits whose innermost call_expression calls `name`.
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
  for _, hit in ipairs(hits) do
    local call = csrc.ancestor_at(tree_root, hit.lnum, hit.col, "call_expression")
    local callee = call and call:field("function")[1]
    if callee and csrc.text(callee, src) == name then
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

-- prepareCallHierarchy, then incomingCalls. Grep answers instead on an error or
-- an empty answer. After M._timeout_ms grep starts as well, and the first answer
-- wins. Calls cb once.
local function call_hierarchy(client, target_bufnr, params, name, root_dir, cb)
  -- Not async.once_with_timeout: that needs the timeout's result at once, but
  -- the grep started on a timeout answers later.
  local answered = false
  local function finish(items, provider, note)
    if answered then
      return
    end
    answered = true
    cb(items, provider, note)
  end
  local function fall_back_to_grep()
    grep_callers(name, root_dir, finish)
  end
  vim.defer_fn(function()
    if not answered then
      fall_back_to_grep()
    end
  end, M._timeout_ms)

  local function on_incoming_calls(err, calls)
    if err or not calls or #calls == 0 then
      fall_back_to_grep()
      return
    end
    finish(sort_items(items_from_calls(calls, client.offset_encoding)), "lsp", nil)
  end
  local function on_prepared(err, result)
    if err or not result or #result == 0 then
      fall_back_to_grep()
      return
    end
    local request = { item = result[1] }
    client:request("callHierarchy/incomingCalls", request, on_incoming_calls, target_bufnr)
  end
  client:request("textDocument/prepareCallHierarchy", params, on_prepared, target_bufnr)
end

-- Find the call sites of function `name` with the language server that
-- finds it from `bufnr`, or with grep when no server offers call hierarchy or
-- the lookup fails (see call_hierarchy). Calls `cb` once, with the items
-- sorted by file, then line, and `note` a message to show with them, or nil.
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
