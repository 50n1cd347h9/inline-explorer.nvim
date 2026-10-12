-- Cosmetic simplification of spliced text. Kernel macros parenthesize
-- defensively at every level, so faithful expansions arrive wrapped in noise
-- like `(({ ... }))`; the pretty printer's own `(expr)` wrapping can also
-- double up when the return expression was already parenthesized.
local csrc = require("inline-explorer.csrc")

local M = {}

-- Collapse redundant paren nests: every parenthesized_expression whose only
-- named child is itself a parenthesized_expression loses its outer pair
-- (`((X))` -> `(X)`), which is always semantics-preserving in C. The fragment
-- is parsed inside a dummy function body, either as the right-hand side of an
-- assignment (an expression) or on its own (a statement). If neither parses
-- without errors, the text is returned untouched, so simplification can never
-- corrupt a splice.
function M.parens(text)
  -- The expression wrapper comes first, then the statement wrapper (for a
  -- do-while and the like). The first one that parses cleanly is used.
  local wrappers = {
    { pre = "void __ie_w(void) {\n__ie_sink =\n", post = "\n;\n}\n" },
    { pre = "void __ie_w(void) {\n", post = "\n}\n" },
  }
  local chosen, wrapped, root
  for _, w in ipairs(wrappers) do
    local candidate = w.pre .. text .. w.post
    local ok, parser = pcall(vim.treesitter.get_string_parser, candidate, "c")
    if ok and parser then
      local r = parser:parse()[1]:root()
      if not r:has_error() then
        chosen = w
        wrapped = candidate
        root = r
        break
      end
    end
  end
  if not root then
    return text
  end

  -- Byte positions (0-based, within `wrapped`) of the parens to drop.
  local cuts = {}
  local function walk(node)
    if node:type() == "parenthesized_expression" and node:named_child_count() == 1 then
      local child = node:named_child(0)
      if child:type() == "parenthesized_expression" then
        -- The outer '(' is node's first byte, and the outer ')' its last.
        cuts[#cuts + 1] = csrc.start_byte(node)
        cuts[#cuts + 1] = csrc.end_byte(node) - 1
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

  -- Cut back to front, so each deletion leaves the positions still to cut
  -- where they were. out:sub(1, pos) is the text before 0-based `pos`, and
  -- out:sub(pos + 2) the text after it.
  table.sort(cuts, function(a, b)
    return a > b
  end)
  local out = wrapped
  for _, pos in ipairs(cuts) do
    out = out:sub(1, pos) .. out:sub(pos + 2)
  end
  -- Strip the wrapper again.
  return out:sub(#chosen.pre + 1, #out - #chosen.post)
end

return M
