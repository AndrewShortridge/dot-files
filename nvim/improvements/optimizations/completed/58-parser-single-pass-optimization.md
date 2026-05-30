# 58 --- Parser Single-Pass Optimization

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

Four targeted optimizations for the vault index parser, addressing repeated
string operations in link resolution, resolution table reuse, and pre-computed
fields on outlink and index entries.

> **Modules affected:** `vault_index_parser.lua`, `vault_index_inlinks.lua`,
> `vault_index.lua`, `search_filter/match_field.lua`

---

## 1. Pre-Computed Link Resolution Keys

**Status:** IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/vault_index_inlinks.lua` (lines 42-53)

Inside `resolve_link_target()`, which is called for every outlink during inlink
resolution, 5 string operations are performed per link:

```lua
-- vault_index_inlinks.lua:42-53
local function resolve_link_target(raw, by_path, by_name, by_alias)
  raw = raw:match("^([^#^]+)") or raw    -- 1. regex: strip heading/block
  raw = vim.trim(raw)                      -- 2. whitespace scan
  if raw == "" then return nil end
  local lower = raw:lower()               -- 3. case conversion
  -- Try path match
  if by_path[lower .. ".md"] then return by_path[lower .. ".md"] end
  local stem = lower:gsub("%.md$", "")    -- 4. pattern replacement
  local basename = lower:match("([^/]+)$") -- 5. regex: extract basename
  -- ... lookup logic ...
end
```

For a vault with 20,000 total outlinks, this is 100,000 string operations
during every inlink recomputation.

### Proposed Solution

Pre-compute resolution keys (`stem_lower`, `basename_lower`) during outlink
extraction in the parser. Store them on each outlink entry.

### Code Changes

**In `vault_index_parser.lua`, outlink extraction:**

```lua
-- When building each outlink entry:
local raw_path = -- ... extracted path portion ...
local stem_lower = raw_path and raw_path:lower():gsub("%.md$", "") or nil
local basename_lower = stem_lower and stem_lower:match("([^/]+)$") or nil

links[#links + 1] = {
  path = raw_path,
  name = name,
  heading = heading,
  block = block,
  stem_lower = stem_lower,        -- NEW: pre-computed
  basename_lower = basename_lower, -- NEW: pre-computed
}
```

**Modified `resolve_link_target()` in `vault_index_inlinks.lua`:**

```lua
local function resolve_link_target(link, by_path, by_name, by_alias)
  local stem = link.stem_lower
  local basename = link.basename_lower
  if not stem then return nil end

  -- Try path match
  if by_path[stem .. ".md"] then return by_path[stem .. ".md"] end
  -- Try name match
  local name_matches = by_name[basename]
  if name_matches then return name_matches[1] end
  -- Try alias match
  local alias_matches = by_alias[basename]
  if alias_matches then return alias_matches[1] end
  return nil
end
```

### Expected Performance Improvement

- **Before:** 5 string operations * 20,000 links = 100,000 operations per
  inlink recomputation
- **After:** 0 string operations at resolution time (pre-computed at parse time)

The per-link cost shifts to parse time (one-time, amortized).

### Risk Assessment

- **Memory:** Two additional strings per outlink. For 20,000 links at ~30 bytes
  each: ~1.2MB — acceptable.
- **Serialization:** Pre-computed fields can be excluded from JSON persistence
  and recomputed on `load()` to avoid bloating the index file.
- **Compatibility:** `resolve_link_target()` signature changes from `(raw, ...)`
  to `(link, ...)`. Update callers in `resolve_outlinks_into()` (line 59).

---

## 2. Resolution Table Reuse from Name Index

**Status:** ALREADY IMPLEMENTED (code uses `_build_resolve_fn()` which reuses `_name_index`/`_alias_index`)

### Problem Analysis

**File:** `lua/andrew/vault/vault_index_inlinks.lua` (line 136)

`recompute_incremental()` calls `build_resolution_tables(files)` which iterates
**all N files** to build three lookup tables (`by_name`, `by_path`, `by_alias`).
This O(N) operation runs on every incremental inlink update, even though the
vault index already maintains equivalent structures:

- `vault_index._name_index` — maps lowercase name -> list of abs_paths
- `vault_index._alias_index` — maps lowercase alias -> list of abs_paths

These indexes are rebuilt immediately before `_recompute_inlinks_incremental()`
is called (in `vault_index_build.lua`).

```lua
-- vault_index_inlinks.lua:98-145
function I.recompute_incremental(files, inlinks, changed_rel_paths, deleted_rel_paths)
  -- Phase 1: Remove old contributions (O(K * inlinks_per_file))
  -- ...

  -- Phase 2: Re-resolve changed files
  if #changed_rel_paths > 0 then
    local by_name, by_path, by_alias = build_resolution_tables(files) -- O(N) REDUNDANT
    for _, rel_path in ipairs(changed_rel_paths) do
      resolve_outlinks_into(files[rel_path], by_path, by_name, by_alias, inlinks)
    end
  end
end
```

**Complexity:** O(N) per incremental update, regardless of how many files changed.
This is a known bottleneck — incremental inlinks already exist, but this
resolution table rebuild negates the benefit.

### Proposed Solution

Pass the existing `_name_index` and `_alias_index` from the vault index to
`recompute_incremental()`. Build a thin `by_path` adapter from `files` (which
is O(N) but can be cached or built incrementally).

### Code Changes

**Modified `recompute_incremental()` signature:**

```lua
function I.recompute_incremental(files, inlinks, changed_rel_paths, deleted_rel_paths, name_idx, alias_idx)
  -- Phase 1: Remove old contributions (unchanged)
  -- ...

  -- Phase 2: Re-resolve changed files using existing indexes
  if #changed_rel_paths > 0 then
    -- Build by_path from files (still O(N) but simpler than full resolution tables)
    -- OR: pass by_path as a parameter too
    local by_path = {}
    for rel_path, entry in pairs(files) do
      by_path[rel_path] = entry.abs_path
    end

    -- Adapt name_idx format: lowercase name -> first abs_path
    -- name_idx is already: lowercase name -> { abs_path1, abs_path2, ... }
    -- by_name expects same format, so pass directly

    for _, rel_path in ipairs(changed_rel_paths) do
      resolve_outlinks_into(files[rel_path], by_path, name_idx, alias_idx, inlinks)
    end
  end
end
```

**In `vault_index.lua`, pass indexes to incremental method:**

```lua
function M:_recompute_inlinks_incremental(changed, deleted)
    self._inlinks = inlinks_mod.recompute_incremental(
        self.files,
        self._inlinks,
        changed,
        deleted,
        self._name_index,   -- reuse existing
        self._alias_index    -- reuse existing
    )
end
```

**Alternative: Cache `by_path` on the index itself:**

Since `by_path` is just `rel_path -> abs_path`, it can be maintained
incrementally alongside `_name_index`:

```lua
-- In vault_index.lua:
function M:_rebuild_by_path()
    self._by_path = {}
    for rel_path, entry in pairs(self.files) do
        self._by_path[rel_path] = entry.abs_path
    end
end
```

### Expected Performance Improvement

- **Before:** O(N) full `build_resolution_tables()` on every incremental update
- **After:** O(0) for name/alias resolution tables (reused from index).
  `by_path` either O(N) (if rebuilt) or O(K) (if maintained incrementally).

Combined with the existing incremental inlinks in `build_async()`, this
makes the full incremental inlink path O(K * M) where K = changed files and
M = avg outlinks, with **no O(N) scanning** of unchanged files.

### Risk Assessment

- **Format compatibility:** The `_name_index` maps `lowercase_name -> [abs_path, ...]`
  while `build_resolution_tables`'s `by_name` maps `lowercase_name -> [abs_path, ...]`.
  These are the same format — direct reuse is safe.
- **Timing:** `_name_index` is rebuilt before `_recompute_inlinks_incremental()`
  is called. The index is fresh and includes all changed entries.
- **by_path map:** This is the one structure that doesn't have an existing
  equivalent. Building it from `files` is still O(N), but the constant factor
  is much smaller (one table insertion per file vs. three tables with basename
  extraction, alias iteration, etc.).

---

---

## 3. Pre-Computed `path_lower` and `name_lower` on Outlink Entries

**Status:** IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/search_filter/match_field.lua` (lines 251-255, 302)

In the `links-to` and `linked-from` filter paths, `link_name:lower()` and
`target_name:lower()` are called repeatedly on the same strings within nested
loops. For `linked-from` (lines 299-307), the inner loop over
`section_outlinks` calls `:lower()` on each entry basename for every filter
evaluation.

```lua
-- match_field.lua:251-255 (links-to filter path)
for _, link in ipairs(entry.outlinks) do
    local link_name = (link.path or link.name or ""):lower()  -- allocated per link
    local target_name = (link.target or ""):lower()            -- allocated per link
    -- ... comparison logic ...
end
```

For a vault with 2000 files averaging 10 outlinks each, filtering by `links-to`
creates 20,000 lowercase string allocations per search query.

### Proposed Solution

Pre-compute and store lowercased link names during index parsing. Add
`path_lower` and `name_lower` fields to each outlink entry in
`vault_index_parser.lua`.

### Code Changes

**In `vault_index_parser.lua`, `extract_outlinks()`:**

```lua
-- When building each outlink entry, add pre-lowered fields:
links[#links + 1] = {
    path = path,
    name = name,
    heading = heading,
    block = block,
    path_lower = path and path:lower() or nil,  -- NEW
    name_lower = name and name:lower() or nil,  -- NEW
}
```

**In `match_field.lua`, update filter to use pre-computed fields:**

```lua
-- Before:
local link_name = (link.path or link.name or ""):lower()

-- After:
local link_name = link.path_lower or link.name_lower or ""
```

### Expected Performance Improvement

- **Before:** 20,000 `:lower()` calls + string allocations per `links-to` query
- **After:** 0 runtime lowercase calls (pre-computed at parse time)

Parse-time cost: +2 `:lower()` calls per outlink during index build (amortized,
runs once per file change).

### Risk Assessment

- **Memory:** ~20 bytes per outlink for pre-lowered strings. For 20,000 links
  total: ~400KB — negligible.
- **Index size:** Persisted index grows slightly. Pre-lowered fields can be
  excluded from serialization and recomputed on load if size is a concern.
- **Correctness:** Lowering at parse time is equivalent to lowering at query
  time. No behavioral change.

---

## 4. Pre-Computed `rel_stem` on Index Entries

**Status:** IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/vault_index_inlinks.lua`

During inlinks computation, `rel_path:gsub("%.md$", "")` is called repeatedly
to strip the `.md` extension for path-based link matching. Every outlink
resolution attempt performs this substitution on the source file's relative
path, creating redundant string allocations.

For a vault with 2000 files and 20 outlinks on average, inlink recomputation
triggers 40,000 `gsub` allocations — one per outlink per file — even though
each file's stem is constant.

### Proposed Solution

Pre-compute `rel_stem` on each index entry during parsing:

```lua
entry.rel_stem = rel_path:gsub("%.md$", "")
```

This shifts the cost to parse time (2000 allocations, once per file) and
eliminates the repeated computation during inlink resolution.

### Code Changes

**In `vault_index_parser.lua`, entry construction:**

```lua
-- When building each file entry:
entry.rel_stem = rel_path:gsub("%.md$", "")
```

**In `vault_index_inlinks.lua`, replace inline gsub calls:**

```lua
-- Before:
local stem = entry.rel_path:gsub("%.md$", "")

-- After:
local stem = entry.rel_stem
```

### Expected Performance Improvement

- **Before:** 40,000 `gsub` allocations during inlink recomputation (2000 files * 20 outlinks)
- **After:** 2,000 allocations total (one per file, at parse time)

### Risk Assessment

- **Memory:** One additional string per entry (~30 bytes avg). For 2000 entries:
  ~60KB — negligible.
- **Serialization:** `rel_stem` can be excluded from JSON persistence and
  recomputed on `load()` since it's derivable from `rel_path`.
- **Consistency:** The gsub pattern `%.md$` is deterministic; pre-computing it
  cannot produce different results.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Pre-computed link resolution keys (#1) | Low | High | Low |
| 2 | Resolution table reuse (#2) | Medium | High | Low |
| 3 | Pre-computed path_lower/name_lower (#3) | Low | High | Low |
| 4 | Pre-computed rel_stem (#4) | Low | Medium | Low |

#1 is a targeted change to one function signature. #2 eliminates the
remaining O(N) bottleneck in the incremental inlink path. #3 eliminates
per-query lowercase allocations in the search filter pipeline. #4 eliminates
repeated gsub during inlink computation.

---

## Testing Strategy

### Pre-Computed Link Keys (#1)
1. **Resolution parity:** Run `_recompute_inlinks()` with old and new approaches.
   Compare resulting inlinks tables.
2. **Special characters:** Test links with paths containing spaces, dots, dashes.
3. **Heading/block links:** Verify `[[Note#heading]]` correctly strips the heading
   portion and resolves the note.

### Resolution Table Reuse (#2)
1. **Incremental correctness:** After warm `build_async()`, compare inlinks
   against full `recompute()`. They must match.
2. **Name index freshness:** Modify a file's name (rename). Verify incremental
   inlinks correctly uses the updated `_name_index`.

### Pre-Computed path_lower/name_lower (#3)
1. Run `links-to:SomeNote` search. Verify results match before/after.
2. Profile with `--startuptime` or `:VaultSearchDebug` to confirm no `:lower()`
   calls in the filter path.

### Pre-Computed rel_stem (#4)
1. Run `:VaultIndexRebuild`. Verify inlinks are identical to before.
2. Check that `entry.rel_stem` matches `rel_path:gsub("%.md$", "")` for all entries.

---

## Related Documents

- Doc 57-search-filter-performance originally proposed `path_lower`/`name_lower`
  (consolidated here as optimization #3).
- Doc 76-index-build-merge-precomputation originally proposed `rel_stem`
  (consolidated here as optimization #4).
- Doc 60-index-persistence-memory originally proposed a single-pass parser
  approach (consolidated here).
