-- Rate-limited domain queuing with per-domain fairness and priority scheduling.
-- Provides queue-based rate limiting: global concurrency semaphore + per-domain
-- cooldowns + priority ordering across domains.
local vault_log = require("andrew.vault.vault_log")

local M = {}
M.__index = M

local log = vault_log.scope("rate_limiter")

--- Create a new rate limiter instance.
---@param opts? { max_concurrent: integer, domain_cooldown_ms: integer, max_queue_size: integer, queue_drain_interval_ms: integer }
---@return table
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    max_concurrent = opts.max_concurrent or 5,
    domain_cooldown_ms = opts.domain_cooldown_ms or 1000,
    max_queue_size = opts.max_queue_size or 200,
    queue_drain_interval_ms = opts.queue_drain_interval_ms or 100,

    -- State
    _active_count = 0,
    _domain_queues = {},         -- domain -> {{priority, fn, queued_at}, ...}
    _domain_last_request = {},   -- domain -> hrtime of last request completion
    _drain_timer = nil,
    _total_queued = 0,
    _stats = {
      submitted = 0,
      completed = 0,
      rejected = 0,
    },
  }, M)
  return self
end

--- Submit a request for a domain. Dispatches immediately if permits/cooldown allow,
--- otherwise queues for later processing.
---@param domain string
---@param opts? { priority: integer }
---@param fn function Called with done() guard when dispatched
---@return boolean ok
---@return string status "dispatched"|"queued"|"queue_full"
function M:submit(domain, opts, fn)
  opts = opts or {}
  local priority = opts.priority or 5

  self._stats.submitted = self._stats.submitted + 1

  -- Check queue capacity
  if self._total_queued >= self.max_queue_size then
    log.warn("Queue full, rejecting request for domain: " .. domain)
    self._stats.rejected = self._stats.rejected + 1
    return false, "queue_full"
  end

  -- Try immediate dispatch
  if self:_can_dispatch(domain) then
    self:_dispatch(domain, fn)
    return true, "dispatched"
  end

  -- Queue for later
  if not self._domain_queues[domain] then
    self._domain_queues[domain] = {}
  end

  table.insert(self._domain_queues[domain], {
    priority = priority,
    fn = fn,
    queued_at = vim.uv.hrtime(),
  })
  self._total_queued = self._total_queued + 1

  -- Sort domain queue by priority (stable: equal priority preserves FIFO)
  table.sort(self._domain_queues[domain], function(a, b)
    if a.priority == b.priority then
      return a.queued_at < b.queued_at
    end
    return a.priority < b.priority
  end)

  -- Ensure drain timer is running
  self:_ensure_drain_timer()

  return true, "queued"
end

--- Check if a request can be dispatched immediately.
---@param domain string
---@return boolean
function M:_can_dispatch(domain)
  if self._active_count >= self.max_concurrent then
    return false
  end
  return self:_domain_cooled_down(domain)
end

--- Check if a domain has cooled down since its last request.
---@param domain string
---@return boolean
function M:_domain_cooled_down(domain)
  local last = self._domain_last_request[domain]
  if not last then
    return true
  end
  local elapsed_ms = (vim.uv.hrtime() - last) / 1e6
  return elapsed_ms >= self.domain_cooldown_ms
end

--- Dispatch a request immediately, acquiring a permit.
---@param domain string
---@param fn function
function M:_dispatch(domain, fn)
  self._active_count = self._active_count + 1

  local released = false
  local done = function()
    if released then
      log.warn("done() called twice for domain: " .. domain)
      return
    end
    released = true
    self._active_count = self._active_count - 1
    self._domain_last_request[domain] = vim.uv.hrtime()
    self._stats.completed = self._stats.completed + 1

    -- Trigger immediate drain attempt
    vim.schedule(function()
      self:_drain_queue()
    end)
  end

  -- Call the work function with the release guard
  local ok, err = pcall(fn, done)
  if not ok then
    log.error("Dispatch function error for " .. domain .. ": " .. tostring(err))
    if not released then
      done()
    end
  end
end

--- Ensure the drain timer is running.
function M:_ensure_drain_timer()
  if self._drain_timer then
    return
  end

  self._drain_timer = vim.uv.new_timer()
  self._drain_timer:start(
    self.queue_drain_interval_ms,
    self.queue_drain_interval_ms,
    vim.schedule_wrap(function()
      self:_drain_queue()
    end)
  )
end

--- Process queued items while permits are available and domains are cooled down.
function M:_drain_queue()
  while self._active_count < self.max_concurrent do
    local best_domain, best_entry = self:_pick_next()
    if not best_domain then
      break
    end

    -- Remove from queue
    local queue = self._domain_queues[best_domain]
    for i, entry in ipairs(queue) do
      if entry == best_entry then
        table.remove(queue, i)
        break
      end
    end
    self._total_queued = self._total_queued - 1

    -- Clean up empty queues
    if #queue == 0 then
      self._domain_queues[best_domain] = nil
    end

    self:_dispatch(best_domain, best_entry.fn)
  end

  -- Stop timer if queue is empty
  if self._total_queued == 0 and self._drain_timer then
    self._drain_timer:stop()
    self._drain_timer:close()
    self._drain_timer = nil
  end
end

--- Find the highest-priority dispatchable entry across all cooled-down domains.
---@return string|nil domain
---@return table|nil entry
function M:_pick_next()
  local best_domain = nil
  local best_entry = nil

  for domain, queue in pairs(self._domain_queues) do
    if #queue > 0 and self:_domain_cooled_down(domain) then
      local candidate = queue[1] -- Already sorted by priority
      if not best_entry or candidate.priority < best_entry.priority then
        best_domain = domain
        best_entry = candidate
      elseif candidate.priority == best_entry.priority
        and candidate.queued_at < best_entry.queued_at then
        best_domain = domain
        best_entry = candidate
      end
    end
  end

  return best_domain, best_entry
end

--- Return total queued items, or queued items for a specific domain.
---@param domain? string
---@return integer
function M:queue_depth(domain)
  if domain then
    local queue = self._domain_queues[domain]
    return queue and #queue or 0
  end
  return self._total_queued
end

--- Return the number of currently in-flight requests.
---@return integer
function M:active_count()
  return self._active_count
end

--- Cancel all queued requests for a specific domain.
---@param domain string
---@return integer count Number of cancelled requests
function M:cancel_domain(domain)
  local queue = self._domain_queues[domain]
  if not queue then
    return 0
  end
  local count = #queue
  self._total_queued = self._total_queued - count
  self._domain_queues[domain] = nil
  log.info("Cancelled " .. count .. " queued requests for " .. domain)
  return count
end

--- Cancel all queued requests and stop the drain timer.
---@return integer count Number of cancelled requests
function M:cancel_all()
  local count = self._total_queued
  self._domain_queues = {}
  self._total_queued = 0
  if self._drain_timer then
    self._drain_timer:stop()
    self._drain_timer:close()
    self._drain_timer = nil
  end
  if count > 0 then
    log.info("Cancelled all " .. count .. " queued requests")
  end
  return count
end

--- Return a copy of the rate limiter's statistics.
---@return { submitted: integer, completed: integer, rejected: integer }
function M:stats()
  return vim.deepcopy(self._stats)
end

--- Full cleanup: cancel all queued, reset all state.
function M:destroy()
  self:cancel_all()
  self._domain_last_request = {}
  self._active_count = 0
end

return M
