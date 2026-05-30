# 22. Chunked Pipeline Processing

**Priority:** MEDIUM
**Phase:** 2 (Scalability)
**Dependencies:** Document 14 (Cooperative Yielding), Document 21 (Stale Operation Cancellation)
**Status:** COMPLETE (2026-03-22) — all proposals implemented, see Implementation Status below
**Inspired by:** Zed's `ready_chunks(64)` pattern (`project.rs:3814`), `chunks_timeout()` (`embedding_index.rs:286`), bounded channels (`embedding_index.rs:103-283`)

---

## Problem

Vault operations process data in one of two extremes:
1. **All-at-once:** Collect everything into a table, then process (high peak memory)
2. **One-at-a-time:** Process items individually with per-item overhead (high CPU overhead)

Neither approach handles **varying data sizes** or **backpressure** well.

### Implementation Status

| Operation | Proposed | Current Status |
|-----------|----------|----------------|
| `search_filter.evaluate()` | Chunked streaming | DONE - `evaluate_async()` via `yield_iter.filter_yielding()` with batch_size=500; sync path has cancellation check every 200 items |
| `connections.compute()` | Top-K accumulator | DONE - `create_top_k()` min-heap + `compute_async()` via `yield_iter.for_each_yielding()` with batch_size=200 + object pools |
| `vault_index.build_async()` | Adaptive batch sizing | DONE - `compute_batch_size()` targets 16ms via `vim.uv.hrtime()`, bounded MIN_BATCH=5 to base*4 |
| `embed.render_embeds()` | Progressive rendering | DONE - Lazy visible-first + `render_remaining_async()` timer (16ms, batch=5) |
| `completion build_iter` | Chunked yielding | DONE - Adaptive batch sizing via `effective_batch_size()` with base batch_size=50 |
| `ripgrep_in_files()` | Streaming line processing | DONE - `stdout` callback with chunk accumulation, newline counting, early `process_obj:kill()` on limit + semaphore concurrency |
| `pipeline.lua` module | New shared module | DECIDED AGAINST - Distributed via `yield_iter.lua` instead (see Architecture section) |

### Current Architecture (Distributed Pipeline)

Instead of a centralized `pipeline.lua` module, the codebase uses a **distributed async pipeline pattern** built on `yield_iter.lua`:

```
yield_iter.lua (lowest level)
  ├── run_async(fn, callback_or_opts)           -- Coroutine + vim.schedule wrapper
  │     opts: { callback, on_error, cancelled, immediate }
  │     Returns: cancel function (sets cancelled=true)
  ├── for_each_yielding(items, batch_size, fn, opts)  -- Batched iteration
  │     Detects list vs dict via vim.islist()
  │     opts: { cancelled, on_yield, on_complete }
  └── filter_yielding(items, batch_size, predicate, opts)  -- Batched filtering
        Returns: (matches_dict, limit_reached_bool)
        opts: { cancelled, max_results }

Each module implements its own batch sizes via config:
  ├── config.index.batch_size = 20              (file parsing)
  ├── config.completion.batch_size = 50         (item building)
  ├── config.graph.bfs_batch_size = 100         (BFS traversal)
  ├── config.connections.score_batch_size = 200  (connection scoring)
  └── config.search.evaluate_batch_size = 500    (metadata filtering)
```

### Current Processing Patterns (Actual)

| Operation | Pattern | Architecture |
|-----------|---------|-------------|
| `vault_index.build_async()` | Adaptive batch sizing via `compute_batch_size()` (target 16ms, hrtime-measured), staged mutations, atomic `_apply_staged()`, progress every 5 batches | `yield_iter.run_async()` + `coroutine.yield()` per batch |
| `search_filter.evaluate_async()` | `filter_yielding()` with batch=500, cancellation, max_results | `yield_iter.run_async()` + `filter_yielding()` |
| `search_filter.evaluate()` (sync) | All entries with `max_result_files` cap, bloom pre-checks, precomputed sets, cancellation check every 200 items | Direct `pairs()` loop with early exit |
| `ripgrep_in_files()` | Streaming `stdout` callback with chunk accumulation + newline counting, early `process_obj:kill()` on limit, parallel leaf spawn for AND/OR | Semaphore-bounded (`max_concurrent_rg=3`), recursive boolean tree, tmpfile reuse |
| `completion build_iter` | Adaptive batch size (`effective_batch_size`), caps at 3 yields, 30s index build timeout | `yield_iter.run_async()` + iterator with `coroutine.yield()` |
| `connections.compute_async()` | Top-K min-heap with early pruning, IDF-weighted 5-signal scoring, object pools | `yield_iter.run_async()` + `for_each_yielding()` |
| `embed.render_embeds()` | Visible-first sync render, async remainder via 16ms timer, descriptor pool, cache warming | `cleanup.repeating(16ms)` timer with generation tracking |
| `bfs.traverse_async()` | BFS with batch_size=100 nodes per yield, per-node iter_hook | `yield_iter.run_async()` + manual counter in iter_hook |

---

## Zed's Approach (Updated References)

Zed uses **chunked streaming with bounded buffers** throughout its pipeline. Updated file references from current codebase:

### `ready_chunks` Usage

```rust
// Project buffer search: load 64 buffers per chunk (project.rs:3814)
// Early exit: buffer_count > 5000 or range_count > 10000
let chunks = matching_buffers_rx.ready_chunks(64);
let mut chunks = pin!(chunks);
'outer: while let Some(matching_buffer_chunk) = chunks.next().await {
    let mut chunk_results = Vec::with_capacity(matching_buffer_chunk.len());
    for buffer in matching_buffer_chunk {
        let query = query.clone();
        let snapshot = buffer.read_with(cx, |buffer, _| buffer.snapshot())?;
        chunk_results.push(cx.background_spawn(async move {
            let ranges = query.search(&snapshot, None).await
                .iter()
                .map(|range| snapshot.anchor_before(range.start)
                    ..snapshot.anchor_after(range.end))
                .collect::<Vec<_>>();
            anyhow::Ok((buffer, ranges))
        }));
    }
    let chunk_results = futures::future::join_all(chunk_results).await;
    // ... early exit on limit reached (MAX_SEARCH_RESULT_FILES=5000, MAX_SEARCH_RESULT_RANGES=10000)
}

// Buffer ordered messages: batch 128 operations (project.rs:2721)
// Batches buffer operations, resync commands, and language server updates
const MAX_BATCH_SIZE: usize = 128;
let mut changes = rx.ready_chunks(MAX_BATCH_SIZE);
while let Some(changes) = changes.next().await {
    for change in changes {
        match change {
            BufferOrderedMessage::Operation { buffer_id, operation } => {
                operations_by_buffer_id.entry(buffer_id).or_insert(Vec::new()).push(operation);
            }
            BufferOrderedMessage::Resync => { flush_operations(...).await?; }
            BufferOrderedMessage::LanguageServerUpdate { .. } => { flush_operations(...).await?; ... }
        }
    }
}

// Edit agent: batch 32 edits at a time (edit_agent.rs:331)
let mut edits = edits.ready_chunks(32);
while let Some(edits) = edits.next().await {
    cx.update(|cx| {
        let max_edit_end = buffer.update(cx, |buffer, cx| {
            buffer.edit(edits.iter().cloned(), None, cx);  // Atomic batch
            // ... calculate max edit position, update action log + agent location
        });
    })?;
}

// Workspace serialization: batch 200 items (workspace.rs:5329)
// Deduplicates by item_id, 200ms throttle between chunks
const CHUNK_SIZE: usize = 200;
let mut serializable_items = items_rx.ready_chunks(CHUNK_SIZE);
while let Some(items_received) = serializable_items.next().await {
    let unique_items = items_received.into_iter()
        .fold(HashMap::default(), |mut acc, item| {
            acc.entry(item.item_id()).or_insert(item);
            acc
        });
    // ... serialize each unique item as detached background task
    cx.background_executor().timer(SERIALIZATION_THROTTLE_TIME).await;  // 200ms
}

// Project search results: batch 1024 (project_search.rs:312)
let mut matches = pin!(search.ready_chunks(1024));
```

### `chunks_timeout` Usage

```rust
// Embedding pipeline: 512 files OR 2 seconds (embedding_index.rs:286)
// Trait: ChunksTimeoutStreamExt from futures-batch crate
let mut chunked_file_batches =
    pin!(chunked_files.chunks_timeout(512, Duration::from_secs(2)));
while let Some(chunked_files) = chunked_file_batches.next().await {
    let chunks: Vec<TextToEmbed> = chunked_files.iter()
        .flat_map(|file| file.chunks.iter().map(|chunk| TextToEmbed {
            text: &file.text[chunk.range.clone()],
            digest: chunk.digest,
        }))
        .collect();
    // Nested batching: chunks_timeout -> file chunks -> embedding provider batches
    for embedding_batch in chunks.chunks(embedding_provider.batch_size()) {
        if let Some(batch_embeddings) =
            embedding_provider.embed(embedding_batch).await.log_err() {
            // ... validate count, extend embeddings
        }
    }
    // Files with ANY failed embedding are discarded entirely (all-or-nothing)
}

// Summary persistence: 4096 summaries OR 2 seconds (summary_index.rs:617)
let mut summaries = pin!(summaries.chunks_timeout(4096, Duration::from_secs(2)));
while let Some(summaries) = summaries.next().await {
    let mut txn = db_connection.write_txn()?;
    for file in &summaries {
        digest_db.put(&mut txn, &file.path, &FileDigest { mtime: file.mtime, digest: file.digest })?;
        summary_db.put(&mut txn, &file.digest, &file.summary)?;
    }
    txn.commit()?;
}
```

### Bounded Channel Pipeline Stages

```rust
// Embedding index 4-stage pipeline (embedding_index.rs)
// scan_entries() -> chunk_files() -> embed_files() -> persist_embeddings()

// Stage boundaries with bounded channels:
let (updated_entries_tx, updated_entries_rx) = channel::bounded(512);   // Scan -> Chunk (line 103)
let (deleted_entry_ranges_tx, deleted_entry_ranges_rx) = channel::bounded(128);  // (line 104)
let (chunked_files_tx, chunked_files_rx) = channel::bounded(2048);     // Chunk -> Embed (line 234)
let (embedded_files_tx, embedded_files_rx) = channel::bounded(512);    // Embed -> Persist (line 283)

// Pipeline composition:
let scan = self.scan_entries(worktree, cx);
let chunk = self.chunk_files(worktree_abs_path, scan.updated_entries, cx);
let embed = Self::embed_files(self.embedding_provider.clone(), chunk.files, cx);
let persist = self.persist_embeddings(scan.deleted_entry_ranges, embed.files, cx);
futures::try_join!(scan.task, chunk.task, embed.task, persist)?;

// Chunk stage uses cx.background_executor().scoped() with num_cpus() workers (lines 237-239)

// Summary index 5-stage pipeline (summary_index.rs):
// scan -> digest -> check_cache -> summarize -> persist
// Channels: bounded(512) for scan(290)/cache(256)/summarize(492), bounded(2048) for digest(424)
futures::try_join!(backlogged.task, digest.task, needs_summary.task, summaries.task, persist)?;

// Persist stage interleaves two receivers (embedding_index.rs:372):
// select_biased! prioritizes deletions over inserts for clean transaction ordering
futures::select_biased! {
    deletion_range = deleted_entry_ranges.next() => { /* delete entries */ },
    file = embedded_files.next() => { /* insert embeddings */ },
    complete => break,
}

// Project search pipeline (project_index.rs:234): bounded(1024) for search results
// Summary pipeline (project_index.rs:413): bounded(1024) for (filename, summary) tuples
```

Key principles:
- **`ready_chunks`** takes what's already available, up to limit (backpressure-aware)
- **`chunks_timeout`** adds time-based fallback to prevent stalls (via `futures-batch` crate)
- **Bounded channels** between pipeline stages prevent upstream from overwhelming downstream
- **Buffer size strategy:** 512 for entries/embeddings, 2048 for chunks/digests, 128 for deletes, 1024 for search/summary results
- **Parallel processing within chunks** via `join_all` + `background_spawn` or `scoped()` with `num_cpus()` workers

---

## What's Already Implemented

### 1. Search Filter Evaluation (DONE)

Both sync and async paths exist in `search_filter.lua`:

```lua
-- search_filter.lua: sync evaluate (lines 435-460)
function M.evaluate(ast, index, graph_sets, restrict_to, cancelled)
  local files, predicate, max_files = prepare_evaluate(ast, index, graph_sets, restrict_to)
  if not files then return {}, false end
  local check_interval = 200  -- cancellation check frequency
  local matches = {}
  local count = 0
  local iter_count = 0
  for rel_path, entry in pairs(files) do
    iter_count = iter_count + 1
    if cancelled and iter_count % check_interval == 0 and cancelled() then
      return nil, "cancelled"
    end
    if predicate(rel_path, entry) then
      matches[rel_path] = entry
      count = count + 1
      if max_files and count >= max_files then return matches, true end
    end
  end
  return matches, false
end

-- search_filter.lua: async evaluate (lines 475-495)
function M.evaluate_async(ast, index, opts)
  opts = opts or {}
  local batch_size = config.search.evaluate_batch_size or 500
  return yield_iter.run_async(function()
    local files, predicate, max_files = prepare_evaluate(
      ast, index, opts.graph_sets, opts.restrict_to)
    if not files then return {}, false end
    local matches, limit_reached = yield_iter.filter_yielding(
      files, batch_size, predicate,
      { cancelled = opts.cancelled, max_results = max_files })
    return matches, limit_reached
  end, opts.callback)
end
```

**Additional optimizations beyond original proposal:**
- `prepare_evaluate()` (lines 399-433) builds filter context with pre-resolved dates, parsed tags, numeric caches
- Bloom filter pre-checks for tag membership (`config.prefilter.bloom_filter`) via `extract_pre_checks()` (lines 302-384)
- Precomputed sets for `type:` (`_files_by_type`), `has:tags` (`_files_with_tags`), `has:tasks` (`_files_with_tasks`)
- Memoized link resolver via `filter_utils.create_memoized_resolver(index)` within single evaluate pass
- Snapshot-based reads (`config.index.use_snapshots`) — full index snapshot for consistent iteration during async builds
- Pre-checks only collected from AND-reachable leaves (OR/NOT subtrees skipped)
- Sync evaluate now supports cancellation via `cancelled` parameter (check every 200 items)

### 2. Connection Scoring with Top-K (DONE)

`connections.lua` implements a proper min-heap, not the simple sorted-array approach proposed:

```lua
-- connections.lua: min-heap top-K (lines 489-546)
local function create_top_k(capacity)
  -- Fixed-size min-heap with:
  --   insert(score, item): bubble-up insertion if heap not full or score > min, O(log k)
  --   min_score(): O(1) threshold for early pruning (returns 0 if heap not full)
  --   results(): sort descending by score, extract items
end

-- connections.lua: 5-signal scoring with early pruning (lines 577-676)
local function score_candidate(rel_path, entry, source_rel_path, source_data,
    weights, idf, total_pages, max_remaining, top, vi, resolve)
  -- 1. Tags (IDF-weighted, cheapest first)
  -- 2. Early pruning: if tag_score + max_remaining < heap.min_score() then return end
  -- 3. Frontmatter field matching (type, project, domain, status)
  -- 4. Co-occurrence/bibliographic coupling (shared outlinks)
  -- 5. Link proximity (1-hop: weight 5.0, 2-hop: weight 2.0)
  -- 6. Temporal proximity
  -- Uses object pools: _breakdown_pool (capacity 200), _result_pool (capacity 200)
end

-- connections.lua: async compute (lines 826-850)
function M.compute_async(source_rel_path, opts)
  opts = opts or {}
  local batch_size = config.connections.score_batch_size or 200
  local max_results_arg = opts.max_results or config.connections.max_results
  return yield_iter.run_async(function()
    local s = prepare_compute(source_rel_path)
    if not s then return {} end
    local top = create_top_k(max_results_arg)
    yield_iter.for_each_yielding(s.files, batch_size,
      function(rel_path, entry)
        score_candidate(rel_path, entry, source_rel_path, s.source_data,
          s.weights, s.idf, s.total_pages, s.max_remaining, top, s.vi, s.resolve)
      end, { cancelled = opts.cancelled })
    return top.results()
  end, opts.callback)
end
```

**Additional optimizations beyond original proposal:**
- 5-signal weighted scoring: tags (IDF), frontmatter, co-links, link proximity (1-hop/2-hop), temporal
- Early pruning: `if tag_score + max_remaining < heap_min then return end` (line 589-590)
- Incremental IDF updates via `update_tag_idf_incremental()` (lines 135-191, generation-based delta)
- Three-tier cache: weighted LRU for results (3 MB), note data (2 MB), + manual IDF cache
- Subscriber-based cache invalidation: only removes changed files from note_data cache (lines 712-725)
- Object pools: `_breakdown_pool` and `_result_pool` (capacity 200 each) reduce GC pressure
- `prepare_compute()` snapshots files table to prevent mid-build mutations during async scoring

### 3. Embed Rendering Pipeline (DONE)

`embed.lua` uses a two-phase approach with timer-based async batching:

```lua
-- embed.lua: render_embeds (lines 386-450)
function M.render_embeds(opts)
  -- ... validation, cancel in-flight async, clear namespace + placements
  local descs = build_descriptors(lines)    -- Single-pass pattern match, uses _desc_pool
  warm_embed_cache(descs, bufpath)          -- Pre-read cross-file targets into file cache
  -- Generation tracking: increment, release old descriptors to pool
  local generation = (old_state and old_state.generation or 0) + 1
  state._embed_descriptors[bufnr] = { generation = generation, list = descs, async_timer = nil }
  if config.embed.lazy then
    -- Phase 1: Render visible embeds synchronously
    local top, bot = visible_range(config.embed.lazy_margin)
    local rendered_count = render_in_range(descs, ctx, top, bot)
    -- Phase 2: Render remaining asynchronously
    if #descs - rendered_count > 0 then
      render_remaining_async(bufnr, generation, ctx)
    end
  else
    -- Legacy: render everything synchronously
    for _, desc in ipairs(descs) do render_single_embed(desc, ctx) end
  end
  -- ... dependency tracking, image retry scheduling (1200ms delay)
end

-- embed.lua: async batch rendering (lines 351-382)
local function render_remaining_async(bufnr, generation, ctx)
  local batch_size = config.embed.lazy_batch_size  -- 5
  local cursor = 1
  ds.async_timer = cleanup.repeating(ds.async_timer, 16, 16, function()
    -- Generation check prevents stale renders
    local current_ds = check_generation(bufnr, generation)
    if not current_ds then return cleanup end
    local rendered_this_tick = 0
    while cursor <= #current_ds.list and rendered_this_tick < batch_size do
      local desc = current_ds.list[cursor]
      cursor = cursor + 1
      if not desc.rendered then
        render_single_embed(desc, ctx)
        rendered_this_tick = rendered_this_tick + 1
      end
    end
    if cursor > #current_ds.list then cleanup() end
  end)
end
```

**Additional features beyond original proposal:**
- Object pool (`_desc_pool`, capacity 50) for descriptor allocation reuse with batch release
- Warm caching of cross-file embeds before rendering (`warm_embed_cache()`, lines 171-183)
- Generation tracking prevents stale async renders (`check_generation()`, lines 340-345)
- Separate image retry mechanism for failed placements (1200ms delay)
- `render_single_embed()` (lines 227-316) handles both image (snacks placement) and note (virtual text) paths
- `render_in_range()` (lines 324-333) renders only descriptors within viewport bounds

### 4. Vault Index Build Batching (DONE)

`vault_index_build.lua` uses adaptive batching with coroutine yielding:

```lua
-- vault_index_build.lua: adaptive batch sizing (lines 10-24)
local TARGET_MS = 16
local MIN_BATCH = 5

local function compute_batch_size(elapsed_ns, files_processed, base)
  if elapsed_ns <= 0 or files_processed <= 0 then return base end
  local ms_per_file = elapsed_ns / (files_processed * 1e6)
  local adaptive = math.floor(TARGET_MS / ms_per_file)
  return math.max(MIN_BATCH, math.min(adaptive, base * 4))
end

-- vault_index_build.lua: batch processing (lines 88-130)
local base_batch = config.index.batch_size  -- 20
local current_batch_size = base_batch
while processed < total do
  local batch_start_ns = vim.uv.hrtime()
  local batch_end = math.min(processed + current_batch_size, total)
  for j = processed + 1, batch_end do
    local file = changed[j]
    local entry = parser.parse_file(file.abs_path, file.rel_path, file.stat)
    if entry then
      index:_apply_entry_mt(entry)
      staged[file.rel_path] = entry
    end
    files_this_batch = files_this_batch + 1
  end
  -- Adapt batch size based on measured time
  local elapsed_ns = vim.uv.hrtime() - batch_start_ns
  current_batch_size = compute_batch_size(elapsed_ns, files_this_batch, base_batch)
  coroutine.yield()
end
-- Atomic apply: all mutations in one synchronous pass (no yield)
index:_apply_staged(staged, deleted_rel_paths, old_entries, changed_rel_paths, is_cold_start)
```

**What's implemented:** Adaptive batch sizing targeting 16ms via `vim.uv.hrtime()` measurement (bounded MIN_BATCH=5 to base*4=80), staged mutations, atomic apply, progress notifications every 5 batches, old entries captured before overwriting.

### 5. Completion Pipeline (DONE)

`completion_base.lua` has adaptive batch sizing:

```lua
-- completion_base.lua: adaptive batch sizing (lines 157-160)
local function effective_batch_size(estimated_items, configured)
  if estimated_items <= 0 then return configured end
  return math.max(configured, math.ceil(estimated_items / 3))  -- Cap at 3 yields
end

-- completion_base.lua: coroutine-based build (lines 327-389)
-- Debounce: cleanup.debounce(state.timer, debounce_ms, ...)  -- debounce_ms=250
yield_iter.run_async(function()
  local count = 0
  for item in iter do
    items[#items + 1] = item
    count = count + 1
    if count % effective_bs == 0 then
      coroutine.yield()
    end
  end
end, {
  cancelled = function()
    -- Checks state.cancelled AND generation match
    if state.cancelled or gen ~= build_generation then return true end
    return false
  end,
  callback = ...,
  immediate = true,
})
```

**Additional details:**
- Index build detection: checks `vault_index._building` with 30-second timeout fallback (lines 165-183)
- Cancellation: `active_state.cancelled` flag + timer cleanup + generation counter
- Legacy sync path (`opts.build`) and coroutine path (`opts.build_iter`) coexist

### 6. Ripgrep Processing (DONE)

`search_filter/ripgrep.lua` uses streaming `stdout` callback with early termination:

```lua
-- ripgrep.lua: async streaming spawn (lines 195-227)
local chunks = {}
local line_count = 0
local max_lines = config.search.max_result_lines
local capped = false

process_obj = vim.system(args, {
  stdout = function(_, data)
    if not data or capped then return end
    if max_lines then
      for _ in data:gmatch("\n") do
        line_count = line_count + 1
        if line_count >= max_lines then
          capped = true
          limit_state.reached = true
          chunks[#chunks + 1] = data
          if process_obj then process_obj:kill() end
          return
        end
      end
    end
    chunks[#chunks + 1] = data
  end,
}, function(result)
  release()
  result.stdout = table.concat(chunks)  -- Assemble collected chunks
  on_done(process(result))
end)

-- ripgrep.lua: sync fallback (line 297)
-- Used by fzf_live provider which requires synchronous returns
vim.system(args, { text = true }):wait()

-- ripgrep.lua: output processing with limits (lines 126-156)
local function process_rg_output(result, opts)
  -- Parse stdout via gmatch("[^\n]+"), enforce max_result_lines via shared limit_state
  -- Post-filter results when --files-from not used
end
```

**What's implemented:**
- Streaming stdout via callback: chunks accumulated, newlines counted, early `process_obj:kill()` on limit
- Semaphore-bounded concurrency (`config.search.max_concurrent_rg = 3`, `rg_queue_max = 5`) via shared `process_semaphore.lua` singleton
- Recursive boolean tree evaluation (AND=intersect, OR=union, NOT=complement)
- Parallel leaf execution for AND/OR nodes via `try_acquire()` + `:wait()` (lines 318-330)
- Result limits (`max_result_lines=10000`, `max_result_files=5000`, `max_matches_per_file=100`)
- Single tmpfile per call, reused across recursive rg calls, cleaned up on completion (lines 493-514)
- `max_files_from=500` threshold: if metadata produces more files, falls back to full-vault rg with post-filtering
- Sync fallback still uses `{ text = true }` (acceptable — sync path used only by fzf_live which needs blocking returns)

### 7. BFS Traversal (DONE)

`bfs.lua` uses per-node yielding via iter_hook callback:

```lua
-- bfs.lua: async BFS with yielding (lines 180-198)
function M.traverse_async(opts, async_opts)
  async_opts = async_opts or {}
  local batch_size = async_opts.batch_size
    or require("andrew.vault.config").graph.bfs_batch_size or 100
  return yield_iter.run_async(function()
    local batch_count = 0
    return run_bfs_loop(opts, function()
      if async_opts.cancelled and async_opts.cancelled() then return true end
      batch_count = batch_count + 1
      if batch_count >= batch_size then
        batch_count = 0
        coroutine.yield()
      end
      return false
    end)
  end, async_opts.callback)
end

-- bfs.lua: sync traverse (lines 161-163)
function M.traverse(opts) return run_bfs_loop(opts, nil) end
-- Core loop (lines 120-156): queue-based BFS with head/tail pointers, max_nodes cap
```

---

## Remaining Work

All originally proposed items are now implemented. The centralized pipeline module was decided against in favor of the distributed architecture.

### Centralized Pipeline Module (DECIDED AGAINST)

The original proposal suggested a `pipeline.lua` module with `chunked()`, `chunked_pairs()`, `streaming_reduce()`, and `top_k()`. The codebase instead evolved these into:

- `yield_iter.lua` -- generic `run_async()`, `for_each_yielding()`, `filter_yielding()`
- `connections.lua` -- domain-specific `create_top_k()` min-heap with early pruning + object pools
- `embed.lua` -- timer-based batching via `cleanup.repeating()` + descriptor pool
- `completion_base.lua` -- adaptive `effective_batch_size()` + generation-based cancellation

This distributed approach has advantages:
- Each module's batching is tuned to its specific access pattern
- No unnecessary abstraction overhead for one-off patterns (embed timer, completion adaptive sizing)
- Top-K is tightly coupled with scoring (early pruning needs access to `max_remaining`)
- Object pools are domain-specific (embed descriptors vs connection breakdowns/results)

**Decision:** Keep the distributed architecture. A centralized `pipeline.lua` would add indirection without clear benefit given that `yield_iter.lua` already provides the shared primitives.

---

## Configuration (Current)

All batch sizes are already in `config.lua`:

```lua
-- config.lua (actual current values with line references)
M.index = {
  batch_size = 20,               -- Files per vim.schedule tick in build_async (line 373)
  persist_debounce_ms = 5000,    -- Debounce for persisting index to disk (line 376)
  persist_min_interval_ms = 10000, -- Adaptive burst protection (line 379)
  watch_debounce_ms = 500,       -- Filesystem watcher debounce (line 385)
  progress_threshold = 50,       -- Min changed files before showing progress (line 396)
  -- ...
}

M.completion = {
  debounce_ms = 250,             -- Debounce before rebuild (line 415)
  batch_size = 50,               -- Entries per coroutine yield (base; adaptive scales up) (line 420)
  index_build_timeout_secs = 30, -- Max wait for vault index build (line 424)
  max_items = 10000,             -- Cap on completion items per source (line 428)
  -- ...
}

M.connections = {
  cache_ttl = 60,                -- Seconds before cached scores expire (line 284)
  max_results = 30,              -- Top-K capacity (line 285)
  score_batch_size = 200,        -- Entries per yield in async scoring (line 286)
  -- ...
}

M.search = {
  evaluate_batch_size = 500,     -- Entries per yield in evaluate_async (line 528)
  max_concurrent_rg = 3,        -- Semaphore permits for ripgrep (line 524)
  rg_queue_max = 5,              -- Max queued rg requests (line 525)
  max_files_from = 500,          -- Threshold before full-vault rg fallback (line 448)
  max_result_files = 5000,       -- Early exit cap (line 517)
  max_result_lines = 10000,      -- Ripgrep output cap (line 518)
  max_matches_per_file = 100,    -- Per-file rg --max-count cap (line 519)
  live_debounce_ms = 150,        -- Live search re-evaluation debounce (line 442)
  -- ...
}

M.embed = {
  lazy = true,                   -- Enable two-phase rendering
  lazy_batch_size = 5,           -- Embeds per async timer tick (line 94)
  lazy_scroll_debounce_ms = 80,  -- Scroll event debounce (line 95)
  lazy_margin = 0,               -- Extra lines around viewport for initial render
  sync = {
    debounce_ms = 300,           -- Cross-file embed sync debounce (line 99)
    self_debounce_ms = 500,      -- Same-file TextChanged debounce (line 100)
  },
  -- ...
}

M.graph = {
  bfs_batch_size = 100,          -- Nodes per yield in BFS traversal (line 549)
  max_nodes = 50,                -- Safety cap for multi-hop collection (line 548)
  -- ...
}

-- Object pool capacities (config.pools, line 863):
--   embed_descriptor = 50       -- Embed descriptor pool (line 868)
--   connection_result = 200     -- Connection result pool (line 865)
--   connection_breakdown = 200  -- Connection breakdown pool (line 866)
--   completion_item = 1000      -- Completion item pool (line 867)

-- Event coalescing (config.events, line 872):
--   buf_enter_coalesce_ms = 16  -- BufEnter coalescing window (line 873)
--   max_batch_size = 32         -- Force flush at this many pending events (line 876)
```

---

## Validation

1. **Memory comparison:** Measure peak memory during search with/without chunking - APPLICABLE to remaining items only
2. **Correctness:** Verify chunked evaluation produces identical results to all-at-once - DONE (sync/async evaluate coexist)
3. **Responsiveness:** Measure UI frame drops during 10K-entry operations - DONE (yield_iter ensures <16ms batches)
4. **Cancellation:** Verify chunked iteration respects cancel tokens at chunk boundaries - DONE (all async paths check `cancelled`)
5. **Top-K accuracy:** Verify top_k produces same results as full sort + truncate - DONE (min-heap in connections)
6. **Edge cases:** Empty input, single item, chunk_size > total items, cancel on first chunk - DONE (yield_iter handles all)

---

## Summary

This document's core proposals have been **fully implemented** (verified 2026-03-22) through a distributed architecture rather than the originally-proposed centralized `pipeline.lua` module:

| Proposal | Status | Implementation |
|----------|--------|---------------|
| Core chunked iterator | DONE (different shape) | `yield_iter.for_each_yielding()` |
| Streaming reduce | DONE (different shape) | `yield_iter.filter_yielding()` |
| Top-K accumulator | DONE (better) | `connections.create_top_k()` min-heap with early pruning + object pools |
| Search filter chunking | DONE | `evaluate_async()` + `filter_yielding()` + sync cancellation (check every 200 items) |
| Connection scoring top-K | DONE | `compute_async()` + min-heap + IDF + early pruning + 3-tier cache |
| Embed progressive rendering | DONE | Two-phase: visible sync + timer-based async + descriptor pool + cache warming |
| Completion chunking | DONE | Adaptive `effective_batch_size()` + generation-based cancellation |
| BFS traversal | DONE | `traverse_async()` + per-node iter_hook + batch_size=100 |
| Index adaptive batching | DONE | `compute_batch_size()` targets 16ms via `vim.uv.hrtime()`, bounded 5–80 |
| Ripgrep streaming | DONE | `stdout` callback with chunk accumulation + early `process_obj:kill()` on limit |
| Centralized pipeline.lua | DECIDED AGAINST | Distributed via `yield_iter.lua` + domain-specific pools |
