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
local util = require("inline-explorer.util")

local M = {}

local function has_c_parser()
  return pcall(vim.treesitter.get_string_parser, "int __ie;", "c")
end

-- Try in-place substitution first; fall back to block-paste.
function M.smart()
  local st = view.current()
  if not st then
    util.notify("open a reading view first (:InlineExplorerOpen)", vim.log.levels.INFO)
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
    return util.notify("nothing under the cursor", vim.log.levels.WARN)
  end

  if not view.begin_fetch(st) then
    return util.notify("a lookup is already in flight", vim.log.levels.INFO)
  end

  local profile = require("inline-explorer.profile")
  -- Number this action before anything is recorded, so every span it
  -- produces carries the same id and the log can be grouped with certainty
  -- rather than by which lines happen to sit next to each other.
  profile.begin_action()
  local total = profile.start()

  -- Hand whatever we already resolved to the block-paste path instead of
  -- making it repeat the round trip. The guard is released first: expand
  -- acquires its own when it does have to fetch.
  local function block_fallback(prefetched)
    total("total:block-fallback", ident)
    view.end_fetch(st)
    vim.schedule(function()
      expander.expand(prefetched)
    end)
  end

  -- Aggregate rejections by cause, not as one opaque bucket.
  local function reject_stage(err)
    local e = tostring(err)
    for _, pat in ipairs({ "variadic", "arity", "not found", "empty" }) do
      if e:find(pat, 1, true) then
        return "substitute:rejected-" .. pat:gsub(" ", "-")
      end
    end
    return "substitute:rejected-other"
  end

  resolver.fetch(ident, st.source_bufnr, function(lines, label)
    if not lines then
      return block_fallback() -- expand re-resolves and reports if the name is unknown
    end
    local prefetched = { name = ident, body = lines, label = label }
    if fname and label == "function_definition" then
      local N = (st.subst_n or 0) + 1
      -- substitute covers parse, analysis (including enclosing_scope's
      -- whole-translation-unit walk) and printing. Kept as one span
      -- deliberately -- splitting it further would need the boundary
      -- inside substitute itself -- but it now says which callee and how
      -- big the caller was, which is what distinguishes a slow site from
      -- a slow engine.
      local sspan = profile.start()
      local ok, new, serr =
        pcall(substitute.inline_in_buffer, src, row, col, table.concat(lines, "\n"), N, config.options.mode)
      sspan(
        ok and new and "substitute:ok" or reject_stage(ok and serr or new),
        ("%s (caller %dL)"):format(ident, vim.api.nvim_buf_line_count(st.source_bufnr))
      )
      if ok and new then
        return vim.schedule(function()
          view.end_fetch(st)
          st.subst_n = N
          view.rewrite(st, bufnr, new, row)
          total("total:inline-function", ident)
        end)
      end
      return block_fallback(prefetched) -- e.g. variadic function
    end

    -- Not a confirmed function (macro, or heuristic-extracted from a header):
    -- try an in-place macro expansion via clangd (tweak, then hover); block-paste
    -- only if that yields nothing (so a plain function-signature hover never gets
    -- spliced). The clangd query runs against the ORIGINAL file, so map the
    -- view row back to its source line; inserted text has no source position
    -- and skips straight to the fallback.
    macro.fetch_expansion(st, view.src_line(st, row), col, function(exp)
      if not exp or #exp == 0 then
        return block_fallback(prefetched)
      end
      vim.schedule(function()
        local ok, new = pcall(macro.replace_in_src, src, row, col, exp)
        if ok and new then
          view.end_fetch(st)
          view.rewrite(st, bufnr, new, row)
          total("total:inline-macro", ident)
        else
          total("total:macro-splice-failed")
          view.end_fetch(st)
          expander.expand(prefetched)
        end
      end)
    end)
  end)
end

return M
