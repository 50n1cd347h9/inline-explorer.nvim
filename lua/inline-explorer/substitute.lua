-- C inline substitution: replace a call `f(args)` with the effect of f's body,
-- as a compilable source transform (GNU C).
--
--   * parameters      -> `__typeof__(arg) param = (arg);` bindings (no type
--                        reconstruction needed, handles pointers/arrays/fn-ptrs)
--   * single-return    -> "pretty" hoist: setup statements lifted above the call
--     straight-line       statement, the returned expression spliced in place
--   * anything else    -> GNU statement expression `({ ... })` with each
--                        `return E;` rewritten to `{ __ie_ret_N = E; goto end; }`
--                        and `__typeof__(first-return) __ie_ret_N;` as the slot
--   * callee labels    -> suffixed `label__ieN` (labels are function-scoped, so
--                        inlining twice would otherwise collide)
--   * name collisions  -> hoisted locals that clash with the caller scope are
--                        suffixed `name__ieN`
--
-- The transform is pure text/tree-sitter and language-specific to C. `N` is a
-- per-expansion id that keeps injected/renamed names unique.
local M = {}

local function parse(src)
  return vim.treesitter.get_string_parser(src, "c"):parse()[1]:root()
end

-- TSNode from a string parser exposes byte offsets only via range(true).
local function sb(node)
  return (select(3, node:range(true)))
end
local function eb(node)
  return (select(6, node:range(true)))
end
local function scol(node)
  return (select(2, node:range(true)))
end

local function text(node, src)
  return src:sub(sb(node) + 1, eb(node))
end

local function query_nodes(node, src, q)
  local out = {}
  for _, n in vim.treesitter.query.parse("c", q):iter_captures(node, src) do
    out[#out + 1] = n
  end
  return out
end

-- Descend a declarator to its identifier name (through pointer/array/fn wrappers).
local function decl_name(decl, src)
  local n = decl
  while n do
    if n:type() == "identifier" then
      return text(n, src)
    end
    local d = n:field("declarator")[1]
    if not d then
      return nil
    end
    n = d
  end
end

-- Unwrap a function definition's declarator to the function_declarator node.
local function func_declarator(decl)
  local n = decl
  while n and n:type() ~= "function_declarator" do
    if n:type() == "pointer_declarator" or n:type() == "parenthesized_declarator" then
      n = n:field("declarator")[1]
    else
      return nil
    end
  end
  return n
end

-- Reconstruct a function's declared return type text (base type + pointer depth),
-- so the statement-expression result slot does not depend on body-local names the
-- way `__typeof__(return expr)` would.
local function return_type(fdef, src)
  local ty = fdef:field("type")[1]
  local base = ty and text(ty, src) or "int"
  local depth, d = 0, fdef:field("declarator")[1]
  while d do
    local t = d:type()
    if t == "pointer_declarator" then
      depth = depth + 1
      d = d:field("declarator")[1]
    elseif t == "parenthesized_declarator" then
      d = d:field("declarator")[1]
    else
      break -- function_declarator or anything unexpected
    end
  end
  if depth > 0 then
    return base .. " " .. string.rep("*", depth)
  end
  return base
end

local function find_function_def(root, src, name)
  for i = 0, root:named_child_count() - 1 do
    local c = root:named_child(i)
    if c:type() == "function_definition" then
      local fd = func_declarator(c:field("declarator")[1])
      if fd and decl_name(fd:field("declarator")[1], src) == name then
        return c, fd
      end
    end
  end
end

local function find_calls(root, src, name)
  local calls = {}
  for _, id in ipairs(query_nodes(root, src, "(call_expression function: (identifier) @f)")) do
    if text(id, src) == name then
      calls[#calls + 1] = id:parent()
    end
  end
  return calls
end

-- Parameters as { name = <string|false>, node = <parameter_declaration> }.
local function get_params(fd, src)
  local out, variadic = {}, false
  local pl = fd:field("parameters")[1]
  for i = 0, pl:named_child_count() - 1 do
    local pc = pl:named_child(i)
    if pc:type() == "variadic_parameter" then
      variadic = true
    elseif pc:type() == "parameter_declaration" then
      local decl = pc:field("declarator")[1]
      local ty = pc:field("type")[1]
      if decl then
        out[#out + 1] = { name = decl_name(decl, src), node = pc }
      elseif not (ty and text(ty, src) == "void") then
        out[#out + 1] = { name = false, node = pc } -- unnamed, non-void parameter
      end
    end
  end
  return out, variadic
end

-- Build a `<param type> <name> = (arg);` binding. Reconstructs the parameter's
-- declared type (arrays decay to pointers) so a NULL/0 argument keeps the right
-- pointer type; __typeof__/__auto_type of the argument would deduce `int` there.
-- Falls back to __auto_type for exotic declarators (function pointers) or
-- unnamed parameters.
local function build_bind(param, arg, rename, N, idx, src)
  local decl = param.node:field("declarator")[1]
  if decl then
    local stars, d = "", decl
    while d do
      local t = d:type()
      if t == "pointer_declarator" or t == "array_declarator" then
        stars = stars .. "*"
        d = d:field("declarator")[1]
      elseif t == "identifier" then
        break
      else
        d = nil
      end
    end
    if d and d:type() == "identifier" then
      local spec = src:sub(sb(param.node) + 1, sb(decl)):gsub("%s+$", "")
      local name = rename[text(d, src)] or text(d, src)
      return string.format("%s %s%s = (%s);", spec, stars, name, arg)
    end
  end
  local name = (param.name and (rename[param.name] or param.name)) or ("__ie_arg" .. idx .. "_" .. N)
  return string.format("__auto_type %s = (%s);", name, arg)
end

-- Apply {start_byte, end_byte, replacement} edits (absolute bytes) restricted to
-- the [s, e) region of src, returning that region's transformed text.
local function apply_edits(src, s, e, edits)
  local within = {}
  for _, ed in ipairs(edits) do
    if ed[1] >= s and ed[2] <= e then
      within[#within + 1] = ed
    end
  end
  table.sort(within, function(a, b)
    return a[1] > b[1]
  end)
  local region = src:sub(s + 1, e)
  for _, ed in ipairs(within) do
    local a, b = ed[1] - s, ed[2] - s
    region = region:sub(1, a) .. ed[3] .. region:sub(b + 1)
  end
  return region
end

-- Longest common leading-whitespace prefix across the non-blank lines.
local function common_ws_prefix(lines)
  local p
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local ws = l:match("^[ \t]*")
      if not p then
        p = ws
      else
        local i = 1
        while i <= #p and p:sub(i, i) == ws:sub(i, i) do
          i = i + 1
        end
        p = p:sub(1, i - 1)
      end
    end
  end
  return p or ""
end

-- Dedent a fragment to its common indent, then re-indent each line under `target`.
-- Relative nesting (and the source's tabs/spaces) is preserved.
local function rebase(fragment, target)
  local lines = vim.split(fragment, "\n", { plain = true })
  local strip = #common_ws_prefix(lines)
  local out = {}
  for _, l in ipairs(lines) do
    out[#out + 1] = l:match("%S") and (target .. l:sub(strip + 1)) or ""
  end
  return out
end

-- Collect declarator identifier names visible in the caller's enclosing function.
local function enclosing_scope(call, src)
  local fn = call
  while fn and fn:type() ~= "function_definition" do
    fn = fn:parent()
  end
  local set = {}
  if not fn then
    return set
  end
  local qs = {
    "(parameter_declaration declarator: (_) @d)",
    "(init_declarator declarator: (_) @d)",
    "(declaration declarator: (_) @d)", -- covers array/pointer declarators, not just plain identifiers
  }
  for _, q in ipairs(qs) do
    for _, d in ipairs(query_nodes(fn, src, q)) do
      local nm = d:type() == "identifier" and text(d, src) or decl_name(d, src)
      if nm then
        set[nm] = true
      end
    end
  end
  return set
end

-- Innermost enclosing statement (or declaration) that contains the call.
local function enclosing_statement(call)
  local n = call
  while n do
    local t = n:type()
    if t:match("_statement$") or t == "declaration" then
      return n
    end
    n = n:parent()
  end
  return call
end

-- Build the transform. Returns (new_caller_src, err).
-- mode: "correct" (default, guaranteed to compile) or "readable" (cleaner output
-- that skips ({...})/goto and safety wrapping, and may not compile in edge cases).
function M.inline_call(caller_src, callee_src, fname, N, occ, mode)
  N = N or 1
  occ = occ or 1
  mode = mode or "correct"

  local call = find_calls(parse(caller_src), caller_src, fname)[occ]
  if not call then
    return nil, "call to '" .. fname .. "' not found"
  end

  local eroot = parse(callee_src)
  local fdef, fd = find_function_def(eroot, callee_src, fname)
  if not fdef then
    return nil, "definition of '" .. fname .. "' not found"
  end

  local params, variadic = get_params(fd, callee_src)
  if variadic then
    return nil, "cannot inline variadic function '" .. fname .. "'"
  end

  local arglist = call:field("arguments")[1]
  local args = {}
  for i = 0, arglist:named_child_count() - 1 do
    args[#args + 1] = text(arglist:named_child(i), caller_src)
  end
  if #args ~= #params then
    return nil, string.format("arity mismatch (%d args, %d params)", #args, #params)
  end

  local body = fdef:field("body")[1]
  local stmts = {}
  for i = 0, body:named_child_count() - 1 do
    stmts[#stmts + 1] = body:named_child(i)
  end
  if #stmts == 0 then
    return nil, "empty function body"
  end
  local returns = query_nodes(body, callee_src, "(return_statement) @r")

  -- Names hoisted into the caller scope; rename those that would collide.
  local scope = enclosing_scope(call, caller_src)
  local rename = {}
  local function maybe_rename(nm)
    if nm and scope[nm] then
      rename[nm] = nm .. "__ie" .. N
    end
  end
  for _, p in ipairs(params) do
    maybe_rename(p.name)
  end
  for _, s in ipairs(stmts) do
    if s:type() == "declaration" then
      for _, d in ipairs(query_nodes(s, callee_src, "(init_declarator declarator: (_) @d)")) do
        maybe_rename(decl_name(d, callee_src))
      end
      for _, d in ipairs(query_nodes(s, callee_src, "(declaration declarator: (identifier) @d)")) do
        maybe_rename(text(d, callee_src))
      end
    end
  end

  -- Body edits: label suffixing + collision renames (disjoint from return edits).
  local body_edits = {}
  local function suffix_label(n)
    body_edits[#body_edits + 1] = { sb(n), eb(n), text(n, callee_src) .. "__ie" .. N }
  end
  for _, n in ipairs(query_nodes(body, callee_src, "(labeled_statement label: (statement_identifier) @l)")) do
    suffix_label(n)
  end
  for _, n in ipairs(query_nodes(body, callee_src, "(goto_statement label: (statement_identifier) @g)")) do
    suffix_label(n)
  end
  if next(rename) then
    for _, id in ipairs(query_nodes(body, callee_src, "(identifier) @i")) do
      local r = rename[text(id, callee_src)]
      -- Do not rename the callee of a call (function names live in caller scope).
      local parent = id:parent()
      local is_callee = parent and parent:type() == "call_expression" and parent:field("function")[1] == id
      if r and not is_callee then
        body_edits[#body_edits + 1] = { sb(id), eb(id), r }
      end
    end
  end

  local binds = {}
  for i, p in ipairs(params) do
    binds[#binds + 1] = build_bind(p, args[i], rename, N, i, callee_src)
  end

  local ret_var = "__ie_ret" .. N
  local end_label = "__ie_end" .. N

  -- Rewrite `return E;` -> `{ ret = E; goto end; }` by editing only the `return`
  -- keyword and the `;` (leaving E for the label/rename edits above).
  -- style "goto": `return E;` -> `{ ret = E; goto end; }` (correct, self-contained)
  -- style "assign": `return E;` -> `ret = E;`            (readable, no control flow)
  local function return_edits(style)
    local eds = {}
    for _, r in ipairs(returns) do
      local kw = r:child(0)
      local semi = r:child(r:child_count() - 1)
      local has_expr = r:named_child_count() > 0
      if style == "assign" then
        eds[#eds + 1] = { sb(kw), eb(kw), has_expr and (ret_var .. " =") or "(void)0" }
      elseif has_expr then
        eds[#eds + 1] = { sb(kw), eb(kw), "{ " .. ret_var .. " =" }
        eds[#eds + 1] = { sb(semi), eb(semi), "; goto " .. end_label .. "; }" }
      else
        eds[#eds + 1] = { sb(kw), eb(kw), "{ goto " .. end_label .. ";" }
        eds[#eds + 1] = { sb(semi), eb(semi), " }" }
      end
    end
    return eds
  end

  local function splice(edits)
    return apply_edits(caller_src, 0, #caller_src, edits)
  end

  -- The statement the call lives in, and its indentation (tabs/spaces preserved).
  local target = enclosing_statement(call)
  local target_type = target:type()
  local stmt_bol = sb(target) - scol(target)
  local stmt_indent = caller_src:sub(stmt_bol + 1, sb(target))
  local unit = stmt_indent:find("\t") and "\t" or "    "

  -- Hoisting is only valid (in correct mode) when the call is reached
  -- unconditionally within a plain statement; short-circuit / ternary contexts
  -- and loop/if headers are not.
  local function hoist_safe()
    if not (target_type == "return_statement" or target_type == "expression_statement" or target_type == "declaration") then
      return false
    end
    local n = call
    while n and n ~= target do
      local t = n:type()
      if t == "conditional_expression" then
        return false
      end
      if t == "binary_expression" then
        for i = 0, n:child_count() - 1 do
          local ch = n:child(i)
          if not ch:named() and (text(ch, caller_src) == "&&" or text(ch, caller_src) == "||") then
            return false
          end
        end
      end
      n = n:parent()
    end
    return true
  end

  local last = stmts[#stmts]
  local callee_simple = #returns == 1 and last:type() == "return_statement" and last:named_child_count() > 0

  -- Pretty hoist: setup lifted above the statement, return expression spliced in.
  local function emit_pretty(wrap)
    local hoist = {}
    for _, b in ipairs(binds) do
      hoist[#hoist + 1] = b
    end
    if #stmts >= 2 then
      local rstart = sb(stmts[1]) - scol(stmts[1])
      vim.list_extend(hoist, rebase(apply_edits(callee_src, rstart, eb(stmts[#stmts - 1]), body_edits), ""))
    end
    local expr = last:named_child(0)
    local expr_text = apply_edits(callee_src, sb(expr), eb(expr), body_edits)

    if wrap then
      -- After a case/goto label a declaration needs a block to be a statement.
      local ttext = text(target, caller_src)
      local off = sb(call) - sb(target)
      local modified = ttext:sub(1, off) .. "(" .. expr_text .. ")" .. ttext:sub(eb(call) - sb(target) + 1)
      local inner = stmt_indent .. unit
      local out = { "{" }
      for _, l in ipairs(hoist) do
        out[#out + 1] = inner .. l
      end
      for _, l in ipairs(vim.split(modified, "\n", { plain = true })) do
        out[#out + 1] = inner .. l
      end
      out[#out + 1] = stmt_indent .. "}"
      return splice({ { sb(target), eb(target), table.concat(out, "\n") } })
    end

    local block = {}
    for _, l in ipairs(hoist) do
      block[#block + 1] = stmt_indent .. l
    end
    return splice({
      { stmt_bol, stmt_bol, table.concat(block, "\n") .. "\n" },
      { sb(call), eb(call), "(" .. expr_text .. ")" },
    })
  end

  -- Correct general form: GNU statement expression (self-contained, compiles).
  local function emit_stmt_expr()
    local edits = {}
    vim.list_extend(edits, body_edits)
    vim.list_extend(edits, return_edits("goto"))
    local rstart = sb(stmts[1]) - scol(stmts[1])
    local body_text = apply_edits(callee_src, rstart, eb(stmts[#stmts]), edits)
    local slot = ""
    if returns[1] and returns[1]:named_child_count() > 0 then
      slot = return_type(fdef, callee_src) .. " " .. ret_var .. ";"
    end
    local inner = stmt_indent .. unit
    local parts = { "({" }
    for _, b in ipairs(binds) do
      parts[#parts + 1] = inner .. b
    end
    if slot ~= "" then
      parts[#parts + 1] = inner .. slot
    end
    vim.list_extend(parts, rebase(body_text, inner))
    parts[#parts + 1] = inner .. end_label .. ":;"
    if slot ~= "" then
      parts[#parts + 1] = inner .. ret_var .. ";"
    end
    parts[#parts + 1] = stmt_indent .. "})"
    return splice({ { sb(call), eb(call), table.concat(parts, "\n") } })
  end

  -- Readable general form: body hoisted with return -> assignment, no ({})/goto.
  -- Reads top-to-bottom; not faithful for functions with early returns.
  local function emit_readable_multi()
    local edits = {}
    vim.list_extend(edits, body_edits)
    vim.list_extend(edits, return_edits("assign"))
    local rstart = sb(stmts[1]) - scol(stmts[1])
    local body_text = apply_edits(callee_src, rstart, eb(stmts[#stmts]), edits)
    local hoist = {}
    for _, b in ipairs(binds) do
      hoist[#hoist + 1] = stmt_indent .. b
    end
    if returns[1] and returns[1]:named_child_count() > 0 then
      hoist[#hoist + 1] = stmt_indent .. return_type(fdef, callee_src) .. " " .. ret_var .. ";"
    end
    vim.list_extend(hoist, rebase(body_text, stmt_indent))
    return splice({
      { stmt_bol, stmt_bol, table.concat(hoist, "\n") .. "\n" },
      { sb(call), eb(call), ret_var },
    })
  end

  if callee_simple and (mode == "readable" or hoist_safe()) then
    local parent_t = target:parent() and target:parent():type()
    local wrap = (mode == "correct") and (parent_t == "case_statement" or parent_t == "labeled_statement")
    return emit_pretty(wrap)
  end
  if mode == "readable" then
    return emit_readable_multi()
  end
  return emit_stmt_expr()
end

-- Climb from (row, col) to the innermost enclosing call_expression node.
local function call_at(root, row, col)
  local node = root:named_descendant_for_range(row, col, row, col)
  while node and node:type() ~= "call_expression" do
    node = node:parent()
  end
  return node
end

-- Name of the function called at (row, col), or nil.
function M.call_name_at(caller_src, row, col)
  local call = call_at(parse(caller_src), row, col)
  if not call then
    return nil
  end
  local fn = call:field("function")[1]
  return fn and fn:type() == "identifier" and text(fn, caller_src) or nil
end

-- Inline the call under the cursor (row, col are 0-indexed). Resolves the call to
-- an occurrence index and delegates to inline_call.
function M.inline_in_buffer(caller_src, row, col, callee_src, N, mode)
  local root = parse(caller_src)
  local call = call_at(root, row, col)
  if not call then
    return nil, "no call under the cursor"
  end
  local fn = call:field("function")[1]
  if not fn or fn:type() ~= "identifier" then
    return nil, "call target is not a plain function name"
  end
  local fname = text(fn, caller_src)

  local occ, i = nil, 0
  for _, id in ipairs(find_calls(root, caller_src, fname)) do
    i = i + 1
    if sb(id) == sb(call) then
      occ = i
      break
    end
  end
  return M.inline_call(caller_src, callee_src, fname, N, occ or 1, mode)
end

return M
