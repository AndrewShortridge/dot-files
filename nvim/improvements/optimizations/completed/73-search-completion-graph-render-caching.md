# 73 --- Search Completion Caching

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

Targeted improvements for the search completion provider, addressing
repeated full-index traversals per keystroke and uncached heading
lowercasing.

> **Modules affected:** `search/completion.lua`

---

## 1. Cached File Name List for Link Completion

### Problem Analysis

**File:** `lua/andrew/vault/search/completion.lua` (lines 139-150)

For `links-to:` and `linked-from:` completions, the handler iterates ALL
files in the vault index per keystroke:

```lua
for _, entry in pairs(idx.files) do
  local name = entry.basename
  if name:lower():sub(1, #rest) == rest then
    items[#items + 1] = { label = prefix .. name, ... }
  end
end
```

Two issues:
1. **Full index iteration:** O(N) per keystroke for N files
2. **Per-entry lowercasing:** `name:lower()` allocates a new string per
   entry per keystroke

### Proposed Solution

Build a cached lowercase basename list with generation tracking:

### Code Changes

```lua
local _name_cache = { gen = 0, names = nil }

local function get_cached_names()
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return {} end

  local gen = idx._generation or 0
  if _name_cache.gen == gen and _name_cache.names then
    return _name_cache.names
  end

  local names = {}
  for _, entry in pairs(idx.files) do
    local name = entry.basename or ""
    names[#names + 1] = { name = name, name_lower = name:lower() }
  end
  table.sort(names, function(a, b) return a.name_lower < b.name_lower end)

  _name_cache = { gen = gen, names = names }
  return _name_cache.names
end

-- In completion handler:
local rest_lower = rest:lower()
local names = get_cached_names()
for _, n in ipairs(names) do
  if n.name_lower:sub(1, #rest_lower) == rest_lower then
    items[#items + 1] = { label = prefix .. n.name, ... }
  end
end
```

### Expected Performance Improvement

For typing `links-to:My` (3 keystrokes) in a 2000-file vault:

- **Before:** 3 * 2000 = 6000 entries iterated + 6000 `:lower()` allocations
- **After:** 1 index scan (first keystroke) + 2 cache hits; 0 `:lower()`
  allocations on cache hits

### Risk Assessment

- **Sorted list:** Sorting enables potential binary search for prefix
  matching (future optimization). Currently still linear but without
  per-entry string allocation.

---

## 2. Pre-Lowered Heading Text in Search Completion

### Problem Analysis

**File:** `lua/andrew/vault/search/completion.lua` (lines 178-182)

When completing heading references (`links-to:Note#`), headings are
lowercased per keystroke:

```lua
local partial_lower = partial_heading:lower()
for _, h in ipairs(entry.headings) do
  if h.text:lower():sub(1, #partial_lower) == partial_lower then
    items[#items + 1] = { ... }
  end
end
```

For a note with 50 headings, this is 50 `:lower()` allocations per
keystroke.

### Proposed Solution

The vault index headings already have pre-computed slugs, but the
completion needs display text matching (not slug matching). Add a
`text_lower` field to headings during index parsing, or cache it on
first access.

### Code Changes

```lua
-- In completion handler, cache lowered headings per entry:
local heading_lower_cache = {}

local function get_headings_lower(entry)
  if heading_lower_cache[entry] then return heading_lower_cache[entry] end
  local result = {}
  for _, h in ipairs(entry.headings or {}) do
    result[#result + 1] = { text = h.text, text_lower = h.text:lower(), level = h.level }
  end
  heading_lower_cache[entry] = result
  return result
end
```

### Expected Performance Improvement

For completing `#Int` across a note with 30 headings over 3 keystrokes:

- **Before:** 3 * 30 = 90 `:lower()` allocations
- **After:** 30 `:lower()` allocations (first keystroke) + 60 cache hits

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Cached name list (#1) | Low | High | Low |
| 2 | Heading lower cache (#2) | Low | Low | Low |

---

## Testing Strategy

### Cached Name List (#1)
1. Type `links-to:My` in search. Verify matching note names appear.
2. Create a new note. Verify it appears in next completion.

---

## Related Documents

- Doc 75-match-field-task-lowercase-caching #1 proposes pre-lowered `basename_lower` at the vault index level. If implemented, `get_cached_names()` in #1 here can use `entry.basename_lower` directly instead of calling `name:lower()`, further reducing allocations during cache rebuilds.
