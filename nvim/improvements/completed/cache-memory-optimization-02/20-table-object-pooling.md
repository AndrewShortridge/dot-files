# 20. Table/Object Pooling

**Priority:** MEDIUM
**Phase:** 2 (Scalability)
**Dependencies:** None (standalone infrastructure)
**Inspired by:** Zed's `QUERY_CURSORS` + `PARSERS` pools (`language.rs:94-112`, `syntax_map.rs:224,1879-1908`), GPU `InstanceBufferPool` (`metal_renderer.rs:51-94`), `LineWrapperHandle` keyed pool (`text_system.rs:52,282-296,572-583`), `FontRuns` pool (`text_system.rs:53,409-510,534,553-554`)

---

## Problem

Vault modules create and discard **thousands of short-lived Lua tables** per operation, generating significant GC pressure. Each table allocation requires the Lua allocator to find free memory, and each abandonment adds to GC's mark-and-sweep workload.

### Hot Allocation Paths (Actual Codebase)

| Operation | Tables Created | Frequency | Tables/Second |
|-----------|---------------|-----------|---------------|
| `vault_index.build_async()` (10K files) | ~200K (entries, outlinks, tags, headings via `vault_index_parser.parse_file()`) | On open/save | Burst: 50K/s |
| `search_filter.evaluate()` (10K entries) | ~7 (1 `matches` dict + 5 filter_context + 1 checks array); no per-match tables | Per keystroke (live) | Low |
| `connections.compute()` scoring loop (`connections.lua:748-754`) | ~3K per 1K files (reasons array + incremental breakdown + result item + display_tags per candidate; heap wrappers at `create_top_k():491,505`) | Per navigation | Burst: 10K/s |
| `completion build_iter` (`completion.lua:210-284`, 10K items) | ~20K (items via `make_item()`:59-75, alias_queue arrays:231,256-275, heading_items:365-373, filtered:401-407) | On trigger | Burst: 20K/s |
| Embed rendering (10 embeds) | ~200 (descriptors:136-146, virt_lines:246, visited_set/list:262-263 per note embed, resolved:109 per recursive call) | Per BufEnter | 200/event |

**Total GC pressure during connection scoring + completion:** 10K+ tables/second created and abandoned, triggering incremental GC steps that compete with UI rendering.

### Existing Optimizations Already In Place

The codebase already has several memory optimization patterns that reduce the pooling surface:

| Optimization | Module | Effect |
|-------------|--------|--------|
| **String interning** (`string_intern.lua`) | `vault_index_parser` (4 pools: tags/500, fm_keys/200, fm_values/2000, lowercase/5000; configured via `config.intern`), `match_field.lua` (`_lowercase_pool`), `completion.lua` (`_desc_pool`:153, 500 capacity), `backlinks.lua` (`_lowercase_pool`:10, 5000 capacity) | Deduplicates repeated strings across entries |
| **LRU caching** (`lru_cache.lua`, 2 variants) | `connections._note_data_cache` (weighted LRU:41-45, `cache_weighers.note_data`), `connections._cache`, `match_field._section_cache`:54-58 | Avoids rebuilding ConnectionNoteData and scoring results |
| **Memory-weighted LRU** (`lru_cache.new_weighted()`) | Uses `cache_weighers.lua` (5 weighers: lines_entry, connections, note_data, section_outlinks, bfs_result) for byte-budget eviction | Bounds cache memory by total bytes, not just item count |
| **Generation-based caching** (`gen_cache.lua`) | `connections`, `completion_base`, `search_filter`; also `gen_cache()` and `keyed_gen_cache()` factories | Invalidates when `vault_index._generation` changes |
| **Memoized resolver** (`filter_utils.create_memoized_resolver()`:45-62) | `connections`, `graph_filter`, `search_filter` | O(1) repeated link resolution via closure-local cache with `false` sentinel for nil results |
| **Lazy entry fields** (metatable `__index`) | `vault_index.lua:30-85` (7 derived fields: abs_path, basename, basename_lower, folder, tag_set, heading_slugs, block_id_set) | Computed on first access, cached via `rawset` for O(1) subsequent reads; ~30% JSON size reduction |
| **Adaptive batch sizing** | `completion_base.lua:135-143` (`effective_batch_size()`: `ceil(total/3)`) | Caps coroutine yields at ~3 regardless of vault size |
| **Weak table caches** (`weak_cache.lua`) _(removed — dead code, no consumers)_ | `new_weak_values()`, `new_weak_keys()`, `new_weak_kv()` | GC-based cleanup safety net for unreferenced computed results |
| **Pre-computed timestamps** | `vault_index_parser.lua:517-526` (`created_ts`, `modified_ts`, `day_ts`) | Avoids runtime date parsing in search/filter hot paths |

### Zed's Approach

Zed pools expensive objects across **five** distinct pool implementations:

#### 1. QUERY_CURSORS — Static LIFO Pool (`language.rs:94`, `syntax_map.rs:224,1879-1908`)

```rust
static QUERY_CURSORS: Mutex<Vec<QueryCursor>> = Mutex::new(vec![]);

impl QueryCursorHandle {
    pub fn new() -> Self {
        let mut cursor = QUERY_CURSORS.lock().pop().unwrap_or_default();
        cursor.set_match_limit(64);
        QueryCursorHandle(Some(cursor))
    }
}

impl Drop for QueryCursorHandle {
    fn drop(&mut self) {
        let mut cursor = self.0.take().unwrap();
        cursor.set_byte_range(0..usize::MAX);
        cursor.set_point_range(Point::zero().to_ts_point()..Point::MAX.to_ts_point());
        QUERY_CURSORS.lock().push(cursor)
    }
}
```

#### 2. PARSERS — Static LIFO Pool with Lazy Init (`language.rs:95-112`)

```rust
static PARSERS: Mutex<Vec<Parser>> = Mutex::new(vec![]);

pub fn with_parser<F, R>(func: F) -> R
where F: FnOnce(&mut Parser) -> R,
{
    let mut parser = PARSERS.lock().pop().unwrap_or_else(|| {
        let mut parser = Parser::new();
        parser.set_wasm_store(WasmStore::new(&WASM_ENGINE).unwrap()).unwrap();
        parser
    });
    parser.set_included_ranges(&[]).unwrap();
    let result = func(&mut parser);
    PARSERS.lock().push(parser);
    result
}
```

#### 3. InstanceBufferPool — GPU Buffer Pool with Dynamic Resizing (`metal_renderer.rs:51-94`)

```rust
pub(crate) struct InstanceBufferPool {
    buffer_size: usize,        // Default: 2MB (line 59), max: 256MB (line 354)
    buffers: Vec<metal::Buffer>,
}

impl InstanceBufferPool {
    fn reset(&mut self, buffer_size: usize) { self.buffer_size = buffer_size; self.buffers.clear(); }
    fn acquire(&mut self, device: &metal::Device) -> InstanceBuffer {
        // pop or create with MTLResourceOptions::StorageModeManaged
        let buffer = self.buffers.pop().unwrap_or_else(|| device.new_buffer(...));
        InstanceBuffer { metal_buffer: buffer, size: self.buffer_size }
    }
    fn release(&mut self, buffer: InstanceBuffer) {
        if buffer.size == self.buffer_size { self.buffers.push(buffer.metal_buffer) }
    }
}
// Auto-doubles buffer_size on render failure (lines 347-363), caps at 256MB
```

#### 4. LineWrapperHandle — Keyed Pool per Font/Size (`text_system.rs:52,282-296,572-583`)

```rust
wrapper_pool: Mutex<FxHashMap<FontIdWithSize, Vec<LineWrapper>>>,
// FontIdWithSize = { font_id: FontId, font_size: Pixels } (lines 560-564)

// Acquire (line_wrapper(), lines 282-296):
let wrappers = lock.entry(FontIdWithSize { font_id, font_size }).or_default();
let wrapper = wrappers.pop().unwrap_or_else(|| LineWrapper::new(font_id, font_size, ...));
// Returns LineWrapperHandle { wrapper: Some(wrapper), text_system: self.clone() }

// Release via Drop (lines 572-583):
// state.get_mut(&FontIdWithSize { font_id, font_size }).unwrap().push(wrapper)
```

#### 5. FontRuns — Nested Vec Pool (`text_system.rs:53,409-510,534,553-554`)

```rust
font_runs_pool: Mutex<Vec<Vec<FontRun>>>,
// Acquire (shape_text:409, layout_line:534):
let mut font_runs = self.font_runs_pool.lock().pop().unwrap_or_default();
// Release (shape_text:489-510, layout_line:553-554):
font_runs.clear();  // Reset contents but keep allocation
self.font_runs_pool.lock().push(font_runs);
```

Key insights:
- Objects that are **expensive to create** or **created in tight loops** benefit from pooling even if individual allocation is cheap
- All pools use RAII (Drop trait) for automatic return-to-pool, preventing manual release errors
- Zed's `with_parser()` uses a **scoped closure** pattern rather than RAII wrapper — simpler for single-use contexts
- `with_query_cursor()` (`language.rs:114-120`) wraps `QueryCursorHandle` in the same closure pattern for convenience
- `InstanceBufferPool` validates size on release — prevents returning stale-sized buffers after resize
- FontRuns pool calls `.clear()` before returning (preserves Vec allocation while resetting contents)

---

## Solution

Create a `table_pool.lua` module providing typed object pools for common table shapes used in vault operations.

### Core Pool Implementation

```lua
-- table_pool.lua

local M = {}

--- Create a new object pool.
--- @param max_size integer Maximum pooled objects (excess are GC'd)
--- @param reset_fn function(obj) Reset object to clean state for reuse
--- @return table pool Pool instance with acquire/release methods
function M.new(max_size, reset_fn)
  local pool = {
    _stack = {},       -- LIFO stack of available objects
    _size = 0,         -- Current pool size
    _max_size = max_size,
    _reset_fn = reset_fn,
    -- Stats
    _hits = 0,
    _misses = 0,
    _releases = 0,
    _overflows = 0,
  }
  return setmetatable(pool, { __index = Pool })
end

local Pool = {}

--- Acquire an object from the pool, or create a new one.
--- @param create_fn function() Factory for new objects (called on pool miss)
--- @return table obj The acquired object (reset to clean state if pooled)
function Pool:acquire(create_fn)
  if self._size > 0 then
    local obj = self._stack[self._size]
    self._stack[self._size] = nil
    self._size = self._size - 1
    self._hits = self._hits + 1
    self._reset_fn(obj)
    return obj
  end
  self._misses = self._misses + 1
  return create_fn()
end

--- Release an object back to the pool for reuse.
--- If pool is full, object is simply abandoned for GC.
--- @param obj table The object to return to the pool
function Pool:release(obj)
  self._releases = self._releases + 1
  if self._size < self._max_size then
    self._size = self._size + 1
    self._stack[self._size] = obj
  else
    self._overflows = self._overflows + 1
    -- Let GC handle it
  end
end

--- Release multiple objects at once.
--- @param objects table[] Array of objects to release
function Pool:release_batch(objects)
  for i = 1, #objects do
    self:release(objects[i])
    objects[i] = nil  -- Clear reference from source
  end
end

--- Get pool statistics.
--- @return table stats { hits, misses, hit_rate, size, max_size, overflows }
function Pool:stats()
  local total = self._hits + self._misses
  return {
    hits = self._hits,
    misses = self._misses,
    hit_rate = total > 0 and (self._hits / total * 100) or 0,
    size = self._size,
    max_size = self._max_size,
    releases = self._releases,
    overflows = self._overflows,
  }
end

--- Clear all pooled objects (e.g., on VimLeavePre).
function Pool:clear()
  for i = 1, self._size do
    self._stack[i] = nil
  end
  self._size = 0
end

return M
```

### Scoped Acquire/Release Helper

Mirrors Zed's `with_parser()` closure pattern for single-use contexts:

```lua
--- Acquire an object, call a function with it, then release.
--- Guarantees release even on error (pcall wrapper).
--- @param pool table The pool instance
--- @param create_fn function Factory for new objects
--- @param use_fn function(obj) Function that uses the object
--- @return any result Return value of use_fn
function M.with(pool, create_fn, use_fn)
  local obj = pool:acquire(create_fn)
  local ok, result = pcall(use_fn, obj)
  pool:release(obj)
  if not ok then error(result, 2) end
  return result
end
```

---

## Integration Targets

### 1. Connection Scoring Result Tables (HIGH IMPACT)

`connections.score_candidate()` (`connections.lua:555-646`) creates a result table per scored candidate. The scoring loop in `M.compute()` (`connections.lua:748-754`, async variant at `compute_async():792-806` via `yield_iter.for_each_yielding`) iterates all files, creating `breakdown` + `reasons` + `display_tags` + result item tables per candidate.

**Note:** `build_note_data()` (`connections.lua:368-423`) is already cached via weighted LRU `_note_data_cache` (`connections.lua:41-45`, weigher: `cache_weighers.note_data`) — pooling note data tables has low incremental value. Focus on the **scoring output tables** instead.

Also note: `create_top_k()` (`connections.lua:467-527`) creates heap wrapper objects `{ score, item }` at lines 491/505 — partially reused on replacement but fresh on insert.

```lua
-- connections.lua (current, lines 573-644)
-- Per candidate: creates breakdown table (incrementally), reasons array, and result item
local reasons = {}                    -- Line 573: POOLING CANDIDATE
local breakdown = { tags = tag_score } -- Line 574: POOLING CANDIDATE (fields added incrementally)
-- ... breakdown.fm, breakdown.colink, breakdown.link, breakdown.temporal added as scored ...
-- ... display_tags = {} at line 577 (up to 3 tags for reason string) ...
-- ... reasons[#reasons + 1] = ... throughout scoring (lines 582, 592, 604, 618, 631) ...
-- Final result item (lines 636-644):
top.insert(total_score, {
  rel_path = rel_path, name = entry.basename,
  name_lower = candidate.name_lower, rel_path_lower = candidate.rel_path_lower,
  score = total_score, reasons = reasons, breakdown = breakdown,
})

-- connections.lua (with pooling)
local result_pool = table_pool.new(200, function(obj)
  obj.rel_path = nil
  obj.name = nil
  obj.name_lower = nil
  obj.rel_path_lower = nil
  obj.score = 0
  obj.reasons = nil
  obj.breakdown = nil
end)

local breakdown_pool = table_pool.new(200, function(obj)
  obj.tags = 0
  obj.fm = 0
  obj.colink = 0
  obj.link = 0
  obj.temporal = 0
end)

-- In score_candidate():
local breakdown = breakdown_pool:acquire(function()
  return { tags = 0, fm = 0, colink = 0, link = 0, temporal = 0 }
end)
-- ... populate breakdown ...

local item = result_pool:acquire(function()
  return { rel_path = nil, name = nil, name_lower = nil,
           rel_path_lower = nil, score = 0, reasons = nil, breakdown = nil }
end)
item.rel_path = rel_path
item.name = entry.basename
item.breakdown = breakdown
-- ... etc

-- On cache invalidation, release previous results:
-- (in _cache eviction callback or manual invalidation)
```

### 2. Completion Item Tables (HIGH IMPACT)

`completion_base.make_item()` (`completion_base.lua:59-75`) creates one table per completion item. The wikilinks `build_iter` path (`completion.lua:210-284`) creates items for every file + alias in the vault.

Additional per-item allocations include:
- `opts.data` table (e.g., `{ rel_path = rel, mtime = mtime }`)
- `opts.labelDetails` table (`{ description = opts.description }`)
- `alias_queue` arrays per entry (`completion.lua:231,256-275` — reset to `{}` per entry, populated with alias items)

**Existing optimization:** `completion.lua` already interns description strings via `_desc_pool` (`string_intern.new(500)`, line 153, helper at 155-160, reset at 163-166), reset on each `build_iter` rebuild (line 215). Cache invalidation at `completion_base.lua:168-172` sets `cached_items = nil` (items become GC candidates).

```lua
-- completion_base.lua (with pooling)
local item_pool = table_pool.new(1000, function(obj)
  obj.label = nil
  obj.insertText = nil
  obj.filterText = nil
  obj.kind = nil
  obj.sortText = nil
  obj.documentation = nil
  obj.data = nil
  obj.labelDetails = nil
end)

function M.make_item(label, insertText, filterText, kind, opts)
  local item = item_pool:acquire(function()
    return { label = nil, insertText = nil, filterText = nil, kind = nil,
             sortText = nil, documentation = nil, data = nil, labelDetails = nil }
  end)
  item.label = label
  item.insertText = insertText
  item.filterText = filterText
  item.kind = kind
  if opts then
    if opts.description then
      item.labelDetails = { description = opts.description }
    end
    if opts.sortText then item.sortText = opts.sortText end
    if opts.documentation then item.documentation = opts.documentation end
    if opts.data then item.data = opts.data end
  end
  return item
end

-- On cache invalidation (completion_base.lua invalidate function):
if cached_items then
  item_pool:release_batch(cached_items)
end
```

### 3. Embed Descriptor + Virtual Line Tables (MEDIUM IMPACT)

`embed.build_descriptors()` (`embed.lua:136-146`) creates one descriptor per embed reference found. Each `render_single_embed()` call (`embed.lua:210-299`) creates:
- `virt_lines = {}` array (`embed.lua:246`) with `{ { text, hl } }` sub-tables per content line
- `visited_set` + `visited_list` for cycle detection (`embed.lua:262-263`) — **already optimal**: shared across recursion, properly cleaned via stack unwinding (`embed_resolver.lua:166-169`)
- `resolved = {}` content array in `embed_resolver.resolve_embed_lines()` (`embed_resolver.lua:66-177`, resolved at line 109) — created per recursive call

Old descriptors stored at `state._embed_descriptors[bufnr] = { generation, list, async_timer }` (`embed_state.lua:19,58-61`). Completely replaced on re-render (`embed.lua:390-391`), old `list` array GC'd.

```lua
-- embed.lua (with pooling)
local desc_pool = table_pool.new(50, function(obj)
  obj.lnum = 0
  obj.col_s = 0
  obj.col_e = 0
  obj.inner = nil
  obj.is_image = false
  obj.rendered = false
  obj.lines_used = 0
end)

-- In build_descriptors():
local function build_descriptors(lines)
  local descs = {}
  iterate_embeds(lines, function(i, inner, s, e)
    local d = desc_pool:acquire(function()
      return { lnum = 0, col_s = 0, col_e = 0, inner = nil,
               is_image = false, rendered = false, lines_used = 0 }
    end)
    d.lnum = i
    d.col_s = s
    d.col_e = e
    d.inner = inner
    d.is_image = images.is_image_embed(inner)
    descs[#descs + 1] = d
  end)
  return descs
end

-- On re-render, release old descriptors before rebuilding:
if state._embed_descriptors[bufnr] then
  desc_pool:release_batch(state._embed_descriptors[bufnr].list)
end
```

### 4. Search Filter Pre-Check Tables (LOW IMPACT)

`search_filter.evaluate()` (`search_filter.lua:435-452`) uses a **dictionary accumulation** pattern (`matches = {}` at line 439, `matches[rel_path] = entry`) — no per-match table creation. The inner loop (lines 441-449) has **zero table allocations**. The main allocation is `build_filter_context()` (`search_filter.lua:148-221`) which creates 5 tables once per query: `ctx` (line 149) with 4 inline sub-tables (`resolved_dates`, `parsed_tags`, `numeric_values`, `bloom_pre_checked`). Additionally, `extract_pre_checks()` (lines 302-384) creates 1 `checks` array (line 306).

Pooling value is low here because:
- Only 7 tables total per `evaluate()` call (1 matches + 5 filter context + 1 checks array), not per match
- The `matches` dict uses direct entry references (no copying)
- Filter context is short-lived but singular
- Pre-check functions from `extract_pre_checks()` (lines 302-384) are created once, not per entry

**Skip this target** unless profiling shows `build_filter_context()` frequency is problematic.

### 5. Temporary Arrays in Hot Paths (LOW IMPACT — DOWNGRADED)

Multiple modules create temporary arrays that are discarded after use. However, **investigation reveals none of these are in per-entry hot loops** — all are created once per function call or once per group:

| Module | Location | Pattern | Frequency |
|--------|----------|---------|-----------|
| `completion.lua:365-373,401-407` | `heading_items = {}`, `filtered = {}` per completion trigger | Array accumulation | Once per trigger |
| `match_field.lua:77,102-160` | `links = {}` per line; `sections = {}`, `heading_stack = {}`, `parent_map = {}`, `direct_count = {}` per file | Per-line/per-file (cached via `_section_cache` LRU) | Per cache miss |
| `ripgrep.lua:128,142,146` | `lines = {}`, `allowed = {}`, `filtered = {}` per rg output; `seen = {}`, `result = {}` in merge_unique:212-228 | Stream processing | Once per rg call |
| `graph_traversal.lua:79,119` | `nodes = {}` per AST traversal, `sets = {}` per precompute call | Traversal accumulation | Once per call |
| `backlinks.lua:36,106,228-229` | `results = {}` per backlink search; `seen = {}`, `links = {}` per forwardlinks | Per-function accumulation | Once per call |
| `query/executor_results.lua:97-106,145-158` | `rows = {}` per group, `items = {}` per group | Result formatting | Once per group |

```lua
-- Generic array pool for temporary collections
local array_pool = table_pool.new(100, function(obj)
  -- Clear all numeric keys
  for i = #obj, 1, -1 do
    obj[i] = nil
  end
end)

-- Usage in hot paths:
local temp = array_pool:acquire(function() return {} end)
for _, item in ipairs(source) do
  if predicate(item) then
    temp[#temp + 1] = item
  end
end
-- Use temp...
array_pool:release(temp)
```

---

## Pool Lifecycle Management

### VimLeavePre Cleanup

```lua
-- engine.lua or init
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("VaultPoolCleanup", { clear = true }),
  callback = function()
    -- Clear all pools to assist final GC
    table_pool.clear_all()
  end,
})
```

### Pool Registry for Monitoring

```lua
-- table_pool.lua addition
local _registry = {}

function M.register(name, pool)
  _registry[name] = pool
end

function M.all_stats()
  local stats = {}
  for name, pool in pairs(_registry) do
    stats[name] = pool:stats()
  end
  return stats
end

function M.clear_all()
  for _, pool in pairs(_registry) do
    pool:clear()
  end
end
```

---

## Configuration

```lua
-- config.lua additions (alongside existing M.intern at lines 852-858)
M.pools = {
  enabled = true,
  connection_result = 200,    -- Max pooled connection scoring result items
  connection_breakdown = 200, -- Max pooled breakdown tables
  completion_item = 1000,     -- Max pooled completion items
  embed_descriptor = 50,      -- Max pooled embed descriptors
}
-- Note: temp_array pool removed — investigation shows §5 targets create tables
-- once per call, not in hot loops. Pooling adds complexity without measurable benefit.
```

---

## Monitoring

Add `:VaultPoolStats` command:

```
Pool Stats:
  conn_result:     200 max, 156 pooled, hit_rate=91.4%, 3 overflows
  conn_breakdown:  200 max, 156 pooled, hit_rate=91.4%, 3 overflows
  completion_item: 1000 max, 847 pooled, hit_rate=94.1%, 0 overflows
  embed_descriptor: 50 max, 12 pooled, hit_rate=78.3%, 0 overflows
```

---

## Validation

1. **Correctness:** Verify reset_fn fully clears object state (no data leakage between uses)
2. **Hit rate monitoring:** Pools with <50% hit rate are wasteful — reduce max_size or remove
3. **Memory comparison:** Measure `collectgarbage("count")` during connection scoring + completion with/without pools
4. **GC pause comparison:** Measure GC step times during burst operations
5. **Edge cases:** Release without prior acquire, acquire with empty pool, release to full pool
6. **Interaction with existing caches:** Ensure pooled objects released from LRU eviction callbacks don't create use-after-release bugs

---

## Expected Impact

### Revised GC Pressure Reduction

The original estimates were overstated for search_filter (which creates very few tables). Updated based on actual codebase analysis:

| Operation | Tables Created (no pool) | Tables Created (with pool) | Reduction |
|-----------|-------------------------|---------------------------|-----------|
| Connection scoring (1K files) | ~3K (result + breakdown + reasons per candidate) | ~200 + 2.8K reused | 93% fewer allocations |
| Completion rebuild (10K files) | ~20K (items + data + labelDetails + alias queues) | ~1K + 19K reused | 95% fewer allocations |
| Embed render (10 embeds) | ~200 (descriptors + virt_lines + resolved; visited_set/list already shared across recursion) | ~50 + 150 reused | 75% fewer allocations |
| Live search (10 keystrokes) | ~70 (7 tables per evaluate × 10 calls) | Not worth pooling | N/A — already minimal |

### Where Pooling Has Low Value

| Module | Why Pooling Adds Little |
|--------|------------------------|
| `search_filter.evaluate()` | Creates 7 tables total per call (1 matches + 5 filter context + 1 checks array), zero allocations in per-entry loop; direct entry references, no copying |
| `connections.build_note_data()` | Already cached in weighted LRU `_note_data_cache` (byte-budgeted via `cache_weighers.note_data`); rebuilt only on cache miss |
| `vault_index_parser.parse_file()` | Entry tables are long-lived (stored in index), not short-lived; 4 string intern pools already deduplicate strings; timestamps pre-computed at parse time |
| Temporary arrays (§5 targets) | All create tables once per call/group, not per entry — no hot-loop allocations found; `match_field` already LRU-cached |

### GC Pause Impact

Lua 5.1 GC runs incrementally, with step time proportional to allocation rate. Pooling completion items and connection scoring results targets the two highest-volume burst allocation paths.

**Estimated GC pause reduction:** 30-60% during completion rebuild and connection scoring operations.

**Memory overhead:** Pool storage costs ~8 bytes per pooled object (stack slot). 1000 pooled objects = 8 KB. Negligible compared to savings.
