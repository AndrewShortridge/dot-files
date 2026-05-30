--- Per-render arena allocation for scope-aligned ephemeral tables.
--- Tables are drawn from a pre-allocated pool during a scope and all
--- returned to the pool in one bulk operation when the scope ends.
--- Complements table_pool.lua (which handles explicit acquire/release).

local M = {}

-- ---------------------------------------------------------------------------
-- Configuration (overridden by config.arena at require-time)
-- ---------------------------------------------------------------------------
M._config = {
  initial_pool_size = 200,
  max_pool_size = 2000,
  debug_validation = false,
}

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------

--- Pre-allocated pool of empty tables (stack).
local _pool = {}
local _pool_size = 0

--- Active scopes: scope_id → { tables = {}, count = 0, valid = true }
local _scopes = {}
local _next_scope_id = 0

-- ---------------------------------------------------------------------------
-- Stats
-- ---------------------------------------------------------------------------
M._stats = {
  total_scopes = 0,
  active_scopes = 0,
  peak_scope_size = 0,
  pool_hits = 0,
  pool_misses = 0,
  tables_cleared = 0,
  overflow_discards = 0,
}

-- ---------------------------------------------------------------------------
-- LuaJIT table.new detection
-- ---------------------------------------------------------------------------
local has_table_new, table_new = pcall(require, "table.new")

-- ---------------------------------------------------------------------------
-- Debug proxy (use-after-free detection)
-- ---------------------------------------------------------------------------

--- Returns a metatable proxy that errors on access after scope invalidation.
--- Only used when config.arena.debug_validation = true.
--- @param scope_id integer
--- @param tbl table The real backing table
--- @param scope table The scope record (for validity check)
--- @return table proxy
local function make_debug_proxy(scope_id, tbl, scope)
  return setmetatable({}, {
    __index = function(_, k)
      if not scope.valid then
        error(string.format(
          "render_arena: use-after-free on scope %d, key '%s'",
          scope_id, tostring(k)
        ), 2)
      end
      return tbl[k]
    end,
    __newindex = function(_, k, v)
      if not scope.valid then
        error(string.format(
          "render_arena: write-after-free on scope %d, key '%s'",
          scope_id, tostring(k)
        ), 2)
      end
      tbl[k] = v
    end,
    __pairs = function()
      if not scope.valid then
        error("render_arena: iterate-after-free on scope " .. scope_id, 2)
      end
      return pairs(tbl)
    end,
    __ipairs = function()
      if not scope.valid then
        error("render_arena: iterate-after-free on scope " .. scope_id, 2)
      end
      return ipairs(tbl)
    end,
    __len = function()
      if not scope.valid then
        error("render_arena: len-after-free on scope " .. scope_id, 2)
      end
      return #tbl
    end,
    -- Store the real table for end_scope clearing
    _arena_real = tbl,
  })
end

-- ---------------------------------------------------------------------------
-- Core API
-- ---------------------------------------------------------------------------

--- Pre-populate the pool with empty tables.
--- Called once at module load and can be called to grow the pool.
--- @param count integer Number of tables to pre-allocate
function M.warm(count)
  local max = M._config.max_pool_size
  for _ = 1, count do
    if _pool_size >= max then break end
    _pool_size = _pool_size + 1
    _pool[_pool_size] = {}
  end
end

--- Begin a new allocation scope.
--- All tables allocated within this scope share its lifetime.
--- @return integer scope_id Handle for this scope
function M.begin_scope()
  _next_scope_id = _next_scope_id + 1
  local id = _next_scope_id
  _scopes[id] = {
    tables = {},
    count = 0,
    valid = true,
  }
  M._stats.total_scopes = M._stats.total_scopes + 1
  M._stats.active_scopes = M._stats.active_scopes + 1
  return id
end

--- Allocate a table from the arena within a scope.
--- Returns a pre-allocated empty table (no GC allocation when pool has stock).
--- @param scope_id integer Scope handle from begin_scope()
--- @return table tbl Empty table ready for use
function M.alloc_table(scope_id)
  local scope = _scopes[scope_id]
  if not scope or not scope.valid then
    error("render_arena: alloc on invalid/ended scope " .. tostring(scope_id), 2)
  end

  local tbl
  if _pool_size > 0 then
    tbl = _pool[_pool_size]
    _pool[_pool_size] = nil
    _pool_size = _pool_size - 1
    M._stats.pool_hits = M._stats.pool_hits + 1
  else
    tbl = {}
    M._stats.pool_misses = M._stats.pool_misses + 1
  end

  scope.count = scope.count + 1
  scope.tables[scope.count] = tbl

  if scope.count > M._stats.peak_scope_size then
    M._stats.peak_scope_size = scope.count
  end

  if M._config.debug_validation then
    return make_debug_proxy(scope_id, tbl, scope)
  end

  return tbl
end

--- Allocate a table and pre-size it as an array (LuaJIT optimization).
--- In PUC Lua, this is equivalent to alloc_table (capacity hint ignored).
--- @param scope_id integer Scope handle
--- @param capacity integer Expected number of array elements
--- @return table tbl Empty table
function M.alloc_array(scope_id, capacity)
  if has_table_new and capacity > 0 then
    local scope = _scopes[scope_id]
    if not scope or not scope.valid then
      error("render_arena: alloc on invalid/ended scope " .. tostring(scope_id), 2)
    end
    -- LuaJIT: create with pre-sized array portion (bypasses pool)
    local tbl = table_new(capacity, 0)
    scope.count = scope.count + 1
    scope.tables[scope.count] = tbl
    M._stats.pool_misses = M._stats.pool_misses + 1
    if scope.count > M._stats.peak_scope_size then
      M._stats.peak_scope_size = scope.count
    end
    if M._config.debug_validation then
      return make_debug_proxy(scope_id, tbl, scope)
    end
    return tbl
  end
  return M.alloc_table(scope_id)
end

--- End a scope, returning ALL allocated tables to the pool.
--- After this call, tables from this scope must not be accessed.
--- @param scope_id integer Scope handle from begin_scope()
function M.end_scope(scope_id)
  local scope = _scopes[scope_id]
  if not scope then return end

  scope.valid = false
  M._stats.active_scopes = M._stats.active_scopes - 1

  local max_pool = M._config.max_pool_size
  local debug = M._config.debug_validation

  for i = 1, scope.count do
    local tbl = scope.tables[i]
    -- If debug proxy, get the real table
    if debug then
      local mt = getmetatable(tbl)
      if mt and mt._arena_real then
        tbl = mt._arena_real
      end
    end
    -- Clear all keys (both hash and array part)
    for k in pairs(tbl) do
      tbl[k] = nil
    end
    M._stats.tables_cleared = M._stats.tables_cleared + 1
    -- Return to pool if room
    if _pool_size < max_pool then
      _pool_size = _pool_size + 1
      _pool[_pool_size] = tbl
    else
      M._stats.overflow_discards = M._stats.overflow_discards + 1
    end
    scope.tables[i] = nil
  end

  _scopes[scope_id] = nil
end

--- Check whether a scope is still valid (not ended).
--- @param scope_id integer Scope handle
--- @return boolean
function M.is_valid(scope_id)
  local scope = _scopes[scope_id]
  return scope ~= nil and scope.valid
end

--- Return a copy of the current stats.
--- @return table stats
function M.stats()
  return {
    pool_size = _pool_size,
    max_pool_size = M._config.max_pool_size,
    total_scopes = M._stats.total_scopes,
    active_scopes = M._stats.active_scopes,
    peak_scope_size = M._stats.peak_scope_size,
    pool_hits = M._stats.pool_hits,
    pool_misses = M._stats.pool_misses,
    tables_cleared = M._stats.tables_cleared,
    overflow_discards = M._stats.overflow_discards,
  }
end

--- Apply configuration from config.arena.
--- @param cfg table { initial_pool_size, max_pool_size, debug_validation }
function M.configure(cfg)
  if not cfg then return end
  if cfg.initial_pool_size then M._config.initial_pool_size = cfg.initial_pool_size end
  if cfg.max_pool_size then M._config.max_pool_size = cfg.max_pool_size end
  if cfg.debug_validation ~= nil then M._config.debug_validation = cfg.debug_validation end
end

--- Reset all state (for testing).
function M.reset()
  _pool = {}
  _pool_size = 0
  _scopes = {}
  _next_scope_id = 0
  M._stats = {
    total_scopes = 0,
    active_scopes = 0,
    peak_scope_size = 0,
    pool_hits = 0,
    pool_misses = 0,
    tables_cleared = 0,
    overflow_discards = 0,
  }
end

-- ---------------------------------------------------------------------------
-- Module init: warm the pool
-- ---------------------------------------------------------------------------
M.warm(M._config.initial_pool_size)

return M
