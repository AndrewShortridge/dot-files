# 41. Operation Counter Staleness Detection

## Problem

Several vault modules perform async operations where results can arrive after the underlying data has changed, leading to stale results being displayed or applied. However, the codebase has already evolved significant per-module staleness mitigations. The remaining problem is that these mitigations are **ad-hoc and inconsistent** — each module invented its own pattern rather than sharing a reusable primitive.

### Current State of Each Module

1. **Live search (`search/advanced.lua`)**: **Already has generation-based staleness detection.** A module-level `_search_generation` counter (line 16) is incremented on each new async search (line 28) and also for text-only (lines 207-208) and mixed-or fallback (lines 264-265) modes. Closures capture `my_gen` and discard results if the generation has advanced (line 41). Also has `_active_eval_cancel` (declared line 11) for cancelling in-flight metadata evaluation (used at line 27) and `semaphore_reset()` for killing queued ripgrep processes (line 387). The live search path (`search/live.lua`) additionally validates incremental filtering cache against vault index generation via `filter_utils.is_cache_gen_valid()` (line 71).

2. **Embed rendering (`embed.lua`)**: **All file reads are synchronous** — `file_cache.read()` uses `io.open()` + mtime validation, not async I/O (lines 210-217). The module already tracks a per-buffer `generation` counter in `state._embed_descriptors[bufnr]` (lines 560-561), incremented on each render. A `check_generation(bufnr, generation)` function (lines 404-409) validates descriptor freshness before scroll-triggered renders (line 1041). Request coalescing via `embed_pool` (declared line 22) with key `"embed_render:" .. bufnr` (is_pending check at lines 469-475, request submission at lines 500+) prevents duplicate in-flight renders; non-forced calls skip if `embed_pool:is_pending()`, forced calls cancel and restart. Uses `resolve_now()` for synchronous resolution. The remaining staleness risk is minimal: since reads are sync, the only race is between `WinScrolled` deferred renders (lines 1004-1058, debounced via `config.embed.lazy_scroll_debounce_ms`) and a new `render_embeds()` call — which the generation check already handles.

3. **URL validation (`url_validate.lua`)**: **Uses request coalescing + TTL-based cache, not raw async.** The `url_pool` request coalescer (line 13) deduplicates identical in-flight curl requests. Cache staleness is TTL-based with status-specific lifetimes configured via `config.url_validation.cache_ttl` — separate TTLs for `network_error`, `success` (2xx), `redirect` (3xx), `client_error` (4xx), and `server_error` (5xx) (lines 175-192 in `cache_valid()` function). Results are applied via `vim.diagnostic.set()` in `linkdiag.lua`. Domain rate limiting via `domain_cooldown_ms` config with per-domain cooldown (lines 18-31 in `get_limiter()`, submitted at lines 405-409 with domain extracted by `url_domain()` at lines 146-148) prevents thundering herd. The remaining gap: if the user edits a link's URL text while a validation is in flight, the result may be applied to a URL that no longer matches. However, the next `linkdiag.validate(bufnr)` call re-extracts URLs from the buffer, so stale diagnostics are self-correcting on the next trigger.

4. **Completion build (`completion_base.lua`)**: **Has dual generation tracking + cancellation.** Compares `_cached_gen` (line 172) against `vault_index._generation` (lines 334-339) for cache validity. Also maintains a local `build_generation` counter (line 173) to detect concurrent builds, incremented on `invalidate()` (line 221). Cancellation via `active_state.cancelled` flag (lines 346-354 in `cancel_active()`) checked at each coroutine yield (lines 409, 425, 439, 485-490). Debounce via `cleanup.debounce()` (lines 407, 437) with configurable `debounce_ms` (default 250ms, line 179). Additionally detects index mid-rebuild via `index_is_building()` (lines 195-213) with 30-second configurable timeout fallback. Also has a separate `_field_cache` memoization layer keyed by `(vault_path, field_name)` validated via `filter_utils.is_cache_gen_valid()` (lines 619-627).

5. **Connections scoring (`connections.lua`)**: **Already has generation-based staleness + subscriber system.** Cache validity checks both `filter_utils.is_cache_gen_valid(cached, index_gen, "index_gen")` and TTL (lines 704-713 in `compute()`). Subscribes to vault index updates via `on_index_update()` (lines 949-978) with tiered invalidation: full rebuild on `ctx.tier == "full"` or nil context, incremental removal on `ctx.tier == "partial"` (tracking changed/deleted files via `_pending_changed`), no-op on `ctx.tier == "additive"`. Subscription registered at lines 983-988 with interests `{ "tags", "outlinks", "frontmatter", "aliases" }` and `weak_state` defense-in-depth for safe unloading. Note data cache tracks `_note_data_gen` (line 57) separately with incremental invalidation logic at lines 651-664. Async path uses `yield_iter.run_async()` with request coalescing via `conn_pool` (line 17, used at lines 775-804).

6. **Wikilinks (`wikilinks.lua`)**: **Fully synchronous — no async resolution exists.** `resolve_link()` (lines 162-189) performs synchronous index lookup via `link_utils.resolve_note_via_index()` (line 170), with fallback to `resolve_relative()` for path-like links (lines 164-166) and `resolve_temporal()` for temporal aliases (lines 183-185). If the index is not ready, it returns an error string immediately (lines 175-180). No queue, no callback registration, no `wait_for_ready` integration. The `follow_link()` handler (lines 245-400) is entirely synchronous, handling wikilinks (lines 247-345), markdown links (lines 349-385), and bare URLs (lines 388-391). **This module does not need an operation tracker.**

### Summary of Existing Mitigations

| Module | Staleness Pattern | Cancellation | Gaps |
|--------|------------------|--------------|------|
| `search/advanced.lua` | `_search_generation` counter (line 16) + race guard (lines 41, 150) | `_active_eval_cancel()` (line 11) + `semaphore_reset()` (line 387) | Pattern is module-private, non-reusable |
| `embed.lua` | Per-buffer `generation` counter (line 560) + `check_generation()` (line 404) | Request coalescing via `embed_pool` (line 22, usage lines 469-475) | Minimal — reads are sync |
| `url_validate.lua` | TTL cache via `cache_valid()` (lines 172-192) + request coalescing via `url_pool` (line 13) | Coalescer dedup + rate limiter (lines 18-31) | Stale diagnostics self-correct on next trigger |
| `completion_base.lua` | `_cached_gen` vs `_generation` (line 334) + `build_generation` (line 173) + `_field_cache` (line 619) | `active_state.cancelled` flag (line 346) | Coupled to vault_index internals |
| `connections.lua` | `is_cache_gen_valid()` (line 707) + TTL + subscriber tiers (line 949) + dependency cascade (lines 1016-1030) | Request coalescing via `conn_pool` (line 17) | Pattern works but uses different primitives than search |
| `wikilinks.lua` | N/A (fully synchronous) | N/A | None — no async ops |

The problem is not missing staleness detection — most modules have it. The problem is **six different patterns** for the same concept, making the codebase harder to reason about and increasing the chance of bugs when adding new async operations.

## Inspiration

### Zed's git_store.rs — Dual Operation Counters

**File:** `crates/project/src/git_store.rs`

The `BufferGitState` struct (lines 109-110) uses dual counters:

```rust
hunk_staging_operation_count: usize,
hunk_staging_operation_count_as_of_write: usize,
```

Documented at lines 101-108:

```rust
/// These operation counts are used to ensure that head and index text
/// values read from the git repository are up-to-date with any hunk staging
/// operations that have been performed on the BufferDiff.
///
/// The operation count is incremented immediately when the user initiates a
/// hunk stage/unstage operation. Then, upon finishing writing the new index
/// text do disk, the `operation count as of write` is updated to reflect
/// the operation count that prompted the write.
```

**Lifecycle:**
1. **Increment** (lines 1337-1339): `diff_state.hunk_staging_operation_count += 1` — immediate on user action, captured value passed to write job (line 1347).
2. **Staleness check** (line 2443): `this.hunk_staging_operation_count > prev_hunk_staging_operation_count` — if counter advanced since recalculation started, cancel the recalculation to avoid invalidating pending state. The comparison value is captured from `hunk_staging_operation_count_as_of_write` at line 2386. Another recalculation will come along later.
3. **Write completion** (lines 3759-3760): `diff_state.hunk_staging_operation_count_as_of_write = hunk_staging_operation_count` — updates the "as of write" counter after disk write finishes.

Both counters initialize at 0 (lines 2205-2206).

### Zed's inlay_hint_cache.rs — Monotonic Version + Vector Clock

**File:** `crates/editor/src/inlay_hint_cache.rs`

The `InlayHintCache` struct (lines 34-46) maintains a `version: usize` counter (line 37). Per-excerpt caches (`CachedExcerptHints`, lines 55-61) track both a cache version and a `buffer_version: Global` (vector clock from `crates/clock/src/clock.rs`).

**Staleness uses two independent conditions** (lines 698-706):

```rust
if cached_excerpt_hints.version > update_cache_version
    || cached_buffer_version.changed_since(&new_task_buffer_version)
{
    continue;  // Skip — cache is stale
}
```

1. **Cache version advanced** beyond the update's snapshot → update is superseded by a newer invalidation.
2. **Buffer changed** since the LSP query started → buffer edits outpaced the async response.

Version ordering check on apply (lines 1205-1210): `Less` → discard; `Greater|Equal` → apply and update cached version.

Counter increments at: line 322 (hint kinds change), line 571 (excerpts removed), line 581 (cache cleared). Before spawning LSP queries, captures `cache_version = self.version + 1` (line 407).

Both Zed patterns share the same principle: **monotonically increasing identifiers make staleness detection a simple integer comparison**. The vault codebase has already converged on this pattern independently (e.g., `_search_generation`, embed `generation`, vault index `_generation`) — but each module re-invented it ad-hoc.

## Design

A lightweight, reusable `OperationTracker` module that encapsulates the dual-counter pattern:

### Core Mechanics

```
                   start()         start()
Timeline:   ──────┤op_id=1├───────┤op_id=2├──────►
                   │               │
                   │  async work   │  async work
                   │               │
                   ▼               ▼
            result arrives   result arrives
            is_stale(1)?     is_stale(2)?
            → YES (2 > 1)    → NO (2 == 2)
            → discard        → apply
```

- **Monotonic counter**: A single integer, incremented on each `start()` call. The returned `operation_id` is the counter's value at the time of the call.
- **Staleness check**: `is_stale(op_id)` returns `true` if `op_id < counter` — meaning a newer operation has been started since this one began.
- **Currency check**: `is_current(op_id)` returns `true` if `op_id == counter` — meaning no newer operation has superseded this one.
- **No locking needed**: All operations run on the Neovim main thread (via `vim.schedule`). The counter is a plain integer with no concurrent access.

### Distinction from Doc 21 (Stale Operation Cancellation)

Doc 21 focuses on **cancelling in-flight work** — killing ripgrep processes, aborting coroutines, stopping timers. This is about **resource reclamation** during execution.

Doc 41 focuses on **detecting staleness upon completion** — when async work finishes naturally, determining whether its result should be applied or discarded. This is about **result validity** after execution.

The two patterns are complementary:
- Doc 21: "Stop doing work that's no longer needed" (proactive).
- Doc 41: "Don't use results from work that's been superseded" (reactive).

A module can use both: cancel old operations when possible (doc 21), and detect staleness for operations that can't be cancelled (doc 41).

## Target Operations

### Refactoring Priority

The goal is not to add staleness detection where none exists — most modules already have it. The goal is to **replace ad-hoc per-module counters with a shared `OperationTracker`** so the pattern is recognizable, consistent, and reusable.

| Module | Current Pattern | Refactor Value |
|--------|----------------|----------------|
| `search/advanced.lua` | Module-private `_search_generation` counter | **High** — replaces 15+ lines with 3-line tracker usage |
| `completion_base.lua` | Dual tracking (`_cached_gen` + `build_generation`) | **Medium** — decouples from vault_index internals |
| `connections.lua` | `is_cache_gen_valid()` + subscriber tiers | **Low** — existing pattern works well, subscriber system is orthogonal |
| `embed.lua` | Per-buffer generation counter + `check_generation()` | **Low** — reads are sync, existing pattern is simple |
| `url_validate.lua` | TTL cache + request coalescing | **None** — staleness is TTL-based, not operation-based |
| `wikilinks.lua` | N/A (fully synchronous) | **None** — no async operations to track |

### 1. search/advanced.lua — Async query staleness (PRIMARY TARGET)

**Current code** (search/advanced.lua:11, 16, 25-46):

```lua
local _active_eval_cancel = nil  -- line 11
-- ...
local _search_generation = 0  -- line 16

local function eval_async_cancellable(metadata_ast, idx, graph_sets, restrict_to, callback)  -- line 25
  local cancelled = false
  if _active_eval_cancel then _active_eval_cancel() end
  _search_generation = _search_generation + 1
  local my_gen = _search_generation
  _active_eval_cancel = function() cancelled = true end

  search_filter.evaluate_async(metadata_ast, idx, {
    graph_sets = graph_sets,
    restrict_to = restrict_to,
    cancelled = function() return cancelled end,
    callback = function(matches, limit_reached)
      _active_eval_cancel = nil
      if cancelled then return end
      if _search_generation ~= my_gen then return end  -- race guard
      callback(matches, limit_reached)
    end,
  })
  return my_gen
end
```

**Refactored with OperationTracker:**

```lua
local operation_tracker = require("andrew.vault.operation_tracker")
local search_ops = operation_tracker.new()

local function eval_async_cancellable(ast, ...)
  if _active_eval_cancel then _active_eval_cancel() end
  local op_id = search_ops:start()
  -- ...
  vim.schedule(function()
    if search_ops:is_stale(op_id) then return end
    on_done(result)
  end)
end
```

Similarly for `dispatch_ripgrep()` (lines 146-157) which has its own `gen` parameter race guard (line 150: `if gen and _search_generation ~= gen then return end`). The generation is also incremented independently for text-only mode (lines 207-208) and mixed-or fallback mode (lines 264-265).

### 2. completion_base.lua — Build generation tracking

**Current code** (completion_base.lua:172-173, 221, 334-339, 365, 394, 485-490):

```lua
-- Declaration (lines 172-173)
local _cached_gen = nil        -- vault_index._generation at last build
local build_generation = 0     -- internal invalidation counter

-- Invalidation (line 221)
build_generation = build_generation + 1

-- Cache validity check (lines 334-339)
local vault_index = package.loaded["andrew.vault.vault_index"]
if vault_index then
  local idx = vault_index.current()
  if idx and idx._generation ~= _cached_gen then
    return false
  end
end

-- Capture at build start (line 365)
local gen = build_generation

-- After build (line 394)
if idx then _cached_gen = idx._generation end

-- Cancelled check in yield_iter (lines 485-490)
cancelled = function()
  if state.cancelled or gen ~= build_generation then
    active_state = nil
    return true
  end
  return false
end,
```

**Refactored:** The tracker replaces the `build_generation` counter for detecting concurrent builds. The `_cached_gen` vs `idx._generation` check is a different concern (index freshness, not operation staleness) and should remain as-is. The `_field_cache` memoization (lines 619-627) using `filter_utils.is_cache_gen_valid()` is also a separate concern.

```lua
local build_ops = operation_tracker.new()

-- In build_items_async:
local op_id = build_ops:start()
-- ...in cancelled() callback:
if build_ops:is_stale(op_id) then return true end
```

### 3. connections.lua — Score computation staleness (OPTIONAL)

The existing `is_cache_gen_valid()` (line 707) + subscriber system (lines 949-988) is already robust. Refactoring to use `OperationTracker` would only replace the `_note_data_gen` tracking (line 57, invalidation logic at lines 651-664). Low value given the complexity of the subscriber tier system with its `_pending_changed` / `_pending_full_clear` (lines 60-61) incremental invalidation and dependency-based cascade invalidation (lines 1016-1030).

### 4. embed.lua — NOT A TARGET

All reads are synchronous via `file_cache.read()` (lines 210-217, uses `io.open()` + mtime validation). The per-buffer `generation` counter in `state._embed_descriptors[bufnr]` (lines 560-561) with `check_generation()` (lines 404-409) is simple and correct. Request coalescing via `embed_pool` (declared line 22, usage at lines 469-475) handles dedup with synchronous `resolve_now()`. No refactoring needed.

### 5. wikilinks.lua — NOT A TARGET

Fully synchronous. `resolve_link()` (lines 162-189) performs synchronous index lookup and returns an error string if index is not ready. No async operations exist in this module.

## Implementation Steps

### Step 1: Create operation_tracker.lua module

```lua
-- lua/andrew/vault/operation_tracker.lua
local M = {}
M.__index = M

function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    _counter = 0,
    _stats_enabled = opts.stats_enabled or false,
    _stats = {
      started = 0,
      completed = 0,
      discarded = 0,
    },
  }, M)
  return self
end
```

### Step 2: Implement start() — begin a new operation

```lua
function M:start()
  -- Guard against overflow (practically impossible but safe)
  if self._counter >= math.maxinteger then
    self._counter = 0
  end

  self._counter = self._counter + 1

  if self._stats_enabled then
    self._stats.started = self._stats.started + 1
  end

  return self._counter
end
```

### Step 3: Implement staleness checks

```lua
function M:is_current(operation_id)
  return operation_id == self._counter
end

function M:is_stale(operation_id)
  local stale = operation_id < self._counter
  if stale and self._stats_enabled then
    self._stats.discarded = self._stats.discarded + 1
  end
  return stale
end
```

### Step 4: Implement completion tracking and debug API

```lua
function M:complete(operation_id)
  -- Optional: explicitly mark an operation as completed for stats
  if self._stats_enabled then
    self._stats.completed = self._stats.completed + 1
  end
  return self:is_current(operation_id)
end

function M:current()
  return self._counter
end

function M:stats()
  return vim.deepcopy(self._stats)
end

function M:reset()
  self._counter = 0
  self._stats = {
    started = 0,
    completed = 0,
    discarded = 0,
  }
end
```

### Step 5: Add a convenience wrapper for the common pattern

```lua
function M:wrap(fn)
  -- Returns a wrapped function that auto-checks staleness
  -- Usage: tracker:wrap(function(op_id) ... end)
  local op_id = self:start()
  return function(...)
    if self:is_stale(op_id) then
      return nil, "stale"
    end
    return fn(op_id, ...)
  end, op_id
end
```

This allows a more ergonomic usage pattern:

```lua
local callback, op_id = search_ops:wrap(function(op_id, results)
  display_results(results)
end)

ripgrep_async(query, callback)
```

### Step 6: Add config entry

```lua
-- In config.lua
M.operation_tracker = {
  stats_enabled = false,  -- Enable discard/completion counting for debugging
}
```

### Step 7: Integrate into search/advanced.lua (primary target)

Replace the module-private `_search_generation` counter and race guard pattern:

```lua
-- BEFORE (search/advanced.lua lines 11, 16, 25-46):
local _active_eval_cancel = nil  -- line 11
local _search_generation = 0     -- line 16

local function eval_async_cancellable(metadata_ast, idx, graph_sets, restrict_to, callback)
  local cancelled = false
  if _active_eval_cancel then _active_eval_cancel() end
  _search_generation = _search_generation + 1
  local my_gen = _search_generation
  _active_eval_cancel = function() cancelled = true end
  -- ... async work via search_filter.evaluate_async ...
  if _search_generation ~= my_gen then return end
end

-- AFTER:
local operation_tracker = require("andrew.vault.operation_tracker")
local search_ops = operation_tracker.new()
-- Expose for debug command
M._ops = search_ops

local function eval_async_cancellable(metadata_ast, idx, graph_sets, restrict_to, callback)
  local cancelled = false
  if _active_eval_cancel then _active_eval_cancel() end
  local op_id = search_ops:start()
  _active_eval_cancel = function() cancelled = true end
  -- ... async work via search_filter.evaluate_async ...
  if search_ops:is_stale(op_id) then return end
end
```

Also refactor `dispatch_ripgrep()` (lines 146-157) which passes `gen` to the ripgrep callback for its own race guard (line 150), and the text-only (lines 207-208) and mixed-or (lines 264-265) generation increments.

### Step 8: Integrate into completion_base.lua (secondary target)

Replace the `build_generation` counter used for concurrent build detection. Keep the `_cached_gen` vs `idx._generation` check (different concern — index freshness).

### Step 9: Add debug command

Register via the existing command pattern in `init.lua` (following the dual-registration pattern at lines 735+: `nvim_create_user_command` + `palette.register_command`) and `palette.register_command()`:

```lua
-- In init.lua command registration section
vim.api.nvim_create_user_command("VaultOpsDebug", function()
  local lines = { "Operation Tracker Stats", "" }
  local trackers = {
    { name = "search", tracker = require("andrew.vault.search.advanced")._ops },
    { name = "completion", tracker = require("andrew.vault.completion_base")._ops },
  }
  for _, t in ipairs(trackers) do
    if t.tracker then
      local s = t.tracker:stats()
      table.insert(lines, string.format(
        "%s: counter=%d started=%d completed=%d discarded=%d",
        t.name, t.tracker:current(), s.started, s.completed, s.discarded
      ))
    end
  end
  -- Display in scratch buffer (following VaultCacheStatus pattern)
end, {})

palette.register_command("VaultOpsDebug", "Show operation tracker stats", "Debug",
  function() vim.cmd("VaultOpsDebug") end)
```

## API

```lua
local ops = require("andrew.vault.operation_tracker")

-- Create a per-module tracker
local search_ops = ops.new({ stats_enabled = true })

-- Before async work: get an operation ID
local op_id = search_ops:start()

-- In async callback: check if result is still relevant
ripgrep_async(query, function(results)
  if search_ops:is_stale(op_id) then
    return  -- Discard stale results
  end
  display_results(results)
end)

-- Alternative: use wrap() for automatic staleness checking
local callback, op_id = search_ops:wrap(function(op_id, results)
  display_results(results)
end)
ripgrep_async(query, callback)

-- Explicit completion tracking (optional, for stats)
search_ops:complete(op_id)

-- Debug queries
search_ops:current()     -- Current counter value
search_ops:stats()       -- {started = 42, completed = 38, discarded = 4}
search_ops:reset()       -- Reset counter and stats to zero
```

### Comparison with Existing Patterns

The tracker replaces these existing ad-hoc patterns:

| Existing Pattern | Where | Equivalent Tracker Call |
|-----------------|-------|----------------------|
| `_search_generation = _search_generation + 1` | search/advanced.lua:28, 207, 264 | `search_ops:start()` |
| `_search_generation ~= my_gen` | search/advanced.lua:41 | `search_ops:is_stale(op_id)` |
| `gen and _search_generation ~= gen` | search/advanced.lua:150 | `search_ops:is_stale(op_id)` |
| `gen ~= build_generation` | completion_base.lua:485-490 | `build_ops:is_stale(op_id)` |

## Relationship to Existing Patterns

### Formalizing search/advanced.lua's generation counter

`search/advanced.lua` currently implements the exact same pattern as `OperationTracker` but inline:

```lua
-- Current (search/advanced.lua:16, 28-29, 41)
local _search_generation = 0  -- ≡ OperationTracker._counter

_search_generation = _search_generation + 1  -- ≡ tracker:start()
local my_gen = _search_generation             -- ≡ op_id

if _search_generation ~= my_gen then return end  -- ≡ tracker:is_stale(op_id)
```

This is **functionally identical** to OperationTracker but:
- **Module-private** — can't be reused or inspected.
- **Mixed with cancellation logic** — `_active_eval_cancel` handling is interleaved.
- **Missing stats** — no tracking of how often staleness is detected.

### Clarifying completion_base.lua's two concerns

`completion_base.lua` has **three separate staleness mechanisms** that should remain distinct:

1. **Index freshness** (`_cached_gen` vs `vault_index._generation`, lines 334-339): "Has the vault index changed since we last built completions?" — This is a **cache invalidation trigger**, not an operation counter. It should remain as-is.

2. **Build concurrency** (`build_generation` + `active_state.cancelled`, lines 173, 365, 485-490): "Has a newer build been started since this one began?" — This IS the operation counter pattern and can be replaced by `OperationTracker`.

3. **Field cache memoization** (`_field_cache` + `filter_utils.is_cache_gen_valid()`, lines 619-627): "Has the vault index changed since we cached this field lookup?" — This is a **per-key cache invalidation** concern, orthogonal to operation tracking. It should remain as-is.

### Complementing doc 21 (Stale Operation Cancellation)

| Aspect | Doc 21 | Doc 41 |
|--------|--------|--------|
| When | During execution | After completion |
| Action | Kill/abort work | Discard result |
| Goal | Save resources | Prevent stale display |
| Mechanism | Process kill, coroutine cancel | Counter comparison |

The codebase already uses both patterns together in `search/advanced.lua`:
- Doc 21: `_active_eval_cancel()` kills in-flight metadata evaluation; `semaphore_reset()` cancels queued ripgrep processes.
- Doc 41: `_search_generation` race guard discards results from superseded queries.

A robust async pipeline uses both: cancel what you can (doc 21), detect staleness for what you can't cancel (doc 41).

## Configuration

```lua
-- config.lua
M.operation_tracker = {
  stats_enabled = false,  -- Track started/completed/discarded counts
}
```

The `stats_enabled` flag defaults to `false` because the discard counting in `is_stale()` adds a conditional branch to every staleness check. While negligible in absolute terms, there is no reason to pay this cost in normal operation. Enable it for debugging via `:VaultOpsDebug` or when investigating race conditions.

## Expected Impact

- **Consistent pattern across codebase**: Replace the ad-hoc `_search_generation` counter and `build_generation` tracking with a shared, recognizable primitive. New async modules can adopt staleness detection by creating a tracker instance rather than re-inventing the pattern.
- **Reduced code in search/advanced.lua**: The `_search_generation` variable, increment, capture, and race guard (~15 lines across `eval_async_cancellable` and `dispatch_ripgrep`) collapse to 3 lines using the tracker API.
- **Decoupled completion staleness**: `completion_base.lua`'s `build_generation` counter is replaced by a tracker, separating "is this build superseded?" (tracker) from "has the index changed?" (`_cached_gen`).
- **Observable async behavior**: With `stats_enabled`, the `:VaultOpsDebug` command shows exactly how often staleness is detected in each module, informing decisions about debounce tuning.
- **No change to modules that don't need it**: `embed.lua` (sync reads, existing generation check), `url_validate.lua` (TTL cache + coalescer), `wikilinks.lua` (fully sync), and `connections.lua` (subscriber system + dependency cascade invalidation) are left as-is.

## Risks

1. **Counter overflow**: `math.maxinteger` in LuaJIT is `2^63 - 1` for 64-bit integers (or `2^53 - 1` for doubles in standard Lua 5.3+). At 1000 operations per second, overflow would take ~285 million years. The implementation includes a reset-to-zero guard as a safety measure, though it will never trigger in practice.

2. **False staleness from unnecessary start() calls**: If a module calls `start()` without actually initiating new work (e.g., in a no-op code path), all in-flight operations become falsely stale. This is a usage error, not a design flaw. The mitigation is clear documentation: only call `start()` when genuinely beginning a new operation that supersedes previous ones.

3. **Stats memory**: The stats table is three integers — negligible. No risk of unbounded growth.

4. **Module coupling via _ops field**: The `:VaultOpsDebug` command accesses `_ops` fields on other modules. This follows the existing pattern in the codebase (e.g., `VaultCacheStatus` accesses registered cache stats, `VaultIndexStatus` accesses index internals). Debug-only coupling is acceptable; if modules are refactored, the debug command simply shows `nil` for missing trackers.

5. **Scope creep**: The tracker should only replace the specific ad-hoc counters identified (`_search_generation`, `build_generation`). It should NOT replace `vault_index._generation` (which serves a different purpose: index versioning for cache invalidation triggers) or embed.lua's per-buffer generation (which is tightly integrated with descriptor state management and works well as-is).
