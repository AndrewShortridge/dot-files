--- Generation-based cache factories for vault index data.
--- Provides invalidation tied to vault_index._generation, ensuring cached
--- computations are automatically refreshed when the index changes.
---
--- Zero external dependencies (uses vault_index via package.loaded to
--- avoid circular requires).
--- @module andrew.vault.gen_cache

local M = {}

--- Get the current vault index (or nil) without a hard require.
---@return table|nil
local function current_index()
  local vi = package.loaded["andrew.vault.vault_index"]
  return vi and vi.current() or nil
end

--- Create a generation-based single-value cache.
--- The build function is called when the vault index generation changes
--- (or when an optional composite key changes).
---
--- @param build_fn fun(idx: table, ...): any  Builder called on cache miss.
--- @param opts? { key_fn: fun(...): string, partial_fn: fun(cached: any, idx: table, ctx: table, ...): any }
--- @return { get: fun(...): any, invalidate: fun() }
function M.gen_cache(build_fn, opts)
  local cached_gen = 0
  local cached_key = nil
  local cached_value = nil
  local key_fn = opts and opts.key_fn
  local partial_fn = opts and opts.partial_fn
  local hits = 0
  local misses = 0

  return {
    get = function(...)
      local idx = current_index()
      if not idx then return nil end

      local gen = idx._generation or 0
      local key = key_fn and key_fn(...) or nil

      if cached_value ~= nil and cached_gen == gen and (not key_fn or cached_key == key) then
        hits = hits + 1
        return cached_value
      end

      -- If partial builder exists and we have a cached value, try partial update.
      -- Only safe when exactly one generation passed; multi-generation skip
      -- means intermediate contexts are lost — fall through to full rebuild.
      if partial_fn and cached_value ~= nil and idx._last_inv_ctx then
        local ctx = idx._last_inv_ctx
        if ctx.tier ~= "full" and gen == cached_gen + 1 then
          local ok, result = pcall(partial_fn, cached_value, idx, ctx, ...)
          if ok then
            cached_value = result
            cached_gen = gen
            cached_key = key
            hits = hits + 1
            -- Track partial cache hit for monitoring
            if idx._inv_stats then
              idx._inv_stats.partial_cache_hits = (idx._inv_stats.partial_cache_hits or 0) + 1
            end
            return cached_value
          end
          -- Fall through to full rebuild on error
        end
      end

      misses = misses + 1
      cached_value = build_fn(idx, ...)
      cached_gen = gen
      cached_key = key
      return cached_value
    end,

    invalidate = function()
      cached_value = nil
      cached_gen = 0
      cached_key = nil
    end,

    get_hits = function() return hits end,
    get_misses = function() return misses end,
  }
end

--- Create a multi-key generation-based cache.
--- Unlike gen_cache which stores one value, this caches multiple keyed entries
--- and invalidates all of them when the vault index generation changes.
---
--- @param build_fn fun(idx: table, key: string, ...): any  Builder for a single key.
--- @return { get: fun(key: string, ...): any, invalidate: fun() }
function M.keyed_gen_cache(build_fn)
  local cached_gen = 0
  local entries = {}
  local hits = 0
  local misses = 0
  local evictions = 0

  return {
    get = function(key, ...)
      local idx = current_index()
      if not idx then return nil end

      local gen = idx._generation or 0
      if gen ~= cached_gen then
        -- Count evicted entries before clearing
        for _ in pairs(entries) do evictions = evictions + 1 end
        entries = {}
        cached_gen = gen
      end

      if entries[key] ~= nil then
        hits = hits + 1
        return entries[key]
      end

      misses = misses + 1
      local value = build_fn(idx, key, ...)
      entries[key] = value
      return value
    end,

    invalidate = function()
      entries = {}
      cached_gen = 0
    end,

    get_hits = function() return hits end,
    get_misses = function() return misses end,
    get_evictions = function() return evictions end,
  }
end

return M
