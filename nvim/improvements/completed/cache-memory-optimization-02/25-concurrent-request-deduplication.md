# 25 — Concurrent Request Deduplication

## Priority: MEDIUM (downgraded from HIGH — several targets already have guards)
## Inspired By: Zed's `loading_buffers: HashMap<ProjectPath, Shared<Task<...>>>` in `buffer_store.rs` (line 36, open_buffer at lines 781-835), `ScanRequest` waiter bundling in `worktree.rs` (lines 139-142, coalescing at lines 4834-4841; note: `PathPrefixScanRequest` at lines 134-137 does NOT coalesce — only `ScanRequest` does)
## Dependencies: Document 21 (Stale Operation Cancellation) — complementary, not overlapping

---

## Problem

Multiple callers can request the **same** operation concurrently, each spawning independent work that produces identical results. Unlike Doc 21 (which cancels OLD work when NEW work arrives), this covers the case where the exact same work is requested by multiple consumers at the same time.

### Existing Guards Already in Place

Investigation of the current codebase reveals several deduplication mechanisms already implemented:

| Module | Existing Guard | Gap |
|--------|---------------|-----|
| `vault_index_build.lua:35` | `if index._building then return end` — boolean flag prevents concurrent builds | Callers that arrive while build is running get no notification when it completes; their callback is silently dropped |
| `embed.lua:404` | `cancel_async_render(bufnr)` cancels in-flight render before starting new one | Cancels + restarts rather than coalescing; wastes work already done |
| `embed.lua:753-756` | `"pending"` state in `state.embeds_visible[bufnr]` prevents BufReadPost→BufEnter double-render | Only covers the BufReadPost/BufEnter race, not other concurrent triggers |
| `embed.lua:348-353,421` | Generation counter (`check_generation` + per-buffer generation) detects stale async renders | Detects staleness but doesn't prevent starting duplicate work |
| `event_coalescer.lua:68-88` | BufEnter events batched by bufnr with adaptive delay (`config.events.buf_enter_coalesce_ms = 16`) | Only coalesces BufEnter events, not the operations they trigger |
| `completion_base.lua:260-261` | Per-source `active_state` prevents concurrent builds; debounce timer | Effectively deduplicates within a single source, but across sources each still builds independently |
| `url_validate.lua:10,323` | `_inflight` set (declared line 10, checked line 323) prevents duplicate HTTP requests for same URL | Already implements the pattern proposed here; no changes needed |
| `connections.lua:759-816` | Multi-cache system (result weighted LRU at line 24, IDF cache at line 34, note data weighted LRU at line 43) with generation-based validity + subscriber-based dependency-tracked invalidation (lines 997-1035) | Cache hit avoids recompute, but two near-simultaneous cache misses both trigger full scoring |

### Remaining Duplicate Work Patterns

Given the existing guards, the **actual remaining gaps** are:

1. **vault_index.build_async() callback loss:** The `_building` flag in `vault_index_build.lua:35` prevents concurrent builds, but callers whose `build_async(callback)` arrives while `_building == true` have their callback silently ignored (the function returns early at line 35). Those callers never learn when the in-flight build completes.

2. **connections.compute()/compute_async() concurrent cache misses:** `connections.lua` has a sophisticated result cache (LRU + generation + dependency tracking), but two near-simultaneous calls for the same `source_rel_path` that both miss the cache will both run full scoring pipelines (5-signal scoring across all index entries at ~100-300ms each).

3. **embed.lua cancel-and-restart waste:** `render_embeds()` at line 404 calls `cancel_async_render(bufnr)` before starting. If BufReadPost (150ms defer via `embed.lua:747-760`) already started rendering and BufEnter (via `event_dispatch.lua:65-112` coalescer → `embed.on_buf_enter()` at lines 813-825) arrives, the first render is cancelled and all its work (parse, cache warm, partial renders) is thrown away.

4. **search_filter.evaluate_async() in live mode:** `search/advanced.lua` calls `search_filter.evaluate_async()` which uses `yield_iter.run_async()`. Rapid keystroke-triggered evaluations with the same AST could overlap before the previous one yields to check cancellation.

### Wasted Resources (Revised Estimates)

| Scenario | Actual duplicate ops | Wasted per duplicate | Frequency |
|----------|---------------------|---------------------|-----------|
| Index rebuild callback loss | 1-3 lost callbacks/event | Callers wait indefinitely or miss state | Every Alt-Tab (mitigated by `_building` flag — no CPU waste, but API contract broken) |
| Connection cache miss race | 2 concurrent on same path | 100-300ms + full index walk | Occasional (BufEnter + sidebar both call compute) |
| Embed cancel-restart | 1 wasted partial render | 30-100ms + file I/O already done | Every BufEnter with pending BufReadPost |
| Search live overlap | 1-2 overlapping evaluations | 50-150ms per redundant eval | During rapid search typing |

### Why This Is Different from Doc 21

| Aspect | Doc 21 (Cancellation) | Doc 25 (Deduplication) |
|--------|----------------------|----------------------|
| Trigger | New request **supersedes** old | New request is **identical** to in-flight |
| Action | Cancel old, start new | Join existing, skip new |
| Key question | "Is newer work available?" | "Is identical work already running?" |
| Result | Only latest result used | Shared result used by all waiters |
| Zed pattern | `search_count` monotonic ID | `loading_buffers` shared task |

They complement each other: Doc 21 cancels stale operations that have been superseded. Doc 25 prevents spawning duplicate operations that would produce the same result.

### Zed's Approach

Zed uses **shared futures** keyed by request identity.

**buffer_store.rs** (line 36 declaration, lines 781-835 usage):

```rust
// buffer_store.rs line 36: Shared loading tasks
loading_buffers: HashMap<ProjectPath, Shared<Task<Result<Entity<Buffer>, Arc<anyhow::Error>>>>>

// buffer_store.rs lines 781-835: open_buffer with deduplication
pub fn open_buffer(
    &mut self,
    project_path: ProjectPath,
    cx: &mut Context<Self>,
) -> Task<Result<Entity<Buffer>>> {
    // Fast path: buffer already loaded
    if let Some(buffer) = self.get_by_path(&project_path) {
        cx.emit(BufferStoreEvent::BufferOpened { buffer: buffer.clone(), project_path });
        return Task::ready(Ok(buffer));
    }

    let task = match self.loading_buffers.entry(project_path.clone()) {
        // Another caller is already loading this buffer — return the same task
        hash_map::Entry::Occupied(e) => e.get().clone(),
        // No one is loading it yet — start the task, store it, return a clone
        hash_map::Entry::Vacant(entry) => {
            let path = project_path.path.clone();
            let Some(worktree) = self.worktree_store.read(cx)
                .worktree_for_id(project_path.worktree_id, cx) else {
                return Task::ready(Err(anyhow!("no such worktree")));
            };
            let load_buffer = match &self.state {
                BufferStoreState::Local(this) => this.open_buffer(path, worktree, cx),
                BufferStoreState::Remote(this) => this.open_buffer(path, worktree, cx),
            };

            entry
                .insert(
                    cx.spawn(async move |this, cx| {
                        let load_result = load_buffer.await;
                        this.update(cx, |this, cx| {
                            // Self-removal: clean up from registry on completion
                            this.loading_buffers.remove(&project_path);
                            let buffer = load_result.map_err(Arc::new)?;
                            cx.emit(BufferStoreEvent::BufferOpened {
                                buffer: buffer.clone(), project_path,
                            });
                            Ok(buffer)
                        })?
                    })
                    .shared(),  // .shared() makes task cloneable — all waiters get same result
                )
                .clone()
        }
    };

    cx.background_spawn(async move { task.await.map_err(|e| anyhow!("{e}")) })
}
```

**worktree.rs** (lines 134-142 structs, lines 4834-4841 coalescing, line 1302 notification):

```rust
// worktree.rs lines 134-137: PathPrefixScanRequest — single path, NO coalescing
pub struct PathPrefixScanRequest {
    path: Arc<Path>,
    done: SmallVec<[barrier::Sender; 1]>,  // Single request's waiters
}

// worktree.rs lines 139-142: ScanRequest — multi-path, WITH coalescing
struct ScanRequest {
    relative_paths: Vec<Arc<Path>>,
    done: SmallVec<[barrier::Sender; 1]>,  // Multiple waiters bundled across coalesced requests
}

// worktree.rs lines 4834-4841: ScanRequest coalescing via channel drain
// NOTE: Only ScanRequest is coalesced; PathPrefixScanRequest is processed one-at-a-time
// (recv() without try_recv() loop at lines 3903-3921)
async fn next_scan_request(&self) -> Result<ScanRequest> {
    let mut request = self.scan_requests_rx.recv().await?;
    while let Ok(next_request) = self.scan_requests_rx.try_recv() {
        request.relative_paths.extend(next_request.relative_paths);
        request.done.extend(next_request.done);  // Bundle waiters from coalesced requests
    }
    Ok(request)
}

// worktree.rs line 1302: All waiters notified by dropping barrier senders
ScanState::Updated { snapshot, changes, barrier, scanning } => {
    *this.is_scanning.0.borrow_mut() = scanning;
    this.set_snapshot(snapshot, changes, cx);
    drop(barrier);  // Dropping SmallVec<barrier::Sender> notifies all receivers
}
```

Key principles:
- **Identity-based deduplication:** Requests keyed by a meaningful identity (path, query hash)
- **Waiter aggregation:** Multiple callers attach to one in-flight operation
- **Self-cleanup:** Completed operations remove themselves from the registry (buffer_store.rs line 817)
- **All waiters notified:** On completion or failure, every waiter receives the result (barrier drop at worktree.rs line 1302)

---

## Solution

Create a `request_coalescer.lua` module that provides a registry of in-flight operations with waiter aggregation. This complements the existing `event_coalescer.lua` (which batches BufEnter events by bufnr) by operating at the operation level rather than the event level.

### Relationship to Existing Patterns

| Existing Module | What It Does | How request_coalescer Differs |
|----------------|-------------|------------------------------|
| `event_coalescer.lua` | Batches BufEnter events by bufnr with adaptive delay | Coalesces at event level; request_coalescer coalesces at operation level |
| `completion_base.lua` active_state | Prevents concurrent builds per source | Per-source only; request_coalescer is cross-caller |
| `url_validate.lua` _inflight | Prevents duplicate HTTP requests | Already perfect — no changes needed. request_coalescer generalizes this pattern |
| `resource_cleanup.debounce()` | Timer-based debounce for operations | Debounce delays + restarts; coalescer joins existing in-flight work |

### Core Implementation

```lua
-- request_coalescer.lua

local M = {}
local scope = require("andrew.vault.vault_log").scope("request_coalescer")
local cleanup = require("andrew.vault.resource_cleanup")

-- Registry of in-flight operations: key → { operation, waiters, timer }
local _in_flight = {}

--- Request an operation, deduplicating with any identical in-flight request.
--- If an operation with this key is already running, the callback is added
--- to the existing waiter list. Otherwise, a new operation is started.
---
--- @param key string Unique key identifying this operation (e.g., "index_rebuild", "connections:/path/to/note")
--- @param operation_fn function(resolve, reject) Function that performs the work.
---   Must call resolve(result) on success or reject(err) on failure.
--- @param callback function(result, err) Called when operation completes or fails.
function M.request(key, operation_fn, callback)
  local entry = _in_flight[key]

  if entry then
    -- Identical operation already in-flight: join it
    if #entry.waiters >= (M._config.max_waiters or 50) then
      scope.warn("max waiters reached for key: %s", key)
      callback(nil, "max waiters exceeded")
      return
    end
    entry.waiters[#entry.waiters + 1] = callback
    scope.debug("coalesced request for key: %s (waiters: %d)", key, #entry.waiters)
    return
  end

  -- No in-flight operation: start new one
  entry = {
    waiters = { callback },
    timer = nil,
  }
  _in_flight[key] = entry

  -- Set up timeout (uses resource_cleanup for safe timer management)
  local timeout_ms = M._config.timeout_ms or 30000
  if timeout_ms > 0 then
    entry.timer = vim.uv.new_timer()
    entry.timer:start(timeout_ms, 0, vim.schedule_wrap(function()
      scope.warn("operation timed out for key: %s", key)
      M._resolve_entry(key, nil, "timeout")
    end))
  end

  scope.debug("started new operation for key: %s", key)

  -- Resolve/reject callbacks for the operation
  local function resolve(result)
    vim.schedule(function()
      M._resolve_entry(key, result, nil)
    end)
  end

  local function reject(err)
    vim.schedule(function()
      M._resolve_entry(key, nil, err)
    end)
  end

  -- Start the operation
  local ok, run_err = pcall(operation_fn, resolve, reject)
  if not ok then
    scope.error("operation_fn threw for key %s: %s", key, run_err)
    M._resolve_entry(key, nil, run_err)
  end
end

--- Resolve an in-flight entry: notify all waiters, clean up.
--- @param key string
--- @param result any
--- @param err string|nil
function M._resolve_entry(key, result, err)
  local entry = _in_flight[key]
  if not entry then return end  -- Already resolved (e.g., timeout + normal completion race)

  -- Clean up timer
  if entry.timer then
    cleanup.close_timer(entry.timer)
    entry.timer = nil
  end

  -- Remove from registry before notifying (prevents re-entrant issues)
  _in_flight[key] = nil

  -- Notify all waiters
  local waiter_count = #entry.waiters
  for i = 1, waiter_count do
    local ok_cb, cb_err = pcall(entry.waiters[i], result, err)
    if not ok_cb then
      scope.error("waiter callback error for key %s: %s", key, cb_err)
    end
    entry.waiters[i] = nil  -- Allow GC
  end

  if err then
    scope.debug("resolved key: %s with error (%d waiters): %s", key, waiter_count, err)
  else
    scope.debug("resolved key: %s successfully (%d waiters)", key, waiter_count)
  end

  -- Update stats
  M._stats.total_operations = M._stats.total_operations + 1
  M._stats.total_coalesced = M._stats.total_coalesced + (waiter_count - 1)
end

--- Coroutine-friendly request: yields until result is available.
--- Must be called from within a coroutine (integrates with yield_iter.run_async pattern).
--- @param key string
--- @param operation_fn function(resolve, reject)
--- @return any result, string|nil err
function M.request_async(key, operation_fn)
  local co = coroutine.running()
  if not co then
    error("request_async must be called from a coroutine")
  end

  M.request(key, operation_fn, function(result, err)
    coroutine.resume(co, result, err)
  end)

  return coroutine.yield()
end

--- Cancel an in-flight operation, notifying all waiters with "cancelled" error.
--- @param key string
function M.cancel(key)
  local entry = _in_flight[key]
  if not entry then return false end
  scope.debug("cancelling key: %s (%d waiters)", key, #entry.waiters)
  M._resolve_entry(key, nil, "cancelled")
  M._stats.total_cancelled = M._stats.total_cancelled + 1
  return true
end

--- Check if an operation is currently in-flight.
--- @param key string
--- @return boolean
function M.is_pending(key)
  return _in_flight[key] ~= nil
end

--- Get the number of waiters for an in-flight operation.
--- @param key string
--- @return integer
function M.waiter_count(key)
  local entry = _in_flight[key]
  return entry and #entry.waiters or 0
end

--- Get all currently in-flight keys (for debugging).
--- @return string[]
function M.pending_keys()
  local keys = {}
  for k, entry in pairs(_in_flight) do
    keys[#keys + 1] = string.format("%s (%d waiters)", k, #entry.waiters)
  end
  return keys
end

--- Get coalescing statistics.
--- @return table
function M.stats()
  return {
    total_operations = M._stats.total_operations,
    total_coalesced = M._stats.total_coalesced,
    total_cancelled = M._stats.total_cancelled,
    in_flight = vim.tbl_count(_in_flight),
    coalesce_rate = M._stats.total_operations > 0
      and (M._stats.total_coalesced / (M._stats.total_operations + M._stats.total_coalesced) * 100) or 0,
  }
end

--- Reset all state (for testing).
function M._reset()
  for key in pairs(_in_flight) do
    M.cancel(key)
  end
  _in_flight = {}
  M._stats = { total_operations = 0, total_coalesced = 0, total_cancelled = 0 }
end

-- Internal state
M._stats = { total_operations = 0, total_coalesced = 0, total_cancelled = 0 }
M._config = {}

--- Configure the coalescer.
--- @param opts table { max_waiters, timeout_ms, debug }
function M.configure(opts)
  M._config = vim.tbl_extend("force", M._config, opts or {})
end

return M
```

---

## Integration Targets

### 1. vault_index.build_async() — Callback Notification for Coalesced Callers

**Current state:** `vault_index_build.lua:35` has `if index._building then return end` which prevents concurrent builds but silently drops callbacks from callers that arrive during an active build.

**Actual current code** (`vault_index_build.lua:34-36`, `vault_index.lua:1125-1127`):
```lua
-- vault_index.lua lines 1125-1127 (wrapper)
function M.VaultIndex:build_async(callback)
  build_mod.build_async(self, callback)
end

-- vault_index_build.lua lines 34-36 (actual implementation)
function B.build_async(index, callback)
  if index._building then return end  -- ← Callback silently lost
  index._building = true
  parser.reset_intern_pool()

  local start_time = vim.uv.hrtime()
  local is_cold_start = not index._ready

  local yield_iter = require("andrew.vault.yield_iter")
  yield_iter.run_async(function()
    -- Coroutine body: detect changes, parse in adaptive batches (16ms target),
    -- stage mutations, atomic apply via _apply_staged(), schedule persistence
    -- ...
    -- line 135: index:_apply_staged(staged, ...) — resets _building flag internally
    -- line 167: if callback then callback() end
  end, {
    on_error = function(err)
      index._building = false  -- line 170
      notify.error("index error: " .. err)
    end,
  })
end
```

**Note on _building flag reset:** The flag is reset in TWO places:
- **Success path:** `vault_index.lua:346` inside `_apply_staged()` sets `self._building = false`
- **Error path:** `vault_index_build.lua:170` in the `on_error` handler
- The `is_building()` public method is at `vault_index.lua:238-240`

**With deduplication** (`vault_index_build.lua`):
```lua
local coalescer = require("andrew.vault.request_coalescer")

function B.build_async(index, callback)
  coalescer.request("index_rebuild", function(resolve, reject)
    -- The _building flag is still useful for update_files_batch() guard (line 183)
    index._building = true
    parser.reset_intern_pool()

    local yield_iter = require("andrew.vault.yield_iter")
    yield_iter.run_async(function()
      -- ... existing coroutine body unchanged ...
    end, {
      callback = function()
        resolve(true)
      end,
      on_error = function(err)
        index._building = false
        reject(err)
      end,
    })
  end, function(result, err)
    if callback then callback() end
    if err then
      scope.warn("index rebuild failed: %s", err)
    end
  end)
end
```

**What changes:** Instead of `if index._building then return end` dropping callbacks, the coalescer adds late-arriving callbacks to the waiter list. When the single in-flight build completes, all waiters are notified. The `_building` flag is retained for the `update_files_batch()` guard at `vault_index_build.lua:183`. Note: in the current code the callback is invoked at line 167 (`if callback then callback() end`) inside the coroutine body. The `_building` flag is reset via two paths: on success inside `_apply_staged()` at `vault_index.lua:346` (`self._building = false`), and on error in the `on_error` handler at `vault_index_build.lua:170`. Both paths are covered.

### 2. connections.compute() / compute_async() — Per-Note Connection Deduplication

**Current state:** `connections.lua` has a multi-cache system — result weighted LRU (line 24-28), IDF cache with incremental updates (lines 34-37), note data weighted LRU (lines 43-48) — with generation-based validity, subscriber-based per-file invalidation (lines 997-1035), and dependency-tracked cache entries (lines 800-813). However, two near-simultaneous cache misses for the same `source_rel_path` both trigger full scoring.

**Actual current code** (`connections.lua:759-816`):
```lua
function M.compute(source_rel_path, max_results, opts_cancel)
  max_results = max_results or config.connections.max_results

  -- Check result cache (TTL + generation-based validity) — lines 763-773
  local vi_check, index_gen_check = get_vault_index()
  if vi_check then
    local ttl = config.connections.cache_ttl
    local now = vim.uv.now() / 1000
    local cached = _cache:get(source_rel_path)
    if filter_utils.is_cache_gen_valid(cached, index_gen_check, "index_gen")
      and (now - cached.timestamp) < ttl
    then
      return cached.results
    end
  end

  -- Cache miss: full scoring pipeline — lines 775-798
  local s = prepare_compute(source_rel_path)  -- Sets up shared state (lines 705-752)
  if not s then return {} end

  local now = vim.uv.now() / 1000
  local top = create_top_k(max_results)
  local arena_scope = render_arena.begin_scope()
  local checked = 0
  for rel_path, entry in pairs(s.files) do
    if opts_cancel then
      checked = checked + 1
      if checked % 200 == 0 and opts_cancel() then
        render_arena.end_scope(arena_scope)
        return nil, "cancelled"
      end
    end
    score_candidate(rel_path, entry, source_rel_path, s.source_data,
      s.weights, s.idf, s.total_pages, s.max_remaining, top, s.vi, s.resolve, arena_scope)
  end
  render_arena.end_scope(arena_scope)
  local results = top.results()

  -- Build dependency set and cache results (lines 800-813)
  local deps = {}
  for _, r in ipairs(results) do
    deps[r.rel_path] = true
  end
  _cache:put(source_rel_path, {
    source_path = source_rel_path,
    results = results,
    deps = deps,
    timestamp = now,
    index_gen = s.index_gen,
  })

  return results
end
```

**Note on cache invalidation:** `prepare_compute()` (lines 705-752) now uses subscriber-based change tracking (`_pending_changed` at line 50, `_pending_full_clear` at line 51) to perform incremental note data cache invalidation rather than full clears on generation change. It also calls `vi:snapshot_files()` for consistent iteration during scoring.

**With deduplication** (`connections.lua`):
```lua
local coalescer = require("andrew.vault.request_coalescer")

function M.compute(source_rel_path, max_results, opts_cancel)
  -- Cache check remains outside coalescer (fast path)
  local vi_check, index_gen_check = get_vault_index()
  if vi_check then
    local ttl = config.connections.cache_ttl
    local now = vim.uv.now() / 1000
    local cached = _cache:get(source_rel_path)
    if filter_utils.is_cache_gen_valid(cached, index_gen_check, "index_gen")
      and (now - cached.timestamp) < ttl
    then
      return cached.results
    end
  end

  -- Coalesced compute for cache misses
  local key = "connections:" .. source_rel_path
  local result, err = coalescer.request_async(key, function(resolve, reject)
    local ok, results = pcall(function()
      local s = prepare_compute(source_rel_path)
      if not s then return {} end
      local top = create_top_k(max_results)
      local arena_scope = render_arena.begin_scope()
      for rel_path, entry in pairs(s.files) do
        score_candidate(rel_path, entry, source_rel_path, s.source_data,
          s.weights, s.idf, s.total_pages, s.max_remaining, top, s.vi, s.resolve, arena_scope)
      end
      render_arena.end_scope(arena_scope)
      return top.results()
    end)
    if ok then resolve(results) else reject(results) end
  end)
  return result, err
end
```

**Actual current compute_async** (lines 828-854, uses `yield_iter.run_async()` with `yield_iter.for_each_yielding()` and batch_size `config.connections.score_batch_size`; note: does NOT use result cache by design — for interactive one-shot use):
```lua
function M.compute_async(source_rel_path, opts)
  opts = opts or {}
  local yield_iter = require("andrew.vault.yield_iter")
  local batch_size = config.connections.score_batch_size or 200
  local max_results_arg = opts.max_results or config.connections.max_results

  return yield_iter.run_async(function()
    local s = prepare_compute(source_rel_path)
    if not s then return {} end
    local top = create_top_k(max_results_arg)
    local arena_scope = render_arena.begin_scope()
    yield_iter.for_each_yielding(s.files, batch_size, function(rel_path, entry)
      score_candidate(rel_path, entry, source_rel_path, s.source_data,
        s.weights, s.idf, s.total_pages, s.max_remaining, top, s.vi, s.resolve, arena_scope)
    end, { cancelled = opts.cancelled })
    render_arena.end_scope(arena_scope)
    return top.results()
  end, opts.callback)
end
```

**With deduplication** (`connections.lua compute_async`):
```lua
function M.compute_async(source_rel_path, opts)
  opts = opts or {}
  local key = "connections:" .. source_rel_path
  coalescer.request(key, function(resolve, reject)
    local yield_iter = require("andrew.vault.yield_iter")
    local batch_size = config.connections.score_batch_size or 200
    local max_results_arg = opts.max_results or config.connections.max_results

    yield_iter.run_async(function()
      local s = prepare_compute(source_rel_path)
      if not s then return {} end
      local top = create_top_k(max_results_arg)
      local arena_scope = render_arena.begin_scope()
      yield_iter.for_each_yielding(s.files, batch_size, function(rel_path, entry)
        score_candidate(rel_path, entry, source_rel_path, s.source_data,
          s.weights, s.idf, s.total_pages, s.max_remaining, top, s.vi, s.resolve, arena_scope)
      end, { cancelled = opts.cancelled })
      render_arena.end_scope(arena_scope)
      return top.results()
    end, function(results) resolve(results) end)
  end, opts.callback)
end
```

### 3. embed.lua render_embeds() — Coalesce Instead of Cancel-Restart

**Current state:** `embed.lua:404` calls `cancel_async_render(bufnr)` (defined at lines 203-207) before starting new render, wasting any work already completed. Has generation-based staleness detection (`check_generation` at lines 348-353, generation assigned at line 421) and "pending" state (lines 753-756) but still cancels and restarts.

**Actual current code** (`embed.lua:394-462`):
```lua
function M.render_embeds(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local bufpath = vim.api.nvim_buf_get_name(bufnr)

  if not engine.is_vault_path(bufpath) then return end

  cancel_async_render(bufnr)  -- ← Line 404: Cancels in-flight render, wasting work

  vim.api.nvim_buf_clear_namespace(bufnr, state.ns, 0, -1)
  images.clear_image_placements(bufnr)

  local arena_scope = render_arena.begin_scope()
  local PlacementMod, snacks_doc_cfg, merge = init_render_deps()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local descs = build_descriptors(lines)
  warm_embed_cache(descs, bufpath, arena_scope)
  local old_state = state._embed_descriptors[bufnr]
  if old_state and old_state.list then
    _desc_pool:release_batch(old_state.list)
  end
  local generation = (old_state and old_state.generation or 0) + 1  -- Line 421
  state._embed_descriptors[bufnr] = { generation = generation, list = descs, async_timer = nil }

  local ctx = build_render_ctx(bufnr, bufpath, opts, descs, PlacementMod, snacks_doc_cfg, merge)

  if config.embed.lazy then
    local margin = config.embed.lazy_margin
    local top, bot = visible_range(margin)
    local rendered_count = render_in_range(descs, ctx, top, bot)
    local unrendered_count = #descs - rendered_count
    if unrendered_count > 0 then
      render_remaining_async(bufnr, generation, ctx)
    end
  else
    for _, desc in ipairs(descs) do render_single_embed(desc, ctx) end
  end
  update_deps(bufnr, ctx.deps)
  state.embeds_visible[bufnr] = true

  state._image_retry_fired[bufnr] = false
  if ctx.stats.images == 0 and ctx.stats.errors > 0 and PlacementMod then
    images.schedule_retry(bufnr, function(o) M.render_embeds(o) end)
  end

  -- ... notification stats (lines 450-459) ...
  render_arena.end_scope(arena_scope)
end
```

**Trigger paths:**
- `BufReadPost`: defer via `config.embed.render_delay_ms` (`embed.lua:747-760`)
- `BufEnter` via `event_dispatch.lua:65-112` coalescer → `embed.on_buf_enter()` (lines 813-825)
  - Note: BufEnter/TextChanged autocmds removed from embed.lua (line 762 comment); now dispatched via `event_dispatch.lua`
- `TextChanged` via `embed_sync.schedule_rerender()`: debounced
- `WinScrolled`: debounced scroll handler (lines 764-800) for lazy rendering
- Manual: `:VaultEmbedRender`, `:VaultEmbedToggle`

**With deduplication** (`embed.lua`):
```lua
local coalescer = require("andrew.vault.request_coalescer")

function M.render_embeds(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local bufpath = vim.api.nvim_buf_get_name(bufnr)

  if not engine.is_vault_path(bufpath) then return end

  local key = "embed_render:" .. bufnr
  coalescer.request(key, function(resolve, reject)
    local ok, err = pcall(function()
      -- Existing pipeline: clear namespace, build_descriptors, warm_embed_cache,
      -- manage descriptor pool, build_render_ctx, render_in_range / render_remaining_async
      -- ... all existing render logic unchanged ...
    end)
    if ok then resolve(true) else reject(err) end
  end, function(_, err)
    if err and not (opts and opts.silent) then
      notify.warn("embed render failed: " .. err)
    end
  end)
end
```

**Note:** For embeds, the cancel-restart pattern may still be preferable when the buffer content has changed (e.g., TextChanged). The coalescer should only be used for identical re-renders (same buffer, same content). Consider using the coalescer only for the BufReadPost/BufEnter race and keeping cancel-restart for TextChanged triggers. Note that BufEnter is now dispatched via `event_dispatch.lua` (line 90) to `embed.on_buf_enter()` (lines 813-825), which checks `if not state.embeds_visible[ctx.bufnr]` before deferring a render with a 50ms delay. The WinScrolled handler (lines 764-800) also debounces scroll-triggered re-renders for lazy rendering.

### 4. search_filter.evaluate_async() — AST-Keyed Deduplication

**Current state:** `search_filter.lua:482-507` provides `evaluate_async()` via `yield_iter.run_async()` using `yield_iter.filter_yielding()` with batch_size `config.search.evaluate_batch_size` (default 500). Rapid live-mode keystrokes could overlap evaluations.

**Actual current code** (`search_filter.lua:400-507`):

`prepare_evaluate()` (lines 400-434) now includes:
- Index snapshot support via `config.index.use_snapshots` for consistent reads during async builds
- `extract_pre_checks()` optimization for fast-path rejection before full predicate evaluation
- `build_filter_context()` for arena-allocated filter context tables

`evaluate()` (lines 436-467):
```lua
function M.evaluate(ast, index, graph_sets, restrict_to, cancelled)
  local arena_scope = render_arena.begin_scope()
  local files, predicate, max_files = prepare_evaluate(ast, index, graph_sets, restrict_to, arena_scope)
  if not files then
    render_arena.end_scope(arena_scope)
    return {}, false
  end

  local matches = {}  -- escapes scope, NOT from arena
  local count = 0
  local checked = 0
  for rel_path, entry in pairs(files) do
    if cancelled then
      checked = checked + 1
      if checked % 200 == 0 and cancelled() then
        render_arena.end_scope(arena_scope)
        return nil, "cancelled"
      end
    end
    if predicate(rel_path, entry) then
      matches[rel_path] = entry
      count = count + 1
      if max_files and count >= max_files then
        render_arena.end_scope(arena_scope)
        return matches, true
      end
    end
  end

  render_arena.end_scope(arena_scope)
  return matches, false
end
```

`evaluate_async()` (lines 482-507) returns a `cancel()` function from `yield_iter.run_async()`:
```lua
function M.evaluate_async(ast, index, opts)
  opts = opts or {}
  local batch_size = config.search.evaluate_batch_size or 500

  return yield_iter.run_async(function()
    local arena_scope = render_arena.begin_scope()
    local files, predicate, max_files = prepare_evaluate(
      ast, index, opts.graph_sets, opts.restrict_to, arena_scope)
    if not files then
      render_arena.end_scope(arena_scope)
      return {}, false
    end

    local matches, limit_reached = yield_iter.filter_yielding(
      files,
      batch_size,
      predicate,
      {
        cancelled = opts.cancelled,
        max_results = max_files,
      }
    )
    render_arena.end_scope(arena_scope)
    return matches, limit_reached
  end, opts.callback)
end
```

**With deduplication** (wrap `evaluate_async`, not `evaluate` — sync evaluate is already fast enough):
```lua
local coalescer = require("andrew.vault.request_coalescer")

function M.evaluate_async(metadata_ast, index, opts)
  opts = opts or {}
  -- Hash the AST + restrict_to to create a deduplication key
  local key = "search:" .. ast_hash(metadata_ast)
  if opts.restrict_to then
    key = key .. ":restricted"  -- Different key when pre-filtered
  end

  coalescer.request(key, function(resolve, reject)
    local batch_size = config.search.evaluate_batch_size or 500
    yield_iter.run_async(function()
      local arena_scope = render_arena.begin_scope()
      local files, predicate, max_files = prepare_evaluate(
        metadata_ast, index, opts.graph_sets, opts.restrict_to, arena_scope)
      if not files then
        render_arena.end_scope(arena_scope)
        return {}, false
      end
      local matches, limit_reached = yield_iter.filter_yielding(
        files, batch_size, predicate,
        { cancelled = opts.cancelled, max_results = max_files })
      render_arena.end_scope(arena_scope)
      return matches, limit_reached
    end, function(matches, limit)
      resolve({ matches = matches, limit = limit })
    end)
  end, function(result, err)
    if opts.callback then
      if err then
        opts.callback(nil, false)
      else
        opts.callback(result.matches, result.limit)
      end
    end
  end)
end
```

### 5. link_utils.resolve_note_via_index() — Resolution Deduplication (LOW PRIORITY)

**Current state:** `link_utils.lua:517-536` provides `resolve_note_via_index(name)` which queries `vault_index:resolve_name(name)` and uses `pick_closest(paths)` (lines 483-509) for disambiguation. This is already fast (in-memory index lookup + proximity scoring) and `filter_utils.create_memoized_resolver()` already caches resolutions within a single evaluate pass.

**Actual current code** (`link_utils.lua:517-536`):
```lua
function M.resolve_note_via_index(name)
  local vi = require("andrew.vault.vault_index")
  local idx = vi.current()
  if not idx or not idx:is_ready() then return nil, nil end

  local paths = idx:resolve_name(name)  -- _name_index + _alias_index lookup
  if not paths or #paths == 0 then return nil, nil end

  local abs_path = M.pick_closest(paths)
  local rel_path = -- ... strip vault_path prefix ...
  local entry = idx.files[rel_path]
  return abs_path, entry  -- returns nil for entry at line 535 if not found
end
```

**Assessment:** This function is synchronous, fast (in-memory index lookup), and already memoized per-evaluate-pass via `filter_utils.create_memoized_resolver()`. Request coalescing would add overhead without meaningful benefit. **Skip this integration.**

---

## Configuration

```lua
-- config.lua additions (alongside existing config.events section at lines 890-895)
M.coalescer = {
  max_waiters = 50,       -- Maximum callbacks per in-flight operation
  timeout_ms = 30000,     -- Auto-cancel operations that take too long
  debug = false,          -- Log coalescing events via vault_log
}
```

Called during vault initialization (`init.lua`, alongside existing `event_dispatch.setup()` at line 243):

```lua
-- init.lua (in setup, near event_dispatch.setup())
local coalescer = require("andrew.vault.request_coalescer")
coalescer.configure(config.coalescer)
```

---

## Monitoring

Add `:VaultCoalescerStats` command (registered in `init.lua` alongside existing `:VaultIndexStatus`, `:VaultEmbedDebug`, `:VaultCompletionDebug`):

```
Coalescer Stats:
  Total operations:  142
  Total coalesced:   87
  Total cancelled:   3
  Currently in-flight: 0
  Coalesce rate:     38.0%

  (87 duplicate requests avoided out of 229 total requests)
```

A high coalesce rate indicates the optimization is actively preventing duplicate work.

Add `:VaultCoalescerDebug` command showing in-flight operations:

```
In-Flight Operations:
  index_rebuild (3 waiters)
  connections:/notes/project.md (2 waiters)
```

---

## Implementation Notes

### Thread Safety in Lua

Lua is single-threaded, so the in-flight registry does not need locks. However, care must be taken with:

- **Re-entrant calls:** A waiter callback could trigger a new `request()` for the same key. The implementation handles this by removing the entry from the registry before notifying waiters.
- **vim.schedule:** Operations using `vim.schedule` or timers complete asynchronously. The `resolve`/`reject` callbacks are wrapped in `vim.schedule` to ensure registry mutations happen on the main thread.
- **Coroutine interaction:** `request_async` yields the calling coroutine and resumes it when the result arrives. This integrates naturally with the vault's existing `yield_iter.run_async()` coroutine-based async pattern.

### Key Design Decisions

1. **String keys, not object identity:** Keys are strings (e.g., `"index_rebuild"`, `"connections:/path"`) because Lua tables use reference equality for table keys, and callers may construct equivalent-but-distinct request objects.

2. **Callback-based, not promise-based:** Lua lacks built-in promise/future types. The callback + coroutine wrapper approach matches the vault's existing patterns (used throughout `yield_iter`, `completion_base`, `connections.compute_async`).

3. **Self-removing entries:** Operations are removed from the registry immediately upon completion (before notifying waiters). This prevents stale entries from blocking future operations and avoids re-entrancy issues. Mirrors Zed's `this.loading_buffers.remove(&project_path)` at buffer_store.rs line 817.

4. **Result sharing via reference:** All waiters receive the same result object. This is efficient for read-only results (index data, connection scores) but callers should not mutate shared results. If mutation is needed, callers should copy the result.

5. **Uses resource_cleanup.close_timer():** Timer cleanup delegates to the existing `resource_cleanup` module (`close_timer` at lines 9-17, `debounce` at lines 35-41) rather than reimplementing `is_closing()` checks, consistent with all other vault modules.

6. **Complements, doesn't replace, existing guards:** The `_building` flag in `vault_index_build.lua` is retained for the `update_files_batch()` guard. The embed generation counter is retained for staleness detection. The coalescer adds waiter aggregation on top of these existing mechanisms.

### AST Hashing for Search Deduplication

Search query deduplication requires hashing the parsed AST to a string key. The AST uses nodes with types: `text`, `quoted`, `regex`, `field`, `has`, `task`, `graph`, `and`, `or`, `not` (per `search_query.lua` token types). A recursive serialization:

```lua
local function ast_hash(node)
  if not node then return "nil" end
  if node.type == "text" or node.type == "quoted" then
    return "T:" .. (node.value or "")
  elseif node.type == "regex" then
    return "R:" .. (node.pattern or "")
  elseif node.type == "field" then
    return "F:" .. (node.field or "") .. ":" .. (node.op or "") .. ":" .. (node.value or "")
  elseif node.type == "has" then
    return "H:" .. (node.field or "")
  elseif node.type == "task" then
    return "K:" .. (node.meta_field or "") .. ":" .. (node.op or "") .. ":" .. (node.value or "")
  elseif node.type == "graph" then
    return "G:" .. (node.depth or "") .. ":" .. (node.dir or "") .. ":" .. (node.center or "")
  elseif node.type == "and" or node.type == "or" then
    return node.type .. "(" .. ast_hash(node.left) .. "," .. ast_hash(node.right) .. ")"
  elseif node.type == "not" then
    return "NOT(" .. ast_hash(node.child) .. ")"
  end
  return tostring(node)
end
```

### Timeout Cleanup

The timeout timer uses `vim.uv.new_timer()` and is cleaned up via `resource_cleanup.close_timer()` (consistent with timer handling in `event_coalescer.lua`, `completion_base.lua`, and `embed.lua`). The timer is closed in `_resolve_entry()` which is called on all completion paths: success, failure, timeout, and cancellation.

---

## Interaction with Existing Patterns

| Module/Pattern | Interaction |
|----------------|-------------|
| `event_coalescer.lua` (BufEnter batching, `config.events.buf_enter_coalesce_ms = 16`) | Reduces event-level duplicates; request_coalescer handles operation-level duplicates that survive batching |
| `process_semaphore.lua` (concurrency limiting for ripgrep) | Coalesced requests share a single process slot instead of each acquiring one |
| `yield_iter.run_async()` (cooperative coroutine scheduling) | Coalesced coroutine operations yield once for all waiters, not once per caller |
| `resource_cleanup.debounce()` (timer-based debounce) | Debounce prevents rapid re-triggers; coalescer handles near-simultaneous arrivals |
| `completion_base.lua` active_state (per-source build dedup) | Already effective for completion; coalescer not needed here |
| `url_validate.lua` _inflight (per-URL dedup) | Already implements the same pattern; no changes needed |
| `connections.lua` multi-cache system (result weighted LRU + IDF cache + note data weighted LRU + gen + subscriber-based invalidation + deps) | Cache hits avoid recompute; coalescer handles concurrent cache misses |
| Doc 21 (Stale Cancellation) | Complementary: cancel stale work AND deduplicate current work. A cancelled operation via Doc 21 also resolves all coalesced waiters |
| Doc 07 (Debounced Persistence) | Index rebuild coalescing reduces the number of post-rebuild persistence writes |

---

## Validation

1. **Coalescing test:** Call `build_async(callback)` 5 times in 10ms — verify only 1 `yield_iter.run_async` coroutine runs, all 5 callbacks receive the result.
2. **Callback notification test:** Verify that callers arriving while `_building == true` now receive notification when the build completes (instead of being silently dropped).
3. **Waiter cap test:** Exceed `max_waiters` — verify excess callers receive immediate error, operation continues for existing waiters.
4. **Timeout test:** Start an operation that never resolves — verify it is cancelled after `timeout_ms` and all waiters notified.
5. **Re-entrant test:** Have a waiter callback trigger a new `request()` for the same key — verify the new request starts fresh (not joined to the completed one).
6. **Cancel test:** Cancel an in-flight operation — verify all waiters receive `nil, "cancelled"`.
7. **Connection race test:** Trigger `connections.compute("note.md")` from two call sites within 5ms — verify only one scoring pipeline runs.
8. **Embed coalesce-vs-restart test:** Verify BufReadPost + BufEnter race coalesces, but TextChanged still cancels and restarts (content changed).
9. **Memory test:** Verify waiter arrays and result references are GC-eligible after resolution.

---

## Expected Impact

### Revised Assessment (Accounting for Existing Guards)

| Without Coalescer | With Coalescer |
|-------------------|----------------|
| `build_async()` callers during active build silently dropped | All callers notified when build completes |
| 2 concurrent connection computes on cache miss | 1 compute, 1 coalesced |
| BufReadPost render cancelled + restarted by BufEnter | Single render, BufEnter joins |
| Search live eval may overlap | Identical ASTs coalesced |

### Operation Reduction by Module

| Module | Current Guard | Remaining Gap | Coalescer Reduction |
|--------|--------------|---------------|-------------------|
| `vault_index_build.build_async` | `_building` flag (prevents concurrent) | Callbacks silently lost | 100% callback delivery (API correctness, not CPU savings) |
| `connections.compute` | 3-tier LRU cache | Concurrent cache misses | 50-66% fewer scoring runs during burst navigation |
| `embed.render_embeds` | `cancel_async_render` + generation | Cancel wastes partial work | 50% fewer restarts on BufReadPost/BufEnter race |
| `search_filter.evaluate_async` | Cancellation flag (checked every 200 entries) | Overlapping identical evals | 0-50% fewer evaluations during rapid live search |
| **Overall** | | | **Moderate improvement — correctness fix for index, CPU savings for connections/embeds** |

### Combined with Doc 21

When both optimizations are active:
- Doc 25 prevents duplicate work from being spawned
- Doc 21 cancels stale work that has been superseded
- Net effect: only the minimum necessary work runs at any time
