-- Regression: a function/macro defined in a `.h` header (often detected as C++,
-- while only the C tree-sitter parser is installed) must still extract as a real
-- definition node, not fall back to the "heuristic" label -- otherwise the smart
-- action mistakes a header-defined function for a non-function and block-pastes.
--   nvim --headless --clean -u NONE -c "luafile tests/resolver_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local resolver = require("inline-explorer.resolver")

if not pcall(vim.treesitter.get_string_parser, "int x;", "c") then
  print("SKIP: c parser unavailable")
  return
end

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and (" (" .. d .. ")") or ""))
  end
end

local hpath = vim.fn.tempname() .. ".h"
local f = assert(io.open(hpath, "w"))
f:write("static __always_inline int acc(int cpu)\n{\n    return per_cpu(cpu) & MASK;\n}\n")
f:close()

local uri = vim.uri_from_fname(hpath)
local col = ("static __always_inline int acc(int cpu)"):find("acc") - 1
local lines, label = resolver.extract({ uri = uri, range = { start = { line = 0, character = col } } })

check("header function extracts as function_definition (not heuristic)", label == "function_definition", tostring(label))
check("extracted body includes the return", table.concat(lines, "\n"):find("return per_cpu", 1, true) ~= nil)

print("")
print(fails == 0 and "ALL RESOLVER TESTS PASSED" or (fails .. " FAILURE(S)"))
