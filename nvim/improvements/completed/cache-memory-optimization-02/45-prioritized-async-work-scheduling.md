# 45. Prioritized Async Work Scheduling

## Priority: MEDIUM
## Inspired By: Zed's `inlay_hint_cache.rs` visible-range-first fetching, `cx.spawn` vs `cx.background_spawn`
## Dependencies: Document 14 (Cooperative Yielding), Document 21 (Stale Cancellation), Document 26 (Viewport Rendering)

---

## Problem

The vault plugin treats all async work as equal. When multiple operations are pending —
index build, completion refresh, embed render, highlight update — they execute in arbitrary
order based on which timer or `vim.schedule` callback fires first. There is no mechanism to
ensure user-visible work completes before background maintenance.

### Current Async Landscape

Every async operation goes through one of several Neovim scheduling primitives and
vault-layer abstractions:

| Primitive / Abstraction | Current Users | Semantics |
|-----------|--------------|-----------|
| `vim.schedule()` | yield_iter.run_async (coroutine stepping), engine.lua (UI callback wrapping), request_coalescer (resolve/reject), embed.lua (index-ready callbacks), rate_limiter (drain trigger), vault_log (notify), guard.lua (leak warnings) | Next event loop tick |
| `vim.defer_fn(fn, ms)` | engine.lua (line 684, UI callback), init.lua (lines 798/811, init steps), embed.lua (line 1067, scroll render), embed_images.lua (line 292, image render), engine_watcher.lua (lines 119/248, 1ms FS event flush), search.lua (line 164, picker display), tasks.lua (line 98, task UI update) | Fixed delay |
| `vim.uv.new_timer()` | request_coalescer (30s timeout, 100ms linger), rate_limiter (100ms repeating drain), event_coalescer (16ms adaptive), watch_channel (0ms coalesce) | Repeating or one-shot |
| `cleanup.debounce()` | embed.lua (config.embed.lazy_scroll_debounce_ms scroll), autosave.lua (config-driven), engine_watcher.lua (100ms fs), url_validate.lua (config-driven persist), vault_index.lua (config.index.persist_debounce_ms persist), vault_index_collisions.lua (config-driven notify), init.lua (200ms focus), viewport.lua (config-driven prefetch), task_hierarchy.lua (config-driven update), completion_base.lua (lines 418/448, config.completion.debounce_ms) | One-shot timer with auto-close of previous |
| `yield_iter.run_async()` | vault_index_build.lua, completion_base.lua, search_filter.lua, connections.lua, bfs.lua | Coroutine with vim.schedule stepping |
| `watch_channel` | highlight_coordinator (0ms coalesce), sidebar.lua, engine_watcher.lua, embed_sync.lua | Within-tick coalescing, next-tick fire |
| `event_coalescer` | event_dispatch.lua BufEnter (16ms base, 200ms rapid) | Adaptive batching with rapid-switch detection |
| `request_coalescer` | embed.lua (render dedup, line 500), vault_index_build.lua (build dedup, line 367), url_validate.lua, connections.lua, search_filter.lua | Pool-based operation deduplication with waiter queues, per-pool timeout (30s), done_linger (100ms) |

All these funnel into the same Neovim event loop with no priority ordering. A deferred
embed render for an off-screen note and a completion popup update for the active cursor
compete equally for event loop time.

### Concrete Problem Scenarios

**Scenario 1: BufEnter on a large note**

```
User opens note.md (3000 lines, 40 embeds, 200 wikilinks):
  t=0ms    BufReadPost fires
  t=0ms    embed.lua sets state.embeds_visible[buf] = "pending", waits for index ready
  t=0ms    event_dispatch BufEnter coalescer queues (16ms adaptive delay)
  t=0ms    vault_index may be mid-build (yield_iter.run_async stepping)
  t=16ms   BufEnter coalescer fires → dispatches to embed.on_buf_enter, breadcrumbs, frecency
  t=16ms   highlight_coordinator.schedule(bufnr) → watch_channel queues, fires next tick
  t=17ms   highlight run_all() scans visible zone via transform_pipeline
  t=17ms   ← highlight scan competes with index build coroutine resumes
  t=50ms   index ready → embed render_embeds fires via vim.schedule
  t=50ms   ← embed render (request_coalescer, visible+prefetch) competes with completion
  t=200ms  User starts typing → completion triggers build_iter coroutine (250ms debounce)
  t=450ms  ← completion build competes with still-running deferred embed work
```

The user sees: sluggish completion popup (blocked behind embed I/O and index stepping),
highlights appearing in chunks (interleaved with index coroutine), and image placements
popping in randomly.

**Scenario 2: Rapid navigation between notes**

```
User presses gf three times quickly:
  t=0ms    BufEnter note-A → event_coalescer queues (16ms)
  t=16ms   BufEnter note-A dispatched → embed, highlights scheduled
  t=50ms   BufEnter note-B → event_coalescer detects rapid switching (< 50ms threshold)
  t=100ms  BufEnter note-C → event_coalescer extends to 200ms delay (rapid_delay_ms)
  t=116ms  note-A highlight fires (watch_channel 0ms + run_all) → wasted work
  t=150ms  note-A embed fires → wasted work (generation check may catch this)
  t=300ms  note-C coalescer fires → user's actual buffer finally gets dispatched
```

The event_coalescer's adaptive delay helps (config.events.rapid_switch_delay_ms=200ms vs
config.events.buf_enter_coalesce_ms=16ms during rapid switching, with
config.events.rapid_switch_threshold_ms=50ms detection), but once dispatched, note-A's
embed and highlight work still occupies the event loop. Embed.lua's generation counter
and request_coalescer skip stale work at execution time, but the scheduling slots are
still consumed.

**Scenario 3: Typing during index rebuild**

```
vault_index_build.build_async() via yield_iter.run_async() (line 377):
  t=0ms    coroutine.resume() → parse adaptive batch (TARGET_MS=16, MIN_BATCH=5) → yield → vim.schedule(step)
  t=16ms   vim.schedule fires step (yield_iter.lua line 121/128) → parse next batch → yield → vim.schedule(step)
  ...repeated for 10K entries...
  t=50ms   User types → completion_base triggers build_iter (config.completion.debounce_ms=250 timer starts)
  t=300ms  completion debounce fires → yield_iter.run_async() (line 487) for completion build
  t=300ms  ← completion coroutine step queued behind index build's next vim.schedule(step)
  t=316ms  Index build step fires (was scheduled first, targets 16ms per batch via compute_batch_size)
  t=332ms  Completion step fires (delayed by one index batch)
```

The index build's adaptive batching (targeting 16ms per yield) means each batch consumes
a significant event loop slot. Completion's coroutine is interleaved but never prioritized,
causing perceptible lag in the popup appearing.

### Why This Matters

Neovim's event loop is single-threaded. Every `vim.schedule` callback, timer, and
`defer_fn` runs on the same thread. Without priority ordering, the user's perceived
responsiveness is governed by the longest-running background task, not by the importance
of what they're actually looking at.

### Existing Partial Solutions

The vault already has several mechanisms that partially address this:

| Mechanism | Module | What It Does | What It Doesn't Do |
|-----------|--------|-------------|-------------------|
| **Watch channel** (0ms coalesce) | highlight_coordinator, sidebar, engine_watcher, embed_sync | Coalesces within-tick events, fires next tick | Doesn't prioritize over other vim.schedule callbacks |
| **Event coalescer** (adaptive delay) | event_dispatch (config.events.buf_enter_coalesce_ms=16, rapid=200) | Extends delay during rapid switching (16ms→200ms) | Doesn't order events by importance |
| **Generation counter** | embed.lua | Skips stale render callbacks | Doesn't prevent scheduling the stale work |
| **Operation tracker** | completion_base, embed | Detects superseded builds at execution time | Work still occupies queue slots |
| **Request coalescer** | embed.lua, vault_index_build, url_validate, connections, search_filter | Deduplicates concurrent identical operations (pool-based, 30s timeout, 100ms linger) | Doesn't prioritize between different operations |
| **Rate limiter** | url_validate | Priority queue with per-domain throttling | Only for external HTTP requests |
| **Viewport zones** | viewport.lua, highlight_coordinator | Three-zone rendering (visible/above/below) | Visible and prefetch both use same scheduling tier |
| **Lazy embed rendering** | embed.lua | Renders visible zone first, defers off-screen | Off-screen deferred via same vim.schedule pool |
| **Region tracker** | region_tracker.lua | Tracks invalid ranges for incremental re-render | Doesn't affect scheduling priority |

The gap: these mechanisms handle **deduplication**, **staleness**, and **scope restriction**,
but none handle **inter-operation priority ordering**.

## Zed Reference

### inlay_hint_cache.rs — Visible-Range-First Fetching

Zed's inlay hint system explicitly prioritizes visible content over background content
(crates/editor/src/inlay_hint_cache.rs):

```rust
// Lines 840-841
const MAX_CONCURRENT_LSP_REQUESTS: usize = 5;
const INVISIBLE_RANGES_HINTS_REQUEST_DELAY_MILLIS: u64 = 400;
```

The core priority mechanism lives in `new_update_task()` (lines 843-926):

```rust
fn new_update_task(
    query: ExcerptQuery,
    query_ranges: QueryRanges,
    excerpt_buffer: Entity<Buffer>,
    cx: &mut Context<Editor>,
) -> Task<()> {
    cx.spawn(async move |editor, cx| {
        // PHASE 1: Fetch visible ranges IMMEDIATELY (parallel, no semaphore)
        let visible_range_update_results = future::join_all(
            query_ranges.visible.into_iter().filter_map(|visible_range| {
                let fetch_task = editor.update(cx, |_, cx| {
                    fetch_and_update_hints(
                        excerpt_buffer.clone(), query, visible_range.clone(),
                        query.invalidate.should_invalidate(), cx,
                    )
                }).log_err()?;
                Some(async move { (visible_range, fetch_task.await) })
            }),
        ).await;

        // Start 400ms timer (non-blocking: other tasks can run)
        let hint_delay = cx.background_executor().timer(Duration::from_millis(
            INVISIBLE_RANGES_HINTS_REQUEST_DELAY_MILLIS,
        ));

        // Process visible results while waiting
        for (range, result) in visible_range_update_results {
            if let Err(e) = result { query_range_failed(&range, e, cx); }
        }

        // PHASE 2: Wait for delay, then fetch invisible ranges
        hint_delay.await;

        let invisible_range_update_results = future::join_all(
            query_ranges.before_visible.into_iter()
                .chain(query_ranges.after_visible.into_iter())
                .filter_map(|invisible_range| {
                    let fetch_task = editor.update(cx, |_, cx| {
                        fetch_and_update_hints(
                            excerpt_buffer.clone(), query, invisible_range.clone(),
                            false, // visible already invalidated
                            cx,
                        )
                    }).log_err()?;
                    Some(async move { (invisible_range, fetch_task.await) })
                }),
        ).await;
    })
}
```

Key insights from current Zed implementation:

1. **Visible work runs first and completes** before off-screen work even starts
2. **400ms delay** between phases ensures event loop is free for user interaction
3. **Semaphore bypass for visible ranges** (lines 937-951): visible ranges skip the
   `lsp_request_limiter` semaphore entirely, while invisible ranges must acquire a permit
4. **Stale invisible cancellation** (lines 958-978): if a throttled invisible request's
   viewport has scrolled away (by >2x visible range via `double_visible_range` at line 964), the request is cancelled entirely (line 978: `query_not_around_visible_range`)
5. **Three-zone range computation** (lines 750-753): `QueryRanges` struct holds
   `before_visible`, `visible`, `after_visible` — each extending by the visible range length

### cx.spawn vs cx.background_spawn

Zed distinguishes between work that needs the UI thread and work that can run in the
background via a dual-executor model (crates/gpui/src/executor.rs):

```rust
// ForegroundExecutor — main thread, futures need NOT be Send (line 459)
// Uses PhantomData<Rc<()>> (line 47) to enforce !Send
// Used for UI updates, state mutations, editor access
impl ForegroundExecutor {
    pub fn spawn<R>(&self, future: impl Future<Output = R> + 'static) -> Task<R>
    where R: 'static
    {
        // ... dispatch_on_main_thread(runnable) ...
    }
}

// BackgroundExecutor — thread pool, futures MUST be Send + 'static (line 145)
// Used for I/O, computation, networking
impl BackgroundExecutor {
    pub fn spawn<R>(&self, future: impl Future<Output = R> + Send + 'static) -> Task<R>
    where R: Send + 'static
    {
        // ... dispatch(runnable, label) ...
    }
}
```

In the inlay hint cache, this manifests as:

```rust
// Main thread: coordinate LSP requests and update cache (cx.spawn used at lines 415, 629, 849, 935)
cx.spawn(async move |editor, cx| {
    // Phase 1 visible, Phase 2 invisible...
});

// Background thread: expensive hint comparison only (cx.background_spawn at line 1044)
let new_update = cx.background_spawn(async move {
    calculate_hint_updates(
        query.excerpt_id, invalidate, fetch_range,
        new_hints, &buffer_snapshot, cached_hints, &visible_hints,
    )
}).await;
```

While Neovim doesn't have background threads, the principle maps to scheduling priority:
UI-critical work should execute before computational background work within the same
event loop. The vault's existing `yield_iter.run_async()` pattern (vim.schedule stepping)
is analogous to Zed's main-thread spawning.

### Additional Zed Patterns

**Semaphore-based request limiting** (field at line 45, initialized at line 277, used at lines 937-942):
```rust
lsp_request_limiter: Arc::new(Semaphore::new(MAX_CONCURRENT_LSP_REQUESTS)),
```
Maps to the vault's existing `rate_limiter.lua` pattern with per-domain concurrency caps.

**TaskLabel for test deprioritization** (lines 113-128 in executor.rs): Zed's `TaskLabel` system (opaque `NonZeroUsize` identifier) enables deterministic test ordering via `spawn_labeled()` (line 154-163) and test-only `deprioritize()` (line 377), but has no runtime priority effect in production — priorities are structural (visible-first phasing) not label-based.

**Debounce at spawn level** (lines 379-432): `spawn_hint_refresh()` applies debounce
*before* spawning update tasks (lines 408-414: invalidate vs append debounce), using
`cx.spawn()` with timer via `cx.background_executor().timer()` (line 417). Maps to
the vault's existing `cleanup.debounce()` pattern used by completion_base and embed.

## Proposed Design

### Priority Levels

Four priority levels, each with distinct scheduling semantics:

```
Level      Delay         Trigger              Examples
────────────────────────────────────────────────────────────────────
CRITICAL   0ms (sync)    Immediate callback    Completion cache hit, active link follow
NORMAL     vim.schedule  Next event loop tick   Viewport highlights, current buffer visible embeds
DEFERRED   200-500ms     Configurable timer     Off-screen embeds, prefetch zone rendering, stale cache cleanup
IDLE       CursorHold    User stopped typing    Index persist, frecency writes, GC sweeps
```

**CRITICAL** runs synchronously within the current call stack — no scheduling delay.
Use sparingly: only for operations where any delay produces visible flicker or lag.

**NORMAL** runs on the next event loop tick via `vim.schedule`. This is the current
default for most vault operations. The scheduler ensures NORMAL items drain before
DEFERRED timers fire.

**DEFERRED** runs after a configurable delay (default 200-500ms). This is for work
that should happen eventually but must not compete with user-facing operations. The
delay ensures NORMAL work from the same trigger event has completed first.

**IDLE** runs on `CursorHold` — when the user has stopped typing for `updatetime` ms
(typically 300-1000ms). This is for maintenance work with no user-visible effect.

### Core Module: `work_scheduler.lua`

```lua
--- Prioritized work scheduling for async vault operations.
--- Routes work items through priority levels to ensure user-visible
--- operations complete before background maintenance.
---
--- Priority levels:
---   CRITICAL (0) — synchronous, immediate execution
---   NORMAL   (1) — vim.schedule, next tick
---   DEFERRED (2) — configurable delay (200-500ms)
---   IDLE     (3) — CursorHold autocmd
---
--- Integrates with existing vault patterns:
---   - operation_tracker: staleness checking at dequeue time
---   - request_coalescer: deduplication before enqueue
---   - watch_channel: coalescing feeds into scheduler
---   - cleanup.debounce: burst protection before scheduler

local config = require("andrew.vault.config")
local log = require("andrew.vault.vault_log").scope("scheduler")

local M = {}

--- Priority level constants.
M.CRITICAL = 0
M.NORMAL   = 1
M.DEFERRED = 2
M.IDLE     = 3

--- @class WorkItem
--- @field fn function The work to execute
--- @field priority number Priority level (0-3)
--- @field operation_id number|nil For staleness checking
--- @field domain string|nil Logical grouping (e.g., "embed", "highlight")
--- @field label string|nil Human-readable description for debugging
--- @field _is_stale (fun(id: number): boolean)|nil Staleness checker from operation_tracker

--- @type WorkItem[][] One array per priority level
local _queues = { {}, {}, {}, {} }

--- @type uv.uv_timer_t|nil Timer for DEFERRED processing
local _deferred_timer = nil

--- @type number|nil Autocmd ID for IDLE processing
local _idle_autocmd = nil

--- @type boolean Whether the scheduler is actively draining
local _draining = false

--- @type { enqueued: number, executed: number, cancelled: number, by_priority: number[] }
local _stats = {
  enqueued = 0,
  executed = 0,
  cancelled = 0,
  by_priority = { 0, 0, 0, 0 },
}

--- Enqueue a work item at a given priority.
--- @param priority number M.CRITICAL, M.NORMAL, M.DEFERRED, or M.IDLE
--- @param fn function The work to execute
--- @param opts? { operation_id: number, domain: string, label: string, _is_stale: fun(id: number): boolean }
function M.schedule(priority, fn, opts)
  opts = opts or {}

  -- CRITICAL: execute immediately, no queuing
  if priority == M.CRITICAL then
    _stats.enqueued = _stats.enqueued + 1
    _stats.executed = _stats.executed + 1
    _stats.by_priority[1] = _stats.by_priority[1] + 1
    fn()
    return
  end

  local item = {
    fn = fn,
    priority = priority,
    operation_id = opts.operation_id,
    domain = opts.domain,
    label = opts.label,
    _is_stale = opts._is_stale,
  }

  -- Queue index: NORMAL=1, DEFERRED=2, IDLE=3 (after CRITICAL handled above)
  local queue_idx = priority
  _queues[queue_idx][#_queues[queue_idx] + 1] = item
  _stats.enqueued = _stats.enqueued + 1

  -- Trigger appropriate scheduling mechanism
  if priority == M.NORMAL and not _draining then
    vim.schedule(function() M._drain() end)
  elseif priority == M.DEFERRED then
    M._ensure_deferred_timer()
  end
  -- IDLE items wait for CursorHold (setup in M.setup())
end
```

### Drain Logic

The drain function processes queues in priority order, with starvation prevention
for lower-priority work:

```lua
--- Drain work queues in priority order.
--- Called from vim.schedule (NORMAL trigger) or deferred timer.
function M._drain()
  if _draining then return end
  _draining = true

  -- Phase 1: Drain all NORMAL items
  local normal_queue = _queues[M.NORMAL]
  while #normal_queue > 0 do
    local item = table.remove(normal_queue, 1)
    if M._should_execute(item) then
      M._execute(item)
    end
  end

  -- Phase 2: Process at least 1 DEFERRED item (starvation prevention)
  local deferred_queue = _queues[M.DEFERRED]
  if #deferred_queue > 0 then
    local item = table.remove(deferred_queue, 1)
    if M._should_execute(item) then
      M._execute(item)
    end
  end

  _draining = false
end

--- Check whether a work item should still execute.
--- Items with an operation_id are checked against their domain's
--- current operation (integration with operation_tracker).
--- @param item WorkItem
--- @return boolean
function M._should_execute(item)
  if not item.operation_id then return true end

  -- If the item carries a staleness checker, use it
  if item._is_stale and item._is_stale(item.operation_id) then
    _stats.cancelled = _stats.cancelled + 1
    return false
  end

  return true
end

--- Execute a single work item with error handling.
--- @param item WorkItem
function M._execute(item)
  local ok, err = pcall(item.fn)
  if not ok then
    log.error("work item failed [%s/%s]: %s",
      item.domain or "unknown", item.label or "?", err)
  end
  _stats.executed = _stats.executed + 1
  _stats.by_priority[item.priority] = (_stats.by_priority[item.priority] or 0) + 1
end
```

### Deferred Timer

```lua
--- Ensure the deferred timer is running.
--- Uses cleanup module for timer lifecycle management (consistent with vault patterns).
function M._ensure_deferred_timer()
  if _deferred_timer then return end

  local delay = config.scheduler.deferred_delay_ms
  local cleanup = require("andrew.vault.resource_cleanup")

  _deferred_timer = vim.uv.new_timer()
  if not _deferred_timer then return end

  _deferred_timer:start(delay, 0, vim.schedule_wrap(function()
    -- Process all pending DEFERRED items
    local queue = _queues[M.DEFERRED]
    while #queue > 0 do
      local item = table.remove(queue, 1)
      if M._should_execute(item) then
        M._execute(item)
      end
    end

    -- Clean up timer
    if _deferred_timer then
      _deferred_timer:stop()
      _deferred_timer:close()
      _deferred_timer = nil
    end
  end))
end
```

### IDLE Processing via CursorHold

```lua
--- Setup the CursorHold autocmd for IDLE priority processing.
--- Called once during vault init.
function M.setup()
  if _idle_autocmd then return end

  _idle_autocmd = vim.api.nvim_create_autocmd("CursorHold", {
    group = vim.api.nvim_create_augroup("VaultWorkScheduler", { clear = true }),
    callback = function()
      local queue = _queues[M.IDLE]
      -- Process a bounded number of IDLE items per CursorHold
      local max_idle = config.scheduler.max_idle_per_hold
      local processed = 0

      while #queue > 0 and processed < max_idle do
        local item = table.remove(queue, 1)
        if M._should_execute(item) then
          M._execute(item)
          processed = processed + 1
        end
      end
    end,
  })
end
```

### Cancellation by Domain

When a new operation supersedes previous work in the same domain, stale items can be
purged from the queue before they execute:

```lua
--- Cancel all pending work items for a domain.
--- Useful when a new operation supersedes all previous work in that domain
--- (e.g., new buffer entered, all previous buffer's deferred work is stale).
--- @param domain string The domain to cancel
--- @return number count Number of items cancelled
function M.cancel_domain(domain)
  local count = 0
  for _, queue in ipairs(_queues) do
    for i = #queue, 1, -1 do
      if queue[i].domain == domain then
        table.remove(queue, i)
        count = count + 1
        _stats.cancelled = _stats.cancelled + 1
      end
    end
  end
  if count > 0 then
    log.debug("cancelled %d items for domain '%s'", count, domain)
  end
  return count
end

--- Cancel all pending work across all domains.
--- Used during vault shutdown or vault path switch.
function M.cancel_all()
  local total = 0
  for i, queue in ipairs(_queues) do
    total = total + #queue
    _queues[i] = {}
  end
  _stats.cancelled = _stats.cancelled + total

  if _deferred_timer then
    _deferred_timer:stop()
    _deferred_timer:close()
    _deferred_timer = nil
  end

  log.debug("cancelled all pending work (%d items)", total)
end
```

### Stats and Debug

```lua
--- Get scheduler statistics.
--- @return table
function M.stats()
  local pending = 0
  for _, queue in ipairs(_queues) do
    pending = pending + #queue
  end
  return {
    enqueued = _stats.enqueued,
    executed = _stats.executed,
    cancelled = _stats.cancelled,
    pending = pending,
    pending_normal = #_queues[M.NORMAL],
    pending_deferred = #_queues[M.DEFERRED],
    pending_idle = #_queues[M.IDLE],
    by_priority = vim.deepcopy(_stats.by_priority),
  }
end

--- Reset stats (for testing).
function M.reset_stats()
  _stats = { enqueued = 0, executed = 0, cancelled = 0, by_priority = { 0, 0, 0, 0 } }
end

return M
```

## Integration with Existing Modules

### embed.lua — Visible vs Off-Screen Embeds

Embed.lua already implements lazy viewport rendering with generation-based staleness
and request_coalescer deduplication. The scheduler adds priority ordering between
visible and off-screen work.

**Current flow** (embed.lua):
1. `render_embeds()` (line 445) → request_coalescer dedup (line 500, key "embed_render:" .. bufnr) → build descriptors for dirty ranges
2. If `config.embed.lazy` (lines 569-579): `render_in_range()` (line 388) for visible zone, then coordinate prefetch via highlight_coordinator Phase 2 dispatch
3. Prefetch via `M.on_prefetch()` (line 626) renders above/below zones, checks generation via embed_pool
4. WinScrolled debounce via `config.embed.lazy_scroll_debounce_ms` (line 1039), generation check at line 1041
5. BufReadPost (line 982): marks `state.embeds_visible[buf] = "pending"`, waits for index ready
6. BufEnter dispatched via event_dispatch.lua → `M.on_buf_enter()` (line 1074) which calls `state.gc_stale_buffers()`

**Proposed change**: Route the two phases through the scheduler:

```lua
local scheduler = require("andrew.vault.work_scheduler")

-- Inside render_embeds(), after building descriptors and checking config.embed.lazy:

-- Cancel any pending embed work for this buffer
scheduler.cancel_domain("embed:" .. bufnr)

-- Phase 1: Visible zone → NORMAL priority (next tick, ahead of background work)
scheduler.schedule(scheduler.NORMAL, function()
  render_in_range(descs, ctx, zones.visible.start_line, zones.visible.end_line)
end, { domain = "embed:" .. bufnr, label = "visible-embed" })

-- Phase 2: Prefetch zones → DEFERRED (after visible work and 300ms delay)
scheduler.schedule(scheduler.DEFERRED, function()
  M.on_prefetch(bufnr, zones.above.start_line, zones.above.end_line)
  M.on_prefetch(bufnr, zones.below.start_line, zones.below.end_line)
end, { domain = "embed:" .. bufnr, label = "prefetch-embed" })
```

**Interaction with existing patterns:**
- **Request coalescer** remains: deduplicates concurrent `render_embeds()` calls
- **Generation counter** remains: scroll debounce callbacks check `ds.generation`
- **Lazy viewport** remains: determines *what* to render; scheduler determines *when*
- **WinScrolled debounce** (80ms via `cleanup.debounce`) remains as burst protection
  feeding into the scheduler

### completion_base.lua — Active Completion vs Cache Warming

Completion already uses operation_tracker for staleness, cleanup.debounce (250ms) for
burst protection, and yield_iter.run_async for coroutine stepping.

**Current flow** (completion_base.lua):
1. `build_items_async(callback)` (line 370) → `cancel_active()` (line 356) → debounce timer (lines 418/448, `config.completion.debounce_ms` default 250ms) → `yield_iter.run_async()` (line 487)
2. Cache warming: `build_items_async()` with no callback (line 533-535, triggered in `source.new()` for markdown buffers)
3. Active completion: `source:get_completions()` (line 543) — cache hit returns `cached_items` directly (lines 546-549, increments `_cache_hits`); cache miss calls `build_items_async(callback)` (lines 551-557)
4. Operation tracking: `build_ops = operation_tracker.new()` (line 183) with `build_ops:is_stale(op_id)` checks (lines 420/436/450/506)
5. Adaptive batch sizing: `effective_batch_size()` (line 198) computes `math.ceil(estimated_items / 3)` to cap yields at 3 (applied at line 483)

**Proposed change**: Route through scheduler based on whether user is actively waiting:

```lua
local scheduler = require("andrew.vault.work_scheduler")

-- In the get_completions path (user actively waiting for popup):
function source:get_completions(ctx, callback)
  if cache_valid() then
    -- Cache hit: CRITICAL — return immediately, no scheduling
    scheduler.schedule(scheduler.CRITICAL, function()
      opts.get_completions(self, ctx, cached_items, callback)
    end)
    return
  end

  -- Cache miss: build must happen ASAP (NORMAL priority, debounce still applies)
  scheduler.schedule(scheduler.NORMAL, function()
    build_items_async(function(items)
      opts.get_completions(self, ctx, items or {}, callback)
    end)
  end, { domain = "completion", label = "active-build" })
end

-- Proactive cache warming (e.g., on vault index generation change):
local function warm_completion_cache()
  scheduler.schedule(scheduler.DEFERRED, function()
    build_items_async() -- no callback = cache warming only
  end, { domain = "completion", label = "cache-warm" })
end
```

**Interaction with existing patterns:**
- **Operation tracker** (`build_ops` at line 183, `build_ops:is_stale(op_id)` at lines 420/436/450/506) remains: detects superseded builds during yield_iter stepping
- **Debounce timer** (`config.completion.debounce_ms`, default 250ms, lines 418/448) remains as inner-loop burst protection
- **Cancellation flag** (`active_state.cancelled`) remains for mid-build abort
- **Generation tracking** (`_cached_gen` at line 180 vs `vault_index._generation`) remains for cache validity
- **Adaptive batch sizing** (`effective_batch_size()` at line 198, caps at 3 yields) remains for yield count capping

### highlight_coordinator.lua — Current Viewport vs Prefetch Zones

Highlight_coordinator already uses watch_channel (0ms coalescing) for scheduling,
viewport zones for scope restriction, and region_tracker for incremental invalidation.

**Current flow** (highlight_coordinator.lua):
1. `M.schedule(bufnr, opts)` (lines 266-270) → `get_channel(bufnr)` → `ch.send(opts)` → watch_channel coalesces to single next-tick fire (channel created at line 247 via `watch.new()`)
2. `run_all(bufnr, opts)` (lines 276-318) → `pipeline.attach()` (line 291) → `pipeline.run()` (line 293) + non-pipeline updater dispatch (lines 296-303)
3. WinScrolled (lines 412-441): Phase 1 `M.schedule(bufnr, { full = false })` (line 420) + Phase 2 `viewport.schedule_prefetch()` (lines 429/435) for above/below zones
4. Registered updaters sorted by priority (line 239: `table.sort(_updaters, ...)`, default priority = 50 at line 235)
5. Region tracker integration: `region_tracker.get(bufnr, "hl_coord")` (lines 283-285) for invalid ranges, marked valid at line 308

**Proposed change**: The watch_channel already provides near-zero-latency scheduling for
current-buffer highlights. The scheduler adds value for cross-buffer scenarios:

```lua
local scheduler = require("andrew.vault.work_scheduler")

function M.schedule(bufnr, opts)
  opts = opts or {}

  local current_buf = vim.api.nvim_get_current_buf()

  if bufnr == current_buf then
    -- Current buffer: existing watch_channel path (NORMAL equivalent, ~0ms coalesce)
    local ch = get_channel(bufnr)
    ch.send(opts)
  else
    -- Non-current buffer: DEFERRED (user isn't looking at it)
    scheduler.cancel_domain("highlight:" .. bufnr)
    scheduler.schedule(scheduler.DEFERRED, function()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      M.run_all(bufnr, opts)
    end, { domain = "highlight:" .. bufnr, label = "adjacent-hl" })
  end
end
```

**Interaction with existing patterns:**
- **Watch channel** remains for current-buffer scheduling (0ms coalesce → next tick)
- **Viewport zones** remain: visible zone immediate, prefetch via `viewport.schedule_prefetch()`
- **Region tracker** remains: provides invalid_ranges to updaters
- **Transform pipeline** remains: dispatches to pipeline consumers and direct updaters
- **Updater priority** (default=50, sorted at line 239) remains for intra-run ordering

### vault_index.lua — Persistence and GC as IDLE Work

Vault index already uses two-phase persistence (WAL delta + debounced full persist)
and adaptive batch sizing targeting 16ms per yield.

**Current flow** (vault_index.lua/vault_index_build.lua):
1. `build_async()` → request_coalescer dedup (line 367, pool created at line 71: `coalescer.new({ name = "index_rebuild" })`) → `yield_iter.run_async()` (line 377) with adaptive batches targeting `TARGET_MS = 16` (line 74), `compute_batch_size()` at lines 96-101 adapts per-batch with `MIN_BATCH=5`
2. `_schedule_persist()` (lines 979-991) → WAL delta via `_persist_delta()` (lines 939-964, fast) + conditional `_schedule_full_persist()` (lines 995-1008) when `_wal_count > 1000` (line 984, field at line 134, incremented at line 963)
3. `_schedule_full_persist()` → `cleanup.debounce` with `config.index.persist_debounce_ms` (5000ms, config.lua line 352), adaptive min interval logic at lines 998-1003
4. VimLeavePre: `persist_now()` (lines 1113-1142) uses synchronous blocking I/O (init.lua lines 818-831)

**Proposed change**: Move non-urgent persistence to IDLE:

```lua
local scheduler = require("andrew.vault.work_scheduler")

-- Instead of debounced full persist, schedule as IDLE when WAL is small:
function M.VaultIndex:_schedule_persist(changed_rel_paths, deleted_rel_paths)
  if changed_rel_paths or deleted_rel_paths then
    -- Incremental: write delta to WAL immediately (fast, <2ms)
    self:_persist_delta(changed_rel_paths or {}, deleted_rel_paths or {})
    -- Full persist: IDLE if WAL small, debounced if WAL large
    if self._wal_count > 1000 then
      self:_schedule_full_persist() -- existing debounced path
    else
      scheduler.schedule(scheduler.IDLE, function()
        self:_persist()
      end, { domain = "index", label = "persist" })
    end
  else
    self:_schedule_full_persist()
  end
end

-- embed_state.gc_stale_buffers as IDLE:
local function schedule_gc()
  scheduler.schedule(scheduler.IDLE, function()
    gc_stale_buffers()
  end, { domain = "embed-gc", label = "stale-buf-gc" })
end
```

**Interaction with existing patterns:**
- **WAL delta persist** remains: fast synchronous writes for incremental changes
- **Debounced full persist** remains for large WAL (>1000 entries)
- **Adaptive batch sizing** in build_async remains: targets 16ms per coroutine yield
- **Request coalescer** remains: deduplicates concurrent build_async calls

### Integration with operation_tracker

Work items can carry staleness information from an `operation_tracker`, enabling
automatic discard of enqueued-but-superseded work:

```lua
local operation_tracker = require("andrew.vault.operation_tracker")
local scheduler = require("andrew.vault.work_scheduler")

local embed_ops = operation_tracker.new()

local function render_embeds(opts)
  local op_id = embed_ops:start()

  -- Schedule work items that know their operation_id
  for _, desc in ipairs(descs) do
    local item_opts = {
      operation_id = op_id,
      domain = "embed:" .. bufnr,
      -- Attach staleness checker (scheduler calls _is_stale before executing)
      _is_stale = function(id) return embed_ops:is_stale(id) end,
    }

    scheduler.schedule(scheduler.NORMAL, function()
      render_single(desc, bufnr)
    end, item_opts)
  end
end
```

When `render_embeds` is called again (e.g., on buffer edit), `embed_ops:start()`
increments the counter. All previously enqueued items for the old `op_id` will fail
the `_is_stale` check and be silently skipped during drain.

### Integration with event_dispatch.lua

The event_dispatch module's BufEnter coalescer (adaptive delay, 16ms base / 200ms rapid)
feeds naturally into the scheduler. The coalescer handles **burst protection**; the
scheduler handles **priority ordering** of the dispatched work:

```lua
-- In event_dispatch.lua BufEnter handler (lines 65-102):
-- Coalescer params from config.events.*:
--   delay_ms = config.events.buf_enter_coalesce_ms (16ms)
--   max_batch_size = config.events.max_batch_size (32)
--   rapid_threshold_ms = config.events.rapid_switch_threshold_ms (50ms)
--   rapid_switch_delay_ms = config.events.rapid_switch_delay_ms (200ms)
handler = function(batch)
  for bufnr, _ in pairs(batch) do
    if is_vault_md then
      -- These module callbacks now internally use the scheduler:
      -- embed.on_buf_enter → schedules NORMAL (visible) + DEFERRED (prefetch)
      -- highlight_coordinator.schedule → NORMAL (current buf) or DEFERRED (other)
      -- frecency.on_buf_enter → IDLE (no user-visible effect)
      -- task_notify.on_buf_enter → NORMAL (user notification)
      -- sidebar.on_buf_enter → DEFERRED (not user-facing)
      breadcrumbs.on_buf_enter(ctx)          -- line 89
      embed.on_buf_enter(ctx)                -- line 90
      frecency.on_buf_enter(ctx)             -- line 91
      task_notify.on_buf_enter(ctx)          -- line 92
      sidebar.on_buf_enter(ctx)              -- lines 95-98 (lazy-loaded)
    else
      -- Non-vault markdown:
      linkdiag.on_buf_enter_non_vault(ctx)   -- line 83
      breadcrumbs.on_buf_enter_non_vault(ctx) -- line 84
    end
  end
end
```

## Configuration

```lua
-- In config.lua (new section — does not exist yet; would follow M.render_cache at ~line 987):
M.scheduler = {
  deferred_delay_ms = 300,   -- Delay before DEFERRED items execute
  max_idle_per_hold = 3,     -- Max IDLE items processed per CursorHold
  stats_enabled = false,     -- Track execution statistics
}
```

### Config Rationale

- **deferred_delay_ms = 300**: Long enough for NORMAL work to complete (most NORMAL
  items execute in <50ms total), short enough that deferred work doesn't feel
  permanently delayed. Matches Zed's `INVISIBLE_RANGES_HINTS_REQUEST_DELAY_MILLIS = 400`
  (slightly shorter since Neovim's event loop is simpler than Zed's multi-thread model).

- **max_idle_per_hold = 3**: CursorHold should feel instant. Processing more than 3
  items risks a perceptible pause. At typical `updatetime=300ms`, this allows ~100ms
  per item before the user might notice.

- **stats_enabled = false**: Stats tracking adds a table write per enqueue/execute.
  Negligible cost but unnecessary in normal operation.

## Relationship to Existing Documents

### Complements Doc 14 (Cooperative Yielding)

Doc 14 addresses **intra-operation** responsiveness: within a single long-running
operation (e.g., vault_index_build parsing via yield_iter.run_async with adaptive
batches targeting 16ms), yield periodically so the event loop can process other callbacks.

Doc 45 addresses **inter-operation** ordering: when multiple operations are pending,
which one should execute first.

The two compose naturally:

```
NORMAL-priority vault_index build_async:
  ├── Parse adaptive batch (~16ms target, via yield_iter.run_async)
  ├── coroutine.yield()          ← doc 14: intra-operation yielding
  ├── vim.schedule(step)
  │   └── (scheduler ensures this resumes before DEFERRED items)  ← doc 45
  ├── Parse next batch
  └── ...
```

### Complements Doc 21 (Stale Cancellation)

Doc 21 cancels **in-flight** work (kill processes, abort coroutines). Doc 45 prevents
**not-yet-started** work from executing by checking staleness at dequeue time.

| Timing | Doc 21 | Doc 45 |
|--------|--------|--------|
| Before execution | — | Skip stale items in queue (via _is_stale) |
| During execution | Cancel process/coroutine (active_state.cancelled, operation_tracker) | — |
| After execution | — | (operation_tracker detects stale results) |

The vault already implements doc 21 patterns: operation_tracker in completion_base,
generation counters in embed.lua, cancellation flags in yield_iter. Doc 45 adds the
pre-execution layer.

### Complements Doc 26 (Viewport Rendering)

Doc 26 determines **what** to render (viewport-visible content vs off-screen content).
Doc 45 determines **when** to render it (NORMAL for visible, DEFERRED for off-screen).

The vault already implements doc 26 patterns:
- `viewport.lua` computes three zones (visible, above prefetch, below prefetch)
- `highlight_coordinator.lua` WinScrolled handler: immediate schedule + 400ms prefetch debounce
- `embed.lua` lazy rendering: `render_in_range()` for visible, `on_prefetch()` for off-screen
- `region_tracker.lua` tracks invalid ranges for incremental re-rendering

Without doc 45, viewport-restricted rendering (doc 26) still queues visible and
off-screen work into the same `vim.schedule` pool. The scheduler ensures visible
work actually executes first.

### Complements Doc 40 (Rate-Limited Domain Queuing)

Doc 40 handles **external** rate limiting (HTTP requests to domain servers via
rate_limiter.lua with per-domain concurrency caps and priority queue). Doc 45
handles **internal** scheduling (Neovim event loop prioritization). A URL validation
batch might be DEFERRED priority (doc 45) and also rate-limited per domain (doc 40).

Note: rate_limiter.lua already implements its own priority queue (lower number = higher
priority, stable FIFO for equal priority). The scheduler complements this by controlling
when rate-limited work enters the rate limiter.

## Expected Impact

### Perceived Responsiveness

| Operation | Before (arbitrary order) | After (prioritized) | Improvement |
|-----------|------------------------|--------------------|----|
| Completion popup after BufEnter | 250-500ms (debounce + blocked by embed + highlight) | <50ms cache hit (CRITICAL) or 250ms debounce (NORMAL, ahead of embeds) | Cache hits: immediate. Misses: 50-70% faster |
| Viewport highlights on scroll | Watch channel next-tick, but interleaved with off-screen work | NORMAL via watch_channel: unchanged for current buf; DEFERRED for non-current | Consistent <30ms for current buffer |
| Off-screen embed prefetch | Scheduled alongside visible via viewport.schedule_prefetch (400ms debounce) | DEFERRED: 300ms after visible work done | No visible impact, predictable timing |
| Index persistence | Debounced 5000ms timer, may coincide with typing | IDLE: only on CursorHold (small WAL) or debounced (large WAL) | Zero typing interference for normal usage |
| Frecency writes | Fires on BufEnter dispatch | IDLE: only on CursorHold | Zero navigation interference |

### Total Work Unchanged

The scheduler does not reduce the total amount of work — it reorders it. All DEFERRED
and IDLE items eventually execute. The improvement is entirely in **perceived latency**
for user-facing operations.

### Memory Overhead

- 4 Lua arrays (empty tables when idle)
- 1 optional `uv_timer_t` for DEFERRED processing
- 1 autocmd for IDLE processing
- Per-item overhead: ~6 fields per `WorkItem` table (function, priority, operation_id,
  domain, label, _is_stale) — typically <20 items in flight at any time

Total: negligible. The scheduler adds no caches, no data copies, no persistent state.

### Throughput

The drain loop adds one function call + one table.remove per item compared to direct
`vim.schedule` callbacks. At <1 microsecond per overhead, this is unmeasurable even
with 100 items per drain cycle.

## Implementation Steps

### Step 1: Create `work_scheduler.lua`

Implement the core module with priority queues, drain logic, deferred timer, and
IDLE autocmd as shown in the design section above. Use `resource_cleanup` patterns
for timer lifecycle management (consistent with existing vault code).

### Step 2: Add config entries

```lua
-- In config.lua (alongside existing config sections)
M.scheduler = {
  deferred_delay_ms = 300,
  max_idle_per_hold = 3,
  stats_enabled = false,
}
```

### Step 3: Integrate into highlight_coordinator.lua

Add scheduler routing for non-current-buffer highlights. The current-buffer path
continues using the existing watch_channel (0ms coalesce → next tick), which is already
equivalent to NORMAL priority. Non-current-buffer highlights → DEFERRED.

Keep the existing patterns:
- watch_channel for current-buffer coalescing
- viewport.schedule_prefetch (400ms) for prefetch zone debouncing
- region_tracker for invalid range tracking
- transform_pipeline + updater priority (autolink=60, footnotes=70)

### Step 4: Integrate into embed.lua

Route visible embed rendering through NORMAL, prefetch zones through DEFERRED.
Combine with `scheduler.cancel_domain("embed:" .. bufnr)` on buffer switch to
purge stale embed work.

Keep the existing patterns:
- request_coalescer for render deduplication
- generation counter for scroll debounce staleness
- WinScrolled debounce (80ms) for burst protection
- Frame cache for rendered embed reuse
- Lazy viewport rendering (config.embed.lazy)

### Step 5: Integrate into completion_base.lua

Route active completion builds through NORMAL, proactive cache warming through
DEFERRED. Cache hits through CRITICAL.

Keep the existing patterns:
- cleanup.debounce (250ms) for burst protection
- operation_tracker for mid-build staleness detection
- yield_iter.run_async for coroutine stepping
- Generation tracking (_cached_gen vs vault_index._generation)
- Adaptive batch sizing (cap at 3 yields)

### Step 6: Move maintenance work to IDLE

- `vault_index` full persistence (small WAL) → IDLE
- `embed_state.gc_stale_buffers` → IDLE
- Frecency writes → IDLE
- Saved-search persistence → IDLE

Keep the existing patterns:
- WAL delta persist remains synchronous (fast, <2ms)
- Large WAL (>1000 entries) still uses debounced full persist
- VimLeavePre still forces synchronous persist

### Step 7: Add `:VaultSchedulerDebug` command

```lua
vim.api.nvim_create_user_command("VaultSchedulerDebug", function()
  local scheduler = require("andrew.vault.work_scheduler")
  local s = scheduler.stats()
  local lines = {
    "Work Scheduler Stats",
    "",
    string.format("Enqueued:  %d", s.enqueued),
    string.format("Executed:  %d", s.executed),
    string.format("Cancelled: %d", s.cancelled),
    string.format("Pending:   %d (normal=%d, deferred=%d, idle=%d)",
      s.pending, s.pending_normal, s.pending_deferred, s.pending_idle),
    "",
    "By priority:",
    string.format("  CRITICAL: %d", s.by_priority[1]),
    string.format("  NORMAL:   %d", s.by_priority[2]),
    string.format("  DEFERRED: %d", s.by_priority[3]),
    string.format("  IDLE:     %d", s.by_priority[4]),
  }
  -- Display in scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)
end, {})
```

### Step 8: Wire into engine.lua / event_dispatch.lua lifecycle

Call `scheduler.setup()` during vault init (after event_dispatch.setup()).
Call `scheduler.cancel_all()` on:
- Vault path switch (`engine.switch_vault`, lines 338-353 — switches vault_path, invalidates caches, restarts FS watcher)
- VimLeavePre (via `engine.teardown()`, lines 696-703 — profiler shutdown, URL cache persist, log close)

## Edge Cases

### Re-entrant scheduling

A NORMAL work item's `fn()` may call `scheduler.schedule()` to enqueue more work.
The `_draining` flag prevents nested `_drain()` calls — newly enqueued NORMAL items
will be processed in the current drain loop's next iteration (since the while loop
checks `#normal_queue > 0`). DEFERRED items enqueued during drain are handled by
the deferred timer.

### Empty queues

When all queues are empty, no timers are running and no autocmd processing occurs.
The scheduler is completely inert — zero CPU cost when idle.

### Buffer validity

Work items that operate on buffers should check `nvim_buf_is_valid()` inside their
`fn()`, not at enqueue time. A buffer may become invalid between enqueue and execution
(especially for DEFERRED and IDLE items). This is already the standard pattern in
vault modules (e.g., highlight_coordinator checks validity in run_all, embed.lua's
scheduled callbacks check `is_valid_current_buf()`).

### Interaction with existing debounce timers

The scheduler does not replace debounce timers. Debounce handles **burst coalescing**
(many events -> one operation). The scheduler handles **operation ordering** (one
operation vs another). A typical flow:

```
TextChanged fires 5 times in 100ms
  -> watch_channel coalesces to 1 highlight update (existing: 0ms coalesce)
  -> highlight update runs via watch_channel next-tick callback (existing)
  -> OR: if non-current buffer, enqueued as DEFERRED priority (new)

WinScrolled fires during rapid scroll
  -> cleanup.debounce(80ms) coalesces to 1 embed render check (existing)
  -> embed render_in_range for visible zone → NORMAL (new)
  -> embed on_prefetch for prefetch zones → DEFERRED (new)

User types after BufEnter
  -> completion debounce timer (250ms) coalesces keystrokes (existing)
  -> completion build → NORMAL via scheduler (new)
  -> background cache warming → DEFERRED via scheduler (new)
```

### Interaction with watch_channel and event_coalescer

Both watch_channel (0ms) and event_coalescer (16ms adaptive) fire their callbacks via
`vim.schedule_wrap()` or `vim.schedule()`. The scheduler's NORMAL items also use
`vim.schedule()`. All three arrive on the same event loop tick pool.

The key difference: watch_channel and event_coalescer handle **when to fire** (coalescing).
The scheduler handles **what order** the resulting work executes in. Modules can use
coalescing *before* the scheduler (to reduce work) and the scheduler *after* coalescing
(to prioritize work).

### Interaction with request_coalescer

Request coalescer deduplicates **identical concurrent operations** (e.g., two
`render_embeds` calls for the same buffer). The scheduler prioritizes **different
operations** against each other. They compose: coalescer deduplicates first, then
the surviving operation is scheduled at the appropriate priority.

## Risk Assessment

- **Low risk**: The scheduler is a thin routing layer over existing `vim.schedule`,
  `vim.uv.new_timer`, and autocmd primitives. It does not change what work is done,
  only when.

- **Low risk**: Starvation prevention (1 DEFERRED item per drain cycle) ensures
  background work cannot be permanently starved by a continuous stream of NORMAL work.

- **Low risk**: All existing scheduling abstractions (watch_channel, event_coalescer,
  cleanup.debounce, request_coalescer, rate_limiter, operation_tracker) continue to
  function unchanged. The scheduler sits alongside them, not on top.

- **Medium risk**: Migration must be incremental. Converting all modules at once risks
  subtle ordering changes. Each module should be migrated independently with before/after
  testing.

- **Rollback**: Each integration point can be independently reverted to direct
  `vim.schedule`/`vim.defer_fn` calls. The scheduler module itself has no persistent
  state and no side effects beyond the CursorHold autocmd.
