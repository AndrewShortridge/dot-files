# 69 --- Link Navigation & Diagnostic Caching

> This document is a self-contained implementation guide. Each optimization below is unique to this document.

Targeted improvements for backlinks I/O, weekly review navigation, link
diagnostics, and link checking, addressing sequential file reads, missing
navigation caches, and redundant validation lookups.

> **Modules affected:** `backlinks.lua`, `navigate.lua`, `linkdiag.lua`,
> `linkcheck.lua`

---

## 1. Batched File Reading in Backlinks — Status: DONE

### Problem Analysis

**File:** `lua/andrew/vault/backlinks.lua` (lines 88-105)

`backlinks()` and `heading_backlinks()` call `find_link_lines()` for each
inlink source. Each call reads a file from disk via `engine.read_file_lines()`:

```lua
for _, source in ipairs(inlinks) do
  local lines = find_link_lines(source.abs_path, target_name)
  -- ... process lines ...
end
```

For a note with 30 inlinks from 20 different files, this performs 20
sequential file reads. On spinning disk or network storage, this creates
noticeable latency in the backlinks panel.

**Complexity:** O(inlinks) file I/O operations, sequential.

### Proposed Solution

Batch-read all unique source files once, then process links from memory.

### Code Changes

**File: `lua/andrew/vault/backlinks.lua`**

```lua
local function backlinks(target_name, target_rel)
  local inlinks = get_inlinks(target_rel)
  if not inlinks or #inlinks == 0 then return {} end

  -- Deduplicate source files and batch-read
  local file_lines_cache = {}
  for _, source in ipairs(inlinks) do
    if not file_lines_cache[source.abs_path] then
      file_lines_cache[source.abs_path] = engine.read_file_lines(source.abs_path)
    end
  end

  -- Process from cached lines
  local results = {}
  for _, source in ipairs(inlinks) do
    local lines = file_lines_cache[source.abs_path]
    if lines then
      local matches = find_link_lines_from_cache(lines, target_name)
      for _, m in ipairs(matches) do
        results[#results + 1] = m
      end
    end
  end
  return results
end
```

### Expected Performance Improvement

- **Before:** 20 file reads for 30 inlinks from 20 files
- **After:** 20 file reads (deduplicated), single pass

Primary benefit: deduplication when multiple inlinks come from the same
file. For typical notes, 30-50% of inlinks share source files.

### Risk Assessment

- **Memory:** Holding 20 files in memory (~200KB total). Acceptable for
  a user-initiated operation. Cache is local and garbage collected after
  the backlinks call returns.
- **Stale reads:** Files are read once per backlinks invocation. Since
  backlinks is triggered by user action (not continuous), freshness is
  guaranteed.

---

## 2. Cached Weekly Review Navigation — Status: DONE

### Problem Analysis

**File:** `lua/andrew/vault/navigate.lua` (lines 92-116)

`get_weekly_reviews_sorted()` is called on every `weekly_prev()` and
`weekly_next()` invocation. Each call:

1. Reads the directory listing via `vim.fn.readdir()`
2. Parses frontmatter of each file via `fm_parser.file_field()`
3. Builds and sorts the entry list

```lua
local function get_weekly_reviews_sorted()
  local dir = config.weekly_review_dir
  local entries = vim.fn.readdir(dir)
  local reviews = {}
  for _, name in ipairs(entries) do
    local abs = dir .. "/" .. name
    local date = fm_parser.file_field(abs, "date")
    -- ... build entry ...
  end
  table.sort(reviews, function(a, b) return a.date < b.date end)
  return reviews
end
```

For a directory with 50 weekly reviews, each navigation triggers 50
file reads + frontmatter parses + a sort.

### Proposed Solution

Cache the sorted review list at module level with filesystem mtime or
vault index generation invalidation.

### Code Changes

```lua
local _weekly_cache = { dir_mtime = 0, reviews = nil }

local function get_weekly_reviews_sorted()
  local dir = config.weekly_review_dir
  if not dir then return {} end

  -- Check directory modification time
  local stat = vim.uv.fs_stat(dir)
  local dir_mtime = stat and stat.mtime.sec or 0

  if _weekly_cache.reviews and _weekly_cache.dir_mtime == dir_mtime then
    return _weekly_cache.reviews
  end

  -- ... existing directory scan, parse, sort logic ...

  _weekly_cache = { dir_mtime = dir_mtime, reviews = reviews }
  return reviews
end
```

### Expected Performance Improvement

- **Before:** 50 file reads + parses + sort per navigation keypress
- **After:** 1 stat() call per navigation; full rebuild only when directory
  changes

For rapid navigation (pressing `]w` 5 times): 250 file reads -> 1 read +
4 cache hits.

### Risk Assessment

- **Staleness:** Directory mtime changes on any file add/delete/rename
  within the directory. This covers all cases where the review list changes.
- **File content changes:** If a review's `date` frontmatter is edited,
  the directory mtime does NOT change. This is an edge case — users rarely
  edit dates on weekly reviews. Add vault index generation check as a
  secondary invalidation if needed.

---

## 3. Efficient Link Extraction in Diagnostics — Status: DONE

### Problem Analysis

**File:** `lua/andrew/vault/linkdiag.lua` (lines 129-214)

`validate()` extracts wikilinks using nested `string.find()` in a while loop:

```lua
for i, line in ipairs(lines) do
  local pos = 1
  while true do
    local open = line:find("%[%[", pos, false)
    if not open then break end
    local close = line:find("%]%]", open + 2, false)
    if not close then break end
    local inner = line:sub(open + 2, close - 1)
    -- ... validate inner ...
    pos = close + 2
  end
end
```

This uses two `string.find()` calls per wikilink (one for `[[`, one for `]]`),
plus a `string.sub()` to extract the inner content. For a line with 5
wikilinks, that's 10+ find calls + 5 sub calls.

### Proposed Solution

Use `gmatch` with a single pattern to extract all wikilinks in one pass:

```lua
for i, line in ipairs(lines) do
  for inner, pos in line:gmatch("%[%[(.-)%]%]()") do
    -- ... validate inner ...
  end
end
```

### Expected Performance Improvement

- **Before:** 2 `string.find()` + 1 `string.sub()` per wikilink
- **After:** 1 `gmatch` iterator per line (handles all wikilinks)

For a 500-line buffer with 100 wikilinks: 300 string operations -> 100
gmatch yields.

### Risk Assessment

- **Nested brackets:** `gmatch("[[(.-)]]")` uses non-greedy matching,
  correctly handling `[[Note1]] and [[Note2]]` on the same line.
- **Edge cases:** Empty wikilinks `[[]]` are correctly captured as empty
  strings. Pipe aliases `[[Note|Alias]]` are captured as `Note|Alias`
  (same as current behavior).

---

## 4. Deduplicated Heading Validation in Linkcheck — Status: DONE (ALREADY IMPLEMENTED)

### Problem Analysis

**File:** `lua/andrew/vault/linkcheck.lua` (lines 82-84, 142-147)

`check_buffer()` maintains a `heading_cache` per file, but looks up headings
via `idx:get_headings()` which itself has internal caching:

```lua
if not heading_cache[filepath] then
  if use_idx then
    heading_cache[filepath] = idx:get_headings(self_path)
  else
    -- ... fallback to file read ...
  end
end
```

When the vault index is available, `idx:get_headings()` returns headings
from the already-indexed entry. The local `heading_cache` adds a layer of
caching on top of the index's own caching — but the local cache is never
invalidated during the buffer check lifecycle, so it's useful for avoiding
repeated method calls.

The real issue is the **block ID fallback path** (lines 166-174) which reads
the entire file from disk when the index doesn't have block IDs:

```lua
local f, err = io.open(filepath, "r")
if f then
  local content = f:read("*a")
  f:close()
  block_id_cache[filepath] = block_patterns.id_set_from_content(content)
end
```

### Proposed Solution

Use the vault index's `block_ids` field (already parsed) instead of falling
back to synchronous file I/O:

```lua
if use_idx then
  local entry = idx.files[rel_path]
  if entry and entry.block_ids then
    local set = {}
    for _, b in ipairs(entry.block_ids) do
      set[b.id] = true
    end
    block_id_cache[filepath] = set
  end
end
```

### Expected Performance Improvement

- **Before:** Synchronous `io.open()` + `read("*a")` per file with
  unresolved block references
- **After:** O(block_ids) set construction from already-indexed data

Eliminates file I/O in the diagnostic validation path entirely when
the vault index is ready.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Batched backlinks I/O (#1) | Low | High | Low |
| 2 | Weekly review cache (#2) | Low | Medium | Low |
| 3 | Link extraction gmatch (#3) | Low | Medium | Low |
| 4 | Block ID from index (#4) | Low | Medium | Low |

All four are low-effort, independent changes.

---

## Testing Strategy

### Batched Backlinks (#1)
1. Open backlinks for a note with 30+ inlinks. Verify all backlinks appear.
2. Verify backlinks from the same source file are grouped correctly.
3. Profile: verify file read count matches unique source files (not total
   inlinks).

### Weekly Review Cache (#2)
1. Navigate weekly reviews with `]w`/`[w`. Verify correct ordering.
2. Create a new weekly review file. Verify next navigation shows it.
3. Rapid navigation (5 presses). Verify no perceptible delay.

### Link Extraction (#3)
1. Open a file with 50 wikilinks. Verify all diagnostics appear correctly.
2. Test edge cases: empty links, pipe aliases, heading links, block refs.

### Block ID from Index (#4)
1. Create a note with block references. Verify linkcheck validates them.
2. Delete a block ID target. Verify diagnostic appears on next check.

---

## Related Documents

- Standalone — no overlapping optimizations in other documents.
