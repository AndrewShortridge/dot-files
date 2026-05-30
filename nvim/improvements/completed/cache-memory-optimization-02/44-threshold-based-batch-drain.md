# 44. Threshold-Based Batch Drain

**Priority:** MEDIUM
**Phase:** 2 (Scalability)
**Dependencies:** Document 22 (Chunked Pipeline Processing), Document 14 (Cooperative Yielding)
**Inspired by:** Zed's `summary_backlog.rs` (`needs_drain()` with count + byte thresholds, HashMap dedup), `ready_chunks(N)` pattern (32–1024), bounded channel backpressure (1–2048)

---

## Problem

Vault operations that accumulate work items before processing them fall into two suboptimal patterns:

1. **One-at-a-time processing:** Each item triggers its own I/O, serialization, or network call. Per-item overhead dominates (syscalls, JSON encode/decode, curl spawns). Examples: `url_validate.lua` validates each URL with a separate curl process; `vault_index.lua` could theoretically persist after every single file parse.

2. **Unbounded accumulation with timer-based flush:** Items pile up until a debounce timer fires. The batch size is unpredictable — a burst of 500 file saves produces a 500-item batch, while a quiet period produces a 1-item batch. Memory grows proportionally to burst size, and processing time varies wildly.

Neither pattern provides **bounded memory** with **predictable batch sizes**.

### Current Accumulation Patterns

| Operation | Pattern | Problem |
|-----------|---------|---------|
| `vault_index._prepare_persist_data()` | WAL deltas + debounced full snapshot via `vim.json.encode(data)` on entire stripped index | Full snapshot still serializes all files at once; WAL mitigates frequency but not peak memory of snapshot |
| `url_validate.lua` | One curl per URL, `rate_limiter` module + `request_coalescer` dedup | Per-URL process spawn overhead amortized by rate limiter; `validate_batch()` exists but dispatches individually |
| `embed.lua render_in_range()` | Viewport-zone rendering with 3 zones (visible, above, below); `compute_remaining()` enforces `config.embed.max_total_lines` (150) budget across all embeds, per-embed `max_lines` (20) cap | Line budget bounds total virtual text but no per-tick byte cap; within budget, all zone embeds render in one pass |
| `completion_base.lua build_iter` | Yield every `effective_batch_size` items (adaptive: max 3 yields) | Count-only, no awareness of item complexity or memory pressure |
| `search_filter.evaluate()` | Sync: accumulates matches into single table with cancellation check every 200 items and `max_result_files` (5000) cap; Async: yields every `evaluate_batch_size` (500) entries via `yield_iter.filter_yielding()`; both paths use bloom filter + precomputed set pre-checks, arena scopes, and request coalescer dedup | Sync path bounded by max_result_files but no byte awareness; async path count-only with no byte awareness |

### The Missing Middle Ground

What these operations need is a **threshold-based drain**: accumulate items until either a count limit or a byte-size limit is reached, then drain the batch immediately. This provides:

- **Bounded memory:** The batch never exceeds `max_bytes`, regardless of burst rate.
- **Predictable batch sizes:** The drain callback always receives between 1 and `max_count` items.
- **Amortized overhead:** Per-item costs (serialization, I/O setup) are paid once per batch, not once per item.
- **Natural backpressure:** Producers that push faster than the drain can process are throttled by the synchronous drain call.

---

## Inspiration

### Zed's `summary_backlog.rs`

Zed's semantic index accumulates files for summarization until either a count or byte threshold is reached:

```rust
// crates/semantic_index/src/summary_backlog.rs

const MAX_FILES_BEFORE_RESUMMARIZE: usize = 4;
const MAX_BYTES_BEFORE_RESUMMARIZE: u64 = 1_000_000;  // 1 MB

#[derive(Default, Debug)]
pub struct SummaryBacklog {
    /// Key: path to a file that needs summarization. Value: (size_bytes, mtime).
    files: HashMap<Arc<Path>, (u64, Option<MTime>)>,
    /// Cache of the sum of all values in `files` — O(1) threshold check.
    total_bytes: u64,
}

impl SummaryBacklog {
    pub fn insert(&mut self, path: Arc<Path>, bytes_on_disk: u64, mtime: Option<MTime>) {
        // unwrap_or_default() returns (0, None) for new keys
        let (prev_bytes, _) = self
            .files
            .insert(path, (bytes_on_disk, mtime))
            .unwrap_or_default();
        // Update cached total by subtracting old amount and adding new one
        self.total_bytes = self.total_bytes - prev_bytes + bytes_on_disk;
    }

    pub fn needs_drain(&self) -> bool {
        self.files.len() > MAX_FILES_BEFORE_RESUMMARIZE
            || self.total_bytes > MAX_BYTES_BEFORE_RESUMMARIZE
    }

    pub fn drain<'a>(&'a mut self) -> impl Iterator<Item = (Arc<Path>, Option<MTime>)> + 'a {
        self.total_bytes = 0;
        self.files
            .drain()
            .map(|(path, (_size, mtime))| (path, mtime))
    }

    pub fn len(&self) -> usize {
        self.files.len()
    }
}
```

Key design choices:
- **Dual threshold:** Count OR bytes, whichever triggers first (using strict `>`, not `>=`). Small files batch by count; large files batch by bytes.
- **HashMap deduplication:** Uses `HashMap` (not `Vec`) so re-inserting the same path updates rather than duplicates; `total_bytes` correctly adjusts via `unwrap_or_default()` — subtracts old size (0 for new keys) and adds new size in a single expression.
- **Cached `total_bytes`:** Adjusted on each `insert()`, reset on `drain()`. No need to re-scan the batch to check the byte threshold.
- **Iterator drain:** `drain()` returns `impl Iterator<Item = (Arc<Path>, Option<MTime>)>` — file sizes are dropped (only needed for threshold calculation), and callers can `.collect()` or stream as needed.
- **`needs_drain()` naming:** Called `needs_drain()` (not `should_flush()`) — semantic clarity about what action is needed.
- **Synchronous drain:** The caller decides what to do with the batch. No internal async machinery. Called from `summary_index.rs` `add_to_backlog()` (line ~319) and `flush_backlog()` (line ~648).

### Zed's `ready_chunks(N)`

Zed uses `ready_chunks` across multiple crates with varying batch sizes tailored to each use case:

```rust
// project.rs:2721 — collaborative buffer operations batched at 128
const MAX_BATCH_SIZE: usize = 128;
let mut changes = rx.ready_chunks(MAX_BATCH_SIZE);
// Groups buffer operations for efficient network transmission (UpdateBuffer RPC)

// project.rs:3814 — search candidate buffers batched at 64
let chunks = matching_buffers_rx.ready_chunks(64);
// Comment: "load at most 64 buffers at a time to avoid overwhelming the main thread"

// project_search.rs:312 — search match aggregation at 1024
let mut matches = pin!(search.ready_chunks(1024));
// Groups individual search result matches for incremental UI model updates

// workspace.rs:5329 — item serialization at 200
const CHUNK_SIZE: usize = 200;
let mut serializable_items = items_rx.ready_chunks(CHUNK_SIZE);
// Deduplicates items by ID within each batch using HashMap fold before serializing

// edit_agent.rs:331 — LLM edit application at 32
let mut edits = edits.ready_chunks(32);
// Applies computed edits atomically to avoid marking them as user-made
```

Each caps memory per processing step to N items, regardless of upstream production rate. Sizes range from 32 (UI-facing edit application within a single effect cycle) to 1024 (background search aggregation).

### Bounded Channels as Backpressure

Zed uses bounded channels with graduated capacities for backpressure:

```rust
// peer.rs:135 — incoming RPC messages (256 in prod, 1 in tests for strict testing)
#[cfg(not(any(test, feature = "test-support")))]
const INCOMING_BUFFER_SIZE: usize = 256;
let (mut incoming_tx, incoming_rx) = mpsc::channel(INCOMING_BUFFER_SIZE);
// Asymmetric: incoming bounded (backpressure), outgoing unbounded

// lsp_store.rs:11498 — LSP progress/refresh signals (capacity 1 for tight sync)
let (progress_tx, mut progress_rx) = mpsc::channel(1);
let (mut refresh_tx, mut refresh_rx) = mpsc::channel(1);
refresh_tx.try_send(()).ok();  // Graceful overflow via try_send

// project.rs:4548 — language server prompt request/response (capacity 1)
let (tx, rx) = smol::channel::bounded(1);

// embedding_index.rs:103 — multi-stage indexing pipeline with graduated buffering
let (updated_entries_tx, updated_entries_rx) = channel::bounded(512);
let (deleted_entry_ranges_tx, deleted_entry_ranges_rx) = channel::bounded(128);
// Also: chunked_files at 2048 (intermediate), embedded_files at 512 (final)

// summary_index.rs — file summarization pipeline
let (needs_summary_tx, needs_summary_rx) = channel::bounded(512);
let (digest_tx, digest_rx) = channel::bounded(2048);  // intermediate digests

// project_index.rs:234 — multi-worktree semantic search chunking
let (chunks_tx, chunks_rx) = channel::bounded(1024);
// project_index.rs:413 — multi-worktree summary aggregation
let (summaries_tx, summaries_rx) = channel::bounded(1024);

// worktree_store.rs:678-679 — file filtering with disk-based verification (worker pool)
let (filter_tx, filter_rx) = smol::channel::bounded(64);
let (output_tx, output_rx) = smol::channel::bounded(64);
```

Capacities follow a consistent hierarchy: 1 (synchronization), 64 (worker pool coordination), 128–256 (network backpressure), 512 (standard work queues), 1024 (cross-system aggregation), 2048 (intermediate high-throughput buffers). In Lua/Neovim (single-threaded), we achieve the same effect by making `push()` synchronously call the drain callback when the threshold is hit — the producer cannot continue until the batch is processed.

---

## Design

### Core: `batch_drain.lua`

A lightweight accumulator with dual-threshold auto-drain.

```
                     push()  push()  push()  push()  push()
                       │       │       │       │       │
                       ▼       ▼       ▼       ▼       ▼
Accumulator:  [ item1, item2, item3, item4, item5 ]
                                                │
                              count threshold ───┘  (max_count = 5)
                              OR byte threshold     (max_bytes = 512KB)
                                                │
                                                ▼
                                        on_drain({ item1..item5 })
                                        accumulator reset
                                                │
                                                ▼
                              push()  push()  ...  (next batch)
```

### API Surface

```lua
local batch_drain = require("andrew.vault.batch_drain")

-- Create a batch accumulator
local batch = batch_drain.new({
  max_count = 100,           -- Drain after N items (default: config value)
  max_bytes = 524288,        -- Drain after N bytes (default: config value, 512KB)
  on_drain = function(items, stats)
    -- items: array of accumulated items
    -- stats: { count, total_bytes, drain_reason }
  end,
})

-- Push items (auto-drains when threshold hit)
batch:push(item, byte_size)  -- byte_size: optional, estimated size of this item

-- Force drain remaining items (e.g., on shutdown, end of operation)
batch:flush()

-- Query state
batch:count()        -- Current item count
batch:bytes()        -- Current accumulated bytes
batch:is_empty()     -- No items pending
batch:stats()        -- { pushes, drains, total_items, total_bytes }

-- Reset without draining (discard pending items)
batch:clear()
```

### Threshold Semantics

- **Count threshold (`max_count`):** Drain fires when `#items >= max_count`. Simple integer comparison.
- **Byte threshold (`max_bytes`):** Drain fires when `total_bytes >= max_bytes`. The running counter is O(1) — no re-scanning.
- **Either-or:** Whichever threshold is hit first triggers the drain. This handles the case where a few large items should drain early (byte threshold) even though the count is low, and where many small items should drain by count even though total bytes are small.
- **`byte_size` is optional:** If not provided for a push, only the count threshold is checked. This supports use cases where byte estimation is impractical.
- **`flush()` drains unconditionally:** Called at end-of-operation to process any remaining items below the threshold.

---

## Implementation

### Step 1: Create `batch_drain.lua`

```lua
-- lua/andrew/vault/batch_drain.lua
local config = require("andrew.vault.config")

local M = {}
M.__index = M

--- Create a new batch drain accumulator.
---@param opts { max_count: number|nil, max_bytes: number|nil, on_drain: fun(items: table[], stats: table) }
---@return table
function M.new(opts)
  assert(opts.on_drain, "batch_drain: on_drain callback is required")

  local self = setmetatable({
    _items = {},
    _count = 0,
    _total_bytes = 0,
    _max_count = opts.max_count or config.batch.default_max_count,
    _max_bytes = opts.max_bytes or config.batch.default_max_bytes,
    _on_drain = opts.on_drain,
    -- Stats
    _stats = {
      pushes = 0,
      drains = 0,
      total_items = 0,
      total_bytes = 0,
    },
  }, M)
  return self
end

return M
```

### Step 2: Implement `push()` with auto-drain

```lua
--- Push an item into the accumulator. Triggers drain if threshold is met.
---@param item any  The item to accumulate
---@param byte_size number|nil  Estimated byte size of this item (optional)
function M:push(item, byte_size)
  self._count = self._count + 1
  self._items[self._count] = item
  self._stats.pushes = self._stats.pushes + 1

  if byte_size then
    self._total_bytes = self._total_bytes + byte_size
  end

  -- Check thresholds
  local should_drain = self._count >= self._max_count
  if not should_drain and byte_size and self._total_bytes >= self._max_bytes then
    should_drain = true
  end

  if should_drain then
    self:_drain("threshold")
  end
end
```

### Step 3: Implement drain mechanics

```lua
--- Internal: execute the drain callback and reset state.
---@param reason string  Why the drain was triggered
function M:_drain(reason)
  if self._count == 0 then return end

  local items = self._items
  local stats = {
    count = self._count,
    total_bytes = self._total_bytes,
    drain_reason = reason,
  }

  -- Update cumulative stats
  self._stats.drains = self._stats.drains + 1
  self._stats.total_items = self._stats.total_items + self._count
  self._stats.total_bytes = self._stats.total_bytes + self._total_bytes

  -- Reset accumulator BEFORE calling on_drain (re-entrancy safe)
  self._items = {}
  self._count = 0
  self._total_bytes = 0

  -- Deliver batch
  self._on_drain(items, stats)
end

--- Force drain all remaining items, regardless of threshold.
function M:flush()
  self:_drain("flush")
end

--- Discard all pending items without draining.
function M:clear()
  self._items = {}
  self._count = 0
  self._total_bytes = 0
end
```

### Step 4: Query methods

```lua
--- Current number of pending items.
function M:count()
  return self._count
end

--- Current accumulated byte size.
function M:bytes()
  return self._total_bytes
end

--- Whether the accumulator has no pending items.
function M:is_empty()
  return self._count == 0
end

--- Cumulative statistics.
function M:stats()
  return vim.deepcopy(self._stats)
end
```

### Step 5: Add config entries

```lua
-- config.lua — add new M.batch section alongside existing per-module batch configs
M.batch = {
  default_max_count = 100,   -- Items before auto-drain
  default_max_bytes = 524288, -- 512 KB before auto-drain
}
-- Note: existing configs like M.index.batch_size (20), M.completion.batch_size (50),
-- M.search.evaluate_batch_size (500), etc. remain unchanged — use sites can reference
-- these existing values as max_count overrides when creating batch_drain instances.
```

---

## Use Cases

### 1. Vault Index Persistence: Batched Entry Serialization

Currently, `vault_index.lua` uses a two-tier persistence strategy: WAL-based deltas (individual JSONL entries per mutation via `_persist_delta()`) and debounced full snapshots. The full snapshot path in `_prepare_persist_data()` (line 1015) strips derived fields via `strip_derived(entry)` then calls `vim.json.encode(data)` on the entire index at once — for a 10K-file vault with `SCHEMA_VERSION = 7`, this produces a multi-megabyte JSON string in a single allocation. The WAL mitigates how often this happens: `_schedule_persist()` (line 979) only triggers a full persist when `_wal_count > 1000`; the async path uses `vim.uv.fs_open/fs_write` (line 1064), while the sync shutdown path `persist_now()` (line 1113) uses blocking `io.open` + `f:write(json)`. But each snapshot remains an all-at-once serialization.

With batch drain, the full snapshot serialization can be chunked: encode entries in batches of 100 (or 512KB), writing each chunk to disk incrementally via `vim.uv.fs_write`. The WAL path already serializes per-entry, so it needs no change.

```lua
-- vault_index.lua — batched persistence
local batch_drain = require("andrew.vault.batch_drain")

function M.VaultIndex:_persist_chunked()
  local fd = vim.uv.fs_open(self._index_path, "w", 438)
  if not fd then return end

  -- Write header
  local header = vim.json.encode({
    version = SCHEMA_VERSION,
    vault_path = self.vault_path,
    built_at = os.time(),
  })
  vim.uv.fs_write(fd, '{"meta":' .. header .. ',"files":{', -1)

  local first = true
  local batch = batch_drain.new({
    max_count = 100,
    max_bytes = 524288,  -- 512 KB
    on_drain = function(items)
      local parts = {}
      for _, item in ipairs(items) do
        local prefix = first and "" or ","
        first = false
        parts[#parts + 1] = prefix .. '"' .. item.key .. '":' .. item.json
      end
      vim.uv.fs_write(fd, table.concat(parts), -1)
    end,
  })

  for rel_path, entry in pairs(self.files) do
    local ok, json = pcall(vim.json.encode, entry)
    if ok then
      batch:push({ key = rel_path, json = json }, #json)
    end
  end

  batch:flush()  -- Drain remaining entries
  vim.uv.fs_write(fd, "}}", -1)
  vim.uv.fs_close(fd)
end
```

**Benefit:** Peak memory drops from "entire index as one JSON string" to "at most 512KB of serialized entries at a time."

### 2. URL Validation: Batched HTTP Checks

`url_validate.lua` currently spawns one curl process per URL via `vim.system()` in `run_curl()` (line 290), throttled by a `rate_limiter` module (with `max_concurrent`, per-domain `domain_cooldown_ms`, `max_queue_size`, and `queue_drain_interval_ms`) and deduplicated via `request_coalescer` (`url_pool` at line 13, keyed by `method:url`). The existing `validate_batch()` function (line 442) accepts an array of `{ url, lnum, col, end_col, priority }` entries but dispatches each individually through `validate_url()` with a remaining-counter for completion tracking — there is no true multi-URL batching. The rate limiter's `_pick_next()` (line 197) uses priority-based selection with FIFO tie-breaking across cooled-down domains.

With batch drain, URLs could be accumulated and validated in batches, allowing a single curl process to check multiple URLs (via `--next` flag) or batching result processing. This would complement the existing rate limiter rather than replace it.

```lua
-- url_validate.lua — batched validation (complements rate_limiter)
local batch_drain = require("andrew.vault.batch_drain")

local url_batch = batch_drain.new({
  max_count = 10,       -- Check 10 URLs per batch
  max_bytes = 0,        -- Not byte-limited for URLs
  on_drain = function(items)
    -- items: array of { url, lnum, col, bufnr }
    -- Could use curl --next to check multiple URLs in one process
    validate_url_batch(items)
  end,
})

--- Queue a URL for validation instead of checking immediately.
function M.queue_url(url, lnum, col, bufnr)
  url_batch:push({ url = url, lnum = lnum, col = col, bufnr = bufnr })
end

--- After scanning a buffer, flush any remaining queued URLs.
function M.flush_queue()
  url_batch:flush()
end
```

**Benefit:** Reduces process spawn overhead by ~10x. Complements existing `rate_limiter` and `request_coalescer` by grouping URLs before they enter the rate-limited queue.

### 3. Embed Rendering: Byte-Aware Batching

`embed.lua` currently uses viewport-zone rendering via `render_in_range(descs, ctx, top, bot)` (line 388), which renders all unrendered embeds within a line range using `render_single_embed()` per embed. The system has a total line budget via `compute_remaining()` (line 225) enforcing `config.embed.max_total_lines` (150) and a per-embed `config.embed.max_lines` (20) cap, but no per-tick byte cap. The `config.embed.lazy` flag controls whether rendering is restricted to the visible zone (with 3-zone prefetch via coordinator dispatch: visible, above, below), but within a zone, all qualifying embeds render synchronously in one pass. The system uses arena scope memory pooling (`render_arena`), `table_pool` for descriptor reuse (`_desc_pool`), and `request_coalescer` (`embed_pool`) to prevent duplicate renders for the same buffer.

With batch drain, zone rendering could be byte-capped so that large embeds don't cause frame drops:

```lua
-- embed.lua — byte-aware zone rendering
local batch_drain = require("andrew.vault.batch_drain")

local function render_in_range_batched(descs, ctx, top, bot)
  local render_batch = batch_drain.new({
    max_count = 10,     -- Cap embeds per render pass
    max_bytes = 8192,   -- 8 KB of content per render pass
    on_drain = function(items)
      for _, desc in ipairs(items) do
        render_single_embed(desc, ctx)
      end
    end,
  })

  for _, d in ipairs(descs) do
    if not d.rendered and d.lnum >= top and d.lnum <= bot then
      local est_bytes = d.content and #table.concat(d.content, "\n") or 100
      render_batch:push(d, est_bytes)
    end
  end

  render_batch:flush()
end
```

**Benefit:** A zone with many tiny embeds renders up to 10; a zone with one massive embed renders just that one. Total work per render pass is bounded by bytes, not just zone membership. This complements the existing viewport-zone lazy rendering and prefetch coordinator dispatch.

### 4. Search Results: Batched UI Updates

`search_filter.lua` has two evaluation paths: the sync `evaluate()` (line 457) which accumulates matches into a single table capped by `config.search.max_result_files` (5000) with cancellation checks every 200 items, and `evaluate_async()` (line 505) which yields every `evaluate_batch_size` (500) entries via `yield_iter.filter_yielding()` with request coalescer dedup (`search_pool`, keyed by `ast_hash`). Both paths share `prepare_evaluate()` (line 421) which builds a predicate combining bloom filter pre-checks (`_tag_blooms`), precomputed set pre-checks (`_files_by_type`, `_files_with_tags`, `_files_with_tasks`), and full AST evaluation — all within arena scopes. But neither streams results to the UI incrementally.

With batch drain, the sync evaluate path could stream results to fzf in predictable chunks:

```lua
-- search.lua — batched result delivery
local batch_drain = require("andrew.vault.batch_drain")

local function stream_results_to_fzf(query, index, fzf_sink)
  local result_batch = batch_drain.new({
    max_count = 50,
    on_drain = function(items)
      -- Deliver chunk of formatted results to fzf
      local lines = {}
      for _, match in ipairs(items) do
        lines[#lines + 1] = format_result_line(match)
      end
      fzf_sink(lines)
    end,
  })

  for rel_path, entry in pairs(index.files) do
    if match_entry(query, rel_path, entry) then
      result_batch:push({ rel_path = rel_path, entry = entry })
    end
  end

  result_batch:flush()
end
```

**Benefit:** The fzf UI receives results in chunks of 50, allowing progressive display without the overhead of per-item fzf sink calls. This complements the existing `evaluate_async()` yielding by adding byte-awareness and encapsulating the accumulation logic.

---

## Integration with Existing Coroutine Builds

The `vault_index_build.lua` coroutine and `completion_base.lua`'s `build_iter` already use count-based batching with `coroutine.yield()`. Batch drain complements these patterns by adding byte-awareness and encapsulating the accumulation logic.

### Coroutine + Batch Drain

`vault_index_build.lua` uses adaptive batch sizing via `compute_batch_size()` (line 96): it measures elapsed time per batch in nanoseconds via `vim.uv.hrtime()`, targets 16ms per batch (`TARGET_MS = 16`, line 74), with a minimum of 5 files (`MIN_BATCH = 5`, line 75) and a maximum of `config.index.batch_size * 4` (base is 20). The build loop (line 428) processes files with `parse_file_chunked()`, accumulates mutations in a local `staged` table, and yields via `coroutine.yield()` (line 468) after each adaptive batch. After all batches complete, mutations are committed atomically via `_apply_staged()` (line 648), which also batch-updates the `_summary_tree` for >10 changes (threshold at line 669, using `batch_begin()`/`batch_update()`/`batch_end()` from `summary_tree.lua` to defer ancestor recomputation). This adaptive approach could be combined with batch drain for byte-awareness:

```lua
-- vault_index_build.lua — coroutine-aware batch drain
local batch = batch_drain.new({
  max_count = config.index.batch_size,  -- 20
  max_bytes = 262144,  -- 256 KB of parsed content
  on_drain = function(items)
    for _, item in ipairs(items) do
      staged[item.rel_path] = item.entry
    end
    -- Yield after processing each batch (integrates with yield_iter.run_async)
    if coroutine.isyieldable() then
      coroutine.yield()
    end
  end,
})

for _, file_path in ipairs(changed_files) do
  local entry = parse_file(file_path)
  local est_bytes = entry and entry._raw_size or 0
  batch:push({ rel_path = rel_path, entry = entry }, est_bytes)
end

batch:flush()
-- Then: index:_apply_staged(staged) commits atomically
```

### Replacing Manual Batch Counting

The existing pattern in `completion_base.lua` uses `effective_batch_size()` (line 198) — an adaptive function that ensures at most 3 coroutine yields by computing `math.max(configured, math.ceil(estimated_items / 3))` from the vault index file count (retrieved via `vi_idx:file_count()` at line 479):

```lua
-- Current: manual count tracking with adaptive batch size
local effective_bs = effective_batch_size(est_count, batch_size)  -- batch_size = 50
local count = 0
for item in iter do
  items[#items + 1] = item
  count = count + 1
  if count % effective_bs == 0 then
    coroutine.yield()
  end
end
```

Becomes:

```lua
-- With batch_drain: encapsulated threshold logic + byte awareness
local effective_bs = effective_batch_size(est_count, batch_size)
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
```

The batch drain handles the counting and threshold logic, while the coroutine yield point is explicit in the drain callback. The adaptive batch sizing from `effective_batch_size()` is preserved via `max_count`.

---

## Performance

### Memory Bounds

The batch accumulator's memory usage is bounded by:

```
max_memory = max_count * avg_item_size
           OR max_bytes (whichever triggers first)
```

For the default config (`max_count = 100`, `max_bytes = 512KB`):
- 100 small items (100 bytes each) = ~10 KB → drains by count
- 5 large items (100 KB each) = ~500 KB → drains by bytes
- Peak is always <= 512 KB regardless of input pattern

### Overhead

| Operation | Cost |
|-----------|------|
| `push()` without drain | O(1): table insert + integer increment + comparison |
| `push()` with drain | O(batch): drain callback + table reset |
| `flush()` | O(remaining): same as drain |
| Byte tracking | O(1): running counter, no re-scan |

The `push()` fast path (no drain) adds ~3 operations compared to raw `table.insert`: one increment of `_total_bytes`, one comparison against `_max_count`, one comparison against `_max_bytes`. At LuaJIT speeds this is negligible.

### Backpressure

Because drain is synchronous, the producer naturally stalls while the consumer processes a batch. In a 10K-item loop with `max_count = 100`:

```
Items 1-99:    push (fast, no drain)          ~1 us each
Item 100:      push + drain callback          ~5 ms (batch processing)
Items 101-199: push (fast, no drain)          ~1 us each
Item 200:      push + drain callback          ~5 ms (batch processing)
...
```

Total time is dominated by drain callback work, not accumulation overhead. The event loop can process events between batches if the drain callback yields via `vim.schedule` or coroutine.

### Table Reuse Consideration

The current design creates a new `_items` table on each drain and passes the old one to the callback. An alternative would be to reuse the table via `table.move` and `self._items[i] = nil`, but this adds complexity for minimal benefit — Lua table allocation for 100-element arrays is ~1 us. The callback owns the drained batch and can hold a reference beyond the drain call without risk of mutation.

---

## Configuration

The codebase already has per-module batch size configs (no `M.batch` section exists yet). The new `M.batch` section provides defaults for the batch drain primitive itself, while existing per-module settings continue to control their own batch counts:

```lua
-- config.lua — new section for batch drain defaults (to be added)
M.batch = {
  default_max_count = 100,    -- Default item count threshold
  default_max_bytes = 524288, -- Default byte size threshold (512 KB)
}

-- Existing per-module batch configs (unchanged, with config.lua line numbers):
-- M.autolink.batch.max_pattern_names = 50  (line 186, names per ripgrep invocation)
-- M.index.batch_size = 20                  (line 349, files per async build batch)
-- M.completion.batch_size = 50             (line 418, items per coroutine yield)
-- M.search.evaluate_batch_size = 500       (line 526, entries per yield in evaluate_async)
-- M.connections.score_batch_size = 200     (line 262, entries per yield in compute_async)
-- M.graph.bfs_batch_size = 100             (line 547, nodes per yield in async BFS)
-- M.events.max_batch_size = 32             (line 879, force flush at N pending events)
-- M.pipeline.batch_extmarks = true         (line 902, atomic operations for extmark batching)
-- M.url_validation.max_queue_size = 200    (line 718, maximum queued rate-limited requests)
-- M.url_validation.queue_drain_interval_ms = 100  (line 720, rate limiter queue drain timer)
```

Each use site can override `M.batch` defaults via the `opts` argument to `batch_drain.new()`, and should prefer existing per-module batch sizes where applicable:

```lua
-- Small batches for UI-facing operations
batch_drain.new({ max_count = 10, max_bytes = 8192, on_drain = fn })

-- Large batches for background I/O
batch_drain.new({ max_count = 500, max_bytes = 1048576, on_drain = fn })

-- Using existing per-module config
batch_drain.new({ max_count = config.index.batch_size, max_bytes = 262144, on_drain = fn })
```

---

## Monitoring

Extend `:VaultCacheStats` with batch drain metrics:

```
Batch Drain Stats:
  index_persist:  pushes=10247, drains=103, avg_batch=99.5, total_bytes=4.2MB
  url_validate:   pushes=47, drains=5, avg_batch=9.4, total_bytes=0
  embed_render:   pushes=23, drains=8, avg_batch=2.9, total_bytes=18.4KB
  search_results: pushes=2847, drains=57, avg_batch=49.9, total_bytes=0
```

Each batch drain instance exposes `:stats()` for the debug command to query.

---

## Relationship to Existing Documents

### Doc 22 (Chunked Pipeline Processing)

Doc 22 provides chunked iteration over **existing collections** — process a pre-built array or map in fixed-size chunks. The data exists before chunking begins.

Doc 44 provides threshold-based accumulation of **incoming items** — items arrive one at a time, and the batch is built incrementally. The data does not exist all at once.

| Aspect | Doc 22 (Chunked Pipeline) | Doc 44 (Batch Drain) |
|--------|--------------------------|---------------------|
| Input | Pre-existing collection | Items arriving incrementally |
| Trigger | Iterator advances by chunk_size | Push count or byte threshold |
| Byte-awareness | No | Yes (dual threshold) |
| Backpressure | Via coroutine yield | Via synchronous drain callback |
| Primary use | Iterating vault index | Accumulating results/changes |

The two patterns compose naturally: a batch drain accumulates incoming items, and when the threshold triggers, the drain callback can use chunked pipeline processing on the batch.

### Doc 14 (Cooperative Yielding)

Batch drain integrates with cooperative yielding by placing `coroutine.yield()` calls inside drain callbacks. The drain callback is the natural yield point — it marks the boundary between batches of work.

### Doc 07 (Debounced Persistence)

Doc 07 controls **when** to persist (debounce timer). Doc 44 controls **how much** to serialize per persistence operation. The current implementation already uses adaptive debouncing (`_schedule_full_persist()` at line 995 with `persist_debounce_ms` and `persist_min_interval_ms`, computing `delay = math.max(debounce, min_interval - since_last)`) and WAL-based deltas (`_persist_delta()` at line 939, triggered by `_schedule_persist()` at line 979 with WAL threshold of 1000 entries). Batch drain adds value specifically to the full snapshot path: when the debounced persist timer fires and `_prepare_persist_data()` is called (line 1015), entries are serialized in bounded chunks rather than all at once via `vim.json.encode(data)` (line 1037).

---

## Validation

1. **Threshold correctness:** Verify drain fires at exactly `max_count` items and at exactly `max_bytes` bytes. Test with items of varying sizes to confirm the first-threshold-wins behavior.
2. **Flush completeness:** After `flush()`, `is_empty()` returns true and all items have been delivered to `on_drain`.
3. **Re-entrancy safety:** The drain callback can safely call `push()` on the same batch (items go into the next batch, not the current drain).
4. **Zero-item flush:** `flush()` on an empty accumulator does not call `on_drain`.
5. **Stats accuracy:** `stats().total_items` equals the sum of all drain batch sizes. `stats().drains` equals the number of `on_drain` calls.
6. **Byte-size-only drain:** Push 3 items with byte sizes summing to > `max_bytes` but count < `max_count`. Verify drain triggers.
7. **Count-only drain:** Push `max_count` items with no byte_size argument. Verify drain triggers on count alone.
8. **Coroutine integration:** Use batch drain inside a coroutine with `coroutine.yield()` in the drain callback. Verify the coroutine resumes correctly after yield.
9. **Memory profile:** Measure peak memory during 10K-item accumulation with `max_count = 100` vs. unbounded accumulation. Confirm ~100x reduction in peak batch size.

---

## Expected Impact

### Memory Reduction

| Operation | Before | After | Reduction |
|-----------|--------|-------|-----------|
| Index full snapshot (10K files) | ~8 MB single JSON string via `_prepare_persist_data()` (line 1037: `vim.json.encode(data)`) | <=512 KB per chunk (WAL path already per-entry via `_persist_delta()`) | 94% peak reduction for snapshots |
| URL validation batch | 1 curl per URL via `run_curl()` (rate-limited via `rate_limiter`, deduplicated via `request_coalescer`) | 10 URLs per curl `--next` batch | 10x fewer process spawns |
| Embed render per zone | All qualifying embeds in zone via `render_in_range()` (line budget via `compute_remaining()` but no byte cap) | Bounded by 8 KB content per pass | Predictable render duration |
| Search result delivery | All matches via `evaluate()` (capped at 5000) or 500-entry yields via `evaluate_async()` | 50 per fzf sink call | Progressive display |

### Predictability

- Drain callback processing time is proportional to `max_count` (or bounded by `max_bytes`), not to burst input rate.
- Memory spikes from burst writes (e.g., git checkout changing hundreds of files) are absorbed: each batch of 100 files is persisted before the next 100 are accumulated.

### Simplicity

The batch drain is a ~60-line module with no dependencies beyond `config.lua`. It replaces ad-hoc counting patterns scattered across multiple modules with a single reusable primitive.

---

## Risks

1. **Synchronous drain blocking:** If the drain callback performs expensive I/O (e.g., disk write), the producer stalls during drain. This is intentional (backpressure), but callers must be aware. For truly async drains, the callback should `vim.schedule` the heavy work and return immediately — but then memory bounding is advisory, not enforced.

2. **Byte size estimation accuracy:** The `byte_size` parameter is caller-provided and may be approximate. If underestimated, actual memory usage exceeds `max_bytes`. If overestimated, batches drain too frequently (harmless but reduces amortization). For JSON-serialized data, `#json_string` is exact; for Lua tables, estimation is inherently approximate.

3. **Interaction with cancellation:** If an operation is cancelled (doc 21) while items are in the accumulator, `flush()` should be called to drain remaining items — or `clear()` to discard them. The caller must decide which is appropriate. The batch drain itself has no cancellation awareness.

4. **Table allocation per drain:** Each drain creates a new `_items` table. For very high drain rates (>1000/sec), this produces garbage collection pressure. In practice, vault operations drain at most a few times per second, so this is not a concern.
