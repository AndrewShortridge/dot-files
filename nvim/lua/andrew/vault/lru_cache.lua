--- Lightweight LRU cache for bounded memoization.
--- Uses a hash table + ordered eviction list.
local M = {}

--- Create a new LRU cache.
---@param max_size number Maximum entries before eviction
---@return table cache instance with :get(), :put(), :clear(), :size(), :remove(), :entries()
function M.new(max_size)
  assert(max_size > 0, "LRU max_size must be positive")
  local cache = {}
  local order = {} -- array of keys in insertion/access order (oldest first)
  local lookup = {} -- key -> value
  local n = 0

  --- Move key to most-recently-used position.
  local function promote(key)
    for i = 1, n do
      if order[i] == key then
        table.remove(order, i)
        order[n] = key
        return
      end
    end
  end

  --- Get a cached value. Returns nil on miss.
  --- Promotes key to most-recently-used on hit.
  function cache:get(key)
    local val = lookup[key]
    if val == nil then return nil end
    promote(key)
    return val
  end

  --- Insert or update a cache entry.
  --- Evicts least-recently-used entry if at capacity.
  function cache:put(key, value)
    if lookup[key] ~= nil then
      -- Update existing: promote
      lookup[key] = value
      promote(key)
      return
    end
    -- Evict if at capacity
    if n >= max_size then
      local evict_key = table.remove(order, 1)
      lookup[evict_key] = nil
      n = n - 1
    end
    n = n + 1
    order[n] = key
    lookup[key] = value
  end

  --- Clear all entries.
  function cache:clear()
    for k in pairs(lookup) do lookup[k] = nil end
    for i = 1, n do order[i] = nil end
    n = 0
  end

  --- Current number of entries.
  function cache:size()
    return n
  end

  --- Invalidate a specific key.
  function cache:remove(key)
    if lookup[key] == nil then return end
    lookup[key] = nil
    for i = 1, n do
      if order[i] == key then
        table.remove(order, i)
        n = n - 1
        break
      end
    end
  end

  --- Iterate all entries (for dependency scans).
  --- Returns iterator yielding (key, value) pairs.
  function cache:entries()
    local i = 0
    return function()
      i = i + 1
      if i > n then return nil end
      local key = order[i]
      return key, lookup[key]
    end
  end

  return cache
end

-- ---------------------------------------------------------------------------
-- Memory-weighted LRU cache (doubly-linked list for O(1) promote/evict)
-- ---------------------------------------------------------------------------

--- @class WeightedCacheEntry
--- @field value any
--- @field weight number byte weight of this entry
--- @field key any
--- @field prev WeightedCacheEntry|nil
--- @field next WeightedCacheEntry|nil

local WeightedCache = {}
WeightedCache.__index = WeightedCache

--- Create a memory-weighted LRU cache.
--- Evicts least-recently-used entries when total weight exceeds max_bytes
--- or item count exceeds max_items.
---@param opts { max_bytes: number, weigher: fun(key: any, value: any): number, max_items?: number }
---@return table cache instance with :get(), :put(), :clear(), :size(), :remove(), :entries(), :stats()
function M.new_weighted(opts)
  assert(opts.max_bytes, "new_weighted requires max_bytes")
  assert(opts.weigher, "new_weighted requires weigher function")
  return setmetatable({
    _entries = {},
    _head = nil,        -- LRU end (evict from here)
    _tail = nil,        -- MRU end (insert/promote here)
    _size = 0,
    _total_weight = 0,
    _max_items = opts.max_items or math.huge,
    _max_bytes = opts.max_bytes,
    _weigher = opts.weigher,
    _on_evict = opts.on_evict,
  }, WeightedCache)
end

--- Get a cached value. Returns nil on miss.
--- Promotes key to most-recently-used on hit.
function WeightedCache:get(key)
  local entry = self._entries[key]
  if not entry then return nil end
  self:_unlink(entry)
  self:_link_at_tail(entry)
  return entry.value
end

--- Insert or update a cache entry.
--- Evicts least-recently-used entries until within budget.
function WeightedCache:put(key, value)
  local weight = self._weigher(key, value)

  -- Remove existing entry if present
  if self._entries[key] then
    self:remove(key)
  end

  -- Evict until within budget
  while self._head and (
    self._total_weight + weight > self._max_bytes or
    self._size >= self._max_items
  ) do
    self:_evict_lru()
  end

  -- Insert new entry at MRU position
  local entry = { value = value, weight = weight, key = key }
  self:_link_at_tail(entry)
  self._entries[key] = entry
  self._size = self._size + 1
  self._total_weight = self._total_weight + weight
end

--- Invalidate a specific key.
function WeightedCache:remove(key)
  local entry = self._entries[key]
  if not entry then return end
  if self._on_evict then self._on_evict(entry.key, entry.value) end
  self:_unlink(entry)
  self._entries[key] = nil
  self._size = self._size - 1
  self._total_weight = self._total_weight - entry.weight
end

--- Clear all entries.
function WeightedCache:clear()
  if self._on_evict then
    local node = self._head
    while node do
      self._on_evict(node.key, node.value)
      node = node.next
    end
  end
  self._entries = {}
  self._head = nil
  self._tail = nil
  self._size = 0
  self._total_weight = 0
end

--- Current number of entries.
function WeightedCache:size()
  return self._size
end

--- Iterate all entries (oldest first).
--- Returns iterator yielding (key, value) pairs.
function WeightedCache:entries()
  local node = self._head
  return function()
    if not node then return nil end
    local key, value = node.key, node.value
    node = node.next
    return key, value
  end
end

--- Return memory utilization statistics.
---@return { items: number, total_bytes: number, max_bytes: number, max_items: number|nil, utilization: number }
function WeightedCache:stats()
  return {
    items = self._size,
    total_bytes = self._total_weight,
    max_bytes = self._max_bytes,
    max_items = self._max_items ~= math.huge and self._max_items or nil,
    utilization = self._max_bytes > 0 and (self._total_weight / self._max_bytes) or 0,
  }
end

--- Evict the least-recently-used entry (head of list).
function WeightedCache:_evict_lru()
  local victim = self._head
  if not victim then return end
  if self._on_evict then self._on_evict(victim.key, victim.value) end
  self:_unlink(victim)
  self._entries[victim.key] = nil
  self._size = self._size - 1
  self._total_weight = self._total_weight - victim.weight
end

--- Append entry at MRU end (tail).
function WeightedCache:_link_at_tail(entry)
  entry.prev = self._tail
  entry.next = nil
  if self._tail then self._tail.next = entry end
  self._tail = entry
  if not self._head then self._head = entry end
end

--- Remove entry from doubly-linked list.
function WeightedCache:_unlink(entry)
  if entry.prev then entry.prev.next = entry.next else self._head = entry.next end
  if entry.next then entry.next.prev = entry.prev else self._tail = entry.prev end
  entry.prev = nil
  entry.next = nil
end

return M
