local M = {}

---@param msg string
---@param level? integer a vim.log.levels value
function M.notify(msg, level)
  vim.notify("[inline-explorer] " .. msg, level)
end

-- byte_col and lsp_col convert a column of one line between bytes (cursor and
-- tree-sitter columns) and the units of an LSP offset encoding. A nil or
-- "utf-8" encoding counts bytes, so the column is returned unchanged.

-- vim.str_byteindex and vim.str_utfindex changed signature in 0.11.
local has_011 = vim.fn.has("nvim-0.11") == 1
local STRICT_INDEXING = false

-- LSP `character` -> byte column. A character past the end of the line gives
-- the line's length.
---@param line_text string
---@param character integer
---@param encoding? string
---@return integer
function M.byte_col(line_text, character, encoding)
  if not encoding or encoding == "utf-8" or character == 0 then
    return character
  end
  local ok, col
  if has_011 then
    ok, col = pcall(vim.str_byteindex, line_text, encoding, character, STRICT_INDEXING)
  else
    ok, col = pcall(vim.str_byteindex, line_text, character, encoding == "utf-16")
  end
  -- Before 0.11, an index past the end raises an error.
  return ok and col or #line_text
end

-- Byte column -> LSP `character`. A byte past the end of the line counts as
-- the line's end, and a failed conversion returns `byte`.
---@param line_text string
---@param byte integer
---@param encoding? string
---@return integer
function M.lsp_col(line_text, byte, encoding)
  if not encoding or encoding == "utf-8" or byte == 0 then
    return byte
  end
  if has_011 then
    local ok, idx = pcall(vim.str_utfindex, line_text, encoding, byte, STRICT_INDEXING)
    return ok and idx or byte
  end
  local ok, u32, u16 = pcall(vim.str_utfindex, line_text, math.min(byte, #line_text))
  if not ok then
    return byte
  end
  return encoding == "utf-16" and u16 or u32
end

-- Drop the least recently used entries of `cache`, by their `at` stamps, until
-- `cap` remain. `on_evict(key, entry)` runs after each entry is removed.
---@generic K, V: { at: number }
---@param cache table<K, V>
---@param cap integer
---@param on_evict? fun(key: K, entry: V)
function M.evict_lru(cache, cap, on_evict)
  local entries = {}
  for k, e in pairs(cache) do
    entries[#entries + 1] = { k = k, at = e.at }
  end
  if #entries <= cap then
    return
  end
  table.sort(entries, function(a, b)
    return a.at < b.at
  end)
  for i = 1, #entries - cap do
    local k = entries[i].k
    local e = cache[k]
    cache[k] = nil
    if on_evict then
      on_evict(k, e)
    end
  end
end

return M
