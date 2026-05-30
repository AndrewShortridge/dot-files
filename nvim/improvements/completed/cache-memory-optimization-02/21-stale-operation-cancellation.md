# 21. Stale Operation Cancellation

**Priority:** MEDIUM (downgraded from HIGH — most patterns already implemented)
**Phase:** 2 (Refinement — core cancellation already exists)
**Dependencies:** Document 10 (Concurrent Process Limiting) — implemented as `process_semaphore.lua`
**Inspired by:** Zed's file_finder `search_count` pattern (`file_finder.rs:396-417, 858-917`), cancellation flags (`paths.rs:127, 160`), broader cancellation strategies across Zed

---

## Problem

Multiple vault operations can be **superseded** by newer requests before completing. The stale operation continues consuming CPU, memory, and I/O resources to produce results that will be immediately discarded.

### Current State: Distributed Cancellation (Already Implemented)

The codebase already implements cancellation through **distributed patterns** across modules rather than a centralized tracker. Each subsystem has evolved its own cancellation strategy:

| Module | Pattern | Location |
|--------|---------|----------|
| Search (async) | `_active_eval_cancel` fn + `_search_generation` counter | `search/advanced.lua:10-46` |
| Search (sync/live) | fzf_live `query_delay` debounce + incremental filter cache + `filter_utils.is_cache_gen_valid()` | `search/live.lua:37-84, 131` |
| Search (ripgrep) | `process_semaphore.lua` with generation-based queue reset | `search_filter/ripgrep.lua:189-206` |
| Completion | `active_state.cancelled` flag + `build_generation` counter | `completion_base.lua:143-146, 243-252, 257-392` |
| Connections | `yield_iter.for_each_yielding()` with `opts.cancelled` callback | `connections.lua:816-840` |
| Embed | Per-buffer `generation` counter + `cancel_async_render()` | `embed.lua:202-206, 340-345, 386-450` |
| Coroutine infra | `yield_iter.run_async()` with `cancelled()` function check | `yield_iter.lua:111-112` |
| Graph traversal | Closure-based `cancelled` flag with nested async propagation | `search_filter/graph_traversal.lua:174-229` |
| Cache infra | `gen_cache` + `keyed_gen_cache` factories using vault index `_generation` | `gen_cache.lua:25-55, 63-90` |

### Remaining Gaps

1. **Live search (sync path):** `search/live.lua` uses `fzf_live` which calls the provider function synchronously — `search_filter.evaluate()` runs to completion on each invocation without cancellation. The incremental filter cache (lines 58-74) mitigates by reusing previous results when query is a prefix (validated via `filter_utils.is_cache_gen_valid()` at line 64 and `search_filter.is_ast_superset()` at line 70), but non-prefix changes (backspace, mid-query edits) still trigger full re-evaluation.

2. **Connections (sync path):** `connections.compute()` (line 757) iterates all vault files without cancellation checks. Only the async path (`compute_async`, line 816) supports cancellation via `yield_iter`.

3. **No unified monitoring:** Each module tracks cancellation independently with no aggregated stats view across all subsystems.

4. **No cancellation in `search_filter.evaluate()` (sync):** The sync evaluate path (line 435-452) iterates all files with no cancellation check — only the async path (`evaluate_async`, line 467-487) supports it.

### Resource Impact of Remaining Gaps

| Scenario | Impact | Mitigation Already Present |
|----------|--------|---------------------------|
| Fast typing in live search | 200-500ms per full eval | Incremental filter cache, fzf debounce, `is_cache_gen_valid()` |
| Rapid buffer switching (embeds) | 50-100ms per render | Generation check + `cancel_async_render()` |
| Completion during typing | Minimal | `cancel_active()` + debounce + generation |
| Connection during navigation | 100-200ms per sync compute | LRU cache with generation, async path available |

### Zed's Approach

Zed uses **multiple cancellation strategies** depending on the subsystem:

**Strategy A: AtomicBool + Monotonic IDs (File Finder)**

```rust
// crates/file_finder/src/file_finder.rs
pub struct FileFinderDelegate {
    search_count: usize,              // Line 400: monotonic counter
    latest_search_id: usize,          // Line 401: latest accepted result
    latest_search_did_cancel: bool,   // Line 402: cancellation status
    cancel_flag: Arc<AtomicBool>,     // Line 408: shared cancellation flag
}

// spawn_search() — Lines 891-894
let search_id = util::post_inc(&mut self.search_count);
self.cancel_flag.store(true, atomic::Ordering::Relaxed);  // Cancel previous
self.cancel_flag = Arc::new(AtomicBool::new(false));      // Fresh flag for new search
let cancel_flag = self.cancel_flag.clone();

// match_path_sets (crates/fuzzy/src/paths.rs:160): check flag at each candidate set
if cancel_flag.load(atomic::Ordering::Relaxed) { break; }

// Final bail-out after all sets (paths.rs:212): return empty on cancel
if cancel_flag.load(atomic::Ordering::Relaxed) { return Vec::new(); }

// Matcher loop (crates/fuzzy/src/matcher.rs:79): check per candidate
if cancel_flag.load(atomic::Ordering::Relaxed) { break; }

// Result gating (file_finder.rs:927): only accept if search_id >= latest
if search_id >= self.latest_search_id {
    self.latest_search_id = search_id;
    // extend_old_matches: if previous search was cancelled and query unchanged,
    // extend rather than replace (line 934)
    let extend_old_matches = self.latest_search_did_cancel && !query_changed;
}

// Cancellation state tracked for next search (line 1004)
self.latest_search_did_cancel = did_cancel;
```

**Strategy B: ID Tracking with `mem::replace` (Project Search)**

```rust
// crates/search/src/project_search.rs
search_id: usize,                              // Line 187: field declaration
self.search_id += 1;                           // Line 308: increment on new search

// entity_changed handler (Lines 1382-1383):
let prev_search_id = mem::replace(&mut self.search_id, self.entity.read(cx).search_id);
let is_new_search = self.search_id != prev_search_id;
// Used to decide whether to reset editor selections and scroll position
```

**Strategy C: Two-Level Version-Based Cache Invalidation (Inlay Hints)**

```rust
// crates/editor/src/inlay_hint_cache.rs
// Main cache version (line 37):
version: usize,

// Per-excerpt cache version (lines 55-61):
struct CachedExcerptHints {
    version: usize,
    buffer_version: Global,
    buffer_id: BufferId,
    ordered_hints: Vec<InlayId>,
    hints_by_id: HashMap<InlayId, InlayHint>,
}

// New queries carry pre-incremented version (line 407):
let cache_version = self.version + 1;

// Stale result gating (lines 1205-1208):
match query.cache_version.cmp(&cached_excerpt_hints.version) {
    cmp::Ordering::Less => return,       // Stale — discard
    cmp::Ordering::Greater | cmp::Ordering::Equal => {
        cached_excerpt_hints.version = query.cache_version;
    }
}

// Version incremented on inlay changes (line 1296, plus lines 322, 571, 581):
editor.inlay_hint_cache.version += 1;
```

**`post_inc` utility** (`crates/util/src/util.rs:167-171`) — used in 35 files (129 call sites):
```rust
pub fn post_inc<T: From<u8> + AddAssign<T> + Copy>(value: &mut T) -> T {
    let prev = *value;
    *value += T::from(1);
    prev
}
```

Key principles:
- **Monotonic IDs** ensure only the latest operation's results are used
- **Cancellation flags** allow in-progress work to exit early (checked per iteration/batch)
- **Multiple strategies coexist** — the right approach depends on the subsystem
- **Relaxed ordering** is sufficient for cancel flags (no data synchronization needed)
- **Bidirectional tracking** — Zed remembers if a search was cancelled to extend (not replace) results on unchanged queries

---

## Current Implementation Details

### 1. Search System (Most Sophisticated)

**Async path — `search/advanced.lua:10-46`:**
```lua
local _active_eval_cancel = nil           -- Line 11
local _search_generation = 0              -- Line 16

local function eval_async_cancellable(metadata_ast, idx, graph_sets, restrict_to, callback)
  local cancelled = false
  if _active_eval_cancel then _active_eval_cancel() end  -- Line 27: Cancel previous
  _search_generation = _search_generation + 1            -- Line 28
  local my_gen = _search_generation                      -- Line 29
  _active_eval_cancel = function() cancelled = true end  -- Line 30

  search_filter.evaluate_async(metadata_ast, idx, {
    cancelled = function() return cancelled end,          -- Line 35: closure cancel check
    callback = function(matches, limit_reached)
      _active_eval_cancel = nil                           -- Line 37
      if cancelled then return end                        -- Line 40: race guard
      if _search_generation ~= my_gen then return end    -- Line 41: generation guard
      callback(matches, limit_reached)
    end,
  })
  return my_gen
end
```

**Execute query cancellation — `search/advanced.lua:373-378`:**
```lua
if _active_eval_cancel then
  _active_eval_cancel()
  _active_eval_cancel = nil
end
search_filter.semaphore_reset()
```

**Ripgrep subprocess cancellation — `search_filter/ripgrep.lua:189-206`:**
```lua
local function spawn_rg_async(node, file_paths, vault_path, tmpfile, limit_state, on_done)
  local args, process = prepare_rg_call(...)
  local process_obj = nil

  local cancel = semaphore.acquire(get_rg_sem(), function(release)
    process_obj = vim.system(args, { text = true }, function(result)
      release()
      on_done(process(result))
    end)
  end)

  return function()
    if process_obj then process_obj:kill() end  -- Line 202: Kill running process
    cancel()                                     -- Line 204: Cancel semaphore queue
  end
end
```

**Ripgrep async binary dispatch — `search_filter/ripgrep.lua:355-385`:**
- AND: Sequential — left dispatched first, right restricted to left's matched files
- OR: Parallel — both sides dispatched concurrently, combined on completion
- Individual `spawn_rg_async` cancel functions not aggregated at the `async_binary` level — relies on semaphore reset for bulk cancellation

**Semaphore reset — `ripgrep.lua:532-534`:**
```lua
function M.semaphore_reset()
  semaphore.reset(get_rg_sem())
end
```

**Semaphore queue reset — `process_semaphore.lua:94-97`:**
```lua
function M.reset(sem)
  sem._generation = sem._generation + 1  -- Invalidate all queued requests
  sem._queue = {}
end
```

**Semaphore acquire with generation gating — `process_semaphore.lua:49-72`:**
```lua
function M.acquire(sem, callback)
  local gen = sem._generation
  -- ... immediate grant if permits available ...
  -- Queue entry captures generation (line 66):
  local entry = { callback = callback, gen = gen }
  table.insert(sem._queue, entry)
  return function() entry.callback = nil end  -- Allow GC of closure
end
```

**Semaphore drain with generation check — `process_semaphore.lua:27-42`:**
```lua
function M._drain_queue(sem)
  while sem._active < sem._max and #sem._queue > 0 do
    local entry = table.remove(sem._queue, 1)
    if entry.callback and entry.gen == sem._generation then  -- Line 30: stale check
      -- ... grant permit ...
    end
  end
end
```
Called in `advanced.execute_advanced_query()` (line 378) on new search.

**Sync evaluate — `search_filter.lua:435-452` (NO cancellation):**
```lua
function M.evaluate(ast, index, graph_sets, restrict_to)
  local files, predicate, max_files = prepare_evaluate(ast, index, graph_sets, restrict_to)
  if not files then return {}, false end

  local matches = {}
  local count = 0
  for rel_path, entry in pairs(files) do
    if predicate(rel_path, entry) then
      matches[rel_path] = entry
      count = count + 1
      if max_files and count >= max_files then
        return matches, true
      end
    end
  end
  return matches, false
end
```

**Async evaluate — `search_filter.lua:467-487` (WITH cancellation):**
```lua
function M.evaluate_async(ast, index, opts)
  opts = opts or {}
  local batch_size = config.search.evaluate_batch_size or 500

  return yield_iter.run_async(function()
    local files, predicate, max_files = prepare_evaluate(
      ast, index, opts.graph_sets, opts.restrict_to)
    if not files then return {}, false end

    local matches, limit_reached = yield_iter.filter_yielding(
      files, batch_size, predicate, {
        cancelled = opts.cancelled,  -- Line 481: cancelled check function
        max_results = max_files,
      }
    )
    return matches, limit_reached
  end, opts.callback)
end
```

**Live search — `search/live.lua:37-134`:**
```lua
-- Line 37-38: Cache state
local _prev_cache = { query = nil, ast = nil, file_set = nil, gen = nil }

-- Lines 40-134: fzf_live provider (synchronous)
fzf.fzf_live(function(args)
  -- Lines 58-74: Incremental filtering cache check
  local restrict_to = nil
  local cur_gen = idx._generation
  if _prev_cache.file_set and _prev_cache.query
    and filter_utils.is_cache_gen_valid(_prev_cache, cur_gen) then  -- Line 64: gen check
    local is_prefix = #query_string > #_prev_cache.query
      and query_string:sub(1, #_prev_cache.query) == _prev_cache.query
    if is_prefix then
      if search_filter.is_ast_superset(_prev_cache.ast, ast) then  -- Line 70: AST check
        restrict_to = _prev_cache.file_set
      end
    end
  end

  -- Lines 76-78: Synchronous evaluation (no async cancellation)
  result, effective_group_mode, metadata_matches = advanced.evaluate_advanced_ast(
    ast, group_mode, idx, source_path, restrict_to)

  -- Lines 80-84: Update cache for next keystroke
  _prev_cache.query = query_string
  _prev_cache.ast = ast
  _prev_cache.file_set = metadata_matches
  _prev_cache.gen = cur_gen

  -- Line 131: query_delay = debounce (config.search.live_debounce_ms)
end)
```

### 2. Completion System (Fully Cancellable)

**`completion_base.lua:143-146, 243-392`:**
```lua
local build_generation = 0                    -- Line 143: internal invalidation counter
-- Active async build state (for cancellation)
local active_state = nil                      -- Line 145-146: { cancelled: bool, timer: uv_timer|nil }

local function cancel_active()                -- Lines 243-252
  if active_state then
    active_state.cancelled = true
    if active_state.timer then
      cleanup.close_timer(active_state.timer)
      active_state.timer = nil
    end
    active_state = nil
  end
end

local function build_items_async(callback)    -- Lines 257-392
  cancel_active()  -- Cancel any previous build

  local state = { cancelled = false, timer = nil }
  active_state = state
  local gen = build_generation

  state.timer = cleanup.debounce(state.timer, debounce_ms, function()
    state.timer = nil
    if state.cancelled or gen ~= build_generation then return end
    -- Lines 328-389: Coroutine path via yield_iter.run_async()
    -- Cancellation check at lines 369-375:
    --   function() return state.cancelled or gen ~= build_generation end
  end)
end
```

Cancellation checks: `state.cancelled` flag + `build_generation` counter, verified at each coroutine step via `yield_iter` `opts.cancelled()` callback (lines 369-375).

### 3. Connections Module (Async Only)

**Sync path — `connections.lua:757-804` (NO cancellation):**
```lua
function M.compute(source_rel_path, max_results)
  -- Lines 761-771: Cache check with TTL and generation validation
  -- Lines 773-784: Synchronous scoring loop over all files (no yielding, no cancellation)
  -- Lines 795-801: Cache storage with dependency tracking
  -- Returns sorted top-K results via min-heap
end
```

**Async path — `connections.lua:816-840` (WITH cancellation):**
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

    yield_iter.for_each_yielding(
      s.files, batch_size,
      function(rel_path, entry)
        score_candidate(rel_path, entry, source_rel_path, s.source_data,
          s.weights, s.idf, s.total_pages, s.max_remaining, top, s.vi, s.resolve)
      end,
      { cancelled = opts.cancelled }  -- Line 835: cancellation check
    )

    return top.results()
  end, opts.callback)
end
```

### 4. Embed Module (Generation-Based)

**`embed.lua:202-206, 340-345, 351-382, 386-450`:**
```lua
local function cancel_async_render(bufnr)          -- Lines 202-206
  local ds = state._embed_descriptors[bufnr]
  state.cleanup_async_timer(ds, ds and ds.async_timer)
  cleanup.close_timer_in(state._scroll_timers, bufnr)
end

local function check_generation(bufnr, generation)  -- Lines 340-345
  if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  local ds = state._embed_descriptors[bufnr]
  if not ds or ds.generation ~= generation then return nil end
  return ds
end

local function render_remaining_async(bufnr, generation, ctx)  -- Lines 351-382
  local ds = state._embed_descriptors[bufnr]
  if not ds then return end
  local batch_size = config.embed.lazy_batch_size
  local cursor = 1

  ds.async_timer = cleanup.repeating(ds.async_timer, 16, 16, function()
    local timer = ds.async_timer
    local current_ds = check_generation(bufnr, generation)  -- Line 360: stale check
    if not current_ds then
      state.cleanup_async_timer(state._embed_descriptors[bufnr], timer)
      return
    end
    -- Render batch_size embeds per 16ms tick, advance cursor
    -- Stop when cursor > #list
  end)
end

function M.render_embeds(opts)                       -- Lines 386-450
  cancel_async_render(bufnr)                         -- Line 396: cancel in-flight
  -- Clear existing extmarks/placements
  -- Build descriptors, increment generation (line 411):
  --   generation = (old_state and old_state.generation or 0) + 1
  -- Visible-first rendering (lazy mode, line 416) + async batch for remaining
end
```

### 5. Cooperative Yielding Infrastructure

**`yield_iter.lua:18-47` — `for_each_yielding()`:**
```lua
function M.for_each_yielding(items, batch_size, process_fn, opts)
  opts = opts or {}
  local count = 0

  if vim.islist(items) then
    for i, item in ipairs(items) do
      if opts.cancelled and opts.cancelled() then return end  -- Line 24
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
      if opts.cancelled and opts.cancelled() then return end  -- Line 35
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
```

**`yield_iter.lua:58-84` — `filter_yielding()`:**
```lua
function M.filter_yielding(items, batch_size, predicate, opts)
  opts = opts or {}
  local matches = {}
  local match_count = 0
  local count = 0
  local max_results = opts.max_results or math.huge

  for k, v in pairs(items) do
    if opts.cancelled and opts.cancelled() then break end  -- Line 66
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
```

**`yield_iter.lua:98-138` — `run_async()`:**
```lua
function M.run_async(fn, callback_or_opts)
  local opts
  if type(callback_or_opts) == "table" then
    opts = callback_or_opts
  else
    opts = { callback = callback_or_opts }
  end

  local co = coroutine.create(fn)
  local cancelled = false

  local function step()
    if cancelled then return end                     -- Line 111
    if opts.cancelled and opts.cancelled() then return end  -- Line 112
    local ok, val = coroutine.resume(co)
    if not ok then
      if opts.on_error then
        opts.on_error(tostring(val))
      else
        log:error("coroutine error: %s", tostring(val))
      end
      return
    end
    if coroutine.status(co) == "dead" then
      if opts.callback then opts.callback(val) end
    else
      vim.schedule(step)  -- Reschedule
    end
  end

  if opts.immediate then
    step()
  else
    vim.schedule(step)
  end

  return function() cancelled = true end             -- Line 136
end
```

### 6. Generation-Based Cache Infrastructure

**`gen_cache.lua:25-55` — `gen_cache()` factory:**
```lua
function M.gen_cache(build_fn, opts)
  local cached_gen = 0
  local cached_key = nil
  local cached_value = nil
  local key_fn = opts and opts.key_fn

  return {
    get = function(...)
      local idx = current_index()
      if not idx then return nil end
      local gen = idx._generation or 0
      local key = key_fn and key_fn(...) or nil
      if cached_value ~= nil and cached_gen == gen and (not key_fn or cached_key == key) then
        return cached_value  -- Cache hit
      end
      cached_value = build_fn(idx, ...)
      cached_gen = gen
      cached_key = key
      return cached_value
    end,
    invalidate = function()
      cached_value = nil
      cached_gen = 0
      cached_key = nil
    end,
  }
end
```

**`gen_cache.lua:63-90` — `keyed_gen_cache()` factory:**
```lua
function M.keyed_gen_cache(build_fn)
  local cached_gen = 0
  local entries = {}

  return {
    get = function(key, ...)
      local idx = current_index()
      if not idx then return nil end
      local gen = idx._generation or 0
      if gen ~= cached_gen then
        entries = {}       -- Flush all entries on generation change
        cached_gen = gen
      end
      if entries[key] ~= nil then return entries[key] end
      local value = build_fn(idx, key, ...)
      entries[key] = value
      return value
    end,
    invalidate = function()
      entries = {}
      cached_gen = 0
    end,
  }
end
```

### 7. Graph Traversal (Sequential Async with Nested Cancellation)

**`search_filter/graph_traversal.lua:174-229`:**
```lua
function M.precompute_graph_sets_async(ast, index, current_path, callback)
  local sets = {}
  local cancelled = false                          -- Line 176: closure flag

  local graph_nodes = collect_graph_nodes_from_ast(ast)

  if #graph_nodes == 0 then
    callback(sets)
    return function() cancelled = true end
  end

  local current_cancel                             -- Line 186: holds current BFS cancel fn
  local function process_next(i)
    if cancelled or i > #graph_nodes then           -- Line 188: cancel check
      callback(sets)
      return
    end

    local node = graph_nodes[i]
    local graph_id = string.format("graph_%s_%d_%s",
      node.center, node.depth, node.direction)
    node._graph_id = graph_id

    if sets[graph_id] then
      process_next(i + 1)
      return
    end

    local center_abs = resolve_graph_center(node.center, current_path, index)
    if not center_abs then
      sets[graph_id] = {}
      process_next(i + 1)
      return
    end

    current_cancel = collect_reachable_async(index, center_abs, node.depth, node.direction,
      function(reachable, truncated)
        if cancelled then return end                -- Line 213: race guard
        sets[graph_id] = reachable
        if truncated then
          local max_nodes_val = config.graph.max_nodes
          notify.info(string.format("search graph '%s' truncated at %d nodes", graph_id, max_nodes_val))
        end
        process_next(i + 1)
      end)
  end

  process_next(1)

  return function()
    cancelled = true                                -- Line 226: set flag
    if current_cancel then current_cancel() end    -- Line 227: cancel current BFS
  end
end
```

---

## Remaining Opportunities — Status Update (2026-03-22)

### 1. Sync `evaluate()` Cancellation — **Implemented (Option A)**

`search_filter.evaluate()` now accepts an optional 5th `cancelled` parameter (function returning bool). Checks every 200 items; returns `nil, "cancelled"` on abort.

**Note:** The 3 call sites in `search/advanced.lua` (lines 193, 232, 259) do **not** pass a `cancelled` argument because they are invoked from `fzf_live`'s synchronous provider, which has no external cancellation signal. The parameter exists for future async callers. Switching live search to the async evaluate path (Option B) remains architecturally disruptive since `fzf_live` expects synchronous provider results.

### 2. Sync `connections.compute()` Cancellation — **Implemented**

`connections.compute()` now accepts an optional 3rd `opts_cancel` parameter (function returning bool). Checks every 200 items; returns `nil, "cancelled"` on abort.

**Note:** The only sync caller (`debug_pair()`) does not pass a cancel function, which is correct — debug inspection should run to completion. Interactive use goes through `compute_async()` which already supports cancellation.

### 3. Dead Code Cleanup — **Done**

- Removed unused `on_yield` and `on_complete` callback parameters from `yield_iter.for_each_yielding()`. No callers ever passed these.

### 4. Unified Operation Stats Command (Low Priority) — **Not Implemented**

Aggregate cancellation statistics from all subsystems. Not pursued — each module already exposes its own debug commands (`:VaultCompletionDebug`, `:VaultEmbedDebug`, semaphore stats).

### 5. Centralized Operation Tracker — **Not Recommended (unchanged)**

The distributed cancellation patterns work well. Each module's cancellation is tailored to its execution model. No centralized tracker needed.

---

## Interaction with Existing Modules

| Module | Role | Status |
|--------|------|--------|
| `process_semaphore.lua` | Limits concurrent rg processes (max 3), generation-based queue reset + drain gating | **Implemented** |
| `yield_iter.lua` | Cooperative yielding with `cancelled()` checks at batch boundaries (`for_each_yielding` + `filter_yielding` + `run_async`) | **Implemented** |
| `search_filter.lua` (async) | `evaluate_async()` with `filter_yielding()` cancellation, configurable `evaluate_batch_size` | **Implemented** |
| `search_filter.lua` (sync) | `evaluate()` — optional `cancelled` param (5th arg), checked every 200 items | **Implemented** |
| `search/advanced.lua` | `_active_eval_cancel` + `_search_generation` double-check + semaphore reset | **Implemented** |
| `search_filter/ripgrep.lua` | `process_obj:kill()` + semaphore cancel on stale searches + `semaphore_reset()` export | **Implemented** |
| `search_filter/graph_traversal.lua` | Closure-based `cancelled` flag with sequential BFS + `current_cancel` propagation | **Implemented** |
| `completion_base.lua` | `active_state.cancelled` + `build_generation` + debounce timer | **Implemented** |
| `connections.lua` (async) | `compute_async()` with `yield_iter` cancellation | **Implemented** |
| `connections.lua` (sync) | `compute()` — optional `opts_cancel` param (3rd arg), checked every 200 items | **Implemented** |
| `embed.lua` | Per-buffer generation + `cancel_async_render()` + lazy rendering (16ms tick) | **Implemented** |
| `gen_cache.lua` | Generation-based cache invalidation factories (`gen_cache` + `keyed_gen_cache`) | **Implemented** |

---

## Configuration (Current)

Cancellation-related configuration already exists across modules:

```lua
-- config.lua (current values)
M.search = {
  live_debounce_ms = 150,          -- fzf_live query_delay (line 442)
  max_concurrent_rg = 3,          -- process_semaphore max permits (line 524)
  rg_queue_max = 5,               -- max queued rg requests (line 525)
  max_result_files = 5000,        -- metadata eval cap (early exit) (line 517)
  max_result_lines = 10000,       -- ripgrep output cap (line 518)
  max_matches_per_file = 100,     -- rg --max-count (line 519)
  max_files_from = 500,           -- metadata filter output cap (line 448)
  evaluate_batch_size = 500,      -- entries per yield in evaluate_async (line 528)
}

M.completion = {
  debounce_ms = 250,              -- timer before build starts (line 415)
  batch_size = 50,                -- items per coroutine yield (line 420)
  index_build_timeout_secs = 30,  -- suppress rebuilds during index build (line 424)
  max_items = 10000,              -- item count cap (line 428)
  intern_descriptions = true,     -- memory optimization (line 432)
}

M.connections = {
  score_batch_size = 200,         -- entries per yield in compute_async (line 286)
  cache_ttl = 60,                 -- seconds before cached scores expire (line 284)
  max_results = 30,               -- max related notes (line 285)
}

M.embed = {
  render_delay_ms = 150,          -- BufReadPost defer delay (line 90)
  lazy = true,                    -- visible-first rendering (line 93)
  lazy_batch_size = 5,            -- embeds per async tick (line 94)
  lazy_scroll_debounce_ms = 80,   -- WinScrolled debounce (line 95)
  sync = {
    enabled = true,               -- auto-sync embeds on buffer changes
    debounce_ms = 300,            -- sync debounce
    self_debounce_ms = 500,       -- self-reference sync debounce
  },
}
```

No additional `M.cancellation` config section is needed — each module's existing config covers its cancellation behavior.

---

## Validation

1. **Cancellation coverage:** Verify `_active_eval_cancel` fires correctly on rapid prompt-mode searches
2. **Ripgrep process cleanup:** Confirm `process_obj:kill()` executes on search supersession via `semaphore.reset()`
3. **Completion cancellation:** Verify `cancel_active()` stops in-flight coroutine builds
4. **Embed generation check:** Rapid `BufEnter` events — confirm only latest buffer's embeds render
5. **Memory test:** Verify cancelled operations' intermediate tables are GC-eligible
6. **yield_iter regression:** Verify `for_each_yielding` still works after removing `on_yield`/`on_complete` parameters

---

## Realized Savings (All Gaps Filled)

The distributed cancellation now provides complete coverage:
- **Search (async/prompt mode):** Previous search cancelled via `_active_eval_cancel`, rg processes killed, semaphore queue flushed
- **Search (sync evaluate):** Optional `cancelled` param available for callers that can signal cancellation
- **Completion:** Previous build cancelled via `cancel_active()`, debounce prevents redundant builds
- **Connections (async):** Cooperative cancellation via `yield_iter` at batch boundaries
- **Connections (sync):** Optional `opts_cancel` param available for callers that can signal cancellation
- **Embeds:** Generation-based staleness prevents stale renders, `cancel_async_render()` stops timers
- **Ripgrep:** Process killing + semaphore generation reset drops queued work
- **Cache infra:** `gen_cache` and `keyed_gen_cache` auto-invalidate on vault index generation change

**Remaining architectural limitation:** Live search (`fzf_live`) uses a synchronous provider function, so the sync evaluate's `cancelled` parameter cannot be wired up without switching to async (Option B). The debounce + incremental filter cache mitigate this effectively.
