local vault_index = require("andrew.vault.vault_index")
local config = require("andrew.vault.config")
local engine = require("andrew.vault.engine")
local date_utils = require("andrew.vault.date_utils")
local filter_utils = require("andrew.vault.filter_utils")
local ui = require("andrew.vault.ui")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("kanban")
local text_utils = require("andrew.vault.text_utils")
local task_utils = require("andrew.vault.task_utils")

local M = {}

local ns = vim.api.nvim_create_namespace("vault_kanban")
local truncate = date_utils.truncate
local passes_filter = filter_utils.passes_task_filter
local filter_cache_key = filter_utils.filter_cache_key

-- ---------------------------------------------------------------------------
-- Data collection (two-level gen_cache)
-- ---------------------------------------------------------------------------

--- Build a simple string key from columns for cache comparison.
---@param columns table
---@return string
local function columns_cache_key(columns)
  local marks = {}
  for _, col in ipairs(columns) do
    marks[#marks + 1] = col.mark
  end
  return table.concat(marks, ",")
end

-- Level 2: filtered+sorted buckets cached by (generation, filter, columns).
local _kanban_cache = task_utils.gen_cache(function(idx, filter_opts, columns)
  local all_items = task_utils.get_raw_tasks()
  if not all_items or #all_items == 0 then return {} end

  local kanban_cfg = config.kanban or {}
  local max_per_col = kanban_cfg.max_per_column or 50

  local allowed = {}
  for _, col in ipairs(columns) do allowed[col.mark] = true end

  local buckets = {}
  for _, col in ipairs(columns) do buckets[col.mark] = {} end

  for _, item in ipairs(all_items) do
    local task = item.task
    local mark = task.status or " "
    if allowed[mark] and passes_filter(task, filter_opts) then
      local task_item = task_utils.build_task_item(task, item)
      -- Kanban-specific defensive defaults
      task_item.text = task_item.text or ""
      task_item.status = mark
      task_item.tags = task_item.tags or {}
      buckets[mark][#buckets[mark] + 1] = task_item
    end
  end

  for bmark, bucket in pairs(buckets) do
    table.sort(bucket, task_utils.compare_priority_due)
    if #bucket > max_per_col then
      local truncated = {}
      for i = 1, max_per_col do truncated[i] = bucket[i] end
      buckets[bmark] = truncated
    end
  end

  return buckets
end, {
  key_fn = function(filter_opts, columns)
    return filter_cache_key(filter_opts) .. "|" .. columns_cache_key(columns)
  end,
})

---Collect tasks from the vault index grouped by status mark.
---@param filter_opts table|nil
---@param columns table list of { mark, label }
---@return table<string, table[]> buckets keyed by mark
local function collect_tasks_by_status(filter_opts, columns)
  return _kanban_cache.get(filter_opts, columns) or {}
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local pad = text_utils.pad

---Render the kanban board into lines, highlights, and card positions.
---@param groups table<string, table[]>
---@param col_width integer
---@param columns table list of { mark, label }
---@return table { lines, highlights, card_positions }
local function render_board(groups, col_width, columns)
  local kanban_cfg = config.kanban or {}
  local show_priority = kanban_cfg.show_priority ~= false
  local show_due = kanban_cfg.show_due ~= false
  local today = engine.today()

  local lines = {}
  local highlights = {}
  local card_positions = {}
  local divider_char = "\xe2\x94\x82" -- "│"
  local horiz_char = "\xe2\x94\x80"   -- "─"

  -- Header row: column labels with task counts
  local header_parts = {}
  for ci, col in ipairs(columns) do
    local bucket = groups[col.mark] or {}
    local label = col.label:upper() .. " (" .. #bucket .. ")"
    local cell = pad("  " .. label, col_width)
    if ci < #columns then
      cell = cell .. divider_char
    end
    header_parts[#header_parts + 1] = cell
  end
  local header_line = table.concat(header_parts)
  lines[#lines + 1] = header_line

  -- Header highlight
  highlights[#highlights + 1] = { group = "VaultKanbanHeader", row = 0, col_start = 0, col_end = -1 }

  -- Add divider highlights on header
  do
    local offset = 0
    for ci = 1, #columns do
      offset = offset + col_width
      if ci < #columns then
        highlights[#highlights + 1] = {
          group = "VaultKanbanDivider",
          row = 0,
          col_start = offset,
          col_end = offset + #divider_char,
        }
        offset = offset + #divider_char
      end
    end
  end

  -- Separator row
  local sep_width = col_width * #columns + (#columns - 1) * #divider_char
  lines[#lines + 1] = string.rep(horiz_char, sep_width)
  highlights[#highlights + 1] = { group = "VaultKanbanHeader", row = 1, col_start = 0, col_end = -1 }

  -- Find the max number of cards across all columns (each card = 3 lines)
  local max_cards = 0
  for _, col in ipairs(columns) do
    local n = #(groups[col.mark] or {})
    if n > max_cards then max_cards = n end
  end

  -- Card rows: each task = 3 lines (title, metadata, blank)
  for card_idx = 1, max_cards do
    local title_parts = {}
    local meta_parts = {}
    local blank_parts = {}
    local row_base = #lines -- 0-indexed line number for title row

    for ci, col in ipairs(columns) do
      local bucket = groups[col.mark] or {}
      local task = bucket[card_idx]
      local title_cell, meta_cell, blank_cell

      if task then
        -- Title line
        local title_text = "  " .. truncate(task.text, col_width - 3)
        title_cell = pad(title_text, col_width)

        -- Metadata line
        local meta_items = {}
        if show_priority and task.priority then
          meta_items[#meta_items + 1] = "P" .. task.priority
        end
        if show_due and task.due then
          meta_items[#meta_items + 1] = task.due
        end
        local meta_str = table.concat(meta_items, " \xe2\x94\x82 ")
        meta_cell = pad("  " .. truncate(meta_str, col_width - 3), col_width)

        -- Blank separator
        blank_cell = pad("", col_width)

        -- Track card position (row is 0-indexed buffer line of title)
        card_positions[#card_positions + 1] = {
          task = task,
          row = row_base,
          col_index = ci,
        }

        -- Card highlight on title line
        local col_byte_offset = (ci - 1) * (col_width + #divider_char)

        local hl_group = "VaultKanbanDefault"
        if task.due and task.due < today and (task.status == " " or task.status == "/") then
          hl_group = "VaultKanbanOverdue"
        elseif task.due and task.due == today then
          hl_group = "VaultKanbanDueToday"
        elseif task.priority == 1 then
          hl_group = "VaultKanbanP1"
        elseif task.priority == 2 then
          hl_group = "VaultKanbanP2"
        end

        highlights[#highlights + 1] = {
          group = hl_group,
          row = row_base,
          col_start = col_byte_offset,
          col_end = col_byte_offset + col_width,
        }
      else
        title_cell = pad("", col_width)
        meta_cell = pad("", col_width)
        blank_cell = pad("", col_width)
      end

      if ci < #columns then
        title_cell = title_cell .. divider_char
        meta_cell = meta_cell .. divider_char
        blank_cell = blank_cell .. divider_char

        -- Divider highlights for each of the 3 lines
        local div_offset = ci * col_width + (ci - 1) * #divider_char
        for line_off = 0, 2 do
          highlights[#highlights + 1] = {
            group = "VaultKanbanDivider",
            row = row_base + line_off,
            col_start = div_offset,
            col_end = div_offset + #divider_char,
          }
        end
      end

      title_parts[#title_parts + 1] = title_cell
      meta_parts[#meta_parts + 1] = meta_cell
      blank_parts[#blank_parts + 1] = blank_cell
    end

    lines[#lines + 1] = table.concat(title_parts)
    lines[#lines + 1] = table.concat(meta_parts)
    lines[#lines + 1] = table.concat(blank_parts)
  end

  -- If no cards, add an empty message row
  if max_cards == 0 then
    local empty_parts = {}
    for ci, _ in ipairs(columns) do
      local cell = pad("  (no tasks)", col_width)
      if ci < #columns then cell = cell .. divider_char end
      empty_parts[#empty_parts + 1] = cell
    end
    lines[#lines + 1] = table.concat(empty_parts)
  end

  return { lines = lines, highlights = highlights, card_positions = card_positions }
end

-- ---------------------------------------------------------------------------
-- Task status mutation
-- ---------------------------------------------------------------------------

---Update a task's checkbox status in its source file.
---@param task table
---@param new_status string single character mark
---@return boolean success
local function set_task_status(task, new_status)
  if not task or not task.abs_path or not task.line then return false end

  -- Ensure the file is loaded in a buffer
  local bufnr = vim.fn.bufadd(task.abs_path)
  vim.fn.bufload(bufnr)

  local line_idx = task.line
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_idx < 1 or line_idx > line_count then return false end

  local lines = vim.api.nvim_buf_get_lines(bufnr, line_idx - 1, line_idx, false)
  if not lines or #lines == 0 then return false end

  local line = lines[1]
  local tasks = require("andrew.vault.tasks")
  local prefix, old_mark, suffix = line:match(tasks.CHECKBOX_PATTERN)
  if not prefix then return false end

  local old_status = old_mark
  local new_suffix = tasks.apply_completion_meta(suffix, old_status, new_status)

  vim.api.nvim_buf_set_lines(bufnr, line_idx - 1, line_idx, false, {
    prefix .. new_status .. new_suffix,
  })

  -- Save the buffer to trigger BufWritePost and vault_index invalidation
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("silent write")
  end)

  -- Handle recurrence for completing recurring tasks
  if new_status == "x" and task.repeat_rule and task.repeat_rule ~= "" then
    local recurrence = require("andrew.vault.recurrence")
    vim.api.nvim_buf_call(bufnr, function()
      recurrence.handle_recurrence(task.line)
    end)
  end

  -- Invalidate caches since task status changed
  task_utils.invalidate_raw_tasks()
  _kanban_cache.invalidate()

  -- Update task object in-place for display consistency
  task.status = new_status
  if new_status == "x" then
    task.completion = engine.today()
  elseif old_status == "x" then
    task.completion = nil
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Spatial index for O(1) card navigation
-- ---------------------------------------------------------------------------

---Build spatial lookup indexes from card_positions.
---Returns row_index (row -> card) and col_index (col_idx -> sorted card list).
---@param card_positions table[]
---@return table row_index, table col_index
local function build_spatial_index(card_positions)
  local row_index = {}
  local col_index = {}

  for _, cp in ipairs(card_positions) do
    -- Map every row in the card's 3-line range
    for r = cp.row, cp.row + 2 do
      row_index[r] = cp
    end
    -- Column index
    if not col_index[cp.col_index] then col_index[cp.col_index] = {} end
    local list = col_index[cp.col_index]
    list[#list + 1] = cp
  end

  -- Col lists are already in insertion order (by card_idx), which is row-sorted
  return row_index, col_index
end

-- ---------------------------------------------------------------------------
-- Navigation helpers (spatial-index accelerated)
-- ---------------------------------------------------------------------------

---Find the card at or nearest to the given cursor row.
---@param card_positions table[]
---@param cursor_row integer 0-indexed buffer line
---@param row_index table|nil spatial row index for O(1) lookup
---@return table|nil card_position entry
local function find_card_at_cursor(card_positions, cursor_row, row_index)
  -- O(1) path via spatial index
  if row_index then
    local hit = row_index[cursor_row]
    if hit then return hit end
    -- Cursor is outside any card range; fall through to nearest search
  end

  if #card_positions == 0 then return nil end
  local best, best_dist = nil, math.huge
  for _, cp in ipairs(card_positions) do
    local dist
    if cursor_row >= cp.row and cursor_row <= cp.row + 2 then
      dist = 0
    else
      dist = math.min(math.abs(cursor_row - cp.row), math.abs(cursor_row - (cp.row + 2)))
    end
    if dist < best_dist then
      best = cp
      best_dist = dist
    end
  end
  return best
end

---Find the nearest card in a specific column, preferring one near the given row.
---@param card_positions table[]
---@param col_index_num integer 1-indexed column
---@param near_row integer 0-indexed buffer line
---@param col_index table|nil spatial column index for fast lookup
---@return table|nil card_position entry
local function find_card_in_column(card_positions, col_index_num, near_row, col_index)
  -- Use spatial index if available
  local candidates = col_index and col_index[col_index_num]
  if not candidates then
    -- Fallback: filter from full list
    candidates = {}
    for _, cp in ipairs(card_positions) do
      if cp.col_index == col_index_num then
        candidates[#candidates + 1] = cp
      end
    end
  end

  local best, best_dist = nil, math.huge
  for _, cp in ipairs(candidates) do
    local dist = math.abs(cp.row - near_row)
    if dist < best_dist then
      best = cp
      best_dist = dist
    end
  end
  return best
end

---Get all cards in a specific column, sorted by row.
---@param card_positions table[]
---@param col_index_num integer
---@param col_index table|nil spatial column index
---@return table[]
local function cards_in_column(card_positions, col_index_num, col_index)
  if col_index and col_index[col_index_num] then
    return col_index[col_index_num]
  end
  local result = {}
  for _, cp in ipairs(card_positions) do
    if cp.col_index == col_index_num then
      result[#result + 1] = cp
    end
  end
  table.sort(result, function(a, b) return a.row < b.row end)
  return result
end

-- ---------------------------------------------------------------------------
-- Redraw
-- ---------------------------------------------------------------------------

---@param state table kanban state
local function redraw(state)
  local groups = collect_tasks_by_status(state.filter_opts, state.columns)

  -- Count total tasks
  local total = 0
  for _, bucket in pairs(groups) do
    total = total + #bucket
  end
  if total == 0 then
    notify.info("no tasks match current filters")
  end

  local board = render_board(groups, state.col_width, state.columns)
  state.card_positions = board.card_positions
  state.row_index, state.col_index = build_spatial_index(board.card_positions)

  vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, board.lines)
  vim.api.nvim_buf_set_option(state.buf, "modifiable", false)

  -- Clear and re-apply highlights
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, hl in ipairs(board.highlights) do
    local ok, err = pcall(vim.api.nvim_buf_add_highlight, state.buf, ns, hl.group, hl.row, hl.col_start, hl.col_end)
    if not ok then log.debug("highlight failed at row %d: %s", hl.row, err) end
  end
end

-- ---------------------------------------------------------------------------
-- Main entry
-- ---------------------------------------------------------------------------

---Open the Kanban board.
---@param opts table|nil { filter = filter_opts }
function M.kanban(opts)
  opts = opts or {}

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    notify.index_not_ready("kanban index not ready")
    return
  end

  local kanban_cfg = config.kanban or {}

  -- Determine columns
  local columns
  if kanban_cfg.columns then
    -- Map marks to task_states entries
    local state_map = {}
    for _, ts in ipairs(config.task_states or {}) do
      state_map[ts.mark] = ts
    end
    columns = {}
    for _, mark in ipairs(kanban_cfg.columns) do
      if state_map[mark] then
        columns[#columns + 1] = { mark = state_map[mark].mark, label = state_map[mark].label }
      end
    end
  else
    columns = {}
    for _, ts in ipairs(config.task_states or {}) do
      columns[#columns + 1] = { mark = ts.mark, label = ts.label }
    end
  end

  if #columns == 0 then
    notify.warn("no kanban columns configured")
    return
  end

  local filter_opts = opts.filter or {}
  local groups = collect_tasks_by_status(filter_opts, columns)

  -- Count total tasks
  local total = 0
  for _, bucket in pairs(groups) do
    total = total + #bucket
  end
  if total == 0 then
    notify.info("no tasks found")
    return
  end

  -- Calculate dimensions
  local ui_width = vim.o.columns
  local ui_height = vim.o.lines
  local width = math.min(ui_width - 4, 160)
  local col_width = math.floor(width / #columns)
  local board = render_board(groups, col_width, columns)

  local height = math.min(#board.lines, ui_height - 6)

  local float = ui.create_float_display({
    title = " Kanban ",
    lines = board.lines,
    width = width,
    height = height,
    cursor_line = 3, -- first card title row (0-indexed: row 2, 1-indexed: row 3)
  })

  if not float or not float.buf then return end

  -- Apply highlights
  for _, hl in ipairs(board.highlights) do
    local ok, err = pcall(vim.api.nvim_buf_add_highlight, float.buf, ns, hl.group, hl.row, hl.col_start, hl.col_end)
    if not ok then log.debug("highlight failed at row %d: %s", hl.row, err) end
  end

  -- Build spatial indexes for O(1) navigation
  local ri, ci = build_spatial_index(board.card_positions)

  -- Store state
  local state = {
    buf = float.buf,
    win = float.win,
    close = float.close,
    card_positions = board.card_positions,
    row_index = ri,
    col_index = ci,
    columns = columns,
    filter_opts = filter_opts,
    col_width = col_width,
    ns = ns,
  }

  -- Helper: redraw if the kanban window is still valid (used by async callbacks)
  local function schedule_redraw(s)
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(s.win) then
        redraw(s)
      end
    end)
  end

  -- Helper: set keymap on buffer
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = state.buf, nowait = true, desc = desc })
  end

  -- Navigation: h/l move between columns
  map("h", function()
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local row = cursor[1] - 1 -- 0-indexed
    local current = find_card_at_cursor(state.card_positions, row, state.row_index)
    if not current then return end
    local target_col = current.col_index - 1
    if target_col < 1 then target_col = #state.columns end
    local target = find_card_in_column(state.card_positions, target_col, current.row, state.col_index)
    if target then
      vim.api.nvim_win_set_cursor(state.win, { target.row + 1, (target_col - 1) * (state.col_width + 3) + 2 })
    end
  end, "Vault: kanban move to previous column")

  map("l", function()
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local row = cursor[1] - 1
    local current = find_card_at_cursor(state.card_positions, row, state.row_index)
    if not current then return end
    local target_col = current.col_index + 1
    if target_col > #state.columns then target_col = 1 end
    local target = find_card_in_column(state.card_positions, target_col, current.row, state.col_index)
    if target then
      vim.api.nvim_win_set_cursor(state.win, { target.row + 1, (target_col - 1) * (state.col_width + 3) + 2 })
    end
  end, "Vault: kanban move to next column")

  -- Navigation: j/k move within column
  map("j", function()
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local row = cursor[1] - 1
    local current = find_card_at_cursor(state.card_positions, row, state.row_index)
    if not current then return end
    local col_cards = cards_in_column(state.card_positions, current.col_index, state.col_index)
    for i, cp in ipairs(col_cards) do
      if cp.row == current.row and col_cards[i + 1] then
        local next_card = col_cards[i + 1]
        vim.api.nvim_win_set_cursor(state.win, { next_card.row + 1, cursor[2] })
        return
      end
    end
  end, "Vault: kanban move to next card")

  map("k", function()
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local row = cursor[1] - 1
    local current = find_card_at_cursor(state.card_positions, row, state.row_index)
    if not current then return end
    local col_cards = cards_in_column(state.card_positions, current.col_index, state.col_index)
    for i, cp in ipairs(col_cards) do
      if cp.row == current.row and i > 1 then
        local prev_card = col_cards[i - 1]
        vim.api.nvim_win_set_cursor(state.win, { prev_card.row + 1, cursor[2] })
        return
      end
    end
  end, "Vault: kanban move to previous card")

  -- Enter: jump to task source
  map("<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local row = cursor[1] - 1
    local cp = find_card_at_cursor(state.card_positions, row, state.row_index)
    if not cp then return end
    local task = cp.task
    state.close()
    vim.cmd("edit +" .. task.line .. " " .. vim.fn.fnameescape(task.abs_path))
  end, "Vault: kanban jump to task")

  -- m: move task to next status
  map("m", function()
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local row = cursor[1] - 1
    local cp = find_card_at_cursor(state.card_positions, row, state.row_index)
    if not cp then return end
    -- Find current column index in columns list by mark
    local current_idx = nil
    for i, col in ipairs(state.columns) do
      if col.mark == cp.task.status then
        current_idx = i
        break
      end
    end
    if not current_idx then return end
    local next_idx = current_idx % #state.columns + 1
    local new_mark = state.columns[next_idx].mark
    if set_task_status(cp.task, new_mark) then
      schedule_redraw(state)
    end
  end, "Vault: kanban move task to next status")

  -- M: move task to previous status
  map("M", function()
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local row = cursor[1] - 1
    local cp = find_card_at_cursor(state.card_positions, row, state.row_index)
    if not cp then return end
    local current_idx = nil
    for i, col in ipairs(state.columns) do
      if col.mark == cp.task.status then
        current_idx = i
        break
      end
    end
    if not current_idx then return end
    local prev_idx = (current_idx - 2) % #state.columns + 1
    local new_mark = state.columns[prev_idx].mark
    if set_task_status(cp.task, new_mark) then
      schedule_redraw(state)
    end
  end, "Vault: kanban move task to previous status")

  -- p: prompt for priority filter
  map("p", function()
    vim.ui.input({ prompt = "Max priority (1-5, empty to clear): " }, function(input)
      if input == nil then return end
      if input == "" then
        state.filter_opts.priority_max = nil
      else
        local n = tonumber(input)
        if n then state.filter_opts.priority_max = n end
      end
      schedule_redraw(state)
    end)
  end, "Vault: kanban filter by priority")

  -- d: prompt for due date filter
  map("d", function()
    vim.ui.input({ prompt = "Due before (YYYY-MM-DD, empty to clear): " }, function(input)
      if input == nil then return end
      if input == "" then
        state.filter_opts.due_before = nil
      else
        state.filter_opts.due_before = input
      end
      schedule_redraw(state)
    end)
  end, "Vault: kanban filter by due date")

  -- /: prompt for text filter
  map("/", function()
    vim.ui.input({ prompt = "Text filter (empty to clear): " }, function(input)
      if input == nil then return end
      if input == "" then
        state.filter_opts.text_pattern = nil
      else
        state.filter_opts.text_pattern = input
      end
      schedule_redraw(state)
    end)
  end, "Vault: kanban filter by text")

  -- P: prompt for project/tag filter
  map("P", function()
    vim.ui.input({ prompt = "Project tag (empty to clear): " }, function(input)
      if input == nil then return end
      if input == "" then
        state.filter_opts.project = nil
      else
        state.filter_opts.project = input
      end
      schedule_redraw(state)
    end)
  end, "Vault: kanban filter by project tag")

  -- r: reset all filters
  map("r", function()
    state.filter_opts = {}
    redraw(state)
  end, "Vault: kanban reset filters")

  -- q / Esc: close
  map("q", function() state.close() end, "Vault: kanban close")
  map("<Esc>", function() state.close() end, "Vault: kanban close")
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  -- Register with engine cache system
  engine.register_cache({
    name = "kanban",
    module = M,
    invalidate = function()
      task_utils.invalidate_raw_tasks()
      _kanban_cache.invalidate()
    end,
    stats = function()
      local items = task_utils.get_raw_tasks()
      return {
        type = "kanban",
        items_count = items and #items or 0,
      }
    end,
  })

  do
    local profiler = require("andrew.vault.memory_profiler")
    profiler.register_cache({
      name = "kanban",
      get_size = function()
        local items = task_utils.get_raw_tasks()
        return items and #items or 0
      end,
      get_capacity = function() return nil end,
      get_hits = function() return _kanban_cache.get_hits() end,
      get_misses = function() return _kanban_cache.get_misses() end,
      get_evictions = function() return 0 end,
    })
  end

  -- Commands, keymaps, and palette registrations are in init.lua lazy stubs
end

return M
