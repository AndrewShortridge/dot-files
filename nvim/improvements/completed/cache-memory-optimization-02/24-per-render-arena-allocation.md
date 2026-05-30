# 24. Per-Render Arena Allocation

**Priority:** MEDIUM
**Phase:** 2 (Scalability)
**Dependencies:** None (standalone infrastructure; complements the already-implemented `table_pool.lua`)
**Inspired by:** Zed's bump arena allocator (`crates/gpui/src/arena.rs`), per-frame arena in `window.rs:209-211`, `ArenaClearNeeded` lifecycle (`window.rs:213-224`)

---

## Zed's Approach

Zed allocates UI element data from a per-frame **bump arena** — a large pre-allocated memory region (configurable chunk size, 1 MB default) that hands out addresses sequentially with zero per-object overhead:

```rust
// window.rs:209-211 — thread-local arena, cleared each frame
thread_local! {
    pub(crate) static ELEMENT_ARENA: RefCell<Arena> = RefCell::new(Arena::new(1024 * 1024));
}

// arena.rs:117-173 — Allocation: O(1) bump pointer advance, #[inline(always)]
let element = ELEMENT_ARENA.with_borrow_mut(|arena| arena.alloc(|| Element { ... }));

// window.rs:213-224 — ArenaClearNeeded (#[must_use]) returned from Window::draw()
// draw() at window.rs:1837-1903 returns ArenaClearNeeded
// Cleared after window.present() to reduce latency (window.rs:1026-1029)
arena_clear_needed.clear();
```

Key design elements:

1. **Scope-based lifecycle:** All allocations within a frame share one lifetime — no individual deallocation
2. **Arena struct:** Contains `chunks: Vec<Chunk>`, `elements: Vec<ArenaElement>` (drop function registry), `valid: Rc<Cell<bool>>`, `current_chunk_index`, `chunk_size` (arena.rs:77-83). `ArenaElement` stores `value: *mut u8` and `drop: unsafe fn(*mut u8)` (arena.rs:9-12)
3. **Validity tracking:** `Rc<Cell<bool>>` flag; `Arena::clear()` sets old flag to false and creates new one; `ArenaBox<T>` validates via `validate()` (`#[track_caller]`) on every `Deref`/`DerefMut` (arena.rs:190-196)
4. **Bulk deallocation:** `Arena::clear()` (arena.rs:107-115) resets chunk bump pointers up to `current_chunk_index`, drops all registered elements via `elements.clear()`, but does NOT deallocate chunks — reuses them. New `Rc<Cell<bool>>` invalidates all existing `ArenaBox` references
5. **Use-after-clear detection:** All builds panic on accessing an `ArenaBox` whose arena has been cleared: `"attempted to dereference an ArenaRef after its Arena was cleared"` (arena.rs:194)
6. **Multi-chunk growth:** Arena grows by allocating new chunks of same size when current is full (arena.rs:141-149), logs `"increased element arena capacity to {}kb"`
7. **Type-erasing map:** `ArenaBox::map()` (arena.rs:182-188) converts `ArenaBox<T>` to `ArenaBox<U>` while preserving validity token — used for `AnyElement` trait object wrapping
8. **Element allocation:** `AnyElement` wraps `ArenaBox<dyn ElementObject>` (element.rs:574), allocated via `ELEMENT_ARENA.with_borrow_mut(|arena| arena.alloc(|| Drawable::new(element))).map(|e| e as &mut dyn ElementObject)` (element.rs:576-586)
9. **Chunk alignment:** `Chunk::allocate()` (arena.rs:58-70) uses `align_offset()` for runtime alignment; panics if single element exceeds chunk size (arena.rs:154-158)

This is fundamentally different from object pooling (`table_pool.lua`). Pooling reuses individual objects with explicit acquire/release. Arena allocation manages objects **in bulk by scope** — everything allocated within a render pass is freed together when the pass ends.

---

## Problem

The vault plugin creates many **short-lived, scope-aligned tables** during render cycles. These tables share a common lifecycle — created at the start of an operation, consumed during it, discarded at the end — but Lua's GC treats each one as an independent object requiring individual tracking and collection.

### Current State: Existing Optimizations Already in Place

Several modules already use `table_pool.lua` (Doc 20, fully implemented) for longer-lived reusable objects:

| Pool | Module | Config Key | Size | Purpose |
|------|--------|------------|------|---------|
| `embed_descriptor` | embed.lua (lines 133-142) | `config.pools.embed_descriptor` | 50 | Embed metadata (lnum, col, inner, is_image, etc.) |
| `connection_breakdown` | connections.lua (line 54) | `config.pools.connection_breakdown` | 200 | Per-candidate score breakdown (tags, fm, colink, link, temporal) |
| `connection_result` | connections.lua (line 63) | `config.pools.connection_result` | 200 | Result items (rel_path, name, score, reasons, breakdown) |
| `completion_item` | completion_base.lua (line 34) | `config.pools.completion_item` | 1000 | Blink.cmp completion items |

Additionally, `string_intern.lua` provides 5 interning pools (tags, fm keys/values, folders, lowercase), and `lru_cache.lua` provides both count-based and memory-weighted caching (file content, section cache, connections).

**What remains unoptimized:** ephemeral intermediates created and discarded *within* a single pass — these are too short-lived for `table_pool` (no natural acquire/release boundary) but too numerous to ignore.

### Scope-Aligned Allocation Hotspots

| Module | Operation | Tables per Cycle | Lifecycle |
|--------|-----------|-----------------|-----------|
| embed.lua | `render_embeds(opts)` (line 386) | ~10 virt_lines arrays + ~10 visited sets/lists per note embed + `seen` set + `parts` array | Single render pass |
| highlight_coordinator.lua | `make_coordinated_update()` (line 151) via `run_all()` (line 242) | ~200 extmark position tables per 500-line viewport | Single coordinated scan |
| search_filter.lua | `evaluate(ast, index, graph_sets, restrict_to, cancelled)` (line 435) | FilterContext + bloom_pre_checked + memoized resolver cache | Single query evaluation |
| connections.lua | `compute(source_rel_path, max_results, opts_cancel)` (line 758) | Top-K heap entries + note_data build tables per candidate | Single scoring pass |
| graph_filter/traversal.lua | `collect_at_depth_async()` (line 267) via bfs.lua | Queue items + visited copies + frontier arrays + accumulator copies | Single BFS traversal |

**Note:** The table counts in the original document were overestimated for some modules. embed.lua descriptors are already pooled via `_desc_pool`, connections.lua breakdowns and results are already pooled via `_breakdown_pool`/`_result_pool`, and search_filter.lua caches its FilterContext across entries (not per-entry). The remaining arena targets are the ephemeral tables these modules still create fresh each pass.

**During rapid scrolling:** Highlight rescans trigger every debounce interval (200ms viewport, 30ms full — configured in `highlight_coordinator.schedule()`, line 229-237), creating extmark-related tables that GC must track. The `link_scan.lua` code exclusion builder (line 31) caches per changedtick, but the highlight process functions still create position arrays fresh each scan.

**Additional ephemeral sources not in original doc:**
- `footnotes.lua:parse_all_footnotes()` (line 108-147): Creates `map{}` + per-footnote record tables `{ refs, def_lnum, def_content, def_end_lnum }`
- `footnotes.lua:render_footnotes()` (line 358-463): Creates `virt_lines = {}` per footnote reference
- `link_scan.lua:build_code_exclusion()` (line 31-107, on cache miss): Creates `ranges{}`, `row_set{}`, `boundary_rows{}` — cached after build
- `link_scan.lua:scan_buffer_names()` (line 286-427): Creates `exclude_set{}`, `multi_words{}`, `single_set{}`, `occupied_cols{}`, `matches{}`

### Why This Differs from Table Pooling (`table_pool.lua`)

| Aspect | `table_pool.lua` (Implemented) | Arena Allocation (This Doc) |
|--------|-------------------------------|---------------------------|
| Granularity | Individual `acquire()`/`release()`/`release_batch()` per table | Bulk lifecycle — all tables in scope freed together |
| Return mechanism | Caller must explicitly release (or use `M.with()` RAII helper) | Caller does nothing — `end_scope` frees everything |
| Mental model | Borrow a book, return when done | Whiteboard session — erase the whole board at once |
| Best for | Objects reused across operations (descriptors, results, completion items) | Short-lived objects confined to a single operation |
| GC interaction | Tables never enter GC (recycled) | Tables never enter GC (bulk-cleared) |
| Forgotten release | Table leaks back to GC (graceful) | Impossible — scope end handles it |
| Current users | embed.lua, connections.lua, completion_base.lua (4 pools) | None yet |

`table_pool.lua`'s pooling is ideal for objects like completion items and embed descriptors that are created in one operation and consumed in another. Arena allocation is ideal for tables that exist only within a single render/evaluate/build pass.

---

## Solution

Create a `render_arena.lua` module providing scope-based bulk table allocation. Tables are drawn from a pre-allocated pool during a scope, and all returned to the pool in one operation when the scope ends.

### Core Arena Implementation

```lua
-- render_arena.lua

local M = {}

-- Pre-allocated pool of empty tables
local _pool = {}
local _pool_size = 0

-- Active scopes: scope_id → { tables = {}, valid = true }
local _scopes = {}
local _next_scope_id = 0

--- Pre-populate the pool with empty tables.
--- Called once at module load and can be called to grow the pool.
--- @param count integer Number of tables to pre-allocate
function M.warm(count)
  for _ = 1, count do
    _pool_size = _pool_size + 1
    _pool[_pool_size] = {}
  end
end

--- Begin a new allocation scope.
--- All tables allocated within this scope share its lifetime.
--- @return integer scope_id Handle for this scope
function M.begin_scope()
  _next_scope_id = _next_scope_id + 1
  local id = _next_scope_id
  _scopes[id] = {
    tables = {},      -- Tables allocated in this scope
    count = 0,        -- Number of allocated tables
    valid = true,     -- Validity flag (false after end_scope)
  }
  return id
end

--- Allocate a table from the arena within a scope.
--- Returns a pre-allocated empty table (no GC allocation).
--- @param scope_id integer Scope handle from begin_scope()
--- @return table tbl Empty table ready for use
function M.alloc_table(scope_id)
  local scope = _scopes[scope_id]
  if not scope or not scope.valid then
    error("render_arena: alloc on invalid/ended scope " .. tostring(scope_id), 2)
  end

  local tbl
  if _pool_size > 0 then
    tbl = _pool[_pool_size]
    _pool[_pool_size] = nil
    _pool_size = _pool_size - 1
  else
    tbl = {}  -- Pool exhausted, fall back to new allocation
  end

  scope.count = scope.count + 1
  scope.tables[scope.count] = tbl
  return tbl
end

--- Allocate a table and pre-size it as an array.
--- Lua tables with pre-declared array portion avoid rehashing.
--- @param scope_id integer Scope handle
--- @param capacity integer Expected number of array elements
--- @return table tbl Empty table (capacity is a hint only in PUC Lua)
function M.alloc_array(scope_id, capacity)
  -- In LuaJIT, table.new(narr, nrec) can pre-size. In PUC Lua, this is
  -- just an alloc_table (capacity hint ignored). Module detects LuaJIT at load.
  return M.alloc_table(scope_id)
end

--- End a scope, returning ALL allocated tables to the pool.
--- After this call, tables from this scope must not be accessed.
--- @param scope_id integer Scope handle from begin_scope()
function M.end_scope(scope_id)
  local scope = _scopes[scope_id]
  if not scope then return end

  scope.valid = false

  -- Bulk-clear all tables and return to pool
  local max_pool = M._config.max_pool_size
  for i = 1, scope.count do
    local tbl = scope.tables[i]
    -- Clear all keys (both hash and array part)
    for k in pairs(tbl) do
      tbl[k] = nil
    end
    -- Return to pool if room
    if _pool_size < max_pool then
      _pool_size = _pool_size + 1
      _pool[_pool_size] = tbl
    end
    scope.tables[i] = nil
  end

  _scopes[scope_id] = nil
end

--- RAII-style scope: begin, call fn(scope_id), end on return/error.
--- Guarantees end_scope runs even if fn errors.
--- @param fn function(scope_id) Body function receiving scope handle
--- @return any ... Return values from fn
function M.with_scope(fn)
  local id = M.begin_scope()
  local ok, result = pcall(fn, id)
  M.end_scope(id)
  if not ok then
    error(result, 2)
  end
  return result
end
```

### Debug Validation Mode

In debug mode, tables track their scope origin and access is checked:

```lua
--- Debug wrapper: returns a proxy that errors on access after scope end.
--- Only active when config.arena.debug_validation = true.
--- Analogous to Zed's ArenaBox validity checking (arena.rs:190-196).
--- @param scope_id integer
--- @param tbl table The real table
--- @return table proxy Proxy with validity checking
local function make_debug_proxy(scope_id, tbl)
  local scope = _scopes[scope_id]
  return setmetatable({}, {
    __index = function(_, k)
      if not scope.valid then
        error(string.format(
          "render_arena: use-after-free on scope %d, key '%s'",
          scope_id, tostring(k)
        ), 2)
      end
      return tbl[k]
    end,
    __newindex = function(_, k, v)
      if not scope.valid then
        error(string.format(
          "render_arena: write-after-free on scope %d, key '%s'",
          scope_id, tostring(k)
        ), 2)
      end
      tbl[k] = v
    end,
    __pairs = function()
      if not scope.valid then
        error("render_arena: iterate-after-free on scope " .. scope_id, 2)
      end
      return pairs(tbl)
    end,
  })
end
```

When `config.arena.debug_validation` is true, `alloc_table()` returns a proxy instead of the raw table. This catches use-after-scope bugs during development, analogous to Zed's `Rc<Cell<bool>>` validity flag on `ArenaBox`.

### LuaJIT Optimization

```lua
-- Detect LuaJIT for table.new pre-sizing
local has_table_new, table_new = pcall(require, "table.new")

if has_table_new then
  function M.alloc_array(scope_id, capacity)
    local scope = _scopes[scope_id]
    if not scope or not scope.valid then
      error("render_arena: alloc on invalid/ended scope", 2)
    end
    -- LuaJIT: create with pre-sized array portion
    local tbl = table_new(capacity, 0)
    scope.count = scope.count + 1
    scope.tables[scope.count] = tbl
    return tbl
  end
end
```

---

## Integration Targets

### 1. embed.lua — `render_embeds(opts)` (line 386)

**Current architecture:** Descriptors are already pooled via `_desc_pool` (table_pool, lines 133-142, acquire at lines 151-154) with `acquire()`/`release_batch()` (release at lines 407-410). The render context (`build_render_ctx`, lines 115-131) is created once per pass. Lazy mode batches rendering via `render_remaining_async()` (lines 351-382) with `cleanup.repeating(timer, 16, 16, callback)` (line 358), batch size from `config.embed.lazy_batch_size`.

**Arena targets:** Per-embed ephemeral tables that are NOT already pooled:

```lua
-- embed.lua — render_single_embed() (line 227)
-- Current: virt_lines arrays and visited tracking created fresh per note embed

-- Per note embed (render_single_embed, lines 260-315):
local virt_lines = {}                              -- ephemeral per-embed (line 263)
local visited_set = { [bufpath] = true }           -- ephemeral per-embed (line 279)
local visited_list = { bufpath }                   -- ephemeral per-embed (line 280)
-- Also per render pass:
local descs = {}                                   -- ephemeral per-render (build_descriptors, line 149)
local seen = {}                                    -- ephemeral per-render (warm_embed_cache, line 172)
local parts = {}                                   -- ephemeral per-render (render_embeds, line 444)

-- embed.lua (with arena)
-- Scope wraps the entire render pass (both sync and lazy phases)
function M.render_embeds(opts)
  local arena_scope = render_arena.begin_scope()
  -- ... existing setup (cancel, clear, init_render_deps, build_descriptors) ...

  -- render_single_embed receives arena_scope in ctx
  ctx.arena_scope = arena_scope

  -- Inside render_single_embed (note embed path, lines 260-315):
  local virt_lines = render_arena.alloc_table(ctx.arena_scope)
  local visited_set = render_arena.alloc_table(ctx.arena_scope)
  visited_set[bufpath] = true
  local visited_list = render_arena.alloc_array(ctx.arena_scope, 8)
  visited_list[1] = bufpath
  -- ... build virt_lines, apply extmarks ...

  -- IMPORTANT: For lazy mode (render_remaining_async), end_scope must be called
  -- in the timer's completion callback (line 378), NOT at the end of render_embeds.
  -- The arena scope spans the full async render lifecycle.
end
```

**Key consideration:** Lazy mode's async timer (line 358, `cleanup.repeating(ds.async_timer, 16, 16, callback)`) means the arena scope must remain open across multiple timer ticks. The timer callback uses a closure-captured `cursor` variable to track progress across ticks. `end_scope` should be called when `cursor > #list` (timer self-cancels via `state.cleanup_async_timer()`) or on generation invalidation (checked via `check_generation()`, lines 340-345). Additional config: `config.embed.lazy_margin` controls viewport pre-render range, `config.embed.lazy_scroll_debounce_ms` controls scroll debounce (line 771).

### 2. Highlight System — `highlight_coordinator.make_coordinated_update()` (line 151)

**Current architecture:** Four highlight modules (highlights.lua, tag_highlights.lua, wikilink_highlights.lua, footnotes.lua) are registered via `highlight_coordinator.register()` (line 216-224) with name, fn, enabled() check, and optional priority. Modules dispatched via `highlight_coordinator.run_all()` (lines 242-254) which iterates priority-sorted `_updaters` list. Each module's scanner is created by `make_coordinated_update()` (lines 151-189) which calls a `process_fn` receiving buffer lines and returning optional position arrays. Debounce handled by `schedule()` (lines 229-237): 30ms full, 200ms viewport. Code exclusion built once per `run_all()` call via `link_scan.build_code_exclusion(bufnr)` (line 244), cached per changedtick (link_scan.lua:31).

**Note:** `wikilink_highlights.lua` does NOT use `make_coordinated_update()` — it has its own `coordinated_update()` (lines 179-193) with manual `apply_range()` (lines 49-173) that directly processes links and applies extmarks. `footnotes.lua` also has its own `coordinated_update()` (lines 469-472) calling `render_footnotes()` (lines 358-463).

**Arena targets:** Per-scan position arrays and intermediate match tables:

```lua
-- highlight_coordinator.lua — make_coordinated_update() (line 151)
-- Current: process_fn creates position arrays that are cached in nav_cache

-- highlights.lua — scan_highlights() (lines 30-56), process_lines() (lines 68-103)
-- Creates positions = {} (line 69), populates { row = row + 1, col = s } per match

-- tag_highlights.lua — scan_tags() (lines 86-132), process_lines() (lines 144-175)
-- Creates positions = {} (line 145), populates { row = row + 1, col = s } per match

-- footnotes.lua — parse_all_footnotes() (lines 108-147)
-- Creates map{} (line 110) + per-footnote { refs={}, def_lnum, def_content={}, def_end_lnum }
-- render_footnotes() (lines 358-463) creates virt_lines = {} (line 401) per reference

-- With arena: wrap run_all() in a scope
function M.run_all(bufnr, opts)
  render_arena.with_scope(function(arena)
    local code_excl = link_scan.build_code_exclusion(bufnr)  -- cached per changedtick (line 244)
    -- Each module's coordinated_update receives arena via opts
    opts.arena = arena
    for _, updater in ipairs(_updaters) do  -- priority-sorted (line 223)
      if updater.enabled() then
        updater.fn(bufnr, code_excl, opts)
      end
    end
  end)
end

-- Inside each process_fn, intermediate match tables use arena:
-- NOTE: positions arrays that get cached in nav_cache MUST NOT use arena
-- (they escape the scope). Only intermediate matching state benefits.
```

**Important nuance:** Position arrays stored in `_nav_cache[bufnr]` (highlights.lua and tag_highlights.lua both use `_nav_cache` at line 11) for `]h`/`[h` navigation escape the scope and must NOT be arena-allocated. Arena is only for intermediate scan state within the process function. Wikilink highlights have NO nav_cache (line 212: empty cache list). Footnote cache (`_fn_cache`, line 20) is changedtick-validated via `hl_coord.cached_value()` (line 152-154) and also escapes scope.

### 3. search_filter.lua — `evaluate()` (line 435)

**Current architecture:** Already heavily optimized with pre-computation:
- `build_filter_context()` (lines 148-221) creates FilterContext with `resolved_dates`, `parsed_tags`, `numeric_values`, `bloom_pre_checked` — all cached per-evaluation, NOT per-entry. Walks AST to pre-resolve dates for DATE_FIELDS, parse tag filters into include/exclude lists, convert numeric values, resolve task date fields
- AST node-level caching: lowered values stored directly on AST nodes (e.g., `node._type_val_lower`)
- `create_memoized_resolver()` (filter_utils.lua:50-62) deduplicates link resolution via `cache = {}` (line 51) closure
- `extract_pre_checks()` (lines 302-384) builds bloom/set pre-checks for fast rejection, gated by `config.prefilter.{enabled, search_pre_checks, precomputed_sets, bloom_filter}`. Creates `checks = {}` (line 306) accumulator. Supports: bloom filter for tag equality, type precomputed set, has:tags/tasks/aliases sets, task existence
- `prepare_evaluate()` (lines 399-433) takes vault index snapshot (respects `config.index.use_snapshots`), builds filter context, extracts pre-checks, creates predicate closure

**Arena targets:** The FilterContext itself and the pre-checks array are per-evaluation intermediates:

```lua
-- search_filter.lua (with arena)
function M.evaluate(ast, index, graph_sets, restrict_to, cancelled)
  return render_arena.with_scope(function(arena)
    -- FilterContext tables are per-evaluation intermediates
    local ctx = render_arena.alloc_table(arena)
    ctx.resolved_dates = render_arena.alloc_table(arena)
    ctx.parsed_tags = render_arena.alloc_table(arena)
    ctx.numeric_values = render_arena.alloc_table(arena)
    ctx.bloom_pre_checked = render_arena.alloc_table(arena)

    -- Memoized resolver cache is also per-evaluation
    local resolve_cache = render_arena.alloc_table(arena)
    ctx.resolve_link = function(link_path)
      local cached = resolve_cache[link_path]
      if cached ~= nil then return cached or nil end
      local result = filter_utils.resolve_in_index(index, link_path) or false
      resolve_cache[link_path] = result
      return result or nil
    end

    local files, predicate, max_files = prepare_evaluate(ast, index, graph_sets, restrict_to, ctx)
    if not files then return {}, false end

    local matches = {}  -- NOTE: escapes scope, NOT from arena
    -- ... iteration with cancellation checks (existing logic) ...
    return matches, false
  end)
end
```

**Reduced impact vs. original estimate:** The original doc estimated ~500 context dicts per evaluation. In reality, FilterContext is created once per `evaluate()` call (not per-entry), and AST nodes cache their derived values across entries. The arena benefit here is the FilterContext itself (~5 tables) plus the memoized resolver cache (potentially hundreds of entries for large vaults). Note: `evaluate()` uses `config.search.evaluate_batch_size` (line 476) for batched iteration — the arena scope must span the full evaluation including all batches.

### 4. connections.lua — `compute()` (line 758)

**Current architecture:** Already uses `_breakdown_pool` (line 54) and `_result_pool` (line 63) for per-candidate scoring objects. Uses `score_candidate()` (lines 577-676) with 5 scoring dimensions (tags/IDF via `score_tags()` line 200, frontmatter via `score_frontmatter()`, colinks via `score_colinks()` line 278, link proximity via `score_link_proximity()` line 306, temporal with decay: same day=1.0, <3d=0.7, <7d=0.4, <30d=0.2). Top-K min-heap (`create_top_k`, lines 489-549) prunes low-scoring candidates with early pruning (line 590). `build_note_data()` (lines 390-445) pre-computes per-note metadata (outlink_targets, inlink_sources, neighbors union, fm_fields) cached in `_note_data_cache`. Setup via `prepare_compute()` (lines 704-751) which takes vault index snapshot (line 734), ensures IDF (line 735), creates memoized resolver (line 736).

**Arena targets:** Ephemeral intermediates NOT already covered by the existing pools:

```lua
-- connections.lua (with arena)
-- Top-K heap entries and per-candidate compute intermediates
function M.compute(source_rel_path, max_results, opts_cancel)
  return render_arena.with_scope(function(arena)
    local vi = vault_index.current()
    local files = vi:snapshot_files()
    local resolve = filter_utils.create_memoized_resolver(vi)
    local source_data = get_note_data(source_rel_path, vi, resolve)
    if not source_data then return nil, "source not in index" end

    -- Top-K heap internals can use arena
    local heap = create_top_k(max_results)
    -- Note: heap.items[] entries escape into results, but the heap
    -- structure itself (the array container) is scope-local

    for rel_path, entry in pairs(files) do
      if rel_path ~= source_rel_path then
        local candidate_data = get_note_data(rel_path, vi, resolve)
        -- Breakdown is already pooled via _breakdown_pool:acquire()
        -- but intermediate scoring tables (tag overlap sets, neighbor
        -- intersection sets) within score_tags/score_colinks/score_link_proximity
        -- could use arena allocation
        score_candidate(source_data, candidate_data, rel_path, entry, heap, arena)
      end
    end

    -- Results extracted from heap — these escape scope via _result_pool
    return finalize_results(heap), nil
  end)
end
```

**Reduced impact vs. original estimate:** The original doc assumed no pooling existed. With `_breakdown_pool` and `_result_pool` already in place, the arena targets the remaining intermediates: shared tag list in `score_tags()` (lines 200-214), shared neighbor count in `score_colinks()` (lines 278-292), neighbor intersection in `score_link_proximity()` (lines 306-327, capped at `weights.max_2hop_bridges or 5`), `reasons = {}` array per candidate (line 595), `display_tags = {}` (line 602), and the memoized resolver cache. Per `compute()` call: `deps = {}` (line 797) for cache invalidation tracking. Additionally, `build_note_data()` creates 3 ephemeral tables per note: `outlink_targets = {}` (line 395), `inlink_sources = {}` (line 409), `neighbors = {}` (line 420). `compute_async()` (line 824) uses `yield_iter.for_each_yielding()` with `config.connections.score_batch_size or 200` for cooperative yielding.

### 5. Graph System — `local_graph()` (graph.lua:24) via `bfs.lua` and `graph_filter/traversal.lua`

**Current architecture:** Modular multi-file system:
- `graph.lua:local_graph()` (lines 24-323) — main entry, routes depth≤1 (sync, lines 290-312: calls `collect.collect_forward_links()` + `collect.collect_backlinks()`) vs depth>1 (async BFS, lines 313-322: calls `graph_filter.collect_at_depth_async()`)
- `graph_filter/traversal.lua:collect_at_depth_async()` (lines 267-288) — cache management + BFS dispatch
- `bfs.lua:traverse_async()` (lines 180-198) — core BFS with cooperative yielding via `yield_iter.run_async()` (line 186), batch size from `config.graph.bfs_batch_size or 100` (line 184)
- `bfs.lua:run_bfs_loop()` (line 120) — queue + visited + frontier management, accepts `iter_hook` for async yielding/cancellation
- Cache: `_bfs_cache` is `lru.new_weighted({ max_bytes = config.cache.bfs_traversal_bytes, max_items = config.cache.bfs_traversal_max })` (traversal.lua:19-35). `check_cache()` (lines 139-195) returns `hit="exact"` (cached depth matches), `hit="extend"` (cached depth < requested, extend from frontier), or `hit=nil` (full BFS)
- Copy utilities: `copy_nodes()` (lines 94-100), `copy_frontier()` (lines 103-109), `copy_visited()` (lines 113-117) create working copies from cache

**BFS data structures (bfs.lua):**
- Queue: single array with head/tail pointers (lines 131-136), items `{ rel, d, ...extra_fields }` created in `process_node_links()` (lines 41-97, items at lines 58, 84) with extra fields merged from `on_discover()` return
- Visited: hash table `visited[rel_path] = true`
- Frontier: collected via `collect_frontier(queue, head, tail)` (line 154)
- Accumulators: `all_nodes[]`, `forward_like[]`, `backlink_like[]` created by `make_on_discover()` (traversal.lua:57-77)

**Arena targets:** Copy operations for cache-to-working-set transitions and per-node queue items:

```lua
-- bfs.lua (with arena)
-- Queue items are ephemeral: created in process_node_links() (lines 41-97),
-- consumed and discarded during traversal
function run_bfs_loop(opts, iter_hook, arena)
  local queue = {}
  local head, tail = 1, 0

  -- Load frontier into queue (lines 131-136)
  for _, item in ipairs(opts.frontier) do
    tail = tail + 1
    queue[tail] = item  -- frontier items may already be from arena
  end

  while head <= tail and node_count < max_nodes do
    local current = queue[head]
    queue[head] = nil
    head = head + 1

    -- process_node_links (lines 41-97) creates new queue items
    -- Items include extra fields from on_discover() return (lines 58-60, 84-86)
    -- With arena: queue items { rel, d, ...extra } are ephemeral
    -- process_node_links would receive arena and use alloc_table for items

    if iter_hook then
      if iter_hook() then break end  -- cancellation or yield
    end
  end
  -- Frontier collected at line 154 via collect_frontier()
end

-- traversal.lua — copy_* utilities can use arena for working copies
-- IMPORTANT: Cached copies (stored in _bfs_cache) must NOT use arena.
-- Only the working copies used during a single BFS pass should use arena.
-- store_and_return() (lines 227-253) sorts nodes (lines 232-233) and stores
-- forward_like, backlink_like, all_nodes, visited, frontier, truncated
-- directly in _bfs_cache — these must be normal tables, not arena-allocated.
```

**Key constraint:** BFS traversal in async mode yields via `yield_iter.run_async()` (bfs.lua:186). The `iter_hook` callback (lines 187-196) checks cancellation and yields after `batch_size` nodes (default `config.graph.bfs_batch_size or 100`). The arena scope must span the entire async traversal, similar to embed.lua's lazy mode. `end_scope` should be called in the completion callback of `collect_at_depth_async()` (traversal.lua:285).

**Cache interaction:** `store_and_return()` (traversal.lua:227-253) stores visited sets and frontier arrays directly in `_bfs_cache` (weighted LRU, `config.cache.bfs_traversal_bytes`). For extension hits, stores working copies directly (line 243); for full BFS, copies before storage to isolate cache. These cached tables must NOT come from the arena, since they persist across BFS invocations. Only the working copies (created by `copy_nodes`/`copy_frontier`/`copy_visited` during incremental extension from `check_cache()` lines 139-195) are arena candidates.

---

## Configuration

```lua
-- config.lua additions — alongside existing M.pools (lines 863-869)
M.arena = {
  initial_pool_size = 200,      -- Tables pre-allocated at module load
  max_pool_size = 2000,         -- Upper bound on pooled tables (excess GC'd)
  debug_validation = false,     -- Enable use-after-free proxy detection
}
```

**Sizing rationale:**

- `initial_pool_size = 200`: Covers typical embed render + highlight scan without cold-start allocation
- `max_pool_size = 2000`: Covers the largest single operation (deep BFS traversal) without unbounded growth; aligns with existing `config.pools` pattern (connection pools at 200, completion at 1000)
- `debug_validation = false`: Proxy tables add overhead; enable only during development

**Integration with existing config:** The `M.pools` section (lines 863-869) already establishes the pattern for pool sizing with `config.pools.enabled`. The `M.guards` section (lines 874-878) provides `guards.enabled`, `guards.log_cleanup_errors`, `guards.warn_unreleased`. The `M.cache` section (lines 821-841) defines both count-based and byte-weighted budgets. The arena config follows the same convention, sitting alongside these sections.

---

## Monitoring

Add `:VaultArenaStats` command (alongside existing `:VaultPoolStats` at init.lua:922-937):

```
Arena Pool Stats:
  Pool size:          187 / 2000 max
  Total scopes:       1,247
  Active scopes:      0
  Peak scope size:    312 tables
  Pool hits:          148,392 (94.2%)
  Pool misses:        9,108 (5.8%)  -- fresh allocations
  Tables cleared:     157,500
  Overflow discards:  342
```

```lua
-- render_arena.lua stats tracking
-- Follows same pattern as table_pool.lua registry/stats
M._stats = {
  total_scopes = 0,
  peak_scope_size = 0,
  pool_hits = 0,
  pool_misses = 0,
  tables_cleared = 0,
  overflow_discards = 0,
}
```

---

## Implementation Notes

### Scope Nesting

Scopes can be nested (e.g., `render_embeds` calling a sub-function that opens its own scope). Each scope tracks its own tables independently. Nested scopes must end in LIFO order — the `with_scope` wrapper enforces this naturally via the call stack.

### Async Scope Lifetime

Several integration targets use async patterns where the scope must outlive a single function call:

- **embed.lua lazy mode:** `render_remaining_async()` (lines 351-382) uses `cleanup.repeating(ds.async_timer, 16, 16, callback)` (line 358) for background batch rendering with `config.embed.lazy_batch_size` items per tick. Arena scope must remain open across all timer ticks, ending only when `cursor > #list` (timer self-cancels via `state.cleanup_async_timer()`) or generation is invalidated (checked by `check_generation()`, lines 340-345).
- **BFS async traversal:** `bfs.traverse_async()` (lines 180-198) yields via `yield_iter.run_async()` (line 186) with batch-based yielding (lines 187-196). Yields after `config.graph.bfs_batch_size or 100` nodes via `coroutine.yield()`. Arena scope spans the entire traversal coroutine, ends in completion callback (traversal.lua:285).
- **connections.compute_async():** yields periodically during candidate scoring.

For these cases, use `begin_scope()`/`end_scope()` explicitly rather than `with_scope()`, and ensure `end_scope` is called in all completion/cancellation paths.

### Tables That Escape Scope

The critical rule: **never return arena-allocated tables to callers outside the scope.** If a function's return value includes tables, those tables must be allocated normally (via `{}`) or from an appropriate `table_pool` instance. Arena tables are for intermediates consumed within the scope.

Tables that MUST NOT use arena (they escape their operation):
- `results` tables returned from `evaluate()`, `compute()`, `local_graph()`
- Position arrays cached in `_nav_cache[bufnr]` for highlight navigation
- BFS results stored in `_bfs_cache` (visited sets, frontier arrays)
- Connection results from `_result_pool` (persisted in connections cache)
- Embed descriptors from `_desc_pool` (persisted across async timer ticks)

The debug validation proxy (when enabled) catches violations — accessing an arena table after scope end raises an immediate error with the offending key name.

### Interaction with Existing `table_pool.lua`

These two mechanisms are complementary and coexist:

| Mechanism | Current Users | Best For |
|-----------|---------------|----------|
| `table_pool.lua` | embed descriptors, connection results/breakdowns, completion items | Objects with explicit acquire/release lifecycle, reused across operations |
| `render_arena.lua` | (proposed) virt_lines, visited sets, queue items, FilterContext, working copies | Ephemeral intermediates consumed within a single scope |

A module can use both: `table_pool` for result objects that persist after the operation completes (e.g., `_breakdown_pool:acquire()` for scoring breakdowns), and arena for scratch computation tables discarded at scope end (e.g., tag intersection sets within `score_tags()`).

### Clearing Cost

Bulk-clearing tables via `for k in pairs(tbl) do tbl[k] = nil end` is O(n) in the number of keys. For the typical case (tables with 3-8 fields), this is negligible. For large tables (visited sets with 1000+ entries), clearing cost is measurable but still far cheaper than GC collection because:

1. No mark phase (no reachability traversal)
2. No sweep phase (no free-list management)
3. No GC pause contribution (runs outside GC cycle)

If profiling reveals clearing as a bottleneck for large tables, the fallback is to discard them (let GC collect) rather than returning to pool — controlled by a per-table size threshold.

### Thread Safety

Not applicable — Neovim's Lua runtime is single-threaded. All arena operations run on the main thread. Coroutine yields within a scope are safe (scope state persists across yields) as long as `end_scope` is called after the coroutine completes.

### Memory Overhead

Pool storage: one table reference per pooled table = 8 bytes on 64-bit. At `max_pool_size = 2000`: 16 KB of references plus the empty table shells (~56 bytes each in LuaJIT) = ~128 KB total. This is recouped after preventing GC of ~128 KB worth of short-lived tables in a single render cycle. Comparable to existing `config.cache` byte budgets (file_content_bytes: 5 MB, section_cache_bytes: 2 MB).

---

## Validation

1. **Scope lifecycle:** Verify `end_scope` returns all tables to pool and invalidates scope
2. **Use-after-free detection:** With `debug_validation = true`, verify accessing a table from an ended scope raises an error
3. **Nested scopes:** Verify inner scope end does not affect outer scope tables
4. **Pool exhaustion:** Verify graceful fallback to `{}` when pool is empty
5. **Pool overflow:** Verify excess tables are discarded (not leaked) when pool is full
6. **Error safety:** Verify `with_scope` calls `end_scope` even when fn errors
7. **Escape detection:** Verify debug proxy catches arena tables used after scope end
8. **Async scope safety:** Verify arena scope survives across `render_remaining_async()` timer ticks and `bfs.traverse_async()` coroutine yields
9. **Coexistence with table_pool:** Verify arena and `table_pool` operate independently — arena `end_scope` does not affect pooled objects, and pool `release()` does not affect arena tables
10. **Memory comparison:** Measure `collectgarbage("count")` during 100 rapid render cycles with/without arena — expect 40-60% reduction in GC allocation rate for remaining un-pooled intermediates

---

## Expected Impact

### GC Pressure Reduction

**Note:** Impact estimates are revised downward from the original document because `table_pool.lua` already handles descriptors, breakdowns, results, and completion items. Arena targets the remaining ephemeral intermediates.

| Operation | Currently Un-pooled Tables | With Arena | GC Allocation Reduction |
|-----------|--------------------------|------------|------------------------|
| `render_embeds()` (10 note embeds) | ~20 virt_lines + ~20 visited sets/lists | ~40 pool hits, 0 GC'd | ~100% of remaining |
| Highlight `run_all()` (500 lines, 4 modules) | ~200 intermediate match/position tables | ~200 pool hits | ~100% of remaining |
| `evaluate()` (1000 entries) | ~5 FilterContext tables + resolver cache | ~5 pool hits + cache entries | ~100% of remaining |
| `compute()` (500 candidates) | Tag/neighbor intersection intermediates | Pool hits per intersection | ~80% of remaining |
| BFS traversal (depth=3, ~200 nodes) | ~200 queue items + copy arrays | ~200 pool hits | ~100% of remaining |
| Rapid scroll (10 highlight scans/sec) | ~2000 tables/sec into GC | ~0 tables/sec into GC | ~100% of remaining |

### GC Pause Impact

Lua 5.1's incremental GC step time is proportional to the number of live objects. By recycling tables outside the GC's purview, arena allocation removes these objects from GC's tracking entirely:

- **GC step frequency:** Reduced proportionally to allocation rate reduction
- **GC pause duration:** Shorter steps because fewer objects to mark/sweep
- **UI responsiveness:** During rapid scrolling, GC no longer competes with highlight rendering

**Estimated improvement:** 40-60% reduction in GC-related CPU time during render-heavy operations (scrolling, search evaluation, graph building). Lower than original 60-80% estimate because `table_pool.lua` already captures the highest-volume allocation sites (descriptors, results, completion items).

### Comparison to Alternative Approaches

| Approach | Per-table overhead | Bulk free cost | Forgotten-release risk | Scope alignment |
|----------|-------------------|----------------|----------------------|-----------------|
| Normal allocation | GC tracking + collection | N/A (GC handles) | N/A | None |
| `table_pool.lua` (implemented) | `acquire()` + `release()` calls | N/A (individual) | Table reverts to GC | Manual |
| `render_arena.lua` (this doc) | Pool pop only | O(tables * keys) | Impossible (scope-based) | Automatic |
