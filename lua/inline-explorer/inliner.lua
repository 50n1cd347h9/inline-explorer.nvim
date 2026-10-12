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
local profile = require("inline-explorer.profile")
local util = require("inline-explorer.util")

local M = {}

-- Returns whether a C grammar is installed. get_string_parser throws without
-- one; the snippet it is given does not matter.
local function has_c_parser()
  local ok = pcall(vim.treesitter.get_string_parser, "int __ie;", "c")
  return ok
end

-- Returns the view buffer's syntax tree. The highlighter keeps it parsed
-- incrementally, so a keypress does not re-parse the whole file. Once
-- has_c_parser() has passed this is not expected to fail; if it does, the
-- result is nil and substitute and macro parse the text themselves.
local function buffer_root(bufnr)
  local ok, root = pcall(function()
    return vim.treesitter.get_parser(bufnr, "c"):parse()[1]:root()
  end)
  if not ok then
    return nil -- root is the error message, not a tree
  end
  return root
end

-- Returns the profile span name for a failed substitution, named by its
-- cause. The keys are words in the reasons canalyze and substitute give:
-- "cannot inline variadic function", "arity mismatch", "... not found" and
-- "empty function body".
local function rejection_label(reason)
  local message = tostring(reason)
  for _, key in ipairs({ "variadic", "arity", "not found", "empty" }) do
    if message:find(key, 1, true) then
      return "substitute:rejected-" .. (key:gsub(" ", "-"))
    end
  end
  return "substitute:rejected-other"
end

-- The functions below take `action`, one smart-inline keypress as M.smart
-- sets it up:
--   st            the reading view's state
--   bufnr         the view buffer
--   row, col      the cursor position, 0-based
--   view_text     the view buffer's text
--   root          the syntax tree of view_text, or nil
--   ident         the name being inlined
--   finish_total  ends the keypress's profile span when called with the
--                 span's name and an optional detail (see profile.start)

-- Block-paste the definition instead. `prefetched`, when given, is the
-- definition already fetched, so expand does not look it up again. The fetch
-- guard is released first because expand takes its own when it has to fetch.
local function block_fallback(action, prefetched)
  action.finish_total("total:block-fallback", action.ident)
  view.end_fetch(action.st)
  vim.schedule(function()
    expander.expand(prefetched)
  end)
end

-- Replace the call under the cursor with the function's body, in place.
-- Falls back to block-paste when substitute rejects the call (a variadic
-- function, for example).
local function inline_function(action, prefetched)
  local st = action.st
  -- expansion_id is the suffix that keeps the names this expansion injects
  -- (__ie_retN and the like) unique in the view.
  local expansion_id = (st.subst_n or 0) + 1
  -- One span covers the whole substitute call: parsing, analysis and
  -- printing. Its detail records the callee and the source file's line
  -- count, so a slow span can be traced to a large file or to one callee.
  local finish_substitute = profile.start()
  local callee_src = table.concat(prefetched.body, "\n")
  local ok, result, reason = pcall(
    substitute.inline_in_buffer,
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
    -- inline_in_buffer returned the new text, or nil and a reason.
    new_text, failure = result, reason
  else
    -- inline_in_buffer threw, and result is the error message.
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

-- Replace the macro use under the cursor with clangd's expansion of it, in
-- place. When clangd has no expansion (a function's hover shows none), the
-- definition is block-pasted instead, so a function signature is never
-- spliced in.
local function expand_macro(action, prefetched)
  local st = action.st
  -- clangd reads the original file, so the view row is mapped back to its
  -- source line. A line inserted by an earlier expansion has none (nil), and
  -- then no expansion comes back.
  local src_row = view.src_line(st, action.row)
  -- fetch_expansion tries clangd's ExpandMacro code action, then its hover.
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
        -- This repeats block_fallback's steps, but records a failed splice
        -- and calls expand directly, as this callback is already scheduled.
        action.finish_total("total:macro-splice-failed")
        view.end_fetch(st)
        expander.expand(prefetched)
      end
    end)
  end)
end

-- Inline the name under the cursor: in place when possible, else as a
-- block-paste of its definition.
function M.smart()
  local st = view.current()
  if not st then
    util.notify("open a reading view first (:InlineExplorerOpen)", vim.log.levels.INFO)
    return
  end
  if vim.bo.filetype ~= "c" or not has_c_parser() then
    expander.expand() -- without C or its parser, only block-paste works
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local view_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local root = buffer_root(bufnr)

  -- call_name is nil unless the cursor is on a call to a named function, f(...).
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

  -- Number the action before any span is recorded, so all of its spans
  -- carry the same id in the profile log.
  profile.begin_action()
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

  -- lines is the definition's text, or nil when it was not found. label is
  -- the kind of definition found; "function_definition" means a C function.
  resolver.fetch(ident, st.source_bufnr, function(lines, label)
    if not lines then
      block_fallback(action) -- expand looks the name up itself and reports it if unknown
      return
    end
    local prefetched = { name = ident, body = lines, label = label }
    if call_name and label == "function_definition" then
      inline_function(action, prefetched)
    else
      -- The cursor is not on a call, or the definition is not known to be a
      -- function (a macro, a declaration, or a heuristic match in a header).
      expand_macro(action, prefetched)
    end
  end)
end

return M
