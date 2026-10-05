-- Shared spec scaffolding: the PASS/FAIL line, the fail counter, the closing
-- banner, and the few one-liners every spec used to carry its own copy of.
--
-- The PASS/FAIL lines and the banners are an interface, not decoration:
-- .github/workflows/test.yml greps for "TESTS PASSED" and for the bare word
-- "FAILURE", so a label must never contain "FAILURE" and the banner text must
-- not change.
local M = {}

-- Number of failed checks so far. Read it; only check() should write it.
M.fails = 0

-- Print one PASS/FAIL line. `detail` is diagnostic only and is printed, on
-- failure, between ---- fences below the FAIL line: strings verbatim (they
-- are usually multi-line C or gcc output), anything else through vim.inspect.
function M.check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
    return
  end
  M.fails = M.fails + 1
  if detail == nil then
    print("FAIL  " .. label)
  else
    local d = type(detail) == "string" and detail or vim.inspect(detail)
    print("FAIL  " .. label .. "\n----\n" .. d .. "\n----")
  end
end

-- The closing banner: "ALL <NAME> TESTS PASSED", or "<n> FAILURE(S)" and a
-- non-zero exit (`cq`) so a failure is red even to a caller that never reads
-- the output. On success it returns and leaves the exit to the caller's
-- `-c "qa!"`.
function M.finish(name)
  print("")
  if M.fails == 0 then
    print("ALL " .. name .. " TESTS PASSED")
  else
    print(M.fails .. " FAILURE(S)")
    vim.cmd("cq")
  end
end

-- The tree-sitter C parser ships with Neovim, but a stripped build may lack
-- it. Prints the SKIP line and returns false when it is unavailable:
--   if not H.require_c_parser() then return end
function M.require_c_parser()
  if pcall(vim.treesitter.get_string_parser, "int x;", "c") then
    return true
  end
  print("SKIP: c parser unavailable")
  return false
end

function M.writef(path, s)
  local f = assert(io.open(path, "w"))
  f:write(s)
  f:close()
end

-- A fresh, existing directory under nvim's per-session temp dir (removed when
-- nvim exits -- do not put anything there that must outlive the run).
function M.tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

return M
