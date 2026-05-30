# 75 --- Match Field & Task Filter Lowercase Caching ✅ COMPLETE

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

> **Status:** All 4 optimizations implemented. Verified 2026-03-07.

Targeted improvements for the search filter matching modules, addressing
repeated per-entry string lowercasing, uncached task state resolution,
per-task date parsing, and missing predicate short-circuiting.

> **Modules affected:** `search_filter/match_field.lua`,
> `search_filter/match_task.lua`, `graph_filter.lua`

---

## 1. Pre-Lowered Basename in Match Field

### Problem Analysis

**File:** `lua/andrew/vault/search_filter/match_field.lua` (line 203)

When matching `name:` filters, the entry basename is lowercased on every
match call:

```lua
if entry.basename:lower():find(filter_val:lower()) then
  return true
end
```

Both `:lower()` calls allocate new strings. For a 2000-file vault with
a `name:project` filter, this creates 4000 string allocations (2 per
entry).

**Additionally at lines 251-255:**

```lua
local link_name = ...
if link_name:lower() == target_name:lower() then ...
if link_name:lower() == target_stem:lower() then ...
```

`target_name:lower()` and `target_stem:lower()` are constant per query
but lowercased per outlink per entry.

### Proposed Solution

Pre-lower constant filter values once before the matching loop. Use
`basename_lower` from the vault index entry (already stored).

### Code Changes

```lua
-- In evaluate() or match_entry() setup:
local filter_val_lower = filter_val:lower()

-- In name matching (line 203):
if entry.basename_lower:find(filter_val_lower) then
  return true
end

-- For links-to matching (lines 251-255):
-- Pre-compute once per query:
local target_name_lower = target_name:lower()
local target_stem_lower = target_stem:lower()

-- In loop:
if link_name_lower == target_name_lower then ...
if link_name_lower == target_stem_lower then ...
```

### Expected Performance Improvement

For `name:project` on 2000 files:

- **Before:** 4000 `:lower()` allocations (2 per entry)
- **After:** 2 `:lower()` allocations (filter_val + reuse basename_lower)

For `links-to:Note` with 2000 files averaging 10 outlinks:

- **Before:** 20000 `:lower()` on target_name + 20000 on target_stem
- **After:** 2 `:lower()` (pre-computed once)

### Risk Assessment

- **basename_lower availability:** Already stored in vault index entries
  by the parser (vault_index_parser.lua line 466).
- **Outlink path_lower:** Not pre-stored. See optimization #4 below.

---

## 2. Pre-Computed Task State Map

### Problem Analysis

**File:** `lua/andrew/vault/search_filter/match_task.lua` (lines 20-22,
38-42)

`resolve_state_mark()` iterates `config.task_states` on every call to
find the mark character for a state label:

```lua
local function resolve_state_mark(label)
  for _, s in ipairs(config.task_states) do
    if s.label:lower() == label:lower() then
      return s.mark
    end
  end
end
```

This is called per task when matching `task-state:` filters. For 500
tasks, with 5 task states, that's 500 * 5 = 2500 comparisons + 2500
`:lower()` allocations.

### Proposed Solution

Build a `label_lower -> mark` lookup table once at module load:

### Code Changes

```lua
-- Module-level (top of match_task.lua)
local _state_map = nil

local function get_state_map()
  if not _state_map then
    _state_map = {}
    for _, s in ipairs(config.task_states) do
      _state_map[s.label:lower()] = s.mark
    end
  end
  return _state_map
end

local function resolve_state_mark(label)
  return get_state_map()[label:lower()]
end
```

### Expected Performance Improvement

For `task-state:in-progress` on 500 tasks:

- **Before:** 500 * 5 = 2500 iterations + 2500 `:lower()` allocations
- **After:** 1 `:lower()` + 1 hash lookup per task = 500 total ops

~5x reduction in state resolution work.

### Risk Assessment

- **Config changes:** Task states are set once at init. If they could
  change, add a config generation check or rebuild on config change.

---

## ~~3. Pre-Resolved Filter Timestamp~~ → Consolidated into doc 55-search-filter-precomputation.md (FilterContext precomputation covers this)

---

## 3. Pre-Lowered Task Tags

### Problem Analysis

**File:** `lua/andrew/vault/search_filter/match_task.lua` (lines 141-152)

`match_task_tag()` lowercases each tag on every comparison:

```lua
local target_lower = target:lower()  -- once per call (good)
for _, task in ipairs(tasks) do
  if task.tags then
    for _, tag in ipairs(task.tags) do
      if tag:lower() == target_lower then  -- per tag per task
        results[#results + 1] = task
        break
      end
    end
  end
end
```

For 500 tasks with 3 tags each: 1500 `:lower()` allocations.

### Proposed Solution

Store pre-lowered tags in the vault index task entries, or build a
per-task tag set once:

### Code Changes

```lua
-- Option A: Pre-lower during index parsing (vault_index_parser.lua)
-- In extract_tasks():
task.tags_lower = {}
for _, tag in ipairs(task.tags or {}) do
  task.tags_lower[tag:lower()] = true  -- set for O(1) lookup
end

-- In match_task_tag():
local target_lower = target:lower()
for _, task in ipairs(tasks) do
  if task.tags_lower and task.tags_lower[target_lower] then
    results[#results + 1] = task
  end
end
```

### Expected Performance Improvement

For `task-tag:urgent` on 500 tasks with 3 tags each:

- **Before:** 1500 `:lower()` + 1500 string comparisons
- **After:** 500 hash lookups (O(1) each), 0 `:lower()` allocations

~3x reduction in string operations.

### Risk Assessment

- **Memory:** One extra set per task. For 500 tasks with 3 tags: ~6KB.
- **Index size:** Slightly larger persisted index. Could skip
  `tags_lower` in serialization (rebuild on load).

---

## 4. Predicate Short-Circuiting in Graph Filter

### Problem Analysis

**File:** `lua/andrew/vault/graph_filter.lua` (line 195)

`build_predicate()` returns a closure that evaluates all predicates
in sequence without short-circuiting on first failure:

```lua
-- Current: evaluates ALL predicates even if first fails
local function combined(path, entry)
  for _, pred in ipairs(predicates) do
    if not pred(path, entry) then
      return false
    end
  end
  return true
end
```

**Note:** The code above already short-circuits with `return false`.
However, individual predicates like `tag_predicate()` (line 77) call
`filter_utils.get_tags()` per entry, which rebuilds the tag set:

```lua
local function tag_predicate(path, entry)
  local tags = filter_utils.get_tags(entry)  -- rebuilds set per call
  -- ...
end
```

### Proposed Solution

Pre-build tag sets during predicate construction rather than per-call:

### Code Changes

```lua
-- In build_predicate(), when tags filter is active:
local function tag_predicate_cached()
  -- Pre-build entry -> tag_set map at filter time
  local tag_cache = {}
  return function(path, entry)
    if not tag_cache[path] then
      tag_cache[path] = filter_utils.get_tags(entry)
    end
    local tags = tag_cache[path]
    -- ... check include/exclude ...
  end
end
```

### Expected Performance Improvement

For a graph with 200 nodes, toggling a tag filter:

- **Before:** 200 `get_tags()` calls (rebuilds set per node per filter)
- **After:** 200 `get_tags()` calls on first filter, 0 on subsequent
  (cache persists across predicate evaluations within same filter set)

### Risk Assessment

- **Cache scope:** Tag cache lives within the predicate closure. When
  filters change, new predicate is built, old cache is GC'd.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Pre-lowered basename (#1) | Low | High | Low |
| 2 | Task state map (#2) | Low | Medium | Low |
| 3 | Pre-lowered task tags (#3) | Medium | Medium | Low |
| 4 | Predicate tag cache (#4) | Low | Low | Low |

---

## Testing Strategy

### Pre-Lowered Basename (#1)
1. Search `name:MyNote`. Verify correct case-insensitive matching.
2. Search `links-to:Note`. Verify all linking files found.

### Task State Map (#2)
1. Search `task-state:in-progress`. Verify matching tasks returned.
2. Search `task-state:DONE` (uppercase). Verify case-insensitive match.

### Pre-Lowered Tags (#3)
1. Search `task-tag:urgent`. Verify matching tasks.
2. Search `task-tag:URGENT`. Verify case-insensitive match.

### Predicate Tag Cache (#4)
1. Open graph. Apply tag filter. Verify correct node filtering.
2. Toggle tag filter on/off rapidly. Verify no stale results.

---

## Related Documents

- Doc 55 consolidates filter-level date precomputation. Doc 57-search-filter-performance covers related search filter optimizations.
- Doc 73-search-completion-graph-render-caching #1 uses pre-lowered basenames in the search completion module. If #1 here (pre-lowered `basename_lower` at index level) is implemented, Doc 73's cache can use the pre-lowered value directly.
