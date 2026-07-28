-- Real-source compile-correctness test: clone a real OSS C project (cJSON) and,
-- for every in-file call to a same-file static function, apply "correct"-mode
-- inline substitution, then rebuild AND run the project's tests. The contract:
-- whenever the engine returns a transform, the result must compile and pass.
--
-- Requires: git + network + gcc. Skips cleanly if any is missing.
--
--   nvim --headless --clean -u NONE -c "luafile tests/real_cjson_spec.lua" -c "qa!"

local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local S = require("inline-explorer.substitute")

local function skip(msg)
  print("SKIP: " .. msg)
end

if vim.fn.executable("git") == 0 or vim.fn.executable("gcc") == 0 then
  return skip("git or gcc not available")
end

local work = vim.fn.tempname()
vim.fn.mkdir(work, "p")
local dir = work .. "/cJSON"
local clone = vim.fn.system({ "git", "clone", "--depth", "1", "https://github.com/DaveGamble/cJSON.git", dir })
if vim.v.shell_error ~= 0 then
  return skip("clone failed (offline?)\n" .. clone)
end
if vim.fn.filereadable(dir .. "/cJSON.c") == 0 or vim.fn.filereadable(dir .. "/test.c") == 0 then
  return skip("unexpected cJSON layout")
end

local cfile = dir .. "/cJSON.c"
local function read(p)
  local f = assert(io.open(p, "r"))
  local s = f:read("*a")
  f:close()
  return s
end
local function write(p, s)
  local f = assert(io.open(p, "w"))
  f:write(s)
  f:close()
end
local src0 = read(cfile)

-- Baseline must build and pass before we trust any comparison.
local base = vim.fn.system({ "gcc", "-std=c99", cfile, dir .. "/test.c", "-o", work .. "/base", "-lm" })
if vim.v.shell_error ~= 0 then
  return skip("baseline build failed\n" .. base)
end
vim.fn.system({ work .. "/base" })
if vim.v.shell_error ~= 0 then
  return skip("baseline test failed")
end

-- Enumerate: static function definitions (name -> text) and in-file call sites.
local function root_of(s)
  return vim.treesitter.get_string_parser(s, "c"):parse()[1]:root()
end
local function text(n, s)
  local _, _, a, _, _, b = n:range(true)
  return s:sub(a + 1, b)
end
local function captures(node, s, q)
  local o = {}
  for _, n in vim.treesitter.query.parse("c", q):iter_captures(node, s) do
    o[#o + 1] = n
  end
  return o
end

local root = root_of(src0)
local defs = {}
for _, nm in ipairs(captures(root, src0, "(function_declarator declarator: (identifier) @n)")) do
  local fn = nm
  while fn and fn:type() ~= "function_definition" do
    fn = fn:parent()
  end
  if fn then
    local name = text(nm, src0)
    defs[name] = defs[name] or text(fn, src0)
  end
end
local calls = {}
for _, f in ipairs(captures(root, src0, "(call_expression function: (identifier) @f)")) do
  local name = text(f, src0)
  if defs[name] then
    local r, c = f:range(true)
    calls[#calls + 1] = { name = name, row = r, col = c }
  end
end

local attempted, accepted, passed, failures = 0, 0, 0, {}
for i, call in ipairs(calls) do
  attempted = attempted + 1
  local ok, new = pcall(S.inline_in_buffer, src0, call.row, call.col, defs[call.name], i, "correct")
  if ok and new and new ~= src0 then
    accepted = accepted + 1
    write(cfile, new)
    local build = vim.fn.system({ "gcc", "-std=c99", "-Wno-unused-label", cfile, dir .. "/test.c", "-o", work .. "/v", "-lm" })
    if vim.v.shell_error ~= 0 then
      failures[#failures + 1] = { call.name, "compile:\n" .. build:sub(1, 300) }
    else
      vim.fn.system({ work .. "/v" })
      if vim.v.shell_error ~= 0 then
        failures[#failures + 1] = { call.name, "runtime exit " .. vim.v.shell_error }
      else
        passed = passed + 1
      end
    end
    write(cfile, src0)
  end
end

print(("real cJSON: sites=%d  engine-accepted=%d  compiled+passed=%d"):format(attempted, accepted, passed))
if #failures > 0 then
  print(#failures .. " FAILURE(S):")
  for _, f in ipairs(failures) do
    print("  * " .. f[1] .. " -> " .. f[2])
  end
else
  print("ALL ACCEPTED TRANSFORMS COMPILE + PASS ON REAL cJSON")
end
