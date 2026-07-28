-- Inliner action: C-only "true inline substitution" of the call under the
-- cursor, inside the reading view. Resolves the callee with the LSP, extracts
-- its definition, and rewrites the view buffer via the substitute engine.
local resolver = require("inline-explorer.resolver")
local substitute = require("inline-explorer.substitute")
local view = require("inline-explorer.view")

local M = {}

local function notify(msg, level)
  vim.notify("[inline-explorer] " .. msg, level or vim.log.levels.WARN)
end

function M.substitute()
  local st = view.current()
  if not st then
    return notify("open a reading view first (:InlineExplorerOpen)", vim.log.levels.INFO)
  end
  if vim.bo.filetype ~= "c" then
    return notify("inline substitution is C-only")
  end
  if not pcall(vim.treesitter.get_string_parser, "int __ie;", "c") then
    return notify("inline substitution needs the C tree-sitter parser (:TSInstall c)")
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1] - 1, cur[2]
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

  local ok, fname = pcall(substitute.call_name_at, src, row, col)
  if not ok then
    return notify("failed to parse the buffer: " .. tostring(fname))
  end
  if not fname then
    return notify("no function call under the cursor")
  end

  resolver.locate(fname, st.source_bufnr, function(loc, err)
    if not loc then
      return vim.schedule(function()
        notify(err or "could not resolve '" .. fname .. "'")
      end)
    end
    local lines = resolver.extract(loc)
    local callee_src = table.concat(lines or {}, "\n")
    local N = (st.subst_n or 0) + 1
    local pok, new, e2 = pcall(substitute.inline_in_buffer, src, row, col, callee_src, N)
    if not pok then
      new, e2 = nil, tostring(new)
    end

    vim.schedule(function()
      if not new then
        return notify((e2 or ("could not inline '" .. fname .. "'")) .. " (macros/variadic are not supported)")
      end
      st.subst_n = N
      -- Whole-buffer rewrite: existing block-expansion extmarks no longer map.
      vim.api.nvim_buf_clear_namespace(bufnr, view.ns, 0, -1)
      st.nodes = {}
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(new, "\n", { plain = true }))
      vim.bo[bufnr].modifiable = false
      pcall(vim.api.nvim_win_set_cursor, 0, { math.min(row + 1, vim.api.nvim_buf_line_count(bufnr)), 0 })
    end)
  end)
end

return M
