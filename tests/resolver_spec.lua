-- Resolver unit tests: LSP documentSymbol range selection (_symbol_range) and
-- the table-free tree-sitter fallback (extract_sync / async extract).
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
    print("FAIL  " .. l .. (d and (" (" .. vim.inspect(d) .. ")") or ""))
  end
end

local function range(sl, sc, el, ec)
  return { start = { line = sl, character = sc }, ["end"] = { line = el, character = ec } }
end

-- _symbol_range: hierarchical DocumentSymbol[] -- the deepest symbol containing
-- the reference wins, and function-ish kinds map to "function_definition".
do
  local symbols = {
    {
      name = "MyClass",
      kind = 5, -- Class
      range = range(0, 0, 20, 1),
      selectionRange = range(0, 6, 0, 13),
      children = {
        { name = "method", kind = 6, range = range(2, 2, 5, 3), selectionRange = range(2, 6, 2, 12) },
      },
    },
  }
  local ref = range(2, 6, 2, 12) -- workspace/symbol points at the method's name
  local r, label = resolver._symbol_range(symbols, ref, "method")
  check("hierarchical: deepest symbol range wins", r and r.start.line == 2 and r["end"].line == 5, r)
  check("hierarchical: Method kind -> function_definition", label == "function_definition", label)
end

-- _symbol_range: non-function kinds keep a lowercase kind label.
do
  local symbols = {
    { name = "S", kind = 23, range = range(0, 0, 3, 1), selectionRange = range(0, 7, 0, 8), children = {} },
  }
  local r, label = resolver._symbol_range(symbols, range(0, 7, 0, 8), "S")
  check("hierarchical: Struct kind -> 'struct' label", label == "struct", label)
  check("hierarchical: struct full range", r and r["end"].line == 3, r)
end

-- _symbol_range: flat SymbolInformation[] -- name-matched containing range;
-- a range identical to the reference (name-only) is rejected.
do
  local flat = {
    { name = "other", kind = 12, location = { uri = "file:///x.c", range = range(0, 0, 4, 1) } },
    { name = "f", kind = 12, location = { uri = "file:///x.c", range = range(6, 0, 9, 1) } },
  }
  local r = resolver._symbol_range(flat, range(6, 11, 6, 12), "f")
  check("flat: name-matched containing range", r and r.start.line == 6 and r["end"].line == 9, r)
  local name_only = { { name = "g", kind = 12, location = { uri = "file:///x.c", range = range(3, 4, 3, 5) } } }
  check("flat: name-only range rejected", resolver._symbol_range(name_only, range(3, 4, 3, 5), "g") == nil)
end

-- extract_sync: header-defined function (no LSP, no node-type table) must
-- still extract the full definition with label "function_definition".
do
  local hpath = vim.fn.tempname() .. ".h"
  local f = assert(io.open(hpath, "w"))
  f:write("static __always_inline int acc(int cpu)\n{\n    return per_cpu(cpu) & MASK;\n}\n")
  f:close()
  local col = ("static __always_inline int acc(int cpu)"):find("acc") - 1
  local lines, label = resolver.extract_sync({ uri = vim.uri_from_fname(hpath), range = range(0, col, 0, col) })
  check("extract_sync: header function -> function_definition", label == "function_definition", tostring(label))
  check("extract_sync: body includes the return", table.concat(lines, "\n"):find("return per_cpu", 1, true) ~= nil)
end

-- extract_sync: macro definition -> a preproc node type, continuation kept.
do
  local cpath = vim.fn.tempname() .. ".c"
  local f = assert(io.open(cpath, "w"))
  f:write("#define TWICE(x) \\\n    ((x) + (x))\nint y;\n")
  f:close()
  local lines, label = resolver.extract_sync({ uri = vim.uri_from_fname(cpath), range = range(0, 8, 0, 13) })
  check("extract_sync: macro label is a preproc node", type(label) == "string" and label:find("preproc") ~= nil, label)
  check("extract_sync: continuation line kept", table.concat(lines, "\n"):find("(x) + (x)", 1, true) ~= nil)
end

-- extract (async wrapper): with no LSP attached it falls back to extract_sync
-- and calls cb synchronously.
do
  local hpath = vim.fn.tempname() .. ".h"
  local f = assert(io.open(hpath, "w"))
  f:write("static int one(void)\n{\n    return 1;\n}\n")
  f:close()
  local got_lines, got_label
  resolver.extract({ uri = vim.uri_from_fname(hpath), range = range(0, 11, 0, 14) }, 0, function(lines, label)
    got_lines, got_label = lines, label
  end)
  vim.wait(200, function()
    return got_lines ~= nil
  end, 10)
  check("extract: no-LSP path falls back", got_label == "function_definition", tostring(got_label))
  check("extract: fallback returned the body", got_lines ~= nil and table.concat(got_lines, "\n"):find("return 1", 1, true) ~= nil)
end

-- extract_sync: include-guarded header must not swallow the whole guard.
-- Pass 1 of the two-pass ancestor walk must find the function_definition
-- before the preproc_ifdef container is ever reached; the container must
-- not be selected and the walk must not ascend past it.
do
  local hpath = vim.fn.tempname() .. ".h"
  local f = assert(io.open(hpath, "w"))
  f:write("#ifndef FOO_H\n#define FOO_H\nstatic int acc(int cpu)\n{\n    return cpu + 1;\n}\n#endif\n")
  f:close()
  local col = ("static int acc(int cpu)"):find("acc") - 1
  local lines, label = resolver.extract_sync({ uri = vim.uri_from_fname(hpath), range = range(2, col, 2, col) })
  check("extract_sync: include guard -> function_definition, not the guard", label == "function_definition", tostring(label))
  local body = lines and table.concat(lines, "\n") or ""
  check(
    "extract_sync: include guard body is exactly the 4 function lines",
    lines ~= nil and #lines == 4 and body:find("acc", 1, true) ~= nil,
    lines
  )
  check("extract_sync: include guard body excludes #ifndef", not body:find("#ifndef", 1, true))
  check("extract_sync: include guard body excludes #endif", not body:find("#endif", 1, true))
end

-- _symbol_range: hierarchical DocumentSymbol whose range equals ref_range
-- must still be accepted -- DocumentSymbol.range is full-range by spec, so
-- the name-only rejection must not apply here (only to flat
-- SymbolInformation, where location.range really can be name-only).
do
  local symbols = {
    { name = "f", kind = 12, range = range(2, 0, 5, 1), selectionRange = range(2, 11, 2, 12) },
  }
  local ref = range(2, 0, 5, 1)
  local r, label = resolver._symbol_range(symbols, ref, "f")
  check(
    "hierarchical: range equal to ref_range is accepted (full-range by spec)",
    r ~= nil and r.start.line == 2 and r["end"].line == 5,
    r
  )
  check("hierarchical: equal-range symbol still labeled function_definition", label == "function_definition", label)
end

-- _symbol_range: flat SymbolInformation whose location.uri differs from the
-- requested document must be ignored.
do
  local flat = {
    { name = "f", kind = 12, location = { uri = "file:///elsewhere.c", range = range(6, 0, 9, 1) } },
  }
  local r = resolver._symbol_range(flat, range(6, 11, 6, 12), "f", "file:///x.c")
  check("flat: cross-file uri is rejected", r == nil, r)
end

-- _symbol_range: vim.NIL (JSON null) children must not throw.
do
  local symbols = {
    { name = "f", kind = 12, range = range(0, 0, 2, 1), selectionRange = range(0, 4, 0, 5), children = vim.NIL },
  }
  local ok, r = pcall(resolver._symbol_range, symbols, range(1, 0, 1, 1), "f")
  check("_symbol_range: vim.NIL children do not error", ok, r)
  check(
    "_symbol_range: vim.NIL children -> range still returned",
    ok and r ~= nil and r.start.line == 0 and r["end"].line == 2,
    r
  )
end

print("")
print(fails == 0 and "ALL RESOLVER TESTS PASSED" or (fails .. " FAILURE(S)"))
