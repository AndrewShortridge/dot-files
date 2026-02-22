local M = {}

--- Parse a recurrence rule string into a structured table.
--- @param rule_str string e.g. "every day", "every 2 weeks", "every month on the 15th"
--- @return table|nil { type: string, n: number, day: number|nil }
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

--- Compute the next occurrence date from a starting date and a parsed rule.
--- @param from_date_str string "YYYY-MM-DD"
--- @param rule table as returned by parse_rule
--- @return string "YYYY-MM-DD"
function M.next_date(from_date_str, rule)
  local y, m, d = from_date_str:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then
    -- Fallback to today if date is unparseable
    return os.date("%Y-%m-%d")
  end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)

  if rule.type == "days" then
    local t = os.time({ year = y, month = m, day = d, hour = 12 })
    t = t + rule.n * 86400
    return os.date("%Y-%m-%d", t)
  end

  if rule.type == "weekday" then
    local t = os.time({ year = y, month = m, day = d, hour = 12 })
    -- Advance at least one day, then skip weekends
    t = t + 86400
    local wday = tonumber(os.date("%w", t)) -- 0=Sun, 6=Sat
    if wday == 0 then
      t = t + 86400 -- Sun -> Mon
    elseif wday == 6 then
      t = t + 2 * 86400 -- Sat -> Mon
    end
    return os.date("%Y-%m-%d", t)
  end

  if rule.type == "months" then
    -- os.time normalizes overflow (e.g. month 13 -> Jan next year, day 31 in a 30-day month)
    local t = os.time({ year = y, month = m + rule.n, day = d, hour = 12 })
    return os.date("%Y-%m-%d", t)
  end

  if rule.type == "monthly_on" then
    local new_m = m + rule.n
    local new_y = y
    -- Normalize month overflow
    local t = os.time({ year = new_y, month = new_m, day = rule.day, hour = 12 })
    return os.date("%Y-%m-%d", t)
  end

  if rule.type == "years" then
    local t = os.time({ year = y + rule.n, month = m, day = d, hour = 12 })
    return os.date("%Y-%m-%d", t)
  end

  -- Fallback
  return from_date_str
end

--- Handle recurrence for a task line that was just checked [x].
--- If the line has a [repeat:: ...] pattern, inserts a new unchecked copy above
--- with the next due date.
--- @param line_nr number 1-indexed line number in the current buffer
--- @return boolean true if a recurring task was created, false otherwise
function M.handle_recurrence(line_nr)
  local line = vim.api.nvim_buf_get_lines(0, line_nr - 1, line_nr, false)[1]
  if not line then
    return false
  end

  -- Extract repeat rule
  local repeat_rule = line:match("%[repeat::%s*([^%]]+)%]")
  if not repeat_rule then
    return false
  end

  local rule = M.parse_rule(repeat_rule)
  if not rule then
    return false
  end

  -- Determine base date: use [due:: ...] if present, otherwise today
  local due_date = line:match("%[due::%s*(%d%d%d%d%-%d%d%-%d%d)%s*%]")
  local base_date = due_date or os.date("%Y-%m-%d")

  -- Compute next date
  local next = M.next_date(base_date, rule)

  -- Build new line: reset checkbox to [ ], remove completion date, update due date
  local new_line = line

  -- Reset checkbox: [x] -> [ ]
  new_line = new_line:gsub("(%- %[)x(%])", "%1 %2")

  -- Remove completion metadata
  new_line = new_line:gsub("%s*%[completion::[^%]]*%]", "")

  -- Update or insert due date
  if due_date then
    new_line = new_line:gsub("%[due::%s*%d%d%d%d%-%d%d%-%d%d%s*%]", "[due:: " .. next .. "]")
  else
    -- Insert due date before [repeat:: ...]
    new_line = new_line:gsub("%[repeat::", "[due:: " .. next .. "] [repeat::")
  end

  -- Insert the new recurring task above the completed line (0-indexed, so line_nr - 1)
  vim.api.nvim_buf_set_lines(0, line_nr - 1, line_nr - 1, false, { new_line })

  return true
end

return M
