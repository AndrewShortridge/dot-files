# 76 --- Index Build Merge & Precomputation

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

Targeted improvements for the vault index build and maintenance pipeline,
addressing full name index rebuilds on incremental updates, triple
iteration during index construction, uncached aggregate queries, redundant
`rel_stem` computation in inlinks, and O(N) file counting.

> **Modules affected:** `vault_index.lua`, `vault_index_build.lua`,
> `vault_index_parser.lua`, `vault_index_inlinks.lua`

---

## 1. Incremental Name Index in build_async()

**Status:** IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/vault_index_build.lua` (line 84)

After parsing all changed files in batches, `build_async()` always
calls `_rebuild_name_index()` which scans ALL files in `self.files`:

```lua
-- After batch parsing loop completes:
index:_rebuild_name_index()  -- Full O(N) rebuild of name/alias indexes

if is_cold_start or not index._inlinks or not next(index._inlinks) then
  index:_recompute_inlinks()
else
  index:_recompute_inlinks_incremental(changed_rel_paths, deleted_rel_paths)
end
```

The inlinks path correctly uses incremental updates for warm starts
(line 92), but the name index always does a full rebuild. The method
`_update_name_index_incremental()` exists (vault_index.lua lines
365-419) but is not used here.

**Complexity:** O(N) name index rebuild per build_async, even when only
a few files changed. For a 5000-file vault with 3 changed files, this
scans all 5000 entries unnecessarily.

### Proposed Solution

Use `_update_name_index_incremental()` for warm-start builds:

### Code Changes

```lua
-- vault_index_build.lua, after batch parsing (line 84):
if is_cold_start then
  index:_rebuild_name_index()  -- Full rebuild on cold start
else
  index:_update_name_index_incremental(changed_rel_paths, deleted_rel_paths)
end

if is_cold_start or not index._inlinks or not next(index._inlinks) then
  index:_recompute_inlinks()
else
  index:_recompute_inlinks_incremental(changed_rel_paths, deleted_rel_paths)
end
```

### Expected Performance Improvement

For a warm-start build with 5 changed files in a 5000-file vault:

- **Before:** 5000 file iterations for name index rebuild
- **After:** 5 removals + 5 additions = 10 operations

~500x reduction for typical incremental builds.

### Risk Assessment

- **Collision detection:** `_update_name_index_incremental()` already
  handles collision detection for batches < 5 files (line 412-418).
  For larger batches, it falls back to full collision scan.
- **Cold start:** Full rebuild on cold start ensures correct initial state.

---

## 2. Merged Triple Iteration in Index Construction

**Status:** IMPLEMENTED (simplified approach — reuse name/alias indexes for inlinks resolution)

### Problem Analysis

**File:** `lua/andrew/vault/vault_index.lua`

Full index construction involves three separate passes over all files:

1. `_rebuild_name_index()` (lines 341-354): Iterates all files to build
   name and alias indexes
2. `_recompute_inlinks()` (lines 442-444): Iterates all files again to
   compute inlinks from outlinks
3. `_detect_collisions()` (line 428-435): Iterates name/alias indexes
   for collision detection

For a 5000-file vault, this is 3 * 5000 = 15000 iterations.

### Proposed Solution

Merge into a single pass that builds all three derived structures:

### Code Changes

```lua
function M.VaultIndex:_rebuild_all_derived()
  local name_index = {}
  local alias_index = {}
  local all_outlinks = {}  -- { source_rel, outlinks }

  -- Single pass: build name, alias, and collect outlinks
  for rel_path, entry in pairs(self.files) do
    -- Name index
    local lower_name = entry.basename_lower
    if not name_index[lower_name] then
      name_index[lower_name] = {}
    end
    name_index[lower_name][#name_index[lower_name] + 1] = rel_path

    -- Alias index
    if entry.aliases then
      for _, alias in ipairs(entry.aliases) do
        local lower_alias = alias:lower()
        if not alias_index[lower_alias] then
          alias_index[lower_alias] = {}
        end
        alias_index[lower_alias][#alias_index[lower_alias] + 1] = rel_path
      end
    end

    -- Collect outlinks for inlinks computation
    if entry.outlinks and #entry.outlinks > 0 then
      all_outlinks[#all_outlinks + 1] = {
        rel_path = rel_path,
        outlinks = entry.outlinks,
      }
    end
  end

  self._name_index = name_index
  self._alias_index = alias_index

  -- Detect collisions from name_index (no extra iteration)
  self:_detect_collisions()

  -- Build inlinks from collected outlinks
  self._inlinks = inlinks_mod.build_from_outlinks(
    all_outlinks, self._name_index, self._alias_index
  )
end
```

### Expected Performance Improvement

For a 5000-file vault on cold start:

- **Before:** 15000 iterations (3 passes)
- **After:** 5000 iterations (1 pass) + collision check on derived data

~3x reduction in cold-start index build iteration count.

### Risk Assessment

- **Modularity:** Merging reduces separation of concerns. Mitigate by
  keeping helper functions for each sub-task, just called from one loop.
- **Inlinks API:** `inlinks_mod.build_from_outlinks()` would need a
  new entry point accepting pre-collected outlink data.

---

## 3. Generation-Cached Aggregate Queries

**Status:** IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/vault_index.lua` (lines 563-595)

`all_tags()` and `all_frontmatter_keys()` build fresh tables on every
call without caching:

```lua
function M.VaultIndex:all_tags()
  local tag_set = {}
  for _, entry in pairs(self.files) do
    if entry.tags then
      for _, tag in ipairs(entry.tags) do
        tag_set[tag] = true
      end
    end
  end
  local tags = {}
  for tag in pairs(tag_set) do
    tags[#tags + 1] = tag
  end
  table.sort(tags)
  return tags
end
```

This iterates all files and all tags on every call. Called from
completion providers, search completion, and tag management UI.

### Proposed Solution

Cache with generation-based invalidation:

### Code Changes

```lua
local _aggregate_cache = { gen = 0, tags = nil, fm_keys = nil }

function M.VaultIndex:all_tags()
  local gen = self._generation or 0
  if _aggregate_cache.gen == gen and _aggregate_cache.tags then
    return _aggregate_cache.tags
  end

  local tag_set = {}
  for _, entry in pairs(self.files) do
    if entry.tags then
      for _, tag in ipairs(entry.tags) do
        tag_set[tag] = true
      end
    end
  end
  local tags = {}
  for tag in pairs(tag_set) do
    tags[#tags + 1] = tag
  end
  table.sort(tags)

  _aggregate_cache.gen = gen
  _aggregate_cache.tags = tags
  return tags
end

function M.VaultIndex:all_frontmatter_keys()
  local gen = self._generation or 0
  if _aggregate_cache.gen == gen and _aggregate_cache.fm_keys then
    return _aggregate_cache.fm_keys
  end

  -- ... existing logic ...

  _aggregate_cache.fm_keys = keys
  return keys
end
```

### Expected Performance Improvement

For tag completion triggering `all_tags()` 4 times per keystroke:

- **Before:** 4 * 2000 = 8000 file iterations + 4 sorts
- **After:** 1 file iteration + 1 sort + 3 cache hits

~4x reduction per completion cycle.

### Risk Assessment

- **Staleness:** Generation tracking ensures fresh data when files change.
- **Memory:** One sorted tag array + one key array. ~20KB combined.

---

## ~~4. Pre-Computed rel_stem~~ → Consolidated into doc 58-parser-single-pass-optimization.md (parser precomputation section)

---

## 4. Cached file_count()

**Status:** IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/vault_index.lua` (line 662)

`file_count()` uses `vim.tbl_count(self.files)` which is O(N):

```lua
function M.VaultIndex:file_count()
  return vim.tbl_count(self.files)
end
```

`vim.tbl_count()` is O(N) — it uses `next()` in a loop to count all keys.
This method is called from:

- `load()` — logging
- `_persist()` — logging
- Various status/debug commands
- Progress messages, build completion notifications

While not on the hottest path, it's easily cached.

### Proposed Solution

Maintain a `_file_count` field updated on every file addition/removal:

### Code Changes

```lua
-- In VaultIndex constructor:
self._file_count = 0

-- Replace file_count():
function M.VaultIndex:file_count()
  return self._file_count
end

-- In load() after populating self.files from persisted data:
self._file_count = vim.tbl_count(self.files)  -- one-time O(N) on cold start

-- In build_async / update_files_batch when adding entries:
-- (vault_index_build.lua)
if entry then
  if not index.files[file.rel_path] then
    index._file_count = index._file_count + 1
  end
  index.files[file.rel_path] = entry
end

-- When deleting entries:
for _, rel_path in ipairs(deleted) do
  if index.files[rel_path] then
    index._file_count = index._file_count - 1
  end
  index.files[rel_path] = nil
end

-- In build_sync (full rebuild):
-- After clearing and rebuilding self.files:
self._file_count = vim.tbl_count(self.files)  -- one-time recalculation
```

### Expected Performance Improvement

- **Before:** O(N) table iteration per `file_count()` call
- **After:** O(1) field access

For a 2000-file vault, each call saves ~2000 iterations. Small absolute
benefit, but the fix is trivial and eliminates a code smell.

### Risk Assessment

- **Correctness:** The count must be updated at every mutation site. There
  are exactly 3 mutation paths: `load()`, `build_async()` batch processing,
  and `update_files_batch()`. All are in `vault_index.lua` and
  `vault_index_build.lua`.
- **Drift:** If a mutation site is missed, the count drifts. Add an assertion
  in debug mode: `assert(self._file_count == vim.tbl_count(self.files))` in
  `_persist()` to catch drift early.
- **Thread safety:** The vault index is single-threaded (coroutine-based
  async, not true threads). No race conditions.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Incremental name index (#1) | Low | High | Low |
| 2 | Cached aggregates (#3) | Low | Medium | Low |
| 3 | Cached file_count (#4) | Low | Low | Low |
| 4 | Merged triple iteration (#2) | High | High | Medium |

---

## Testing Strategy

### Incremental Name Index (#1)
1. Edit and save a file. Verify name index updates correctly.
2. Rename a file. Verify old name removed, new name added.
3. Check `:VaultIndexStatus` shows correct file count.

### Cached Aggregates (#3)
1. Type `tag:` in search completion. Verify tags appear.
2. Add a new tag to a file, save. Verify tag appears in next completion.
3. Verify no stale tags after file deletion.

### Cached file_count (#4)
1. After index build, verify `file_count()` matches `vim.tbl_count(files)`.
2. Add a file via watcher. Verify count increments.
3. Delete a file. Verify count decrements.
4. Full rebuild. Verify count matches.

### Merged Iteration (#2)
1. Start Neovim on a 1000-file vault. Verify all indexes are correct.
2. Compare `_name_index`, `_alias_index`, `_inlinks` with pre-merge.
3. Profile cold-start time reduction.

---

## 5. Post-Implementation Cleanup

**Status:** IMPLEMENTED

### Changes Made

1. **Dead code removal in `vault_index_inlinks.lua`:** Removed `build_resolution_tables()`,
   `resolve_link_target()`, and `resolve_outlinks_into()` — all three were unreachable since
   `resolve_fn` is always provided by callers. Removed fallback branches in `recompute()` and
   `recompute_incremental()`. Module went from 178 lines to ~98 lines.

2. **Simplified `_recompute_inlinks()` in `vault_index.lua`:** Removed the `next(self._name_index)`
   guard since name index is always populated before inlinks recomputation. Now unconditionally
   passes `self:_build_resolve_fn()`.

3. **Generation-cached `tags_with_counts()`:** Added `_cached_tag_counts` / `_cached_tag_counts_gen`
   for consistency with `all_tags()` and `all_frontmatter_keys()`. Called from completion_tags,
   sidebar_tags, and tags modules.

4. **Generation-cached `get_name_cache()`:** Added `_cached_name_cache` / `_cached_name_cache_gen`.
   This method was O(N) on every call and is used by 7 modules (autolink, linkdiag, engine,
   unlinked, link_scan, link_repair).

---

## Related Documents

- Doc 58-parser-single-pass-optimization consolidates all parser-level field precomputations.
- Doc 57-completion-system-optimizations #3 covers completion-level `accumulate_fields()` memoization (complementary to #3 here — Doc 76 caches vault-level aggregates, Doc 57 caches completion-specific field accumulation).
