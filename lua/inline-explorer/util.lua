-- Small helpers shared across modules.
local M = {}

-- Every user-facing message carries the plugin's prefix. `level` is passed
-- through as given (nil is vim.notify's own default).
function M.notify(msg, level)
  vim.notify("[inline-explorer] " .. msg, level)
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
