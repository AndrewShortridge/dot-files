# 50 --- Section Outlink Cache (Cross-Search Persistence)

## Motivation

The search filter pipeline (`search_filter.lua`) parses heading-qualified link
queries like `linked-from:Note#Heading` by reading the source file from disk,
splitting it into heading sections, and extracting outlinks from each section.
This work is performed by `build_file_section_map()` via `get_section_outlinks()`.

The current implementation already uses a module-level `_section_cache` table
that persists across `evaluate()` calls, with generation-based invalidation
when the vault index is rebuilt. However, it lacks two important properties:

1. **Per-file mtime invalidation** -- if a single file is saved, the entire
   cache is only invalidated when the vault index generation advances. The
   `_section_cache` has no way to know that a specific file changed between
   searches without a full index rebuild.
2. **Memory bounds** -- the cache grows without limit. A vault with 1,000+
   notes could accumulate section maps for every file ever queried, consuming
   significant memory indefinitely.
3. **Engine cache registry integration** -- the section cache is invisible to
   the `:VaultCacheInvalidate` command and the `VaultCacheInvalidation`
   augroup. File-scoped invalidation from `BufWritePost` does not reach it.

These gaps matter most in live search (`search_advanced_live`), where
`evaluate()` is called on every keystroke (debounced to 150ms). If the user
edits a file and then re-runs a `linked-from:Note#Heading` query, the stale
section outlinks from `_section_cache` are returned until the vault index
happens to rebuild and advance its generation counter.

---

## Current State Analysis

### File: `lua/andrew/vault/search_filter.lua`

The section outlinks cache lives at module scope (lines 231-249):

```lua
-- =============================================================================
-- Section outlinks cache (generation-aware, persists across evaluate() calls)
-- =============================================================================

--- Per-file section outlinks cache.
--- Structure: { [rel_path] = { sections = { [heading_slug] = outlinks[] } } }
---@type table<string, { sections: table<string, table[]> }>
local _section_cache = {}
local _section_cache_generation = -1

--- Invalidate section cache if vault index generation has advanced.
---@param index table VaultIndex instance
local function maybe_invalidate_section_cache(index)
  local gen = index and index._generation or 0
  if gen ~= _section_cache_generation then
    _section_cache = {}
    _section_cache_generation = gen
  end
end
```

The cache is populated by `get_section_outlinks()` (lines 338-355):

```lua
local function get_section_outlinks(entry, heading, index)
  if index then
    maybe_invalidate_section_cache(index)
  end

  local rel = entry.rel_path

  -- Populate file cache on first access
  if not _section_cache[rel] then
    _section_cache[rel] = {
      sections = build_file_section_map(entry.abs_path),
    }
  end

  local slug_mod = require("andrew.vault.slug")
  local heading_slug = slug_mod.heading_to_slug(heading)
  return _section_cache[rel].sections[heading_slug] or {}
end
```

The cache is consumed in two places within `match_field()`:

1. **`linked-from` with heading** (line 551): finds outlinks within a specific
   heading section of the source note, then checks if any outlink points to
   the candidate entry.

2. **`evaluate()`** (line 1352): calls `maybe_invalidate_section_cache(index)`
   at the top of each evaluation pass, but this only checks generation -- not
   per-file mtime.

### What `build_file_section_map()` does (lines 273-330)

Reads the file from disk via `io.open`, iterates all lines in a single pass,
maintains a heading stack, and builds a `{ [heading_slug] = outlinks[] }` map.
This is the expensive operation that the cache amortizes.

### Engine cache registry

The engine (`engine.lua`) provides `register_cache()` for modules to opt into
the centralized invalidation system. Registered caches receive:

- `invalidate()` -- full wipe (called on `FocusGained`, vault switch, scope "all")
- `invalidate_file(abs_path)` -- per-file wipe (called on `BufWritePost`, `BufDelete`)

Currently, `search_filter.lua` does **not** register with the engine cache
registry. The `_section_cache` is invisible to `:VaultCacheInvalidate` and all
`VaultCacheInvalidation` augroup events.

### Config

There is no config entry for section cache size. The `M.search` table in
`config.lua` has settings for debounce, max files, field names, history, etc.,
but nothing related to the section outlink cache.

---

## Implementation

### 1. Config Addition

**File: `lua/andrew/vault/config.lua`**

Add `section_cache_max` inside the `M.search` table.

#### Before (lines 379-383)

```lua
M.search = {
  -- Debounce interval (ms) for live advanced search re-evaluation.
  -- Applied internally by fzf-lua's fzf_live. Lower = more responsive,
  -- higher = fewer ripgrep invocations.
  live_debounce_ms = 150,
```

#### After

```lua
M.search = {
  -- Debounce interval (ms) for live advanced search re-evaluation.
  -- Applied internally by fzf-lua's fzf_live. Lower = more responsive,
  -- higher = fewer ripgrep invocations.
  live_debounce_ms = 150,

  -- Maximum number of files to cache in the section outlinks cache.
  -- Used by linked-from:Note#Heading queries. LRU eviction when exceeded.
  -- Set to 0 to disable the cache entirely.
  section_cache_max = 200,
```

---

### 2. Rewrite Section Cache with LRU Eviction and mtime Tracking

**File: `lua/andrew/vault/search_filter.lua`**

Replace the existing section cache block (lines 231-355) with an LRU-bounded,
mtime-aware, engine-registered cache.

#### Before (lines 231-249)

```lua
-- =============================================================================
-- Section outlinks cache (generation-aware, persists across evaluate() calls)
-- =============================================================================

--- Per-file section outlinks cache.
--- Structure: { [rel_path] = { sections = { [heading_slug] = outlinks[] } } }
---@type table<string, { sections: table<string, table[]> }>
local _section_cache = {}
local _section_cache_generation = -1

--- Invalidate section cache if vault index generation has advanced.
---@param index table VaultIndex instance
local function maybe_invalidate_section_cache(index)
  local gen = index and index._generation or 0
  if gen ~= _section_cache_generation then
    _section_cache = {}
    _section_cache_generation = gen
  end
end
```

#### After

```lua
-- =============================================================================
-- Section outlinks cache (mtime + generation aware, LRU bounded)
-- =============================================================================
-- Persists across evaluate() calls. Each entry stores the file's mtime at
-- parse time so stale entries are detected on next access without waiting
-- for a full index rebuild. An LRU eviction list prevents unbounded growth.

--- Cache entry: { mtime = number, sections = { [heading_slug] = outlinks[] } }
---@type table<string, { mtime: number, sections: table<string, table[]> }>
local _section_cache = {}

--- LRU order: most-recently-used at the end, oldest at index 1.
--- Contains rel_path strings. Kept in sync with _section_cache keys.
---@type string[]
local _section_lru = {}

--- Vault index generation at last full-cache wipe.
local _section_cache_generation = -1

--- Remove a key from the LRU list (O(n) scan, acceptable for max ~200 entries).
---@param rel string
local function lru_remove(rel)
  for i = #_section_lru, 1, -1 do
    if _section_lru[i] == rel then
      table.remove(_section_lru, i)
      return
    end
  end
end

--- Touch a key: move it to the end of the LRU list (most-recently-used).
---@param rel string
local function lru_touch(rel)
  lru_remove(rel)
  _section_lru[#_section_lru + 1] = rel
end

--- Evict the oldest entries until the cache is within the configured max size.
local function lru_evict()
  local max_size = config.search and config.search.section_cache_max or 200
  if max_size <= 0 then
    -- Cache disabled: wipe everything
    _section_cache = {}
    _section_lru = {}
    return
  end
  while #_section_lru > max_size do
    local oldest = table.remove(_section_lru, 1)
    _section_cache[oldest] = nil
  end
end

--- Invalidate the entire section cache if vault index generation has advanced.
---@param index table VaultIndex instance
local function maybe_invalidate_section_cache(index)
  local gen = index and index._generation or 0
  if gen ~= _section_cache_generation then
    _section_cache = {}
    _section_lru = {}
    _section_cache_generation = gen
  end
end

--- Invalidate a single file's section cache entry.
---@param rel_path string vault-relative path
local function invalidate_section_cache_file(rel_path)
  if _section_cache[rel_path] then
    _section_cache[rel_path] = nil
    lru_remove(rel_path)
  end
end

--- Wipe the entire section cache (used by engine.invalidate_caches).
local function invalidate_section_cache_all()
  _section_cache = {}
  _section_lru = {}
  _section_cache_generation = -1
end
```

---

### 3. Rewrite `get_section_outlinks()` with mtime Check

#### Before (lines 338-355)

```lua
local function get_section_outlinks(entry, heading, index)
  if index then
    maybe_invalidate_section_cache(index)
  end

  local rel = entry.rel_path

  -- Populate file cache on first access
  if not _section_cache[rel] then
    _section_cache[rel] = {
      sections = build_file_section_map(entry.abs_path),
    }
  end

  local slug_mod = require("andrew.vault.slug")
  local heading_slug = slug_mod.heading_to_slug(heading)
  return _section_cache[rel].sections[heading_slug] or {}
end
```

#### After

```lua
--- Get the mtime of a file, returning 0 on failure.
---@param abs_path string
---@return number
local function file_mtime(abs_path)
  local stat = vim.uv.fs_stat(abs_path)
  return stat and stat.mtime.sec or 0
end

--- Get outlinks from a specific heading section of a note.
--- Uses mtime-aware, LRU-bounded cache to avoid redundant disk reads.
---@param entry table VaultIndexEntry
---@param heading string heading text to scope to
---@param index table|nil VaultIndex instance (for generation tracking)
---@return table[] outlinks within the section
local function get_section_outlinks(entry, heading, index)
  if index then
    maybe_invalidate_section_cache(index)
  end

  local rel = entry.rel_path
  local cached = _section_cache[rel]

  -- Check if cached entry is still valid (mtime unchanged)
  if cached then
    local current_mtime = file_mtime(entry.abs_path)
    if cached.mtime ~= current_mtime then
      -- File changed since we cached it: invalidate this entry
      _section_cache[rel] = nil
      lru_remove(rel)
      cached = nil
    end
  end

  -- Populate on cache miss
  if not cached then
    local mtime = file_mtime(entry.abs_path)
    _section_cache[rel] = {
      mtime = mtime,
      sections = build_file_section_map(entry.abs_path),
    }
    lru_touch(rel)
    lru_evict()
  else
    -- Cache hit: refresh LRU position
    lru_touch(rel)
  end

  local slug_mod = require("andrew.vault.slug")
  local heading_slug = slug_mod.heading_to_slug(heading)
  return _section_cache[rel].sections[heading_slug] or {}
end
```

---

### 4. Register with Engine Cache Registry

Add the following block after the section cache code, before
`extract_line_outlinks()`. This integrates the section cache into the
centralized invalidation system so that `:VaultCacheInvalidate`, `BufWritePost`,
`BufDelete`, and `FocusGained` all properly reach it.

#### Code to Add

```lua
-- Register section cache with the engine's central cache registry.
-- This enables per-file invalidation on BufWritePost and full invalidation
-- on FocusGained / :VaultCacheInvalidate.
local engine = require("andrew.vault.engine")
engine.register_cache({
  name = "section_outlinks",
  module = "andrew.vault.search_filter",
  invalidate = invalidate_section_cache_all,
  invalidate_file = function(abs_path)
    local rel = engine.vault_relative(abs_path)
    if rel then
      invalidate_section_cache_file(rel)
    end
  end,
  stats = function()
    return {
      entries = #_section_lru,
    }
  end,
})
```

#### Insertion Point

After the `invalidate_section_cache_all()` function definition and before the
`extract_line_outlinks()` function (current line 251). The engine `require` is
added locally in this block to avoid a circular dependency (search_filter
already requires link_utils and config at the top level, and engine does not
require search_filter).

**Circular dependency check:** `search_filter.lua` currently requires
`config`, `date_utils`, `filter_utils`, `link_utils`, and `vault_index` at
the top of the file. Adding `engine` is safe because `engine.lua` does not
require `search_filter` anywhere -- confirmed via grep. The `register_cache`
call executes at module load time (when `search_filter` is first `require`d),
which is after `engine.lua` is already loaded (engine is loaded early in the
vault init sequence).

---

### 5. Expose `invalidate_section_cache_all` on Module Table

For completeness and testability, expose a function to manually clear the
section cache.

#### Code to Add

At the bottom of the file, before `return M`:

```lua
--- Clear the section outlinks cache.
--- Exposed for testing and manual invalidation.
function M.clear_section_cache()
  invalidate_section_cache_all()
end
```

---

## Complete Diff Summary

All changes are in two files:

### `lua/andrew/vault/config.lua`

| Location | Change |
|----------|--------|
| Inside `M.search` table (after `live_debounce_ms`) | Add `section_cache_max = 200` with comment |

### `lua/andrew/vault/search_filter.lua`

| Location | Change |
|----------|--------|
| Lines 231-249 (cache declarations) | Replace with mtime-aware cache + LRU list + helpers |
| Lines 338-355 (`get_section_outlinks`) | Replace with mtime-checking, LRU-touching version |
| After cache helpers (before `extract_line_outlinks`) | Add `engine.register_cache()` block |
| Before `return M` | Add `M.clear_section_cache()` |

No other files require modification.

---

## Performance Analysis

### Current Behavior

| Scenario | Disk Reads |
|----------|------------|
| Single `linked-from:Note#Heading` query | 1 per unique source file (cached for remainder of session until generation changes) |
| Live search typing `linked-from:` queries | 0 after first evaluation (cache hit), but **entire cache wiped** whenever vault index rebuilds (e.g., on any `BufWritePost` that triggers `build_async`) |
| Editing a file then re-searching | Cache wiped by generation advance, all files re-read from disk |

### After This Change

| Scenario | Disk Reads |
|----------|------------|
| Single `linked-from:Note#Heading` query | 1 per unique source file (same as before) |
| Live search typing `linked-from:` queries | 0 after first evaluation (cache hit); **not wiped** by generation advance unless file mtime changed |
| Editing a file then re-searching | Only the **edited file** is re-read (mtime mismatch); all other cached files remain valid |
| `BufWritePost` on a cached file | Single-file eviction via `invalidate_file`, no full wipe |

### Expected Speedup

The primary benefit is during **live search sessions** after editing files:

- **Before:** A `BufWritePost` triggers `engine.invalidate_caches` which
  advances the vault index generation. On the next live search keystroke,
  `maybe_invalidate_section_cache` wipes the entire cache. Every source file
  for `linked-from` queries is re-read from disk.

- **After:** `BufWritePost` calls `invalidate_file` on the section cache,
  removing only the saved file's entry. Other cached entries remain valid
  (their mtime has not changed). The `stat()` call on cache hit adds ~0.1ms
  per file, which is negligible compared to the ~1-5ms cost of
  `build_file_section_map()` per file (disk I/O + line parsing).

For a session where the user edits 1 file and re-runs a `linked-from:` query
that touches 20 source files: before = 20 disk reads; after = 1 disk read +
19 `stat()` calls. The `stat()` calls are ~100x faster than full file reads.

### Memory Impact

With `section_cache_max = 200` and an average section map of ~2KB per file,
the cache consumes at most ~400KB -- well within acceptable bounds. The LRU
eviction ensures that rarely-queried files are evicted first.

---

## Testing Instructions

### 1. Config Default

1. Open Neovim, enter a vault buffer.
2. Run `:lua print(require("andrew.vault.config").search.section_cache_max)`.
3. Verify output is `200`.

### 2. Cache Registration

1. Run `:VaultCacheStatus` (or however the cache status command is exposed).
2. Verify that `section_outlinks` appears in the list of registered caches
   with `entries = 0` initially.

### 3. Cache Population

1. Open a vault note that contains heading-qualified outlinks.
2. Run an advanced search: `:VaultSearchAdvancedLive` and type
   `linked-from:SomeNote#SomeHeading` (substitute a real note and heading).
3. Verify results appear.
4. Run `:lua print(require("andrew.vault.search_filter").clear_section_cache)`.
5. Verify it prints a function reference (confirming the method exists).
6. Run `:VaultCacheStatus` again and verify `section_outlinks` shows
   `entries > 0`.

### 4. mtime Invalidation

1. Perform a `linked-from:Note#Heading` search (populates cache).
2. Open the source note (`Note.md`) and add a new line under the heading.
3. Save the file (`:w`).
4. Re-run the same search query.
5. Verify that the results reflect the new content (the cache entry was
   invalidated by mtime mismatch on next access).

### 5. Per-File Invalidation via Engine

1. Populate the section cache with queries touching multiple source files.
2. Save one of those source files (`:w`).
3. Run `:VaultCacheStatus` and note the `section_outlinks` entry count.
4. Verify it decreased by 1 (the saved file was evicted by `invalidate_file`).

### 6. Full Invalidation

1. Populate the section cache.
2. Run `:VaultCacheInvalidate`.
3. Run `:VaultCacheStatus` and verify `section_outlinks` shows `entries = 0`.

### 7. LRU Eviction

1. Temporarily set `config.search.section_cache_max = 3` in config.lua.
2. Run queries that touch 5 different source files.
3. Verify that only 3 entries remain in the cache (the 2 oldest were evicted).
4. Restore `section_cache_max = 200`.

### 8. Cache Disabled

1. Set `config.search.section_cache_max = 0` in config.lua.
2. Run a `linked-from:Note#Heading` search.
3. Verify it still returns correct results (cache is just never populated).
4. Restore `section_cache_max = 200`.

### 9. Live Search Session (End-to-End)

1. Open `:VaultSearchAdvancedLive`.
2. Type `linked-from:MyNote#Methods` (or a real heading-qualified query).
3. Verify results appear.
4. Without closing the search, open the source note in a split and add a
   wikilink under the `## Methods` heading. Save.
5. Return to the live search and re-type the query (or modify and restore it).
6. Verify the new link appears in results -- confirming the stale cache entry
   was invalidated and the file was re-parsed.

---

## Summary of Changes

| File | Lines Changed | Description |
|------|---------------|-------------|
| `lua/andrew/vault/config.lua` | +4 | Add `section_cache_max = 200` to `M.search` |
| `lua/andrew/vault/search_filter.lua` | ~+70, ~-15 | Replace section cache with mtime+LRU version, register with engine, expose `clear_section_cache()` |

No new files. No new dependencies (only adds a `require("andrew.vault.engine")`
which is already loaded before search_filter). No breaking API changes -- the
`evaluate()`, `match_entry()`, and `get_section_outlinks()` signatures are
unchanged.
