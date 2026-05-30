--- Reusable monotonic operation counter for async staleness detection.
--- Replaces ad-hoc per-module generation counters with a shared primitive.
---
--- Usage:
---   local tracker = require("andrew.vault.operation_tracker")
---   local ops = tracker.new()
---   local op_id = ops:start()           -- begin new operation
---   -- ... async work ...
---   if ops:is_stale(op_id) then return end  -- discard stale results
local config = require("andrew.vault.config")

local M = {}
M.__index = M

--- Create a new operation tracker.
---@param opts? { stats_enabled?: boolean }
---@return table
function M.new(opts)
  opts = opts or {}
  local stats_enabled = opts.stats_enabled
  if stats_enabled == nil then
    local cfg = config.operation_tracker
    stats_enabled = cfg and cfg.stats_enabled or false
  end
  return setmetatable({
    _counter = 0,
    _stats_enabled = stats_enabled,
    _stats = {
      started = 0,
      completed = 0,
      discarded = 0,
    },
  }, M)
end

--- Start a new operation, invalidating all previous ones.
---@return number op_id  The operation ID for this operation
function M:start()
  -- Guard against overflow (practically impossible: 2^53 at 1000 ops/s = 285M years)
  if self._counter >= 9007199254740992 then
    self._counter = 0
  end

  self._counter = self._counter + 1

  if self._stats_enabled then
    self._stats.started = self._stats.started + 1
  end

  return self._counter
end

--- Check if an operation is still current (not superseded).
---@param operation_id number
---@return boolean
function M:is_current(operation_id)
  return operation_id == self._counter
end

--- Check if an operation has been superseded by a newer one.
---@param operation_id number
---@return boolean
function M:is_stale(operation_id)
  local stale = operation_id < self._counter
  if stale and self._stats_enabled then
    self._stats.discarded = self._stats.discarded + 1
  end
  return stale
end

--- Mark an operation as completed and return whether it's still current.
---@param operation_id number
---@return boolean is_current  true if this operation is still the latest
function M:complete(operation_id)
  if self._stats_enabled then
    self._stats.completed = self._stats.completed + 1
  end
  return self:is_current(operation_id)
end

--- Return the current counter value.
---@return number
function M:current()
  return self._counter
end

--- Return a copy of the stats table.
---@return { started: number, completed: number, discarded: number }
function M:stats()
  return {
    started = self._stats.started,
    completed = self._stats.completed,
    discarded = self._stats.discarded,
  }
end

--- Reset counter and stats to zero.
function M:reset()
  self._counter = 0
  self._stats.started = 0
  self._stats.completed = 0
  self._stats.discarded = 0
end

--- Convenience wrapper: start an operation and return a staleness-guarded callback.
---@param fn fun(op_id: number, ...: any): any  Function to call if not stale
---@return fun(...: any): any|nil callback  Wrapped function (returns nil, "stale" if superseded)
---@return number op_id  The operation ID
function M:wrap(fn)
  local op_id = self:start()
  return function(...)
    if self:is_stale(op_id) then
      return nil, "stale"
    end
    return fn(op_id, ...)
  end, op_id
end

return M
