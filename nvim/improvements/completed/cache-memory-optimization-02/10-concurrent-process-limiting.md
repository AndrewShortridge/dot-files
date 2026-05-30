# 10 — Concurrent Process Limiting

## Priority: HIGH
## Inspired By: Zed's `Arc<Semaphore>` in `inlay_hint_cache.rs`, bounded channels / `ready_chunks` in `project.rs`

## Problem

The vault spawns ripgrep (`rg`) processes without concurrency limits. Multiple simultaneous
operations (live search typing, graph queries, search-in-files) can spawn unbounded `rg`
child processes, causing:

1. **Process exhaustion:** Each `rg` spawn consumes a PID, file descriptors, and ~5-10 MB RSS
2. **I/O contention:** Multiple `rg` processes scanning the same vault directory thrash disk cache
3. **Memory spikes:** N concurrent `rg` outputs buffered in Lua tables simultaneously
4. **Stale results:** Earlier searches complete after newer ones, displaying outdated results

### Current State

```lua
-- search_filter/ripgrep.lua: No limit on concurrent spawns
-- Async path (L161-166):
local function spawn_rg_async(node, file_paths, vault_path, tmpfile, on_done)
  local args, process = prepare_rg_call(node, file_paths, vault_path, tmpfile)
  vim.system(args, { text = true }, function(result)  -- Unbounded!
    on_done(process(result))
  end)
end

-- Sync path (L221-224):
local function run_rg_sync(node, file_paths, vault_path, tmpfile)
  local args, process = prepare_rg_call(node, file_paths, vault_path, tmpfile)
  return process(vim.system(args, { text = true }):wait())  -- Blocking
end

-- Parallel spawn for AND/OR nodes (L254-271):
local function sync_binary(text_ast, file_paths, vault_path, tmpfile, combine_fn)
  local left, right
  if is_leaf(text_ast.left) and is_leaf(text_ast.right) then
    local l_args, l_process = prepare_rg_call(text_ast.left, file_paths, vault_path, tmpfile)
    local r_args, r_process = prepare_rg_call(text_ast.right, file_paths, vault_path, tmpfile)
    local lh = vim.system(l_args, { text = true })  -- Both spawned immediately (L261)
    local rh = vim.system(r_args, { text = true })  -- No concurrency limit    (L262)
    left = l_process(lh:wait())                     -- Wait sequentially        (L263)
    right = r_process(rh:wait())                    --                          (L264)
  else
    left = ripgrep_recursive_sync(text_ast.left, file_paths, vault_path, tmpfile)
    right = ripgrep_recursive_sync(text_ast.right, file_paths, vault_path, tmpfile)
  end
  return combine_fn(left, right)
end

-- Async binary coordination (L281-300):
local function async_binary(text_ast, file_paths, vault_path, tmpfile, combine_fn, on_done)
  local left_result, right_result
  local pending = 2
  local function check_done()
    pending = pending - 1
    if pending == 0 then on_done(combine_fn(left_result, right_result)) end
  end
  -- Both children dispatched concurrently, no limit
  ripgrep_recursive_async(text_ast.left, ..., function(lines) left_result = lines; check_done() end)
  ripgrep_recursive_async(text_ast.right, ..., function(lines) right_result = lines; check_done() end)
end
```

**Key entry point:**
- `M.ripgrep_in_files(text_ast, file_paths, vault_path, on_done?)` (L393-430)
  - Dual-mode: async (with `on_done` callback) or sync (blocking via `:wait()`)
  - File list passed via `--files-from=<tmpfile>` to avoid shell arg limits
  - Recursive dispatchers: `ripgrep_recursive_async()` (L343-373) and `ripgrep_recursive_sync()` (L309-334)
  - Re-exported from `search_filter.lua` (L30): `M.ripgrep_in_files = ripgrep_mod.ripgrep_in_files`

**Modules that spawn `rg`:**
- `search_filter/ripgrep.lua` — text search (called per AST node for AND/OR trees, can spawn multiple concurrent `vim.system()` calls)
  - `spawn_rg_async()` (L163): single async rg via callback
  - `sync_binary()` (L261-262): parallel 2-process spawn for AND/OR leaf nodes
  - `run_rg_sync()` (L223): blocking single rg with `:wait()`
- `search/live.lua` — fzf_live provider (L155-188), calls `search_filter.ripgrep_in_files()` in **sync blocking mode** (L177-178, no `on_done` callback); debounce via fzf `query_delay` (L194 = `config.search.live_debounce_ms`)
- `search/advanced.lua` — prompt-mode search, `execute_advanced_query()` (L219-343) calls `evaluate_advanced_ast()` (L182-213) in **async mode** with `on_done` callback; `resolve_query()` (L48-164) dispatches ripgrep at L71 (text-only), L113 (metadata+text), L156 (mixed-or)
- `unlinked/rg_pipeline.lua` — `rg_search()` (L38-68) spawns single rg via `vim.system()` at L50 for unlinked mention detection
- `rename.lua` — `discover_from_rg()` (L104-122, vim.system at L108) and `tag_rename()` (L418-560, vim.system at L435) spawn rg for wikilink/tag discovery
- `navigate.lua` — `find_by_subtype()` (L104-134, vim.system at L115) and `review_list()` (L342-424, vim.system at L354) spawn rg for review file discovery
- `linkcheck.lua` — `scan_broken_links()` (L263-384, vim.system at L270) spawns rg for wikilink scanning; `check_urls_vault()` (L503-570, vim.system at L507) spawns rg for URL extraction

**Modules that do NOT spawn `rg` (confirmed):**
- `query/init.lua` — uses vault index only, no direct rg spawning
- `vault_index.lua` — purely metadata-based, no ripgrep dependency

### Impact Scenario (Live Search)

Live search (`search/live.lua`) uses **synchronous** ripgrep execution inside the fzf_live provider
function (L155-188). Each keystroke (after 150ms debounce via `config.search.live_debounce_ms`) blocks until
all rg processes complete. However, fzf-lua can invoke the provider concurrently:

```
User types "type:note project" (16 chars, 150ms debounce):
  → ~5 debounce fires from fzf_live provider
  → Each fire: 1 metadata eval + 1-3 sync rg spawns (AND/OR tree)
  → sync_binary() spawns both children as vim.system() simultaneously
  → Peak: 5-15 concurrent rg processes (overlapping I/O via parallel vim.system())
  → Memory: 50-150 MB transient RSS
  → Incremental cache (_prev_cache) helps for prefix queries but not for edits
```

**Existing mitigations (insufficient):**
- fzf `query_delay` (150ms) debounces keystrokes, not ripgrep spawning itself
- `_prev_cache` in live.lua (L37-84) restricts file set when new query is superset of previous (prefix optimization); uses `idx._generation` for staleness detection
- No cancellation of in-flight rg processes when new keystroke arrives

### Existing Concurrency Precedent: `url_validate.lua`

The vault already has a working concurrency pattern in `url_validate.lua` (L10, L315-322):

```lua
-- url_validate.lua: In-flight tracking + hard concurrency limit
local _inflight = {}  -- url -> true (L10)

-- Before spawning (L315-322):
if _inflight[url] then return end  -- Dedup in-flight

if vim.tbl_count(_inflight) >= cfg.max_concurrent then
  callback({ url = url, status = -2, error = "concurrency limit" })
  return
end

-- Rate limit check per domain (L325-332):
local domain = url_domain(url)
local can_req, wait_ms = check_rate_limit(domain)
if not can_req then
  vim.defer_fn(function() M.validate_url(url, callback, opts) end, wait_ms)
  return
end

_inflight[url] = true
vim.system(curl_args, { text = true }, function(result)
  _inflight[url] = nil  -- Release on completion
  -- process result...
end)
```

Configuration: `config.url_validation.max_concurrent = 5` (config.lua L653)

Additionally, `validate_batch()` (L421-461) uses a queue-based dispatcher that spawns up to
`max_concurrent` requests initially, then processes the next URL from the queue after each completion.

This pattern works but lacks queuing with backpressure (requests are rejected or deferred with retry)
and has no generation-based cancellation. The semaphore module below provides a more robust foundation.

### Existing Cancellation Precedent: `completion_base.lua`

The completion system has a generation-based cancellation pattern (L54-302):

```lua
-- Active async build state (for cancellation)
local active_state = nil -- { cancelled: bool, timer: uv_timer|nil }
local build_generation = 0  -- Incremented on invalidation (L54)

-- cancel_active() sets active_state.cancelled = true (L148-157)
-- Guard clauses check: if state.cancelled or gen ~= build_generation (L212, 221, 235, 275)
-- Returns cancel function to blink.cmp (L229, 301)
```

This pattern — cancelled flag + generation counter — can be adapted for ripgrep process cancellation.

## Proposed Solution

### 1. Process Semaphore Module

Create `lua/andrew/vault/process_semaphore.lua`:

```lua
--- Process semaphore for bounding concurrent subprocess spawns.
--- Inspired by Zed's Arc<Semaphore> pattern in inlay_hint_cache.rs.

local M = {}

--- @class ProcessSemaphore
--- @field _max number Maximum concurrent permits
--- @field _active number Currently held permits
--- @field _queue function[] Callbacks waiting for permits
--- @field _generation number Incremented on reset (cancels queued waiters)

--- Create a new semaphore with max concurrent permits.
--- @param max number
--- @return ProcessSemaphore
function M.new(max)
  return {
    _max = max,
    _active = 0,
    _queue = {},
    _generation = 0,
  }
end

--- Acquire a permit. Calls callback immediately if available,
--- otherwise queues it. Returns a cancel function.
--- @param sem ProcessSemaphore
--- @param callback function Called with release_fn when permit acquired
--- @return function cancel Cancel the queued request
function M.acquire(sem, callback)
  local gen = sem._generation

  if sem._active < sem._max then
    sem._active = sem._active + 1
    local released = false
    local function release()
      if released then return end
      released = true
      sem._active = sem._active - 1
      M._drain_queue(sem)
    end
    callback(release)
    return function() end  -- Already acquired, cancel is no-op
  end

  -- Queue the request
  local cancelled = false
  local entry = { callback = callback, gen = gen }
  table.insert(sem._queue, entry)

  return function()
    cancelled = true
    entry.callback = nil  -- Allow GC of closure
  end
end

--- Try to acquire without queuing. Returns release_fn or nil.
--- Mirrors Zed's try_acquire() fast-path in inlay_hint_cache.rs (L948).
--- @param sem ProcessSemaphore
--- @return function|nil release_fn
function M.try_acquire(sem)
  if sem._active < sem._max then
    sem._active = sem._active + 1
    local released = false
    return function()
      if released then return end
      released = true
      sem._active = sem._active - 1
      M._drain_queue(sem)
    end
  end
  return nil
end

--- Cancel all queued waiters (e.g., on search cancel).
--- @param sem ProcessSemaphore
function M.reset(sem)
  sem._generation = sem._generation + 1
  sem._queue = {}
  -- Note: active permits still held until released
end

--- @private
function M._drain_queue(sem)
  while sem._active < sem._max and #sem._queue > 0 do
    local entry = table.remove(sem._queue, 1)
    if entry.callback and entry.gen == sem._generation then
      sem._active = sem._active + 1
      local released = false
      local function release()
        if released then return end
        released = true
        sem._active = sem._active - 1
        M._drain_queue(sem)
      end
      entry.callback(release)
    end
  end
end

--- Get current state for debugging.
--- @param sem ProcessSemaphore
--- @return table { active, max, queued }
function M.stats(sem)
  return {
    active = sem._active,
    max = sem._max,
    queued = #sem._queue,
  }
end

return M
```

### 2. Apply to Ripgrep Spawns

In `search_filter/ripgrep.lua`, wrap `spawn_rg_async()` and `vim.system()` calls:

```lua
local semaphore = require("andrew.vault.process_semaphore")
local config = require("andrew.vault.config")

-- Module-level semaphore, initialized from config
local _rg_sem = semaphore.new(config.search.max_concurrent_rg)

--- Wrap spawn_rg_async with semaphore permit.
--- Returns a cancel function that kills the process and releases the permit.
local function spawn_rg_limited(node, file_paths, vault_path, tmpfile, on_done)
  local process_obj = nil
  local cancel = semaphore.acquire(_rg_sem, function(release)
    process_obj = vim.system(args, { text = true }, function(result)
      release()  -- Return permit on process exit
      on_done(process(result))
    end)
  end)

  -- Return cancel function: kills process if running, or cancels queued request
  return function()
    if process_obj then
      process_obj:kill()  -- vim.system object has :kill() method
    end
    cancel()
  end
end

--- Wrap sync path with try_acquire (non-blocking, skip queue).
--- Falls back to unbounded if semaphore full (sync callers can't wait).
local function run_rg_sync_limited(node, file_paths, vault_path, tmpfile)
  local release = semaphore.try_acquire(_rg_sem)
  local result = vim.system(args, { text = true }):wait()
  if release then release() end
  return process(result)
end
```

**Integration with `async_binary()`:** Both children go through semaphore, naturally serializing
when limit reached:

```lua
local function async_binary_limited(text_ast, ...)
  local pending = 2
  local function check_done()
    pending = pending - 1
    if pending == 0 then on_done(combine_fn(left_result, right_result)) end
  end
  -- Each child acquires its own permit via spawn_rg_limited
  spawn_rg_limited(left_node, ..., function(result) left_result = result; check_done() end)
  spawn_rg_limited(right_node, ..., function(result) right_result = result; check_done() end)
end
```

### 3. Search Cancellation on New Query

Live search uses **sync blocking mode** inside fzf_live's provider function (L155-188). The semaphore
primarily helps with:
- **Prompt mode** (`search/advanced.lua`): async searches that can overlap
- **AND/OR tree expansion**: limiting concurrent rg for complex boolean queries
- **Cross-module contention**: preventing search + rename + linkcheck from exhausting PIDs

For live search specifically, the sync blocking nature means fzf handles serialization,
but the semaphore still bounds parallel `vim.system()` calls within `sync_binary()`:

```lua
-- search/live.lua: The provider function is called synchronously by fzf_live (L155-188).
-- Each keystroke waits for all rg processes to complete before returning.
-- Semaphore limits concurrent vim.system() calls within the sync tree walk.

-- For prompt mode (search/advanced.lua), add cancellation:
local _active_search_cancel = nil

local function execute_advanced_query_cancellable(query_text, on_done)
  -- Cancel previous async search
  if _active_search_cancel then
    _active_search_cancel()
  end

  -- Reset semaphore queue (drop stale queued requests)
  semaphore.reset(_rg_sem)

  local cancel = evaluate_advanced_ast(ast, ..., function(results)
    _active_search_cancel = nil
    on_done(results)
  end)

  _active_search_cancel = cancel
end
```

### 4. Configurable Limits

In `config.lua`, add to existing `M.search` table (currently at L428-504, no concurrency keys):

```lua
M.search = {
  -- ... existing keys (live_debounce_ms, max_files_from, builtin_fields,
  --   field_aliases, has_targets, graph_operator, graph_max_depth,
  --   prompt_width, help_width, history, show_stats, field_correction,
  --   field_enums, grouping) ...
  max_concurrent_rg = 3,        -- Max simultaneous rg processes (semaphore permits)
  rg_queue_max = 5,             -- Max queued rg requests (drop oldest beyond this)
}
```

## Zed Reference

### Semaphore Pattern: `inlay_hint_cache.rs`

From `crates/editor/src/inlay_hint_cache.rs` (L29, L45, L277, L840, L941-952):

```rust
use smol::lock::Semaphore;  // smol crate, not tokio (L29)

const MAX_CONCURRENT_LSP_REQUESTS: usize = 5;  // L840

pub struct InlayHintCache {
    lsp_request_limiter: Arc<Semaphore>,  // L45
    // ...
}

// Initialization (L277):
lsp_request_limiter: Arc::new(Semaphore::new(MAX_CONCURRENT_LSP_REQUESTS)),

// Clone from editor (L941):
let lsp_request_limiter = Arc::clone(&editor.inlay_hint_cache.lsp_request_limiter);

// Acquisition with try_acquire fast-path + async fallback (L945-952):
let (lsp_request_guard, got_throttled) = if query.invalidate.should_invalidate() {
    (None, false)  // Skip limit during invalidations
} else {
    match lsp_request_limiter.try_acquire() {
        Some(guard) => (Some(guard), false),        // Non-blocking fast path (L948)
        None => (Some(lsp_request_limiter.acquire().await), true),  // Async wait (L950)
    }
};

// Throttle detection: skip requests outside visible range when throttled (L957)
// Release via drop(lsp_request_guard) after fetch completes
```

### Bounded Batch Processing: `project.rs`

From `crates/project/src/project.rs`:

```rust
// Hard search result caps (L146-147):
const MAX_SEARCH_RESULT_FILES: usize = 5_000;
const MAX_SEARCH_RESULT_RANGES: usize = 10_000;

// Buffer operations batching (L2691, L2721):
const MAX_BATCH_SIZE: usize = 128;
let mut changes = rx.ready_chunks(MAX_BATCH_SIZE);

// Search results batching (L3814):
let chunks = matching_buffers_rx.ready_chunks(64);
// Loads at most 64 buffers at a time to avoid overwhelming the main thread

// Limit enforcement (L3848-3849):
if buffer_count > MAX_SEARCH_RESULT_FILES
    || range_count > MAX_SEARCH_RESULT_RANGES
```

### Additional Concurrency Patterns in Zed

**Rate Limiter** (`crates/language_model/src/rate_limiter.rs`):
```rust
use smol::lock::{Semaphore, SemaphoreGuardArc};  // L2

pub struct RateLimiter {
    semaphore: Arc<Semaphore>,  // L13-14
}

pub struct RateLimitGuard<T> {
    inner: T,
    _guard: SemaphoreGuardArc,  // L17-19: held for lifetime of stream/result
}

// Constructor (L34-38): parametric limit
pub fn new(limit: usize) -> Self {
    Self { semaphore: Arc::new(Semaphore::new(limit)) }
}

// run() for futures (L40-54): acquire_arc().await, hold guard across await
// stream() for streams (L56-77): same pattern, wraps in RateLimitGuard
```

**Connection Guard** (`crates/collab/src/rpc.rs`, L92-120):
```rust
const MAX_CONCURRENT_CONNECTIONS: usize = 512;  // L92
static CONCURRENT_CONNECTIONS: AtomicUsize = AtomicUsize::new(0);  // L94

pub struct ConnectionGuard;  // L99

impl ConnectionGuard {
    pub fn try_acquire() -> Result<Self, ()> {  // L102
        let current_connections = CONCURRENT_CONNECTIONS.fetch_add(1, SeqCst);  // L103
        if current_connections >= MAX_CONCURRENT_CONNECTIONS {
            CONCURRENT_CONNECTIONS.fetch_sub(1, SeqCst);  // L105: rollback
            return Err(());
        }
        Ok(ConnectionGuard)
    }
}

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        CONCURRENT_CONNECTIONS.fetch_sub(1, SeqCst);  // L118: RAII release
    }
}
```

**Message Handler Semaphore** (`crates/collab/src/rpc.rs`, L832):
```rust
use tokio::sync::{Semaphore, watch};  // L76 — tokio, not smol

let concurrent_handlers = Arc::new(Semaphore::new(512));  // L832
// acquire_owned().await (L835) → permit held until handler completes
// drop(permit) inside handler closure (L869)
// Foreground/background separation via FuturesUnordered + select_biased! (L840)
```

**Scoped File Scans** (`crates/project/src/worktree_store.rs`, L698-712):
```rust
const MAX_CONCURRENT_FILE_SCANS: usize = 64;  // L698
let filters = cx.background_spawn(async move {  // L699
    executor.scoped(move |scope| {  // L702
        for _ in 0..MAX_CONCURRENT_FILE_SCANS {  // L704
            let filter_rx = filter_rx.clone();
            scope.spawn(async move {  // L706
                Self::filter_paths(fs, filter_rx, query).await;
            })
        }
    }).await;
});
```

**Eval Concurrency** (`crates/assistant_tools/src/edit_agent/evals.rs`, L1328):
```rust
let semaphore = Arc::new(smol::lock::Semaphore::new(32));  // 32 concurrent eval tasks
```

### Key Zed Design Principles

1. **Try-acquire + async fallback:** Non-blocking fast path, async wait on congestion (inlay_hint_cache.rs L948-950)
2. **Guard-based RAII:** Auto-release via Drop on guard objects (rpc.rs L116-120)
3. **Batching over individual limits:** `ready_chunks()` groups items to avoid per-item overhead (project.rs L2721, L3814)
4. **Throttle detection:** Track whether acquisition was delayed, skip low-priority work when throttled (inlay_hint_cache.rs L957)
5. **Scoped executors:** Fixed worker pool via `executor.scoped()` for bounded concurrency (worktree_store.rs L702-712)
6. **Dual semaphore crates:** smol for editor/language_model (cooperative async), tokio for collab server (runtime-based async)

## Expected Impact

| Metric | Before | After |
|--------|--------|-------|
| Peak concurrent rg processes | Unbounded (5-15 typical for complex queries) | 3 max |
| RSS during live search | 50-150 MB transient | 15-30 MB max |
| Stale result processing (prompt mode) | All complete, last wins | Cancelled on new query |
| I/O contention | High (parallel scans via sync_binary) | Bounded (sequential after 3) |
| AND/OR tree with 5 terms | 5 simultaneous rg | 3 active + 2 queued |

## Testing Strategy

1. Type rapidly in live search, verify `rg` process count ≤ 3 via `ps aux | grep rg`
2. Start prompt-mode search, immediately start another — verify first cancelled
3. Run `:VaultCacheStats` or equivalent — show semaphore stats (active/queued)
4. Stress test: 10 rapid queries, verify no orphaned `rg` processes after settling
5. AND/OR query with 5 terms — verify rg processes serialized through semaphore
6. Concurrent search + rename — verify combined rg count respects limit
7. Verify `try_acquire` in sync path doesn't deadlock when semaphore full

## Dependencies

- None (standalone module)
- Optional integration with doc 05 (search result limits)
- Follows precedent set by `url_validate.lua` concurrency pattern (L315-322)
- Cancellation pattern draws from `completion_base.lua` (L142-288)

## Implementation Notes

- Lua has no built-in semaphore — the callback-based approach works with Neovim's event loop
- `try_acquire` is useful for sync paths (live search via fzf_live L155-188) where callers can't wait
- `reset()` is critical for prompt-mode search — prevents queue buildup from rapid submissions
- Live search sync mode: semaphore bounds `sync_binary()` parallel spawns but provider still blocks
- `vim.system()` returns an object with `:kill()` method for cancellation (unlike `vim.fn.jobstart`)
- Consider exposing semaphore in `:VaultCacheStats` for debugging
- Additional rg-spawning modules (rename L108/L435, linkcheck L270/L507, navigate L115/L354, unlinked L50) can share the same semaphore to prevent cross-module process exhaustion
- `process_semaphore.lua` does not yet exist — it is a new module to be created
- `config.search` table (L428-504) currently has no concurrency keys; `max_concurrent_rg` and `rg_queue_max` are new additions
