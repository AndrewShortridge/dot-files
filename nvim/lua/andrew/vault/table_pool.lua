local M = {}

-- ---------------------------------------------------------------------------
-- Pool class
-- ---------------------------------------------------------------------------

local Pool = {}
Pool.__index = Pool

--- Create a new object pool.
--- @param max_size integer Maximum pooled objects (excess are GC'd)
--- @param reset_fn function(obj) Reset object to clean state for reuse
--- @return table pool Pool instance with acquire/release methods
function M.new(max_size, reset_fn)
  local pool = setmetatable({
    _stack = {},
    _size = 0,
    _max_size = max_size,
    _reset_fn = reset_fn,
    _hits = 0,
    _misses = 0,
    _releases = 0,
    _overflows = 0,
  }, Pool)
  return pool
end

--- Acquire an object from the pool, or create a new one.
--- @param create_fn function() Factory for new objects (called on pool miss)
--- @return table obj
function Pool:acquire(create_fn)
  if self._size > 0 then
    local obj = self._stack[self._size]
    self._stack[self._size] = nil
    self._size = self._size - 1
    self._hits = self._hits + 1
    self._reset_fn(obj)
    return obj
  end
  self._misses = self._misses + 1
  return create_fn()
end

--- Release an object back to the pool for reuse.
--- If pool is full, object is simply abandoned for GC.
--- @param obj table
function Pool:release(obj)
  self._releases = self._releases + 1
  if self._size < self._max_size then
    self._size = self._size + 1
    self._stack[self._size] = obj
  else
    self._overflows = self._overflows + 1
  end
end

--- Release multiple objects at once.
--- @param objects table[] Array of objects to release
function Pool:release_batch(objects)
  for i = 1, #objects do
    self:release(objects[i])
    objects[i] = nil
  end
end

--- Get pool statistics.
--- @return table stats
function Pool:stats()
  local total = self._hits + self._misses
  return {
    hits = self._hits,
    misses = self._misses,
    hit_rate = total > 0 and (self._hits / total * 100) or 0,
    size = self._size,
    max_size = self._max_size,
    releases = self._releases,
    overflows = self._overflows,
  }
end

--- Clear all pooled objects.
function Pool:clear()
  for i = 1, self._size do
    self._stack[i] = nil
  end
  self._size = 0
end

-- ---------------------------------------------------------------------------
-- Scoped acquire/release (mirrors Zed's with_parser() pattern)
-- ---------------------------------------------------------------------------

--- Acquire an object, call a function with it, then release.
--- Guarantees release even on error.
--- @param pool table The pool instance
--- @param create_fn function Factory for new objects
--- @param use_fn function(obj) Function that uses the object
--- @return any result Return value of use_fn
function M.with(pool, create_fn, use_fn)
  local obj = pool:acquire(create_fn)
  local ok, result = pcall(use_fn, obj)
  pool:release(obj)
  if not ok then error(result, 2) end
  return result
end

-- ---------------------------------------------------------------------------
-- Registry for monitoring and bulk cleanup
-- ---------------------------------------------------------------------------

local _registry = {}

--- Register a named pool for monitoring.
--- @param name string
--- @param pool table
function M.register(name, pool)
  _registry[name] = pool
end

--- Get stats for all registered pools.
--- @return table<string, table>
function M.all_stats()
  local stats = {}
  for name, pool in pairs(_registry) do
    stats[name] = pool:stats()
  end
  return stats
end

--- Clear all registered pools.
function M.clear_all()
  for _, pool in pairs(_registry) do
    pool:clear()
  end
end

return M
