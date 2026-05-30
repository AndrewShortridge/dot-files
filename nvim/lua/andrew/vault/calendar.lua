local config = require("andrew.vault.config")
local engine = require("andrew.vault.engine")
local link_utils = require("andrew.vault.link_utils")
local ui = require("andrew.vault.ui")
local cleanup = require("andrew.vault.resource_cleanup")
local vault_index = require("andrew.vault.vault_index")
local gen_cache = require("andrew.vault.gen_cache")
local date_utils = require("andrew.vault.date_utils")
local log = require("andrew.vault.vault_log").scope("calendar")
local pat = require("andrew.vault.patterns")

local M = {}

-- Highlight groups defined centrally by vault/colors.lua

-- Import date utilities
local days_in_month = date_utils.days_in_month
local first_weekday = date_utils.first_weekday
local format_date = date_utils.format_date

--- Month names for display.
local month_names = {
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
}

-- =============================================================================
-- Task Deadline Cache
-- =============================================================================

--- Get the calendar indicator config (memoized reference).
---@return table[] indicators
local function get_indicators()
  local cal_config = config.calendar or {}
  return cal_config.indicators or {
    { key = "due", sources = { "frontmatter.due", "inline.due", "task.due" } },
    { key = "scheduled", sources = { "frontmatter.scheduled", "inline.scheduled", "task.scheduled" } },
  }
end

--- Scan a single file's date entries and merge them into an existing date table.
--- Extracted from scan_dates_from_index for incremental updates.
---@param entry VaultIndexEntry
---@param rel_path string
---@param dates table<string, table[]> date table to merge into
---@param seen? table deduplication set (created if nil)
local function scan_single_file_dates(entry, rel_path, dates, seen)
  seen = seen or {}
  local indicators = get_indicators()

  local display = entry.frontmatter and entry.frontmatter.title
    and tostring(entry.frontmatter.title)
    or entry.basename
    or link_utils.rel_to_stem(rel_path)

  local function add_date(date_str, item, kind)
    if not date_str then return end
    local seen_key = rel_path .. "|" .. date_str .. "|" .. kind
    if seen[seen_key] then return end
    seen[seen_key] = true
    if not dates[date_str] then
      dates[date_str] = {}
    end
    dates[date_str][#dates[date_str] + 1] = item
  end

  for _, indicator in ipairs(indicators) do
    for _, source in ipairs(indicator.sources) do
      local scope, field = source:match("^(%w+)%.(.+)$")
      if scope then
        if scope == "frontmatter" or scope == "inline" then
          local source_tbl = scope == "frontmatter" and entry.frontmatter or entry.inline_fields
          local val = source_tbl and source_tbl[field]
          if type(val) == "string" then
            local date_str = val:match(pat.ISO_DATE_PREFIX)
            if date_str then
              add_date(date_str, {
                text = display,
                file = rel_path,
                abs_file = entry.abs_path,
                line = 1,
                kind = indicator.key,
              }, indicator.key)
            end
          end

        elseif scope == "task" then
          if entry.tasks then
            for _, task in ipairs(entry.tasks) do
              local date_str = task[field]
              if date_str then
                local task_text = task.text
                task_text = task_text:gsub("%[" .. field .. "::[^%]]*%]", "")
                task_text = task_text:gsub("%(" .. field .. "::[^%)]*%)", "")
                task_text = task_text:gsub(field .. "::%s*%d%d%d%d%-%d%d%-%d%d", "")
                task_text = vim.trim(task_text)
                if task_text == "" then task_text = "(task)" end
                add_date(date_str, {
                  text = task_text,
                  file = rel_path,
                  abs_file = entry.abs_path,
                  line = task.line,
                  kind = indicator.key,
                }, indicator.key)
              end
            end
          end
        end
      end
    end
  end
end

--- Scan the vault index for all date-bearing items, grouped by date string.
--- Supports multiple indicator types (due, scheduled, etc.) as configured in
--- config.calendar.indicators. Each item carries a `kind` field for display.
--- Returns "YYYY-MM-DD" -> { {text, file, abs_file, line, kind}, ... }
---@return table<string, table[]>
local function scan_dates_from_index()
  local stop = require("andrew.vault.memory_profiler").start_timer("calendar.scan_dates")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    log.debug("index not ready, deferring deadline scan")
    if idx then
      idx:wait_for_ready(function()
        vim.schedule(function()
          _deadline_cache:invalidate()
        end)
      end, "calendar.indicators")
    end
    stop()
    return {}, nil
  end

  local dates = {}
  local seen = {}
  for rel_path, entry in pairs(idx:snapshot_files()) do
    scan_single_file_dates(entry, rel_path, dates, seen)
  end
  stop()
  return dates
end

-- Module-level cache so deadline data persists across month navigation and
-- calendar re-opens without re-scanning the entire vault each time.
-- Uses gen_cache for automatic generation-based invalidation with partial support.
local _deadline_cache = gen_cache.gen_cache(function(_idx)
  return scan_dates_from_index()
end, {
  key_fn = function() return engine.vault_path end,
  partial_fn = function(cached, idx, ctx)
    if not cached then return cached end
    -- Collect affected relative paths
    local affected = {}
    for _, list in ipairs({ ctx.changed_paths, ctx.deleted_paths }) do
      if list then
        for _, p in ipairs(list) do affected[p] = true end
      end
    end

    -- Remove date entries contributed by affected files
    for date_str, items in pairs(cached) do
      for i = #items, 1, -1 do
        if affected[items[i].file] then
          table.remove(items, i)
        end
      end
      if #items == 0 then cached[date_str] = nil end
    end

    -- Rescan changed and added files
    local rescan_paths = {}
    for _, list in ipairs({ ctx.changed_paths, ctx.added_paths }) do
      if list then
        for _, p in ipairs(list) do rescan_paths[#rescan_paths + 1] = p end
      end
    end
    for _, p in ipairs(rescan_paths) do
      local entry = idx.files[p]
      if entry then
        scan_single_file_dates(entry, p, cached)
      end
    end

    return cached
  end,
})

--- Get cached deadline data, returning from gen_cache (auto-rebuilds on
--- index generation change or vault path switch).
---@return table<string, table[]>
local function get_deadlines()
  return _deadline_cache.get() or {}
end


--- Extract the set of days in a given month that have date indicators.
--- Returns a table mapping day_number -> set of indicator keys.
---@param year number
---@param month number
---@param deadlines table full date map from get_deadlines()
---@return table<number, table<string, boolean>> day -> { due=true, scheduled=true, ... }
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

-- =============================================================================
-- Calendar State
-- =============================================================================

-- The calendar state is local to the floating window session.
-- We store it in a table that gets created per calendar() invocation.

-- =============================================================================
-- Calendar Rendering
-- =============================================================================

--- Cached log directory scan.  Keyed by "YYYY-MM"; invalidated when the
--- vault index generation changes (covers file creation/deletion and
--- FocusGained events).
local _log_cache = gen_cache.keyed_gen_cache(function(_idx, key)
  local log_dir = engine.vault_path .. "/Log"
  local has_log = {}

  if vim.fn.isdirectory(log_dir) == 0 then return has_log end

  -- Use vim.uv.fs_scandir (non-blocking) instead of vim.fn.readdir
  local handle = vim.uv.fs_scandir(log_dir)
  if handle then
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if (ftype == "file" or ftype == nil) and name:sub(1, 7) == key
        and name:match(pat.ISO_DATE_MD) then
        local day = tonumber(name:sub(9, 10))
        if day then
          has_log[day] = true
        end
      end
    end
  end

  return has_log
end)

--- Build the set of days in `year-month` that have daily log files.
---@param year number
---@param month number
---@return table<number, boolean> day_number -> true
local function scan_logs_for_month(year, month)
  local key = string.format("%04d-%02d", year, month)
  return _log_cache.get(key) or {}
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
  local day_indicators = indicators_for_month(year, month, deadlines)
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
  for _, wd in ipairs(weekdays) do
    hdr = hdr .. " " .. wd
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

  -- Track whether any indicators are visible this month (for legend)
  local month_has_deadlines = false
  local month_has_scheduled = false

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
    local indicators = day_indicators[day]
    local is_due = indicators and indicators.due
    local is_sched = indicators and indicators.scheduled

    if is_due then month_has_deadlines = true end
    if is_sched then month_has_scheduled = true end

    if is_today then
      -- Today always wins with its distinctive green background
      highlights[#highlights + 1] = { "VaultCalendarToday", row_idx, col_start, col_end }
    elseif is_logged and is_due then
      -- Combined: log + deadline -> orange background
      highlights[#highlights + 1] = { "VaultCalendarLogDeadline", row_idx, col_start, col_end }
    elseif is_due then
      -- Deadline only -> cyan/teal
      highlights[#highlights + 1] = { "VaultCalendarDeadline", row_idx, col_start, col_end }
    elseif is_logged and is_sched then
      -- Combined: log + scheduled -> orange background
      highlights[#highlights + 1] = { "VaultCalendarLogDeadline", row_idx, col_start, col_end }
    elseif is_sched then
      -- Scheduled only -> purple
      highlights[#highlights + 1] = { "VaultCalendarScheduled", row_idx, col_start, col_end }
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
  if month_has_scheduled then
    legend = legend .. "  *sched"
  end
  if month_has_deadlines and next(has_log) ~= nil then
    legend = legend .. "  *log+due"
  end
  lines[#lines] = legend
  -- Apply highlights to the legend markers (the * characters)
  -- Each token is found independently via string.find() from position 1.
  -- Highlight ranges are derived from the find result + token length, not manual offsets.
  -- Longer tokens are searched first so shorter substrings (e.g. "*log" inside "*log+due")
  -- don't claim positions that belong to longer tokens.
  local legend_tokens = {
    { token = "*today", hl_group = "VaultCalendarToday" },
    { token = "*log+due", hl_group = "VaultCalendarLogDeadline", cond = month_has_deadlines and next(has_log) ~= nil },
    { token = "*log", hl_group = "VaultCalendarHasLog" },
    { token = "*due", hl_group = "VaultCalendarDeadline" },
    { token = "*sched", hl_group = "VaultCalendarScheduled", cond = month_has_scheduled },
  }
  local claimed = {} ---@type table<number, boolean>
  for _, entry in ipairs(legend_tokens) do
    if entry.cond == nil or entry.cond then
      local pos = legend:find(entry.token, 1, true)
      if pos and not claimed[pos] then
        claimed[pos] = true
        local label_len = #entry.token - 1 -- length of label without the leading "*"
        -- pos is 1-indexed; nvim highlight cols are 0-indexed
        -- "*" marker: 1 char at [pos-1, pos)
        -- label text: label_len chars at [pos, pos+label_len)
        highlights[#highlights + 1] = { entry.hl_group, legend_row, pos - 1, pos }
        highlights[#highlights + 1] = { "VaultCalendarLegend", legend_row, pos, pos + label_len }
      end
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
  M.setup() -- Ensure cache is registered (idempotent)
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

  -- Create floating window via shared UI module
  local float = ui.create_float_display({
    title = "Vault Calendar",
    lines = {},
    width = 34,
    height = 18,
    cursor_line = false,
  })
  state.buf = float.buf
  state.win = float.win

  -- Calendar-specific window options
  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  vim.wo[state.win].signcolumn = "no"

  local ns = vim.api.nvim_create_namespace("vault_calendar")

  -- Previous lines for incremental diffing (nil = first render)
  local prev_lines = nil

  --- Redraw the calendar content in the buffer.
  --- Uses incremental diffing: only updates lines that actually changed.
  local function redraw()
    local data = render_calendar(state.year, state.month, state.deadlines)
    state.day_positions = data.day_positions
    state.num_days = data.num_days

    vim.bo[state.buf].modifiable = true
    prev_lines = ui.apply_incremental_render(state.buf, ns, prev_lines, data.lines, data.highlights)
    vim.bo[state.buf].modifiable = false

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
      local ok, err = pcall(vim.api.nvim_win_set_cursor, state.win, { pos.row + 1, pos.col_start + 1 })
      if not ok then log.debug("failed to set cursor to calendar day position: %s", err) end
    end
  end

  redraw()

  --- Close the calendar window.
  local function close()
    cleanup.close_win(state.win)
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
  local function open_or_create_log(date)
    local path = engine.vault_path .. "/Log/" .. date .. ".md"
    if vim.fn.filereadable(path) == 1 then
      vim.cmd("edit " .. vim.fn.fnameescape(path))
    else
      local daily_log = require("andrew.vault.templates.daily_log")
      local content = daily_log.generate(engine, date)
      engine.run(function()
        engine.write_note(config.dirs.log .. "/" .. date, content)
      end)
    end
  end

  --- Show date-bearing items on a given date in an fzf-lua picker.
  ---@param date string YYYY-MM-DD
  ---@param tasks table[] list of {text, file, abs_file, line, kind}
  local function show_deadline_tasks(date, tasks)
    local fzf = require("fzf-lua")

    -- Build display entries: "[kind] file:line: task text"
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
    local items = state.deadlines[date]
    local has_items = items and #items > 0
    local log_path = engine.vault_path .. "/Log/" .. date .. ".md"
    local has_log = vim.fn.filereadable(log_path) == 1

    -- If no items, open/create log directly
    if not has_items then
      close()
      open_or_create_log(date)
      return
    end

    -- Build kind summary for display
    local kind_counts = {}
    for _, item in ipairs(items) do
      local k = item.kind or "due"
      kind_counts[k] = (kind_counts[k] or 0) + 1
    end
    local summary_parts = {}
    for kind, count in pairs(kind_counts) do
      summary_parts[#summary_parts + 1] = kind .. ": " .. count
    end
    local summary = table.concat(summary_parts, ", ")

    -- If items exist but no log, offer choice
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
          open_or_create_log(date)
        end
      end)
      return
    end

    -- Both log and items exist: offer all options
    close()
    engine.run(function()
      local choice = engine.select(
        { "Open daily log", "Show items (" .. summary .. ")" },
        { prompt = date }
      )
      if choice and choice:match("^Open daily") then
        open_or_create_log(date)
      elseif choice and choice:match("^Show items") then
        show_deadline_tasks(date, items)
      end
    end)
  end

  -- -------------------------------------------------------------------------
  -- Key mappings (buffer-local to the calendar buffer)
  -- -------------------------------------------------------------------------
  local kopts = { buffer = state.buf, nowait = true, silent = true }

  -- q and <Esc> are already mapped by ui.create_float_display()
  vim.keymap.set("n", "<CR>", open_day, kopts)
  vim.keymap.set("n", "l", function() shift_month(1) end, kopts)
  vim.keymap.set("n", "h", function() shift_month(-1) end, kopts)
  vim.keymap.set("n", "L", function() shift_year(1) end, kopts)
  vim.keymap.set("n", "H", function() shift_year(-1) end, kopts)

  -- Also support arrow-key navigation within the grid
  local function move_week(direction)
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local crow = cursor[1] - 1
    local ccol = cursor[2]
    local current = day_at_cursor(state.day_positions, crow, ccol, state.num_days)
    local target = current and (current + 7 * direction)
    if target and target >= 1 and target <= state.num_days then
      local pos = state.day_positions[target]
      if pos then
        vim.api.nvim_win_set_cursor(state.win, { pos.row + 1, pos.col_start + 1 })
      end
    end
  end

  vim.keymap.set("n", "j", function() move_week(1) end, kopts)
  vim.keymap.set("n", "k", function() move_week(-1) end, kopts)

  -- Close on BufLeave so the float doesn't linger
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = state.buf,
    once = true,
    callback = close,
  })
end

-- =============================================================================
-- Setup (called from init.lua)
-- =============================================================================

function M.setup()
  engine.register_cache({
    name = "calendar_deadlines",
    module = "andrew.vault.calendar",
    invalidate = function()
      _deadline_cache.invalidate()
      _log_cache.invalidate()
    end,
    stats = function()
      local data = _deadline_cache.get()
      return {
        entries = data and vim.tbl_count(data) or 0,
      }
    end,
  })

  do
    local profiler = require("andrew.vault.memory_profiler")
    profiler.register_cache({
      name = "calendar_deadlines",
      get_size = function()
        local data = _deadline_cache.get()
        return data and vim.tbl_count(data) or 0
      end,
      get_capacity = function() return nil end,
      get_hits = function() return _deadline_cache.get_hits() end,
      get_misses = function() return _deadline_cache.get_misses() end,
      get_evictions = function() return 0 end,
    })
  end

  -- Commands and keymaps are registered via navigate.lua setup()
end

return M
