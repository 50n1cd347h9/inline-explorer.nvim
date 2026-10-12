-- Small helpers shared across modules.
local M = {}

-- Every user-facing message carries the plugin's prefix. `level` is passed
-- through as given (nil is vim.notify's own default).
function M.notify(msg, level)
  vim.notify("[inline-explorer] " .. msg, level)
end

-- LSP positions count characters in the encoding negotiated with the server
-- (utf-16 by default, utf-8 for clangd), while cursor columns and tree-sitter
-- count bytes. byte_col and lsp_col convert a column of one line between the
-- two; a nil or "utf-8" encoding already counts bytes.

-- vim.str_byteindex and vim.str_utfindex changed signature in 0.11.
local has_011 = vim.fn.has("nvim-0.11") == 1
-- With strict indexing off, the 0.11 functions clamp an index past the end of
-- the line to the line's end instead of raising an error.
local STRICT_INDEXING = false

-- LSP `character` in `encoding` -> byte column in `line_text`. A character
-- past the end of the line gives the line's length; a nil or "utf-8" encoding
-- returns `character` unchanged.
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
  -- Before 0.11, an index past the end raises an error; clamp it here.
  return ok and col or #line_text
end

-- Byte column `byte` in `line_text` -> LSP `character` in `encoding`. A byte
-- past the end of the line counts as the line's end. A nil or "utf-8"
-- encoding returns `byte` unchanged, and so does a failed conversion.
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
