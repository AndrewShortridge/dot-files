--- Consolidated highlight coordinator.
---
--- Registers a single set of autocmds (TextChanged, BufEnter, WinScrolled, etc.)
--- and dispatches to all registered highlight updaters via a single debounce timer
--- per buffer. Shares code exclusion and frontmatter data across all updaters to
--- avoid redundant treesitter parses.

local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local SlotMap = require("andrew.vault.slot_map")
local link_scan = require("andrew.vault.link_scan")
local cleanup = require("andrew.vault.resource_cleanup")
local render_arena = require("andrew.vault.render_arena")
local viewport = require("andrew.vault.viewport")
local watch = require("andrew.vault.watch_channel")
local log = require("andrew.vault.vault_log").scope("hl_coord")

local notify = require("andrew.vault.notify")

local M = {}

--- Clear extmarks for a namespace from a buffer (optionally scoped to a range).
--- Shared utility to replace duplicate `clear()` functions in highlight modules.
---@param ns number namespace id
---@param bufnr number
---@param start_line? number 0-indexed start (nil = full buffer)
---@param end_line? number exclusive end (nil = full buffer)
local function clear_extmarks(ns, bufnr, start_line, end_line)
  if start_line and end_line then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, start_line, end_line)
  else
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

--- Create a toggle function for a highlight module.
---@param mod table module table with `enabled` and `ns` fields
---@param feature_name string display name for notify.toggle
---@return fun()
function M.make_toggle(mod, feature_name)
  return function()
    mod.enabled = not mod.enabled
    if mod.enabled then
      -- Trigger a full pipeline run for the current buffer
      -- so the consumer (which checks mod.enabled) re-renders.
      local bufnr = vim.api.nvim_get_current_buf()
      M.schedule(bufnr, { full = true })
    else
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        clear_extmarks(mod.ns, buf)
      end
    end
    notify.toggle(feature_name, mod.enabled)
  end
end

--- Create a jump function for navigating between positions in a buffer.
--- get_positions_fn receives a bufnr and returns a sorted list of {row, col}
--- where row is 1-indexed and col is 1-indexed (cursor col = col - 1).
---@param get_positions_fn fun(bufnr: number): table[]
---@return fun(direction: 1|-1)
function M.make_jump(get_positions_fn)
  return function(direction)
    local bufnr = vim.api.nvim_get_current_buf()
    local positions = get_positions_fn(bufnr)
    if #positions == 0 then return end

    local cur_row, cur_col = unpack(vim.api.nvim_win_get_cursor(0))
    cur_col = cur_col + 1

    if direction == 1 then
      for _, p in ipairs(positions) do
        if p.row > cur_row or (p.row == cur_row and p.col > cur_col) then
          vim.api.nvim_win_set_cursor(0, { p.row, p.col - 1 })
          return
        end
      end
      vim.api.nvim_win_set_cursor(0, { positions[1].row, positions[1].col - 1 })
    else
      for j = #positions, 1, -1 do
        local p = positions[j]
        if p.row < cur_row or (p.row == cur_row and p.col < cur_col) then
          vim.api.nvim_win_set_cursor(0, { p.row, p.col - 1 })
          return
        end
      end
      local last = positions[#positions]
      vim.api.nvim_win_set_cursor(0, { last.row, last.col - 1 })
    end
  end
end

--- Get positions from a changedtick-validated cache, scanning on miss.
---@param cache_table table bufnr -> { tick, positions } cache
---@param bufnr number
---@param scan_fn fun(bufnr: number): table[] scanner that returns positions
---@return table[] positions
local function cached_positions(cache_table, bufnr, scan_fn)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = cache_table[bufnr]
  if cached and cached.tick == tick then
    return cached.positions
  end
  local positions = scan_fn(bufnr)
  cache_table[bufnr] = { tick = tick, positions = positions }
  return positions
end

--- Get an arbitrary value from a changedtick-validated cache, computing on miss.
--- Generic version of cached_positions() for non-position data (e.g. footnote maps).
---@param cache_table table bufnr -> { tick, value } cache
---@param bufnr number
---@param compute_fn fun(bufnr: number): any function that computes the cached value
---@return any value
function M.cached_value(cache_table, bufnr, compute_fn)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = cache_table[bufnr]
  if cached and cached.tick == tick then
    return cached.value
  end
  local value = compute_fn(bufnr)
  cache_table[bufnr] = { tick = tick, value = value }
  return value
end

--- Register a BufDelete autocmd that clears extmarks and optional caches.
---@param group number augroup id
---@param ns number namespace id
---@param cache_tables table[] list of cache tables to clear [bufnr] entries from
function M.setup_buf_cleanup(group, ns, cache_tables)
  cleanup.on_buf_delete(group, function(bufnr)
    clear_extmarks(ns, bufnr)
    for _, cache in ipairs(cache_tables) do
      cache[bufnr] = nil
    end
  end, { pattern = "*.md" })
end

--- Create and register a VaultXXXRefresh user command.
---@param name string command name (e.g. "VaultHighlightRefresh")
---@param desc string command description
function M.make_refresh_command(name, desc)
  vim.api.nvim_create_user_command(name, function()
    local bufnr = vim.api.nvim_get_current_buf()
    M.schedule(bufnr, { full = true })
  end, { desc = desc })
end

--- Create navigation functions (get_positions + jump) for a highlight module.
---@param nav_cache table bufnr -> { tick, positions } cache
---@param scan_fn fun(bufnr: number): table[] full-buffer position scanner
---@return fun(direction: 1|-1) jump function
local function make_scanner_nav(nav_cache, scan_fn)
  local function get_positions(bufnr)
    return cached_positions(nav_cache, bufnr, scan_fn)
  end
  return M.make_jump(get_positions)
end

--- Create a scanner-based nav function with standard boilerplate.
--- Wraps the common pattern: get full buffer lines → build code exclusion →
--- get frontmatter range → scan → collect {row, col} positions.
---@param nav_cache table bufnr -> { tick, positions } cache
---@param scan_fn fun(lines: string[], start: number, code_excl: fun, fm_start: number|nil, fm_end: number|nil, callback: fun(...))
---@param pos_from_callback fun(...): number, number extracts (row_1indexed, col_1indexed) from scan callback args
---@return fun(direction: 1|-1) jump function
function M.make_scan_nav(nav_cache, scan_fn, pos_from_callback)
  return make_scanner_nav(nav_cache, function(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local is_in_code = link_scan.build_code_exclusion(bufnr)
    local fm_start, fm_end = link_scan.get_frontmatter_range(bufnr)
    local positions = {}
    scan_fn(lines, 0, is_in_code, fm_start, fm_end, function(...)
      local row1, col1 = pos_from_callback(...)
      positions[#positions + 1] = { row = row1, col = col1 }
    end)
    return positions
  end)
end

--- Register forward/backward navigation keymaps for a buffer.
---@param ev table autocmd event args (needs ev.buf)
---@param jump_fn fun(direction: 1|-1) jump function from make_scan_nav or make_jump
---@param forward_key string e.g. "]h"
---@param backward_key string e.g. "[h"
---@param forward_desc string e.g. "Next ==highlight=="
---@param backward_desc string e.g. "Previous ==highlight=="
function M.register_nav_keymaps(ev, jump_fn, forward_key, backward_key, forward_desc, backward_desc)
  vim.keymap.set("n", forward_key, function() jump_fn(1) end, {
    buffer = ev.buf,
    desc = forward_desc,
    silent = true,
  })
  vim.keymap.set("n", backward_key, function() jump_fn(-1) end, {
    buffer = ev.buf,
    desc = backward_desc,
    silent = true,
  })
end

---@class HLUpdater
---@field fn fun(bufnr: number, code_excl: fun, opts: table)
---@field name string
---@field priority number
---@field enabled fun(): boolean

---@type HLUpdater[]
local _updaters = {}

local FrameCache = require("andrew.vault.frame_cache")

local _hl_entities = SlotMap.new({
  name = "highlight",
  leak_detect = config.slot_map.leak_detect,
})
local _hl_handles = {} -- bufnr -> handle

---@return table record { bufnr, channel, cache }
local function get_hl_state(bufnr)
  return _hl_entities:get_or_insert(bufnr, _hl_handles, function(b)
    return { bufnr = b, channel = nil, cache = nil }
  end)
end

local function get_cache(bufnr)
  local st = get_hl_state(bufnr)
  if not st.cache then
    local cfg = require("andrew.vault.config")
    if not cfg.render_cache.enabled then return nil end
    st.cache = FrameCache.new({
      max_entries = cfg.render_cache.max_entries_per_frame,
    })
  end
  return st.cache
end

local _augroup = nil

--- Register a highlight updater function.
--- The updater receives shared code_excl and opts (full = bool).
---@param name string module name for debugging
---@param fn fun(bufnr: number, code_excl: fun, opts: table) updater function
---@param enabled fun(): boolean function returning whether module is enabled
---@param priority? number execution order (lower = first, default 50)
---@param opts? { supports_prefetch?: boolean } optional flags
function M.register(name, fn, enabled, priority, opts)
  opts = opts or {}
  _updaters[#_updaters + 1] = {
    fn = fn,
    name = name,
    priority = priority or 50,
    enabled = enabled,
    supports_prefetch = opts.supports_prefetch or false,
  }
  table.sort(_updaters, function(a, b) return a.priority < b.priority end)
end

-- Forward declaration: run_all is defined below get_channel/schedule but
-- referenced in the watch channel subscriber and scheduler callback.
local run_all

--- Get or create a watch channel for a buffer.
---@param bufnr number
---@return { send: fun(opts: table), handle: WatchChannelHandle }
local function get_channel(bufnr)
  local st = get_hl_state(bufnr)
  if not st.channel then
    local send, handle = watch.new(nil)
    handle.subscribe(function(opts)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        st.channel.handle.close()
        st.channel = nil
        return
      end
      run_all(bufnr, opts or {})
    end)
    st.channel = { send = send, handle = handle }
  end
  return st.channel
end

--- Schedule a coordinated update for a buffer.
--- Current buffer uses watch-style coalescing (0ms latency, next tick).
--- Non-current buffers use DEFERRED priority via work scheduler.
---@param bufnr number
---@param opts table { full = bool }
function M.schedule(bufnr, opts)
  opts = opts or {}

  local current_buf = vim.api.nvim_get_current_buf()

  if bufnr == current_buf then
    -- Current buffer: existing watch_channel path (NORMAL equivalent, ~0ms coalesce)
    local ch = get_channel(bufnr)
    ch.send(opts)
  else
    -- Non-current buffer: DEFERRED (user isn't looking at it)
    local scheduler = require("andrew.vault.work_scheduler")
    scheduler.cancel_domain("highlight:" .. bufnr)
    scheduler.schedule(scheduler.DEFERRED, function()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      run_all(bufnr, opts)
    end, { domain = "highlight:" .. bufnr, label = "adjacent-hl" })
  end
end

--- Execute all registered updaters for a buffer.
--- Wraps all updaters in a shared arena scope for ephemeral allocations.
---@param bufnr number
---@param opts table
function run_all(bufnr, opts)
  local stop = require("andrew.vault.memory_profiler").start_timer("hl_coord.run_all")
  local arena_scope = render_arena.begin_scope()
  opts.arena = arena_scope
  opts.frame_cache = get_cache(bufnr)

  -- Inject invalid ranges for coordinated updaters (scoped to "hl_coord")
  local region_tracker = require("andrew.vault.region_tracker")
  local tracker = region_tracker.get(bufnr, "hl_coord")
  opts.invalid_ranges = tracker:get_invalid_ranges()

  local ok, err = pcall(function()
    -- Build shared context once (cached per changedtick)
    local code_excl = link_scan.build_code_exclusion(bufnr)

    local pipeline = require("andrew.vault.transform_pipeline")
    pipeline.attach(bufnr) -- idempotent
    pipeline.run(bufnr, code_excl, opts)
    -- Also dispatch updaters not covered by pipeline consumers
    -- (e.g., inline_fields, autolink)
    for _, updater in ipairs(_updaters) do
      if updater.enabled() and not pipeline.is_updater_covered(updater.name) then
        local ok2, err2 = pcall(updater.fn, bufnr, code_excl, opts)
        if not ok2 then
          log.warn("error in %s: %s", updater.name, err2)
        end
      end
    end
  end)

  -- Mark processed ranges as valid only on success
  if ok and opts.invalid_ranges then
    region_tracker.mark_ranges_valid(bufnr, opts.invalid_ranges, "hl_coord")
  end

  render_arena.end_scope(arena_scope)
  if opts.frame_cache then opts.frame_cache:finish_frame() end
  opts.arena = nil
  stop()
  if not ok then
    log.warn("run_all failed: %s", err)
  end
end

--- Run prefetch rendering for a line range.
--- Only dispatches to modules that support range-based rendering.
--- Also calls embed.on_prefetch() directly (embed is not a registered updater).
--- Follows run_all() pattern: arena scope + frame_cache for consistency.
--- @param bufnr number
--- @param start_line number 1-indexed
--- @param end_line number 1-indexed
local function run_prefetch(bufnr, start_line, end_line)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local stop = require("andrew.vault.memory_profiler").start_timer("hl_coord.run_prefetch")

  local arena_scope = render_arena.begin_scope()
  local fc = get_cache(bufnr)

  local ok, err = pcall(function()
    local pipeline = require("andrew.vault.transform_pipeline")
    for _, updater in ipairs(_updaters) do
      if updater.enabled() and updater.supports_prefetch
        and not pipeline.is_updater_covered(updater.name) then
        local ok2, err2 = pcall(updater.fn, bufnr, nil, {
          full = false,
          prefetch = true,
          start_line = start_line,
          end_line = end_line,
          arena = arena_scope,
          frame_cache = fc,
        })
        if not ok2 then
          log.warn("prefetch error in %s: %s", updater.name, err2)
        end
      end
    end

    -- Dispatch to embed directly (not a registered updater)
    local embed_ok, embed = pcall(require, "andrew.vault.embed")
    if embed_ok and embed.on_prefetch then
      local ok2, err2 = pcall(embed.on_prefetch, bufnr, start_line, end_line)
      if not ok2 then
        log.warn("prefetch error in embed: %s", err2)
      end
    end
  end)

  render_arena.end_scope(arena_scope)
  stop()
  if not ok then log.warn("run_prefetch failed: %s", err) end
end

-- Deferred profiler registration (safe: profiler may not be loaded yet)
do
  local ok, profiler = pcall(require, "andrew.vault.memory_profiler")
  if ok then
    profiler.register_counter_deferred({
      name = "hl_entities",
      get_count = function()
        return _hl_entities:len()
      end,
      description = "highlight coordinator per-buffer slot map entities",
    })
    profiler.register_counter_deferred({
      name = "hl_frame_caches",
      get_count = function()
        local count = 0
        for _, val in _hl_entities:iter() do
          if val.cache then count = count + val.cache:size() end
        end
        return count
      end,
      description = "highlight coordinator per-buffer dual-frame render caches",
    })
  end
end

--- Clean up per-buffer highlight state (channel + viewport).
--- Shared between BufDelete and VimLeavePre teardown.
---@param bufnr number
---@param st table state record from _hl_entities
local function cleanup_hl_state(bufnr, st)
  if st.channel then
    st.channel.handle.close()
  end
  viewport.clear_state(bufnr)
end

function M.setup()
  _augroup = vim.api.nvim_create_augroup("VaultHighlightCoordinator", { clear = true })

  -- Render on buffer enter: viewport-only for large files, full for small files
  vim.api.nvim_create_autocmd("BufEnter", {
    group = _augroup,
    pattern = "*.md",
    callback = function(ev)
      if engine.is_vault_buf(ev.buf) then
        local line_count = vim.api.nvim_buf_line_count(ev.buf)
        local full = line_count <= config.viewport.full_buffer_threshold
        M.schedule(ev.buf, { full = full })
      end
    end,
  })

  -- Viewport-only render on scroll (Phase 1: visible, Phase 2: prefetch zones)
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = _augroup,
    callback = function()
      local bufnr = vim.api.nvim_get_current_buf()
      if vim.bo[bufnr].filetype == "markdown"
        and engine.is_vault_buf(bufnr)
      then
        -- Phase 1: Visible zone (existing behavior, 200ms debounce)
        M.schedule(bufnr, { full = false })

        -- Phase 2: Prefetch zones (400ms debounce, both zones equal priority)
        local winid = vim.api.nvim_get_current_win()
        local zones = viewport.get_zones(winid)
        local above_changed, below_changed =
          viewport.prefetch_zones_changed(bufnr, winid, zones)

        if above_changed and zones.above.end_line >= zones.above.start_line then
          viewport.schedule_prefetch(bufnr, winid, "above", function()
            run_prefetch(bufnr, zones.above.start_line, zones.above.end_line)
          end)
        end

        if below_changed and zones.below.end_line >= zones.below.start_line then
          viewport.schedule_prefetch(bufnr, winid, "below", function()
            run_prefetch(bufnr, zones.below.start_line, zones.below.end_line)
          end)
        end
      end
    end,
  })

  -- Re-render on cache invalidation
  vim.api.nvim_create_autocmd("User", {
    pattern = "VaultCacheInvalidate",
    callback = function(ev)
      local data = ev.data or {}
      local bufnr = vim.api.nvim_get_current_buf()
      if not vim.api.nvim_buf_is_valid(bufnr)
        or vim.bo[bufnr].filetype ~= "markdown"
      then
        return
      end
      if not engine.is_vault_buf(bufnr) then return end
      local bufname = vim.api.nvim_buf_get_name(bufnr)

      local filter_utils = require("andrew.vault.filter_utils")
      if not filter_utils.should_invalidate_buffer(data, bufname) then return end

      -- Clear frame cache before re-render: cache keys don't include content
      -- hashes, so stale virt_lines would be served if target content changed.
      local st = _hl_entities:try_get(bufnr, _hl_handles)
      if st and st.cache then st.cache:clear() end

      -- Invalidate all regions across all scopes so renderers do a full re-render
      local region_tracker = require("andrew.vault.region_tracker")
      local bt = region_tracker.get_buffer(bufnr)
      if bt then bt:invalidate_all_scopes() end

      M.schedule(bufnr, { full = true })
    end,
  })

  -- Clean up channels and pipeline state on buffer delete
  cleanup.on_buf_delete(_augroup, function(bufnr)
    local st = _hl_entities:remove_by_key(bufnr, _hl_handles)
    if st then
      cleanup_hl_state(bufnr, st)
    end
    local pipeline = require("andrew.vault.transform_pipeline")
    pipeline.detach(bufnr)
    local region_tracker = require("andrew.vault.region_tracker")
    region_tracker.remove(bufnr)
  end)

end

--- Called by event_dispatch.lua on BufWritePost for vault markdown buffers.
--- @param ctx { bufnr: number, file: string }
function M.on_buf_write(ctx)
  local line_count = vim.api.nvim_buf_line_count(ctx.bufnr)
  local full = line_count <= config.viewport.full_buffer_threshold
  M.schedule(ctx.bufnr, { full = full })
end

--- Called by event_dispatch.lua on VimLeavePre for cleanup.
function M.teardown()
  for _, val in _hl_entities:iter() do
    cleanup_hl_state(val.bufnr, val)
  end
  _hl_entities:destroy()
  _hl_handles = {}
end

--- Get the frame cache for a buffer (for debug commands).
---@param bufnr number
---@return table|nil
function M.get_frame_cache(bufnr)
  local st = _hl_entities:try_get(bufnr, _hl_handles)
  return st and st.cache or nil
end

--- Expose slot map for debug commands.
---@return SlotMap
function M._get_slot_map()
  return _hl_entities
end

-- Register with engine cache registry for :VaultCacheDebug visibility
_hl_entities:register_with_engine({
  name = "highlight_slotmap",
  module = "andrew.vault.highlight_coordinator",
  invalidate = function()
    -- Slot map entries are lifecycle-managed; invalidation = clear all caches
    for _, val in _hl_entities:iter() do
      if val.cache then val.cache:clear() end
    end
  end,
})

return M
