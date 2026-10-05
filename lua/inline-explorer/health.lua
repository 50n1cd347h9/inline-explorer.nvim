-- :checkhealth inline-explorer -- one-stop diagnosis of everything the
-- Troubleshooting table in the README covers: Neovim version, language
-- servers and their capabilities, tree-sitter parsers, and (for C) whether
-- clangd can find a compile_commands.json.
local M = {}

function M.check()
  local health = vim.health
  health.start("inline-explorer")

  -- Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim >= 0.10")
  else
    health.error("Neovim 0.10+ required")
  end

  -- Language servers on the current buffer
  local bufnr = vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    health.warn("no language server attached to the current buffer", {
      "open a source file with an LSP configured, then re-run :checkhealth",
      "expansion fails with 'no language server attached' without one",
    })
  end
  for _, c in ipairs(clients) do
    local caps = c.server_capabilities or {}
    if caps.workspaceSymbolProvider then
      health.ok(("%s: workspace/symbol supported (name resolution)"):format(c.name))
    else
      health.error(("%s: no workspace/symbol -- symbol resolution will fail"):format(c.name))
    end
    if caps.documentSymbolProvider then
      health.ok(("%s: documentSymbol supported (definition ranges)"):format(c.name))
    else
      health.warn(("%s: no documentSymbol -- falling back to tree-sitter extraction"):format(c.name))
    end
    if c.name == "clangd" then
      if require("inline-explorer.macro").supports_tweak(c) then
        health.ok("clangd: applyTweak supported (ExpandMacro path)")
      else
        health.warn("clangd: no applyTweak -- macro expansion uses hover scraping only")
      end
    end
  end

  -- tree-sitter parser for the current filetype
  local ft = vim.bo[bufnr].filetype
  if ft ~= "" then
    local lang = vim.treesitter.language.get_lang(ft) or ft
    if pcall(vim.treesitter.language.inspect, lang) then
      health.ok(
        ("tree-sitter parser for '%s' installed (view highlighting, extraction fallback%s)"):format(
          lang,
          lang == "c" and ", inline substitution" or ""
        )
      )
    else
      health.warn(("no tree-sitter parser for '%s'"):format(lang), {
        ":TSInstall " .. lang,
        "the view falls back to regex syntax; C inline substitution needs the c parser",
      })
    end
  end

  -- compile_commands.json (C projects)
  if ft == "c" or ft == "cpp" then
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local found = vim.fs.find("compile_commands.json", {
      upward = true,
      path = bufname ~= "" and vim.fs.dirname(bufname) or nil,
    })[1]
    if found then
      health.ok("compile_commands.json found: " .. found)
    else
      health.warn("no compile_commands.json found upward of this file", {
        "clangd's index (and therefore resolution) works best with one",
        "kernel: make defconfig && ./scripts/clang-tools/gen_compile_commands.py",
      })
    end
  end
end

return M
