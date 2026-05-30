-- memoize.lua — Generic version-aware memoization for state checks.
-- Pairs a version function with a computation function; returns cached
-- result when the version matches, recomputes otherwise.

local M = {}

local config = require("andrew.vault.config")

---@class MemoizedCheck
---@field _version_fn fun(key: any): any
---@field _compute_fn fun(key: any): any
---@field _cache table<any, {version: any, result: any}>
---@field _entry_count number
---@field _name string|nil
---@field _hits number
---@field _misses number
local MemoizedCheck = {}
MemoizedCheck.__index = MemoizedCheck

--- Create a new memoized check.
---@param version_fn fun(key: any): any  Returns current version for key
---@param compute_fn fun(key: any): any  Expensive computation to cache
---@param name? string  Optional name for debug output
---@return MemoizedCheck
function M.new(version_fn, compute_fn, name)
  local self = setmetatable({
    _version_fn = version_fn,
    _compute_fn = compute_fn,
    _cache = {},
    _entry_count = 0,
    _name = name,
    _hits = 0,
    _misses = 0,
  }, MemoizedCheck)
  return self
end

--- Get the cached or freshly computed result for the given key.
---@param key any  Cache key (typically bufnr)
---@return any result
function MemoizedCheck:get(key)
  local current_version = self._version_fn(key)
  local entry = self._cache[key]

  if entry and entry.version == current_version then
    self._hits = self._hits + 1
    return entry.result
  end

  self._misses = self._misses + 1

  -- Evict if at capacity and this is a new key
  if not entry and self._entry_count >= (config.memoize and config.memoize.max_entries or 100) then
    self:_evict_one()
  end

  local result = self._compute_fn(key)

  if not entry then
    self._entry_count = self._entry_count + 1
  end

  self._cache[key] = { version = current_version, result = result }
  return result
end

--- Remove a specific key from the cache (e.g., on BufDelete).
---@param key any
function MemoizedCheck:invalidate(key)
  if self._cache[key] then
    self._cache[key] = nil
    self._entry_count = self._entry_count - 1
  end
end

--- Clear all cached entries.
function MemoizedCheck:clear()
  self._cache = {}
  self._entry_count = 0
end

--- Evict one arbitrary entry when at capacity.
function MemoizedCheck:_evict_one()
  local evict_key = next(self._cache)
  if evict_key then
    self._cache[evict_key] = nil
    self._entry_count = self._entry_count - 1
  end
end

-- ============================================================================
-- Buffer cleanup registry
-- ============================================================================

local _registered = {}
local _cleanup_installed = false

--- Clear all registered memoized checks (for vault-wide invalidation).
function M.clear_all()
  for _, check in ipairs(_registered) do
    check:clear()
  end
end

--- Register a MemoizedCheck for automatic buffer cleanup.
---@param check MemoizedCheck
function M.register_buf_cleanup(check)
  table.insert(_registered, check)

  if not _cleanup_installed then
    _cleanup_installed = true
    local cleanup = require("andrew.vault.resource_cleanup")
    cleanup.on_buf_delete(
      vim.api.nvim_create_augroup("VaultMemoizeCleanup", { clear = true }),
      function(bufnr)
        for _, c in ipairs(_registered) do
          c:invalidate(bufnr)
        end
      end
    )
  end
end

-- ============================================================================
-- Pre-built version functions
-- ============================================================================

--- Version function: buffer changedtick.
---@param bufnr number
---@return number
function M.changedtick(bufnr)
  return vim.api.nvim_buf_get_changedtick(bufnr)
end

--- Version function: vault index generation.
---@return number
function M.index_generation(_key)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  return idx and idx._generation or 0
end

--- Version function: composite of changedtick + index generation.
---@param bufnr number
---@return string
function M.changedtick_and_generation(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  local gen = idx and idx._generation or 0
  return tick .. ":" .. gen
end

-- ============================================================================
-- Debug
-- ============================================================================

--- Get stats for all registered checks (for VaultCacheDebug integration).
---@return table[]
function M.stats()
  local result = {}
  for i, check in ipairs(_registered) do
    result[i] = {
      name = check._name or ("check_" .. i),
      entries = check._entry_count,
      hits = check._hits,
      misses = check._misses,
    }
  end
  return result
end

function M.setup_commands()
  vim.api.nvim_create_user_command("VaultMemoDebug", function()
    local lines = { "Memoized State Checks:" }
    for i, check in ipairs(_registered) do
      local label = check._name or ("check_" .. i)
      local total = check._hits + check._misses
      local rate = total > 0 and string.format("%.1f%%", (check._hits / total) * 100) or "n/a"
      table.insert(lines, string.format("  %s: %d entries, %d hits, %d misses (hit rate: %s)",
        label, check._entry_count, check._hits, check._misses, rate))
    end
    table.insert(lines, string.format("Total registered: %d", #_registered))
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "Show memoized check statistics" })
end

return M
