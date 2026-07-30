-- Performance regression harness. Drives the REAL user actions against a real
-- clangd and asserts structural invariants -- how many round trips an action
-- costs, and whether the attach cache is doing its job. These hold regardless
-- of machine speed, which is why they are the pass/fail gate; timings are
-- reported separately (see the report section below).
--
--   nvim --headless --clean -u NONE -c "luafile tests/bench_spec.lua" -c "qa!"
--
-- Env: IE_BENCH_CLANGD (clangd path), IE_BENCH_REPS, IE_BENCH_WARMUP,
--      IE_BENCH_TIMING_GATE (default 1; 0 downgrades vs-baseline timing
--      failures to warnings -- see TIMING_GATE below)
local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":h:h")
vim.opt.rtp:append(root)

local bench = require("tests.lib.bench")
local fixture = require("tests.fixtures.bench.gen")
local profile = require("inline-explorer.profile")
local view = require("inline-explorer.view")
local expander = require("inline-explorer.expander")
local inliner = require("inline-explorer.inliner")
local history = require("inline-explorer.history")
local resolver = require("inline-explorer.resolver")

local clangd = os.getenv("IE_BENCH_CLANGD") or "clangd"
if vim.fn.executable(clangd) == 0 then
  print("SKIP: clangd not found (set IE_BENCH_CLANGD)")
  return
end

local REPS = tonumber(os.getenv("IE_BENCH_REPS") or "") or 15
local WARMUP = tonumber(os.getenv("IE_BENCH_WARMUP") or "") or 3

-- A steadily-loaded runner (CI, unlike a benchmarking machine, is never
-- idle) inflates every scenario's latency together, so the noise floor --
-- measured from two populations of the SAME run -- stays small while both
-- populations are slower than the baseline. That defeats the `noisy`
-- detector below, which only catches noise WITHIN a run, not a whole run
-- running hot relative to the baseline's machine. Set IE_BENCH_TIMING_GATE=0
-- (the CI job does) to downgrade vs-baseline timing failures to warnings
-- unconditionally; structural invariants never depend on the clock and are
-- never affected by this flag.
local TIMING_GATE = (os.getenv("IE_BENCH_TIMING_GATE") or "1") ~= "0"

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and ("\n----\n" .. tostring(d) .. "\n----") or ""))
  end
end

require("inline-explorer").setup({ profile = true })
profile.logfile = false -- the report is the output; no user log from a bench

-- ---------------------------------------------------------------------------
-- Fixture + server
-- ---------------------------------------------------------------------------
local dir = vim.fn.tempname()
local meta = fixture.generate(dir)

vim.cmd.edit(meta.main)
local sbuf = vim.api.nvim_get_current_buf()
vim.lsp.start({ name = "clangd", cmd = { clangd, "--background-index" }, root_dir = dir })
vim.wait(15000, function()
  return #vim.lsp.get_clients({ bufnr = sbuf, name = "clangd" }) > 0
end, 50)
if #vim.lsp.get_clients({ bufnr = sbuf, name = "clangd" }) == 0 then
  print("SKIP: clangd did not attach")
  return
end

-- Wait until the background index can answer for a symbol that lives in a
-- header -- that is the precondition for every scenario below.
local indexed = false
for _ = 1, 120 do
  local done = false
  resolver.locate(meta.warm[1], sbuf, function(loc)
    indexed, done = loc ~= nil, true
  end)
  vim.wait(3000, function()
    return done
  end, 20)
  if indexed then
    break
  end
  vim.wait(500)
end
if not indexed then
  print("SKIP: clangd index never answered workspace/symbol")
  return
end

local vbuf = view.open()
local st = view.current()

-- ---------------------------------------------------------------------------
-- Driving helpers
-- ---------------------------------------------------------------------------

-- Put the cursor on the first occurrence of `pat` in the view. Returns false
-- when the pattern is absent (a scenario that cannot run must say so rather
-- than silently measure the wrong thing).
local function goto_pattern(pat)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(vbuf, 0, -1, false)) do
    local c = l:find(pat)
    if c then
      vim.api.nvim_win_set_cursor(0, { i, c - 1 })
      return true
    end
  end
  return false
end

-- Run one action on `pat` and hand back its spans, leaving the view as it was
-- (every action mutates the buffer; undo keeps reps independent).
-- Returns (spans, complete). `complete` is false when the action never
-- reached its own final total: span within the timeout. Callers must not
-- read counts off an incomplete capture.
local function act(pat, fn, capture_opts)
  if not goto_pattern(pat) then
    return nil, false
  end
  local spans, complete = bench.capture(fn, 30000, capture_opts)
  history.undo()
  return spans, complete
end

local function expand_on(pat)
  return act(pat, expander.expand)
end
local function inline_on(pat, capture_opts)
  return act(pat, inliner.smart, capture_opts)
end

-- ---------------------------------------------------------------------------
-- Structural invariants -- the gate
-- ---------------------------------------------------------------------------
print("=== structural invariants ===")

-- 1. One expansion costs exactly one locate and one extract.
do
  local spans, complete = expand_on(meta.cold[1] .. "%(")
  check("capture completed within the timeout", complete == true,
    spans and (bench.names(spans) .. " -- " .. tostring(select(2, bench.assert_complete(spans)))))
  -- Counts the OUTCOME of extraction, not every span the stage emits.
  -- `extract:` also covers the sub-spans that decompose a slow extract --
  -- `extract:bufload` (reading the definition file off disk) and
  -- `extract:attach` (handing it to the server) -- which exist precisely
  -- because a single opaque `extract:cold` could not say where four seconds
  -- went. Counting the prefix would make this invariant fail whenever those
  -- fire, which is exactly when the extra detail is wanted.
  local function outcomes(sp)
    local n = 0
    for _, pat in ipairs({ "^extract:local$", "^extract:cold$", "^extract:warm$", "^extract:cached$",
      "^extract:no%-lsp$", "^extract:no%-capability$" }) do
      n = n + bench.count(sp, pat)
    end
    return n
  end
  check("one expand = one locate + one extract outcome",
    complete and bench.count(spans, "^locate:") == 1 and outcomes(spans) == 1,
    spans and bench.names(spans))
end

-- 2. C extraction must never wait for the server. This invariant used to
--    assert the cold/warm attach distinction on the documentSymbol path;
--    with local-first extraction the point IS that neither symbol issues a
--    documentSymbol wait at all -- the first touch of a definition file was
--    measured (real kernel, real clangd) at 400ms-4s of preamble build per
--    file, on a keypress, and the wait bought nothing tree-sitter had not
--    already provided. cold/warm remain live spans for the non-C server
--    path, which resolver_spec exercises by forcing _local_first off.
do
  local first, first_complete = expand_on(meta.warm[1] .. "%(")
  local second, second_complete = expand_on(meta.warm[2] .. "%(")
  check("first touch of a header extracts locally, no documentSymbol wait",
    first_complete and bench.count(first, "^extract:local") == 1, first and bench.names(first))
  check("second symbol from the same header extracts locally too",
    second_complete and bench.count(second, "^extract:local") == 1, second and bench.names(second))
end

-- 3. Falling back to block-paste must not re-resolve: the inliner already has
--    the body and hands it over. This is a two-phase action (block-fallback,
--    then expander.expand's own splice), so give the capture a generous
--    settle_cap_ms -- the default 300ms cap is sized for single-phase
--    scenarios and can cut off before the second phase's total: span lands.
do
  -- Cursor must land on the type name itself so <cword> resolves the struct
  -- symbol, not on a preceding "struct " keyword (which <cword> would read
  -- as the C keyword "struct", not a resolvable name).
  local spans, complete = inline_on(meta.struct_name, { settle_cap_ms = 3000, until_span = "^total:expand" })
  check("block fallback happened",
    complete and bench.count(spans, "^total:block%-fallback") == 1, spans and bench.names(spans))
  check("block fallback costs no second lookup",
    complete and bench.count(spans, "^locate:") == 1 and bench.count(spans, "^extract:") == 1,
    spans and bench.names(spans))
end

-- 4. A definition in the file being edited opens nothing new.
do
  local spans, complete = expand_on(meta.same_file .. "%(3%)")
  check("same-file definition is never a cold extraction",
    complete and bench.count(spans, "^extract:cold") == 0 and bench.count(spans, "^extract:") == 1,
    spans and bench.names(spans))
end

-- 5. A macro resolves through the tweak; the hover scrape is a fallback for
--    servers that cannot do better, and must not be reached here.
do
  -- "%(" alone matches the #define line itself (earlier in the generated
  -- file than the call site); disambiguate with the call's argument, same
  -- idiom as the same-file scenario above, so the cursor lands on the actual
  -- invocation in main() where the ExpandMacro tweak applies.
  local spans, complete = inline_on(meta.macro_call .. "%(4%)")
  check("macro uses the ExpandMacro tweak",
    complete and bench.count(spans, "^macro:tweak$") == 1, spans and bench.names(spans))
  check("macro does not fall back to hover scraping",
    complete and bench.count(spans, "^macro:hover") == 0, spans and bench.names(spans))
end

-- ---------------------------------------------------------------------------
-- Timing -- reported always, fails only on a change bigger than the noise
-- ---------------------------------------------------------------------------
print("")
print("=== timing (p50/p90 over " .. REPS .. " reps, " .. WARMUP .. " discarded) ===")

-- Each scenario is its own population; cold and warm are never mixed. The
-- cold reps walk distinct headers (touching each exactly once) rather than
-- restarting the server, which is cheaper and means the same thing.
local scenarios = {
  {
    name = "expand:cold",
    action = function(i)
      -- Every scenario whose baseline describes a SERVER round trip clears
      -- the resolver's result caches first. Without this they measure the
      -- cache instead, and silently: the structural invariants above run
      -- before the scenarios and resolve these very names, so by the time a
      -- scenario runs its answer is already cached, `extract:warm` never
      -- fires, the guard rejects every rep, and the population is empty.
      -- That is not a loud failure -- `expand:warm` is also the noise-floor
      -- calibration scenario, so an empty population makes the floor
      -- unmeasurable, which SUSPENDS the whole timing gate while the
      -- structural invariants still report green. The cached path is
      -- measured on purpose further down instead.
      resolver.clear_caches()
      local sym = meta.cold[((i - 1) % #meta.cold) + 1]
      local spans, complete = expand_on(sym .. "%(")
      if complete and bench.count(spans, "^extract:local") == 1 then
        return bench.elapsed_ms(spans)
      end
      return nil -- not actually cold: do not pollute the population
    end,
  },
  {
    name = "expand:warm",
    action = function(i)
      resolver.clear_caches()
      local sym = meta.warm[((i - 1) % #meta.warm) + 1]
      local spans, complete = expand_on(sym .. "%(")
      if complete and bench.count(spans, "^extract:local") == 1 then
        return bench.elapsed_ms(spans)
      end
      return nil
    end,
  },
  {
    name = "inline:function",
    action = function()
      resolver.clear_caches()
      local spans, complete = inline_on(meta.fn_call .. "%(")
      return complete and bench.count(spans, "^total:inline%-function") == 1 and bench.elapsed_ms(spans) or nil
    end,
  },
  {
    name = "inline:macro",
    action = function()
      -- "%(" alone matches the #define line itself, ahead of the call site in
      -- the generated file; disambiguate with the call's argument, same
      -- idiom as invariant 5 above, so the cursor lands on the invocation.
      resolver.clear_caches()
      local spans, complete = inline_on(meta.macro_call .. "%(4%)")
      return complete and bench.count(spans, "^total:inline%-macro") == 1 and bench.elapsed_ms(spans) or nil
    end,
  },
  {
    name = "expand:same-file",
    action = function()
      resolver.clear_caches()
      local spans, complete = expand_on(meta.same_file .. "%(3%)")
      -- Unlike every other scenario above, this one had no span-shape guard
      -- at all: `total:expand-failed` satisfies both `complete` and the
      -- `^total:` sum in elapsed_ms, so a silently-failing expansion would
      -- report a (fast) latency and pass. Require exactly one genuine
      -- `total:expand` span, same idiom as the other scenarios' guards.
      return complete and bench.count(spans, "^total:expand$") == 1 and bench.elapsed_ms(spans) or nil
    end,
  },
  {
    -- The counterpart to the clears above: this one deliberately does NOT
    -- clear, so it measures the path a user actually repeats -- returning to
    -- a name already looked up. It is guarded on `extract:cached` for the
    -- same reason the others are guarded on `extract:cold`/`extract:warm`:
    -- if the cache ever stops being consulted this population empties and
    -- says so, rather than quietly measuring a round trip and reporting a
    -- number that merely looks worse.
    name = "expand:cached",
    action = function()
      local spans, complete = expand_on(meta.warm[1] .. "%(")
      if complete and bench.count(spans, "^extract:cached") == 1 then
        return bench.elapsed_ms(spans)
      end
      return nil
    end,
  },
  {
    name = "inline:cached",
    action = function()
      local spans, complete = inline_on(meta.fn_call .. "%(")
      if complete and bench.count(spans, "^total:inline%-function") == 1
        and bench.count(spans, "^extract:cached") == 1 then
        return bench.elapsed_ms(spans)
      end
      return nil
    end,
  },
}

local measured = {}
for _, sc in ipairs(scenarios) do
  measured[sc.name] = bench.stats(bench.run(sc.action, { warmup = WARMUP, reps = REPS }))
end

-- The harness's own reproducibility, measured now rather than assumed: the
-- same scenario run as two independent populations. A difference smaller
-- than this is not a difference.
--
-- This is measured only from expand:warm (scenarios[2]) -- it is a single
-- global noise floor applied below to every scenario's tolerance, not a
-- per-scenario measurement. A scenario with different jitter characteristics
-- still gets this same number.
local noise = bench.noise_floor(scenarios[2].action, { warmup = WARMUP, reps = REPS })

-- `noise_floor` returns `math.huge` when either of its two populations came
-- back with zero usable samples (e.g. the calibration scenario's action
-- timed out on every rep). Left unguarded, `3 * math.huge` makes every
-- tolerance below infinite, so every comparison prints "ok ... tolerance
-- infms" -- a vacuous pass, not a measurement. Treat "not finite" as its own
-- case: the harness could not measure its own clock this run, which gets the
-- same timing-gate suspension as a run independently detected as noisy (see
-- below).
local function is_finite(x)
  return x == x and x ~= math.huge and x ~= -math.huge
end

print(("%-18s %4s %9s %9s %9s %9s"):format("scenario", "n", "p50", "p90", "mad", "max"))
print(string.rep("-", 64))
local has_excluded_row = false
for _, sc in ipairs(scenarios) do
  local s = measured[sc.name]
  -- inline:function and inline:macro exclude inliner.smart's pre-span
  -- whole-buffer concat and its call_name_at tree-sitter parse -- see the
  -- footnote below and bench.lua's elapsed_ms comment.
  local excluded = sc.name == "inline:function" or sc.name == "inline:macro"
  has_excluded_row = has_excluded_row or excluded
  local label = sc.name .. (excluded and "*" or "")
  if s.n > 0 then
    print(("%-18s %4d %8.1fms %8.1fms %8.1fms %8.1fms"):format(label, s.n, s.p50, s.p90, s.mad, s.max))
  else
    print(("%-18s %4d  (no usable samples)"):format(label, 0))
  end
end
if has_excluded_row then
  print("* excludes inliner.smart's pre-span whole-buffer concat and call_name_at tree-sitter parse"
    .. " (~0.4ms on this fixture, ~15% of the number; larger on real files) -- these run before the"
    .. " total: span starts. See bench.lua's elapsed_ms comment.")
end
if is_finite(noise) then
  print(("noise floor: %.2fms (p50 gap between two runs of expand:warm)"):format(noise))
else
  print("noise floor: unmeasurable (both populations of the calibration scenario produced zero"
    .. " usable samples this run) -- the harness could not measure its own clock")
end

-- Baseline comparison. The structural invariants above are the pass/fail
-- gate regardless of machine speed; these timings are a report against that
-- gate ONLY when the run's own clock can be trusted. No tolerance formula
-- can be made load-invariant: a contended machine and a genuine regression
-- widen the exact same measurements, including the calibration scenario
-- itself (an injected 10ms delay on the shared completion path moves
-- expand:warm's own p50 from 1.2ms to 11.2ms, right along with everything
-- else it touches). So instead of trying to build a tolerance that widens
-- for load but not for a regression, a run already flagged noisy (see
-- `noisy` below) has its vs-baseline timing comparisons downgraded to WARN
-- and cannot fail the run on timing alone -- only the structural invariants
-- above, which do not depend on the clock, still can.
local baseline_path = root .. "/tests/bench_baseline.json"

-- A comparison against a handful of samples is not a comparison: p50 over
-- n=1 or n=2 is a single draw from a right-skewed distribution and will
-- swing far more than any tolerance worth setting. Below this, the run
-- FAILS with "not compared" rather than quietly passing on noise. (The old
-- `s.n > 0` guard admitted n=1, which the plan's own rules forbid.) The same
-- floor applies to what a baseline is allowed to RECORD: a baseline itself
-- built from fewer than MIN_SAMPLES samples poisons every comparison made
-- against it later, so both the write path and the read path enforce it.
local MIN_SAMPLES = 5

-- Both terms below were re-derived from measurement after `elapsed_ms` was
-- fixed to sum the `total:` spans. The previous 25%/2ms pair was tuned
-- against the vim.uv.now() derivation, which was counting event-loop tick
-- boundaries rather than latency, so it was fitted to numbers that did not
-- mean what they said -- two scenarios' baselines moved by 1.9x and 4.5x on
-- the fix alone. What follows is what the fixed metric actually does.
--
-- Method: record a baseline, then run the comparison 4 more times on an idle
-- machine. Observed p50 across those 5 populations (ms):
--
--   scenario          base    r1    r2    r3    r4   range   range/base
--   expand:cold       32.23  35.6  33.5  31.7  33.4  3.9ms     12.1%
--   inline:macro       3.92   4.1   4.1   3.9   3.9  0.2ms      5.1%
--   inline:function    2.45   2.6   2.6   2.6   2.5  0.15ms     6.1%
--   expand:warm        1.16   1.1   1.3   1.1   1.2  0.2ms     17.2%
--   expand:same-file   0.75   0.9   0.8   0.8   0.8  0.15ms    19.9%
--
-- Relative term. It only ever governs expand:cold -- for every other
-- scenario a fifth of a sub-4ms baseline lands under the floor. So the
-- number has to be chosen for expand:cold, whose worst run-to-run excursion
-- above baseline was +3.4ms (10.6%) and whose full range was 3.9ms (12.1%).
-- 20% gives a 6.4ms band: 1.9x the worst observed excursion and 1.6x the
-- full range -- clear of jitter, while still catching a fifth-slower cold
-- expansion. 15% (4.8ms) would sit only 1.2x above the observed range and
-- would flake. 25% (the old value) is 2.4x, more slack than the data asks
-- for, and would let an 8ms regression on the slowest scenario through.
local PCT_TOLERANCE = 0.20

-- Absolute floor, for the four scenarios whose entire p50 is under 4ms. The
-- worst idle-machine excursion above baseline was 0.2ms, so 1ms is 5x that
-- -- ample -- and it halves the smallest regression the gate can see on all
-- four fast scenarios versus the old 2ms floor.
--
-- This floor and the 3*noise term do NOT, between them, make the tolerance
-- safe to trust under load -- see the comment above `noisy` below for why,
-- and for what a 12-core-saturated run actually did to expand:cold and
-- inline:macro even with this floor and the 20% relative term both in
-- place.
local MIN_TOLERANCE_MS = 1

if os.getenv("IE_BENCH_WRITE_BASELINE") == "1" then
  -- Refuse outright rather than write a baseline that would poison every
  -- comparison made against it: either a scenario fell short of
  -- MIN_SAMPLES, or this run's own noise floor is unmeasurable (in which
  -- case recording it would also disable the noisy-run detection below for
  -- every future run compared against this baseline, since `noise >
  -- recorded_noise * 4` can never fire once `recorded_noise` itself is
  -- infinite).
  local short = {}
  for _, sc in ipairs(scenarios) do
    local s = measured[sc.name]
    if not s or s.n < MIN_SAMPLES then
      short[#short + 1] = ("%s (%d/%d samples)"):format(sc.name, s and s.n or 0, MIN_SAMPLES)
    end
  end
  if not is_finite(noise) then
    short[#short + 1] = "noise floor unmeasurable this run"
  end
  if #short > 0 then
    fails = fails + 1
    print("FAIL  refusing to write a baseline: " .. table.concat(short, "; ")
      .. " -- a baseline recorded on too few samples (or an unmeasured clock) poisons every"
      .. " later comparison")
  else
    -- Record enough to tell what produced these numbers: p50 alone cannot be
    -- audited later. `n` says whether the p50 is worth anything, `mad` says
    -- how spread the population was, and the commit + nvim version say which
    -- code and which runtime they came from.
    local commit = vim.trim(vim.fn.system({ "git", "rev-parse", "--short", "HEAD" }))
    if vim.v.shell_error ~= 0 then
      commit = "unknown"
    else
      -- A baseline recorded with uncommitted changes names a commit that did
      -- not actually produce these numbers. Mark it rather than silently
      -- misattribute the measurement to a clean tree.
      local dirty = vim.fn.system({ "git", "status", "--porcelain" })
      if vim.v.shell_error == 0 and vim.trim(dirty) ~= "" then
        commit = commit .. "-dirty"
      end
    end
    local v = vim.version()
    local out = {
      recorded = os.date("%Y-%m-%d"),
      commit = commit,
      nvim = ("%d.%d.%d"):format(v.major, v.minor, v.patch),
      noise_floor_ms = noise,
      scenarios = {},
    }
    for name, s in pairs(measured) do
      if s.n >= MIN_SAMPLES then
        out.scenarios[name] = { p50 = s.p50, n = s.n, mad = s.mad }
      end
    end
    local f = assert(io.open(baseline_path, "w"))
    f:write(vim.json.encode(out))
    f:close()
    print("baseline written: " .. baseline_path)
  end
elseif vim.fn.filereadable(baseline_path) == 1 then
  local base = vim.json.decode(table.concat(vim.fn.readfile(baseline_path), "\n"))
  print("")
  print(("=== vs baseline recorded %s (commit %s, nvim %s) ===")
    :format(tostring(base.recorded), tostring(base.commit or "?"), tostring(base.nvim or "?")))

  if not TIMING_GATE then
    print("WARN  IE_BENCH_TIMING_GATE=0: vs-baseline timing comparisons below cannot fail the run"
      .. " regardless of noise; only the structural invariants above gate it.")
  end

  local recorded_noise = base.noise_floor_ms or 0
  -- `noisy` covers two ways this run's clock cannot be trusted: it could not
  -- be measured at all (non-finite noise), or it measured four times noisier
  -- than the run the baseline was recorded on. Reproduced on a 12-core-
  -- saturated machine: this WARN fired correctly (1.31ms vs 0.15ms) but,
  -- before this fix, that was all it did -- the comparison below still went
  -- on to FAIL expand:cold (32.0 -> 100.5ms against a 6.4ms band: the
  -- relative term is pinned to expand:cold's own baseline, which a
  -- contended machine does not widen) and inline:macro (3.8 -> 9.4ms
  -- against 3*noise's 3.9ms band: it scales faster under load than
  -- expand:warm, the ~1.2ms scenario the noise floor is calibrated on).
  -- Meanwhile expand:warm, expand:same-file and inline:function -- all
  -- close in magnitude to the calibration scenario -- passed under that
  -- same 3*noise band. That split is exactly why no single tolerance
  -- formula can be trusted here: once a run is this noisy, a timing
  -- comparison cannot tell "the machine is slow" from "the code is slow",
  -- so it is suspended rather than allowed to fail (or vacuously pass) the
  -- run. The structural invariants above do not depend on the clock and are
  -- unaffected.
  local noisy = (not is_finite(noise)) or (noise > recorded_noise * 4 and noise >= 1)
  if noisy then
    if not is_finite(noise) then
      print("WARN  this run's noise floor could not be measured (the calibration scenario produced"
        .. " zero usable samples in one or both populations); timings below are unreliable")
    else
      print(("WARN  this run is noisy (%.2fms vs %.2fms when recorded); timings below are unreliable")
        :format(noise, recorded_noise))
    end
    print("WARN  timing gate suspended for this run: the harness could not trust its own clock, so"
      .. " the vs-baseline timing comparisons below are reported as warnings and cannot fail the"
      .. " run; the structural invariants above still applied and still gate it.")
  end

  -- Iterate the BASELINE's scenarios, not the measured ones. A scenario that
  -- the baseline knows about but that produced no usable samples this run is
  -- a broken scenario -- it used to print nothing at all and slip through
  -- the gate silently, which is exactly how a harness stops measuring
  -- without anyone noticing.
  local names = {}
  for name in pairs(base.scenarios or {}) do
    names[#names + 1] = name
  end
  table.sort(names)

  for _, name in ipairs(names) do
    local b = base.scenarios[name]
    if (b.n or 0) < MIN_SAMPLES then
      -- Defensive: the write path above now refuses to record a scenario
      -- below MIN_SAMPLES, but a baseline can predate that guard or be
      -- hand-edited (this is exactly the stale-baseline-n path the audit
      -- exercises with a phantom scenario). Comparing against a p50 that was
      -- itself an unreliable draw is worse than not comparing at all, so
      -- this always fails -- it is a baseline-provenance problem, not a
      -- clock-trust one, and is not suspended by `noisy`.
      fails = fails + 1
      print(("FAIL  %-18s BASELINE UNTRUSTWORTHY: recorded with %d sample(s), need %d -- re-record"
        .. " the baseline before comparing")
        :format(name, b.n or 0, MIN_SAMPLES))
    else
      local s = measured[name] or { n = 0 }
      if s.n < MIN_SAMPLES then
        fails = fails + 1
        print(("FAIL  %-18s NOT COMPARED: %d usable sample(s), need %d (baseline p50 %.1fms). %s")
          :format(name, s.n, MIN_SAMPLES,
            b.p50 or 0,
            s.n == 0 and "The scenario produced nothing -- its action returned nil every rep (incomplete capture, or its span-shape guard never matched)."
              or "Too few reps completed to form a p50 worth comparing."))
      else
        local by_noise = is_finite(noise) and (3 * noise) or 0
        local by_pct, by_floor = b.p50 * PCT_TOLERANCE, MIN_TOLERANCE_MS
        local tolerance = math.max(by_noise, by_pct, by_floor)
        local provenance = tolerance == by_floor and "floor"
          or (by_noise > 0 and tolerance == by_noise and "3xnoise" or ("%d%%"):format(PCT_TOLERANCE * 100))
        local delta = s.p50 - b.p50
        local line = ("%-18s %8.1fms -> %8.1fms  (%+.1fms, tolerance %.1fms [%s], n=%d)")
          :format(name, b.p50, s.p50, delta, tolerance, provenance, s.n)
        if delta > tolerance then
          if noisy or not TIMING_GATE then
            print("WARN  " .. line)
          else
            fails = fails + 1
            print("FAIL  " .. line)
          end
        else
          print("ok    " .. line)
        end
      end
    end
  end

  -- A scenario the baseline has never seen is not a failure, but it is not
  -- compared either -- say so instead of leaving it out of the section.
  for _, sc in ipairs(scenarios) do
    if not (base.scenarios or {})[sc.name] then
      print(("note  %-18s not in the baseline; re-record to start gating it"):format(sc.name))
    end
  end
else
  print("")
  print("no baseline yet: re-run with IE_BENCH_WRITE_BASELINE=1 to record one")
end

print("")
print(fails == 0 and "ALL BENCH TESTS PASSED" or (fails .. " FAILURE(S)"))
