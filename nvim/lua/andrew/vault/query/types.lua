-- andrew/vault/query/types.lua
-- Core value types for Dataview-style query evaluation.

local M = {}

-- ---------------------------------------------------------------------------
-- Duration
-- ---------------------------------------------------------------------------

local Duration = {}
Duration.__index = Duration

--- Approximate conversion constants (seconds).
local SECS_PER_MINUTE = 60
local SECS_PER_HOUR = 3600
local SECS_PER_DAY = 86400
local SECS_PER_WEEK = 7 * SECS_PER_DAY
local SECS_PER_MONTH = 30.44 * SECS_PER_DAY
local SECS_PER_YEAR = 365.25 * SECS_PER_DAY

--- Create a new Duration from a specification table.
---@param spec? table {years, months, weeks, days, hours, minutes, seconds}
---@return table Duration
function Duration.new(spec)
  spec = spec or {}
  local self = setmetatable({}, Duration)
  self.years = spec.years or 0
  self.months = spec.months or 0
  self.weeks = spec.weeks or 0
  self.days = spec.days or 0
  self.hours = spec.hours or 0
  self.minutes = spec.minutes or 0
  self.seconds = spec.seconds or 0
  return self
end

--- Parse a human-readable duration string.
--- Supports forms like "7 days", "1 month", "2 weeks", "1 year, 3 months",
--- "30 minutes", "1 hour".
---@param str string
---@return table|nil Duration or nil on failure
function Duration.parse(str)
  if type(str) ~= "string" then
    return nil
  end
  str = vim.trim(str)
  if str == "" then
    return nil
  end

  local unit_map = {
    year = "years",
    years = "years",
    month = "months",
    months = "months",
    week = "weeks",
    weeks = "weeks",
    day = "days",
    days = "days",
    hour = "hours",
    hours = "hours",
    minute = "minutes",
    minutes = "minutes",
    second = "seconds",
    seconds = "seconds",
    min = "minutes",
    mins = "minutes",
    sec = "seconds",
    secs = "seconds",
    hr = "hours",
    hrs = "hours",
    wk = "weeks",
    wks = "weeks",
    mo = "months",
    mos = "months",
    yr = "years",
    yrs = "years",
  }

  local spec = {}
  local matched = false
  for amount, unit in str:gmatch("(%d+)%s+(%a+)") do
    local key = unit_map[unit:lower()]
    if not key then
      return nil
    end
    spec[key] = (spec[key] or 0) + tonumber(amount)
    matched = true
  end

  if not matched then
    return nil
  end

  return Duration.new(spec)
end

--- Approximate total seconds for comparison purposes.
---@return number
function Duration:to_seconds()
  return self.years * SECS_PER_YEAR
    + self.months * SECS_PER_MONTH
    + self.weeks * SECS_PER_WEEK
    + self.days * SECS_PER_DAY
    + self.hours * SECS_PER_HOUR
    + self.minutes * SECS_PER_MINUTE
    + self.seconds
end

--- Human-readable representation.
---@return string
function Duration:__tostring()
  local parts = {}
  local fields = {
    { "year", self.years },
    { "month", self.months },
    { "week", self.weeks },
    { "day", self.days },
    { "hour", self.hours },
    { "minute", self.minutes },
    { "second", self.seconds },
  }
  for _, f in ipairs(fields) do
    local label, val = f[1], f[2]
    if val ~= 0 then
      if val == 1 then
        table.insert(parts, val .. " " .. label)
      else
        table.insert(parts, val .. " " .. label .. "s")
      end
    end
  end
  if #parts == 0 then
    return "0 seconds"
  end
  return table.concat(parts, ", ")
end

--- Add two Durations.
---@param a table Duration
---@param b table Duration
---@return table Duration
function Duration.__add(a, b)
  return Duration.new({
    years = a.years + b.years,
    months = a.months + b.months,
    weeks = a.weeks + b.weeks,
    days = a.days + b.days,
    hours = a.hours + b.hours,
    minutes = a.minutes + b.minutes,
    seconds = a.seconds + b.seconds,
  })
end

--- Equality via approximate seconds.
---@param a table Duration
---@param b table Duration
---@return boolean
function Duration.__eq(a, b)
  return a:to_seconds() == b:to_seconds()
end

--- Less-than via approximate seconds.
---@param a table Duration
---@param b table Duration
---@return boolean
function Duration.__lt(a, b)
  return a:to_seconds() < b:to_seconds()
end

M.Duration = Duration

-- ---------------------------------------------------------------------------
-- Date
-- ---------------------------------------------------------------------------

local Date = {}
Date.__index = Date

--- Create a new Date.
---@param year number
---@param month number
---@param day number
---@param hour? number defaults to 0
---@param min? number defaults to 0
---@param sec? number defaults to 0
---@return table Date
function Date.new(year, month, day, hour, min, sec)
  local self = setmetatable({}, Date)
  self.year = year
  self.month = month
  self.day = day
  self.hour = hour or 0
  self.min = min or 0
  self.sec = sec or 0
  return self
end

--- Today at midnight.
---@return table Date
function Date.today()
  local t = os.date("*t") --[[@as osdate]]
  return Date.new(t.year, t.month, t.day, 0, 0, 0)
end

--- Current date and time.
---@return table Date
function Date.now()
  local t = os.date("*t") --[[@as osdate]]
  return Date.new(t.year, t.month, t.day, t.hour, t.min, t.sec)
end

--- Clamp a day to the valid range for a given year/month.
---@param year number
---@param month number
---@param day number
---@return number
local function clamp_day(year, month, day)
  -- os.time normalizes overflows, so ask it for day 0 of next month to get
  -- the last day of this month.
  local last = os.date("*t", os.time({ year = year, month = month + 1, day = 0 })) --[[@as osdate]]
  if day > last.day then
    return last.day
  end
  return day
end

--- Parse a date string.
--- Supported formats:
---   "2026-02-18"
---   "2026-02-18T10:30:00"
---   "February 18, 2026"
---   "today", "tomorrow", "yesterday"
---   "sow" (start of week, Monday), "eow" (end of week, Sunday)
---@param str string
---@return table|nil Date or nil on failure
function Date.parse(str)
  if type(str) ~= "string" then
    return nil
  end
  str = vim.trim(str)
  local lower = str:lower()

  -- Relative keywords
  if lower == "today" then
    return Date.today()
  elseif lower == "tomorrow" then
    return Date.today():plus(Duration.new({ days = 1 }))
  elseif lower == "yesterday" then
    return Date.today():plus(Duration.new({ days = -1 }))
  elseif lower == "sow" then
    -- Start of week (Monday)
    local t = os.date("*t") --[[@as osdate]]
    -- Lua wday: 1=Sunday ... 7=Saturday
    local wday = t.wday
    local days_since_monday = (wday - 2) % 7
    local monday = os.time({ year = t.year, month = t.month, day = t.day }) - days_since_monday * SECS_PER_DAY
    local mt = os.date("*t", monday) --[[@as osdate]]
    return Date.new(mt.year, mt.month, mt.day, 0, 0, 0)
  elseif lower == "eow" then
    -- End of week (Sunday)
    local t = os.date("*t") --[[@as osdate]]
    local wday = t.wday
    local days_until_sunday = (1 - wday) % 7
    if days_until_sunday == 0 then
      days_until_sunday = 7
    end
    local sunday = os.time({ year = t.year, month = t.month, day = t.day }) + days_until_sunday * SECS_PER_DAY
    local st = os.date("*t", sunday) --[[@as osdate]]
    return Date.new(st.year, st.month, st.day, 0, 0, 0)
  end

  -- ISO 8601 with time: 2026-02-18T10:30:00
  local y, m, d, H, M_val, S = str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)$")
  if y then
    return Date.new(tonumber(y), tonumber(m), tonumber(d), tonumber(H), tonumber(M_val), tonumber(S))
  end

  -- ISO date: 2026-02-18
  y, m, d = str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y then
    return Date.new(tonumber(y), tonumber(m), tonumber(d))
  end

  -- Long form: February 18, 2026
  local month_names = {
    january = 1,
    february = 2,
    march = 3,
    april = 4,
    may = 5,
    june = 6,
    july = 7,
    august = 8,
    september = 9,
    october = 10,
    november = 11,
    december = 12,
  }
  local mname, day_str, year_str = str:match("^(%a+)%s+(%d+),?%s+(%d%d%d%d)$")
  if mname then
    local mn = month_names[mname:lower()]
    if mn then
      return Date.new(tonumber(year_str), mn, tonumber(day_str))
    end
  end

  return nil
end

--- Return the os.time() timestamp for this date.
---@return number
function Date:timestamp()
  return os.time({
    year = self.year,
    month = self.month,
    day = self.day,
    hour = self.hour,
    min = self.min,
    sec = self.sec,
  })
end

--- Format using os.date format string.
---@param fmt string
---@return string
function Date:format(fmt)
  return os.date(fmt, self:timestamp())
end

--- Default string representation: "YYYY-MM-DD".
---@return string
function Date:__tostring()
  return string.format("%04d-%02d-%02d", self.year, self.month, self.day)
end

--- Less-than comparison.
---@param a table Date
---@param b table Date
---@return boolean
function Date.__lt(a, b)
  return a:timestamp() < b:timestamp()
end

--- Less-than-or-equal comparison.
---@param a table Date
---@param b table Date
---@return boolean
function Date.__le(a, b)
  return a:timestamp() <= b:timestamp()
end

--- Equality comparison.
---@param a table Date
---@param b table Date
---@return boolean
function Date.__eq(a, b)
  return a:timestamp() == b:timestamp()
end

--- Add a Duration to this Date, returning a new Date.
--- Month/year arithmetic clamps the day to valid ranges (e.g., Jan 31 + 1 month = Feb 28).
---@param dur table Duration
---@return table Date
function Date:plus(dur)
  -- Accept plain tables like {days = 7} by wrapping them as Duration
  if type(dur) == "table" and getmetatable(dur) ~= Duration then
    dur = Duration.new(dur)
  end
  -- Step 1: apply year and month offsets, clamping the day.
  local new_year = self.year + dur.years
  local new_month = self.month + dur.months
  -- Normalize month into 1..12 range.
  new_year = new_year + math.floor((new_month - 1) / 12)
  new_month = ((new_month - 1) % 12) + 1
  local new_day = clamp_day(new_year, new_month, self.day)

  -- Step 2: convert to timestamp and add the remaining sub-month fields.
  local ts = os.time({
    year = new_year,
    month = new_month,
    day = new_day,
    hour = self.hour,
    min = self.min,
    sec = self.sec,
  })

  ts = ts
    + dur.weeks * SECS_PER_WEEK
    + dur.days * SECS_PER_DAY
    + dur.hours * SECS_PER_HOUR
    + dur.minutes * SECS_PER_MINUTE
    + dur.seconds

  local t = os.date("*t", ts) --[[@as osdate]]
  return Date.new(t.year, t.month, t.day, t.hour, t.min, t.sec)
end

--- Subtract a Duration (returns Date) or another Date (returns Duration).
---@param dur_or_date table Duration|Date
---@return table Date|Duration
function Date:minus(dur_or_date)
  -- Accept plain tables like {days = 7}
  if type(dur_or_date) == "table" and getmetatable(dur_or_date) ~= Duration and getmetatable(dur_or_date) ~= Date then
    dur_or_date = Duration.new(dur_or_date)
  end
  if getmetatable(dur_or_date) == Duration then
    -- Negate every field and add.
    local neg = Duration.new({
      years = -dur_or_date.years,
      months = -dur_or_date.months,
      weeks = -dur_or_date.weeks,
      days = -dur_or_date.days,
      hours = -dur_or_date.hours,
      minutes = -dur_or_date.minutes,
      seconds = -dur_or_date.seconds,
    })
    return self:plus(neg)
  end

  -- Assume it is a Date; return the difference as a Duration in seconds.
  local diff = self:timestamp() - dur_or_date:timestamp()
  return Duration.new({ seconds = diff })
end

M.Date = Date

-- ---------------------------------------------------------------------------
-- Link
-- ---------------------------------------------------------------------------

local Link = {}
Link.__index = Link

--- Create a new Link.
---@param path string
---@param display? string
---@param embed? boolean defaults to false
---@return table Link
function Link.new(path, display, embed)
  local self = setmetatable({}, Link)
  self.path = path
  self.display = display
  self.embed = embed or false
  return self
end

--- String representation in wiki-link style.
---@return string
function Link:__tostring()
  local prefix = self.embed and "!" or ""
  if self.display then
    return prefix .. "[[" .. self.path .. "|" .. self.display .. "]]"
  end
  return prefix .. "[[" .. self.path .. "]]"
end

M.Link = Link

-- ---------------------------------------------------------------------------
-- Utility functions
-- ---------------------------------------------------------------------------

--- Determine a descriptive type name for a value.
---@param val any
---@return string
function M.typename(val)
  if val == nil then
    return "null"
  end
  local mt = getmetatable(val)
  if mt == Date then
    return "date"
  end
  if mt == Duration then
    return "duration"
  end
  if mt == Link then
    return "link"
  end
  if type(val) == "table" then
    -- Distinguish arrays from objects.
    -- An empty table is treated as an array.
    for k, _ in pairs(val) do
      if type(k) ~= "number" then
        return "object"
      end
    end
    return "array"
  end
  return type(val)
end

--- Truthiness: nil and false are falsy; everything else (including 0 and "") is truthy.
---@param val any
---@return boolean
function M.truthy(val)
  if val == nil or val == false then
    return false
  end
  return true
end

--- Generic three-way comparator returning -1, 0, or 1.
--- nil is always less than any non-nil value.
---@param a any
---@param b any
---@return number -1|0|1
function M.compare(a, b)
  -- Handle nils.
  if a == nil and b == nil then
    return 0
  end
  if a == nil then
    return -1
  end
  if b == nil then
    return 1
  end

  local ta = M.typename(a)
  local tb = M.typename(b)

  -- Same type: direct comparison.
  if ta == tb then
    if ta == "number" then
      if a < b then
        return -1
      elseif a > b then
        return 1
      end
      return 0
    elseif ta == "string" then
      local la, lb = a:lower(), b:lower()
      if la < lb then
        return -1
      elseif la > lb then
        return 1
      end
      return 0
    elseif ta == "date" then
      local at, bt = a:timestamp(), b:timestamp()
      if at < bt then
        return -1
      elseif at > bt then
        return 1
      end
      return 0
    elseif ta == "duration" then
      local as, bs = a:to_seconds(), b:to_seconds()
      if as < bs then
        return -1
      elseif as > bs then
        return 1
      end
      return 0
    elseif ta == "link" then
      local pa, pb = a.path:lower(), b.path:lower()
      if pa < pb then
        return -1
      elseif pa > pb then
        return 1
      end
      return 0
    elseif ta == "boolean" then
      if a == b then
        return 0
      end
      -- false < true
      return a and 1 or -1
    else
      -- Fallback: tostring comparison.
      local sa, sb = tostring(a), tostring(b)
      if sa < sb then
        return -1
      elseif sa > sb then
        return 1
      end
      return 0
    end
  end

  -- Different types: compare by typename string.
  if ta < tb then
    return -1
  elseif ta > tb then
    return 1
  end
  return 0
end

return M
