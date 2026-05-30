# 82 --- Residual Lower Allocations & Graph Tag Hierarchy Fix

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

> **Status:** Complete.

Follow-up to Doc 75 (match field/task lowercase caching). Addresses
remaining per-entry `:lower()` allocations in the filter pipeline and
a behavioral bug where graph tag filtering ignores hierarchical tags.

> **Modules affected:** `search_filter/match_helpers.lua`,
> `search_filter/match_task.lua`, `search_filter/match_field.lua`,
> `graph_filter.lua`, `filter_utils.lua`

---

## 1. Graph Tag Predicate Hierarchical Matching (Bug Fix)

### Problem Analysis

**File:** `lua/andrew/vault/graph_filter.lua` (lines 75-88)

`tag_predicate()` uses `filter_utils.get_tags()` which returns a flat
`table<string, boolean>` set, then matches via direct key lookup:

```lua
return filter_utils.matches_include_exclude(include, exclude, function(item)
  return tags[item]
end)
```

This means filtering by tag `project` will NOT match notes tagged
`project/alpha`. The search filter system correctly uses
`vault_index.tag_matches()` (with hierarchical prefix matching and
case-insensitive support) at `match_field.lua:154`, but the graph
filter bypasses this entirely.

**Impact:** Inconsistent tag filtering behavior between search and
graph views. Users filtering by a parent tag in the graph see fewer
results than the equivalent search query.

### Proposed Solution

Replace the flat set lookup in `tag_predicate` with
`vault_index.tag_matches()`, matching the search filter behavior.

### Code Changes

```lua
-- graph_filter.lua, tag_predicate():
local function tag_predicate(include, exclude)
  local tag_cache = {}
  return function(path)
    if not tag_cache[path] then
      tag_cache[path] = filter_utils.get_tags_list(path)
    end
    local entry_tags = tag_cache[path]
    return filter_utils.matches_include_exclude(include, exclude, function(filter_tag)
      return vault_index.tag_matches(entry_tags, filter_tag, { case_insensitive = true })
    end)
  end
end
```

Requires adding `filter_utils.get_tags_list(path)` that returns the raw
`string[]` array (not a set), or using `entry.tags` directly from the
vault index entry. Alternatively, pass the entry's tags array through
the cache instead of a set.

### Risk Assessment

- **Behavioral change:** Notes with child tags now appear when
  filtering by parent tag. This is the correct, expected behavior.
- **Performance:** `vault_index.tag_matches()` iterates the tags array
  (O(T) per filter tag). For typical entries with <10 tags this is
  negligible. The per-path cache prevents redundant index lookups.

---

## 2. Pre-Lowered Filter Value in `eq_ci`

### Problem Analysis

**File:** `lua/andrew/vault/search_filter/match_helpers.lua` (line 46)

```lua
function M.eq_ci(a, b)
  if a == nil or b == nil then return false end
  return tostring(a):lower() == tostring(b):lower()
end
```

Called from `match_field.lua` for `type:` (line 177), `status:`
(line 341), and generic `=` fields (line 433). In all three cases,
`b` is the constant `filter_val` from the AST node, lowered
redundantly on every entry. Side `a` (the entry value) varies per
entry and must be lowered each time.

The file/alias/range fields already cache their lowered filter values
on the AST node (`node._file_val_lower`, `node._alias_val_lower`,
`node._range_lo_lower`), but `type`, `status`, and generic `=` do not.

### Proposed Solution

Cache the lowered filter value on the AST node (same pattern as file
and alias fields). Add an `eq_ci_cached` helper or inline the
comparison at each call site.

### Code Changes

```lua
-- Option A: Cache on node at each call site in match_field.lua

-- type: field (line 177):
if op == "=" then
  local fv = node._type_val_lower
  if not fv then fv = filter_val:lower(); node._type_val_lower = fv end
  local ev = entry_val and tostring(entry_val):lower() or nil
  return ev == fv
end

-- status: field (line 341):
if op == "=" then
  local fv = node._status_val_lower
  if not fv then fv = filter_val:lower(); node._status_val_lower = fv end
  local ev = entry_val and tostring(entry_val):lower() or nil
  return ev == fv
end

-- generic = field (line 433):
if op == "=" then
  if num_entry and num_filter then return num_entry == num_filter end
  local fv = node._generic_eq_lower
  if not fv then fv = filter_val:lower(); node._generic_eq_lower = fv end
  return tostring(entry_val):lower() == fv
end
```

### Expected Performance Improvement

For `type:note` on 2000 files:

- **Before:** 2000 `filter_val:lower()` allocations (1 per entry)
- **After:** 1 `filter_val:lower()` allocation (cached on node)

Same pattern for `status:` and generic `=` fields.

### Risk Assessment

- **Low risk:** Identical pattern to existing `_file_val_lower` and
  `_alias_val_lower` caching. AST nodes are per-query and GC'd
  after evaluation.

---

## 3. Pre-Lowered Outlink Names in Links-To/Linked-From

### Problem Analysis

**File:** `lua/andrew/vault/search_filter/match_field.lua`

In `links-to` heading matching (line 259):

```lua
for _, link in ipairs(entry.outlinks or {}) do
  ...
  local link_name_lower = link_name:lower()  -- per outlink
```

In `linked-from` section matching (line 311):

```lua
for _, link in ipairs(section_outlinks) do
  ...
  link_name = vim.trim(link_name):lower()  -- per outlink
```

Both lower the outlink name inside per-entry loops. The outlink names
come from the vault index and are stable per index generation.

### Proposed Solution

Store `path_lower` on outlink entries during index parsing, or build a
per-entry lowered outlinks cache on first access.

### Code Changes

```lua
-- Option A: Pre-lower at parse time (vault_index_parser.lua, extract_outlinks):
link.path_lower = link.path:lower()

-- Then in match_field.lua links-to (line 259):
local link_name_lower = (link.path_lower or ""):match("^([^#^]+)") or ""
link_name_lower = vim.trim(link_name_lower)

-- Option B: Lower once per match_field call using local cache:
-- (More localized, no index schema change)
local function get_link_name_lower(link)
  if not link._name_lower then
    local raw = link.path or ""
    local name = raw:match("^([^#^]+)") or raw
    link._name_lower = vim.trim(name):lower()
  end
  return link._name_lower
end
```

### Expected Performance Improvement

For `links-to:Note#Heading` on 2000 files with 10 outlinks each:

- **Before:** Up to 20000 `:lower()` allocations
- **After:** 0 (if Option A) or at most 20000 on first query then 0
  on subsequent queries within same index generation (if Option B)

### Risk Assessment

- **Option A** increases index entry size slightly but is cleanest.
- **Option B** mutates link objects (acceptable since they persist
  within the index generation).
- Both approaches are safe; outlinks are immutable within an index
  generation.

---

## 4. Pre-Lowered Task Text for Pattern Matching

### Problem Analysis

**File:** `lua/andrew/vault/search_filter/match_task.lua` (lines 262,
273, 285)

Three task variant loops (`any`, `todo`, `done`) all lower task text
per-task:

```lua
if task.text and task.text:lower():find(pattern_lower, 1, true) then
```

Also in `filter_utils.lua` line 160:

```lua
if not (task.text or ""):lower():find(opts._text_pattern_lower, 1, true) then
```

For 500 tasks, this creates 500 (or up to 1500 across variants)
`:lower()` string allocations.

### Proposed Solution

Store `text_lower` on task entries during index parsing.

### Code Changes

```lua
-- vault_index_parser.lua, extract_tasks():
task.text_lower = task.text and task.text:lower() or nil

-- match_task.lua (lines 262, 273, 285):
if task.text_lower and task.text_lower:find(pattern_lower, 1, true) then

-- filter_utils.lua (line 160):
if not (task.text_lower or ""):find(opts._text_pattern_lower, 1, true) then
```

### Expected Performance Improvement

For `task:keyword` on 500 tasks:

- **Before:** 500 `:lower()` allocations per variant check
- **After:** 0 `:lower()` allocations (pre-computed at parse time)

### Risk Assessment

- **Memory:** One extra string per task. For 500 tasks averaging 80
  chars: ~40KB. Acceptable.
- **Index size:** Can skip `text_lower` in serialization (rebuild on
  load, same as `tags_lower`).

---

## 5. Pre-Lowered Repeat Rule for Pattern Matching

### Problem Analysis

**File:** `lua/andrew/vault/search_filter/match_task.lua` (line 186)

```lua
if task.repeat_rule:lower():find(value_lower, 1, true) then
```

Called per-task inside the task loop. The repeat rule string is stable
per index generation.

### Proposed Solution

Store `repeat_rule_lower` during index parsing or lazily on first access.

### Code Changes

```lua
-- vault_index_parser.lua, extract_tasks() or vault_index.lua load():
if task.repeat_rule then
  task.repeat_rule_lower = task.repeat_rule:lower()
end

-- match_task.lua (line 186):
if task.repeat_rule_lower and task.repeat_rule_lower:find(value_lower, 1, true) then
```

### Expected Performance Improvement

For `task-repeat:weekly` on 200 recurring tasks:

- **Before:** 200 `:lower()` allocations
- **After:** 0 allocations

### Risk Assessment

- **Low impact:** Repeat rules are short strings (~10-20 chars).
  Savings are modest but free.
- **Skip in serialization:** Same pattern as `tags_lower`.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Graph tag hierarchy fix (#1) | Low | High | Low (bug fix) |
| 2 | Pre-lowered filter value in eq_ci (#2) | Low | Medium | Low |
| 3 | Pre-lowered task text (#4) | Low | Medium | Low |
| 4 | Pre-lowered outlink names (#3) | Medium | Medium | Low |
| 5 | Pre-lowered repeat rule (#5) | Low | Low | Low |

---

## Testing Strategy

### Graph Tag Hierarchy (#1)
1. Tag a note with `project/alpha`. Open graph, filter by `project`.
   Verify the note appears.
2. Filter by `project/alpha` (exact). Verify same result.
3. Filter by `other`. Verify the note does NOT appear.

### Pre-Lowered eq_ci (#2)
1. Search `type:Note`. Verify matching.
2. Search `status:active`. Verify matching.
3. Verify case-insensitive: `type:NOTE` matches `type: note`.

### Pre-Lowered Outlink Names (#3)
1. Search `links-to:Note#Heading`. Verify correct results.
2. Search `linked-from:Note#Section`. Verify correct results.

### Pre-Lowered Task Text (#4)
1. Search `task:keyword`. Verify matching tasks found.
2. Search `task-todo:Keyword` (mixed case). Verify case-insensitive.

### Pre-Lowered Repeat Rule (#5)
1. Search `task-repeat:weekly`. Verify matching recurring tasks.
2. Search `task-repeat:DAILY`. Verify case-insensitive.

---

## Related Documents

- Doc 75: Predecessor (match field/task lowercase caching, completed).
- Doc 58-parser: Parser precomputation phase; task text/outlink
  pre-lowering would be added to the same parsing pass.
- Doc 55: FilterContext precomputation; pre-lowered fields reduce
  FilterContext per-entry work.
