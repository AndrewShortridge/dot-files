--- Task timeline view — plots vault tasks by due date with overdue/today/upcoming zones.
--- @module andrew.vault.task_timeline

local config = require("andrew.vault.config")
local engine = require("andrew.vault.engine")
local date_utils = require("andrew.vault.date_utils")
local filter_utils = require("andrew.vault.filter_utils")
local task_utils = require("andrew.vault.task_utils")
local notify = require("andrew.vault.notify")
local ui = require("andrew.vault.ui")
local vault_index = require("andrew.vault.vault_index")
local cleanup = require("andrew.vault.resource_cleanup")
local log = require("andrew.vault.vault_log").scope("timeline")

local M = {}

local ns = vim.api.nvim_create_namespace("vault_task_timeline")
local passes_filter = filter_utils.passes_task_filter
local filter_cache_key = filter_utils.filter_cache_key
local build_row_index = filter_utils.build_row_index
local date_add = date_utils.date_add
local format_date_short = date_utils.format_date_short

-- ---------------------------------------------------------------------------
-- Data collection
-- ---------------------------------------------------------------------------

-- Generation-based cache for collect_timeline_tasks.
-- Invalidated when vault index generation changes or filter/show_done changes.
local _timeline_cache = task_utils.gen_cache(function(idx, filter_opts)
  if not idx:is_ready() then return { dated = {}, undated = {} } end

  local all_items = task_utils.get_raw_tasks()
  local dated = {} ---@type table<string, table[]>
  local undated = {} ---@type table[]
  local show_done = config.timeline.show_done

  for _, raw in ipairs(all_items) do
    local task = raw.task

    -- Skip done/cancelled unless show_done
    if not show_done then
      if task.status == "x" or task.status == "X" or task.status == "-" then
        goto continue
      end
    end

    do
      local item = task_utils.build_task_item(task, raw)

      if passes_filter(item, filter_opts) then
        if task.due then
          if not dated[task.due] then
            dated[task.due] = {}
          end
          dated[task.due][#dated[task.due] + 1] = item
        else
          undated[#undated + 1] = item
        end
      end
    end

    ::continue::
  end

  return { dated = dated, undated = undated }
end, {
  key_fn = function(filter_opts)
    return filter_cache_key(filter_opts) .. "|" .. tostring(config.timeline.show_done)
  end,
})

--- Collect tasks from vault index, grouped by due date.
---@param filter_opts table|nil
---@return { dated: table<string, table[]>, undated: table[] }
local function collect_timeline_tasks(filter_opts)
  return _timeline_cache.get(filter_opts) or { dated = {}, undated = {} }
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Format a task line for display (delegates to shared formatter).
---@param task table
---@param width number
---@return string
local function format_task_line(task, width)
  return task_utils.format_task_line(task, { width = width })
end

--- Render the timeline into lines with highlight info and task positions.
---@param data { dated: table<string, table[]>, undated: table[] }
---@param state table  { center_date, range_days }
---@param width number
---@return { lines: string[], highlights: table[], task_positions: table[] }
local function render_timeline(data, state, width)
  local lines = {} ---@type string[]
  local highlights = {} ---@type { [1]: string, [2]: number, [3]: number, [4]: number }[]
  local task_positions = {} ---@type { task: table, row: number }[]

  local today = engine.today()
  local from_date = date_add(today, -state.range_days)
  local to_date = date_add(today, state.range_days)

  -- Collect and sort all dated keys within range
  local overdue_dates = {}
  local today_date = nil
  local upcoming_dates = {}

  for date_str, _ in pairs(data.dated) do
    if date_str >= from_date and date_str <= to_date then
      if date_str < today then
        overdue_dates[#overdue_dates + 1] = date_str
      elseif date_str == today then
        today_date = date_str
      else
        upcoming_dates[#upcoming_dates + 1] = date_str
      end
    end
  end

  table.sort(overdue_dates) -- oldest first
  table.sort(upcoming_dates) -- nearest first

  local has_overdue = #overdue_dates > 0
  local has_today = today_date ~= nil
  local has_upcoming = #upcoming_dates > 0
  local has_undated = config.timeline.show_undated and #data.undated > 0

  -- Helper: add line and return its 0-indexed row
  local function add_line(text)
    lines[#lines + 1] = text
    return #lines - 1 -- 0-indexed
  end

  -- Helper: add a highlight
  local function add_hl(group, row, col_start, col_end)
    highlights[#highlights + 1] = { group, row, col_start, col_end }
  end

  -- Header
  local range_label = format_date_short(from_date) .. " .. " .. format_date_short(to_date)
  local header = "  Task Timeline  [" .. range_label .. "]"
  local row = add_line(header)
  add_hl("VaultTimelineHeader", row, 0, #header)

  local sep = string.rep("─", width - 2)
  row = add_line("  " .. sep)
  add_hl("VaultTimelineDim", row, 0, #sep + 2)

  -- Helper: render a group of tasks for a date
  local function render_date_group(date_str, tasks, label, hl_group)
    local date_label = "  " .. format_date_short(date_str) .. ":"
    if label then
      date_label = date_label .. "  [" .. label .. "]"
    end
    row = add_line(date_label)
    add_hl(hl_group, row, 0, #date_label)

    -- Sort tasks: by priority (ascending, nil last), then text
    table.sort(tasks, task_utils.compare_priority_text)

    for _, task in ipairs(tasks) do
      local task_line = format_task_line(task, width)
      row = add_line(task_line)
      add_hl("VaultTimelineTask", row, 0, -1)
      task_positions[#task_positions + 1] = { task = task, row = row }

      -- Highlight priority
      if task.priority then
        local prio_str = "(P" .. task.priority .. ")"
        local prio_start = task_line:find(prio_str, 1, true)
        if prio_start then
          add_hl("VaultTimelinePriority", row, prio_start - 1, prio_start - 1 + #prio_str)
        end
      end
    end
  end

  -- Overdue section
  if has_overdue then
    add_line("")
    for _, date_str in ipairs(overdue_dates) do
      local days_overdue = date_utils.days_between(date_str, today)
      local label = "OVERDUE " .. days_overdue .. "d"
      render_date_group(date_str, data.dated[date_str], label, "VaultTimelineOverdue")
    end
  end

  -- Today section
  if has_today then
    add_line("")
    render_date_group(today, data.dated[today], "TODAY", "VaultTimelineToday")
  end

  -- Upcoming section
  if has_upcoming then
    add_line("")
    for _, date_str in ipairs(upcoming_dates) do
      local days_ahead = date_utils.days_between(today, date_str)
      local label = "in " .. days_ahead .. "d"
      render_date_group(date_str, data.dated[date_str], label, "VaultTimelineUpcoming")
    end
  end

  -- Undated section
  if has_undated then
    add_line("")
    row = add_line("  NO DUE DATE")
    add_hl("VaultTimelineUndated", row, 0, -1)

    table.sort(data.undated, task_utils.compare_priority_text)

    for _, task in ipairs(data.undated) do
      local task_line = format_task_line(task, width)
      row = add_line(task_line)
      add_hl("VaultTimelineTask", row, 0, -1)
      task_positions[#task_positions + 1] = { task = task, row = row }

      if task.priority then
        local prio_str = "(P" .. task.priority .. ")"
        local prio_start = task_line:find(prio_str, 1, true)
        if prio_start then
          add_hl("VaultTimelinePriority", row, prio_start - 1, prio_start - 1 + #prio_str)
        end
      end
    end
  end

  -- Empty state
  if #lines <= 2 then
    add_line("")
    add_line("  No tasks in range.")
  end

  return { lines = lines, highlights = highlights, task_positions = task_positions }
end

-- ---------------------------------------------------------------------------
-- Float management
-- ---------------------------------------------------------------------------

-- Render cache: stores rendered output (lines, highlights, task_positions) to
-- avoid re-running render_timeline() when nothing has changed.
local _render_cache = { key = nil, result = nil }

--- Build a composite cache key for the render output.
---@param state table  { center_date, range_days }
---@param filter_opts table|nil
---@param win_width number
---@return string
local function render_cache_key(state, filter_opts, win_width)
  local idx = vault_index.current()
  local gen = idx and idx._generation or 0
  local fkey = filter_opts and filter_cache_key(filter_opts) or ""
  return table.concat({
    state.center_date,
    tostring(state.range_days),
    fkey,
    tostring(gen),
    tostring(win_width),
    engine.today(),
    tostring(config.timeline.show_undated),
    tostring(config.timeline.show_done),
  }, "|")
end

--- Active float state (singleton).
---@type { buf: number, win: number, close: fun(), state: table, task_positions: table[], filter_opts: table|nil }|nil
local active = nil

--- Apply highlights to the float buffer.
---@param buf number
---@param hl_list table[]
local function apply_highlights(buf, hl_list)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, hl in ipairs(hl_list) do
    local ok, err = pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl[1], hl[2], hl[3], hl[4])
    if not ok then log.debug("highlight failed at row %d: %s", hl[2], err) end
  end
end

--- Redraw the timeline in the existing float.
--- Uses incremental line updates when line count is unchanged (scroll).
---@param state table
local function redraw(state)
  if not active or not vim.api.nvim_win_is_valid(active.win) then return end

  local win_width = vim.api.nvim_win_get_width(active.win)
  local rkey = render_cache_key(state, active.filter_opts, win_width)

  local result
  if _render_cache.key == rkey and _render_cache.result then
    result = _render_cache.result
    log.debug("render cache hit")
  else
    local data = collect_timeline_tasks(active.filter_opts)
    result = render_timeline(data, state, win_width)
    _render_cache.key = rkey
    _render_cache.result = result
    log.debug("render cache miss, rebuilt")
  end

  vim.bo[active.buf].modifiable = true
  active._prev_lines = ui.apply_incremental_render(active.buf, ns, active._prev_lines, result.lines, result.highlights)
  vim.bo[active.buf].modifiable = false
  active.task_positions = result.task_positions
  active.row_index = build_row_index(result.task_positions)
  active.state = state
end

--- Find the task at the given cursor row (O(1) via row index).
---@param cursor_row number  1-indexed cursor row
---@return table|nil  task entry
local function task_at_cursor(cursor_row)
  if not active or not active.task_positions then return nil end
  local row0 = cursor_row - 1 -- convert to 0-indexed
  local tp = active.row_index and active.row_index[row0]
  if tp then return tp.task end
  return nil
end

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

--- Set up buffer-local keymaps for the timeline float.
---@param buf number
---@param state table
local function set_keymaps(buf, state)
  local kopts = { buffer = buf, nowait = true, silent = true }

  -- Scroll 1 day back/forward
  vim.keymap.set("n", "h", function()
    state.center_date = date_add(state.center_date, -1)
    redraw(state)
  end, kopts)

  vim.keymap.set("n", "l", function()
    state.center_date = date_add(state.center_date, 1)
    redraw(state)
  end, kopts)

  -- Scroll 7 days back/forward
  vim.keymap.set("n", "H", function()
    state.center_date = date_add(state.center_date, -7)
    redraw(state)
  end, kopts)

  vim.keymap.set("n", "L", function()
    state.center_date = date_add(state.center_date, 7)
    redraw(state)
  end, kopts)

  -- Preset views
  vim.keymap.set("n", "w", function()
    state.range_days = 7
    redraw(state)
  end, kopts)

  vim.keymap.set("n", "W", function()
    state.range_days = 30
    redraw(state)
  end, kopts)

  vim.keymap.set("n", "d", function()
    state.range_days = 14
    redraw(state)
  end, kopts)

  -- Recenter on today
  vim.keymap.set("n", "t", function()
    state.center_date = engine.today()
    redraw(state)
  end, kopts)

  -- Jump to task source file
  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(active.win)
    local task = task_at_cursor(cursor[1])
    if not task then
      notify.info("no task under cursor")
      return
    end
    -- Close the float first
    active.close()
    active = nil
    -- Open the file and jump to line
    vim.cmd("edit " .. vim.fn.fnameescape(task.abs_path))
    if task.line then
      local ok, err = pcall(vim.api.nvim_win_set_cursor, 0, { task.line, 0 })
      if not ok then log.debug("failed to set cursor to task line: %s", err) end
      vim.cmd("normal! zz")
    end
  end, kopts)

  -- Filter prompt
  vim.keymap.set("n", "f", function()
    vim.ui.input({ prompt = "Filter tasks: " }, function(input)
      if input == nil then return end
      if input == "" then
        active.filter_opts = nil
      else
        active.filter_opts = active.filter_opts or {}
        active.filter_opts.text_pattern = input
      end
      redraw(state)
    end)
  end, kopts)

  -- Close (q and Esc are already set by ui.create_float_display)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Open the task timeline view.
---@param opts table|nil  Optional overrides { range_days?, filter_opts? }
function M.timeline(opts)
  opts = opts or {}

  local today = engine.today()
  local range_days = (opts.range_days) or config.timeline.range_days

  local filter_opts = opts.filter_opts or nil
  local data = collect_timeline_tasks(filter_opts)

  -- Check if there are any tasks at all
  local has_any = false
  for _, _ in pairs(data.dated) do
    has_any = true
    break
  end
  if not has_any and #data.undated == 0 then
    notify.info("no tasks found in vault")
    return
  end

  local state = {
    center_date = today,
    range_days = range_days,
  }

  -- Determine float dimensions
  local ui_info = ui.get_screen_dims()
  local width = math.floor(ui_info.width * config.timeline.float_width_ratio)
  local height = math.floor(ui_info.height * config.timeline.float_height_ratio)

  local result = render_timeline(data, state, width)

  local float = ui.create_float_display({
    title = "Task Timeline",
    lines = result.lines,
    width = width,
    height = math.min(#result.lines + 2, height),
    cursor_line = true,
  })

  apply_highlights(float.buf, result.highlights)

  active = {
    buf = float.buf,
    win = float.win,
    close = float.close,
    state = state,
    task_positions = result.task_positions,
    row_index = build_row_index(result.task_positions),
    filter_opts = filter_opts,
  }

  set_keymaps(float.buf, state)

  -- Position cursor on first task if possible
  if #result.task_positions > 0 then
    local ok, err = pcall(vim.api.nvim_win_set_cursor, float.win, { result.task_positions[1].row + 1, 0 })
    if not ok then log.debug("failed to set cursor to first task position: %s", err) end
  end

  -- Clean up active state when buffer is deleted or wiped
  cleanup.on_buf_delete_once(float.buf, function()
    active = nil
  end)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  engine.register_cache({
    name = "task_timeline",
    module = M,
    invalidate = function()
      task_utils.invalidate_raw_tasks()
      _timeline_cache.invalidate()
      _render_cache.key = nil
      _render_cache.result = nil
    end,
    stats = function()
      return { type = "timeline" }
    end,
  })

  do
    local profiler = require("andrew.vault.memory_profiler")
    profiler.register_cache({
      name = "task_timeline",
      get_size = function()
        local data = _timeline_cache.get()
        if not data then return 0 end
        local dated = data.dated and #data.dated or 0
        local undated = data.undated and #data.undated or 0
        return dated + undated
      end,
      get_capacity = function() return nil end,
      get_hits = function() return _timeline_cache.get_hits() end,
      get_misses = function() return _timeline_cache.get_misses() end,
      get_evictions = function() return 0 end,
    })
  end

  -- Commands, keymaps, and palette registrations are in init.lua lazy stubs
end

return M
