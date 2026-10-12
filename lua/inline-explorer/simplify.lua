-- Cosmetic: drops redundant parens from spliced text, such as the
-- `(({ ... }))` of kernel macros, which parenthesize at every level, or the
-- pretty printer's `(E)` around an E already in parens.
local csrc = require("inline-explorer.csrc")

local M = {}

-- `((X))` -> `(X)`, which never changes C's meaning. The text is parsed in a
-- dummy function, as an expression, else as statements; when neither parses
-- cleanly it is returned unchanged, so a splice is never corrupted.
function M.parens(text)
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

  -- 0-based byte offsets in `wrapped` of the parens to drop.
  local cuts = {}
  local function walk(node)
    if node:type() == "parenthesized_expression" and node:named_child_count() == 1 then
      local child = node:named_child(0)
      if child:type() == "parenthesized_expression" then
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

  -- Back to front, so each cut leaves the offsets still to cut in place.
  table.sort(cuts, function(a, b)
    return a > b
  end)
  local out = wrapped
  for _, pos in ipairs(cuts) do
    out = out:sub(1, pos) .. out:sub(pos + 2)
  end
  return out:sub(#chosen.pre + 1, #out - #chosen.post)
end

return M
