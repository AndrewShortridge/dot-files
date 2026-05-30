--- Request coalescer: deduplicates concurrent identical operations.
--- Multiple callers requesting the same operation join a single in-flight
--- execution and all receive the result when it completes.
---
--- Usage: create a pool via M.new(opts), then call pool:request(key, op, cb).
--- request() returns a CoalescerHandle with cancel() for per-subscriber cancellation.
--- Each pool has independent state, configuration, and statistics.
--- Late-arrival safety via done_linger_ms keeps resolved entries briefly.
--- Module API: M.new(), M.pools(), M.configure(), M._reset().
--- Complements event_coalescer.lua (event-level batching) by operating at
--- the operation level. Used by url_validate, embed, search_filter, connections, etc.

local M = {}
local scope = require("andrew.vault.vault_log").scope("request_coalescer")
local cleanup = require("andrew.vault.resource_cleanup")

-- ---------------------------------------------------------------------------
-- Pool class (metatable-based)
-- ---------------------------------------------------------------------------

---@class CoalescerPool
---@field _in_flight table<string, CoalescerEntry>
---@field _stats CoalescerStats
---@field _config CoalescerPoolConfig
---@field name string

---@class CoalescerEntry
---@field waiters table<integer, {cb: fun(result: any, err: string|nil), cancelled: boolean, id: integer}>
---@field timer userdata|nil
---@field done boolean
---@field result any
---@field err string|nil
---@field done_timer userdata|nil  -- cleanup timer for late-arrival window
---@field next_waiter_id integer  -- monotonic waiter ID counter

---@class CoalescerHandle
---@field cancel fun(): boolean  Cancel this subscriber; auto-cancels operation if last one

---@class CoalescerStats
---@field total_operations integer
---@field total_coalesced integer
---@field total_cancelled integer

---@class CoalescerPoolConfig
---@field max_waiters integer
---@field timeout_ms integer
---@field done_linger_ms integer  -- how long resolved entries remain for late arrivals

local Pool = {}
Pool.__index = Pool

--- Create a new coalescer pool with independent state and configuration.
---@param opts? {max_waiters?: integer, timeout_ms?: integer, done_linger_ms?: integer, name?: string}
---@return CoalescerPool
function Pool.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Pool)
  self._in_flight = {}
  self._stats = { total_operations = 0, total_coalesced = 0, total_cancelled = 0 }
  self._config = {
    max_waiters = opts.max_waiters or 50,
    timeout_ms = opts.timeout_ms or 30000,
    done_linger_ms = opts.done_linger_ms or 100,
  }
  self.name = opts.name or "default"
  return self
end

--- Configure this pool.
---@param opts table { max_waiters?, timeout_ms?, done_linger_ms? }
function Pool:configure(opts)
  if opts then
    for k, v in pairs(opts) do
      if k == "name" then
        self.name = v
      elseif self._config[k] ~= nil then
        self._config[k] = v
      end
    end
  end
end

--- Count active (non-cancelled) waiters in an entry.
---@param entry CoalescerEntry
---@return integer
local function active_waiter_count(entry)
  local n = 0
  for i = 1, #entry.waiters do
    if entry.waiters[i] and not entry.waiters[i].cancelled then
      n = n + 1
    end
  end
  return n
end

--- Build a cancellation handle for a single subscriber.
--- When cancelled, marks the waiter as cancelled. If no active waiters remain,
--- auto-cancels the entire operation.
---@param pool CoalescerPool
---@param key string
---@param entry CoalescerEntry
---@param waiter_id integer
---@return CoalescerHandle
local function make_handle(pool, key, entry, waiter_id)
  local cancelled = false
  return {
    cancel = function()
      if cancelled then return false end
      cancelled = true
      -- Find and mark this waiter as cancelled
      for i = 1, #entry.waiters do
        local w = entry.waiters[i]
        if w and w.id == waiter_id and not w.cancelled then
          w.cancelled = true
          -- If no active waiters remain and operation isn't done, auto-cancel
          if not entry.done and active_waiter_count(entry) == 0 then
            scope.debug("[%s] last subscriber cancelled, auto-cancelling key: %s", pool.name, key)
            pool:cancel(key)
          end
          return true
        end
      end
      return false
    end,
  }
end

--- Noop handle returned for late arrivals and error paths.
local noop_handle = { cancel = function() return false end }

--- Request an operation, deduplicating with any identical in-flight request.
--- If the same key is already in-flight, the callback joins the existing operation.
--- If the key just resolved (within done_linger_ms), delivers the cached result.
--- Returns a handle with cancel() to unsubscribe this individual caller.
---@param key string Unique key identifying this operation
---@param operation_fn fun(resolve: fun(result: any), reject: fun(err: string))
---@param callback fun(result: any, err: string|nil)
---@return CoalescerHandle handle Cancellation handle for this subscriber
function Pool:request(key, operation_fn, callback)
  local entry = self._in_flight[key]

  if entry then
    -- Late arrival: result already available, deliver immediately
    if entry.done then
      scope.debug("[%s] late arrival for key: %s", self.name, key)
      self._stats.total_coalesced = self._stats.total_coalesced + 1
      vim.schedule(function() callback(entry.result, entry.err) end)
      return noop_handle
    end

    -- Identical operation already in-flight: join it
    local active = active_waiter_count(entry)
    if active >= self._config.max_waiters then
      scope.warn("[%s] max waiters reached for key: %s", self.name, key)
      callback(nil, "max waiters exceeded")
      return noop_handle
    end
    local waiter_id = entry.next_waiter_id
    entry.next_waiter_id = waiter_id + 1
    entry.waiters[#entry.waiters + 1] = { cb = callback, id = waiter_id, cancelled = false }
    scope.debug("[%s] coalesced request for key: %s (waiters: %d)", self.name, key, active + 1)
    self._stats.total_coalesced = self._stats.total_coalesced + 1
    return make_handle(self, key, entry, waiter_id)
  end

  -- No in-flight operation: start new one
  local waiter_id = 1
  entry = {
    waiters = { { cb = callback, id = waiter_id, cancelled = false } },
    next_waiter_id = waiter_id + 1,
    timer = nil,
    done = false,
    result = nil,
    err = nil,
    done_timer = nil,
  }
  self._in_flight[key] = entry

  -- Set up timeout
  local timeout_ms = self._config.timeout_ms
  if timeout_ms > 0 then
    entry.timer = vim.uv.new_timer()
    if entry.timer then
      local pool = self
      entry.timer:start(timeout_ms, 0, vim.schedule_wrap(function()
        scope.warn("[%s] operation timed out for key: %s", pool.name, key)
        pool:_resolve_entry(key, nil, "timeout")
      end))
    end
  end

  scope.debug("[%s] started new operation for key: %s", self.name, key)

  -- Resolve/reject callbacks for the operation
  local pool = self
  local function resolve(result)
    vim.schedule(function()
      pool:_resolve_entry(key, result, nil)
    end)
  end

  local function reject(err)
    vim.schedule(function()
      pool:_resolve_entry(key, nil, err)
    end)
  end

  -- Build handle before starting (entry is already stored in _in_flight)
  local handle = make_handle(self, key, entry, waiter_id)

  -- Start the operation
  local ok, run_err = pcall(operation_fn, resolve, reject)
  if not ok then
    scope.error("[%s] operation_fn threw for key %s: %s", self.name, key, run_err)
    self:_resolve_entry(key, nil, run_err)
  end

  return handle
end

--- Resolve an in-flight entry: notify all waiters, clean up.
---@param key string
---@param result any
---@param err string|nil
function Pool:_resolve_entry(key, result, err)
  local entry = self._in_flight[key]
  if not entry then return end -- Already resolved
  if entry.done then return end -- Already in linger phase

  -- Clean up timeout timer
  if entry.timer then
    cleanup.close_timer(entry.timer)
    entry.timer = nil
  end

  -- Mark done and store result for late arrivals
  entry.done = true
  entry.result = result
  entry.err = err

  -- Notify all active (non-cancelled) waiters
  local total = #entry.waiters
  local notified = 0
  for i = 1, total do
    local w = entry.waiters[i]
    if w and not w.cancelled then
      notified = notified + 1
      local ok_cb, cb_err = pcall(w.cb, result, err)
      if not ok_cb then
        scope.error("[%s] waiter callback error for key %s: %s", self.name, key, cb_err)
      end
    end
    entry.waiters[i] = nil -- Allow GC
  end
  entry.resolved_waiter_count = notified

  if err then
    scope.debug("[%s] resolved key: %s with error (%d waiters): %s", self.name, key, notified, err)
  else
    scope.debug("[%s] resolved key: %s successfully (%d waiters)", self.name, key, notified)
  end

  -- Update stats
  self._stats.total_operations = self._stats.total_operations + 1

  -- Keep entry in done state for late arrivals, then remove
  local linger_ms = self._config.done_linger_ms
  if linger_ms > 0 then
    entry.done_timer = vim.uv.new_timer()
    if entry.done_timer then
      local pool = self
      entry.done_timer:start(linger_ms, 0, vim.schedule_wrap(function()
        local e = pool._in_flight[key]
        if e and e.done then
          if e.done_timer then
            cleanup.close_timer(e.done_timer)
          end
          pool._in_flight[key] = nil
        end
      end))
    else
      self._in_flight[key] = nil
    end
  else
    self._in_flight[key] = nil
  end
end

--- Resolve an in-flight entry synchronously (without vim.schedule wrapper).
--- Use when the caller is already on the main thread and needs the entry
--- removed before returning (e.g., synchronous render completion).
---@param key string
---@param result any
---@param err string|nil
function Pool:resolve_now(key, result, err)
  self:_resolve_entry(key, result, err)
end

--- Cancel an in-flight operation, notifying all waiters with "cancelled" error.
---@param key string
---@return boolean
function Pool:cancel(key)
  local entry = self._in_flight[key]
  if not entry then return false end
  if entry.done then
    -- Already resolved, just clean up the linger entry
    if entry.done_timer then
      cleanup.close_timer(entry.done_timer)
    end
    self._in_flight[key] = nil
    return false
  end
  scope.debug("[%s] cancelling key: %s (%d waiters)", self.name, key, #entry.waiters)
  self:_resolve_entry(key, nil, "cancelled")
  self._stats.total_cancelled = self._stats.total_cancelled + 1
  return true
end

--- Check if an operation is currently in-flight (not yet resolved).
---@param key string
---@return boolean
function Pool:is_pending(key)
  local entry = self._in_flight[key]
  return entry ~= nil and not entry.done
end

--- Count currently in-flight (not yet resolved) operations.
---@return integer
function Pool:pending_count()
  local n = 0
  for _, entry in pairs(self._in_flight) do
    if not entry.done then n = n + 1 end
  end
  return n
end

--- Get all currently in-flight keys (for debugging).
---@return string[]
function Pool:pending_keys()
  local keys = {}
  for k, entry in pairs(self._in_flight) do
    local state = entry.done and "done/linger" or "in-flight"
    if entry.done then
      local count = entry.resolved_waiter_count or 0
      keys[#keys + 1] = string.format("%s (%d waiters, %s)", k, count, state)
    else
      local active = active_waiter_count(entry)
      local total = #entry.waiters
      if active == total then
        keys[#keys + 1] = string.format("%s (%d waiters, %s)", k, active, state)
      else
        keys[#keys + 1] = string.format("%s (%d/%d active waiters, %s)", k, active, total, state)
      end
    end
  end
  return keys
end

--- Get coalescing statistics.
---@return table
function Pool:stats()
  local in_flight = 0
  for _, entry in pairs(self._in_flight) do
    if not entry.done then in_flight = in_flight + 1 end
  end
  local total_requests = self._stats.total_operations + self._stats.total_coalesced
  return {
    total_operations = self._stats.total_operations,
    total_coalesced = self._stats.total_coalesced,
    total_cancelled = self._stats.total_cancelled,
    in_flight = in_flight,
    coalesce_rate = total_requests > 0
      and (self._stats.total_coalesced / total_requests * 100)
      or 0,
  }
end

--- Reset all state (for testing).
function Pool:_reset()
  for _, entry in pairs(self._in_flight) do
    if entry.timer then cleanup.close_timer(entry.timer) end
    if entry.done_timer then cleanup.close_timer(entry.done_timer) end
  end
  self._in_flight = {}
  self._stats = { total_operations = 0, total_coalesced = 0, total_cancelled = 0 }
end

-- ---------------------------------------------------------------------------
-- Pool registry (for debug introspection)
-- ---------------------------------------------------------------------------

local _pools = {}
local _pool_configs = {} -- Stored pool configs from configure(), applied to late-registered pools

--- Create a new independent coalescer pool.
--- If configure() was already called with opts for this pool name, applies them.
---@param opts? {max_waiters?: integer, timeout_ms?: integer, done_linger_ms?: integer, name?: string}
---@return CoalescerPool
function M.new(opts)
  local pool = Pool.new(opts)
  _pools[pool.name] = pool
  -- Apply stored config for late-registered pools (loaded after configure())
  if _pool_configs[pool.name] then
    pool:configure(_pool_configs[pool.name])
  end
  return pool
end

--- Get all registered pools (for debug commands).
---@return table<string, CoalescerPool>
function M.pools()
  return _pools
end

--- Reset all pools (for testing).
function M._reset()
  for _, pool in pairs(_pools) do
    pool:_reset()
  end
  _pool_configs = {}
end

--- Configure named pools.
--- Pool configs are stored so late-registered pools (loaded after configure()) also receive them.
---@param opts table { pools?: table<string, table> }
function M.configure(opts)
  if not opts then return end
  if opts.pools then
    for name, pool_opts in pairs(opts.pools) do
      _pool_configs[name] = pool_opts
      if _pools[name] then
        _pools[name]:configure(pool_opts)
      end
    end
  end
end

return M
