--- Batches and coalesces autocmd events to reduce redundant processing.
--- Inspired by Zed's ready_chunks(128), DebouncedDelay, and EventCoalescer patterns.

local cleanup = require("andrew.vault.resource_cleanup")

local M = {}

--- @class EventCoalescer
--- @field _pending table<number, table> Pending events by bufnr
--- @field _timer uv_timer_t|nil Coalescing timer
--- @field _delay_ms number Base coalescing window (ms)
--- @field _handler function Batch handler callback
--- @field _max_batch number Max events before forced flush
--- @field _pending_count number Number of unique buffers pending
--- @field _adaptive boolean Whether adaptive delay is enabled
--- @field _rapid_threshold_ms number Time between events to count as rapid
--- @field _rapid_delay_ms number Extended delay during rapid switching
--- @field _last_queue_time number Last queue timestamp (ms)
--- @field _rapid_count number Consecutive rapid events

--- Create a new event coalescer.
--- @param opts { delay_ms: number, max_batch: number, handler: function, adaptive: boolean, rapid_threshold_ms: number, rapid_delay_ms: number }
--- @return EventCoalescer
function M.new(opts)
  return {
    _pending = {},
    _timer = nil,
    _delay_ms = opts.delay_ms or 16,
    _max_batch = opts.max_batch or 32,
    _handler = opts.handler,
    _pending_count = 0,
    -- Adaptive delay for :bufdo-style rapid switching
    _adaptive = opts.adaptive or false,
    _rapid_threshold_ms = opts.rapid_threshold_ms or 50,
    _rapid_delay_ms = opts.rapid_delay_ms or 200,
    _last_queue_time = 0,
    _rapid_count = 0,
  }
end

--- Compute effective delay, increasing during rapid buffer switching.
--- @param coalescer EventCoalescer
--- @return number delay_ms
local function effective_delay(coalescer)
  if not coalescer._adaptive then
    return coalescer._delay_ms
  end

  local now = vim.uv.now()
  if now - coalescer._last_queue_time < coalescer._rapid_threshold_ms then
    coalescer._rapid_count = coalescer._rapid_count + 1
  else
    coalescer._rapid_count = 0
  end
  coalescer._last_queue_time = now

  -- After 3+ rapid switches, use extended delay
  if coalescer._rapid_count > 3 then
    return coalescer._rapid_delay_ms
  end
  return coalescer._delay_ms
end

--- Queue an event for batched processing.
--- @param coalescer EventCoalescer
--- @param bufnr number
--- @param event_data table|nil Additional event context
function M.queue(coalescer, bufnr, event_data)
  coalescer._pending[bufnr] = event_data or {}
  coalescer._pending_count = vim.tbl_count(coalescer._pending)

  if coalescer._pending_count >= coalescer._max_batch then
    M.flush(coalescer)
    return
  end

  local delay = effective_delay(coalescer)

  if coalescer._timer then
    coalescer._timer:stop()
  else
    coalescer._timer = vim.uv.new_timer()
  end

  coalescer._timer:start(delay, 0, vim.schedule_wrap(function()
    M.flush(coalescer)
  end))
end

--- Flush all pending events as a single batch.
--- @param coalescer EventCoalescer
function M.flush(coalescer)
  if coalescer._timer then
    coalescer._timer:stop()
  end

  local batch = coalescer._pending
  coalescer._pending = {}
  coalescer._pending_count = 0

  if next(batch) then
    coalescer._handler(batch)
  end
end

--- Stop the coalescer, flush pending, close timer.
--- @param coalescer EventCoalescer
function M.close(coalescer)
  M.flush(coalescer)
  cleanup.close_timer(coalescer._timer)
  coalescer._timer = nil
end

return M
