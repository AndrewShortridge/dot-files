local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local cleanup = require("andrew.vault.resource_cleanup")
local filter_utils = require("andrew.vault.filter_utils")
local log = require("andrew.vault.vault_log").scope("completion_base")
local table_pool = require("andrew.vault.table_pool")
local operation_tracker = require("andrew.vault.operation_tracker")

local M = {}

-- ---------------------------------------------------------------------------
-- CompletionItemKind constants (LSP spec)
-- ---------------------------------------------------------------------------
M.KIND = {
  Text = 1,
  Variable = 10,
  Value = 12,
  Keyword = 14,
  File = 18,
  Folder = 19,
  Reference = 22,
}

local _item_pool = table_pool.new(config.pools.completion_item, function(obj)
  obj.label = nil
  obj.insertText = nil
  obj.filterText = nil
  obj.kind = nil
  obj.sortText = nil
  obj.documentation = nil
  obj.data = nil
  obj.labelDetails = nil
  obj._char_bag = nil
end)
table_pool.register("completion_item", _item_pool)

-- ---------------------------------------------------------------------------
-- Shared utilities
-- ---------------------------------------------------------------------------

--- Derive absolute path from a relative vault path.
--- @param rel_path string
--- @return string
function M.resolve_abs_path(rel_path)
  return engine.vault_path .. "/" .. rel_path
end

--- Truncate text with ellipsis if it exceeds max_len.
--- @param text string
--- @param max_len number|nil  Default 60
--- @return string
function M.truncate_text(text, max_len)
  max_len = max_len or 60
  if #text > max_len then
    return text:sub(1, max_len - 3) .. "..."
  end
  return text
end

--- Format a sortText string for order-based sorting (ascending).
--- @param order number
--- @return string
function M.order_sort_text(order)
  return string.format("%04d", order)
end

--- Build a completion item with standard fields.
--- @param label string
--- @param insertText string
--- @param filterText string
--- @param kind number  CompletionItemKind
--- @param opts { description: string|nil, sortText: string|nil, documentation: table|nil, data: table|nil }|nil
--- @return table
function M.make_item(label, insertText, filterText, kind, opts)
  local item = _item_pool:acquire(function()
    return { label = nil, insertText = nil, filterText = nil, kind = nil,
             sortText = nil, documentation = nil, data = nil, labelDetails = nil,
             _char_bag = nil }
  end)
  item.label = label
  item.insertText = insertText
  item.filterText = filterText
  item.kind = kind
  if opts then
    if opts.description then
      item.labelDetails = { description = opts.description }
    end
    if opts.sortText then item.sortText = opts.sortText end
    if opts.documentation then item.documentation = opts.documentation end
    if opts.data then item.data = opts.data end
  end
  return item
end

--- Read a completion config value with a default fallback.
local function conf(key, default)
  local c = config.completion
  return c and c[key] or default
end

local _building_first_seen = nil -- tracks when we first saw vault_index._building (for 30s timeout)

local all_invalidators = {}
local all_source_stats = {} -- { name -> stats_fn } for debug reporting
local all_ops_trackers = {} -- { name -> operation_tracker } for VaultOpsDebug

--- Expose per-source operation trackers for VaultOpsDebug.
---@return table<string, table>
function M.ops_trackers()
  return all_ops_trackers
end

-- Memoize build_kv_single_pass results by (vault_path, field_name, generation)
local _field_cache = {} -- "vault_path\0field_name" -> { gen, result }

--- Per-file invalidation handlers registered by each source.
---@type table<string, fun(abs_path: string)>
local all_file_invalidators = {}

--- Invalidate all registered completion source caches.
--- Called by engine.invalidate_caches() on FocusGained / fs_event / vault switch.
function M.invalidate_all()
  for _, invalidate in ipairs(all_invalidators) do
    invalidate()
  end
  _field_cache = {} -- clear memoized single-pass results
end

--- Invalidate completion items for a single file across all sources.
---@param abs_path string
function M.invalidate_file(abs_path)
  for _, invalidate_file in pairs(all_file_invalidators) do
    invalidate_file(abs_path)
  end
end

-- Register with central cache registry
engine.register_cache({
  name = "completions",
  module = "andrew.vault.completion_base",
  invalidate = M.invalidate_all,
  invalidate_file = M.invalidate_file,
  stats = function()
    return {
      entries = #all_invalidators,
      age_seconds = nil,
      vault = nil,
      ttl = nil,
    }
  end,
})

do
  local profiler = require("andrew.vault.memory_profiler")
  profiler.register_counter({
    name = "completion_active_builds",
    get_count = function()
      local n = 0
      for _, stats_fn in pairs(all_source_stats) do
        local s = stats_fn()
        if s.state ~= "idle" then n = n + 1 end
      end
      return n
    end,
    description = "completion sources with active async builds",
  })
end

--- Create a blink-cmp completion source with standard boilerplate.
--- @param opts { build: (fun(vault_path: string, callback: fun(items: table[])))|nil, build_iter: (fun(vault_path: string): (fun(): table|nil)|nil)|nil, get_completions: (fun(self: table, ctx: table, items: table[], callback: fun(response: table)))|nil, resolve_item: (fun(self: table, item: table, callback: fun(item: table)))|nil, name: string|nil }
--- @return table  blink-cmp source module
function M.create_source(opts)
  local source = {}
  local cached_items = nil
  local cached_vault = nil
  -- NOTE: Manual generation tracking (not gen_cache) because completion sources
  -- have async coroutine builds with debounce/cancellation and vault-switch
  -- detection. gen_cache assumes synchronous build-on-access.
  local _cached_gen = nil -- vault_index._generation at last build
  -- Operation tracker for detecting concurrent/superseded builds.
  -- Replaces the ad-hoc build_generation counter.
  local build_ops = operation_tracker.new()

  -- Active async build state (for cancellation)
  local active_state = nil -- { cancelled: bool, timer: uv_timer|nil }

  -- Configuration
  local debounce_ms = conf("debounce_ms", 250)
  local batch_size = conf("batch_size", 50)

  --- Compute adaptive batch size to cap coroutine yields at 3.
  --- For small vaults, increases batch to minimize scheduling overhead.
  --- @param estimated_items number
  --- @param configured number
  --- @return number
  local function effective_batch_size(estimated_items, configured)
    if estimated_items <= 0 then return configured end
    return math.max(configured, math.ceil(estimated_items / 3))
  end

  --- Check if vault index is mid-build (with 30s timeout fallback).
  --- Returns true if rebuild should be skipped.
  --- @return boolean
  local function index_is_building()
    local vault_index_mod = package.loaded["andrew.vault.vault_index"]
    if vault_index_mod then
      local idx = vault_index_mod.current()
      if idx and idx._building then
        if not _building_first_seen then
          _building_first_seen = vim.uv.hrtime()
        end
        local timeout = conf("index_build_timeout_secs", 30)
        if (vim.uv.hrtime() - _building_first_seen) / 1e9 < timeout then
          return true
        end
      end
    end
    if _building_first_seen then
      _building_first_seen = nil
    end
    return false
  end

  local function invalidate()
    if cached_items then
      _item_pool:release_batch(cached_items)
    end
    cached_items = nil
    _cached_gen = nil
    build_ops:start()
  end

  -- Track last build timing
  local last_build_ms = nil
  local last_build_time = nil -- os.time() of last build completion

  -- Register this source's invalidator for the shared autocmd
  all_invalidators[#all_invalidators + 1] = invalidate

  -- Register per-file invalidator for tiered cache invalidation
  local source_name = opts.name or ("source_" .. (#all_invalidators))
  all_ops_trackers[source_name] = build_ops
  all_file_invalidators[source_name] = function(abs_path)
    if not cached_items then return end
    local rel = engine.vault_relative(abs_path)
    if not rel then return end

    -- Remove stale items for this file, track if anything was removed
    local new_items = {}
    local removed_count = 0
    for _, item in ipairs(cached_items) do
      if item.data and item.data.rel_path == rel then
        _item_pool:release(item)
        removed_count = removed_count + 1
      else
        new_items[#new_items + 1] = item
      end
    end

    -- If no items matched this file (e.g., aggregate sources like tags),
    -- do NOT update _cached_gen — let cache_valid() detect staleness
    -- and trigger a proper full rebuild.
    if removed_count == 0 and not opts.build_single then return end

    -- Rebuild items for this file if it still exists and source provides build_single
    if opts.build_single then
      local vi = package.loaded["andrew.vault.vault_index"]
      if vi then
        local idx = vi.current()
        if idx and idx.files[rel] then
          local new = opts.build_single(rel, idx.files[rel], idx)
          if new then
            if type(new) == "table" and new[1] then
              for _, item in ipairs(new) do
                new_items[#new_items + 1] = item
              end
            else
              new_items[#new_items + 1] = new
            end
          end
        end
      end
    end

    cached_items = new_items
    -- Only update generation if build_single rebuilt the items.
    -- Without build_single, items were removed but not replaced — leave
    -- _cached_gen stale so cache_valid() triggers a full async rebuild.
    if opts.build_single then
      local vi = package.loaded["andrew.vault.vault_index"]
      if vi then
        local idx = vi.current()
        if idx then _cached_gen = idx._generation end
      end
    end
  end

  -- Profiler cache registration: hit/miss tracking for gen-based cache
  local _cache_hits = 0
  local _cache_misses = 0
  do
    local profiler = require("andrew.vault.memory_profiler")
    profiler.register_cache({
      name = "completion:" .. source_name,
      get_size = function() return cached_items and #cached_items or 0 end,
      get_capacity = function() return conf("max_items", 10000) end,
      get_hits = function() return _cache_hits end,
      get_misses = function() return _cache_misses end,
      get_evictions = function() return 0 end,
      get_generation = function() return _cached_gen end,
    })
  end

  -- Register stats accessor for debug command
  all_source_stats[source_name] = function()
    local state_label = "idle"
    if active_state then
      state_label = active_state.timer and "debouncing" or "building"
    end
    return {
      cached = cached_items ~= nil,
      item_count = cached_items and #cached_items or 0,
      cached_vault = cached_vault,
      _cached_gen = _cached_gen,
      build_generation = build_ops:current(),
      state = state_label,
      uses_build_iter = opts.build_iter ~= nil,
      last_build_ms = last_build_ms,
      last_build_time = last_build_time,
      debounce_ms = debounce_ms,
      batch_size = batch_size,
    }
  end

  --- Check if the cached items are still valid against the vault index generation.
  --- NOTE: Intentionally does NOT use filter_utils.is_cache_gen_valid() because
  --- we want to serve stale cache when vault_index isn't loaded/ready yet,
  --- rather than triggering a rebuild.
  local function cache_valid()
    if not cached_items or cached_vault ~= engine.vault_path then
      return false
    end
    -- Check vault index generation for staleness
    local vault_index = package.loaded["andrew.vault.vault_index"]
    if vault_index then
      local idx = vault_index.current()
      if idx and idx._generation ~= _cached_gen then
        return false
      end
    end
    return true
  end

  --- Cancel any in-flight async build.
  local function cancel_active()
    if active_state then
      active_state.cancelled = true
      if active_state.timer then
        cleanup.close_timer(active_state.timer)
        active_state.timer = nil
      end
      active_state = nil
    end
  end

  --- Build items using a coroutine that yields every batch_size entries.
  --- @param callback fun(items: table[])
  --- @return fun() cancel  Cancel function for blink.cmp
  local function build_items_async(callback)
    cancel_active()

    local state = { cancelled = false, timer = nil }
    active_state = state

    local op_id = build_ops:current()
    local vault_path = engine.vault_path
    local build_start = vim.uv.hrtime()

    -- Helper to update cache after a successful build
    local function update_cache(items)
      -- Generate sortText from mtime for items that don't have one yet.
      -- Lower sortText = more recent (blink.cmp sorts ascending).
      for _, item in ipairs(items) do
        if not item.sortText and item.data and item.data.mtime then
          item.sortText = string.format("%010d", 9999999999 - item.data.mtime)
        end
      end

      -- Cap item count to prevent unbounded memory growth
      local max_items = conf("max_items", 10000)
      if max_items > 0 and #items > max_items then
        -- Items are now sorted by mtime via sortText. Truncate to keep most recent.
        table.sort(items, function(a, b)
          return (a.sortText or "") < (b.sortText or "")
        end)
        for i = max_items + 1, #items do
          items[i] = nil
        end
      end

      local vault_index = package.loaded["andrew.vault.vault_index"]
      if vault_index then
        local idx = vault_index.current()
        if idx then _cached_gen = idx._generation end
      end
      cached_items = items
      cached_vault = vault_path
      active_state = nil
      last_build_ms = (vim.uv.hrtime() - build_start) / 1e6
      last_build_time = os.time()
    end

    --- Shared pre-build guard: returns true if the build should be skipped
    --- (stale operation or index mid-build). Handles wait_for_ready scheduling.
    local function should_skip_build(cb)
      if state.cancelled or build_ops:is_stale(op_id) then
        if cb then cb({}) end
        return true
      end
      if index_is_building() then
        local vi = require("andrew.vault.vault_index")
        local idx = vi.current()
        if idx then
          idx:wait_for_ready(function()
            invalidate()
          end, "completion.first_ready")
        end
        if cb then cb({}) end
        return true
      end
      return false
    end

    -- If the source provides a chunked build, use the coroutine path.
    -- Otherwise fall back to the original synchronous build.
    if not opts.build_iter and opts.build then
      -- Legacy synchronous build (for sources that haven't migrated)
      state.timer = cleanup.debounce(state.timer, debounce_ms, function()
        state.timer = nil
        if should_skip_build(callback) then return end
        opts.build(vault_path, function(items)
          if state.cancelled or build_ops:is_stale(op_id) then
            if callback then callback({}) end
            return
          end
          update_cache(items)
          if callback then callback(items) end
        end)
      end)
      return function() cancel_active() end
    end

    -- Coroutine-based chunked build
    state.timer = cleanup.debounce(state.timer, debounce_ms, function()
      state.timer = nil
      if should_skip_build(callback) then return end

      local items = {}
      local iter = opts.build_iter(vault_path)
      if not iter then
        update_cache(items)
        if callback then callback(items) end
        return
      end

      -- Adaptive batch sizing: cap at 3 yields
      local est_count = 0
      local vi_mod = package.loaded["andrew.vault.vault_index"]
      if vi_mod then
        local vi_idx = vi_mod.current()
        if vi_idx and vi_idx.file_count then
          est_count = vi_idx:file_count()
        end
      end
      local effective_bs = effective_batch_size(est_count, batch_size)

      local yield_iter = require("andrew.vault.yield_iter")
      local batch_drain = require("andrew.vault.batch_drain")
      yield_iter.run_async(function()
        local batch = batch_drain.new({
          max_count = effective_bs,
          on_drain = function(chunk)
            for _, item in ipairs(chunk) do
              items[#items + 1] = item
            end
            if coroutine.isyieldable() then
              coroutine.yield()
            end
          end,
        })

        for item in iter do
          batch:push(item)
        end
        batch:flush()
      end, {
        cancelled = function()
          if state.cancelled or build_ops:is_stale(op_id) then
            active_state = nil
            return true
          end
          return false
        end,
        on_error = function(err)
          vim.schedule(function()
            log:warn("completion build error: %s", err)
          end)
          active_state = nil
          if callback then callback({}) end
        end,
        callback = function()
          update_cache(items)
          if callback then callback(items) end
        end,
        immediate = true,
      })
    end)

    return function() cancel_active() end
  end

  function source.new()
    local self = setmetatable({}, { __index = source })
    -- Pre-warm the cache via DEFERRED priority (background, not competing
    -- with user-visible work like highlight rendering or embed display)
    if vim.bo.filetype == "markdown" then
      local sched = require("andrew.vault.work_scheduler")
      sched.schedule(sched.DEFERRED, function()
        build_items_async()
      end, { domain = "completion", label = "cache-warm" })
    end

    -- Re-warm when vault index generation advances (e.g., after build_async
    -- completes a full scan). Without this, cached completion items become
    -- stale until the user's next [[ input triggers a rebuild.
    vim.api.nvim_create_autocmd("User", {
      pattern = "VaultCacheInvalidate",
      callback = function()
        if not cache_valid() and vim.bo.filetype == "markdown" then
          local sched = require("andrew.vault.work_scheduler")
          sched.schedule(sched.DEFERRED, function()
            build_items_async()
          end, { domain = "completion", label = "cache-rewarm" })
        end
      end,
    })

    return self
  end

  function source:enabled()
    return vim.bo.filetype == "markdown"
  end

  function source:get_completions(ctx, callback)
    local scheduler = require("andrew.vault.work_scheduler")

    -- If the source provides a custom get_completions, use it
    if opts.get_completions then
      if cache_valid() then
        -- Cache hit: CRITICAL — return immediately, no scheduling overhead
        _cache_hits = _cache_hits + 1
        scheduler.schedule(scheduler.CRITICAL, function()
          opts.get_completions(self, ctx, cached_items, callback)
        end, { domain = "completion", label = "cache-hit" })
        return
      end
      -- Cache miss: NORMAL priority — ahead of DEFERRED background work
      _cache_misses = _cache_misses + 1
      local inner_cancel
      scheduler.schedule(scheduler.NORMAL, function()
        local stop = require("andrew.vault.memory_profiler").start_timer("completion." .. source_name .. ".build")
        inner_cancel = build_items_async(function(items)
          stop()
          opts.get_completions(self, ctx, items or {}, callback)
        end)
      end, { domain = "completion", label = "active-build" })
      -- Return a cancel function that cancels both scheduler domain and inner build
      return function()
        scheduler.cancel_domain("completion")
        if inner_cancel then inner_cancel() end
      end
    end

    -- All sources must provide opts.get_completions.
    log:warn("source %s missing get_completions", source_name)
    callback(M.empty_response)
  end

  -- Passthrough resolve_item if the source defines it
  if opts.resolve_item then
    function source:resolve(item, callback)
      opts.resolve_item(self, item, callback)
    end
  end

  return source
end

--- Shared empty completion response (avoids duplication across sources).
M.empty_response = { is_incomplete_forward = false, is_incomplete_backward = false, items = {} }

--- Build a standard completion response wrapping an items array.
--- @param items table[]
--- @return table
function M.response(items)
  return { is_incomplete_forward = false, is_incomplete_backward = false, items = items }
end

--- Get the current vault index if ready, or nil.
--- Convenience helper to avoid duplicating the lookup + readiness check in every source.
--- @return VaultIndex|nil
function M.get_ready_index()
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if idx and idx:is_ready() then return idx end
  return nil
end

--- Format a count as "N note(s)" for label descriptions.
--- @param count number
--- @return string
function M.count_label(count)
  return count .. " note" .. (count == 1 and "" or "s")
end

--- Format a sortText string for frequency-based sorting (descending).
--- @param count number
--- @param name string
--- @return string
function M.freq_sort_text(count, name)
  return string.format("%05d", 99999 - count) .. name
end

--- Return the shared known field values table used by frontmatter and inline field completions.
--- @return table<string, string[]>
function M.known_field_values()
  return {
    status = config.status_values,
    priority = vim.tbl_map(tostring, config.priority_values),
    maturity = config.maturity_values,
    type = config.note_types,
  }
end

--- Look up value completion items for a given field key.
--- Shared helper for frontmatter and inline field sources.
--- @param items table  { names: table[], values: table<string, table[]> }
--- @param key string  Field key to look up
--- @return table[]
function M.field_value_items(items, key)
  return items.values and items.values[key] or {}
end

--- Single-pass field value accumulation and item building.
--- Iterates idx.files once, building both name_items and value_items simultaneously
--- without an intermediate field_values table.
--- Results are memoized per (vault_path, field_name, generation).
--- @param idx VaultIndex  Ready vault index
--- @param field_name string  Entry field to read ("frontmatter" or "inline_fields")
--- @param known_vals table<string, string[]>  Preset values to merge per field
--- @param separator string  Inserted after field name (": " or ":: ")
--- @return table  { names: table[], values: table<string, table[]> }
function M.build_kv_single_pass(idx, field_name, known_vals, separator)
  local vault_path = idx.vault_path or ""
  local cache_key = vault_path .. "\0" .. field_name
  local gen = idx._generation or 0

  local cached = _field_cache[cache_key]
  if filter_utils.is_cache_gen_valid(cached, gen) then
    return cached.result
  end

  local field_counts = {} -- key -> count
  local value_items_by_key = {} -- key -> { value_string -> item }
  local item_index = {} -- key -> { value_string -> item } for O(1) updates

  --- Upsert a value string into the index/items for a given field key.
  local function upsert_value(s, key_idx, key_items, initial_count)
    local existing = key_idx[s]
    if existing then
      existing._count = existing._count + 1
    else
      local new_item = M.make_item(s, s, s, M.KIND.Value)
      new_item._count = initial_count
      key_idx[s] = new_item
      key_items[#key_items + 1] = new_item
    end
  end

  --- Ensure index/items tables exist for a field key, return them.
  local function ensure_key(key)
    if not item_index[key] then
      item_index[key] = {}
      value_items_by_key[key] = {}
    end
    return item_index[key], value_items_by_key[key]
  end

  -- Snapshot for consistent reads during single-pass build.
  local snap_files = idx:snapshot_files()
  for _, entry in pairs(snap_files) do
    local fields = entry[field_name]
    if fields then
      for key, val in pairs(fields) do
        field_counts[key] = (field_counts[key] or 0) + 1
        local key_idx, key_items = ensure_key(key)

        if type(val) == "table" then
          for _, item in ipairs(val) do
            local s = type(item) == "string" and item or tostring(item)
            if s ~= "" then upsert_value(s, key_idx, key_items, 1) end
          end
        else
          local s = type(val) == "string" and val or tostring(val)
          if s ~= "" then upsert_value(s, key_idx, key_items, 1) end
        end
      end
    end
  end

  -- Merge in preset values that weren't seen in index data
  for key, presets in pairs(known_vals) do
    local key_idx, key_items = ensure_key(key)
    for _, v in ipairs(presets) do
      local s = type(v) == "string" and v or tostring(v)
      if not key_idx[s] then upsert_value(s, key_idx, key_items, 0) end
    end
  end

  -- Finalize value items: set sortText, labelDetails, remove _count; sort alphabetically
  for _, items in pairs(value_items_by_key) do
    for i, item in ipairs(items) do
      local count = item._count
      item.sortText = M.freq_sort_text(count, item.label)
      item.labelDetails = { description = count > 0 and M.count_label(count) or "suggested" }
      item._count = nil
      items[i] = item
    end
    table.sort(items, function(a, b) return a.label < b.label end)
  end

  -- Build name_items from accumulated field_counts
  local sorted_names = {}
  for name in pairs(field_counts) do
    sorted_names[#sorted_names + 1] = name
  end
  table.sort(sorted_names)

  local name_items = {}
  for _, name in ipairs(sorted_names) do
    local count = field_counts[name]
    name_items[#name_items + 1] = M.make_item(name, name .. separator, name, M.KIND.Variable, {
      sortText = M.freq_sort_text(count, name),
      description = M.count_label(count),
    })
  end

  local result = { names = name_items, values = value_items_by_key }
  _field_cache[cache_key] = { gen = gen, result = result }
  return result
end

--- Return a build function for key-value field sources (frontmatter, inline fields).
--- Uses build_kv_single_pass for single-iteration item building with memoization.
--- @param field_name string  Entry field to read ("frontmatter" or "inline_fields")
--- @param separator string  Inserted after field name (": " or ":: ")
--- @return fun(vault_path: string, callback: fun(items: table))
function M.build_kv_fields(field_name, separator)
  return function(vault_path, callback)
    local idx = M.get_ready_index()
    if not idx then
      callback({ names = {}, values = {} })
      return
    end
    callback(M.build_kv_single_pass(idx, field_name, M.known_field_values(), separator))
  end
end

--- Create a get_completions handler for key-value field sources.
--- The matcher function receives (before, ctx, bufnr) and returns:
---   string key → value completion for that key
---   false      → name completion (field key suggestions)
---   nil        → no completion (empty response)
--- @param matchers fun(before: string, ctx: table, bufnr: number): string|false|nil
--- @return fun(self: table, ctx: table, items: table, callback: fun(response: table))
function M.kv_get_completions(matchers)
  return function(self, ctx, items, callback)
    local col = ctx.cursor[2]
    local before = ctx.line:sub(1, col)
    local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()

    local key = matchers(before, ctx, bufnr)
    if key then
      callback(M.response(M.field_value_items(items, key)))
    elseif key == false then
      callback(M.response(items.names or {}))
    else
      callback(M.empty_response)
    end
  end
end

--- Collect debug info for all registered completion sources.
--- @return string[]  Lines suitable for notify.info_lines()
function M.debug_info()
  local lines = {
    "Completion Debug",
    string.rep("=", config.ui.status_separator_width),
    "  Registered sources: " .. #all_invalidators,
    "  Config: debounce_ms=" .. conf("debounce_ms", 250)
      .. ", batch_size=" .. conf("batch_size", 50),
  }

  -- Vault index generation
  local vault_index = package.loaded["andrew.vault.vault_index"]
  if vault_index then
    local idx = vault_index.current()
    if idx then
      lines[#lines + 1] = "  Index generation: " .. idx._generation
        .. " (" .. idx:file_count() .. " files)"
    else
      lines[#lines + 1] = "  Index: not initialized"
    end
  end

  lines[#lines + 1] = ""

  -- Config additions
  local max_items = conf("max_items", 10000)
  local intern = conf("intern_descriptions", nil)
  lines[#lines + 1] = "  max_items=" .. max_items
    .. ", intern_descriptions=" .. tostring(intern ~= false)
  lines[#lines + 1] = ""

  -- Estimated bytes per item by source type
  local EST_BYTES = { wikilinks = 350, vault_tags = 100, vault_frontmatter = 100, vault_inline_fields = 80 }

  -- Per-source stats
  for name, stats_fn in pairs(all_source_stats) do
    local s = stats_fn()
    lines[#lines + 1] = "  [" .. name .. "]"
    local est_per = EST_BYTES[name] or 200
    local est_kb = s.item_count * est_per / 1024
    lines[#lines + 1] = "    Cache: " .. (s.cached and (s.item_count .. " items (~" .. string.format("%.0f", est_kb) .. " KB est)") or "empty")
    lines[#lines + 1] = "    Data fields: rel_path only (abs_path derived)"
    lines[#lines + 1] = "    State: " .. s.state
    lines[#lines + 1] = "    Mode: " .. (s.uses_build_iter and "coroutine (build_iter)" or "legacy (build)")
    lines[#lines + 1] = "    Generation: cache=" .. tostring(s._cached_gen)
      .. ", invalidation=" .. s.build_generation
    if s.last_build_ms then
      local ago = s.last_build_time and (os.time() - s.last_build_time) or nil
      lines[#lines + 1] = "    Last build: " .. string.format("%.1fms", s.last_build_ms)
        .. (ago and (" (" .. ago .. "s ago)") or "")
    end
    -- Description pool stats (wikilinks source only)
    if name == "wikilinks" then
      local wl = package.loaded["andrew.vault.completion"]
      if wl and wl.desc_pool_stats then
        local ps = wl.desc_pool_stats()
        local pct = ps.total > 0 and string.format("%.0f%%", (1 - ps.unique / ps.total) * 100) or "n/a"
        lines[#lines + 1] = "    Description pool: " .. ps.unique .. " unique / " .. ps.total .. " total (" .. pct .. " dedup)"
      end
    end
  end

  return lines
end

return M
