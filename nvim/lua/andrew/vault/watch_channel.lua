--- Watch-style coalescing channel.
--- Holds only the latest value; multiple sends between event loop ticks
--- collapse into a single subscriber notification.
---
--- Unlike debounce (which adds N ms of latency), watch coalescing fires
--- on the NEXT event loop tick after any send(). Multiple rapid sends
--- within the same tick produce exactly one callback invocation.
---
--- Unlike event_coalescer.lua (which batches per-buffer event data and
--- flushes after a configurable delay/batch-size), watch_channel is a
--- lower-level primitive: it carries a single latest value and fires on
--- the next tick with zero delay.
---
--- Inspired by Zed's custom watch crate (crates/watch/src/watch.rs).

local M = {}

---@class WatchChannel
---@field _value any           The latest value
---@field _dirty boolean       Whether a send has occurred since last notify
---@field _timer uv.uv_timer_t|nil  Scheduled notification timer
---@field _subscribers fun(value: any)[]  Registered callbacks
---@field _closed boolean      Whether the channel has been closed

---@class WatchChannelHandle
---@field subscribe fun(callback: fun(value: any)): fun()
---@field get fun(): any
---@field close fun()

---@param initial any  Initial value (can be nil)
---@return fun(value: any) send  Function to send a new value
---@return WatchChannelHandle handle  Object with subscribe/close methods
function M.new(initial)
  ---@type WatchChannel
  local state = {
    _value = initial,
    _dirty = false,
    _timer = nil,
    _subscribers = {},
    _closed = false,
  }

  --- Notify all subscribers with the current value and reset dirty flag.
  local function notify()
    state._dirty = false
    state._timer = nil
    if state._closed then return end

    local val = state._value
    for _, cb in ipairs(state._subscribers) do
      cb(val)
    end
  end

  --- Send a new value into the channel.
  --- If already dirty (a notification is pending), the value is updated
  --- in place without scheduling an additional notification -- this is
  --- what produces the coalescing behavior.
  ---@param value any
  local function send(value)
    if state._closed then return end

    state._value = value

    if not state._dirty then
      state._dirty = true
      -- Schedule notification on the next event loop tick.
      -- vim.uv timer with 0ms delay fires after the current Lua call stack
      -- unwinds back to the event loop, coalescing all sends in this tick.
      if state._timer then
        pcall(function()
          state._timer:stop()
          if not state._timer:is_closing() then
            state._timer:close()
          end
        end)
      end
      local t = vim.uv.new_timer()
      if t then
        state._timer = t
        t:start(0, 0, vim.schedule_wrap(notify))
      end
    end
  end

  ---@type WatchChannelHandle
  local handle = {}

  --- Register a callback that fires once per coalesced batch of sends.
  ---@param callback fun(value: any)
  ---@return fun() unsubscribe  Call to remove the subscription
  function handle.subscribe(callback)
    table.insert(state._subscribers, callback)
    return function()
      for i, cb in ipairs(state._subscribers) do
        if cb == callback then
          table.remove(state._subscribers, i)
          return
        end
      end
    end
  end

  --- Get the current value without subscribing.
  ---@return any
  function handle.get()
    return state._value
  end

  --- Close the channel and release the timer.
  function handle.close()
    state._closed = true
    state._subscribers = {}
    if state._timer then
      pcall(function()
        state._timer:stop()
        if not state._timer:is_closing() then
          state._timer:close()
        end
      end)
      state._timer = nil
    end
  end

  return send, handle
end

return M
