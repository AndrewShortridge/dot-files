# Feature 15: Date Utility Consolidation

## Dependencies
- **None** — can be done independently.
- **Depended on by:** Nothing

## Problem
Date-related utilities are scattered across 4 locations with overlapping functionality:

### engine.lua (lines 87-114):
- `M.today()` → `os.date("%Y-%m-%d")`
- `M.today_long()` → `os.date("%B %d, %Y")`
- `M.today_weekday()` → `os.date("%A, %B ") .. day_num .. os.date(", %Y")`
- `M.date_offset(days)` → shifts today by N days using `os.time` table normalization

### navigate.lua (lines 25-40):
- `parse_date(date_str)` → converts `"YYYY-MM-DD"` to timestamp
- `shift_date(date_str, days)` → offsets a date string by N days
These duplicate `engine.date_offset` but work from arbitrary date strings instead of "today".

### recurrence.lua (lines 71 and 141):
- Uses raw `os.date("%Y-%m-%d")` instead of `engine.today()` — does not require engine at all

### templates/daily_log.lua (lines 67-73):
- Re-derives weekday formatting for arbitrary dates that `engine.today_weekday()` already provides for today
- Computes yesterday/tomorrow manually instead of using `engine.date_offset`

### query/types.lua (lines 237-309):
- Full `Date.parse()` supporting ISO dates, datetimes, long-form, keywords
- This is the most comprehensive date parser

### query/api.lua (lines 568-589):
- `dv.date()` partially reimplements "today"/"tomorrow"/"yesterday" even though `Date.parse` already handles them

## Files to Modify
1. `lua/andrew/vault/engine.lua` — Add `M.parse_date(str)`, `M.format_weekday(date_str)`, `M.date_offset_from(base_date, days)`
2. `lua/andrew/vault/recurrence.lua` — Replace `os.date("%Y-%m-%d")` with `engine.today()`
3. `lua/andrew/vault/navigate.lua` — Replace `parse_date` and `shift_date` with engine helpers
4. `lua/andrew/vault/templates/daily_log.lua` — Use `engine.format_weekday()` and `engine.date_offset_from()`
5. `lua/andrew/vault/query/api.lua` — Remove redundant tomorrow/yesterday handling, delegate to `Date.parse`

## Implementation Steps

### Step 1: Extend engine.lua date utilities

Add after the existing date functions (~line 114):

```lua
--- Parse a "YYYY-MM-DD" date string into a timestamp.
--- @param date_str string
--- @return number|nil  os.time timestamp, or nil on parse failure
function M.parse_date(date_str)
  local y, m, d = date_str:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then return nil end
  return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

--- Offset an arbitrary date string by N days.
--- @param date_str string  "YYYY-MM-DD" format
--- @param days number  Positive for future, negative for past
--- @return string  "YYYY-MM-DD" format
function M.date_offset_from(date_str, days)
  local ts = M.parse_date(date_str)
  if not ts then return date_str end
  return os.date("%Y-%m-%d", ts + days * 86400)
end

--- Format a date string as a long weekday string.
--- e.g., "2026-02-22" → "Sunday, February 22, 2026"
--- @param date_str string  "YYYY-MM-DD" format
--- @return string
function M.format_weekday(date_str)
  local ts = M.parse_date(date_str)
  if not ts then return date_str end
  local day_num = tonumber(os.date("%d", ts))
  return os.date("%A, %B ", ts) .. day_num .. os.date(", %Y", ts)
end
```

Also refactor existing `M.date_offset` to use the new helper:
```lua
function M.date_offset(days)
  return M.date_offset_from(M.today(), days)
end
```

And refactor `M.today_weekday` to use the new helper:
```lua
function M.today_weekday()
  return M.format_weekday(M.today())
end
```

### Step 2: Update recurrence.lua

Add at top:
```lua
local engine = require("andrew.vault.engine")
```

Replace:
- Line 71: `return os.date("%Y-%m-%d")` → `return engine.today()`
- Line 141: `local base_date = due_date or os.date("%Y-%m-%d")` → `local base_date = due_date or engine.today()`

### Step 3: Update navigate.lua

Delete `parse_date` (lines 25-30) and `shift_date` (lines 32-40).

Replace all calls:
```lua
-- Before:
local ts = parse_date(date_str)
local next_date = shift_date(date_str, 1)

-- After:
local ts = engine.parse_date(date_str)
local next_date = engine.date_offset_from(date_str, 1)
```

### Step 4: Update templates/daily_log.lua

Replace lines 67-73 date computation:
```lua
-- Before:
local y, mn, d = date:match("(%d+)-(%d+)-(%d+)")
y, mn, d = tonumber(y), tonumber(mn), tonumber(d)
local ts = os.time({ year = y, month = mn, day = d, hour = 12 })
local yesterday = os.date("%Y-%m-%d", os.time({ year = y, month = mn, day = d - 1, hour = 12 }))
local tomorrow = os.date("%Y-%m-%d", os.time({ year = y, month = mn, day = d + 1, hour = 12 }))
local day_num = tonumber(os.date("%d", ts))
local weekday_long = os.date("%A, %B ", ts) .. day_num .. os.date(", %Y", ts)

-- After:
local yesterday = engine.date_offset_from(date, -1)
local tomorrow = engine.date_offset_from(date, 1)
local weekday_long = engine.format_weekday(date)
```

### Step 5: Clean up query/api.lua

Lines 568-589 (`dv.date`) have redundant handling:
```lua
-- Current (redundant):
if arg == "tomorrow" then
  local d = types.Date.today()
  return d:add_days(1) or types.Date.parse(os.date("%Y-%m-%d", os.time() + 86400))
end
```

`types.Date.parse("tomorrow")` already handles this. Simplify:
```lua
function dv.date(arg)
  if not arg then return types.Date.today() end
  return types.Date.parse(tostring(arg))
end
```

## Testing
- `VaultDaily` — verify daily log has correct weekday, yesterday/tomorrow links
- Navigate daily logs with `<leader>v[` / `<leader>v]` — verify date shifting works
- Task recurrence — complete a recurring task, verify next due date computed
- Dataview query with `date("tomorrow")` — verify correct date returned
- `VaultCalendar` — verify date navigation still works

## Estimated Impact
- **Lines removed:** ~25
- **Lines added:** ~20
- **Net reduction:** ~5 lines
- **Benefit:** Single source of truth for date parsing/formatting, eliminates raw `os.date` calls
