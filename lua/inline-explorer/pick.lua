-- Picker glue: callers.get / resolver.locate_definition on one side,
-- trail.goto_location on the other, the plugin's own floating list
-- (select.lua) in the middle -- j/k move because it is a real window,
-- not because anything implements them. vim.ui.select was the first
-- middle and was dropped: stock nvim resolves it to inputlist(), a
-- type-a-number prompt, and whether j/k exist must not depend on which
-- UI plugin happens to be installed.
local callers = require("inline-explorer.callers")
local trail = require("inline-explorer.trail")
local select_ui = require("inline-explorer.select")
local util = require("inline-explorer.util")

local M = {}

local function word_under_cursor()
  return vim.fn.expand("<cword>")
end

-- The buffer to resolve against: a view's queries go through its source
-- buffer (which has the LSP clients); a plain buffer is its own source.
local function source_buf()
  local cur = vim.api.nvim_get_current_buf()
  local st = require("inline-explorer.view").state[cur]
  return st and st.source_bufnr or cur
end

-- The prelude both pickers share: a done() that fires done_cb if given,
-- and the identifier to act on -- nil (after warning and calling done)
-- when there is none.
local function begin(done_cb, name)
  local function done()
    if done_cb then
      done_cb()
    end
  end
  if name == "" then
    util.notify("no identifier under the cursor", vim.log.levels.WARN)
    done()
    return nil, done
  end
  return name, done
end

-- opts_name overrides the word under the cursor (tests, command args).
-- done_cb fires exactly once, after the flow settles (tests need a seam;
-- interactive use passes nothing).
function M.callers(done_cb, opts_name)
  local name, done = begin(done_cb, opts_name or word_under_cursor())
  if not name then
    return
  end
  callers.get(name, source_buf(), function(items, source, err)
    if #items == 0 then
      -- Never an empty picker: "0 callers" must not read as "nobody calls
      -- this" -- the index may simply not have finished.
      util.notify(
        ("no callers of '%s' found%s (the server's index may be incomplete)"):format(
          name,
          err and (" -- " .. err) or ""
        ),
        vim.log.levels.INFO
      )
      return done()
    end
    local title = ("callers of %s — %d [%s]%s"):format(name, #items, source, err and (" (" .. err .. ")") or "")
    select_ui.open(items, {
      prompt = title,
      format_item = function(it)
        return ("%s  %s:%d  │ %s"):format(
          it.name,
          vim.fn.fnamemodify(vim.uri_to_fname(it.uri), ":t"),
          it.range.start.line + 1,
          it.text
        )
      end,
    }, function(choice)
      if choice then
        trail.goto_location(choice)
      end
      done()
    end)
  end)
end

function M.definition(done_cb)
  local name, done = begin(done_cb, word_under_cursor())
  if not name then
    return
  end
  require("inline-explorer.resolver").locate_definition(name, source_buf(), function(loc, _, _, err)
    if not loc then
      util.notify(err or ("no definition found for '" .. name .. "'"), vim.log.levels.INFO)
      return done()
    end
    trail.goto_location(loc)
    done()
  end)
end

return M
