# 18. Memory-Weighted Cache Eviction

**Priority:** MEDIUM
**Phase:** 2 (Scalability)
**Dependencies:** LRU cache infrastructure (`lua/andrew/vault/lru_cache.lua`)
**Inspired by:** Zed's Moka cache with custom weigher functions (`wasm_host.rs:808-839`)

---

## Problem

The vault's LRU cache (`lru_cache.lua`) is bounded by **item count** via `M.new(max_size)`. Current config limits (from `config.cache`, lines 821-831):

```lua
M.cache = {
  slug_max = 2000,
  date_parse_max = 5000,
  connections_max = 500,
  section_cache_max = 200,
  note_data_max = 1000,
  display_width_max = 2000,
  bfs_traversal_max = 100,
  image_path_max = 500,
  file_content_max = 100,
}
```

Item count is a poor proxy for memory usage when entries vary dramatically in size:

| Cache | Module | Stored Type | Entry Size Range | At-limit memory |
|-------|--------|-------------|-----------------|-----------------|
| `slug` | `slug.lua` | string | 20-80 bytes | ~100 KB (2000 items) |
| `date_parse` | `date_utils.lua` | parsed date | 20-40 bytes | ~150 KB (5000 items) |
| `_section_cache` | `file_cache.lua` | `{ lines, mtime }` | 100-50,000 bytes | 20 KB - 10 MB (200 items) |
| `_cache` (file content) | `file_cache.lua` | `{ lines, mtime }` | 500-500,000 bytes | 50 KB - 50 MB (100 items) |
| `_cache` (connections) | `connections.lua` | `{ results[], deps, timestamp, index_gen }` | 1,000-20,000 bytes | 500 KB - 10 MB (500 items) |
| `_note_data_cache` | `connections.lua` | `ConnectionNoteData` (tags, links, neighbors, fm) | 200-5,000 bytes | 200 KB - 5 MB (1000 items) |
| `_section_cache` | `search_filter/match_field.lua` | `{ sections = { slug → outlinks[] } }` | 100-50,000 bytes | 20 KB - 10 MB (200 items) |
| `_bfs_cache` | `graph_filter/traversal.lua` | `BfsCacheEntry` (visited, frontier, nodes, resolve) | 500-20,000 bytes | 50 KB - 2 MB (100 items) |

The file content cache and section caches can hold entries that differ by **100x** in memory. A 100-item file cache could use 50 KB or 50 MB depending on which files are cached.

### Current LRU Implementation

The existing cache (`lru_cache.lua`) uses a closure-based array + hash table design:

```lua
-- Internal structure (closure-based, no metatable) — lines 11-13
local order = {}    -- array of keys (oldest first, newest last)
local lookup = {}   -- key -> value hash table
local n = 0         -- current size
-- promote(key) at lines 16-24: local helper captured in closures
```

API surface: `get(key)` (28-33), `put(key, value)` (37-53), `clear()` (56-60), `size()` (63-65), `remove(key)` (68-78), `entries()` (82-90).

Key characteristics:
- `promote()` scans the `order` array linearly (O(n) per access)
- `put()` evicts `order[1]` via `table.remove(order, 1)` (O(n) shift)
- `remove(key)` also uses O(n) linear scan of the `order` array
- No entry metadata (no weight, no prev/next pointers)
- Closure-based API (not metatable/class-based) — each `M.new(max_size)` (line 8) call captures fresh locals

### Zed's Approach

Zed's WASM incremental compilation cache (`crates/extension_host/src/wasm_host.rs:808-839`) uses `moka::sync::Cache` with a **memory-weighted eviction policy**:

```rust
/// Wrapper around a mini-moka bounded cache for storing incremental compilation artifacts.
/// Since wasm modules have many similar elements, this can save us a lot of work at the
/// cost of a small memory footprint. However, we don't want this to be unbounded, so we use
/// a LFU/LRU cache to evict less used cache entries.
#[derive(Debug)]
struct IncrementalCompilationCache {
    cache: Cache<Vec<u8>, Vec<u8>>,
}

impl IncrementalCompilationCache {
    fn new() -> Self {
        let cache = Cache::builder()
            // Cap this at 32 MB for now. Our extensions turn into roughly 512kb in the cache,
            // which means we could store 64 completely novel extensions in the cache, but in
            // practice we will more than that, which is more than enough for our use case.
            .max_capacity(32 * 1024 * 1024)
            .weigher(|k: &Vec<u8>, v: &Vec<u8>| (k.len() + v.len()).try_into().unwrap_or(u32::MAX))
            .build();
        Self { cache }
    }
}

impl CacheStore for IncrementalCompilationCache {
    fn get(&self, key: &[u8]) -> Option<Cow<'_, [u8]>> {
        self.cache.get(key).map(|v| v.into())
    }
    fn insert(&self, key: &[u8], value: Vec<u8>) -> bool {
        self.cache.insert(key.to_vec(), value);
        true
    }
}
```

The cache instance is created as a `LazyLock` singleton via `cache_store()` (lines 545-549). Moka (v0.12.10, `features = ["sync"]`) provides hybrid LFU/LRU eviction internally. Only the `extension_host` crate depends on moka.

This is the **only** memory-weighted cache in Zed's production code. Other Zed caches use:
- Frame-based expiration (`line_layout.rs:392-466`): `finish_frame()` swaps two `FrameCache` buffers via `std::mem::swap()`, then clears the now-current frame; `reuse_layouts()` (line 429) and `truncate_layouts()` (line 450) are separate methods for layout migration and pruning
- Unbounded retain-all (`image_cache.rs:228`): `RetainAllImageCache(HashMap<u64, ImageCacheItem>)` with release observer cleanup; also `project/src/image_store.rs:283` uses `WeakEntity<ImageItem>` for automatic GC via weak reference upgrade checks (failed `upgrade()` triggers removal)
- Count-based LRU (`image_gallery.rs:133-229`): `SimpleLruCache` with `max_items`, `usages: Vec<u64>` tracking insertion order
- Dual-threshold drain (`summary_backlog.rs:1-49`): `MAX_FILES_BEFORE_RESUMMARIZE = 4` OR `MAX_BYTES_BEFORE_RESUMMARIZE = 1_000_000` (1 MB), `needs_drain()` checks both with OR logic
- VecDeque ring buffer (`code_context_menus.rs:53-695`): `MARKDOWN_CACHE_MAX_SIZE = 16`, uses `rotate_right(1)` + overwrites first element for MRU promotion
- Hybrid array + HashMap (`line_wrapper.rs:6-12`): `cached_ascii_char_widths: [Option<Pixels>; 128]` for O(1) ASCII lookup, `cached_other_char_widths: HashMap<char, Pixels>` fallback for Unicode

The moka weigher ensures the cache stays within a **memory budget** regardless of how many items are stored. Small items coexist efficiently; one large item doesn't crowd out hundreds of small ones.

---

## Solution

Add `M.new_weighted(opts)` to `lru_cache.lua`, preserving the existing `M.new(max_size)` API unchanged.

### API Design

```lua
local lru = require("andrew.vault.lru_cache")

-- Count-based (existing API, unchanged)
local slug_cache = lru.new(2000)

-- Memory-weighted (new API)
local section_cache = lru.new_weighted({
  max_bytes = 2 * 1024 * 1024,  -- 2 MB budget
  weigher = function(key, value)
    -- Return estimated byte size of entry
    return #key + estimate_lines_memory(value)
  end,
})

-- Dual-bounded (both count and memory)
local file_cache = lru.new_weighted({
  max_items = 200,              -- Hard item cap
  max_bytes = 5 * 1024 * 1024,  -- 5 MB budget
  weigher = function(key, value)
    return #key + #table.concat(value, "\n")
  end,
})
```

### Core Implementation

The weighted cache needs entry metadata that the current closure-based design doesn't support. Two options:

**Option A: Separate class with doubly-linked list** (better for weighted cache where entries carry weight metadata):

```lua
-- In lru_cache.lua, add alongside existing M.new()

local WeightedCache = {}
WeightedCache.__index = WeightedCache

function M.new_weighted(opts)
  assert(opts.max_bytes, "new_weighted requires max_bytes")
  assert(opts.weigher, "new_weighted requires weigher function")
  local cache = setmetatable({
    _entries = {},      -- key -> { value, weight, key, prev, next }
    _head = nil,        -- LRU end (evict from here)
    _tail = nil,        -- MRU end (insert here)
    _size = 0,          -- Current item count
    _total_weight = 0,  -- Current total memory weight
    _max_items = opts.max_items or math.huge,
    _max_bytes = opts.max_bytes,
    _weigher = opts.weigher,
  }, WeightedCache)
  return cache
end

function WeightedCache:get(key)
  local entry = self._entries[key]
  if not entry then return nil end
  self:_unlink(entry)
  self:_link_at_tail(entry)
  return entry.value
end

function WeightedCache:put(key, value)
  local weight = self._weigher(key, value)

  -- Remove existing entry if present
  if self._entries[key] then
    self:remove(key)
  end

  -- Evict until within budget
  while self._head and (
    self._total_weight + weight > self._max_bytes or
    self._size >= self._max_items
  ) do
    self:_evict_lru()
  end

  -- Insert new entry at MRU position
  local entry = { value = value, weight = weight, key = key }
  self:_link_at_tail(entry)
  self._entries[key] = entry
  self._size = self._size + 1
  self._total_weight = self._total_weight + weight
end

function WeightedCache:remove(key)
  local entry = self._entries[key]
  if not entry then return end
  self:_unlink(entry)
  self._entries[key] = nil
  self._size = self._size - 1
  self._total_weight = self._total_weight - entry.weight
end

function WeightedCache:clear()
  self._entries = {}
  self._head = nil
  self._tail = nil
  self._size = 0
  self._total_weight = 0
end

function WeightedCache:size() return self._size end

function WeightedCache:entries()
  local node = self._head
  return function()
    if not node then return nil end
    local key, value = node.key, node.value
    node = node.next
    return key, value
  end
end

function WeightedCache:_evict_lru()
  local victim = self._head
  if not victim then return end
  self:_unlink(victim)
  self._entries[victim.key] = nil
  self._size = self._size - 1
  self._total_weight = self._total_weight - victim.weight
end

function WeightedCache:_link_at_tail(entry)
  entry.prev = self._tail
  entry.next = nil
  if self._tail then self._tail.next = entry end
  self._tail = entry
  if not self._head then self._head = entry end
end

function WeightedCache:_unlink(entry)
  if entry.prev then entry.prev.next = entry.next else self._head = entry.next end
  if entry.next then entry.next.prev = entry.prev else self._tail = entry.prev end
  entry.prev = nil
  entry.next = nil
end

function WeightedCache:stats()
  return {
    items = self._size,
    total_bytes = self._total_weight,
    max_bytes = self._max_bytes,
    max_items = self._max_items ~= math.huge and self._max_items or nil,
    utilization = self._total_weight / self._max_bytes,
  }
end
```

**Note:** The weighted cache uses a doubly-linked list (O(1) promote/evict) rather than the existing array-scan approach. This is important because weighted eviction may evict multiple entries per `put()` call, making O(n) scans expensive.

### Weigher Functions for Common Types

```lua
-- In a new file: lua/andrew/vault/cache_weighers.lua
-- Or as a section within lru_cache.lua

local weighers = {}

-- Lines array: file content stored as { lines = string[], mtime = number }
-- Used by: file_cache._cache
function weighers.file_content(key, entry)
  local size = #key + 64  -- key + table overhead + mtime number
  if entry.lines then
    for _, line in ipairs(entry.lines) do
      size = size + #line + 16  -- string header + pointer in array
    end
  end
  return size
end

-- Section entry: { lines = string[], mtime = number }
-- Used by: file_cache._section_cache (keyed by path.."\0"..fragment)
function weighers.section_lines(key, entry)
  local size = #key + 64  -- key + table overhead + mtime number
  if entry.lines then
    for _, line in ipairs(entry.lines) do
      size = size + #line + 16  -- string header + pointer in array
    end
  end
  return size
end

-- Connection result entry: { source_path, results, deps, timestamp, index_gen }
-- Used by: connections._cache
function weighers.connections(key, entry)
  local size = #key + 128  -- key + table overhead + source_path + timestamp + index_gen
  if entry.results then
    for _, r in ipairs(entry.results) do
      size = size + #(r.rel_path or "") + #(r.title or "") + 120
    end
  end
  if entry.deps then
    for dep_path in pairs(entry.deps) do
      size = size + #dep_path + 32  -- key + boolean overhead
    end
  end
  return size
end

-- Note data: ConnectionNoteData with tags, outlinks, inlinks, neighbors, fm_fields
-- Used by: connections._note_data_cache
function weighers.note_data(key, data)
  local size = #key + 128  -- key + rel_path + rel_path_lower + name_lower + ctime + mtime
  -- tag set (tag -> true)
  if data.tags then
    for tag in pairs(data.tags) do size = size + #tag + 24 end
  end
  -- outlink_targets (rel_path -> true)
  if data.outlink_targets then
    for path in pairs(data.outlink_targets) do size = size + #path + 24 end
  end
  -- inlink_sources (rel_path -> true)
  if data.inlink_sources then
    for path in pairs(data.inlink_sources) do size = size + #path + 24 end
  end
  -- neighbors (rel_path -> true)
  if data.neighbors then
    for path in pairs(data.neighbors) do size = size + #path + 24 end
  end
  -- fm_fields (key -> value)
  if data.fm_fields then
    for k, v in pairs(data.fm_fields) do
      size = size + #k + #tostring(v) + 32
    end
  end
  return size
end

-- Section outlinks: { sections = { heading_slug -> { { path, _name_lower }, ... } } }
-- Used by: search_filter/match_field._section_cache
function weighers.section_outlinks(key, data)
  local size = #key + 64
  if data.sections then
    for slug, links in pairs(data.sections) do
      size = size + #slug + 32
      for _, link in ipairs(links) do
        size = size + #(link.path or "") + #(link._name_lower or "") + 48
      end
    end
  end
  return size
end

-- BFS traversal results (BfsCacheEntry)
-- Used by: graph_filter/traversal._bfs_cache
-- Fields: gen, state_hash, depth, forward_like, backlink_like, all_nodes, visited, frontier, truncated, resolve
function weighers.bfs_result(key, result)
  local size = #key + 128  -- key + scalar fields (gen, depth, truncated) + table headers
  if result.state_hash then size = size + #result.state_hash end
  -- visited: table<string, true>
  if result.visited then
    for path in pairs(result.visited) do size = size + #path + 24 end
  end
  -- frontier: array of { rel, d, direction }
  if result.frontier then
    for _, f in ipairs(result.frontier) do
      size = size + #(f.rel or "") + 48  -- rel string + d number + direction string + table overhead
    end
  end
  -- forward_like/backlink_like/all_nodes: arrays of { name, path }
  if result.forward_like then
    for _, n in ipairs(result.forward_like) do size = size + #(n.name or "") + #(n.path or "") + 48 end
  end
  if result.backlink_like then
    for _, n in ipairs(result.backlink_like) do size = size + #(n.name or "") + #(n.path or "") + 48 end
  end
  if result.all_nodes then
    for _, n in ipairs(result.all_nodes) do size = size + #(n.name or "") + #(n.path or "") + 48 end
  end
  -- resolve: function reference, not sized (negligible overhead)
  return size
end

-- Simple string value (slug, date parse results)
function weighers.string_value(key, value)
  return #key + #tostring(value) + 32
end
```

---

## Integration Targets

### 1. File Content Cache (`file_cache.lua`)

The strongest candidate — file sizes vary enormously. Currently uses lazy initialization:

```lua
-- file_cache.lua (current) — lines 11-14, 17-21
local _cache = nil          -- line 11
local _section_cache = nil  -- line 12
local _hits = 0             -- line 13
local _misses = 0           -- line 14

local function ensure_init()  -- line 17
  if _cache then return end
  _cache = lru.new(config.cache.file_content_max or 100)         -- { lines, mtime }
  _section_cache = lru.new(config.cache.section_cache_max or 200) -- { lines, mtime }
end
```

Key details:
- **File content cache** (`_cache`): keyed by absolute path, stores `{ lines = string[], mtime = number }`
- **Section cache** (`_section_cache`): keyed by composite `path .. "\0" .. fragment` (line 73), stores `{ lines = string[], mtime = number }`
- Tracks `_hits`/`_misses` for hit rate statistics (incremented in `M.read()` at lines 38/43)
- `M.read(path, max_lines)` (lines 28-60): only caches unlimited reads (line 55), not partial reads with `max_lines`
- `M.get_section(path, fragment, extract_fn)` (lines 67-92): extracts and caches section data
- `invalidate(path)` (lines 97-111) removes file entry AND scans section cache for matching prefix entries
- `M.stats()` (lines 124-136) returns `file_size`, `file_max`, `section_size`, `section_max`, `hits`, `misses`, `hit_rate`
- Registered with engine via `init.lua:690-710` (not self-registered, to avoid circular deps: engine → link_utils → file_cache)
- Engine registration returns extended stats: entries, max, hits, misses, section_entries, section_max, hit_rate

Proposed:

```lua
-- file_cache.lua (weighted) — inside ensure_init()
_cache = lru.new_weighted({
  max_bytes = config.cache.file_content_bytes,  -- 5 MB default
  max_items = config.cache.file_content_max,    -- 100 hard cap
  weigher = weighers.file_content,
})

_section_cache = lru.new_weighted({
  max_bytes = config.cache.section_cache_bytes, -- 2 MB default
  max_items = config.cache.section_cache_max,   -- 200 hard cap
  weigher = weighers.section_lines,
})
```

**Impact:** A 100-entry file cache could use 50 KB (small files) or 50 MB (large files). With a 5 MB budget, it self-regulates: many small files cached, few large files cached.

### 2. Section Outlinks Cache (`search_filter/match_field.lua`)

Currently uses `lru.new(config.cache.section_cache_max)` (line 53) with generation-aware invalidation. Stores per-file section outlink maps (`{ sections = { heading_slug → outlinks[] } }`) that vary significantly by file complexity.

Key details:
- Keyed by `rel_path`, stores `{ sections = { [heading_slug] = { { path, _name_lower }, ... } } }` (lines 51-52, built at lines 195-199)
- Uses `_lowercase_pool = string_intern.new(5000)` (line 15) for deduplicating lowercased link names
- Generation tracking: `_section_cache_generation` (line 54) compared to `index._generation`
- `maybe_invalidate_section_cache(index)` (lines 58-65) — clears both cache (line 61) and intern pool (line 62) when generation changes
- Called from `search_filter.lua:prepare_evaluate()` before each search execution
- **Not registered** with engine cache registry (invalidation is implicit via generation tracking, not engine dispatch)

```lua
-- search_filter/match_field.lua (weighted)
local _section_cache = lru.new_weighted({
  max_bytes = config.cache.section_outlinks_bytes, -- 2 MB default
  max_items = config.cache.section_cache_max,      -- 200 hard cap
  weigher = weighers.section_outlinks,
})
```

**Note:** The `maybe_invalidate_section_cache()` function also clears `_lowercase_pool` — this interaction is unaffected by switching to weighted LRU.

### 3. Connections Caches (`connections.lua`)

Three caches with variable-size entries. Currently (lines 21-43):

```lua
-- connections.lua (current)
local _cache = lru.new(config.cache.connections_max)         -- line 21: connection result entries
local _note_data_cache = lru.new(config.cache.note_data_max) -- line 36: note metadata tables

-- Also: _idf_cache (manual, not LRU — generation-tracked IDF table)
local _idf_cache = nil              -- line 27: cached IDF table (tag -> doc_count)
local _idf_total = 0               -- line 28: total page count for IDF
local _idf_gen = 0                  -- line 29: generation when IDF was built
local _idf_file_tags = {}           -- line 30: rel_path -> {tag1=true, tag2=true, ...}

-- Subscriber state
local _pending_changed = {}         -- line 40: set of changed rel_paths
local _pending_full_clear = false   -- line 41: flag for full rebuild
local _subscription = nil           -- line 43: subscription handle (initialized at lines 959-961)
```

Key details:
- **`_cache`** keyed by `source_rel_path`, stores `{ source_path, results = ConnectionResult[], deps = { rel_path = true }, timestamp, index_gen }` (stored at lines 753-759)
- **`_note_data_cache`** keyed by `rel_path`, stores `ConnectionNoteData` (built at lines 397-409) with `rel_path`, `rel_path_lower`, `name_lower`, `tags`, `outlink_targets`, `outlink_count`, `inlink_sources`, `neighbors`, `fm_fields`, `ctime`, `mtime`
- **`_idf_cache`** is NOT LRU-based — uses manual generation tracking with incremental updates via `update_tag_idf_incremental()` (lines 100-156)
- Subscriber-based invalidation via `resource_cleanup.subscription_handle()` — `on_index_update()` callback (lines 940-956) populates `_pending_changed` with changed/deleted paths
- Incremental invalidation: `prepare_compute()` (lines 661-681) checks `_note_data_gen != index_gen`, removes only affected entries or does full clear if `_pending_full_clear`
- `M.invalidate_cache()` (lines 49-60) clears both LRU caches, resets IDF state, and unsubscribes
- Dependency-aware: `invalidate_file()` (in `M.setup()` at lines 988-1006) removes both the file's entry AND all entries whose `deps` reference it
- Registered with engine in `M.setup()` (lines 983-1025) as `"connections"` — stats callback returns entries, note_data_entries, index_generation, idf_generation, idf_cached, subscribed, pending_changes

Proposed (only the two LRU caches — `_idf_cache` remains manual):

```lua
-- connections.lua (weighted)
local _cache = lru.new_weighted({
  max_bytes = config.cache.connections_bytes,    -- 3 MB default
  max_items = config.cache.connections_max,      -- 500 hard cap
  weigher = weighers.connections,
})

local _note_data_cache = lru.new_weighted({
  max_bytes = config.cache.note_data_bytes,      -- 2 MB default
  max_items = config.cache.note_data_max,        -- 1000 hard cap
  weigher = weighers.note_data,
})
```

### 4. BFS Traversal Cache (`graph_filter/traversal.lua`)

BFS results vary by graph density. Currently `lru.new(config.cache.bfs_traversal_max)` (line 30, 100 entries).

Key details:
- Keyed by `center_rel` (center note's relative path)
- Stores `BfsCacheEntry` (type at lines 18-28): `{ gen, state_hash, depth, forward_like, backlink_like, all_nodes, visited, frontier, truncated, resolve }`
  - `forward_like`/`backlink_like`/`all_nodes`: arrays of `{ name, path }` — variable size by graph density
  - `visited`: `table<string, true>` — grows with BFS depth
  - `frontier`: array of `{ rel, d, direction }` — remaining unexplored nodes
  - `resolve`: memoized link resolver function (reference, not sized)
- Dual validation: generation check via `filter_utils.is_cache_gen_valid()` (`filter_utils.lua:234-245`) at traversal line 144, AND state hash comparison ensures filter parameter changes invalidate
- Registered with engine in `graph_filter.lua:69-78` as `"graph_filter_bfs"` (not directly in traversal.lua)
- Exposes `M.bfs_cache_size()` (lines 278-280) for stats callback

```lua
-- graph_filter/traversal.lua (weighted)
local _bfs_cache = lru.new_weighted({
  max_bytes = config.cache.bfs_traversal_bytes, -- 1 MB default
  max_items = config.cache.bfs_traversal_max,   -- 100 hard cap
  weigher = weighers.bfs_result,
})
```

### Not Targeted (count-based is sufficient)

These caches store uniformly small entries where count-based limits work well:

| Cache | Module | Reason |
|-------|--------|--------|
| `_slug_cache` | `slug.lua` | Uniform ~50 byte entries |
| `_parse_cache` | `date_utils.lua` | Uniform ~30 byte entries |
| `_dw_cache` | `graph/render.lua` | Uniform integer values |
| `_image_cache` | `embed_images.lua` | Uniform path strings |
| `_fold_state` | `task_hierarchy.lua` | Small fold state objects |

---

## Configuration

```lua
-- config.lua additions to M.cache (currently at lines 821-831)
M.cache = {
  -- Existing count-based limits (unchanged, now serve as hard item caps)
  slug_max = 2000,
  date_parse_max = 5000,
  connections_max = 500,
  section_cache_max = 200,
  note_data_max = 1000,
  display_width_max = 2000,
  bfs_traversal_max = 100,
  image_path_max = 500,
  file_content_max = 100,

  -- New memory-weighted byte budgets
  file_content_bytes = 5 * 1024 * 1024,       -- 5 MB
  section_cache_bytes = 2 * 1024 * 1024,       -- 2 MB
  section_outlinks_bytes = 2 * 1024 * 1024,    -- 2 MB
  connections_bytes = 3 * 1024 * 1024,          -- 3 MB
  note_data_bytes = 2 * 1024 * 1024,           -- 2 MB
  bfs_traversal_bytes = 1 * 1024 * 1024,       -- 1 MB
}
```

Total memory budget across all weighted caches: **15 MB** (vs unbounded worst-case today).

---

## Monitoring

### Extend `engine.cache_debug()` and `:VaultCacheDebug`

The existing debug system (`engine.lua:141-255`) iterates `M._cache_registry` (line 32) and shows entries + fill percentage via `LRU_CONFIG_KEYS`. The `M.cache_stats()` helper (lines 114-124) collects stats from all registered caches. The debug output has four sections: Registered Caches (lines 145-206), LRU Capacity Limits (lines 208-219), Vault Index Summary (lines 221-234), and String Intern Pools (lines 236-252). The `:VaultCacheDebug` command (defined in `init.lua:896-905`) opens a read-only scratch buffer in a bottom split.

**Current `LRU_CONFIG_KEYS` mapping** (`engine.lua:129-136`):

```lua
local LRU_CONFIG_KEYS = {
  connections = "connections_max",
  slug = "slug_max",
  date_parse = "date_parse_max",
  section_cache = "section_cache_max",
  note_data = "note_data_max",
  file_content = "file_content_max",
}
```

Note: `bfs_traversal`, `image_path`, and `display_width` are NOT in `LRU_CONFIG_KEYS` — their fill percentages won't show in debug output without adding them.

**Current `CacheSpec` type** (`engine.lua:34-39`):

```lua
--- @class CacheSpec
--- @field name string           Unique cache identifier
--- @field module string         Module path for display
--- @field invalidate fun()      Full invalidation callback
--- @field invalidate_file? fun(abs_path: string)  Per-file invalidation (optional)
--- @field stats? fun(): CacheStats  Status reporting callback (optional)
```

**Current `CacheStats` type** (`engine.lua:41-45`):

```lua
--- @class CacheStats
--- @field entries number|nil    Number of cached entries
--- @field age_seconds number|nil Seconds since last build/refresh
--- @field vault string|nil      Vault path this cache is scoped to
--- @field ttl number|nil        Configured TTL in seconds (nil = no TTL)
```

**Changes to `engine.lua`:**

1. Add `WEIGHTED_CONFIG_KEYS` mapping (parallel to `LRU_CONFIG_KEYS`) for byte budgets:
   ```lua
   local WEIGHTED_CONFIG_KEYS = {
     connections = "connections_bytes",
     file_content = "file_content_bytes",
     section_cache = "section_cache_bytes",
     note_data = "note_data_bytes",
     graph_filter_bfs = "bfs_traversal_bytes",
   }
   ```

2. Also add missing entries to `LRU_CONFIG_KEYS`:
   ```lua
   graph_filter_bfs = "bfs_traversal_max",
   ```

3. Extend `CacheStats` with optional byte fields:
   ```lua
   --- @field total_bytes number|nil       -- NEW: current byte weight
   --- @field max_bytes number|nil         -- NEW: byte budget
   --- @field utilization number|nil       -- NEW: total_bytes / max_bytes
   ```

4. Have `stats()` callbacks from weighted cache modules return `WeightedCache:stats()` fields

5. Extend `cache_debug()` output to show byte utilization inline and add a memory budget summary section:

```
Vault Cache Debug
========================================

Registered Caches (15)
----------------------------------------
  connections              entries: 312, max: 500, fill: 62.4%, 1.8 MB / 3.0 MB (60%)
  file_content             entries: 38, max: 100, fill: 38.0%, 4.2 MB / 5.0 MB (84%)
  note_data                entries: 847, max: 1000, fill: 84.7%, 1.6 MB / 2.0 MB (80%)
  section_cache            entries: 142, max: 200, fill: 71.0%, 1.3 MB / 2.0 MB (65%)
  graph_filter_bfs         entries: 45, max: 100, fill: 45.0%, 0.3 MB / 1.0 MB (30%)
  slug                     entries: 1847, max: 2000, fill: 92.4%
  date_parse               entries: 3241, max: 5000, fill: 64.8%
  ...

Memory Budget Summary
----------------------------------------
  Total weighted:    10.0 MB / 15.0 MB (66.7%)
```

**Note:** `match_field._section_cache` is NOT registered with the engine cache registry — it uses implicit generation-based invalidation via `maybe_invalidate_section_cache()`. To include it in the memory budget summary, it would need to be registered (either in `init.lua` like `file_cache`, or by adding a registration call in `search_filter.lua`).

---

## Interaction with Existing Systems

### Cache Registry (`engine.register_cache`)

Weighted caches integrate with the existing registry unchanged — they implement the same `invalidate()`, `invalidate_file()`, and `stats()` callbacks. The `stats()` callback simply returns additional byte fields.

Current registration points:
- `file_content`: registered in `init.lua:690-710` (avoids circular dep: engine → link_utils → file_cache)
- `connections`: registered in `connections.lua:M.setup()` (lines 983-1025) as `"connections"`
- `graph_filter_bfs`: registered in `graph_filter.lua:69-78` (wraps `traversal.invalidate_bfs_cache()`)
- `match_field._section_cache`: **NOT registered** — uses `maybe_invalidate_section_cache()` (lines 58-65) called from `search_filter.lua:prepare_evaluate()`

### Generation-Based Caches

Multiple caches use vault index generation (`_generation`) for staleness detection:
- `match_field._section_cache`: `_section_cache_generation` (line 54) compared to `index._generation` in `maybe_invalidate_section_cache()` (lines 58-65)
- `connections._note_data_cache`: `_note_data_gen` (line 37) compared to `index._generation` in `prepare_compute()` (lines 661-681)
- `traversal._bfs_cache`: entries store `gen` field (type line 19), validated via `filter_utils.is_cache_gen_valid()` (`filter_utils.lua:234-245`) + `state_hash` comparison at traversal line 144

These are orthogonal to memory budgets. Upgrading to weighted LRU does not affect generation logic — generation changes trigger `clear()` or `remove()` which correctly adjust `_total_weight`.

### Subscriber-Based Invalidation (`connections.lua`)

Connections uses `resource_cleanup.subscription_handle()` to subscribe to vault index changes. The `on_index_update()` callback (lines 940-956) collects changed/deleted paths into `_pending_changed` (or sets `_pending_full_clear = true` if context is nil). `prepare_compute()` (lines 661-681) performs incremental removal of affected `_note_data_cache` entries. Dependency-aware `invalidate_file()` (lines 988-1006 inside `M.setup()`) scans `_cache` entries' `deps` tables. This pattern is compatible with weighted caching — `remove(key)` correctly adjusts `_total_weight`.

### String Interning (`config.intern`)

String interning pools (configured in `config.intern` at lines 842-848: `tag_pool_max = 500`, `fm_key_pool_max = 200`, `fm_value_pool_max = 2000`, `folder_pool_max = 500`, `lowercase_pool_max = 5000`) are separate from cache entries. `match_field.lua` also has its own `_lowercase_pool = string_intern.new(5000)` (line 15). Interned strings referenced by cache values reduce actual memory but won't be reflected in weigher estimates. This is acceptable — weigher estimates are conservative upper bounds.

---

## Validation

1. **Accuracy test:** Compare weigher estimates with `collectgarbage("count")` before/after cache operations
2. **Eviction test:** Fill cache with large entries, verify small entries survive when budget allows
3. **Mixed workload:** Alternate large and small entries, verify total stays within budget
4. **Edge cases:** Entry larger than max_bytes (should evict all, then insert), zero-weight entries
5. **API compatibility:** Verify weighted cache implements same interface as `M.new()` (get, put, clear, size, remove, entries)
6. **Registry integration:** Verify `:VaultCacheDebug` shows byte utilization for weighted caches
7. **Generation compat:** Verify weighted caches in `match_field.lua` still invalidate on generation change

---

## Expected Impact

| Cache | Before (count-based worst-case) | After (memory-weighted) | Worst-case savings |
|-------|--------------------------------|------------------------|-------------------|
| file_content | Up to 50 MB (100 large files) | Max 5 MB | 45 MB |
| section_cache | Up to 10 MB (200 large sections) | Max 2 MB | 8 MB |
| section_outlinks | Up to 10 MB (200 complex files) | Max 2 MB | 8 MB |
| connections | Up to 5 MB (500 entries) | Max 3 MB | 2 MB |
| note_data | Up to 5 MB (1000 entries) | Max 2 MB | 3 MB |
| bfs_traversal | Up to 2 MB (100 dense graphs) | Max 1 MB | 1 MB |
| **Total** | **Up to ~82 MB** | **Max 15 MB** | **~67 MB** |

The primary benefit is **predictable memory usage** regardless of content variation. Count-based limits create worst-case scenarios that memory-weighted limits prevent entirely. The 15 MB total budget is generous for typical vault usage while preventing runaway memory consumption with large files or dense graphs.
