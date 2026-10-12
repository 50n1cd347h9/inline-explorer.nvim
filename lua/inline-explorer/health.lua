-- :checkhealth inline-explorer. It checks everything the Troubleshooting
-- table in the README covers: the Neovim version, the language servers and
-- their capabilities, the tree-sitter parser, and (for C and C++) whether
-- clangd can find a compile_commands.json.
local macro = require("inline-explorer.macro")

local M = {}

local health = vim.health

local function check_version()
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim >= 0.10")
  else
    health.error("Neovim 0.10+ required")
  end
end

-- Report which of the requests the plugin relies on `client` supports.
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
    health.warn(("%s: no documentSymbol -- falling back to tree-sitter extraction"):format(client.name))
  end
  if client.name == "clangd" then
    if macro.supports_tweak(client) then
      health.ok("clangd: applyTweak supported (ExpandMacro path)")
    else
      health.warn("clangd: no applyTweak -- macro expansion uses hover scraping only")
    end
  end
end

-- Report each language server attached to `bufnr`, or warn that there is none.
local function check_clients(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    health.warn("no language server attached to the current buffer", {
      "open a source file with an LSP configured, then re-run :checkhealth",
      "expansion fails with 'no language server attached' without one",
    })
  end
  for _, client in ipairs(clients) do
    check_client(client)
  end
end

-- Report whether the tree-sitter parser for filetype `ft` is installed.
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

-- Report whether a compile_commands.json exists in the directory of
-- `bufnr`'s file or in any directory above it.
local function check_compile_commands(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  -- An unnamed buffer has no directory; with no path, vim.fs.find starts
  -- from the current directory.
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

-- Check the current buffer: its language servers, its parser and, for C and
-- C++, its compile_commands.json.
function M.check()
  health.start("inline-explorer")
  check_version()
  local bufnr = vim.api.nvim_get_current_buf()
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
