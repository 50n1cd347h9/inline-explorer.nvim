-- Callers of a function, from the language server's call hierarchy when it
-- offers one, else from a grep of the source tree confirmed with tree-sitter.
--
-- Every result is tagged with where it came from, "lsp" or "grep", and
-- pick.lua shows the tag: an indexing server can return incomplete results
-- silently, and "0 callers" must not read as "nobody calls this". LSP knows
-- which function each call targets, but only sees what it has indexed; grep
-- sees every textual call (even through macros), but cannot tell two
-- same-named static functions apart.
--
-- An item is one call site:
--   { name = calling function ("?" if unknown), uri = file of the call,
--     range = LSP range of the call, text = the call's line, trimmed,
--     encoding = offset encoding of `range` (LSP items only; grep ranges
--     count bytes) }
local csrc = require("inline-explorer.csrc")
local resolver = require("inline-explorer.resolver")

local M = {}

-- How long the language server has to answer before grep takes over.
M._timeout_ms = 4000
-- The most grep hits that are checked; the result is marked as truncated
-- when there are more.
M._grep_max = 200

-- Sort items by file, then by line, in place, and return them.
local function sort_items(items)
  table.sort(items, function(a, b)
    if a.uri ~= b.uri then
      return a.uri < b.uri
    end
    return a.range.start.line < b.range.start.line
  end)
  return items
end

-- The trimmed text of 0-based line `lnum0` of `path`: from its buffer if it
-- is loaded, else from disk. Only LSP results need this; the grep path takes
-- the line from the file text it has already read.
local function trimmed_line(path, lnum0)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    local text = vim.api.nvim_buf_get_lines(buf, lnum0, lnum0 + 1, false)[1]
    return text and vim.trim(text) or ""
  end
  local lnum1 = lnum0 + 1 -- readfile() counts lines from 1
  local text = vim.fn.readfile(path, "", lnum1)[lnum1]
  return text and vim.trim(text) or ""
end

-- Parse rg or grep output into hits grouped by file:
-- { [path] = { { lnum = 0-based line, col = 0-based byte column }, ... } }.
-- Keeps the first M._grep_max hits; the second value is true when the output
-- had more.
local function parse_grep_output(stdout, name)
  local hits_by_file, count, truncated = {}, 0, false
  for line in stdout:gmatch("[^\n]+") do
    -- rg --vimgrep prints file:line:col:text; grep -rnw prints file:line:text.
    local file, lnum, col = line:match("^(.-):(%d+):(%d+):")
    if not file then
      local text
      file, lnum, text = line:match("^(.-):(%d+):(.*)$")
      -- grep prints no column. Tree-sitter confirmation needs the identifier's
      -- own column (column 1 of an indented line is whitespace, outside the
      -- call), so find the identifier in the line, matching whole words only.
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

-- Append to `items` the hits in `file` that tree-sitter confirms as calls of
-- `name`: the innermost call_expression at the hit must call that identifier.
-- A file that cannot be read or parsed adds nothing.
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

-- The grep fallback: search `root_dir` for `name` with rg (or grep), keep the
-- hits that tree-sitter confirms as calls, and call cb(items, "grep", note).
-- `note` is nil unless the hits were truncated.
local function grep_callers(name, root_dir, cb)
  local search = "grep -rnw"
  if vim.fn.executable("rg") == 1 then
    -- --max-count 50 keeps at most 50 matching lines per file.
    search = "rg --vimgrep --word-regexp --max-count 50"
  end
  -- Cap the output with head rather than in Lua: head closes the pipe and rg
  -- stops early on SIGPIPE, which matters on huge trees. Asking for one line
  -- more than M._grep_max lets parse_grep_output tell that the output was cut.
  local shellcmd = ("%s %s %s | head -n %d"):format(
    search,
    vim.fn.shellescape(name),
    vim.fn.shellescape(root_dir),
    M._grep_max + 1
  )
  vim.system({ "sh", "-c", shellcmd }, { text = true }, function(out)
    local hits_by_file, truncated = parse_grep_output(out.stdout or "", name)
    -- vim.fn.readfile cannot run in vim.system's callback, so the files are
    -- read and checked on the main loop.
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

-- The directory grep searches: the root_dir of the first language server on
-- `bufnr` that has one, else the directory of the buffer's file, else the
-- current directory.
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

-- The items for an incomingCalls answer: one per call site (fromRanges),
-- named after the calling function. `encoding` is the server's offset
-- encoding, the units of the ranges.
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

-- Ask `client` for the calls of the symbol at `params` (prepareCallHierarchy,
-- then callHierarchy/incomingCalls, both about `target_bufnr`) and call
-- cb(items, "lsp", nil). On an error, an empty answer, or no answer within
-- M._timeout_ms, grep_callers answers instead. cb fires only once.
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
    resolver.client_request(client, "callHierarchy/incomingCalls", request, on_incoming_calls, target_bufnr)
  end
  resolver.client_request(client, "textDocument/prepareCallHierarchy", params, on_prepared, target_bufnr)
end

-- Find the calls of function `name`, asking the language servers attached to
-- `bufnr`. Async: calls cb(items, provider, note) once, where
--   items     is the list of call sites (items, as described at the top of
--             this file), sorted by file and then line;
--   provider  says where the items came from: "lsp" or "grep";
--   note      is nil, or a message to show with the items, such as
--             "truncated at 200 matches".
-- Falls back to grep when no server offers call hierarchy, or when the
-- lookup fails, errors, times out or finds nothing.
function M.get(name, bufnr, cb)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/prepareCallHierarchy" })
  local root_dir = grep_root(bufnr)
  if #clients == 0 then
    grep_callers(name, root_dir, cb)
    return
  end
  -- Send the request to the symbol's own location, resolved by name, not to
  -- the cursor: the cursor may be in a reading view, a scratch buffer that no
  -- language server has open. resolver.locate is enough here; unlike
  -- locate_definition, it neither extracts the body nor chases a declaration
  -- to its definition.
  resolver.locate(name, bufnr, function(loc)
    if not loc then
      grep_callers(name, root_dir, cb)
      return
    end
    -- A buffer of loc's file with bufnr's language servers attached (a server
    -- answers only about documents it has open); nil if bufnr has none.
    local target_bufnr = resolver.ensure_attached(loc.uri, bufnr)
    if not target_bufnr then
      grep_callers(name, root_dir, cb)
      return
    end
    local client = clients[1]
    local params = {
      textDocument = { uri = loc.uri },
      position = resolver.name_position(target_bufnr, loc, client.offset_encoding),
    }
    call_hierarchy(client, target_bufnr, params, name, root_dir, cb)
  end)
end

return M
