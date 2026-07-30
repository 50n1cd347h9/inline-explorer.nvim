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
    local a = { uri = uri, pos = pos, on_edit = function(e)
      calls = calls + 1
      got = e
    end }
    macro._pending[1] = { a }
    local r = h(nil, { edit = mine })
    check("interceptor: active fetch consumes matching edit", calls == 1 and got == mine)
    check("interceptor: consumed edit answers applied=true", type(r) == "table" and r.applied == true)
    check("interceptor: consumed claim downgraded to a tombstone", a.on_edit == nil and a.expires ~= nil)
    check("interceptor: consume did not delegate", delegated == 0)

    -- (b) tombstone swallows a late edit -- it must NOT reach the real handler.
    macro._pending[1] = { { uri = uri, pos = pos, on_edit = nil, expires = vim.uv.now() + 3000 } }
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
    macro._pending[1] = { p }
    h(nil, { edit = foreign })
    check("interceptor: foreign edit delegated mid-fetch", delegated == 2)
    check("interceptor: foreign edit leaves the claim intact", macro._pending[1][1] == p and p.on_edit ~= nil)
    macro._pending[1] = nil
  end)
  vim.lsp.handlers["workspace/applyEdit"] = orig_global
  check("interceptor: test body ran without error", ok, tostring(err))
end

-- Claims are per fetch, not per client: overlapping fetches must each keep
-- their own claim (and their own tombstone), or a superseded fetch's late edit
-- ends up delegated into the real buffer.
do
  local uri = "file:///src/x.c"
  local posA, posB = { line = 3, character = 10 }, { line = 7, character = 4 }
  local function edit_at(line, c0, c1)
    return { changes = { [uri] = { { range = { start = { line = line, character = c0 }, ["end"] = { line = line, character = c1 } }, newText = "X" } } } }
  end
  local editA, editB = edit_at(3, 8, 12), edit_at(7, 2, 6)

  local client = { id = 2, handlers = {} }
  macro._install_interceptor(client)
  local h = client.handlers["workspace/applyEdit"]

  local orig_global = vim.lsp.handlers["workspace/applyEdit"]
  local delegated = 0
  vim.lsp.handlers["workspace/applyEdit"] = function()
    delegated = delegated + 1
    return { applied = false }
  end
  local ok, err = pcall(function()
    local callsA, callsB = 0, 0
    local A = { uri = uri, pos = posA, on_edit = function() callsA = callsA + 1 end }
    local B = { uri = uri, pos = posB, on_edit = function() callsB = callsB + 1 end }
    macro._pending[2] = { A, B } -- A is the older fetch, B supersedes it

    -- (1) the older fetch is still answered, and the newer one is untouched.
    h(nil, { edit = editA })
    check("claims: superseded fetch still consumes its own edit", callsA == 1 and callsB == 0)
    check("claims: newer claim untouched and still active", B.on_edit ~= nil)
    check("claims: older claim consumed without delegating", delegated == 0)

    -- (2) consuming leaves a tombstone: a duplicate edit is swallowed, not
    -- delegated, and the callback does not fire twice.
    local r = h(nil, { edit = editA })
    check("claims: duplicate edit swallowed by the consume tombstone", type(r) == "table" and r.applied == true)
    check("claims: duplicate edit did not delegate", delegated == 0)
    check("claims: on_edit not called twice", callsA == 1)

    -- the newer fetch is answered afterwards, as normal.
    h(nil, { edit = editB })
    check("claims: newer fetch consumed after the older one", callsB == 1 and delegated == 0)

    -- (3) an expired tombstone is pruned and its edit delegates again.
    macro._pending[2] = { { uri = uri, pos = posA, on_edit = nil, expires = vim.uv.now() - 1 } }
    h(nil, { edit = editA })
    check("claims: expired tombstone delegates", delegated == 1)
    check("claims: expired tombstone pruned from the list", #macro._pending[2] == 0)
    macro._pending[2] = nil
  end)
  vim.lsp.handlers["workspace/applyEdit"] = orig_global
  check("claims: test body ran without error", ok, tostring(err))
end

-- (4) If another plugin replaces our handler, the next fetch chain-reinstalls
-- on top of it instead of silently losing coverage.
do
  local client = { id = 3, handlers = {} }
  macro._install_interceptor(client)
  local first = client.handlers["workspace/applyEdit"]

  local foreign_calls = 0
  client.handlers["workspace/applyEdit"] = function()
    foreign_calls = foreign_calls + 1
    return { applied = true }
  end
  macro._install_interceptor(client) -- next fetch's install step
  local h = client.handlers["workspace/applyEdit"]
  check("reinstall: a replaced handler is re-wrapped", h ~= first and type(h) == "function")

  h(nil, { edit = { changes = { ["file:///other.c"] = { { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } }, newText = "y" } } } } })
  check("reinstall: the foreign handler is chained as prev", foreign_calls == 1)

  macro._install_interceptor(client)
  check("reinstall: no-op while our handler is still installed", client.handlers["workspace/applyEdit"] == h)
end

-- Redundant paren collapse: kernel-style expansions arrive as `(({ ... }))`
-- (the macro definition's own defensive parens around an rcu-style statement
-- expression); the splice must not keep the noise, and must not add a third
-- pair on top.
do
  local simplify = require("inline-explorer.simplify")
  check("simplify: ((X)) collapses", simplify.parens("((x + 1))") == "(x + 1)")
  check("simplify: cast parens preserved", simplify.parens("((int)(x))") == "((int)(x))")
  check("simplify: unparsable text untouched", simplify.parens("((") == "((")

  local src = "int f(void) { return ekp != DEREF(key); }"
  local col = src:find("DEREF") - 1
  local new = macro.replace_in_src(src, 0, col, { "(({ int v = 1; v; }))" })
  check("kernel-shaped expansion loses the redundant nest", new:find("!= ({ int v = 1; v; });", 1, true) ~= nil, new)
end

-- _edit_lines trims blank edge lines from the applyEdit's newText.
do
  local uri = "file:///src/x.c"
  local range14 = { start = { line = 1, character = 0 }, ["end"] = { line = 4, character = 0 } }
  local padded = { changes = { [uri] = { { range = range14, newText = "\n\n(v + 1)\n\n" } } } }
  local lines = macro._edit_lines(padded, uri)
  check("edit: blank edge lines trimmed", lines ~= nil and #lines == 1 and lines[1] == "(v + 1)", lines and vim.inspect(lines))
end

-- Housekeeping: claims and interceptor bookkeeping for dead client ids are
-- pruned on the next fetch.
do
  macro._pending[99991] = { { uri = "file:///x.c", pos = { line = 0, character = 0 } } }
  macro._pending[99992] = {}
  macro._prune_dead_clients()
  check("dead-client claims pruned", macro._pending[99991] == nil and macro._pending[99992] == nil)
end

-- A leading space on the expansion's first line must not defeat the
-- already-grouped check. clangd 21 emits ExpandMacro text whose first line
-- can carry one, the check was anchored (`^%b()$`), so a `({...})` arrived
-- "not grouped", got wrapped again, and the reader saw `( ({ ... }))` --
-- the exact nest simplify exists to remove, reintroduced downstream of
-- simplify because the wrap happened AFTER it ran.
do
  local src = "void f(void) { fa->len = READ_ONCE(sqe->len); }"
  local col = src:find("READ_ONCE") - 1
  local out = macro.replace_in_src(src, 0, col,
    { " ({ do { } while (0); (*(&x)); })" })
  check("splice: leading space does not cause a second paren wrap",
    out:find("( ({", 1, true) == nil and out:find("(({", 1, true) == nil, out)
  check("splice: the statement expression itself survives",
    out:find("({ do { } while (0);", 1, true) ~= nil, out)
end

-- And the class, not just the instance: even when a wrap IS added for
-- precedence, wrapping an already-parenthesized expression must collapse
-- to a single pair.
do
  local src = "void f(void) { y = M(a) * 2; }"
  local col = src:find("M%(") - 1
  local out = macro.replace_in_src(src, 0, col, { "(a + 1)" })
  check("splice: wrapping a parenthesized expansion yields ONE pair",
    out:find("(a + 1) * 2", 1, true) ~= nil and out:find("((a + 1))", 1, true) == nil, out)
end

-- The macro splice must ride csrc's parse cache. macro.lua carried a
-- private pre-cache copy of parse(), so the SAME keypress that parsed the
-- caller cached via substitute.call_name_at re-parsed it uncached here --
-- measured at 33-42ms on a 13k-line kernel file, ~0ms cached. Counted, not
-- timed: a warm cache plus one replace_in_src must add zero parser
-- constructions for the same source text.
do
  local C = require("inline-explorer.csrc")
  local src = "void f(void) { x = M(1); }"
  C._parse_cache = {}
  C.parse(src) -- warm
  local real = vim.treesitter.get_string_parser
  local made = 0
  vim.treesitter.get_string_parser = function(text, ...)
    -- simplify legitimately parses its own tiny wrapper fragments; the
    -- finding was about re-parsing the CALLER, so count only that text.
    if text == src then
      made = made + 1
    end
    return real(text, ...)
  end
  local col = src:find("M%(") - 1
  macro.replace_in_src(src, 0, col, { "(1 + 0)" })
  vim.treesitter.get_string_parser = real
  check("splice: rides the shared parse cache (zero caller re-parses for warm text)",
    made == 0, ("caller parses=%d"):format(made))
end

print("")
print(fails == 0 and "ALL MACRO TESTS PASSED" or (fails .. " FAILURE(S)"))
