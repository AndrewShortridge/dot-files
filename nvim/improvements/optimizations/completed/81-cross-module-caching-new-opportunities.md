# 81 --- Cross-Module Caching & New Optimization Opportunities

This document is a self-contained implementation guide. Each optimization
below is unique to this document.

Memoization opportunities for heading slug computation and date parsing
that span multiple vault modules.

> **Modules affected:** `link_utils.lua`, `date_utils.lua`

---

## 1. Memoized heading_to_slug() in link_utils

### Problem Analysis

**File:** `lua/andrew/vault/link_utils.lua` (lines 135-137)

`heading_to_slug()` delegates to `slug_mod.heading_to_slug()` with no
caching. This pure function is called from:

- `embed.lua` — resolving `![[Note#Heading]]` embeds
- `preview.lua` — jumping to heading in preview float
- `linkdiag.lua` — validating heading references
- `wikilinks.lua` — following `[[Note#Heading]]` links
- `backlinks.lua` — matching heading references in backlinks

The same heading strings are slugified repeatedly across modules within
a single operation (e.g., embed rendering slugifies all headings in a
file, then linkdiag re-slugifies the same set).

```lua
function M.heading_to_slug(heading)
  return slug_mod.heading_to_slug(heading)  -- no cache
end
```

### Proposed Solution

Memoize with a bounded LRU or simple table (headings are finite per vault):

### Code Changes

```lua
local _slug_cache = {}
local _slug_cache_size = 0
local SLUG_CACHE_MAX = 2000

function M.heading_to_slug(heading)
  local cached = _slug_cache[heading]
  if cached then return cached end

  local slug = slug_mod.heading_to_slug(heading)
  _slug_cache[heading] = slug
  _slug_cache_size = _slug_cache_size + 1

  -- Simple eviction: clear when too large
  if _slug_cache_size > SLUG_CACHE_MAX then
    _slug_cache = { [heading] = slug }
    _slug_cache_size = 1
  end

  return slug
end
```

### Expected Performance Improvement

For a vault with 500 unique headings referenced across modules:

- **Before:** 500 × 4 modules = 2000 slug computations per operation
- **After:** 500 computations + 1500 cache hits

### Risk Assessment

- **Pure function:** heading_to_slug is deterministic on input string.
  Cache is always correct.
- **Memory:** 2000 entries × ~100 bytes = ~200KB. Acceptable.

---

## 2. Memoized parse_iso_datetime() in date_utils

### Problem Analysis

**File:** `lua/andrew/vault/date_utils.lua`

`parse_iso_datetime()` is called per-entry in search filter matching
without memoization:

- `match_field.lua:348,353,357,376,382` — called per entry for date comparisons
- `match_task.lua:76` — called per task for date matching

```lua
-- In match_field.lua, per-entry:
local entry_ts = date_utils.parse_iso_datetime(entry_date)  -- per entry
```

The same date strings (e.g., `2024-01-15`, `2025-03-07`) appear across
many entries. Each call re-parses the string and constructs a timestamp,
even though the result is deterministic for a given input.

> For filter-level resolve_date() hoisting (query-level precomputation),
> see doc 55-search-filter-precomputation.md

### Proposed Solution

Add module-level memoization to `parse_iso_datetime()` with bounded
cache size:

### Code Changes

```lua
-- date_utils.lua:
local _parse_cache = {}
local _parse_cache_size = 0

function M.parse_iso_datetime(str)
  if not str then return nil end
  local cached = _parse_cache[str]
  if cached then return cached end

  -- existing parsing logic...
  local ts = -- result

  _parse_cache[str] = ts
  _parse_cache_size = _parse_cache_size + 1
  if _parse_cache_size > 5000 then
    _parse_cache = { [str] = ts }
    _parse_cache_size = 1
  end
  return ts
end
```

### Expected Performance Improvement

For `created:>2024-01-01` on 2000 entries with ~200 unique dates:

- **Before:** 2000 parse_iso_datetime() calls (full parsing each time)
- **After:** 200 parses + 1800 cache hits

~10x reduction in date parsing work for typical queries.

### Risk Assessment

- **Correctness:** ISO datetime parsing is deterministic on string input.
  Cache is always correct for absolute date strings.
- **Memory:** 5000 entries × ~50 bytes = ~250KB max. Acceptable.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Memoized heading_to_slug (#1) | Low | Medium | Low |
| 2 | Date parsing memoization (#2) | Low | Medium | Low |

---

## Testing Strategy

### heading_to_slug Memoization (#1)
1. Follow a `[[Note#Heading]]` link. Verify correct heading jump.
2. Follow an embed `![[Note#Heading]]`. Verify correct section shown.
3. Run `:VaultLinkDiag`. Verify heading validation results unchanged.

### Date Parsing Memoization (#2)
1. Search `created:>2024-01-01`. Verify correct results.
2. Search `task-due:<7d`. Verify forward-looking date resolution.
3. Search `created:today`. Verify resolves to current day.

---

## Related Documents

- Doc 55 covers filter-level date precomputation (resolve_date hoisting). Doc 59-completion-link-resolution-performance #3 covers heading slug caching via vault index (complementary to #1 here).
