-- Differential property layer: build and RUN each generated program before
-- and after inline substitution; stdout must match exactly. Also renders the
-- canonical printer alongside a pretty-decided transform and requires the
-- same output -- a direct check that decide()'s safety analysis is sound.
-- readable mode is compile-only (documented as not semantics-preserving).
--
--   IE_PBT_CASES=N   number of cases (default 30)
--   IE_PBT_SEED=S    base seed (default 12345)
--
--   nvim --headless --clean -u NONE -c "luafile tests/pbt_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local H = require("tests.lib.harness")
local check = H.check
local cc = require("tests.lib.cc")
local gen = require("tests.lib.gen")
local T = require("tests.lib.inline")
local C = require("inline-explorer.csrc")

if vim.fn.executable("gcc") == 0 then
  print("SKIP: gcc not found")
  return
end
if not H.require_c_parser() then
  return
end

local N_CASES = tonumber(os.getenv("IE_PBT_CASES") or "") or 30
local BASE_SEED = tonumber(os.getenv("IE_PBT_SEED") or "") or 12345

local tmp = H.tmpdir()
local n_built = 0

-- Compile and run `src`; returns (stdout, exit_code) or (nil, gcc_output).
local function build_run(src, tag)
  n_built = n_built + 1
  local c = tmp .. "/" .. tag .. "_" .. n_built
  return cc.build_run(src, c .. ".c", c .. ".out")
end

-- Substitute rc's call in the caller and rebuild the whole program.
local function program_with(rc, new_caller)
  return rc.callee_src .. "\n" .. new_caller .. "\n" .. rc.main_src
end

-- Does src actually contain a call_expression naming fname, per tree-sitter's
-- own parse? Zero-arg calls immediately wrapped as "(f()) & <lit>" (generator
-- context 9) hit a genuine C grammar ambiguity: tree-sitter-c has no semantic
-- type info, so it resolves the dangling-paren ambiguity as a cast_expression
-- (treating "f" as a type name via the abstract function declarator "()"),
-- not a call_expression -- confirmed by checking the same shape with 1+ args,
-- which parses as a call_expression every time. So the engine's "not found"
-- rejection in that narrow case is correct given the actual parse tree, not
-- an inline_call defect. Same exemption as tests/properties_spec.lua.
local function has_real_call(src, fname)
  return #C.find_calls(C.parse(src), src, fname, 1) > 0
end

-- Exemptions taken for the cast-vs-call ambiguity; reported at the end.
local exempted = 0
-- Originals that failed to build (generator defect, not an engine bug);
-- reported at the end so a generator regression cannot hide in silence.
local skipped_unbuildable = 0

-- The differential for one case. Returns nil if healthy, else a violation tag.
local function violation(case)
  local rc = gen.render(case)
  local base_out, base_code = build_run(rc.program_src, "orig")
  if base_out == nil then
    skipped_unbuildable = skipped_unbuildable + 1
    return nil -- original does not build: generator edge, not an engine bug; skip
  end

  local new, err = T.inline_call(rc.caller_src, rc.callee_src, "f", 1, 1, "correct")
  if not new then
    -- The engine may legitimately reject; but on our vocabulary it never
    -- should (no variadics, arity always matches) -- except the grammar-
    -- ambiguity artifact documented on has_real_call above, which is a
    -- generator/parser interaction, not an engine bug.
    if not has_real_call(rc.caller_src, "f") then
      exempted = exempted + 1
      return nil
    end
    return "engine rejected a well-formed case: " .. tostring(err)
  end
  local t_out, t_code = build_run(program_with(rc, new), "corr")
  if t_out == nil then
    return "correct-mode output does not compile:\n" .. tostring(t_code)
  end
  if t_out ~= base_out or t_code ~= base_code then
    return "correct-mode stdout/exit differs from the original"
  end

  -- Structure property: when decide() chose pretty, the canonical rendering
  -- of the very same call must agree as well.
  local probe = T.probe(rc.caller_src, rc.callee_src, "f", 1, "correct")
  if probe and probe.decision == "pretty" then
    local canon, cerr = T.render(rc.caller_src, rc.callee_src, "f", 1, 1, "canonical")
    if not canon then
      -- A nil here must not silently disable the structure property.
      return "canonical rendering unavailable: " .. tostring(cerr)
    end
    local c_out, c_code = build_run(program_with(rc, canon), "canon")
    if c_out == nil then
      return "canonical rendering does not compile:\n" .. tostring(c_code)
    end
    if c_out ~= base_out or c_code ~= base_code then
      return "canonical rendering disagrees with the original"
    end
  end
  return nil
end

local readable_compiled, readable_total = 0, 0
local bad, bad_seed

for i = 1, N_CASES do
  local seed = BASE_SEED + 100000 + i
  local case = gen.case(gen.rng(seed))
  local v = violation(case)
  if v then
    bad, bad_seed = v, seed
    local small = gen.shrink(case, function(c)
      return violation(c) ~= nil
    end)
    local rc = gen.render(small)
    -- NOT under `tmp`: vim.fn.tempname() lives in nvim's per-session scratch
    -- directory, which nvim deletes on exit -- the artifact must outlive the
    -- headless run. Default to the cwd (the repo root under the documented
    -- invocation); override with IE_PBT_DUMP_DIR.
    local dump_dir = os.getenv("IE_PBT_DUMP_DIR") or vim.fn.getcwd()
    local cx = dump_dir .. "/pbt_counterexample_" .. seed .. ".c"
    H.writef(cx, rc.program_src)
    print("counterexample (seed=" .. seed .. ") saved to: " .. cx)
    print(rc.callee_src)
    print(rc.caller_src)
    break
  end

  -- readable: compile-only statistics, never a failure (documented trade-off)
  local rc = gen.render(case)
  local readable = T.inline_call(rc.caller_src, rc.callee_src, "f", 1, 1, "readable")
  if readable then
    readable_total = readable_total + 1
    local r_out = build_run(program_with(rc, readable), "read")
    if r_out ~= nil then
      readable_compiled = readable_compiled + 1
    end
  end
end

if bad then
  check("differential property @seed=" .. bad_seed .. ": " .. bad, false)
else
  check(("differential property holds for %d cases (gcc builds: %d)"):format(N_CASES, n_built), true)
end

-- P-unique, gcc half (moved from the fast layer to keep it gcc-free): the
-- double-inlined caller must survive a real syntax check -- a shared injected
-- name would be a duplicate declaration in one scope, invisible to
-- tree-sitter.
do
  local ubad, ubad_seed
  for i = 1, 20 do
    local seed = BASE_SEED + 7000 + i
    local case = gen.case(gen.rng(seed))
    local rc = gen.render(case)
    local two = gen.render_double(case)
    local once = T.inline_call(two, rc.callee_src, "f", 1, 1, "correct")
    local twice = once and T.inline_call(once, rc.callee_src, "f", 2, 1, "correct")
    if twice then
      local ok, out = cc.syntax_ok(tmp .. "/uniq" .. i .. ".c", rc.callee_src .. "\n" .. twice .. "\n" .. rc.main_src)
      if not ok then
        ubad, ubad_seed = out, seed
        break
      end
    end
  end
  if ubad then
    check("double-inlining uniqueness @seed=" .. ubad_seed .. ":", false, ubad)
  else
    check("double-inlined programs survive gcc syntax checks (20 cases)", true)
  end
end
print(("info  readable mode compiled %d/%d (compile-only, never failing)"):format(readable_compiled, readable_total))
print(("info  cast-vs-call exemptions taken: %d"):format(exempted))
print(("info  unbuildable originals skipped: %d"):format(skipped_unbuildable))

H.finish("PBT")
