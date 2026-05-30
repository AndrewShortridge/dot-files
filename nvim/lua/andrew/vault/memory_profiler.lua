--- Memory profiling infrastructure for the vault plugin.
--- Collects and displays cache hit rates, resource counts, operation timings,
--- and GC pressure metrics. All public functions are no-ops when disabled.
---
--- Dependencies: vault_log (health warnings), config (thresholds),
--- resource_cleanup (timer teardown). All other modules depend on this
--- (one-way dependency via register_* calls).
--- @module andrew.vault.memory_profiler

local M = {}

local _enabled = false
local _caches = {} ---@type table<string, ProfilerCacheSpec>
local _counters = {} ---@type table<string, ProfilerCounterSpec>
local _timings = {} ---@type table<string, { calls: number, total_ms: number, max_ms: number, window_start: number }>
local _snapshots = {} ---@type table[]
local _gc_samples = {} ---@type { timestamp: number, lua_kb: number }[]
local _health_timer = nil
local _gc_timer = nil
local _gc_sample_interval_ms = 5000
local _gc_sample_max = 720

---@class ProfilerCacheSpec
---@field name string           Must match engine cache registry name
---@field get_size fun(): number
---@field get_capacity fun(): number|nil  nil = unbounded
---@field get_hits fun(): number
---@field get_misses fun(): number
---@field get_evictions fun(): number
---@field get_generation fun(): number|nil
---@field get_bytes fun(): number|nil      Current byte weight (memory-weighted caches)
---@field get_max_bytes fun(): number|nil   Byte budget (memory-weighted caches)

---@class ProfilerCounterSpec
---@field name string
---@field get_count fun(): number
---@field description string

--- No-op guard used by all public functions.
local function noop_guard()
  return not _enabled
end

-- ───────────────────────────────────────────────────────────────────────────
-- Initialization
-- ───────────────────────────────────────────────────────────────────────────

--- Initialize the profiler. Called from engine.lua setup.
---@param opts { enable: boolean, health_check_interval_s: number, gc_sample_interval_ms: number, gc_sample_max: number, alert_memory_growth_mb: number, alert_hit_rate_min: number }
function M.init(opts)
  _enabled = opts.enable
  if not _enabled then return end
  _gc_sample_interval_ms = opts.gc_sample_interval_ms or 5000
  _gc_sample_max = opts.gc_sample_max or 720
  M._start_gc_sampling()
  if (opts.health_check_interval_s or 0) > 0 then
    M._start_health_check(opts.health_check_interval_s, opts)
  end
end

-- ───────────────────────────────────────────────────────────────────────────
-- 1. Cache Registry
-- ───────────────────────────────────────────────────────────────────────────

--- Register a cache for profiling.
---@param spec ProfilerCacheSpec
function M.register_cache(spec)
  if noop_guard() then return end
  assert(spec.name and spec.get_size and spec.get_hits and spec.get_misses,
    "profiler cache spec requires name, get_size, get_hits, get_misses")
  _caches[spec.name] = spec
end

-- ───────────────────────────────────────────────────────────────────────────
-- 2. Resource Counters
-- ───────────────────────────────────────────────────────────────────────────

--- Register a resource counter.
---@param spec ProfilerCounterSpec
function M.register_counter(spec)
  if noop_guard() then return end
  _counters[spec.name] = spec
end

--- Deferred counter registration — safe to call at module load time.
--- Schedules the registration on the next event loop tick via vim.schedule.
---@param spec ProfilerCounterSpec
function M.register_counter_deferred(spec)
  vim.schedule(function()
    M.register_counter(spec)
  end)
end

-- ───────────────────────────────────────────────────────────────────────────
-- 3. Operation Timing
-- ───────────────────────────────────────────────────────────────────────────

local _noop_stop = function() end

--- Start timing an operation. Returns a stop function.
---@param name string  Operation name (e.g., "index.build_async")
---@return fun()  Call this to record the elapsed time
function M.start_timer(name)
  if noop_guard() then return _noop_stop end
  local start = vim.uv.hrtime()
  return function()
    local elapsed_ms = (vim.uv.hrtime() - start) / 1e6
    local entry = _timings[name]
    if not entry then
      entry = { calls = 0, total_ms = 0, max_ms = 0, window_start = os.time() }
      _timings[name] = entry
    end
    entry.calls = entry.calls + 1
    entry.total_ms = entry.total_ms + elapsed_ms
    if elapsed_ms > entry.max_ms then entry.max_ms = elapsed_ms end
  end
end

--- Reset timing window (called by dashboard to show "last N seconds").
function M.reset_timings()
  if noop_guard() then return end
  for _, entry in pairs(_timings) do
    entry.calls = 0
    entry.total_ms = 0
    entry.max_ms = 0
    entry.window_start = os.time()
  end
end

-- ───────────────────────────────────────────────────────────────────────────
-- 4. GC Pressure Metrics
-- ───────────────────────────────────────────────────────────────────────────

function M._start_gc_sampling()
  local cleanup = require("andrew.vault.resource_cleanup")
  _gc_timer = cleanup.repeating(_gc_timer, 0, _gc_sample_interval_ms, function()
    local kb = collectgarbage("count")
    _gc_samples[#_gc_samples + 1] = { timestamp = os.time(), lua_kb = kb }
    if #_gc_samples > _gc_sample_max then
      table.remove(_gc_samples, 1)
    end
  end)
end

--- Get current memory info.
---@return { lua_kb: number, delta_kb: number, samples: number, growth_rate_kb_per_min: number }
function M.memory_info()
  if noop_guard() then return { lua_kb = 0, delta_kb = 0, samples = 0, growth_rate_kb_per_min = 0 } end
  local current_kb = collectgarbage("count")
  local first = _gc_samples[1]
  local delta_kb = first and (current_kb - first.lua_kb) or 0
  local elapsed_min = first and ((os.time() - first.timestamp) / 60) or 0
  local rate = elapsed_min > 0 and (delta_kb / elapsed_min) or 0
  return {
    lua_kb = current_kb,
    delta_kb = delta_kb,
    samples = #_gc_samples,
    growth_rate_kb_per_min = rate,
  }
end

-- ───────────────────────────────────────────────────────────────────────────
-- 5. Snapshot & Diff
-- ───────────────────────────────────────────────────────────────────────────

--- Take a snapshot of current profiler state.
---@return table snapshot
function M.snapshot()
  if noop_guard() then return {} end
  local snap = {
    timestamp = os.time(),
    lua_kb = collectgarbage("count"),
    caches = {},
    counters = {},
    timings = vim.deepcopy(_timings),
  }
  for name, spec in pairs(_caches) do
    snap.caches[name] = {
      size = spec.get_size(),
      capacity = spec.get_capacity and spec.get_capacity() or nil,
      hits = spec.get_hits(),
      misses = spec.get_misses(),
      evictions = spec.get_evictions(),
      bytes = spec.get_bytes and spec.get_bytes() or nil,
      max_bytes = spec.get_max_bytes and spec.get_max_bytes() or nil,
    }
  end
  for name, spec in pairs(_counters) do
    snap.counters[name] = spec.get_count()
  end
  _snapshots[#_snapshots + 1] = snap
  return snap
end

--- Diff current state against the last snapshot.
---@return table|nil diff  nil if no previous snapshot
function M.diff()
  if noop_guard() or #_snapshots == 0 then return nil end
  local prev = _snapshots[#_snapshots]
  local curr = M.snapshot()
  local result = {
    elapsed_s = curr.timestamp - prev.timestamp,
    lua_kb_delta = curr.lua_kb - prev.lua_kb,
    caches = {},
    counters = {},
  }
  for name, curr_c in pairs(curr.caches) do
    local prev_c = prev.caches[name]
    if prev_c then
      result.caches[name] = {
        size_delta = curr_c.size - prev_c.size,
        new_hits = curr_c.hits - prev_c.hits,
        new_misses = curr_c.misses - prev_c.misses,
        new_evictions = curr_c.evictions - prev_c.evictions,
        bytes_delta = (curr_c.bytes or 0) - (prev_c.bytes or 0),
      }
    end
  end
  for name, curr_count in pairs(curr.counters) do
    local prev_count = prev.counters[name] or 0
    result.counters[name] = curr_count - prev_count
  end
  return result
end

-- ───────────────────────────────────────────────────────────────────────────
-- 6. Periodic Health Check
-- ───────────────────────────────────────────────────────────────────────────

function M._start_health_check(interval_s, opts)
  local cleanup = require("andrew.vault.resource_cleanup")
  local log = require("andrew.vault.vault_log").scope("profiler")
  local prev_kb = collectgarbage("count")
  local threshold_mb = opts.alert_memory_growth_mb or 10
  local min_hit_rate = opts.alert_hit_rate_min or 0.5

  _health_timer = cleanup.repeating(_health_timer, interval_s * 1000, interval_s * 1000, function()
    local curr_kb = collectgarbage("count")
    local growth_mb = (curr_kb - prev_kb) / 1024

    -- Memory growth alert
    if growth_mb > threshold_mb then
      log.warn("Lua memory grew %.1f MB in last %ds (%.1f MB -> %.1f MB)",
        growth_mb, interval_s, prev_kb / 1024, curr_kb / 1024)
    end

    -- Cache hit rate alerts
    for name, spec in pairs(_caches) do
      local hits = spec.get_hits()
      local misses = spec.get_misses()
      local total = hits + misses
      if total > 100 then
        local rate = hits / total
        if rate < min_hit_rate then
          log.warn("Cache '%s' hit rate %.1f%% (below %.0f%% threshold)",
            name, rate * 100, min_hit_rate * 100)
        end
      end
    end

    -- Memory budget alerts for weighted caches
    for name, spec in pairs(_caches) do
      if spec.get_bytes and spec.get_max_bytes then
        local bytes = spec.get_bytes()
        local max_bytes = spec.get_max_bytes()
        if bytes and max_bytes and max_bytes > 0 then
          local utilization = bytes / max_bytes
          if utilization > 0.95 then
            log.warn("Cache '%s' at %.0f%% memory budget (%.1f MB / %.1f MB)",
              name, utilization * 100, bytes / (1024 * 1024), max_bytes / (1024 * 1024))
          end
        end
      end
    end

    prev_kb = curr_kb
  end)
end

-- ───────────────────────────────────────────────────────────────────────────
-- 7. Dashboard
-- ───────────────────────────────────────────────────────────────────────────

function M.render_dashboard()
  local lines = {}
  local function add(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
  local function sep() lines[#lines + 1] = "" end

  add("=== Vault Memory Profile ===")
  sep()

  -- Memory section
  local mem = M.memory_info()
  add("Lua Memory: %.1f MB (growth rate: %.1f KB/min)", mem.lua_kb / 1024, mem.growth_rate_kb_per_min)
  add("GC Samples: %d", mem.samples)
  sep()

  -- Caches section
  add("--- Caches ---")
  add("%-24s %12s %8s %10s %12s %5s", "Cache", "Size/Cap", "Hit%", "Evictions", "Bytes/Max", "Gen")
  local cache_names = {}
  for name in pairs(_caches) do cache_names[#cache_names + 1] = name end
  table.sort(cache_names)
  for _, name in ipairs(cache_names) do
    local spec = _caches[name]
    local size = spec.get_size()
    local cap = spec.get_capacity and spec.get_capacity()
    local hits = spec.get_hits()
    local misses = spec.get_misses()
    local total = hits + misses
    local hit_pct = total > 0 and string.format("%.1f%%", (hits / total) * 100) or "-"
    local evictions = spec.get_evictions()
    local gen = spec.get_generation and spec.get_generation()
    local bytes = spec.get_bytes and spec.get_bytes()
    local max_bytes = spec.get_max_bytes and spec.get_max_bytes()
    local cap_str = cap and tostring(cap) or "∞"
    local gen_str = gen and tostring(gen) or "-"
    local bytes_str = "-"
    if bytes and max_bytes and max_bytes > 0 then
      bytes_str = string.format("%.1f/%.1fM", bytes / (1024 * 1024), max_bytes / (1024 * 1024))
    end
    add("%-24s %5d/%-6s %8s %10d %12s %5s", name, size, cap_str, hit_pct, evictions, bytes_str, gen_str)
  end
  sep()

  -- Resources section
  add("--- Resources ---")
  add("%-32s %s", "Resource", "Count")
  local counter_names = {}
  for name in pairs(_counters) do counter_names[#counter_names + 1] = name end
  table.sort(counter_names)
  for _, name in ipairs(counter_names) do
    local spec = _counters[name]
    add("%-32s %d", name, spec.get_count())
  end
  sep()

  -- Timings section
  add("--- Operations (session) ---")
  add("%-28s %6s %9s %9s %10s", "Operation", "Calls", "Avg(ms)", "Max(ms)", "Total(ms)")
  local timing_names = {}
  for name in pairs(_timings) do timing_names[#timing_names + 1] = name end
  table.sort(timing_names)
  for _, name in ipairs(timing_names) do
    local entry = _timings[name]
    if entry.calls > 0 then
      local avg = entry.total_ms / entry.calls
      add("%-28s %6d %9.1f %9.1f %10.1f", name, entry.calls, avg, entry.max_ms, entry.total_ms)
    end
  end

  return lines
end

--- Open dashboard in a floating window.
function M.open_dashboard()
  if noop_guard() then
    vim.notify("Vault profiler is disabled. Set config.profiler.enable = true", vim.log.levels.WARN)
    return
  end
  local lines = M.render_dashboard()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "vault-profiler"

  local width = 110
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Vault Memory Profile ",
    title_pos = "center",
  })

  -- q to close
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, silent = true })
  -- R to refresh
  vim.keymap.set("n", "R", function()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.render_dashboard())
    vim.bo[buf].modifiable = false
  end, { buffer = buf, silent = true })
end

--- Render diff in a floating window.
function M.open_diff()
  if noop_guard() then
    vim.notify("Vault profiler is disabled. Set config.profiler.enable = true", vim.log.levels.WARN)
    return
  end
  local d = M.diff()
  if not d then
    vim.notify("No previous snapshot to diff against. Run :VaultMemorySnapshot first.", vim.log.levels.WARN)
    return
  end

  local lines = {}
  local function add(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
  local function sep() lines[#lines + 1] = "" end

  add("=== Memory Diff (last %ds) ===", d.elapsed_s)
  sep()
  add("Lua memory delta: %+.1f KB", d.lua_kb_delta)
  sep()

  add("--- Cache Deltas ---")
  add("%-24s %8s %8s %8s %10s %10s", "Cache", "Size Δ", "Hits", "Misses", "Evictions", "Bytes Δ")
  local names = {}
  for name in pairs(d.caches) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local c = d.caches[name]
    add("%-24s %+8d %8d %8d %10d %+10d",
      name, c.size_delta, c.new_hits, c.new_misses, c.new_evictions, c.bytes_delta)
  end
  sep()

  add("--- Counter Deltas ---")
  local cnames = {}
  for name in pairs(d.counters) do cnames[#cnames + 1] = name end
  table.sort(cnames)
  for _, name in ipairs(cnames) do
    add("%-32s %+d", name, d.counters[name])
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "vault-profiler"

  local width = 100
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Vault Memory Diff ",
    title_pos = "center",
  })

  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, silent = true })
end

-- ───────────────────────────────────────────────────────────────────────────
-- 8. Teardown
-- ───────────────────────────────────────────────────────────────────────────

function M.shutdown()
  local cleanup = require("andrew.vault.resource_cleanup")
  if _health_timer then
    cleanup.close_timer(_health_timer)
    _health_timer = nil
  end
  if _gc_timer then
    cleanup.close_timer(_gc_timer)
    _gc_timer = nil
  end
  _caches = {}
  _counters = {}
  _timings = {}
  _gc_samples = {}
  _snapshots = {}
  _enabled = false
end

return M
