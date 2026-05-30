# 48. Idle-Time Proactive Cache Warming

## Problem

Most vault caching is reactive: caches are populated on first access, which means the first interaction in a session pays the full computation cost. This manifests as perceptible latency at several touch points:

1. **First completion popup**: The wikilink completion source in `completion_base.lua` builds its item list on first `get_completions()` call. For a vault with 5000+ notes, this coroutine-based build takes 200-800ms. The user sees a delayed popup or a spinner on their first `[[` input of the session. **Partial mitigation exists**: `completion_base.lua` already schedules a `DEFERRED`-priority pre-warm in `source.new()` (lines 522-533) via `work_scheduler`, but this only fires if the buffer is already markdown at source construction time, and does not re-trigger on index generation changes.

2. **First link follow (gf)**: `wikilinks.lua` resolves the target via vault index lookup (2-stage: name index -> alias index -> nil at `resolve_name()` line 1687), then `file_cache.read()` to load content. Note: `resolve_name()` returns `string[]|nil` (an array of matching absolute paths, or nil). On first access, the index may still be loading (the `build_async` coroutine hasn't finished), causing a deferred resolution path that adds 100-300ms.

3. **First embed render**: `embed.lua` reads all referenced files via `file_cache.read()` for cross-file embeds. The `warm_embed_cache()` function (line 215) pre-reads embeds into `file_cache` for the current render pass, but only for embeds in the current buffer -- not for files linked from the current buffer that the user is likely to navigate to.

4. **First search query**: `search_filter.lua` builds filter context via `build_filter_context()`, pre-resolving dates, tags, and numeric values from the AST. The `precompute_graph_sets()` BFS traversal (imported from `graph_traversal`) is particularly expensive for densely-linked vaults. A module-level `_date_memo` caches date resolutions per calendar day, but is cold on the first query.

5. **First connection panel**: `connections.lua` uses a weighted LRU cache (`lru.new_weighted()`) for connection scores (max: `config.cache.connections_max` = 500 items / `config.cache.connections_bytes` = 3MB) and a separate `_note_data_cache` (max: `config.cache.note_data_bytes` = 2MB / `config.cache.note_data_max` items) for pre-computed note data. The IDF computation queries `vault_index._summary_tree:query("")` for tag file counts and total file count (O(1) lookup from tree root via `ensure_idf()` at line 632); per-file scoring is O(n) in outlink count. Both caches are cold on first access.

These cold-start costs are predictable and avoidable. The user opens a markdown file, then thinks, reads, scrolls -- idle time that could be spent pre-warming the caches they will inevitably use.

### What Already Exists

The codebase already has building blocks for idle-time work:

- **`work_scheduler.lua`**: A priority-based work scheduler with four tiers: `CRITICAL` (0, synchronous), `NORMAL` (1, vim.schedule), `DEFERRED` (2, configurable timer delay via `config.scheduler.deferred_delay_ms` = 300ms), `IDLE` (3, CursorHold). The IDLE tier already drains up to `config.scheduler.max_idle_per_hold` (default 3) items per CursorHold event via the CursorHold callback in `M.setup()` (lines 225-236). Note: `M._drain()` (lines 84-103) only drains NORMAL and one DEFERRED item — it does NOT touch the IDLE queue. Queue structure: `_queues[1]` = NORMAL, `_queues[2]` = DEFERRED, `_queues[3]` = IDLE. This is the natural home for warming tasks.

- **`completion_base.lua` source.new()** (lines 522-533): Already schedules a DEFERRED-priority cache warm on source construction when filetype is markdown. The `_cached_gen` field (line 179) tracks the vault index generation at last build, and `build_ops` (line 182, an `operation_tracker` instance) provides staleness detection. No `VaultCacheInvalidate` autocmd handler exists in completion_base.lua yet — it registers with engine's cache registry via `engine.register_cache()` (lines 138-151) for invalidation dispatch.

- **`file_cache.lua`**: Two weighted LRU caches — a file content cache (max `config.cache.file_content_max` items / `config.cache.file_content_bytes` = 5MB) and a section cache (max `config.cache.section_cache_max` items / `config.cache.section_cache_bytes` = 2MB) — both with mtime-based validation. `read(path, max_lines)` (lines 39-71) returns cached lines if mtime matches; only unlimited reads (no `max_lines`) are cached. Registers with `memory_profiler` (lines 158-173) but NOT with `engine.register_cache()` (avoids circular deps). Used by `embed.lua`, `wikilinks.lua`, and other modules. This is the correct target for adjacent file pre-reading (not a separate content cache).

- **`memo` module**: Provides changedtick-based memoization for per-buffer computations. `link_scan.lua` uses `memo.new(memo.changedtick, build_code_exclusion_fn, "code_exclusion")` to cache treesitter exclusion zones, automatically invalidated when the buffer changes.

- **`search_filter.lua` `_date_memo`**: Module-level date resolution cache with daily reset via `os.date("%Y-%m-%d")` boundary detection.

### Why Not Just Cache Everything on Startup?

Startup must be fast. Loading all caches during init would delay Neovim startup by 500ms-2s. The vault index already uses a deferred lifecycle: `load()` reads persisted JSON (ready immediately), then `build_async()` runs an incremental diff in a coroutine. Warming should follow the same principle -- schedule work **after** the editor is usable, during idle periods when the user is reading or thinking.

## Inspiration

Zed uses idle time and incremental computation to eliminate first-interaction latency:

### `inlay_hint_cache.rs` -- Spatial Priority Queuing

**File**: `crates/editor/src/inlay_hint_cache.rs`

After fetching inlay hints for the visible viewport, Zed schedules a delayed request for invisible ranges using `INVISIBLE_RANGES_HINTS_REQUEST_DELAY_MILLIS = 400` (line 841). The implementation uses a three-tier spatial query strategy via the `QueryRanges` struct (lines 750-754):

```rust
struct QueryRanges {
    before_visible: Vec<Range<language::Anchor>>,
    visible: Vec<Range<language::Anchor>>,
    after_visible: Vec<Range<language::Anchor>>,
}
```

The `spawn_hint_refresh()` function (line 379) queries visible ranges first (lines 850-869), then delays invisible range queries by 400ms (lines 871-873). The prefetch distance matches the visible region length (`excerpt_visible_len` at line 786), so above-visible and below-visible ranges each span one viewport height. Concurrency is bounded by `MAX_CONCURRENT_LSP_REQUESTS = 5` via a semaphore (line 840, 45). Visible ranges bypass throttling when invalidating; invisible ranges respect it and may be skipped if the user has scrolled away (lines 957-989).

The key design property: the 400ms delay is long enough for the visible-range response to arrive and render (typically 50-200ms for LSP inlay hints), but short enough to complete before the user scrolls.

### Background Syntax Tree Parsing (`syntax_map.rs`)

**File**: `crates/language/src/syntax_map.rs`

Zed's syntax tree parsing uses incremental reprocessing via `ChangeRegionSet` (line 218), a sorted list of `ChangedRegion { depth, range }` entries (lines 212-215). The `reparse_with_ranges()` function (line 457) initializes a `ChangeRegionSet::default()` (line 474) and uses a BinaryHeap queue (line 475) for priority-based parsing. Old layers are reused if their language and range match the current parse step (lines 569-578); only layers that intersect changed regions are discarded (lines 536-544). Tree-sitter's incremental parsing with the old tree (line 1302 via `parser.parse_with_options()` in the `parse_text()` function) means only changed regions are re-parsed internally. This gives fold ranges, outline symbols, and semantic tokens for off-screen regions without additional parsing when the user navigates.

### WrapMap Background Rewrapping (`wrap_map.rs`)

**File**: `crates/editor/src/display_map/wrap_map.rs`

When wrap width changes, Zed rewraps visible content with a tight timeout, then continues in the background. The `WrapMap` struct (lines 21-29) uses:

```rust
pending_edits: VecDeque<(TabSnapshot, Vec<TabEdit>)>,
background_task: Option<Task<()>>,
```

The `sync()` function (line 118) adds edits to `pending_edits` and calls `flush_edits()`. Flush processing uses two timeout tiers: 5ms for full rewraps (line 194), 1ms for incremental edits (line 272). If timeout is exceeded, work moves to `cx.spawn()` background tasks (lines 201, 279). Meanwhile, an interpolation mode (lines 298-312) provides approximate wrapping: `self.edits_since_sync = self.edits_since_sync.compose(&interpolated_edits)` followed by `self.interpolated_edits = self.interpolated_edits.compose(&interpolated_edits)` (lines 305-306) maintains correctness without waiting for the full rewrap. When the background task completes, `flush_edits()` is called recursively and the UI is notified via `cx.notify()`.

### Texture Atlas Glyph Caching

**Files**: `crates/gpui/src/window.rs` (lines 2878-2883), `crates/gpui/src/text_system.rs` (lines 299-309)

Zed's GPU text renderer uses on-demand glyph rasterization with atlas caching. Glyphs are rasterized when first painted via `get_or_insert_with()` (lines 2878-2883), which calls `rasterize_glyph()` only when the glyph is not already in the atlas. Raster bounds are cached in an `FxHashMap` behind an `RwLock` (text_system.rs line 51), using upgradable read locks for concurrent access (read lock at line 300, upgrade to write at line 304). Atlas textures start at 1024x1024 (metal_atlas.rs lines 152-154) and grow to 16384x16384 max (lines 157-159). The pattern is lazy caching (not pre-rasterization) -- the cache eliminates re-rasterization cost on subsequent frames.

The common principle: **identify work that will certainly be needed, prioritize the visible/likely path, schedule the remainder during idle time, and ensure the result is ready before the user requests it.**

## Design

### Extending work_scheduler.lua

Rather than creating a separate warming module, cache warming extends the existing `work_scheduler.lua` infrastructure. The scheduler already provides:

- **IDLE priority** (tier 3, `_queues[3]`): Drained on CursorHold via the callback in `M.setup()` (lines 225-236), bounded by `config.scheduler.max_idle_per_hold` (default 3)
- **Domain-based cancellation**: `cancel_domain("warming")` (line 180) iterates all three queues in reverse, removes matching items, increments `_stats.cancelled`, returns count
- **Staleness detection**: `operation_id` + `_is_stale` callback checked at dequeue time via `should_execute()` (lines 56-67)
- **Statistics tracking**: `stats()` (lines 251-266) returns `{ enqueued, executed, cancelled, pending, pending_normal, pending_deferred, pending_idle, by_priority }`

Warming tasks are scheduled at IDLE priority with domain `"warming"`. This naturally integrates with the existing scheduler lifecycle:

```
Session start
  |
  +- BufReadPost (markdown)
  |   +- completion_base.lua source.new() schedules DEFERRED pre-warm (existing)
  |
  +- BufEnter (markdown, deferred 2s)
  |   +- Schedule IDLE: adjacent file pre-read (domain: "warming")
  |   +- Schedule IDLE: connection score pre-compute (domain: "warming")
  |
  +- VaultCacheInvalidate (User autocmd)
  |   +- Schedule IDLE: re-warm if generation changed (domain: "warming")
  |
  +- CursorHold (after updatetime ms of inactivity)
      +- work_scheduler drains up to max_idle_per_hold IDLE items
      +- Warming tasks execute alongside other IDLE work
```

### Priority Within IDLE Tier

IDLE tasks are drained FIFO within the queue. Since warming tasks compete with other IDLE work (e.g., deferred diagnostics), they should be scheduled in order of expected value:

| Schedule Order | Strategy | Rationale |
|----------------|----------|-----------|
| 1st | Adjacent file pre-read | Prepares for link follow and embed render |
| 2nd | Connection score pre-compute | Expensive but panel is opened frequently |

Completion pre-warming is already handled by DEFERRED scheduling in `completion_base.lua`. Date context and exclusion zones are already cached by their respective modules (`_date_memo`, `memo.changedtick`).

### Idle Detection

The `work_scheduler.lua` IDLE tier uses `CursorHold` (fires after `updatetime` ms of inactivity). For warming, an additional `FocusLost` handler can drain warming tasks more aggressively since the user is away from Neovim.

## Warming Strategies

### A. Completion Cache Pre-Build (EXISTING)

**Status**: Already implemented in `completion_base.lua` lines 522-533.

```lua
-- In completion_base.lua source.new() (existing code, lines 522-533)
function source.new()
  local self = setmetatable({}, { __index = source })
  if vim.bo.filetype == "markdown" then
    local scheduler = require("andrew.vault.work_scheduler")
    scheduler.schedule(scheduler.DEFERRED, function()
      build_items_async()
    end, { domain = "completion", label = "cache-warm" })
  end
  return self
end
```

**How it works**: When a completion source is constructed and the current buffer is markdown, the source schedules a DEFERRED-priority build. The build uses the same coroutine-based `build_iter` path as user-triggered builds (lines 453-517), yielding every `batch_size` items with adaptive batch sizing (lines 467-475). The `build_ops` operation tracker (an `operation_tracker` instance at line 182) prevents conflicts: if the user triggers a build while warming is in flight, the warm build's `operation_id` becomes stale and its results are discarded. Cancellation is also tracked via `active_state.cancelled` (line 185).

**Gap**: This only fires at source construction time. If the vault index generation advances (e.g., after `build_async` completes a full scan), the cached completion items become stale but no re-warm is triggered until the user's next `[[` input. The `_cached_gen` field (line 179) tracks the index generation at last build, and `cache_valid()` (lines 339-352) checks it -- but nothing proactively triggers a rebuild when generation changes. Note: `completion_base.lua` registers with engine's cache registry (lines 138-151) for invalidation dispatch, but does not subscribe to `VaultCacheInvalidate` autocmd directly.

**Proposed enhancement**: Add a `VaultCacheInvalidate` handler that re-schedules the DEFERRED pre-warm when the index generation has advanced past `_cached_gen`:

```lua
-- In completion_base.lua create_source(), after existing warmup scheduling
vim.api.nvim_create_autocmd("User", {
  pattern = "VaultCacheInvalidate",
  callback = function()
    if not cache_valid() and vim.bo.filetype == "markdown" then
      scheduler.schedule(scheduler.DEFERRED, function()
        build_items_async()
      end, { domain = "completion", label = "cache-rewarm" })
    end
  end,
})
```

### B. Adjacent File Pre-Read

**Trigger**: `BufEnter` for markdown files, after 2-second defer.
**Scheduler**: IDLE priority, domain `"warming"`, label `"adjacent-files"`.

Scan the current buffer for wikilinks (`[[file]]`) and embed references (`![[file]]`), resolve their paths via the vault index, and pre-read their content into the existing `file_cache.lua` weighted LRU. When the user follows a link (gf) or renders an embed, `file_cache.read()` returns a cache hit instead of performing disk I/O.

```lua
-- In cache_warming.lua
local file_cache = require("andrew.vault.file_cache")
local vault_index = require("andrew.vault.vault_index")
local config = require("andrew.vault.config")
local log = require("andrew.vault.vault_log").scope("cache_warming")

local function warm_adjacent_files(bufnr)
  local vault_path = require("andrew.vault.engine").vault_path
  if not vault_path then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local targets = {}

  for _, line in ipairs(lines) do
    -- Collect embed targets: ![[...]]
    for inner in line:gmatch("!%[%[([^%]]+)%]%]") do
      local note_part = inner:match("^([^#^]+)")
      if note_part and not note_part:match("%.png$")
        and not note_part:match("%.jpg$")
        and not note_part:match("%.jpeg$")
        and not note_part:match("%.gif$")
        and not note_part:match("%.webp$")
        and not note_part:match("%.svg$") then
        targets[note_part] = true
      end
    end
    -- Collect link targets: [[...]] (strip aliases and headings)
    for inner in line:gmatch("%[%[([^%]]+)%]%]") do
      if not inner:match("^!") then
        local note_part = inner:match("^([^#|]+)")
        if note_part and #note_part > 0 then
          targets[note_part] = true
        end
      end
    end
  end

  local idx = vault_index.current()
  if not idx then return end

  local warmed = 0
  for name, _ in pairs(targets) do
    -- resolve_name() returns string[]|nil (array of matching absolute paths)
    local paths = idx:resolve_name(name)
    if paths and #paths > 0 then
      -- Use first match (closest or most relevant path)
      local abs_path = paths[1]
      -- file_cache.read() handles mtime validation internally;
      -- if the file is already cached and mtime matches, this is a no-op
      local read_lines, _ = file_cache.read(abs_path)
      if read_lines then
        warmed = warmed + 1
      end
    end
    -- Respect per-tick budget
    if warmed >= config.cache_warming.max_files_per_warm then
      break
    end
  end

  log.debug("warmed %d adjacent files from buf %d", warmed, bufnr)
end
```

This reuses the existing `file_cache.lua` file content weighted LRU (max `config.cache.file_content_max` items / `config.cache.file_content_bytes` = 5MB). No separate content cache is needed. The `file_cache.read()` function (lines 39-71) already handles mtime validation, LRU eviction, and cache miss statistics. Note: only unlimited reads (no `max_lines` parameter) are cached — partial reads bypass the cache. Pre-warming simply moves the disk I/O from "first user interaction" to "idle time."

Consumers (`embed.lua`, `wikilinks.lua`) already call `file_cache.read()`, so warm cache hits are transparent -- no consumer changes needed.

### C. Connection Score Pre-Compute

**Trigger**: `CursorHold` in a markdown buffer.
**Scheduler**: IDLE priority, domain `"warming"`, label `"connections"`.

Pre-compute connection scores for the current file. The `connections.lua` module stores results in a weighted LRU cache (`_cache`, configured by `config.cache.connections_max` / `config.cache.connections_bytes`). Pre-computing populates both the main result cache and the secondary `_note_data_cache`, so the connections panel opens instantly.

```lua
local function warm_connections(bufnr)
  local abs_path = vim.api.nvim_buf_get_name(bufnr)
  if abs_path == "" then return end

  local vault_path = require("andrew.vault.engine").vault_path
  if not vault_path then return end

  local rel_path = abs_path:sub(#vault_path + 2)
  local connections = require("andrew.vault.connections")

  -- compute(source_rel_path, max_results, opts_cancel) checks its own cache
  -- (generation + TTL) and returns early on hit, so this is safe to call
  -- unconditionally. Pass nil for max_results (uses config.connections.max_results)
  -- and nil for opts_cancel (no cancellation needed during warming).
  local result = connections.compute(rel_path)
  if result then
    log.debug("warmed connection scores for %s (%d results)", rel_path, #result)
  end
end
```

The `compute()` function (line 697, signature: `M.compute(source_rel_path, max_results, opts_cancel)`) already checks `filter_utils.is_cache_gen_valid()` against the cached `index_gen` field AND validates `config.connections.cache_ttl` before recomputing. Calling it during idle time is equivalent to a user opening the connections panel -- it caches the results in the same weighted LRU (`_cache`, max `config.cache.connections_max` = 500 items / `config.cache.connections_bytes` = 3MB). The IDF computation (via `ensure_idf()` at lines 632-637, which queries `vault_index._summary_tree:query("")` for O(1) tag file counts and total file count from the tree root) is implicitly warmed on the first compute call and benefits all subsequent connection lookups. Connection requests are also deduplicated via `request_coalescer` (line 775 in `compute_async()`).

No new exports are needed on `connections.lua`. The existing `compute()` function is the correct entry point. `connections.lua` already registers with `engine.register_cache()` (lines 1011-1049) with both `invalidate` and `invalidate_file` handlers (including dependency-based cascade invalidation).

### D. Code Exclusion Zone Pre-Parse (ALREADY MEMOIZED)

**Status**: No additional warming needed.

`link_scan.lua` already memoizes exclusion zone computation via the `memo` module:

```lua
-- link_scan.lua line 108 (existing)
_code_exclusion_check = memo.new(memo.changedtick, build_code_exclusion_fn, "code_exclusion")
```

This memo is keyed on `bufnr` and invalidated automatically when `b:changedtick` changes. The first call per buffer builds the exclusion set; subsequent calls return the cached result. The treesitter parse (`parser:parse()`) is required for the exclusion check but is typically already triggered by syntax highlighting before any vault module runs. Pre-warming this would add complexity with minimal benefit.

### E. Search Date Context Pre-Resolve (ALREADY CACHED)

**Status**: No additional warming needed.

`search_filter.lua` already maintains a `_date_memo` that caches date resolutions per calendar day:

```lua
-- search_filter.lua (existing)
local _date_memo = {}
local _date_memo_day = ""

local function get_or_reset_date_memo()
  local today = os.date("%Y-%m-%d")
  if today ~= _date_memo_day then
    _date_memo = {}
    _date_memo_day = today
  end
  return _date_memo
end
```

Additionally, `build_filter_context()` pre-resolves all date values from the search AST into a `resolved_dates` table before any filtering begins. The `date_utils.resolve_date()` function is cheap for keyword lookups ("today", "yesterday") -- it's pure arithmetic on `os.time()` with no I/O. Pre-warming would save microseconds, not milliseconds.

## Implementation

### Step 1: Create `cache_warming.lua` Module

File: `lua/andrew/vault/cache_warming.lua`

This module is a thin orchestration layer that schedules warming tasks via `work_scheduler` and provides the `FocusLost` aggressive drain enhancement.

```lua
local config = require("andrew.vault.config")
local log = require("andrew.vault.vault_log").scope("cache_warming")
local scheduler = require("andrew.vault.work_scheduler")

local M = {}

-- -----------------------------------------------------------------------
-- Warming Statistics
-- -----------------------------------------------------------------------

local warm_stats = {
  scheduled = 0,
  completed = 0,
  failed = 0,
}

--- Schedule a warming task via work_scheduler IDLE priority.
--- @param label string  Human-readable identifier for logging/debug
--- @param fn fun()      The warming function
function M.schedule_warm(label, fn)
  if not config.cache_warming.enabled then return end

  warm_stats.scheduled = warm_stats.scheduled + 1
  scheduler.schedule(scheduler.IDLE, function()
    local start = vim.uv.hrtime()
    local ok, err = pcall(fn)
    local elapsed_ms = (vim.uv.hrtime() - start) / 1e6

    if ok then
      warm_stats.completed = warm_stats.completed + 1
      log.debug("warm completed: %s (%.1fms)", label, elapsed_ms)
    else
      warm_stats.failed = warm_stats.failed + 1
      log.warn("warm failed: %s: %s (%.1fms)", label, tostring(err), elapsed_ms)
    end
  end, { domain = "warming", label = label })
end

--- Cancel all pending warming tasks.
function M.cancel_warming()
  scheduler.cancel_domain("warming")
end
```

### Step 1b: Add `drain_idle()` to `work_scheduler.lua`

The existing `M._drain()` (lines 84-103) only drains the NORMAL queue and one DEFERRED item -- it does NOT touch the IDLE queue (`_queues[3]`). For the FocusLost aggressive drain, we need a public method to drain IDLE items:

```lua
-- In work_scheduler.lua, new function
--- Drain IDLE queue items up to config.scheduler.max_idle_per_hold.
--- Called by CursorHold autocmd (existing) and FocusLost handler (cache_warming).
function M.drain_idle()
  local queue = _queues[3]
  local max_idle = config.scheduler.max_idle_per_hold
  local processed = 0
  while #queue > 0 and processed < max_idle do
    local item = table.remove(queue, 1)
    execute(item)
    processed = processed + 1
  end
  return processed
end
```

This extracts the existing CursorHold callback logic (lines 225-236 in `M.setup()`) into a reusable function, and the CursorHold autocmd can call `M.drain_idle()` instead of inlining the loop.

### Step 2: Register Autocmd Handlers

```lua
local augroup = nil

function M.setup()
  if not config.cache_warming.enabled then return end
  if augroup then return end

  augroup = vim.api.nvim_create_augroup("VaultCacheWarming", { clear = true })

  -- Aggressive drain on FocusLost (user is away from Neovim)
  -- Note: scheduler._drain() (lines 84-103) only drains NORMAL queue + 1
  -- DEFERRED item; it does NOT touch IDLE queue. For IDLE drain, we must
  -- manually process the IDLE queue items via the same pattern as CursorHold.
  vim.api.nvim_create_autocmd("FocusLost", {
    group = augroup,
    callback = function()
      vim.schedule(function()
        local stats = scheduler.stats()
        if stats.pending_idle > 0 then
          -- Temporarily raise the per-hold limit to drain all IDLE items
          local saved = config.scheduler.max_idle_per_hold
          config.scheduler.max_idle_per_hold = stats.pending_idle
          -- Simulate a CursorHold drain for IDLE items
          scheduler.drain_idle()
          config.scheduler.max_idle_per_hold = saved
        end
      end)
    end,
  })

  -- Cancel warming when user starts active input
  vim.api.nvim_create_autocmd({ "InsertEnter", "CmdlineEnter" }, {
    group = augroup,
    callback = function()
      M.cancel_warming()
    end,
  })

  -- Schedule warming tasks on buffer enter
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    pattern = "*.md",
    callback = function(ev)
      vim.defer_fn(function()
        if not vim.api.nvim_buf_is_valid(ev.buf) then return end
        M.schedule_buffer_warmup(ev.buf)
      end, config.cache_warming.idle_delay_ms)
    end,
  })

  -- Re-schedule warming when index changes
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "VaultCacheInvalidate",
    callback = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local ft = vim.bo[bufnr].filetype
      if ft == "markdown" then
        M.schedule_buffer_warmup(bufnr)
      end
    end,
  })

  log.info("cache warming enabled")
end
```

### Step 3: Implement Buffer Warmup Scheduling

```lua
--- Schedule warming tasks relevant to the current buffer.
--- @param bufnr number
function M.schedule_buffer_warmup(bufnr)
  if not config.cache_warming.enabled then return end

  -- Don't warm while index is building
  local vault_index = package.loaded["andrew.vault.vault_index"]
  if vault_index then
    local idx = vault_index.current()
    if idx and idx:is_building() then
      log.debug("skipping warmup: index is building")
      return
    end
  end

  local strategies = config.cache_warming.strategies

  if strategies.adjacent_files then
    M.schedule_warm("adjacent_files:" .. bufnr, function()
      warm_adjacent_files(bufnr)
    end)
  end

  if strategies.connections then
    M.schedule_warm("connections:" .. bufnr, function()
      warm_connections(bufnr)
    end)
  end
end
```

### Step 4: Debug Command

```lua
--- Get warming statistics for debug display.
--- @return table
function M.stats()
  return {
    scheduled = warm_stats.scheduled,
    completed = warm_stats.completed,
    failed = warm_stats.failed,
    scheduler_stats = scheduler.stats(),
    file_cache_stats = require("andrew.vault.file_cache").stats(),
  }
end

vim.api.nvim_create_user_command("VaultWarmDebug", function()
  local s = M.stats()
  local sched = s.scheduler_stats
  local fc = s.file_cache_stats
  local lines = {
    "Cache Warming Stats",
    "",
    string.format("  Warming:   %d scheduled, %d completed, %d failed",
      s.scheduled, s.completed, s.failed),
    "",
    string.format("  Scheduler: %d pending IDLE, %d total executed",
      sched.pending_idle, sched.executed),
    "",
    -- file_cache.stats() returns: file_size, hits, misses, hit_rate,
    -- total_bytes, max_bytes, file_bytes, file_max_bytes, etc.
    string.format("  File cache: %d entries, %d hits, %d misses",
      fc.file_size or 0, fc.hits or 0, fc.misses or 0),
  }
  if fc.hit_rate and fc.hit_rate > 0 then
    table.insert(lines, string.format("  Hit rate:   %.1f%%", fc.hit_rate))
  end
  if fc.file_bytes and fc.file_max_bytes then
    table.insert(lines, string.format("  Bytes:      %s / %s",
      require("andrew.vault.format_utils").bytes(fc.file_bytes),
      require("andrew.vault.format_utils").bytes(fc.file_max_bytes)))
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.cmd.split()
  vim.api.nvim_set_current_buf(buf)
end, {})

return M
```

### Step 5: Integration with engine.lua

Register the warming module in the engine's initialization sequence. Engine setup happens at lines 677-746 of `engine.lua`:

```lua
-- In engine.lua (setup function, after vault index is initialized)
local function setup_cache_warming()
  local ok, warming = pcall(require, "andrew.vault.cache_warming")
  if ok then
    warming.setup()
  end
end
```

Register with the cache registry (via `engine.register_cache()` at lines 50-56) so `invalidate_caches()` (lines 58-119) can clear warm-related state:

```lua
-- In cache_warming.lua
local engine = require("andrew.vault.engine")

engine.register_cache({
  name = "warming",
  module = "andrew.vault.cache_warming",
  invalidate = function()
    M.cancel_warming()
    warm_stats = { scheduled = 0, completed = 0, failed = 0 }
  end,
  stats = function()
    return {
      entries = 0, -- warming has no persistent cache; it populates file_cache and connections._cache
    }
  end,
})
```

Note: `file_cache.lua` does not register with `engine.register_cache()` (it registers only with `memory_profiler` at lines 158-173 to avoid circular deps). Warming tasks populate file_cache, but invalidation of file_cache entries is handled separately by `file_cache.invalidate(path)` calls from the fs watcher. `connections.lua` DOES register with engine (lines 1011-1049) and handles its own file-level invalidation with dependency cascade.

## Guard Rails

### 1. Only warm when genuinely idle

Warming tasks use `scheduler.IDLE` priority, which only fires on `CursorHold` (no keypress for `updatetime` ms). The `idle_delay_ms` config (default 2000ms) provides an additional buffer before tasks are even enqueued, independent of `updatetime`.

### 2. Stop warming immediately on user activity

```lua
vim.api.nvim_create_autocmd({ "InsertEnter", "CmdlineEnter" }, {
  group = augroup,
  callback = function()
    M.cancel_warming()
  end,
})
```

`cancel_warming()` calls `scheduler.cancel_domain("warming")`, which removes all pending warming items from the IDLE queue without affecting other scheduled work. Currently-executing tasks run to completion (they are short), but no new warming tasks start.

### 3. Cap per-tick CPU usage

The `work_scheduler` already bounds IDLE processing to `config.scheduler.max_idle_per_hold` items per CursorHold (default 3). Warming tasks compete fairly with other IDLE work. For `FocusLost`, the limit is temporarily raised to drain all pending items since the user is away.

### 4. Don't warm during index build

```lua
if idx and idx:is_building() then
  log.debug("skipping warmup: index is building")
  return
end
```

The `is_building()` method (lines 573-577 of vault_index.lua) returns `self._building`. The `_generation` field (initialized at line 189, incremented at line 537) tracks index rebuild cycles. Warming tasks that depend on the index (connections) would get stale results from a partially-built index. The warmup scheduling skips entirely when `_building` is true. Tasks are re-scheduled on the next `VaultCacheInvalidate` event (fired by `engine.invalidate_caches()` at line 110 of engine.lua after build completes).

### 5. Reuse existing caches

Warming populates the same caches that user-triggered operations use:
- Adjacent file pre-read -> `file_cache.lua` file content weighted LRU (mtime-validated, `config.cache.file_content_bytes` = 5MB budget)
- Connection pre-compute -> `connections._cache` weighted LRU (generation + TTL validated via `filter_utils.is_cache_gen_valid()` + `config.connections.cache_ttl`, `config.cache.connections_bytes` = 3MB budget)

No separate warm-only caches are introduced. This eliminates the risk of cache incoherence and doubles the value of existing cache investment.

### 6. Track warm statistics for tuning

The `warm_stats` table tracks scheduled/completed/failed counts. The `:VaultWarmDebug` command surfaces these alongside file_cache hit/miss rates and scheduler pending counts. If a strategy shows low file_cache hit rates (warmed files never accessed before eviction), it should be disabled via config.

## Configuration

Add to `lua/andrew/vault/config.lua`:

```lua
M.cache_warming = {
  -- Master switch: enable/disable all proactive warming
  enabled = true,

  -- Delay before scheduling warmup tasks after BufEnter (ms)
  -- Allows BufEnter processing (embed autocmd, highlight setup) to complete first
  idle_delay_ms = 2000,

  -- Maximum files to pre-read per adjacent-file warm cycle
  max_files_per_warm = 10,

  -- Per-strategy enable flags
  strategies = {
    adjacent_files = true,  -- Pre-read linked/embedded files into file_cache
    connections = true,     -- Pre-compute connection scores
  },
}
```

Note: The existing `M.scheduler` section (config.lua lines 1009-1021) already controls IDLE drain behavior:

```lua
M.scheduler = {
  deferred_delay_ms = 300,   -- Delay before DEFERRED items execute (line 1012)
  max_idle_per_hold = 3,     -- Max IDLE items per CursorHold (line 1016)
  stats_enabled = false,     -- Track execution statistics (line 1020)
}
```

The existing `M.cache` section (config.lua lines 815-835) defines the byte budgets that warming tasks populate:

```lua
M.cache = {
  -- ...
  connections_max = 500,                    -- (line 819)
  file_content_bytes = 5 * 1024 * 1024,    -- 5MB (line 829)
  section_cache_bytes = 2 * 1024 * 1024,   -- 2MB (line 830)
  connections_bytes = 3 * 1024 * 1024,     -- 3MB (line 832)
  note_data_bytes = 2 * 1024 * 1024,       -- 2MB (line 833)
  -- ...
}
```

## API

```lua
local warming = require("andrew.vault.cache_warming")

-- Initialize (called once during vault setup in engine.lua)
warming.setup()

-- Schedule a custom warming task (uses work_scheduler IDLE tier)
warming.schedule_warm("my_custom_warm", function()
  -- ... warming work ...
end)

-- Cancel all pending warming tasks (domain-based via work_scheduler)
warming.cancel_warming()

-- Debug statistics
warming.stats() -- { scheduled, completed, failed, scheduler_stats, file_cache_stats }

-- Debug command
-- :VaultWarmDebug  -- opens scratch buffer with warming stats
```

## Interaction with Other Docs

### Doc 14 (Cooperative Yielding)

Warm tasks that iterate large data sets should use cooperative yielding from doc 14. The `connections.compute()` path already handles this internally. The adjacent file pre-read is bounded by `max_files_per_warm` and performs synchronous `file_cache.read()` calls (each is a single `fs_stat` + optional `fs_read`), which are fast enough to not need yielding.

### Doc 21 (Stale Operation Cancellation)

The `work_scheduler` already supports staleness detection via `operation_id` and `_is_stale` callbacks. If a warming task is superseded (e.g., the user switches buffers while warming is queued), `cancel_domain("warming")` removes it. The completion pre-warm uses `build_ops` (an `operation_tracker` instance) to detect when a warm build has been superseded by a user-triggered build.

### Doc 25 (Concurrent Request Deduplication)

The completion pre-warm and user-triggered build share the same `build_ops` operation tracker (line 182) and `active_state` cancellation flag (line 185) in `completion_base.lua`. If the user triggers a completion popup while the warm build is in flight, the warm build's `operation_id` becomes stale and its results are discarded. The `connections.lua` module uses `request_coalescer` via a dedicated `conn_pool` (line 14-17) for its async path (`compute_async()` at line 771, with `conn_pool:request` at line 775), preventing duplicate compute requests for the same source note.

### Doc 29 (Tiered Cache Invalidation)

Warm caches participate in the tiered invalidation hierarchy: `VaultCacheInvalidate` (fired by `engine.invalidate_caches()`) triggers the `User` autocmd handler in `cache_warming.lua`, which re-schedules warming for the current buffer. The underlying caches (`file_cache`, `connections._cache`) are invalidated separately by their own registered handlers and fs watcher callbacks.

### Doc 33 (Three-Zone Viewport Prefetch)

Doc 33 proposes prefetching decorations for above/below viewport zones, inspired by Zed's `QueryRanges` pattern. Cache warming is a broader version: prefetch not just for scroll direction but for any likely next action (link follow, panel open). The two systems are complementary -- doc 33 warms extmark state, doc 48 warms data caches.

### Doc 41 (Operation Counter Staleness)

The completion pre-warm uses `build_ops` (an `operation_tracker` instance at `completion_base.lua` line 182) to detect staleness. Staleness is checked at multiple points: `should_skip_build()` (line 415), legacy build callback (line 442), and async cancelled check (line 498). If the index generation changes while the coroutine-based build is in progress, the warm build's `operation_id` is no longer current and its results are discarded rather than cached.

### Doc 42 (Content-Hash Change Detection)

The adjacent file pre-read uses `file_cache.read()`, which validates by mtime. If doc 42's content-hash change detection is implemented in `file_cache.lua`, warm reads would automatically benefit: files where mtime changed but content hash matches (e.g., after `git checkout` that touches timestamps) would return cache hits without re-reading.

## Expected Impact

### Cold-Start Latency Reduction

| Operation | Before (cold) | After (warm) | Reduction |
|-----------|--------------|--------------|-----------|
| First `[[` completion popup | 200-800ms | 0ms (DEFERRED pre-built, existing) | 100% |
| First `gf` link follow | 100-300ms | 10-20ms (file_cache hit) | 85-95% |
| First embed render (10 embeds) | 500-2000ms | 50-100ms (file_cache hits) | 90-95% |
| First search with `task-due:today` | 50-100ms date resolve | ~0ms (_date_memo, existing) | ~100% |
| First connection panel | 300-1000ms | 0ms (pre-computed) | 100% |

### Resource Cost

- **CPU**: Negligible during idle. Warming tasks run during `CursorHold` at IDLE priority and are bounded by `max_idle_per_hold` (default 3 items per CursorHold). Total warming cost for a typical buffer: 50-200ms spread across multiple idle events over 5-15 seconds.
- **Memory**: No additional caches. Warming populates the existing `file_cache` file content weighted LRU (`config.cache.file_content_bytes` = 5MB budget) and `connections._cache` weighted LRU (`config.cache.connections_bytes` = 3MB budget). Both enforce their own capacity limits via weighted LRU eviction.
- **Disk I/O**: Adjacent file pre-reads perform `file_cache.read()` which calls `vim.uv.fs_stat()` + optional `vim.uv.fs_read()`. For 10 linked files (bounded by `max_files_per_warm`), this is 10-20 syscalls. Each read is bounded by file size (typical note: 1-10KB). Total I/O: 10-100KB per warm cycle.

### Hit Rate Expectations

Based on typical vault usage patterns:

- **Completion warm**: >95% hit rate. Already implemented via DEFERRED scheduling.
- **Adjacent file warm**: 60-80% hit rate. Users follow links in the current note more often than jumping to unrelated notes, but not every linked file is visited. The 5MB file_cache budget is shared with other readers, so warm entries may be evicted by subsequent reads.
- **Connection warm**: 40-60% hit rate. The connection panel is used regularly but not on every buffer. The 3MB connections cache budget provides room for ~500 cached entries.
- **Date context**: >99% hit rate. Already implemented via `_date_memo`.
- **Exclusion zones**: >90% hit rate. Already implemented via `memo.changedtick`.

Strategies with low hit rates should be tuned via config or disabled. The `:VaultWarmDebug` command provides the data needed to make these decisions.

## Risks

1. **File cache eviction pressure**: Pre-reading 10 adjacent files into `file_cache` consumes LRU budget (up to ~100KB of the `config.cache.file_content_bytes` = 5MB limit). Note that `file_cache` also maintains a section cache (`config.cache.section_cache_bytes` = 2MB) that is not affected by warming. If the vault has many large notes, warm entries may evict entries cached by other modules. Mitigation: the `max_files_per_warm` config (default 10) limits warm reads, and the weighted LRU evicts by byte weight, so large warm entries are evicted first.

2. **Warming during index rebuild**: If warming is scheduled while `build_async` is mid-flight, it could get partial index state. Mitigation: `schedule_buffer_warmup()` checks `idx:is_building()` and skips entirely when true. The `VaultCacheInvalidate` autocmd handler re-schedules warming after the build completes.

3. **`updatetime` sensitivity**: Warming depends on `CursorHold`, which fires after `updatetime` ms. Users with very high `updatetime` (10000ms+) will get less warming. Users with very low `updatetime` (100ms) may get warming during brief pauses. Mitigation: the `idle_delay_ms` config (default 2000ms) defers task scheduling independent of `updatetime`.

4. **Stale connection scores**: Connection scores are cached with both generation validation (`filter_utils.is_cache_gen_valid()` against `index_gen` field) and TTL (`config.connections.cache_ttl`). A warm connection score could become stale if the index changes after warming but before the user opens the panel. Mitigation: `connections.compute()` (line 697) validates both checks on every access, recomputing if stale. File-level invalidation also cascades via dependency tracking in `invalidate_file` (lines 1011-1049). Warming only avoids the cold-start cost, not the staleness check.

5. **Scheduler queue contention**: Warming tasks compete with other IDLE work in `work_scheduler`. If many IDLE tasks are queued (e.g., deferred diagnostics, URL validation), warming may be delayed. Mitigation: warming tasks are scheduled in value order (adjacent files first, then connections), so the highest-value warming completes first even if the queue is not fully drained.

6. **Warm task exceptions**: A bug in a warming function could crash during IDLE drain. Mitigation: `schedule_warm()` wraps each task in `pcall`. Failures are logged via `vault_log` and counted in `warm_stats.failed`. The scheduler continues to the next task.
