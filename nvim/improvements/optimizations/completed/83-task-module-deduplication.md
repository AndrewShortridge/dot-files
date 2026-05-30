# 83 --- Task Module Deduplication & Shared Utilities

> This document is a self-contained implementation guide. Each refactoring
> below is unique to this document.

Consolidate duplicated patterns across the four task UI modules into shared
utilities, reducing maintenance burden and ensuring consistent behavior.

> **Modules affected:** `task_kanban.lua`, `task_hierarchy.lua`,
> `task_notify.lua`, `task_timeline.lua`
> **New modules:** `task_utils.lua`

---

## 1. Shared Task Iteration Helper

### Problem Analysis

**Files:**
- `task_kanban.lua` (lines 57-68) — `collect_all_items()`
- `task_hierarchy.lua` (lines 285-302) — `collect_file_entries_cached()`
- `task_notify.lua` (lines 51-80) — `find_overdue()`
- `task_timeline.lua` (lines 56-93) — `collect_timeline_tasks()`

All four modules contain a near-identical double-nested loop:

```lua
for rel_path, entry in pairs(idx.files or {}) do
  if entry.tasks then
    for _, task in ipairs(entry.tasks) do
      -- module-specific processing
    end
  end
end
```

Each module independently guards against nil `idx`, nil `idx.files`, and
nil `entry.tasks`. The outer structure is identical; only the inner
processing differs.

**Differences between modules:**

| Module | Inner Logic | Output Shape |
|--------|------------|--------------|
| kanban | No filtering; wraps task with path metadata | Flat array of `{task, rel_path, abs_path}` |
| hierarchy | `#tasks > 1` guard; `build_tree()`; hierarchy check | Filtered array of `{rel_path, abs_path, roots}` |
| notify | Status/due filter; `days_between()`; overdue check | Flat array of overdue items |
| timeline | Status filter (configurable); `passes_filter()`; date bucketing | `{dated = {}, undated = {}}` |

### Proposed Solution

Add `iterate_tasks(callback)` to a new `task_utils.lua` module. The
callback receives `(task, rel_path, entry)` for each task in the vault
index. Each consumer calls the iterator with its own filter/transform
logic.

### Code Changes

**New file: `lua/andrew/vault/task_utils.lua`**

```lua
local vault_index = require("andrew.vault.vault_index")

local M = {}

--- Iterate all tasks in the vault index.
--- @param callback fun(task: table, rel_path: string, entry: table): boolean?
---   Return false to stop iteration (optional).
function M.iterate_tasks(callback)
  local idx = vault_index.current()
  if not idx or not idx.files then return end

  for rel_path, entry in pairs(idx.files) do
    if entry.tasks then
      for _, task in ipairs(entry.tasks) do
        if callback(task, rel_path, entry) == false then
          return
        end
      end
    end
  end
end

--- Collect tasks matching a predicate into a flat array.
--- @param predicate fun(task: table, rel_path: string, entry: table): table|nil
---   Return an item table to include it, or nil to skip.
--- @return table[] items
function M.collect_tasks(predicate)
  local items = {}
  M.iterate_tasks(function(task, rel_path, entry)
    local item = predicate(task, rel_path, entry)
    if item then
      items[#items + 1] = item
    end
  end)
  return items
end

return M
```

**Consumer migration example — `task_kanban.lua`:**

```lua
local task_utils = require("andrew.vault.task_utils")

local function collect_all_items()
  local idx = vault_index.current()
  if not idx then return {} end
  local gen = idx._generation or 0
  if _items_cache and _items_gen == gen then return _items_cache end

  local items = task_utils.collect_tasks(function(task, rel_path, entry)
    return { task = task, rel_path = rel_path, abs_path = entry.abs_path }
  end)

  _items_cache = items
  _items_gen = gen
  return items
end
```

**Consumer migration example — `task_notify.lua`:**

```lua
local task_utils = require("andrew.vault.task_utils")

-- Inside find_overdue(), replace the double loop:
local tasks = task_utils.collect_tasks(function(task, rel_path, entry)
  if not task.due or task.due == "" then return nil end
  local mark = task.status or " "
  if mark == "x" or mark == "-" then return nil end
  local days = date_utils.days_between(task.due, today)
  if days <= 0 then return nil end
  return {
    rel_path = rel_path,
    abs_path = entry.abs_path or (idx.vault_path .. "/" .. rel_path),
    line = task.line or 1, text = task.text or "",
    due = task.due, mark = mark,
    priority = task.priority or 99, days_overdue = days,
  }
end)
```

### Expected Improvement

- Eliminates 4 copies of the double-nested loop (~15 lines each = ~60 lines)
- Single place to add future guards (e.g., entry validity checks)
- Each consumer reduces to a single `collect_tasks()` call + its transform

### Risk Assessment

- **Low:** Pure extraction; no behavioral change. Each consumer still owns
  its filtering and output shape.
- **Performance:** One extra function call per task. For 500 tasks this is
  negligible (~0.01ms).

---

## 2. Generation-Based Cache Factory

### Problem Analysis

**Files:**
- `task_kanban.lua` (lines 22-31, 51-54, 70-71, 85-90, 148-151)
- `task_hierarchy.lua` (lines 270, 279-282, 313)
- `task_timeline.lua` (lines 29-32, 47-52, 98-101)
- `task_notify.lua` (lines 18-24, 43-46, 91-93)
- `calendar.lua` (lines 68-72, 186-190)
- `connections.lua` (lines 38-40, 65-66)
- `completion_base.lua` (lines 44-46)

Seven modules independently implement the same generation-cache pattern:

```lua
local _cache = nil
local _gen = 0

local function get_cached()
  local gen = idx._generation or 0
  if _cache and _gen == gen then return _cache end
  -- ... rebuild ...
  _cache = result
  _gen = gen
  return result
end
```

Some modules extend this with composite keys (filter options, config
flags), but the core generation-equality check is identical everywhere.

### Proposed Solution

Add a `gen_cache(opts)` factory to `task_utils.lua` that returns
`get(extra_key?)` and `invalidate()` functions. Supports optional
composite key validation beyond generation.

### Code Changes

**In `lua/andrew/vault/task_utils.lua`:**

```lua
--- Create a generation-based cache.
--- @param build_fn fun(idx: table, ...): any  Builder called on cache miss.
--- @param opts? { key_fn: fun(...): string }  Optional composite key extractor.
--- @return { get: fun(...): any, invalidate: fun() }
function M.gen_cache(build_fn, opts)
  local cached_gen = 0
  local cached_key = nil
  local cached_value = nil
  local key_fn = opts and opts.key_fn

  return {
    get = function(...)
      local idx = vault_index.current()
      if not idx then return nil end

      local gen = idx._generation or 0
      local key = key_fn and key_fn(...) or nil

      if cached_value ~= nil and cached_gen == gen and (not key_fn or cached_key == key) then
        return cached_value
      end

      cached_value = build_fn(idx, ...)
      cached_gen = gen
      cached_key = key
      return cached_value
    end,

    invalidate = function()
      cached_value = nil
      cached_gen = 0
      cached_key = nil
    end,
  }
end
```

**Consumer migration example — `task_notify.lua`:**

```lua
local task_utils = require("andrew.vault.task_utils")

local overdue_cache = task_utils.gen_cache(function(idx)
  local today = engine.today()
  return task_utils.collect_tasks(function(task, rel_path, entry)
    -- ... existing overdue logic ...
  end)
end)

-- Usage:
local tasks = overdue_cache.get()

-- In M.invalidate():
overdue_cache.invalidate()

-- In engine.register_cache():
engine.register_cache("task_notify", { invalidate = overdue_cache.invalidate })
```

**Consumer migration example — `task_timeline.lua` (with composite key):**

```lua
local timeline_cache = task_utils.gen_cache(
  function(idx, filter_opts)
    -- ... existing collection logic ...
  end,
  { key_fn = function(filter_opts)
    return filter_cache_key(filter_opts) .. tostring(config.timeline.show_done)
  end }
)

-- Usage:
local result = timeline_cache.get(filter_opts)
```

### Expected Improvement

- Eliminates ~10-15 lines of boilerplate cache management per module
  (7 modules × ~12 lines = ~84 lines)
- Consistent cache behavior: all modules handle nil index, generation 0,
  and invalidation identically
- Single place to add cache diagnostics (hit/miss counters, timing)

### Risk Assessment

- **Low:** The factory is a thin wrapper. Each module still owns its
  build function.
- **Composite keys:** `key_fn` handles modules that cache by more than
  generation (kanban filters, timeline show_done).
- **Two-level caches:** `task_kanban.lua` uses two cache levels (raw items
  + filtered buckets). Each level becomes a separate `gen_cache` instance.

---

## 3. Shared Checkbox Display Function

### Problem Analysis

**Files:**
- `task_hierarchy.lua` (lines 164-170) — standalone `checkbox()` function
- `task_timeline.lua` (line 116) — inline `"[" .. task.status .. "]"`
- `task_notify.lua` (line 186) — inline `string.format("[%s]", mark)`
- `task_kanban.lua` — references status directly in render logic

`task_hierarchy.lua` has the only proper display function that maps
special statuses:

```lua
local function checkbox(status)
  if status == "x" or status == "X" then return "[x]" end
  if status == "/" then return "[/]" end
  if status == "-" then return "[-]" end
  if status == ">" then return "[>]" end
  return "[ ]"
end
```

Other modules do raw string interpolation, which would display `[nil]`
for tasks without a status field if not guarded elsewhere.

### Proposed Solution

Move `checkbox()` to `task_utils.lua` and use it in all task display
modules.

### Code Changes

**In `lua/andrew/vault/task_utils.lua`:**

```lua
--- Render a task status mark as a display checkbox string.
--- @param status string|nil  The status mark character.
--- @return string  e.g. "[x]", "[ ]", "[/]"
function M.checkbox(status)
  if status == "x" or status == "X" then return "[x]" end
  if status == "/" then return "[/]" end
  if status == "-" then return "[-]" end
  if status == ">" then return "[>]" end
  return "[ ]"
end
```

**Migration in `task_hierarchy.lua`:**

```lua
local task_utils = require("andrew.vault.task_utils")
-- Replace local checkbox() with:
local checkbox = task_utils.checkbox
```

**Migration in `task_timeline.lua` (line 116):**

```lua
-- Before:
parts[#parts + 1] = "    [" .. task.status .. "] "
-- After:
parts[#parts + 1] = "    " .. task_utils.checkbox(task.status) .. " "
```

**Migration in `task_notify.lua` (line 186):**

```lua
-- Before:
string.format("[%s] %s", mark_display, label)
-- After:
string.format("%s %s", task_utils.checkbox(mark_display), label)
```

### Expected Improvement

- Consistent checkbox rendering across all task UIs
- Nil-safe: `checkbox(nil)` returns `"[ ]"` instead of `"[nil]"`
- Single definition to update if new status marks are added

### Risk Assessment

- **Trivial:** Pure function extraction. No state, no side effects.

---

## 4. Normalize Task Item Field Names

### Problem Analysis

**Files:**
- `task_kanban.lua` (lines 111-123): uses `status`, `file` (= rel_path)
- `task_timeline.lua` (lines 66-75): uses `status`, `file` (= basename),
  `rel_path`
- `task_notify.lua` (lines 65-74): uses `mark` (= status), `rel_path`
- `task_hierarchy.lua`: uses `status` (from vault index directly)

Three inconsistencies:

1. **Status field name:** `status` in 3 modules, `mark` in task_notify
2. **File path field:** `file` means rel_path in kanban, basename in
   timeline; `rel_path` is separate in timeline and notify
3. **Default values:** Kanban uses `task.text or ""`, `task.tags or {}`;
   notify uses `task.line or 1`; timeline uses no defaults

### Proposed Solution

Define a canonical field name convention in `task_utils.lua` documentation
and migrate task_notify to use `status` instead of `mark`. Normalize
`file` to always mean `rel_path` (since `entry.basename` is available
from the entry).

### Code Changes

**Field name convention (documented in `task_utils.lua`):**

```lua
--- Canonical task item fields:
--- @field text string        Task description
--- @field status string      Status mark character (" ", "x", "/", "-", ">")
--- @field due string|nil     Due date (YYYY-MM-DD)
--- @field priority number|nil Priority level
--- @field line number        Source line number
--- @field rel_path string    Relative path from vault root
--- @field abs_path string    Absolute path to source file
--- @field tags string[]|nil  Tag list
--- @field scheduled string|nil  Scheduled date
--- @field completion string|nil Completion date
--- @field repeat_rule string|nil Recurrence rule
---
--- Module-specific derived fields (not shared):
--- @field days_overdue number   (task_notify only)
--- @field children table[]      (task_hierarchy only)
--- @field parent_line number    (task_hierarchy only)
```

**Migration in `task_notify.lua`:**

```lua
-- Lines 65-74: rename `mark` to `status` in item construction
tasks[#tasks + 1] = {
  rel_path = rel_path,
  abs_path = entry.abs_path or (idx.vault_path .. "/" .. rel_path),
  line = task.line or 1,
  text = task.text or "",
  due = task.due,
  status = mark,           -- was: mark = mark
  priority = priority,
  days_overdue = days,
}

-- Update all references to .mark → .status in:
-- - list_overdue() fzf entry formatting (line ~186)
-- - notification display (line ~135)
```

**Migration in `task_timeline.lua`:**

```lua
-- Lines 66-75: rename `file` to use rel_path consistently
local item = {
  text = task.text,
  priority = task.priority,
  status = task.status,
  rel_path = rel_path,        -- was: file = entry.basename
  abs_path = entry.abs_path,
  line = task.line,
  due = task.due,
}

-- Update render code to use entry.basename where display name is needed
```

**Migration in `task_kanban.lua`:**

```lua
-- Lines 111-123: rename `file` to `rel_path`
buckets[mark][#buckets[mark] + 1] = {
  text = task.text or "",
  status = mark,
  due = task.due,
  priority = task.priority,
  tags = task.tags or {},
  rel_path = item.rel_path,   -- was: file = item.rel_path
  abs_path = item.abs_path,
  line = task.line,
  scheduled = task.scheduled,
  completion = task.completion,
  repeat_rule = task.repeat_rule,
}

-- Update all references to .file → .rel_path in render/navigation code
```

### Expected Improvement

- Consistent field access patterns across all task modules
- Eliminates confusion between `mark`/`status` and `file`/`rel_path`
- Enables future shared display/sort utilities that can operate on any
  task item regardless of source module

### Risk Assessment

- **Medium:** Requires updating all downstream references to renamed
  fields within each module. Each module is self-contained, so no
  cross-module breakage.
- **Testing:** Each module's UI must be exercised after rename to verify
  no missed references.

---

## Implementation Order

| Priority | Refactoring | Effort | Impact | Risk |
|----------|------------|--------|--------|------|
| 1 | Task iteration helper (#1) | Low | High | Low |
| 2 | Generation cache factory (#2) | Medium | High | Low |
| 3 | Checkbox display (#3) | Trivial | Low | Trivial |
| 4 | Field name normalization (#4) | Medium | Medium | Medium |

**Recommended approach:** Implement #1 and #3 together (they both go into
`task_utils.lua`). Then #2 as a second pass. Then #4 as a final cleanup
once all modules import `task_utils`.

---

## Testing Strategy

### Task Iteration Helper (#1)
1. Open kanban board. Verify all tasks appear with correct paths.
2. Open hierarchy tree. Verify file entries match previous behavior.
3. Wait for overdue notification cycle. Verify correct overdue count.
4. Open timeline. Verify dated/undated bucketing unchanged.

### Generation Cache Factory (#2)
1. Open kanban. Toggle filters 3 times without edits. Add debug log to
   verify `gen_cache` returns cached value.
2. Edit a task file. Verify next UI refresh shows updated data.
3. Call `invalidate()` manually. Verify cache rebuilds on next access.

### Checkbox Display (#3)
1. Open hierarchy tree. Verify checkbox rendering unchanged.
2. Open timeline. Verify `[x]`, `[ ]`, `[/]` display correctly.
3. Open overdue list. Verify status display correct.

### Field Name Normalization (#4)
1. Open kanban. Navigate cards, toggle filters, verify all task data
   renders correctly (especially file paths in card labels).
2. Open timeline. Verify file names display correctly in entries.
3. Open overdue list. Verify status marks display correctly (was `mark`,
   now `status`).
4. Test all keymap actions that reference task items (open file, toggle
   status, etc.).

---

## Related Documents

- `70-task-ui-generation-caching-spatial-index.md` — Generation caching
  and spatial index optimizations (already implemented). This document
  addresses the remaining duplication patterns discovered during that
  implementation review.
