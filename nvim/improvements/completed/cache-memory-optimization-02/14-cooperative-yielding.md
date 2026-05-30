# 14 — Cooperative Yielding in Search & Filter Hot Paths

## Priority: MEDIUM
## Inspired By: Zed's `YIELD_INTERVAL` patterns, `chunks_timeout()`, `ready_chunks()` batching

## Problem

Several vault operations iterate over the entire index (10K+ entries) synchronously,
blocking the Neovim event loop until completion. This causes visible UI freezes:

### Blocking Hot Paths

| Operation | Iterations | Duration (10K vault) | Blocks UI? |
|-----------|-----------|---------------------|------------|
| `search_filter.evaluate()` | 10K entries | ~20-50ms | Yes |
| `connections.compute()` | 10K entries | ~50-100ms | Yes |
| `bfs.traverse()` / `traversal.collect_at_depth()` | 10K × depth BFS | ~30-80ms | Yes |
| `vault_index_build` (coroutine batch) | batch_size entries | Yields ✓ | No (already async) |
| `completion_base.build_iter()` | 10K entries | Yields ✓ | No (already async) |
| `engine_watcher` (dir scan) | directories | Yields ✓ | No (already async) |

The vault index build, completion, and engine watcher systems already use coroutine-based
yielding. But search/filter, connections, and BFS do not, causing freezes during
interactive operations.

### Why This Matters

```
User types in live search:
  → Debounce fires (150ms)
  → evaluate() blocks for 30ms on 10K entries
  → Then ripgrep_in_files() blocks for 50ms+ waiting for rg
  → Total: 80ms+ freeze per keystroke (after debounce)
  → Perceived as sluggish/janky at >16ms (1 frame at 60fps)
```

### Existing Yielding Patterns in Codebase

Three modules already implement cooperative yielding — new code should follow these patterns:

**vault_index_build.lua** (249 lines total) — Batch file parsing:
```lua
-- B.build_async(index, callback) entry point (line 15)
-- coroutine.create() wraps build (line 23), vim.schedule(step) resumes (line 174)
-- Outer loop: for i = 1, total, config.index.batch_size do (lines 69-101)
-- Inner loop: for j = i, batch_end do ... parse_file ... end
-- Single coroutine.yield() at end of each batch (line 100)
-- batch_notify_interval = 5 → progress every 5 batches (line 30, checked at lines 87-97)
-- _building flag set true before create, false after complete or error (lines 17, 129, 169)
-- Progress notifications via vim.schedule() at lines 35, 91, 156
-- config.index.batch_size = 20 (config.lua line 372)
-- config.index.show_progress + progress_threshold = 50 control notifications
```

**completion_base.lua** (682 lines total) — Async completion building:
```lua
-- coroutine.create() at line 331, vim.schedule(step) at line 362
-- coroutine.yield() at count % effective_bs == 0 (line 337)
-- effective_batch_size(estimated_items, configured) adapts: max(configured, ceil(estimated/3))
--   caps yields at ~3 for small vaults (lines 131-139)
-- active_state.cancelled flag checked at lines 280, 289, 303, 343
-- cleanup.debounce(state.timer, debounce_ms, callback) wraps startup (line 301)
-- Errors logged via log:warn() in step function (lines 347-355)
-- config.completion.batch_size = 50 (config.lua line 413)
-- config.completion.debounce_ms = 250 (config.lua line 408)
-- index_build_timeout_secs = 30 (config.lua line 417) — skip rebuild if vault index mid-build
```

**engine_watcher.lua** (343 lines total) — Directory scanning:
```lua
-- start_incremental_watches() entry point (line 202)
-- coroutine.create() at line 210, vim.defer_fn(step, 1) at line 242
-- NOTE: uses vim.defer_fn(step, 1), NOT vim.schedule(step) — differs from other patterns
-- Also vim.defer_fn at line 83 for deferred .md file scan (100ms delay)
-- Yield every 10 directories processed (hardcoded, lines 224-226)
-- batch counter initialized at line 215, reset after yield: batch = 0 (line 226)
-- Checks coroutine.status(co) == "dead" for completion (line 235)
-- Error handling: log.error() (dot, not colon — lines 237-240)
-- No state management flag (watches run in background)
```

### Zed's Approach

Zed uses multiple cooperative yielding strategies calibrated to workload:

**Pattern 1 — Modulo-based interval (search):**
```rust
// crates/project/src/search.rs (line 359) — yield every 20,000 match iterations
const YIELD_INTERVAL: usize = 20000;

// Three search variants all use this pattern:
// Text search (lines 381-382), multiline regex (lines 414-415), chunk-based regex (lines 426-427)
for (ix, mat) in search.stream_find_iter(rope.bytes_in_range(0..rope.len())).enumerate() {
    if (ix + 1) % YIELD_INTERVAL == 0 {
        yield_now().await;
    }
    // Process match...
}
```

**Pattern 2 — Counter-reset interval (tighter loops):**
```rust
// crates/multi_buffer/src/multi_buffer.rs (line 5720) — yield every 100 row accesses
// Used in enclosing_indent() (lines 5695-5827) for indent guide computation
const YIELD_INTERVAL: u32 = 100;

let mut accessed_row_counter = 0;
for (row, indent, _) in self.reversed_line_indents(target_row, |_| true) {
    accessed_row_counter += 1;
    if accessed_row_counter == YIELD_INTERVAL {
        accessed_row_counter = 0;
        yield_now().await;
    }
    // Process indent...
}
// 4 loops at lines 5738, 5754, 5790, 5807
```

**Pattern 3 — Time-bounded batching:**
```rust
// crates/semantic_index/src/embedding_index.rs (line 286)
let mut chunked_file_batches = pin!(chunked_files.chunks_timeout(512, Duration::from_secs(2)));
while let Some(chunked_files) = chunked_file_batches.next().await {
    // Batches up to 512 items OR waits max 2 seconds
}

// crates/semantic_index/src/summary_index.rs (line 617)
let mut summaries = pin!(summaries.chunks_timeout(4096, Duration::from_secs(2)));
```

**Pattern 4 — Ready-chunks batching (search results):**
```rust
// crates/search/src/project_search.rs (line 312) — batch 1024 search results
let mut matches = pin!(search.ready_chunks(1024));
while let Some(results) = matches.next().await {
    for result in results { /* Handle SearchResult */ }
}

// crates/project/src/project.rs (line 2721) — batch 128 buffer ordered messages
let mut changes = rx.ready_chunks(MAX_BATCH_SIZE);  // MAX_BATCH_SIZE = 128

// Also: crates/project/src/project.rs (line 3814) — batch 64 matching buffers
let chunks = matching_buffers_rx.ready_chunks(64);
```

**Pattern 5 — Per-item yielding (message/event loops):**
```rust
// crates/client/src/client.rs (line 1050) — prevent starvation during message floods
while let Some(message) = incoming.next().await {
    this.handle_message(message, &cx);
    smol::future::yield_now().await;  // Don't starve the main thread
}

// Also used in 13+ other locations (14 files total, 27 yield_now() calls):
// wrap_map.rs:507 (per-line wrapping), lsp.rs:521,557 (per-notification + per-stderr-line),
// terminal.rs:568,581 (per-event), buffer.rs:1684,1766 (per-row indent suggestion),
// assistant_context.rs:2159, agent/thread.rs:1948 (per-stream-chunk),
// context_server/client.rs:288, debugger_tools/dap_log.rs:161,176 (per-message),
// collab/rpc.rs:184,187,193 (tokio::task::yield_now — server-side variant)
```

## Proposed Solution

### 1. Yielding Iterator Utility

Create `lua/andrew/vault/yield_iter.lua`:

```lua
--- Cooperative yielding utilities for long-running iterations.
--- Prevents UI freezes by yielding control to Neovim's event loop
--- at configurable intervals.
---
--- Follows existing patterns from vault_index_build.lua and completion_base.lua:
--- coroutine.create() + vim.schedule(step) + coroutine.yield() at batch boundaries.

local M = {}

--- Run a function over a collection with periodic yielding.
--- Must be called from within a coroutine context (e.g., inside run_async).
---
--- @param items table Array or dict to iterate over
--- @param batch_size number Process this many items before yielding
--- @param process_fn function(key, value) Called for each item
--- @param opts table|nil { on_yield: function, on_complete: function, cancelled: function }
function M.for_each_yielding(items, batch_size, process_fn, opts)
  opts = opts or {}
  local count = 0

  if vim.islist(items) then
    for i, item in ipairs(items) do
      if opts.cancelled and opts.cancelled() then return end
      process_fn(i, item)
      count = count + 1
      if count >= batch_size then
        count = 0
        if opts.on_yield then opts.on_yield() end
        coroutine.yield()
      end
    end
  else
    for k, v in pairs(items) do
      if opts.cancelled and opts.cancelled() then return end
      process_fn(k, v)
      count = count + 1
      if count >= batch_size then
        count = 0
        if opts.on_yield then opts.on_yield() end
        coroutine.yield()
      end
    end
  end

  if opts.on_complete then opts.on_complete() end
end

--- Run a filtering operation with periodic yielding.
--- Returns matches accumulated across yields.
---
--- @param items table Dict to filter (key → value)
--- @param batch_size number Items per yield
--- @param predicate function(key, value) → boolean
--- @param opts table|nil { cancelled: function, max_results: number }
--- @return table matches Dict of matching key → value pairs
--- @return boolean limit_reached True if max_results cap was hit
function M.filter_yielding(items, batch_size, predicate, opts)
  opts = opts or {}
  local matches = {}
  local match_count = 0
  local count = 0
  local max_results = opts.max_results or math.huge

  for k, v in pairs(items) do
    if opts.cancelled and opts.cancelled() then break end
    if match_count >= max_results then
      return matches, true
    end

    if predicate(k, v) then
      matches[k] = v
      match_count = match_count + 1
    end

    count = count + 1
    if count >= batch_size then
      count = 0
      coroutine.yield()
    end
  end

  return matches, false
end

--- Wrap a synchronous iteration as an async operation using vim.schedule.
--- For use outside of existing coroutine contexts.
---
--- Follows the coroutine.create() + vim.schedule(step) pattern from
--- vault_index_build.lua and completion_base.lua.
---
--- @param fn function Coroutine body (must call coroutine.yield)
--- @param callback function(result) Called when iteration completes
--- @return function cancel Cancel the iteration
function M.run_async(fn, callback)
  local co = coroutine.create(fn)
  local cancelled = false

  local function step()
    if cancelled then return end
    local ok, val = coroutine.resume(co)
    if not ok then
      -- Error in coroutine — log via vim.schedule to avoid context issues
      -- (matches completion_base.lua error handling pattern)
      vim.notify("yield_iter error: " .. tostring(val), vim.log.levels.ERROR)
      return
    end
    if coroutine.status(co) == "dead" then
      -- Completed
      if callback then callback(val) end
    else
      -- Yielded — schedule next step on next event loop tick
      vim.schedule(step)
    end
  end

  vim.schedule(step)

  return function()
    cancelled = true
  end
end

return M
```

### 2. Apply to search_filter.evaluate()

Current synchronous implementation (`search_filter.lua`, lines 380-416, file total 419 lines):
```lua
-- function M.evaluate(ast, index, graph_sets, restrict_to)
--   ast: table|nil — metadata AST node (field, has, task, graph, and, or, not)
--   index: table — VaultIndex instance
--   graph_sets: table|nil — pre-computed graph reachable sets (from graph_traversal.precompute_graph_sets)
--   restrict_to: table<string, table>|nil — subset to filter (used by search_in_files)
--   returns: matches (table<string, table>), limit_reached (boolean)
--
-- Key internals:
--   match_field_mod.maybe_invalidate_section_cache(index) (line 381) — cache housekeeping
--   ctx = M.build_filter_context(ast, index)  (line 387, lines 147-219)
--     → resolved_dates, parsed_tags, numeric_values, resolve_link (all pre-cached)
--   extract_pre_checks(ast, index) (lines 299-378) → O(1) predicates tested BEFORE match_entry:
--     → controlled by config.prefilter.{enabled, search_pre_checks, precomputed_sets} (config.lua lines 524-531)
--     → type field (via index._files_by_type), has:tags (index._files_with_tags),
--       has:tasks (index._files_with_tasks), has:aliases (entry.aliases)
--     → pre-check callback signature: check(entry, rel_path) — NOTE: entry first, rel_path second
--   M.match_entry(ast, entry, index, graph_sets, ctx) (lines 237-277)
--     → Recursive boolean eval: and/or/not + leaf dispatch to match_field/match_has/match_task/graph
--   config.search.max_result_files = 5000 (config.lua line 510) — early return when reached
```

Add async version that preserves the existing evaluate() for non-interactive paths:

```lua
local yield_iter = require("andrew.vault.yield_iter")

--- Async version of evaluate() that yields periodically.
--- @param ast table|nil Parsed metadata AST
--- @param index VaultIndex
--- @param opts table { graph_sets, restrict_to, callback, cancelled }
function M.evaluate_async(ast, index, opts)
  opts = opts or {}
  local batch_size = config.search.evaluate_batch_size or 500

  return yield_iter.run_async(function()
    -- Cache housekeeping (same as sync evaluate, line 381)
    match_field_mod.maybe_invalidate_section_cache(index)
    -- Pre-compute filter context once (same as sync evaluate, line 387)
    local ctx = M.build_filter_context(ast, index)
    -- Extract O(1) pre-checks for cheap early rejection (lines 388, 393-402)
    local pre_checks = extract_pre_checks(ast, index)
    local files = opts.restrict_to or index.files
    local max_files = config.search.max_result_files

    local matches, limit_reached = yield_iter.filter_yielding(
      files,
      batch_size,
      function(rel_path, entry)
        -- Apply pre-checks first (cheap O(1) predicates before expensive match_entry)
        -- NOTE: pre-check callbacks take (entry, rel_path) — entry first
        if pre_checks then
          for _, check in ipairs(pre_checks) do
            if not check(entry, rel_path) then return false end
          end
        end
        return M.match_entry(ast, entry, index, opts.graph_sets, ctx)
      end,
      {
        cancelled = opts.cancelled,
        max_results = max_files,
      }
    )
    return matches, limit_reached
  end, opts.callback)
end
```

### 3. Apply to connections.compute()

Current synchronous implementation (`connections.lua`, lines 510-705, file total 936 lines):
```lua
-- function M.compute(source_rel_path, max_results)
--   max_results defaults to config.connections.max_results (30, config.lua line 285)
--
-- Architecture (3-level caching + subscriber-based invalidation):
--   1. Result cache (_cache, LRU at line 20): source_rel_path → {results, deps, timestamp, index_gen}
--      TTL: config.connections.cache_ttl (60s), + vault index generation check (lines 521-528)
--   2. Note data cache (_note_data_cache, LRU at line 29): rel_path → ConnectionNoteData
--      Generation tracking: _note_data_gen (line 30)
--      Invalidated via subscriber on_index_update (lines 846-862)
--      ensure_subscription() (lines 866-876), unsubscribe() (lines 879-885)
--   3. IDF cache (_idf_cache at line 23): tag → doc_count, incremental update on generation change
--      _idf_gen (line 25), _idf_total (line 24), _idf_file_tags (line 26)
--      update_tag_idf_incremental() (lines 93-149) or full build_tag_idf() (lines 75-89)
--
-- Setup (lines 513-514): ensure_subscription() called at entry
-- Vault index + generation retrieved via get_vault_index() (lines 516-517)
-- Max remaining score pre-computed for early pruning (lines 576-583)
--
-- Main scoring loop (lines 585-685):
--   for rel_path, entry in pairs(vi.files) do
--     skip self (line 589)
--     tag_score = score_tags(source, candidate, idf, total) (line 595, lines 158-172)
--     EARLY PRUNING: if tag_score + max_remaining < heap.min_score(), skip (line 602)
--     data = get_note_data(entry, vi, resolve) (line 608, LRU cached, lines 408-415)
--     fm_score = score_frontmatter(fm_a, fm_b) (line 623, lines 211-223)
--       FM_FIELDS (lines 179-184): type(1.0), project(1.5), domain(1.0), status(0.3)
--     colink_score = score_colinks(out_a, out_b, count_a, count_b) (line 634, lines 236-250)
--     link_score = score_link_proximity(rel_a, neighbors_a, rel_b, neighbors_b) (line 646, lines 264-285)
--     temporal_score = score_temporal(ctime_a, mtime_a, ctime_b, mtime_b) (line 660, lines 328-333)
--       temporal_decay() (lines 294-300): 1.0 (<1d), 0.7 (<3d), 0.4 (<7d), 0.2 (<30d), 0.0 (≥30d)
--     heap.insert(total_score, result) (line 685)
--   end
--   return heap:results() (line 687, sorted descending)
--   Result cached with deps set for invalidation (lines 696-704)
--
-- create_top_k(k) (lines 444-504): Fixed-size min-heap, O(log K) insert, early pruning via min_score()
-- get_weights() (lines 423-435): Merged config + defaults
--   {tags=3, frontmatter=2, colink=2.5, link_1hop=5, link_2hop=2, temporal=1, max_2hop_bridges=5}
-- build_note_data() (lines 345-400): tags, outlink_targets, inlink_sources, neighbors, fm_fields, ctime/mtime
-- setup() (lines 891-933): registers cache with engine, sets up subscription
```

Add async version:

```lua
--- Async connection scoring with yielding.
--- @param source_rel_path string
--- @param opts table { max_results, callback, cancelled }
function M.compute_async(source_rel_path, opts)
  opts = opts or {}
  local batch_size = config.connections.score_batch_size or 200
  local max_results = opts.max_results or config.connections.max_results

  return yield_iter.run_async(function()
    local vi = vault_index.current()
    if not vi then return {} end

    local source_entry = vi:get_entry(source_rel_path)
    if not source_entry then return {} end

    -- Pre-compute IDF and source note data (cheap, do before yielding loop)
    -- Matches sync compute() setup at lines 546-585
    local weights = get_weights()
    local resolve = filter_utils.create_memoized_resolver(vi)
    -- IDF: use incremental update if previous exists, else full rebuild
    local idf, total = update_tag_idf_incremental(vi.files)
    if not idf then idf, total = build_tag_idf(vi.files) end
    local source_data = build_note_data(source_entry, vi, resolve)
    local heap = create_top_k(max_results)

    yield_iter.for_each_yielding(
      vi.files,
      batch_size,
      function(rel_path, entry)
        if rel_path == source_rel_path then return end

        -- Tag scoring first for early pruning (matches line 595-602)
        local tag_score = score_tags(source_data.tags, entry.tag_set, idf, total)
        -- Early pruning: skip if tag_score + max_remaining < heap minimum
        local max_remaining = weights.frontmatter + weights.colink
            + math.max(weights.link_1hop, weights.link_2hop) + weights.temporal
        if tag_score * weights.tags + max_remaining < heap.min_score() then return end

        -- Full note data (LRU cached via get_note_data, lines 408-415)
        local data = get_note_data(entry, vi, resolve)

        local fm_score = score_frontmatter(source_data.fm_fields, data.fm_fields)
        local colink_score = score_colinks(source_data.outlink_targets, data.outlink_targets,
          source_data.outlink_count, data.outlink_count)
        local link_score = score_link_proximity(source_rel_path, source_data.neighbors,
          rel_path, data.neighbors, weights)
        local temporal_score = score_temporal(source_data.ctime, source_data.mtime,
          data.ctime, data.mtime)

        local total_score = tag_score * weights.tags
          + fm_score * weights.frontmatter
          + colink_score * weights.colink
          + link_score  -- already weighted by link_1hop/link_2hop
          + temporal_score * weights.temporal

        heap.insert(total_score, {
          rel_path = rel_path,
          name = entry.name,
          score = total_score,
        })
      end,
      { cancelled = opts.cancelled }
    )

    return heap:results()
  end, opts.callback)
end
```

### 4. Apply to BFS traversal

Current synchronous architecture:
```lua
-- bfs.lua (127 lines): M.traverse(opts) — queue-based BFS (lines 29-124)
--   @class BfsOpts (lines 7-19):
--     index, frontier[], max_depth, max_nodes, resolve, visited,
--     initial_count?, process_outlinks?, process_inlinks?,
--     on_discover(rel, entry, depth, "outlink"|"inlink", parent) → table|true|nil
--   Queue: array with head/tail pointers (lines 40-45)
--     dequeue: queue[head] = nil; head = head + 1 (allows GC)
--   Core loop (lines 47-109)
--   Outlinks: cur_entry.outlinks → resolve(link.path or "") → target_rel (lines 56-79)
--   Inlinks: idx:get_inlinks(current.rel) → link.path .. ".md" (lines 83-106)
--   on_discover returns: true (accept default), table (merge extra fields), nil (reject)
--   Early termination: node_count >= max_nodes → break
--   ::skip:: goto for depth check AND missing entry
--   Collects remaining frontier items (lines 111-117)
--   @class BfsResult (lines 21-24): { node_count, truncated, frontier[] }
--
-- graph_filter/traversal.lua (230 lines): M.collect_at_depth(center_path, depth, predicate, state_hash)
--   (lines 132-221)
--   M.invalidate_bfs_cache() (lines 34-36)
--   @class BfsCacheEntry (lines 18-28):
--     gen, state_hash, depth, forward_like[], backlink_like[], all_nodes[],
--     visited, frontier[], truncated, resolve
--   LRU cache: _bfs_cache = lru.new(config.cache.bfs_traversal_max) (line 30)
--   Validates index readiness (lines 136-139)
--   Initializes center via filter_utils.bfs_init() (line 141)
--   Three paths:
--     1. Exact cache hit: depth == cached.depth, gen valid, state matches (lines 147-157)
--     2. Incremental extension: cached.depth < depth AND not truncated (lines 158-188)
--        → copies visited/results from cache, calls bfs_expand() from cached frontier
--     3. Full rebuild: cache miss, depth decreased, gen changed, filters changed (lines 191-216)
--   bfs_expand() helper (lines 58-99): calls bfs.traverse() with direction tracking
--     on_discover callback (lines 69-87) classifies nodes as "forward" vs "backlink"
--     Filters frontier to only target_depth items (lines 90-96)
--     Direction: outlinks from center="forward", inlinks="backlink", transitive=inherit parent
--   copy_nodes() (lines 104-110) and copy_visited() (lines 113-117) for safe cache storage
--   M.bfs_cache_size() (lines 225-227)
--
-- search_filter/graph_traversal.lua (120 lines): collect_reachable() (lines 35-60)
--   Caps depth to config.search.graph_max_depth (lines 36-37)
--   Initializes center via filter_utils.bfs_init() (line 41)
--   Simpler BFS for search graph: operator — accepts all via on_discover = function() return true end
--   initial_count = 1 (center pre-counted, line 53)
--   Direction controls outlinks/inlinks processing (lines 54-55)
--   resolve_graph_center() (lines 15-26) resolves center spec
--   M.ast_contains_graph() (lines 65-75) recursive AST check for graph: nodes
--   precompute_graph_sets(ast, index, current_path) (lines 83-117)
--     → walks AST, creates graph_id per graph: node, annotates with _graph_id
--     → returns {graph_id → {rel_path → true}}
```

Add async BFS with yielding within the queue processing loop:

```lua
--- Async BFS with yielding during queue processing.
--- Integrates with bfs.lua's queue-based traversal pattern.
function M.traverse_async(opts, async_opts)
  async_opts = async_opts or {}
  local batch_size = config.graph.bfs_batch_size or 100

  return yield_iter.run_async(function()
    local idx = opts.index
    local visited = opts.visited or {}
    local max_nodes = opts.max_nodes or config.graph.max_nodes
    local max_depth = opts.max_depth or config.graph.max_depth
    local resolve = opts.resolve
    local on_discover = opts.on_discover

    local queue = {}
    local head, tail = 1, 0
    local node_count = opts.initial_count or 0

    -- Initialize queue from frontier
    for _, item in ipairs(opts.frontier) do
      tail = tail + 1
      queue[tail] = item
    end

    local batch_count = 0

    while head <= tail and node_count < max_nodes do
      if async_opts.cancelled and async_opts.cancelled() then break end

      local current = queue[head]
      queue[head] = nil  -- Allow GC
      head = head + 1

      if current.d >= max_depth then goto skip end

      -- Process outlinks (inline neighbor discovery, matching bfs.lua pattern)
      if opts.process_outlinks ~= false then
        local cur_entry = idx:get_entry(current.rel)
        if cur_entry then
          for _, link in ipairs(cur_entry.outlinks) do
            local target_rel = resolve(link.path or "")
            if target_rel and not visited[target_rel] then
              local target_entry = idx:get_entry(target_rel)
              if target_entry then
                local extra = on_discover(target_rel, target_entry, current.d + 1, "outlink", current)
                if extra then
                  visited[target_rel] = true
                  node_count = node_count + 1
                  tail = tail + 1
                  local item = { rel = target_rel, d = current.d + 1 }
                  if type(extra) == "table" then
                    for k, v in pairs(extra) do item[k] = v end
                  end
                  queue[tail] = item
                end
              end
            end
          end
        end
      end

      -- Process inlinks (same pattern)
      if opts.process_inlinks ~= false then
        local inlinks = idx:get_inlinks(current.rel)
        for _, link in ipairs(inlinks) do
          local source_rel = link.path .. ".md"
          if not visited[source_rel] then
            local source_entry = idx:get_entry(source_rel)
            if source_entry then
              local extra = on_discover(source_rel, source_entry, current.d + 1, "inlink", current)
              if extra then
                visited[source_rel] = true
                node_count = node_count + 1
                tail = tail + 1
                local item = { rel = source_rel, d = current.d + 1 }
                if type(extra) == "table" then
                  for k, v in pairs(extra) do item[k] = v end
                end
                queue[tail] = item
              end
            end
          end
        end
      end

      ::skip::
      batch_count = batch_count + 1
      if batch_count >= batch_size then
        batch_count = 0
        coroutine.yield()
      end
    end

    local truncated = node_count >= max_nodes and head <= tail
    -- Collect remaining frontier items
    local remaining_frontier = {}
    while head <= tail do
      remaining_frontier[#remaining_frontier + 1] = queue[head]
      queue[head] = nil
      head = head + 1
    end

    return { node_count = node_count, truncated = truncated, frontier = remaining_frontier }
  end, async_opts.callback)
end
```

### 5. Cancellation Pattern for Live Search

**Note:** The search system is split across multiple files:
- `search.lua` — dispatcher module
- `search/live.lua` (197 lines) — live mode (`search_advanced_live` lines 17-134) + `search_in_files` (lines 156-194)
- `search/advanced.lua` (363 lines) — core evaluation (`evaluate_advanced_ast` lines 202-231, `resolve_query` lines 136-184) + `execute_advanced_query` (lines 237-360)
- `search/prompt.lua` — prompt mode UI

An existing cancellation pattern already exists in `search/advanced.lua` (lines 274-277):
```lua
-- _active_search_cancel (line 11) tracks active async search callback
-- Set at lines 274-276 (cleared) and line 282 (nullified)
if _active_search_cancel then
  _active_search_cancel()
  _active_search_cancel = nil
end
search_filter.semaphore_reset()
```

The evaluate_async integration would extend this existing pattern:

```lua
local _current_eval_cancel = nil

local function on_live_search_input(query_text)
  -- Cancel previous evaluation (extends existing _active_search_cancel pattern
  -- in search/advanced.lua lines 274-277)
  if _current_eval_cancel then
    _current_eval_cancel()
  end

  local cancelled = false
  _current_eval_cancel = function()
    cancelled = true
  end

  search_filter.evaluate_async(ast, index, {
    graph_sets = graph_sets,
    restrict_to = restrict_to,
    cancelled = function() return cancelled end,
    callback = function(matches, limit_reached)
      if not cancelled then
        display_results(matches, limit_reached)
      end
      _current_eval_cancel = nil
    end,
  })
end
```

## Configuration

Add to existing config sections in `config.lua`:

```lua
-- Add to M.search (existing section, lines 431-519 of config.lua, file total 846 lines)
M.search.evaluate_batch_size = 500      -- Entries per yield in evaluate_async()

-- Add to M.connections (existing section, lines 283-295 of config.lua)
M.connections.score_batch_size = 200    -- Entries per yield in compute_async()

-- Add to M.graph (existing section, lines 536-568 of config.lua)
M.graph.bfs_batch_size = 100           -- Nodes per yield in async BFS
```

Existing related config values for reference:
- `M.index.batch_size = 20` (config.lua line 372) — files per vim.schedule tick in vault_index_build
- `M.completion.batch_size = 50` (config.lua line 413) — entries per coroutine batch in completion_base
- `M.embed.lazy_batch_size = 5` (config.lua line 94) — embeds per async batch tick
- `M.events.max_batch_size = 32` (config.lua line 843) — force flush at this many pending events

## Zed Reference

### Pattern 1: Modulo-based YIELD_INTERVAL (search)
From `crates/project/src/search.rs` (599 lines, line 359):
```rust
use smol::future::yield_now;
const YIELD_INTERVAL: usize = 20000;

// Text search (lines 381-382)
for (ix, mat) in search.stream_find_iter(rope.bytes_in_range(0..rope.len())).enumerate() {
    if (ix + 1) % YIELD_INTERVAL == 0 {
        yield_now().await;
    }
}
// Also applied to multiline regex (lines 414-415) and chunk-based regex (lines 426-427)
```

### Pattern 2: Counter-reset YIELD_INTERVAL (tighter loops)
From `crates/multi_buffer/src/multi_buffer.rs` (7,959 lines, line 5720):
```rust
const YIELD_INTERVAL: u32 = 100;
let mut accessed_row_counter = 0;

for (row, indent, _) in self.reversed_line_indents(target_row, |_| true) {
    accessed_row_counter += 1;
    if accessed_row_counter == YIELD_INTERVAL {
        accessed_row_counter = 0;
        yield_now().await;
    }
}
// Used in 4 loops within enclosing_indent() (lines 5738, 5754, 5790, 5807)
```

### Pattern 3: Time-bounded batching
From `crates/semantic_index/src/embedding_index.rs` (471 lines, line 286):
```rust
use futures_batch::ChunksTimeoutStreamExt;
let mut chunked_file_batches = pin!(chunked_files.chunks_timeout(512, Duration::from_secs(2)));
while let Some(chunked_files) = chunked_file_batches.next().await {
    // Batches up to 512 items OR waits max 2 seconds
}
```

From `crates/semantic_index/src/summary_index.rs` (700 lines, line 617):
```rust
let mut summaries = pin!(summaries.chunks_timeout(4096, Duration::from_secs(2)));
```

### Pattern 4: Ready-chunks batching (search results)
From `crates/search/src/project_search.rs` (4,286 lines, line 312):
```rust
let mut matches = pin!(search.ready_chunks(1024));
while let Some(results) = matches.next().await {
    for result in results { /* Process batch */ }
}
```

Also in `crates/project/src/project.rs`:
```rust
// Line 2721 — batch 128 buffer ordered messages (MAX_BATCH_SIZE = 128, defined at line 2691)
let mut changes = rx.ready_chunks(MAX_BATCH_SIZE);

// Line 3814 — batch 64 matching buffers before loading and searching
let chunks = matching_buffers_rx.ready_chunks(64);
```

Additional `ready_chunks` locations:
```rust
// crates/assistant_tools/src/edit_agent.rs (line 331) — batch 32 edit events
let mut edits = edits.ready_chunks(32);

// crates/workspace/src/workspace.rs (line 5329) — batch 200 serializable items (CHUNK_SIZE = 200, line 5327)
let mut serializable_items = items_rx.ready_chunks(CHUNK_SIZE);
```

### Pattern 5: Per-item yielding (event/message loops)
From `crates/client/src/client.rs` (line 1050):
```rust
while let Some(message) = incoming.next().await {
    this.handle_message(message, &cx);
    smol::future::yield_now().await;  // Don't starve the main thread
}
```

Also used in 13+ other locations (14 files total, 27 yield_now() calls):
- `editor/src/display_map/wrap_map.rs` (line 507) — per-line yield in text wrapping computation
- `lsp/src/lsp.rs` (lines 521, 557) — per-notification yield AND per-stderr-line yield
- `terminal/src/terminal.rs` (lines 568, 581) — per-event yield in terminal event loop
- `assistant_context/src/assistant_context.rs` (line 2159) — per-chunk yield in completion streaming
- `agent/src/thread.rs` (line 1948) — per-chunk yield in message streaming
- `language/src/buffer.rs` (lines 1684, 1766) — per-row yield in indent suggestion
- `context_server/src/client.rs` (line 288) — per-message yield in context server
- `debugger_tools/src/dap_log.rs` (lines 161, 176) — per-message yield in DAP logging
- `collab/src/rpc.rs` (lines 184, 187, 193) — server-side tokio::task::yield_now() variant

## Expected Impact

| Operation | Before (10K vault) | After | Improvement |
|-----------|-------------------|-------|-------------|
| evaluate() | 30ms blocking | 30ms total, 0ms max block | No UI freeze |
| compute() | 80ms blocking | 80ms total, 0ms max block | No UI freeze |
| BFS depth=3 | 50ms blocking | 50ms total, 0ms max block | No UI freeze |
| Live search perceived | Janky at 10K+ | Smooth | Responsive |

**Total operation time is unchanged** — yielding doesn't make it faster, it makes the
UI responsive during the operation. User sees incremental progress instead of a freeze.

## Testing Strategy

1. Run `evaluate_async` on 10K vault, verify results identical to `evaluate()`
2. Run `compute_async` on 10K vault, verify results identical to `compute()`
3. Type rapidly in live search during large query — verify no UI freeze
4. Cancel mid-evaluation — verify no results displayed, no errors
5. Benchmark: async total time vs sync (should be within 10%)
6. Verify coroutine cleanup: no orphaned coroutines after cancel
7. Verify BFS cache still works correctly with async traversal

## Dependencies

- Independent module (`yield_iter.lua` has no vault-specific requires)
- Benefits from doc 05 (search result limits) — max_results enables early exit
- Benefits from doc 10 (process limiting) — cancelled rg processes don't pile up
- Existing patterns: `vault_index_build.lua` and `completion_base.lua` use `vim.schedule(step)`;
  `engine_watcher.lua` uses `vim.defer_fn(step, 1)` — yield_iter.run_async should use `vim.schedule(step)`
  to match the majority pattern (1ms defer is only needed for watcher's lower priority)

## Risk Assessment

- **Low risk:** Async wrappers don't change evaluation logic, only scheduling
- **Backward compatibility:** Sync `evaluate()`, `compute()`, and `bfs.traverse()` remain
  available for non-interactive paths
- **Edge case:** Cancellation during `match_entry()` — safe because cancellation is checked
  at batch boundaries, not mid-entry
- **BFS cache interaction:** Async BFS must produce identical `frontier` and `visited` sets
  for `traversal.lua`'s incremental depth extension cache to remain valid. Note that
  `traversal.lua` has 3 cache paths (exact hit, incremental extension, full rebuild) —
  async BFS results feed into the same `bfs_expand()` helper (lines 58-99), so cache
  consistency depends on the same visited/frontier sets being produced
- **connections.compute() caching:** The async version bypasses the 3-level cache system
  (result cache, note data LRU, IDF cache). Consider whether async callers need their own
  result caching or if the existing subscriber-based invalidation (on_index_update lines 846-862,
  ensure_subscription lines 866-876, setup lines 891-933) should be extended to cover async results
- **Pre-checks in evaluate_async:** The `extract_pre_checks()` optimization (lines 299-378)
  must be included in the async path to maintain performance parity with sync evaluate()
