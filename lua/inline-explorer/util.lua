-- Small helpers the modules share: a notification with the plugin's prefix,
-- column conversion between bytes and LSP offset encodings, and eviction
-- from the LRU caches.
local M = {}

---@param msg string
---@param level? integer a vim.log.levels value
function M.notify(msg, level)
  vim.notify("[inline-explorer] " .. msg, level)
end

-- byte_col and lsp_col convert a column of one line between bytes (cursor and
-- tree-sitter columns) and the units of an LSP offset encoding, nil meaning
-- "utf-8". A column past the end of the line counts as the line's end.

---@param line_text string
---@param character integer
---@param encoding? string
---@return integer
function M.byte_col(line_text, character, encoding)
  return vim.str_byteindex(line_text, encoding or "utf-8", character, false)
end

---@param line_text string
---@param byte integer
---@param encoding? string
---@return integer
function M.lsp_col(line_text, byte, encoding)
  return vim.str_utfindex(line_text, encoding or "utf-8", byte, false)
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
