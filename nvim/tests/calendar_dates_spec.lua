-- Unit tests for lua/andrew/vault/date_utils.lua (pure date helpers)
-- Run with: nvim --headless -u NONE -l tests/calendar_dates_spec.lua
--
-- NOTE on scope: calendar.lua's own date-bucketing/per-day-dedup helpers
-- (scan_single_file_dates, indicators_for_month, day_at_cursor) are all
-- `local function` and depend on vault_index/engine — they are NOT exported
-- and NOT pure, so they cannot be reliably tested under `-u NONE`. Per the
-- issue's substitution rule, this spec targets date_utils.lua, which provides
-- the pure date-resolution/comparison primitives the calendar relies on.

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_false, _H.assert_nil

-- ============================================================================
-- Load module under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local du = require("andrew.vault.date_utils")

-- Build a timestamp for an absolute local date (noon, to avoid DST edges).
local function ts_for(y, m, d, hour)
  return os.time({ year = y, month = m, day = d, hour = hour or 12, min = 0, sec = 0 })
end

-- ============================================================================
-- Tests
-- ============================================================================

print("\n=== date_utils Tests ===\n")

-- ---------------------------------------------------------------------------
-- 1. is_leap_year / days_in_month
-- ---------------------------------------------------------------------------
test("is_leap_year for divisible-by-4 non-century", function()
  assert_true(du.is_leap_year(2024))
  assert_false(du.is_leap_year(2023))
end)

test("is_leap_year century rule", function()
  assert_false(du.is_leap_year(1900))
  assert_true(du.is_leap_year(2000))
end)

test("days_in_month handles February leap/non-leap", function()
  assert_eq(du.days_in_month(2024, 2), 29)
  assert_eq(du.days_in_month(2023, 2), 28)
end)

test("days_in_month for 30/31-day months", function()
  assert_eq(du.days_in_month(2026, 1), 31)
  assert_eq(du.days_in_month(2026, 4), 30)
end)

-- ---------------------------------------------------------------------------
-- 2. format_date
-- ---------------------------------------------------------------------------
test("format_date zero-pads to YYYY-MM-DD", function()
  assert_eq(du.format_date(2026, 1, 5), "2026-01-05")
end)

-- ---------------------------------------------------------------------------
-- 3. days_since_monday (ISO week bucketing)
-- ---------------------------------------------------------------------------
test("days_since_monday: Monday is 0", function()
  -- os.date wday: 1=Sun..7=Sat, so Monday=2 -> 0
  assert_eq(du.days_since_monday(2), 0)
end)

test("days_since_monday: Sunday is 6", function()
  assert_eq(du.days_since_monday(1), 6)
end)

test("days_since_monday: Saturday is 5", function()
  assert_eq(du.days_since_monday(7), 5)
end)

-- ---------------------------------------------------------------------------
-- 4. start_of_day / same_day (per-day bucketing primitives)
-- ---------------------------------------------------------------------------
test("start_of_day returns midnight of the given date", function()
  local t = { year = 2026, month = 6, day = 9 }
  local sod = du.start_of_day(t)
  local back = os.date("*t", sod)
  assert_eq(back.year, 2026)
  assert_eq(back.month, 6)
  assert_eq(back.day, 9)
  assert_eq(back.hour, 0)
  assert_eq(back.min, 0)
  assert_eq(back.sec, 0)
end)

test("same_day true for two times on the same calendar day", function()
  local morning = ts_for(2026, 6, 9, 8)
  local evening = ts_for(2026, 6, 9, 22)
  assert_true(du.same_day(morning, evening))
end)

test("same_day false across adjacent days", function()
  local a = ts_for(2026, 6, 9, 23)
  local b = ts_for(2026, 6, 10, 1)
  assert_false(du.same_day(a, b))
end)

-- ---------------------------------------------------------------------------
-- 5. is_iso_date
-- ---------------------------------------------------------------------------
test("is_iso_date true for YYYY-MM-DD", function()
  assert_true(du.is_iso_date("2026-06-09"))
end)

test("is_iso_date false for non-date strings", function()
  assert_false(du.is_iso_date("today"))
  assert_false(du.is_iso_date("2026/06/09"))
  assert_false(du.is_iso_date(nil))
end)

-- ---------------------------------------------------------------------------
-- 6. resolve_date / resolve_date_string
-- ---------------------------------------------------------------------------
test("resolve_date for absolute date returns midnight timestamp", function()
  local ts = du.resolve_date("2026-06-09")
  assert_eq(ts, ts_for(2026, 6, 9, 0))
end)

test("resolve_date 'today' equals start of today", function()
  local ts = du.resolve_date("today")
  assert_eq(ts, du.start_of_day(os.date("*t")))
end)

test("resolve_date returns nil for empty/unrecognized", function()
  assert_nil(du.resolve_date(""))
  assert_nil(du.resolve_date(nil))
  assert_nil(du.resolve_date("not-a-date"))
end)

test("resolve_date_string round-trips an absolute date", function()
  assert_eq(du.resolve_date_string("2026-06-09"), "2026-06-09")
end)

-- ---------------------------------------------------------------------------
-- 7. days_between / date_add
-- ---------------------------------------------------------------------------
test("days_between counts forward days", function()
  assert_eq(du.days_between("2026-06-09", "2026-06-12"), 3)
end)

test("days_between is negative when going backward", function()
  assert_eq(du.days_between("2026-06-12", "2026-06-09"), -3)
end)

test("date_add advances across a month boundary", function()
  assert_eq(du.date_add("2026-01-30", 3), "2026-02-02")
end)

-- ---------------------------------------------------------------------------
-- 8. in_date_range (inclusive lo, full endpoint day)
-- ---------------------------------------------------------------------------
test("in_date_range includes endpoints (full upper day)", function()
  local lo = ts_for(2026, 6, 1, 0)
  local hi = ts_for(2026, 6, 30, 0)
  assert_true(du.in_date_range(ts_for(2026, 6, 1, 0), lo, hi))
  assert_true(du.in_date_range(ts_for(2026, 6, 30, 23), lo, hi))
end)

test("in_date_range excludes out-of-range timestamps", function()
  local lo = ts_for(2026, 6, 1, 0)
  local hi = ts_for(2026, 6, 30, 0)
  assert_false(du.in_date_range(ts_for(2026, 5, 31, 12), lo, hi))
  assert_false(du.in_date_range(ts_for(2026, 7, 1, 12), lo, hi))
end)

test("in_date_range swaps reversed bounds", function()
  local lo = ts_for(2026, 6, 1, 0)
  local hi = ts_for(2026, 6, 30, 0)
  -- Pass bounds reversed; should still match a mid-range date.
  assert_true(du.in_date_range(ts_for(2026, 6, 15, 12), hi, lo))
end)

-- ---------------------------------------------------------------------------
-- 9. is_relative_duration
-- ---------------------------------------------------------------------------
test("is_relative_duration true for Nd pattern", function()
  assert_true(du.is_relative_duration("7d"))
  assert_true(du.is_relative_duration("30d"))
end)

test("is_relative_duration false otherwise", function()
  assert_false(du.is_relative_duration("today"))
  assert_false(du.is_relative_duration("2026-06-09"))
  assert_false(du.is_relative_duration(nil))
end)

-- ---------------------------------------------------------------------------
-- 10. parse_iso_datetime
-- ---------------------------------------------------------------------------
test("parse_iso_datetime parses full datetime", function()
  local ts = du.parse_iso_datetime("2026-06-09T13:30:00")
  assert_eq(ts, os.time({ year = 2026, month = 6, day = 9, hour = 13, min = 30, sec = 0 }))
end)

test("parse_iso_datetime parses date-only with default hour", function()
  local ts = du.parse_iso_datetime("2026-06-09")
  assert_eq(ts, ts_for(2026, 6, 9, 0))
end)

test("parse_iso_datetime returns nil for garbage", function()
  assert_nil(du.parse_iso_datetime("nope"))
  assert_nil(du.parse_iso_datetime(nil))
end)

-- ============================================================================
-- Summary
-- ============================================================================
_H.finish({ style = "results", exit = "os" })
