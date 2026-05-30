-- batch_drain.lua — Threshold-based batch accumulator with dual-threshold auto-drain.
-- Accumulates items until either a count or byte-size threshold is reached,
-- then synchronously drains the batch via a callback. Provides bounded memory
-- with predictable batch sizes and natural backpressure.
local config = require("andrew.vault.config")

local M = {}
M.__index = M

--- Create a new batch drain accumulator.
---@param opts { max_count: number|nil, max_bytes: number|nil, on_drain: fun(items: table[], stats: table) }
---@return table
function M.new(opts)
  assert(opts.on_drain, "batch_drain: on_drain callback is required")

  local self = setmetatable({
    _items = {},
    _count = 0,
    _total_bytes = 0,
    _max_count = opts.max_count or config.batch.default_max_count,
    _max_bytes = opts.max_bytes or config.batch.default_max_bytes,
    _on_drain = opts.on_drain,
    _stats = {
      pushes = 0,
      drains = 0,
      total_items = 0,
      total_bytes = 0,
    },
  }, M)
  return self
end

--- Push an item into the accumulator. Triggers drain if threshold is met.
---@param item any  The item to accumulate
---@param byte_size number|nil  Estimated byte size of this item (optional)
function M:push(item, byte_size)
  self._count = self._count + 1
  self._items[self._count] = item
  self._stats.pushes = self._stats.pushes + 1

  if byte_size then
    self._total_bytes = self._total_bytes + byte_size
  end

  -- Check thresholds: either count or bytes triggers drain
  local should_drain = self._count >= self._max_count
  if not should_drain and byte_size and self._total_bytes >= self._max_bytes then
    should_drain = true
  end

  if should_drain then
    self:_drain("threshold")
  end
end

--- Internal: execute the drain callback and reset state.
---@param reason string  Why the drain was triggered
function M:_drain(reason)
  if self._count == 0 then return end

  local items = self._items
  local stats = {
    count = self._count,
    total_bytes = self._total_bytes,
    drain_reason = reason,
  }

  -- Update cumulative stats
  self._stats.drains = self._stats.drains + 1
  self._stats.total_items = self._stats.total_items + self._count
  self._stats.total_bytes = self._stats.total_bytes + self._total_bytes

  -- Reset accumulator BEFORE calling on_drain (re-entrancy safe)
  self._items = {}
  self._count = 0
  self._total_bytes = 0

  -- Deliver batch
  self._on_drain(items, stats)
end

--- Force drain all remaining items, regardless of threshold.
function M:flush()
  self:_drain("flush")
end

--- Discard all pending items without draining.
function M:clear()
  self._items = {}
  self._count = 0
  self._total_bytes = 0
end

--- Current number of pending items.
function M:count()
  return self._count
end

--- Current accumulated byte size.
function M:bytes()
  return self._total_bytes
end

--- Whether the accumulator has no pending items.
function M:is_empty()
  return self._count == 0
end

--- Cumulative statistics.
function M:stats()
  return vim.deepcopy(self._stats)
end

return M
