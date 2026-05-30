local types = require("andrew.vault.query.types")

local M = {}

local function date_offset(field, amount)
  local d = os.date("*t")
  d[field] = d[field] + amount
  local r = os.date("*t", os.time(d))
  return types.Date.new(r.year, r.month, r.day)
end

local function sum_nums(list)
  local total = 0
  for _, v in ipairs(list) do
    total = total + (tonumber(v) or 0)
  end
  return total
end

local function collect_nums(list)
  local nums = {}
  for _, v in ipairs(list) do
    nums[#nums + 1] = tonumber(v) or 0
  end
  return nums
end

--- Build the builtins dispatch table.
--- @param deps table { contains_value: function }
--- @return table<string, function>
function M.make_fns(deps)
  local contains_value = deps.contains_value
  return {
    -- contains(list_or_string, value)
    contains = function(a, b)
      return contains_value(a, b)
    end,

    -- link(path, display?)
    link = function(path, display)
      if type(path) == "table" and path.path then
        return types.Link.new(path.path, tostring(display or path.display), false)
      end
      return types.Link.new(tostring(path or ""), display and tostring(display) or nil, false)
    end,

    -- date(str)
    date = function(str)
      return types.Date.parse(tostring(str or ""))
    end,

    -- dur(str)
    dur = function(str)
      return types.Duration.parse(tostring(str or ""))
    end,

    -- number(val)
    number = function(val)
      return tonumber(val)
    end,

    -- string(val)
    ["string"] = function(val)
      return tostring(val or "")
    end,

    -- length(val)
    length = function(val)
      if type(val) == "string" then
        return #val
      elseif type(val) == "table" then
        return #val
      end
      return 0
    end,

    -- round(num, digits?)
    round = function(num, digits)
      num = tonumber(num) or 0
      digits = tonumber(digits) or 0
      local mult = 10 ^ digits
      return math.floor(num * mult + 0.5) / mult
    end,

    -- min(...)
    min = function(...)
      local vals = { ... }
      if #vals == 0 then
        return nil
      end
      local best = tonumber(vals[1])
      for i = 2, #vals do
        local v = tonumber(vals[i])
        if v and (best == nil or v < best) then
          best = v
        end
      end
      return best
    end,

    -- max(...)
    max = function(...)
      local vals = { ... }
      if #vals == 0 then
        return nil
      end
      local best = tonumber(vals[1])
      for i = 2, #vals do
        local v = tonumber(vals[i])
        if v and (best == nil or v > best) then
          best = v
        end
      end
      return best
    end,

    -- default(val, default_val)
    default = function(val, def)
      if val == nil then
        return def
      end
      return val
    end,

    -- choice(condition, if_true, if_false)
    choice = function(cond, t, f)
      if types.truthy(cond) then
        return t
      end
      return f
    end,

    -- dateformat(date, format?)
    dateformat = function(d, fmt)
      if type(d) == "table" and d.format then
        return d:format(fmt or "%Y-%m-%d")
      end
      return tostring(d or "")
    end,

    -- striptime(date)
    striptime = function(d)
      if type(d) == "table" and d.year then
        return types.Date.new(d.year, d.month, d.day)
      end
      return d
    end,

    -- flat(list) -- flatten nested arrays one level
    flat = function(list)
      if type(list) ~= "table" then
        return list
      end
      local out = {}
      for _, v in ipairs(list) do
        if type(v) == "table" and #v > 0 then
          for _, inner in ipairs(v) do
            table.insert(out, inner)
          end
        else
          table.insert(out, v)
        end
      end
      return out
    end,

    -- reverse(list)
    reverse = function(list)
      if type(list) ~= "table" then
        return list
      end
      local out = {}
      for i = #list, 1, -1 do
        table.insert(out, list[i])
      end
      return out
    end,

    -- sort(list)
    sort = function(list)
      if type(list) ~= "table" then
        return list
      end
      local copy = { unpack(list) }
      table.sort(copy, function(a, b)
        return types.compare(a, b) < 0
      end)
      return copy
    end,

    -- join(list, sep)
    join = function(list, sep)
      if type(list) ~= "table" then
        return tostring(list or "")
      end
      sep = tostring(sep or ", ")
      local strs = {}
      for _, v in ipairs(list) do
        table.insert(strs, tostring(v))
      end
      return table.concat(strs, sep)
    end,

    -- filter(list, fn_name) -- simplified: just returns non-nil/non-false items
    filter = function(list)
      if type(list) ~= "table" then
        return list
      end
      local out = {}
      for _, v in ipairs(list) do
        if types.truthy(v) then
          table.insert(out, v)
        end
      end
      return out
    end,

    -- regexmatch(str, pattern)
    regexmatch = function(str, pattern)
      if type(str) ~= "string" or type(pattern) ~= "string" then
        return false
      end
      return str:match(pattern) ~= nil
    end,

    -- replace(str, pattern, replacement)
    replace = function(str, pattern, replacement)
      if type(str) ~= "string" then
        return str
      end
      return (str:gsub(tostring(pattern or ""), tostring(replacement or "")))
    end,

    -- lower(str)
    lower = function(str)
      return type(str) == "string" and str:lower() or tostring(str or ""):lower()
    end,

    -- upper(str)
    upper = function(str)
      return type(str) == "string" and str:upper() or tostring(str or ""):upper()
    end,

    -- split(str, sep)
    split = function(str, sep)
      if type(str) ~= "string" then
        return {}
      end
      sep = tostring(sep or ",")
      local parts = {}
      for part in str:gmatch("([^" .. sep:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1") .. "]+)") do
        table.insert(parts, part)
      end
      return parts
    end,

    -- sum(list)
    sum = function(list)
      if type(list) ~= "table" then
        return tonumber(list) or 0
      end
      return sum_nums(list)
    end,

    -- average(list)
    average = function(list)
      if type(list) ~= "table" or #list == 0 then
        return 0
      end
      return sum_nums(list) / #list
    end,

    -- typeof(val)
    typeof = function(val)
      return types.typename(val)
    end,

    -- nonnull(list) -- filter out nil values from an array
    nonnull = function(list)
      if type(list) ~= "table" then
        return list
      end
      local out = {}
      for _, v in ipairs(list) do
        if v ~= nil then
          table.insert(out, v)
        end
      end
      return out
    end,

    -- all(list) -- true if all elements are truthy
    all = function(list)
      if type(list) ~= "table" then
        return types.truthy(list)
      end
      for _, v in ipairs(list) do
        if not types.truthy(v) then
          return false
        end
      end
      return true
    end,

    -- any(list) -- true if any element is truthy
    any = function(list)
      if type(list) ~= "table" then
        return types.truthy(list)
      end
      for _, v in ipairs(list) do
        if types.truthy(v) then
          return true
        end
      end
      return false
    end,

    -- none(list) -- true if no elements are truthy
    none = function(list)
      if type(list) ~= "table" then
        return not types.truthy(list)
      end
      for _, v in ipairs(list) do
        if types.truthy(v) then
          return false
        end
      end
      return true
    end,

    -- -----------------------------------------------------------------
    -- String functions
    -- -----------------------------------------------------------------

    -- capitalize(str) -- first letter uppercase
    capitalize = function(str)
      str = tostring(str or "")
      if #str == 0 then return str end
      return str:sub(1, 1):upper() .. str:sub(2)
    end,

    -- startswith(str, prefix)
    startswith = function(str, prefix)
      if type(str) ~= "string" or type(prefix) ~= "string" then return false end
      return str:sub(1, #prefix) == prefix
    end,

    -- endswith(str, suffix)
    endswith = function(str, suffix)
      if type(str) ~= "string" or type(suffix) ~= "string" then return false end
      return str:sub(-#suffix) == suffix
    end,

    -- padleft(str, length, char?)
    padleft = function(str, length, char)
      str = tostring(str or "")
      length = tonumber(length) or 0
      char = tostring(char or " "):sub(1, 1)
      while #str < length do
        str = char .. str
      end
      return str
    end,

    -- padright(str, length, char?)
    padright = function(str, length, char)
      str = tostring(str or "")
      length = tonumber(length) or 0
      char = tostring(char or " "):sub(1, 1)
      while #str < length do
        str = str .. char
      end
      return str
    end,

    -- trim(str)
    trim = function(str)
      if type(str) ~= "string" then return tostring(str or "") end
      return vim.trim(str)
    end,

    -- substring(str, start, end?)
    substring = function(str, start_idx, end_idx)
      if type(str) ~= "string" then return "" end
      start_idx = tonumber(start_idx) or 1
      if end_idx then
        return str:sub(start_idx, tonumber(end_idx))
      end
      return str:sub(start_idx)
    end,

    -- truncate(str, length, suffix?)
    truncate = function(str, length, suffix)
      str = tostring(str or "")
      length = tonumber(length) or #str
      suffix = tostring(suffix or "...")
      if #str <= length then return str end
      return str:sub(1, length - #suffix) .. suffix
    end,

    -- regexreplace(str, pattern, replacement)
    regexreplace = function(str, pattern, replacement)
      if type(str) ~= "string" then return str end
      return (str:gsub(tostring(pattern or ""), tostring(replacement or "")))
    end,

    -- extract(str, pattern) -- return first match
    extract = function(str, pattern)
      if type(str) ~= "string" or type(pattern) ~= "string" then return nil end
      return str:match(pattern)
    end,

    -- -----------------------------------------------------------------
    -- Numeric functions
    -- -----------------------------------------------------------------

    -- abs(num)
    abs = function(num)
      return math.abs(tonumber(num) or 0)
    end,

    -- ceil(num)
    ceil = function(num)
      return math.ceil(tonumber(num) or 0)
    end,

    -- floor(num)
    floor = function(num)
      return math.floor(tonumber(num) or 0)
    end,

    -- product(list)
    product = function(list)
      if type(list) ~= "table" or #list == 0 then return 0 end
      local result = 1
      for _, v in ipairs(list) do
        result = result * (tonumber(v) or 0)
      end
      return result
    end,

    -- median(list)
    median = function(list)
      if type(list) ~= "table" or #list == 0 then return 0 end
      local sorted = collect_nums(list)
      table.sort(sorted)
      local n = #sorted
      if n % 2 == 0 then
        return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
      else
        return sorted[math.ceil(n / 2)]
      end
    end,

    -- -----------------------------------------------------------------
    -- Array functions
    -- -----------------------------------------------------------------

    -- unique(list) -- deduplicate
    unique = function(list)
      if type(list) ~= "table" then return list end
      local seen = {}
      local out = {}
      for _, v in ipairs(list) do
        local key = tostring(v)
        if not seen[key] then
          seen[key] = true
          out[#out + 1] = v
        end
      end
      return out
    end,

    -- slice(list, start, end?)
    slice = function(list, start_idx, end_idx)
      if type(list) ~= "table" then return {} end
      start_idx = tonumber(start_idx) or 1
      end_idx = tonumber(end_idx) or #list
      if start_idx < 0 then start_idx = #list + start_idx + 1 end
      if end_idx < 0 then end_idx = #list + end_idx + 1 end
      local out = {}
      for idx = math.max(1, start_idx), math.min(#list, end_idx) do
        out[#out + 1] = list[idx]
      end
      return out
    end,

    -- first(list)
    first = function(list)
      if type(list) ~= "table" then return nil end
      return list[1]
    end,

    -- last(list)
    last = function(list)
      if type(list) ~= "table" then return nil end
      return list[#list]
    end,

    -- count(list)
    count = function(list)
      if type(list) ~= "table" then return 0 end
      return #list
    end,

    -- zip(list1, list2)
    zip = function(list1, list2)
      if type(list1) ~= "table" or type(list2) ~= "table" then return {} end
      local out = {}
      for idx = 1, math.min(#list1, #list2) do
        out[#out + 1] = { list1[idx], list2[idx] }
      end
      return out
    end,

    -- -----------------------------------------------------------------
    -- Date/Range functions
    -- -----------------------------------------------------------------

    -- isbetween(val, min_val, max_val) -- inclusive range check
    isbetween = function(val, min_val, max_val)
      local cmp_min = types.compare(val, min_val)
      local cmp_max = types.compare(val, max_val)
      return cmp_min >= 0 and cmp_max <= 0
    end,

    -- today() -- return today's date
    today = function()
      return types.Date.today()
    end,

    -- now() -- return current date+time
    now = function()
      local d = os.date("*t")
      return types.Date.new(d.year, d.month, d.day, d.hour, d.min, d.sec)
    end,

    -- yesterday()
    yesterday = function()
      return date_offset("day", -1)
    end,

    -- tomorrow()
    tomorrow = function()
      return date_offset("day", 1)
    end,

    -- daysago(n) -- date n days in the past
    daysago = function(n)
      return date_offset("day", -(tonumber(n) or 0))
    end,

    -- daysfromnow(n) -- date n days in the future
    daysfromnow = function(n)
      return date_offset("day", tonumber(n) or 0)
    end,

    -- weeksago(n) -- date n weeks in the past
    weeksago = function(n)
      return date_offset("day", -(tonumber(n) or 0) * 7)
    end,

    -- monthsago(n) -- date n months in the past
    monthsago = function(n)
      return date_offset("month", -(tonumber(n) or 0))
    end,

    -- sow() -- start of current week (Monday)
    sow = function()
      return types.Date.parse("sow")
    end,

    -- eow() -- end of current week (Sunday)
    eow = function()
      return types.Date.parse("eow")
    end,

    -- som() -- start of current month
    som = function()
      local d = os.date("*t")
      return types.Date.new(d.year, d.month, 1)
    end,

    -- eom() -- end of current month
    eom = function()
      local d = os.date("*t")
      d.month = d.month + 1
      d.day = 0 -- day 0 of next month = last day of current month
      local r = os.date("*t", os.time(d))
      return types.Date.new(r.year, r.month, r.day)
    end,

    -- -----------------------------------------------------------------
    -- Utility functions
    -- -----------------------------------------------------------------

    -- keys(object) -- get keys of a table
    keys = function(obj)
      if type(obj) ~= "table" then return {} end
      local out = {}
      for k in pairs(obj) do
        if type(k) == "string" then
          out[#out + 1] = k
        end
      end
      table.sort(out)
      return out
    end,

    -- values(object) -- get values of a table
    values = function(obj)
      if type(obj) ~= "table" then return {} end
      local out = {}
      for _, v in pairs(obj) do
        out[#out + 1] = v
      end
      return out
    end,

    -- object(keys, values) -- create table from parallel arrays
    object = function(key_list, val_list)
      if type(key_list) ~= "table" or type(val_list) ~= "table" then return {} end
      local out = {}
      for idx = 1, math.min(#key_list, #val_list) do
        out[tostring(key_list[idx])] = val_list[idx]
      end
      return out
    end,
  }
end

return M
