-- Picker glue: callers.get / resolver.locate on one side,
-- trail.goto_location on the other, vim.ui.select in the middle. Kept
-- deliberately thin -- a dressing.nvim / telescope override of
-- vim.ui.select upgrades this UI without this module knowing.
local callers = require("inline-explorer.callers")
local trail = require("inline-explorer.trail")

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

-- opts_name overrides the word under the cursor (tests, command args).
-- done_cb fires exactly once, after the flow settles (tests need a seam;
-- interactive use passes nothing).
function M.callers(done_cb, opts_name)
  local name = opts_name or word_under_cursor()
  local function done()
    if done_cb then
      done_cb()
    end
  end
  if name == "" then
    vim.notify("[inline-explorer] no identifier under the cursor", vim.log.levels.WARN)
    return done()
  end
  callers.get(name, source_buf(), function(items, source, err)
    if #items == 0 then
      -- Never an empty picker: "0 callers" must not read as "nobody calls
      -- this" -- the index may simply not have finished.
      vim.notify(("[inline-explorer] no callers of '%s' found%s (the server's index may be incomplete)"):format(
        name, err and (" -- " .. err) or ""), vim.log.levels.INFO)
      return done()
    end
    local title = ("callers of %s — %d [%s]%s"):format(name, #items, source,
      err and (" (" .. err .. ")") or "")
    vim.ui.select(items, {
      prompt = title,
      format_item = function(it)
        return ("%s  %s:%d  │ %s"):format(it.name,
          vim.fn.fnamemodify(vim.uri_to_fname(it.uri), ":t"),
          it.range.start.line + 1, it.text)
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
  local name = word_under_cursor()
  local function done()
    if done_cb then
      done_cb()
    end
  end
  if name == "" then
    vim.notify("[inline-explorer] no identifier under the cursor", vim.log.levels.WARN)
    return done()
  end
  require("inline-explorer.resolver").locate(name, source_buf(), function(loc, err)
    if not loc then
      vim.notify("[inline-explorer] " .. (err or ("no definition found for '" .. name .. "'")),
        vim.log.levels.INFO)
      return done()
    end
    trail.goto_location(loc)
    done()
  end)
end

return M
