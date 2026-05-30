# 72 --- Frecency, Tags, Export & Rename Efficiency

> This document is a self-contained implementation guide. Each optimization below is unique to this document.

Targeted improvements for the frecency ranking, tag operations, export
pipeline, and rename system, addressing filesystem-based file listing,
redundant full-file parsing, multi-pass content transformation, and
quadratic change collection.

> **Modules affected:** `frecency.lua`, `tags.lua`, `export.lua`,
> `rename.lua`

---

## 1. Index-Based Frecency File Listing — Status: DONE

### Problem Analysis

**File:** `lua/andrew/vault/frecency.lua` (line 125)

`ranked_files()` calls `vim.fn.globpath()` to list all vault files:

```lua
local all_files = vim.fn.globpath(vault_path, "**/*.md", false, true)
```

This spawns a synchronous filesystem glob on every frecency UI open. For a
vault with 2000 files on a slow filesystem, this blocks for 100-500ms.

The vault index already contains the complete file list with pre-computed
paths.

### Proposed Solution

Use the vault index file list instead of filesystem globbing.

### Code Changes

```lua
local function get_all_vault_files()
  local idx = vault_index.current()
  if idx and idx:is_ready() then
    local files = {}
    for rel_path, entry in pairs(idx.files) do
      files[#files + 1] = entry.abs_path or (idx._vault_path .. "/" .. rel_path)
    end
    return files
  end

  -- Fallback: only if index not ready
  local vault_path = engine.vault_path
  return vim.fn.globpath(vault_path, "**/*.md", false, true)
end
```

### Expected Performance Improvement

- **Before:** Filesystem glob (~100-500ms for 2000 files)
- **After:** Table iteration (~1-2ms for 2000 files)

~100x faster file listing when vault index is available.

### Risk Assessment

- **Index readiness:** Fallback to globpath when index isn't ready.
  On subsequent calls (after async index build completes), uses index.
- **File coverage:** The vault index only contains `.md` files, which
  matches the globpath pattern. No coverage difference.

---

## 2. Index-Based Tag Operations — Status: DONE

### Problem Analysis

**File:** `lua/andrew/vault/tags.lua` (lines 165-266)

`add_tag()` re-parses frontmatter for every selected file to check if
the tag already exists:

```lua
for _, file in ipairs(selected_files) do
  -- Full frontmatter parsing per file
  local fm = fm_parser.parse_file(file.abs_path)
  if fm and fm.tags then
    for _, existing_tag in ipairs(fm.tags) do
      if existing_tag == tag then
        goto skip_file  -- already has tag
      end
    end
  end
  -- ... add tag to file ...
end
```

The vault index already stores parsed tags for every file. The existence
check can use the index directly:

```lua
local entry = idx.files[rel_path]
if entry and entry.tags then
  for _, t in ipairs(entry.tags) do
    if t == tag then goto skip_file end
  end
end
```

Similarly, `remove_tag()` (lines 307-402) performs two full file scans:
one to find files with the tag (already available from the index) and
another to scan through lines to remove it.

### Proposed Solution

**Phase 1:** Use vault index for tag existence checks (eliminates
frontmatter re-parsing).

**Phase 2:** For `remove_tag()`, get file list from index tags instead
of re-scanning.

### Code Changes

```lua
-- add_tag: use index for existence check
local function file_has_tag(idx, rel_path, tag)
  local entry = idx.files[rel_path]
  if not entry or not entry.tags then return false end
  for _, t in ipairs(entry.tags) do
    if t:lower() == tag:lower() then return true end
  end
  return false
end

-- remove_tag: get affected files from index
local function files_with_tag(idx, tag)
  local files = {}
  local tag_lower = tag:lower()
  for rel_path, entry in pairs(idx.files) do
    if entry.tags then
      for _, t in ipairs(entry.tags) do
        if t:lower() == tag_lower then
          files[#files + 1] = { rel_path = rel_path, entry = entry }
          break
        end
      end
    end
  end
  return files
end
```

### Expected Performance Improvement

For adding a tag to 10 files:

- **Before:** 10 file reads + 10 frontmatter parses
- **After:** 10 index lookups (in-memory)

For removing a tag from a 1000-file vault:

- **Before:** 1000 file scans (to find files with tag) + N file reads
- **After:** 1 index iteration + N file reads (only for files that need editing)

### Risk Assessment

- **Index freshness:** The index may be slightly behind if a file was just
  saved. Since tag operations are user-initiated (not automatic), the index
  is typically current.
- **Fallback:** If index not ready, fall back to direct file parsing.

---

## 3. Single-Pass Export Pipeline + File Cache — Status: DONE

### Problem Analysis

**File:** `lua/andrew/vault/export.lua` (lines 268-291)

The export pipeline processes content in 3 separate passes:

```lua
-- Pass 1: Convert embeds (line splitting + regex)
content = convert_embeds(content)

-- Pass 2: Convert wikilinks (regex substitution)
content = convert_wikilinks(content)

-- Pass 3: Convert callouts (regex substitution)
content = convert_callouts(content)
```

Each pass allocates new strings and re-scans the full content.

Additionally, `convert_embeds()` reads embedded files from disk without
caching (lines 130-155), so the same file embedded in multiple notes
is read multiple times during a bulk export.

### Proposed Solution

**Phase 1:** Cache file reads during export to avoid re-reading the same
embedded file:

```lua
local _export_file_cache = {}

local function read_file_cached(abs_path)
  if not _export_file_cache[abs_path] then
    _export_file_cache[abs_path] = engine.read_file_content(abs_path)
  end
  return _export_file_cache[abs_path]
end

-- Clear after export completes
local function clear_export_cache()
  _export_file_cache = {}
end
```

**Phase 2:** Merge the 3 conversion passes into a line-by-line processor:

```lua
local function convert_content(lines)
  local result = {}
  for _, line in ipairs(lines) do
    -- Check embed, wikilink, and callout patterns in one pass
    line = convert_embed_line(line)
    line = convert_wikilinks_in_line(line)
    line = convert_callout_line(line)
    result[#result + 1] = line
  end
  return result
end
```

### Expected Performance Improvement

For exporting a 500-line note with 10 embeds:

- **Before:** 3 full content passes + 10 potential file reads (some duplicated)
- **After:** 1 line-by-line pass + deduplicated file reads

File cache benefit: if 5 of the 10 embeds reference 3 unique files,
reads drop from 10 to 3.

### Risk Assessment

- **Pattern interaction:** Embed conversion can produce lines containing
  wikilinks. Processing embed first, then wikilinks on the result, is
  already the current order. The merged pass preserves this ordering.
- **Cache scope:** Export file cache is scoped to a single export
  operation. Cleared after export completes. No stale data.

---

## 4. Pre-Compiled Patterns in Rename — Status: DONE

### Problem Analysis

**File:** `lua/andrew/vault/rename.lua` (lines 162-203)

`collect_rename_changes()` builds a regex pattern for each renamed note
and applies it via `gsub` to every line of every linking file:

```lua
for _, link_file in ipairs(linking_files) do
  local lines = read_file(link_file.abs_path)
  for i, line in ipairs(lines) do
    local new_line = line:gsub(pattern, replacement)
    if new_line ~= line then
      changes[#changes + 1] = { ... }
    end
  end
end
```

For renaming a note linked from 50 files averaging 200 lines each, this
applies the gsub pattern 10,000 times.

Additionally, `tag_rename()` (lines 434-480) escapes the tag pattern
multiple times with identical calls to `:gsub()`:

```lua
-- Lines 434, 439, 445, 454, 460, 467 — same escape pattern compiled 6 times
local escaped = otag:gsub("([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1")
```

### Proposed Solution

Pre-compile the escaped pattern once before the loop:

```lua
-- Pre-escape once
local escaped_old = old_name:gsub("([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1")
local pattern = "%[%[" .. escaped_old .. "(.-)" .. "%]%]"

-- Use pre-compiled pattern in loop
for _, link_file in ipairs(linking_files) do
  local lines = read_file(link_file.abs_path)
  for i, line in ipairs(lines) do
    local new_line = line:gsub(pattern, replacement)
    -- ...
  end
end
```

For tag rename, extract the escape call outside the loop:

```lua
local escaped_tag = otag:gsub("([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1")
-- Use escaped_tag in all 6 pattern constructions
```

### Expected Performance Improvement

- **Pattern escape:** 6 identical escapes -> 1 escape per rename
- **Pattern compilation:** Lua caches recent patterns internally, but
  explicit pre-computation is clearer and guaranteed

Minor per-call savings, but eliminates redundant string operations.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Index-based frecency (#1) | Low | High | Low |
| 2 | Index-based tag checks (#2) | Medium | Medium | Low |
| 3 | Export file caching (#3, Phase 1) | Low | Medium | Low |
| 4 | Pre-compiled rename patterns (#4) | Low | Low | Low |
| 5 | Single-pass export (#3, Phase 2) | High | Medium | Medium |

---

## Testing Strategy

### Index-Based Frecency (#1)
1. Open frecency picker. Verify all vault files appear.
2. Delete vault index. Open frecency picker. Verify globpath fallback works.
3. Profile: verify no perceptible delay on open.

### Index-Based Tags (#2)
1. Add a tag to 5 files. Verify tag appears in each file's frontmatter.
2. Try adding a tag that already exists. Verify skip behavior.
3. Remove a tag. Verify removed from all files.

### Export Caching (#3)
1. Export a note with 5 embeds referencing 2 unique files. Verify content
   is correct and file reads are deduplicated (add debug log).
2. Bulk export 10 notes. Verify cache is cleared after export.

### Rename Patterns (#4)
1. Rename a note linked from 20 files. Verify all links updated.
2. Rename a tag used in 10 files. Verify all occurrences updated.

---

## Related Documents

Standalone — no overlapping optimizations in other documents.
