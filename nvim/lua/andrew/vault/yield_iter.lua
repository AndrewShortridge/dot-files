--- Cooperative yielding utilities for long-running iterations.
--- Prevents UI freezes by yielding control to Neovim's event loop
--- at configurable intervals.
---
--- Provides the canonical coroutine.create() + vim.schedule(step) pattern.
--- Used by vault_index_build.lua, completion_base.lua, search_filter.lua,
--- connections.lua, and bfs.lua.

local M = {}

--- Run a function over a collection with periodic yielding.
--- Must be called from within a coroutine context (e.g., inside run_async).
---
--- @param items table Array or dict to iterate over
--- @param batch_size number Process this many items before yielding
--- @param process_fn function(key, value) Called for each item
--- @param opts table|nil { cancelled: function }
function M.for_each_yielding(items, batch_size, process_fn, opts)
  opts = opts or {}
  local count = 0

  if vim.islist(items) then
    for i, item in ipairs(items) do
      if opts.cancelled and opts.cancelled() then return end
      process_fn(i, item)
      count = count + 1
      if count >= batch_size then
        count = 0
        coroutine.yield()
      end
    end
  else
    for k, v in pairs(items) do
      if opts.cancelled and opts.cancelled() then return end
      process_fn(k, v)
      count = count + 1
      if count >= batch_size then
        count = 0
        coroutine.yield()
      end
    end
  end
end

--- Run a filtering operation with periodic yielding.
--- Returns matches accumulated across yields.
---
--- @param items table Dict to filter (key → value)
--- @param batch_size number Items per yield
--- @param predicate function(key, value) → boolean
--- @param opts table|nil { cancelled: function, max_results: number }
--- @return table matches Dict of matching key → value pairs
--- @return boolean limit_reached True if max_results cap was hit
function M.filter_yielding(items, batch_size, predicate, opts)
  opts = opts or {}
  local matches = {}
  local match_count = 0
  local count = 0
  local max_results = opts.max_results or math.huge

  for k, v in pairs(items) do
    if opts.cancelled and opts.cancelled() then break end
    if match_count >= max_results then
      return matches, true
    end

    if predicate(k, v) then
      matches[k] = v
      match_count = match_count + 1
    end

    count = count + 1
    if count >= batch_size then
      count = 0
      coroutine.yield()
    end
  end

  return matches, false
end

--- Wrap a synchronous iteration as an async operation using vim.schedule.
--- For use outside of existing coroutine contexts.
---
--- @param fn function Coroutine body (must call coroutine.yield)
--- @param callback_or_opts function|table|nil
---   As function: called with return values when iteration completes.
---   As table: { callback, on_error, cancelled, immediate }
---     callback:  function(val)     — called on completion with coroutine return value
---     on_error:  function(err)     — called on coroutine error (replaces default log)
---     cancelled: function() → bool — external cancellation check (in addition to returned cancel fn)
---     immediate: boolean           — call step() directly instead of vim.schedule(step)
--- @return function cancel Cancel the iteration
function M.run_async(fn, callback_or_opts)
  local opts
  if type(callback_or_opts) == "table" then
    opts = callback_or_opts
  else
    opts = { callback = callback_or_opts }
  end

  local co = coroutine.create(fn)
  local cancelled = false
  local log = require("andrew.vault.vault_log").scope("yield_iter")

  local function step()
    if cancelled then return end
    if opts.cancelled and opts.cancelled() then return end
    local ok, val = coroutine.resume(co)
    if not ok then
      if opts.on_error then
        opts.on_error(tostring(val))
      else
        log:error("coroutine error: %s", tostring(val))
      end
      return
    end
    if coroutine.status(co) == "dead" then
      if opts.callback then opts.callback(val) end
    else
      vim.schedule(step)
    end
  end

  if opts.immediate then
    step()
  else
    vim.schedule(step)
  end

  return function()
    cancelled = true
  end
end

return M
