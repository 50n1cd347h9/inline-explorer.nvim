-- Real-source compile-correctness test on zlib: a different flavour of C
-- from cJSON -- state machines, goto-based error handling, bit manipulation,
-- and functions declared through zlib's own `local` (static) macro.
--
-- The library's own translation units are rewritten because those are what
-- `make test` actually rebuilds -- but rebuilding is not the same as
-- exercising: a call site whose own line never survives this build's
-- preprocessing (no #ifdef branch it lives in is ever active) gets spliced
-- and handed to gcc like any other, and gcc trivially "passes" it without
-- ever having compiled it. Measured surface at the pinned v1.3.1 tag (see
-- `cfg.ref` below): 238 in-file call sites, of which the harness declines 28
-- as genuinely ambiguous (a name with more than one definition, or one that
-- is also a macro -- see real_source.lua's `enumerate`) and a further 33 as
-- dead-branch (a single, unambiguous definition, but the call site's own
-- line does not survive `gcc -E` in this build -- e.g. zlib's
-- `braid`/`write_table` family, only reachable under
-- `#ifdef DYNAMIC_CRC_TABLE`/`MAKECRCH`, which this harness's `./configure`
-- never defines; also crc32.c's `crc_word`/`crc_word_big` braid-combining
-- calls gated by an always-false `#if N > 5` in this build). That leaves 177
-- sites the engine actually compiles and runs. Of those, 169 build and pass;
-- the remaining 8 are engine defects (not harness artifacts; see
-- `known_failures` below, which pins this exact set), including gzwrite.c's
-- `gzvprintf`, whose va_list argument gets an invalid copy initializer --
-- code the harness only reaches once the skip rule stops declining every
-- call whose callee merely sits inside a preprocessor conditional.
--
-- (These counts moved slightly -- 239/23/34/182/174 before this spec's clone
-- was pinned to v1.3.1 -- because the previously unpinned clone had drifted
-- onto zlib's development history past that tag; see `cfg.ref` below. The
-- failing set itself did not change: same 8 (file, callee) pairs.)
--
-- Oracle limitation, verified experimentally: zlib's `make test` is a
-- ROUND-TRIP self-test (compress then decompress and compare). An asymmetric
-- break is caught loudly -- XOR-ing one byte of uncompress()'s output makes
-- it exit 2 with "*** zlib test FAILED ***" -- but a SYMMETRIC break is not:
-- making adler32() return a constant leaves both the writer and the reader
-- agreeing on the same wrong checksum, and the suite passes. Rewriting one
-- file at a time is normally asymmetric, but adler32.c / crc32.c / zutil.c
-- are used by both directions, so detection there rests on the compile step
-- more than on the run. `cfg.syntax_check` below adds a second, deterministic
-- gate (`gcc -fsyntax-only`) that runs on every accepted transform ahead of
-- `make test`: it cannot see a wrong VALUE (adler32_z's defect, below), but
-- for the other 7 residual failures it gives the same red verdict `make
-- test` would anyway (verified below), sooner and with a single-file
-- diagnostic instead of a full rebuild's.
--
-- The clone is pinned to the v1.3.1 tag (`cfg.ref`), not zlib's default
-- branch: an upstream commit changing this source text would silently move
-- every number above, and the exact-set failure pin below, for a reason
-- that has nothing to do with this plugin's engine.
--
-- The 8 remaining failures are pinned as an EXACT set (`cfg.known_failures`,
-- below) rather than left as a bare count: real_source.lua's `M.run` fails
-- the run if an unlisted site fails (a regression) OR if a listed site
-- stops failing (fixed without the list being updated -- see that entry's
-- own doc comment for why a one-directional suppression list is not
-- enough). All three engine defects zlib originally found (E1, E4, E5; see
-- docs/superpowers/plans/2026-07-29-engine-fixes-from-zlib.md) are fixed;
-- what is pinned here is not a suppressed bug but a documented engine
-- LIMIT -- a macro that hardcodes an identifier (E2), a callee that reaches
-- a helper or macro defined later in the file (E3), and a va_list that
-- cannot be copy-initialised (E6).
--
-- Requires: git + network + gcc + make. Skips cleanly if any is missing.
--
--   nvim --headless --clean -u NONE -c "luafile tests/real_zlib_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local real = require("tests.lib.real_source")

if vim.fn.executable("make") == 0 then
  print("SKIP: make not available")
  return
end

real.run({
  name = "zlib",
  url = "https://github.com/madler/zlib.git",
  -- Pinned to a tag, not whatever the default branch's HEAD happens to be:
  -- an upstream release would otherwise change the source text this spec
  -- measures against, and both the summary counts above and the
  -- `known_failures` exact-set pin below would drift for a reason that has
  -- nothing to do with the engine.
  ref = "v1.3.1",
  requires = { "deflate.c", "inflate.c", "configure", "Makefile.in" },
  sources = {
    "adler32.c",
    "compress.c",
    "crc32.c",
    "deflate.c",
    "gzlib.c",
    "gzread.c",
    "gzwrite.c",
    "inflate.c",
    "inftrees.c",
    "trees.c",
    "uncompr.c",
  },
  setup = function(dir)
    return real.sh("./configure > /dev/null 2>&1", dir)
  end,
  -- Resolved after `setup` runs `./configure`, from the Makefile it
  -- actually generated -- not a guessed `-I.` substitute. `make test`
  -- builds every one of these sources with `$(CC) $(CFLAGS) $(ZINC) -c
  -- ...` (see the `*.o:` rules), so those are the exact two variables the
  -- dead-branch check's own `gcc -E` run needs to match the real build:
  -- CFLAGS carries zlib's `-D_LARGEFILE64_SOURCE=1`/`-DHAVE_HIDDEN`
  -- (feature macros an #ifdef branch's activeness can depend on), and
  -- ZINC is normally empty but is the hook a real `./configure --zprefix`
  -- or similar would put something in.
  cpp_flags = function(dir)
    -- A `[=[ ]=]` long bracket, not `[[ ]]`: the sed script's own
    -- `[:space:]]` contains a literal `]]`, which would otherwise close a
    -- level-0 Lua long string early.
    local ok, out = real.sh(
      [=[sed -n 's/^CFLAGS[[:space:]]*=[[:space:]]*//p;s/^ZINC[[:space:]]*=[[:space:]]*//p' Makefile]=],
      dir
    )
    if not ok then
      return ""
    end
    return out:gsub("\n", " ")
  end,
  verify = function(dir)
    -- `make test` propagates failure: its teststatic recipe ends in `false`
    -- when the round trip does not reproduce the input.
    return real.sh("make -s test 2>&1", dir)
  end,
  -- A cheap, deterministic gate that runs BEFORE `verify` on every accepted
  -- transform: one `gcc -fsyntax-only` pass over the rewritten translation
  -- unit, instead of a full rebuild plus zlib's own (round-trip) test
  -- binary. `make test`'s round trip cannot see a SYMMETRIC break (see
  -- `oracle_note` below); a syntax check has no such blind spot for an
  -- identifier-resolution failure -- it either resolves every identifier or
  -- it does not, deterministically, every time.
  -- `-Werror=implicit-function-declaration` turns "callee calls a helper
  -- (or macro) defined later in the file" -- this project's dominant
  -- failure shape -- from a warning into an error; `-Werror=implicit-int`
  -- does the same for a return type gcc would otherwise default to `int`
  -- and warn about.
  --
  -- Measured, not assumed: disabling this gate entirely and rerunning the
  -- full spec against a real clone reproduces the identical
  -- 238/28/33/177/169 counts and the identical 8 failures via `make test`'s
  -- own build -- zlib's default CFLAGS, no `-Werror` anywhere. All 7
  -- non-adler32_z failures are hard, deterministic `error:` (a conflicting
  -- or undeclared identifier) or linker (`undefined reference`) failures
  -- under the plain build too -- none of them depend on what an
  -- uninitialised stack slot happens to hold. This gate's demonstrated
  -- value is speed (`-fsyntax-only` over one translation unit vs. a full
  -- rebuild plus round-trip test run) and a cleaner, single-file diagnostic
  -- when a failure is pinned -- not catching a break the plain build would
  -- otherwise miss. (The two paths never run side by side in an ordinary
  -- run -- `real_source.lua` skips `verify` once `syntax_check` has already
  -- failed -- so this claim rests on that separate, gate-disabled run, not
  -- on anything the ordinary pinned run itself demonstrates.) adler32_z's
  -- defect is a wrong VALUE from a hijacked identifier, not an unresolved
  -- one, and so is invisible to a syntax check either way -- only
  -- `verify`'s round trip catches that one, and only because
  -- adler32/crc32/zutil happen to run in both compress and decompress.
  syntax_check = function(dir, rel)
    return real.sh(
      ("gcc -fsyntax-only -I. -Werror=implicit-function-declaration -Werror=implicit-int %s"):format(rel),
      dir
    )
  end,
  oracle_note = "zlib's tests are a round trip, so a symmetric break (both directions wrong the same way) is invisible; asymmetric breaks exit non-zero.",
  -- The residual failures after the three engine fixes (E1/E5/E4, see
  -- docs/superpowers/plans/2026-07-29-engine-fixes-from-zlib.md) are pinned
  -- as an EXACT set, checked in both directions by real_source.lua's
  -- `M.run`: an unlisted failure is a regression, and a listed entry that
  -- stops failing means someone fixed it without updating this list --
  -- both are treated as a hard failure so this list cannot silently rot.
  -- `occurrence` is the Nth time (in file order) a transform for that
  -- exact callee name was accepted in that file -- needed because the
  -- same name can be called, and substituted, from more than one site,
  -- with only some of those sites failing (deflateEnd is called both
  -- before and after its own callee deflateStateCheck's definition; only
  -- the earlier call is a forward reference). All eight callees below
  -- happen to have exactly one attempted call site each, so occurrence is
  -- 1 throughout, but the field still has to be there for the tuple to be
  -- unambiguous. Each entry's `why` names the underlying engine limit
  -- (verified by reading zlib v1.3.1's source directly, not guessed at):
  --
  --   E2 -- a macro's own BODY hardcodes an identifier instead of routing
  --   it through the macro's parameter list, so renaming the identifier
  --   for collision safety silently changes which variable the expanded
  --   macro touches.
  --
  --   E3 -- the callee being spliced into an EARLIER call site calls a
  --   helper (function or object/function-like macro) whose own
  --   definition sits LATER in the same file -- true at the helper's
  --   original position, but not at the earlier position the splice
  --   lands the callee's body at.
  --
  --   E6 -- a `va_list` parameter cannot be given a copy initializer
  --   (`va_list v = other_va_list;` is not valid C; only `va_copy` is).
  --
  -- `fingerprint` (added alongside `why`) is what `real_source.lua`'s pin
  -- check actually compares against this run's captured failure text --
  -- `why` is prose for a human reading a mismatch print, never matched
  -- against anything; `fingerprint` is the substring that must survive in
  -- `f[5]` (the FULL, untruncated capture of gcc's or make test's own
  -- output -- see real_source.lua's own comment on why matching happens
  -- against the full text and not the `tail(...)`-truncated `f[3]` kept
  -- only for the human-readable print) for a match at this site to count
  -- as the SAME failure, not merely a failure at the same (file, callee,
  -- occurrence) key. Each was chosen for two properties: it survives
  -- irrelevant churn (a line number moving, a gcc version rewording a
  -- diagnostic's prose), and it is specific enough that a genuinely
  -- different break at the same site would not produce it. For the six E3
  -- forward-reference sites and gzvprintf, that means the undefined/
  -- conflicting identifier's own name (quoted the way gcc quotes it, so a
  -- substring match cannot land on an unrelated word), not the surrounding
  -- sentence -- gcc's exact wording has changed across major versions, but
  -- the identifier a forward reference names has not. Each such fingerprint
  -- was picked to be one of the identifiers `why` itself names as the
  -- forward reference at that site (verified against the actual captured
  -- `-fsyntax-only` diagnostic, not merely grepped out of it), so a reader
  -- comparing `why` to `fingerprint` never finds the latter naming
  -- something the former never mentions.
  --
  -- adler32_z's defect produces no compiler diagnostic at all (see its own
  -- `why`), so its fingerprint is a RUNTIME message instead: "large inflate
  -- error: -3" is printed by `test/example.c`'s `CHECK_ERR` macro whenever
  -- `inflate()` returns anything other than `Z_OK` from `test_large_inflate`
  -- -- here, that is `Z_DATA_ERROR` (-3) because the stream's trailing
  -- checksum disagreed with what inflate recomputed while decompressing.
  -- Unlike the other seven fingerprints, this is NOT a mechanistic marker of
  -- THIS defect: `CHECK_ERR`'s message is the same generic "%s error: %d"
  -- for every failure mode `inflate()` has, and inflate.c sets Z_DATA_ERROR
  -- for several unrelated causes too (a bad distance code, a distance too
  -- far back, an invalid stored block length -- see inflate.c's other
  -- `Z_DATA_ERROR` sites) besides a checksum mismatch (inflate.c:1198,
  -- "incorrect data check"). That more specific message is never surfaced
  -- here: `strm->msg` is set internally but `CHECK_ERR` never prints it, so
  -- "large inflate error: -3" is genuinely the tightest fingerprint this
  -- test binary's own output offers for a checksum-corrupting defect in
  -- this transform. A future, unrelated defect anywhere in the
  -- adler32/crc32/zutil compress-and-decompress path that also lands on
  -- Z_DATA_ERROR at this exact call would print the byte-for-byte identical
  -- fingerprint -- weaker evidence than the other seven, which are each
  -- tied to one specific identifier gcc itself names. Treat a PIN OK on
  -- this entry as "still fails with -3 here", not as proof the E2 macro
  -- hardcoding is still the cause.
  known_failures = {
    {
      file = "adler32.c",
      callee = "adler32_z",
      occurrence = 1,
      why = "E2: DO1/DO2/DO4/DO8/DO16 (adler32.c:14-17) hardcode the "
        .. "identifiers `adler`/`sum2` in their own macro bodies rather than "
        .. "taking them as parameters (only `buf` is parameterised); "
        .. "collision-renaming adler32_z's own `adler` parameter for the "
        .. "splice leaves the macro invocations reading the wrong variable, "
        .. "so the checksum comes out wrong -- a value defect, not a syntax "
        .. "one, so `syntax_check` above cannot see it; only make test's "
        .. "round trip catches it, and only because adler32 runs on both "
        .. "the compress and decompress side.",
      fingerprint = "large inflate error: -3",
    },
    {
      file = "deflate.c",
      callee = "deflateEnd",
      occurrence = 1,
      why = "E3: this is the call inside deflateInit2_ (line 503), which "
        .. "sits BEFORE deflateStateCheck's own definition (line 529) that "
        .. "deflateEnd's body calls; the second call to deflateEnd, inside "
        .. "deflateCopy (line 1313, after line 529), is unaffected and "
        .. "builds and passes.",
      fingerprint = "'deflateStateCheck'",
    },
    {
      file = "deflate.c",
      callee = "deflateReset",
      occurrence = 1,
      why = "E3: deflateReset's body calls lm_init, defined at line 673; "
        .. "the call being substituted here is inside deflateInit2_ at "
        .. "line 523, before that definition.",
      fingerprint = "'lm_init'",
    },
    {
      file = "deflate.c",
      callee = "deflate",
      occurrence = 1,
      why = "E3: deflate's body calls flush_pending (defined line 915), "
        .. "putShortMSB (defined line 904), and the HCRC_UPDATE macro "
        .. "(#defined line 938); the call being substituted here is the "
        .. "recursive `deflate(strm, Z_BLOCK)` inside deflateParams, at "
        .. "line 772, before all three -- gcc's actual diagnostic flags "
        .. "all three as implicit/undeclared, in that order (flush_pending "
        .. "first, since it is called earliest in deflate's body).",
      fingerprint = "'flush_pending'",
    },
    {
      file = "deflate.c",
      callee = "deflate_stored",
      occurrence = 1,
      why = "E3: deflate_stored's body uses the MAX_STORED and MIN macros, "
        .. "#defined at lines 1607/1610 -- right above deflate_stored's own "
        .. "definition (1627) -- but the call being substituted, deflate()'s "
        .. "dispatch to its strategy function (line 1182), sits well before "
        .. "that #define.",
      fingerprint = "'MAX_STORED'",
    },
    {
      file = "deflate.c",
      callee = "deflate_huff",
      occurrence = 1,
      why = "E3: deflate_huff's body uses the FLUSH_BLOCK macro, #defined "
        .. "at line 1601, directly above the deflate_stored/_huff/_rle "
        .. "family; the call being substituted, deflate()'s strategy "
        .. "dispatch (line 1184), sits before that #define.",
      fingerprint = "'FLUSH_BLOCK'",
    },
    {
      file = "deflate.c",
      callee = "deflate_rle",
      occurrence = 1,
      why = "E3: deflate_rle's body uses both the FLUSH_BLOCK macro (line "
        .. "1601) and check_match (empty macro under this build, line "
        .. "1582); the call being substituted, deflate()'s strategy "
        .. "dispatch (line 1183), sits before both.",
      fingerprint = "'check_match'",
    },
    {
      file = "gzwrite.c",
      callee = "gzvprintf",
      occurrence = 1,
      why = "E6: gzprintf's call site copy-initializes a va_list "
        .. "(`va_list va = (va_arg_from_caller);`) to bind gzvprintf's "
        .. "`va_list va` parameter -- not valid C; only va_copy may do "
        .. "this. Known since Task 4 (the skip-rule narrowing recovered "
        .. "this call from being declined outright); not fixed here.",
      fingerprint = "invalid initializer",
    },
  },
})
