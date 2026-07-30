-- Expander: resolve the symbol under the cursor and splice its definition into
-- the reading view as a folded, indented block below the call line.
local config = require("inline-explorer.config")
local resolver = require("inline-explorer.resolver")
local view = require("inline-explorer.view")

local M = {}

-- Names of expansions whose extmark range currently contains `lnum` (0-indexed).
-- Used to stop a symbol from being expanded inside its own body (recursion).
local function ancestor_names(st, bufnr, lnum)
  local names = {}
  for _, node in ipairs(st.nodes) do
    local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, view.ns, node.s_mark, {})
    local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, view.ns, node.e_mark, {})
    if s[1] and e[1] and lnum >= s[1] and lnum <= e[1] then
      names[node.name] = true
    end
  end
  return names
end

local function notify(msg, level)
  vim.notify("[inline-explorer] " .. msg, level or vim.log.levels.WARN)
end

-- Block-expand the symbol under the cursor.
--
-- `prefetched` ({ name, body, label }) lets a caller that ALREADY resolved the
-- symbol hand the result over instead of making us repeat the round trip --
-- the inliner does this when it falls back to block-pasting. Anything without
-- a `body` is ignored, so the plain command/keymap callbacks (which are
-- invoked with their own argument tables) behave exactly as before. The
-- prefetched path is instrumented like the fetching one: it still records its
-- own `total:expand` span around the splice, so every completed expansion --
-- prefetched or not -- ends with a terminal `total:` span for the harness to
-- wait on.
function M.expand(prefetched)
  local st = view.current()
  if not st then
    return notify("open a reading view first (:InlineExplorerOpen)", vim.log.levels.INFO)
  end

  local pre = (type(prefetched) == "table" and prefetched.body and #prefetched.body > 0) and prefetched or nil
  local name = pre and pre.name or vim.fn.expand("<cword>")
  if not name or name == "" then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1

  if ancestor_names(st, bufnr, lnum)[name] then
    return notify("'" .. name .. "' is already expanded above (recursion guard)", vim.log.levels.INFO)
  end

  if pre then
    -- Deliberately does NOT number a new action. This branch is only ever
    -- reached as the continuation of an inline that fell back to block
    -- paste, so the work belongs to the action already in progress.
    -- Numbering here split one keypress across two ids in the log --
    -- `#7 total:block-fallback 133.0ms` followed by a stray
    -- `#8 total:expand 0.6ms` -- which is exactly the grouping the ids
    -- exist to make reliable.
    local pre_span = require("inline-explorer.profile").start()
    M._insert(st, bufnr, lnum, name, pre.body, pre.label)
    pre_span("total:expand", name)
    return
  end

  if not view.begin_fetch(st) then
    return notify("a lookup is already in flight", vim.log.levels.INFO)
  end

  local pf2 = require("inline-explorer.profile")
  pf2.begin_action()
  local span = pf2.start()
  resolver.fetch(name, st.source_bufnr, function(body, label, err)
    vim.schedule(function()
      view.end_fetch(st)
      if not body or #body == 0 then
        span("total:expand-failed", name)
        return notify(err or ("could not extract a body for '" .. name .. "'"))
      end
      M._insert(st, bufnr, lnum, name, body, label)
      span("total:expand", ("%s (%dL, %s)"):format(name, #body, tostring(label)))
    end)
  end)
end

-- Splice `body` into `bufnr` just below `lnum`, indented one level past the
-- call line, wrapped in a fold that starts open.
function M._insert(st, bufnr, lnum, name, body, label)
  local opts = config.options
  local call_line = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""
  local pad = (call_line:match("^%s*") or "") .. opts.indent

  local out = {}
  if opts.header then
    out[#out + 1] = pad .. "/* v " .. name .. " (" .. label .. ") */"
  end
  for _, l in ipairs(body) do
    out[#out + 1] = (l == "") and "" or (pad .. l)
  end
  if opts.header then
    out[#out + 1] = pad .. "/* ^ " .. name .. " */"
  end

  require("inline-explorer.history").snapshot(st, bufnr)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, lnum + 1, lnum + 1, false, out)
  vim.bo[bufnr].modifiable = false

  -- Origin bookkeeping: spliced lines have no position in the source file.
  if st.origin then
    for _ = 1, #out do
      table.insert(st.origin, lnum + 2, false)
    end
  end

  local first, last = lnum + 1, lnum + #out -- 0-indexed inserted range
  st.nodes[#st.nodes + 1] = {
    name = name,
    s_mark = vim.api.nvim_buf_set_extmark(bufnr, view.ns, first, 0, {}),
    e_mark = vim.api.nvim_buf_set_extmark(bufnr, view.ns, last, 0, {}),
  }

  -- Create the fold (1-indexed line numbers) and open it.
  vim.cmd(string.format("%d,%dfold", first + 1, last + 1))
  vim.cmd(string.format("%d,%dfoldopen", first + 1, last + 1))
end

return M
