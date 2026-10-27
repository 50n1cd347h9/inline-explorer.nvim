-- Jumps from the identifier under the cursor: to one of its callers, chosen
-- in a picker (select.lua), or to its definition. Both go through
-- trail.goto_location.
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

-- Names are looked up from a view's source buffer: the language servers are
-- attached to it, not to the view.
local function source_buf()
  local st = view.current()
  return st and st.source_bufnr or vim.api.nvim_get_current_buf()
end

local function format_caller(item)
  return ("%s  %s:%d  │ %s"):format(
    item.name,
    vim.fn.fnamemodify(vim.uri_to_fname(item.uri), ":t"),
    item.range.start.line + 1,
    item.text
  )
end

---@param done_cb? fun() called once, however the flow ends; tests wait on it
function M.callers(done_cb)
  local done = done_cb or function() end
  local name = word_under_cursor()
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

---@param done_cb? fun() called once, however the flow ends; tests wait on it
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
