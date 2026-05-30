# 66 --- Completion Build & Keystroke Efficiency

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

Two targeted optimizations for the completion system, addressing double
iteration in field value accumulation and per-keystroke tag hierarchy filtering.

> **Modules affected:** `completion_base.lua`, `completion_tags.lua`

---

## 1. Single-Pass Field Value Accumulation — IMPLEMENTED

> **Status:** IMPLEMENTED + CLEANED UP. `build_kv_single_pass()` merges
> accumulation and item building into a single iteration over `idx.files`.
> Dead code (`accumulate_fields`, `build_kv_items`) removed — no external
> callers existed.

### Problem Analysis

**File:** `lua/andrew/vault/completion_base.lua` (lines 324-351, 361-417)

The completion build pipeline for frontmatter and inline field sources uses a
two-pass approach:

1. **Pass 1 — `accumulate_fields()`** (lines 327-349): Iterates all
   `idx.files` entries, extracts field key-value pairs, and accumulates
   counts into a `field_values` table: `field_values[key][value] = count`.

2. **Pass 2 — `build_kv_items()`** (lines 394-414): Iterates the
   `field_values` table again, converting each `(key, value, count)` triple
   into a blink.cmp completion item with `label`, `sortText`, `detail`, etc.

```lua
-- completion_base.lua:327-349 (Pass 1)
local function accumulate_fields(idx, extract_fn)
  local field_values = {}
  for _, entry in pairs(idx.files) do               -- O(N files)
    local fields = extract_fn(entry)
    for key, val in pairs(fields or {}) do           -- O(M fields per file)
      for _, item in ipairs(type(val) == "table" and val or { val }) do
        local s = tostring(item)
        if not field_values[key] then field_values[key] = {} end
        field_values[key][s] = (field_values[key][s] or 0) + 1
      end
    end
  end
  return field_values
end

-- completion_base.lua:394-414 (Pass 2)
local function build_kv_items(field_values, known_vals)
  local items = {}
  for key, vals in pairs(field_values) do            -- O(K unique keys)
    for val, count in pairs(vals) do                 -- O(V values per key)
      items[#items + 1] = {
        label = val,
        sortText = freq_sort_text(count, val),
        detail = key .. " (" .. count .. ")",
        -- ...
      }
    end
  end
  return items
end
```

For a vault with 2000 files, 10 field types, and 100 unique values per type,
Pass 1 creates 10 * 100 = 1000 count entries, then Pass 2 iterates all 1000
entries again to build items. The `tostring()` call at line 334/341 also
allocates a new string for every value even when the value is already a string.

**Complexity:** O(N * M * V) for accumulation + O(K * V) for item building.

### Proposed Solution

Merge the two passes: build completion items during accumulation, updating
counts in-place. Use a secondary index from `(key, value_string)` to the
existing item for O(1) count updates.

### Code Changes

**File: `lua/andrew/vault/completion_base.lua`**

**After (merged single-pass):**

```lua
--- Build field completion items in a single pass over the index.
---@param idx table  vault index
---@param extract_fn function  entry -> { key = value|list }
---@param known_vals table  preset field values from config
---@return table[]  completion items
local function build_field_items_single_pass(idx, extract_fn, known_vals)
  local items = {}
  -- (key, value_string) -> index in items[]
  local item_index = {}

  -- Pass 1+2 merged: accumulate and build items simultaneously
  for _, entry in pairs(idx.files) do
    local fields = extract_fn(entry)
    for key, val in pairs(fields or {}) do
      local values = type(val) == "table" and val or { val }
      for _, v in ipairs(values) do
        -- Skip tostring() when value is already a string
        local s = type(v) == "string" and v or tostring(v)
        if s ~= "" then
          local idx_key = key .. "\0" .. s
          local existing_idx = item_index[idx_key]
          if existing_idx then
            -- Update count in-place
            local item = items[existing_idx]
            item._count = item._count + 1
            item.detail = key .. " (" .. item._count .. ")"
            item.sortText = freq_sort_text(item._count, s)
          else
            -- Create new item
            items[#items + 1] = {
              label = s,
              sortText = freq_sort_text(1, s),
              detail = key .. " (1)",
              kind = 12,  -- Value
              _count = 1,
              _key = key,
            }
            item_index[idx_key] = #items
          end
        end
      end
    end
  end

  -- Merge preset values (from known_vals) that weren't seen in the vault
  if known_vals then
    for key, presets in pairs(known_vals) do
      for _, v in ipairs(presets) do
        local s = type(v) == "string" and v or tostring(v)
        local idx_key = key .. "\0" .. s
        if not item_index[idx_key] then
          items[#items + 1] = {
            label = s,
            sortText = freq_sort_text(0, s),
            detail = key .. " (preset)",
            kind = 12,
            _count = 0,
            _key = key,
          }
          item_index[idx_key] = #items
        end
      end
    end
  end

  return items
end
```

### Expected Performance Improvement

For a 2000-file vault with 1000 unique (key, value) pairs:

- **Before:** 2000 file iterations + 1000 item iterations = 3000 loop bodies
- **After:** 2000 file iterations (items built inline) = 2000 loop bodies

~33% reduction in loop iterations. Also eliminates the intermediate
`field_values` table allocation (1000 entries with sub-tables), reducing
GC pressure.

The `tostring()` skip for string values avoids ~80% of unnecessary string
allocations (most field values are already strings).

### Risk Assessment

- **Correctness:** The merged approach produces identical items — same labels,
  counts, and sort order. The `_count` field is used internally and stripped
  or ignored by blink.cmp.
- **item_index memory:** One entry per unique (key, value) pair. For 1000
  unique pairs, ~50KB — negligible.
- **Preset ordering:** Presets are added after vault values, matching current
  behavior where `build_kv_items()` processes presets after accumulated values.

---

## 2. Pre-Indexed Tag Hierarchy for Completion — IMPLEMENTED

> **Status:** IMPLEMENTED. `build()` now constructs a `_prefix_index` map
> (prefix_string → { immediate, descendants }) and `get_completions()` uses
> O(1) table lookup instead of scanning all items per keystroke.

### Problem Analysis

**File:** `lua/andrew/vault/completion_tags.lua` (lines 23-34, 67-115)

The tag completion source has two performance issues:

**Build phase (lines 23-34):** Computes `has_children_set` by scanning forward
through sorted tags. While the algorithm is O(N log N) due to sorting (not
O(N^2) as initially suspected), it creates a `has_children_set` lookup but
does NOT pre-build a child-to-parent index.

**Keystroke phase (lines 92-109):** On every keystroke with a hierarchical tag
prefix (e.g., `#project/`), `get_completions()` iterates ALL items to filter
by prefix:

```lua
-- completion_tags.lua:92-109 (per-keystroke filtering)
local parent_prefix = parent_tag .. "/"
local filtered = {}
for _, item in ipairs(items) do
  if item.label:sub(1, #parent_prefix) == parent_prefix then
    local remainder = item.label:sub(#parent_prefix + 1)
    if not remainder:find("/") then
      filtered[#filtered + 1] = item  -- immediate child
    end
  end
end
-- Fallback: if no immediate children found, scan again for all descendants
if #filtered == 0 then
  for _, item in ipairs(items) do
    if item.label:sub(1, #parent_prefix) == parent_prefix then
      filtered[#filtered + 1] = item
    end
  end
end
```

For 500 tags, this scans 500 items per keystroke, potentially twice (with
fallback). The prefix filtering and string operations repeat identical work.

### Proposed Solution

Pre-build a prefix-to-children map during the build phase. On keystroke,
perform a single O(1) map lookup instead of scanning all items.

### Code Changes

**File: `lua/andrew/vault/completion_tags.lua`**

**Build phase addition:**

```lua
-- In build() function, after building items:

-- Pre-index: parent_prefix -> { immediate_children, all_descendants }
local prefix_index = {}

for _, item in ipairs(items) do
  local tag = item.label
  -- Find all ancestor prefixes for this tag
  local pos = 0
  while true do
    pos = tag:find("/", pos + 1)
    if not pos then break end
    local prefix = tag:sub(1, pos)  -- e.g., "project/"
    if not prefix_index[prefix] then
      prefix_index[prefix] = { immediate = {}, descendants = {} }
    end
    local entry = prefix_index[prefix]
    entry.descendants[#entry.descendants + 1] = item
    -- Check if immediate child (no more "/" after prefix)
    local remainder = tag:sub(pos + 1)
    if not remainder:find("/") then
      entry.immediate[#entry.immediate + 1] = item
    end
  end
end

-- Store for use in get_completions()
self._prefix_index = prefix_index
```

**Keystroke phase (get_completions) replacement:**

```lua
-- Replace lines 92-109 with:
local parent_prefix = parent_tag .. "/"
local indexed = self._prefix_index and self._prefix_index[parent_prefix]
if indexed then
  local filtered = #indexed.immediate > 0 and indexed.immediate or indexed.descendants
  return filtered
end
-- Fallback to linear scan only if prefix_index not built yet
```

### Expected Performance Improvement

For 500 tags with hierarchical prefixes:

- **Before:** 500-1000 string comparisons per keystroke (with fallback scan)
- **After:** 1 table lookup per keystroke

~500x reduction in per-keystroke work for tag hierarchy navigation. The
build-time cost increases slightly (one-time O(N * D) where D = average tag
depth), but build runs only on index changes, not keystrokes.

### Risk Assessment

- **Memory:** One map entry per unique prefix. For 500 tags with average
  depth 3, ~1500 prefix entries referencing existing item tables. ~10KB.
- **Correctness:** The prefix index produces the same filtered results as
  the linear scan. Both paths return items whose labels start with the
  parent prefix.
- **Stale index:** The prefix index is rebuilt whenever `build()` runs
  (on index generation change), matching the lifecycle of the items array.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Single-Pass Accumulation (#1) | Medium | Medium | Low |
| 2 | Tag Hierarchy Pre-Index (#2) | Medium | Medium | Low |

**#1 (Single-Pass Accumulation)** eliminates the intermediate `field_values`
table and reduces iteration. Straightforward refactor of two functions into one.

**#2 (Tag Pre-Index)** adds a build-time index for O(1) keystroke lookups.
Medium effort due to prefix tree construction. Also subsumes the O(N) child
detection optimization (previously in 57 and 59).

---

## Testing Strategy

### Single-Pass Accumulation (#1)

1. Compare completion items (labels, counts, sort order) before/after for a
   test vault with known field values.
2. Verify preset values appear correctly when not present in vault data.
3. Benchmark build time for a 2000-file vault.

### Tag Pre-Index (#2)

1. Compare filtered tag results for various prefixes (single level, deep
   hierarchy, no children) before/after.
2. Verify fallback to descendants when no immediate children exist.
3. Verify O(N) child detection: with tags `project`, `project/a`, `project/b`,
   `other`, confirm `has_children_set` contains `project` and not `other`.
4. Test empty tag list and single tag.
5. Benchmark keystroke response time with 1000+ tags.

---

## Related Documents

- Doc 57-completion-system-optimizations covers completion system debounce and batch sizing (complementary).
