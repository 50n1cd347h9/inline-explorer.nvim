-- luacheck (https://github.com/lunarmodules/luacheck): lint, plus a ceiling
-- on how many paths one function may have (if/elseif, loops, and/or).
-- A function over the ceiling is split, not exempted.
--   luacheck lua tests
std = "luajit"
globals = { "vim" }
max_cyclomatic_complexity = 15

-- Specs are linear scripts -- one long main chunk of checks -- with
-- fixture strings (generated C, expected output) that cannot wrap. They are
-- linted, but their complexity and line length are not limited.
files["tests"] = {
  max_cyclomatic_complexity = false,
  max_line_length = false,
}
