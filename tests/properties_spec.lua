-- Fast property layer: run inline_call over generated cases and check
-- tree-sitter-verifiable invariants -- no gcc involved. ~300 cases per run
-- (override with IE_PROP_CASES), both output modes, deterministic seeds
-- (IE_PBT_SEED as the base). On failure, the offending case is shrunk and
-- printed with its seed for exact reproduction.
--   nvim --headless --clean -u NONE -c "luafile tests/properties_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local H = require("tests.lib.harness")
local gen = require("tests.lib.gen")
local T = require("tests.lib.inline")
local C = require("inline-explorer.csrc")

if not H.require_c_parser() then
  return
end

local N_CASES = tonumber(os.getenv("IE_PROP_CASES") or "") or 300
local BASE_SEED = tonumber(os.getenv("IE_PBT_SEED") or "") or 12345

local check = H.check

local function count_calls(src)
  local n = 0
  for _ in src:gmatch("f%(") do
    n = n + 1
  end
  return n
end

-- Does src actually contain a call_expression naming fname, per tree-sitter's
-- own parse? Zero-arg calls immediately wrapped as "(f()) & <lit>" (generator
-- context 9) hit a genuine C grammar ambiguity: tree-sitter-c has no semantic
-- type info, so it resolves the dangling-paren ambiguity as a cast_expression
-- (treating "f" as a type name via the abstract function declarator "()"),
-- not a call_expression -- confirmed by checking the same shape with 1+ args,
-- which parses as a call_expression every time. So the engine's "not found"
-- rejection in that narrow case is correct given the actual parse tree, not
-- an inline_call defect.
local function has_real_call(src, fname)
  return #C.find_calls(C.parse(src), src, fname, 1) > 0
end

-- Exemptions taken by violation() for the cast-vs-call ambiguity; printed at
-- the end so an erosion in the exemption rate stays visible.
local exempted = 0

-- One case, one mode. Returns nil if healthy, else a short violation tag.
local function violation(case, mode)
  local rc = gen.render(case)
  local new, err = T.inline_call(rc.caller_src, rc.callee_src, "f", 1, 1, mode)
  if not new then
    -- The engine may legitimately reject; but on our vocabulary it never
    -- should (no variadics, arity always matches) -- except the grammar-
    -- ambiguity artifact documented on has_real_call above, which is a
    -- generator/parser interaction, not an engine bug.
    if not has_real_call(rc.caller_src, "f") then
      exempted = exempted + 1
      return nil
    end
    return "rejected: " .. tostring(err)
  end
  if C.parse(new):has_error() then
    return "P-parse: transformed source has ERROR nodes"
  end
  if count_calls(new) ~= count_calls(rc.caller_src) - 1 then
    return "P-count: call count did not decrease by exactly 1"
  end
  return nil
end

-- P-parse + P-count over the whole case budget, both modes.
do
  local bad, bad_seed, bad_mode
  for i = 1, N_CASES do
    local seed = BASE_SEED + i
    for _, mode in ipairs({ "correct", "readable" }) do
      local case = gen.case(gen.rng(seed))
      local v = violation(case, mode)
      if v then
        bad, bad_seed, bad_mode = v, seed, mode
        local small = gen.shrink(case, function(c)
          return violation(c, mode) ~= nil
        end)
        local rc = gen.render(small)
        print("counterexample (seed=" .. seed .. ", mode=" .. mode .. "):")
        print(rc.callee_src)
        print(rc.caller_src)
        break
      end
    end
    if bad then
      break
    end
  end
  check(
    ("P-parse/P-count hold for %d cases x 2 modes"):format(N_CASES),
    bad == nil,
    bad and (bad .. " @seed=" .. bad_seed .. " mode=" .. bad_mode)
  )
end

-- P-unique: two inlinings with different N never share injected names.
-- Parse-only here; the gcc syntax check of the double-inlined program (a
-- shared injected name is a SEMANTIC duplicate declaration tree-sitter cannot
-- see) lives in the gcc layer, tests/pbt_spec.lua.
do
  local bad, bad_seed
  local n_unique = math.min(N_CASES, 100)
  for i = 1, n_unique do
    local seed = BASE_SEED + 7000 + i
    local case = gen.case(gen.rng(seed))
    local rc = gen.render(case)
    local two = gen.render_double(case)
    local once = T.inline_call(two, rc.callee_src, "f", 1, 1, "correct")
    if once then
      local twice = T.inline_call(once, rc.callee_src, "f", 2, 1, "correct")
      if twice and C.parse(twice):has_error() then
        bad, bad_seed = "second inlining produced ERROR nodes", seed
      end
    end
    if bad then
      break
    end
  end
  check(
    ("P-unique holds for %d double-inlining cases"):format(n_unique),
    bad == nil,
    bad and (bad .. " @seed=" .. bad_seed)
  )
end

-- P-reject-safe: bogus inputs return nil + err and never throw.
do
  local bad
  for i = 1, 50 do
    local seed = BASE_SEED + 9000 + i
    local case = gen.case(gen.rng(seed))
    local rc = gen.render(case)
    -- unknown function name
    local ok1, r1, e1 = pcall(T.inline_call, rc.caller_src, rc.callee_src, "nosuch", 1, 1, "correct")
    if not ok1 or r1 ~= nil or e1 == nil then
      bad = "unknown-name case misbehaved @seed=" .. seed
      break
    end
    -- arity mismatch: swap in a callee with one extra param
    local fat = rc.callee_src:gsub("static int f%(void%)", "static int f(int zz)")
    if fat == rc.callee_src then
      fat = rc.callee_src:gsub("static int f%(", "static int f(int zz, ", 1)
    end
    local ok2, r2, e2 = pcall(T.inline_call, rc.caller_src, fat, "f", 1, 1, "correct")
    if not ok2 or r2 ~= nil or e2 == nil then
      bad = "arity case misbehaved @seed=" .. seed .. " err=" .. tostring(e2)
      break
    end
  end
  check("P-reject-safe holds for 50 bogus-input cases", bad == nil, bad)
end

-- Utility roundtrip: rebase re-indents to the target, and the common prefix
-- of the result is that target.
do
  local bad
  for i = 1, 100 do
    local r = gen.rng(BASE_SEED + 11000 + i)
    local lines = {}
    local base = string.rep(" ", r.int(0, 6))
    for k = 1, r.int(1, 5) do
      lines[k] = base .. string.rep(" ", r.int(0, 4)) .. "x" .. k .. ";"
    end
    local frag = table.concat(lines, "\n")
    local target = string.rep(" ", r.int(0, 8))
    local out = C.reindent(frag, target)
    local nonblank = {}
    for _, l in ipairs(out) do
      if l:match("%S") then
        nonblank[#nonblank + 1] = l
      end
    end
    local prefix = C.common_ws_prefix(nonblank)
    if prefix:sub(1, #target) ~= target then
      bad = "roundtrip broke @case " .. i .. ": prefix=" .. vim.inspect(prefix) .. " target=" .. vim.inspect(target)
      break
    end
  end
  check("rebase x common_ws_prefix roundtrip holds for 100 fragments", bad == nil, bad)
end

print(("info  cast-vs-call exemptions taken: %d"):format(exempted))
H.finish("PROPERTY")
