# 61 --- Calendar, Task, & UI Float Optimizations

> This document is a self-contained implementation guide. Each optimization below is unique to this document.

Targeted improvements for the calendar, task listing, preview, and timeline
systems, addressing redundant vault index scans, blocking filesystem I/O,
full re-renders on navigation, and wasteful float creation patterns.

---

## 1. Calendar Deadline Scanning Optimization — Status: DONE

### Problem Analysis

**File:** `lua/andrew/vault/calendar.lua` (lines 102-167)

`scan_dates_from_index()` iterates ALL vault files in a triple-nested loop:

```lua
for rel_path, entry in pairs(idx.files) do       -- O(N) files
  for _, indicator in ipairs(indicators) do        -- O(I) indicator types
    for _, source in ipairs(indicator.sources) do  -- O(S) sources per indicator
      -- Extract date from frontmatter/inline/task fields
    end
  end
end
```

With 4 indicators and 2 sources each, this is O(N * 8) iterations. For a
1000-file vault, that's 8000 entry accesses per calendar render.

**Additional inefficiencies:**
- **Title extraction repeated** (lines 112-114): `entry.basename` and
  `entry.frontmatter.title` checked inside the inner loop, but only depend
  on the file (outer loop).
- **Log directory scan** (line 249): `vim.fn.readdir(log_dir)` is synchronous
  filesystem I/O, called on every calendar open and month navigation.
- **Days-in-month calculation** (lines 20-38): Uses `os.time()` syscall
  when a lookup table would suffice.

### Proposed Solution

**Optimization 1: Hoist file-level work outside indicator loops.**

```lua
for rel_path, entry in pairs(idx.files) do
  -- Compute display name ONCE per file
  local display = entry.frontmatter and entry.frontmatter.title
    and tostring(entry.frontmatter.title)
    or entry.basename
    or link_utils.rel_to_stem(rel_path)

  for _, indicator in ipairs(indicators) do
    for _, source in ipairs(indicator.sources) do
      -- Use pre-computed display
    end
  end
end
```

**Optimization 2: Cache log directory listing.**

```lua
local _log_cache = {}  -- "YYYY-MM" -> { entries }
local _log_cache_gen = 0

local function scan_logs_cached(log_dir, year, month)
  local key = string.format("%04d-%02d", year, month)

  -- Invalidate on index generation change
  local idx = vault_index.current()
  local gen = idx and idx._generation or 0
  if gen ~= _log_cache_gen then
    _log_cache = {}
    _log_cache_gen = gen
  end

  if _log_cache[key] then return _log_cache[key] end

  -- Use vim.uv.fs_scandir() (non-blocking) instead of vim.fn.readdir()
  local result = {}
  local handle = vim.uv.fs_scandir(log_dir)
  if handle then
    local prefix = key
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if ftype == "file" and name:sub(1, 7) == prefix
        and name:match("^%d%d%d%d%-%d%d%-%d%d%.md$") then
        result[name:sub(1, 10)] = true
      end
    end
  end

  _log_cache[key] = result
  return result
end
```

**Optimization 3: Lookup table for days-in-month.**

```lua
local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function is_leap_year(year)
  return (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
end

local function days_in_month(year, month)
  if month == 2 and is_leap_year(year) then return 29 end
  return DAYS_IN_MONTH[month]
end
```

### Expected Performance Improvement

- **Title extraction:** Saves 7 redundant accesses per file (moved outside
  inner loops). For 1000 files: 7000 fewer property lookups.
- **Log caching:** Eliminates filesystem I/O on month navigation after
  initial scan. Navigation between cached months is instantaneous.
- **Days-in-month:** Eliminates `os.time()` syscall. Negligible absolute
  savings but cleaner code.

### Risk Assessment

- **Log cache staleness:** Invalidated on index generation change, which
  covers file creation/deletion. Log files created outside Neovim may
  not appear until the next generation bump (acceptable — FocusGained
  triggers generation change).
- **Leap year correctness:** Standard algorithm, well-tested.

---

## 2. Task Listing with Index-Based Caching — Status: DONE

### Problem Analysis

**Files:**
- `lua/andrew/vault/tasks.lua` (lines 149-161)
- `lua/andrew/vault/task_timeline.lua` (lines 28-79)

Both modules iterate ALL vault files and ALL tasks on every invocation:

```lua
-- tasks.lua:
for rel_path, entry in pairs(idx.files) do
  if entry.tasks then
    for _, task in ipairs(entry.tasks) do
      if not filter or filter(task) then
        entries[#entries + 1] = entry.abs_path .. ":" .. task.line .. ":1:- ["
          .. task.status .. "] " .. task.text
      end
    end
  end
end
```

**Sub-problems:**
- String concatenation with `..` in inner loop (line 155): Creates temporary
  strings for every task.
- No caching: The same task list is rebuilt on every `:VaultTasks` invocation
  and every timeline scroll.
- Timeline re-collects ALL tasks on every single-day scroll (lines 320-328).

### Proposed Solution

**Optimization 1: Use `string.format()` for task display lines.**

```lua
-- Before:
entries[#entries + 1] = entry.abs_path .. ":" .. task.line .. ":1:- ["
  .. task.status .. "] " .. task.text

-- After:
entries[#entries + 1] = string.format("%s:%d:1:- [%s] %s",
  entry.abs_path, task.line, task.status, task.text)
```

**Optimization 2: Cache task collection by index generation.**

```lua
local _task_cache = { gen = 0, all_tasks = nil }

local function get_all_tasks()
  local idx = vault_index.current()
  if not idx then return {} end

  local gen = idx._generation or 0
  if _task_cache.gen == gen and _task_cache.all_tasks then
    return _task_cache.all_tasks
  end

  local all_tasks = {}
  for rel_path, entry in pairs(idx.files) do
    if entry.tasks then
      for _, task in ipairs(entry.tasks) do
        all_tasks[#all_tasks + 1] = {
          task = task,
          rel_path = rel_path,
          abs_path = idx:abs_path(entry) or entry.abs_path,
        }
      end
    end
  end

  _task_cache = { gen = gen, all_tasks = all_tasks }
  return all_tasks
end
```

Then both `tasks.lua` and `task_timeline.lua` filter from the cached list:

```lua
-- tasks.lua:
local all = get_all_tasks()
local entries = {}
for _, item in ipairs(all) do
  if not filter or filter(item.task) then
    entries[#entries + 1] = string.format("%s:%d:1:- [%s] %s",
      item.abs_path, item.task.line, item.task.status, item.task.text)
  end
end
```

**Optimization 3: Timeline viewport caching.**

Instead of rebuilding everything on scroll, cache the collected and sorted
task items, and only re-slice the viewport:

```lua
-- In task_timeline.lua:
local _timeline_data = nil  -- Cached: sorted tasks with dates

function M.scroll(direction)
  if not _timeline_data then
    _timeline_data = collect_and_sort_tasks()
  end

  -- Shift viewport window
  active.start_date = active.start_date + direction
  active.end_date = active.end_date + direction

  -- Re-render from cached data (no vault scan)
  render_from_cache(_timeline_data, active.start_date, active.end_date)
end
```

### Expected Performance Improvement

- **string.format:** ~20-30% faster than multiple `..` concatenations for
  4+ segments (Lua optimization).
- **Task caching:** Eliminates full vault scan on repeated invocations.
  For 1000 files with 500 tasks: saves ~1000 table iterations + 500 task
  iterations per invocation.
- **Timeline viewport:** Scroll operations go from O(N_tasks) to O(visible)
  — typically 20-30 tasks instead of 500+.

---

## 3. Preview Float Reuse — Status: DONE (treesitter dedup, keymap dedup, markdown render optimization; breadcrumb cache skipped — only called on content change)

### Problem Analysis

**File:** `lua/andrew/vault/preview.lua` (lines 347-374)

Every `K` press creates a new buffer and window:

```lua
state.buf = vim.api.nvim_create_buf(false, true)
state.win = vim.api.nvim_open_win(state.buf, false, win_opts)
-- Set up treesitter, render-markdown plugin
vim.bo[state.buf].filetype = "markdown"
pcall(vim.treesitter.start, state.buf, "markdown")
require("render-markdown").render({ buf = state.buf, win = state.win })
```

Additionally, `setup_markdown_rendering()` is called on every content update
(line 142) even though treesitter only needs to be started once per buffer.

Keymaps are re-registered on every `focus_preview()` (lines 224-256).

### Proposed Solution

**Optimization 1: Reuse preview buffer.**

```lua
function M.preview()
  -- ... target resolution ...

  if is_active() and vim.api.nvim_buf_is_valid(state.buf) then
    -- Reuse existing float: just update content
    replace_float_content(target)
    return
  end

  -- Create new float only if none exists
  state.buf = vim.api.nvim_create_buf(false, true)
  state.win = vim.api.nvim_open_win(state.buf, false, win_opts)
  state._treesitter_started = false
  state._keymaps_set = false
end
```

**Optimization 2: Track initialization state.**

```lua
local function setup_markdown_rendering()
  if state._treesitter_started then return end
  vim.bo[state.buf].filetype = "markdown"
  pcall(vim.treesitter.start, state.buf, "markdown")
  state._treesitter_started = true
end

local function setup_keymaps_once()
  if state._keymaps_set then return end
  -- ... keymap setup ...
  state._keymaps_set = true
end
```

**Optimization 3: Cache breadcrumb when target hasn't changed.**

```lua
function update_float_title(target)
  if state._last_target == target then return end
  state._last_target = target
  -- ... existing breadcrumb logic ...
end
```

### Expected Performance Improvement

- **Buffer reuse:** Saves buffer creation + treesitter init + render-markdown
  plugin call on repeated preview toggles. Estimated 5-10ms per toggle.
- **Keymap dedup:** Saves 8+ `nvim_buf_set_keymap` calls per focus.
- **Breadcrumb cache:** Saves `strdisplaywidth()` + string formatting when
  viewing the same target repeatedly.

---

## 4. Calendar Incremental Re-render — Status: DONE

### Problem Analysis

**File:** `lua/andrew/vault/calendar.lua` (lines 501-535)

Every month navigation triggers a full re-render:

```lua
function redraw()
  local lines, hl_data = render_calendar(state.year, state.month, ...)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, hl in ipairs(hl_data) do
    vim.api.nvim_buf_add_highlight(state.buf, ns, hl.group, hl.row, hl.col_start, hl.col_end)
  end
end
```

This clears ALL buffer lines and ALL highlights, then recreates everything.
For a month with 30 days and 50+ highlights, that's 50+ API calls per
navigation.

### Proposed Solution

Since the calendar layout is fixed-size (7 rows + header), update only the
cells that change between months.

```lua
function redraw_incremental()
  local new_lines, new_hl = render_calendar(state.year, state.month, ...)

  -- Only update lines that actually changed
  for i, new_line in ipairs(new_lines) do
    if new_line ~= state._prev_lines[i] then
      vim.api.nvim_buf_set_lines(state.buf, i - 1, i, false, { new_line })
    end
  end

  -- Re-apply highlights (must clear first since line content may have changed)
  -- But only clear/re-apply rows that changed
  for i, new_line in ipairs(new_lines) do
    if new_line ~= state._prev_lines[i] then
      vim.api.nvim_buf_clear_namespace(state.buf, ns, i - 1, i)
      for _, hl in ipairs(new_hl) do
        if hl.row == i - 1 then
          vim.api.nvim_buf_add_highlight(state.buf, ns, hl.group, hl.row, hl.col_start, hl.col_end)
        end
      end
    end
  end

  state._prev_lines = new_lines
end
```

### Expected Performance Improvement

When navigating between months, typically only 3-5 of 9 lines change
(day numbers, not header/weekday labels).

- **Before:** 9 line updates + 50+ highlight clears + 50+ highlight adds
- **After:** 3-5 line updates + 15-25 highlight ops
- **Reduction:** ~50-60% fewer API calls per navigation

### Risk Assessment

- **First render:** No previous state, falls back to full render.
- **Resize handling:** Window resize may change line content without
  month change. The line comparison handles this correctly.

---

## 5. Timeline Scroll Viewport Optimization — Status: DONE (already uses gen_cache for task collection caching)

### Problem Analysis

**File:** `lua/andrew/vault/task_timeline.lua` (lines 279-293)

Every scroll triggers:
1. Full task collection from vault index
2. Complete render of all visible days
3. Full buffer replacement
4. All highlights recomputed

For a timeline showing 14 days with 50 tasks, scrolling one day forward
re-processes all 50 tasks and re-renders all 14 days.

### Proposed Solution

Cache the task collection and implement sliding window rendering:

```lua
-- Cache task data per generation
local _cached_tasks = { gen = 0, items = nil }

function collect_tasks_cached()
  local idx = vault_index.current()
  local gen = idx and idx._generation or 0
  if _cached_tasks.gen == gen and _cached_tasks.items then
    return _cached_tasks.items
  end
  -- ... collect and sort tasks ...
  _cached_tasks = { gen = gen, items = sorted_tasks }
  return sorted_tasks
end

-- On scroll: reuse cached tasks, only re-render
function M.scroll(direction)
  local tasks = collect_tasks_cached()
  -- Shift date window
  -- Re-render only the new day entering the viewport
  -- Shift buffer lines by 1 (delete first/last, insert new)
end
```

### Expected Performance Improvement

- **Before:** Full vault scan + full render per scroll = O(N_files + N_tasks)
- **After:** Cache hit + 1 day render per scroll = O(tasks_in_one_day)
- For typical timelines: ~95% reduction in scroll processing time

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Task String Formatting (#2, part 1) | Low | Low | Low |
| 2 | Log Directory Caching (#1, part 2) | Low | Medium | Low |
| 3 | Task Collection Caching (#2, part 2) | Low | High | Low |
| 4 | Preview Float Reuse (#3) | Medium | Medium | Low |
| 5 | Calendar Incremental Render (#4) | Medium | Low-Medium | Low |
| 6 | Timeline Viewport Caching (#5) | Medium | High | Medium |
| 7 | Calendar Scan Hoisting (#1, part 1) | Low | Medium | Low |

---

## Testing Strategy

### Calendar (#1)
1. Navigate months rapidly. Verify no visual glitches.
2. Create a new log file. Verify it appears after cache invalidation.
3. Verify February 29th appears correctly in leap years.

### Task Caching (#2)
1. Run `:VaultTasks` twice without edits. Verify second call is faster
   (log timing).
2. Edit a task file. Verify next `:VaultTasks` shows updated task.
3. Compare task list output before/after for identity.

### Preview Reuse (#3)
1. Press `K` on a link, then `K` again. Verify float updates without
   flicker (buffer reuse).
2. Navigate to different note in preview. Verify content updates.
3. Close preview, reopen. Verify new buffer is created.

### Timeline Viewport (#5)
1. Open timeline. Scroll left/right. Verify smooth updates.
2. Edit a task. Verify timeline reflects change on next generation bump.

---

## Related Documents

- Doc 78-highlight-navigation-outline-dedup former #4 (preview rendering setup dedup) has been consolidated into #3 here as the canonical source for all preview.lua optimization.
