-- Shared harness for the real-source regression specs: clone a real OSS C
-- project, verify it builds and passes its own tests, then for every in-file
-- call to a same-file function apply correct-mode inline substitution and
-- require the project to still build AND still pass.
--
-- The contract is deliberately narrow: whenever the engine RETURNS a
-- transform, that transform must compile and the project's own tests must
-- still pass. Rejections are counted, not failures -- the engine is allowed
-- to decline (variadic functions, arity it cannot match); it is not allowed
-- to produce something that breaks.
local S = require("inline-explorer.substitute")
local C = require("inline-explorer.csrc")
local H = require("tests.lib.harness")

local M = {}

-- Every shell-out here runs under LC_ALL=C, and `known_failures`
-- fingerprints depend on it. gcc quotes identifiers in its diagnostics with
-- directional quotes when the locale's charset is UTF-8 and with ASCII
-- apostrophes otherwise -- same gcc, same source, different bytes:
--
--   LC_ALL=C        implicit declaration of function 'undeclared_fn'
--   LC_ALL=C.UTF-8  implicit declaration of function <U+2018>undeclared_fn<U+2019>
--
-- Without pinning it, a fingerprint written as `"'flush_pending'"` matches
-- on a machine whose locale happens to be C and fails on one whose locale
-- happens to be UTF-8, with no change to the engine, the source, or the
-- compiler. That is not hypothetical: it is how this was found -- six of
-- the eight pinned entries went red on a UTF-8 CI runner after passing in a
-- C-locale sandbox, and the two that survived were exactly the two whose
-- fingerprints contain no quotes.
--
-- Pinning the locale rather than dropping the quotes from the fingerprints
-- keeps them tight: `'lm_init'` cannot collide with the same identifier
-- appearing in an echoed source line, which bare `lm_init` could.
-- `export`, not a `VAR=x cmd` prefix: `cd` is a regular builtin, so a bare
-- assignment prefix would apply to the `cd` alone and not survive into the
-- `&&` command that actually runs the compiler.
local LOCALE = "export LC_ALL=C LANG=C; "

local function run(cmd)
  local out = vim.fn.system(cmd)
  return vim.v.shell_error == 0, out
end

M.sh = function(script, cwd)
  local out = vim.fn.system({ "bash", "-lc", LOCALE .. "cd " .. vim.fn.shellescape(cwd) .. " && " .. script })
  return vim.v.shell_error == 0, out
end

local function read(p)
  local f = assert(io.open(p, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

-- Last `n` bytes of `s`, trimmed forward to the nearest following newline
-- so the result starts on a line boundary instead of mid-line. A raw
-- `sub(-n)` can land inside a multi-line compiler diagnostic -- e.g. after
-- the "In function 'foo':" header but before the caret it belongs to --
-- which reads as a dangling fragment even though the decisive `error:`
-- lines and the final `make: *** Error N` further down are intact either
-- way.
local function tail(s, n)
  s = tostring(s)
  if #s <= n then
    return s
  end
  local cut = #s - n + 1
  local nl = s:find("\n", cut, true)
  return nl and s:sub(nl + 1) or s:sub(cut)
end

-- Given the exact source text gcc's preprocessor would see, return the set
-- of 1-indexed line numbers of `rel` that actually survive that run -- i.e.
-- that cpp's own `# <line> "<file>"` line-marker output attributes to
-- `rel`, AND whose output line actually carries content. Every marker
-- starts a new, correctly-numbered, contiguous run of whichever file it
-- names (the main file itself, or wherever a #include last returned
-- from), so one pass over the markers yields the complete surviving-line
-- set for the file. This is run ONCE PER FILE by the caller, not once per
-- call site: the set, once built, answers "does line N survive" for every
-- site in that file without re-invoking gcc.
--
-- The blank-content check matters as much as the file/line attribution:
-- gcc's -E only re-syncs via an explicit linemarker when a skipped
-- #ifdef/#if region is large enough (empirically >=6 lines on this gcc);
-- below that threshold cpp blank-pads instead, emitting one EMPTY output
-- line per skipped source line to keep the line count exact, with no
-- marker to say the file changed. Attribution alone cannot tell that blank
-- pad apart from a genuinely blank source line -- both are still "cur_file
-- == rel" -- so a line only counts as surviving when its content is
-- non-blank too. Verified (by hand, with `gcc -E`) on a bare multi-line
-- call and on a macro whose own body is split across lines: in both, the
-- callee's own token still lands on a non-blank output line, on the same
-- row treesitter reports for the call. NOT true for a call passed as an
-- argument to a different, ENCLOSING multi-line macro invocation: gcc
-- dumps that whole expansion on the invocation's OPENING line and
-- blank-pads the argument's own line(s), so a genuinely live call's row
-- reads as blank here even though the callee's token does appear, just on
-- a neighbouring line instead of its own. `callee_survives_nearby` below
-- is the secondary check that catches that shape before this rule's
-- verdict is trusted.
--
-- Returns nil (not an empty table) if the preprocessor itself could not be
-- run, so callers can tell "nothing survived" from "we couldn't check."
-- The table maps surviving 1-indexed line numbers to that output line's own
-- (non-blank) text, not just to `true` -- `callee_survives_nearby` reuses
-- that text for its own literal search instead of re-running `gcc -E`.
local function surviving_lines(dir, rel, cpp_flags)
  local ok, out = M.sh(("gcc -E %s %s 2>/dev/null"):format(cpp_flags or "", rel), dir)
  if not ok then
    return nil
  end
  local present = {}
  local cur_line, cur_file
  for ln in (out .. "\n"):gmatch("([^\n]*)\n") do
    local n, f = ln:match('^# (%d+) "(.-)"')
    if n then
      cur_line, cur_file = tonumber(n), f
    else
      if cur_file and (cur_file == rel or cur_file:sub(-(#rel + 1)) == "/" .. rel) and ln:match("%S") then
        present[cur_line] = ln
      end
      if cur_line then
        cur_line = cur_line + 1
      end
    end
  end
  return present
end

-- Preprocessor-conditional wrapper node types tree-sitter-c uses when
-- `#if`/`#ifdef`/`#elif` wraps one or more statements inside a block. These
-- must stop the climb in `enclosing_span`, not just pass through it: zlib's
-- crc32.c braid-combining code nests FIVE of these (`#if N > 1` down to
-- `#if N > 5`, one per braid, each wrapping exactly one `crc = crc_word(...);`
-- statement) directly inside a single `compound_statement`. Climbing past
-- them instead of stopping at the first one would treat all five nested
-- conditionals -- and all five sibling `crc_word` calls, several of them
-- genuinely live -- as one "enclosing statement", making the genuinely dead
-- innermost call (`#if N > 5`, false in this build) read as ambiguous
-- because a DIFFERENT, active call to the same name sits a few lines away
-- in a sibling branch. Confirmed by dumping the actual ancestor chain for
-- crc32.c's `crc = crc_word(crc5 ^ words[5] ^ crc);` (guarded by the
-- innermost `#if N > 5`): parent is `preproc_if` at every one of the five
-- nesting levels before a `compound_statement` is finally reached.
--
-- `preproc_else` is listed for the same reason even though omitting it is,
-- today, survivable: its own parent is always a `preproc_if`/`preproc_ifdef`,
-- so the climb halts one level later at the same effective boundary, and a
-- branch's siblings are uniformly dead or live together, so the widened span
-- cannot straddle a real dead/live boundary. Measured, with it omitted:
-- `gzwrite.c`'s `gz_init` and `gz_zero` calls got an 84-row span (514-597)
-- instead of their own statement, and still classified correctly. That is a
-- correct answer resting on an invariant nothing here states or checks, in
-- code whose whole point is to be pointed at the next project.
local PREPROC_WRAPPER = {
  preproc_if = true,
  preproc_ifdef = true,
  preproc_elif = true,
  preproc_elifdef = true,
  preproc_else = true,
}

-- The row range (0-indexed, inclusive) of the syntactic statement or
-- declaration that encloses `call_expr`: its nearest ancestor whose own
-- parent is a block (`compound_statement`), the top level
-- (`translation_unit`), or a preprocessor-conditional wrapper (see
-- `PREPROC_WRAPPER` above) -- climbing INTO one of those would cross a
-- `#if`/`#ifdef` boundary and pull in sibling branches that have nothing to
-- do with this call. For an ordinary call this is just the call's own
-- statement; for a call passed as an argument to an enclosing multi-line
-- macro invocation (see `callee_survives_nearby`), this is the whole
-- invocation, e.g. every physical line from `WRAP(` down to the closing
-- `);` -- which is exactly the span gcc may have collapsed onto one line.
local function enclosing_span(call_expr)
  local n = call_expr
  while n:parent() do
    local pt = n:parent():type()
    if pt == "compound_statement" or pt == "translation_unit" or PREPROC_WRAPPER[pt] then
      break
    end
    n = n:parent()
  end
  local r1, _, _, r2 = n:range(true)
  return r1, r2
end

-- Secondary check for a call site the blank-content rule (see
-- `surviving_lines` above) has just tagged `dead`: is that verdict actually
-- trustworthy, or is this the enclosing-macro-argument shape where gcc
-- dumped the callee's token on a neighbouring line instead of the call's
-- own? Cheap and deliberately approximate, matching the `has_line_directive`
-- precedent (detect-and-flag, not a general fix): if `name` followed by `(`
-- appears as a literal, word-bounded match in the NON-BLANK surviving text
-- of any line within the call's enclosing statement, the blank-content rule
-- cannot be trusted for this site -- route it away from `dead` rather than
-- trust a heuristic known to misfire on this exact shape.
local function callee_survives_nearby(call_expr, name, surviving)
  local r1, r2 = enclosing_span(call_expr)
  local pat = "%f[%w_]" .. name:gsub("%W", "%%%1") .. "%s*%("
  for row = r1, r2 do
    local content = surviving[row + 1]
    if content and content:find(pat) then
      return true
    end
  end
  return false
end

-- True if `src` contains a literal `#line N ["file"]` directive, in either
-- its keyword spelling or the bare `# N "file"` shorthand cpp itself
-- accepts as input (both are legal C, e.g. from a lex/yacc code
-- generator). Either form can retarget cpp's line/file attribution for
-- every line that follows it without a single physical line of `rel`
-- having moved -- `surviving_lines` has no way to tell that apart from a
-- genuine #include exit (see its file-attribution check above), so a file
-- containing one is treated as unverifiable for dead-branch purposes
-- rather than silently mis-attributed: a `#line N "otherfile"` mid-file
-- would otherwise make every real line of `rel` after it fail the
-- `cur_file == rel` check and read as dead, dropping a live call site from
-- the failure-detecting pool with no indication anything was skipped.
local function has_line_directive(src)
  for ln in (src .. "\n"):gmatch("([^\n]*)\n") do
    if ln:match("^%s*#%s*line%s") or ln:match('^%s*#%s*%d+%s+"') then
      return true
    end
  end
  return false
end

-- Every in-file function definition, and every call to one of them.
--
-- A call is skipped -- not guessed at -- when its callee name is genuinely
-- ambiguous without a preprocessor: it has more than one function
-- definition in the file, or the same name is also defined as a macro
-- (object-like `preproc_def` or function-like `preproc_function_def`).
-- Those are the only two cases the harness cannot resolve on its own:
-- with several definitions it cannot know which one a call binds to, and
-- with a same-named macro it cannot know whether a given call site is even
-- a function call once the preprocessor runs.
--
-- Merely sitting inside a preprocessor conditional (#if/#ifdef/#else/...)
-- is NOT ambiguous by itself, and is deliberately not checked here as a
-- reason to DECLINE. But it is also not proof of anything: if the branch
-- is inactive in this build, splicing that definition's body in is
-- unverified -- neither shown to break nor shown to work, because the
-- compiler never sees it. `surviving` (see `surviving_lines` above, built
-- once per file from the harness's own preprocessor run) is how a site is
-- told apart from that case: a non-ambiguous call whose own line does not
-- survive preprocessing is tagged `dead`, and the caller must count it
-- separately from a genuine engine-accepted, compiled-and-run transform.
-- If the branch IS active, the real plugin resolves the call exactly the
-- way `resolver` does for any other call: by asking the language server,
-- which already knows the translation unit's active configuration.
-- Declining every conditional call outright, regardless of activeness,
-- cost the harness a real, correct transform: zlib's gzwrite.c defines
-- `gzvprintf` once, unconditionally active, with no same-named macro --
-- there is nothing ambiguous about it, and `surviving` confirms it.
--
-- The `dead` tag is call-site-based, not definition-based, on purpose:
-- zlib's `byte_swap` sits inside `#if defined(W) && (!defined(ARMCRC32) ||
-- defined(DYNAMIC_CRC_TABLE))` (crc32.c:114-140) -- a conditional, not a
-- literal absence of one, just one that happens to always be true on this
-- platform, so its own definition line does survive preprocessing. It is
-- still called from inside `make_crc_table`'s `#ifdef DYNAMIC_CRC_TABLE`
-- region (never compiled by this harness's `./configure`) as well as from
-- `crc32`'s always-active body -- the same callee, two call sites, only
-- one of them live. Checking the definition's own location would have
-- missed that: the definition survives either way, only one call site
-- does.
--
-- The two cases this still declines outright as ambiguous are real:
-- crc32.c defines crc32_z twice (the ARM asm path uses macros --
-- Z_BATCH, Z_BATCH_ZEROS, Z_BATCH_MIN -- that only exist in that branch,
-- so splicing it into the x86 build fails to compile), and deflate.c's
-- check_match is a real function only under #ifdef ZLIB_DEBUG while the
-- same name is an empty macro otherwise (so the "call" the harness sees
-- there is a macro invocation, and splicing a function body in is
-- meaningless).
local function enumerate(src, surviving)
  local root = C.parse(src)
  local defs = {}
  local def_count = {}
  local ambiguous = {}
  for _, nm in ipairs(C.query_nodes(root, src, "(function_declarator declarator: (identifier) @n)")) do
    local fn = nm
    while fn and fn:type() ~= "function_definition" do
      fn = fn:parent()
    end
    if fn then
      local name = C.text(nm, src)
      def_count[name] = (def_count[name] or 0) + 1
      if not defs[name] then
        defs[name] = C.text(fn, src)
      end
    end
  end
  local macro_named = {}
  for _, n in
    ipairs(
      C.query_nodes(root, src, "[(preproc_def name: (identifier) @n) (preproc_function_def name: (identifier) @n)]")
    )
  do
    macro_named[C.text(n, src)] = true
  end
  for name, n in pairs(def_count) do
    if n > 1 or macro_named[name] then
      ambiguous[name] = true
    end
  end
  -- One combined, file-ordered list of every call site to an in-file
  -- function, each tagged with whether it was declined as ambiguous, and
  -- (for the rest) whether its own line survives preprocessing. This lets
  -- the caller apply a single site cap across skipped, dead, and attempted
  -- calls alike, instead of the cap only bounding a subset of the three.
  local sites = {}
  for _, f in ipairs(C.query_nodes(root, src, "(call_expression function: (identifier) @f)")) do
    local name = C.text(f, src)
    if defs[name] then
      local r, c = f:range(true)
      local amb = ambiguous[name] or false
      -- Only a non-ambiguous site can be usefully tagged dead: an
      -- ambiguous one is already declined for a different, stronger
      -- reason, and is counted there instead.
      local dead = (not amb) and surviving ~= nil and not surviving[r + 1]
      -- A `dead` verdict can itself be wrong: see `callee_survives_nearby`.
      -- When it fires, this site's own blank-content reading is untrusted,
      -- not confidently dead -- fail open (like a whole `unverifiable`
      -- file does) so the site still gets attempted, while flagging it so
      -- the summary line does not stay silent about the substitution.
      local ambiguous_dead = false
      if dead then
        ambiguous_dead = callee_survives_nearby(f:parent(), name, surviving)
        if ambiguous_dead then
          dead = false
        end
      end
      sites[#sites + 1] =
        { name = name, row = r, col = c, ambiguous = amb, dead = dead, ambiguous_dead = ambiguous_dead }
    end
  end
  return defs, sites
end

function M.run(cfg)
  local function skip(msg)
    print("SKIP: " .. msg)
  end

  if vim.fn.executable("git") == 0 or vim.fn.executable("gcc") == 0 then
    return skip("git or gcc not available")
  end

  local work = vim.fn.tempname()
  vim.fn.mkdir(work, "p")
  local dir = work .. "/" .. cfg.name
  -- `cfg.ref`, when given, pins the clone to a tag (`--branch` accepts tags as
  -- well as branches) instead of whatever the upstream default branch's HEAD
  -- happens to be at the moment CI runs. Without it, an upstream release
  -- moves the file under our feet: call-site counts, which sites are
  -- ambiguous or dead-branch, and which sites fail all depend on the exact
  -- source text, so an un-pinned clone makes both the summary numbers above
  -- and (far worse) the `known_failures` exact-set pin below go stale for a
  -- reason that has nothing to do with an engine regression.
  local clone_cmd = { "git", "clone", "--depth", "1" }
  if cfg.ref then
    clone_cmd[#clone_cmd + 1] = "--branch"
    clone_cmd[#clone_cmd + 1] = cfg.ref
  end
  clone_cmd[#clone_cmd + 1] = cfg.url
  clone_cmd[#clone_cmd + 1] = dir
  local ok, out = run(clone_cmd)
  if not ok then
    return skip("clone failed (offline?)\n" .. out)
  end
  for _, rel in ipairs(cfg.requires) do
    if vim.fn.filereadable(dir .. "/" .. rel) == 0 then
      return skip("unexpected " .. cfg.name .. " layout: missing " .. rel)
    end
  end

  if cfg.setup then
    local sok, sout = cfg.setup(dir)
    if not sok then
      return skip("setup failed\n" .. tostring(sout))
    end
  end

  -- The baseline must build and pass before any comparison means anything.
  local bok, bout = cfg.verify(dir)
  if not bok then
    return skip("baseline build/test failed\n" .. tostring(bout))
  end

  -- `cfg.cpp_flags` may be a plain string (the cJSON spec's flags never
  -- depend on anything generated) or a function of `dir` (zlib's do: they
  -- come out of the Makefile `./configure` just wrote, so they cannot be
  -- known until after `cfg.setup` has run). Resolved once here, not once
  -- per file -- the flags are the same for every translation unit in a
  -- single build.
  local cpp_flags = cfg.cpp_flags
  if type(cpp_flags) == "function" then
    cpp_flags = cpp_flags(dir)
  end

  local max_sites = tonumber(os.getenv("IE_REAL_MAX_SITES") or "") or math.huge
  -- `sites` counts every call site the cap has let it look at, whether
  -- that site was then declined as ambiguous, declined as dead (its own
  -- line never survives preprocessing in this build), or attempted. The
  -- cap must bound `sites` itself -- not just the attempted subset -- so
  -- that `sites = skipped-ambiguous + dead-branch + (whatever was
  -- attempted)` still holds when the cap is in effect; otherwise the
  -- summary line reports a `sites` total that never stopped growing while
  -- everything else did.
  local sites, accepted, passed, failures, skipped, dead_branch = 0, 0, 0, {}, 0, 0
  -- Files where the dead-branch check itself could not be trusted for a
  -- reason other than "there is nothing dead" -- a failed `gcc -E`, or a
  -- `#line` directive that would corrupt the check silently (see
  -- `has_line_directive`). Every non-ambiguous call site in such a file
  -- falls through to being treated as ordinary (not dead), the same
  -- unfiltered accounting this harness had before dead-branch tracking
  -- existed -- so this list, and its count in the summary line below, is
  -- what keeps that fallback from being silent.
  local unverifiable = {}
  -- Distinct from `unverifiable` above, and at a different granularity: that
  -- one is per-FILE (the whole file's dead-branch check is untrustworthy).
  -- This one is per-SITE -- the file's check is fine, but `enumerate`'s
  -- `callee_survives_nearby` found this one particular call's blank-content
  -- reading contradicted by its own callee token surviving on a neighbouring
  -- line (the enclosing-multi-line-macro-argument shape; see
  -- `surviving_lines`'s doc comment). Folded into its own summary-line
  -- counter for the same reason `unverifiable-files` is folded in rather
  -- than left to a per-file print only a hand-reader would notice. These
  -- sites are NOT a fourth bucket in the sites=skipped+dead+attempted split
  -- below -- they fail open into "attempted" exactly like a whole
  -- unverifiable file's sites do -- this list exists purely so that fail-open
  -- is visible instead of silent.
  local unverifiable_dead = {}

  for _, rel in ipairs(cfg.sources) do
    if sites >= max_sites then
      break
    end
    local path = dir .. "/" .. rel
    if vim.fn.filereadable(path) == 1 then
      local src0 = read(path)
      -- Computed ONCE per file: which of this file's own lines survive
      -- the preprocessor the harness's own build will run. nil (not an
      -- empty table) means "couldn't check" -- in that case `enumerate`
      -- leaves every site untagged-dead rather than guessing, and this
      -- file is added to `unverifiable` so the fallback is surfaced in the
      -- summary line rather than only in an easy-to-miss per-file print.
      local surviving
      if has_line_directive(src0) then
        unverifiable[#unverifiable + 1] =
          { rel, "contains a #line directive -- line/file attribution after it is not trustworthy" }
      else
        surviving = surviving_lines(dir, rel, cpp_flags)
        if surviving == nil then
          unverifiable[#unverifiable + 1] = { rel, "gcc -E failed" }
        end
      end
      local defs, call_sites = enumerate(src0, surviving)
      -- Per-callee-name occurrence counter, reset for every file: the Nth
      -- time (in file order) a transform for THIS name was actually
      -- accepted and put through the deterministic/verify gates below.
      -- `known_failures` below is keyed on (file, callee, occurrence)
      -- rather than just (file, callee) because the same name can be
      -- called from more than one site in a file, with only some of
      -- those sites failing -- e.g. zlib's deflateEnd is called both
      -- before and after its own callee deflateStateCheck's definition;
      -- only the earlier call site's substitution is a forward reference.
      local occurrence_of = {}
      for i, call in ipairs(call_sites) do
        if sites >= max_sites then
          break
        end
        sites = sites + 1
        if call.ambiguous_dead then
          unverifiable_dead[#unverifiable_dead + 1] = { rel, call.name, call.row + 1 }
        end
        if call.ambiguous then
          skipped = skipped + 1
        elseif call.dead then
          -- Genuinely a single, unambiguous definition -- but this call
          -- site's own line never survives preprocessing in this build
          -- (e.g. it is only reachable under #ifdef DYNAMIC_CRC_TABLE,
          -- which this harness's ./configure never defines). The engine
          -- is never asked to transform it, so it is neither
          -- engine-accepted nor built+passed: crediting it as either
          -- would report a transform as verified that gcc never compiled.
          dead_branch = dead_branch + 1
        else
          local sok, new = pcall(S.inline_at, src0, call.row, call.col, defs[call.name], i, "correct")
          if sok and new and new ~= src0 then
            accepted = accepted + 1
            occurrence_of[call.name] = (occurrence_of[call.name] or 0) + 1
            local occurrence = occurrence_of[call.name]
            H.writef(path, new)
            -- The deterministic gate runs BEFORE the project's own
            -- (slow, round-trip) test suite: it is cheap -- one
            -- `-fsyntax-only` pass over a single translation unit -- and
            -- its verdict does not depend on what was sitting in
            -- whatever stack slot an uninitialised read happened to land
            -- on, the way a round-trip build+run's pass/fail can. See
            -- `cfg.syntax_check`'s own doc comment at its call sites
            -- (real_zlib_spec.lua) for what class of defect this is
            -- for and, just as importantly, what it is NOT for -- it
            -- catches a forward-referenced identifier or an invalid
            -- initializer, not a value that is merely wrong.
            local gate_ok, gate_out = true, nil
            if cfg.syntax_check then
              gate_ok, gate_out = cfg.syntax_check(dir, rel)
            end
            if not gate_ok then
              local full = "[gcc -fsyntax-only] " .. tostring(gate_out)
              failures[#failures + 1] =
                { rel, call.name, "[gcc -fsyntax-only] " .. tail(gate_out, 1500), occurrence, full }
            else
              local vok, vout = cfg.verify(dir)
              if vok then
                passed = passed + 1
              else
                -- The tail, not the head, is what gets PRINTED: gcc warnings
                -- and build noise fill the front of the output, while the
                -- actual failure -- "Segmentation fault", "*** zlib test
                -- FAILED ***" -- sits at the end. Cut on a line boundary, not
                -- a byte count: a raw byte-offset cut lands mid-line
                -- (mid-diagnostic, even mid-caret), dropping the header line
                -- that names the failing function without dropping enough to
                -- matter. `f[5]` below carries the FULL, untruncated text
                -- alongside it -- see the fingerprint-matching code near
                -- `known_failures` for why truncation must not touch what
                -- gets matched, only what gets printed.
                failures[#failures + 1] = { rel, call.name, tail(vout, 1500), occurrence, tostring(vout) }
              end
            end
            H.writef(path, src0)
          end
        end
      end
    end
  end

  -- `unverifiable-files` sits in the summary line itself -- not a
  -- separate print() a monitoring grep for `^real %s:` would never see --
  -- because a preprocessing failure here means every one of that file's
  -- non-ambiguous sites silently reverted to pre-dead-branch accounting.
  -- Folding the count in is what keeps that reversion from degrading
  -- verification with nothing downstream to catch it.
  print(
    ("real %s: sites=%d  skipped-ambiguous=%d  dead-branch=%d  engine-accepted=%d  built+passed=%d  unverifiable-files=%d  unverifiable-dead-sites=%d"):format(
      cfg.name,
      sites,
      skipped,
      dead_branch,
      accepted,
      passed,
      #unverifiable,
      #unverifiable_dead
    )
  )
  if cfg.oracle_note then
    print("note: " .. cfg.oracle_note)
  end
  if #unverifiable > 0 then
    print(#unverifiable .. " FILE(S) UNVERIFIABLE FOR DEAD-BRANCH:")
    for _, u in ipairs(unverifiable) do
      print(("  * %s -> %s"):format(u[1], u[2]))
    end
  end
  if #unverifiable_dead > 0 then
    print(#unverifiable_dead .. " CALL SITE(S) WHERE DEAD-BRANCH READING WAS OVERRULED (attempted instead):")
    for _, u in ipairs(unverifiable_dead) do
      print(
        ("  * %s:%d %s -- callee token survives on a neighbouring line (enclosing multi-line macro argument?)"):format(
          u[1],
          u[3],
          u[2]
        )
      )
    end
  end
  if #failures > 0 then
    print(#failures .. " FAILURE(S):")
    for _, f in ipairs(failures) do
      print(("  * %s %s occurrence=%d -> %s"):format(f[1], f[2], f[4], f[3]))
    end
  else
    print(("ALL ACCEPTED TRANSFORMS COMPILE + PASS ON REAL %s"):format(cfg.name:upper()))
  end

  -- `cfg.known_failures`, when given, pins the FAILURE(S) list above as an
  -- exact set rather than a one-directional suppression list. Each element
  -- is `{ file, callee, occurrence, why, fingerprint }`; `occurrence`
  -- disambiguates a callee called from more than one site in the same file
  -- (see the doc comment on `occurrence_of` above). The check below is
  -- deliberately symmetric, and checks more than site identity:
  --
  -- Fingerprint matching (see below) is done against `f[5]`, each failure's
  -- FULL, untruncated captured text -- never `f[3]`, the `tail(...., 1500)`
  -- kept only for the human-readable print at the top of this function.
  -- Before `fingerprint` existed, that truncation was cosmetic (nothing
  -- compared `f[3]` to anything, it was only ever printed). Matching against
  -- it would make the truncation load-bearing: a real, unchanged diagnostic
  -- whose relevant identifier lands earlier than the last 1500 bytes -- or
  -- that grows past that window because of an unrelated gcc-version wording
  -- change elsewhere in the same multi-line diagnostic -- would silently
  -- drop the fingerprint from view and misreport PINNED SITE(S) FAILING FOR
  -- A DIFFERENT REASON with no engine regression behind it at all.
  --
  --   * a failure this run that is NOT in `known_failures` is a
  --     regression -- something new broke -- and must fail the run;
  --   * an entry IN `known_failures` that did NOT fail this run means
  --     someone fixed it without updating the list, which must ALSO fail
  --     the run. A one-directional suppression list (only checking "is
  --     every failure expected") would let entries silently accumulate
  --     forever, including ones nobody has looked at in months -- exactly
  --     the failure mode a pin exists to prevent.
  --   * a failure this run at a pinned (file, callee, occurrence) site
  --     that does NOT carry `fingerprint` as a substring is ALSO a
  --     mismatch: the site is the same, but the reason is not. Matching
  --     `(file, callee, occurrence)` alone answers "did something fail
  --     here", never "is it the same defect" -- `fingerprint` is what
  --     answers that, and the field this file's own doc comment on this
  --     block used to omit checking at all (a call site's failure text,
  --     `f[3]`, was previously read only to print it, never compared).
  --   * two failures this run, or two `known_failures` entries, that
  --     collide onto the same `(file, callee, occurrence)` key are a
  --     mismatch too, reported by name rather than one silently
  --     overwriting the other in the `actual`/`known` maps below (which
  --     would drop the first one out of pin-matching with no sign it ever
  --     happened, and, for a `known_failures` duplicate, would let
  --     `#cfg.known_failures` overstate how many distinct sites are
  --     actually pinned in the OK message).
  --
  -- Printing "-- FAILURE" in the mismatch banner (rather than only in the
  -- unconditional FAILURE(S) block above, which fires for ANY build/verify
  -- failure whether pinned or not) is what lets a CI step distinguish "the
  -- known, pinned set failed as expected" from "the pinned set drifted" --
  -- grepping bare "FAILURE" cannot tell those apart, since the ordinary
  -- FAILURE(S) banner above prints every time there is a single pinned
  -- failure in the list, pinned or not.
  if cfg.known_failures then
    local function key(file, callee, occurrence)
      return file .. "\1" .. callee .. "\1" .. tostring(occurrence)
    end
    -- The inverse of `key`: for printing a collision, not for matching --
    -- every other print in this file is human-readable, and the raw key
    -- (file .. "\1" .. callee .. "\1" .. occurrence) is not: the \1 (SOH)
    -- separator renders as an unreadable control-character glyph in a CI
    -- log instead of a visible delimiter, e.g. "deflate.c^Adeflate_huff^A1".
    local function unkey(k)
      local file, callee, occurrence = k:match("^(.*)\1(.*)\1(.*)$")
      return ("%s %s occurrence=%s"):format(file, callee, occurrence)
    end
    local actual = {}
    -- Two failures this run collapsing onto the same (file, callee,
    -- occurrence) key would otherwise silently overwrite one another in
    -- `actual[k] = f` below, dropping the first one out of pin-matching
    -- entirely with no sign it happened -- reported explicitly instead.
    local actual_collisions = {}
    for _, f in ipairs(failures) do
      local k = key(f[1], f[2], f[4])
      if actual[k] then
        actual_collisions[#actual_collisions + 1] = k
      end
      actual[k] = f
    end
    local known = {}
    -- Same shape of bug, on the list side: a duplicate `known_failures`
    -- entry would silently collapse into one `known` slot while
    -- `#cfg.known_failures` (the count printed verbatim in the PIN OK
    -- message below) is not deduplicated, overstating how many distinct
    -- sites are actually pinned. Reported explicitly, same as above.
    local known_collisions = {}
    for _, kf in ipairs(cfg.known_failures) do
      assert(
        type(kf.fingerprint) == "string" and kf.fingerprint ~= "",
        ("known_failures entry %s/%s/occurrence=%s is missing a required, non-empty `fingerprint`"):format(
          kf.file,
          kf.callee,
          tostring(kf.occurrence)
        )
      )
      local k = key(kf.file, kf.callee, kf.occurrence)
      if known[k] then
        known_collisions[#known_collisions + 1] = k
      end
      known[k] = kf
    end
    -- No load-time "does this fingerprint's position leave margin before
    -- tail()'s cut" assertion here on purpose: that check would have
    -- guarded against exactly one failure mode, which no longer exists.
    -- `fingerprint` is matched against `f[5]` (the FULL, untruncated
    -- capture -- see the comment above) rather than the truncated `f[3]`,
    -- so there is no cut for any fingerprint's position to have margin
    -- from any more; a margin assertion would be checking an invariant
    -- nothing downstream of it depends on.
    --
    -- Matching the full text does open the opposite risk, and nothing here
    -- checks for it: a fingerprint that coincidentally appears somewhere
    -- earlier in the capture, unrelated to the pinned cause, would match
    -- and report PIN OK for the wrong reason -- the silent green this
    -- whole mechanism exists to prevent, arriving from the other end. It
    -- is not live today: the eight pinned captures run 178 to 1959 bytes,
    -- all of them targeted single-file diagnostics with no header dumps or
    -- long paths, and each fingerprint was checked by hand against its own
    -- full capture. A future entry whose failure produces a long or noisy
    -- log -- a multi-file build, a verbose test runner -- does not get that
    -- for free, and whoever adds it should confirm by hand that the string
    -- they pick cannot occur anywhere in that output except where they
    -- mean it to.
    local unlisted, fixed, wrong_reason = {}, {}, {}
    for k, f in pairs(actual) do
      local kf = known[k]
      if not kf then
        unlisted[#unlisted + 1] = f
      -- The key matching says a failure exists at the pinned SITE; it says
      -- nothing about whether it is the pinned defect. `f[5]` is this run's
      -- FULL, untruncated captured failure text (see the note above `f[3]`
      -- is the truncated-for-printing sibling, never matched against);
      -- `kf.fingerprint` must appear in it verbatim (plain substring, not a
      -- pattern -- a compiler diagnostic can contain `%`-free but
      -- paren/bracket-heavy text `string.find`'s pattern mode would
      -- misread) or the site failed for a different reason than the one
      -- pinned.
      elseif not f[5]:find(kf.fingerprint, 1, true) then
        wrong_reason[#wrong_reason + 1] = { key = k, kf = kf, f = f }
      end
    end
    for k, kf in pairs(known) do
      if not actual[k] then
        fixed[#fixed + 1] = kf
      end
    end
    table.sort(unlisted, function(a, b)
      return (a[1] .. a[2] .. tostring(a[4])) < (b[1] .. b[2] .. tostring(b[4]))
    end)
    table.sort(fixed, function(a, b)
      return (a.file .. a.callee .. tostring(a.occurrence)) < (b.file .. b.callee .. tostring(b.occurrence))
    end)
    table.sort(wrong_reason, function(a, b)
      return a.key < b.key
    end)
    table.sort(actual_collisions)
    table.sort(known_collisions)
    if #unlisted == 0 and #fixed == 0 and #wrong_reason == 0 and #actual_collisions == 0 and #known_collisions == 0 then
      print(("KNOWN-FAILURES PIN OK: exact match, %d pinned failure(s)"):format(#cfg.known_failures))
    else
      print("KNOWN-FAILURES PIN MISMATCH -- FAILURE")
      if #unlisted > 0 then
        print(#unlisted .. " FAILURE(S) NOT IN known_failures (new regression):")
        for _, f in ipairs(unlisted) do
          print(("  * %s %s occurrence=%d"):format(f[1], f[2], f[4]))
        end
      end
      if #fixed > 0 then
        print(#fixed .. " known_failures ENTRY(IES) THAT DID NOT FAIL (update the list):")
        for _, kf in ipairs(fixed) do
          print(("  * %s %s occurrence=%d (%s)"):format(kf.file, kf.callee, kf.occurrence, kf.why))
        end
      end
      if #wrong_reason > 0 then
        print(#wrong_reason .. " PINNED SITE(S) FAILING FOR A DIFFERENT REASON THAN PINNED (fingerprint mismatch):")
        for _, w in ipairs(wrong_reason) do
          print(
            ("  * %s %s occurrence=%d -- expected fingerprint %q not found in this run's captured failure"):format(
              w.kf.file,
              w.kf.callee,
              w.kf.occurrence,
              w.kf.fingerprint
            )
          )
        end
      end
      if #actual_collisions > 0 then
        print(#actual_collisions .. " ACTUAL FAILURE(S) COLLIDE ON THE SAME (file, callee, occurrence) KEY:")
        for _, k in ipairs(actual_collisions) do
          print("  * " .. unkey(k))
        end
      end
      if #known_collisions > 0 then
        print(
          #known_collisions
            .. " known_failures ENTRY(IES) COLLIDE ON THE SAME (file, callee, occurrence) KEY (duplicate entry):"
        )
        for _, k in ipairs(known_collisions) do
          print("  * " .. unkey(k))
        end
      end
    end
  end
end

return M
