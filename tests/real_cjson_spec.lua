-- Real-source compile-correctness test: clone cJSON and, for every in-file
-- call to a same-file function, apply "correct"-mode inline substitution,
-- then rebuild AND run the project's tests. The contract: whenever the engine
-- returns a transform, the result must compile and pass.
--
-- Requires: git + network + gcc. Skips cleanly if any is missing.
--
--   nvim --headless --clean -u NONE -c "luafile tests/real_cjson_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local real = require("tests.lib.real_source")

real.run({
  name = "cJSON",
  url = "https://github.com/DaveGamble/cJSON.git",
  -- Pinned for the same reason as the zlib spec's `ref` (see
  -- real_zlib_spec.lua): cJSON's own default branch is not at its latest
  -- tag either (master carries commits past v1.7.19 as of this writing),
  -- so an unpinned clone is exposed to the exact same drift.
  ref = "v1.7.19",
  requires = { "cJSON.c", "test.c" },
  sources = { "cJSON.c" },
  -- Matches the one flag `verify` below actually compiles cJSON.c with,
  -- so the dead-branch check's own `gcc -E` run sees the same standard
  -- version (and therefore the same predefined macros) as the build being
  -- verified.
  cpp_flags = "-std=c99",
  verify = function(dir)
    return real.sh(
      "gcc -std=c99 -Werror=implicit-function-declaration -Wno-unused-label"
        .. " cJSON.c test.c -o ie_check -lm && ./ie_check",
      dir
    )
  end,
})
