# 40 --- Extended Recurrence Patterns and Bulk Generation

**Priority:** Medium
**Summary:** Extend the recurrence rule parser in `recurrence.lua` to support English patterns like "every other week", "every 2 weeks on Monday", "every month on the first Monday", and "every other month". Add a `:VaultRecurrenceBuild` command that generates all future occurrences of recurring tasks within a date range, inserting them into the appropriate daily logs or a designated task file.

---

## Motivation

The current `parse_rule()` handles a useful but limited set of recurrence patterns: fixed-interval days, weeks, months, quarters, years, weekdays, and monthly-on-day. Real-world recurring tasks often require more nuanced scheduling:

- Biweekly standups ("every other week")
- Meetings on specific weekdays with multi-week cadence ("every 2 weeks on Monday")
- Monthly reviews on ordinal weekdays ("every month on the first Monday")
- Bimonthly check-ins ("every other month")
- Multi-day-of-week rules ("every 2 weeks on Monday, Wednesday")

Additionally, there is no way to pre-generate future occurrences of recurring tasks. When a user wants to see their recurring commitments for an upcoming month, they must manually check each task or wait until each occurrence triggers via `handle_recurrence()`. A bulk generation command would allow planning and review of upcoming obligations.

---

## Current State

### `parse_rule()` --- Existing Patterns

File: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/recurrence.lua`, lines 9--64.

| Rule String | Parsed Result | Notes |
|---|---|---|
| `every day` | `{ type = "days", n = 1 }` | |
| `every weekday` | `{ type = "weekday", n = 1 }` | Skip weekends |
| `every week` | `{ type = "days", n = 7 }` | Treated as 7-day interval |
| `every N weeks` | `{ type = "days", n = N * 7 }` | Treated as N*7-day interval |
| `every month on the Nth` | `{ type = "monthly_on", n = 1, day = N }` | Fixed day-of-month |
| `every month` | `{ type = "months", n = 1 }` | Same day next month |
| `every quarter` | `{ type = "months", n = 3 }` | |
| `every year` | `{ type = "years", n = 1 }` | |
| `every N days` | `{ type = "days", n = N }` | |

### `next_date()` --- Existing Cases

File: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/recurrence.lua`, lines 70--118.

| Rule Type | Logic |
|---|---|
| `days` | Add `n * 86400` seconds to timestamp |
| `weekday` | Add 1 day, then skip Saturday/Sunday |
| `months` | Add `n` to month, let `os.time` normalize overflow |
| `monthly_on` | Advance month by `n`, set day to `rule.day` |
| `years` | Add `n` to year |

### `handle_recurrence()` --- Trigger Flow

File: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/recurrence.lua`, lines 125--176.

Called when a task is checked `[x]` (from `tasks.lua:cycle_task()` or `task_kanban.lua`):

1. Parses task text via `vault_index.parse_task_fields()`
2. Extracts `repeat_rule` field
3. Calls `parse_rule()` on the rule string
4. Computes `next_date()` from the task's `due` date (or today)
5. Builds a new unchecked task line with updated `[due:: ...]`
6. Inserts it above the completed line in the current buffer

### Limitations

1. **No "every other" patterns.** "every other week" or "every other day" are common English idioms not recognized.
2. **No day-of-week constraints on multi-week rules.** "every 2 weeks" advances by 14 days from the current due date but cannot anchor to a specific weekday.
3. **No ordinal weekday-of-month.** "every month on the first Monday" or "the last Friday" are unsupported.
4. **No "every other month".** Must use `every 2 months` (not currently parsed --- `every N months` has no pattern).
5. **No multi-day rules.** "every 2 weeks on Monday, Wednesday" is not representable.
6. **No bulk generation.** Future occurrences must be triggered one at a time.

---

## Grammar for New Patterns

The following BNF-like grammar defines the full set of supported recurrence rule strings after this change. New productions are marked with `(NEW)`.

```
rule        ::= "every" interval
              | "every" "weekday"

interval    ::= day_rule
              | week_rule
              | month_rule
              | quarter_rule
              | year_rule

day_rule    ::= "day"
              | NUMBER "days"
              | "other day"                         (NEW)

week_rule   ::= "week"
              | NUMBER "weeks"
              | "other week"                        (NEW)
              | NUMBER "weeks" "on" day_list        (NEW)
              | "other week" "on" day_list          (NEW)
              | "week" "on" day_list                (NEW)

month_rule  ::= "month"
              | NUMBER "months"                     (NEW)
              | "other month"                       (NEW)
              | "month" "on the" ordinal            (existing, day-of-month)
              | "month" "on the" ordinal_weekday    (NEW)
              | NUMBER "months" "on the" ordinal    (NEW)
              | NUMBER "months" "on the" ordinal_weekday  (NEW)

quarter_rule ::= "quarter"

year_rule   ::= "year"

day_list    ::= WEEKDAY ("," WEEKDAY)*

WEEKDAY     ::= "monday" | "tuesday" | "wednesday" | "thursday"
              | "friday" | "saturday" | "sunday"
              | "mon" | "tue" | "wed" | "thu" | "fri" | "sat" | "sun"

ordinal     ::= NUMBER ("st" | "nd" | "rd" | "th")

ordinal_weekday ::= ORDINAL_WORD WEEKDAY             (NEW)

ORDINAL_WORD ::= "first" | "second" | "third" | "fourth" | "last"  (NEW)

NUMBER      ::= [1-9][0-9]*
```

### Example Rule Strings

| Rule String | Meaning |
|---|---|
| `every other day` | Every 2 days |
| `every other week` | Every 2 weeks (14 days from due date) |
| `every 2 weeks on Monday` | Every 2 weeks, pinned to Monday |
| `every 2 weeks on Monday, Wednesday` | Every 2 weeks, generates on both Mon and Wed |
| `every week on Friday` | Every week, pinned to Friday |
| `every other week on Tuesday` | Every 2 weeks, pinned to Tuesday |
| `every month on the first Monday` | First Monday of each month |
| `every month on the last Friday` | Last Friday of each month |
| `every month on the third Wednesday` | Third Wednesday of each month |
| `every other month` | Every 2 months |
| `every 3 months` | Every 3 months (currently only "every quarter" works for this) |
| `every 2 months on the 15th` | 15th of every other month |
| `every 3 months on the first Monday` | First Monday of every 3rd month |

---

## Implementation Plan

### 1. New Rule Types for the Return Struct

Currently `parse_rule()` returns tables with `{ type, n, day }`. We add new fields:

```lua
--- @class RecurrenceRule
--- @field type string          "days"|"weekday"|"months"|"monthly_on"|"years"
---                              NEW: "weekly_on"|"monthly_ordinal"
--- @field n number             Interval multiplier (1 = every, 2 = every other, etc.)
--- @field day number|nil       Day-of-month for "monthly_on"
--- @field weekdays number[]|nil  (NEW) Day-of-week list for "weekly_on" (1=Mon..7=Sun)
--- @field ordinal number|nil   (NEW) Which occurrence: 1=first, 2=second, ..., -1=last
--- @field weekday number|nil   (NEW) Day-of-week for "monthly_ordinal" (1=Mon..7=Sun)
```

New `type` values:

| Type | Fields Used | Meaning |
|---|---|---|
| `weekly_on` | `n`, `weekdays` | Every `n` weeks, anchored to specific weekday(s) |
| `monthly_ordinal` | `n`, `ordinal`, `weekday` | Every `n` months, on the Nth weekday of the month |

Existing types remain unchanged. "every other day" maps to `{ type = "days", n = 2 }`, "every other week" to `{ type = "days", n = 14 }`, "every other month" to `{ type = "months", n = 2 }`, "every N months" to `{ type = "months", n = N }`.

### 2. Extending `parse_rule()`

#### 2a. Weekday Name Lookup Table

Add a local lookup table at the top of `recurrence.lua`:

```lua
--- Map weekday names (lowercase) to ISO weekday numbers (1=Monday..7=Sunday).
local WEEKDAY_NUMS = {
  monday = 1, mon = 1,
  tuesday = 2, tue = 2,
  wednesday = 3, wed = 3,
  thursday = 4, thu = 4,
  friday = 5, fri = 5,
  saturday = 6, sat = 6,
  sunday = 7, sun = 7,
}

--- Map ordinal words to numeric values (-1 = last).
local ORDINAL_WORDS = {
  first = 1, second = 2, third = 3, fourth = 4, last = -1,
}
```

#### 2b. Helper: Parse a Comma-Separated Day List

```lua
--- Parse a comma-separated list of weekday names into sorted ISO weekday numbers.
---@param day_str string e.g. "Monday, Wednesday" or "mon, wed, fri"
---@return number[]|nil sorted ISO weekday numbers, or nil if any name is invalid
local function parse_day_list(day_str)
  local days = {}
  for name in day_str:gmatch("[%a]+") do
    local num = WEEKDAY_NUMS[name:lower()]
    if not num then return nil end
    days[#days + 1] = num
  end
  if #days == 0 then return nil end
  table.sort(days)
  return days
end
```

#### 2c. New Patterns in `parse_rule()`

The patterns below are inserted into `parse_rule()` **before** the existing catch-all patterns. Order matters: more specific patterns must come first.

```lua
function M.parse_rule(rule_str)
  if not rule_str then return nil end
  local s = vim.trim(rule_str):lower()

  -- === Existing patterns (unchanged) ===

  -- "every day"
  if s == "every day" then
    return { type = "days", n = 1 }
  end

  -- "every weekday"
  if s == "every weekday" then
    return { type = "weekday", n = 1 }
  end

  -- === NEW: "every other day" ===
  if s == "every other day" then
    return { type = "days", n = 2 }
  end

  -- === NEW: "every other week" (no day constraint) ===
  if s == "every other week" then
    return { type = "days", n = 14 }
  end

  -- === NEW: "every [N] week[s] on <day_list>" / "every other week on <day_list>" ===
  do
    local week_n_str, day_str = s:match("^every (%d+) weeks? on (.+)$")
    if not week_n_str then
      day_str = s:match("^every other week on (.+)$")
      if day_str then week_n_str = "2" end
    end
    if not week_n_str then
      day_str = s:match("^every week on (.+)$")
      if day_str then week_n_str = "1" end
    end
    if week_n_str and day_str then
      local days = parse_day_list(day_str)
      if days then
        return { type = "weekly_on", n = tonumber(week_n_str), weekdays = days }
      end
    end
  end

  -- "every week" (existing)
  if s == "every week" then
    return { type = "days", n = 7 }
  end

  -- "every N weeks" (existing)
  local week_n = s:match("^every (%d+) weeks?$")
  if week_n then
    return { type = "days", n = tonumber(week_n) * 7 }
  end

  -- === NEW: "every month on the <ordinal_word> <weekday>" ===
  -- === Also: "every N months on the <ordinal_word> <weekday>" ===
  do
    local month_n_str, ord_str, wd_str = s:match(
      "^every (%d+) months? on the (%a+) (%a+)$"
    )
    if not month_n_str then
      ord_str, wd_str = s:match("^every other month on the (%a+) (%a+)$")
      if ord_str then month_n_str = "2" end
    end
    if not month_n_str then
      ord_str, wd_str = s:match("^every month on the (%a+) (%a+)$")
      if ord_str then month_n_str = "1" end
    end
    if month_n_str and ord_str and wd_str then
      local ord_num = ORDINAL_WORDS[ord_str]
      local wd_num = WEEKDAY_NUMS[wd_str]
      if ord_num and wd_num then
        return {
          type = "monthly_ordinal",
          n = tonumber(month_n_str),
          ordinal = ord_num,
          weekday = wd_num,
        }
      end
    end
  end

  -- "every month on the 15th" (existing)
  local day_of_month = s:match("^every month on the (%d+)")
  if day_of_month then
    return { type = "monthly_on", n = 1, day = tonumber(day_of_month) }
  end

  -- === NEW: "every N months on the <day>th" ===
  do
    local mn, dom = s:match("^every (%d+) months? on the (%d+)")
    if mn and dom then
      return { type = "monthly_on", n = tonumber(mn), day = tonumber(dom) }
    end
  end

  -- "every month" (existing)
  if s == "every month" then
    return { type = "months", n = 1 }
  end

  -- === NEW: "every other month" ===
  if s == "every other month" then
    return { type = "months", n = 2 }
  end

  -- === NEW: "every N months" ===
  local month_n = s:match("^every (%d+) months?$")
  if month_n then
    return { type = "months", n = tonumber(month_n) }
  end

  -- "every quarter" (existing)
  if s == "every quarter" then
    return { type = "months", n = 3 }
  end

  -- "every year" (existing)
  if s == "every year" then
    return { type = "years", n = 1 }
  end

  -- "every N days" (existing)
  local day_n = s:match("^every (%d+) days?$")
  if day_n then
    return { type = "days", n = tonumber(day_n) }
  end

  return nil
end
```

### 3. New `next_date()` Cases

#### 3a. Helper: Weekday Computation Utilities

These helpers go at the top of `recurrence.lua`, after the lookup tables:

```lua
--- Convert ISO weekday (1=Mon..7=Sun) to Lua os.date wday (1=Sun..7=Sat).
---@param iso number 1=Mon..7=Sun
---@return number lua wday 1=Sun..7=Sat
local function iso_to_lua_wday(iso)
  -- ISO: 1=Mon,2=Tue,...,7=Sun -> Lua: 2=Mon,3=Tue,...,1=Sun
  return (iso % 7) + 1
end

--- Convert Lua os.date wday (1=Sun..7=Sat) to ISO weekday (1=Mon..7=Sun).
---@param lua_wday number 1=Sun..7=Sat
---@return number iso weekday 1=Mon..7=Sun
local function lua_to_iso_wday(lua_wday)
  return ((lua_wday - 2) % 7) + 1
end

--- Find the Nth occurrence of a specific weekday in a given month.
--- If ordinal is -1, finds the last occurrence.
---@param year number
---@param month number
---@param iso_weekday number 1=Mon..7=Sun
---@param ordinal number 1=first, 2=second, ..., -1=last
---@return number|nil day of month, or nil if invalid (e.g., 5th Monday doesn't exist)
local function nth_weekday_of_month(year, month, iso_weekday, ordinal)
  local target_lua_wday = iso_to_lua_wday(iso_weekday)

  if ordinal == -1 then
    -- Last occurrence: start from the end of the month and work backward
    -- Find last day of month by getting day 0 of next month
    local last_day = os.date("*t", os.time({
      year = year, month = month + 1, day = 0, hour = 12,
    })).day
    for d = last_day, 1, -1 do
      local t = os.time({ year = year, month = month, day = d, hour = 12 })
      if tonumber(os.date("%w", t)) + 1 == target_lua_wday then
        return d
      end
    end
    return nil
  end

  -- Nth occurrence: scan from day 1 forward
  local count = 0
  -- Maximum 31 days in any month
  for d = 1, 31 do
    local ok, t_info = pcall(function()
      local t = os.time({ year = year, month = month, day = d, hour = 12 })
      return os.date("*t", t)
    end)
    if not ok then break end
    -- Make sure we haven't rolled into the next month
    if t_info.month ~= month or t_info.year ~= year then
      -- os.time normalized the overflow; d exceeds month length
      -- But we need to handle os.time's normalization properly.
      -- Re-check: if the normalized month doesn't match, stop.
      break
    end
    if t_info.wday == target_lua_wday then
      count = count + 1
      if count == ordinal then
        return d
      end
    end
  end
  return nil -- e.g., "fifth Monday" doesn't exist in this month
end
```

Note on `nth_weekday_of_month`: Lua's `os.time` normalizes overflows (e.g., day 32 of January becomes February 1). The loop must detect this to avoid scanning into the next month. We do this by checking `t_info.month ~= month` after normalization.

A cleaner approach for the loop termination:

```lua
local function days_in_month(year, month)
  -- Day 0 of next month = last day of this month
  return os.date("*t", os.time({ year = year, month = month + 1, day = 0, hour = 12 })).day
end

local function nth_weekday_of_month(year, month, iso_weekday, ordinal)
  local target_lua_wday = iso_to_lua_wday(iso_weekday)
  local dim = days_in_month(year, month)

  if ordinal == -1 then
    for d = dim, 1, -1 do
      local t = os.time({ year = year, month = month, day = d, hour = 12 })
      local info = os.date("*t", t)
      if info.wday == target_lua_wday then
        return d
      end
    end
    return nil
  end

  local count = 0
  for d = 1, dim do
    local t = os.time({ year = year, month = month, day = d, hour = 12 })
    local info = os.date("*t", t)
    if info.wday == target_lua_wday then
      count = count + 1
      if count == ordinal then
        return d
      end
    end
  end
  return nil
end
```

#### 3b. New `next_date()` Branches

Add after the existing `monthly_on` case and before the `years` case:

```lua
if rule.type == "weekly_on" then
  -- Advance by (rule.n) weeks from the start of the current week,
  -- then find the first matching weekday on or after that point.
  local t = os.time({ year = y, month = m, day = d, hour = 12 })
  local info = os.date("*t", t)
  local current_iso = lua_to_iso_wday(info.wday)

  -- Find the next matching weekday in the current week cycle first.
  -- If there's a later weekday in the list within the same week, use it.
  local found_later_this_cycle = nil
  for _, wd in ipairs(rule.weekdays) do
    if wd > current_iso then
      found_later_this_cycle = wd
      break
    end
  end

  if found_later_this_cycle then
    -- Advance to that weekday within the same week
    local days_ahead = found_later_this_cycle - current_iso
    local next_t = t + days_ahead * date_utils.SECS_PER_DAY
    return os.date("%Y-%m-%d", next_t)
  else
    -- Jump to the first weekday of the next cycle (n weeks ahead)
    -- Start of next cycle = current day + (n * 7 - days_since_start_of_week) days
    -- But we want to land on the first weekday in the list.
    local first_wd = rule.weekdays[1]
    -- Days until Monday of next cycle
    local days_since_monday = (current_iso - 1) -- 0 for Mon, 6 for Sun
    local days_to_next_monday = rule.n * 7 - days_since_monday
    -- Then advance to the target weekday from that Monday
    local days_from_monday = first_wd - 1  -- 0 for Mon, 4 for Fri, etc.
    local total_days = days_to_next_monday + days_from_monday
    local next_t = t + total_days * date_utils.SECS_PER_DAY
    return os.date("%Y-%m-%d", next_t)
  end
end

if rule.type == "monthly_ordinal" then
  -- Find the Nth weekday of the month, (rule.n) months ahead.
  local new_m = m + rule.n
  local new_y = y
  -- Normalize month overflow
  while new_m > 12 do
    new_m = new_m - 12
    new_y = new_y + 1
  end

  local target_day = nth_weekday_of_month(new_y, new_m, rule.weekday, rule.ordinal)
  if not target_day then
    -- Fallback: if the ordinal doesn't exist (e.g., 5th Monday),
    -- try the next month.
    new_m = new_m + 1
    if new_m > 12 then
      new_m = 1
      new_y = new_y + 1
    end
    target_day = nth_weekday_of_month(new_y, new_m, rule.weekday, rule.ordinal)
  end

  if target_day then
    local t = os.time({ year = new_y, month = new_m, day = target_day, hour = 12 })
    return os.date("%Y-%m-%d", t)
  end

  -- Ultimate fallback
  return from_date_str
end
```

### 4. Updated `monthly_on` for Multi-Month Intervals

The existing `monthly_on` handler already uses `rule.n` but was only ever set to `n = 1`. With the new "every N months on the Nth" pattern, `n` can be > 1. The existing code already handles this correctly since it does `month + rule.n`:

```lua
-- Existing code (no change needed):
if rule.type == "monthly_on" then
  local new_m = m + rule.n
  local new_y = y
  local t = os.time({ year = new_y, month = new_m, day = rule.day, hour = 12 })
  return os.date("%Y-%m-%d", t)
end
```

### 5. Complete Diff for `recurrence.lua` parse_rule / next_date

#### Before (parse_rule, lines 9--64):

```lua
function M.parse_rule(rule_str)
  if not rule_str then
    return nil
  end
  local s = vim.trim(rule_str):lower()

  -- "every day"
  if s == "every day" then
    return { type = "days", n = 1 }
  end

  -- "every weekday"
  if s == "every weekday" then
    return { type = "weekday", n = 1 }
  end

  -- "every week"
  if s == "every week" then
    return { type = "days", n = 7 }
  end

  -- "every 2 weeks", "every 3 weeks", etc.
  local week_n = s:match("^every (%d+) weeks?$")
  if week_n then
    return { type = "days", n = tonumber(week_n) * 7 }
  end

  -- "every month on the 15th" (or 1st, 2nd, 3rd, etc.)
  local day_of_month = s:match("^every month on the (%d+)")
  if day_of_month then
    return { type = "monthly_on", n = 1, day = tonumber(day_of_month) }
  end

  -- "every month"
  if s == "every month" then
    return { type = "months", n = 1 }
  end

  -- "every quarter"
  if s == "every quarter" then
    return { type = "months", n = 3 }
  end

  -- "every year"
  if s == "every year" then
    return { type = "years", n = 1 }
  end

  -- "every N days"
  local day_n = s:match("^every (%d+) days?$")
  if day_n then
    return { type = "days", n = tonumber(day_n) }
  end

  return nil
end
```

#### After (parse_rule, complete replacement):

```lua
--- Map weekday names (lowercase) to ISO weekday numbers (1=Monday..7=Sunday).
local WEEKDAY_NUMS = {
  monday = 1, mon = 1,
  tuesday = 2, tue = 2,
  wednesday = 3, wed = 3,
  thursday = 4, thu = 4,
  friday = 5, fri = 5,
  saturday = 6, sat = 6,
  sunday = 7, sun = 7,
}

--- Map ordinal words to numeric values (-1 = last).
local ORDINAL_WORDS = {
  first = 1, second = 2, third = 3, fourth = 4, last = -1,
}

--- Parse a comma-separated list of weekday names into sorted ISO weekday numbers.
---@param day_str string e.g. "Monday, Wednesday" or "mon, wed, fri"
---@return number[]|nil sorted ISO weekday numbers, or nil if any name is invalid
local function parse_day_list(day_str)
  local days = {}
  for name in day_str:gmatch("[%a]+") do
    local num = WEEKDAY_NUMS[name:lower()]
    if not num then return nil end
    days[#days + 1] = num
  end
  if #days == 0 then return nil end
  table.sort(days)
  -- Deduplicate
  local deduped = { days[1] }
  for i = 2, #days do
    if days[i] ~= days[i - 1] then
      deduped[#deduped + 1] = days[i]
    end
  end
  return deduped
end

--- Parse a recurrence rule string into a structured table.
--- @param rule_str string e.g. "every day", "every 2 weeks on Monday"
--- @return table|nil parsed rule
function M.parse_rule(rule_str)
  if not rule_str then
    return nil
  end
  local s = vim.trim(rule_str):lower()

  -- "every day"
  if s == "every day" then
    return { type = "days", n = 1 }
  end

  -- "every weekday"
  if s == "every weekday" then
    return { type = "weekday", n = 1 }
  end

  -- "every other day"
  if s == "every other day" then
    return { type = "days", n = 2 }
  end

  -- "every other week" (no day constraint)
  if s == "every other week" then
    return { type = "days", n = 14 }
  end

  -- "every [N] week[s] on <day_list>" / "every other week on <day_list>"
  -- "every week on <day_list>"
  do
    local week_n_str, day_str = s:match("^every (%d+) weeks? on (.+)$")
    if not week_n_str then
      day_str = s:match("^every other week on (.+)$")
      if day_str then week_n_str = "2" end
    end
    if not week_n_str then
      day_str = s:match("^every week on (.+)$")
      if day_str then week_n_str = "1" end
    end
    if week_n_str and day_str then
      local days = parse_day_list(day_str)
      if days then
        return { type = "weekly_on", n = tonumber(week_n_str), weekdays = days }
      end
    end
  end

  -- "every week"
  if s == "every week" then
    return { type = "days", n = 7 }
  end

  -- "every N weeks"
  local week_n = s:match("^every (%d+) weeks?$")
  if week_n then
    return { type = "days", n = tonumber(week_n) * 7 }
  end

  -- "every [N] month[s] on the <ordinal_word> <weekday>"
  -- "every other month on the <ordinal_word> <weekday>"
  -- "every month on the <ordinal_word> <weekday>"
  do
    local month_n_str, ord_str, wd_str = s:match(
      "^every (%d+) months? on the (%a+) (%a+)$"
    )
    if not month_n_str then
      ord_str, wd_str = s:match("^every other month on the (%a+) (%a+)$")
      if ord_str then month_n_str = "2" end
    end
    if not month_n_str then
      ord_str, wd_str = s:match("^every month on the (%a+) (%a+)$")
      if ord_str then month_n_str = "1" end
    end
    if month_n_str and ord_str and wd_str then
      local ord_num = ORDINAL_WORDS[ord_str]
      local wd_num = WEEKDAY_NUMS[wd_str]
      if ord_num and wd_num then
        return {
          type = "monthly_ordinal",
          n = tonumber(month_n_str),
          ordinal = ord_num,
          weekday = wd_num,
        }
      end
    end
  end

  -- "every month on the 15th" (or 1st, 2nd, 3rd, etc.)
  local day_of_month = s:match("^every month on the (%d+)")
  if day_of_month then
    return { type = "monthly_on", n = 1, day = tonumber(day_of_month) }
  end

  -- "every N months on the <day>th"
  do
    local mn, dom = s:match("^every (%d+) months? on the (%d+)")
    if mn and dom then
      return { type = "monthly_on", n = tonumber(mn), day = tonumber(dom) }
    end
  end

  -- "every month"
  if s == "every month" then
    return { type = "months", n = 1 }
  end

  -- "every other month"
  if s == "every other month" then
    return { type = "months", n = 2 }
  end

  -- "every N months"
  local month_n = s:match("^every (%d+) months?$")
  if month_n then
    return { type = "months", n = tonumber(month_n) }
  end

  -- "every quarter"
  if s == "every quarter" then
    return { type = "months", n = 3 }
  end

  -- "every year"
  if s == "every year" then
    return { type = "years", n = 1 }
  end

  -- "every N days"
  local day_n = s:match("^every (%d+) days?$")
  if day_n then
    return { type = "days", n = tonumber(day_n) }
  end

  return nil
end
```

#### Before (next_date, lines 70--118):

```lua
function M.next_date(from_date_str, rule)
  local y, m, d = from_date_str:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then
    return engine.today()
  end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)

  if rule.type == "days" then
    local t = os.time({ year = y, month = m, day = d, hour = 12 })
    t = t + rule.n * date_utils.SECS_PER_DAY
    return os.date("%Y-%m-%d", t)
  end

  if rule.type == "weekday" then
    local t = os.time({ year = y, month = m, day = d, hour = 12 })
    t = t + date_utils.SECS_PER_DAY
    local wday = tonumber(os.date("%w", t)) -- 0=Sun, 6=Sat
    if wday == 0 then
      t = t + date_utils.SECS_PER_DAY
    elseif wday == 6 then
      t = t + 2 * date_utils.SECS_PER_DAY
    end
    return os.date("%Y-%m-%d", t)
  end

  if rule.type == "months" then
    local t = os.time({ year = y, month = m + rule.n, day = d, hour = 12 })
    return os.date("%Y-%m-%d", t)
  end

  if rule.type == "monthly_on" then
    local new_m = m + rule.n
    local new_y = y
    local t = os.time({ year = new_y, month = new_m, day = rule.day, hour = 12 })
    return os.date("%Y-%m-%d", t)
  end

  if rule.type == "years" then
    local t = os.time({ year = y + rule.n, month = m, day = d, hour = 12 })
    return os.date("%Y-%m-%d", t)
  end

  return from_date_str
end
```

#### After (next_date, complete replacement):

```lua
--- Convert ISO weekday (1=Mon..7=Sun) to Lua os.date wday (1=Sun..7=Sat).
local function iso_to_lua_wday(iso)
  return (iso % 7) + 1
end

--- Convert Lua os.date wday (1=Sun..7=Sat) to ISO weekday (1=Mon..7=Sun).
local function lua_to_iso_wday(lua_wday)
  return ((lua_wday - 2) % 7) + 1
end

--- Return the number of days in a given month.
local function days_in_month(year, month)
  return os.date("*t", os.time({ year = year, month = month + 1, day = 0, hour = 12 })).day
end

--- Find the Nth occurrence (or last, if ordinal == -1) of a specific weekday
--- in a given month. Returns the day-of-month, or nil if it doesn't exist.
---@param year number
---@param month number
---@param iso_weekday number 1=Mon..7=Sun
---@param ordinal number 1..4 or -1 for last
---@return number|nil
local function nth_weekday_of_month(year, month, iso_weekday, ordinal)
  local target_lua_wday = iso_to_lua_wday(iso_weekday)
  local dim = days_in_month(year, month)

  if ordinal == -1 then
    for d = dim, 1, -1 do
      local info = os.date("*t", os.time({ year = year, month = month, day = d, hour = 12 }))
      if info.wday == target_lua_wday then
        return d
      end
    end
    return nil
  end

  local count = 0
  for d = 1, dim do
    local info = os.date("*t", os.time({ year = year, month = month, day = d, hour = 12 }))
    if info.wday == target_lua_wday then
      count = count + 1
      if count == ordinal then
        return d
      end
    end
  end
  return nil
end

function M.next_date(from_date_str, rule)
  local y, m, d = from_date_str:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then
    return engine.today()
  end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)

  if rule.type == "days" then
    local t = os.time({ year = y, month = m, day = d, hour = 12 })
    t = t + rule.n * date_utils.SECS_PER_DAY
    return os.date("%Y-%m-%d", t)
  end

  if rule.type == "weekday" then
    local t = os.time({ year = y, month = m, day = d, hour = 12 })
    t = t + date_utils.SECS_PER_DAY
    local wday = tonumber(os.date("%w", t)) -- 0=Sun, 6=Sat
    if wday == 0 then
      t = t + date_utils.SECS_PER_DAY
    elseif wday == 6 then
      t = t + 2 * date_utils.SECS_PER_DAY
    end
    return os.date("%Y-%m-%d", t)
  end

  if rule.type == "weekly_on" then
    local t = os.time({ year = y, month = m, day = d, hour = 12 })
    local info = os.date("*t", t)
    local current_iso = lua_to_iso_wday(info.wday)

    -- Check if there's a later matching weekday remaining in this week cycle
    local found_later = nil
    for _, wd in ipairs(rule.weekdays) do
      if wd > current_iso then
        found_later = wd
        break
      end
    end

    if found_later then
      local days_ahead = found_later - current_iso
      return os.date("%Y-%m-%d", t + days_ahead * date_utils.SECS_PER_DAY)
    end

    -- Jump to the first weekday of the next cycle
    local first_wd = rule.weekdays[1]
    local days_since_monday = current_iso - 1  -- 0 for Mon, 6 for Sun
    local days_to_next_monday = rule.n * 7 - days_since_monday
    local days_from_monday = first_wd - 1
    local total_days = days_to_next_monday + days_from_monday
    return os.date("%Y-%m-%d", t + total_days * date_utils.SECS_PER_DAY)
  end

  if rule.type == "months" then
    local t = os.time({ year = y, month = m + rule.n, day = d, hour = 12 })
    return os.date("%Y-%m-%d", t)
  end

  if rule.type == "monthly_on" then
    local new_m = m + rule.n
    local new_y = y
    local t = os.time({ year = new_y, month = new_m, day = rule.day, hour = 12 })
    return os.date("%Y-%m-%d", t)
  end

  if rule.type == "monthly_ordinal" then
    local new_m = m + rule.n
    local new_y = y
    while new_m > 12 do
      new_m = new_m - 12
      new_y = new_y + 1
    end

    local target_day = nth_weekday_of_month(new_y, new_m, rule.weekday, rule.ordinal)
    if not target_day then
      -- Ordinal doesn't exist this month (e.g., fifth Monday). Try next month.
      new_m = new_m + 1
      if new_m > 12 then
        new_m = 1
        new_y = new_y + 1
      end
      target_day = nth_weekday_of_month(new_y, new_m, rule.weekday, rule.ordinal)
    end
    if target_day then
      return os.date("%Y-%m-%d",
        os.time({ year = new_y, month = new_m, day = target_day, hour = 12 }))
    end
    return from_date_str
  end

  if rule.type == "years" then
    local t = os.time({ year = y + rule.n, month = m, day = d, hour = 12 })
    return os.date("%Y-%m-%d", t)
  end

  return from_date_str
end
```

---

## `:VaultRecurrenceBuild` Command

### Overview

A new command that scans the vault index for all tasks with `repeat_rule` fields, then generates future occurrences for each recurring task within a specified date range. Generated tasks are inserted into daily log files (one per date) or optionally into a single designated file.

### Command Syntax

```
:VaultRecurrenceBuild --from 2026-03-01 --to 2026-03-31
:VaultRecurrenceBuild --from today --to 2026-03-31
:VaultRecurrenceBuild --from 2026-03-01 --to 2026-03-31 --file Projects/recurring-schedule.md
:VaultRecurrenceBuild --from 2026-03-01 --to 2026-03-31 --dry-run
```

| Flag | Required | Default | Description |
|---|---|---|---|
| `--from` | Yes | -- | Start date (YYYY-MM-DD or `today`) |
| `--to` | Yes | -- | End date (YYYY-MM-DD or date keyword) |
| `--file` | No | daily logs | Output to a single file instead of daily logs |
| `--dry-run` | No | false | Preview what would be generated without writing |
| `--heading` | No | `### Recurring Tasks` | Heading under which tasks are inserted in daily logs |

### Implementation

Add a new function `M.build_occurrences()` and command registration to `recurrence.lua`.

#### Command Argument Parsing

```lua
--- Parse --key value pairs from a command argument string.
---@param args string raw argument string
---@return table<string, string|boolean> parsed flags
local function parse_flags(args)
  local flags = {}
  -- Boolean flags (no value)
  for flag in args:gmatch("%-%-(%S+)") do
    if not args:match("%-%-" .. flag .. "%s+[^%-]") then
      flags[flag] = true
    end
  end
  -- Key-value flags
  for key, value in args:gmatch("%-%-(%S+)%s+([^%-]%S*)") do
    flags[key] = value
  end
  return flags
end
```

#### Core Build Logic

```lua
--- Collect all recurring tasks from the vault index.
---@return table[] list of { text, due, repeat_rule, rule, source_path, source_line }
local function collect_recurring_tasks()
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    return {}
  end

  local results = {}
  for rel_path, entry in pairs(idx._entries) do
    if entry.tasks then
      for _, task in ipairs(entry.tasks) do
        if task.repeat_rule and task.repeat_rule ~= "" then
          local rule = M.parse_rule(task.repeat_rule)
          if rule then
            results[#results + 1] = {
              text = task.text,
              due = task.due,
              repeat_rule = task.repeat_rule,
              rule = rule,
              source_path = rel_path,
              source_line = task.line,
              status = task.status,
            }
          end
        end
      end
    end
  end

  return results
end

--- Generate all occurrences of a recurring task within a date range.
---@param task table as returned by collect_recurring_tasks
---@param from_str string YYYY-MM-DD
---@param to_str string YYYY-MM-DD
---@return table[] list of { date = "YYYY-MM-DD", line = "- [ ] ..." }
local function generate_occurrences(task, from_str, to_str)
  local occurrences = {}
  -- Start from the task's current due date, or from_str if no due date
  local current = task.due or from_str
  -- Limit iterations to prevent infinite loops
  local max_iterations = 500

  for _ = 1, max_iterations do
    local next = M.next_date(current, task.rule)
    if next > to_str then
      break
    end
    if next >= from_str then
      -- Build the task line with updated due date
      local line = task.text
      -- Replace existing due date or prepend one
      if line:match("%[due::[^%]]*%]") then
        line = line:gsub("%[due::%s*[^%]]*%]", "[due:: " .. next .. "]")
      else
        line = "[due:: " .. next .. "] " .. line
      end
      -- Ensure it's an unchecked task
      if not line:match("^%s*[-*] %[") then
        line = "- [ ] " .. line
      else
        line = line:gsub("^(%s*[-*] %[)x(%])", "%1 %2")
      end
      -- Remove completion metadata
      line = line:gsub("%s*%[completion::[^%]]*%]", "")

      occurrences[#occurrences + 1] = {
        date = next,
        line = line,
        source = task.source_path,
      }
    end
    current = next
  end

  return occurrences
end
```

#### Deduplication

Before inserting a generated task into a daily log, check if a task with the same text (ignoring metadata fields) already exists in that file.

```lua
--- Normalize task text for deduplication: strip metadata fields, whitespace.
---@param text string
---@return string normalized key
local function normalize_task_key(text)
  local s = text
  -- Strip inline fields: [key:: value] and (key:: value)
  s = s:gsub("%[%w+::[^%]]*%]", "")
  s = s:gsub("%(%w+::[^%)]*%)", "")
  -- Strip checkbox prefix
  s = s:gsub("^%s*[-*] %[.%]%s*", "")
  -- Strip whitespace
  s = vim.trim(s):lower()
  return s
end

--- Check if a task already exists in a file.
---@param filepath string absolute path
---@param task_key string normalized task key
---@return boolean
local function task_exists_in_file(filepath, task_key)
  local f = io.open(filepath, "r")
  if not f then return false end
  for line in f:lines() do
    if line:match("^%s*[-*] %[.%]") then
      if normalize_task_key(line) == task_key then
        f:close()
        return true
      end
    end
  end
  f:close()
  return false
end
```

#### File Insertion

For daily log mode, tasks are inserted under a configurable heading. If the daily log does not exist, it is created.

```lua
--- Insert task lines into a daily log file under a heading.
---@param filepath string absolute path to the daily log
---@param heading string heading text (e.g., "### Recurring Tasks")
---@param lines string[] task lines to insert
local function insert_into_daily_log(filepath, heading, lines)
  local engine_mod = require("andrew.vault.engine")

  if vim.fn.filereadable(filepath) == 0 then
    -- Daily log doesn't exist yet; create it via the template system
    local date = vim.fn.fnamemodify(filepath, ":t:r")
    local daily_template = require("andrew.vault.templates.daily_log")
    local content = daily_template.generate(engine_mod, date)
    local dir = vim.fn.fnamemodify(filepath, ":h")
    engine_mod.ensure_dir(dir)
    local f = io.open(filepath, "w")
    if f then
      f:write(content)
      f:close()
    end
  end

  -- Read existing content
  local existing = {}
  local f = io.open(filepath, "r")
  if f then
    for line in f:lines() do
      existing[#existing + 1] = line
    end
    f:close()
  end

  -- Find the heading, or insert before "---" / "## End of Day" / EOF
  local insert_idx = nil
  for i, line in ipairs(existing) do
    if line == heading then
      -- Find the end of any existing content under this heading
      insert_idx = i + 1
      -- Skip blank line after heading
      if existing[insert_idx] and existing[insert_idx] == "" then
        insert_idx = insert_idx + 1
      end
      -- Skip to end of existing task lines under this heading
      while insert_idx <= #existing
        and existing[insert_idx]
        and existing[insert_idx]:match("^%s*[-*] %[") do
        insert_idx = insert_idx + 1
      end
      break
    end
  end

  if not insert_idx then
    -- Heading doesn't exist; insert before "## End of Day" or append
    local anchor = nil
    for i, line in ipairs(existing) do
      if line:match("^## End of Day") or line:match("^## Scratchpad") then
        anchor = i
        break
      end
    end

    if anchor then
      -- Insert heading + tasks before anchor
      local insert_block = { "", heading, "" }
      for _, task_line in ipairs(lines) do
        insert_block[#insert_block + 1] = task_line
      end
      insert_block[#insert_block + 1] = ""

      for idx = #insert_block, 1, -1 do
        table.insert(existing, anchor, insert_block[idx])
      end
    else
      -- Append at end
      existing[#existing + 1] = ""
      existing[#existing + 1] = heading
      existing[#existing + 1] = ""
      for _, task_line in ipairs(lines) do
        existing[#existing + 1] = task_line
      end
    end
  else
    -- Insert at found position
    for i = #lines, 1, -1 do
      table.insert(existing, insert_idx, lines[i])
    end
  end

  -- Write back
  f = io.open(filepath, "w")
  if f then
    f:write(table.concat(existing, "\n"))
    if existing[#existing] ~= "" then
      f:write("\n")
    end
    f:close()
  end
end
```

#### Single-File Mode

When `--file` is provided, all generated tasks are appended to a single file grouped by date:

```lua
--- Insert all occurrences into a single file, grouped by date.
---@param filepath string absolute path
---@param occurrences_by_date table<string, string[]> date -> task lines
local function insert_into_single_file(filepath, occurrences_by_date)
  local engine_mod = require("andrew.vault.engine")
  local dir = vim.fn.fnamemodify(filepath, ":h")
  engine_mod.ensure_dir(dir)

  local existing = {}
  local f = io.open(filepath, "r")
  if f then
    for line in f:lines() do
      existing[#existing + 1] = line
    end
    f:close()
  end

  -- Read existing task keys for deduplication
  local existing_keys = {}
  for _, line in ipairs(existing) do
    if line:match("^%s*[-*] %[.%]") then
      existing_keys[normalize_task_key(line)] = true
    end
  end

  -- Sort dates
  local dates = {}
  for date in pairs(occurrences_by_date) do
    dates[#dates + 1] = date
  end
  table.sort(dates)

  -- Append
  local new_lines = {}
  local total = 0
  for _, date in ipairs(dates) do
    local tasks = occurrences_by_date[date]
    local filtered = {}
    for _, line in ipairs(tasks) do
      if not existing_keys[normalize_task_key(line)] then
        filtered[#filtered + 1] = line
        total = total + 1
      end
    end
    if #filtered > 0 then
      new_lines[#new_lines + 1] = ""
      new_lines[#new_lines + 1] = "### " .. date
      new_lines[#new_lines + 1] = ""
      for _, line in ipairs(filtered) do
        new_lines[#new_lines + 1] = line
      end
    end
  end

  if total == 0 then
    return 0
  end

  f = io.open(filepath, "a")
  if f then
    f:write(table.concat(new_lines, "\n"))
    f:write("\n")
    f:close()
  end

  return total
end
```

#### Main Build Function

```lua
--- Build recurring task occurrences for a date range.
---@param opts table { from, to, file?, dry_run?, heading? }
function M.build_occurrences(opts)
  local from_str = date_utils.resolve_date_string(opts.from) or opts.from
  local to_str = date_utils.resolve_date_string(opts.to) or opts.to

  -- Validate dates
  if not from_str or not from_str:match("^%d%d%d%d%-%d%d%-%d%d$") then
    vim.notify("VaultRecurrenceBuild: invalid --from date: " .. tostring(opts.from),
      vim.log.levels.ERROR)
    return
  end
  if not to_str or not to_str:match("^%d%d%d%d%-%d%d%-%d%d$") then
    vim.notify("VaultRecurrenceBuild: invalid --to date: " .. tostring(opts.to),
      vim.log.levels.ERROR)
    return
  end
  if from_str > to_str then
    vim.notify("VaultRecurrenceBuild: --from must be before --to", vim.log.levels.ERROR)
    return
  end

  local recurring_tasks = collect_recurring_tasks()
  if #recurring_tasks == 0 then
    vim.notify("VaultRecurrenceBuild: no recurring tasks found in vault index",
      vim.log.levels.WARN)
    return
  end

  -- Generate all occurrences across all recurring tasks
  local by_date = {}  -- date -> { lines }
  local total = 0
  for _, task in ipairs(recurring_tasks) do
    local occs = generate_occurrences(task, from_str, to_str)
    for _, occ in ipairs(occs) do
      if not by_date[occ.date] then
        by_date[occ.date] = {}
      end
      by_date[occ.date][#by_date[occ.date] + 1] = occ.line
      total = total + 1
    end
  end

  if total == 0 then
    vim.notify("VaultRecurrenceBuild: no occurrences in range " ..
      from_str .. " to " .. to_str, vim.log.levels.INFO)
    return
  end

  -- Dry run: just report
  if opts.dry_run then
    local dates = {}
    for date in pairs(by_date) do
      dates[#dates + 1] = date
    end
    table.sort(dates)

    local report = { "VaultRecurrenceBuild dry run: " .. total .. " occurrences", "" }
    for _, date in ipairs(dates) do
      report[#report + 1] = "  " .. date .. ":"
      for _, line in ipairs(by_date[date]) do
        report[#report + 1] = "    " .. line
      end
    end
    vim.notify(table.concat(report, "\n"), vim.log.levels.INFO)
    return
  end

  local heading = opts.heading or "### Recurring Tasks"

  if opts.file then
    -- Single-file mode
    local filepath = engine.vault_path .. "/" .. opts.file
    if not filepath:match("%.md$") then
      filepath = filepath .. ".md"
    end
    local count = insert_into_single_file(filepath, by_date)
    vim.notify("VaultRecurrenceBuild: inserted " .. count .. " tasks into " .. opts.file,
      vim.log.levels.INFO)
  else
    -- Daily log mode
    local config = require("andrew.vault.config")
    local log_dir = engine.vault_path .. "/" .. config.dirs.log
    local inserted = 0

    local dates = {}
    for date in pairs(by_date) do
      dates[#dates + 1] = date
    end
    table.sort(dates)

    for _, date in ipairs(dates) do
      local filepath = log_dir .. "/" .. date .. ".md"
      local tasks_for_date = by_date[date]

      -- Deduplicate against existing file
      local filtered = {}
      for _, line in ipairs(tasks_for_date) do
        local key = normalize_task_key(line)
        if not task_exists_in_file(filepath, key) then
          filtered[#filtered + 1] = line
        end
      end

      if #filtered > 0 then
        insert_into_daily_log(filepath, heading, filtered)
        inserted = inserted + #filtered
      end
    end

    vim.notify("VaultRecurrenceBuild: inserted " .. inserted .. " tasks across " ..
      #dates .. " daily logs", vim.log.levels.INFO)
  end
end
```

#### Command Registration

Add to the existing setup or create a new `M.setup()`:

```lua
function M.setup()
  vim.api.nvim_create_user_command("VaultRecurrenceBuild", function(cmd_opts)
    local flags = parse_flags(cmd_opts.args)
    M.build_occurrences({
      from = flags.from,
      to = flags.to,
      file = flags.file,
      dry_run = flags["dry-run"] or false,
      heading = flags.heading,
    })
  end, {
    nargs = "+",
    desc = "Generate recurring task occurrences for a date range",
    complete = function(_, line, _)
      -- Offer flag completions
      local flags = { "--from", "--to", "--file", "--dry-run", "--heading" }
      local completions = {}
      for _, f in ipairs(flags) do
        if not line:match(vim.pesc(f)) then
          completions[#completions + 1] = f
        end
      end
      return completions
    end,
  })

  -- Register in command palette if available
  local ok, palette = pcall(require, "andrew.vault.command_palette")
  if ok then
    palette.register({
      name = "Recurrence: Build occurrences",
      command = "VaultRecurrenceBuild",
      category = "tasks",
    })
  end
end
```

---

## Test Cases

### `parse_rule()` Tests

```lua
-- Existing patterns (regression tests)
assert_eq(M.parse_rule("every day"),       { type = "days", n = 1 })
assert_eq(M.parse_rule("every weekday"),   { type = "weekday", n = 1 })
assert_eq(M.parse_rule("every week"),      { type = "days", n = 7 })
assert_eq(M.parse_rule("every 2 weeks"),   { type = "days", n = 14 })
assert_eq(M.parse_rule("every 3 weeks"),   { type = "days", n = 21 })
assert_eq(M.parse_rule("every month"),     { type = "months", n = 1 })
assert_eq(M.parse_rule("every month on the 15th"), { type = "monthly_on", n = 1, day = 15 })
assert_eq(M.parse_rule("every quarter"),   { type = "months", n = 3 })
assert_eq(M.parse_rule("every year"),      { type = "years", n = 1 })
assert_eq(M.parse_rule("every 10 days"),   { type = "days", n = 10 })

-- New: "every other" patterns
assert_eq(M.parse_rule("every other day"),   { type = "days", n = 2 })
assert_eq(M.parse_rule("every other week"),  { type = "days", n = 14 })
assert_eq(M.parse_rule("every other month"), { type = "months", n = 2 })

-- New: "every N months"
assert_eq(M.parse_rule("every 2 months"),  { type = "months", n = 2 })
assert_eq(M.parse_rule("every 6 months"),  { type = "months", n = 6 })

-- New: "every N months on the Nth"
assert_eq(M.parse_rule("every 2 months on the 15th"), { type = "monthly_on", n = 2, day = 15 })
assert_eq(M.parse_rule("every 3 months on the 1st"),  { type = "monthly_on", n = 3, day = 1 })

-- New: weekly_on with single day
assert_eq(M.parse_rule("every week on Monday"),
  { type = "weekly_on", n = 1, weekdays = { 1 } })
assert_eq(M.parse_rule("every 2 weeks on Monday"),
  { type = "weekly_on", n = 2, weekdays = { 1 } })
assert_eq(M.parse_rule("every other week on Tuesday"),
  { type = "weekly_on", n = 2, weekdays = { 2 } })

-- New: weekly_on with multiple days
assert_eq(M.parse_rule("every 2 weeks on Monday, Wednesday"),
  { type = "weekly_on", n = 2, weekdays = { 1, 3 } })
assert_eq(M.parse_rule("every week on Mon, Wed, Fri"),
  { type = "weekly_on", n = 1, weekdays = { 1, 3, 5 } })

-- New: monthly_ordinal
assert_eq(M.parse_rule("every month on the first Monday"),
  { type = "monthly_ordinal", n = 1, ordinal = 1, weekday = 1 })
assert_eq(M.parse_rule("every month on the last Friday"),
  { type = "monthly_ordinal", n = 1, ordinal = -1, weekday = 5 })
assert_eq(M.parse_rule("every month on the third Wednesday"),
  { type = "monthly_ordinal", n = 1, ordinal = 3, weekday = 3 })
assert_eq(M.parse_rule("every 2 months on the first Monday"),
  { type = "monthly_ordinal", n = 2, ordinal = 1, weekday = 1 })
assert_eq(M.parse_rule("every other month on the last Friday"),
  { type = "monthly_ordinal", n = 2, ordinal = -1, weekday = 5 })

-- Abbreviations
assert_eq(M.parse_rule("every week on mon"),
  { type = "weekly_on", n = 1, weekdays = { 1 } })
assert_eq(M.parse_rule("every month on the first fri"),
  { type = "monthly_ordinal", n = 1, ordinal = 1, weekday = 5 })

-- Case insensitivity
assert_eq(M.parse_rule("Every Other Week On Monday"),
  { type = "weekly_on", n = 2, weekdays = { 1 } })
assert_eq(M.parse_rule("EVERY MONTH ON THE FIRST MONDAY"),
  { type = "monthly_ordinal", n = 1, ordinal = 1, weekday = 1 })

-- Invalid patterns return nil
assert_eq(M.parse_rule("every blorp"),     nil)
assert_eq(M.parse_rule("every week on Flurpsday"), nil)
assert_eq(M.parse_rule("every month on the fifth Monday"), nil)  -- "fifth" not in ORDINAL_WORDS
assert_eq(M.parse_rule(""), nil)
assert_eq(M.parse_rule(nil), nil)
```

### `next_date()` Tests

```lua
-- Existing: days
assert_eq(M.next_date("2026-03-01", { type = "days", n = 1 }),  "2026-03-02")
assert_eq(M.next_date("2026-03-01", { type = "days", n = 14 }), "2026-03-15")
assert_eq(M.next_date("2026-03-01", { type = "days", n = 2 }),  "2026-03-03") -- every other day

-- Existing: weekday
assert_eq(M.next_date("2026-03-06", { type = "weekday", n = 1 }), "2026-03-09") -- Fri -> Mon
assert_eq(M.next_date("2026-03-04", { type = "weekday", n = 1 }), "2026-03-05") -- Wed -> Thu

-- Existing: months
assert_eq(M.next_date("2026-03-15", { type = "months", n = 2 }), "2026-05-15") -- every other month

-- New: weekly_on (single day)
-- 2026-03-02 is Monday. "every 2 weeks on Wednesday" -> 2026-03-04 (same cycle, later day)
assert_eq(M.next_date("2026-03-02",
  { type = "weekly_on", n = 2, weekdays = { 3 } }), "2026-03-04")

-- 2026-03-04 is Wednesday. "every 2 weeks on Monday" -> 2026-03-16 (next cycle)
assert_eq(M.next_date("2026-03-04",
  { type = "weekly_on", n = 2, weekdays = { 1 } }), "2026-03-16")

-- 2026-03-02 is Monday. "every 1 week on Monday" -> 2026-03-09 (next cycle, same day)
assert_eq(M.next_date("2026-03-02",
  { type = "weekly_on", n = 1, weekdays = { 1 } }), "2026-03-09")

-- New: weekly_on (multiple days)
-- 2026-03-02 is Monday. "every 2 weeks on Mon, Wed" -> 2026-03-04 (Wed same cycle)
assert_eq(M.next_date("2026-03-02",
  { type = "weekly_on", n = 2, weekdays = { 1, 3 } }), "2026-03-04")

-- 2026-03-04 is Wednesday. "every 2 weeks on Mon, Wed" -> 2026-03-16 (Mon next cycle)
assert_eq(M.next_date("2026-03-04",
  { type = "weekly_on", n = 2, weekdays = { 1, 3 } }), "2026-03-16")

-- New: monthly_ordinal
-- 2026-03-01. "every month on the first Monday" -> April 6, 2026
-- (April 2026: 1st is Wed, so first Mon is Apr 6)
assert_eq(M.next_date("2026-03-01",
  { type = "monthly_ordinal", n = 1, ordinal = 1, weekday = 1 }), "2026-04-06")

-- 2026-03-01. "every month on the last Friday" -> April 24, 2026
-- (April 2026: last Friday is Apr 24)
assert_eq(M.next_date("2026-03-01",
  { type = "monthly_ordinal", n = 1, ordinal = -1, weekday = 5 }), "2026-04-24")

-- 2026-03-01. "every 2 months on the third Wednesday" -> May 20, 2026
-- (May 2026: 1st is Fri, first Wed is May 6, second May 13, third May 20)
assert_eq(M.next_date("2026-03-01",
  { type = "monthly_ordinal", n = 2, ordinal = 3, weekday = 3 }), "2026-05-20")

-- New: monthly_on with n > 1
-- 2026-03-15. "every 2 months on the 15th" -> 2026-05-15
assert_eq(M.next_date("2026-03-15",
  { type = "monthly_on", n = 2, day = 15 }), "2026-05-15")
```

### `build_occurrences()` Tests

These are integration-level tests that require a vault index with recurring tasks. They should be tested manually or via a test harness that populates a mock index.

```lua
-- Scenario: Task with [repeat:: every week] [due:: 2026-03-02]
-- Build from 2026-03-01 to 2026-03-31
-- Expected: occurrences on 2026-03-09, 2026-03-16, 2026-03-23, 2026-03-30

-- Scenario: Task with [repeat:: every 2 weeks on Monday, Wednesday]
--           [due:: 2026-03-02]
-- Build from 2026-03-01 to 2026-03-31
-- Expected: 2026-03-04 (Wed same cycle), 2026-03-16 (Mon next cycle),
--           2026-03-18 (Wed same cycle), 2026-03-30 (Mon next cycle)

-- Scenario: Task with [repeat:: every month on the first Monday]
--           [due:: 2026-02-01]
-- Build from 2026-03-01 to 2026-05-31
-- Expected: 2026-03-02, 2026-04-06, 2026-05-04

-- Deduplication: Run build twice for the same range; second run inserts 0 tasks.
```

---

## Edge Cases

### Month Boundary Overflow

Lua's `os.time` normalizes date overflow. For example:

- `os.time({ year = 2026, month = 13, day = 1 })` resolves to January 1, 2027
- `os.time({ year = 2026, month = 2, day = 30 })` resolves to March 2, 2026

This means "every month" starting from January 31 produces: Jan 31 -> Mar 3 (Feb has 28 days, so Feb 31 normalizes to Mar 3). This is the **existing behavior** and is preserved. Users who want "last day of the month" should use "every month on the last day" (a future enhancement) or "every month on the 28th" as an approximation.

### Leap Years

`os.time` handles leap years correctly. February 29 in a leap year normalizes naturally:

- `next_date("2028-02-29", { type = "months", n = 1 })` produces `"2028-03-29"` (March has 29 days)
- `next_date("2028-02-29", { type = "years", n = 1 })` produces `"2029-03-01"` (Feb 29 in non-leap year overflows to Mar 1)

### `monthly_ordinal` Edge: Fifth Occurrence

Some months have a fifth Monday, Friday, etc. Since `ORDINAL_WORDS` only includes `first` through `fourth` and `last`, "fifth" is intentionally unsupported. If a user needs it, they should use the `last` keyword when it coincides, or extend `ORDINAL_WORDS` in a future iteration.

The `nth_weekday_of_month` helper returns `nil` when the requested ordinal does not exist in the target month. In `next_date()`, this triggers a fallback to the following month. This handles the rare case where `monthly_ordinal` with `ordinal = 4` lands in a month with only 4 occurrences of that weekday --- the function succeeds. If `ordinal = 4` and the month has only 3 occurrences, it would skip to the next month. However, every month has at least 4 of every weekday (28 days minimum), so `ordinal = 4` always succeeds. This fallback exists purely for defensive coding.

### `weekly_on` Edge: From Date IS a Target Weekday

When the from-date falls on one of the target weekdays (e.g., "every 2 weeks on Monday" with `from = Monday`), the algorithm correctly advances to the **next** matching day. This is because the check `wd > current_iso` uses strict greater-than, ensuring same-day is never returned as the next occurrence.

### `weekly_on` Edge: Sunday Handling

ISO weekday 7 = Sunday. Since the algorithm counts days since Monday (ISO 1), Sunday is 6 days from Monday. A rule like "every 2 weeks on Sunday" produces `weekdays = { 7 }`. The `days_since_monday` for Sunday is `7 - 1 = 6`, and `days_to_next_monday = 2 * 7 - 6 = 8`. Then `days_from_monday = 7 - 1 = 6`, totaling 14 days forward, which is correct (next cycle's Sunday = 14 days later).

### `generate_occurrences` Iteration Limit

The 500-iteration cap prevents runaway loops from rules like "every day" over a long date range. For a daily task across 365 days, 365 iterations are needed. The cap of 500 covers over a year of daily tasks. For longer ranges, the cap should be increased proportionally, or made configurable.

### Deduplication Across Builds

The `normalize_task_key` approach strips all metadata fields before comparing. This means two tasks with the same descriptive text but different due dates are considered duplicates. This is intentional: the same recurring task should not appear twice on the same day regardless of when it was generated. However, two distinct recurring tasks with identical descriptive text will collide. This is an acceptable trade-off; users can differentiate them by adding distinguishing text.

### Empty Vault Index

If the vault index is not ready (e.g., first launch before build completes), `collect_recurring_tasks()` returns an empty list and the command notifies the user. No data loss occurs.

---

## Files Modified

| File | Change |
|---|---|
| `lua/andrew/vault/recurrence.lua` | Add lookup tables, helpers, extended `parse_rule()`, extended `next_date()`, `build_occurrences()`, `setup()` with `:VaultRecurrenceBuild` command |
| `lua/andrew/vault/config.lua` | (Optional) Add `M.recurrence` config section for build defaults |
| `lua/andrew/vault/init.lua` or plugin loader | Call `recurrence.setup()` during vault initialization |

### Optional Config Addition

```lua
-- In config.lua
M.recurrence = {
  -- Default heading for bulk-generated recurring tasks in daily logs.
  build_heading = "### Recurring Tasks",

  -- Maximum iterations per task when generating occurrences (safety limit).
  max_iterations = 500,
}
```

---

## Summary of New Exports

```lua
-- recurrence.lua public API after this change:

M.parse_rule(rule_str)         -- Extended with new patterns
M.next_date(from_date_str, rule) -- Extended with weekly_on, monthly_ordinal
M.handle_recurrence(line_nr)    -- Unchanged
M.build_occurrences(opts)       -- NEW: bulk generation
M.setup()                       -- NEW: command registration
```
