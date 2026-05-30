# 09 — Index Memory Reduction

## Priority: LOW
## Estimated Effort: Low (most proposals already implemented)

## Problem

The vault index stores per-file entries with pre-computed fields that trade
memory for speed. While each individual field is justified, the aggregate
cost scales linearly with vault size.

### Current Architecture (Already Optimized)

The vault index (SCHEMA_VERSION = 5, `vault_index.lua:17`) already
implements several memory optimizations:

1. **Metatable lazy fields** (`vault_index.lua:30-80`): `abs_path`, `basename`,
   `basename_lower`, `folder`, `tag_set`, `heading_slugs`, `block_id_set` are
   computed on first access via `__index` and cached via `rawset()`.

2. **Derived field stripping** (`vault_index.lua:21-24`): `DERIVED_FIELDS` list
   (`tag_set`, `heading_slugs`, `block_id_set`, `abs_path`, `basename`,
   `basename_lower`, `folder`) stripped before JSON persistence (~30% size
   reduction).

3. **WAL persistence** (`vault_index.lua:351-383`): Fast delta writes to
   `changes.jsonl` via `_persist_delta()` (lines 351-376) with WAL truncation
   via `_truncate_wal()` (lines 379-383).

4. **Generation-based aggregate caching** (`vault_index.lua:870-942`):
   `_cached_tags`, `_cached_tag_counts`, `_cached_fm_keys`,
   `_cached_name_cache`, `_cached_sorted_names`, `_cached_aliases` rebuilt
   only when `_aggregates_gen != _generation`.

5. **Backward-compat field reconstruction** (`vault_index.lua:289-337`):
   On load, missing pre-computed fields (`rel_stem`, `rel_stem_lower`,
   `_name_lower`, `tags_lower`, timestamps) are rebuilt.

### Per-Entry Memory Breakdown (current, estimated)

| Field | Size (bytes) | Count per file | Total per file |
|-------|-------------|----------------|----------------|
| rel_path, rel_stem, rel_stem_lower | ~200 | 1 | 200 |
| abs_path, basename, basename_lower, folder (lazy) | 0 until accessed | 1 | 0-300 |
| frontmatter dict | ~200 | 1 | 200 |
| aliases array | ~50 | 1 | 50 |
| tags array + tag_set (lazy) | ~100 | 1 | 100 |
| headings array (with slug, text_lower) | ~200 | 1 | 200 |
| heading_slugs (lazy, derived from headings) | 0 until accessed | 1 | 0-100 |
| block_ids array + block_id_set (lazy) | ~100 | 1 | 100 |
| outlinks array (with pre-lowered fields) | ~100 | 20 avg | 2000 |
| tasks array (with text_lower, tags_lower, repeat_rule_lower; parser lines 359-414) | ~200 | 5 avg | 1000 |
| inline_fields dict | ~100 | 1 | 100 |
| mtime, size, ctime, day, day_ts, created_ts, modified_ts | ~60 | 1 | 60 |
| **Total (all lazy fields accessed)** | | | **~4.4 KB** |
| **Total (typical, lazy fields unaccessed)** | | | **~3.6 KB** |

For a 10K-note vault: **~36-44 MB** of index data in memory.

The largest contributor remains **outlinks** (~2KB per file due to pre-computed
`_name_lower`, `stem_lower`, `basename_lower` on each link via
`make_link_entry()` in `vault_index_parser.lua:230-243`).

## Zed Inspiration

Zed's worktree and text buffer systems (`crates/worktree/src/worktree.rs`,
`crates/rope/src/chunk.rs`, `crates/text/src/text.rs`) employ several
memory optimization patterns. Here is what they actually do (corrected from
earlier assumptions):

### 1. Lazy Directory Loading (EntryKind)

**File**: `crates/worktree/src/worktree.rs:3474-3479`

```rust
pub enum EntryKind {
    UnloadedDir,  // Never loaded from filesystem
    PendingDir,   // Found but children not yet scanned
    Dir,          // Fully loaded with children scanned
    File,
}
```

Directories start as `PendingDir` and only become `Dir` when expanded.
**Vault parallel**: The vault index already uses incremental scanning with
mtime+size change detection, but doesn't have a concept of "unloaded" entries.

### 2. Arc\<Path\> Deduplication

**File**: `crates/worktree/src/worktree.rs:3439`

All paths stored as `Arc<Path>` — multiple entries share the same pointer.
Combined with dual-index architecture (`entries_by_path` SumTree +
`entries_by_id` SumTree, lines 164-165) using `PathKey(Arc<Path>)` (line 3784).

**Vault parallel**: Lua strings are interned by the VM for short strings,
but explicit frontmatter interning (see Implementation §2) could extend
this to longer values.

### 3. u128 Bitmap Metadata (Rope Chunks, NOT Entries)

**File**: `crates/rope/src/chunk.rs:12-18`

```rust
pub struct Chunk {
    chars: u128,       // Bitmap: character boundary positions
    chars_utf16: u128, // UTF-16 code unit positions
    newlines: u128,    // Newline positions
    tabs: u128,        // Tab positions
    pub text: ArrayString<MAX_BASE>,  // Max 128 bytes
}
```

Zed uses u128 bitmaps in **rope chunks** (not file entries) to compute line
counts via `POPCNT` (O(1)), char boundaries, and UTF-16 offsets. Entry-level
metadata uses individual bools (`is_ignored`, `is_external`, etc.), not bitsets.

**Vault parallel**: Not directly applicable — the vault doesn't have a rope
structure. But the principle of compact representation for frequently-queried
metadata is relevant.

### 4. inode + mtime Change Detection (NOT Content Hashing)

**File**: `crates/worktree/src/worktree.rs:3440-3441`

Zed does **not** use content hashing. It tracks `inode: u64` + `mtime: Option<MTime>`
for change detection. Content hashing is delegated to git integration.

**Vault parallel**: The vault index already uses mtime+size change detection
(`vault_index.lua`), which matches Zed's approach.

### 5. Dual Visible/Deleted Ropes

**File**: `crates/text/src/text.rs:105-116`

```rust
pub struct BufferSnapshot {
    visible_text: Rope,    // Currently visible content (line 108)
    deleted_text: Rope,    // For undo/redo (line 109)
    fragments: SumTree<Fragment>,  // Metadata about text ranges (line 112)
    // ...
}
```

Fragment visibility determined by `is_visible()` (line 2746) using
deletion sets and undo maps. `RopeBuilder` (lines 2587-2592 struct,
impl block at 2594+) moves text between ropes in a single pass during edits.

**Vault parallel**: Not applicable — vault doesn't track text edits.

### 6. SharedString / ArcCow Pattern

**File**: `crates/gpui/src/shared_string.rs:13-14`, `crates/util/src/arc_cow.rs:9-12`

```rust
pub struct SharedString(ArcCow<'static, str>);

pub enum ArcCow<'a, T: ?Sized> {
    Borrowed(&'a T),  // Zero allocation for static strings
    Owned(Arc<T>),    // Shared ownership for dynamic strings
}
```

Static strings (language names, keywords) borrow at zero cost. Dynamic
strings use `Arc` for cheap cloning.

**Vault parallel**: This is directly analogous to the frontmatter interning
proposal — common string values shared across entries.

### 7. OnceLock Lazy Initialization

**File**: `crates/language/src/language.rs:160-170`

```rust
pub struct CachedLspAdapter {
    manifest_name: OnceLock<Option<ManifestName>>,  // line 168
    attach_kind: OnceLock<Attach>,                  // line 169
    // ...
}
```

Expensive metadata computed once on first access via `get_or_init()`
(lines 288, 292).

**Vault parallel**: This matches the vault's existing metatable `__index`
pattern for lazy field computation.

### 8. Derived Field Stripping in Serialization

**File**: `crates/worktree/src/worktree.rs:5445-5498`

Zed strips `char_bag`, `is_always_included`, `is_private` from protobuf
serialization (lines 5445-5463) and recomputes them on deserialization
(lines 5465-5498): `char_bag` rebuilt from root char_bag + path,
`is_always_included` rebuilt from PathMatcher, `is_private` reset to false.
No disk persistence at all for worktrees — always re-scans filesystem on
startup.

**Vault parallel**: Already implemented — `DERIVED_FIELDS` stripped from
JSON, reconstructed on load via metatable and `_apply_entry_mt()`.

### 9. Shared\<Task\<T\>\> Async Memoization

**File**: `crates/project/src/environment.rs:18,135-138`

Concurrent requests for the same directory environment share a single async
task via `Shared<Task<T>>` (field at line 18) + HashMap `entry().or_insert_with()`
(lines 135-138). Prevents duplicate computation.

**Vault parallel**: The vault's generation-based aggregate caching serves
a similar purpose — rebuilds only when generation changes.

### Key Insight: Compute on Demand vs. Pre-Compute

Zed's dominant pattern is **lazy initialization with caching** (OnceLock,
Arc, or SumTree dimensions). The vault index already applies this for
entry-level fields via metatables. The remaining opportunity is applying
the same pattern to **outlink-level fields** and **frontmatter string
deduplication**.

## Implementation

### ~~1. Lazy Lowercase Computation for Outlinks~~ (Deferred)

**Status**: NOT YET IMPLEMENTED — deferred pending profiling

**File**: `vault_index_parser.lua:230-243`

Currently, `make_link_entry()` pre-computes three lowercase fields per link:
```lua
local name_lower = filter_utils.normalize_link_name(path) or ""  -- line 232
local stem_lower = name_lower:gsub("%.md$", "")                  -- line 233
local basename_lower = stem_lower:match("([^/]+)$") or stem_lower -- line 234
```

These are used by:
- `vault_index.lua` — name index building, inlink computation
- `search_filter/match_field.lua` — link target matching
- `query/index.lua` — query resolution

A metatable approach would defer computation:

```lua
local link_mt = {
  __index = function(t, k)
    if k == "_name_lower" then
      local raw = rawget(t, "path") or ""
      local name = raw:match("^([^#^]+)") or raw
      local v = vim.trim(name):lower()
      rawset(t, k, v)
      return v
    elseif k == "stem_lower" then
      local v = t._name_lower:gsub("%.md$", "")
      rawset(t, k, v)
      return v
    elseif k == "basename_lower" then
      local v = t.stem_lower:match("([^/]+)$") or t.stem_lower
      rawset(t, k, v)
      return v
    end
  end,
}
```

**Savings**: ~60 bytes per outlink x 20 links x 10K files = ~12 MB
(only allocated when accessed, then cached on the link table)

**Trade-off**: Link resolution (wikilinks.lua, inlinks computation) touches
ALL outlinks, so all lowercase fields will be computed anyway — making this
a wash for those code paths. Only saves memory for queries that filter a
subset of links.

**Verdict**: Only implement if profiling shows outlinks are the dominant
memory consumer. The backward-compat reconstruction in `vault_index.lua:303-313`
would also need to be updated to use the metatable instead of eagerly computing.

### ~~2. Deduplicate heading_slugs and headings~~ ALREADY DONE

**Status**: IMPLEMENTED

`heading_slugs` is already computed lazily via metatable `__index`
(`vault_index.lua:59-67`). It derives the slug set from `entry.headings`
on first access and caches via `rawset()`. It's listed in `DERIVED_FIELDS`
and stripped from JSON persistence. Similarly, `block_id_set` is lazy
(`vault_index.lua:68-76`) and `tag_set` is lazy (`vault_index.lua:52-58`).

### ~~3. Don't Persist Derived Fields to JSON~~ ALREADY DONE

**Status**: IMPLEMENTED

`DERIVED_FIELDS` (`vault_index.lua:21-24`) lists fields stripped before
JSON serialization:

```lua
local DERIVED_FIELDS = {
  "tag_set", "heading_slugs", "block_id_set",
  "abs_path", "basename", "basename_lower", "folder",
}
```

On load, `_apply_entry_mt()` (lines 166-168) sets the shared metatable,
and backward-compat reconstruction (lines 289-337) rebuilds missing
pre-computed fields for `rel_stem`/`rel_stem_lower` (lines 296-301),
outlinks `_name_lower`/`stem_lower`/`basename_lower` (lines 303-313),
tasks `tags_lower` (lines 314-322), and timestamps (lines 323-337).

**Note**: Outlink lowercase fields and task `tags_lower` are currently
**persisted** to JSON (not in DERIVED_FIELDS). They are reconstructed on
load only as a backward-compat fallback. Moving them to DERIVED_FIELDS
would reduce JSON size further but add ~50-100ms to cold start for 10K files.

### 4. Intern Common Frontmatter Values

**Status**: IMPLEMENTED

Many notes share common frontmatter values ("type: note", "status: draft").
Lua interns short strings automatically (typically < 40 bytes), but
frontmatter values like long tag strings or descriptions may not benefit.

Inspired by Zed's `SharedString`/`ArcCow` pattern (static borrowing for
common values, shared ownership for dynamic ones):

```lua
local _fm_intern = {}

local function intern(s)
  if type(s) ~= "string" then return s end
  if _fm_intern[s] then return _fm_intern[s] end
  _fm_intern[s] = s
  return s
end

-- In vault_index_parser.lua, when extracting frontmatter values:
for key, value in pairs(raw_frontmatter) do
  entry.frontmatter[intern(key)] = intern(value)
end
```

**Savings**: Depends on frontmatter diversity. Typically 10-30% for vaults
with consistent schemas. Most benefit for keys (which repeat across all
notes) and enum-like values.

**Risk**: Very low — interning is transparent to consumers.

**Implementation note**: The intern table should be module-scoped in the
parser (not global), and could optionally be cleared on full rebuild to
prevent unbounded growth. A weak-value table (`setmetatable(_fm_intern,
{__mode = "v"})`) would allow GC of unused strings.

### 5. Strip Outlink/Task Lowercase Fields from JSON (NEW)

**Status**: IMPLEMENTED

Currently, outlink `_name_lower`/`stem_lower`/`basename_lower` and task
`tags_lower`/`repeat_rule_lower`/`text_lower` are persisted to JSON. These
can all be recomputed from their source fields:

```lua
-- Add to DERIVED_FIELDS or handle in serialization:
-- Outlink: _name_lower from path, stem_lower from _name_lower, basename_lower from stem_lower
-- Task: tags_lower from tags, repeat_rule_lower from repeat_rule, text_lower from text
```

The backward-compat reconstruction already exists (`vault_index.lua:303-322`),
and `strip_derived()` (`vault_index.lua:226-230`) already handles field removal
before JSON encoding (called at lines 362 and 427). Just add these fields to
the stripping logic or to `DERIVED_FIELDS`.

**Savings**: ~40 bytes per outlink x 20 links + ~30 bytes per task x 5 tasks
= ~950 bytes per file on disk. For 10K files: ~9.5 MB smaller JSON.

**Trade-off**: Slightly slower cold start (reconstruct lowercase fields).

## Config

No new config options needed. The existing optimizations are architectural
(baked into vault_index.lua and vault_index_parser.lua). The remaining
proposals (frontmatter interning, JSON field stripping) are safe defaults
that don't require user configuration.

Existing relevant config:
```lua
-- config.lua M.index section (lines 361-396)
M.index.skip_dirs = { ... }          -- dirs to skip (.obsidian, .git, etc.) (lines 363-369)
M.index.batch_size = 20              -- files per async batch tick (line 372)
M.index.persist_debounce_ms = 5000   -- debounce for disk persistence (line 375)
M.index.watch = true                 -- enable filesystem watcher (line 378)
M.index.watch_debounce_ms = 500      -- watcher event debounce (line 381)
M.index.warn_collisions = true       -- warn on name collisions (line 385)
M.index.show_progress = true         -- show index build progress (line 388)
M.index.progress_threshold = 50      -- min files to show progress (line 392)
M.index.collision_notify_ms = 5000   -- collision notification duration (line 395)

-- config.lua M.completion section (lines 401-415) — async build behavior
M.completion.debounce_ms = 250       -- completion debounce (line 405)
M.completion.batch_size = 50         -- items per coroutine yield (line 410)
M.completion.index_build_timeout_secs = 30  -- max wait for index (line 414)

-- config.lua M.cache section (lines 776-785) — LRU eviction limits
M.cache.slug_max = 2000              -- (line 777)
M.cache.date_parse_max = 5000        -- (line 778)
M.cache.connections_max = 500        -- (line 779)
M.cache.section_cache_max = 200      -- (line 780)
M.cache.note_data_max = 1000         -- (line 781)
M.cache.display_width_max = 2000     -- (line 782)
M.cache.bfs_traversal_max = 100      -- (line 783)
M.cache.image_path_max = 500         -- (line 784)
```

## Risk Assessment

| Change | Risk | Status | Reward |
|--------|------|--------|--------|
| Lazy entry fields (metatable) | — | DONE | ~4 MB saved (lazy fields) |
| Derived field stripping (JSON) | — | DONE | ~30% smaller disk |
| WAL persistence | — | DONE | Fast delta writes |
| Generation-based aggregates | — | DONE | No stale cache rebuilds |
| Lazy outlink lowercase | Medium | Deferred | ~12 MB for 10K vault |
| Intern frontmatter values | Very Low | DONE | 10-30% FM string memory |
| Strip outlink/task lowercase from JSON | Low | DONE | ~9.5 MB smaller JSON |

## Testing

- Memory comparison: `:lua print(collectgarbage("count"))` before and after
  frontmatter interning
- Benchmark cold start with/without lowercase fields in JSON
- Verify `wikilinks.resolve_link()` still works after any changes to
  outlink field computation
- Regression test: load old-format index.json (with all fields present)
  to verify backward-compat reconstruction
