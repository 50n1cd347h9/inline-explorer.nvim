-- :checkhealth inline-explorer reports on the file it was run from.
--   nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/health_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local H = require("tests.lib.harness")

local check = H.check

-- :checkhealth runs the checks in a new health:// buffer. Checks that read
-- the current buffer saw that buffer instead of the user's file, so the
-- parser and compile_commands.json checks never ran.
local dir = H.tmpdir()
H.writef(dir .. "/a.c", "int f(void) { return 1; }\n")
H.writef(dir .. "/compile_commands.json", "[]")
vim.cmd("filetype on")
vim.cmd.edit(dir .. "/a.c")
vim.cmd("checkhealth inline-explorer")

local out = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
check("health: the report is in its own buffer", vim.api.nvim_buf_get_name(0):match("^health://") ~= nil)
check("health: the parser check ran for the C file", out:find("parser for 'c'", 1, true) ~= nil, out)
check(
  "health: compile_commands.json is looked up from the C file",
  out:find("compile_commands.json found", 1, true) ~= nil,
  out
)

-- Macro expansion uses whichever server has clangd's tweak, so the report
-- says so for that server, and a clangd without it is told it gets no
-- expansion at all (the hover is asked only from the tweak's server).
do
  local fake_lsp = require("tests.lib.fake_lsp")
  vim.cmd.edit(dir .. "/a.c")
  local abuf = vim.api.nvim_get_current_buf()
  local plain = fake_lsp.start({
    name = "clangd",
    buf = abuf,
    root_dir = dir,
    capabilities = { workspaceSymbolProvider = true, hoverProvider = true },
    skip = "health client checks (in-process LSP server unavailable)",
  })
  local tweaked = fake_lsp.start({
    name = "clangd-18",
    buf = abuf,
    root_dir = dir,
    capabilities = { workspaceSymbolProvider = true, executeCommandProvider = { commands = { "clangd.applyTweak" } } },
    skip = "health client checks (in-process LSP server unavailable)",
  })
  if plain and tweaked then
    vim.cmd("checkhealth inline-explorer")
    local report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    check(
      "health: the tweak is reported for the server that has it, whatever its name",
      report:find("clangd-18: applyTweak supported", 1, true) ~= nil,
      report
    )
    check(
      "health: a clangd without the tweak is told macros are not expanded",
      report:find("macros are block-pasted", 1, true) ~= nil,
      report
    )
  end
end

H.finish("HEALTH")
