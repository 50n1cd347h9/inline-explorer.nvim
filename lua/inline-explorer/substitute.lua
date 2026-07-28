-- C inline substitution: replace a call `f(args)` with the effect of f's body,
-- as a compilable source transform (GNU C).
--
--   * parameters      -> bindings that reconstruct each parameter's declared
--                        type (arrays decay to pointers, handles pointers/
--                        fn-ptrs); falls back to `__auto_type` for exotic
--                        declarators
--   * single-return    -> "pretty" hoist: setup statements lifted above the call
--     straight-line       statement, the returned expression spliced in place
--   * anything else    -> GNU statement expression `({ ... })` with each
--                        `return E;` rewritten to `{ __ie_retN = E; goto end; }`
--                        and the reconstructed declared return type as
--                        `__ie_retN`'s slot
--   * callee labels    -> suffixed `label__ieN` (labels are function-scoped, so
--                        inlining twice would otherwise collide)
--   * name collisions  -> hoisted locals that clash with the caller scope are
--                        suffixed `name__ieN`
--
-- The transform is pure text/tree-sitter and language-specific to C. `N` is a
-- per-expansion id that keeps injected/renamed names unique.
--
-- Structure: analyze_callee -> IR, analyze_context -> ctx, decide (the single
-- decision point) -> one of three layout-only printers (pretty / canonical
-- statement-expression / readable-multi).
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
-- NOTE: parenthesized_declarator has no `declarator` field in tree-sitter-c, so
-- fall through it via its first named child (e.g. `int (*fp)(int)`).
local function decl_name(decl, src)
  local n = decl
  while n do
    if n:type() == "identifier" then
      return text(n, src)
    end
    local d = n:field("declarator")[1]
    if not d and n:type() == "parenthesized_declarator" then
      d = n:named_child(0)
    end
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
    if n:type() == "pointer_declarator" then
      n = n:field("declarator")[1]
    elseif n:type() == "parenthesized_declarator" then
      n = n:field("declarator")[1] or n:named_child(0)
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

-- ---------------------------------------------------------------------------
-- Analysis: resolve the callee into a small IR and the call site into a ctx,
-- so that a single decision point picks one of three "dumb" printers. The
-- printers do layout only; every judgement lives in analyze_* / decide.
-- ---------------------------------------------------------------------------

-- IR: everything the printers need to know about the callee.
--   params/rename   parameter list and planned collision renames (name__ieN)
--   stmts/returns   body statement nodes and return_statement nodes
--   body_edits      label-suffix + rename edits on callee_src (absolute bytes)
--   ret_type        reconstructed declared return type text
--   has_value       whether returns carry an expression
--   simple          straight-line body with a single trailing return
--   ret_var/end_label  injected names, unique per expansion id N
--   binds           bound-parameter lines, populated by inline_call after the
--                   arity check (nil in _probe results)
local function analyze_callee(callee_src, fname, N, scope)
  local fdef, fd = find_function_def(parse(callee_src), callee_src, fname)
  if not fdef then
    return nil, "definition of '" .. fname .. "' not found"
  end
  local params, variadic = get_params(fd, callee_src)
  if variadic then
    return nil, "cannot inline variadic function '" .. fname .. "'"
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

  local last = stmts[#stmts]
  return {
    src = callee_src,
    params = params,
    rename = rename,
    stmts = stmts,
    returns = returns,
    body_edits = body_edits,
    ret_type = return_type(fdef, callee_src),
    has_value = returns[1] ~= nil and returns[1]:named_child_count() > 0,
    simple = #returns == 1 and last:type() == "return_statement" and last:named_child_count() > 0,
    ret_var = "__ie_ret" .. N,
    end_label = "__ie_end" .. N,
  }
end

-- ctx: everything the printers need to know about the call site.
--   braced          the enclosing statement sits directly inside a {} block
--                   (if not, hoisting printers must wrap in a block: a
--                   declaration cannot follow a bare label / unbraced if body)
--   unconditional   the call is reached unconditionally in a plain statement
--                   (not in a loop/if header, ?: arm, or after &&/||)
--   stmt_bol/indent/unit  layout facts; the source's tabs/spaces are preserved
local function analyze_context(caller_src, call)
  local target = enclosing_statement(call)
  local t = target:type()
  local unconditional = t == "return_statement" or t == "expression_statement" or t == "declaration"
  if unconditional then
    local n = call
    while n and n ~= target do
      local ty = n:type()
      if ty == "conditional_expression" then
        unconditional = false
      elseif ty == "binary_expression" then
        for i = 0, n:child_count() - 1 do
          local ch = n:child(i)
          if not ch:named() and (text(ch, caller_src) == "&&" or text(ch, caller_src) == "||") then
            unconditional = false
          end
        end
      end
      n = n:parent()
    end
  end
  local stmt_bol = sb(target) - scol(target)
  local indent = caller_src:sub(stmt_bol + 1, sb(target))
  local parent_t = target:parent() and target:parent():type()
  return {
    call = call,
    target = target,
    braced = parent_t == "compound_statement",
    unconditional = unconditional,
    stmt_bol = stmt_bol,
    indent = indent,
    unit = indent:find("\t") and "\t" or "    ",
  }
end

-- The single decision point: which printer renders this expansion.
--   pretty          simple callee, and hoisting is provably safe (or the user
--                   asked for readable output, which tolerates the risk)
--   readable_multi  readable mode for everything else: no ({...})/goto, may
--                   not preserve semantics (documented trade-off)
--   canonical       the always-correct GNU statement expression + goto form
local function decide(ir, ctx, mode)
  if ir.simple and (mode == "readable" or ctx.unconditional) then
    return "pretty"
  end
  if mode == "readable" then
    return "readable_multi"
  end
  return "canonical"
end

-- ---------------------------------------------------------------------------
-- Printers: pure layout. Each receives (caller_src, ir, ctx) and returns the
-- transformed caller source. No judgements here beyond mechanical wrapping.
-- ---------------------------------------------------------------------------

local function splice(caller_src, edits)
  return apply_edits(caller_src, 0, #caller_src, edits)
end

-- Rewrite `return E;` inside the body region.
-- style "goto":   `return E;` -> `{ ret = E; goto end; }` (self-contained)
-- style "assign": `return E;` -> `ret = E;`               (no control flow)
local function return_edits(ir, style)
  local eds = {}
  for _, r in ipairs(ir.returns) do
    local kw = r:child(0)
    local semi = r:child(r:child_count() - 1)
    local has_expr = r:named_child_count() > 0
    if style == "assign" then
      eds[#eds + 1] = { sb(kw), eb(kw), has_expr and (ir.ret_var .. " =") or "(void)0" }
    elseif has_expr then
      eds[#eds + 1] = { sb(kw), eb(kw), "{ " .. ir.ret_var .. " =" }
      eds[#eds + 1] = { sb(semi), eb(semi), "; goto " .. ir.end_label .. "; }" }
    else
      eds[#eds + 1] = { sb(kw), eb(kw), "{ goto " .. ir.end_label .. ";" }
      eds[#eds + 1] = { sb(semi), eb(semi), " }" }
    end
  end
  return eds
end

-- Body statements [1..last_i] with `extra` edits applied, dedented to "".
local function body_text(ir, last_i, extra)
  local edits = {}
  vim.list_extend(edits, ir.body_edits)
  vim.list_extend(edits, extra or {})
  local rstart = sb(ir.stmts[1]) - scol(ir.stmts[1])
  return apply_edits(ir.src, rstart, eb(ir.stmts[last_i]), edits)
end

-- Replace the whole target statement with `{ hoist...; modified target }`.
local function print_wrapped(caller_src, ir, ctx, hoist, replacement)
  local ttext = text(ctx.target, caller_src)
  local off = sb(ctx.call) - sb(ctx.target)
  local modified = ttext:sub(1, off) .. replacement .. ttext:sub(eb(ctx.call) - sb(ctx.target) + 1)
  local inner = ctx.indent .. ctx.unit
  local out = { "{" }
  for _, l in ipairs(hoist) do
    out[#out + 1] = inner .. l
  end
  for _, l in ipairs(vim.split(modified, "\n", { plain = true })) do
    out[#out + 1] = inner .. l
  end
  out[#out + 1] = ctx.indent .. "}"
  return splice(caller_src, { { sb(ctx.target), eb(ctx.target), table.concat(out, "\n") } })
end

-- Insert `hoist` lines above the target statement and swap the call for
-- `replacement`; wraps in a block when the target is not directly braced.
local function print_hoisted(caller_src, ir, ctx, hoist, replacement)
  if not ctx.braced then
    return print_wrapped(caller_src, ir, ctx, hoist, replacement)
  end
  local block = {}
  for _, l in ipairs(hoist) do
    block[#block + 1] = ctx.indent .. l
  end
  return splice(caller_src, {
    { ctx.stmt_bol, ctx.stmt_bol, table.concat(block, "\n") .. "\n" },
    { sb(ctx.call), eb(ctx.call), replacement },
  })
end

-- Pretty hoist: setup lifted above the statement, the returned expression
-- spliced in place (parenthesised, so precedence is preserved).
local function print_pretty(caller_src, ir, ctx)
  local hoist = {}
  vim.list_extend(hoist, ir.binds)
  if #ir.stmts >= 2 then
    vim.list_extend(hoist, rebase(body_text(ir, #ir.stmts - 1), ""))
  end
  local expr = ir.stmts[#ir.stmts]:named_child(0)
  local expr_text = apply_edits(ir.src, sb(expr), eb(expr), ir.body_edits)
  return print_hoisted(caller_src, ir, ctx, hoist, "(" .. expr_text .. ")")
end

-- Canonical form: GNU statement expression + return->goto. Legal in any
-- expression context, so it needs no wrapping and no safety analysis.
local function print_canonical(caller_src, ir, ctx)
  local inner = ctx.indent .. ctx.unit
  local parts = { "({" }
  for _, b in ipairs(ir.binds) do
    parts[#parts + 1] = inner .. b
  end
  if ir.has_value then
    parts[#parts + 1] = inner .. ir.ret_type .. " " .. ir.ret_var .. ";"
  end
  vim.list_extend(parts, rebase(body_text(ir, #ir.stmts, return_edits(ir, "goto")), inner))
  parts[#parts + 1] = inner .. ir.end_label .. ":;"
  if ir.has_value then
    parts[#parts + 1] = inner .. ir.ret_var .. ";"
  end
  parts[#parts + 1] = ctx.indent .. "})"
  return splice(caller_src, { { sb(ctx.call), eb(ctx.call), table.concat(parts, "\n") } })
end

-- Readable general form: body hoisted with return -> assignment, no ({})/goto.
-- Reads top-to-bottom; not faithful for functions with early returns.
local function print_readable_multi(caller_src, ir, ctx)
  local hoist = {}
  vim.list_extend(hoist, ir.binds)
  if ir.has_value then
    hoist[#hoist + 1] = ir.ret_type .. " " .. ir.ret_var .. ";"
  end
  vim.list_extend(hoist, rebase(body_text(ir, #ir.stmts, return_edits(ir, "assign")), ""))
  return print_hoisted(caller_src, ir, ctx, hoist, ir.ret_var)
end

local PRINTERS = {
  pretty = print_pretty,
  canonical = print_canonical,
  readable_multi = print_readable_multi,
}

-- Build the transform. Returns (new_caller_src, err).
-- mode: "correct" (default, guaranteed to compile) or "readable" (cleaner
-- output that skips ({...})/goto and may not compile in edge cases).
function M.inline_call(caller_src, callee_src, fname, N, occ, mode)
  N = N or 1
  occ = occ or 1
  mode = mode or "correct"

  local call = find_calls(parse(caller_src), caller_src, fname)[occ]
  if not call then
    return nil, "call to '" .. fname .. "' not found"
  end

  local ir, err = analyze_callee(callee_src, fname, N, enclosing_scope(call, caller_src))
  if not ir then
    return nil, err
  end

  local arglist = call:field("arguments")[1]
  local args = {}
  for i = 0, arglist:named_child_count() - 1 do
    args[#args + 1] = text(arglist:named_child(i), caller_src)
  end
  if #args ~= #ir.params then
    return nil, string.format("arity mismatch (%d args, %d params)", #args, #ir.params)
  end
  ir.binds = {}
  for i, p in ipairs(ir.params) do
    ir.binds[i] = build_bind(p, args[i], ir.rename, N, i, callee_src)
  end

  local ctx = analyze_context(caller_src, call)
  return PRINTERS[decide(ir, ctx, mode)](caller_src, ir, ctx)
end

-- Test/introspection hook: run the analysis without printing.
function M._probe(caller_src, callee_src, fname, occ, mode)
  local call = find_calls(parse(caller_src), caller_src, fname)[occ or 1]
  if not call then
    return nil, "call to '" .. fname .. "' not found"
  end
  local ir, err = analyze_callee(callee_src, fname, 1, enclosing_scope(call, caller_src))
  if not ir then
    return nil, err
  end
  local ctx = analyze_context(caller_src, call)
  return { ir = ir, ctx = ctx, decision = decide(ir, ctx, mode or "correct") }
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
