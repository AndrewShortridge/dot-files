# 01 — LRU Cache Infrastructure

## Priority: HIGH
## Estimated Effort: Small (single new utility module)

## Problem

Multiple modules implement ad-hoc bounded caches with a "catastrophic reset" eviction
strategy — when the cache exceeds a threshold, the entire table is replaced with only
the current entry. This loses all cached work on every overflow.

### Current Cache Inventory

| Module | Variable(s) | Limit | Eviction | Invalidation |
|--------|-------------|-------|----------|--------------|
| `slug.lua` | `_slug_cache`, `_slug_cache_size` | `SLUG_CACHE_MAX = 2000` | Catastrophic reset (keeps current entry) | None |
| `date_utils.lua` | `_parse_cache`, `_parse_cache_size` | `PARSE_CACHE_MAX = 5000` | Catastrophic reset (keeps current entry) | None |
| `connections.lua` | `_cache`, `_cache_size` | `MAX_CACHE_ENTRIES = 500` | Catastrophic reset (keeps current entry) | Generation + TTL + dependency tracking |
| `connections.lua` | `_idf_cache`, `_idf_total`, `_idf_gen`, `_idf_file_tags` | **Unbounded** | None (incremental updates) | Generation-based (full rebuild or incremental depending on vault change) |
| `connections.lua` | `_note_data_cache`, `_note_data_gen` | **Unbounded** | None | Generation-based (full clear on gen change) |
| `connections.lua` | `_index`, `_index_gen` | Single entry | Replaced on gen change | Generation-based |
| `search_filter/match_field.lua` | `_section_cache`, `_section_cache_generation` | **Unbounded** | None | Generation-based (full clear on gen change via `M.maybe_invalidate_section_cache`) |

**Additional per-call caches** (not migration targets — scoped to function lifetime):
- `search_filter.lua`: `build_filter_context()` creates `FilterContext` with `resolved_dates`, `parsed_tags`, `numeric_values` dicts, plus `ctx.resolve_link` via `filter_utils.create_memoized_resolver(index)` (per `evaluate()` call)
- `search_filter/match_field.lua`: Per-node field lowering via `cached_lower()` pattern (mutable cache on AST nodes)
- `search_filter/ast_split.lua`: Classification cache `{}` passed to `classify(node, cache)` (per `split_ast()` call); classification logic lives in `search_filter/classify.lua`
- `search_filter/match_task.lua`: `_state_map` — tiny fixed-size map, module-level persistent cache invalidated on `config.task_states` identity change (reference equality via `_state_map_states == states`)
- `filter_utils.lua`: `create_memoized_resolver(idx)` — closure-based per-evaluate cache with false sentinel for not-found entries
- `filter_utils.lua`: `filter_cache_key(filter_opts)` — builds deterministic string key from filter_opts for cache comparison (used by `task_kanban.lua` and `task_timeline.lua`)

The per-call caches are well-scoped and don't need LRU — they're naturally bounded by
call lifetime. The module-level caches in the table above are the migration targets.

There is no shared LRU utility (`lru_cache.lua` does not exist yet), so each module
either uses catastrophic reset or grows unbounded.

**Other caching infrastructure** (not migration targets but relevant context):
- `completion_base.lua`: Multi-layer caching — `_field_cache` memoizes `build_kv_single_pass` results per `(vault_path, field_name, generation)`, per-source caches track `cached_items`/`cached_vault`/`cached_index_gen`/`build_generation`, `_building_first_seen` tracks 30s timeout for index-building suppression. All invalidated via `M.invalidate_all()` on engine cache events
- `frecency.lua`: `_db` / `_db_vault` in-memory database cache with vault-switch detection
- `url_validate.lua`: `_cache` — TTL-based persistent disk cache (url → {status, checked_at, error}), with status-code-specific TTLs via `config.url_validation.cache_ttl`, persisted to disk with debounced writes
- `highlights.lua`: `_nav_cache` — navigation cache (module-level)
- `engine.lua`: Centralized cache registry (`M._cache_registry`) — modules register via `M.register_cache({ name, module, invalidate, invalidate_file, stats })`, triggered by `M.invalidate_caches(opts)` on `FocusGained`, filesystem events, and vault switches. Supports scope-aware invalidation (`opts.scope = "all"|"files"`, `opts.paths`, `opts.module`, `opts.skip_index`). Also propagates to vault index (`update_files_batch` or `build_async`) and fires `User/VaultCacheInvalidate` autocmd. `M.cache_stats()` returns status for all registered caches.
  Registered modules: `completions` (completion_base), `tasks`, `task_timeline`, `callout_folds`, `calendar_deadlines`, `autolink_index`, `task_kanban`

## Zed Inspiration

Zed uses multiple bounded cache strategies across its codebase:

### Moka Cache (LFU/LRU with weighted eviction)

Used in `crates/extension_host/src/wasm_host.rs` for WASM compilation artifacts:
```rust
// IncrementalCompilationCache (wasm_host.rs:808-839)
#[derive(Debug)]
struct IncrementalCompilationCache {
    cache: Cache<Vec<u8>, Vec<u8>>,  // moka::sync::Cache
}

impl IncrementalCompilationCache {
    fn new() -> Self {
        let cache = Cache::builder()
            .max_capacity(32 * 1024 * 1024)  // 32 MB (~64 novel extensions at ~512KB each)
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

// Singleton via LazyLock (wasm_host.rs:545-549)
fn cache_store() -> Arc<IncrementalCompilationCache> {
    static CACHE_STORE: LazyLock<Arc<IncrementalCompilationCache>> =
        LazyLock::new(|| Arc::new(IncrementalCompilationCache::new()));
    CACHE_STORE.clone()
}
```
Key pattern: **weighted capacity** (bytes, not entry count) with custom weigher function.
Integrated via `config.enable_incremental_compilation(cache_store())` in WASM engine init.
Dependency: `moka = { version = "0.12.10", features = ["sync"] }` in workspace Cargo.toml.

### VecDeque Ring Buffers (multiple bounded caches)

**Markdown doc cache** — 16-entry ring buffer in `crates/editor/src/code_context_menus.rs`:
```rust
const MARKDOWN_CACHE_MAX_SIZE: usize = 16;
const MARKDOWN_CACHE_BEFORE_ITEMS: usize = 2;  // prefetch window
const MARKDOWN_CACHE_AFTER_ITEMS: usize = 2;   // prefetch window
markdown_cache: Rc<RefCell<VecDeque<(MarkdownCacheKey, Entity<Markdown>)>>>,

// Promote on access via rotate_right (lines 651-655):
if is_render && cache_index != 0 {
    markdown_cache.rotate_right(1);
    let cache_len = markdown_cache.len();
    markdown_cache.swap(0, (cache_index + 1) % cache_len);
}
// Evict oldest when full — reuses entity instead of allocating (lines 691-699):
markdown_cache.rotate_right(1);
markdown_cache[0].0 = MarkdownCacheKey::ForCandidate { candidate_id };
let markdown = &markdown_cache[0].1;
markdown.update(cx, |markdown, cx| markdown.reset(source.clone(), cx));
```

**Inline completions** — 50-entry bounded queue in `crates/zeta/src/zeta.rs` (lines 1075-1082):
```rust
pub fn completion_shown(&mut self, completion: &InlineCompletion, cx: &mut Context<Self>) {
    self.shown_completions.push_front(completion.clone());
    if self.shown_completions.len() > 50 {
        let completion = self.shown_completions.pop_back().unwrap();
        self.rated_completions.remove(&completion.id);
    }
    cx.notify();
}
```

**Events cache** — 16-entry with adaptive half-drain in `crates/zeta/src/zeta.rs` (lines 354-358):
```rust
/// Maximum number of events to track.
const MAX_EVENT_COUNT: usize = 16;
self.events.push_back(event);
if self.events.len() >= MAX_EVENT_COUNT {
    // These are halved instead of popping to improve prompt caching.
    self.events.drain(..MAX_EVENT_COUNT / 2);
}
```

**Log file lines** — 1000-line sliding window in `crates/zed/src/zed.rs` (lines 1068-1088):
```rust
const MAX_LINES: usize = 1000;
let mut lines = VecDeque::with_capacity(MAX_LINES);
for line in old_log.iter().flat_map(|log| log.lines())
    .chain(new_log.iter().flat_map(|log| log.lines()))
{
    if lines.len() == MAX_LINES { lines.pop_front(); }
    lines.push_back(line);
}
```

### Object Pooling with RAII Cleanup

**Parser/cursor pools** — global `Mutex<Vec<T>>` pools in `crates/language/src/language.rs` (lines 94-120):
```rust
static QUERY_CURSORS: Mutex<Vec<QueryCursor>> = Mutex::new(vec![]);
static PARSERS: Mutex<Vec<Parser>> = Mutex::new(vec![]);

pub fn with_parser<F, R>(func: F) -> R
where
    F: FnOnce(&mut Parser) -> R,
{
    let mut parser = PARSERS.lock().pop().unwrap_or_else(|| {
        let mut parser = Parser::new();
        parser
            .set_wasm_store(WasmStore::new(&WASM_ENGINE).unwrap())
            .unwrap();
        parser
    });
    parser.set_included_ranges(&[]).unwrap();
    let result = func(&mut parser);
    PARSERS.lock().push(parser);
    result
}
```

**RAII cursor handle** — auto-returns to pool on drop (`crates/language/src/syntax_map.rs`, lines 1879-1908):
```rust
pub(crate) struct QueryCursorHandle(Option<QueryCursor>);

impl QueryCursorHandle {
    pub fn new() -> Self {
        let mut cursor = QUERY_CURSORS.lock().pop().unwrap_or_default();
        cursor.set_match_limit(64);  // cap match count on acquisition
        QueryCursorHandle(Some(cursor))
    }
}

impl Drop for QueryCursorHandle {
    fn drop(&mut self) {
        let mut cursor = self.0.take().unwrap();
        cursor.set_byte_range(0..usize::MAX);  // reset state
        cursor.set_point_range(Point::zero().to_ts_point()..Point::MAX.to_ts_point());
        QUERY_CURSORS.lock().push(cursor)       // return to pool
    }
}
```

**Line wrapper pool** — per-font-size pool in `crates/gpui/src/text_system.rs` (lines 47-598):
```rust
pub struct TextSystem {
    // ...
    wrapper_pool: Mutex<FxHashMap<FontIdWithSize, Vec<LineWrapper>>>,
    font_runs_pool: Mutex<Vec<Vec<FontRun>>>,
    // ...
}

pub struct LineWrapperHandle {
    wrapper: Option<LineWrapper>,
    text_system: Arc<TextSystem>,
}

// LineWrapperHandle auto-returns on drop:
impl Drop for LineWrapperHandle {
    fn drop(&mut self) {
        let mut state = self.text_system.wrapper_pool.lock();
        let wrapper = self.wrapper.take().unwrap();
        state
            .get_mut(&FontIdWithSize { font_id: wrapper.font_id, font_size: wrapper.font_size })
            .unwrap()
            .push(wrapper);
    }
}
```

**Line layout cache** — double-buffered frame cache (`crates/gpui/src/text_system/line_layout.rs`, lines 392-466):
```rust
pub(crate) struct LineLayoutCache {
    previous_frame: Mutex<FrameCache>,
    current_frame: RwLock<FrameCache>,
    platform_text_system: Arc<dyn PlatformTextSystem>,
}

#[derive(Default)]
struct FrameCache {
    lines: FxHashMap<Arc<CacheKey>, Arc<LineLayout>>,
    wrapped_lines: FxHashMap<Arc<CacheKey>, Arc<WrappedLineLayout>>,
    used_lines: Vec<Arc<CacheKey>>,
    used_wrapped_lines: Vec<Arc<CacheKey>>,
}

// finish_frame() swaps buffers and clears current:
pub fn finish_frame(&self) {
    let mut prev_frame = self.previous_frame.lock();
    let mut curr_frame = self.current_frame.write();
    std::mem::swap(&mut *prev_frame, &mut *curr_frame);
    curr_frame.lines.clear();
    curr_frame.wrapped_lines.clear();
    curr_frame.used_lines.clear();
    curr_frame.used_wrapped_lines.clear();
}
```

### Relevance to Lua LRU

For the vault use case, a lightweight LRU built on a hash table + ordered eviction list
is the right analog to Moka's bounded cache. The VecDeque ring buffer patterns
(promote-on-access, evict-oldest) directly inform the LRU design. Object pooling is
not applicable (Lua's GC handles allocation), but the RAII pattern of "reset state
before returning to pool" parallels `:clear()` on cache invalidation.

## Implementation

### New File: `lua/andrew/vault/lru_cache.lua`

```lua
--- Lightweight LRU cache for bounded memoization.
--- Uses a hash table + ordered eviction list.
local M = {}

--- Create a new LRU cache.
---@param max_size number Maximum entries before eviction
---@return table cache instance with :get(), :put(), :clear(), :size()
function M.new(max_size)
  assert(max_size > 0, "LRU max_size must be positive")
  local cache = {}
  local order = {}   -- array of keys in insertion/access order (oldest first)
  local lookup = {}  -- key -> value
  local size = 0

  --- Get a cached value. Returns nil on miss.
  --- Promotes key to most-recently-used on hit.
  function cache:get(key)
    local val = lookup[key]
    if val == nil then return nil end
    -- Promote: remove from current position, append to end
    for i = 1, size do
      if order[i] == key then
        table.remove(order, i)
        order[size] = key
        break
      end
    end
    return val
  end

  --- Insert or update a cache entry.
  --- Evicts least-recently-used entry if at capacity.
  function cache:put(key, value)
    if lookup[key] ~= nil then
      -- Update existing: promote
      lookup[key] = value
      self:get(key) -- promote via get
      return
    end
    -- Evict if at capacity
    if size >= max_size then
      local evict_key = table.remove(order, 1)
      lookup[evict_key] = nil
      size = size - 1
    end
    size = size + 1
    order[size] = key
    lookup[key] = value
  end

  --- Clear all entries.
  function cache:clear()
    for k in pairs(lookup) do lookup[k] = nil end
    for i = 1, size do order[i] = nil end
    size = 0
  end

  --- Current number of entries.
  function cache:size()
    return size
  end

  --- Invalidate a specific key.
  function cache:remove(key)
    if lookup[key] == nil then return end
    lookup[key] = nil
    for i = 1, size do
      if order[i] == key then
        table.remove(order, i)
        size = size - 1
        break
      end
    end
  end

  return cache
end

return M
```

### Performance Note

The O(n) promotion in `:get()` is acceptable for caches up to ~2000 entries.
For the vault use case (slug cache = 2000, date cache = 5000), the linear scan
through the `order` array is negligible compared to the string operations being
cached. If profiling shows this is a bottleneck, replace with a doubly-linked
list (more complex but O(1) promotion).

## Migration Targets

### 1. `slug.lua` — Replace catastrophic reset with LRU eviction

**Current code** (zero-dependency module, cache at module level):
```lua
local _slug_cache = {}
local _slug_cache_size = 0
local SLUG_CACHE_MAX = 2000

function M.heading_to_slug(text)
  local cached = _slug_cache[text]
  if cached then return cached end
  -- ... compute slug ...
  _slug_cache[text] = slug
  _slug_cache_size = _slug_cache_size + 1
  if _slug_cache_size > SLUG_CACHE_MAX then
    _slug_cache = { [text] = slug }
    _slug_cache_size = 1
  end
  return slug
end
```

**After migration:**
```lua
local lru = require("andrew.vault.lru_cache")
local _slug_cache = lru.new(2000) -- config.cache.slug_max

function M.heading_to_slug(text)
  local cached = _slug_cache:get(text)
  if cached then return cached end
  -- ... compute slug ...
  _slug_cache:put(text, slug)
  return slug
end
```

**Note:** `slug.lua` is a zero-dependency module (safe to require from vault_index.lua
and link_utils.lua). Adding `lru_cache.lua` as a dependency is safe since lru_cache.lua
also has zero requires.

### 2. `date_utils.lua` — Replace catastrophic reset with LRU eviction

**Current code** (cache in `parse_iso_datetime`):
```lua
local _parse_cache = {}
local _parse_cache_size = 0
local PARSE_CACHE_MAX = 5000

function M.parse_iso_datetime(s, default_hour)
  local cache_key = default_hour == 0 and s or s .. "\0" .. default_hour
  local cached = _parse_cache[cache_key]
  if cached then return cached end
  -- ... parse datetime ...
  if ts then
    _parse_cache[cache_key] = ts
    _parse_cache_size = _parse_cache_size + 1
    if _parse_cache_size > PARSE_CACHE_MAX then
      _parse_cache = { [cache_key] = ts }
      _parse_cache_size = 1
    end
  end
  return ts
end
```

**After migration:**
```lua
local lru = require("andrew.vault.lru_cache")
local _parse_cache = lru.new(5000) -- config.cache.date_parse_max

function M.parse_iso_datetime(s, default_hour)
  local cache_key = default_hour == 0 and s or s .. "\0" .. default_hour
  local cached = _parse_cache:get(cache_key)
  if cached then return cached end
  -- ... parse datetime ...
  if ts then
    _parse_cache:put(cache_key, ts)
  end
  return ts
end
```

### 3. `connections.lua` — Replace catastrophic reset with LRU eviction

**Current code** (main connection cache with generation + TTL + dependency tracking):
```lua
local MAX_CACHE_ENTRIES = 500
local _cache = {}
local _cache_size = 0
local _cache_vault = nil  -- tracks which vault the cache belongs to

-- Cache lookup in M.compute uses filter_utils.is_cache_gen_valid():
local cached = _cache[source_rel_path]
if filter_utils.is_cache_gen_valid(cached, index_gen, "index_gen")
  and (now - cached.timestamp) < ttl
then
  return cached.results
end

-- Cache store in M.compute (guards against double-counting):
if not _cache[source_rel_path] then
  _cache_size = _cache_size + 1
end
_cache[source_rel_path] = {
  source_path = source_rel_path,
  results = results,
  deps = deps,
  timestamp = now,
  index_gen = index_gen,
}
if _cache_size > MAX_CACHE_ENTRIES then
  local entry = _cache[source_rel_path]
  _cache = { [source_rel_path] = entry }
  _cache_size = 1
end
```

**After migration:**
```lua
local lru = require("andrew.vault.lru_cache")
local _cache = lru.new(500) -- config.cache.connections_max

-- In compute function:
_cache:put(source_rel_path, {
  source_path = source_rel_path,
  results = results,
  deps = deps,
  timestamp = now,
  index_gen = index_gen,
})
```

**Caveat:** `connections.lua` has an `invalidate_file` callback (registered with
`engine.register_cache()`) that does dependency-based invalidation:
```lua
invalidate_file = function(abs_path)
  local rel = engine.vault_relative(abs_path)
  if rel then
    -- Remove the changed file's own cache entry
    if _cache[rel] then
      _cache[rel] = nil
      _cache_size = _cache_size - 1
    end
    -- Invalidate entries that depend on the changed file
    for cached_rel, entry in pairs(_cache) do
      if entry.deps and entry.deps[rel] then
        _cache[cached_rel] = nil
        _cache_size = _cache_size - 1
      end
    end
    -- Clear note data cache for the changed file
    _note_data_cache[rel] = nil
    -- IDF and index will naturally refresh via generation tracking
    -- (vault_index updates its _generation on file changes)
  end
end
```
LRU's `:remove(key)` handles direct invalidation, but the dependency scan needs
the ability to iterate all entries. Options:
1. Add an `:entries()` iterator to the LRU cache
2. Keep a separate `_deps_index` (changed_file → set of cache keys) alongside the LRU
3. Keep `connections.lua` on its own cache with LRU eviction bolted on

Option 2 is cleanest — the deps index is small and lets us do O(1) lookups instead of
scanning all entries.

**Also consider:** `_idf_cache` (with `_idf_total`, `_idf_file_tags`) and `_note_data_cache`
are unbounded but generation-gated. `_idf_cache` supports incremental updates (only
rebuilds changed files when vault stays the same but generation changes; full rebuild on
vault switch). `_note_data_cache` does full clear on generation change. These could use
LRU as a safety net (e.g., 1000 entries each for `_note_data_cache`) even though
generation invalidation keeps them from growing indefinitely in practice. `_idf_cache`
is a single dict (not per-entry), so LRU doesn't apply — it's already bounded by tag
vocabulary size.

There is also a full `M.invalidate_cache()` function (registered as `invalidate` callback
with `engine.register_cache()`) that clears all caches at once — resets `_cache`, `_cache_size`,
`_idf_cache`, `_idf_gen`, `_idf_file_tags`, `_cache_vault`, `_index`, `_index_gen`,
`_note_data_cache`, and `_note_data_gen`. The `stats` callback reports `entries`, `index_generation`,
`idf_generation`, `idf_cached`, and `vault`.

### 4. `search_filter/match_field.lua` — Add bounded section cache

**Current code** (generation-invalidated, unbounded, public function):
```lua
local _section_cache = {}
local _section_cache_generation = -1

function M.maybe_invalidate_section_cache(index)
  local gen = index and index._generation or 0
  if gen ~= _section_cache_generation then
    _section_cache = {}
    _section_cache_generation = gen
  end
end
```

Cache structure: `{ [rel_path] = { sections = { [heading_slug] = outlinks[] } } }`

Populated lazily in `get_section_outlinks()` via `build_file_section_map()`, which
does a single-pass parse of headings and outlinks with propagation up the heading
hierarchy. Called once per `evaluate()` call from search_filter.lua.

**After migration:**
```lua
local lru = require("andrew.vault.lru_cache")
local _section_cache = lru.new(200) -- config.cache.section_cache_max
local _section_cache_generation = -1

function M.maybe_invalidate_section_cache(index)
  local gen = index and index._generation or 0
  if gen ~= _section_cache_generation then
    _section_cache:clear()
    _section_cache_generation = gen
  end
end
```

**Note:** The section cache builds per-file section maps via `build_file_section_map()`,
which parses headings, extracts links, and propagates outlinks up the heading hierarchy.
Each entry is moderately expensive to compute, so LRU eviction (keeping hot files) is
preferable to the current unbounded growth. 200 entries is generous — typical search
sessions touch <50 files.

## Testing

- Unit test `lru_cache.lua` with eviction order verification
- Integration: run `:VaultIndexRebuild` with >2000 headings, verify slug cache
  stays bounded at 2000 entries (check via debug command)
- Add `:VaultCacheDebug` output for LRU cache stats across all migrated caches

## Config

```lua
-- config.lua additions (no existing M.cache section — this is new)
-- Note: connections.lua already has M.connections.cache_ttl = 60
-- Note: url_validation already has its own M.url_validation.cache_ttl table
--       and cache_persist_debounce_ms — those are unrelated to LRU
M.cache = {
  slug_max = 2000,
  date_parse_max = 5000,
  connections_max = 500,
  section_cache_max = 200,
}
```
