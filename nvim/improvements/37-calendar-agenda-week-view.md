# 37 - Calendar Agenda and Week View Modes

**Priority:** Medium -- usability enhancement (currently month-only)
**Status:** Planned
**Files:** `lua/andrew/vault/calendar.lua`, `lua/andrew/vault/config.lua`, `lua/andrew/vault/colors.lua`

## Summary

The calendar module (`calendar.lua`) currently provides only a month grid view.
This improvement adds two additional view modes -- **week view** and **agenda
view** -- giving users day-level detail and a linear task list without leaving
the calendar workflow. All three modes share the same cached deadline data
(`get_deadlines()` / `scan_dates_from_index()`) and the same highlight groups.
Mode switching is instantaneous because the float buffer is reused and only the
render function changes.

## Current State

### Month View (existing)

- 7x6 grid of day cells, 4 chars wide each (`render_calendar()`).
- Floating window: 34 columns, 18 rows, created via `ui.create_float_display()`.
- Navigation: `h/l` shift month, `H/L` shift year, `j/k` move cursor by week,
  `<CR>` opens daily log or shows date items in fzf picker.
- Indicators: per-day highlight groups (`VaultCalendarToday`,
  `VaultCalendarDeadline`, `VaultCalendarScheduled`, `VaultCalendarHasLog`,
  `VaultCalendarLogDeadline`).
- Deadline data: `get_deadlines()` returns `"YYYY-MM-DD" -> items[]`, cached by
  vault index generation via `_deadline_cache`.
- Legend and footer with keybinding hints at bottom.

### What is Missing

1. No way to see **which tasks/events** fall on a day without pressing `<CR>`
   and going through the fzf picker.
2. No week-level view showing individual items per day in a compact layout.
3. No scrollable agenda list for planning across multiple days.
4. No unified mode-switching -- the user must close and reopen the calendar.

## Detailed Implementation

### Architecture Overview

```
calendar.lua (existing module, extended)
  |
  |-- state.mode = "month" | "week" | "agenda"
  |
  |-- render_month()      -- existing render_calendar(), renamed
  |-- render_week()       -- NEW: 7-day columnar layout with items
  |-- render_agenda()     -- NEW: vertical day-by-day task list
  |
  |-- redraw()            -- dispatches to the active render function
  |-- set_keymaps()       -- NEW: centralized keymap setup (mode-aware)
```

All three renderers return the same shape:
```lua
{
  lines = string[],
  highlights = { {group, row, col_start, col_end} }[],
  -- mode-specific position data:
  day_positions = table,       -- month mode
  item_positions = table[],    -- week/agenda mode: { item, row, col? }
}
```

The floating window is created once and resized as needed when switching modes.
The `state` table gains a `mode` field and retains `year`, `month`,
`selected_day` across mode transitions.

### 1. Week View

#### Layout

The week view shows 7 days in a horizontal layout. Each day is a column, and
items for that day are listed vertically within the column. The window is wider
than the month view to accommodate item text.

```
         Week of 02 Mar 2026
  Mon 02    Tue 03    Wed 04    Thu 05    Fri 06    Sat 07    Sun 08
 ─────────────────────────────────────────────────────────────────────
  *Review   Draft                         Lab mtg
   paper    proposal                      (P1)
  *Submit                                 Seminar
   report                                  prep
   (P2)

 *today  *log  *due  *sched
 h/l: day  H/L: week  m: month  a: agenda  <CR>: open  q: close
```

- Each column is `col_width` characters wide (configurable, default 12).
- Window width: `7 * col_width + padding` (approximately 90 columns).
- Window height: dynamic, based on the maximum number of items in any single
  day, capped at `max_week_rows` (default 20).
- Day headers show abbreviated weekday + day number. Today's column uses
  `VaultCalendarToday` highlight on the header.
- Items show truncated task text. Priority shown as `(P1)` suffix.
- Items are colored by kind: `VaultCalendarDeadline` for due,
  `VaultCalendarScheduled` for scheduled.
- Days with daily logs have a `*` marker in the header.

#### Week Boundaries

The week is anchored to `state.selected_day`. The Monday-Sunday range
containing that day is computed:

```lua
local function week_bounds(date_str)
  -- Returns (monday_str, sunday_str) for the ISO week containing date_str
  local y, m, d = date_str:match("(%d+)-(%d+)-(%d+)")
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  local wday = tonumber(os.date("%w", t))  -- 0=Sun
  local days_since_monday = (wday == 0) and 6 or (wday - 1)
  local monday_ts = t - days_since_monday * 86400
  local sunday_ts = monday_ts + 6 * 86400
  return os.date("%Y-%m-%d", monday_ts), os.date("%Y-%m-%d", sunday_ts)
end
```

#### Navigation

| Key   | Action                                    |
|-------|-------------------------------------------|
| `h`   | Move selected day back 1 day              |
| `l`   | Move selected day forward 1 day           |
| `H`   | Move selected day back 7 days (prev week) |
| `L`   | Move selected day forward 7 days          |
| `j`   | Move cursor down within current day column|
| `k`   | Move cursor up within current day column  |
| `<CR>`| Open item under cursor (jump to file:line)|
| `m`   | Switch to month view                      |
| `a`   | Switch to agenda view                     |
| `t`   | Jump to today                             |
| `q`   | Close calendar                            |

#### Renderer: `render_week()`

```lua
--- Render the week view into buffer lines.
---@param state table  calendar state
---@param deadlines table  full deadline map
---@param width number  available window width
---@return table { lines, highlights, item_positions }
local function render_week(state, deadlines, width)
  local lines = {}
  local highlights = {}
  local item_positions = {}  -- { item, row, col_start, col_end, date_str }

  local today = engine.today()
  local monday, sunday = week_bounds(state.selected_day)
  local col_width = math.floor((width - 2) / 7)

  -- Title line
  local title = "  Week of " .. format_date_short(monday) .. " " .. monday:sub(1, 4)
  lines[1] = title
  highlights[#highlights + 1] = { "VaultCalendarHeader", 0, 0, #title }

  lines[2] = ""

  -- Day headers
  local weekdays = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
  local header_line = ""
  local day_dates = {}  -- 1..7 -> "YYYY-MM-DD"
  for i = 0, 6 do
    local ds = date_add(monday, i)
    day_dates[i + 1] = ds
    local d_num = ds:sub(9, 10)
    local label = string.format(" %-" .. (col_width - 1) .. "s", weekdays[i + 1] .. " " .. d_num)
    local col_start = #header_line
    header_line = header_line .. label
    local col_end = #header_line

    -- Highlight today's header
    if ds == today then
      highlights[#highlights + 1] = { "VaultCalendarToday", 2, col_start, col_end }
    elseif i >= 5 then  -- weekend
      highlights[#highlights + 1] = { "VaultCalendarWeekend", 2, col_start, col_end }
    end
  end
  lines[3] = header_line

  -- Separator
  lines[4] = string.rep("─", #header_line)
  highlights[#highlights + 1] = { "VaultCalendarDim", 3, 0, #lines[4] }

  -- Collect items per day column
  local day_items = {}  -- 1..7 -> { items }
  local max_items = 0
  for i = 1, 7 do
    local ds = day_dates[i]
    day_items[i] = deadlines[ds] or {}
    -- Sort by priority (ascending), then text
    table.sort(day_items[i], function(a, b)
      local pa = tonumber(a.priority) or 99
      local pb = tonumber(b.priority) or 99
      if pa ~= pb then return pa < pb end
      return (a.text or "") < (b.text or "")
    end)
    if #day_items[i] > max_items then
      max_items = #day_items[i]
    end
  end

  -- Render item rows (one row per vertical slot across all 7 columns)
  for row_i = 1, max_items do
    local row_line = ""
    local row_idx = #lines  -- 0-indexed row for highlights
    for col_i = 1, 7 do
      local item = day_items[col_i][row_i]
      local col_start = #row_line
      if item then
        local text = truncate(item.text or "", col_width - 2)
        if item.priority then
          local avail = col_width - 2 - 5  -- room for " (P1)"
          if avail > 3 then
            text = truncate(item.text or "", avail) .. " (P" .. item.priority .. ")"
          end
        end
        local cell = string.format(" %-" .. (col_width - 1) .. "s", text)
        row_line = row_line .. cell
        local col_end = #row_line

        -- Highlight by kind
        local hl_group = "VaultCalendarDeadline"
        if item.kind == "scheduled" then
          hl_group = "VaultCalendarScheduled"
        end
        highlights[#highlights + 1] = { hl_group, row_idx, col_start, col_end }

        item_positions[#item_positions + 1] = {
          item = item,
          row = row_idx,
          col_start = col_start,
          col_end = col_end,
          date_str = day_dates[col_i],
        }
      else
        row_line = row_line .. string.rep(" ", col_width)
      end
    end
    lines[#lines + 1] = row_line
  end

  -- Empty state
  if max_items == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  No items this week."
    highlights[#highlights + 1] = { "VaultCalendarDim", #lines - 1, 0, #lines[#lines] }
  end

  -- Legend
  lines[#lines + 1] = ""
  local legend = " *today  *due  *sched"
  lines[#lines + 1] = legend
  -- (highlight legend markers same as month view)

  -- Footer
  lines[#lines + 1] = ""
  local footer = " h/l: day  H/L: week  m: month  a: agenda  <CR>: open  q: close"
  lines[#lines + 1] = footer
  highlights[#highlights + 1] = { "VaultCalendarDim", #lines - 1, 0, #footer }

  return {
    lines = lines,
    highlights = highlights,
    item_positions = item_positions,
    monday = monday,
    sunday = sunday,
    day_dates = day_dates,
  }
end
```

### 2. Agenda View

The agenda view is a vertical, scrollable list of upcoming days with their
tasks and events. It is the most information-dense view and complements the
existing `task_timeline.lua` by being calendar-centric (showing all date items,
not just tasks) and integrated into the calendar workflow.

#### Layout

```
  Agenda  (14 days from Mon 02 Mar)
 ──────────────────────────────────────────

  OVERDUE
  ────────
  Sat 28 Feb
    [due] Review paper draft  (P1)        Projects/paper.md:45
    [due] Submit grant report (P2)        Areas/grants.md:12

  TODAY - Mon 02 Mar
  ────────
    [due] Lab meeting prep    (P1)        Log/2026-03-02.md:8
    [sched] Write introduction            Projects/paper.md:67

  Tue 03 Mar
  ────────
    [sched] Draft proposal                Projects/proposal.md:3

  Wed 04 Mar
  ────────
    (no items)

  ...

 j/k: navigate  <CR>: open  f: filter  m: month  w: week  q: close
```

- **Overdue section** at the top: all items with dates before today, grouped by
  date, sorted oldest first. Uses `VaultCalendarDeadline` highlight with bold.
- **Today section** prominently labeled with `VaultCalendarToday` highlight.
- **Upcoming days** listed chronologically for `agenda_days` days (configurable,
  default 14).
- Each item line shows: `[kind] text (priority) file:line`.
- Items within a day are sorted by priority (ascending), then alphabetically.
- Days with no items show `(no items)` in dim text, or are skipped entirely
  (configurable via `agenda_hide_empty`).
- File path shown in dim text at the right margin for context.

#### Overdue Collection

```lua
--- Collect overdue items (dates strictly before today).
---@param deadlines table  full deadline map
---@param today string  "YYYY-MM-DD"
---@return table<string, table[]>  date -> items, sorted by date ascending
local function collect_overdue(deadlines, today)
  local overdue = {}
  for date_str, items in pairs(deadlines) do
    if date_str < today then
      overdue[date_str] = items
    end
  end
  return overdue
end
```

#### Filtering

The agenda view supports interactive filtering via `f` key:

```lua
-- Filter prompt (reuses filter_utils.passes_task_filter pattern)
vim.keymap.set("n", "f", function()
  vim.ui.input({ prompt = "Filter (text/tag/priority): " }, function(input)
    if input == nil then return end
    if input == "" then
      state.agenda_filter = nil
    else
      -- Parse simple filter syntax:
      -- "P1" or "p1"       -> priority filter
      -- "#tag"             -> tag filter
      -- anything else      -> text substring match
      local filter = {}
      if input:match("^[Pp](%d)$") then
        filter.priority_max = tonumber(input:match("(%d)$"))
      elseif input:match("^#") then
        filter.tag = input:sub(2)
      else
        filter.text_pattern = input
      end
      state.agenda_filter = filter
    end
    redraw()
  end)
end, kopts)
```

#### Item Matching for Filters

Items from `get_deadlines()` carry `text`, `file`, `abs_file`, `line`, `kind`
fields. For priority filtering, the agenda renderer needs to cross-reference
back to the vault index task entry. The approach:

```lua
--- Check if a deadline item passes the agenda filter.
---@param item table  { text, file, abs_file, line, kind }
---@param filter table|nil  { priority_max?, tag?, text_pattern? }
---@return boolean
local function passes_agenda_filter(item, filter)
  if not filter then return true end

  if filter.text_pattern and filter.text_pattern ~= "" then
    if not (item.text or ""):lower():find(filter.text_pattern:lower(), 1, true) then
      return false
    end
  end

  -- Priority filtering: extract from item if available, or from vault index
  if filter.priority_max then
    -- Items from scan_dates_from_index don't carry priority directly.
    -- We need to add priority to the scan output (see Data Changes below).
    if item.priority then
      if tonumber(item.priority) > filter.priority_max then return false end
    end
  end

  if filter.tag then
    -- Tag filtering: check if the source file has the tag
    local tags = filter_utils.get_tags(item.abs_file)
    if not tags[filter.tag] and not tags[filter.tag:lower()] then
      return false
    end
  end

  return true
end
```

#### Renderer: `render_agenda()`

```lua
--- Render the agenda view into buffer lines.
---@param state table  calendar state (includes agenda_days, agenda_filter)
---@param deadlines table  full deadline map
---@param width number  available window width
---@return table { lines, highlights, item_positions }
local function render_agenda(state, deadlines, width)
  local lines = {}
  local highlights = {}
  local item_positions = {}

  local today = engine.today()
  local agenda_days = state.agenda_days or 14
  local filter = state.agenda_filter
  local hide_empty = state.agenda_hide_empty

  -- Title
  local title = "  Agenda  (" .. agenda_days .. " days from " .. format_date_short(today) .. ")"
  lines[1] = title
  highlights[#highlights + 1] = { "VaultCalendarHeader", 0, 0, #title }
  lines[2] = " " .. string.rep("─", width - 2)
  highlights[#highlights + 1] = { "VaultCalendarDim", 1, 0, width }

  local function add_line(text)
    lines[#lines + 1] = text
    return #lines - 1
  end

  local function add_hl(group, row, cs, ce)
    highlights[#highlights + 1] = { group, row, cs, ce }
  end

  --- Render items for a single date.
  ---@param date_str string
  ---@param items table[]
  ---@param label string|nil  extra label (e.g. "OVERDUE 3d", "TODAY")
  ---@param header_hl string  highlight group for the date header
  local function render_day(date_str, items, label, header_hl)
    -- Filter items
    local filtered = {}
    for _, item in ipairs(items) do
      if passes_agenda_filter(item, filter) then
        filtered[#filtered + 1] = item
      end
    end

    if #filtered == 0 and hide_empty then return end

    -- Date header
    local hdr = "  " .. format_date_short(date_str)
    if label then
      hdr = hdr .. "  " .. label
    end
    add_line("")
    local row = add_line(hdr)
    add_hl(header_hl, row, 0, #hdr)
    row = add_line("  " .. string.rep("─", math.min(40, width - 4)))
    add_hl("VaultCalendarDim", row, 0, -1)

    if #filtered == 0 then
      row = add_line("    (no items)")
      add_hl("VaultCalendarDim", row, 0, -1)
      return
    end

    -- Sort: priority ascending, then text
    table.sort(filtered, function(a, b)
      local pa = tonumber(a.priority) or 99
      local pb = tonumber(b.priority) or 99
      if pa ~= pb then return pa < pb end
      return (a.text or "") < (b.text or "")
    end)

    for _, item in ipairs(filtered) do
      local kind_label = item.kind and ("[" .. item.kind .. "]") or "[due]"
      local prio = item.priority and (" (P" .. item.priority .. ")") or ""
      local text = truncate(item.text or "", width - 30)
      local file_hint = item.file or ""
      local item_line = string.format("    %-7s %s%s", kind_label, text, prio)
      -- Right-align file hint
      local pad_needed = width - #item_line - #file_hint - 2
      if pad_needed > 2 then
        item_line = item_line .. string.rep(" ", pad_needed) .. file_hint
      end

      row = add_line(item_line)

      -- Highlight kind bracket
      local kind_hl = "VaultCalendarDeadline"
      if item.kind == "scheduled" then
        kind_hl = "VaultCalendarScheduled"
      end
      add_hl(kind_hl, row, 4, 4 + #kind_label)

      -- Dim the file hint
      if pad_needed > 2 then
        add_hl("VaultCalendarDim", row, #item_line - #file_hint, #item_line)
      end

      item_positions[#item_positions + 1] = {
        item = item,
        row = row,
      }
    end
  end

  -- ---- Overdue section ----
  local overdue_dates = {}
  for date_str, _ in pairs(deadlines) do
    if date_str < today then
      overdue_dates[#overdue_dates + 1] = date_str
    end
  end
  table.sort(overdue_dates)

  if #overdue_dates > 0 then
    local overdue_hdr = "  OVERDUE"
    add_line("")
    local row = add_line(overdue_hdr)
    add_hl("VaultCalendarDeadline", row, 0, #overdue_hdr)

    for _, ds in ipairs(overdue_dates) do
      local days_late = date_utils.days_between(ds, today)
      render_day(ds, deadlines[ds], days_late .. "d overdue", "VaultCalendarDeadline")
    end
  end

  -- ---- Today + upcoming ----
  for offset = 0, agenda_days - 1 do
    local ds = date_add(today, offset)
    local items = deadlines[ds] or {}
    local label = nil
    local hl = "VaultCalendarHeader"

    if offset == 0 then
      label = "TODAY"
      hl = "VaultCalendarToday"
    end

    -- Only render days that have items (or today, always shown)
    if #items > 0 or offset == 0 or not hide_empty then
      render_day(ds, items, label, hl)
    end
  end

  -- Empty state
  if #item_positions == 0 and #overdue_dates == 0 then
    add_line("")
    add_line("  No items in agenda range.")
  end

  -- Footer
  add_line("")
  local footer = " j/k: navigate  <CR>: open  f: filter  m: month  w: week  q: close"
  row = add_line(footer)
  add_hl("VaultCalendarDim", row, 0, #footer)

  return {
    lines = lines,
    highlights = highlights,
    item_positions = item_positions,
  }
end
```

#### Navigation

| Key   | Action                                         |
|-------|------------------------------------------------|
| `j`   | Move cursor to next item                       |
| `k`   | Move cursor to previous item                   |
| `J`   | Jump to next day header                        |
| `K`   | Jump to previous day header                    |
| `<CR>`| Open file at item's line (close float first)   |
| `f`   | Open filter prompt (text/tag/priority)          |
| `F`   | Clear active filter                             |
| `m`   | Switch to month view                           |
| `w`   | Switch to week view                            |
| `+`   | Increase agenda range by 7 days                |
| `-`   | Decrease agenda range by 7 days (min 7)        |
| `t`   | Reset to today                                 |
| `q`   | Close calendar                                 |

### 3. Mode Switching

All three views are accessible from any other view via single-key toggles.
The state is preserved across transitions.

| Key | From any mode | Action                           |
|-----|---------------|----------------------------------|
| `m` | week, agenda  | Switch to month view             |
| `w` | month, agenda | Switch to week view              |
| `a` | month, week   | Switch to agenda view            |
| `v` | any           | Cycle: month -> week -> agenda   |

Mode switching preserves the current `selected_day`. When entering month view,
`state.year` and `state.month` are derived from `selected_day`. When entering
week view, the week containing `selected_day` is shown.

```lua
--- Switch calendar mode, preserving selected day context.
---@param new_mode "month"|"week"|"agenda"
local function switch_mode(new_mode)
  state.mode = new_mode

  -- Sync month/year from selected_day for month view
  if new_mode == "month" then
    local y, m = state.selected_day:match("(%d+)-(%d+)")
    state.year = tonumber(y)
    state.month = tonumber(m)
  end

  -- Resize window for the new mode
  local target_width, target_height
  if new_mode == "month" then
    target_width = 34
    target_height = 18
  elseif new_mode == "week" then
    target_width = math.min(92, ui_width - 4)
    target_height = 24
  elseif new_mode == "agenda" then
    target_width = math.min(80, ui_width - 4)
    target_height = math.min(40, ui_height - 4)
  end

  vim.api.nvim_win_set_width(state.win, target_width)
  vim.api.nvim_win_set_height(state.win, target_height)

  -- Re-center the float
  local ui_info = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
  local new_col = math.floor((ui_info.width - target_width) / 2)
  local new_row = math.floor((ui_info.height - target_height) / 2)
  vim.api.nvim_win_set_config(state.win, {
    relative = "editor",
    col = new_col,
    row = new_row,
  })

  redraw()
end
```

### 4. Unified Redraw Dispatcher

The existing `redraw()` local function inside `M.calendar()` is replaced with a
mode-dispatching version:

```lua
local function redraw()
  local data
  if state.mode == "month" then
    data = render_month(state.year, state.month, state.deadlines)
    state.day_positions = data.day_positions
    state.num_days = data.num_days
    state.item_positions = nil
  elseif state.mode == "week" then
    local win_width = vim.api.nvim_win_get_width(state.win)
    data = render_week(state, state.deadlines, win_width)
    state.item_positions = data.item_positions
    state.day_positions = nil
  elseif state.mode == "agenda" then
    local win_width = vim.api.nvim_win_get_width(state.win)
    data = render_agenda(state, state.deadlines, win_width)
    state.item_positions = data.item_positions
    state.day_positions = nil
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, data.lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, hl in ipairs(data.highlights) do
    pcall(vim.api.nvim_buf_add_highlight, state.buf, ns, hl[1], hl[2], hl[3], hl[4])
  end
end
```

### 5. Unified Keymap Setup

Instead of defining keymaps inline in `M.calendar()`, a centralized
`set_keymaps()` function sets mode-aware bindings. All keymaps are buffer-local
and use the same `kopts` pattern as today.

```lua
local function set_keymaps(buf, state)
  local kopts = { buffer = buf, nowait = true, silent = true }

  -- Mode-switching (always available)
  vim.keymap.set("n", "m", function()
    if state.mode ~= "month" then switch_mode("month") end
  end, kopts)

  vim.keymap.set("n", "w", function()
    if state.mode ~= "week" then switch_mode("week") end
  end, kopts)

  vim.keymap.set("n", "a", function()
    if state.mode ~= "agenda" then switch_mode("agenda") end
  end, kopts)

  vim.keymap.set("n", "v", function()
    local cycle = { month = "week", week = "agenda", agenda = "month" }
    switch_mode(cycle[state.mode] or "month")
  end, kopts)

  -- Navigation: mode-dependent behavior
  vim.keymap.set("n", "h", function()
    if state.mode == "month" then
      shift_month(-1)
    else
      state.selected_day = date_add(state.selected_day, -1)
      redraw()
    end
  end, kopts)

  vim.keymap.set("n", "l", function()
    if state.mode == "month" then
      shift_month(1)
    else
      state.selected_day = date_add(state.selected_day, 1)
      redraw()
    end
  end, kopts)

  vim.keymap.set("n", "H", function()
    if state.mode == "month" then
      shift_year(-1)
    else
      state.selected_day = date_add(state.selected_day, -7)
      redraw()
    end
  end, kopts)

  vim.keymap.set("n", "L", function()
    if state.mode == "month" then
      shift_year(1)
    else
      state.selected_day = date_add(state.selected_day, 7)
      redraw()
    end
  end, kopts)

  -- j/k: grid movement in month, item navigation in week/agenda
  vim.keymap.set("n", "j", function()
    if state.mode == "month" then
      -- existing: move cursor down 1 week in grid
      month_cursor_down()
    else
      -- Move to next item_position
      jump_to_next_item(1)
    end
  end, kopts)

  vim.keymap.set("n", "k", function()
    if state.mode == "month" then
      month_cursor_up()
    else
      jump_to_next_item(-1)
    end
  end, kopts)

  -- <CR>: open item/day
  vim.keymap.set("n", "<CR>", function()
    if state.mode == "month" then
      open_day()
    else
      open_item_at_cursor()
    end
  end, kopts)

  -- t: jump to today (all modes)
  vim.keymap.set("n", "t", function()
    state.selected_day = engine.today()
    if state.mode == "month" then
      local y, m = state.selected_day:match("(%d+)-(%d+)")
      state.year = tonumber(y)
      state.month = tonumber(m)
    end
    redraw()
  end, kopts)

  -- Agenda-specific keys
  vim.keymap.set("n", "f", function()
    if state.mode ~= "agenda" then return end
    vim.ui.input({ prompt = "Filter (text / #tag / P1-5): " }, function(input)
      if input == nil then return end
      if input == "" then
        state.agenda_filter = nil
      else
        state.agenda_filter = parse_filter_input(input)
      end
      redraw()
    end)
  end, kopts)

  vim.keymap.set("n", "F", function()
    if state.mode ~= "agenda" then return end
    state.agenda_filter = nil
    redraw()
  end, kopts)

  vim.keymap.set("n", "+", function()
    if state.mode ~= "agenda" then return end
    state.agenda_days = (state.agenda_days or 14) + 7
    redraw()
  end, kopts)

  vim.keymap.set("n", "-", function()
    if state.mode ~= "agenda" then return end
    state.agenda_days = math.max(7, (state.agenda_days or 14) - 7)
    redraw()
  end, kopts)
end
```

### 6. Item Navigation Helpers

```lua
--- Jump to the next/previous item position in the buffer.
---@param direction number  1 for next, -1 for previous
local function jump_to_next_item(direction)
  if not state.item_positions or #state.item_positions == 0 then return end

  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local crow = cursor[1] - 1  -- 0-indexed

  -- Find the closest item in the given direction
  local best_idx = nil
  if direction > 0 then
    for i, pos in ipairs(state.item_positions) do
      if pos.row > crow then
        best_idx = i
        break
      end
    end
    -- Wrap around
    if not best_idx then best_idx = 1 end
  else
    for i = #state.item_positions, 1, -1 do
      if state.item_positions[i].row < crow then
        best_idx = i
        break
      end
    end
    if not best_idx then best_idx = #state.item_positions end
  end

  if best_idx then
    local pos = state.item_positions[best_idx]
    pcall(vim.api.nvim_win_set_cursor, state.win, { pos.row + 1, 4 })
  end
end

--- Open the item at the current cursor position.
local function open_item_at_cursor()
  if not state.item_positions then return end
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local crow = cursor[1] - 1

  for _, pos in ipairs(state.item_positions) do
    if pos.row == crow then
      local item = pos.item
      close()
      vim.cmd("edit +" .. (item.line or 1) .. " " .. vim.fn.fnameescape(item.abs_file))
      return
    end
  end
end
```

### 7. Data Changes: Enrich `scan_dates_from_index()` Output

The existing `scan_dates_from_index()` builds items with `{text, file,
abs_file, line, kind}`. For the agenda view's priority filtering, we need to
add the `priority` field to task-sourced items:

#### Before (calendar.lua, task scope in `scan_dates_from_index`, ~line 149)

```lua
add_date(date_str, {
  text = task_text,
  file = rel_path,
  abs_file = entry.abs_path,
  line = task.line,
  kind = indicator.key,
}, rel_path, indicator.key)
```

#### After

```lua
add_date(date_str, {
  text = task_text,
  file = rel_path,
  abs_file = entry.abs_path,
  line = task.line,
  kind = indicator.key,
  priority = task.priority,
  status = task.status,
}, rel_path, indicator.key)
```

This is backward-compatible: existing code that does not read `priority` or
`status` is unaffected.

### 8. Configuration Additions

#### Before (config.lua, `M.calendar` section)

```lua
M.calendar = {
  indicators = {
    {
      key = "due",
      label = "due",
      sources = { "frontmatter.due", "inline.due", "task.due" },
    },
    {
      key = "scheduled",
      label = "sched",
      sources = { "frontmatter.scheduled", "inline.scheduled", "task.scheduled" },
    },
  },
  show_created = false,
}
```

#### After

```lua
M.calendar = {
  indicators = {
    {
      key = "due",
      label = "due",
      sources = { "frontmatter.due", "inline.due", "task.due" },
    },
    {
      key = "scheduled",
      label = "sched",
      sources = { "frontmatter.scheduled", "inline.scheduled", "task.scheduled" },
    },
  },
  show_created = false,

  -- Default view mode when opening the calendar.
  -- One of: "month", "week", "agenda"
  default_view = "month",

  -- Number of upcoming days shown in agenda view.
  agenda_days = 14,

  -- Hide empty days in agenda view (days with no items).
  agenda_hide_empty = false,

  -- Week start day for week view boundaries.
  -- 1 = Monday (ISO), 7 = Sunday.
  week_start = 1,

  -- Column width in week view (characters per day column).
  week_col_width = 12,
}
```

### 9. New Highlight Groups

Two new highlight groups are needed for the agenda overdue header and the
agenda item file hint. These are added to `colors.lua`:

```lua
-- In the calendar highlight group section:
VaultCalendarAgendaOverdue = { bold = true, fg = p.calendar_deadline, underdouble = true },
VaultCalendarAgendaFile    = { fg = p.calendar_dim, italic = true },
```

### 10. State Initialization Changes

#### Before (`M.calendar()`, ~line 470)

```lua
local state = {
  year = now.year,
  month = now.month,
  buf = nil,
  win = nil,
  day_positions = {},
  num_days = 0,
  deadlines = deadlines,
}
```

#### After

```lua
local cal_config = config.calendar or {}
local today_str = engine.today()
local state = {
  mode = cal_config.default_view or "month",
  year = now.year,
  month = now.month,
  selected_day = today_str,
  buf = nil,
  win = nil,
  day_positions = {},
  item_positions = nil,
  num_days = 0,
  deadlines = deadlines,
  -- Agenda-specific state
  agenda_days = cal_config.agenda_days or 14,
  agenda_filter = nil,
  agenda_hide_empty = cal_config.agenda_hide_empty or false,
}
```

### 11. Float Creation Changes

The initial float dimensions depend on the starting mode:

```lua
local float_width, float_height
if state.mode == "month" then
  float_width = 34
  float_height = 18
elseif state.mode == "week" then
  float_width = math.min(92, ui_width - 4)
  float_height = 24
elseif state.mode == "agenda" then
  float_width = math.min(80, ui_width - 4)
  float_height = math.min(40, ui_height - 4)
end

local float = ui.create_float_display({
  title = "Vault Calendar",
  lines = {},
  width = float_width,
  height = float_height,
  cursor_line = (state.mode ~= "month"),
})
```

### 12. Relationship to `task_timeline.lua`

The agenda view and the task timeline serve complementary purposes:

| Aspect         | Task Timeline                      | Calendar Agenda                     |
|----------------|------------------------------------|-------------------------------------|
| Data source    | Tasks only (vault index tasks)     | All date items (tasks + frontmatter + inline fields) |
| Grouping       | Overdue / Today / Upcoming zones   | Per-day chronological list          |
| Filtering      | `filter_utils.passes_task_filter`  | Custom agenda filter (text/tag/priority) |
| Access         | `:VaultTimeline` / `<leader>vxt`   | Calendar `a` key / `config.calendar.default_view = "agenda"` |
| Integration    | Standalone float                   | Part of calendar mode system        |

The agenda view does NOT replace the timeline; it complements it by being
accessible from within the calendar workflow and by including non-task date
items (frontmatter due dates, scheduled dates, etc.).

## Test Cases

### 1. Mode Switching Preserves Context

```
Steps:
  1. Open calendar (month view, March 2026)
  2. Navigate to March 15 with cursor
  3. Press 'w' to switch to week view
  4. Verify: week containing March 15 is shown (Mon 09 - Sun 15 or Mon 16 - Sun 22)
  5. Press 'a' to switch to agenda view
  6. Verify: agenda starts from today, overdue section visible if applicable
  7. Press 'm' to return to month view
  8. Verify: still showing March 2026

Expected: No crashes, state preserved across transitions.
```

### 2. Week View Item Display

```
Setup: Create vault tasks with due dates across a single week.
  - Task A: due 2026-03-02 (Monday), priority 1
  - Task B: due 2026-03-02 (Monday), priority 3
  - Task C: due 2026-03-04 (Wednesday), scheduled

Steps:
  1. Open calendar, press 'w'
  2. Navigate to week of March 2

Expected:
  - Monday column shows Task A (P1) above Task B (P3)
  - Wednesday column shows Task C with scheduled highlight
  - Other columns empty
  - Today column (March 2) has VaultCalendarToday highlight on header
```

### 3. Agenda View Overdue Section

```
Setup: Create a task with due date 2026-02-25 (5 days before today).

Steps:
  1. Open calendar, press 'a'

Expected:
  - "OVERDUE" header appears at top
  - Feb 25 entry shown with "5d overdue" label
  - Item highlighted with VaultCalendarDeadline
  - Today section follows below
```

### 4. Agenda Filtering

```
Setup: Multiple tasks across several days with varying priorities and tags.

Steps:
  1. Open agenda view
  2. Press 'f', type "P1", press Enter
  3. Verify: only priority 1 items shown
  4. Press 'F' to clear filter
  5. Verify: all items visible again
  6. Press 'f', type "#project/paper", press Enter
  7. Verify: only items from files tagged #project/paper shown
```

### 5. Agenda Empty Days

```
Setup: config.calendar.agenda_hide_empty = false (default)

Steps:
  1. Open agenda for a range where some days have no items
  2. Verify: empty days show "(no items)" in dim text
  3. Set config.calendar.agenda_hide_empty = true
  4. Re-open agenda
  5. Verify: empty days are skipped entirely
```

### 6. Week View Navigation Boundaries

```
Steps:
  1. Open week view on first week of March
  2. Press 'H' to go back one week (last week of February)
  3. Verify: week header shows "Week of 23 Feb 2026"
  4. Press 'h' five times to navigate back day by day
  5. Verify: when crossing week boundary, a new week is rendered

Expected: no off-by-one errors at month/year boundaries.
```

### 7. Opening Items from Week/Agenda

```
Steps:
  1. Open week view, position cursor on a task item
  2. Press <CR>
  3. Verify: calendar closes, file opens at correct line

  4. Open agenda view, position cursor on a task item
  5. Press <CR>
  6. Verify: calendar closes, file opens at correct line
```

### 8. Cycle Key (v)

```
Steps:
  1. Open calendar (default month)
  2. Press 'v' -> verify week view
  3. Press 'v' -> verify agenda view
  4. Press 'v' -> verify month view (full cycle)
```

### 9. Configuration Defaults

```
Setup: Set config.calendar.default_view = "agenda"

Steps:
  1. Open calendar via :VaultCalendar
  2. Verify: opens directly in agenda view, not month view
```

### 10. Window Resizing on Mode Switch

```
Steps:
  1. Open calendar (month view, ~34 wide)
  2. Press 'w' to switch to week view
  3. Verify: window expands to ~92 columns, re-centered
  4. Press 'a' to switch to agenda view
  5. Verify: window resizes to ~80 columns, taller, re-centered
  6. Press 'm' to return to month
  7. Verify: window shrinks back to 34 columns, re-centered
```

## Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/calendar.lua` | Add `render_week()`, `render_agenda()`, mode-switching logic, unified keymaps, `selected_day` tracking, item navigation helpers. Rename existing `render_calendar()` to `render_month()`. Enrich `scan_dates_from_index()` task items with priority/status. |
| `lua/andrew/vault/config.lua` | Add `default_view`, `agenda_days`, `agenda_hide_empty`, `week_start`, `week_col_width` to `M.calendar` section. |
| `lua/andrew/vault/colors.lua` | Add `VaultCalendarAgendaOverdue` and `VaultCalendarAgendaFile` highlight groups. |

No new files are created. All changes are within the existing calendar module.
The `date_utils.lua`, `filter_utils.lua`, `ui.lua`, and `vault_index.lua`
modules are used as-is with no modifications needed.
