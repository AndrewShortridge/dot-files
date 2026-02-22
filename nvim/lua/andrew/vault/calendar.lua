local engine = require("andrew.vault.engine")

local M = {}

-- =============================================================================
-- Highlight Groups
-- =============================================================================

local function define_highlights()
  -- Header row (month/year title and weekday names)
  vim.api.nvim_set_hl(0, "VaultCalendarHeader", { bold = true, fg = "#89b4fa" })
  -- Today's date
  vim.api.nvim_set_hl(0, "VaultCalendarToday", { bold = true, fg = "#1e1e2e", bg = "#a6e3a1" })
  -- Days that have a daily log file
  vim.api.nvim_set_hl(0, "VaultCalendarHasLog", { bold = true, fg = "#f9e2af" })
  -- Days that have task deadlines
  vim.api.nvim_set_hl(0, "VaultCalendarDeadline", { bold = true, fg = "#94e2d5" })
  -- Days that have BOTH a daily log and task deadlines
  vim.api.nvim_set_hl(0, "VaultCalendarLogDeadline", { bold = true, fg = "#1e1e2e", bg = "#fab387" })
  -- Weekend day numbers (Sat/Sun)
  vim.api.nvim_set_hl(0, "VaultCalendarWeekend", { fg = "#f38ba8" })
  -- Normal day numbers
  vim.api.nvim_set_hl(0, "VaultCalendarDay", { fg = "#cdd6f4" })
  -- Dimmed days outside current month (padding)
  vim.api.nvim_set_hl(0, "VaultCalendarDim", { fg = "#585b70" })
  -- Legend labels
  vim.api.nvim_set_hl(0, "VaultCalendarLegend", { fg = "#7f849c" })
end

-- =============================================================================
-- Date Utilities
-- =============================================================================

--- Number of days in a given month/year.
---@param year number
---@param month number 1-12
---@return number
local function days_in_month(year, month)
  -- Advance to the first of the next month, then subtract one day
  local t = os.time({ year = year, month = month + 1, day = 0 })
  return tonumber(os.date("%d", t))
end

--- Weekday of the first day of a month (1=Mon, 7=Sun, ISO style).
---@param year number
---@param month number 1-12
---@return number 1-7 (Mon-Sun)
local function first_weekday(year, month)
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
local function format_date(year, month, day)
  return string.format("%04d-%02d-%02d", year, month, day)
end

--- Month names for display.
local month_names = {
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
}

-- =============================================================================
-- Task Deadline Cache
-- =============================================================================

-- Module-level cache so deadline data persists across month navigation and
-- calendar re-opens without re-scanning the entire vault each time.
-- Structure:
--   _deadline_cache = {
--     vault_path = string,         -- vault path when cache was built
--     built_at   = number,         -- os.clock() timestamp
--     deadlines  = table,          -- "YYYY-MM-DD" -> { {text, file, line}, ... }
--   }
local _deadline_cache = nil
local DEADLINE_CACHE_TTL = 60 -- seconds before cache goes stale

--- Scan the vault for tasks with due dates using ripgrep.
--- Searches for:
---   1. Inline fields:  [due:: YYYY-MM-DD]  or  (due:: YYYY-MM-DD)
---   2. Frontmatter:    due: YYYY-MM-DD
---   3. Standalone:     due:: YYYY-MM-DD
--- Returns a table mapping "YYYY-MM-DD" -> list of { text, file, line }.
---@return table<string, table[]>
local function scan_deadlines()
  local vault = engine.vault_path
  if not vault or vim.fn.isdirectory(vault) == 0 then
    return {}
  end

  -- Use ripgrep for speed. We search for any line containing a due date pattern.
  -- The regex captures both inline-field styles and frontmatter style.
  local cmd = {
    "rg",
    "--no-heading",
    "--line-number",
    "--with-filename",
    "--glob", "*.md",
    "--glob", "!.obsidian/**",
    "--glob", "!.trash/**",
    "-e", "\\[due::\\s*\\d{4}-\\d{2}-\\d{2}\\]",
    "-e", "\\(due::\\s*\\d{4}-\\d{2}-\\d{2}\\)",
    "-e", "^due:\\s*\\d{4}-\\d{2}-\\d{2}",
    "-e", "due::\\s*\\d{4}-\\d{2}-\\d{2}",
    vault,
  }

  local raw = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 and vim.v.shell_error ~= 1 then
    -- shell_error == 1 means no matches, which is fine
    return {}
  end

  local deadlines = {}
  for _, line in ipairs(raw) do
    -- Each line from rg: /abs/path/file.md:LINE_NO:content
    local file, lnum, content = line:match("^(.+):(%d+):(.*)$")
    if file and content then
      -- Extract all YYYY-MM-DD dates that appear in a due context on this line
      -- Handle: [due:: 2026-03-15], (due:: 2026-03-15), due:: 2026-03-15, due: 2026-03-15
      for date_str in content:gmatch("due::?%s*(%d%d%d%d%-%d%d%-%d%d)") do
        if not deadlines[date_str] then
          deadlines[date_str] = {}
        end
        -- Build a clean display text: strip the file path to be vault-relative
        local rel_file = engine.vault_relative(file)
        -- Clean up the task text for display
        local task_text = content
        -- If this is a task line, extract just the text part
        local task_body = content:match("^%s*[-*] %[.%] (.+)$")
        if task_body then
          task_text = task_body
        end
        -- Remove inline field markup for cleaner display
        task_text = task_text:gsub("%[due::[^%]]*%]", ""):gsub("%(due::[^%)]*%)", "")
        task_text = vim.trim(task_text)
        if task_text == "" then
          task_text = "(due date in frontmatter)"
        end

        deadlines[date_str][#deadlines[date_str] + 1] = {
          text = task_text,
          file = rel_file,
          abs_file = file,
          line = tonumber(lnum),
        }
      end
    end
  end

  return deadlines
end

--- Get cached deadline data, re-scanning if the cache is stale or missing.
---@return table<string, table[]>
local function get_deadlines()
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

--- Force-invalidate the deadline cache (e.g., after editing a task).
function M.invalidate_deadline_cache()
  _deadline_cache = nil
end

--- Extract the set of days in a given month that have deadlines.
---@param year number
---@param month number
---@param deadlines table full deadline map from get_deadlines()
---@return table<number, boolean> day_number -> true
local function deadlines_for_month(year, month, deadlines)
  local prefix = format_date(year, month, 1):sub(1, 7) -- "YYYY-MM"
  local has_deadline = {}
  for date_str, _ in pairs(deadlines) do
    if date_str:sub(1, 7) == prefix then
      local day = tonumber(date_str:sub(9, 10))
      if day then
        has_deadline[day] = true
      end
    end
  end
  return has_deadline
end

-- =============================================================================
-- Calendar State
-- =============================================================================

-- The calendar state is local to the floating window session.
-- We store it in a table that gets created per calendar() invocation.

-- =============================================================================
-- Calendar Rendering
-- =============================================================================

--- Build the set of days in `year-month` that have daily log files.
---@param year number
---@param month number
---@return table<number, boolean> day_number -> true
local function scan_logs_for_month(year, month)
  local log_dir = engine.vault_path .. "/Log"
  local prefix = format_date(year, month, 1):sub(1, 7) -- "YYYY-MM"
  local has_log = {}

  if vim.fn.isdirectory(log_dir) == 0 then
    return has_log
  end

  local entries = vim.fn.readdir(log_dir)
  for _, name in ipairs(entries) do
    if name:sub(1, 7) == prefix and name:match("^%d%d%d%d%-%d%d%-%d%d%.md$") then
      local day = tonumber(name:sub(9, 10))
      if day then
        has_log[day] = true
      end
    end
  end
  return has_log
end

--- Render the calendar into buffer lines and collect highlight regions.
--- Returns { lines = string[], highlights = { {group, row, col_start, col_end} } }
---@param year number
---@param month number
---@param deadlines table full deadline map from get_deadlines()
---@return table
local function render_calendar(year, month, deadlines)
  local lines = {}
  local highlights = {}
  local cell_width = 4 -- each day cell is 4 chars wide ("  3 ")
  local grid_width = 7 * cell_width -- 28 chars for the grid

  local today = engine.today()
  local today_y, today_m, today_d = today:match("(%d+)-(%d+)-(%d+)")
  today_y, today_m, today_d = tonumber(today_y), tonumber(today_m), tonumber(today_d)

  local has_log = scan_logs_for_month(year, month)
  local has_deadline = deadlines_for_month(year, month, deadlines)
  local num_days = days_in_month(year, month)
  local start_wday = first_weekday(year, month) -- 1=Mon

  -- Title line: "  < February 2026 >  "
  local title = month_names[month] .. " " .. tostring(year)
  local title_line = "  < " .. title .. " >  "
  -- Center the title relative to the grid
  local pad = math.max(0, math.floor((grid_width - #title_line) / 2))
  title_line = string.rep(" ", pad) .. title_line
  lines[1] = title_line
  highlights[#highlights + 1] = { "VaultCalendarHeader", 0, 0, #title_line }

  -- Blank line
  lines[2] = ""

  -- Weekday header: " Mon Tue Wed Thu Fri Sat Sun"
  local weekdays = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
  local hdr = ""
  for i, wd in ipairs(weekdays) do
    hdr = hdr .. " " .. wd
    if i < 7 then
      hdr = hdr .. ""
    end
  end
  lines[3] = hdr
  highlights[#highlights + 1] = { "VaultCalendarHeader", 2, 0, #hdr }

  -- Separator
  lines[4] = string.rep("-", grid_width)

  -- Day grid
  local row_idx = 4 -- 0-indexed line number for highlights (lines[5])
  local current_line = ""
  local col = 1 -- current column in the week (1=Mon .. 7=Sun)

  -- Pad the first row with blanks for days before the 1st
  for _ = 1, start_wday - 1 do
    current_line = current_line .. "    "
    col = col + 1
  end

  -- Day-to-position map: day_number -> { row (0-indexed), col_start, col_end }
  local day_positions = {}

  -- Track whether any deadlines are visible this month (for legend)
  local month_has_deadlines = false

  for day = 1, num_days do
    local cell = string.format(" %2d ", day)
    local col_start = #current_line
    current_line = current_line .. cell
    local col_end = #current_line

    -- We'll store positions after the line is finalized
    day_positions[day] = { row = row_idx, col_start = col_start, col_end = col_end }

    -- Determine highlight for this day
    local is_today = (year == today_y and month == today_m and day == today_d)
    local is_weekend = (col == 6 or col == 7)
    local is_logged = has_log[day]
    local is_due = has_deadline[day]

    if is_due then
      month_has_deadlines = true
    end

    if is_today then
      -- Today always wins with its distinctive green background
      highlights[#highlights + 1] = { "VaultCalendarToday", row_idx, col_start, col_end }
    elseif is_logged and is_due then
      -- Combined: log + deadline -> orange background
      highlights[#highlights + 1] = { "VaultCalendarLogDeadline", row_idx, col_start, col_end }
    elseif is_due then
      -- Deadline only -> cyan/teal
      highlights[#highlights + 1] = { "VaultCalendarDeadline", row_idx, col_start, col_end }
    elseif is_logged then
      highlights[#highlights + 1] = { "VaultCalendarHasLog", row_idx, col_start, col_end }
    elseif is_weekend then
      highlights[#highlights + 1] = { "VaultCalendarWeekend", row_idx, col_start, col_end }
    end

    if col == 7 then
      lines[#lines + 1] = current_line
      current_line = ""
      col = 1
      row_idx = row_idx + 1
    else
      col = col + 1
    end
  end

  -- Flush any remaining partial row
  if current_line ~= "" then
    -- Pad the rest of the row
    while col <= 7 do
      current_line = current_line .. "    "
      col = col + 1
    end
    lines[#lines + 1] = current_line
  end

  -- Legend showing color meanings
  lines[#lines + 1] = ""
  -- Build legend with colored markers
  local legend_row = #lines - 1  -- 0-indexed row for highlights
  local legend = " *today  *log  *due"
  if month_has_deadlines then
    legend = legend .. "  *log+due"
  end
  lines[#lines] = legend
  -- Apply highlights to the legend markers (the * characters)
  -- We use plain string find (4th arg = true) to avoid Lua pattern issues with *
  local pos_today = legend:find("*today", 1, true)
  local pos_log = legend:find("*log", (pos_today or 0) + 6, true)
  local pos_due = legend:find("*due", (pos_log or 0) + 4, true)
  if pos_today then
    -- pos_today is 1-indexed; nvim highlight cols are 0-indexed
    -- "*" marker: 1 char at [pos-1, pos)
    -- "today" label: 5 chars at [pos, pos+5)
    highlights[#highlights + 1] = { "VaultCalendarToday", legend_row, pos_today - 1, pos_today }
    highlights[#highlights + 1] = { "VaultCalendarLegend", legend_row, pos_today, pos_today + 5 }
  end
  if pos_log then
    highlights[#highlights + 1] = { "VaultCalendarHasLog", legend_row, pos_log - 1, pos_log }
    highlights[#highlights + 1] = { "VaultCalendarLegend", legend_row, pos_log, pos_log + 3 }
  end
  if pos_due then
    highlights[#highlights + 1] = { "VaultCalendarDeadline", legend_row, pos_due - 1, pos_due }
    highlights[#highlights + 1] = { "VaultCalendarLegend", legend_row, pos_due, pos_due + 3 }
  end
  if month_has_deadlines then
    local pos_both = legend:find("*log+due", (pos_due or 0) + 4, true)
    if pos_both then
      highlights[#highlights + 1] = { "VaultCalendarLogDeadline", legend_row, pos_both - 1, pos_both }
      highlights[#highlights + 1] = { "VaultCalendarLegend", legend_row, pos_both, pos_both + 7 }
    end
  end

  -- Footer with navigation hints
  lines[#lines + 1] = ""
  local footer = " h/l: month  H/L: year  <CR>: open  q: close"
  lines[#lines + 1] = footer
  highlights[#highlights + 1] = { "VaultCalendarDim", #lines - 1, 0, #footer }

  return {
    lines = lines,
    highlights = highlights,
    day_positions = day_positions,
    num_days = num_days,
    start_wday = start_wday,
  }
end

--- Determine which day number the cursor is on, or nil if not on a day cell.
---@param day_positions table<number, table>
---@param cursor_row number 0-indexed row in buffer
---@param cursor_col number 0-indexed column in buffer
---@param num_days number
---@return number|nil day
local function day_at_cursor(day_positions, cursor_row, cursor_col, num_days)
  for day = 1, num_days do
    local pos = day_positions[day]
    if pos and cursor_row == pos.row and cursor_col >= pos.col_start and cursor_col < pos.col_end then
      return day
    end
  end
  return nil
end

-- =============================================================================
-- Calendar Floating Window
-- =============================================================================

--- Open the calendar floating window.
function M.calendar()
  define_highlights()

  -- Pre-fetch deadline data (cached; does not re-scan unless stale)
  local deadlines = get_deadlines()

  local now = os.date("*t")
  local state = {
    year = now.year,
    month = now.month,
    buf = nil,
    win = nil,
    day_positions = {},
    num_days = 0,
    deadlines = deadlines,
  }

  -- Create scratch buffer
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].swapfile = false

  -- Window dimensions (increased height for legend line)
  local width = 34
  local height = 16
  local ui = vim.api.nvim_list_uis()[1]
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width - width) / 2)

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Vault Calendar ",
    title_pos = "center",
  })

  -- Window options
  vim.wo[state.win].cursorline = false
  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].wrap = false

  local ns = vim.api.nvim_create_namespace("vault_calendar")

  --- Redraw the calendar content in the buffer.
  local function redraw()
    local data = render_calendar(state.year, state.month, state.deadlines)
    state.day_positions = data.day_positions
    state.num_days = data.num_days

    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, data.lines)
    vim.bo[state.buf].modifiable = false

    -- Apply highlights
    vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
    for _, hl in ipairs(data.highlights) do
      local group, r, cs, ce = hl[1], hl[2], hl[3], hl[4]
      pcall(vim.api.nvim_buf_add_highlight, state.buf, ns, group, r, cs, ce)
    end

    -- Position cursor on today if it's the current month, otherwise on the 1st
    local today = engine.today()
    local ty, tm, td = today:match("(%d+)-(%d+)-(%d+)")
    ty, tm, td = tonumber(ty), tonumber(tm), tonumber(td)
    local target_day = 1
    if state.year == ty and state.month == tm then
      target_day = td
    end
    local pos = state.day_positions[target_day]
    if pos then
      pcall(vim.api.nvim_win_set_cursor, state.win, { pos.row + 1, pos.col_start + 1 })
    end
  end

  redraw()

  --- Close the calendar window.
  local function close()
    if vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_close(state.win, true)
    end
  end

  --- Navigate months by offset.
  local function shift_month(offset)
    state.month = state.month + offset
    -- Normalize month/year
    while state.month > 12 do
      state.month = state.month - 12
      state.year = state.year + 1
    end
    while state.month < 1 do
      state.month = state.month + 12
      state.year = state.year - 1
    end
    redraw()
  end

  --- Navigate years by offset.
  local function shift_year(offset)
    state.year = state.year + offset
    redraw()
  end

  --- Open the daily log for a given date string. Creates from template if missing.
  ---@param date string YYYY-MM-DD
  ---@param y number year
  ---@param m number month
  ---@param day number day
  local function open_or_create_log(date, y, m, day)
    local path = engine.vault_path .. "/Log/" .. date .. ".md"
    if vim.fn.filereadable(path) == 1 then
      vim.cmd("edit " .. vim.fn.fnameescape(path))
    else
      local t = os.time({ year = y, month = m, day = day })
      local yesterday = os.date("%Y-%m-%d", os.time({ year = y, month = m, day = day - 1 }))
      local tomorrow = os.date("%Y-%m-%d", os.time({ year = y, month = m, day = day + 1 }))
      local weekday_long = os.date("%A, %B ", t) .. day .. os.date(", %Y", t)

      local content = "---\n"
        .. "type: log\n"
        .. "date: " .. date .. "\n"
        .. "tags:\n"
        .. "  - log\n"
        .. "  - daily\n"
        .. "---\n\n"
        .. "<< [[" .. yesterday .. "]] | [[" .. tomorrow .. "]] >>\n\n"
        .. "# " .. weekday_long .. "\n\n"
        .. "---\n\n"
        .. "## Morning Plan\n\n"
        .. "### Today's Focus\n\n"
        .. "> [!target] The single biggest task to complete today. Link to its parent project.\n\n"
        .. "- [ ]\n\n"
        .. "### Other Priorities\n\n"
        .. "- [ ]\n"
        .. "- [ ]\n"
        .. "- [ ]\n\n"
        .. "### Tasks Due Today\n\n"
        .. "```dataview\n"
        .. "TASK FROM \"Projects\"\n"
        .. "WHERE !completed AND due = date(\"" .. date .. "\")\n"
        .. "SORT priority ASC\n"
        .. "```\n\n"
        .. "---\n\n"
        .. "## Work Log\n\n"
        .. "> Add an entry for each work block. Include the time range, project, and what you did.\n\n"
        .. "- **__:__ - __:__** |\n"
        .. "- **__:__ - __:__** |\n"
        .. "- **__:__ - __:__** |\n\n"
        .. "---\n\n"
        .. "## Scratchpad\n\n"
        .. "> Fleeting thoughts, ideas, links, questions -- anything that comes to mind. Process into proper notes later.\n\n"
        .. "-\n\n"
        .. "---\n\n"
        .. "## End of Day\n\n"
        .. "### Completed Today\n\n"
        .. "- [x]\n\n"
        .. "### Blockers & Open Questions\n\n"
        .. "> [!warning] What's preventing progress? What needs to be resolved?\n\n"
        .. "-\n\n"
        .. "### Reflection\n\n"
        .. "> One thing I learned, one decision I made, or one thing that clicked.\n\n"
        .. "-\n\n"
        .. "### Tomorrow's Priorities\n\n"
        .. "- [ ]\n"
        .. "- [ ]\n"
        .. "- [ ]\n"

      engine.run(function()
        engine.write_note("Log/" .. date, content)
      end)
    end
  end

  --- Show tasks due on a given date in an fzf-lua picker.
  ---@param date string YYYY-MM-DD
  ---@param tasks table[] list of {text, file, abs_file, line}
  local function show_deadline_tasks(date, tasks)
    local fzf = require("fzf-lua")

    -- Build display entries: "file:line: task text"
    local entries = {}
    local entry_map = {}
    for _, task in ipairs(tasks) do
      local label = task.file .. ":" .. task.line .. ": " .. task.text
      entries[#entries + 1] = label
      entry_map[label] = task
    end

    fzf.fzf_exec(entries, {
      prompt = "Due " .. date .. "> ",
      previewer = "builtin",
      actions = {
        ["default"] = function(selected)
          if selected and selected[1] then
            local task = entry_map[selected[1]]
            if task then
              vim.cmd("edit +" .. task.line .. " " .. vim.fn.fnameescape(task.abs_file))
            end
          end
        end,
        ["ctrl-s"] = function(selected)
          if selected and selected[1] then
            local task = entry_map[selected[1]]
            if task then
              vim.cmd("split +" .. task.line .. " " .. vim.fn.fnameescape(task.abs_file))
            end
          end
        end,
        ["ctrl-v"] = function(selected)
          if selected and selected[1] then
            local task = entry_map[selected[1]]
            if task then
              vim.cmd("vsplit +" .. task.line .. " " .. vim.fn.fnameescape(task.abs_file))
            end
          end
        end,
      },
    })
  end

  --- Open (or create) the daily log for the day under cursor.
  --- If the day has task deadlines, offers a choice between log and deadline list.
  local function open_day()
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local crow = cursor[1] - 1 -- 0-indexed
    local ccol = cursor[2]     -- 0-indexed
    local day = day_at_cursor(state.day_positions, crow, ccol, state.num_days)
    if not day then
      return
    end

    local date = format_date(state.year, state.month, day)
    local due_tasks = state.deadlines[date]
    local has_due = due_tasks and #due_tasks > 0
    local log_path = engine.vault_path .. "/Log/" .. date .. ".md"
    local has_log = vim.fn.filereadable(log_path) == 1

    -- If only a log exists (no deadlines), open log directly
    if not has_due then
      close()
      open_or_create_log(date, state.year, state.month, day)
      return
    end

    -- If only deadlines exist (no log), show deadline picker directly
    if has_due and not has_log then
      close()
      -- Offer choice: view deadlines or create log
      engine.run(function()
        local choice = engine.select(
          { "Show tasks due (" .. #due_tasks .. ")", "Create daily log" },
          { prompt = date }
        )
        if choice and choice:match("^Show tasks") then
          show_deadline_tasks(date, due_tasks)
        elseif choice and choice:match("^Create") then
          open_or_create_log(date, state.year, state.month, day)
        end
      end)
      return
    end

    -- Both log and deadlines exist: offer all options
    close()
    engine.run(function()
      local choice = engine.select(
        { "Open daily log", "Show tasks due (" .. #due_tasks .. ")" },
        { prompt = date }
      )
      if choice and choice:match("^Open daily") then
        open_or_create_log(date, state.year, state.month, day)
      elseif choice and choice:match("^Show tasks") then
        show_deadline_tasks(date, due_tasks)
      end
    end)
  end

  -- -------------------------------------------------------------------------
  -- Key mappings (buffer-local to the calendar buffer)
  -- -------------------------------------------------------------------------
  local kopts = { buffer = state.buf, nowait = true, silent = true }

  vim.keymap.set("n", "q", close, kopts)
  vim.keymap.set("n", "<Esc>", close, kopts)
  vim.keymap.set("n", "<CR>", open_day, kopts)
  vim.keymap.set("n", "l", function() shift_month(1) end, kopts)
  vim.keymap.set("n", "h", function() shift_month(-1) end, kopts)
  vim.keymap.set("n", "L", function() shift_year(1) end, kopts)
  vim.keymap.set("n", "H", function() shift_year(-1) end, kopts)

  -- Also support arrow-key navigation within the grid
  vim.keymap.set("n", "j", function()
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local crow = cursor[1] - 1
    local ccol = cursor[2]
    local current = day_at_cursor(state.day_positions, crow, ccol, state.num_days)
    if current and current + 7 <= state.num_days then
      local pos = state.day_positions[current + 7]
      if pos then
        vim.api.nvim_win_set_cursor(state.win, { pos.row + 1, pos.col_start + 1 })
      end
    end
  end, kopts)

  vim.keymap.set("n", "k", function()
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local crow = cursor[1] - 1
    local ccol = cursor[2]
    local current = day_at_cursor(state.day_positions, crow, ccol, state.num_days)
    if current and current - 7 >= 1 then
      local pos = state.day_positions[current - 7]
      if pos then
        vim.api.nvim_win_set_cursor(state.win, { pos.row + 1, pos.col_start + 1 })
      end
    end
  end, kopts)

  -- Close on BufLeave so the float doesn't linger
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = state.buf,
    once = true,
    callback = close,
  })
end

-- =============================================================================
-- Setup (called from navigate.lua or init.lua)
-- =============================================================================

function M.setup()
  -- Commands and keymaps are registered via navigate.lua setup()
  -- This is here in case calendar.lua is loaded standalone.
  define_highlights()
end

return M
