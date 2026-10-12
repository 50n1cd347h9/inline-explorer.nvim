-- Commands on the identifier under the cursor:
--   M.callers lists its callers in a picker (select.lua) and goes to the
--     chosen call;
--   M.definition goes straight to its definition.
-- Both move with trail.goto_location, which shows the target in a reading
-- view and records the move on the navigation trail.
local callers = require("inline-explorer.callers")
local resolver = require("inline-explorer.resolver")
local select_ui = require("inline-explorer.select")
local trail = require("inline-explorer.trail")
local view = require("inline-explorer.view")
local util = require("inline-explorer.util")

local M = {}

local function word_under_cursor()
  return vim.fn.expand("<cword>")
end

-- The buffer to look names up from: a reading view's source buffer (the one
-- the language servers are attached to), or the current buffer when it is
-- not a view.
local function source_buf()
  local st = view.current()
  return st and st.source_bufnr or vim.api.nvim_get_current_buf()
end

-- A picker row for a callers.get item: the calling function, the file and
-- line of the call, and the text of that line.
local function format_caller(item)
  return ("%s  %s:%d  │ %s"):format(
    item.name,
    vim.fn.fnamemodify(vim.uri_to_fname(item.uri), ":t"),
    item.range.start.line + 1,
    item.text
  )
end

-- List the callers of the identifier under the cursor in a picker, and go to
-- the chosen call. `name_override` is an identifier to look up instead of the
-- word under the cursor. `done_cb` is called once when the flow ends (a
-- choice, a cancel, or nothing to show); tests use it to wait. Interactive
-- callers pass neither.
function M.callers(done_cb, name_override)
  local done = done_cb or function() end
  local name = name_override or word_under_cursor()
  if name == "" then
    util.notify("no identifier under the cursor", vim.log.levels.WARN)
    done()
    return
  end
  callers.get(name, source_buf(), function(items, provider, note)
    if #items == 0 then
      -- No empty picker: the message says the index may be incomplete, so
      -- "0 callers" does not read as "nobody calls this".
      local msg = ("no callers of '%s' found"):format(name)
      if note then
        msg = msg .. " -- " .. note
      end
      util.notify(msg .. " (the server's index may be incomplete)", vim.log.levels.INFO)
      done()
      return
    end
    -- For example "callers of kfree — 12 [lsp]", or
    -- "callers of foo — 37 [grep] (truncated at 200 matches)".
    local title = ("callers of %s — %d [%s]"):format(name, #items, provider)
    if note then
      title = title .. " (" .. note .. ")"
    end
    select_ui.open(items, { prompt = title, format_item = format_caller }, function(choice)
      if choice then
        trail.goto_location(choice)
      end
      done()
    end)
  end)
end

-- Go to the definition of the identifier under the cursor. resolver's
-- locate_definition follows a declaration to its definition when it can.
-- `done_cb` is called once when the flow ends; tests use it to wait.
function M.definition(done_cb)
  local done = done_cb or function() end
  local name = word_under_cursor()
  if name == "" then
    util.notify("no identifier under the cursor", vim.log.levels.WARN)
    done()
    return
  end
  resolver.locate_definition(name, source_buf(), function(loc, _lines, _label, err)
    if not loc then
      util.notify(err or ("no definition found for '" .. name .. "'"), vim.log.levels.INFO)
      done()
      return
    end
    trail.goto_location(loc)
    done()
  end)
end

return M
