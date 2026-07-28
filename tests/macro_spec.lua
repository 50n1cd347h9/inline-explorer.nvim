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
  -- A plain function-signature hover has no "Expands to" -> not a macro.
  local sig = "### `foo`\n```c\nint foo(int a)\n```"
  check("function-signature hover -> nil (not spliced as a macro)", macro._expansion_lines(sig) == nil)
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

-- _pick_expand_action: choose clangd's "Expand macro" tweak from a codeAction
-- response, in both shapes the protocol allows.
do
  local as_code_action = {
    { title = "Inline function", kind = "refactor.inline", command = { command = "clangd.applyTweak", arguments = { { tweakID = "InlineFunction" } } } },
    { title = "Expand macro READ_ONCE", kind = "refactor", command = { command = "clangd.applyTweak", arguments = { { tweakID = "ExpandMacro" } } } },
  }
  local cmd = macro._pick_expand_action(as_code_action)
  check("pick: CodeAction shape -> inner command", cmd ~= nil and cmd.command == "clangd.applyTweak", cmd and vim.inspect(cmd))
  check("pick: picks the Expand macro action, not Inline", cmd ~= nil and cmd.arguments[1].tweakID == "ExpandMacro", cmd and vim.inspect(cmd))

  local as_command = {
    { title = "Expand macro FOO", command = "clangd.applyTweak", arguments = { { tweakID = "ExpandMacro" } } },
  }
  local cmd2 = macro._pick_expand_action(as_command)
  check("pick: bare Command shape accepted", cmd2 ~= nil and cmd2.command == "clangd.applyTweak", cmd2 and vim.inspect(cmd2))

  check("pick: no expand action -> nil", macro._pick_expand_action({
    { title = "Add include", kind = "quickfix" },
  }) == nil)
  check("pick: garbage input tolerated", macro._pick_expand_action({ 42, "x", {} }) == nil)
  check("pick: nil input tolerated", macro._pick_expand_action(nil) == nil)
end

-- _edit_lines: extract the expansion text from the applyEdit a tweak sends.
do
  local uri = "file:///src/x.c"
  local range = { start = { line = 3, character = 8 }, ["end"] = { line = 3, character = 12 } }

  local changes_shape = { changes = { [uri] = { { range = range, newText = "(0x3U << 0)" } } } }
  check("edit: changes shape -> lines", table.concat(macro._edit_lines(changes_shape, uri) or {}, "\n") == "(0x3U << 0)")

  local doc_changes_shape = {
    documentChanges = {
      { textDocument = { uri = "file:///other.c", version = 1 }, edits = { { range = range, newText = "WRONG" } } },
      { textDocument = { uri = uri, version = 1 }, edits = { { range = range, newText = "({\n    do { } while (0);\n    v;\n})" } } },
    },
  }
  local lines = macro._edit_lines(doc_changes_shape, uri)
  check("edit: documentChanges shape, uri-matched", lines ~= nil and lines[1] == "({" and lines[#lines] == "})", lines and vim.inspect(lines))

  check("edit: wrong uri -> nil", macro._edit_lines(changes_shape, "file:///nope.c") == nil)
  check("edit: empty newText -> nil", macro._edit_lines({ changes = { [uri] = { { range = range, newText = "" } } } }, uri) == nil)
  check("edit: nil input tolerated", macro._edit_lines(nil, uri) == nil)
end

-- _edit_matches: does a WorkspaceEdit belong to OUR tweak (exactly one document,
-- a range covering the fetch position) or is it a foreign edit to delegate?
do
  local uri = "file:///src/x.c"
  local pos = { line = 3, character = 10 }
  local inr = { start = { line = 3, character = 8 }, ["end"] = { line = 3, character = 12 } }
  local outr = { start = { line = 9, character = 0 }, ["end"] = { line = 9, character = 4 } }

  check("matches: single-doc changes, range covers pos", macro._edit_matches({ changes = { [uri] = { { range = inr, newText = "X" } } } }, uri, pos) == true)
  check("matches: range does not cover pos -> false", macro._edit_matches({ changes = { [uri] = { { range = outr, newText = "X" } } } }, uri, pos) == false)
  check("matches: two documents in changes -> false", macro._edit_matches({
    changes = { [uri] = { { range = inr, newText = "X" } }, ["file:///other.c"] = { { range = inr, newText = "Y" } } },
  }, uri, pos) == false)
  check("matches: documentChanges all same uri, covers pos", macro._edit_matches({
    documentChanges = { { textDocument = { uri = uri, version = 1 }, edits = { { range = inr, newText = "X" } } } },
  }, uri, pos) == true)
  check("matches: documentChanges with a foreign uri -> false", macro._edit_matches({
    documentChanges = {
      { textDocument = { uri = uri, version = 1 }, edits = { { range = inr, newText = "X" } } },
      { textDocument = { uri = "file:///other.c", version = 1 }, edits = { { range = inr, newText = "Y" } } },
    },
  }, uri, pos) == false)
  check("matches: nil edit -> false", macro._edit_matches(nil, uri, pos) == false)
end

-- The persistent applyEdit interceptor: consume for the active fetch, swallow
-- during the post-fetch grace window, delegate everything else.
do
  local uri = "file:///src/x.c"
  local pos = { line = 3, character = 10 }
  local inr = { start = { line = 3, character = 8 }, ["end"] = { line = 3, character = 12 } }
  local mine = { changes = { [uri] = { { range = inr, newText = "(0x3U << 0)" } } } }
  local foreign = { changes = { ["file:///other.c"] = { { range = inr, newText = "nope" } } } }

  local client = { id = 1, handlers = {} }
  macro._install_interceptor(client)
  local h = client.handlers["workspace/applyEdit"]
  check("interceptor: installed on the client", type(h) == "function")
  macro._install_interceptor(client)
  check("interceptor: install is idempotent", client.handlers["workspace/applyEdit"] == h)

  -- Stub the global fallback so delegation is observable. Restored below.
  local orig_global = vim.lsp.handlers["workspace/applyEdit"]
  local delegated = 0
  vim.lsp.handlers["workspace/applyEdit"] = function()
    delegated = delegated + 1
    return { applied = false }
  end
  local ok, err = pcall(function()
    -- (a) active fetch consumes the matching edit exactly once.
    local got, calls = nil, 0
    macro._pending[1] = { uri = uri, pos = pos, on_edit = function(e)
      calls = calls + 1
      got = e
    end }
    local r = h(nil, { edit = mine })
    check("interceptor: active fetch consumes matching edit", calls == 1 and got == mine)
    check("interceptor: consumed edit answers applied=true", type(r) == "table" and r.applied == true)
    check("interceptor: pending cleared after consume", macro._pending[1] == nil)
    check("interceptor: consume did not delegate", delegated == 0)

    -- (b) tombstone swallows a late edit -- it must NOT reach the real handler.
    macro._pending[1] = { uri = uri, pos = pos, on_edit = nil, expires = vim.uv.now() + 10000 }
    local r2 = h(nil, { edit = mine })
    check("interceptor: late edit swallowed by tombstone", type(r2) == "table" and r2.applied == true)
    check("interceptor: swallowed edit never hits the real file", delegated == 0)

    -- (c) nothing pending -> straight delegation.
    macro._pending[1] = nil
    h(nil, { edit = mine })
    check("interceptor: no pending -> delegates", delegated == 1)

    -- (d) a foreign edit mid-fetch still reaches the original handler, and the
    -- in-flight fetch keeps its claim.
    local p = { uri = uri, pos = pos, on_edit = function()
      check("interceptor: foreign edit must not be consumed", false)
    end }
    macro._pending[1] = p
    h(nil, { edit = foreign })
    check("interceptor: foreign edit delegated mid-fetch", delegated == 2)
    check("interceptor: foreign edit leaves pending intact", macro._pending[1] == p)
    macro._pending[1] = nil
  end)
  vim.lsp.handlers["workspace/applyEdit"] = orig_global
  check("interceptor: test body ran without error", ok, tostring(err))
end

print("")
print(fails == 0 and "ALL MACRO TESTS PASSED" or (fails .. " FAILURE(S)"))
