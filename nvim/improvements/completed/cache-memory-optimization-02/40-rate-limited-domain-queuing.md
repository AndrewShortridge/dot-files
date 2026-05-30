# 40. Rate-Limited Domain Queuing

## Problem

`url_validate.lua` (611 lines) implements per-domain rate limiting via `config.url_validation.domain_rate_limit_ms` and a global `config.url_validation.max_concurrent` cap (default 5). In-flight request deduplication is handled by a `url_pool` coalescer object (line 12), created via `require("andrew.vault.request_coalescer").new()` with `name = "url_validate"` (pool config applied separately via `coalescer.configure()` in init.lua, with defaults in `config.coalescer.pools.url_validate`). The coalescer has per-pool config in `config.coalescer.pools.url_validate` (config.lua line 881). The module also requires `resource_cleanup`, `link_utils`, and `patterns` (lines 3-7). The current behavior when limits are hit is split:

- **Concurrency limit**: When `url_pool:pending_count() >= cfg.max_concurrent` (lines 430-433), the callback fires immediately with status `-2` and error `"concurrency limit"`. The URL is **not validated**.
- **Rate limit**: When `check_rate_limit(domain)` returns `false, wait_ms` (lines 151-163), the request is deferred via `vim.defer_fn()` with the remaining cooldown time (lines 439-442). The URL **is retried** after the delay.
- **In-flight dedup**: If the same URL is already pending, `url_pool:is_pending(key)` (line 418) returns true and `url_pool:request()` coalesces the callback onto the existing operation (lines 418-427). The coalescer key is `make_url_key(url, method)` to distinguish HEAD vs GET requests for the same URL.

The `validate_batch()` function (lines 462-507) uses a head-pointer queue pattern with `process_next()` to maintain up to `max_concurrent` in-flight requests. Each completion triggers the next dequeue. This provides basic concurrency control but has several limitations:

1. **Concurrency-limited URLs are silently failed**: When the concurrency cap is hit, `validate_url()` returns status `-2` to the callback rather than queuing the request. The batch dispatcher (`validate_batch`) handles this by calling `process_next()` again, but individual callers using `validate_url()` directly receive a failure.
2. **No priority ordering**: A critical wikilink in the document body is treated identically to a footnote reference or an embedded metadata URL. The batch queue is strictly FIFO with no mechanism to validate high-visibility links first.
3. **No cross-domain fairness**: The batch queue is a single FIFO. If a note contains 50 links to `github.com` and 5 to `example.com`, the github links consume all concurrent slots while example.com links wait behind them, even though they could run in parallel without domain contention.
4. **Rate limit deferral is per-call, not centralized**: Each deferred `vim.defer_fn()` call independently re-enters `validate_url()`, creating scattered timer state. There is no single queue that tracks all pending work or provides backpressure signals.

## Inspiration

Zed's `crates/language_model/src/rate_limiter.rs` implements semaphore-based rate limiting with RAII guards using `smol::lock::Semaphore`:

- **`RateLimiter`** (lines 12-15) wraps an `Arc<Semaphore>` initialized with a concurrency limit (typically 4 for API providers via `RateLimiter::new(4)`).
- **`RateLimitGuard<T>`** (lines 17-20) holds an inner value `T` and a `_guard: SemaphoreGuardArc`. The guard keeps the semaphore permit alive for the entire lifetime of the wrapped stream/future.
- Two dispatch methods: **`run(future)`** (lines 40-54) for one-off futures (acquires permit, runs future, explicitly drops guard on completion) and **`stream(future)`** (lines 56-76) for streaming responses (acquires permit, wraps result stream in `RateLimitGuard`, releases when stream is dropped). Both return `Result<T, LanguageModelCompletionError>`.
- `stream()` uses a `use<Fut, T>` precise capture clause (line 61) on the returned `impl Stream` for lifetime bounds.
- `RateLimitGuard` implements the `Stream` trait (lines 22-31) by delegating `poll_next` to the inner stream via `unsafe Pin::map_unchecked_mut`, making it transparent to consumers.
- Fair queuing is implicit in the semaphore — `acquire_arc().await` blocks until a permit is available, with FIFO ordering.
- Used across 14 language model provider modules (Anthropic, Bedrock, Cloud, Copilot Chat, DeepSeek, Google, LMStudio, Mistral, Ollama, OpenAI, OpenAI Compatible, OpenRouter, Vercel, xAI) with 16 total instantiations (Google and Mistral each have 2 — one in `create_language_model()` and one in `provided_models()` for batch model creation). All initialize with `RateLimiter::new(4)`. File is 77 lines total (`crates/language_model/src/rate_limiter.rs`).

Also relevant: Zed's `crates/editor/src/inlay_hint_cache.rs` (3570 lines) uses `MAX_CONCURRENT_LSP_REQUESTS: usize = 5` (line 840) with an `lsp_request_limiter: Arc<Semaphore>` field on the cache struct (line 45, initialized at line 277 as `Arc::new(Semaphore::new(MAX_CONCURRENT_LSP_REQUESTS))`) and a **two-tier acquire pattern** (lines 945-950, with the `should_invalidate()` conditional at line 945 and the `match` block at lines 948-950):

```rust
let (lsp_request_guard, got_throttled) = if query.invalidate.should_invalidate() {
    (None, false)                                                // Bypass semaphore
} else {
    match lsp_request_limiter.try_acquire() {
        Some(guard) => (Some(guard), false),                     // Immediate dispatch
        None => (Some(lsp_request_limiter.acquire().await), true),  // Queued wait
    }
};
```

Invalidation requests (`should_invalidate()` at lines 109-113 — `RefreshRequested` or `BufferEdited` variants, but NOT `InvalidationStrategy::None` at line 79) bypass the semaphore entirely. When `got_throttled` is true (lines 957-978), the code checks whether the fetch range has scrolled outside a "double visible range" (visible range ± one visible-range-width padding, computed via `current_visible_range.start.saturating_sub(visible_offset_length)..current_visible_range.end.saturating_add(visible_offset_length).min(buffer_snapshot.len())` at lines 964-974) and skips stale requests, also invalidating the task range entry. This demonstrates that even in a high-throughput editor, bounded concurrency with queuing is preferred over skip-and-retry.

## Design

A `RateLimiter` module that provides queue-based rate limiting with per-domain fairness. The global concurrency semaphore pattern already exists in `process_semaphore.lua`; this module extends it with domain-aware cooldowns, per-domain queuing, and priority scheduling:

### Core Components

1. **Global semaphore**: A counter-based permit pool (`max_concurrent` permits). Each in-flight request holds one permit. When all permits are consumed, new requests are queued.

2. **Per-domain cooldown**: After a request to domain D completes, the next request to domain D is delayed by `domain_cooldown_ms`. This prevents request storms to a single host while allowing requests to other domains to proceed immediately.

3. **Per-domain FIFO queues**: Each domain maintains its own queue of pending requests. When a permit becomes available and the domain's cooldown has elapsed, the next request in the domain's queue is dispatched.

4. **Priority ordering across domains**: When multiple domains have queued requests and permits are available, the domain with the highest-priority pending request is served first. Priority is a numeric field (lower = higher priority).

5. **Guard-based release**: The callback passed to the queued function receives a `done()` function. Calling `done()` releases the permit and triggers queue draining. This is the callback-based equivalent of Rust's RAII drop.

6. **Backpressure API**: Callers can query `queue_depth()` to determine how many requests are pending, allowing adaptive behavior (e.g., showing a progress indicator, or declining to queue more if the queue is full).

### Request Lifecycle

```
submit(domain, opts, fn)
  │
  ├─ permit available AND domain cooled down?
  │   ├─ YES → acquire permit, call fn(done)
  │   └─ NO  → enqueue {domain, priority, fn}
  │
  ▼
fn executes async work
  │
  ▼
done() called by fn
  │
  ├─ release permit
  ├─ record domain last_request_time
  └─ trigger drain_queue()
        │
        ├─ find highest-priority domain with cooled-down status
        ├─ dequeue next request for that domain
        └─ acquire permit, call fn(done)
```

## Target Modules

- **`url_validate.lua`** (primary, 611 lines): Replace the split concurrency/rate-limit logic (status `-2` callback for concurrency at lines 430-433, `vim.defer_fn()` for rate limit at lines 439-442, `url_pool` coalescer dedup at lines 418-427, `_domain_last_request` tracking table at line 15, `check_rate_limit()`/`record_request()`/`prune_domain_cache()` at lines 151-189) with unified queue-based submission via the rate limiter. All URLs are guaranteed to be validated in a single pass.
- **`config.lua`** (982 lines): Extend `M.url_validation` (lines 674-716) with `max_queue_size` and `queue_drain_interval_ms`. Reuse existing `max_concurrent` (line 681) and `domain_rate_limit_ms` (line 685). Note: `M.coalescer` section (lines 879-887) has pool-specific settings including `url_validate` pool with `max_waiters = 10`, `timeout_ms = 30000`, `done_linger_ms = 200` defaults — these may need updating if the coalescer interaction changes.
- **`process_semaphore.lua`** (existing, 125 lines): Provides the base semaphore pattern (`acquire`, `try_acquire`, `_drain_queue`, `reset` with generation-based cancellation). Currently used by 5 modules (`search_filter/ripgrep.lua`, `linkcheck.lua`, `rename.lua`, `navigate.lua`, `unlinked/rg_pipeline.lua`) for ripgrep process limiting via shared `rg_semaphore()` singleton (initialized with `config.search.max_concurrent_rg`, default 3). The rate limiter can optionally compose with this module for global permit management, or reimplement the permit logic inline if the domain-aware drain diverges too much from the generic callback-based drain.
- **Future external API modules**: Any module making HTTP requests (e.g., link preview fetching, remote resource checking) can create separate `rate_limiter.new()` instances with their own concurrency/cooldown settings.

## Implementation Steps

### Step 1: Create rate_limiter.lua module

```lua
-- lua/andrew/vault/rate_limiter.lua
local vault_log = require("andrew.vault.vault_log")

local M = {}
M.__index = M

local log = vault_log.scope("rate_limiter")

function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    max_concurrent = opts.max_concurrent or 5,
    domain_cooldown_ms = opts.domain_cooldown_ms or 1000,
    max_queue_size = opts.max_queue_size or 200,
    queue_drain_interval_ms = opts.queue_drain_interval_ms or 100,

    -- State
    _active_count = 0,           -- Current in-flight requests
    _domain_queues = {},         -- domain → {{priority, fn, queued_at}, ...}
    _domain_last_request = {},   -- domain → hrtime of last request completion
    _drain_timer = nil,          -- uv timer for queue draining
    _total_queued = 0,           -- Total items across all domain queues
    _stats = {
      submitted = 0,
      completed = 0,
      rejected = 0,              -- Rejected due to max_queue_size
    },
  }, M)
  return self
end
```

Note: The `M.__index = M` + `setmetatable` OOP pattern is appropriate here because `rate_limiter` is a stateful object supporting multiple instances (e.g., separate limiters for URL validation vs. future API modules). Most vault modules use the simpler `local M = {} / return M` singleton pattern, but instance-based modules like `lru_cache.lua` (250 lines) use this same metatable approach (there as `WeightedCache.__index = WeightedCache` at line 107 with fields `_entries`, `_head`, `_tail`, `_size`, `_total_weight`, `_max_items`, `_max_bytes`, `_weigher`, `_on_evict`; the basic LRU cache in the same file uses a closure-based pattern instead).

**Existing infrastructure**: `process_semaphore.lua` (125 lines) already implements a general-purpose semaphore with queue draining, inspired by Zed's `Arc<Semaphore>` pattern. The semaphore struct has fields `_max`, `_active`, `_queue`, `_generation` (defined in `M.new()` at lines 17-20). It provides `acquire(sem, callback)` (lines 49-72, immediate dispatch or FIFO-queued, returns cancel function), `try_acquire(sem)` (lines 77-89, non-blocking, returns `release` or `nil`), `reset(sem)` (lines 94-97, cancel all queued waiters via generation bump), `stats(sem)` (lines 102-108), and `_drain_queue(sem)` (lines 27-42, dispatch queued callbacks when permits free up, skips entries with stale `gen`). Each acquired permit returns a `release()` closure with `released` boolean double-call guard — the same pattern proposed for `rate_limiter`'s `done()`. A shared singleton `M.rg_semaphore()` (lines 116-122, lazily initialized with `config.search.max_concurrent_rg`, default 3) is used by 5 vault modules (`search_filter/ripgrep.lua`, `linkcheck.lua`, `rename.lua`, `navigate.lua`, `unlinked/rg_pipeline.lua`) for ripgrep process limiting.

The rate limiter's core permit acquisition and release logic can delegate to `process_semaphore` for the global concurrency cap, layering per-domain cooldowns, priority ordering, and domain-fair queuing on top. This avoids duplicating the semaphore/queue-drain/double-release-guard pattern. The alternative — a standalone implementation as shown below — is also viable if the domain-aware queuing logic diverges enough from the generic semaphore to make composition awkward (e.g., `process_semaphore._drain_queue` has no concept of "skip this waiter because its domain is still cooling down").

### Step 2: Implement submit() with immediate dispatch or queuing

```lua
function M:submit(domain, opts, fn)
  opts = opts or {}
  local priority = opts.priority or 5  -- Default mid-priority (1=highest, 10=lowest)

  self._stats.submitted = self._stats.submitted + 1

  -- Check queue capacity
  if self._total_queued >= self.max_queue_size then
    log.warn("Queue full, rejecting request for domain: " .. domain)
    self._stats.rejected = self._stats.rejected + 1
    return false, "queue_full"
  end

  -- Try immediate dispatch
  if self:_can_dispatch(domain) then
    self:_dispatch(domain, fn)
    return true, "dispatched"
  end

  -- Queue for later
  if not self._domain_queues[domain] then
    self._domain_queues[domain] = {}
  end

  table.insert(self._domain_queues[domain], {
    priority = priority,
    fn = fn,
    queued_at = vim.uv.hrtime(),
  })
  self._total_queued = self._total_queued + 1

  -- Sort domain queue by priority (stable: equal priority preserves FIFO)
  table.sort(self._domain_queues[domain], function(a, b)
    if a.priority == b.priority then
      return a.queued_at < b.queued_at
    end
    return a.priority < b.priority
  end)

  -- Ensure drain timer is running
  self:_ensure_drain_timer()

  return true, "queued"
end
```

### Step 3: Implement dispatch and guard release

```lua
function M:_can_dispatch(domain)
  if self._active_count >= self.max_concurrent then
    return false
  end
  return self:_domain_cooled_down(domain)
end

function M:_domain_cooled_down(domain)
  local last = self._domain_last_request[domain]
  if not last then
    return true
  end
  local elapsed_ms = (vim.uv.hrtime() - last) / 1e6
  return elapsed_ms >= self.domain_cooldown_ms
end

function M:_dispatch(domain, fn)
  self._active_count = self._active_count + 1

  local released = false
  local done = function()
    if released then
      log.warn("done() called twice for domain: " .. domain)
      return
    end
    released = true
    self._active_count = self._active_count - 1
    self._domain_last_request[domain] = vim.uv.hrtime()
    self._stats.completed = self._stats.completed + 1

    -- Trigger immediate drain attempt
    vim.schedule(function()
      self:_drain_queue()
    end)
  end

  -- Call the work function with the release guard
  local ok, err = pcall(fn, done)
  if not ok then
    log.error("Dispatch function error for " .. domain .. ": " .. tostring(err))
    if not released then
      done()  -- Release permit on error
    end
  end
end
```

### Step 4: Implement timer-based queue draining

```lua
function M:_ensure_drain_timer()
  if self._drain_timer then
    return
  end

  self._drain_timer = vim.uv.new_timer()
  self._drain_timer:start(
    self.queue_drain_interval_ms,
    self.queue_drain_interval_ms,
    vim.schedule_wrap(function()
      self:_drain_queue()
    end)
  )
end

function M:_drain_queue()
  -- Process as many queued items as permits allow
  while self._active_count < self.max_concurrent do
    local best_domain, best_entry = self:_pick_next()
    if not best_domain then
      break  -- Nothing dispatchable
    end

    -- Remove from queue
    local queue = self._domain_queues[best_domain]
    for i, entry in ipairs(queue) do
      if entry == best_entry then
        table.remove(queue, i)
        break
      end
    end
    self._total_queued = self._total_queued - 1

    -- Clean up empty queues
    if #queue == 0 then
      self._domain_queues[best_domain] = nil
    end

    self:_dispatch(best_domain, best_entry.fn)
  end

  -- Stop timer if queue is empty
  if self._total_queued == 0 and self._drain_timer then
    self._drain_timer:stop()
    self._drain_timer:close()
    self._drain_timer = nil
  end
end

function M:_pick_next()
  -- Find highest-priority entry across all cooled-down domains
  local best_domain = nil
  local best_entry = nil

  for domain, queue in pairs(self._domain_queues) do
    if #queue > 0 and self:_domain_cooled_down(domain) then
      local candidate = queue[1]  -- Already sorted by priority
      if not best_entry or candidate.priority < best_entry.priority then
        best_domain = domain
        best_entry = candidate
      elseif candidate.priority == best_entry.priority
        and candidate.queued_at < best_entry.queued_at then
        -- Same priority: prefer older request (fairness)
        best_domain = domain
        best_entry = candidate
      end
    end
  end

  return best_domain, best_entry
end
```

### Step 5: Implement query and cancellation API

```lua
function M:queue_depth(domain)
  if domain then
    local queue = self._domain_queues[domain]
    return queue and #queue or 0
  end
  return self._total_queued
end

function M:active_count()
  return self._active_count
end

function M:cancel_domain(domain)
  local queue = self._domain_queues[domain]
  if not queue then
    return 0
  end
  local count = #queue
  self._total_queued = self._total_queued - count
  self._domain_queues[domain] = nil
  log.info("Cancelled " .. count .. " queued requests for " .. domain)
  return count
end

function M:cancel_all()
  local count = self._total_queued
  self._domain_queues = {}
  self._total_queued = 0
  if self._drain_timer then
    self._drain_timer:stop()
    self._drain_timer:close()
    self._drain_timer = nil
  end
  log.info("Cancelled all " .. count .. " queued requests")
  return count
end

function M:stats()
  return vim.deepcopy(self._stats)
end

function M:destroy()
  self:cancel_all()
  self._domain_last_request = {}
  self._active_count = 0
end
```

### Step 6: Add config entries

Extend the existing `M.url_validation` section in `config.lua` (lines 674-716, 15 top-level fields, config.lua is 982 lines total) rather than creating a new top-level section. The rate limiter config is specific to URL validation's network behavior and belongs alongside `max_concurrent` and `domain_rate_limit_ms`. Note: `M.coalescer` (lines 879-887) has per-pool settings (no global defaults section — each pool specifies its own `max_waiters`, `timeout_ms`, `done_linger_ms`) including `url_validate` (line 881), `embed` (line 882), `search` (line 883), `index_rebuild` (line 884), `connections` (line 885) — review whether coalescer pool config needs updating after rate limiter integration:

```lua
-- In config.lua, M.url_validation section (lines 674-716, extend existing):
-- Existing fields (with line numbers):
--   enabled = true,                                    -- line 675
--   diagnostics = true,                                -- line 677
--   timeout_ms = 10000,                                -- line 679
--   max_concurrent = 5,                                -- line 681
--   max_redirects = 5,                                 -- line 683
--   domain_rate_limit_ms = 1000,                       -- line 685
--   domain_rate_limit_max = 200,                       -- line 687
--   domain_rate_limit_ttl = 3600,                      -- line 689
--   user_agent = "Mozilla/5.0 (...VaultLinkCheck/1.0)",-- line 691
--   cache_ttl = { success, redirect, client_error,     -- lines 693-699
--                 server_error, network_error },
--   exclude_patterns = { localhost, 127.*, 192.168.*,  -- lines 701-707
--                        10.*, 0.0.0.0 },
--   cache_persist_debounce_ms = 5000,                  -- line 709
--   exclude_domains = {},                              -- line 711
--   accept_status_codes = {},                          -- line 713
--   head_fallback_to_get = {403, 405, 501},            -- line 715

-- New fields for queue-based rate limiting:
max_queue_size = 200,
queue_drain_interval_ms = 100,
```

Note: `max_concurrent` (default 5, line 681) and `domain_rate_limit_ms` (default 1000, line 685) already exist in `M.url_validation` and will be reused by the rate limiter. The `domain_rate_limit_max` (line 687) and `domain_rate_limit_ttl` (line 689) fields manage the domain tracking table cleanup via `prune_domain_cache()` (lines 171-189) and can be removed once the rate limiter replaces the current `_domain_last_request` + `prune_domain_cache()` approach.

### Step 7: Integrate into url_validate.lua

Replace the current concurrency/rate-limit logic in `validate_url()` and `validate_batch()` with rate limiter submission. The current implementation has these components to replace:

**Current code to remove/replace (verified against url_validate.lua, 611 lines total):**
- `url_pool` coalescer object (line 12, from `require("andrew.vault.request_coalescer")` at line 7) — in-flight dedup partially replaced by rate limiter; URL coalescing may still be needed for callback fan-out on duplicate `make_url_key(url, method)` keys
- `_domain_last_request` table (line 15) — replaced by rate limiter's per-domain cooldown tracking
- `check_rate_limit()` function (lines 151-163, returns `bool, wait_ms` using `vim.uv.now()`) — replaced by `_domain_cooled_down()`
- `record_request()` function (lines 165-169, sets `_domain_last_request[domain] = vim.uv.now()`) — handled by `done()` guard (note: currently records at dispatch time in `run_curl` line 316; rate limiter moves this to completion time)
- `prune_domain_cache()` function (lines 171-189, TTL-based + hard cap eviction) — no longer needed (rate limiter manages its own state)
- In-flight dedup check via `url_pool:is_pending(key)` in `validate_url()` (lines 418-427) — replaced by rate limiter dedup or URL coalescing layer
- Concurrency check via `url_pool:pending_count()` in `validate_url()` (lines 430-433, status `-2` path) — replaced by queue submission
- Rate limit deferral in `validate_url()` (lines 439-442, `vim.defer_fn()` path) — replaced by queue submission
- Normal dispatch via `url_pool:request()` in `validate_url()` (lines 446-459) — permit acquisition handled by rate limiter
- `validate_batch()` head-pointer queue with `process_next()` (lines 462-507, starts `math.min(#queue - head + 1, max_concurrent)` initial workers at lines 502-506) — simplified to submit all URLs to rate limiter
- `prune_domain_cache()` call at batch start (line 463) — no longer needed

**Cache registration to update (preserve observability):**
- `engine.register_cache()` at lines 574-593 — add rate limiter queue stats (currently exposes entries/valid/expired and invalidates `_domain_last_request` + `_cache`)
- `profiler.register_cache()` at lines 596-607 — add rate limiter metrics (currently exposes size/capacity/hits/misses/evictions via `_cache_hits`, `_cache_misses`, `_cache_evictions`)

```lua
local rate_limiter = require("andrew.vault.rate_limiter")
local config = require("andrew.vault.config")

-- Module-level limiter instance (created once, reused across :VaultUrlValidate calls)
local _limiter = nil

local function get_limiter()
  if not _limiter then
    local cfg = config.url_validation
    _limiter = rate_limiter.new({
      max_concurrent = cfg.max_concurrent,
      domain_cooldown_ms = cfg.domain_rate_limit_ms,
      max_queue_size = cfg.max_queue_size,
      queue_drain_interval_ms = cfg.queue_drain_interval_ms,
    })
  end
  return _limiter
end

-- Replace the validate_url() concurrency/rate-limit checks (current: lines 392-460):
-- Instead of checking url_pool:pending_count()/check_rate_limit/vim.defer_fn, submit to the limiter.
-- The existing run_curl(url, method, resolve) function (lines 309-390) with vim.system() call
-- (--silent, --head/--request GET, --output /dev/null, --write-out "%{http_code}",
-- --max-time, --max-redirs, --location, --user-agent, --connect-timeout 5) and HEAD→GET
-- fallback logic (_fallback_get marker at line 379, caught at line 454) remain unchanged —
-- only the admission control changes.
-- Note: The url_pool coalescer (line 12, from request_coalescer module with
-- make_url_key(url, method) as dedup key at lines 301-307) provides callback fan-out for duplicate URLs.
-- This coalescing behavior should be preserved — either keep url_pool for dedup or add
-- dedup logic to the rate limiter submission path.
function M.validate_url(url, callback, opts)
  opts = opts or {}
  local domain = url_domain(url)

  -- Exclusion check (unchanged)
  if is_excluded(url) then
    callback({ url = url, status = -1, error = "excluded" })
    return
  end

  -- Cache check (unchanged)
  local cached = M.get_cached(url)
  if cached then
    callback({ url = url, status = cached.status, error = cached.error })
    return
  end

  local priority = opts.priority or 5
  local rl = get_limiter()
  local ok, status = rl:submit(domain, { priority = priority }, function(done)
    -- Build and execute curl command (existing vim.system() logic)
    do_curl_request(url, opts, function(result)
      M.cache_result(url, result.status, result.error)
      callback(result)
      done()  -- Release permit, trigger queue drain
    end)
  end)

  if not ok then
    log.warn("URL queuing failed for %s: %s", url, status)
    callback({ url = url, status = -2, error = "queue_full" })
  end
end

-- Simplify validate_batch() — submit all entries to rate limiter instead of
-- managing a head-pointer queue with process_next():
function M.validate_batch(url_entries, on_result, on_done)
  local results = {}
  local remaining = #url_entries

  if remaining == 0 then
    if on_done then on_done(results) end
    return
  end

  for _, entry in ipairs(url_entries) do
    M.validate_url(entry.url, function(result)
      local r = { entry = entry, result = result }
      results[#results + 1] = r
      if on_result then on_result(entry, result) end

      remaining = remaining - 1
      if remaining == 0 and on_done then
        on_done(results)
      end
    end, { priority = entry.priority })
  end
end
```

**Note on `do_curl_request`**: This maps to the existing `run_curl(url, method, resolve)` function (lines 309-390), which is already a separate function — not inline in `validate_url()`. It builds the `vim.system()` command with curl flags (lines 314-330: `--silent`, `--head`/`--request GET`, `--output /dev/null`, `--write-out "%{http_code}"`, `--max-time`, `--max-redirs`, `--location`, `--user-agent`, `--connect-timeout 5`), handles exit code mapping (28→timeout, 6→DNS, 7→refused, 35→TLS, 60→cert at lines 339-349), and implements HEAD→GET fallback for status codes in `config.url_validation.head_fallback_to_get` (403, 405, 501 at lines 370-383). The fallback resolves with `_fallback_get = true` marker (line 379); `validate_url()` catches this at line 454 and retries with `{ method = "GET" }`. The `record_request(domain)` call currently happens at dispatch time (line 316 inside `run_curl`); the rate limiter design moves this to completion time via `done()`. Renaming `run_curl` to `do_curl_request` is optional — the existing name is fine.

### Step 8: Add priority assignment logic

```lua
-- Priority levels for URL validation
local PRIORITY = {
  WIKILINK_BODY = 1,       -- Links in document body
  EMBED_SOURCE = 2,        -- Embedded content sources
  FRONTMATTER_URL = 3,     -- URLs in frontmatter fields
  FOOTNOTE_REF = 5,        -- Footnote reference URLs
  COMMENT_URL = 8,         -- URLs in comments/metadata
}
```

## API

```lua
local rate_limiter = require("andrew.vault.rate_limiter")
local rl = rate_limiter.new({
  max_concurrent = 5,             -- reuse config.url_validation.max_concurrent
  domain_cooldown_ms = 1000,      -- reuse config.url_validation.domain_rate_limit_ms
  max_queue_size = 200,           -- new: config.url_validation.max_queue_size
  queue_drain_interval_ms = 100,  -- new: config.url_validation.queue_drain_interval_ms
})

-- Submit a request — dispatched immediately if permits/cooldown allow, queued otherwise
-- Returns: ok (boolean), status ("dispatched"|"queued"|"queue_full")
rl:submit("example.com", { priority = 1 }, function(done)
  -- Perform HTTP request using vim.system() (existing curl logic)
  vim.system(curl_args, {}, function(obj)
    process(obj)
    done()  -- Release permit, trigger queue drain
  end)
end)

-- Query state
rl:queue_depth()                  -- total pending across all domains
rl:queue_depth("example.com")     -- per-domain pending count
rl:active_count()                 -- currently in-flight requests
rl:cancel_domain("example.com")   -- cancel all pending for domain
rl:cancel_all()                   -- cancel everything, stop drain timer
rl:stats()                        -- {submitted, completed, rejected}
rl:destroy()                      -- full cleanup (cancel + reset state)
```

## Queue Processing

The queue is drained via two mechanisms:

1. **Completion-triggered drain**: When any request calls `done()`, the `_drain_queue()` method runs immediately via `vim.schedule()`. This is the primary drain path and handles most cases with zero latency — as soon as a permit is freed, the next queued request is dispatched.

2. **Timer-based drain**: A `vim.uv` repeating timer runs every `queue_drain_interval_ms` (default 100ms) as a fallback. This handles the case where domain cooldowns expire and queued requests become dispatchable without any completion event. The timer is started lazily when the first item is queued and stopped automatically when the queue empties.

The `_pick_next()` method selects the highest-priority entry across all cooled-down domains. For equal priorities, it prefers the oldest request (FIFO fairness). Domains that have not yet cooled down are skipped entirely — their requests remain queued until the next drain cycle after cooldown expires.

### Drain loop invariant

`_drain_queue()` runs in a tight loop dispatching requests until either:
- All permits are consumed (`_active_count >= max_concurrent`), or
- No domain has a dispatchable request (all queued domains are still in cooldown).

This ensures maximum throughput while respecting both global concurrency and per-domain rate limits.

## Configuration

The rate limiter reuses existing fields from `M.url_validation` in `config.lua` (lines 674-716, 15 fields currently) and adds two new fields:

```lua
-- config.lua — M.url_validation section (showing relevant fields)
M.url_validation = {
  -- Existing fields (reused by rate limiter):
  max_concurrent = 5,              -- Global permit pool size
  domain_rate_limit_ms = 1000,     -- Minimum ms between requests to same domain

  -- New fields for queue-based rate limiting:
  max_queue_size = 200,            -- Reject new submissions when queue exceeds this
  queue_drain_interval_ms = 100,   -- Fallback timer interval for cooldown-based drain

  -- Existing fields that become obsolete after migration:
  -- domain_rate_limit_max = 200,  -- Was: max domains in tracking table (rate limiter manages its own)
  -- domain_rate_limit_ttl = 3600, -- Was: TTL for stale domain entries (rate limiter has no TTL — entries cleared on destroy())
}
```

| Setting | Default | Source | Rationale |
|---------|---------|--------|-----------|
| `max_concurrent` | 5 | Existing | Matches Zed's `MAX_CONCURRENT_LSP_REQUESTS`. Prevents overwhelming the system with file descriptors and curl processes. |
| `domain_rate_limit_ms` | 1000 | Existing | Respectful rate for most web servers. Prevents 429 responses. Can be lowered for known-fast APIs. |
| `max_queue_size` | 200 | **New** | Safety valve. A typical vault note has 20-80 links; 200 covers batch validation of multiple notes with margin. Matches the old `domain_rate_limit_max` value. |
| `queue_drain_interval_ms` | 100 | **New** | Low enough for responsive draining, high enough to avoid busy-waiting. Only active when queue is non-empty. |

## Expected Impact

- **Elimination of status `-2` failures**: No URLs receive the concurrency-limit error callback. Every submitted URL is guaranteed to be validated (or explicitly rejected only if the queue is full at `max_queue_size`).
- **Fair domain distribution**: Per-domain queues prevent a single domain from monopolizing all permits. A note with 50 github.com links and 5 example.com links validates both domains in parallel.
- **Priority ordering**: Body wikilinks are validated before footnote references, giving users faster feedback on the most visible links.
- **Backpressure visibility**: `queue_depth()` enables progress indicators and informed decisions about whether to queue more work.
- **Centralized timer state**: Replaces scattered `vim.defer_fn()` calls with a single drain timer, making the system easier to reason about and debug.
- **Simplified `validate_batch()`**: The head-pointer queue with `process_next()` callback chaining is replaced by a simple loop that submits all entries to the rate limiter. The rate limiter handles all concurrency/ordering concerns.
- **Reduced module state**: `_domain_last_request` (line 15), `check_rate_limit()` (lines 151-163), `record_request()` (lines 165-169), and `prune_domain_cache()` (lines 171-189) are all removed from `url_validate.lua`, consolidating rate-limiting state in the rate limiter instance. The `url_pool` coalescer (line 12) may be retained for callback fan-out on duplicate URLs, or its dedup logic can be folded into the rate limiter submission path.

## Risks

1. **Queue memory for large link sets**: Each queued entry holds a closure and metadata (~200-500 bytes). At `max_queue_size = 200`, worst case is ~100KB — negligible. The `max_queue_size` cap provides a hard upper bound.

2. **Timer overhead for queue draining**: The repeating timer fires every 100ms when the queue is non-empty. Each invocation is a lightweight table scan of domain queues. With typical domain counts (5-20), this is sub-microsecond. The timer stops automatically when the queue empties, so there is zero cost when no validation is in progress.

3. **Double-done() calls**: If a caller accidentally calls `done()` twice, the permit count would go negative. The implementation guards against this with a `released` flag per dispatch, logging a warning on duplicate calls.

4. **Interaction with vim.schedule**: All drain operations run via `vim.schedule()` to ensure they execute on the main thread. This adds a single event loop tick of latency per drain cycle, which is imperceptible to users.

5. **Module-level limiter lifecycle**: The `_limiter` instance in `url_validate.lua` persists for the Neovim session. If the user changes `config.url_validation` settings at runtime, the limiter retains its original values. Consider exposing a reset function or re-reading config on `:VaultUrlValidate` invocation.

6. **Cache registry integration**: `url_validate.lua` currently registers with `engine.register_cache()` (lines 574-593) and `memory_profiler.register_cache()` (lines 596-607). The engine registration provides `invalidate` (clears `_domain_last_request` and `_cache`) and `stats` callbacks (entries/valid/expired); the profiler registration provides `get_size`, `get_capacity` (nil), `get_hits` (`_cache_hits`), `get_misses` (`_cache_misses`), `get_evictions` (`_cache_evictions`) accessors. The rate limiter's internal state (`_domain_queues`, `_domain_last_request`, `_stats`) should be included in both registrations to maintain observability parity.

7. **HEAD→GET fallback interaction**: The existing HEAD→GET fallback (for status codes in `config.url_validation.head_fallback_to_get`: 403, 405, 501, line 715) retries with a GET request. This retry must call `do_curl_request` recursively but should NOT acquire a second permit — the original `done()` guard covers both attempts. The fallback must call `done()` only once, after the final attempt completes.

8. **url_pool coalescer preservation**: The current `url_pool` coalescer (line 12) provides callback fan-out when the same URL is requested multiple times concurrently — `url_pool:is_pending(key)` returns true and `url_pool:request()` attaches the new callback to the existing in-flight operation (lines 418-427). If the rate limiter replaces admission control, the coalescing behavior must either be preserved (keep `url_pool` as a dedup layer in front of the rate limiter) or replicated within the rate limiter. Without it, duplicate URLs would consume separate permits and make redundant network requests.
