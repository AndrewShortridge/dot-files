# 55 --- Search Filter Precomputation

This document is a self-contained implementation guide. Each optimization below is unique to this document.

**Status:** Implemented

Targeted performance improvement for the advanced search system, addressing
redundant per-entry computation in metadata filters.

---

## 1. Filter Context Precomputation

> **Canonical source:** This is the authoritative document for filter-level
> date precomputation (hoisting `resolve_date()` calls from per-entry to
> per-query level via FilterContext). Other documents that reference date
> filter precomputation defer to this one.

### Problem Analysis

**Files:** `lua/andrew/vault/search_filter/match_field.lua`, `lua/andrew/vault/search_filter/match_task.lua`

When `evaluate()` processes a query against the vault index, it calls
`match_entry()` for every file in the index. Many filter operations re-parse
or re-resolve the **same constant filter value** on every entry:

1. **Date resolution** (`match_field.lua:346-390`): `date_utils.resolve_date(filter_val)`
   is called for every entry, even though `filter_val` is constant per query.
   For `created:>2024-01-01` on a 2000-file vault, that's 2000 identical
   `resolve_date()` calls.

2. **Tag filter parsing** (`match_field.lua:183-188`): `filter_utils.parse_tag_filter(filter_val)`
   is called per entry. The include/exclude sets are identical across all entries.

3. **Link target resolution** (`match_field.lua:220-227`): `filter_utils.resolve_in_index(index, target_name)`
   resolves the same target name for every entry when evaluating `links-to:TargetNote`.

4. **Numeric conversion** (`match_field.lua:331-344`): `tonumber(filter_val)` and
   `tonumber(filter_val2)` are called per entry for priority comparisons.

5. **Section cache invalidation** (`match_field.lua:32-38`): `maybe_invalidate_section_cache()`
   checks the index generation on every entry, but the generation only changes
   once per evaluation.

### Proposed Solution

Introduce a `FilterContext` object created once per `evaluate()` call that
pre-computes all constant filter values. Pass it through `match_entry()` to
all sub-matchers.

### Code Changes

**File: `lua/andrew/vault/search_filter/init.lua` (or wherever evaluate lives)**

```lua
--- Pre-compute constant filter values from the AST.
--- Called once per evaluate(), results passed to every match_entry() call.
---@param ast table  parsed query AST
---@param index table  vault index
---@return table  context with pre-resolved values
local function build_filter_context(ast, index)
  local ctx = {
    resolved_dates = {},     -- filter_val -> timestamp
    parsed_tags = {},        -- filter_val -> {includes, excludes}
    resolved_links = {},     -- target_name -> rel_path or false
    numeric_values = {},     -- filter_val -> number or false
    section_cache_valid = false,
  }

  -- Walk AST to find all field/task nodes, pre-resolve their values
  local function walk(node)
    if not node then return end
    if node.type == "field" then
      local name, val, val2 = node.name, node.value, node.value2

      -- Pre-resolve dates
      if name == "created" or name == "modified" or name == "due"
        or name == "scheduled" or name == "completion" then
        if val and not ctx.resolved_dates[val] then
          ctx.resolved_dates[val] = date_utils.resolve_date(val)
        end
        if val2 and not ctx.resolved_dates[val2] then
          ctx.resolved_dates[val2] = date_utils.resolve_date(val2)
        end
      end

      -- Pre-parse tag filters
      if name == "tag" and val then
        if not ctx.parsed_tags[val] then
          ctx.parsed_tags[val] = { filter_utils.parse_tag_filter(val) }
        end
      end

      -- Pre-resolve link targets
      if (name == "links-to" or name == "linked-from") and val then
        if ctx.resolved_links[val] == nil then
          ctx.resolved_links[val] = filter_utils.resolve_in_index(index, val) or false
        end
      end

      -- Pre-convert numeric values
      if name == "priority" then
        if val and ctx.numeric_values[val] == nil then
          ctx.numeric_values[val] = tonumber(val) or false
        end
        if val2 and ctx.numeric_values[val2] == nil then
          ctx.numeric_values[val2] = tonumber(val2) or false
        end
      end

    end

    walk(node.left)
    walk(node.right)
    walk(node.operand)
  end

  walk(ast)

  -- Invalidate section cache once (not per entry)
  match_field.maybe_invalidate_section_cache(index)
  ctx.section_cache_valid = true

  return ctx
end

function M.evaluate(ast, index, graph_sets)
  local ctx = build_filter_context(ast, index)
  local matches = {}

  for rel_path, entry in pairs(index.files) do
    if M.match_entry(ast, entry, index, graph_sets, ctx) then
      matches[rel_path] = entry
    end
  end

  return matches
end
```

**File: `lua/andrew/vault/search_filter/match_field.lua`**

Update `match_field()` to accept and use context:

```lua
-- Before:
local filter_ts = date_utils.resolve_date(filter_val)

-- After:
local filter_ts = ctx and ctx.resolved_dates[filter_val]
  or date_utils.resolve_date(filter_val)
```

```lua
-- Before:
local includes, excludes = filter_utils.parse_tag_filter(filter_val)

-- After:
local cached = ctx and ctx.parsed_tags[filter_val]
local includes, excludes
if cached then
  includes, excludes = cached[1], cached[2]
else
  includes, excludes = filter_utils.parse_tag_filter(filter_val)
end
```

```lua
-- Before:
local target_rel = filter_utils.resolve_in_index(index, target_name)

-- After:
local target_rel = ctx and ctx.resolved_links[target_name]
if target_rel == false then target_rel = nil end
if target_rel == nil and not ctx then
  target_rel = filter_utils.resolve_in_index(index, target_name)
end
```

### Expected Performance Improvement

For a query like `tag:project created:>2024-01-01 priority:<=3` on a 2000-file vault:

- **Before:** 2000 * 3 = 6000 redundant re-computations (parse_tag_filter + resolve_date + tonumber)
- **After:** 3 computations total, cached in context

For complex queries with 5+ filter terms, this eliminates **10,000-30,000
redundant operations per search**, reducing metadata evaluation time by
an estimated 30-50%.

### Risk Assessment

- **Backward compatibility:** The `ctx` parameter is optional; all matchers
  fall back to direct computation if `ctx` is nil.
- **Correctness:** Pre-computed values are immutable during a single evaluation.
  No entry-dependent state is cached (only query-constant values).
- **AST walk overhead:** The single walk to pre-compute is O(AST nodes), which
  is negligible compared to O(N * filters) saved.

---

## Testing Strategy

1. Run same complex query with and without context. Compare results for
   identity (same matched files, same order).
2. Profile with `vim.uv.hrtime()` before/after on a 1000+ file vault.
3. Edge case: empty filter values, missing frontmatter fields.

---

## Related Documents

- Doc 75 #3 (pre-resolved filter timestamp in `match_task`) was consolidated
  here as it is a subset of FilterContext date precomputation.
- Doc 81 #2 covers module-level `parse_iso_datetime` caching (different level,
  complementary to the query-level precomputation described here).
