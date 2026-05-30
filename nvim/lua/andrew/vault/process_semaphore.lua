--- Process semaphore for bounding concurrent subprocess spawns.
--- Inspired by Zed's Arc<Semaphore> pattern in inlay_hint_cache.rs.

local M = {}

--- @class ProcessSemaphore
--- @field _max number Maximum concurrent permits
--- @field _active number Currently held permits
--- @field _queue table[] Callbacks waiting for permits
--- @field _generation number Incremented on reset (cancels queued waiters)

--- Create a new semaphore with max concurrent permits.
--- @param max number
--- @return ProcessSemaphore
function M.new(max)
  return {
    _max = max,
    _active = 0,
    _queue = {},
    _generation = 0,
  }
end

--- @private
--- Drain queued waiters when permits become available.
--- @param sem ProcessSemaphore
function M._drain_queue(sem)
  while sem._active < sem._max and #sem._queue > 0 do
    local entry = table.remove(sem._queue, 1)
    if entry.callback and entry.gen == sem._generation then
      sem._active = sem._active + 1
      local released = false
      local function release()
        if released then return end
        released = true
        sem._active = sem._active - 1
        M._drain_queue(sem)
      end
      entry.callback(release)
    end
  end
end

--- Acquire a permit. Calls callback immediately if available,
--- otherwise queues it. Returns a cancel function.
--- @param sem ProcessSemaphore
--- @param callback fun(release: fun()) Called with release_fn when permit acquired
--- @return fun() cancel Cancel the queued request
function M.acquire(sem, callback)
  local gen = sem._generation

  if sem._active < sem._max then
    sem._active = sem._active + 1
    local released = false
    local function release()
      if released then return end
      released = true
      sem._active = sem._active - 1
      M._drain_queue(sem)
    end
    callback(release)
    return function() end -- Already acquired, cancel is no-op
  end

  -- Queue the request
  local entry = { callback = callback, gen = gen }
  table.insert(sem._queue, entry)

  return function()
    entry.callback = nil -- Allow GC of closure
  end
end

--- Try to acquire without queuing. Returns release_fn or nil.
--- @param sem ProcessSemaphore
--- @return fun()|nil release_fn
function M.try_acquire(sem)
  if sem._active < sem._max then
    sem._active = sem._active + 1
    local released = false
    return function()
      if released then return end
      released = true
      sem._active = sem._active - 1
      M._drain_queue(sem)
    end
  end
  return nil
end

--- Cancel all queued waiters (e.g., on search cancel).
--- Active permits are still held until released.
--- @param sem ProcessSemaphore
function M.reset(sem)
  sem._generation = sem._generation + 1
  sem._queue = {}
end

--- Get current state for debugging.
--- @param sem ProcessSemaphore
--- @return table { active: number, max: number, queued: number }
function M.stats(sem)
  return {
    active = sem._active,
    max = sem._max,
    queued = #sem._queue,
  }
end

-- Shared singleton for ripgrep process limiting across all vault modules.
local _rg_sem

--- Get (or lazily create) the shared ripgrep semaphore.
--- All modules that spawn rg should use this single instance.
--- @return ProcessSemaphore
function M.rg_semaphore()
  if not _rg_sem then
    local config = require("andrew.vault.config")
    _rg_sem = M.new(config.search.max_concurrent_rg)
  end
  return _rg_sem
end

return M
