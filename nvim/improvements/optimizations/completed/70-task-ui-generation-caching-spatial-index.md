# 70 --- Task UI Generation Caching & Spatial Indexing

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

Targeted improvements for the task kanban, hierarchy, and notification
systems, addressing missing generation-based caching and linear card position
lookups.

> **Modules affected:** `task_kanban.lua`, `task_hierarchy.lua`,
> `task_notify.lua`

---

## 1. Generation-Cached Kanban Task Collection

### Problem Analysis

**File:** `lua/andrew/vault/task_kanban.lua` (lines 24-91)

`collect_tasks_by_status()` iterates ALL vault files on every redraw,
filter toggle, and column navigation:

```lua
for rel_path, entry in pairs(idx.files or {}) do
  if entry.tasks then
    for _, task in ipairs(entry.tasks) do
      local abs_path = vault_path .. "/" .. rel_path  -- string concat in inner loop
      -- ... bucket by status ...
    end
  end
end
```

When the user toggles filters (p/d//) or navigates columns, the full
vault scan runs again even though the vault index hasn't changed.

**Sub-problems:**

1. **No generation tracking:** Every interaction triggers O(N * T) iteration
   where N = files, T = avg tasks per file.
2. **Path reconstruction:** `vault_path .. "/" .. rel_path` concatenated
   for every task when `entry.abs_path` already exists.
3. **Redundant bucket truncation:** Copies bucket array even when size
   equals `max_per_col`.

### Proposed Solution

Cache the raw task buckets by vault index generation. Apply filters on the
cached buckets instead of re-collecting from the index.

### Code Changes

```lua
local _kanban_cache = { gen = 0, buckets = nil, all_items = nil }

local function collect_tasks_cached()
  local idx = vault_index.current()
  if not idx then return {} end

  local gen = idx._generation or 0
  if _kanban_cache.gen == gen and _kanban_cache.all_items then
    return _kanban_cache.all_items
  end

  local all_items = {}
  for rel_path, entry in pairs(idx.files or {}) do
    if entry.tasks then
      local abs_path = entry.abs_path  -- use pre-computed path
      for _, task in ipairs(entry.tasks) do
        all_items[#all_items + 1] = {
          task = task, rel_path = rel_path, abs_path = abs_path,
        }
      end
    end
  end

  _kanban_cache = { gen = gen, all_items = all_items }
  return all_items
end

-- Filter from cached list (fast)
local function bucket_tasks(all_items, filters)
  local buckets = {}
  for _, item in ipairs(all_items) do
    if passes_filters(item.task, filters) then
      local mark = item.task.status or " "
      if not buckets[mark] then buckets[mark] = {} end
      buckets[mark][#buckets[mark] + 1] = item
    end
  end
  return buckets
end
```

### Expected Performance Improvement

For a 1000-file vault with 500 tasks, toggling a filter:

- **Before:** 1000 file iterations + 500 task iterations per filter toggle
- **After:** 500 cached item iterations (filter only) per filter toggle;
  0 work if filters unchanged and generation matches

### Risk Assessment

- **Staleness:** Generation tracking ensures fresh data when files change.
- **Memory:** One list of task item references. For 500 tasks: ~20KB.

---

## 2. Spatial Index for Kanban Card Navigation

### Problem Analysis

**File:** `lua/andrew/vault/task_kanban.lua` (lines 346-397)

Three navigation functions use linear search over `card_positions`:

- `find_card_at_cursor()` (lines 346-363): scans all cards for cursor match
- `find_card_in_column()` (lines 370-382): scans all cards for column + row
- `cards_in_column()` (lines 388-397): scans all cards for column membership

These are called on every h/j/k/l keypress during kanban navigation:

```lua
local function find_card_at_cursor()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, cp in ipairs(card_positions) do
    if row >= cp.start_row and row <= cp.end_row then
      return cp
    end
  end
end
```

For a kanban board with 100 cards, each keypress triggers 100 linear
comparisons.

### Proposed Solution

Build spatial indexes during render: `row_to_card` (row number -> card)
and `col_to_cards` (column index -> sorted card list).

### Code Changes

```lua
local _row_index = {}     -- row_number -> card_position
local _col_index = {}     -- col_idx -> { card_position, ... }

local function build_spatial_index(card_positions)
  _row_index = {}
  _col_index = {}

  for _, cp in ipairs(card_positions) do
    -- Row index: map every row in the card's range
    for row = cp.start_row, cp.end_row do
      _row_index[row] = cp
    end

    -- Column index
    if not _col_index[cp.col] then _col_index[cp.col] = {} end
    _col_index[cp.col][#_col_index[cp.col] + 1] = cp
  end
end

-- O(1) card lookup by cursor position
local function find_card_at_cursor()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return _row_index[row]
end

-- O(1) column card list
local function cards_in_column(col_idx)
  return _col_index[col_idx] or {}
end
```

### Expected Performance Improvement

- **Before:** O(N) linear search per keypress (N = total cards)
- **After:** O(1) hash lookup per keypress

For 100 cards with 4 keypresses per second: 400 comparisons/sec -> 4 lookups/sec.

### Risk Assessment

- **Build cost:** O(N * avg_card_height) for row index. For 100 cards with
  3-line height: 300 entries. Built once per render, which already does O(N)
  work.
- **Memory:** ~300 row entries + 100 card entries = ~3KB. Negligible.

---

## 3. Generation-Cached Task Hierarchy

### Problem Analysis

**File:** `lua/andrew/vault/task_hierarchy.lua` (lines 261-280)

`M.show()` iterates ALL vault files and calls `build_tree()` for each file
with tasks, every time the hierarchy view is opened:

```lua
for rel_path, entry in pairs(idx.files) do
  if entry.tasks and #entry.tasks > 1 then
    local roots = M.build_tree(entry.tasks)
    -- ...
  end
end
```

Additionally, `file_entry_for()` (used in keymap handlers) performs a linear
search over the file_entries array:

```lua
local function file_entry_for(file)
  for _, fe in ipairs(file_entries) do
    if fe.abs_path == file then return fe end
  end
end
```

### Proposed Solution

Cache the file entries by vault index generation, and build a lookup table
for `file_entry_for()`.

### Code Changes

```lua
local _hierarchy_cache = { gen = 0, entries = nil }
local _file_entry_lookup = {}  -- abs_path -> file_entry

local function collect_file_entries_cached()
  local idx = vault_index.current()
  if not idx then return {} end

  local gen = idx._generation or 0
  if _hierarchy_cache.gen == gen and _hierarchy_cache.entries then
    return _hierarchy_cache.entries
  end

  local entries = {}
  -- ... existing collection logic ...

  -- Build lookup table
  _file_entry_lookup = {}
  for _, fe in ipairs(entries) do
    _file_entry_lookup[fe.abs_path] = fe
  end

  _hierarchy_cache = { gen = gen, entries = entries }
  return entries
end

local function file_entry_for(file)
  return _file_entry_lookup[file]
end
```

### Expected Performance Improvement

- **Before:** O(N) file scan per tree open; O(entries) per keymap action
- **After:** O(1) cache hit on repeated opens; O(1) lookup per keymap

---

## 4. Generation-Cached Overdue Task Detection

### Problem Analysis

**File:** `lua/andrew/vault/task_notify.lua` (lines 32-81)

`find_overdue()` iterates ALL vault files every 300 seconds (configurable),
even if the vault index hasn't changed since the last check:

```lua
for rel_path, entry in pairs(idx.files) do
  if not entry.tasks then goto continue_file end
  for _, task in ipairs(entry.tasks) do
    if not task.due or task.due == "" then goto continue_task end
    -- ... check overdue ...
  end
end
```

### Proposed Solution

Cache overdue task list by vault index generation. Only re-scan when the
index has changed.

### Code Changes

```lua
local _overdue_cache = { gen = 0, tasks = nil }

local function find_overdue()
  local idx = vault_index.current()
  if not idx then return {} end

  local gen = idx._generation or 0
  if _overdue_cache.gen == gen and _overdue_cache.tasks then
    return _overdue_cache.tasks
  end

  -- ... existing scan logic ...

  _overdue_cache = { gen = gen, tasks = overdue }
  return overdue
end
```

### Expected Performance Improvement

For a 2000-file vault with 5-minute check interval and index changes
every 30 seconds:

- **Before:** 10 full scans per 5 minutes
- **After:** ~10 cache hits, 1-2 actual scans per 5 minutes (only when
  generation changes)

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Kanban generation cache (#1) | Medium | High | Low |
| 2 | Spatial card index (#2) | Medium | Medium | Low |
| 3 | Hierarchy generation cache (#3) | Low | Medium | Low |
| 4 | Overdue generation cache (#4) | Low | Medium | Low |

---

## Testing Strategy

### Kanban Cache (#1)
1. Open kanban. Toggle filter 3 times without edits. Verify no re-scan
   (log cache hit).
2. Edit a task file. Verify next kanban refresh shows updated data.

### Spatial Index (#2)
1. Open kanban with 50+ cards. Navigate h/j/k/l rapidly. Verify smooth
   cursor movement.
2. Verify card selection highlights correctly at all positions.

### Hierarchy Cache (#3)
1. Open `:VaultTaskTree` twice. Verify second open is instant.
2. Edit a task. Reopen tree. Verify updated hierarchy.

### Overdue Cache (#4)
1. Wait for notification cycle. Verify correct overdue count.
2. Complete a task. Wait for next cycle. Verify updated list.

---

## Related Documents

Standalone — no overlapping optimizations in other documents.
