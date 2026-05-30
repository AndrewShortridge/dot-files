# 35 — Task Kanban Bulk Operations

**Priority:** Medium
**Status:** Planned

## Summary

Add multi-select capability and bulk mutation operations (status, priority, due
date) to the Kanban board and task timeline views. Currently both views only
support single-task operations: the Kanban `m`/`M` keymaps cycle one task at a
time through status columns, and the timeline view has no mutation keymaps at
all. Bulk operations let users triage a batch of tasks in one pass -- selecting
several cards, then applying a single status/priority/due-date change to all of
them at once, with correct recurrence handling and a per-batch undo stack.

## Current State

### Kanban (`task_kanban.lua`)

- **Single-task status mutation** via `m` (next status) / `M` (previous status)
  on the card under the cursor (lines 606-655).
- `set_task_status(task, new_status)` (lines 284-345) writes the new checkbox
  mark to the source file, manages the `[completion:: ...]` inline field, and
  triggers `recurrence.handle_recurrence()` when completing a recurring task.
- No multi-select mechanism exists. There is no visual indication of "selected"
  cards and no bulk operation keymaps.
- Navigation: `h`/`l` (columns), `j`/`k` (within column), `<CR>` (jump to
  source). Filter keymaps: `p` (priority), `d` (due), `/` (text), `P`
  (project), `r` (reset).
- State is stored in a local `state` table: `buf`, `win`, `close`,
  `card_positions`, `columns`, `filter_opts`, `col_width`, `ns`.

### Timeline (`task_timeline.lua`)

- Read-only view. Navigation keymaps (`h`/`l`/`H`/`L` for date scrolling,
  `j`/`k` normal motion, `w`/`W`/`d` for range presets, `t` for recenter,
  `<CR>` for jump, `f` for text filter).
- No task mutation keymaps at all.
- Active state stored in module-level `active` table: `buf`, `win`, `close`,
  `state`, `task_positions`, `filter_opts`.

### Recurrence (`recurrence.lua`)

- `handle_recurrence(line_nr)` (lines 124-175): called after a task line is set
  to `[x]`. Reads the buffer line, parses `[repeat:: ...]` and `[due:: ...]`
  inline fields, computes the next occurrence date, builds a new unchecked copy
  with the updated due date and no completion field, and inserts it above the
  completed line.
- Operates on the current buffer (`vim.api.nvim_buf_get_lines(0, ...)`), so the
  file must be loaded into a buffer before calling.
- `set_task_status()` in `task_kanban.lua` already handles this: it ensures the
  buffer is loaded (lines 327-329) and calls `recurrence.handle_recurrence()`
  inside `nvim_buf_call` (lines 331-333).

### Config (`config.lua`)

- `M.kanban`: `columns`, `max_per_column`, `show_priority`, `show_due`.
- `M.timeline`: `range_days`, `show_done`, `show_undated`.
- `M.task_states`: array of `{ mark, label }` defining all checkbox states.

## Detailed Implementation

### 1. Selection State Model

Add a selection set to the kanban and timeline state tables. Selections are
keyed by a unique task identity string (`file:line`) to survive redraws.

```lua
-- In kanban state (task_kanban.lua, inside M.kanban()):
local state = {
  buf = float.buf,
  win = float.win,
  close = float.close,
  card_positions = board.card_positions,
  columns = columns,
  filter_opts = filter_opts,
  col_width = col_width,
  ns = ns,
  -- NEW: selection and undo
  selected = {},    -- set<string> keyed by "rel_path:line"
  undo_stack = {},  -- list of { tasks = {task_snapshot...}, field = "status"|"priority"|"due" }
}
```

```lua
-- In timeline active state (task_timeline.lua):
active = {
  buf = float.buf,
  win = float.win,
  close = float.close,
  state = state,
  task_positions = result.task_positions,
  filter_opts = filter_opts,
  -- NEW:
  selected = {},
  undo_stack = {},
}
```

Task identity key helper (shared):

```lua
--- Unique key for a task (stable across redraws).
---@param task table
---@return string
local function task_key(task)
  return task.file .. ":" .. task.line
end
```

### 2. Multi-Select Toggle (`<Space>`)

**Kanban** -- `task_kanban.lua`, add keymap after the existing `map()` calls
(after line 734):

```lua
-- <Space>: toggle selection on current card
map("<Space>", function()
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local row = cursor[1] - 1
  local cp = find_card_at_cursor(state.card_positions, row)
  if not cp then return end
  local key = task_key(cp.task)
  if state.selected[key] then
    state.selected[key] = nil
  else
    state.selected[key] = true
  end
  apply_selection_highlights(state)
  update_selection_status(state)
end, "Kanban: toggle task selection")
```

**Timeline** -- `task_timeline.lua`, add keymap inside `set_keymaps()`:

```lua
vim.keymap.set("n", "<Space>", function()
  local cursor = vim.api.nvim_win_get_cursor(active.win)
  local task = task_at_cursor(cursor[1])
  if not task then return end
  local key = task_key(task)
  if active.selected[key] then
    active.selected[key] = nil
  else
    active.selected[key] = true
  end
  apply_selection_highlights_timeline(active)
  update_selection_status_timeline(active)
end, kopts)
```

### 3. Visual Feedback for Selected Tasks

#### 3a. Selection Highlight

Define a new highlight group in the setup functions or via `nvim_set_hl`:

```lua
-- In M.setup() of both modules, or in a shared highlight init:
vim.api.nvim_set_hl(0, "VaultKanbanSelected", { bg = "#3b4261", bold = true })
vim.api.nvim_set_hl(0, "VaultTimelineSelected", { bg = "#3b4261", bold = true })
```

A separate namespace avoids conflicts with the board/timeline highlights:

```lua
local sel_ns = vim.api.nvim_create_namespace("vault_kanban_selection")
```

#### 3b. Apply Selection Highlights (Kanban)

```lua
---Apply or clear selection highlights on the kanban board.
---@param state table
local function apply_selection_highlights(state)
  vim.api.nvim_buf_clear_namespace(state.buf, sel_ns, 0, -1)
  for _, cp in ipairs(state.card_positions) do
    local key = task_key(cp.task)
    if state.selected[key] then
      -- Highlight all 3 rows of the card (title, metadata, blank)
      for offset = 0, 2 do
        pcall(vim.api.nvim_buf_add_highlight,
          state.buf, sel_ns, "VaultKanbanSelected",
          cp.row + offset, 0, -1)
      end
    end
  end
end
```

#### 3c. Apply Selection Highlights (Timeline)

```lua
---Apply or clear selection highlights on the timeline.
---@param a table  active state
local function apply_selection_highlights_timeline(a)
  vim.api.nvim_buf_clear_namespace(a.buf, sel_ns, 0, -1)
  for _, tp in ipairs(a.task_positions) do
    local key = task_key(tp.task)
    if a.selected[key] then
      pcall(vim.api.nvim_buf_add_highlight,
        a.buf, sel_ns, "VaultTimelineSelected",
        tp.row, 0, -1)
    end
  end
end
```

#### 3d. Selection Count in Status Line

Show `[N selected]` in the floating window title or in a virtual text footer.

```lua
---Update window title to reflect selection count.
---@param state table  must have .win and .selected
local function update_selection_status(state)
  local count = 0
  for _ in pairs(state.selected) do count = count + 1 end
  local title = " Kanban "
  if count > 0 then
    title = " Kanban [" .. count .. " selected] "
  end
  pcall(vim.api.nvim_win_set_config, state.win, { title = title, title_pos = "center" })
end
```

```lua
local function update_selection_status_timeline(a)
  local count = 0
  for _ in pairs(a.selected) do count = count + 1 end
  local title = "Task Timeline"
  if count > 0 then
    title = "Task Timeline [" .. count .. " selected]"
  end
  pcall(vim.api.nvim_win_set_config, a.win, { title = title, title_pos = "center" })
end
```

### 4. Select All in Column (`V`) -- Kanban Only

```lua
-- V: select all tasks in current column
map("V", function()
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local row = cursor[1] - 1
  local current = find_card_at_cursor(state.card_positions, row)
  if not current then return end
  local col_cards = cards_in_column(state.card_positions, current.col_index)
  -- If all are already selected, deselect all; otherwise select all
  local all_selected = true
  for _, cp in ipairs(col_cards) do
    if not state.selected[task_key(cp.task)] then
      all_selected = false
      break
    end
  end
  for _, cp in ipairs(col_cards) do
    local key = task_key(cp.task)
    if all_selected then
      state.selected[key] = nil
    else
      state.selected[key] = true
    end
  end
  apply_selection_highlights(state)
  update_selection_status(state)
end, "Kanban: select/deselect all in column")
```

### 5. Clear Selection (`<Esc>`)

Override the existing `<Esc>` behavior: if there is an active selection, clear
it instead of closing the window.

**Kanban** -- replace the existing `<Esc>` mapping:

```lua
-- <Esc>: clear selection, or close if nothing selected
map("<Esc>", function()
  local count = 0
  for _ in pairs(state.selected) do count = count + 1 end
  if count > 0 then
    state.selected = {}
    apply_selection_highlights(state)
    update_selection_status(state)
  else
    state.close()
  end
end, "Kanban: clear selection / close")
```

**Timeline** -- same pattern:

```lua
vim.keymap.set("n", "<Esc>", function()
  local count = 0
  for _ in pairs(active.selected) do count = count + 1 end
  if count > 0 then
    active.selected = {}
    apply_selection_highlights_timeline(active)
    update_selection_status_timeline(active)
  else
    active.close()
    active = nil
  end
end, kopts)
```

### 6. Shared Bulk Mutation Helpers

These helpers belong in `task_kanban.lua` but are also callable from
`task_timeline.lua` by requiring the module. Alternatively, extract into a
shared `task_ops.lua` module.

#### 6a. Collect Selected Tasks

```lua
---Collect the actual task objects for all selected keys from card/task positions.
---@param positions table[]  card_positions or task_positions
---@param selected table<string, boolean>
---@return table[]  list of task objects
local function collect_selected_tasks(positions, selected)
  local tasks = {}
  local seen = {}
  for _, pos in ipairs(positions) do
    local key = task_key(pos.task)
    if selected[key] and not seen[key] then
      seen[key] = true
      tasks[#tasks + 1] = pos.task
    end
  end
  return tasks
end
```

#### 6b. Snapshot for Undo

```lua
---Create a snapshot of task states for undo.
---@param tasks table[]
---@param field string  "status"|"priority"|"due"
---@return table  snapshot entry for the undo stack
local function snapshot_tasks(tasks, field)
  local snap = { field = field, tasks = {} }
  for _, task in ipairs(tasks) do
    snap.tasks[#snap.tasks + 1] = {
      abs_path = task.abs_path,
      line = task.line,
      file = task.file,
      old_status = task.status,
      old_priority = task.priority,
      old_due = task.due,
    }
  end
  return snap
end
```

#### 6c. Set Task Priority in Source File

New function, analogous to `set_task_status()`:

```lua
---Update a task's priority inline field in its source file.
---@param task table
---@param new_priority number|nil  nil to remove priority
---@return boolean success
local function set_task_priority(task, new_priority)
  if not task or not task.abs_path or not task.line then return false end

  local file_lines = vim.fn.readfile(task.abs_path)
  if not file_lines or #file_lines == 0 then return false end

  local line_idx = task.line
  if line_idx < 1 or line_idx > #file_lines then return false end

  local line = file_lines[line_idx]

  if new_priority then
    -- Replace existing priority field or append one
    if line:find("%[priority::%s*%d+%s*%]") then
      line = line:gsub("%[priority::%s*%d+%s*%]", "[priority:: " .. new_priority .. "]")
    else
      -- Insert before the first tag or at end of line
      line = line .. " [priority:: " .. new_priority .. "]"
    end
  else
    -- Remove priority field
    line = line:gsub("%s*%[priority::%s*%d+%s*%]", "")
  end

  file_lines[line_idx] = line
  vim.fn.writefile(file_lines, task.abs_path)

  -- Reload buffer if open
  local bufnr = vim.fn.bufnr(task.abs_path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("edit!") end)
  end

  task.priority = new_priority
  return true
end
```

#### 6d. Set Task Due Date in Source File

```lua
---Update a task's due date inline field in its source file.
---@param task table
---@param new_due string|nil  "YYYY-MM-DD" or nil to remove
---@return boolean success
local function set_task_due(task, new_due)
  if not task or not task.abs_path or not task.line then return false end

  local file_lines = vim.fn.readfile(task.abs_path)
  if not file_lines or #file_lines == 0 then return false end

  local line_idx = task.line
  if line_idx < 1 or line_idx > #file_lines then return false end

  local line = file_lines[line_idx]

  if new_due then
    if line:find("%[due::%s*%d%d%d%d%-%d%d%-%d%d%s*%]") then
      line = line:gsub("%[due::%s*%d%d%d%d%-%d%d%-%d%d%s*%]", "[due:: " .. new_due .. "]")
    else
      line = line .. " [due:: " .. new_due .. "]"
    end
  else
    line = line:gsub("%s*%[due::%s*%d%d%d%d%-%d%d%-%d%d%s*%]", "")
  end

  file_lines[line_idx] = line
  vim.fn.writefile(file_lines, task.abs_path)

  local bufnr = vim.fn.bufnr(task.abs_path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("edit!") end)
  end

  task.due = new_due
  return true
end
```

#### 6e. Bulk Apply with Recurrence Awareness

When bulk-completing tasks (`new_status == "x"`), each recurring task must
trigger `handle_recurrence()` individually. Because recurrence inserts a new
line above the completed task, line numbers shift. Process tasks in **reverse
line order per file** to keep line numbers stable.

```lua
---Apply a bulk status change to a list of tasks.
---@param tasks table[]
---@param new_status string
---@return number success_count
local function bulk_set_status(tasks, new_status)
  -- Group by file, sort descending by line within each file
  local by_file = {}
  for _, task in ipairs(tasks) do
    local fp = task.abs_path
    if not by_file[fp] then by_file[fp] = {} end
    by_file[fp][#by_file[fp] + 1] = task
  end
  for fp, file_tasks in pairs(by_file) do
    table.sort(file_tasks, function(a, b) return a.line > b.line end)
  end

  local count = 0
  for _, file_tasks in pairs(by_file) do
    for _, task in ipairs(file_tasks) do
      if set_task_status(task, new_status) then
        count = count + 1
      end
    end
  end
  return count
end
```

### 7. Bulk Operation Keymaps

All bulk keymaps are prefixed with `b` (mnemonic: "bulk").

#### 7a. Bulk Status Change (`bm`)

**Kanban:**

```lua
-- bm: bulk status change for selected tasks
map("bm", function()
  local tasks = collect_selected_tasks(state.card_positions, state.selected)
  if #tasks == 0 then
    vim.notify("No tasks selected", vim.log.levels.INFO)
    return
  end

  -- Build status menu from config.task_states
  local items = {}
  for i, ts in ipairs(config.task_states) do
    items[#items + 1] = string.format("%d. [%s] %s", i, ts.mark, ts.label)
  end

  vim.ui.select(items, { prompt = "Set status for " .. #tasks .. " tasks:" }, function(choice)
    if not choice then return end
    local idx = tonumber(choice:match("^(%d+)"))
    if not idx or not config.task_states[idx] then return end
    local new_mark = config.task_states[idx].mark

    -- Snapshot for undo
    local snap = snapshot_tasks(tasks, "status")
    table.insert(state.undo_stack, snap)

    local count = bulk_set_status(tasks, new_mark)
    state.selected = {}

    vim.schedule(function()
      if vim.api.nvim_win_is_valid(state.win) then
        redraw(state)
        apply_selection_highlights(state)
        update_selection_status(state)
      end
      vim.notify(string.format("Changed status of %d/%d tasks to [%s]", count, #tasks, new_mark))
    end)
  end)
end, "Kanban: bulk set status")
```

**Timeline** -- identical logic using `active.task_positions`, `active.selected`,
`active.undo_stack`, and the timeline redraw/highlight functions.

#### 7b. Bulk Priority Change (`bp`)

```lua
-- bp: bulk priority change for selected tasks
map("bp", function()
  local tasks = collect_selected_tasks(state.card_positions, state.selected)
  if #tasks == 0 then
    vim.notify("No tasks selected", vim.log.levels.INFO)
    return
  end

  vim.ui.input({
    prompt = "Set priority for " .. #tasks .. " tasks (1-5, empty to clear): ",
  }, function(input)
    if input == nil then return end

    local snap = snapshot_tasks(tasks, "priority")
    table.insert(state.undo_stack, snap)

    local new_priority = nil
    if input ~= "" then
      new_priority = tonumber(input)
      if not new_priority or new_priority < 1 or new_priority > 5 then
        vim.notify("Invalid priority (must be 1-5)", vim.log.levels.ERROR)
        return
      end
    end

    local count = 0
    for _, task in ipairs(tasks) do
      if set_task_priority(task, new_priority) then
        count = count + 1
      end
    end
    state.selected = {}

    vim.schedule(function()
      if vim.api.nvim_win_is_valid(state.win) then
        redraw(state)
        apply_selection_highlights(state)
        update_selection_status(state)
      end
      local label = new_priority and ("P" .. new_priority) or "none"
      vim.notify(string.format("Set priority to %s for %d/%d tasks", label, count, #tasks))
    end)
  end)
end, "Kanban: bulk set priority")
```

#### 7c. Bulk Due Date Change (`bd`)

```lua
-- bd: bulk due date change for selected tasks
map("bd", function()
  local tasks = collect_selected_tasks(state.card_positions, state.selected)
  if #tasks == 0 then
    vim.notify("No tasks selected", vim.log.levels.INFO)
    return
  end

  vim.ui.input({
    prompt = "Set due date for " .. #tasks .. " tasks (YYYY-MM-DD, empty to clear): ",
  }, function(input)
    if input == nil then return end

    local snap = snapshot_tasks(tasks, "due")
    table.insert(state.undo_stack, snap)

    local new_due = nil
    if input ~= "" then
      -- Validate date format
      if not input:match("^%d%d%d%d%-%d%d%-%d%d$") then
        vim.notify("Invalid date format (use YYYY-MM-DD)", vim.log.levels.ERROR)
        return
      end
      new_due = input
    end

    local count = 0
    for _, task in ipairs(tasks) do
      if set_task_due(task, new_due) then
        count = count + 1
      end
    end
    state.selected = {}

    vim.schedule(function()
      if vim.api.nvim_win_is_valid(state.win) then
        redraw(state)
        apply_selection_highlights(state)
        update_selection_status(state)
      end
      local label = new_due or "none"
      vim.notify(string.format("Set due date to %s for %d/%d tasks", label, count, #tasks))
    end)
  end)
end, "Kanban: bulk set due date")
```

### 8. Batch Undo (`u`)

Each bulk operation pushes a snapshot onto `state.undo_stack`. The `u` keymap
pops the most recent snapshot and restores each task's previous value in its
source file.

```lua
-- u: undo last bulk operation
map("u", function()
  if #state.undo_stack == 0 then
    vim.notify("Nothing to undo", vim.log.levels.INFO)
    return
  end

  local snap = table.remove(state.undo_stack)
  local count = 0

  if snap.field == "status" then
    -- Restore in reverse line order per file (same grouping as bulk_set_status)
    local by_file = {}
    for _, s in ipairs(snap.tasks) do
      if not by_file[s.abs_path] then by_file[s.abs_path] = {} end
      by_file[s.abs_path][#by_file[s.abs_path] + 1] = s
    end
    for _, file_snaps in pairs(by_file) do
      table.sort(file_snaps, function(a, b) return a.line > b.line end)
    end
    for _, file_snaps in pairs(by_file) do
      for _, s in ipairs(file_snaps) do
        -- Build a minimal task table for set_task_status
        local pseudo_task = {
          abs_path = s.abs_path,
          line = s.line,
          file = s.file,
          status = nil, -- current status unknown; set_task_status reads from file
          repeat_rule = nil, -- do NOT trigger recurrence on undo
        }
        -- Read current status to inform completion field logic
        local file_lines = vim.fn.readfile(s.abs_path)
        if file_lines and s.line >= 1 and s.line <= #file_lines then
          local mark = file_lines[s.line]:match("%- %[(.)%]")
          if mark then pseudo_task.status = mark end
        end
        -- Temporarily clear repeat_rule to prevent recurrence on undo
        if set_task_status(pseudo_task, s.old_status) then
          count = count + 1
        end
      end
    end
  elseif snap.field == "priority" then
    for _, s in ipairs(snap.tasks) do
      local pseudo_task = { abs_path = s.abs_path, line = s.line, file = s.file }
      if set_task_priority(pseudo_task, s.old_priority) then
        count = count + 1
      end
    end
  elseif snap.field == "due" then
    for _, s in ipairs(snap.tasks) do
      local pseudo_task = { abs_path = s.abs_path, line = s.line, file = s.file }
      if set_task_due(pseudo_task, s.old_due) then
        count = count + 1
      end
    end
  end

  vim.schedule(function()
    if vim.api.nvim_win_is_valid(state.win) then
      redraw(state)
    end
    vim.notify(string.format("Undid %s change for %d tasks", snap.field, count))
  end)
end, "Kanban: undo last bulk operation")
```

**Important undo caveat for recurrence:** When undoing a bulk status change that
set tasks to `x`, the undo restores the checkbox to its previous mark but does
NOT delete the new recurring task line that `handle_recurrence()` inserted.
Fully reversing recurrence would require tracking inserted line numbers, which
adds significant complexity. The undo notification should warn: "Note: recurring
task copies created during completion are not removed by undo."

### 9. Timeline Mutation Keymaps

The timeline currently has no mutation keymaps. Add single-task and bulk
operations mirroring the kanban, reusing `set_task_status`,
`set_task_priority`, and `set_task_due`:

```lua
-- Inside set_keymaps() in task_timeline.lua:

-- m: cycle status for task under cursor
vim.keymap.set("n", "m", function()
  local cursor = vim.api.nvim_win_get_cursor(active.win)
  local task = task_at_cursor(cursor[1])
  if not task then return end

  local columns = config.task_states
  local current_idx
  for i, ts in ipairs(columns) do
    if ts.mark == task.status then current_idx = i; break end
  end
  if not current_idx then return end

  local next_idx = current_idx % #columns + 1
  local kanban = require("andrew.vault.task_kanban")
  -- Reuse set_task_status via the module (requires exporting it; see section 11)
  if kanban.set_task_status(task, columns[next_idx].mark) then
    vim.schedule(function() redraw(state) end)
  end
end, kopts)

-- bm, bp, bd, u: bulk operations (same pattern as kanban, using active.selected)
```

### 10. Recurrence Handling During Bulk Completion

The critical correctness concern: when bulk-setting status to `x` for multiple
tasks, some may have `[repeat:: ...]` rules. `handle_recurrence()` inserts a
new line above the completed task, which shifts line numbers for tasks below it
in the same file.

The solution (implemented in `bulk_set_status` above):

1. **Group tasks by file.**
2. **Sort descending by line number within each file.**
3. **Process from bottom to top** so that insertions above a task do not affect
   tasks that have already been processed.

This is the same strategy used by any multi-line buffer edit (e.g., LSP
refactoring). The existing `set_task_status()` handles the per-task recurrence
call, so `bulk_set_status` just needs to enforce the ordering.

### 11. Module Exports

To share mutation functions between kanban and timeline, export them from
`task_kanban.lua`:

```lua
-- At the end of task_kanban.lua, before `return M`:
M.set_task_status = set_task_status
M.set_task_priority = set_task_priority
M.set_task_due = set_task_due
M.bulk_set_status = bulk_set_status
```

Alternatively, extract these into a new `task_ops.lua` module (cleaner
separation, avoids circular dependencies). The timeline would then
`require("andrew.vault.task_ops")` instead of requiring the full kanban module.

### 12. Config Additions

```lua
-- In config.lua, extend M.kanban:
M.kanban = {
  columns = nil,
  max_per_column = 50,
  show_priority = true,
  show_due = true,
  -- NEW:
  bulk_confirm = true,   -- prompt for confirmation on bulk ops affecting >10 tasks
  max_undo_stack = 20,   -- maximum undo stack depth
}
```

### 13. Help Keymap (`?`)

Add a `?` keymap that displays available keymaps in a notification or small
float. Include the new bulk operation keys:

```lua
map("?", function()
  local help = {
    "Kanban Keymaps:",
    "  j/k       Move up/down in column",
    "  h/l       Move between columns",
    "  <CR>      Jump to task source",
    "  m/M       Cycle task status forward/backward",
    "  p         Filter by priority",
    "  d         Filter by due date",
    "  /         Filter by text",
    "  P         Filter by project tag",
    "  r         Reset all filters",
    "",
    "  <Space>   Toggle task selection",
    "  V         Select/deselect all in column",
    "  <Esc>     Clear selection (or close if none)",
    "  bm        Bulk set status",
    "  bp        Bulk set priority",
    "  bd        Bulk set due date",
    "  u         Undo last bulk operation",
    "  q         Close",
  }
  vim.notify(table.concat(help, "\n"), vim.log.levels.INFO)
end, "Kanban: show help")
```

## Before/After Comparison

### Before: Single Task Status Change (Kanban)

User positions cursor on a card and presses `m` to advance its status. To
change 8 tasks from "open" to "done", the user must navigate to each card
individually and press `m` twice (open -> in-progress -> done), repeating 16
keystrokes plus navigation.

### After: Bulk Status Change (Kanban)

1. User presses `V` on the "open" column to select all 8 tasks. Selected cards
   are highlighted with `VaultKanbanSelected` background. The title bar shows
   `Kanban [8 selected]`.
2. User presses `bm`, selects `[x] done` from the status picker.
3. All 8 tasks are updated in their source files. Recurring tasks spawn new
   occurrences. The board redraws with cards moved to the "done" column.
4. If the user realizes this was wrong, pressing `u` restores all 8 tasks to
   their previous status.

**Keystroke comparison:** Before: ~40 keystrokes. After: 4 keystrokes (`V`,
`bm`, `3`, `<CR>`).

### Before: Timeline Has No Mutation

User sees overdue tasks in the timeline, must press `<CR>` to jump to each
file, manually edit the checkbox, then reopen the timeline.

### After: Timeline Supports Bulk Ops

User selects overdue tasks with `<Space>`, presses `bd` to set a new due date,
types `2026-03-05`, and all selected tasks are updated. Pressing `bm` and
choosing "done" completes them in bulk.

## Test Cases

### 1. Single Selection Toggle

- Open Kanban with tasks in multiple columns.
- Navigate to a card, press `<Space>`.
- **Expected:** Card is highlighted with `VaultKanbanSelected`. Title shows
  `[1 selected]`.
- Press `<Space>` again.
- **Expected:** Highlight removed. Title reverts to `Kanban`.

### 2. Select All in Column

- Navigate to a column with 5 tasks.
- Press `V`.
- **Expected:** All 5 cards highlighted. Title shows `[5 selected]`.
- Press `V` again.
- **Expected:** All 5 deselected.

### 3. Clear Selection with Esc

- Select 3 tasks across columns.
- Press `<Esc>`.
- **Expected:** Selection cleared, window remains open.
- Press `<Esc>` again.
- **Expected:** Window closes.

### 4. Bulk Status Change

- Select 3 open tasks (mark=` `).
- Press `bm`, choose `[x] done`.
- **Expected:** All 3 source files updated. Board redraws with tasks in the
  "done" column. Selection cleared.
- Verify source files: checkboxes are `[x]`, `[completion:: YYYY-MM-DD]`
  appended.

### 5. Bulk Status Change with Recurrence

- Select 2 tasks: one with `[repeat:: every week]`, one without.
- Press `bm`, choose `[x] done`.
- **Expected:** Both tasks completed. The recurring task's source file now has a
  new unchecked copy above the completed line with the next due date. The
  non-recurring task has no new line.
- Board redraws showing the new recurring task in the "open" column.

### 6. Bulk Priority Change

- Select 4 tasks with mixed priorities (P1, P3, none).
- Press `bp`, type `2`.
- **Expected:** All 4 tasks now have `[priority:: 2]` in their source files.
  Existing `[priority:: N]` fields updated; tasks without priority get it
  appended.

### 7. Bulk Due Date Change

- Select 3 tasks.
- Press `bd`, type `2026-03-15`.
- **Expected:** All 3 source files updated with `[due:: 2026-03-15]`.
- Press `bd` again with empty input on re-selected tasks.
- **Expected:** `[due:: ...]` fields removed.

### 8. Undo Bulk Operation

- Perform a bulk status change (open -> done) on 3 tasks.
- Press `u`.
- **Expected:** All 3 tasks restored to `[ ]` in source files. Board redraws.
  Notification: "Undid status change for 3 tasks".

### 9. Undo Stack Depth

- Perform 3 separate bulk operations.
- Press `u` three times.
- **Expected:** Each undo reverses the most recent remaining operation. After 3
  undos, pressing `u` shows "Nothing to undo".

### 10. Bulk with Confirmation (>10 tasks)

- Set `config.kanban.bulk_confirm = true`.
- Select 15 tasks, press `bm`.
- **Expected:** A confirmation prompt appears: "Change status of 15 tasks? (y/n)".
  Only proceeds on `y`.

### 11. Timeline Bulk Operations

- Open timeline. Select 3 overdue tasks with `<Space>`.
- Press `bm`, choose `[x] done`.
- **Expected:** All 3 tasks completed in source files. Timeline redraws.
  Selection cleared.

### 12. Selection Survives Redraw

- Select 2 tasks in kanban.
- Press `r` (reset filters) to trigger a redraw.
- **Expected:** The same 2 tasks remain selected (matched by `file:line` key).

### 13. Invalid Input Handling

- Select tasks, press `bp`, type `abc`.
- **Expected:** Error notification "Invalid priority (must be 1-5)". No changes
  made. Selection preserved.
- Press `bd`, type `not-a-date`.
- **Expected:** Error notification "Invalid date format (use YYYY-MM-DD)". No
  changes made.

### 14. Line Number Stability During Bulk Recurrence

- In a single file, create 3 recurring tasks on lines 10, 15, 20.
- Select all 3 in kanban, bulk complete.
- **Expected:** Processing order is line 20, 15, 10 (descending). Each
  `handle_recurrence()` inserts above its line. Final file has 6 task lines
  (3 new + 3 completed), all with correct content.

## Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/task_kanban.lua` | Add selection state, `sel_ns` namespace, `task_key()`, selection highlight functions, `set_task_priority()`, `set_task_due()`, `bulk_set_status()`, `collect_selected_tasks()`, `snapshot_tasks()`, keymaps (`<Space>`, `V`, `<Esc>` override, `bm`, `bp`, `bd`, `u`, `?`), export mutation functions on `M` |
| `lua/andrew/vault/task_timeline.lua` | Add selection state to `active`, `sel_ns` namespace, `task_key()`, timeline selection highlight functions, keymaps (`<Space>`, `<Esc>` override, `m`, `bm`, `bp`, `bd`, `u`), require kanban or task_ops for mutation functions |
| `lua/andrew/vault/config.lua` | Add `bulk_confirm` and `max_undo_stack` to `M.kanban` |
| `lua/andrew/vault/filter_utils.lua` | No changes required (existing `passes_task_filter` is sufficient) |
| `lua/andrew/vault/recurrence.lua` | No changes required (called per-task by existing `set_task_status`) |

### Optional: Extract `task_ops.lua`

If the mutation functions (`set_task_status`, `set_task_priority`,
`set_task_due`, `bulk_set_status`, `snapshot_tasks`, `collect_selected_tasks`,
`task_key`) grow large enough to warrant separation, create
`lua/andrew/vault/task_ops.lua` as a shared module. Both `task_kanban.lua` and
`task_timeline.lua` would require it. This avoids the timeline depending on the
full kanban module and keeps the mutation logic testable in isolation.
