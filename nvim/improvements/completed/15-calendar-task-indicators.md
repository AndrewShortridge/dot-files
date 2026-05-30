# Calendar with Event/Task Indicators via Vault Index

## Problem

The calendar module (`lua/andrew/vault/calendar.lua`) already scans for tasks
with `due::` dates via a standalone ripgrep scan (`scan_deadlines()`, line 74).
This approach has three issues:

1. **Redundant scanning.** The vault index (`vault_index.lua`) already extracts
   tasks and inline fields (including `due::` fields) during its single-pass
   parse. The calendar module duplicates this work by launching a separate
   `rg` process every time the cache expires.

2. **Inconsistent data source.** The ripgrep scan uses raw regex matching against
   file content, while the vault index uses a structured parser that strips code
   blocks, handles frontmatter YAML arrays, and normalizes inline field syntax.
   Edge cases (e.g., a `due::` inside a fenced code block) are handled correctly
   by the index but not by the ripgrep scan.

3. **No event indicators.** The calendar shows due-date deadlines but does not
   show other date-bearing metadata that would be useful on a calendar view:
   - `scheduled::` dates (when a task is planned to start)
   - `created` frontmatter dates (when notes were created)
   - Frontmatter `due:` fields (YAML-style, distinct from inline `due::`)
   - Custom date fields that users may define

4. **Cache TTL mismatch.** The calendar uses `os.clock()` with a 60-second TTL
   (line 65), which measures CPU time, not wall-clock time. `os.clock()` only
   advances when the process is active, so the cache may appear "fresh" even
   after the user has been idle for minutes. The vault index uses generation-
   based change detection which is more reliable.

## Current Architecture

### Calendar Module (`calendar.lua`)

**Deadline scanning** (lines 54-162):

- `scan_deadlines()` (line 74): Launches `rg` with four `-e` patterns to find
  `[due:: DATE]`, `(due:: DATE)`, `^due: DATE`, and `due:: DATE` in all `.md`
  files. Returns `table<string, table[]>` mapping `"YYYY-MM-DD"` to lists of
  `{ text, file, abs_file, line }`.

- `get_deadlines()` (line 145): Module-level TTL cache around `scan_deadlines()`.
  Uses `os.clock()` with 60-second TTL. Returns cached results if fresh.

- `deadlines_for_month()` (line 174): Filters the full deadline map to a single
  month, returning `table<number, boolean>` (day -> has_deadline).

- `_deadline_cache` (line 64): Module-level variable storing `{ vault_path,
  built_at, deadlines }`.

**Rendering** (lines 230-393):

- `render_calendar()` (line 230): Builds calendar lines with highlights. For
  each day, checks `has_log[day]` and `has_deadline[day]` to determine the
  highlight group. Currently uses four mutually exclusive states:
  - `VaultCalendarToday` (green bg) -- always wins
  - `VaultCalendarLogDeadline` (orange bg) -- log + deadline
  - `VaultCalendarDeadline` (cyan/teal) -- deadline only
  - `VaultCalendarHasLog` (yellow) -- log only
  - `VaultCalendarWeekend` (pink) -- weekend, no other indicator

**Interaction** (lines 577-630):

- `open_day()` (line 577): On `<CR>`, checks if the day has deadlines. If so,
  offers a choice between opening the daily log and showing a deadline picker
  (`show_deadline_tasks()`). The picker uses fzf-lua with file:line navigation.

- `show_deadline_tasks()` (line 531): Opens fzf-lua with the task list for a
  specific date, supporting `<CR>` (edit), `ctrl-s` (split), `ctrl-v` (vsplit).

**Setup** (lines 683-701):

- `M.setup()` (line 683): Registers the cache with `engine.register_cache()` for
  unified cache management. Provides `invalidate` and `stats` callbacks.

### Vault Index Entry Structure (`vault_index.lua`, line 545)

Each indexed file produces a `VaultIndexEntry` with these relevant fields:

```lua
{
  rel_path = "Log/2026-02-27.md",
  abs_path = "/path/to/vault/Log/2026-02-27.md",
  basename = "2026-02-27",
  folder = "Log",
  day = "2026-02-27",           -- extracted from basename if YYYY-MM-DD pattern
  frontmatter = {
    due = "2026-03-15",         -- YAML frontmatter field
    created = "2026-02-27T10:30:00",
    -- ...
  },
  tasks = {
    {
      text = "Review PR #42 [due:: 2026-03-01]",
      status = " ",             -- checkbox character
      completed = false,
      line = 15,
      tags = { "project/vault" },
    },
    -- ...
  },
  inline_fields = {
    due = "2026-03-01",         -- last-wins for duplicate keys
    scheduled = "2026-02-28",
    -- ...
  },
  tags = { "project/vault", "status/in-progress" },
  -- ...
}
```

**Task extraction** (`extract_tasks()`, line 448): Extracts checkbox tasks from
the body text, skipping fenced code blocks. Each task includes `text`, `status`,
`completed`, `line`, and `tags`.

**Inline field extraction** (`extract_inline_fields()`, line 487): Extracts
`key:: value` patterns from body text (standalone, bracketed `[key:: val]`, and
parenthesized `(key:: val)`). Skips task lines to avoid double-extraction. Last
value wins for duplicate keys.

**Frontmatter parsing** (`parse_frontmatter()`, line 253): Parses YAML-like
frontmatter into a flat table. Handles scalar values, lists (both indented and
inline `[]` syntax), quoted strings, booleans, and numbers.

### Date Utilities (`date_utils.lua`)

- `parse_iso_datetime(s)` (line 31): Parses `"YYYY-MM-DDTHH:MM:SS"` and
  `"YYYY-MM-DD"` into Unix timestamps.
- `resolve_date(value)` (line 71): Resolves keywords (`"today"`, `"yesterday"`,
  relative `"7d"`) and absolute dates to timestamps.
- `resolve_date_string(value)` (line 221): Convenience wrapper returning
  `"YYYY-MM-DD"` string.

### Color System (`colors.lua`)

Calendar highlight groups are defined in `build_hl_groups()` (line 233) using
palette colors. All three palettes (OneDark, Soft Paper Light, Soft Paper Dark)
define calendar-specific colors:

| Palette Key | Current Usage |
|---|---|
| `calendar_header` | Month/year title, weekday headers |
| `calendar_today_fg/bg` | Today cell (green background) |
| `calendar_has_log` | Days with daily log files |
| `calendar_deadline` | Days with task deadlines |
| `calendar_log_dead_fg/bg` | Days with both log and deadline |
| `calendar_weekend` | Weekend days (no other indicator) |
| `calendar_dim` | Footer navigation hints |
| `calendar_legend` | Legend label text |

## Proposed Changes

### Overview

Replace the standalone ripgrep-based deadline scan with vault index queries.
Add support for multiple date field types (due, scheduled, created) as distinct
indicator categories. Each day cell can show a compact indicator line below the
day number using virtual text or character-based markers.

### Data Model

Replace the flat `has_deadline[day] = true` map with a richer per-day metadata
structure:

```lua
---@class CalendarDayInfo
---@field has_log boolean        -- daily log file exists
---@field due_count number       -- tasks/notes with due date on this day
---@field scheduled_count number -- tasks/notes with scheduled date on this day
---@field created_count number   -- notes created on this day
---@field items table[]          -- list of { text, file, abs_file, line, kind }
```

The `kind` field distinguishes `"due"`, `"scheduled"`, and `"created"` for the
detail picker.

### Configuration

Add a new `M.calendar` section to `config.lua`:

```lua
M.calendar = {
  -- Which date fields to scan from the vault index.
  -- Each entry maps a display label to the field extraction spec.
  -- "frontmatter.due" means entry.frontmatter.due
  -- "inline.due" means entry.inline_fields.due
  -- "task.due" means due:: dates found inside task text
  indicators = {
    {
      key = "due",
      label = "due",
      sources = { "frontmatter.due", "inline.due", "task.due" },
      highlight = "VaultCalendarDeadline",
    },
    {
      key = "scheduled",
      label = "sched",
      sources = { "frontmatter.scheduled", "inline.scheduled" },
      highlight = "VaultCalendarScheduled",
    },
  },

  -- Show creation dates as indicators (can generate visual noise).
  show_created = false,

  -- Use vault index instead of ripgrep for deadline scanning.
  -- When false, falls back to the current rg-based scan (for compatibility).
  use_vault_index = true,
}
```

## Implementation Steps

### Step 1: Add Config Section

**File**: `lua/andrew/vault/config.lua`

Add after the existing `M.carry_forward` section (around line 416):

```lua
-- ---------------------------------------------------------------------------
-- Calendar
-- ---------------------------------------------------------------------------
M.calendar = {
  -- Date fields to extract from vault index entries for calendar indicators.
  -- Each source is checked in order. "frontmatter.X" reads entry.frontmatter[X],
  -- "inline.X" reads entry.inline_fields[X], "task.X" extracts X:: from task text.
  indicators = {
    {
      key = "due",
      label = "due",
      sources = { "frontmatter.due", "inline.due", "task.due" },
    },
    {
      key = "scheduled",
      label = "sched",
      sources = { "frontmatter.scheduled", "inline.scheduled" },
    },
  },

  -- Whether to show note creation dates as calendar indicators.
  show_created = false,

  -- Use vault index for date scanning (true) or ripgrep fallback (false).
  use_vault_index = true,
}
```

### Step 2: Add New Highlight Groups and Palette Colors

**File**: `lua/andrew/vault/colors.lua`

Add to all three palette definitions (OneDark, Soft Paper Light, Soft Paper Dark):

```lua
-- In onedark (around line 70, after calendar_legend):
calendar_scheduled   = "#c678dd",  -- purple for scheduled dates

-- In soft_paper_light (around line 132):
calendar_scheduled   = "#9A85AE",  -- c.lavender

-- In soft_paper_dark (around line 190):
calendar_scheduled   = "#BB93D6",  -- c.lavender
```

Add the highlight group definition in `build_hl_groups()` (after
`VaultCalendarLogDeadline`, around line 283):

```lua
VaultCalendarScheduled     = { bold = true, fg = p.calendar_scheduled },
```

### Step 3: Add Vault Index Query Function

**File**: `lua/andrew/vault/calendar.lua`

Add a new function that queries the vault index instead of using ripgrep. This
replaces `scan_deadlines()` while producing the same output format for backward
compatibility with `deadlines_for_month()` and `show_deadline_tasks()`.

```lua
--- Extract a YYYY-MM-DD date string from a value that may be a date or datetime.
---@param value any
---@return string|nil "YYYY-MM-DD" or nil
local function extract_date_string(value)
  if type(value) ~= "string" then return nil end
  local date = value:match("^(%d%d%d%d%-%d%d%-%d%d)")
  return date
end

--- Extract due dates from a task's text content.
--- Handles: [due:: 2026-03-01], (due:: 2026-03-01), due:: 2026-03-01
---@param text string the task text
---@param field_name string the field to look for (e.g., "due")
---@return string|nil date_str
local function extract_date_from_task_text(text, field_name)
  -- [field:: YYYY-MM-DD] or (field:: YYYY-MM-DD) or field:: YYYY-MM-DD
  local pattern = field_name .. "::?%s*(%d%d%d%d%-%d%d%-%d%d)"
  return text:match(pattern)
end

--- Scan the vault index for all date-bearing items, grouped by date string.
--- Returns the same format as scan_deadlines() for backward compatibility:
---   "YYYY-MM-DD" -> { {text, file, abs_file, line, kind}, ... }
---@return table<string, table[]>
local function scan_dates_from_index()
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    return {}
  end

  local cal_config = config.calendar or {}
  local indicators = cal_config.indicators or {
    { key = "due", sources = { "frontmatter.due", "inline.due", "task.due" } },
  }

  local dates = {}

  local function add_date(date_str, item)
    if not date_str then return end
    if not dates[date_str] then
      dates[date_str] = {}
    end
    dates[date_str][#dates[date_str] + 1] = item
  end

  for rel_path, entry in pairs(idx.files) do
    for _, indicator in ipairs(indicators) do
      for _, source in ipairs(indicator.sources) do
        local scope, field = source:match("^(%w+)%.(.+)$")
        if not scope then goto continue_source end

        if scope == "frontmatter" then
          local val = entry.frontmatter and entry.frontmatter[field]
          local date_str = extract_date_string(val)
          if date_str then
            -- Build display text from the note basename
            local display = entry.basename
            if entry.frontmatter.title then
              display = tostring(entry.frontmatter.title)
            end
            add_date(date_str, {
              text = display .. " (" .. indicator.key .. ")",
              file = rel_path,
              abs_file = entry.abs_path,
              line = 1,
              kind = indicator.key,
            })
          end

        elseif scope == "inline" then
          local val = entry.inline_fields and entry.inline_fields[field]
          local date_str = extract_date_string(val)
          if date_str then
            add_date(date_str, {
              text = entry.basename .. " [" .. field .. ":: " .. date_str .. "]",
              file = rel_path,
              abs_file = entry.abs_path,
              line = 1,  -- inline field line not tracked; default to 1
              kind = indicator.key,
            })
          end

        elseif scope == "task" then
          if entry.tasks then
            for _, task in ipairs(entry.tasks) do
              local date_str = extract_date_from_task_text(task.text, field)
              if date_str then
                -- Clean up task text for display
                local task_text = task.text
                -- Remove inline field markup
                task_text = task_text:gsub("%[" .. field .. "::[^%]]*%]", "")
                task_text = task_text:gsub("%(" .. field .. "::[^%)]*%)", "")
                task_text = task_text:gsub(field .. "::%s*%d%d%d%d%-%d%d%-%d%d", "")
                task_text = vim.trim(task_text)
                if task_text == "" then
                  task_text = entry.basename
                end

                add_date(date_str, {
                  text = task_text,
                  file = rel_path,
                  abs_file = entry.abs_path,
                  line = task.line,
                  kind = indicator.key,
                })
              end
            end
          end
        end

        ::continue_source::
      end
    end
  end

  return dates
end
```

### Step 4: Update `get_deadlines()` to Use Vault Index

**File**: `lua/andrew/vault/calendar.lua`

Modify `get_deadlines()` to dispatch between vault-index-based and ripgrep-based
scanning based on the config flag. The vault index path uses generation-based
cache invalidation instead of TTL:

```lua
-- Module-level generation tracker for vault-index-based scanning.
local _index_generation = -1

--- Get cached deadline/date data, re-scanning if stale.
--- When config.calendar.use_vault_index is true, reads from the vault index
--- using generation-based invalidation. Otherwise falls back to ripgrep scan.
---@return table<string, table[]>
local function get_deadlines()
  local cal_config = config.calendar or {}
  local use_index = cal_config.use_vault_index ~= false  -- default true

  if use_index then
    local vault_index = require("andrew.vault.vault_index")
    local idx = vault_index.current()
    if idx and idx:is_ready() then
      if idx._generation ~= _index_generation
        or not _deadline_cache
        or _deadline_cache.vault_path ~= engine.vault_path
      then
        local deadlines = scan_dates_from_index()
        _deadline_cache = {
          vault_path = engine.vault_path,
          built_at = os.clock(),
          deadlines = deadlines,
        }
        _index_generation = idx._generation
      end
      return _deadline_cache.deadlines
    end
    -- Fall through to ripgrep if index not ready
  end

  -- Original ripgrep-based path (unchanged)
  local vault = engine.vault_path
  local now = os.clock()
  if _deadline_cache
    and _deadline_cache.vault_path == vault
    and (now - _deadline_cache.built_at) < DEADLINE_CACHE_TTL then
    return _deadline_cache.deadlines
  end

  local deadlines = scan_deadlines()
  _deadline_cache = {
    vault_path = vault,
    built_at = now,
    deadlines = deadlines,
  }
  return deadlines
end
```

### Step 5: Update `deadlines_for_month()` to Support Multiple Indicator Types

**File**: `lua/andrew/vault/calendar.lua`

Replace the simple `has_deadline[day] = true` with a richer structure that tracks
which kinds of indicators exist on each day:

```lua
--- Extract the set of days in a given month that have date indicators.
--- Returns a table mapping day_number -> set of indicator keys.
---@param year number
---@param month number
---@param deadlines table full date map from get_deadlines()
---@return table<number, table<string, boolean>>  day -> { due=true, scheduled=true, ... }
local function indicators_for_month(year, month, deadlines)
  local prefix = format_date(year, month, 1):sub(1, 7) -- "YYYY-MM"
  local day_indicators = {}
  for date_str, items in pairs(deadlines) do
    if date_str:sub(1, 7) == prefix then
      local day = tonumber(date_str:sub(9, 10))
      if day then
        if not day_indicators[day] then
          day_indicators[day] = {}
        end
        for _, item in ipairs(items) do
          local kind = item.kind or "due"
          day_indicators[day][kind] = true
        end
      end
    end
  end
  return day_indicators
end
```

### Step 6: Update `render_calendar()` to Show Multiple Indicator Types

**File**: `lua/andrew/vault/calendar.lua`

Modify the rendering loop (starting at line 289) to use the new
`indicators_for_month()` and assign highlights based on the combination of
indicator types present. The priority order for cell background highlighting
remains: today > combined > single indicator > log > weekend.

The key change is adding a **dot row** below each week row that shows small
markers for each indicator type. This avoids overloading the day cell itself
with too many colors:

```lua
local function render_calendar(year, month, deadlines)
  local lines = {}
  local highlights = {}
  local cell_width = 4
  local grid_width = 7 * cell_width

  local today = engine.today()
  local today_y, today_m, today_d = today:match("(%d+)-(%d+)-(%d+)")
  today_y, today_m, today_d = tonumber(today_y), tonumber(today_m), tonumber(today_d)

  local has_log = scan_logs_for_month(year, month)
  local day_indicators = indicators_for_month(year, month, deadlines)
  local num_days = days_in_month(year, month)
  local start_wday = first_weekday(year, month)

  -- Title, blank, weekday header, separator (unchanged)
  -- ... (lines 245-271 remain the same) ...

  -- Day grid with indicator dots
  local row_idx = 4
  local current_line = ""
  local dot_line = ""        -- indicator dot row below each week row
  local col = 1
  local month_has_deadlines = false
  local month_has_scheduled = false

  -- Pad the first row
  for _ = 1, start_wday - 1 do
    current_line = current_line .. "    "
    dot_line = dot_line .. "    "
    col = col + 1
  end

  local day_positions = {}

  for day = 1, num_days do
    local cell = string.format(" %2d ", day)
    local col_start = #current_line
    current_line = current_line .. cell
    local col_end = #current_line

    day_positions[day] = { row = row_idx, col_start = col_start, col_end = col_end }

    local is_today = (year == today_y and month == today_m and day == today_d)
    local is_weekend = (col == 6 or col == 7)
    local is_logged = has_log[day]
    local indicators = day_indicators[day]
    local is_due = indicators and indicators.due
    local is_sched = indicators and indicators.scheduled

    if is_due then month_has_deadlines = true end
    if is_sched then month_has_scheduled = true end

    -- Cell highlight (same priority as before, with scheduled added)
    if is_today then
      highlights[#highlights + 1] = { "VaultCalendarToday", row_idx, col_start, col_end }
    elseif is_logged and is_due then
      highlights[#highlights + 1] = { "VaultCalendarLogDeadline", row_idx, col_start, col_end }
    elseif is_due then
      highlights[#highlights + 1] = { "VaultCalendarDeadline", row_idx, col_start, col_end }
    elseif is_sched then
      highlights[#highlights + 1] = { "VaultCalendarScheduled", row_idx, col_start, col_end }
    elseif is_logged then
      highlights[#highlights + 1] = { "VaultCalendarHasLog", row_idx, col_start, col_end }
    elseif is_weekend then
      highlights[#highlights + 1] = { "VaultCalendarWeekend", row_idx, col_start, col_end }
    end

    -- Build dot indicators for this day
    -- Each day cell is 4 chars wide. Use the center 2 chars for up to 2 dots.
    local dots = "    "  -- 4 spaces (no indicators)
    if indicators and (is_due or is_sched) and not is_today then
      local d = is_due and "." or " "
      local s = is_sched and "." or " "
      dots = " " .. d .. s .. " "
    end
    dot_line = dot_line .. dots

    if col == 7 then
      lines[#lines + 1] = current_line
      -- Only emit dot_line if it has any dots
      if dot_line:find("%.") then
        local dot_row = #lines  -- 0-indexed for highlights
        lines[#lines + 1] = dot_line
        -- Highlight the dots: scan for "." positions
        for pos = 1, #dot_line do
          if dot_line:sub(pos, pos) == "." then
            -- Determine which day this position belongs to
            local day_col = math.floor((pos - 1) / cell_width)
            local offset_in_cell = (pos - 1) % cell_width
            -- offset 1 = due dot, offset 2 = scheduled dot
            local hl_group
            if offset_in_cell == 1 then
              hl_group = "VaultCalendarDeadline"
            elseif offset_in_cell == 2 then
              hl_group = "VaultCalendarScheduled"
            end
            if hl_group then
              highlights[#highlights + 1] = { hl_group, dot_row, pos - 1, pos }
            end
          end
        end
        row_idx = row_idx + 2  -- day row + dot row
      else
        row_idx = row_idx + 1  -- day row only
      end
      current_line = ""
      dot_line = ""
      col = 1
    else
      col = col + 1
    end
  end

  -- Flush remaining partial row (same as before, plus dot_line)
  if current_line ~= "" then
    while col <= 7 do
      current_line = current_line .. "    "
      dot_line = dot_line .. "    "
      col = col + 1
    end
    lines[#lines + 1] = current_line
    if dot_line:find("%.") then
      lines[#lines + 1] = dot_line
      -- (highlight dots same as above)
    end
  end

  -- Updated legend with scheduled indicator
  lines[#lines + 1] = ""
  local legend_row = #lines - 1
  local legend = " *today  *log  *due"
  if month_has_scheduled then
    legend = legend .. "  *sched"
  end
  if month_has_deadlines and vim.tbl_count(has_log) > 0 then
    legend = legend .. "  *log+due"
  end
  lines[#lines] = legend
  -- (apply legend highlights as before, adding VaultCalendarScheduled for *sched)

  -- ... (footer unchanged) ...

  return {
    lines = lines,
    highlights = highlights,
    day_positions = day_positions,
    num_days = num_days,
    start_wday = start_wday,
  }
end
```

**Alternative (simpler) approach**: Instead of the dot-row system, keep the
existing single-row layout and use the cell highlight to convey the most
important indicator. Add a tooltip-style popup on cursor hover that shows the
full breakdown. This is simpler to implement and avoids changing the calendar
height dynamically.

Given the calendar's compact design (34-char width, 16-line height), the simpler
approach is recommended for the initial implementation. The dot row can be added
as a follow-up if users want more visual density.

### Step 6 (Alternative -- Recommended): Keep Single-Row Layout

Use the existing highlight-based approach but extend the priority chain to
include scheduled dates. The `open_day()` function already handles showing
detail pickers, so the cell color serves as a quick visual cue while `<CR>`
provides full detail.

Replace the highlight priority block in `render_calendar()` (lines 298-321):

```lua
-- Determine highlight for this day
local is_today = (year == today_y and month == today_m and day == today_d)
local is_weekend = (col == 6 or col == 7)
local is_logged = has_log[day]
local indicators = day_indicators[day]
local is_due = indicators and indicators.due
local is_sched = indicators and indicators.scheduled
local has_any_indicator = is_due or is_sched

if is_due then month_has_deadlines = true end
if is_sched then month_has_scheduled = true end

if is_today then
  highlights[#highlights + 1] = { "VaultCalendarToday", row_idx, col_start, col_end }
elseif is_logged and is_due then
  highlights[#highlights + 1] = { "VaultCalendarLogDeadline", row_idx, col_start, col_end }
elseif is_due then
  highlights[#highlights + 1] = { "VaultCalendarDeadline", row_idx, col_start, col_end }
elseif is_logged and is_sched then
  -- New: log + scheduled combo
  highlights[#highlights + 1] = { "VaultCalendarLogDeadline", row_idx, col_start, col_end }
elseif is_sched then
  highlights[#highlights + 1] = { "VaultCalendarScheduled", row_idx, col_start, col_end }
elseif is_logged then
  highlights[#highlights + 1] = { "VaultCalendarHasLog", row_idx, col_start, col_end }
elseif is_weekend then
  highlights[#highlights + 1] = { "VaultCalendarWeekend", row_idx, col_start, col_end }
end
```

### Step 7: Update `open_day()` to Show All Indicator Types

**File**: `lua/andrew/vault/calendar.lua`

Modify `open_day()` (line 577) to show items from all indicator types in the
detail picker, not just "due" tasks. Add the `kind` field to the fzf display:

```lua
local function open_day()
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local crow = cursor[1] - 1
  local ccol = cursor[2]
  local day = day_at_cursor(state.day_positions, crow, ccol, state.num_days)
  if not day then return end

  local date = format_date(state.year, state.month, day)
  local items = state.deadlines[date]
  local has_items = items and #items > 0
  local log_path = engine.vault_path .. "/Log/" .. date .. ".md"
  local has_log = vim.fn.filereadable(log_path) == 1

  if not has_items then
    close()
    open_or_create_log(date, state.year, state.month, day)
    return
  end

  -- Group items by kind for display
  local kind_counts = {}
  for _, item in ipairs(items) do
    local k = item.kind or "due"
    kind_counts[k] = (kind_counts[k] or 0) + 1
  end

  -- Build summary for the select menu
  local summary_parts = {}
  for kind, count in pairs(kind_counts) do
    summary_parts[#summary_parts + 1] = kind .. ": " .. count
  end
  local summary = table.concat(summary_parts, ", ")

  if has_items and not has_log then
    close()
    engine.run(function()
      local choice = engine.select(
        { "Show items (" .. summary .. ")", "Create daily log" },
        { prompt = date }
      )
      if choice and choice:match("^Show items") then
        show_deadline_tasks(date, items)
      elseif choice and choice:match("^Create") then
        open_or_create_log(date, state.year, state.month, day)
      end
    end)
    return
  end

  -- Both log and items exist
  close()
  engine.run(function()
    local choice = engine.select(
      { "Open daily log", "Show items (" .. summary .. ")" },
      { prompt = date }
    )
    if choice and choice:match("^Open daily") then
      open_or_create_log(date, state.year, state.month, day)
    elseif choice and choice:match("^Show items") then
      show_deadline_tasks(date, items)
    end
  end)
end
```

### Step 8: Update `show_deadline_tasks()` to Display Kind

**File**: `lua/andrew/vault/calendar.lua`

Modify `show_deadline_tasks()` (line 531) to include the item kind in the
display label:

```lua
local function show_deadline_tasks(date, tasks)
  local fzf = require("fzf-lua")

  local entries = {}
  local entry_map = {}
  for _, task in ipairs(tasks) do
    local kind_prefix = task.kind and ("[" .. task.kind .. "] ") or ""
    local label = kind_prefix .. task.file .. ":" .. task.line .. ": " .. task.text
    entries[#entries + 1] = label
    entry_map[label] = task
  end

  fzf.fzf_exec(entries, {
    prompt = date .. "> ",
    -- ... (actions unchanged) ...
  })
end
```

### Step 9: Update Legend

**File**: `lua/andrew/vault/calendar.lua`

The legend section (around line 344) needs to include the scheduled indicator
when scheduled items exist in the current month. Add after the `*due` legend
entry:

```lua
if month_has_scheduled then
  legend = legend .. "  *sched"
end
```

And add the highlight application for the `*sched` marker:

```lua
if month_has_scheduled then
  local pos_sched = legend:find("*sched", 1, true)
  if pos_sched then
    highlights[#highlights + 1] = { "VaultCalendarScheduled", legend_row, pos_sched - 1, pos_sched }
    highlights[#highlights + 1] = { "VaultCalendarLegend", legend_row, pos_sched, pos_sched + 5 }
  end
end
```

### Step 10: Update `setup()` Cache Registration

**File**: `lua/andrew/vault/calendar.lua`

Update the cache stats to report vault index generation when using the index:

```lua
function M.setup()
  engine.register_cache({
    name = "calendar_deadlines",
    module = "andrew.vault.calendar",
    invalidate = function()
      _deadline_cache = nil
      _index_generation = -1
    end,
    stats = function()
      return {
        entries = _deadline_cache and vim.tbl_count(_deadline_cache.deadlines) or 0,
        age_seconds = _deadline_cache and (os.clock() - _deadline_cache.built_at) or nil,
        vault = _deadline_cache and _deadline_cache.vault_path or nil,
        ttl = DEADLINE_CACHE_TTL,
        index_generation = _index_generation,
      }
    end,
  })
end
```

### Step 11: Increase Default Window Height

**File**: `lua/andrew/vault/calendar.lua`

The window height (currently 16, line 437) may need a small increase to
accommodate the updated legend with more indicator types. Change to dynamic
sizing:

```lua
local float = ui.create_float_display({
  title = "Vault Calendar",
  lines = {},
  width = 34,
  height = 18,  -- slightly taller for expanded legend
  cursor_line = false,
})
```

## Files to Modify

| File | Changes |
|------|---------|
| `lua/andrew/vault/config.lua` | Add `M.calendar` section with indicator config |
| `lua/andrew/vault/colors.lua` | Add `calendar_scheduled` to all 3 palettes; add `VaultCalendarScheduled` highlight group |
| `lua/andrew/vault/calendar.lua` | Replace `scan_deadlines()` dispatch with vault index query; update `get_deadlines()`, `deadlines_for_month()` -> `indicators_for_month()`, `render_calendar()`, `open_day()`, `show_deadline_tasks()`, `setup()` |

## Edge Cases

1. **Vault index not ready on first calendar open.** The vault index loads
   persisted data on startup (which sets `_ready=true` immediately) and then
   runs an incremental diff. If the calendar is opened before the index is
   ready (e.g., very early in startup), the code falls back to the ripgrep
   scan. This is handled by the `if idx and idx:is_ready()` guard in the
   updated `get_deadlines()`.

2. **Duplicate dates from multiple sources.** A note with both
   `due: 2026-03-15` in frontmatter and `[due:: 2026-03-15]` in body text
   produces two entries for the same date from the same file. The
   `scan_dates_from_index()` function should deduplicate by
   `(rel_path, date_str, kind)` tuple. Add a seen-set:

   ```lua
   local seen_key = rel_path .. "|" .. date_str .. "|" .. indicator.key
   if not seen[seen_key] then
     seen[seen_key] = true
     add_date(date_str, item)
   end
   ```

3. **Tasks with multiple date fields.** A task like
   `- [ ] Review PR [due:: 2026-03-01] [scheduled:: 2026-02-28]` has both
   due and scheduled dates. The task text extraction handles each field
   independently via the `extract_date_from_task_text()` helper, so both
   dates are captured under their respective indicator keys.

4. **Non-date values in date fields.** A frontmatter field `due: TBD` or
   `due: next week` does not match the `YYYY-MM-DD` pattern and is silently
   skipped by `extract_date_string()`.

5. **Inline field last-wins behavior.** The vault index's `extract_inline_fields()`
   stores only the last value for each key. If a note has multiple
   `due:: 2026-03-01` and `due:: 2026-03-15` fields, only the last one is
   indexed. This is consistent with the vault index's existing behavior but
   means earlier dates in the same file are invisible to the calendar. This
   is acceptable because having multiple `due::` fields in one file is an
   unusual pattern.

6. **Task text in inline_fields extraction.** The vault index's
   `extract_inline_fields()` (line 490) explicitly skips task lines
   (`^%s*[-*] %[.%] `) to avoid double-extraction. The calendar's
   `task.due` source handles task lines separately. This means task-line
   due dates are only found via the `task.due` source, not `inline.due`.

7. **Performance with large vaults.** The vault index iteration
   (`for rel_path, entry in pairs(idx.files)`) is O(n) where n is the number
   of indexed files. For a vault with 10,000 files, this produces a single
   pass through all entries. The extraction per entry is O(1) for frontmatter
   and inline fields, O(t) for tasks where t is the number of tasks in the
   file. With generation-based caching, this scan only runs when the index
   changes (not on every month navigation).

8. **Calendar month navigation.** Navigating between months (h/l keys) calls
   `redraw()` which re-renders from the cached deadline data. Since the cache
   covers all dates (not just the current month), month navigation is instant
   with no re-scanning.

9. **Empty vault or no date fields.** If no files have date fields, all
   indicator sets are empty and the calendar renders identically to the
   current "no deadlines" state.

10. **Highlight priority when today has indicators.** Today always gets the
    `VaultCalendarToday` highlight (green background). This means indicators
    on today's date are not visible in the cell color. The `open_day()` detail
    picker still works, and the legend communicates that today's cell always
    shows green regardless of indicators.

## Testing Strategy

### Unit Tests

These tests can be run without a full Neovim environment using the existing
vault test infrastructure (if available) or as manual verification steps.

1. **`extract_date_string()` function:**
   - `"2026-03-15"` returns `"2026-03-15"`
   - `"2026-03-15T10:30:00"` returns `"2026-03-15"`
   - `"TBD"` returns `nil`
   - `""` returns `nil`
   - `nil` returns `nil`
   - `123` (number) returns `nil`

2. **`extract_date_from_task_text()` function:**
   - `"Review PR [due:: 2026-03-01]"` with field `"due"` returns `"2026-03-01"`
   - `"Submit report (due:: 2026-04-15)"` with field `"due"` returns `"2026-04-15"`
   - `"Plan sprint due:: 2026-03-10"` with field `"due"` returns `"2026-03-10"`
   - `"No date here"` with field `"due"` returns `nil`
   - `"[scheduled:: 2026-03-01]"` with field `"due"` returns `nil`
   - `"[scheduled:: 2026-03-01]"` with field `"scheduled"` returns `"2026-03-01"`

3. **`indicators_for_month()` function:**
   - Given dates `{ ["2026-03-01"] = {{kind="due"}}, ["2026-03-15"] = {{kind="scheduled"}} }`
     and month 3, returns `{ [1] = {due=true}, [15] = {scheduled=true} }`
   - Given dates from a different month, returns empty table
   - Given items with mixed kinds on same day, returns both flags

### Integration Tests (Manual)

1. **Basic vault index integration:**
   - Open `:VaultCalendar` in a vault with `due::` dates
   - Verify days with due dates are highlighted in teal/cyan
   - Press `<CR>` on a highlighted day to see the detail picker
   - Verify task text and file paths are correct

2. **Scheduled date indicators:**
   - Add `scheduled:: 2026-03-10` to a vault note
   - Open `:VaultCalendar` and navigate to March 2026
   - Verify day 10 is highlighted with the scheduled color (purple)
   - Press `<CR>` to see "scheduled" items in the picker

3. **Frontmatter due dates:**
   - Create a note with `due: 2026-04-01` in frontmatter
   - Open calendar and navigate to April 2026
   - Verify day 1 shows a deadline indicator

4. **Fallback to ripgrep:**
   - Set `config.calendar.use_vault_index = false`
   - Open `:VaultCalendar` and verify deadlines still appear
   - Verify behavior is identical to the current implementation

5. **Month navigation:**
   - Open calendar on a month with indicators
   - Press `l` to go forward, `h` to go back
   - Verify indicators persist across navigation without re-scanning

6. **Cache invalidation:**
   - Open calendar, note the indicators
   - Edit a note to add/remove a `due::` field
   - Re-open calendar (or wait for index rebuild)
   - Verify indicators update to reflect the change

7. **Legend accuracy:**
   - Open calendar on a month with both due and scheduled items
   - Verify legend shows `*today *log *due *sched`
   - Navigate to a month with only log entries
   - Verify legend shows `*today *log *due` (no `*sched`)

8. **Detail picker with mixed kinds:**
   - Have a day with both due and scheduled items
   - Press `<CR>` on that day
   - Verify the picker shows `[due]` and `[scheduled]` prefixes
   - Verify navigation to the correct file and line on selection

### Regression Tests

- Verify existing daily log navigation (h/l/H/L) still works
- Verify j/k cursor movement within the grid still works
- Verify `<CR>` on a day with only a log (no indicators) opens the log directly
- Verify `<CR>` on an empty day offers to create a daily log
- Verify `q` and `<Esc>` close the calendar
- Verify `BufLeave` autocmd still closes the calendar
