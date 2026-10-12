-- Cosmetic simplification of spliced text. Kernel macros parenthesize
-- defensively at every level, so faithful expansions arrive wrapped in noise
-- like `(({ ... }))`; the pretty printer's own `(expr)` wrapping can also
-- double up when the return expression was already parenthesized.
local csrc = require("inline-explorer.csrc")

local M = {}

-- Collapse redundant paren nests: every parenthesized_expression whose only
-- named child is itself a parenthesized_expression loses its outer pair
-- (`((X))` -> `(X)`), which is always semantics-preserving in C. The fragment
-- is parsed inside a function-body wrapper so both expressions and statements
-- get expression context; on any parse error the text is returned untouched
-- (simplification must never be able to corrupt a splice).
function M.parens(text)
  -- A bare expression needs an assignment + semicolon to be a valid statement;
  -- a statement fragment (do-while, ...) needs neither. Try both wrappers and
  -- take the first that parses clean.
  local wrappers = {
    { pre = "void __ie_w(void) {\n__ie_sink =\n", post = "\n;\n}\n" },
    { pre = "void __ie_w(void) {\n", post = "\n}\n" },
  }
  local wrapped, prefix, postfix, root
  for _, w in ipairs(wrappers) do
    local cand = w.pre .. text .. w.post
    local ok, parser = pcall(vim.treesitter.get_string_parser, cand, "c")
    if ok and parser then
      local r = parser:parse()[1]:root()
      if not r:has_error() then
        wrapped, prefix, postfix, root = cand, w.pre, w.post, r
        break
      end
    end
  end
  if not root then
    return text
  end

  -- Byte positions (0-based, within `wrapped`) of paren pairs to drop.
  local cuts = {}
  local function walk(node)
    if node:type() == "parenthesized_expression" and node:named_child_count() == 1 then
      local child = node:named_child(0)
      if child:type() == "parenthesized_expression" then
        cuts[#cuts + 1] = csrc.start_byte(node) -- the '('
        cuts[#cuts + 1] = csrc.end_byte(node) - 1 -- the ')'
      end
    end
    for c in node:iter_children() do
      walk(c)
    end
  end
  walk(root)
  if #cuts == 0 then
    return text
  end

  table.sort(cuts, function(a, b)
    return a > b
  end)
  local out = wrapped
  for _, byte in ipairs(cuts) do
    out = out:sub(1, byte) .. out:sub(byte + 2)
  end
  -- Unwrap: strip the wrapper prefix and postfix.
  return out:sub(#prefix + 1, #out - #postfix)
end

return M
