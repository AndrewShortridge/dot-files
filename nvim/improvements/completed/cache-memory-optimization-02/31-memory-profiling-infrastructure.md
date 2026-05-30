# 31 — Memory Profiling Infrastructure

## Priority: MEDIUM
## Estimated Effort: Medium (new module + registration hooks in existing modules)
## Phase: 2 (Infrastructure — enables data-driven optimization)
## Dependencies: None (standalone, but benefits from 01-LRU and 02-bounded-caches)

## Problem

When investigating memory issues in the vault plugin, there is no unified view of
resource usage. Developers must add print statements and restart Neovim to understand
what is happening. Specific gaps:

1. **Limited cache hit/miss rates.** The engine cache registry (`engine._cache_registry`)
   tracks 18 caches with `invalidate`, optional `invalidate_file`, and optional `stats`
   callbacks. `CacheStats` reports `entries`, `age_seconds`, `vault`, `ttl`,
   `total_bytes`, `max_bytes`, and `utilization` — but only `file_cache.lua` tracks
   hit/miss rates. The remaining 17 caches have no hit rate, miss count, or eviction
   count — so there is no way to know if they are effective.

2. **No Lua memory visibility.** No module calls `collectgarbage("count")`, so there
   is no baseline for memory usage and no way to detect growth over time.

3. **No resource counting.** `resource_cleanup.lua` provides `close_timer`,
   `close_timer_in`, `debounce`, `repeating`, `weak_callback`, `subscription_handle`,
   and window/buffer/augroup cleanup — but does not track how many timers, autocmds,
   or coroutines are alive at any given moment. The 30 modules that require
   `resource_cleanup` each manage their own lifetimes independently. Per-buffer timer
   dictionaries exist in `autosave.lua`, `highlight_coordinator.lua`, `embed_state.lua`,
   and `task_hierarchy.lua`, but there is no aggregate count.

4. **No operation timing.** Index builds, search evaluations, completion builds, and
   embed renders have no instrumented timing. There is no way to correlate slowness
   with a specific subsystem without adding ad-hoc `os.clock()` calls.

5. **Many debug commands, no aggregate view.** Sixteen debug/status commands exist:
   `:VaultCacheStatus`, `:VaultCacheDebug`, `:VaultIndexStatus`,
   `:VaultIndexCollisions`, `:VaultWatcherStatus`, `:VaultCompletionDebug`,
   `:VaultPipelineDebug`, `:VaultCoalescerStats`, `:VaultCoalescerDebug`,
   `:VaultEmbedDebug`, `:VaultFoldDebug`, `:VaultConnectionDebug`,
   `:VaultPoolStats`, `:VaultArenaStats`, `:VaultSharingStats`, and `:VaultLog`.
   Each shows its own module's state but there is no unified view correlating
   cache effectiveness with memory pressure and operation timing.

6. **No leak detection.** Without periodic memory snapshots, slow leaks (e.g., a
   subscriber list that never shrinks, a timer dictionary that accumulates entries)
   go unnoticed until Neovim becomes sluggish.

## Zed Inspiration

Zed instruments resource lifecycles and cache effectiveness at multiple levels:

- **Entity leak detector** (`crates/gpui/src/app/entity_map.rs:787-835`): Gated by
  `#[cfg(any(test, feature = "leak-detection"))]` at line 787, `LEAK_BACKTRACE` env var
  declared via `LazyLock` at lines 788-789, `HandleId` struct at lines 793-795,
  `LeakDetector` struct with `HashMap<EntityId, HashMap<HandleId, Option<Backtrace>>>`
  at lines 798-801, `assert_released()` at lines 822-835 panics if any handles remain,
  printing resolved backtraces. This catches leaks immediately rather than after
  symptoms appear.

- **Inlay hint cache invalidation tiers** (`crates/editor/src/inlay_hint_cache.rs:65-80`):
  Three-tier `InvalidationStrategy` enum — `RefreshRequested` (LSP-initiated full
  invalidation), `BufferEdited` (editor-initiated, debounced), and `None` (append-only,
  no invalidation for scrolls/new excerpts). Cache entries carry a `version: usize`
  counter incremented on invalidation (line 37 in `InlayHintCache`), plus a
  `buffer_version: Global` (line 57 in `CachedExcerptHints`) for conflict detection.
  Range-based `remove_cached_ranges_from_query()` (line 168) computes deltas to avoid
  re-fetching already-cached regions. This distinguishes useful vs wasteful cache churn.

- **Search `LimitReached`** (`crates/project/src/project.rs:146-147, 3848-3859`):
  Two independent limits — `MAX_SEARCH_RESULT_FILES = 5_000` (line 146) and
  `MAX_SEARCH_RESULT_RANGES = 10_000` (line 147). Limit check at lines 3848-3853,
  `SearchResult::LimitReached` sent at line 3859. The `SearchResult` enum itself is
  defined in `crates/project/src/search.rs` (lines 19-25). This makes it visible when
  caps affect user experience.

- **SlotMap generation tracking** (`crates/gpui/src/app/entity_map.rs:28-31`): Uses
  the `slotmap` crate's built-in `KeyData` generation counter on `EntityId`. Each slot
  carries an implicit generation for O(1) ABA-problem prevention — similar to
  `vault_index._generation` but with per-slot granularity.

- **Performance profiling infrastructure**: Uses the `profiling` crate (workspace
  dependency in `Cargo.toml` line 533) with `#[profiling::function]` decorators and
  `profiling::scope!()` macros in GPUI rendering paths (e.g., `window.rs` lines 1836,
  1929, 3464; `blade_renderer.rs` lines 493, 583, 611, 817). Custom `zlog` timer
  (`crates/zlog/src/zlog.rs:177-368`) provides `time!()` macro (lines 177-184) with
  optional `warn_if_gt()` thresholds (line 333) — `Timer` struct (lines 307-368)
  auto-logs elapsed time on drop.

- **Debug-only inspector** (`crates/inspector_ui/`): Full GPUI element inspector with
  source files `inspector_ui.rs`, `inspector.rs`, `div_inspector.rs`. All core modules
  gated by `#[cfg(debug_assertions)]` (lines 1-7 of `inspector_ui.rs`) with release
  build stub that shows error message when toggle is attempted (lines 9-24).
  `debug_panic!` macro (`crates/util/src/util.rs:38-47`) panics in debug, logs with
  backtrace in release.

The common pattern: instrument resource lifecycles in debug/development mode with
zero cost in production mode.

## Existing Infrastructure to Leverage

The vault plugin already has substantial debugging infrastructure that the profiler
should complement rather than duplicate:

### Cache Registry (`engine.lua`)

```lua
---@class CacheSpec              -- engine.lua lines 34-39
---@field name string           Unique cache identifier
---@field module string         Module path for display
---@field invalidate fun()      Full invalidation callback
---@field invalidate_file? fun(abs_path: string)  Per-file invalidation (optional)
---@field stats? fun(): CacheStats  Status reporting callback (optional)

---@class CacheStats             -- engine.lua lines 41-48
---@field entries number|nil    Number of cached entries
---@field age_seconds number|nil Seconds since last build/refresh
---@field vault string|nil      Vault path this cache is scoped to
---@field ttl number|nil        Configured TTL in seconds (nil = no TTL)
---@field total_bytes number|nil Current byte weight (memory-weighted caches)
---@field max_bytes number|nil   Byte budget (memory-weighted caches)
---@field utilization number|nil total_bytes / max_bytes (memory-weighted caches)
```

**Note:** Individual stats callbacks may return additional ad-hoc fields beyond the
class definition (e.g., `index_generation`, `items_count`, `type` from kanban/timeline
caches). These are not part of the formal `CacheStats` annotation.

### Registered Caches (18 total)

| # | Cache Name | Module File | Has invalidate_file | Has stats | Cache Type |
|---|-----------|-------------|---------------------|-----------|------------|
| 1 | `connections` | connections.lua | Yes | Yes | LRU-weighted + gen tracking |
| 2 | `completions` | completion_base.lua | Yes | Yes | Gen-based + async coroutine |
| 3 | `calendar_deadlines` | calendar.lua | No | Yes | gen_cache |
| 4 | `tags` | tags.lua | No | Yes | Direct index access |
| 5 | `query_index` | query/init.lua | No | Yes | gen_cache |
| 6 | `autolink_index` | autolink.lua | No | Yes | Extmark dict |
| 7 | `task_hierarchy` | task_hierarchy.lua | Yes | Yes | LRU + gen_cache |
| 8 | `task_notify` | task_notify.lua | No | Yes | gen_cache |
| 9 | `kanban` | task_kanban.lua | No | Yes | gen_cache (2-level) |
| 10 | `task_timeline` | task_timeline.lua | No | Yes | gen_cache + render cache |
| 11 | `callout_folds` | callout_folds.lua | Yes | Yes | Changedtick + JSON store |
| 12 | `user_templates` | user_templates.lua | Yes | Yes | Directory mtime |
| 13 | `file_content` | file_cache.lua (via init.lua) | Yes | Yes | LRU-weighted, **has hit/miss** |
| 14 | `section_outlinks` | init.lua | No | Yes | Memory-weighted |
| 15 | `image_paths` | embed_images.lua | Yes | Yes | LRU |
| 16 | `url_validation` | url_validate.lua | No | Yes | TTL-based |
| 17 | `graph_filter_bfs` | graph_filter.lua | No | Yes | Memory-weighted BFS |
| 18 | `tasks` | tasks.lua | No | No | Basic |

### Memory-Weighted Caches (byte budgets in `config.cache`)

| Cache | Byte Budget | Count Limit |
|-------|------------|-------------|
| `file_content` | 5 MB | 100 |
| `connections` | 3 MB | 500 |
| `section_outlinks` | 2 MB | 200 |
| `note_data` (connections sub-cache) | 2 MB | 1000 |
| `section_cache` | 2 MB | 200 |
| `bfs_traversal` | 1 MB | 100 |
| **Total** | **15 MB** | — |

### LRU Config Mapping (`engine.lua`)

```lua
local LRU_CONFIG_KEYS = {
  connections = "connections_max",
  slug = "slug_max",
  date_parse = "date_parse_max",
  section_cache = "section_cache_max",
  note_data = "note_data_max",
  file_content = "file_content_max",
  section_outlinks = "section_cache_max",
  graph_filter_bfs = "bfs_traversal_max",
}
```

### Existing Debug Commands (16 total)

| Command | Module | Line | Shows |
|---------|--------|------|-------|
| `:VaultCacheStatus` | init.lua | 758 | Quick per-cache stats via `engine.cache_stats()` |
| `:VaultCacheDebug` | init.lua | 1011 | Detailed 5-section report: caches, LRU limits, memory budget, index, intern pools |
| `:VaultIndexStatus` | init.lua | 841 | Index build state, file counts, generation, subscribers, watcher |
| `:VaultIndexCollisions` | init.lua | 915 | Heading/alias name collisions in vault index |
| `:VaultWatcherStatus` | init.lua | 876 | Filesystem watcher status |
| `:VaultCompletionDebug` | init.lua | 924 | Per-source cache state, build timing, mode |
| `:VaultPipelineDebug` | init.lua | 929 | Pipeline tokenizer/render debug info |
| `:VaultCoalescerStats` | init.lua | 976 | Request coalescer statistics |
| `:VaultCoalescerDebug` | init.lua | 996 | In-flight coalesced operations |
| `:VaultEmbedDebug` | embed.lua | 741 | Per-placement state, conversion errors |
| `:VaultFoldDebug` | callout_folds.lua | 343 | Callout fold state per buffer |
| `:VaultConnectionDebug` | init.lua | 568 | Connection data for current note |
| `:VaultPoolStats` | init.lua | 1022 | Object pool allocation via `table_pool.all_stats()` |
| `:VaultArenaStats` | init.lua | 1040 | Render arena allocation via `render_arena.stats()` |
| `:VaultSharingStats` | init.lua | 1058 | Structural sharing via `structural_sharing.share_stats()` |
| `:VaultLog [n]` | engine.lua | 661 | Log file tail in scratch buffer |

### String Intern Pools (already track hit rates)

Configured in `config.intern`: `tag_pool_max`, `fm_key_pool_max`, `fm_value_pool_max`,
`folder_pool_max`, `lowercase_pool_max`. Hit rate statistics are shown in
`:VaultCacheDebug` output.

## Implementation

### New File: `lua/andrew/vault/memory_profiler.lua`

A singleton module that collects and displays resource metrics. When
`config.profiler.enable` is false, all public functions are no-ops (zero overhead).

```lua
local M = {}

local _enabled = false
local _caches = {}     -- name -> { get_size, get_capacity, get_hits, get_misses, get_evictions, get_generation, get_bytes, get_max_bytes }
local _counters = {}   -- name -> { get_count, description }
local _timings = {}    -- name -> { calls, total_ms, max_ms }
local _snapshots = {}  -- array of { timestamp, lua_kb, caches, counters }
local _gc_samples = {} -- array of { timestamp, lua_kb }
local _health_timer = nil
local _gc_timer = nil

--- Initialize the profiler. Called from engine.lua setup.
---@param opts { enable: boolean, track_allocations: boolean, health_check_interval_s: number }
function M.init(opts)
  _enabled = opts.enable
  if not _enabled then return end
  -- Start periodic GC sampling
  M._start_gc_sampling()
  if opts.health_check_interval_s > 0 then
    M._start_health_check(opts.health_check_interval_s)
  end
end

--- No-op guard used by all public functions.
local function noop_guard()
  return not _enabled
end
```

### 1. Cache Registry (Extended)

Extends the existing `engine._cache_registry` with profiling-specific callbacks.
Modules opt in by calling `profiler.register_cache()` alongside their existing
`engine.register_cache()` call.

```lua
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

--- Register a cache for profiling.
---@param spec ProfilerCacheSpec
function M.register_cache(spec)
  if noop_guard() then return end
  assert(spec.name and spec.get_size and spec.get_hits and spec.get_misses,
    "profiler cache spec requires name, get_size, get_hits, get_misses")
  _caches[spec.name] = spec
end
```

**Integration example** — `connections.lua`:

The connections cache currently uses `lru.new_weighted()` with byte budgets and
tracks entries, note_data_entries, index_generation, idf_generation, idf_cached,
subscribed, pending_changes, total_bytes, and max_bytes via its
`engine.register_cache()` stats callback (connections.lua lines 1103-1142). It
does NOT track hit/miss/eviction counts.

```lua
-- Existing code (unchanged, connections.lua lines 1103-1142):
engine.register_cache({
  name = "connections",
  module = "andrew.vault.connections",
  invalidate = function() ... end,
  invalidate_file = function(abs_path) ... end,
  stats = function()
    return {
      entries = _cache:size(),
      note_data_entries = _note_data_cache:size(),
      index_generation = vi and vi._generation or 0,
      idf_generation = _idf_gen,
      idf_cached = _idf_cache ~= nil,
      subscribed = _subscription ~= nil,
      pending_changes = vim.tbl_count(_pending_changed),
      total_bytes = (cache_stats.total_bytes or 0) + (nd_stats.total_bytes or 0),
      max_bytes = (cache_stats.max_bytes or 0) + (nd_stats.max_bytes or 0),
    }
  end,
})

-- New addition:
local profiler = require("andrew.vault.memory_profiler")
profiler.register_cache({
  name = "connections",
  get_size = function() return _cache:size() end,
  get_capacity = function() return config.cache.connections_max end,
  get_hits = function() return _cache_hits end,
  get_misses = function() return _cache_misses end,
  get_evictions = function() return _cache_evictions end,
  get_generation = function() return _idf_gen end,
  get_bytes = function()
    local cs = _cache.stats and _cache:stats() or {}
    local ns = _note_data_cache.stats and _note_data_cache:stats() or {}
    return (cs.total_bytes or 0) + (ns.total_bytes or 0)
  end,
  get_max_bytes = function()
    return config.cache.connections_bytes
  end,
})
```

This requires adding `_cache_hits`, `_cache_misses`, `_cache_evictions` counters
to each cache-bearing module. The counters are simple integer increments with
negligible overhead. Note that `file_cache.lua` already has `_hits` and `_misses`
locals (lines 14-15) that can be reused directly.

**Modules that need hit/miss counters added:**

| Module | Cache Name | Currently Tracks | Cache Type |
|--------|-----------|-----------------|------------|
| `connections.lua` | connections | entries, bytes, generation | LRU-weighted |
| `completion_base.lua` | completions | entries (per-source), build timing | Gen + async coroutine |
| `calendar.lua` | calendar_deadlines | entries, gen (via gen_cache) | gen_cache |
| `tags.lua` | tags | entries (direct index) | Direct index access |
| `query/init.lua` | query_index | entries, vault path | gen_cache |
| `autolink.lua` | autolink_index | ready state, generation | Extmark dict |
| `task_hierarchy.lua` | task_hierarchy | fold_state size, vtext buffers | LRU + gen_cache |
| `task_notify.lua` | task_notify | entries (via gen_cache) | gen_cache |
| `task_kanban.lua` | kanban | entries (via gen_cache) | gen_cache (2-level key) |
| `task_timeline.lua` | task_timeline | entries (via gen_cache) | gen_cache + render cache |
| `callout_folds.lua` | callout_folds | block cache per-buffer | Changedtick + JSON store |
| `user_templates.lua` | user_templates | template count, mtime | Directory mtime |
| `file_cache.lua` | file_content | **hits, misses, hit_rate** | LRU-weighted |
| `embed_images.lua` | image_paths | entries | LRU |
| `url_validate.lua` | url_validation | entries | TTL-based |
| `graph_filter.lua` | graph_filter_bfs | entries, bytes | Memory-weighted BFS |

**Note on gen_cache modules:** Calendar (`_deadline_cache`, line 137, gen_cache with
partial_fn), query/init (`_index_cache`, line 19, gen_cache with key_fn), task_notify
(`_overdue_cache`, line 18, gen_cache via task_utils), task_kanban (`_kanban_cache`,
line 35, gen_cache with key_fn), and task_timeline (`_timeline_cache`, line 30,
gen_cache with key_fn) all use the `gen_cache` or `keyed_gen_cache` abstractions
from `gen_cache.lua`. Calendar also has a `_log_cache` (line 227, keyed_gen_cache
keyed by "YYYY-MM"). Hit/miss tracking can be added at the `gen_cache` level (a
single change in `gen_cache.lua`) rather than per module, since `gen_cache.get()`
(lines 33-69) is the common lookup path that determines cache validity via generation
comparison. Currently, only `idx._inv_stats.partial_cache_hits` (lines 56-58) is
tracked. Note that `connections.lua` and `completion_base.lua` do NOT use `gen_cache`
— they implement manual generation tracking against `vault_index._generation` directly.

### 2. Resource Counters

Generic counter registration for tracking live resource counts.

```lua
---@class ProfilerCounterSpec
---@field name string
---@field get_count fun(): number
---@field description string

--- Register a resource counter.
---@param spec ProfilerCounterSpec
function M.register_counter(spec)
  if noop_guard() then return end
  _counters[spec.name] = spec
end
```

**Integration points:**

```lua
-- resource_cleanup.lua: wrap timer creation to track count
-- (Alternative: each module registers its own counter)

profiler.register_counter({
  name = "active_timers",
  get_count = function() return vim.tbl_count(_active_timers) end,
  description = "uv timers created via resource_cleanup",
})

-- highlight_coordinator.lua (3 autocmds + 1 BufDelete in _augroup):
profiler.register_counter({
  name = "highlight_debounce_timers",
  get_count = function() return vim.tbl_count(_timers) end,
  description = "per-buffer highlight debounce timers",
})

-- vault_index.lua (has subscriber_count() method):
profiler.register_counter({
  name = "index_subscribers",
  get_count = function()
    local idx = vault_index.current()
    return idx and idx:subscriber_count() or 0
  end,
  description = "vault index change subscribers",
})

-- embed_state.lua (7 registered per-buffer state dicts with unified GC):
-- embeds_visible, image_placements, _embed_deps, _sync_timers,
-- _image_retry_fired, _embed_descriptors, _scroll_timers
-- Plus _subscription (singleton, not per-buffer)
profiler.register_counter({
  name = "embed_tracked_buffers",
  get_count = function()
    return #(require("andrew.vault.embed_state").all_tracked_buffers())
  end,
  description = "buffers with embed state (images, timers, descriptors)",
})

-- autosave.lua:
profiler.register_counter({
  name = "autosave_timers",
  get_count = function() return vim.tbl_count(_timers) end,
  description = "per-buffer autosave debounce timers",
})
```

To make timer counting work without modifying every call site,
`resource_cleanup.lua` can maintain an internal `_active_timers` weak table.
Currently, `resource_cleanup.lua` is intentionally best-effort with no error
logging — the weak table approach preserves this philosophy:

```lua
-- In resource_cleanup.lua:
local _active_timers = setmetatable({}, { __mode = "v" })
local _timer_id = 0

function M.debounce(existing, delay_ms, callback)
  M.close_timer(existing)
  local t = vim.uv.new_timer()
  if not t then return nil end
  t:start(delay_ms, 0, vim.schedule_wrap(callback))
  -- Track for profiler (weak ref: GC'd timers disappear automatically)
  _timer_id = _timer_id + 1
  _active_timers[_timer_id] = t
  return t
end

-- Same pattern for M.repeating():
function M.repeating(existing, delay_ms, repeat_ms, callback)
  M.close_timer(existing)
  local t = vim.uv.new_timer()
  if not t then return nil end
  t:start(delay_ms, repeat_ms, vim.schedule_wrap(callback))
  _timer_id = _timer_id + 1
  _active_timers[_timer_id] = t
  return t
end

function M.active_timer_count()
  local n = 0
  for _ in pairs(_active_timers) do n = n + 1 end
  return n
end
```

### 3. Operation Timing

Lightweight stopwatch for instrumenting key operations. Inspired by Zed's `zlog`
Timer which auto-logs on drop and supports `warn_if_gt()` thresholds.

```lua
--- Start timing an operation. Returns a stop function.
---@param name string  Operation name (e.g., "index.build_async")
---@return fun()  Call this to record the elapsed time
function M.start_timer(name)
  if noop_guard() then return function() end end
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
```

**Integration example** — `vault_index_build.lua`:

Note: `build_async` lives in `vault_index_build.lua` (line 37, separate from
`vault_index.lua`), wraps work in `yield_iter.run_async()` with adaptive batch
sizing via `compute_batch_size()` targeting ~16ms per batch, uses
`request_coalescer` to prevent parallel builds, and applies structural sharing
via `sharing.share_unchanged()` / `sharing.intern_array()` when enabled.

```lua
function B.build_async(index, callback)
  local stop = profiler.start_timer("index.build_async")
  -- ... existing coalesced async build logic ...
  -- At resolve/reject callback:
  stop()
end
```

**Operations to instrument:**

| Operation | Module | Frequency | Notes |
|-----------|--------|-----------|-------|
| `index.build_async` | vault_index_build.lua (line 37) | On open, on save | Uses request_coalescer, adaptive batch sizing |
| `search.evaluate` | search_filter.lua (line 454) | Per keystroke (live search) | `evaluate(ast, index, graph_sets, restrict_to, cancelled)` with arena scope |
| `completion.build` | completion_base.lua | On trigger character | Async coroutine with adaptive batch sizing |
| `embed.render` | embed.lua (line 399) | Per BufEnter | Uses request_coalescer, lazy viewport mode, arena scope |
| `highlights.run_all` | highlight_coordinator.lua (line 245) | Per TextChanged | Debounced, arena-scoped render pass |
| `connections.compute` | connections.lua (line 790) | Per navigation | LRU-weighted with byte budgets |
| `calendar.scan_dates` | calendar.lua | Per month change | gen_cache with partial rebuild |
| `graph.layout` | graph.lua | Per graph open/filter | BFS batch size configurable |
| `pipeline.run` | highlight_coordinator.lua | Per highlight dispatch | Arena-scoped render pass |

### 4. GC Pressure Metrics

Periodic sampling of Lua memory state via `collectgarbage("count")`.

```lua
local GC_SAMPLE_INTERVAL_MS = 5000  -- 5 seconds
local GC_SAMPLE_MAX = 720           -- 1 hour of samples at 5s intervals

function M._start_gc_sampling()
  local timer = vim.uv.new_timer()
  if not timer then return end
  timer:start(0, GC_SAMPLE_INTERVAL_MS, vim.schedule_wrap(function()
    local kb = collectgarbage("count")
    _gc_samples[#_gc_samples + 1] = { timestamp = os.time(), lua_kb = kb }
    -- Trim old samples
    if #_gc_samples > GC_SAMPLE_MAX then
      table.remove(_gc_samples, 1)
    end
  end))
  _gc_timer = timer
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
```

### 5. Snapshot & Diff

Capture full profiler state for before/after comparisons.

```lua
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
```

### 6. Periodic Health Check

Background monitor that detects anomalies and logs warnings.

```lua
function M._start_health_check(interval_s)
  local timer = vim.uv.new_timer()
  if not timer then return end
  local log = require("andrew.vault.vault_log").scope("profiler")
  local prev_kb = collectgarbage("count")
  local threshold_mb = config.profiler.alert_memory_growth_mb
  local min_hit_rate = config.profiler.alert_hit_rate_min

  timer:start(interval_s * 1000, interval_s * 1000, vim.schedule_wrap(function()
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
      if total > 100 then  -- Only alert after sufficient sample size
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
  end))
  _health_timer = timer
end
```

### 7. Dashboard Command

`:VaultMemoryProfile` opens a floating scratch buffer with formatted output.
Complements the existing `:VaultCacheDebug` (which shows LRU limits, memory budgets,
and intern pool stats) by adding hit rates, operation timings, and GC pressure metrics.

```lua
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
  for name, spec in pairs(_caches) do
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
    if bytes and max_bytes then
      bytes_str = string.format("%.1f/%.1fM", bytes / (1024*1024), max_bytes / (1024*1024))
    end
    add("%-24s %5d/%-6s %8s %10d %12s %5s", name, size, cap_str, hit_pct, evictions, bytes_str, gen_str)
  end
  sep()

  -- Resources section
  add("--- Resources ---")
  add("%-32s %s", "Resource", "Count")
  for name, spec in pairs(_counters) do
    add("%-32s %d", name, spec.get_count())
  end
  sep()

  -- Timings section
  local window_label = "session"
  add("--- Operations (%s) ---", window_label)
  add("%-28s %6s %9s %9s %10s", "Operation", "Calls", "Avg(ms)", "Max(ms)", "Total(ms)")
  for name, entry in pairs(_timings) do
    if entry.calls > 0 then
      local avg = entry.total_ms / entry.calls
      add("%-28s %6d %9.1f %9.1f %10.1f", name, entry.calls, avg, entry.max_ms, entry.total_ms)
    end
  end

  return lines
end

--- Open dashboard in a floating window.
function M.open_dashboard()
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
```

### 8. Teardown

```lua
function M.shutdown()
  if _health_timer then
    local cleanup = require("andrew.vault.resource_cleanup")
    cleanup.close_timer(_health_timer)
    _health_timer = nil
  end
  if _gc_timer then
    local cleanup = require("andrew.vault.resource_cleanup")
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
```

## Commands

| Command | Description |
|---------|-------------|
| `:VaultMemoryProfile` | Open dashboard float (R to refresh, q to close) |
| `:VaultMemorySnapshot` | Save current state to snapshot stack |
| `:VaultMemoryDiff` | Compare current state vs last snapshot, show in float |
| `:VaultMemoryReset` | Reset timing windows and GC samples |

## Configuration

```lua
-- config.lua additions (new M.profiler section, after M.sharing at line 910)
-- Note: M.sharing at lines 906-910, M.cache at lines 794-814,
-- M.intern at lines 825-831, M.pools at lines 836-842, M.arena at lines 847-851,
-- M.events at lines 854-859, M.coalescer at lines 862-865,
-- M.pipeline at lines 870-876, M.viewport at lines 881-885,
-- M.patterns at lines 890-892, M.invalidation at lines 897-901
M.profiler = {
  enable = false,                  -- Master switch (false = all functions are no-ops)
  track_allocations = false,       -- Per-module allocation counting (higher overhead)
  health_check_interval_s = 60,    -- Periodic anomaly check (0 = disabled)
  gc_sample_interval_ms = 5000,    -- Memory sampling rate
  gc_sample_max = 720,             -- Max samples retained (1 hour at 5s)
  alert_memory_growth_mb = 10,     -- Warn if memory grows by this much between checks
  alert_hit_rate_min = 0.5,        -- Warn if any cache hit rate drops below this
}
```

## Integration Points

### Modules Requiring Changes

**Cache hit/miss counters** (add `_hits`, `_misses`, `_evictions` locals + increment at lookup sites):

Note: Modules using `gen_cache` or `keyed_gen_cache` (calendar, query/init,
task_notify, task_kanban, task_timeline) can have hit/miss tracking added at the
gen_cache abstraction level (single change in `gen_cache.lua` covers all 5).
LRU-based caches (connections, task_hierarchy, file_content, embed_images) track
at the LRU lookup site. Manual-gen-tracking modules (connections, completion_base)
need per-module counters at their generation comparison sites.

- `file_cache.lua` — **already has** `_hits` (line 14) and `_misses` (line 15); add `_evictions`. Hit path at lines 46-48 (mtime match), miss path at lines 51-52
- `connections.lua` — LRU-weighted `_cache` (lines 29-36) / `_note_data_cache` (lines 51-56) lookups; registration at lines 1103-1142
- `completion_base.lua` — per-source generation check via `_cached_gen` (line 155) in `build_iter` coroutine; registration at lines 130-143
- `calendar.lua` — `_deadline_cache.get()` (line 137) via gen_cache; registration at lines 725-738
- `tags.lua` — direct vault index access at lines 60-69 (no local cache; track index lookups)
- `query/init.lua` — `_index_cache.get()` (line 34) via gen_cache; registration at line 46
- `autolink.lua` — `matches_by_extmark` (line 38) dict lookups
- `task_hierarchy.lua` — `_vtext_cache` gen-based (line 27) + `_fold_state` LRU (line 23); `_timers` per-buffer (line 19)
- `task_notify.lua` — `_overdue_cache.get()` (line 58) via gen_cache; registration at line 230
- `task_kanban.lua` — `_kanban_cache.get()` (line 82) via gen_cache (2-level key); registration at line 774
- `task_timeline.lua` — `_timeline_cache.get()` (line 77) via gen_cache + `_render_cache` (line 244) key check at lines 294-295; registration at line 492
- `callout_folds.lua` — `_block_cache` (line 14) with changedtick comparison at lines 24-25; registration at line 311
- `user_templates.lua` — `M._cache` (line 310) with mtime comparison at lines 325-326; registration at line 539
- `embed_images.lua` — `_image_cache` LRU (line 42) with generation tracking (line 45); registration at lines 51-67
- `url_validate.lua` — TTL-based `_cache` (line 17) with status-dependent TTLs (lines 194-211); registration at lines 528-547
- `graph_filter.lua` — BFS `_bfs_cache` LRU weighted (traversal.lua line 32); registration at lines 69-84; stats at traversal.lua lines 311-322

**Resource counters** (add `profiler.register_counter()` call):
- `resource_cleanup.lua` — active timer count (via weak table, covers debounce + repeating). Currently has NO timer tracking or `active_timer_count()` — must be added
- `highlight_coordinator.lua` — per-buffer debounce timer count (`vim.tbl_count(_timers)`, line 208); teardown at lines 346-350
- `vault_index.lua` — subscriber count (has `subscriber_count()` method at lines 260-262); `_generation` field at line 124
- `embed_state.lua` — tracked buffer count (has `all_tracked_buffers()` at lines 135-143); 7 per-buffer state dicts (lines 16-24): embeds_visible, image_placements, _embed_deps, _sync_timers, _image_retry_fired, _embed_descriptors, _scroll_timers; plus `_subscription` singleton (line 22). State registry at lines 26-32
- `autosave.lua` — per-buffer timer count (`vim.tbl_count(_timers)`, line 19)
- `completion_base.lua` — active source count; field memoization cache at line 106

**Operation timing** (wrap with `profiler.start_timer()` / `stop()`):
- `vault_index_build.lua` — `B.build_async()` (line 37; uses request_coalescer, adaptive batch sizing targeting ~16ms at lines 17-27)
- `search_filter.lua` — `evaluate()` (line 454; arena-scoped with predicate matching loop)
- `completion_base.lua` — `build_iter()` coroutine (async with adaptive batch sizing)
- `embed.lua` — `render_embeds()`
- `highlight_coordinator.lua` — `M.run_all()` dispatch (line 245; arena-scoped, executes updaters in priority order)
- `connections.lua` — `M.compute()` (line 790; LRU-weighted with byte budgets)
- `calendar.lua` — `scan_dates_from_index()` (gen_cache with partial rebuild)
- `graph.lua` — graph layout

**Engine setup** (initialization):
- `engine.lua` — call `profiler.init(config.profiler)` during vault setup (after
  logger config at lines 649-652 and arena config at lines 655-658, after the
  `:VaultLog` command at lines 661-670)
- `engine.lua` — call `profiler.shutdown()` inside `M.teardown()` (line 641),
  which is called by `event_dispatch.lua` on VimLeavePre

### No Circular Dependencies

`memory_profiler.lua` requires only:
- `vault_log` (for health check warnings)
- `config` (for threshold values)
- `resource_cleanup` (for timer teardown in `shutdown()`)

All other modules require `memory_profiler` (one-way dependency). The profiler
never calls back into cache modules — it only invokes the getter functions
provided during registration.

## Implementation Notes

### Zero-Cost When Disabled

Every public function starts with `if noop_guard() then return end` (or returns
a no-op closure for `start_timer`). When `config.profiler.enable = false`:
- No timers created
- No memory sampling
- No function call overhead beyond the boolean check
- Registration calls are ignored

### Hit/Miss Counter Pattern

Each cache module adds three locals and two increment sites:

```lua
local _hits = 0
local _misses = 0
local _evictions = 0

-- At cache lookup:
local cached = _cache[key]
if cached then
  _hits = _hits + 1
  return cached
end
_misses = _misses + 1

-- At eviction:
_evictions = _evictions + 1
```

This is a single integer increment per lookup — unmeasurable overhead.

**For gen_cache modules**, hit/miss tracking is best added inside `gen_cache.lua`
itself since validity is determined by generation comparison. The `get()` method
(lines 33-69) already has a clear hit path at lines 37-42
(`cached_value ~= nil and cached_gen == gen`) and miss path (falls through to
`build_fn` at lines 65-68). The partial update path (lines 44-63) tracks
`idx._inv_stats.partial_cache_hits` at lines 56-58. Adding counters to the
`gen_cache` return table covers all 5 gen_cache consumers in a single change:

```lua
-- In gen_cache.lua get() method:
local hits, misses = 0, 0

-- Hit path (lines 37-42):
if cached_value ~= nil and cached_gen == gen and (not key_fn or cached_key == key) then
  hits = hits + 1
  return cached_value
end
-- Also count partial_fn success as hit (line 50 call, lines 56-58 stats):
hits = hits + 1
return cached_value

-- Miss path (lines 65-68):
misses = misses + 1
cached_value = build_fn(idx, ...)

-- Expose on returned table:
return {
  get = function(...) ... end,
  invalidate = function() ... end,
  get_hits = function() return hits end,
  get_misses = function() return misses end,
}
```

The same pattern applies to `keyed_gen_cache()` (line 85), where a hit is
`entries[key] ~= nil` (line 100) and a miss falls through to `build_fn` (line 102).

### Allocation Tracking (Optional, Higher Overhead)

When `config.profiler.track_allocations = true`, the profiler can hook into
per-module table creation by providing a tracked constructor:

```lua
--- Create a tracked table (only when allocation tracking is enabled).
---@param module_name string
---@return table
function M.tracked_table(module_name)
  if not _track_allocations then return {} end
  local counts = _alloc_counts[module_name]
  if not counts then
    counts = { total = 0, rate_window_start = os.time(), window_count = 0 }
    _alloc_counts[module_name] = counts
  end
  counts.total = counts.total + 1
  counts.window_count = counts.window_count + 1
  return {}
end
```

This is opt-in per call site and only used during investigation, not in
production. The overhead is a hash table lookup + two increments per tracked
allocation.

### Relationship to Existing Debug Commands

The profiler dashboard complements, not replaces, existing 16 debug commands:

| Profiler Dashboard | Existing Command(s) | Relationship |
|-------------------|---------------------|--------------|
| Cache hit rates | `:VaultCacheDebug` | Profiler adds hit/miss; CacheDebug shows LRU limits, byte budgets, intern pools |
| GC pressure | (none) | New capability |
| Operation timings | (none) | New capability — complements `:VaultCoalescerStats` (request dedup counts) |
| Resource counts | (none) | New capability — complements `:VaultWatcherStatus` (watcher state) |
| Memory snapshots/diffs | (none) | New capability |
| Cache entries/sizes | `:VaultCacheStatus` | Overlapping — profiler shows same + hit rates |
| Pool/arena stats | `:VaultPoolStats`, `:VaultArenaStats` | Not duplicated — profiler focuses on caches |
| Pipeline/render | `:VaultPipelineDebug` | Not duplicated — profiler focuses on timing, not pipeline state |

### Dashboard Refresh

The dashboard float uses `R` to refresh in-place (re-renders all lines into the
same buffer). This avoids opening/closing windows repeatedly during
investigation. The `q` mapping closes the float.

### Snapshot Stack

Snapshots are stored in a simple array. Typical workflow:

1. `:VaultMemorySnapshot` — baseline
2. Perform the operation being investigated
3. `:VaultMemoryDiff` — see what changed

The diff shows per-cache size deltas, byte deltas, new hits/misses since snapshot,
and overall Lua memory change. This replaces the current workflow of adding print
statements and restarting Neovim.

## Testing

- Unit test `memory_profiler.lua`: register mock caches/counters, verify dashboard
  output format, verify snapshot/diff arithmetic
- Integration: enable profiler, run `:VaultIndexRebuild`, verify `index.build_async`
  timing appears in dashboard
- Verify zero-cost: with `enable = false`, run a full index build and confirm no
  profiler state is populated
- Health check: set `alert_memory_growth_mb = 0.001`, trigger a build, verify
  warning appears in vault log
- Verify `file_cache.lua` existing hit/miss counters integrate without duplication

## Expected Impact

- **Zero runtime cost when disabled** — boolean guard on every entry point
- **Enables data-driven optimization** — cache hit rates reveal which caches are
  worth their memory cost and which should be resized or removed
- **Catches memory leaks early** — periodic sampling + health check alerts on
  anomalous growth before users notice sluggishness
- **Memory budget visibility** — shows byte utilization for weighted caches
  (total budget: 15 MB across 6 weighted caches)
- **Validates optimization effectiveness** — take snapshot before applying an
  optimization from another doc, take diff after, see measurable improvement
- **Complements existing debug commands** — single `:VaultMemoryProfile` dashboard
  adds hit rates, GC pressure, and timings alongside existing `:VaultCacheDebug`
  for LRU/intern pool details
- **Baseline for future work** — operation timings establish performance baselines
  that prevent regressions
