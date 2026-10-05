-- Regression tests pinning the real-source harness's dead-branch detector
-- and its failure-reporting paths (tests/lib/real_source.lua), independent
-- of the ~4-minute zlib/cJSON clones the two full specs drive. Each case
-- builds a tiny synthetic local git repo and runs it through the same
-- public `real.run()` entry point those specs use -- an end-to-end
-- exercise of the harness through its real interface, not a white-box call
-- into its (unexported) locals.
--
--   nvim --headless --clean -u NONE -c "luafile tests/real_source_lib_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local H = require("tests.lib.harness")
local real = require("tests.lib.real_source")

local check = H.check

-- One-commit local git repo from a list of source lines.
local function make_synth_repo(lines)
  local src = vim.fn.tempname()
  vim.fn.mkdir(src, "p")
  vim.fn.writefile(lines, src .. "/main.c")
  vim.fn.system({
    "bash",
    "-lc",
    "cd "
      .. vim.fn.shellescape(src)
      .. " && git init -q && git add main.c"
      .. " && git -c user.email=t@t.example -c user.name=t commit -q -m synth",
  })
  assert(vim.v.shell_error == 0, "failed to init synthetic git repo")
  return src
end

-- Runs real.run(cfg) with print() intercepted, returning the captured lines
-- (still echoed to the real print, same as an uncaptured run would show)
-- plus whether it errored.
local function run_captured(cfg)
  local captured = {}
  local orig_print = _G.print
  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring(select(i, ...))
    end
    local line = table.concat(parts, "\t")
    captured[#captured + 1] = line
    orig_print(line)
  end
  local run_ok, run_err = pcall(real.run, cfg)
  _G.print = orig_print
  return captured, run_ok, run_err
end

local function summary_line(captured, name)
  for _, l in ipairs(captured) do
    if l:match("^real " .. name:gsub("%p", "%%%1") .. ":") then
      return l
    end
  end
  return nil
end

if vim.fn.executable("git") == 0 or vim.fn.executable("gcc") == 0 then
  print("SKIP: git or gcc not available")
else
  -- ======================================================================
  -- Finding 1 (HIGH): the detector is blind to SMALL dead regions.
  --
  -- Repo shape: a single, unambiguous definition `d`, called once from a
  -- dead site guarded by a *sub-6-line* `#ifdef` (the region gcc
  -- blank-pads rather than resyncs via linemarker -- see
  -- surviving_lines's doc comment in real_source.lua; confirmed by hand
  -- with `gcc -E | tail | cat -A` while writing this test, which showed
  -- the #ifdef/call/#endif trio turn into three blank output lines with
  -- no linemarker in between) and once from a live, always-active site.
  -- `main` always returns 0 regardless of `d`'s result, so the baseline
  -- build+run succeeds whether or not the inliner later rewrites either
  -- call site.
  do
    local repo = make_synth_repo({
      "static int d(int x) { return x + 1; }",
      "",
      "int main(void) {",
      "#ifdef NEVER_DEFINED_FLAG",
      "  d(5);",
      "#endif",
      "  d(1);",
      "  return 0;",
      "}",
    })
    local captured, run_ok, run_err = run_captured({
      name = "synth-dead-branch",
      url = repo,
      requires = { "main.c" },
      sources = { "main.c" },
      verify = function(dir)
        return real.sh("gcc main.c -o ie_check_1 && ./ie_check_1", dir)
      end,
    })
    check("F1: real.run completed without erroring", run_ok, run_err)
    local summary = summary_line(captured, "synth-dead-branch")
    check("F1: summary line was printed", summary ~= nil, table.concat(captured, "\n"))
    if summary then
      -- Before the fix this read dead-branch=0, engine-accepted=2,
      -- built+passed=2 -- exactly the pre-9d7a5c6 behaviour the reviewer
      -- reproduced (see the fix commit's report for the observed
      -- before/after of this exact test).
      check(
        "F1: dead-branch counts the one guarded, never-active call site",
        summary:match("dead%-branch=1%f[%D]") ~= nil,
        summary
      )
      check(
        "F1: engine-accepted counts only the one live call site",
        summary:match("engine%-accepted=1%f[%D]") ~= nil,
        summary
      )
      check(
        "F1: built+passed counts only the one live call site",
        summary:match("built%+passed=1%f[%D]") ~= nil,
        summary
      )
      check("F1: sites=2 (one dead, one live; neither ambiguous)", summary:match("sites=2%f[%D]") ~= nil, summary)
    end
  end

  -- ======================================================================
  -- Finding 3 (MEDIUM): `#line` over-declining.
  --
  -- A literal `#line N "otherfile.c"` retargets cpp's file attribution for
  -- everything after it without moving a single physical line of main.c.
  -- Left unguarded, the one non-ambiguous call after it would fail the
  -- `cur_file == rel` check and get tagged `dead` -- a live call silently
  -- dropped from the failure-detecting pool. The fix instead makes the
  -- whole file's dead-branch check unavailable (surviving == nil), so the
  -- call falls through as ordinary/attempted, and the file is named in
  -- `unverifiable-files`, not silently misclassified.
  do
    local repo = make_synth_repo({
      "static int d(int x) { return x + 3; }",
      "",
      "int main(void) {",
      '#line 500 "otherfile.c"',
      "  d(3);",
      "  return 0;",
      "}",
    })
    local captured, run_ok, run_err = run_captured({
      name = "synth-line-directive",
      url = repo,
      requires = { "main.c" },
      sources = { "main.c" },
      verify = function(dir)
        return real.sh("gcc main.c -o ie_check_3 && ./ie_check_3", dir)
      end,
    })
    check("F3: real.run completed without erroring", run_ok, run_err)
    local summary = summary_line(captured, "synth-line-directive")
    check("F3: summary line was printed", summary ~= nil, table.concat(captured, "\n"))
    if summary then
      check(
        "F3: the #line'd file is not silently miscounted as dead-branch",
        summary:match("dead%-branch=0%f[%D]") ~= nil,
        summary
      )
      check(
        "F3: the one live call is still attempted (engine-accepted=1)",
        summary:match("engine%-accepted=1%f[%D]") ~= nil,
        summary
      )
      check(
        "F3: unverifiable-files=1 -- the #line makes the file's check untrustworthy, and says so",
        summary:match("unverifiable%-files=1%f[%D]") ~= nil,
        summary
      )
    end
    local named = false
    for _, l in ipairs(captured) do
      if l:match("^  %* main%.c %->.*#line") then
        named = true
      end
    end
    check(
      "F3: the unverifiable file is named with the #line reason, not just counted",
      named,
      table.concat(captured, "\n")
    )
  end

  -- ======================================================================
  -- Finding 4 (MEDIUM): the fallback fails open and reports too quietly.
  --
  -- Forces gcc -E itself (not the real build) to fail, via a cpp_flags
  -- value the dead-branch check's own preprocessor run uses but the
  -- `verify` build below never passes -- so the baseline build and the
  -- post-transform builds all still succeed; only the dead-branch check's
  -- `gcc -E` invocation dies. Confirms the fallback is (a) still fail-open
  -- (the file's one call site is still attempted, not wrongly dropped) and
  -- (b) now visible in the summary line itself, not just an easy-to-miss
  -- per-file note.
  do
    local repo = make_synth_repo({
      "static int d(int x) { return x + 4; }",
      "",
      "int main(void) {",
      "  d(4);",
      "  return 0;",
      "}",
    })
    local captured, run_ok, run_err = run_captured({
      name = "synth-cpp-fail",
      url = repo,
      requires = { "main.c" },
      sources = { "main.c" },
      -- Only the dead-branch check's own `gcc -E %cpp_flags% main.c` uses
      -- this; the verify build below does not, so it is unaffected.
      cpp_flags = "-include /this/path/does/not/exist_ie_test.h",
      verify = function(dir)
        return real.sh("gcc main.c -o ie_check_4 && ./ie_check_4", dir)
      end,
    })
    check("F4: real.run completed without erroring even though gcc -E failed", run_ok, run_err)
    local summary = summary_line(captured, "synth-cpp-fail")
    check("F4: summary line was printed", summary ~= nil, table.concat(captured, "\n"))
    if summary then
      check(
        "F4: fails open -- the one call site is still attempted, not dropped",
        summary:match("engine%-accepted=1%f[%D]") ~= nil,
        summary
      )
      check(
        "F4: built+passed=1 -- the fallback did not break a real transform",
        summary:match("built%+passed=1%f[%D]") ~= nil,
        summary
      )
      check(
        "F4: unverifiable-files=1 is IN the summary line monitoring greps `^real %s:` actually match",
        summary:match("unverifiable%-files=1%f[%D]") ~= nil,
        summary
      )
    end
    local named = false
    for _, l in ipairs(captured) do
      if l:match("^  %* main%.c %-> gcc %-E failed") then
        named = true
      end
    end
    check("F4: the unverifiable file is named with the gcc -E reason", named, table.concat(captured, "\n"))
  end

  -- ======================================================================
  -- Finding 5 (HIGH, round-3 review): the blank-content rule misreads a
  -- live call as dead when it is passed as an argument to a different,
  -- ENCLOSING multi-line function-like macro invocation.
  --
  -- Repro is the reviewer's exact shape: `helper(5)` sits entirely on its
  -- own physical line, inside `WRAP(...)`, itself spanning three lines.
  -- gcc -E dumps the whole `WRAP(helper(5))` expansion onto WRAP(`'s
  -- opening line and blank-pads helper(5)'s own line -- confirmed by hand
  -- with `gcc -E`: the opening line reads `int r = (helper(5))` and the
  -- next output line is empty, with no linemarker between them -- so
  -- `surviving_lines` alone reads helper(5)'s line as blank even though
  -- helper is unconditionally live, always-compiled code. `main` computes
  -- `r - 5` so the baseline (and, if the transform is genuinely applied
  -- correctly, the post-transform build too) always exits 0 regardless of
  -- whether this call site is later substituted.
  do
    local repo = make_synth_repo({
      "#define WRAP(x) (x)",
      "static int helper(int a) { return a; }",
      "int main(void) {",
      "    int r = WRAP(",
      "        helper(5)",
      "    );",
      "    return r - 5;",
      "}",
    })
    local captured, run_ok, run_err = run_captured({
      name = "synth-macro-arg-reflow",
      url = repo,
      requires = { "main.c" },
      sources = { "main.c" },
      verify = function(dir)
        return real.sh("gcc main.c -o ie_check_5 && ./ie_check_5", dir)
      end,
    })
    check("F5: real.run completed without erroring", run_ok, run_err)
    local summary = summary_line(captured, "synth-macro-arg-reflow")
    check("F5: summary line was printed", summary ~= nil, table.concat(captured, "\n"))
    if summary then
      -- Before the fix: dead-branch=1, engine-accepted=0 -- the live
      -- helper(5) call silently dropped from the failure-detecting pool.
      check("F5: the live call is NOT tagged dead-branch", summary:match("dead%-branch=0%f[%D]") ~= nil, summary)
      check(
        "F5: the live call is still attempted (engine-accepted=1)",
        summary:match("engine%-accepted=1%f[%D]") ~= nil,
        summary
      )
      check("F5: and it builds + passes (built+passed=1)", summary:match("built%+passed=1%f[%D]") ~= nil, summary)
      check("F5: sites=1 (the one call, neither ambiguous nor dead)", summary:match("sites=1%f[%D]") ~= nil, summary)
      check(
        "F5: the file itself is not marked unverifiable (only the site is flagged)",
        summary:match("unverifiable%-files=0%f[%D]") ~= nil,
        summary
      )
      check(
        "F5: the site-level ambiguity is counted (unverifiable-dead-sites=1)",
        summary:match("unverifiable%-dead%-sites=1%f[%D]") ~= nil,
        summary
      )
    end
    local named = false
    for _, l in ipairs(captured) do
      if l:match("^  %* main%.c:5 helper %-%-") then
        named = true
      end
    end
    check("F5: the overruled site is named (file:line + callee), not just counted", named, table.concat(captured, "\n"))
  end

  -- ======================================================================
  -- Finding 6 (self-caught while verifying Finding 5's fix against real
  -- zlib): `callee_survives_nearby`'s enclosing-statement walk must stop at
  -- a preprocessor-conditional wrapper (`preproc_if`/`preproc_ifdef`/...),
  -- not climb through it.
  --
  -- Repro mirrors zlib's crc32.c braid-combining code exactly: a single-line
  -- statement guarded by a NESTED `#if` (itself nested inside an outer,
  -- active `#if`) directly inside a block. `w(0)` is unconditional; `w(1)`
  -- is guarded by an always-true `#if 1`; `w(2)` is guarded by a nested,
  -- always-false `#if 0`, so only `w(2)`'s own line is blank-padded and
  -- genuinely dead. Without the `preproc_if` stop, `enclosing_span` climbed
  -- from `w(2)`'s statement through BOTH nested `preproc_if` wrappers up to
  -- the enclosing `compound_statement`, making the span cover `w(1)`'s line
  -- too -- and `w(1)`'s survived, non-blank line contains the literal text
  -- "w(1)", which also matches the bare-name search for callee "w". That
  -- false match wrongly overruled `w(2)`'s correct `dead` verdict. This is
  -- exactly the false positive first observed against real zlib: it turned
  -- crc32.c's crc_word/crc_word_big sites (782, 904) from dead-branch back
  -- into unverifiable-dead-sites, undoing two of the real dead-branch counts
  -- c7b2c76 added.
  do
    local repo = make_synth_repo({
      "static int w(int a) { return a; }",
      "int main(void) {",
      "  int crc = w(0);",
      "#if 1",
      "  crc = w(1);",
      "#if 0",
      "  crc = w(2);",
      "#endif",
      "#endif",
      "  return crc - 1;",
      "}",
    })
    local captured, run_ok, run_err = run_captured({
      name = "synth-nested-ifdef-siblings",
      url = repo,
      requires = { "main.c" },
      sources = { "main.c" },
      verify = function(dir)
        return real.sh("gcc main.c -o ie_check_6 && ./ie_check_6", dir)
      end,
    })
    check("F6: real.run completed without erroring", run_ok, run_err)
    local summary = summary_line(captured, "synth-nested-ifdef-siblings")
    check("F6: summary line was printed", summary ~= nil, table.concat(captured, "\n"))
    if summary then
      check("F6: sites=3 (w(0), w(1), w(2); none ambiguous)", summary:match("sites=3%f[%D]") ~= nil, summary)
      check(
        "F6: exactly one call (w(2), the nested-#if-0 one) is dead-branch",
        summary:match("dead%-branch=1%f[%D]") ~= nil,
        summary
      )
      check(
        "F6: the other two (w(0), w(1)) are attempted (engine-accepted=2)",
        summary:match("engine%-accepted=2%f[%D]") ~= nil,
        summary
      )
      check("F6: and both build + pass (built+passed=2)", summary:match("built%+passed=2%f[%D]") ~= nil, summary)
      -- The regression: w(2)'s correct dead verdict must NOT be overruled by
      -- w(1)'s sibling, active call to the same name a few lines away.
      check(
        "F6: w(2)'s dead verdict is NOT overruled (unverifiable-dead-sites=0)",
        summary:match("unverifiable%-dead%-sites=0%f[%D]") ~= nil,
        summary
      )
    end
  end
end

H.finish("REAL SOURCE LIB")
