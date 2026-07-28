-- Smart inline: the primary expansion action. In a C buffer it prefers
-- in-place substitution (functions -> compiler-style inline, macros -> clangd
-- expansion) and only falls back to block-paste (`expander.expand`) when
-- in-place is not possible. Non-C buffers always use block-paste.
local resolver = require("inline-explorer.resolver")
local substitute = require("inline-explorer.substitute")
local macro = require("inline-explorer.macro")
local expander = require("inline-explorer.expander")
local view = require("inline-explorer.view")
local config = require("inline-explorer.config")

local M = {}

local function has_c_parser()
  return pcall(vim.treesitter.get_string_parser, "int __ie;", "c")
end

-- Try in-place substitution first; fall back to block-paste.
function M.smart()
  local st = view.current()
  if not st then
    vim.notify("[inline-explorer] open a reading view first (:InlineExplorerOpen)", vim.log.levels.INFO)
    return
  end
  if vim.bo.filetype ~= "c" or not has_c_parser() then
    return expander.expand() -- non-C / no parser: block only
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1] - 1, cur[2]
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

  local fname = substitute.call_name_at(src, row, col) -- non-nil only on a call
  local ident = fname
  if not ident or ident == "" then
    ident = vim.fn.expand("<cword>")
  end
  if not ident or ident == "" then
    return vim.notify("[inline-explorer] nothing under the cursor", vim.log.levels.WARN)
  end

  local function block_fallback()
    vim.schedule(expander.expand)
  end

  resolver.locate(ident, st.source_bufnr, function(loc)
    if not loc then
      return block_fallback() -- expander.expand re-resolves and reports if unknown
    end
    resolver.extract(loc, st.source_bufnr, function(lines, label)
      if fname and label == "function_definition" then
        local N = (st.subst_n or 0) + 1
        local ok, new = pcall(substitute.inline_in_buffer, src, row, col, table.concat(lines or {}, "\n"), N, config.options.mode)
        if ok and new then
          return vim.schedule(function()
            st.subst_n = N
            view.rewrite(st, bufnr, new, row)
          end)
        end
        return block_fallback() -- e.g. variadic function
      end

      -- Not a confirmed function (macro, or heuristic-extracted from a header):
      -- try an in-place macro expansion via clangd hover; block-paste only if that
      -- yields nothing (so a plain function-signature hover never gets spliced).
      macro.fetch_expansion(st, row, col, function(exp)
        if not exp or #exp == 0 then
          return block_fallback()
        end
        vim.schedule(function()
          local ok, new = pcall(macro.replace_in_src, src, row, col, exp)
          if ok and new then
            view.rewrite(st, bufnr, new, row)
          else
            expander.expand()
          end
        end)
      end)
    end)
  end)
end

return M
