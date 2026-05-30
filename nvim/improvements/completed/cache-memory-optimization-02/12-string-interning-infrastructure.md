# 12 — String Interning Infrastructure

## Priority: MEDIUM
## Inspired By: Zed's `SharedString`, `ArcCow`, `Arc<str>`, string deduplication across entities

## Problem

The vault stores many duplicate strings across caches and data structures. Unlike Rust's
`Arc<str>` which shares a single allocation, Lua duplicates every string assignment into
its string intern table — but only for *identical* strings. Derived strings (lowercase
variants, path segments) create new allocations even when logically redundant.

### Duplication Sources

| String Type | Occurrences | Duplication Pattern |
|-------------|-------------|---------------------|
| Tag names | Per-file × per-cache | `"project"` stored in index, completion, search results |
| Folder paths | Per-file in index | `"notes/"`, `"daily/"` repeated for every file in folder |
| Field keys | Per-file frontmatter | `"type"`, `"status"`, `"tags"` in every file's FM dict |
| Field values | Per-file frontmatter | `"note"`, `"draft"`, `"published"` repeated across files |
| Heading text | Per-file + heading_slugs | `"## References"` common across many notes |
| Link names | Per-outlink × _name_lower | `filter_utils.normalize_link_name()` computed per link, not shared |

### Memory Impact (10K-note vault)

```
Tag names:     ~50 unique tags × 200 avg occurrences × 20 bytes = ~200 KB
                (but 50 × 20 bytes = 1 KB if interned)

Folder paths:  ~100 unique folders × 100 avg files × 30 bytes = ~300 KB
                (but 100 × 30 bytes = 3 KB if interned)

FM keys:       ~20 unique keys × 10K files × 15 bytes = ~3 MB
                (but 20 × 15 bytes = 300 bytes if interned)

FM values:     ~200 unique values × avg 50 occurrences × 20 bytes = ~200 KB
                (but 200 × 20 bytes = 4 KB if interned)

Total waste:   ~3.7 MB reducible to ~8 KB
```

**Note:** Lua's built-in string interning handles *identical* string values automatically.
The waste comes from strings that are *logically* the same but created via different code
paths (e.g., `string.lower()` creates a new string each call even if result is same).

### Where Lua Interning Fails

```lua
-- Lua DOES intern these (same literal):
local a = "project"
local b = "project"
-- a and b share same internal string object ✓

-- Lua does NOT guarantee interning for computed strings:
local tag = line:match("#(%w+)")  -- "project" from parsing
local lower = name:lower()        -- "myfile" from lowercasing
-- These MAY or MAY NOT be interned depending on Lua implementation
```

## Existing Interning in Codebase

### completion.lua — Description String Pool

A description-level interning pool already exists in `completion.lua` (lines 151-170):

```lua
local _desc_pool = {}       -- hash table: desc_string → desc_string  (line 151)
local _desc_pool_size = 0                                             -- (line 152)
local _desc_pool_total = 0                                            -- (line 153)
local DESC_POOL_MAX = 500                                             -- (line 154)

local function intern_desc(desc)                                      -- (lines 156-170)
  -- guarded by config.completion.intern_descriptions (default true, line 157)
  -- returns existing string from pool if found (dedup hit)
  -- auto-clears pool when full, adds new string
end
```

- Controlled by `config.completion.intern_descriptions` (default `true`, config.lua line 422)
- Debug stats exposed via `:VaultCompletionDebug` (registered init.lua line 864) → `desc_pool_stats()` (line 527-529)
- Shows: `"Description pool: X unique / Y total (Z% dedup)"`
- Reset on cache invalidation via `reset_desc_pool()` (lines 173-177), called in `build_iter()` (line 226)

This proves the interning pattern works in the codebase. The proposal extends it to
index-level string deduplication across all vault entries.

## Current Architecture Context

### Parsing Pipeline

Parsing is in `vault_index_parser.lua`, NOT inline in `vault_index.lua`:

- **Frontmatter**: `parse_frontmatter(text)` (parser lines 108-157) — extracts YAML-like
  fields, handles lists, inline arrays, type coercion, quote stripping. Stored as
  `entry.frontmatter = fm_fields` (parser line 509). No interning.

- **Tags**: `extract_tags()` (parser lines 160-198) — `add_tag_with_parents()` helper at
  lines 160-168, main function at lines 171-198. Collects from FM `tags` field and
  body hashtags `#([%w_%-][%w_%-/]*)`. `add_tag_with_parents()` adds hierarchy segments.
  Stored as sorted array `entry.tags` (parser line 511). Deduped via set during extraction
  but no cross-entry interning.

- **Folder path**: Lazy-computed via `__index` metatable in `make_entry_mt()` (vault_index.lua lines 47-51,
  metatable defined at lines 30-80):
  ```lua
  elseif key == "folder" then
    local rp = rawget(self, "rel_path")
    local v = rp:match("^(.+)/[^/]+$") or ""
    rawset(self, "folder", v)
    return v
  ```
  Cached per-entry via `rawset()` on first access. No cross-entry sharing.

- **Outlinks**: `make_link_entry()` (parser lines 230-243):
  ```lua
  local name_lower = filter_utils.normalize_link_name(path) or ""
  local stem_lower = name_lower:gsub("%.md$", "")
  local basename_lower = stem_lower:match("([^/]+)$") or stem_lower
  ```
  Lowercase computed via `filter_utils.normalize_link_name()` (filter_utils.lua lines 67-72)
  which strips fragments, trims, then calls `:lower()`. No interning.

### Entry Structure (Schema Version 5)

Primary persisted fields (parser lines 502-521):
```
rel_path, rel_stem, rel_stem_lower, mtime, size, ctime,
frontmatter, aliases, tags, headings, block_ids, outlinks,
tasks, inline_fields, day, created_ts, modified_ts, day_ts
```

Lazy-computed derived fields via `__index` in `make_entry_mt()` (vault_index.lua lines 32-78):
```
abs_path (33-36), basename (37-41), basename_lower (42-46),
folder (47-51), tag_set (52-58), heading_slugs (59-67), block_id_set (68-76)
```

### Pre-computed Lowercase Fields (Already Optimized)

These are computed once at parse time and cached — interning would deduplicate across entries:
- `entry.rel_stem_lower` (parser line 497)
- `entry.basename_lower` — lazy via `__index` (vault_index.lua lines 42-46)
- Heading `text_lower` (parser line 212)
- Task `text_lower` (parser line 392), `tags_lower` (parser line 386-388), `repeat_rule_lower` (parser line 402)
- Outlink `_name_lower`, `stem_lower`, `basename_lower` (parser lines 239-241)

### Index Build Pipeline

- **Full sync**: `build_sync` (vault_index.lua lines 823-833) → `_walk()` → `_rebuild_name_index()` (lines 663-676) → `_recompute_inlinks()` (lines 805-807)
- **Async incremental**: `build_async` (vault_index_build.lua lines 15-171) → `_detect_changes()` (vault_index.lua lines 586-610) at line 23 →
  coroutine batches (`config.index.batch_size`) → incremental `_update_name_index_incremental()` (lines 687-741) for warm starts.
  Cold start detection via `is_cold_start = not index._ready` (build line 20): full rebuild on cold, incremental on warm (lines 105-118).
- **Persistence**: `{vault_path}/.vault-index/index.json` + WAL at `changes.jsonl`
- Derived fields stripped via `strip_derived()` (vault_index.lua lines 226-230) before JSON serialization to reduce size ~30%
- **Change detection**: mtime+size comparison per-file; incremental inlinks via `_recompute_inlinks_incremental()` (lines 812-816)

## Proposed Solution

### 1. String Intern Pool Module

Create `lua/andrew/vault/string_intern.lua`:

```lua
--- String interning pool for deduplicating frequently-repeated strings.
--- Lua interns short strings automatically, but this module ensures
--- computed strings (from lower(), match(), sub()) share allocations.
---
--- Inspired by Zed's SharedString/ArcCow pattern and the existing
--- intern_desc() pool in completion.lua.

local M = {}

--- @class StringPool
--- @field _pool table<string, string> Canonical string references
--- @field _size number Current pool size
--- @field _max number Maximum pool capacity
--- @field _hits number Cache hit count
--- @field _misses number Cache miss count

--- Create a new string pool.
--- @param max number Maximum unique strings to intern (default 10000)
--- @return StringPool
function M.new(max)
  return {
    _pool = {},
    _size = 0,
    _max = max or 10000,
    _hits = 0,
    _misses = 0,
  }
end

--- Intern a string, returning the canonical reference.
--- @param pool StringPool
--- @param s string|nil
--- @return string|nil
function M.intern(pool, s)
  if s == nil or s == "" then return s end

  local canonical = pool._pool[s]
  if canonical then
    pool._hits = pool._hits + 1
    return canonical
  end

  pool._misses = pool._misses + 1

  -- Evict all if over capacity (simple strategy; LRU not needed for strings)
  if pool._size >= pool._max then
    pool._pool = {}
    pool._size = 0
  end

  pool._pool[s] = s
  pool._size = pool._size + 1
  return s
end

--- Intern a string after lowercasing it.
--- @param pool StringPool
--- @param s string|nil
--- @return string|nil
function M.intern_lower(pool, s)
  if s == nil or s == "" then return s end
  return M.intern(pool, s:lower())
end

--- Get pool statistics.
--- @param pool StringPool
--- @return table { size, max, hits, misses, hit_rate }
function M.stats(pool)
  local total = pool._hits + pool._misses
  return {
    size = pool._size,
    max = pool._max,
    hits = pool._hits,
    misses = pool._misses,
    hit_rate = total > 0 and (pool._hits / total * 100) or 0,
  }
end

--- Clear the pool.
--- @param pool StringPool
function M.clear(pool)
  pool._pool = {}
  pool._size = 0
end

return M
```

### 2. Shared Pools for Common String Categories

In `vault_index_parser.lua` (where parsing happens) or a shared location:

```lua
local string_intern = require("andrew.vault.string_intern")

-- Shared pools for different string categories
local _pools = {
  tags = string_intern.new(500),         -- ~50-500 unique tags
  fm_keys = string_intern.new(200),      -- ~20-200 unique FM keys
  fm_values = string_intern.new(2000),   -- ~200-2000 unique FM values
  folders = string_intern.new(500),      -- ~100-500 unique folder paths
  lowercase = string_intern.new(5000),   -- General lowercase cache
}
```

### 3. Integration Points

#### vault_index_parser.lua — Frontmatter Parsing (~line 108-157)

```lua
-- BEFORE (parse_frontmatter returns fm_fields dict as-is):
fields[key] = value  -- or fields[key] = list

-- AFTER:
local si = require("andrew.vault.string_intern")
local ikey = si.intern(_pools.fm_keys, key)
local ival = type(value) == "string" and si.intern(_pools.fm_values, value) or value
fields[ikey] = ival
-- For list values, intern each string element:
-- for i, item in ipairs(list) do
--   list[i] = type(item) == "string" and si.intern(_pools.fm_values, item) or item
-- end
```

#### vault_index_parser.lua — Tag Extraction (~lines 160-198)

```lua
-- BEFORE (add_tag_with_parents inserts raw strings into set):
set[tag] = true

-- AFTER:
set[si.intern(_pools.tags, tag)] = true
```

#### vault_index.lua — Folder Path (lazy __index in make_entry_mt(), lines 47-51)

```lua
-- BEFORE:
elseif key == "folder" then
  local rp = rawget(self, "rel_path")
  local v = rp:match("^(.+)/[^/]+$") or ""
  rawset(self, "folder", v)
  return v

-- AFTER:
elseif key == "folder" then
  local rp = rawget(self, "rel_path")
  local raw = rp:match("^(.+)/[^/]+$") or ""
  local v = si.intern(_pools.folders, raw)
  rawset(self, "folder", v)
  return v
```

#### vault_index_parser.lua — Outlink Lowercase (lines 230-243, make_link_entry)

```lua
-- BEFORE:
local name_lower = filter_utils.normalize_link_name(path) or ""
local stem_lower = name_lower:gsub("%.md$", "")
local basename_lower = stem_lower:match("([^/]+)$") or stem_lower

-- AFTER:
local raw_name_lower = filter_utils.normalize_link_name(path) or ""
local name_lower = si.intern(_pools.lowercase, raw_name_lower)
local stem_lower = si.intern(_pools.lowercase, name_lower:gsub("%.md$", ""))
local basename_lower = si.intern(_pools.lowercase, stem_lower:match("([^/]+)$") or stem_lower)
```

#### vault_index_parser.lua — Heading text_lower (line 212)

```lua
-- BEFORE:
text_lower = text:lower()

-- AFTER:
text_lower = si.intern_lower(_pools.lowercase, text)
```

### 4. Pool Lifecycle

```lua
-- Clear pools on full index rebuild (new strings expected)
-- In vault_index.lua build_sync (line 823) or vault_index_build.lua:
function clear_intern_pools()
  for _, pool in pairs(_pools) do
    string_intern.clear(pool)
  end
end

-- Pools persist across incremental updates (good: reuses existing strings)
-- Pools cleared on VaultIndex:rebuild() / build_sync, NOT on incremental build_async
--
-- Optimal integration points in vault_index_build.lua:
--   After line 23 (post _detect_changes, before parsing) — for cold start full rebuilds
--   build_async uses is_cold_start (line 20) to decide full vs incremental rebuild
--   Cold start → full _rebuild_name_index() (line 105-106)
--   Warm start → incremental _update_name_index_incremental() (line 107-109)
```

### 5. Debug Visibility

Add to `:VaultCacheDebug` (registered in init.lua line 869, palette line 878):

```lua
-- String Intern Pools:
--   tags:      45/500   (hit rate: 97.2%)
--   fm_keys:   18/200   (hit rate: 99.8%)
--   fm_values: 156/2000 (hit rate: 94.1%)
--   folders:   42/500   (hit rate: 98.5%)
--   lowercase: 1847/5000 (hit rate: 89.3%)
```

This mirrors the existing `:VaultCompletionDebug` pattern that already reports
`desc_pool_stats()` for the completion description interning pool.

### 6. Relationship to Existing completion.lua Interning

The existing `intern_desc()` in completion.lua is a single-purpose pool. Options:
- **Option A**: Keep it separate (it's completion-specific, small scope)
- **Option B**: Migrate to use `string_intern.lua` module for consistency

Recommended: **Option A** initially — avoid coupling completion to index pools.
Later unify if the pattern proves stable.

## Configuration

Add to `config.lua` alongside existing `M.cache` section (lines 789-798, file ends at line 807):

```lua
M.intern = {
  enabled = true,           -- Master toggle
  tag_pool_max = 500,
  fm_key_pool_max = 200,
  fm_value_pool_max = 2000,
  folder_pool_max = 500,
  lowercase_pool_max = 5000,
}
```

## Zed Reference

### SharedString — `crates/gpui/src/shared_string.rs` (140 lines)

```rust
// SharedString wraps ArcCow for hybrid borrowed/owned string sharing (line 14)
#[derive(Deref, DerefMut, Eq, PartialEq, PartialOrd, Ord, Hash, Clone)]  // line 13
pub struct SharedString(ArcCow<'static, str>);

impl SharedString {
    // Zero-copy for static strings (compile-time constants) (lines 18-20)
    pub const fn new_static(str: &'static str) -> Self {
        Self(ArcCow::Borrowed(str))
    }
    // Arc-backed for dynamic strings (cheap clone via refcount) (lines 23-25)
    pub fn new(str: impl Into<Arc<str>>) -> Self {
        SharedString(ArcCow::Owned(str.into()))
    }
}

// Trait impls: PartialEq<String> (72-94), From conversions (96-121),
// Display/Debug (60-70), AsRef<str> (48-52), Borrow<str> (54-58),
// Default (42-46), Serialize/Deserialize (123-140), JsonSchema (28-40)
```

### ArcCow — `crates/util/src/arc_cow.rs` (141 lines)

```rust
// Hybrid borrowed/owned type — avoids Arc allocation for static strings (lines 9-12)
pub enum ArcCow<'a, T: ?Sized> {
    Borrowed(&'a T),   // Zero-cost reference
    Owned(Arc<T>),     // Atomic shared ownership, cheap clone
}

// Trait impls: PartialEq/PartialOrd/Ord/Eq (14-34), Hash (36-43), Clone (45-52),
// From conversions including String/&str/Vec<T>/Cow (54-103),
// Borrow (105-112), Deref (114-123), AsRef (125-132), Debug (134-141)
```

### LanguageName Wrapper — `crates/language/src/language_registry.rs` (lines 39-104)

```rust
// Type-safe wrapper: SharedString used for bounded set of language names (lines 39-42)
#[derive(Debug, Clone, Hash, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema)]
pub struct LanguageName(pub SharedString);

impl LanguageName {                                       // lines 44-61
    pub fn new(s: &str) -> Self { Self(SharedString::new(s)) }       // 45-47
    pub fn from_proto(s: String) -> Self { Self(SharedString::from(s)) }  // 49-51
    pub fn to_proto(self) -> String { /* ... */ }                    // 52-54
    pub fn lsp_id(&self) -> String { /* "Plain Text" → "plaintext" */ }   // 55-60
}
// 7 trait impls: From<LanguageName>/From<SharedString>/AsRef<str>/Borrow<str>/Display/From<&str>/From→String (lines 63-104)
// In LanguageRegistryState (line 113):
//   grammars: HashMap<Arc<str>, AvailableGrammar> (line 118)
//   lsp_adapters: HashMap<LanguageName, Vec<Arc<CachedLspAdapter>>> (line 119)
// Natural deduplication through HashMap key collision
```

### Arc<str> Usage Patterns

```rust
// Language config — grammar names, comments (language.rs LanguageConfig struct, lines 680-696)
pub code_fence_block_name: Option<Arc<str>>,  // line 685
pub grammar: Option<Arc<str>>,                // line 687
pub line_comments: Vec<Arc<str>>,             // line 729

// Block comment config also uses Arc<str> (language.rs lines 841-850)
pub struct BlockCommentConfig {
    pub start: Arc<str>,   // line 843
    pub end: Arc<str>,     // line 845
    pub prefix: Arc<str>,  // line 847
    pub tab_size: u32,     // line 849
}

// Language registry — HashMap keys naturally deduplicate (language_registry.rs line 118)
grammars: HashMap<Arc<str>, AvailableGrammar>,

// File type associations (language_settings.rs line 64)
file_types: FxHashMap<Arc<str>, GlobSet>,

// Formatter command (language_settings.rs lines 910-915)
External { command: Arc<str>, arguments: Option<Arc<[String]>> },

// Buffer edits share text (buffer.rs line 508)
pub edits: Vec<(Range<usize>, Arc<str>)>,
```

### Arc<Path> for Path Sharing

```rust
// Worktree uses SanitizedPath wrapper (worktree.rs Snapshot struct, lines 159-179)
pub struct Snapshot {
    abs_path: SanitizedPath,  // wraps Arc<Path> (line 161, SanitizedPath imported at line 69)
    always_included_entries: Vec<Arc<Path>>,
    // ...
}

// Entry stores path as Arc<Path> (worktree.rs lines 3436-3471, path field at line 3439)
pub struct Entry {
    pub path: Arc<Path>,
    pub canonical_path: Option<Arc<Path>>,  // line 3443
    // ...
}

// LocalSnapshot struct (worktree.rs lines 357-368)
struct LocalSnapshot {
    snapshot: Snapshot,                                                    // line 358
    ignores_by_parent_abs_path: HashMap<Arc<Path>, (Arc<Gitignore>, bool)>,  // line 361
    git_repositories: TreeMap<ProjectEntryId, LocalRepositoryEntry>,       // line 364
    root_file_handle: Option<Arc<dyn fs::FileHandle>>,                    // line 367
}

// Arc<Path> fields distributed across related structs:
// BackgroundScannerState (lines 370-382):
//   path_prefixes_to_scan: HashSet<Arc<Path>>,  // line 373
//   paths_to_scan: HashSet<Arc<Path>>,           // line 374
// LocalRepositoryEntry (lines 385-407):
//   work_directory_abs_path: Arc<Path>,           // line 388

// WorkDirectory enum variants use Arc<Path> (worktree.rs lines 187-195)
pub enum WorkDirectory {
    InProject { relative_path: Arc<Path> },
    AboveProject { absolute_path: Arc<Path>, location_in_repo: Arc<Path> },
}

// Path trie interns path components as Arc<OsStr> (project/src/manifest_tree/path_trie.rs lines 16-20)
pub struct RootPathTrie<Label> {
    worktree_relative_path: Arc<Path>,
    labels: BTreeMap<Label, LabelPresence>,
    children: BTreeMap<Arc<OsStr>, RootPathTrie<Label>>,
}
```

### Content Deduplication — `crates/semantic_index/src/semantic_index.rs` (lines 109-144)

```rust
// Sequential file content cache: avoids re-reading when multiple results from same file
// Declaration at line 109, filter at lines 114-119, reassignment at lines 138-143
let mut last_loaded_file: Option<(Entity<Worktree>, Arc<Path>, PathBuf, String)> = None;
// If same file as previous result, reuse content string
```

### Blake3 Digest Deduplication — `crates/semantic_index/src/summary_index.rs`

```rust
// Content-addressed summary cache
pub type Blake3Digest = ArrayString<{ blake3::OUT_LEN * 2 }>;  // line 63
pub struct FileDigest {     // lines 65-69
    pub mtime: Option<MTime>,
    pub digest: Blake3Digest,
}

// Two-level DB: file_digest_db (path → digest+mtime), summary_db (digest → summary)
file_digest_db: heed::Database<Str, SerdeBincode<FileDigest>>,              // line 85
summary_db: heed::Database<SerdeBincode<Blake3Digest>, Str>,                // line 86

// Digest generation incorporates path + contents (lines 448-456)
// hasher.update(path) at line 453, hasher.update(contents) at line 454
// so context-dependent code (e.g., Rails controllers) gets unique digests
```

### SHA256 Chunk Deduplication — `crates/semantic_index/src/chunking.rs`

```rust
// Per-chunk content digests for embedding cache (lines 26-29, used at 153-156 and 194-197)
pub struct Chunk { pub range: Range<usize>, pub digest: [u8; 32] }
// TextToEmbed wraps text+SHA256 digest (embedding.rs lines 86-100)
```

### Key Design Pattern

Zed does NOT use a global string interning pool. Instead, deduplication happens implicitly:
1. `Arc` sharing — multiple references to same `Arc<str>`/`Arc<Path>` share allocation
2. `HashMap` keys — naturally deduplicate bounded string sets (grammars, languages, file types)
3. Static borrowing — `ArcCow::Borrowed` for compile-time constants (zero allocation)
4. Content hashing — Blake3/SHA256 digests for content-addressed caching
5. Sequential caching — `last_loaded_file` avoids re-reading same file across results

## Expected Impact

| String Category | Before (10K vault) | After | Savings |
|-----------------|---------------------|-------|---------|
| FM keys | ~3 MB | ~300 B | ~3 MB |
| FM values | ~200 KB | ~4 KB | ~196 KB |
| Tags | ~200 KB | ~1 KB | ~199 KB |
| Folders | ~300 KB | ~3 KB | ~297 KB |
| Lowercase (links) | ~12 MB (see doc 09) | ~100 KB | ~11.9 MB |
| **Total** | **~15.7 MB** | **~108 KB** | **~15.6 MB** |

**Note:** Actual savings depend on Lua's internal interning behavior. LuaJIT and PUC Lua
intern all strings shorter than ~40 bytes automatically. The biggest wins come from
longer strings and computed (lowercased) strings that bypass automatic interning.

## Testing Strategy

1. Build index on 10K vault, check pool stats via `:VaultCacheDebug`
2. Verify hit rates > 80% for tags, FM keys (indicates deduplication working)
3. Memory comparison: `collectgarbage("count")` before/after enabling interning
4. Verify `entry.frontmatter["type"]` identity equality across files: `rawequal(a, b)`
5. Benchmark: index build time should not regress (pool lookup is O(1) hash)
6. Compare with existing `:VaultCompletionDebug` desc_pool dedup rates as baseline

## Dependencies

- Independent module (no dependencies)
- Complements doc 09 (Index Memory Reduction) — interning addresses the same problem
  from a different angle (shared references vs lazy computation)
- Can be adopted incrementally (one integration point at a time)
- Existing `completion.lua` intern_desc() proves the pattern works in this codebase

## Relationship to Doc 09

Doc 09 proposes lazy lowercase via metatables. This document proposes interning as an
alternative/complement:

| Approach | Memory Savings | CPU Cost | Complexity |
|----------|---------------|----------|------------|
| Doc 09: Lazy metatable | Defer allocation | First-access overhead | Medium (metatable) |
| Doc 12: String interning | Share allocations | Hash lookup on create | Low (simple pool) |
| Both combined | Maximum savings | Minimal | Medium |

**Recommendation:** Implement interning first (simpler, immediate savings), then evaluate
whether lazy metatables provide additional benefit.
