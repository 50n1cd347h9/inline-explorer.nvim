-- Smart inline (<leader>ei), the primary expansion action. In a C buffer, a
-- call of a function whose definition is found is substituted in place.
-- Any other name with a definition is offered to clangd as a macro use and
-- replaced by its expansion: clangd expands only macros, so for anything
-- else that step finds nothing. A name found only as a declaration, and
-- every failure, block-pastes the definition (expander.expand), as in any
-- other language.
local resolver = require("inline-explorer.resolver")
local substitute = require("inline-explorer.substitute")
local csrc = require("inline-explorer.csrc")
local macro = require("inline-explorer.macro")
local expander = require("inline-explorer.expander")
local view = require("inline-explorer.view")
local config = require("inline-explorer.config")
local profile = require("inline-explorer.profile")
local util = require("inline-explorer.util")

local M = {}

-- The view buffer's tree, which the highlighter keeps parsed incrementally,
-- so a keypress does not parse the whole file. nil on failure; substitute and
-- macro then parse the text themselves.
local function buffer_root(bufnr)
  local ok, root = pcall(function()
    return vim.treesitter.get_parser(bufnr, "c"):parse()[1]:root()
  end)
  if not ok then
    return nil
  end
  return root
end

-- The profile span name for a failed substitution: the refusal's code, or
-- "other" for an error raised inside the engine.
local function rejection_label(reason)
  local code = type(reason) == "table" and reason.code or "other"
  return "substitute:rejected-" .. code
end

-- One smart-inline keypress, as M.smart sets it up.
---@class inline_explorer.InlineAction
---@field st inline_explorer.ViewState
---@field bufnr integer the view buffer
---@field row integer the cursor row, 0-based
---@field col integer the cursor's byte column, 0-based
---@field view_text string the view buffer's text
---@field root TSNode? the tree of view_text
---@field ident string the name being inlined
---@field finish_total inline_explorer.StopTimer ends the keypress's span

-- The fetch guard is released first: without `prefetched`, expand fetches and
-- takes the guard itself.
local function block_fallback(action, prefetched)
  action.finish_total("total:block-fallback", action.ident)
  view.end_fetch(action.st)
  vim.schedule(function()
    expander.expand(prefetched)
  end)
end

local function inline_function(action, prefetched)
  local st = action.st
  local expansion_id = (st.subst_n or 0) + 1
  local finish_substitute = profile.start()
  local callee_src = table.concat(prefetched.body, "\n")
  local ok, result, reason = pcall(
    substitute.inline_at,
    action.view_text,
    action.row,
    action.col,
    callee_src,
    expansion_id,
    config.options.mode,
    action.root
  )
  local new_text, failure
  if ok then
    new_text, failure = result, reason
  else
    failure = result
  end
  finish_substitute(
    new_text and "substitute:ok" or rejection_label(failure),
    ("%s (caller %dL)"):format(action.ident, vim.api.nvim_buf_line_count(st.source_bufnr))
  )
  if not new_text then
    block_fallback(action, prefetched)
    return
  end
  vim.schedule(function()
    view.end_fetch(st)
    st.subst_n = expansion_id
    view.rewrite(st, action.bufnr, new_text, action.row)
    action.finish_total("total:inline-function", action.ident)
  end)
end

local function expand_macro(action, prefetched)
  local st = action.st
  -- clangd knows only the source file.
  local src_row = view.src_line(st, action.row)
  macro.fetch_expansion(st, src_row, action.col, function(expansion)
    if not expansion or #expansion == 0 then
      block_fallback(action, prefetched)
      return
    end
    vim.schedule(function()
      local ok, new_text = pcall(macro.replace_in_src, action.view_text, action.row, action.col, expansion, action.root)
      if ok and new_text then
        view.end_fetch(st)
        view.rewrite(st, action.bufnr, new_text, action.row)
        action.finish_total("total:inline-macro", action.ident)
      else
        -- As block_fallback, but under its own span name, and calling expand
        -- directly: this callback already runs scheduled.
        action.finish_total("total:macro-splice-failed")
        view.end_fetch(st)
        expander.expand(prefetched)
      end
    end)
  end)
end

function M.smart()
  local st = view.current()
  if not st then
    util.notify("open a reading view first (:InlineExplorerOpen)", vim.log.levels.INFO)
    return
  end
  if vim.bo.filetype ~= "c" or not csrc.has_parser() then
    expander.expand()
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local view_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local root = buffer_root(bufnr)

  local call_name = substitute.call_name_at(view_text, row, col, root)
  local ident = call_name
  if not ident or ident == "" then
    ident = vim.fn.expand("<cword>")
  end
  if not ident or ident == "" then
    util.notify("nothing under the cursor", vim.log.levels.WARN)
    return
  end

  if not view.begin_fetch(st) then
    util.notify("a lookup is already in flight", vim.log.levels.INFO)
    return
  end

  -- Before resolver.fetch, so its spans carry this action's id too.
  profile.begin_action()
  ---@type inline_explorer.InlineAction
  local action = {
    st = st,
    bufnr = bufnr,
    row = row,
    col = col,
    view_text = view_text,
    root = root,
    ident = ident,
    finish_total = profile.start(),
  }

  resolver.fetch(ident, st.source_bufnr, function(lines, label)
    if not lines then
      block_fallback(action) -- expand looks up <cword> itself, and reports a failure
      return
    end
    local prefetched = { name = ident, body = lines, label = label }
    if call_name and label == "function_definition" then
      inline_function(action, prefetched)
    elseif label == "declaration" then
      -- Its definition was not found, and it is no macro.
      block_fallback(action, prefetched)
    else
      -- For anything but a macro, clangd has no expansion, and expand_macro
      -- block-pastes the definition.
      expand_macro(action, prefetched)
    end
  end)
end

return M
