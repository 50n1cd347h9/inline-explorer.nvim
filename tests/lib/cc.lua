-- gcc helpers shared by the specs that compile what the engine produced.
--
-- One flag set for every site. The only hard error it adds is
-- -Werror=implicit-function-declaration; the -Wno-unused-* flags merely keep
-- gcc's output readable, and since none of those warnings is enabled without
-- -Wall/-Wextra (and nothing here turns them into errors), they can never
-- change an exit status -- which is why the sites that used to pass slightly
-- different subsets of them could share this list.
local H = require("tests.lib.harness")

local M = {}

M.FLAGS = {
  "-std=gnu11",
  "-Werror=implicit-function-declaration",
  "-Wno-unused-label",
  "-Wno-unused-function",
  "-Wno-unused-variable",
  "-Wno-unused-but-set-variable",
}

local function gcc(extra, path, tail)
  local argv = { "gcc" }
  vim.list_extend(argv, M.FLAGS)
  vim.list_extend(argv, extra)
  argv[#argv + 1] = path
  vim.list_extend(argv, tail)
  local out = vim.fn.system(argv)
  return vim.v.shell_error == 0, out
end

-- Write `src` to `path` and syntax-check it. Returns (ok, gcc_output).
function M.syntax_ok(path, src)
  H.writef(path, src)
  return gcc({ "-fsyntax-only" }, path, {})
end

-- Write `src` to `path`, build it to `exe` and run it.
-- Returns (stdout, exit_code), or (nil, gcc_output) when it does not build.
function M.build_run(src, path, exe)
  H.writef(path, src)
  local ok, out = gcc({}, path, { "-o", exe })
  if not ok then
    return nil, out
  end
  local stdout = vim.fn.system({ exe })
  return stdout, vim.v.shell_error
end

return M
