-- Callers: LSP callHierarchy first, grep+tree-sitter fallback, source
-- always labelled. Counts, not timings.
--   nvim --headless --clean -u NONE -c "set rtp+=." -c "luafile tests/callers_spec.lua" -c "qa!"
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(here, ":h:h"))

local callers = require("inline-explorer.callers")

local fails = 0
local function check(l, ok, d)
  if ok then
    print("PASS  " .. l)
  else
    fails = fails + 1
    print("FAIL  " .. l .. (d and ("  " .. tostring(d)) or ""))
  end
end

-- A tiny project on disk: two callers of `target_fn` in two files, plus a
-- same-named STATIC in a third file whose call must NOT be attributed to
-- our target (the multiple-definition ambiguity the real-source harness
-- taught us): grep cannot tell them apart, and the test pins that the
-- fallback reports the textual truth (3 call sites) -- over-approximation
-- is the fallback's documented contract, not a bug; the label tells the
-- user which contract they are looking at.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function write(rel, text)
  local f = assert(io.open(dir .. "/" .. rel, "w"))
  f:write(text)
  f:close()
end
write("lib.c", "int target_fn(int a)\n{\n    return a + 1;\n}\n")
write("use1.c", "int target_fn(int);\nint u1(void)\n{\n    return target_fn(1);\n}\n")
write("use2.c", "int target_fn(int);\nint u2(void)\n{\n    int x = target_fn(2);\n    return x;\n}\n")
write("other.c", "static int target_fn(int a) { return a; }\nint u3(void) { return target_fn(3); }\n")
-- a non-call textual mention that tree-sitter must reject:
write("doc.c", "// target_fn is documented here, not called\nint unrelated(void) { return 0; }\n")

vim.cmd.edit(dir .. "/lib.c")
local buf = vim.api.nvim_get_current_buf()

-- 1. No LSP attached at all: get() must fall back to grep, labelled so.
do
  local done, items, source, err = false, nil, nil, nil
  callers.get("target_fn", buf, function(i, s, e)
    items, source, err = i, s, e
    done = true
  end)
  vim.wait(10000, function() return done end, 10)
  check("grep fallback: fires when no LSP is attached", done and source == "grep", tostring(source))
  check("grep fallback: finds the three textual call sites",
    items ~= nil and #items == 3, items and #items)
  check("grep fallback: the doc-comment mention is rejected by tree-sitter",
    (function()
      for _, it in ipairs(items or {}) do
        if it.uri:find("doc%.c") then return false end
      end
      return true
    end)())
  check("grep fallback: enclosing function names resolved",
    (function()
      local names = {}
      for _, it in ipairs(items or {}) do names[it.name] = true end
      return names["u1"] and names["u2"] and names["u3"]
    end)(), vim.inspect(items))
  check("grep fallback: items sorted by file then line",
    (function()
      for i = 2, #(items or {}) do
        local a, b = items[i - 1], items[i]
        if a.uri > b.uri then return false end
        if a.uri == b.uri and a.range.start.line > b.range.start.line then return false end
      end
      return true
    end)())
end

-- 1b. The same fallback with rg masked: the runner that broke this had no
-- rg, and grep gives no column -- the first version assumed column 1,
-- which lands on indentation whose ancestors never include the
-- call_expression, so every hit failed confirmation and the fallback
-- reported zero callers while every rg-equipped machine passed.
do
  local orig = vim.fn.executable
  vim.fn.executable = function(n)
    if n == "rg" then
      return 0
    end
    return orig(n)
  end
  local done, items, source = false, nil, nil
  callers.get("target_fn", buf, function(i, s2)
    items, source = i, s2
    done = true
  end)
  vim.wait(10000, function() return done end, 10)
  vim.fn.executable = orig
  check("grep(no rg): still finds the three call sites without column info",
    done and source == "grep" and items ~= nil and #items == 3,
    ("source=%s n=%s"):format(tostring(source), items and #items))
end

-- 2. In-process LSP server with callHierarchy: LSP wins, labelled so.
do
  local uri1 = vim.uri_from_fname(vim.fn.resolve(dir .. "/use1.c"))
  local prepare_count, incoming_count = 0, 0
  local cid = vim.lsp.start({
    name = "hier",
    cmd = function(dispatchers)
      local closing, next_id = false, 0
      return {
        request = function(method, _, callback)
          next_id = next_id + 1
          if method == "initialize" then
            callback(nil, { capabilities = {
              callHierarchyProvider = true, workspaceSymbolProvider = true } })
          elseif method == "workspace/symbol" then
            -- the LSP path resolves the symbol's real location before it
            -- aims callHierarchy (the window-0 params sent view URIs)
            callback(nil, { { name = "target_fn", kind = 12,
              location = { uri = vim.uri_from_fname(vim.fn.resolve(dir .. "/lib.c")), range = {
                start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 13 } } } } })
          elseif method == "textDocument/prepareCallHierarchy" then
            prepare_count = prepare_count + 1
            callback(nil, { { name = "target_fn", kind = 12, uri = uri1,
              range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 10 } },
              selectionRange = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 13 } } } })
          elseif method == "callHierarchy/incomingCalls" then
            incoming_count = incoming_count + 1
            callback(nil, { {
              from = { name = "u1", kind = 12, uri = uri1,
                range = { start = { line = 1, character = 0 }, ["end"] = { line = 4, character = 1 } },
                selectionRange = { start = { line = 1, character = 4 }, ["end"] = { line = 1, character = 6 } } },
              fromRanges = { { start = { line = 3, character = 11 }, ["end"] = { line = 3, character = 20 } } },
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
    root_dir = dir,
  })
  vim.wait(2000, function()
    return cid ~= nil and #vim.lsp.get_clients({ bufnr = buf, name = "hier" }) > 0
  end, 20)
  if #vim.lsp.get_clients({ bufnr = buf, name = "hier" }) == 0 then
    print("SKIP  LSP callers checks (in-process server unavailable)")
  else
    local done, items, source = false, nil, nil
    callers.get("target_fn", buf, function(i, s)
      items, source = i, s
      done = true
    end)
    vim.wait(5000, function() return done end, 10)
    check("lsp: source labelled lsp", done and source == "lsp", tostring(source))
    check("lsp: both round trips issued", prepare_count == 1 and incoming_count == 1,
      ("prepare=%d incoming=%d"):format(prepare_count, incoming_count))
    check("lsp: one caller with its fromRange as the call site",
      items and #items == 1 and items[1].name == "u1" and items[1].range.start.line == 3,
      vim.inspect(items))
    check("lsp: call line text extracted",
      items and items[1].text ~= nil and items[1].text:find("target_fn", 1, true) ~= nil,
      items and items[1].text)
    vim.lsp.stop_client(cid, true)
    vim.wait(1000, function() return #vim.lsp.get_clients({ bufnr = buf }) == 0 end, 20)
  end
end

-- 3. A server that never answers: the timeout must hand over to grep,
-- and cb must fire EXACTLY once -- the first version of this module
-- routed the timeout through once_with_timeout, whose internal callback
-- capture bypassed the sentinel filter, delivering a nil-items callback
-- and then grep's answer on top of it.
do
  local cid2 = vim.lsp.start({
    name = "wedgehier",
    cmd = function(dispatchers)
      local closing, next_id = false, 0
      return {
        request = function(method, _, callback)
          next_id = next_id + 1
          if method == "initialize" then
            callback(nil, { capabilities = { callHierarchyProvider = true } })
          end
          -- everything else: swallowed
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
    return cid2 ~= nil and #vim.lsp.get_clients({ bufnr = buf, name = "wedgehier" }) > 0
  end, 20)
  if #vim.lsp.get_clients({ bufnr = buf, name = "wedgehier" }) == 0 then
    print("SKIP  timeout-fallback checks (in-process LSP server unavailable)")
  else
    local saved = callers._timeout_ms
    callers._timeout_ms = 200
    local calls, items, source = 0, nil, nil
    callers.get("target_fn", buf, function(i2, s2)
      calls = calls + 1
      items, source = i2, s2
    end)
    vim.wait(15000, function() return calls > 0 end, 10)
    vim.wait(500) -- room for a buggy second invocation to land
    check("timeout: falls back to grep", source == "grep", tostring(source))
    check("timeout: cb fired exactly once", calls == 1, calls)
    check("timeout: grep items intact (never a nil-items callback)",
      items ~= nil and #items == 3, items and #items)
    callers._timeout_ms = saved
    vim.lsp.stop_client(cid2, true)
  end
end

-- callers.get must reach the LSP path with the REAL file, regardless of
-- which window is current. The old code built position params from window
-- 0; the plugin's own keymap lives inside the reading view -- a detached
-- nofile copy named inline-explorer://... that no server has open -- so
-- every in-view keypress skipped LSP and paid the full-tree grep fallback
-- (measured 558ms vs 6.5ms on the kernel).
do
  local seen_uri
  vim.cmd.edit(dir .. "/lib.c")
  local src3 = vim.api.nvim_get_current_buf()
  local cid3 = vim.lsp.start({
    name = "hier2",
    cmd = function(dispatchers)
      local closing, next_id = false, 0
      local uri1 = vim.uri_from_fname(vim.fn.resolve(dir .. "/use1.c"))
      local liburi = vim.uri_from_fname(vim.fn.resolve(dir .. "/lib.c"))
      return {
        request = function(method, params, callback)
          next_id = next_id + 1
          if method == "initialize" then
            callback(nil, { capabilities = {
              callHierarchyProvider = true, workspaceSymbolProvider = true, definitionProvider = true } })
          elseif method == "workspace/symbol" then
            callback(nil, { { name = "target_fn", kind = 12,
              location = { uri = liburi, range = {
                start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 13 } } } } })
          elseif method == "textDocument/prepareCallHierarchy" then
            seen_uri = params.textDocument and params.textDocument.uri
            -- clangd answers only for documents it has: a view's
            -- inline-explorer:// URI gets an error, same as the field.
            if seen_uri and seen_uri:find("^file://") then
              callback(nil, { { name = "target_fn", kind = 12, uri = liburi,
                range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 20 } },
                selectionRange = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 13 } } } })
            else
              callback({ code = -32602, message = "trying to get AST for non-added document" }, nil)
            end
          elseif method == "callHierarchy/incomingCalls" then
            callback(nil, { {
              from = { name = "u1", kind = 12, uri = vim.uri_from_fname(vim.fn.resolve(dir .. "/use1.c")),
                range = { start = { line = 1, character = 0 }, ["end"] = { line = 4, character = 1 } },
                selectionRange = { start = { line = 1, character = 4 }, ["end"] = { line = 1, character = 6 } } },
              fromRanges = { { start = { line = 3, character = 11 }, ["end"] = { line = 3, character = 20 } } },
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
    root_dir = dir,
  })
  vim.wait(2000, function()
    return cid3 ~= nil and #vim.lsp.get_clients({ bufnr = src3, name = "hier2" }) > 0
  end, 20)
  if #vim.lsp.get_clients({ bufnr = src3, name = "hier2" }) == 0 then
    print("SKIP  view-context callers checks (in-process LSP server unavailable)")
  else
    -- Make a detached nofile copy current, as the in-view keymap does.
    local view = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(view, 0, -1, false,
      vim.api.nvim_buf_get_lines(src3, 0, -1, false))
    pcall(vim.api.nvim_buf_set_name, view, "inline-explorer://lib.c")
    vim.api.nvim_set_current_buf(view)
    require("inline-explorer.resolver").clear_caches()
    local done, items, source = false, nil, nil
    callers.get("target_fn", src3, function(i2, s2)
      items, source = i2, s2
      done = true
    end)
    vim.wait(10000, function() return done end, 10)
    check("view context: the LSP path is reached (source=lsp, not grep)",
      done and source == "lsp", tostring(source))
    check("view context: prepareCallHierarchy was aimed at a real file, not the view",
      seen_uri ~= nil and seen_uri:find("^file://") ~= nil, tostring(seen_uri))
    vim.lsp.stop_client(cid3, true)
    vim.api.nvim_set_current_buf(src3)
    pcall(vim.api.nvim_buf_delete, view, { force = true })
  end
end

print("")
print(fails == 0 and "ALL CALLERS TESTS PASSED" or (fails .. " FAILURE(S)"))
if fails > 0 then vim.cmd("cq") end
vim.cmd("qa!")
