# 06 — Connections Cache Optimization

## Priority: MEDIUM
## Estimated Effort: Low (most work already done)

## Current State

The connections module (`connections.lua`) already implements significant
caching and incremental optimization. This document tracks what exists,
what remains, and Zed-inspired patterns that could further improve it.

### Already Implemented

1. **Incremental IDF updates** (lines 108-165, `update_tag_idf_incremental`):
   Three-path logic in `M.compute` (lines 536-560):
   - Generation changed, same vault → incremental update via `_idf_file_tags` diff
   - Generation unchanged → reuse cached `_idf_cache` and `_idf_total`
   - No cache or vault changed → full rebuild via `build_tag_idf`

2. **LRU result cache** (line 31):
   - `_cache = lru.new(config.cache.connections_max)` (max 500 entries)
   - Each entry stores: `source_path`, `results`, `deps`, `timestamp`, `index_gen`
   - TTL: `config.connections.cache_ttl` (60 seconds)

3. **LRU note data cache** (lines 41-42):
   - `_note_data_cache = lru.new(config.cache.note_data_max)` (max 1000 entries)
   - Tracks generation via `_note_data_gen`
   - `get_note_data()` at lines 418-425 retrieves from cache or builds via
     `build_note_data()` (lines 357-411)

4. **Per-file invalidation** (lines 869-888, `invalidate_file` callback):
   - Removes changed file's own cache entry (line 873)
   - Scans all cached entries via `_cache:entries()` and removes those with
     `deps` referencing the changed file (lines 876-883)
   - Removes changed file from `_note_data_cache` (line 885)

5. **Early pruning with min-heap** (lines 454-514, `create_top_k`):
   - Maintains top-K results during scoring
   - Skips candidates when `tag_score + max_remaining < heap_min`

6. **Bridge computation cap** (via `config.connections.weights.max_2hop_bridges = 5`)

7. **Engine registration** (lines 864-902, `M.setup()`):
   - `engine.register_cache()` (engine.lua:49-53) with `invalidate`, `invalidate_file`,
     and `stats` callbacks
   - Engine's `invalidate_caches()` (engine.lua:57-110) routes per-file calls
     when `scope = "files"` and ≤10 paths changed (engine_watcher.lua:154-158)
   - LRU module at `lru_cache.lua` provides `get/put/clear/size/remove/entries`

### Remaining Gap

**Note data cache cleared entirely on generation change** (lines 536-540):
```lua
if _note_data_gen ~= index_gen then
  _note_data_cache:clear()
  _note_data_gen = index_gen
end
```

When any file changes (generation increments), ALL cached note data is
discarded. For a 5K-note vault where one file changes, this means
rebuilding `ConnectionNoteData` for every file scored in the next query.

**Generation polling** (lines 67-80, `get_index()`):
The module polls `vault_index._generation` on each `M.compute()` call
(line 69: `local gen = idx and idx._generation or 0`), comparing against
`_index_gen` to detect staleness. It does not use `vault_index:subscribe()`.

## Problem (Remaining)

1. **Note data over-invalidation**: Single file edit clears entire
   `_note_data_cache` (up to 1000 LRU entries), forcing full rebuild
   of `ConnectionNoteData` for every file in next query
2. **No subscriber integration**: Connections uses generation polling,
   not `vault_index:subscribe()`. It cannot know WHICH files changed,
   only THAT something changed — preventing targeted note data updates

### Memory per Connection Query

For a 5K-note vault with avg 10 tags, 20 outlinks per note:
- ConnectionNoteData per file: ~500 bytes (tags set, outlinks set, inlinks set,
  neighbors union, frontmatter fields, timestamps)
- Total per query (cache miss): 5000 × 500 = ~2.5 MB transient allocation
- IDF table: ~50 KB (one entry per unique tag)
- Result cache entry: ~3 KB (30 results × ~100 bytes each)

## Zed Inspiration

Zed's approach to expensive computations (verified against current codebase):

1. **Priority-based deferred computation** (`crates/worktree/src/worktree.rs:3893-3931`):
   `futures::select_biased!` (imported at line 17) prioritizes scan requests >
   path prefix loads > FS events. The `BackgroundScannerPhase` enum (lines 3818-3822)
   defines phases: `InitialScan` → `EventsReceivedDuringInitialScan` → `Events`,
   with the phase set to `Events` at line 3890 before the main loop. Additional
   `select_biased!` usages at lines 4178 and 4656 handle other scanning phases.

2. **Incremental updates via `UpdatedEntriesSet`** (`crates/worktree/src/worktree.rs:3513`):
   Type alias: `Arc<[(Arc<Path>, ProjectEntryId, PathChange)]>`. Used extensively:
   `ScanState::Updated` (lines 453-458), `UpdateObservationState` (lines 464-468),
   `Event::UpdatedEntries` (line 472), and as mpsc channel type (line 2045).
   In `embedding_index.rs:80-100`, `index_updated_entries()` accepts this type;
   `scan_updated_entries()` (lines 182-224, dispatch at 192-213) dispatches on `PathChange` variants:
   `Added | Updated | AddedOrUpdated` → index entry, `Removed` → delete range,
   `Loaded` → no-op.

3. **Multi-level change detection** (`crates/worktree/src/worktree.rs:2950-2967`):
   - Primary: inode comparison (fast rename detection)
   - Secondary: mtime comparison (content changes)
   - Tertiary: path matching (path updates)
   `reuse_entry_id()` checks `removed_entries` by inode, conditionally reuses
   entry ID if mtime or path matches. Called from `insert_entry()` (line 2969)
   and during scanning (line 4420).

4. **Content-hash deduplication** (`crates/semantic_index/src/summary_index.rs`):
   BLAKE3 hash of file contents + path (`digest_files()` at line 417, hash
   computation at lines 448-456). `Blake3Digest` type (line 63) and `FileDigest`
   struct (lines 66-69). Two-tier cache: `file_digest_db` (path → {mtime, digest}) and `summary_db`
   (digest → summary) at lines 85-86. Cache lookup in `check_summary_cache()`
   (lines 249-287): same content = same cached summary regardless of path or mtime.

5. **Batching with thresholds** (`crates/semantic_index/src/summary_backlog.rs:5-6`):
   `MAX_FILES_BEFORE_RESUMMARIZE = 4` and `MAX_BYTES_BEFORE_RESUMMARIZE = 1_000_000`.
   `SummaryBacklog` (lines 8-14) accumulates work; `needs_drain()` (lines 29-34) checks both
   thresholds using cached `total_bytes` aggregate for O(1) checks.

6. **Streaming pipeline** (`crates/semantic_index/src/embedding_index.rs:59-78`):
   Staged async pipeline: `scan_entries()` → `chunk_files()` → `embed_files()` →
   `persist_embeddings()`, connected via async channels. Each stage runs
   concurrently via `futures::try_join!`. Embed stage uses `chunks_timeout(512,
   Duration::from_secs(2))` batching (line 286). Persist stage interleaves
   deletes and inserts (lines 358-398).

### Key Insight: Targeted Invalidation via Change Context

The vault index already provides `changed_paths` and `deleted_paths` via
its subscriber API (`vault_index:subscribe(fn)` at vault_index.lua:182-192).
Subscribers receive `(generation, context)` where context contains:
- `changed_paths`: array of absolute paths of changed/new files
- `deleted_paths`: array of absolute paths of deleted files

Context is populated from `vault_index_build.lua:update_files_batch()` (lines 178-237)
which converts relative paths to absolute via `vault_path .. "/" .. rel_path`
(lines 223-235). Note: `build_async()` calls `_notify_update()` with nil context
(line 123), meaning a full async rebuild does not provide per-file change info —
only incremental `update_files_batch()` calls do.

Currently only `embed_sync.lua` (line 102) subscribes, using an inverted
dependency index (`_dep_to_bufs`) for O(changed_paths) buffer lookups.
The connections module should subscribe similarly.

## Implementation

### 1. Subscribe to Vault Index for Changed Paths

**File**: `connections.lua`

Replace generation polling with subscriber-based change tracking:

```lua
local _pending_changed = {}  -- rel_path -> true
local _unsubscribe = nil

local function on_index_update(_gen, context)
  if context then
    local vault_path = engine.vault_path or ""
    local prefix = vault_path .. "/"
    for _, abs_path in ipairs(context.changed_paths or {}) do
      local rel = abs_path:sub(#prefix + 1)
      _pending_changed[rel] = true
    end
    for _, abs_path in ipairs(context.deleted_paths or {}) do
      local rel = abs_path:sub(#prefix + 1)
      _pending_changed[rel] = true
    end
  else
    -- No context = full rebuild needed (build_async completion, vault switch)
    _note_data_cache:clear()
    _note_data_gen = 0
  end
end

-- In setup(), after engine registration:
local idx = vault_index.current()
if idx then
  _unsubscribe = idx:subscribe(on_index_update)
end
```

Note: `engine.vault_relative(abs_path)` (used by `invalidate_file`) could
also be used here instead of manual prefix stripping, for consistency.

### 2. Incremental Note Data Cache Update

**File**: `connections.lua`

Replace the full `_note_data_cache:clear()` on generation change with
targeted updates using `_pending_changed`:

```lua
-- In M.compute, replace the current block (lines 536-540):
if _note_data_gen ~= index_gen then
  -- Incremental: only rebuild note data for files that actually changed
  if next(_pending_changed) then
    for rel_path in pairs(_pending_changed) do
      _note_data_cache:remove(rel_path)
    end
    _pending_changed = {}
  end
  _note_data_gen = index_gen
end
```

This removes only changed entries from the LRU cache. Unchanged entries
survive and are reused on next query. `build_note_data` is called lazily
when a cache-missed entry is needed during scoring (via `get_note_data()`
at lines 418-425).

### 3. Selective Result Cache Invalidation via Subscriber

The existing `invalidate_file` callback already handles per-file result
cache invalidation via `deps` tracking (lines 869-889). The engine watcher
(`engine_watcher.lua:154-158`) calls `invalidate_caches({ scope = "files" })`
for ≤10 changed files, which routes to each cache's `invalidate_file`.
The subscriber integration from step 1 could additionally trigger
`invalidate_file` proactively, but this is optional since engine already
handles it on file save events.

## Existing Config (No Changes Needed)

```lua
-- config.lua (lines 283-295)
M.connections = {
  cache_ttl = 60,
  max_results = 30,
  weights = {
    tags = 3.0,
    frontmatter = 2.0,
    colink = 2.5,
    link_1hop = 5.0,
    link_2hop = 2.0,
    temporal = 1.0,
    max_2hop_bridges = 5,
  },
}

-- config.lua (lines 776-785)
M.cache = {
  slug_max = 2000,
  date_parse_max = 5000,
  connections_max = 500,   -- result cache LRU limit
  section_cache_max = 200,
  note_data_max = 1000,    -- note data cache LRU limit
  display_width_max = 2000,
  bfs_traversal_max = 100,
  image_path_max = 500,
}
```

## Expected Impact

| Metric | Current | After |
|--------|---------|-------|
| IDF rebuild on single file edit | Incremental (already done) | No change |
| Result cache invalidation on file edit | Per-file via deps (already done) | No change |
| Note data cache on single file edit | Full clear (1000 entries) | Remove 1 entry |
| Note data rebuilds per query (warm) | O(N) on any generation change | O(changed files) |
| Subscriber overhead | None (generation polling) | Minimal (set insert per changed path) |

## Testing

- Edit a single file, verify `_note_data_cache` retains entries for unchanged files
- Edit file A, verify connections cache for file B (unrelated) is preserved
  (already works via `invalidate_file` + `deps`)
- Run `:VaultConnections` on 100 files, verify note data cache hits via
  `:VaultCacheStats`
- Verify subscriber cleanup on vault switch (unsubscribe called, caches cleared)
- Verify full cache clear when subscriber context is nil (build_async completion)
- Verify incremental path via `update_files_batch()` provides context with
  changed/deleted paths (not nil)
