-- guard.lua — RAII-style cleanup guards for scope-based resource management.
-- Composable, scope-aware abstractions for deterministic cleanup.
-- Inspired by Zed's Drop trait (terminal.rs, lsp.rs), Subscription.detach(),
-- ConnectionGuard, and QueryCursorHandle patterns.

local M = {}

-- ---------------------------------------------------------------------------
-- Core Guard
-- ---------------------------------------------------------------------------

local Guard = {}
Guard.__index = Guard

--- Create a cleanup guard that runs cleanup_fn when released.
---@param cleanup_fn function The cleanup action to perform
---@param name? string Guard name for debugging
---@return table guard Object with :release() and :dismiss() methods
function M.new(cleanup_fn, name)
  local guard = setmetatable({
    _cleanup = cleanup_fn,
    _name = name or "anonymous",
    _released = false,
    _dismissed = false,
  }, Guard)

  -- Debug mode: detect guards that are GC'd without release or dismiss
  local cfg = package.loaded["andrew.vault.config"]
  if cfg and cfg.guards and cfg.guards.warn_unreleased then
    local guard_name = guard._name
    local ud = newproxy(true)
    getmetatable(ud).__gc = function()
      vim.schedule(function()
        vim.notify(
          string.format("Guard '%s' was never released or dismissed!", guard_name),
          vim.log.levels.WARN
        )
      end)
    end
    guard._detector = ud
  end

  return guard
end

--- Explicitly release the guard, running cleanup immediately.
--- Safe to call multiple times (idempotent).
function Guard:release()
  if self._released or self._dismissed then return end
  self._released = true
  self._detector = nil -- disarm leak detector
  local ok, err = pcall(self._cleanup)
  if not ok then
    local cfg = package.loaded["andrew.vault.config"]
    local should_log = not cfg or not cfg.guards or cfg.guards.log_cleanup_errors ~= false
    if should_log then
      vim.schedule(function()
        vim.notify(
          string.format("Guard '%s' cleanup error: %s", self._name, err),
          vim.log.levels.WARN
        )
      end)
    end
  end
end

--- Dismiss the guard (cancel cleanup).
--- Call when the resource has been transferred to another owner.
--- Inspired by Zed's Subscription.detach() (subscription.rs:175-177).
function Guard:dismiss()
  self._dismissed = true
  self._detector = nil -- disarm leak detector
end

--- Check if guard is still active (not released or dismissed).
---@return boolean
function Guard:is_active()
  return not self._released and not self._dismissed
end

-- ---------------------------------------------------------------------------
-- Multi-Guard (Multiple Resources, LIFO Release)
-- ---------------------------------------------------------------------------

--- Manage multiple cleanup guards with ordered release (LIFO).
---@return table multi_guard
function M.multi()
  local guards = {}

  local mg = {}

  --- Add a cleanup action. Cleanups run in reverse order (LIFO).
  ---@param cleanup_fn function
  ---@param name? string
  ---@return table guard Individual guard handle
  function mg:add(cleanup_fn, name)
    local g = M.new(cleanup_fn, name)
    guards[#guards + 1] = g
    return g
  end

  --- Release all guards in reverse order.
  function mg:release_all()
    for i = #guards, 1, -1 do
      guards[i]:release()
    end
  end

  --- Dismiss all guards.
  function mg:dismiss_all()
    for i = 1, #guards do
      guards[i]:dismiss()
    end
  end

  --- Execute body with automatic cleanup of all guards on exit.
  ---@param body_fn function(mg) Function receiving multi_guard for adding guards
  ---@return boolean ok, any result_or_error
  function mg:run(body_fn)
    local ok, result = pcall(body_fn, mg)
    if not ok then
      mg:release_all()
      return false, result
    end
    return true, result
  end

  return mg
end

return M
