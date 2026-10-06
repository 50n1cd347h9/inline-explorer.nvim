-- Small helpers shared across modules.
local M = {}

-- Every user-facing message carries the plugin's prefix. `level` is passed
-- through as given (nil is vim.notify's own default).
function M.notify(msg, level)
  vim.notify("[inline-explorer] " .. msg, level)
end

-- LSP positions count characters in the encoding negotiated with the
-- server (utf-16 by default, utf-8 for clangd), while cursor columns and
-- tree-sitter count bytes. These convert one `line`'s column between the
-- two; a nil or "utf-8" encoding is bytes already. vim.str_byteindex and
-- vim.str_utfindex changed signature in 0.11, hence the branch.
local has_011 = vim.fn.has("nvim-0.11") == 1

-- LSP `character` in `encoding` -> byte column. Clamped to the line.
function M.byte_col(line, character, encoding)
  if not encoding or encoding == "utf-8" or character == 0 then
    return character
  end
  local ok, col
  if has_011 then
    ok, col = pcall(vim.str_byteindex, line, encoding, character, false)
  else
    ok, col = pcall(vim.str_byteindex, line, character, encoding == "utf-16")
  end
  return ok and col or #line
end

-- Byte column -> LSP `character` in `encoding`. Clamped to the line.
function M.lsp_col(line, byte, encoding)
  if not encoding or encoding == "utf-8" or byte == 0 then
    return byte
  end
  if has_011 then
    local ok, idx = pcall(vim.str_utfindex, line, encoding, byte, false)
    return ok and idx or byte
  end
  local ok, u32, u16 = pcall(vim.str_utfindex, line, math.min(byte, #line))
  if not ok then
    return byte
  end
  return encoding == "utf-16" and u16 or u32
end

-- Bound a cache whose entries carry `at` (a recency stamp) to `cap` entries,
-- dropping the least recently used. `on_evict(key, entry)` runs for each
-- dropped entry, after it is removed.
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
