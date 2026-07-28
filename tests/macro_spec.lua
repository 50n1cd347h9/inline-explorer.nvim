-- Pure tests for macro expansion parsing and in-place placement (no LSP needed).
--   nvim --headless --clean -u NONE -c "luafile tests/macro_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local macro = require("inline-explorer.macro")

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
    print("FAIL  " .. l .. (d and ("\n----\n" .. d .. "\n----") or ""))
  end
end

-- clangd puts #define + "// Expands to" + expansion in a single code block.
local hover_inline = table.concat({
  "### `READ_ONCE`", "", "```c",
  "#define READ_ONCE(x) ({ compiletime_assert_rwonce_type(x); __READ_ONCE(x); })", "",
  "// Expands to", "",
  "({", "    do { assert(); } while (0);", "    (*(volatile typeof(v) *)&(v));", "})",
  "```",
}, "\n")
-- Older/alternate: separate code blocks with a plain "Expands to" line.
local hover_blocks = "### macro `MASK`\n```c\n#define MASK (0x3U << 0)\n```\n\nExpands to\n\n```c\n(0x3U << 0)\n```"

do
  local e = table.concat(macro._expansion_lines(hover_inline), "\n")
  check("expansion after inline '// Expands to', #define dropped", e:find("({", 1, true) and not e:find("#define", 1, true), e)
  check("separate-block 'Expands to' -> value", table.concat(macro._expansion_lines(hover_blocks), "\n") == "(0x3U << 0)")
end

-- Object-like macro in expression context -> parenthesised value.
do
  local src = "int f(int x) { return x & MASK; }"
  local col = src:find("MASK") - 1
  local new = macro.replace_in_src(src, 0, col, { "(0x3U << 0)" })
  check("object macro replaced, no double parens", new:find("x & (0x3U << 0)", 1, true) and not new:find("((0x3U", 1, true), new)
end

-- Function-like macro invocation -> whole call replaced.
do
  local src = "int f(int y) { return FOO(y) + 1; }"
  local col = src:find("FOO") - 1
  local new = macro.replace_in_src(src, 0, col, { "((y) + 1)" })
  check("function-like macro call replaced", new:find("return ((y) + 1) + 1;", 1, true) ~= nil, new)
end

-- Multi-line expansion: continuation lines indented with whitespace only.
do
  local src = "void g(void)\n{\n    *flags = READ_ONCE(v);\n}"
  local row, col = 2, ("    *flags = READ_ONCE(v);"):find("READ_ONCE") - 1
  local new = macro.replace_in_src(src, row, col, { "({", "    do {} while (0);", "    v;", "})" })
  check("multi-line: no 'foo =' repeated on continuations", select(2, new:gsub("%*flags = ", "")) == 1, new)
  check("multi-line: continuation indented with spaces", new:find("\n        do {", 1, true) ~= nil, new)
end

print("")
print(fails == 0 and "ALL MACRO TESTS PASSED" or (fails .. " FAILURE(S)"))
