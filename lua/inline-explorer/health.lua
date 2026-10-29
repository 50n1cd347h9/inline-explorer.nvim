-- :checkhealth inline-explorer, for the buffer it was run from.
local macro = require("inline-explorer.macro")

local M = {}

local health = vim.health

local function check_version()
  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim >= 0.11")
  else
    health.error("Neovim 0.11+ required")
  end
end

local function check_client(client)
  local caps = client.server_capabilities or {}
  if caps.workspaceSymbolProvider then
    health.ok(("%s: workspace/symbol supported (name resolution)"):format(client.name))
  else
    health.error(("%s: no workspace/symbol -- symbol resolution will fail"):format(client.name))
  end
  if caps.documentSymbolProvider then
    health.ok(("%s: documentSymbol supported (definition ranges)"):format(client.name))
  else
    health.warn(
      (
        "%s: no documentSymbol -- definitions come from tree-sitter (which C and C++ use first anyway),"
        .. " else from a brace counter"
      ):format(client.name)
    )
  end
  if macro.supports_tweak(client) then
    health.ok(("%s: applyTweak supported (macro expansion)"):format(client.name))
  elseif client.name == "clangd" then
    health.warn("clangd: no applyTweak -- macros are block-pasted, not expanded")
  end
end

local function check_clients(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    health.warn("no language server attached to the buffer :checkhealth was run from", {
      "open a source file with an LSP configured, then re-run :checkhealth",
      "expansion fails with 'no language server attached' without one",
    })
  end
  for _, client in ipairs(clients) do
    check_client(client)
  end
end

local function check_parser(ft)
  local lang = vim.treesitter.language.get_lang(ft) or ft
  if pcall(vim.treesitter.language.inspect, lang) then
    local used_for = "view highlighting, extraction fallback"
    if lang == "c" then
      used_for = used_for .. ", inline substitution"
    end
    health.ok(("tree-sitter parser for '%s' installed (%s)"):format(lang, used_for))
  else
    health.warn(("no tree-sitter parser for '%s'"):format(lang), {
      ":TSInstall " .. lang,
      "the view falls back to regex syntax; C inline substitution needs the c parser",
    })
  end
end

local function check_compile_commands(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local start_dir
  if bufname ~= "" then
    start_dir = vim.fs.dirname(bufname)
  end
  local matches = vim.fs.find("compile_commands.json", { upward = true, path = start_dir })
  local found = matches[1]
  if found then
    health.ok("compile_commands.json found: " .. found)
  else
    health.warn("no compile_commands.json found upward of this file", {
      "clangd's index (and therefore resolution) works best with one",
      "kernel: make defconfig && ./scripts/clang-tools/gen_compile_commands.py",
    })
  end
end

-- :checkhealth runs the checks in its own health:// buffer, so the file it was
-- run from is the alternate buffer.
local function checked_buffer()
  local cur = vim.api.nvim_get_current_buf()
  if not vim.startswith(vim.api.nvim_buf_get_name(cur), "health://") then
    return cur
  end
  local alt = vim.fn.bufnr("#")
  if alt > 0 and vim.api.nvim_buf_is_valid(alt) then
    return alt
  end
  return cur
end

function M.check()
  health.start("inline-explorer")
  check_version()
  local bufnr = checked_buffer()
  check_clients(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft ~= "" then
    check_parser(ft)
  end
  if ft == "c" or ft == "cpp" then
    check_compile_commands(bufnr)
  end
end

return M
