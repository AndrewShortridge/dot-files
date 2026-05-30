--- Prioritized work scheduling for async vault operations.
--- Routes work items through priority levels to ensure user-visible
--- operations complete before background maintenance.
---
--- Priority levels:
---   CRITICAL (0) -- synchronous, immediate execution
---   NORMAL   (1) -- vim.schedule, next tick
---   DEFERRED (2) -- configurable delay (200-500ms)
---   IDLE     (3) -- CursorHold autocmd
---
--- Integrates with existing vault patterns:
---   - operation_tracker: staleness checking at dequeue time
---   - request_coalescer: deduplication before enqueue
---   - watch_channel: coalescing feeds into scheduler
---   - cleanup.debounce: burst protection before scheduler

local config = require("andrew.vault.config")
local log = require("andrew.vault.vault_log").scope("scheduler")

local M = {}

--- Priority level constants.
M.CRITICAL = 0
M.NORMAL   = 1
M.DEFERRED = 2
M.IDLE     = 3

--- @class WorkItem
--- @field fn function The work to execute
--- @field priority number Priority level (0-3)
--- @field operation_id number|nil For staleness checking
--- @field domain string|nil Logical grouping (e.g., "embed", "highlight")
--- @field label string|nil Human-readable description for debugging
--- @field _is_stale (fun(id: number): boolean)|nil Staleness checker from operation_tracker

--- @type WorkItem[][] One array per priority level (NORMAL=1, DEFERRED=2, IDLE=3)
local _queues = { {}, {}, {} }

--- @type uv.uv_timer_t|nil Timer for DEFERRED processing
local _deferred_timer = nil

--- @type number|nil Autocmd ID for IDLE processing
local _idle_autocmd = nil

--- @type boolean Whether the scheduler is actively draining
local _draining = false

--- @type { enqueued: number, executed: number, cancelled: number, by_priority: number[] }
local _stats = {
  enqueued = 0,
  executed = 0,
  cancelled = 0,
  by_priority = { 0, 0, 0, 0 },
}

--- Check whether a work item should still execute.
--- Items with an operation_id are checked against their staleness checker.
--- @param item WorkItem
--- @return boolean
local function should_execute(item)
  if not item.operation_id then return true end
  if item._is_stale and item._is_stale(item.operation_id) then
    _stats.cancelled = _stats.cancelled + 1
    return false
  end
  return true
end

--- Execute a single work item with error handling.
--- @param item WorkItem
local function execute(item)
  if not should_execute(item) then return end
  local ok, err = pcall(item.fn)
  if not ok then
    log.error("work item failed [%s/%s]: %s",
      item.domain or "unknown", item.label or "?", err)
  end
  _stats.executed = _stats.executed + 1
  _stats.by_priority[item.priority + 1] = (_stats.by_priority[item.priority + 1] or 0) + 1
end

--- Drain work queues in priority order.
--- Called from vim.schedule (NORMAL trigger) or deferred timer.
function M._drain()
  if _draining then return end
  _draining = true

  -- Phase 1: Drain all NORMAL items
  local normal_queue = _queues[1]
  while #normal_queue > 0 do
    local item = table.remove(normal_queue, 1)
    execute(item)
  end

  -- Phase 2: Process at least 1 DEFERRED item (starvation prevention)
  local deferred_queue = _queues[2]
  if #deferred_queue > 0 then
    local item = table.remove(deferred_queue, 1)
    execute(item)
  end

  _draining = false
end

--- Ensure the deferred timer is running.
--- Uses one-shot timer; cleaned up after all DEFERRED items are processed.
function M._ensure_deferred_timer()
  if _deferred_timer then return end

  local delay = config.scheduler.deferred_delay_ms

  _deferred_timer = vim.uv.new_timer()
  if not _deferred_timer then return end

  _deferred_timer:start(delay, 0, vim.schedule_wrap(function()
    -- Process all pending DEFERRED items
    local queue = _queues[2]
    while #queue > 0 do
      local item = table.remove(queue, 1)
      execute(item)
    end

    -- Clean up timer
    if _deferred_timer then
      _deferred_timer:stop()
      _deferred_timer:close()
      _deferred_timer = nil
    end
  end))
end

--- Enqueue a work item at a given priority.
--- @param priority number M.CRITICAL, M.NORMAL, M.DEFERRED, or M.IDLE
--- @param fn function The work to execute
--- @param opts? { operation_id: number, domain: string, label: string, _is_stale: fun(id: number): boolean }
function M.schedule(priority, fn, opts)
  opts = opts or {}

  -- CRITICAL: execute immediately, no queuing
  if priority == M.CRITICAL then
    _stats.enqueued = _stats.enqueued + 1
    _stats.executed = _stats.executed + 1
    _stats.by_priority[1] = _stats.by_priority[1] + 1
    local ok, err = pcall(fn)
    if not ok then
      log.error("CRITICAL work item failed [%s/%s]: %s",
        opts.domain or "unknown", opts.label or "?", err)
    end
    return
  end

  local item = {
    fn = fn,
    priority = priority,
    operation_id = opts.operation_id,
    domain = opts.domain,
    label = opts.label,
    _is_stale = opts._is_stale,
  }

  -- Queue index: NORMAL=1, DEFERRED=2, IDLE=3
  local queue_idx = priority
  _queues[queue_idx][#_queues[queue_idx] + 1] = item
  _stats.enqueued = _stats.enqueued + 1

  -- Trigger appropriate scheduling mechanism
  if priority == M.NORMAL and not _draining then
    vim.schedule(function() M._drain() end)
  elseif priority == M.DEFERRED then
    M._ensure_deferred_timer()
  end
  -- IDLE items wait for CursorHold (setup in M.setup())
end

--- Cancel all pending work items for a domain.
--- Useful when a new operation supersedes all previous work in that domain
--- (e.g., new buffer entered, all previous buffer's deferred work is stale).
--- @param domain string The domain to cancel
--- @return number count Number of items cancelled
function M.cancel_domain(domain)
  local count = 0
  for _, queue in ipairs(_queues) do
    for i = #queue, 1, -1 do
      if queue[i].domain == domain then
        table.remove(queue, i)
        count = count + 1
        _stats.cancelled = _stats.cancelled + 1
      end
    end
  end
  if count > 0 then
    log.debug("cancelled %d items for domain '%s'", count, domain)
  end
  return count
end

--- Cancel all pending work across all domains.
--- Used during vault shutdown or vault path switch.
function M.cancel_all()
  local total = 0
  for i, queue in ipairs(_queues) do
    total = total + #queue
    _queues[i] = {}
  end
  _stats.cancelled = _stats.cancelled + total

  if _deferred_timer then
    _deferred_timer:stop()
    _deferred_timer:close()
    _deferred_timer = nil
  end

  if total > 0 then
    log.debug("cancelled all pending work (%d items)", total)
  end
end

--- Drain IDLE queue items up to a configurable limit.
--- Called by CursorHold autocmd and FocusLost handler (cache_warming).
--- @param max_items? number  Override for max items (defaults to config.scheduler.max_idle_per_hold)
--- @return number processed  Number of items executed
function M.drain_idle(max_items)
  local queue = _queues[3]
  local limit = max_items or config.scheduler.max_idle_per_hold
  local processed = 0

  while #queue > 0 and processed < limit do
    local item = table.remove(queue, 1)
    execute(item)
    processed = processed + 1
  end
  return processed
end

--- Setup the CursorHold autocmd for IDLE priority processing.
--- Called once during vault init.
function M.setup()
  if _idle_autocmd then return end

  _idle_autocmd = vim.api.nvim_create_autocmd("CursorHold", {
    group = vim.api.nvim_create_augroup("VaultWorkScheduler", { clear = true }),
    callback = function()
      M.drain_idle()
    end,
  })
end

--- Teardown: cancel all work and remove autocmd.
function M.teardown()
  M.cancel_all()
  if _idle_autocmd then
    vim.api.nvim_del_autocmd(_idle_autocmd)
    _idle_autocmd = nil
  end
end

--- Get scheduler statistics.
--- @return table
function M.stats()
  local pending = 0
  for _, queue in ipairs(_queues) do
    pending = pending + #queue
  end
  return {
    enqueued = _stats.enqueued,
    executed = _stats.executed,
    cancelled = _stats.cancelled,
    pending = pending,
    pending_normal = #_queues[1],
    pending_deferred = #_queues[2],
    pending_idle = #_queues[3],
    by_priority = vim.deepcopy(_stats.by_priority),
  }
end

--- Reset stats (for testing).
function M.reset_stats()
  _stats = { enqueued = 0, executed = 0, cancelled = 0, by_priority = { 0, 0, 0, 0 } }
end

return M
