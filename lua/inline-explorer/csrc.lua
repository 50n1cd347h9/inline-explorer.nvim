-- Low-level tree-sitter/text helpers for C source: parsing, byte-range
-- accessors, declarator/type reconstruction, and edit application.
local M = {}

function M.parse(src)
  return vim.treesitter.get_string_parser(src, "c"):parse()[1]:root()
end

-- TSNode from a string parser exposes byte offsets only via range(true).
function M.sb(node)
  return (select(3, node:range(true)))
end
function M.eb(node)
  return (select(6, node:range(true)))
end
function M.scol(node)
  return (select(2, node:range(true)))
end

function M.text(node, src)
  return src:sub(M.sb(node) + 1, M.eb(node))
end

function M.query_nodes(node, src, q)
  local out = {}
  for _, n in vim.treesitter.query.parse("c", q):iter_captures(node, src) do
    out[#out + 1] = n
  end
  return out
end

-- Descend a declarator to its identifier name (through pointer/array/fn wrappers).
-- NOTE: parenthesized_declarator has no `declarator` field in tree-sitter-c, so
-- fall through it via its first named child (e.g. `int (*fp)(int)`).
function M.decl_name(decl, src)
  local n = decl
  while n do
    if n:type() == "identifier" then
      return M.text(n, src)
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
function M.func_declarator(decl)
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
function M.return_type(fdef, src)
  local ty = fdef:field("type")[1]
  local base = ty and M.text(ty, src) or "int"
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

function M.find_function_def(root, src, name)
  for i = 0, root:named_child_count() - 1 do
    local c = root:named_child(i)
    if c:type() == "function_definition" then
      local fd = M.func_declarator(c:field("declarator")[1])
      if fd and M.decl_name(fd:field("declarator")[1], src) == name then
        return c, fd
      end
    end
  end
end

function M.find_calls(root, src, name)
  local calls = {}
  for _, id in ipairs(M.query_nodes(root, src, "(call_expression function: (identifier) @f)")) do
    if M.text(id, src) == name then
      calls[#calls + 1] = id:parent()
    end
  end
  return calls
end

-- Parameters as { name = <string|false>, node = <parameter_declaration> }.
function M.get_params(fd, src)
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
        out[#out + 1] = { name = M.decl_name(decl, src), node = pc }
      elseif not (ty and M.text(ty, src) == "void") then
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
function M.build_bind(param, arg, rename, N, idx, src)
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
      local spec = src:sub(M.sb(param.node) + 1, M.sb(decl)):gsub("%s+$", "")
      local name = rename[M.text(d, src)] or M.text(d, src)
      return string.format("%s %s%s = (%s);", spec, stars, name, arg)
    end
  end
  local name = (param.name and (rename[param.name] or param.name)) or ("__ie_arg" .. idx .. "_" .. N)
  return string.format("__auto_type %s = (%s);", name, arg)
end

-- Apply {start_byte, end_byte, replacement} edits (absolute bytes) restricted to
-- the [s, e) region of src, returning that region's transformed text.
function M.apply_edits(src, s, e, edits)
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
function M.common_ws_prefix(lines)
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
function M.rebase(fragment, target)
  local lines = vim.split(fragment, "\n", { plain = true })
  local strip = #M.common_ws_prefix(lines)
  local out = {}
  for _, l in ipairs(lines) do
    out[#out + 1] = l:match("%S") and (target .. l:sub(strip + 1)) or ""
  end
  return out
end

return M
