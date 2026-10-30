-- K in a reading view: the language server's hover, as K shows it in a file.
-- The view has no server of its own. A line it still has from its file asks
-- about that place in the file; an expansion's line, which has none, asks
-- about the definition of the name under the cursor.
local lsp = require("inline-explorer.lsp")
local resolver = require("inline-explorer.resolver")
local util = require("inline-explorer.util")
local view = require("inline-explorer.view")

local M = {}

local METHOD = "textDocument/hover"

local function show(client, bufnr, position)
  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = position }
  client:request(METHOD, params, function(err, result)
    local lines = not err
      and result
      and result.contents
      and vim.lsp.util.convert_input_to_markdown_lines(result.contents)
    if not lines or #lines == 0 then
      return util.notify("no hover information", vim.log.levels.INFO)
    end
    vim.lsp.util.open_floating_preview(lines, "markdown", { focus_id = METHOD })
  end, bufnr)
end

function M.hover()
  local st = view.current()
  if not st then
    return util.notify("not in a reading view", vim.log.levels.WARN)
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local src_row = view.src_line(st, row - 1)
  if src_row then
    local client = vim.lsp.get_clients({ bufnr = st.source_bufnr, method = METHOD })[1]
    if not client then
      return util.notify("no language server with hover on the source buffer", vim.log.levels.WARN)
    end
    -- The line is the file's own, so the cursor's byte column holds there.
    local line = vim.api.nvim_get_current_line()
    return show(
      client,
      st.source_bufnr,
      { line = src_row, character = util.lsp_col(line, col, client.offset_encoding) }
    )
  end
  local name = vim.fn.expand("<cword>")
  resolver.locate(name, st.source_bufnr, function(loc, err)
    local client = loc and lsp.client_for(loc, st.source_bufnr, METHOD)
    if not client then
      return util.notify(err or ("no hover for '" .. name .. "'"), vim.log.levels.INFO)
    end
    local target = lsp.ensure_attached(loc.uri, client)
    show(client, target, lsp.name_position(target, loc, client.offset_encoding))
  end)
end

return M
