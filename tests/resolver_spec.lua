-- Resolver unit tests: LSP documentSymbol range selection (_symbol_range) and
-- the table-free tree-sitter fallback (extract_sync / async extract).
--   nvim --headless --clean -u NONE -c "luafile tests/resolver_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local resolver = require("inline-explorer.resolver")

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
    print("FAIL  " .. l .. (d and (" (" .. vim.inspect(d) .. ")") or ""))
  end
end

local function range(sl, sc, el, ec)
  return { start = { line = sl, character = sc }, ["end"] = { line = el, character = ec } }
end

-- _symbol_range: hierarchical DocumentSymbol[] -- the deepest symbol containing
-- the reference wins, and function-ish kinds map to "function_definition".
do
  local symbols = {
    {
      name = "MyClass",
      kind = 5, -- Class
      range = range(0, 0, 20, 1),
      selectionRange = range(0, 6, 0, 13),
      children = {
        { name = "method", kind = 6, range = range(2, 2, 5, 3), selectionRange = range(2, 6, 2, 12) },
      },
    },
  }
  local ref = range(2, 6, 2, 12) -- workspace/symbol points at the method's name
  local r, label = resolver._symbol_range(symbols, ref, "method")
  check("hierarchical: deepest symbol range wins", r and r.start.line == 2 and r["end"].line == 5, r)
  check("hierarchical: Method kind -> function_definition", label == "function_definition", label)
end

-- _symbol_range: non-function kinds keep a lowercase kind label.
do
  local symbols = {
    { name = "S", kind = 23, range = range(0, 0, 3, 1), selectionRange = range(0, 7, 0, 8), children = {} },
  }
  local r, label = resolver._symbol_range(symbols, range(0, 7, 0, 8), "S")
  check("hierarchical: Struct kind -> 'struct' label", label == "struct", label)
  check("hierarchical: struct full range", r and r["end"].line == 3, r)
end

-- _symbol_range: flat SymbolInformation[] -- name-matched containing range;
-- a range identical to the reference (name-only) is rejected.
do
  local flat = {
    { name = "other", kind = 12, location = { uri = "file:///x.c", range = range(0, 0, 4, 1) } },
    { name = "f", kind = 12, location = { uri = "file:///x.c", range = range(6, 0, 9, 1) } },
  }
  local r = resolver._symbol_range(flat, range(6, 11, 6, 12), "f")
  check("flat: name-matched containing range", r and r.start.line == 6 and r["end"].line == 9, r)
  local name_only = { { name = "g", kind = 12, location = { uri = "file:///x.c", range = range(3, 4, 3, 5) } } }
  check("flat: name-only range rejected", resolver._symbol_range(name_only, range(3, 4, 3, 5), "g") == nil)
end

-- extract_sync: header-defined function (no LSP, no node-type table) must
-- still extract the full definition with label "function_definition".
do
  local hpath = vim.fn.tempname() .. ".h"
  local f = assert(io.open(hpath, "w"))
  f:write("static __always_inline int acc(int cpu)\n{\n    return per_cpu(cpu) & MASK;\n}\n")
  f:close()
  local col = ("static __always_inline int acc(int cpu)"):find("acc") - 1
  local lines, label = resolver.extract_sync({ uri = vim.uri_from_fname(hpath), range = range(0, col, 0, col) })
  check("extract_sync: header function -> function_definition", label == "function_definition", tostring(label))
  check("extract_sync: body includes the return", table.concat(lines, "\n"):find("return per_cpu", 1, true) ~= nil)
end

-- extract_sync: macro definition -> a preproc node type, continuation kept.
do
  local cpath = vim.fn.tempname() .. ".c"
  local f = assert(io.open(cpath, "w"))
  f:write("#define TWICE(x) \\\n    ((x) + (x))\nint y;\n")
  f:close()
  local lines, label = resolver.extract_sync({ uri = vim.uri_from_fname(cpath), range = range(0, 8, 0, 13) })
  check("extract_sync: macro label is a preproc node", type(label) == "string" and label:find("preproc") ~= nil, label)
  check("extract_sync: continuation line kept", table.concat(lines, "\n"):find("(x) + (x)", 1, true) ~= nil)
end

-- extract (async wrapper): with no LSP attached it falls back to extract_sync
-- and calls cb synchronously.
do
  local hpath = vim.fn.tempname() .. ".h"
  local f = assert(io.open(hpath, "w"))
  f:write("static int one(void)\n{\n    return 1;\n}\n")
  f:close()
  local got_lines, got_label
  resolver.extract({ uri = vim.uri_from_fname(hpath), range = range(0, 11, 0, 14) }, 0, function(lines, label)
    got_lines, got_label = lines, label
  end)
  vim.wait(200, function()
    return got_lines ~= nil
  end, 10)
  check("extract: no-LSP path falls back", got_label == "function_definition", tostring(got_label))
  check("extract: fallback returned the body", got_lines ~= nil and table.concat(got_lines, "\n"):find("return 1", 1, true) ~= nil)
end

-- extract_sync: include-guarded header must not swallow the whole guard.
-- The definition here is a ONE-LINE function specifically so this test pins
-- the CONTAINER_NODES denylist itself: with the outermost-in-window walk
-- and an empty denylist, a multi-line body would still happen to stop at
-- the function_definition (its parent, translation_unit, is the loop-exit
-- root) even without the guard against ascending into the preproc_ifdef --
-- but a one-line function's function_definition node is a plausible
-- "outermost in window" candidate all the way up through the #ifndef itself
-- (which also starts within the window), so only the denylist stops the
-- ascent there and keeps the whole header out of the result.
do
  local hpath = vim.fn.tempname() .. ".h"
  local f = assert(io.open(hpath, "w"))
  f:write("#ifndef FOO_H\n#define FOO_H\nstatic int acc(int cpu) { return cpu + 1; }\n#endif\n")
  f:close()
  local col = ("static int acc(int cpu)"):find("acc") - 1
  local lines, label = resolver.extract_sync({ uri = vim.uri_from_fname(hpath), range = range(2, col, 2, col) })
  check("extract_sync: include guard -> function_definition, not the guard", label == "function_definition", tostring(label))
  local body = lines and table.concat(lines, "\n") or ""
  check(
    "extract_sync: include guard body is exactly the 1 function line",
    lines ~= nil and #lines == 1 and body:find("acc", 1, true) ~= nil,
    lines
  )
  check("extract_sync: include guard body excludes #ifndef", not body:find("#ifndef", 1, true))
  check("extract_sync: include guard body excludes #endif", not body:find("#endif", 1, true))
end

-- extract_sync: a multi-line parameter list must not truncate the
-- definition to its signature. Regression test for a bug in the first
-- version of this fix: an "innermost ancestor that spans multiple lines"
-- pass picked the function_declarator (identifier + multi-line parameter
-- list) instead of the function_definition, dropping the body and mislabeling
-- the result. The walk now only ever takes the OUTERMOST ancestor in the
-- window, so it climbs past the declarator to the full definition.
do
  local cpath = vim.fn.tempname() .. ".c"
  local f = assert(io.open(cpath, "w"))
  f:write("int add(\n    int a,\n    int b)\n{ return a + b; }\n")
  f:close()
  local lines, label = resolver.extract_sync({ uri = vim.uri_from_fname(cpath), range = range(0, 4, 0, 4) })
  check("extract_sync: multi-line parameter list -> function_definition", label == "function_definition", tostring(label))
  check("extract_sync: multi-line parameter list keeps all 4 lines", lines ~= nil and #lines == 4, lines)
  check(
    "extract_sync: multi-line parameter list body includes the return",
    lines ~= nil and table.concat(lines, "\n"):find("return a + b", 1, true) ~= nil,
    lines
  )
end

-- _symbol_range: hierarchical DocumentSymbol whose range equals ref_range
-- must still be accepted -- DocumentSymbol.range is full-range by spec, so
-- the name-only rejection must not apply here (only to flat
-- SymbolInformation, where location.range really can be name-only).
do
  local symbols = {
    { name = "f", kind = 12, range = range(2, 0, 5, 1), selectionRange = range(2, 11, 2, 12) },
  }
  local ref = range(2, 0, 5, 1)
  local r, label = resolver._symbol_range(symbols, ref, "f")
  check(
    "hierarchical: range equal to ref_range is accepted (full-range by spec)",
    r ~= nil and r.start.line == 2 and r["end"].line == 5,
    r
  )
  check("hierarchical: equal-range symbol still labeled function_definition", label == "function_definition", label)
end

-- _symbol_range: flat SymbolInformation whose location.uri differs from the
-- requested document must be ignored.
do
  local flat = {
    { name = "f", kind = 12, location = { uri = "file:///elsewhere.c", range = range(6, 0, 9, 1) } },
  }
  local r = resolver._symbol_range(flat, range(6, 11, 6, 12), "f", "file:///x.c")
  check("flat: cross-file uri is rejected", r == nil, r)
end

-- _symbol_range: vim.NIL (JSON null) children must not throw.
do
  local symbols = {
    { name = "f", kind = 12, range = range(0, 0, 2, 1), selectionRange = range(0, 4, 0, 5), children = vim.NIL },
  }
  local ok, r = pcall(resolver._symbol_range, symbols, range(1, 0, 1, 1), "f")
  check("_symbol_range: vim.NIL children do not error", ok, r)
  check(
    "_symbol_range: vim.NIL children -> range still returned",
    ok and r ~= nil and r.start.line == 0 and r["end"].line == 2,
    r
  )
end

-- Timeout: a wedged server (accepts requests, never replies) must not starve
-- the callbacks -- locate reports a timeout error, extract falls back to
-- extract_sync. Uses an in-process LSP server that swallows everything after
-- the initialize handshake.
do
  local hpath = vim.fn.tempname() .. ".h"
  local f = assert(io.open(hpath, "w"))
  f:write("static int wedge_fn(void)\n{\n    return 9;\n}\n")
  f:close()

  vim.cmd.edit(hpath)
  local src_buf = vim.api.nvim_get_current_buf()
  local client_id = vim.lsp.start({
    name = "wedge",
    cmd = function(dispatchers)
      local closing = false
      local next_id = 0
      return {
        request = function(method, _, callback)
          next_id = next_id + 1
          if method == "initialize" then
            callback(nil, {
              capabilities = {
                documentSymbolProvider = true,
                workspaceSymbolProvider = true,
              },
            })
          end
          -- every other request: accepted, never answered (the wedge)
          return true, next_id
        end,
        notify = function()
          return true
        end,
        is_closing = function()
          return closing
        end,
        terminate = function()
          closing = true
          dispatchers.on_exit(0, 0)
        end,
      }
    end,
    root_dir = vim.fn.fnamemodify(hpath, ":h"),
  })
  vim.wait(2000, function()
    return client_id ~= nil and #vim.lsp.get_clients({ bufnr = src_buf, name = "wedge" }) > 0
  end, 20)

  if #vim.lsp.get_clients({ bufnr = src_buf, name = "wedge" }) == 0 then
    print("SKIP  timeout checks (in-process LSP server unavailable)")
  else
    -- These checks exist to exercise the SERVER extraction path -- timeout,
    -- cold budget, retry -- which local-first C extraction would bypass
    -- entirely. It stays the live path for non-C-family languages, so
    -- forcing it here tests real code, not a dead branch.
    local saved_lf = resolver._local_first
    resolver._local_first = false
    local saved = resolver._timeout_ms
    resolver._timeout_ms = 300

    local loc_result, loc_err, loc_done
    resolver.locate("wedge_fn", src_buf, function(l, e)
      loc_result, loc_err, loc_done = l, e, true
    end)
    vim.wait(2000, function()
      return loc_done
    end, 20)
    check("locate: wedged server times out with an error", loc_done == true and loc_result == nil, loc_err)
    check("locate: timeout error names the cause", tostring(loc_err):find("timed out") ~= nil, tostring(loc_err))

    local col = ("static int wedge_fn(void)"):find("wedge_fn") - 1
    local got_lines, got_label
    resolver.extract(
      { uri = vim.uri_from_fname(hpath), range = range(0, col, 0, col), name = "wedge_fn" },
      src_buf,
      function(lines, label)
        got_lines, got_label = lines, label
      end
    )
    vim.wait(2000, function()
      return got_lines ~= nil
    end, 20)
    check("extract: wedged server falls back to extract_sync", got_label == "function_definition", tostring(got_label))

    -- A timeout must not be recorded as a successful extract. once_with_timeout
    -- routes its own result through the same callback as a real response, so
    -- labelling by stage recorded a wedged request as `extract:cold` whose
    -- duration was really just _timeout_ms: a real session log showed
    -- `extract:cold 4030.0ms` against a 4000ms timeout, which reads as the
    -- server having taken four seconds when it means we stopped waiting.
    do
      local profile = require("inline-explorer.profile")
      local was, wasfile = profile.enabled, profile.logfile
      profile.enabled, profile.logfile = true, false
      profile.clear()
      local done2 = false
      resolver.extract({ uri = vim.uri_from_fname(hpath),
        range = { start = { line = 0, character = 11 }, ["end"] = { line = 0, character = 19 } },
        kind = 12, name = "wedge_fn" }, src_buf, function() done2 = true end)
      vim.wait(3000, function() return done2 end, 5)
      local names = {}
      for _, e in ipairs(profile.events) do names[#names + 1] = e.name end
      local saw_timeout, saw_cold = false, false
      for _, n in ipairs(names) do
        if n == "extract:timeout" then saw_timeout = true end
        if n == "extract:cold" or n == "extract:warm" then saw_cold = true end
      end
      check("extract: a timeout is labelled as one, not as a cold extract",
        saw_timeout and not saw_cold, table.concat(names, ","))

      -- The first touch of a definition file must use the SHORT budget, not
      -- the general one. One number cannot serve both: an already-attached
      -- file answers in single-digit ms, while a first touch has to wait for
      -- a preamble -- and when that goes pathological the old single 4000ms
      -- budget bought nothing except four seconds of waiting before the same
      -- tree-sitter fallback the short budget reaches immediately.
      -- A SECOND header, never touched before: reusing the first one would
      -- measure the warm path, because extract attached it a moment ago.
      local hpath2 = vim.fn.tempname() .. ".h"
      local f2 = assert(io.open(hpath2, "w"))
      f2:write("static int wedge_fn2(void)\n{\n    return 8;\n}\n")
      f2:close()

      local saved_cold = resolver._cold_timeout_ms
      resolver._cold_timeout_ms = 120
      resolver._timeout_ms = 8000 -- must NOT be the one that governs here
      profile.clear()
      local done3, t3 = false, vim.uv.hrtime()
      resolver.extract({ uri = vim.uri_from_fname(hpath2),
        range = { start = { line = 0, character = 11 }, ["end"] = { line = 0, character = 20 } },
        kind = 12, name = "wedge_fn2" }, src_buf, function() done3 = true end)
      vim.wait(6000, function() return done3 end, 5)
      local waited = (vim.uv.hrtime() - t3) / 1e6
      check("extract: a first touch uses the cold budget, not the general one",
        done3 and waited < 2000, ("waited %.0fms (cold=%d general=%d)"):format(
          waited, resolver._cold_timeout_ms, resolver._timeout_ms))

      -- The retry probe must send a WELL-FORMED request. Its first version
      -- read `params` from inside the timeout closure while the local of
      -- that name was declared below it, so the name resolved to a global --
      -- nil -- and the probe sent documentSymbol with no textDocument. The
      -- server rejected that in single-digit milliseconds and the probe
      -- reported retry-failed, which read as evidence about the server when
      -- it was evidence about this file. The wedge server swallows the
      -- retry (never answers), so what this pins is the absence of the
      -- instant `retry-failed` that only a malformed request produces.
      vim.wait(500)
      local saw_retry_failed = false
      for _, e in ipairs(profile.events) do
        if e.name == "extract:retry-failed" then
          saw_retry_failed = true
        end
      end
      check("extract: the retry probe does not fail instantly on a malformed request",
        not saw_retry_failed,
        "extract:retry-failed recorded -- the probe's request is malformed again")

      -- A late answer must not be thrown away. A real kernel log showed a
      -- symbol whose first touch timed out costing another 89ms round trip
      -- on the next look, when the server's answer had arrived moments
      -- after the timeout and was discarded. The server below swallows the
      -- FIRST documentSymbol and answers every later one -- the same shape
      -- as a preamble finishing just after the budget -- so the retry's
      -- answer must land in the cache and the next fetch must be served
      -- without a new request.
      do
        local dpath3 = vim.fn.tempname() .. ".h"
        local f3 = assert(io.open(dpath3, "w"))
        f3:write("static int late_fn(void)\n{\n    return 4;\n}\n")
        f3:close()
        local uri3 = vim.uri_from_fname(vim.fn.resolve(dpath3))
        local ds_count, swallowed = 0, false
        vim.cmd.edit(dpath3)
        local src3 = vim.api.nvim_get_current_buf()
        local cid3 = vim.lsp.start({
          name = "late",
          cmd = function(dispatchers)
            local closing, next_id = false, 0
            return {
              request = function(method, _, callback)
                next_id = next_id + 1
                if method == "initialize" then
                  callback(nil, { capabilities = {
                    documentSymbolProvider = true, workspaceSymbolProvider = true } })
                elseif method == "textDocument/documentSymbol" then
                  ds_count = ds_count + 1
                  if ds_count == 1 then
                    swallowed = true -- first request: never answered
                  else
                    callback(nil, { {
                      name = "late_fn", kind = 12,
                      range = { start = { line = 0, character = 0 }, ["end"] = { line = 3, character = 1 } },
                      selectionRange = { start = { line = 0, character = 11 }, ["end"] = { line = 0, character = 18 } },
                    } })
                  end
                else
                  callback(nil, nil)
                end
                return true, next_id
              end,
              notify = function() return true end,
              is_closing = function() return closing end,
              terminate = function() closing = true; dispatchers.on_exit(0, 0) end,
            }
          end,
          root_dir = vim.fn.fnamemodify(dpath3, ":h"),
        })
        vim.wait(2000, function()
          return cid3 ~= nil and #vim.lsp.get_clients({ bufnr = src3, name = "late" }) > 0
        end, 20)

        if #vim.lsp.get_clients({ bufnr = src3, name = "late" }) == 0 then
          print("SKIP  retry-cache checks (in-process LSP server unavailable)")
        else
          resolver.clear_caches()
          resolver._cold_timeout_ms = 100
          resolver._timeout_ms = 100
          local loc3 = { uri = uri3,
            range = { start = { line = 0, character = 11 }, ["end"] = { line = 0, character = 18 } },
            kind = 12, name = "late_fn" }
          local done4 = false
          resolver.extract(loc3, src3, function() done4 = true end)
          vim.wait(4000, function() return done4 end, 5)
          -- allow the retry round trip to land
          vim.wait(2000, function() return ds_count >= 2 end, 10)
          vim.wait(200)
          check("retry cache: the retry reached the server", swallowed and ds_count >= 2,
            ("ds_count=%d"):format(ds_count))

          local before = ds_count
          local done5, lines5 = false, nil
          resolver.extract(loc3, src3, function(l) lines5 = l; done5 = true end)
          vim.wait(4000, function() return done5 end, 5)
          check("retry cache: the next fetch is served without a new request",
            done5 and ds_count == before, ("ds_count %d -> %d"):format(before, ds_count))
          check("retry cache: and returns the server's body, not the fallback",
            lines5 ~= nil and table.concat(lines5, "\n"):find("return 4", 1, true) ~= nil,
            vim.inspect(lines5))
          if cid3 then vim.lsp.stop_client(cid3, true) end
        end
      end
      resolver._cold_timeout_ms = saved_cold
      resolver._timeout_ms = 300
      profile.enabled, profile.logfile = was, wasfile
      profile.clear()
    end
    check("extract: fallback body intact", got_lines ~= nil and table.concat(got_lines, "\n"):find("return 9", 1, true) ~= nil)

    -- Attachment hygiene: definition-file attachments are cached (dropping
    -- them makes clangd rebuild the header's preamble on every repeat), and
    -- the least recently used entry beyond the capacity is detached.
    local saved_cap = resolver._attach_cache_n
    resolver._attach_cache_n = 1
    local function extract_temp_header(name, body)
      local hp = vim.fn.tempname() .. ".h"
      local fh = assert(io.open(hp, "w"))
      fh:write(body)
      fh:close()
      local done
      resolver.extract(
        { uri = vim.uri_from_fname(hp), range = range(0, 11, 0, 13), name = name },
        src_buf,
        function(lines)
          done = lines
        end
      )
      vim.wait(2000, function()
        return done ~= nil
      end, 20)
      return vim.uri_to_bufnr(vim.uri_from_fname(hp))
    end
    local t_a = extract_temp_header("other_fn", "static int other_fn(void)\n{\n    return 5;\n}\n")
    local kept = #vim.lsp.get_clients({ bufnr = t_a, name = "wedge" })
    check("extract: attachment cached after settling (no re-preamble)", kept > 0, "attached: " .. kept)
    local t_b = extract_temp_header("third_fn", "static int third_fn(void)\n{\n    return 6;\n}\n")
    local evicted = #vim.lsp.get_clients({ bufnr = t_a, name = "wedge" })
    local newest = #vim.lsp.get_clients({ bufnr = t_b, name = "wedge" })
    check("extract: LRU entry evicted beyond capacity", evicted == 0 and newest > 0,
      ("old=%d new=%d"):format(evicted, newest))
    resolver._attach_cache_n = saved_cap

    resolver._timeout_ms = saved
    resolver._local_first = saved_lf
    if client_id then
      vim.lsp.stop_client(client_id, true)
    end
  end
end


-- Result caching: a repeat lookup of the same name, against an unchanged
-- file, must not go back to the server -- and must stop doing so the moment
-- the definition's file changes. This is the difference between ~55ms and
-- ~0ms per invocation on real kernel source (linux-6.12, kernel/sched/core.c:
-- p50 60.1ms uncached vs 0.0ms cached, worst case 571ms vs 0.1ms), so the
-- checks below count SERVER REQUESTS, not elapsed time: a cache that merely
-- got lucky on timing would still pass a timing assertion.
do
  local dpath = vim.fn.tempname() .. ".c"
  local f = assert(io.open(dpath, "w"))
  f:write("int cached_fn(int a)\n{\n    return a + 1;\n}\n\nint caller(void) { return cached_fn(1); }\n")
  f:close()

  vim.cmd.edit(dpath)
  local src_buf = vim.api.nvim_get_current_buf()
  local uri = vim.uri_from_fname(vim.fn.resolve(dpath))
  local counts = { ["workspace/symbol"] = 0, ["textDocument/documentSymbol"] = 0 }

  local cid = vim.lsp.start({
    name = "counting",
    cmd = function(dispatchers)
      local closing, next_id = false, 0
      return {
        request = function(method, _, callback)
          next_id = next_id + 1
          if method == "initialize" then
            callback(nil, { capabilities = {
              documentSymbolProvider = true, workspaceSymbolProvider = true } })
          elseif method == "workspace/symbol" then
            counts[method] = counts[method] + 1
            callback(nil, { {
              name = "cached_fn", kind = 12,
              location = { uri = uri, range = {
                start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 13 } } },
            } })
          elseif method == "textDocument/documentSymbol" then
            counts[method] = counts[method] + 1
            callback(nil, { {
              name = "cached_fn", kind = 12,
              range = { start = { line = 0, character = 0 }, ["end"] = { line = 3, character = 1 } },
              selectionRange = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 13 } },
            } })
          else
            callback(nil, nil)
          end
          return true, next_id
        end,
        notify = function() return true end,
        is_closing = function() return closing end,
        terminate = function() closing = true; dispatchers.on_exit(0, 0) end,
      }
    end,
    root_dir = vim.fn.fnamemodify(dpath, ":h"),
  })
  vim.wait(2000, function()
    return cid ~= nil and #vim.lsp.get_clients({ bufnr = src_buf, name = "counting" }) > 0
  end, 20)

  if #vim.lsp.get_clients({ bufnr = src_buf, name = "counting" }) == 0 then
    print("SKIP  cache checks (in-process LSP server unavailable)")
  else
    -- The point of these checks is the SERVER-path result cache; C
    -- local-first extraction would answer without ever issuing the
    -- documentSymbol these counters count.
    local saved_lf2 = resolver._local_first
    resolver._local_first = false
    resolver.clear_caches()

    local function fetch_once()
      local done, got = false, nil
      resolver.fetch("cached_fn", src_buf, function(lines) got = lines; done = true end)
      vim.wait(3000, function() return done end, 5)
      return got
    end

    local first = fetch_once()
    local c1w, c1d = counts["workspace/symbol"], counts["textDocument/documentSymbol"]
    check("cache: first fetch reaches the server", c1w >= 1 and c1d >= 1,
      ("symbol=%d documentSymbol=%d"):format(c1w, c1d))
    check("cache: first fetch returns the body", first ~= nil and
      table.concat(first, "\n"):find("return a + 1", 1, true) ~= nil, vim.inspect(first))

    local second = fetch_once()
    check("cache: repeat fetch asks the server nothing",
      counts["workspace/symbol"] == c1w and counts["textDocument/documentSymbol"] == c1d,
      ("symbol=%d->%d documentSymbol=%d->%d"):format(c1w, counts["workspace/symbol"],
        c1d, counts["textDocument/documentSymbol"]))
    check("cache: repeat fetch returns the same body",
      second ~= nil and table.concat(second, "\n") == table.concat(first, "\n"))

    -- Editing the definition must retire the entry, not serve the old body.
    local tbuf = vim.uri_to_bufnr(uri)
    vim.fn.bufload(tbuf)
    vim.api.nvim_buf_set_lines(tbuf, 2, 3, false, { "    return a + 99;" })
    local third = fetch_once()
    check("cache: an edit to the definition goes back to the server",
      counts["textDocument/documentSymbol"] > c1d,
      ("documentSymbol=%d->%d"):format(c1d, counts["textDocument/documentSymbol"]))
    check("cache: an edit to the definition yields the NEW body",
      third ~= nil and table.concat(third, "\n"):find("return a + 99", 1, true) ~= nil,
      vim.inspect(third))

    -- Capacity is honoured rather than growing without bound.
    local saved_n = resolver._locate_cache_n
    resolver._locate_cache_n = 2
    resolver.clear_caches()
    for i = 1, 5 do
      local done = false
      resolver.locate("cached_fn_" .. i, src_buf, function() done = true end)
      vim.wait(2000, function() return done end, 5)
    end
    local n = 0
    for _ in pairs(resolver._locate_cache) do n = n + 1 end
    check("cache: locate cache is bounded by its capacity", n <= 2, ("entries=%d"):format(n))
    resolver._locate_cache_n = saved_n
    resolver._local_first = saved_lf2
    resolver.clear_caches()

    -- Local-first itself, against the same counting server: a C definition
    -- must be extracted without ANY documentSymbol round trip, and the
    -- result must be the real body. This is the root fix for the measured
    -- keypress-triggers-a-compile cost (400ms-4s per first-touched file on
    -- kernel trees); if this ever regresses to asking the server, that cost
    -- comes back exactly as it was.
    do
      resolver.clear_caches()
      local before_ds = counts["textDocument/documentSymbol"]
      local done6, lines6, label6 = false, nil, nil
      resolver.extract({ uri = uri,
        range = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 13 } },
        kind = 12, name = "cached_fn" }, src_buf, function(l, lb) lines6, label6 = l, lb; done6 = true end)
      vim.wait(3000, function() return done6 end, 5)
      check("local-first: a C definition never waits for documentSymbol",
        done6 and counts["textDocument/documentSymbol"] == before_ds,
        ("documentSymbol %d -> %d"):format(before_ds, counts["textDocument/documentSymbol"]))
      check("local-first: and yields the full definition with a node label",
        lines6 ~= nil and table.concat(lines6, "\n"):find("return a + 99", 1, true) ~= nil
          and label6 == "function_definition",
        ("label=%s lines=%s"):format(tostring(label6), vim.inspect(lines6)))
    end

    if cid then vim.lsp.stop_client(cid, true) end
  end
end

-- A name whose workspace/symbol answer is a header PROTOTYPE must not stop
-- there. clangd returns the canonical declaration for symbols like kfree
-- (declared in slab.h, defined in mm/slub.c), extraction faithfully
-- extracts what is at that location -- one prototype line -- and the reader
-- gets `void kfree(const void *objp);` labelled (declaration) instead of a
-- body. When extraction yields a declaration, fetch now chases
-- textDocument/definition once and extracts THERE; when the chase finds
-- nothing (no index), the prototype is still returned, labelled honestly.
do
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local hpath = dir .. "/api.h"
  local cpath = dir .. "/impl.c"
  local fh = assert(io.open(hpath, "w"))
  fh:write("void kfree_like(const void *objp);\n")
  fh:close()
  local fc = assert(io.open(cpath, "w"))
  fc:write("void kfree_like(const void *objp)\n{\n    (void)objp;\n}\n")
  fc:close()
  local huri = vim.uri_from_fname(vim.fn.resolve(hpath))
  local curi = vim.uri_from_fname(vim.fn.resolve(cpath))

  vim.cmd.edit(dir .. "/use.c")
  local src_buf = vim.api.nvim_get_current_buf()
  local def_requests = 0
  local cid = vim.lsp.start({
    name = "chase",
    cmd = function(dispatchers)
      local closing, next_id = false, 0
      return {
        request = function(method, params, callback)
          next_id = next_id + 1
          if method == "initialize" then
            callback(nil, { capabilities = {
              workspaceSymbolProvider = true, definitionProvider = true } })
          elseif method == "workspace/symbol" then
            -- the canonical DECLARATION -- and the range covers the WHOLE
            -- declaration starting at column 0, on `void`, as real clangd
            -- can answer. A chase that sends range.start verbatim asks for
            -- the definition of a keyword.
            callback(nil, { { name = "kfree_like", kind = 12,
              location = { uri = huri, range = {
                start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 34 } } } } })
          elseif method == "textDocument/definition" then
            def_requests = def_requests + 1
            -- Real clangd answers only when the position is ON the
            -- identifier; the first fake answered regardless of position,
            -- which made it more forgiving than the real server and let a
            -- keyword-positioned chase pass here while missing in the
            -- field (locate:chase-miss 217.3ms on real kfree @ slab.h).
            local ch = params.position and params.position.character or -1
            if params.position and params.position.line == 0 and ch >= 5 and ch <= 14 then
              callback(nil, { { uri = curi, range = {
                start = { line = 0, character = 5 }, ["end"] = { line = 0, character = 15 } } } })
            else
              callback(nil, {})
            end
          else
            callback(nil, nil)
          end
          return true, next_id
        end,
        notify = function() return true end,
        is_closing = function() return closing end,
        terminate = function() closing = true; dispatchers.on_exit(0, 0) end,
      }
    end,
    root_dir = dir,
  })
  vim.wait(2000, function()
    return cid ~= nil and #vim.lsp.get_clients({ bufnr = src_buf, name = "chase" }) > 0
  end, 20)

  if #vim.lsp.get_clients({ bufnr = src_buf, name = "chase" }) == 0 then
    print("SKIP  declaration-chase checks (in-process LSP server unavailable)")
  else
    resolver.clear_caches()
    local done, lines, label = false, nil, nil
    resolver.fetch("kfree_like", src_buf, function(l, lb)
      lines, label = l, lb
      done = true
    end)
    vim.wait(10000, function() return done end, 10)
    check("chase: a prototype answer is chased to the definition",
      done and def_requests >= 1, ("def_requests=%d"):format(def_requests))
    check("chase: the BODY comes back, not the prototype",
      lines ~= nil and table.concat(lines, "\n"):find("(void)objp", 1, true) ~= nil, vim.inspect(lines))
    check("chase: labelled as a function definition, not a declaration",
      label == "function_definition", tostring(label))

    -- The chase result must be remembered: a repeat fetch asks for no
    -- second definition round trip.
    local before = def_requests
    local done2 = false
    resolver.fetch("kfree_like", src_buf, function()
      done2 = true
    end)
    vim.wait(10000, function() return done2 end, 10)
    check("chase: the chased location is cached for repeats",
      done2 and def_requests == before, ("def_requests %d -> %d"):format(before, def_requests))

    -- A MISS is memoized too: without this, every repeat of a
    -- prototype-only name pays a definition round trip per keypress --
    -- the ask-the-same-question-every-time class this module exists to
    -- prevent. The server below is the same one, but the target is a
    -- name whose definition request will return the declaration itself
    -- (no progress), which the chase treats as a miss.
    resolver.clear_caches()
    local self_uri = huri
    -- redefine the server's definition answer to be the declaration itself
    -- is not possible per-name here, so use a second name the server does
    -- not know: workspace/symbol still answers the declaration, definition
    -- answers nothing.
    local m0 = def_requests
    -- (the fake server answers definition regardless of name; point the
    -- chase at a location whose "definition" equals itself by asking for
    -- the C file's own location, where extract already yields a
    -- function_definition and no chase happens -- so instead assert via
    -- the miss memo directly)
    resolver._chase_miss[self_uri .. "\1" .. 0] = vim.uv.now()
    local done3, label3 = false, nil
    resolver.fetch("kfree_like", src_buf, function(_, lb)
      label3 = lb
      done3 = true
    end)
    vim.wait(10000, function() return done3 end, 10)
    check("chase: a memoized miss short-circuits (no definition request)",
      done3 and def_requests == m0 and label3 == "declaration",
      ("def_requests %d -> %d label=%s"):format(m0, def_requests, tostring(label3)))

    -- The miss EXPIRES. The session-scoped version pinned a symbol probed
    -- during index construction to its prototype until Neovim restarted --
    -- and nothing in production calls clear_caches, so "until clear_caches"
    -- meant never. Backdate the memo past the TTL and the chase must ask
    -- the server again.
    resolver._chase_miss[self_uri .. "\1" .. 0] = vim.uv.now() - resolver._chase_miss_ttl_ms - 1
    resolver._extract_cache = {}
    local m1 = def_requests
    local done4 = false
    resolver.fetch("kfree_like", src_buf, function()
      done4 = true
    end)
    vim.wait(10000, function() return done4 end, 10)
    check("chase: an expired miss is retried against the server",
      done4 and def_requests > m1, ("def_requests %d -> %d"):format(m1, def_requests))
    vim.lsp.stop_client(cid, true)
  end
end

-- A fuzzy stranger is not an answer. With no exact workspace/symbol
-- match, the old locate took the server's first fuzzy suggestion --
-- against real clangd with no compile database, fetching kfree expanded
-- ATOMIC_CHAR16_T_LOCK_FREE @ stdatomic.h. Wrong body, no warning.
do
  local jpath = vim.fn.tempname() .. ".c"
  local jf = assert(io.open(jpath, "w"))
  jf:write("int other_thing(void)\n{\n    return 1;\n}\n")
  jf:close()
  vim.cmd.edit(jpath)
  local jbuf = vim.api.nvim_get_current_buf()
  local jcid = vim.lsp.start({
    name = "fuzzy",
    cmd = function(dispatchers)
      local closing, next_id = false, 0
      return {
        request = function(method, _, callback)
          next_id = next_id + 1
          if method == "initialize" then
            callback(nil, { capabilities = { workspaceSymbolProvider = true } })
          elseif method == "workspace/symbol" then
            callback(nil, { { name = "ATOMIC_CHAR16_T_LOCK_FREE", kind = 14,
              location = { uri = vim.uri_from_fname(jpath), range = {
                start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 15 } } } } })
          else
            callback(nil, nil)
          end
          return true, next_id
        end,
        notify = function() return true end,
        is_closing = function() return closing end,
        terminate = function() closing = true; dispatchers.on_exit(0, 0) end,
      }
    end,
    root_dir = vim.fn.fnamemodify(jpath, ":h"),
  })
  vim.wait(2000, function()
    return jcid ~= nil and #vim.lsp.get_clients({ bufnr = jbuf, name = "fuzzy" }) > 0
  end, 20)
  if #vim.lsp.get_clients({ bufnr = jbuf, name = "fuzzy" }) == 0 then
    print("SKIP  fuzzy-stranger checks (in-process LSP server unavailable)")
  else
    resolver.clear_caches()
    local done, loc, lerr
    resolver.locate("kfree", jbuf, function(l, e)
      loc, lerr = l, e
      done = true
    end)
    vim.wait(5000, function() return done end, 5)
    check("locate: a fuzzy-only answer is a not-found, never a stranger's body",
      loc == nil and lerr ~= nil and lerr:find("kfree", 1, true) ~= nil
        and lerr:find("ATOMIC_CHAR16_T_LOCK_FREE", 1, true) ~= nil, tostring(lerr))
    vim.lsp.stop_client(jcid, true)
  end
end

print("")
print(fails == 0 and "ALL RESOLVER TESTS PASSED" or (fails .. " FAILURE(S)"))
