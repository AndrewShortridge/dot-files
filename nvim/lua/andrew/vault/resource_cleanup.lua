-- resource_cleanup.lua — Shared resource cleanup utilities
-- Eliminates duplicated timer/window/buffer cleanup patterns across vault modules.

local M = {}

-- Weak table for profiler timer tracking (GC'd timers disappear automatically)
local _active_timers = setmetatable({}, { __mode = "v" })
local _timer_id = 0

--- Get count of active (non-GC'd) timers tracked by this module.
---@return number
function M.active_timer_count()
  local n = 0
  for _ in pairs(_active_timers) do n = n + 1 end
  return n
end

--- Stop and close a uv timer safely.
--- Handles already-stopped, already-closing, and nil timers.
---@param timer uv.uv_timer_t|nil
function M.close_timer(timer)
  if not timer then return end
  pcall(function()
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end)
end

--- Stop, close, and remove a timer from a keyed dictionary.
---@param dict table<any, uv.uv_timer_t>
---@param key any
function M.close_timer_in(dict, key)
  local timer = dict[key]
  if not timer then return end
  dict[key] = nil
  M.close_timer(timer)
end

--- Create a debounced timer. Closes any existing timer, creates a new one,
--- and starts it with the given delay. The callback is vim.schedule_wrap'd.
---@param existing uv.uv_timer_t|nil  existing timer to close first
---@param delay_ms number
---@param callback function  called inside vim.schedule after delay
---@return uv.uv_timer_t|nil  the new timer (caller should store this)
function M.debounce(existing, delay_ms, callback)
  M.close_timer(existing)
  local t = vim.uv.new_timer()
  if not t then return nil end
  t:start(delay_ms, 0, vim.schedule_wrap(callback))
  _timer_id = _timer_id + 1
  _active_timers[_timer_id] = t
  return t
end

--- Create a repeating timer. Closes any existing timer, creates a new one,
--- and starts it with the given initial delay and repeat interval.
--- The callback is vim.schedule_wrap'd.
---@param existing uv.uv_timer_t|nil  existing timer to close first
---@param delay_ms number  initial delay before first tick
---@param repeat_ms number  interval between subsequent ticks
---@param callback function  called inside vim.schedule on each tick
---@return uv.uv_timer_t|nil  the new timer (caller should store this)
function M.repeating(existing, delay_ms, repeat_ms, callback)
  M.close_timer(existing)
  local t = vim.uv.new_timer()
  if not t then return nil end
  t:start(delay_ms, repeat_ms, vim.schedule_wrap(callback))
  _timer_id = _timer_id + 1
  _active_timers[_timer_id] = t
  return t
end

--- Create a weak-reference wrapper for a module's state.
--- The callback becomes a no-op when the referenced state is GC'd.
---
---@param state table The module state to weakly reference
---@param callback function(state, ...) Called with state if still alive
---@return function(...) Wrapped callback
function M.weak_callback(state, callback)
  local weak = setmetatable({ ref = state }, { __mode = "v" })

  return function(...)
    local s = weak.ref
    if s then
      callback(s, ...)
    end
  end
end

--- Create a BufDelete + BufWipeout autocmd that calls a cleanup function with bufnr.
--- Centralises the event pair so BufWipeout is never accidentally omitted.
---@param group number augroup id
---@param callback fun(bufnr: number)
---@param opts? { pattern?: string } optional file pattern filter (e.g. "*.md")
function M.on_buf_delete(group, callback, opts)
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    pattern = opts and opts.pattern or nil,
    callback = function(ev) callback(ev.buf) end,
  })
end

--- Create a one-shot BufDelete + BufWipeout autocmd for a specific buffer.
--- Useful for buffer-local cleanup that should fire exactly once.
---@param bufnr number buffer handle
---@param callback fun(bufnr: number)
function M.on_buf_delete_once(bufnr, callback)
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    buffer = bufnr,
    once = true,
    callback = function() callback(bufnr) end,
  })
end

--- Delete an augroup if it exists.
--- Handles already-deleted augroups gracefully.
---@param augroup number|nil augroup id
function M.close_augroup(augroup)
  if not augroup then return end
  pcall(vim.api.nvim_del_augroup_by_id, augroup)
end

--- Close a window if it exists and is valid.
---@param win number|nil
function M.close_win(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

--- Delete a buffer if it exists and is valid.
---@param buf number|nil
function M.delete_buf(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- Close a window and delete its buffer.
---@param win number|nil
---@param buf number|nil
function M.close_win_buf(win, buf)
  M.close_win(win)
  M.delete_buf(buf)
end

--- Create a managed subscription handle with idempotency and vault-switch detection.
--- Encapsulates the ensure/unsubscribe pattern used by embed_sync and connections.
---@param get_index fun(): table|nil  Function returning current vault index (or nil)
---@param callback function  The subscriber callback
---@param opts? { weak_state?: table }  If weak_state is provided, wraps callback with weak_callback so it becomes a no-op when the state table is GC'd (defense-in-depth)
---@return table handle  { ensure(): boolean, unsubscribe(): nil, is_active(): boolean }
function M.subscription_handle(get_index, callback, opts)
  -- callback can be a plain function or a { fn, interests } table (tiered invalidation)
  assert(type(callback) == "function"
    or (type(callback) == "table" and type(callback.fn) == "function"),
    "subscription_handle: callback must be a function or { fn = function, interests? = string[] }")
  local actual_sub = callback
  if opts and opts.weak_state then
    if type(callback) == "table" and callback.fn then
      -- Wrap the inner fn with weak_callback, preserve interests
      local weak_fn = M.weak_callback(opts.weak_state, function(_state, ...)
        callback.fn(...)
      end)
      actual_sub = { fn = weak_fn, interests = callback.interests }
    else
      actual_sub = M.weak_callback(opts.weak_state, function(_state, ...)
        callback(...)
      end)
    end
  end

  local unsub_fn = nil
  local subscribed_idx = nil

  local handle = {}

  function handle.ensure()
    local idx = get_index()
    if not idx then return false end
    if unsub_fn and subscribed_idx == idx then return true end
    if unsub_fn then unsub_fn() end
    unsub_fn = idx:subscribe(actual_sub)
    subscribed_idx = idx
    return true
  end

  function handle.unsubscribe()
    if unsub_fn then
      unsub_fn()
      unsub_fn = nil
    end
    subscribed_idx = nil
  end

  function handle.is_active()
    return unsub_fn ~= nil
  end

  return handle
end

-- Deferred profiler registration (safe: profiler may not be loaded yet)
do
  local ok, profiler = pcall(require, "andrew.vault.memory_profiler")
  if ok then
    profiler.register_counter_deferred({
      name = "active_timers",
      get_count = function() return M.active_timer_count() end,
      description = "uv timers created via resource_cleanup",
    })
  end
end

return M
