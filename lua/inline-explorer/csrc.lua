-- Low-level tree-sitter/text helpers for C source: parsing, byte-range
-- accessors, declarator/type reconstruction, and edit application.
local M = {}

-- Parsed trees, keyed on the exact source text.
--
-- One smart-inline over a function parses the SAME caller source three times
-- -- substitute.call_name_at, substitute.inline_in_buffer and
-- canalyze.analyze_call each start from scratch -- and parsing is
-- proportional to the whole file while the user's action concerns one call.
-- Measured on a 25,007-line file: about 61ms per parse, ~236ms for the three
-- together.
--
-- Keying on the text itself makes invalidation exact rather than a policy:
-- edit the buffer and the string differs, so the entry cannot be reused.
-- Lua interns strings, so the lookup does not re-hash the file on every
-- call. The entry holds the parser and the tree alongside the root as
-- belt and braces, not as a correctness requirement: on this Neovim a
-- TSNode anchors its TSTree through its function environment (verified:
-- a root cached alone survived 50 GC cycles with all children and ranges
-- intact). An earlier version of this comment claimed the opposite.
M._parse_cache_n = 4
M._parse_cache = {}

function M.parse(src)
  local e = M._parse_cache[src]
  if e then
    e.at = vim.uv.hrtime()
    return e.root
  end
  local parser = vim.treesitter.get_string_parser(src, "c")
  local tree = parser:parse()[1]
  local root = tree:root()
  M._parse_cache[src] = { parser = parser, tree = tree, root = root, at = vim.uv.hrtime() }

  local n, entries = 0, {}
  for k, v in pairs(M._parse_cache) do
    n = n + 1
    entries[n] = { k = k, at = v.at }
  end
  if n > M._parse_cache_n then
    table.sort(entries, function(a, b)
      return a.at < b.at
    end)
    for i = 1, n - M._parse_cache_n do
      M._parse_cache[entries[i].k] = nil
    end
  end
  return root
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

-- C type/type-qualifier keywords that can start (or continue) a base type. A
-- leading token outside this set cannot itself be a type -- it is either a
-- storage-class specifier (static, extern, ...) or, per zlib's `#define
-- local static`, a project macro standing in for one. A token after the type
-- has already started that falls outside this set is not part of the type
-- either (e.g. zlib's `ZEXPORT` calling-convention decorator).
local TYPE_STARTERS = {
  void = true, char = true, short = true, int = true, long = true,
  float = true, double = true, signed = true, unsigned = true,
  ["_Bool"] = true, struct = true, union = true, enum = true,
  const = true, volatile = true,
}

-- Project macros known to stand in for a storage-class specifier in front of
-- a type, confirmed from real source (zlib's `#define local static`, used
-- ahead of typedef return types tree-sitter has no way to recognize as types
-- -- `local block_state deflate_stored(...)`, `local uInt longest_match(...)`
-- -- so no keyword ever appears anywhere in the run to prove `local` isn't
-- the type). Recognizing the macro by name is necessary but not sufficient --
-- no whole-file context is available here (see return_type's callers), so
-- there is no way to tell this apart, by name alone, from `local` instead
-- being a genuine project type (e.g. `typedef long local;`) with an ordinary
-- decorator macro after it that expands to nothing (`local WINAPI f(...)`).
-- Both shapes put a bare identifier in the ERROR sibling; looks_like_bare_decorator
-- below narrows this against a small curated list of known decorator-macro
-- spellings, not a general rule -- it does not resolve the ambiguity for
-- macros outside that list. See its own comment for what that residual is
-- and why the list's default (unrecognized => real type) is the right way
-- to be wrong.
local KNOWN_LEADING_MACROS = { ["local"] = true }

local function tokenize(text)
  local tokens = {}
  for tok in text:gmatch("%S+") do
    tokens[#tokens + 1] = tok
  end
  return tokens
end

local function has_type_starter(text)
  for tok in text:gmatch("%S+") do
    if TYPE_STARTERS[tok] then
      return true
    end
  end
  return false
end

-- Calling-convention/visibility decorator macros that vanish at the
-- preprocessor and so appear as a bare identifier immediately after a
-- KNOWN_LEADING_MACROS-spelled type with nothing of their own to contribute
-- to it. The two entries do not rest on the same evidence, and a reader
-- should not assume they do:
--
--   * WINAPI is attested (zconf.h's `#define ZEXPORT WINAPI`, alongside
--     ZEXPORTVA/WINAPIV) and load-bearing -- removing it turns case30 red.
--   * ZEXPORT is precautionary. It is a real zlib name, but no test and no
--     corpus site exercises it here: `local ZEXPORT` occurs nowhere in
--     zlib's .c files, and `z_size_t ZEXPORT deflateBound_z(...)` never
--     reaches this branch at all (`z_size_t` is not in KNOWN_LEADING_MACROS,
--     so the second clause is false whatever this list holds). Removing it
--     changes no test and no real-source result. It is here for symmetry
--     with the convention it belongs to, not because it has been validated
--     the way WINAPI has.
--
-- Capitalization alone is deliberately NOT used as the signal, even though
-- both known entries happen to be ALL-CAPS: an ALL-CAPS single-word type is
-- an ordinary, widespread C convention well outside zlib (Windows SDK
-- style -- DWORD, BOOL, UINT, HANDLE; embedded/systems style -- U32, S8,
-- STATUS, single-letter T), so treating shape alone as proof of "decorator,
-- not type" misfires on exactly the input this guard exists to protect --
-- silently, since the wrong slot type still compiles under zlib's own
-- `#define local static`.
--
-- This name-list is necessarily incomplete: a project's own decorator macro
-- that is neither ZEXPORT nor WINAPI (e.g. a hypothetical EXPORT_API) will
-- not be recognized here, so the KNOWN_LEADING_MACROS-spelled token in
-- front of it will be wrongly read as a genuine type and the decorator
-- spliced in as if it were the type instead. That residual is real and
-- narrower than the shape it replaces: the overwhelmingly common case
-- across every real corpus this engine has been run against is the ERROR
-- sibling BEING the true type (80+ real zlib call sites), which requires a
-- program to have a typedef literally named `local` to go wrong the other
-- way, versus a decorator macro spelled anything other than these two known
-- names to go wrong this way. It is also milder in kind: a decorator that
-- vanishes at the preprocessor leaves the result slot as a bare
-- `__ie_retN;`, which is a compile error, not a wrong value that runs
-- (measured: `local DLLEXPORT f(...)` fails with `'__ie_ret1' undeclared`).
local KNOWN_DECORATOR_MACROS = { ZEXPORT = true, WINAPI = true }

local function looks_like_bare_decorator(text)
  local tokens = tokenize(text)
  return #tokens == 1 and KNOWN_DECORATOR_MACROS[tokens[1]] == true
end

-- Reconstruct a base type from a run of text known (by the guards at each
-- call site below) to contain a real type keyword somewhere, but which may
-- also carry an unrecognized leading macro (zlib's `local`, standing in for
-- `static`). Leading tokens are dropped only while a recognized type
-- keyword still appears later in the run -- that is the signature of a
-- leading macro. Once positioned on the first real token, further keyword
-- tokens are folded in (`unsigned long`, `struct foo`) but the first
-- non-keyword token ends the type -- so a *trailing* decorator (`ZEXPORT`)
-- is left out, matching what field("type") alone already does when it
-- isolates the real type correctly on its own.
local function base_type_from_run(text)
  local tokens = tokenize(text)
  if #tokens == 0 then
    return "int"
  end
  local i = 1
  while i < #tokens and not TYPE_STARTERS[tokens[i]] do
    local starter_ahead = false
    for j = i + 1, #tokens do
      if TYPE_STARTERS[tokens[j]] then
        starter_ahead = true
        break
      end
    end
    if not starter_ahead then
      break
    end
    i = i + 1
  end
  local out = { tokens[i] }
  local j = i + 1
  while true do
    local last, nxt = out[#out], tokens[j]
    if (last == "struct" or last == "union" or last == "enum") and nxt and not TYPE_STARTERS[nxt] then
      out[#out + 1] = nxt -- tag name, e.g. `struct foo`
      j = j + 1
    elseif nxt and TYPE_STARTERS[nxt] then
      out[#out + 1] = nxt
      j = j + 1
    else
      break
    end
  end
  return table.concat(out, " ")
end

-- Reconstruct a function's declared return type text (base type + pointer depth),
-- so the statement-expression result slot does not depend on body-local names the
-- way `__typeof__(return expr)` would.
--
-- field("type") is trusted by default: it already gets exotic shapes right
-- that a from-scratch text scan would mangle, notably a function-like macro
-- wrapping the type (cJSON's `CJSON_PUBLIC(cJSON *) f(...)`, grammar node
-- `macro_type_specifier`), which must pass through verbatim so it
-- macro-expands correctly at the real call site. One narrow, known-bad shape
-- is corrected instead of doing a blanket rescan: a bare, non-keyword
-- type_identifier (e.g. `local`) with the true type demoted to an
-- immediately following ERROR sibling -- zlib's `local int f(...)` and
-- `local block_state deflate_stored(...)`. Only fires when the ERROR
-- sibling itself contains a recognized type keyword, or its name is on the
-- small KNOWN_LEADING_MACROS allowlist and it is not a bare, single token
-- on the KNOWN_DECORATOR_MACROS name-list (see looks_like_bare_decorator)
-- -- otherwise field("type") is left as-is, which is what keeps zlib's own
-- `z_size_t ZEXPORT deflateBound_z(...)` untouched (ERROR sibling
-- `ZEXPORT`, no keyword, and `z_size_t` is not on the KNOWN_LEADING_MACROS
-- allowlist).
--
-- A sized_type_specifier can be poisoned the same way as the bare-identifier
-- case but with no ERROR sibling to recover from: `local unsigned long`
-- parses as ONE sized_type_specifier spanning all three words. That is
-- handled by rescanning the field's own (self-contained) text.
function M.return_type(fdef, src)
  local decl = fdef:field("declarator")[1]
  local ty = fdef:field("type")[1]
  local base = ty and M.text(ty, src) or "int"

  if ty and ty:type() == "sized_type_specifier" then
    base = base_type_from_run(base)
  elseif ty and ty:type() == "type_identifier" and not TYPE_STARTERS[base] then
    local sib = ty:next_sibling()
    if sib and sib:type() == "ERROR" then
      local sib_text = M.text(sib, src)
      if has_type_starter(sib_text)
        or (KNOWN_LEADING_MACROS[base] and not looks_like_bare_decorator(sib_text)) then
        base = base_type_from_run(sib_text)
      end
    end
  end

  local depth, d = 0, decl
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
