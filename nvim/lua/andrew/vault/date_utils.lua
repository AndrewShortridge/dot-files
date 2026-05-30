--- Shared date utility functions for vault modules.
---
--- Provides date resolution (keywords, relative dates, absolute dates),
--- ISO datetime parsing, and comparison helpers. Used by search_filter.lua
--- and graph_filter.lua to avoid duplicating date logic.

local M = {}

local lru = require("andrew.vault.lru_cache")
local pat = require("andrew.vault.patterns")
local config = require("andrew.vault.config")

--- Seconds in one day.
M.SECS_PER_DAY = 86400

--- Static lookup for days per month (non-leap year).
M.DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

--- Check if a year is a leap year.
---@param year number
---@return boolean
function M.is_leap_year(year)
  return (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
end

--- Number of days in a given month/year.
---@param year number
---@param month number 1-12
---@return number
function M.days_in_month(year, month)
  if month == 2 then
    return M.is_leap_year(year) and 29 or 28
  end
  return M.DAYS_IN_MONTH[month]
end

--- Weekday of the first day of a month (1=Mon, 7=Sun, ISO style).
---@param year number
---@param month number 1-12
---@return number 1-7 (Mon-Sun)
function M.first_weekday(year, month)
  local t = os.time({ year = year, month = month, day = 1 })
  local wday = tonumber(os.date("%w", t)) -- 0=Sun, 1=Mon, ..., 6=Sat
  -- Convert to ISO: Mon=1 .. Sun=7
  if wday == 0 then
    return 7
  end
  return wday
end

--- Format a date as YYYY-MM-DD with zero-padding.
---@param year number
---@param month number
---@param day number
---@return string
function M.format_date(year, month, day)
  return string.format("%04d-%02d-%02d", year, month, day)
end

--- Compute days since Monday for a Lua os.date wday value (1=Sun..7=Sat).
--- Returns 0 for Monday, 1 for Tuesday, ..., 6 for Sunday.
--- Uses ISO week convention where Monday is the first day of the week.
---@param wday number os.date("*t").wday (1=Sunday, 2=Monday, ..., 7=Saturday)
---@return number days since Monday (0-6)
function M.days_since_monday(wday)
  return (wday - 2) % 7
end

--- Get the start-of-day timestamp (00:00:00 local time) for a date table.
---@param t table os.date("*t")-compatible table
---@return number
function M.start_of_day(t)
  return os.time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 })
end

--- Check if two timestamps fall on the same calendar day (local time).
---@param ts number first timestamp
---@param ref number second timestamp
---@return boolean
function M.same_day(ts, ref)
  local a = os.date("*t", ts)
  local b = os.date("*t", ref)
  return a.year == b.year and a.month == b.month and a.day == b.day
end

--- Parse an ISO datetime string into a Unix timestamp.
--- Handles "YYYY-MM-DDTHH:MM:SS" and "YYYY-MM-DD".
---@param s string|nil
---@param default_hour number|nil hour to use when time is absent (default 0)
---@return number|nil
local _parse_cache = lru.new(config.cache.date_parse_max)

function M.parse_iso_datetime(s, default_hour)
  if not s or type(s) ~= "string" then return nil end
  default_hour = default_hour or 0

  local cache_key = default_hour == 0 and s or s .. "\0" .. default_hour
  local cached = _parse_cache:get(cache_key)
  if cached then return cached end

  local ts

  -- Full: YYYY-MM-DDTHH:MM:SS
  local y, m, d, h, mi, se = s:match(pat.ISO_DATETIME_FULL)
  if y then
    ts = os.time({
      year = tonumber(y), month = tonumber(m), day = tonumber(d),
      hour = tonumber(h), min = tonumber(mi), sec = tonumber(se),
    })
  else
    -- Date only: YYYY-MM-DD
    y, m, d = s:match(pat.ISO_DATETIME_SHORT)
    if y then
      ts = os.time({
        year = tonumber(y), month = tonumber(m), day = tonumber(d),
        hour = default_hour, min = 0, sec = 0,
      })
    end
  end

  if ts then
    _parse_cache:put(cache_key, ts)
  end

  return ts
end

--- Check if a string matches YYYY-MM-DD format.
---@param s string|nil
---@return boolean
function M.is_iso_date(s)
  if not s or type(s) ~= "string" then return false end
  return s:match(pat.ISO_DATE) ~= nil
end

--- Resolve a date value string into a Unix timestamp.
---
--- Supported formats:
---   - Relative: "7d", "30d" (days ago from now)
---   - Keywords: "today", "yesterday"
---   - Range keywords: "this-week", "last-week", "previous-week",
---     "this-month", "last-month", "previous-month"
---   - Absolute: "2026-01-15" (specific date)
---   - Partial:  "2026-01" (first of month)
---
--- For range keywords, this returns the START of the range.
--- Use resolve_date_range() to get both start and end for = comparisons.
---
---@param value string|nil the date value to resolve
---@return number|nil timestamp, or nil for unrecognized formats
function M.resolve_date(value)
  if not value or value == "" then return nil end
  local lower = value:lower()

  -- Relative: Nd (start of day N days ago)
  local n = lower:match(pat.RELATIVE_DURATION)
  if n then
    local t = os.date("*t")
    t.day = t.day - tonumber(n)
    return M.start_of_day(t)
  end

  -- Keywords
  if lower == "today" then
    return M.start_of_day(os.date("*t"))
  end

  if lower == "yesterday" then
    local t = os.date("*t")
    t.day = t.day - 1
    return M.start_of_day(t)
  end

  if lower == "this-week" then
    local t = os.date("*t")
    t.day = t.day - M.days_since_monday(t.wday)
    return M.start_of_day(t)
  end

  if lower == "last-week" or lower == "previous-week" then
    local t = os.date("*t")
    t.day = t.day - M.days_since_monday(t.wday) - 7
    return M.start_of_day(t)
  end

  if lower == "this-month" then
    local t = os.date("*t")
    t.day = 1
    return M.start_of_day(t)
  end

  if lower == "last-month" or lower == "previous-month" then
    local t = os.date("*t")
    t.day = 1
    t.month = t.month - 1
    return M.start_of_day(t)
  end

  -- Absolute: YYYY-MM-DD
  local y, m, d = value:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if y then
    return os.time({
      year = tonumber(y), month = tonumber(m), day = tonumber(d),
      hour = 0, min = 0, sec = 0,
    })
  end

  -- Partial: YYYY-MM (first of month)
  local ym, mm = value:match("^(%d%d%d%d)-(%d%d)$")
  if ym then
    return os.time({
      year = tonumber(ym), month = tonumber(mm), day = 1,
      hour = 0, min = 0, sec = 0,
    })
  end

  return nil
end

--- Check if a date value is a relative duration pattern (e.g. "7d", "30d").
--- Used to determine when comparison operators should be inverted so that
--- "modified:<7d" means "modified less than 7 days ago" (within last 7 days).
---@param value string
---@return boolean
function M.is_relative_duration(value)
  if not value then return false end
  return value:lower():match("^%d+d$") ~= nil
end

--- Resolve a date value that represents a multi-day range.
--- Returns (start_ts, end_ts) where start is inclusive and end is exclusive.
--- Returns nil for single-day values (use resolve_date + same_day instead).
---@param value string|nil
---@return number|nil start_ts
---@return number|nil end_ts
local function resolve_date_range(value)
  if not value or value == "" then return nil end
  local lower = value:lower()

  -- last-Nd (e.g. last-7d, last-30d): from N days ago to end of today
  local n = lower:match("^last%-(%d+)d$")
  if n then
    local t = os.date("*t")
    t.day = t.day - tonumber(n)
    local start_ts = M.start_of_day(t)
    local t2 = os.date("*t")
    t2.day = t2.day + 1
    local end_ts = M.start_of_day(t2)
    return start_ts, end_ts
  end

  if lower == "this-week" then
    local t = os.date("*t")
    t.day = t.day - M.days_since_monday(t.wday)
    local start_ts = M.start_of_day(t)
    t.day = t.day + 7
    local end_ts = M.start_of_day(t)
    return start_ts, end_ts
  end

  if lower == "last-week" or lower == "previous-week" then
    local t = os.date("*t")
    t.day = t.day - M.days_since_monday(t.wday)
    local this_monday = M.start_of_day(t)
    t.day = t.day - 7
    local last_monday = M.start_of_day(t)
    return last_monday, this_monday
  end

  if lower == "this-month" then
    local t = os.date("*t")
    t.day = 1
    local start_ts = M.start_of_day(t)
    t.month = t.month + 1
    local end_ts = M.start_of_day(t)
    return start_ts, end_ts
  end

  if lower == "last-month" or lower == "previous-month" then
    local t = os.date("*t")
    t.day = 1
    local this_month = M.start_of_day(t)
    t.month = t.month - 1
    local last_month = M.start_of_day(t)
    return last_month, this_month
  end

  return nil
end

--- Resolve a date keyword to a YYYY-MM-DD date string.
--- Convenience wrapper around resolve_date() for modules that work with
--- date strings rather than timestamps.
---@param value string|nil the date value to resolve
---@return string|nil date string in "YYYY-MM-DD" format, or nil
function M.resolve_date_string(value)
  local ts = M.resolve_date(value)
  if not ts then return nil end
  return os.date("%Y-%m-%d", ts)
end

--- Calculate the number of days between two YYYY-MM-DD date strings.
---@param from_str string
---@param to_str string
---@return number days (positive if to > from)
function M.days_between(from_str, to_str)
  local fy, fm, fd = from_str:match(pat.ISO_DATE_PARTS)
  local ty, tm, td = to_str:match(pat.ISO_DATE_PARTS)
  if not fy or not ty then return 0 end
  local from_ts = os.time({ year = tonumber(fy), month = tonumber(fm), day = tonumber(fd), hour = 12 })
  local to_ts = os.time({ year = tonumber(ty), month = tonumber(tm), day = tonumber(td), hour = 12 })
  return math.floor((to_ts - from_ts) / M.SECS_PER_DAY)
end

--- Add N days to a YYYY-MM-DD date string, return new YYYY-MM-DD string.
---@param date_str string
---@param days number
---@return string
function M.date_add(date_str, days)
  local y, m, d = date_str:match(pat.ISO_DATE_PARTS)
  if not y then return date_str end
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  t = t + days * M.SECS_PER_DAY
  return os.date("%Y-%m-%d", t)
end

--- Format "YYYY-MM-DD" as "Mon DD" (e.g., "Mar 01").
---@param date_str string
---@return string
function M.format_date_short(date_str)
  local y, m, d = date_str:match(pat.ISO_DATE_PARTS)
  if not y then return date_str end
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  return os.date("%b %d", t)
end

--- Truncate a string to max characters, appending ellipsis if truncated.
---@param s string|nil
---@param max number
---@return string
function M.truncate(s, max)
  if not s then return "" end
  if #s <= max then return s end
  return s:sub(1, max - 1) .. "…"
end

--- Check if a timestamp falls within a normalized date range.
--- Automatically swaps lo/hi if reversed (e.g., when relative durations
--- produce inverted bounds like 7d..30d).
--- Upper bound is exclusive with +86400 to include the full endpoint day.
---@param ts number entry timestamp
---@param lo number range lower bound (start of day)
---@param hi number range upper bound (start of day)
---@return boolean
function M.in_date_range(ts, lo, hi)
  if lo > hi then lo, hi = hi, lo end
  return ts >= lo and ts < hi + M.SECS_PER_DAY
end

--- Check if a timestamp falls within a keyword date range
--- (this-week, last-month, last-7d, etc.).
--- Returns nil if the value is not a recognized range keyword.
---@param ts number entry timestamp
---@param value string raw filter value
---@return boolean|nil true/false if matched, nil if not a range keyword
function M.in_keyword_range(ts, value)
  local range_start, range_end = resolve_date_range(value)
  if not range_start then return nil end
  return ts >= range_start and ts < range_end
end

return M
