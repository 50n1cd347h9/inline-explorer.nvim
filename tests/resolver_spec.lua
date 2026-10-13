-- Resolver unit tests: LSP documentSymbol range selection (_symbol_range) and
-- the table-free tree-sitter fallback (extract_sync / async extract).
--   nvim --headless --clean -u NONE -c "luafile tests/resolver_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))
local H = require("tests.lib.harness")
local resolver = require("inline-explorer.resolver")

if not H.require_c_parser() then
  return
end

local check = H.check
local fake_lsp = require("tests.lib.fake_lsp")

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
  H.writef(hpath, "static __always_inline int acc(int cpu)\n{\n    return per_cpu(cpu) & MASK;\n}\n")
  local col = ("static __always_inline int acc(int cpu)"):find("acc") - 1
  local lines, label = resolver.extract_sync({ uri = vim.uri_from_fname(hpath), range = range(0, col, 0, col) })
  check("extract_sync: header function -> function_definition", label == "function_definition", tostring(label))
  check("extract_sync: body includes the return", table.concat(lines, "\n"):find("return per_cpu", 1, true) ~= nil)
end

-- extract_sync: macro definition -> a preproc node type, continuation kept.
do
  local cpath = vim.fn.tempname() .. ".c"
  H.writef(cpath, "#define TWICE(x) \\\n    ((x) + (x))\nint y;\n")
  local lines, label = resolver.extract_sync({ uri = vim.uri_from_fname(cpath), range = range(0, 8, 0, 13) })
  check("extract_sync: macro label is a preproc node", type(label) == "string" and label:find("preproc") ~= nil, label)
  check("extract_sync: continuation line kept", table.concat(lines, "\n"):find("(x) + (x)", 1, true) ~= nil)
end

-- extract (async wrapper): with no LSP attached it falls back to extract_sync
-- and calls cb synchronously.
do
  local hpath = vim.fn.tempname() .. ".h"
  H.writef(hpath, "static int one(void)\n{\n    return 1;\n}\n")
  local got_lines, got_label
  resolver.extract({ uri = vim.uri_from_fname(hpath), range = range(0, 11, 0, 14) }, 0, function(lines, label)
    got_lines, got_label = lines, label
  end)
  vim.wait(200, function()
    return got_lines ~= nil
  end, 10)
  check("extract: no-LSP path falls back", got_label == "function_definition", tostring(got_label))
  check(
    "extract: fallback returned the body",
    got_lines ~= nil and table.concat(got_lines, "\n"):find("return 1", 1, true) ~= nil
  )
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
  H.writef(hpath, "#ifndef FOO_H\n#define FOO_H\nstatic int acc(int cpu) { return cpu + 1; }\n#endif\n")
  local col = ("static int acc(int cpu)"):find("acc") - 1
  local lines, label = resolver.extract_sync({ uri = vim.uri_from_fname(hpath), range = range(2, col, 2, col) })
  check(
    "extract_sync: include guard -> function_definition, not the guard",
    label == "function_definition",
    tostring(label)
  )
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
  H.writef(cpath, "int add(\n    int a,\n    int b)\n{ return a + b; }\n")
  local lines, label = resolver.extract_sync({ uri = vim.uri_from_fname(cpath), range = range(0, 4, 0, 4) })
  check(
    "extract_sync: multi-line parameter list -> function_definition",
    label == "function_definition",
    tostring(label)
  )
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

-- async.request against a stub client: one callback whatever happens, and a
-- cancel on timeout only while the request is still pending -- Neovim logs an
-- error for cancelling one that is not.
do
  local async = require("inline-explorer.async")
  local function stub(sent)
    local client = { requests = {}, cancelled = {}, handlers = {} }
    function client:request(method, _, handler, bufnr)
      if not sent then
        return false, nil
      end
      self.requests[7] = { type = "pending", method = method, bufnr = bufnr }
      self.handlers[7] = handler
      return true, 7
    end
    function client:cancel_request(id)
      self.cancelled[#self.cancelled + 1] = id
      self.requests[id] = { type = "cancel" }
    end
    return client
  end
  local function run(client, before_timeout)
    local calls = {}
    async.request(client, "textDocument/definition", {}, 0, 50, function(err, result)
      calls[#calls + 1] = { err = err, result = result }
    end)
    if before_timeout then
      before_timeout(client)
    end
    vim.wait(300, function()
      return #calls > 0
    end, 5)
    vim.wait(100) -- room for a second callback
    return calls
  end

  local client = stub(true)
  local calls = run(client)
  check(
    "async.request: no reply -> one error callback, and the pending request is cancelled",
    #calls == 1 and calls[1].err ~= nil and #client.cancelled == 1 and client.cancelled[1] == 7,
    { calls = calls, cancelled = client.cancelled }
  )

  client = stub(true)
  calls = run(client, function(c)
    c.requests[7] = nil -- answered, its handler not yet run
  end)
  check(
    "async.request: a request no longer pending is not cancelled",
    #calls == 1 and #client.cancelled == 0,
    { calls = calls, cancelled = client.cancelled }
  )

  client = stub(true)
  calls = run(client, function(c)
    c.handlers[7](nil, "answer")
  end)
  vim.wait(100)
  check(
    "async.request: a reply -> one callback with it, nothing cancelled",
    #calls == 1 and calls[1].err == nil and calls[1].result == "answer" and #client.cancelled == 0,
    { calls = calls, cancelled = client.cancelled }
  )

  client = stub(false)
  calls = run(client)
  check(
    "async.request: a request that cannot be sent fails at once",
    #calls == 1 and calls[1].err ~= nil and #client.cancelled == 0,
    calls
  )
end

-- Timeout: a wedged server (accepts requests, never replies) must not starve
-- the callbacks -- locate reports a timeout error, extract falls back to
-- extract_sync. Uses an in-process LSP server that swallows everything after
-- the initialize handshake.
do
  local hpath = vim.fn.tempname() .. ".h"
  H.writef(hpath, "static int wedge_fn(void)\n{\n    return 9;\n}\n")

  vim.cmd.edit(hpath)
  local src_buf = vim.api.nvim_get_current_buf()
  local client_id, wedge_log = fake_lsp.start({
    name = "wedge",
    buf = src_buf,
    root_dir = vim.fn.fnamemodify(hpath, ":h"),
    capabilities = {
      documentSymbolProvider = true,
      workspaceSymbolProvider = true,
    },
    -- every other request: accepted, never answered (the wedge)
    skip = "timeout checks (in-process LSP server unavailable)",
  })
  if client_id then
    -- These checks exist to exercise the SERVER extraction path -- timeout,
    -- cold budget, late reply -- which local-first C extraction would bypass
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
      resolver.extract(
        {
          uri = vim.uri_from_fname(hpath),
          range = { start = { line = 0, character = 11 }, ["end"] = { line = 0, character = 19 } },
          kind = 12,
          name = "wedge_fn",
        },
        src_buf,
        function()
          done2 = true
        end
      )
      vim.wait(3000, function()
        return done2
      end, 5)
      local names = {}
      for _, e in ipairs(profile.events) do
        names[#names + 1] = e.name
      end
      local saw_timeout, saw_cold = false, false
      for _, n in ipairs(names) do
        if n == "extract:timeout" then
          saw_timeout = true
        end
        if n == "extract:cold" or n == "extract:warm" then
          saw_cold = true
        end
      end
      check(
        "extract: a timeout is labelled as one, not as a cold extract",
        saw_timeout and not saw_cold,
        table.concat(names, ",")
      )

      -- The first touch of a definition file must use the SHORT budget, not
      -- the general one. One number cannot serve both: an already-attached
      -- file answers in single-digit ms, while a first touch has to wait for
      -- a preamble -- and when that goes pathological the old single 4000ms
      -- budget bought nothing except four seconds of waiting before the same
      -- tree-sitter fallback the short budget reaches immediately.
      -- A SECOND header, never touched before: reusing the first one would
      -- measure the warm path, because extract attached it a moment ago.
      local hpath2 = vim.fn.tempname() .. ".h"
      H.writef(hpath2, "static int wedge_fn2(void)\n{\n    return 8;\n}\n")

      local saved_cold = resolver._cold_timeout_ms
      resolver._cold_timeout_ms = 120
      resolver._timeout_ms = 8000 -- must NOT be the one that governs here
      profile.clear()
      local ds_before = fake_lsp.count(wedge_log.requests, "textDocument/documentSymbol")
      local done3, t3 = false, vim.uv.hrtime()
      resolver.extract(
        {
          uri = vim.uri_from_fname(hpath2),
          range = { start = { line = 0, character = 11 }, ["end"] = { line = 0, character = 20 } },
          kind = 12,
          name = "wedge_fn2",
        },
        src_buf,
        function()
          done3 = true
        end
      )
      vim.wait(6000, function()
        return done3
      end, 5)
      local waited = (vim.uv.hrtime() - t3) / 1e6
      check(
        "extract: a first touch uses the cold budget, not the general one",
        done3 and waited < 2000,
        ("waited %.0fms (cold=%d general=%d)"):format(waited, resolver._cold_timeout_ms, resolver._timeout_ms)
      )

      -- A timeout neither cancels the request nor sends it again: its reply,
      -- whenever it comes, is what the next look uses. The background retry
      -- this replaced sent a second documentSymbol while the first was still
      -- pending.
      vim.wait(500)
      check(
        "extract: a timed-out request is sent once and not cancelled",
        fake_lsp.count(wedge_log.requests, "textDocument/documentSymbol") == ds_before + 1
          and fake_lsp.count(wedge_log.notifications, "$/cancelRequest") == 0,
        wedge_log
      )

      -- A late answer must not be thrown away. A real kernel log showed a
      -- symbol whose first touch timed out costing another 89ms round trip
      -- on the next look, when the server's answer had arrived moments
      -- after the timeout and was discarded. The server below answers
      -- documentSymbol only after the budget -- the shape of a preamble
      -- finishing just after it -- so its answer must land in the cache and
      -- the next fetch must be served without a new request.
      local function wait_for_span(name)
        return vim.wait(2000, function()
          for _, e in ipairs(profile.events) do
            if e.name == name then
              return true
            end
          end
          return false
        end, 10)
      end
      do
        local dpath3 = vim.fn.tempname() .. ".h"
        H.writef(dpath3, "static int late_fn(void)\n{\n    return 4;\n}\nstatic int after_late(void);\n")
        local uri3 = vim.uri_from_fname(vim.fn.resolve(dpath3))
        local ds_count = 0
        vim.cmd.edit(dpath3)
        local src3 = vim.api.nvim_get_current_buf()
        local cid3 = fake_lsp.start({
          name = "late",
          buf = src3,
          root_dir = vim.fn.fnamemodify(dpath3, ":h"),
          capabilities = {
            documentSymbolProvider = true,
            workspaceSymbolProvider = true,
          },
          handle = function(method, _, callback)
            if method == "textDocument/documentSymbol" then
              ds_count = ds_count + 1
              vim.defer_fn(function()
                callback(nil, {
                  {
                    name = "late_fn",
                    kind = 12,
                    -- End-exclusive at the start of the next line, as
                    -- servers report a range that ends with its newline.
                    range = { start = { line = 0, character = 0 }, ["end"] = { line = 4, character = 0 } },
                    selectionRange = {
                      start = { line = 0, character = 11 },
                      ["end"] = { line = 0, character = 18 },
                    },
                  },
                })
              end, 300)
            else
              callback(nil, nil)
            end
          end,
          skip = "late-reply checks (in-process LSP server unavailable)",
        })
        if cid3 then
          resolver.clear_caches()
          profile.clear()
          resolver._cold_timeout_ms = 100
          resolver._timeout_ms = 100
          local loc3 = {
            uri = uri3,
            range = { start = { line = 0, character = 11 }, ["end"] = { line = 0, character = 18 } },
            kind = 12,
            name = "late_fn",
          }
          local done4 = false
          resolver.extract(loc3, src3, function()
            done4 = true
          end)
          vim.wait(4000, function()
            return done4
          end, 5)
          check("late reply: it is logged once it arrives", wait_for_span("extract:late"))

          local done5, lines5 = false, nil
          resolver.extract(loc3, src3, function(l)
            lines5 = l
            done5 = true
          end)
          vim.wait(4000, function()
            return done5
          end, 5)
          check(
            "late reply: the next fetch is served from it, one request in all",
            done5 and ds_count == 1,
            ("ds_count=%d"):format(ds_count)
          )
          check(
            "late reply: and returns the server's body, not the fallback",
            lines5 ~= nil and table.concat(lines5, "\n"):find("return 4", 1, true) ~= nil,
            vim.inspect(lines5)
          )
          -- The retry this replaced parsed the reply on its own copy of the
          -- main path's code, minus the end-exclusive trim: an end at
          -- character 0 kept the next line, and the cache served it on every
          -- later look.
          check(
            "late reply: an end-exclusive range does not drag in the next line",
            lines5 ~= nil and #lines5 == 4 and not table.concat(lines5, "\n"):find("after_late", 1, true),
            vim.inspect(lines5)
          )
          vim.lsp.stop_client(cid3, true)
        end
      end
      -- A late reply belongs to the file as it was when asked: an edit made
      -- while the request was out keeps it from being served, as it would
      -- an answer in time. Read against the edited file, its range picks
      -- other lines.
      do
        local dpath5 = vim.fn.tempname() .. ".h"
        H.writef(dpath5, "static int edited_fn(void)\n{\n    return 6;\n}\n")
        local uri5 = vim.uri_from_fname(vim.fn.resolve(dpath5))
        local ds5 = 0
        vim.cmd.edit(dpath5)
        local src5 = vim.api.nvim_get_current_buf()
        local cid5 = fake_lsp.start({
          name = "edited",
          buf = src5,
          root_dir = vim.fn.fnamemodify(dpath5, ":h"),
          capabilities = { documentSymbolProvider = true, workspaceSymbolProvider = true },
          handle = function(method, _, callback)
            if method == "textDocument/documentSymbol" then
              ds5 = ds5 + 1
              vim.defer_fn(function()
                callback(
                  nil,
                  { { name = "edited_fn", kind = 12, range = range(0, 0, 4, 0), selectionRange = range(0, 11, 0, 20) } }
                )
              end, 300)
            else
              callback(nil, nil)
            end
          end,
          skip = "edited late-reply checks (in-process LSP server unavailable)",
        })
        if cid5 then
          resolver.clear_caches()
          profile.clear()
          resolver._cold_timeout_ms = 100
          resolver._timeout_ms = 100
          local loc5 = { uri = uri5, range = range(0, 11, 0, 20), kind = 12, name = "edited_fn" }
          local asked, asked_again = false, false
          resolver.extract(loc5, src5, function()
            asked = true
          end)
          vim.wait(4000, function()
            return asked
          end, 5)
          vim.api.nvim_buf_set_lines(src5, 0, 0, false, { "// a line above" })
          wait_for_span("extract:late")
          profile.clear()
          resolver.extract(loc5, src5, function()
            asked_again = true
          end)
          vim.wait(4000, function()
            return asked_again
          end, 5)
          check(
            "late reply: an edit made while it was out keeps it from being served",
            ds5 == 2 and not wait_for_span("extract:cached"),
            ("documentSymbol requests: %d"):format(ds5)
          )
          vim.lsp.stop_client(cid5, true)
        end
      end
      -- A late reply that cannot be read is logged as such, not as one that
      -- filled the cache. The label once came from pcall's second value,
      -- which is the error message when reading the reply raises.
      do
        local dpath4 = vim.fn.tempname() .. ".h"
        H.writef(dpath4, "static int bad_fn(void)\n{\n    return 5;\n}\n")
        local uri4 = vim.uri_from_fname(vim.fn.resolve(dpath4))
        vim.cmd.edit(dpath4)
        local src4 = vim.api.nvim_get_current_buf()
        local cid4 = fake_lsp.start({
          name = "malformed",
          buf = src4,
          root_dir = vim.fn.fnamemodify(dpath4, ":h"),
          capabilities = {
            documentSymbolProvider = true,
            workspaceSymbolProvider = true,
          },
          handle = function(method, _, callback)
            if method == "textDocument/documentSymbol" then
              -- After the budget, a symbol whose ranges have no positions.
              vim.defer_fn(function()
                callback(nil, { { name = "bad_fn", kind = 12, range = {}, selectionRange = {} } })
              end, 300)
            else
              callback(nil, nil)
            end
          end,
          skip = "malformed late-reply checks (in-process LSP server unavailable)",
        })
        if cid4 then
          resolver.clear_caches()
          profile.clear()
          resolver._cold_timeout_ms = 100
          resolver._timeout_ms = 100
          local done6 = false
          resolver.extract(
            {
              uri = uri4,
              range = { start = { line = 0, character = 11 }, ["end"] = { line = 0, character = 17 } },
              kind = 12,
              name = "bad_fn",
            },
            src4,
            function()
              done6 = true
            end
          )
          vim.wait(4000, function()
            return done6
          end, 5)
          local unusable = wait_for_span("extract:late-unusable")
          local labels = {}
          for _, e in ipairs(profile.events) do
            labels[e.name] = true
          end
          check(
            "late reply: one that cannot be read is logged as unusable",
            unusable and not labels["extract:late"],
            vim.tbl_keys(labels)
          )
          vim.lsp.stop_client(cid4, true)
        end
      end
      resolver._cold_timeout_ms = saved_cold
      resolver._timeout_ms = 300
      profile.enabled, profile.logfile = was, wasfile
      profile.clear()
    end
    check(
      "extract: fallback body intact",
      got_lines ~= nil and table.concat(got_lines, "\n"):find("return 9", 1, true) ~= nil
    )

    -- Attachment hygiene: definition-file attachments are cached (dropping
    -- them makes clangd rebuild the header's preamble on every repeat), and
    -- the least recently used entry beyond the capacity is detached.
    local saved_cap = resolver._attach_cache_max
    resolver._attach_cache_max = 1
    local function extract_temp_header(name, body)
      local hp = vim.fn.tempname() .. ".h"
      H.writef(hp, body)
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
    check(
      "extract: LRU entry evicted beyond capacity",
      evicted == 0 and newest > 0,
      ("old=%d new=%d"):format(evicted, newest)
    )
    resolver._attach_cache_max = saved_cap

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
  H.writef(dpath, "int cached_fn(int a)\n{\n    return a + 1;\n}\n\nint caller(void) { return cached_fn(1); }\n")

  vim.cmd.edit(dpath)
  local src_buf = vim.api.nvim_get_current_buf()
  local uri = vim.uri_from_fname(vim.fn.resolve(dpath))
  local counts = { ["workspace/symbol"] = 0, ["textDocument/documentSymbol"] = 0 }

  local cid = fake_lsp.start({
    name = "counting",
    buf = src_buf,
    root_dir = vim.fn.fnamemodify(dpath, ":h"),
    capabilities = {
      documentSymbolProvider = true,
      workspaceSymbolProvider = true,
    },
    handle = function(method, _, callback)
      if method == "workspace/symbol" then
        counts[method] = counts[method] + 1
        callback(nil, {
          {
            name = "cached_fn",
            kind = 12,
            location = {
              uri = uri,
              range = {
                start = { line = 0, character = 4 },
                ["end"] = { line = 0, character = 13 },
              },
            },
          },
        })
      elseif method == "textDocument/documentSymbol" then
        counts[method] = counts[method] + 1
        callback(nil, {
          {
            name = "cached_fn",
            kind = 12,
            range = { start = { line = 0, character = 0 }, ["end"] = { line = 3, character = 1 } },
            selectionRange = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 13 } },
          },
        })
      else
        callback(nil, nil)
      end
    end,
    skip = "cache checks (in-process LSP server unavailable)",
  })
  if cid then
    -- The point of these checks is the SERVER-path result cache; C
    -- local-first extraction would answer without ever issuing the
    -- documentSymbol these counters count.
    local saved_lf2 = resolver._local_first
    resolver._local_first = false
    resolver.clear_caches()

    local function fetch_once()
      local done, got = false, nil
      resolver.fetch("cached_fn", src_buf, function(lines)
        got = lines
        done = true
      end)
      vim.wait(3000, function()
        return done
      end, 5)
      return got
    end

    local first = fetch_once()
    local c1w, c1d = counts["workspace/symbol"], counts["textDocument/documentSymbol"]
    check(
      "cache: first fetch reaches the server",
      c1w >= 1 and c1d >= 1,
      ("symbol=%d documentSymbol=%d"):format(c1w, c1d)
    )
    check(
      "cache: first fetch returns the body",
      first ~= nil and table.concat(first, "\n"):find("return a + 1", 1, true) ~= nil,
      vim.inspect(first)
    )

    local second = fetch_once()
    check(
      "cache: repeat fetch asks the server nothing",
      counts["workspace/symbol"] == c1w and counts["textDocument/documentSymbol"] == c1d,
      ("symbol=%d->%d documentSymbol=%d->%d"):format(
        c1w,
        counts["workspace/symbol"],
        c1d,
        counts["textDocument/documentSymbol"]
      )
    )
    check(
      "cache: repeat fetch returns the same body",
      second ~= nil and table.concat(second, "\n") == table.concat(first, "\n")
    )

    -- Editing the definition must retire the entry, not serve the old body.
    local tbuf = vim.uri_to_bufnr(uri)
    vim.fn.bufload(tbuf)
    vim.api.nvim_buf_set_lines(tbuf, 2, 3, false, { "    return a + 99;" })
    local third = fetch_once()
    check(
      "cache: an edit to the definition goes back to the server",
      counts["textDocument/documentSymbol"] > c1d,
      ("documentSymbol=%d->%d"):format(c1d, counts["textDocument/documentSymbol"])
    )
    check(
      "cache: an edit to the definition yields the NEW body",
      third ~= nil and table.concat(third, "\n"):find("return a + 99", 1, true) ~= nil,
      vim.inspect(third)
    )

    -- Capacity is honoured rather than growing without bound.
    local saved_n = resolver._locate_cache_max
    resolver._locate_cache_max = 2
    resolver.clear_caches()
    for i = 1, 5 do
      local done = false
      resolver.locate("cached_fn_" .. i, src_buf, function()
        done = true
      end)
      vim.wait(2000, function()
        return done
      end, 5)
    end
    local n = 0
    for _ in pairs(resolver._locate_cache) do
      n = n + 1
    end
    check("cache: locate cache is bounded by its capacity", n <= 2, ("entries=%d"):format(n))
    resolver._locate_cache_max = saved_n
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
      resolver.extract(
        {
          uri = uri,
          range = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 13 } },
          kind = 12,
          name = "cached_fn",
        },
        src_buf,
        function(l, lb)
          lines6, label6 = l, lb
          done6 = true
        end
      )
      vim.wait(3000, function()
        return done6
      end, 5)
      check(
        "local-first: a C definition never waits for documentSymbol",
        done6 and counts["textDocument/documentSymbol"] == before_ds,
        ("documentSymbol %d -> %d"):format(before_ds, counts["textDocument/documentSymbol"])
      )
      check(
        "local-first: and yields the full definition with a node label",
        lines6 ~= nil
          and table.concat(lines6, "\n"):find("return a + 99", 1, true) ~= nil
          and label6 == "function_definition",
        ("label=%s lines=%s"):format(tostring(label6), vim.inspect(lines6))
      )
    end

    if cid then
      vim.lsp.stop_client(cid, true)
    end
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
  H.writef(hpath, "void kfree_like(const void *objp);\n")
  H.writef(cpath, "void kfree_like(const void *objp)\n{\n    (void)objp;\n}\n")
  local huri = vim.uri_from_fname(vim.fn.resolve(hpath))
  local curi = vim.uri_from_fname(vim.fn.resolve(cpath))

  vim.cmd.edit(dir .. "/use.c")
  local src_buf = vim.api.nvim_get_current_buf()
  local def_requests = 0
  local cid = fake_lsp.start({
    name = "chase",
    buf = src_buf,
    root_dir = dir,
    capabilities = {
      workspaceSymbolProvider = true,
      definitionProvider = true,
    },
    handle = function(method, params, callback)
      if method == "workspace/symbol" then
        -- the canonical DECLARATION -- and the range covers the WHOLE
        -- declaration starting at column 0, on `void`, as real clangd
        -- can answer. A chase that sends range.start verbatim asks for
        -- the definition of a keyword.
        callback(nil, {
          {
            name = "kfree_like",
            kind = 12,
            location = {
              uri = huri,
              range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = 34 },
              },
            },
          },
        })
      elseif method == "textDocument/definition" then
        def_requests = def_requests + 1
        -- Real clangd answers only when the position is ON the
        -- identifier; the first fake answered regardless of position,
        -- which made it more forgiving than the real server and let a
        -- keyword-positioned chase pass here while missing in the
        -- field (locate:chase-miss 217.3ms on real kfree @ slab.h).
        local ch = params.position and params.position.character or -1
        if params.position and params.position.line == 0 and ch >= 5 and ch <= 14 then
          callback(nil, {
            {
              uri = curi,
              range = {
                start = { line = 0, character = 5 },
                ["end"] = { line = 0, character = 15 },
              },
            },
          })
        else
          callback(nil, {})
        end
      else
        callback(nil, nil)
      end
    end,
    skip = "declaration-chase checks (in-process LSP server unavailable)",
  })
  if cid then
    -- gd chases too. It used locate alone, so on a cold cache it opened
    -- the prototype in api.h, and the body only after an expand had
    -- cached the chased location: which one you got depended on order.
    resolver.clear_caches()
    vim.api.nvim_buf_set_lines(src_buf, 0, -1, false, { "    kfree_like(p);" })
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    local gd_done = false
    require("inline-explorer.pick").definition(function()
      gd_done = true
    end)
    vim.wait(10000, function()
      return gd_done
    end, 10)
    local gd_st = require("inline-explorer.view").state[vim.api.nvim_get_current_buf()]
    local gd_file = gd_st and vim.api.nvim_buf_get_name(gd_st.source_bufnr) or "(no view)"
    check(
      "chase: gd on a cold cache opens the definition, not the prototype",
      gd_done and vim.fn.resolve(gd_file) == vim.fn.resolve(cpath),
      gd_file
    )
    require("inline-explorer.trail").clear()
    vim.api.nvim_set_current_buf(src_buf)

    resolver.clear_caches()
    local done, lines, label = false, nil, nil
    resolver.fetch("kfree_like", src_buf, function(l, lb)
      lines, label = l, lb
      done = true
    end)
    vim.wait(10000, function()
      return done
    end, 10)
    check(
      "chase: a prototype answer is chased to the definition",
      done and def_requests >= 1,
      ("def_requests=%d"):format(def_requests)
    )
    check(
      "chase: the BODY comes back, not the prototype",
      lines ~= nil and table.concat(lines, "\n"):find("(void)objp", 1, true) ~= nil,
      vim.inspect(lines)
    )
    check(
      "chase: labelled as a function definition, not a declaration",
      label == "function_definition",
      tostring(label)
    )

    -- The chase result must be remembered: a repeat fetch asks for no
    -- second definition round trip.
    local before = def_requests
    local done2 = false
    resolver.fetch("kfree_like", src_buf, function()
      done2 = true
    end)
    vim.wait(10000, function()
      return done2
    end, 10)
    check(
      "chase: the chased location is cached for repeats",
      done2 and def_requests == before,
      ("def_requests %d -> %d"):format(before, def_requests)
    )

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
    vim.wait(10000, function()
      return done3
    end, 10)
    check(
      "chase: a memoized miss short-circuits (no definition request)",
      done3 and def_requests == m0 and label3 == "declaration",
      ("def_requests %d -> %d label=%s"):format(m0, def_requests, tostring(label3))
    )

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
    vim.wait(10000, function()
      return done4
    end, 10)
    check(
      "chase: an expired miss is retried against the server",
      done4 and def_requests > m1,
      ("def_requests %d -> %d"):format(m1, def_requests)
    )
    vim.lsp.stop_client(cid, true)
  end
end

-- A fuzzy stranger is not an answer. With no exact workspace/symbol
-- match, the old locate took the server's first fuzzy suggestion --
-- against real clangd with no compile database, fetching kfree expanded
-- ATOMIC_CHAR16_T_LOCK_FREE @ stdatomic.h. Wrong body, no warning.
do
  local jpath = vim.fn.tempname() .. ".c"
  H.writef(jpath, "int other_thing(void)\n{\n    return 1;\n}\n")
  vim.cmd.edit(jpath)
  local jbuf = vim.api.nvim_get_current_buf()
  local jcid = fake_lsp.start({
    name = "fuzzy",
    buf = jbuf,
    root_dir = vim.fn.fnamemodify(jpath, ":h"),
    capabilities = { workspaceSymbolProvider = true },
    handle = function(method, _, callback)
      if method == "workspace/symbol" then
        callback(nil, {
          {
            name = "ATOMIC_CHAR16_T_LOCK_FREE",
            kind = 14,
            location = {
              uri = vim.uri_from_fname(jpath),
              range = {
                start = { line = 0, character = 4 },
                ["end"] = { line = 0, character = 15 },
              },
            },
          },
        })
      else
        callback(nil, nil)
      end
    end,
    skip = "fuzzy-stranger checks (in-process LSP server unavailable)",
  })
  if jcid then
    resolver.clear_caches()
    local done, loc, lerr
    resolver.locate("kfree", jbuf, function(l, e)
      loc, lerr = l, e
      done = true
    end)
    vim.wait(5000, function()
      return done
    end, 5)
    check(
      "locate: a fuzzy-only answer is a not-found, never a stranger's body",
      loc == nil
        and lerr ~= nil
        and lerr:find("kfree", 1, true) ~= nil
        and lerr:find("ATOMIC_CHAR16_T_LOCK_FREE", 1, true) ~= nil,
      tostring(lerr)
    )
    vim.lsp.stop_client(jcid, true)
  end
end

-- Replies that come late, or never. A workspace/symbol reply after the
-- deadline is not cancelled but cached, so that a server slower than the
-- budget still answers the next lookup without being asked again; before, a
-- slower server could never succeed. A definition request the chase gave up
-- on is cancelled, so the server can drop the work.
do
  local lpath = vim.fn.tempname() .. ".c"
  H.writef(lpath, "int slow_fn(int a);\nint slow_fn(int a)\n{\n    return a;\n}\n")
  vim.cmd.edit(lpath)
  local lbuf = vim.api.nvim_get_current_buf()
  local luri = vim.uri_from_bufnr(lbuf)
  local lcid, llog = fake_lsp.start({
    name = "slow",
    buf = lbuf,
    root_dir = vim.fn.fnamemodify(lpath, ":h"),
    capabilities = { workspaceSymbolProvider = true, definitionProvider = true },
    handle = function(method, _, callback)
      if method == "workspace/symbol" then
        vim.defer_fn(function()
          callback(nil, { { name = "slow_fn", kind = 12, location = { uri = luri, range = range(0, 4, 0, 11) } } })
        end, 600)
      end -- definition: never answered
    end,
    skip = "late-reply checks (in-process LSP server unavailable)",
  })
  if lcid then
    resolver.clear_caches()
    local saved = resolver._timeout_ms
    resolver._timeout_ms = 300
    local function locate()
      local done, loc, err = false, nil, nil
      resolver.locate("slow_fn", lbuf, function(l, e)
        loc, err, done = l, e, true
      end)
      vim.wait(3000, function()
        return done
      end, 5)
      return loc, err
    end
    local first, first_err = locate()
    check("late reply: the first lookup times out", first == nil and tostring(first_err):find("timed out") ~= nil, {
      first,
      first_err,
    })
    vim.wait(600)
    local second = locate()
    check(
      "late reply: the next lookup gets the late answer without asking again",
      second ~= nil
        and second.uri == luri
        and fake_lsp.count(llog.requests, "workspace/symbol") == 1
        and fake_lsp.count(llog.notifications, "$/cancelRequest") == 0,
      { second = second, log = llog }
    )

    local chased
    resolver._chase_definition({ uri = luri, range = range(0, 4, 0, 11), name = "slow_fn" }, lbuf, function(d)
      chased = d or false
    end)
    vim.wait(3000, function()
      return chased ~= nil
    end, 5)
    vim.wait(100)
    local pending = 0
    for _, r in pairs(vim.lsp.get_client_by_id(lcid).requests) do
      pending = pending + ((r.type == "pending") and 1 or 0)
    end
    check(
      "chase: a definition request that timed out is cancelled",
      chased == false and fake_lsp.count(llog.notifications, "$/cancelRequest") == 1 and pending == 0,
      { notifications = llog.notifications, pending = pending }
    )
    resolver._timeout_ms = saved
    resolver.clear_caches()
    vim.lsp.stop_client(lcid, true)
  end
end

-- Two servers on one buffer: "found" knows the symbol, "hung" accepts every
-- request and answers none. The lookup must not wait for "hung" past its
-- deadline, and everything asked about the symbol afterwards goes to the
-- server that found it -- not to the other one, and not to an arbitrary
-- first client.
do
  local dir = H.tmpdir()
  H.writef(dir .. "/api.h", "int two_fn(int a);\n")
  H.writef(dir .. "/impl.c", "int two_fn(int a)\n{\n    return a;\n}\n")
  local huri = vim.uri_from_fname(vim.fn.resolve(dir .. "/api.h"))
  local curi = vim.uri_from_fname(vim.fn.resolve(dir .. "/impl.c"))
  vim.cmd.edit(dir .. "/use.c")
  local ubuf = vim.api.nvim_get_current_buf()
  local asked = { found = {}, hung = {} }
  local function count(server, method)
    asked[server][method] = (asked[server][method] or 0) + 1
  end
  local caps = { workspaceSymbolProvider = true, documentSymbolProvider = true, definitionProvider = true }
  -- Started first, so that it is the first client of the buffer.
  local hung_id, hung_log = fake_lsp.start({
    name = "hung",
    buf = ubuf,
    root_dir = dir,
    capabilities = caps,
    handle = function(method)
      count("hung", method)
    end,
    skip = "two-server checks (in-process LSP server unavailable)",
  })
  local found_id = fake_lsp.start({
    name = "found",
    buf = ubuf,
    root_dir = dir,
    capabilities = caps,
    handle = function(method, _, callback)
      count("found", method)
      if method == "workspace/symbol" then
        callback(nil, { { name = "two_fn", kind = 12, location = { uri = huri, range = range(0, 4, 0, 10) } } })
      elseif method == "textDocument/definition" then
        callback(nil, { { uri = curi, range = range(0, 4, 0, 10) } })
      elseif method == "textDocument/documentSymbol" then
        callback(nil, {})
      else
        callback(nil, nil)
      end
    end,
    skip = "two-server checks (in-process LSP server unavailable)",
  })
  if hung_id and found_id then
    resolver.clear_caches()
    local saved_t, saved_c, saved_lf = resolver._timeout_ms, resolver._cold_timeout_ms, resolver._local_first
    resolver._timeout_ms, resolver._cold_timeout_ms = 300, 300
    local done, loc, lerr = false, nil, nil
    resolver.locate("two_fn", ubuf, function(l, e)
      loc, lerr, done = l, e, true
    end)
    vim.wait(3000, function()
      return done
    end, 5)
    check(
      "two servers: at the deadline, the answer that arrived is used",
      loc ~= nil and loc.uri == huri,
      { loc = loc, err = lerr }
    )
    check("two servers: the loc records the server that found it", loc ~= nil and loc.client_id == found_id, loc)
    vim.wait(100)
    check(
      "two servers: once the answer is known, the silent server's request is cancelled",
      hung_log and fake_lsp.count(hung_log.notifications, "$/cancelRequest") == 1,
      hung_log and hung_log.notifications
    )

    -- The loc locate returns, so that the checks below do not depend on it.
    local found_loc = {
      uri = huri,
      range = range(0, 4, 0, 10),
      kind = 12,
      name = "two_fn",
      client_id = found_id,
    }
    do
      -- The server path, so that documentSymbol is asked at all.
      resolver._local_first = false
      local got = false
      resolver.extract(found_loc, ubuf, function()
        got = true
      end)
      vim.wait(3000, function()
        return got
      end, 5)
      local hbuf = vim.uri_to_bufnr(huri)
      check(
        "two servers: documentSymbol goes only to the server that found the symbol",
        got and asked.found["textDocument/documentSymbol"] == 1 and asked.hung["textDocument/documentSymbol"] == nil,
        asked
      )
      check(
        "two servers: only that server is attached to the definition file",
        vim.lsp.buf_is_attached(hbuf, found_id) and not vim.lsp.buf_is_attached(hbuf, hung_id),
        vim.tbl_map(function(c)
          return c.name
        end, vim.lsp.get_clients({ bufnr = hbuf }))
      )

      local chased
      pcall(resolver._chase_definition, found_loc, ubuf, function(dloc)
        chased = dloc or false
      end)
      vim.wait(3000, function()
        return chased ~= nil
      end, 5)
      check(
        "two servers: the chase asks only the server that found the symbol",
        chased and chased.uri == curi and asked.hung["textDocument/definition"] == nil,
        { chased = chased, asked = asked }
      )
      check(
        "two servers: the chased loc records the server that answered",
        chased and chased.client_id == found_id,
        chased
      )
    end
    resolver._timeout_ms, resolver._cold_timeout_ms, resolver._local_first = saved_t, saved_c, saved_lf
    resolver.clear_caches()
  end
  for _, id in ipairs({ hung_id, found_id }) do
    vim.lsp.stop_client(id, true)
  end
  vim.wait(1000, function()
    return #vim.lsp.get_clients({ bufnr = ubuf }) == 0
  end, 10)
end

-- A server attached to the buffer that cannot answer workspace/symbol is no
-- server for locate. Asking anyway sent nothing, raised Neovim's own "not
-- supported" error, and reported a timeout once the whole budget had passed.
do
  local npath = vim.fn.tempname() .. ".c"
  H.writef(npath, "int nows_fn(void)\n{\n    return 1;\n}\n")
  vim.cmd.edit(npath)
  local nbuf = vim.api.nvim_get_current_buf()
  local requests = 0
  local ncid = fake_lsp.start({
    name = "nows",
    buf = nbuf,
    root_dir = vim.fn.fnamemodify(npath, ":h"),
    capabilities = { hoverProvider = true },
    handle = function(_, _, callback)
      requests = requests + 1
      callback(nil, nil)
    end,
    skip = "unsupported-method checks (in-process LSP server unavailable)",
  })
  if ncid then
    resolver.clear_caches()
    local saved = resolver._timeout_ms
    resolver._timeout_ms = 10000
    local notes = {}
    local orig_notify = vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = tostring(msg)
    end
    local done, loc, lerr, t0 = false, nil, nil, vim.uv.hrtime()
    resolver.locate("nows_fn", nbuf, function(l, e)
      loc, lerr, done = l, e, true
    end)
    vim.wait(3000, function()
      return done
    end, 5)
    local waited = (vim.uv.hrtime() - t0) / 1e6
    vim.notify = orig_notify
    resolver._timeout_ms = saved
    check(
      "locate: no server supporting workspace/symbol fails at once, not at the deadline",
      done and loc == nil and waited < 2000,
      ("done=%s waited=%.0fms"):format(tostring(done), waited)
    )
    check(
      "locate: the error names the missing method and the server attached",
      tostring(lerr):find("workspace/symbol", 1, true) ~= nil and tostring(lerr):find("nows", 1, true) ~= nil,
      tostring(lerr)
    )
    check(
      "locate: nothing is sent, and Neovim reports no error of its own",
      requests == 0 and #notes == 0,
      { requests = requests, notes = notes }
    )
    vim.lsp.stop_client(ncid, true)
  end
end

-- Definition files: a server is attached to one only right before it is
-- asked about it, and eviction from the attach cache puts the file back as
-- it was. Every extract used to attach the file, and so open it in the
-- server, even when tree-sitter answered locally; with a FileType autostart
-- the files stayed open for good, since the cache only recorded files whose
-- clients it had attached itself.
do
  local dir = H.tmpdir()
  local function header(name)
    local path = dir .. "/" .. name .. ".h"
    H.writef(path, "static int " .. name .. "(void)\n{\n    return 1;\n}\n")
    return path
  end
  local function loc_of(path, name)
    return { uri = vim.uri_from_fname(path), range = range(0, 11, 0, 11 + #name), name = name, kind = 12 }
  end
  H.writef(dir .. "/src.c", "int main(void) { return 0; }\n")
  vim.cmd.edit(dir .. "/src.c")
  local sbuf = vim.api.nvim_get_current_buf()
  local cid, log = fake_lsp.start({
    name = "files",
    buf = sbuf,
    root_dir = dir,
    capabilities = { documentSymbolProvider = true, textDocumentSync = { openClose = true, change = 1 } },
    handle = function(method, params, callback)
      if method == "textDocument/documentSymbol" then
        local name = vim.fn.fnamemodify(vim.uri_to_fname(params.textDocument.uri), ":t:r")
        callback(nil, { { name = name, kind = 12, range = range(0, 0, 3, 1), selectionRange = range(0, 11, 0, 11) } })
      else
        callback(nil, nil)
      end
    end,
    skip = "definition-file checks (in-process LSP server unavailable)",
  })
  local function extract(path, name)
    local got
    resolver.extract(loc_of(path, name), sbuf, function(lines)
      got = lines
    end)
    vim.wait(3000, function()
      return got ~= nil
    end, 5)
    vim.wait(50) -- let didOpen/didClose land
    return vim.fn.bufnr(path)
  end
  local function opened(path, method)
    local uri = vim.uri_from_fname(path)
    local n = 0
    for _, e in ipairs(log.notifications) do
      if e.method == method and e.params.textDocument.uri == uri then
        n = n + 1
      end
    end
    return n
  end
  if cid then
    resolver.clear_caches()
    local saved_cap, saved_lf = resolver._attach_cache_max, resolver._local_first
    resolver._attach_cache_max = 1

    local a = header("lazy_a")
    local abuf = extract(a, "lazy_a")
    check(
      "definition files: a local extraction attaches no server",
      vim.api.nvim_buf_is_loaded(abuf)
        and not vim.lsp.buf_is_attached(abuf, cid)
        and opened(a, "textDocument/didOpen") == 0,
      log.notifications
    )

    resolver._local_first = false
    local b = header("lazy_b")
    local bbuf = extract(b, "lazy_b")
    check(
      "definition files: the server is attached right before it is asked",
      vim.lsp.buf_is_attached(bbuf, cid) and opened(b, "textDocument/didOpen") == 1,
      log.notifications
    )
    check(
      "definition files: a file this loaded is unloaded on eviction",
      not vim.api.nvim_buf_is_loaded(abuf),
      { a_loaded = vim.api.nvim_buf_is_loaded(abuf) }
    )

    local c = header("lazy_c")
    extract(c, "lazy_c")
    check(
      "definition files: unloading closes the file in the server",
      not vim.api.nvim_buf_is_loaded(bbuf) and opened(b, "textDocument/didClose") == 1,
      log.notifications
    )

    -- A file the user has open (listed) is only detached, and without the
    -- "Cannot detach" message when the client went away from it meanwhile.
    local d = header("lazy_d")
    vim.cmd.edit(d)
    vim.cmd.edit(dir .. "/src.c")
    local dbuf = vim.fn.bufnr(d)
    extract(d, "lazy_d")
    local attached_d = vim.lsp.buf_is_attached(dbuf, cid)
    vim.lsp.buf_detach_client(dbuf, cid)
    local notes = {}
    local orig_notify = vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = tostring(msg)
    end
    extract(header("lazy_e"), "lazy_e")
    vim.notify = orig_notify
    check(
      "definition files: a file the user has open stays loaded, and eviction says nothing",
      attached_d and vim.api.nvim_buf_is_loaded(dbuf) and #notes == 0,
      { attached_d = attached_d, notes = notes }
    )

    -- A file a reading view reads from keeps its server: the view looks
    -- names up through it.
    local f = header("lazy_f")
    local fbuf = extract(f, "lazy_f")
    local v = require("inline-explorer.view").open(fbuf) -- shown, not fbuf
    extract(header("lazy_g"), "lazy_g")
    check(
      "definition files: the source of a reading view is left alone",
      vim.api.nvim_buf_is_loaded(fbuf) and vim.lsp.buf_is_attached(fbuf, cid),
      { loaded = vim.api.nvim_buf_is_loaded(fbuf) }
    )
    vim.cmd.edit(dir .. "/src.c")
    pcall(vim.api.nvim_buf_delete, v, { force = true })

    -- With an autostart, loading the file attaches the server. The plugin
    -- attaches nothing then, but it loaded the file, so eviction still
    -- unloads it and the server closes it.
    resolver._local_first = true
    vim.api.nvim_create_autocmd("BufReadPost", {
      pattern = dir .. "/auto_*.h",
      callback = function(ev)
        vim.lsp.buf_attach_client(ev.buf, cid)
      end,
    })
    local h1, h2 = header("auto_one"), header("auto_two")
    local h1buf = extract(h1, "auto_one")
    local autostarted = vim.lsp.buf_is_attached(h1buf, cid)
    extract(h2, "auto_two")
    check(
      "definition files: a file an autostart opened is closed once evicted",
      autostarted and not vim.api.nvim_buf_is_loaded(h1buf) and opened(h1, "textDocument/didClose") == 1,
      { autostarted = autostarted, notifications = log.notifications }
    )

    resolver._attach_cache_max, resolver._local_first = saved_cap, saved_lf
    resolver.clear_caches()
    vim.lsp.stop_client(cid, true)
  end
end

-- Position encodings. LSP `character` counts in the encoding negotiated
-- with the server (utf-16 unless it says otherwise; clangd says utf-8);
-- cursor columns and tree-sitter count bytes. Every check below sits on a
-- line with a multibyte character before the position, where the two
-- differ -- on plain ASCII they agree, which is how the missing conversion
-- went unnoticed.
do
  local util = require("inline-explorer.util")
  local line = "/* é */ x" -- 'x' is byte 9, utf-16/utf-32 index 8
  check("encoding: utf-16 character -> byte", util.byte_col(line, 8, "utf-16") == 9, util.byte_col(line, 8, "utf-16"))
  check("encoding: byte -> utf-16 character", util.lsp_col(line, 9, "utf-16") == 8, util.lsp_col(line, 9, "utf-16"))
  check("encoding: utf-32 counts é as one", util.byte_col(line, 8, "utf-32") == 9, util.byte_col(line, 8, "utf-32"))
  check(
    "encoding: utf-8 and nil are bytes already",
    util.byte_col(line, 9, "utf-8") == 9 and util.lsp_col(line, 9, nil) == 9
  )
  check(
    "encoding: a column past the end is the line's end, in every encoding",
    util.byte_col(line, 99, "utf-8") == #line
      and util.byte_col(line, 99, "utf-16") == #line
      and util.lsp_col(line, 99, nil) == #line
      and util.lsp_col(line, 99, "utf-16") == 9
  )

  local epath = vim.fn.tempname() .. ".c"
  H.writef(epath, "/* éééééééééééé */ static int g(void) { return 2; }\nint h(void);\n")
  local eline = "/* éééééééééééé */ static int g(void) { return 2; }"
  local s_byte = assert(eline:find("static", 1, true)) - 1
  local s_u16 = util.lsp_col(eline, s_byte, "utf-16")
  local uri = vim.uri_from_fname(epath)
  local lines, label = resolver.extract_sync({
    uri = uri,
    range = range(0, s_u16, 0, s_u16 + 6),
    name = "g",
    encoding = "utf-16",
  })
  check(
    "encoding: extract_sync finds the definition from a utf-16 position",
    label == "function_definition" and lines and lines[1]:find("static int g", 1, true) ~= nil,
    { label = label, lines = lines }
  )

  local tbuf = vim.uri_to_bufnr(uri)
  vim.fn.bufload(tbuf)
  vim.api.nvim_buf_set_lines(tbuf, 1, 2, false, { "/* é */ int target_fn(void);" })
  local loc = { uri = uri, range = range(1, 0, 1, 27), name = "target_fn" }
  local p16 = resolver.name_position(tbuf, loc, "utf-16")
  local p8 = resolver.name_position(tbuf, loc, "utf-8")
  check("encoding: name_position answers in the server's units (utf-16)", p16.character == 12, p16)
  check("encoding: name_position answers in the server's units (utf-8)", p8.character == 13, p8)
end

H.finish("RESOLVER")
