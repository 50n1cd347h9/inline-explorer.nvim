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

local function line_text(path, lnum0)
  local lines = vim.fn.readfile(path, "", lnum0 + 2)
  local l = lines[lnum0 + 1]
  return l and vim.trim(l) or ""
end

-- grep fallback: rg (or grep -rn) for the identifier, then tree-sitter
-- confirms each hit is the callee of a call_expression and names the
-- enclosing function. Parsed per FILE, not per hit.
local function grep_callers(name, root, cb)
  local cmd
  if vim.fn.executable("rg") == 1 then
    cmd = { "rg", "--vimgrep", "--word-regexp", "--max-count", "50", name, root }
  else
    cmd = { "grep", "-rnw", name, root }
  end
  vim.system(cmd, { text = true }, function(out)
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
          local s0 = text:find("%f[%w_]" .. name .. "%f[^%w_]")
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
        local ok, src = pcall(function()
          return table.concat(vim.fn.readfile(file), "\n")
        end)
        if ok then
          local pok, root_node = pcall(function()
            return vim.treesitter.get_string_parser(src, "c"):parse()[1]:root()
          end)
          if pok then
            for _, h in ipairs(hits) do
              local node = root_node:named_descendant_for_range(h.lnum, h.col, h.lnum, h.col)
              -- climb to the call_expression whose callee is this identifier
              local is_call = false
              local nd = node
              while nd do
                if nd:type() == "call_expression" then
                  local fn = nd:field("function")[1]
                  if fn then
                    local _, _, a, _, _, b = fn:range(true)
                    if src:sub(a + 1, b) == name then
                      is_call = true
                    end
                  end
                  break
                end
                nd = nd:parent()
              end
              if is_call then
                -- enclosing function name, "?" when there is none
                local encl = "?"
                local up = node
                while up do
                  if up:type() == "function_definition" then
                    local C = require("inline-explorer.csrc")
                    local fd = C.func_declarator(up:field("declarator")[1])
                    encl = (fd and C.decl_name(fd:field("declarator")[1], src)) or "?"
                    break
                  end
                  up = up:parent()
                end
                items[#items + 1] = {
                  name = encl,
                  uri = vim.uri_from_fname(file),
                  range = { start = { line = h.lnum, character = h.col },
                    ["end"] = { line = h.lnum, character = h.col + #name } },
                  text = line_text(file, h.lnum),
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

  -- Exactly one cb, grep on timeout. A plain guard, deliberately not
  -- once_with_timeout: that helper routes its timeout value through the
  -- same callback as a real answer, which is one indirection too many here
  -- -- the timeout does not HAVE a value, it starts the grep fallback,
  -- whose own answer arrives through this same guard.
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

  local params = vim.lsp.util.make_position_params(0, clients[1].offset_encoding)
  -- The cursor may not be on the symbol (picker can be invoked anywhere), so
  -- position params are only a hint; prepareCallHierarchy is driven off the
  -- definition when the resolver knows it. Task 3 passes a position; here
  -- the buffer's cursor is used as-is.
  clients[1]:request("textDocument/prepareCallHierarchy", params, function(err, result)
    if err or not result or #result == 0 then
      return grep_callers(name, root, finish)
    end
    local item = result[1]
    clients[1]:request("callHierarchy/incomingCalls", { item = item }, function(ierr, calls)
      if ierr or not calls or #calls == 0 then
        return grep_callers(name, root, function(items, source, gerr)
          finish(items, source, gerr)
        end)
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
    end, bufnr)
  end, bufnr)
end

return M
