-- Callers of a function: LSP callHierarchy when the server offers it, a
-- grep + tree-sitter fallback when it does not or returns nothing. The
-- source is always reported to the caller of this module and always shown
-- to the user -- an indexing server returns INCOMPLETE results silently,
-- and "0 callers" must never be allowed to read as "nobody calls this".
--
-- The two sources have different contracts, both honest: LSP resolves
-- identity (which target_fn) but sees only what its index has; grep sees
-- every textual call, including through macros the AST cannot follow, but
-- cannot tell two same-named statics apart. The label is what tells the
-- user which contract they are looking at.
local C = require("inline-explorer.csrc")

local M = {}

M._timeout_ms = 4000
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

-- The hit line for an LSP item: through the loaded buffer when one
-- exists, from disk otherwise. The grep path does not come here at all --
-- it slices lines out of the file text it already read for tree-sitter
-- confirmation (measured before that change: 170-190 redundant prefix
-- reads per invocation, 150k-200k lines re-read, 25-33ms, for content
-- already sitting in memory).
local function line_text(path, lnum0)
  local b = vim.fn.bufnr(path)
  if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
    local l = vim.api.nvim_buf_get_lines(b, lnum0, lnum0 + 1, false)[1]
    return l and vim.trim(l) or ""
  end
  local lines = vim.fn.readfile(path, "", lnum0 + 2)
  local l = lines[lnum0 + 1]
  return l and vim.trim(l) or ""
end

-- grep fallback: rg (or grep -rn) for the identifier, then tree-sitter
-- confirms each hit is the callee of a call_expression and names the
-- enclosing function. Parsed per FILE, not per hit.
local function grep_callers(name, root, cb)
  -- The cap is enforced at the PRODUCER. Consuming only the first
  -- _grep_max lines of a completed run still paid for the whole run:
  -- measured for kfree over a kernel tree, rg buffered 6.3MB / 40,324
  -- hits in ~200ms where a head-stopped pipe finishes in single-digit
  -- ms -- and which 200 survived varied run to run, so the item set was
  -- nondeterministic on top of slow. head closes the pipe at the cap and
  -- rg dies on the SIGPIPE; the +1 line is how the consumer detects
  -- truncation without a second source of truth.
  local shellcmd
  if vim.fn.executable("rg") == 1 then
    shellcmd = ("rg --vimgrep --word-regexp --max-count 50 %s %s | head -n %d"):format(
      vim.fn.shellescape(name),
      vim.fn.shellescape(root),
      M._grep_max + 1
    )
  else
    shellcmd = ("grep -rnw %s %s | head -n %d"):format(
      vim.fn.shellescape(name),
      vim.fn.shellescape(root),
      M._grep_max + 1
    )
  end
  vim.system({ "sh", "-c", shellcmd }, { text = true }, function(out)
    local hits_by_file, n, truncated = {}, 0, false
    for line in (out.stdout or ""):gmatch("[^\n]+") do
      -- rg --vimgrep: file:line:col:text   grep -rnw: file:line:text
      local file, lnum, col = line:match("^(.-):(%d+):(%d+):")
      if not file then
        local text
        file, lnum, text = line:match("^(.-):(%d+):(.*)$")
        -- grep gives no column, and assuming column 1 is not a harmless
        -- default: tree-sitter's confirmation resolves the node AT the
        -- column, and column 1 of an indented call line is whitespace whose
        -- ancestors never include the call_expression -- every hit then
        -- fails confirmation and the fallback reports zero callers. CI
        -- caught this (no rg on the runner); rg's --vimgrep column had
        -- hidden it everywhere rg exists. Find the identifier in the line,
        -- word-bounded, instead of guessing.
        if file and text then
          local s0 = text:find("%f[%w_]" .. vim.pesc(name) .. "%f[^%w_]")
          col = tostring(s0 or 1)
        end
      end
      if file then
        n = n + 1
        if n > M._grep_max then
          truncated = true
          break
        end
        hits_by_file[file] = hits_by_file[file] or {}
        table.insert(hits_by_file[file], { lnum = tonumber(lnum) - 1, col = tonumber(col) - 1 })
      end
    end
    vim.schedule(function()
      local items = {}
      for file, hits in pairs(hits_by_file) do
        local ok, flines = pcall(vim.fn.readfile, file)
        if ok then
          local src = table.concat(flines, "\n")
          local pok, root_node = pcall(C.parse, src)
          if pok then
            for _, h in ipairs(hits) do
              -- the innermost call_expression must be calling this identifier
              local call = C.ancestor_at(root_node, h.lnum, h.col, "call_expression")
              local fn = call and call:field("function")[1]
              if fn and C.text(fn, src) == name then
                -- enclosing function name, "?" when there is none
                local fdef = C.ancestor_at(root_node, h.lnum, h.col, "function_definition")
                local encl = fdef and C.function_name(fdef, src) or "?"
                items[#items + 1] = {
                  name = encl,
                  uri = vim.uri_from_fname(file),
                  range = {
                    start = { line = h.lnum, character = h.col },
                    ["end"] = { line = h.lnum, character = h.col + #name },
                  },
                  text = vim.trim(flines[h.lnum + 1] or ""), -- sliced from the read we already did
                }
              end
            end
          end
        end
      end
      cb(sort_items(items), "grep", truncated and ("truncated at " .. M._grep_max .. " matches") or nil)
    end)
  end)
end

local function grep_root(bufnr)
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if c.config and c.config.root_dir then
      return c.config.root_dir
    end
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fn.fnamemodify(name, ":h") or vim.fn.getcwd()
end

-- Async: cb(items, source, err). Falls back to grep when the server lacks
-- callHierarchy, errors, times out, or answers with nothing.
function M.get(name, bufnr, cb)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/prepareCallHierarchy" })
  local root = grep_root(bufnr)
  if #clients == 0 then
    return grep_callers(name, root, cb)
  end

  -- Resolve the symbol to a REAL location first, and aim there. The old
  -- code built position params from window 0 -- and the plugin's own
  -- callers keymap lives inside the reading view, a detached nofile copy
  -- no server has open, so every in-view keypress sent an
  -- inline-explorer:// URI, got an error, and paid the full-tree grep
  -- fallback: measured 558ms against 6.5ms on the kernel for the same
  -- symbol.
  local resolver = require("inline-explorer.resolver")
  resolver.locate(name, bufnr, function(loc)
    if not loc then
      return grep_callers(name, root, cb)
    end
    local target = resolver.ensure_attached(loc.uri, bufnr)
    if not target then
      return grep_callers(name, root, cb)
    end
    local params = {
      textDocument = { uri = loc.uri },
      position = resolver.name_position(target, loc),
    }
    M._hierarchy(clients[1], target, params, name, root, cb)
  end)
end

-- The two callHierarchy round trips, separated so locate's async resolution
-- above stays readable. Falls back to grep on refusal, error, emptiness or
-- timeout, exactly as before.
function M._hierarchy(client, target, params, name, root, cb)
  local resolver = require("inline-explorer.resolver")
  local answered = false
  local function finish(items, source, err)
    if answered then
      return
    end
    answered = true
    cb(items, source, err)
  end
  vim.defer_fn(function()
    if not answered then
      grep_callers(name, root, finish)
    end
  end, M._timeout_ms)
  resolver.client_request(client, "textDocument/prepareCallHierarchy", params, function(err, result)
    if err or not result or #result == 0 then
      return grep_callers(name, root, finish)
    end
    local item = result[1]
    resolver.client_request(client, "callHierarchy/incomingCalls", { item = item }, function(ierr, calls)
      if ierr or not calls or #calls == 0 then
        return grep_callers(name, root, finish)
      end
      local items = {}
      for _, call in ipairs(calls) do
        local from = call.from
        local path = vim.uri_to_fname(from.uri)
        for _, r in ipairs(call.fromRanges or {}) do
          items[#items + 1] = {
            name = from.name or "?",
            uri = from.uri,
            range = r,
            text = line_text(path, r.start.line),
          }
        end
      end
      finish(sort_items(items), "lsp", nil)
    end, target)
  end, target)
end

return M
