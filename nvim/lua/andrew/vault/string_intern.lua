--- String interning pool for deduplicating frequently-repeated strings.
--- Lua interns short strings automatically, but this module ensures
--- computed strings (from lower(), match(), sub()) share allocations.
---
--- Inspired by Zed's SharedString/ArcCow pattern and the existing
--- intern_desc() pool in completion.lua.

local M = {}

--- @class StringPool
--- @field _pool table<string, string> Canonical string references
--- @field _size number Current pool size
--- @field _max number Maximum pool capacity
--- @field _hits number Cache hit count
--- @field _misses number Cache miss count

--- Create a new string pool.
--- @param max number Maximum unique strings to intern (default 10000)
--- @return StringPool
function M.new(max)
  return {
    _pool = {},
    _size = 0,
    _max = max or 10000,
    _hits = 0,
    _misses = 0,
  }
end

--- Intern a string, returning the canonical reference.
--- @param pool StringPool
--- @param s string|nil
--- @return string|nil
function M.intern(pool, s)
  if s == nil or s == "" then return s end

  local canonical = pool._pool[s]
  if canonical then
    pool._hits = pool._hits + 1
    return canonical
  end

  pool._misses = pool._misses + 1

  -- Evict all if over capacity (simple strategy; LRU not needed for strings)
  if pool._size >= pool._max then
    pool._pool = {}
    pool._size = 0
  end

  pool._pool[s] = s
  pool._size = pool._size + 1
  return s
end

--- Intern a string after lowercasing it.
--- @param pool StringPool
--- @param s string|nil
--- @return string|nil
function M.intern_lower(pool, s)
  if s == nil or s == "" then return s end
  return M.intern(pool, s:lower())
end

--- Get pool statistics.
--- @param pool StringPool
--- @return table { size: number, max: number, hits: number, misses: number, hit_rate: number }
function M.stats(pool)
  local total = pool._hits + pool._misses
  return {
    size = pool._size,
    max = pool._max,
    hits = pool._hits,
    misses = pool._misses,
    hit_rate = total > 0 and (pool._hits / total * 100) or 0,
  }
end

--- Clear the pool (preserves max setting).
--- @param pool StringPool
function M.clear(pool)
  pool._pool = {}
  pool._size = 0
end

--- Reset pool statistics.
--- @param pool StringPool
function M.reset_stats(pool)
  pool._hits = 0
  pool._misses = 0
end

return M
