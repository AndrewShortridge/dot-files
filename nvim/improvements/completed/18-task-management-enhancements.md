# 18 -- Task Management Enhancements

## Overview

The vault's task infrastructure is functional but view-limited. Tasks are
extracted by the vault index (`vault_index.lua`) with rich structured metadata
(status, due, priority, scheduled, repeat_rule, completion, tags, fields), and
the search system supports advanced task queries (`task-due:<7d`,
`task-priority:<=2`). However, the only way to *see* tasks is through flat
fzf-lua pickers (`tasks.lua`) or the calendar's per-day deadline list
(`calendar.lua`). There is no spatial layout that shows task distribution by
status, no temporal view that plots tasks along a timeline, no hierarchy
visualization for nested subtasks, and no proactive notification when tasks
become overdue.

This document specifies five sub-features that expand the task presentation
layer while reusing the existing vault index as the sole data source.

### Sub-features

| # | Feature | Module | Estimated Lines |
|---|---------|--------|-----------------|
| 1 | Kanban / Swimlane View | `task_kanban.lua` | ~450 |
| 2 | Task Timeline View | `task_timeline.lua` | ~400 |
| 3 | Subtask Hierarchy Visualization | `task_hierarchy.lua` | ~350 |
| 4 | Task Notifications for Overdue Items | `task_notify.lua` | ~200 |
| 5 | Strikethrough Completed Tasks | (config changes only) | ~20 |

### Motivation

- **Kanban:** Project managers and researchers think in terms of workflow
  stages (open, in-progress, done). A columnar view maps directly to that
  mental model and enables rapid status assessment without reading checkbox
  characters.

- **Timeline:** Due dates scattered across hundreds of files are invisible
  unless searched. A timeline makes temporal density visible -- clusters of
  deadlines, empty weeks, overdue pileups -- at a glance.

- **Hierarchy:** Many vault workflows use indented subtask lists under a parent
  task. Today, the vault index extracts each subtask as an independent entry
  with no parent relationship. Exposing hierarchy enables completion percentage
  tracking and collapsible tree views.

- **Notifications:** Overdue tasks silently accumulate. A periodic check with
  `vim.notify()` brings awareness without requiring the user to remember to
  run a query.

- **Strikethrough:** Already specified in detail at `improvements/14`. Included
  here for completeness as part of the task management enhancement suite.

---

## Data Flow: Vault Index to Views

All five sub-features read from the same source:

```
vault_index.lua (singleton)
  │
  ├── idx.files[rel_path].tasks[]
  │     ├── text, status, completed, line
  │     ├── due, priority, scheduled, repeat_rule, completion
  │     ├── tags[], fields{}
  │     └── (new) indent_level, parent_line  (sub-feature 3)
  │
  └── idx._generation  (cache invalidation key)
        │
        ├──> task_kanban.lua    (groups by status)
        ├──> task_timeline.lua  (groups by due date)
        ├──> task_hierarchy.lua (builds parent-child tree)
        └──> task_notify.lua    (filters overdue)
```

Each view module follows the pattern established by `calendar.lua`:

1. Obtain the vault index via `require("andrew.vault.vault_index").current()`.
2. Guard against `not idx or not idx:is_ready()` with an early return + notify.
3. Iterate `idx.files` to collect tasks matching the view's criteria.
4. Cache results keyed by `idx._generation` to avoid re-scanning on repeated
   opens when the index has not changed.
5. Register with `engine.register_cache()` for unified invalidation.

---

## Sub-feature 1: Kanban / Swimlane View

### Goal

A full-width scratch buffer showing tasks grouped into status columns:

```
 ┌─ Open ──────────┬─ In Progress ─────┬─ Done ──────────────┬─ Cancelled ──────┐
 │                  │                   │                     │                  │
 │  Review paper    │  Refactor embed   │  Fix slug matching  │  Remove legacy   │
 │  [due:: 03-01]   │  P2               │  [completion:: ...] │                  │
 │  P1 #urgent     │                   │                     │                  │
 │                  │  Write tests      │  Update config      │                  │
 │  Submit proposal │  P3               │                     │                  │
 │  [due:: 03-05]   │                   │                     │                  │
 │  P2             │                   │                     │                  │
 │                  │                   │                     │                  │
 └──────────────────┴───────────────────┴─────────────────────┴──────────────────┘
 [m] move  [<CR>] open  [p] filter priority  [d] filter due  [/] filter text  [q] close
```

### Architecture

**New module:** `lua/andrew/vault/task_kanban.lua`

The Kanban view is a scratch buffer with direct text rendering and extmark-based
highlighting. This approach is chosen over pure virtual text because:

1. Direct text is selectable and searchable (useful for large boards).
2. The calendar module already proves this pattern works well.
3. Cursor navigation across columns maps naturally to buffer columns.

#### Data Collection

```lua
--- Collect all tasks from the vault index, grouped by status column.
---@return table<string, table[]> status_char -> sorted task list
local function collect_tasks_by_status(filter_opts)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    vim.notify("Vault index not ready", vim.log.levels.WARN)
    return {}
  end

  local groups = {}
  for _, state in ipairs(config.task_states) do
    groups[state.mark] = {}
  end

  for rel_path, entry in pairs(idx.files) do
    if entry.tasks then
      for _, task in ipairs(entry.tasks) do
        if passes_filter(task, filter_opts) then
          local bucket = groups[task.status]
          if bucket then
            bucket[#bucket + 1] = {
              text = task.text,
              status = task.status,
              due = task.due,
              priority = task.priority,
              tags = task.tags,
              file = rel_path,
              abs_path = entry.abs_path,
              line = task.line,
              scheduled = task.scheduled,
              completion = task.completion,
            }
          end
        end
      end
    end
  end

  -- Sort each column: by priority (ascending), then by due date (ascending)
  for _, bucket in pairs(groups) do
    table.sort(bucket, function(a, b)
      local pa = a.priority or 999
      local pb = b.priority or 999
      if pa ~= pb then return pa < pb end
      local da = a.due or "9999-99-99"
      local db = b.due or "9999-99-99"
      return da < db
    end)
  end

  return groups
end
```

#### Filter Predicate

```lua
--- Check if a task passes the current filter set.
---@param task table vault index task entry
---@param opts table { priority_max?, due_before?, due_after?, text_pattern?, project? }
---@return boolean
local function passes_filter(task, opts)
  if not opts then return true end

  if opts.priority_max and task.priority then
    if task.priority > opts.priority_max then return false end
  end

  if opts.due_before and task.due then
    if task.due > opts.due_before then return false end
  end

  if opts.due_after and task.due then
    if task.due < opts.due_after then return false end
  end

  if opts.text_pattern then
    if not task.text:lower():find(opts.text_pattern:lower(), 1, true) then
      return false
    end
  end

  if opts.project then
    local found = false
    for _, tag in ipairs(task.tags or {}) do
      if tag:lower():find(opts.project:lower(), 1, true) then
        found = true
        break
      end
    end
    if not found then return false end
  end

  return true
end
```

#### Rendering

The board is rendered as a scratch buffer with fixed-width columns. Each column
width is `math.floor(total_width / num_columns)`. Tasks are rendered as
multi-line "cards" separated by blank lines.

```lua
--- Render the Kanban board into buffer lines and highlight regions.
---@param groups table<string, table[]> status -> task list
---@param col_width number width of each column in characters
---@return table { lines: string[], highlights: table[], card_positions: table[] }
local function render_board(groups, col_width)
  local columns = {}
  for _, state in ipairs(config.task_states) do
    columns[#columns + 1] = {
      mark = state.mark,
      label = state.label,
      tasks = groups[state.mark] or {},
    }
  end

  local lines = {}
  local highlights = {}
  local card_positions = {} -- { task_ref, row, col_index }

  -- Header row
  local header = ""
  for i, col in ipairs(columns) do
    local title = " " .. col.label:upper() .. " (" .. #col.tasks .. ")"
    title = title .. string.rep(" ", col_width - #title)
    if i < #columns then
      title = title:sub(1, col_width - 1) .. "|"
    end
    header = header .. title
  end
  lines[1] = header
  highlights[#highlights + 1] = { "VaultKanbanHeader", 0, 0, #header }

  -- Separator
  local sep = string.rep("-", col_width * #columns)
  lines[2] = sep

  -- Task cards: render row by row across columns
  local max_rows = 0
  for _, col in ipairs(columns) do
    max_rows = math.max(max_rows, #col.tasks)
  end

  local row_offset = 2 -- lines already written (header + separator)
  for task_idx = 1, max_rows do
    -- Each task card occupies card_height lines (title + metadata + blank)
    local card_height = 3
    for card_line = 1, card_height do
      local line = ""
      for col_idx, col in ipairs(columns) do
        local task = col.tasks[task_idx]
        local cell = ""

        if task then
          if card_line == 1 then
            -- Title line: truncate to fit column
            local display = truncate(task.text, col_width - 4)
            cell = "  " .. display
          elseif card_line == 2 then
            -- Metadata line: priority + due
            local parts = {}
            if task.priority then
              parts[#parts + 1] = "P" .. task.priority
            end
            if task.due then
              parts[#parts + 1] = task.due
            end
            cell = "  " .. table.concat(parts, " | ")
          else
            cell = "" -- blank separator between cards
          end
        end

        -- Pad to column width
        cell = cell .. string.rep(" ", col_width - #cell)
        if col_idx < #columns then
          cell = cell:sub(1, col_width - 1) .. "|"
        end
        line = line .. cell

        -- Record card position for navigation
        if task and card_line == 1 then
          card_positions[#card_positions + 1] = {
            task = task,
            row = row_offset + (task_idx - 1) * card_height,
            col_index = col_idx,
          }
        end
      end

      lines[#lines + 1] = line
    end
  end

  return { lines = lines, highlights = highlights, card_positions = card_positions }
end
```

#### Card Highlight Groups

Each card's title line is highlighted based on priority and overdue status:

| Condition | Highlight Group | Visual |
|-----------|----------------|--------|
| Overdue (due < today, status = open/in-progress) | `VaultKanbanOverdue` | Red fg, bold |
| Due today | `VaultKanbanDueToday` | Yellow fg, bold |
| Priority 1 | `VaultKanbanP1` | Red fg |
| Priority 2 | `VaultKanbanP2` | Orange fg |
| Priority 3+ or none | `VaultKanbanDefault` | Normal fg |
| Column header | `VaultKanbanHeader` | Bold, accent fg |
| Column divider | `VaultKanbanDivider` | Dim fg |

#### Navigation and Actions

Buffer-local keymaps set in the Kanban buffer:

| Key | Action | Description |
|-----|--------|-------------|
| `h` / `l` | Move cursor to previous/next column | Snaps to the nearest card in the target column at the same vertical position |
| `j` / `k` | Move to next/previous card in current column | Standard vertical navigation between cards |
| `<CR>` | Jump to task source | Closes Kanban, opens `abs_path` at `line` |
| `m` | Move task to next status | Updates checkbox in source file via `set_task_status()` |
| `M` | Move task to previous status | Reverse direction |
| `p` | Filter by priority | Prompts for max priority (1-5) |
| `d` | Filter by due date range | Prompts for date range keyword |
| `/` | Filter by text | Opens input for plain-text substring filter |
| `P` | Filter by project tag | Selects from discovered project tags |
| `r` | Reset all filters | Clears filter_opts and redraws |
| `q` / `<Esc>` | Close the Kanban view | |

#### Moving Tasks Between Columns

The `m` key updates the actual checkbox character in the source file:

```lua
--- Update a task's checkbox status in its source file.
---@param task table { abs_path, line, status }
---@param new_status string single checkbox character
local function set_task_status(task, new_status)
  -- Read the source file
  local lines = vim.fn.readfile(task.abs_path)
  if not lines or not lines[task.line] then
    vim.notify("Cannot read source file", vim.log.levels.ERROR)
    return false
  end

  local source_line = lines[task.line]
  local prefix, old_mark, rest = source_line:match("^(.*%- %[)(.)(%].*)$")
  if not prefix then
    vim.notify("Task line format not recognized", vim.log.levels.ERROR)
    return false
  end

  -- Handle completion date: add when moving to [x], remove when leaving [x]
  if new_status == "x" and old_mark ~= "x" then
    rest = rest:gsub("%s*%[completion::[^%]]*%]", "")
    rest = rest .. " [completion:: " .. os.date("%Y-%m-%d") .. "]"
  elseif old_mark == "x" and new_status ~= "x" then
    rest = rest:gsub("%s*%[completion::[^%]]*%]", "")
  end

  lines[task.line] = prefix .. new_status .. rest
  vim.fn.writefile(lines, task.abs_path)

  -- If the file is open in a buffer, reload it
  local bufnr = vim.fn.bufnr(task.abs_path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("edit!")
    end)
  end

  -- Handle recurrence if completing a recurring task
  if new_status == "x" then
    local recurrence = require("andrew.vault.recurrence")
    -- Re-read in case recurrence modifies the file
    recurrence.handle_recurrence(task.line)
  end

  return true
end
```

This mirrors the logic in `ftplugin/markdown.lua` (lines 162-181) where
`<leader>mx` cycles checkboxes and appends/removes `[completion:: ...]`.

#### Window Setup

```lua
function M.kanban(opts)
  opts = opts or {}
  local filter_opts = opts.filter or {}

  local groups = collect_tasks_by_status(filter_opts)

  local total_tasks = 0
  for _, bucket in pairs(groups) do
    total_tasks = total_tasks + #bucket
  end

  if total_tasks == 0 then
    vim.notify("No tasks found" .. (next(filter_opts) and " (with filters)" or ""),
      vim.log.levels.INFO)
    return
  end

  -- Use full editor width
  local ui_info = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
  local width = math.min(ui_info.width - 4, 160)
  local col_width = math.floor(width / #config.task_states)

  local data = render_board(groups, col_width)

  local float = ui.create_float_display({
    title = "Vault Kanban",
    lines = data.lines,
    width = width,
    height = math.min(#data.lines + 2, ui_info.height - 4),
    cursor_line = true,
  })

  -- Apply highlights, set keymaps, store state for navigation...
end
```

### Commands and Keybindings

```lua
function M.setup()
  vim.api.nvim_create_user_command("VaultKanban", function()
    M.kanban()
  end, { desc = "Open task Kanban board" })

  vim.keymap.set("n", "<leader>vxk", function()
    M.kanban()
  end, { desc = "Vault: Kanban board", silent = true })
end
```

### Config Options

Add to `config.lua`:

```lua
M.kanban = {
  -- Columns to show (subset of task_states marks). nil = show all.
  columns = nil,

  -- Maximum tasks per column before truncation with "... N more" footer.
  max_per_column = 50,

  -- Default sort: "priority" (ascending) or "due" (ascending).
  default_sort = "priority",

  -- Card display options.
  show_priority = true,
  show_due = true,
  show_tags = true,
  show_file = false,  -- Show source file basename on cards.
}
```

---

## Sub-feature 2: Task Timeline View

### Goal

A horizontal timeline showing tasks plotted by their due date, with visual
zones for overdue, today, and upcoming tasks:

```
  OVERDUE                  TODAY                   UPCOMING
  ──────────────────────────|────────────────────────────────────>

  Feb 20  Feb 24  Feb 26   Feb 28  Mar 01  Mar 03  Mar 05  Mar 10
  ────────────────────────────────────────────────────────────────
    *       *              |   *      **       *                *
                           |
  Feb 20:                  | Mar 01:
   Submit proposal (P2)    |  Review paper draft (P1)
   [OVERDUE 8d]            |  Write tests (P3)
                           |
  Feb 24:                  | Mar 03:
   Update config (P3)     |  Weekly standup notes
   [OVERDUE 4d]            |
                           | Mar 05:
  Feb 26:                  |  Submit proposal (P2)
   Fix slug matching       |
   [OVERDUE 2d]            | Mar 10:
                           |  Quarterly review
  ─────────────────────────────────────────────────────────────
  [h/l] scroll  [w/W] week/month  [<CR>] open  [f] filter  [q] close
```

### Architecture

**New module:** `lua/andrew/vault/task_timeline.lua`

#### Data Collection

```lua
--- Collect tasks with due dates, grouped by date.
---@param filter_opts table optional filters
---@return table { dated: table<string, table[]>, undated: table[] }
local function collect_timeline_tasks(filter_opts)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return { dated = {}, undated = {} } end

  local dated = {}   -- "YYYY-MM-DD" -> task[]
  local undated = {} -- tasks without due dates

  for rel_path, entry in pairs(idx.files) do
    if entry.tasks then
      for _, task in ipairs(entry.tasks) do
        -- Skip done/cancelled tasks by default (configurable)
        if task.status ~= "x" and task.status ~= "-" then
          if passes_filter(task, filter_opts) then
            if task.due then
              if not dated[task.due] then dated[task.due] = {} end
              dated[task.due][#dated[task.due] + 1] = {
                text = task.text,
                priority = task.priority,
                status = task.status,
                file = rel_path,
                abs_path = entry.abs_path,
                line = task.line,
                due = task.due,
              }
            else
              undated[#undated + 1] = task
            end
          end
        end
      end
    end
  end

  return { dated = dated, undated = undated }
end
```

#### Rendering Approach

The timeline is rendered as a scratch buffer with three zones:

1. **Header zone** (lines 1-3): Zone labels ("OVERDUE", "TODAY", "UPCOMING")
   with a horizontal axis line. The today marker `|` is positioned at a fixed
   column (configurable, default 1/3 from left).

2. **Tick zone** (line 4): Date labels along the axis. Dates with tasks get
   an asterisk marker above their label. Multiple tasks on the same date show
   multiple asterisks.

3. **Detail zone** (lines 5+): Tasks listed vertically, grouped by date and
   sorted chronologically. Each group has a date header and indented task
   entries.

Zone coloring:

| Zone | Highlight Group | Visual |
|------|----------------|--------|
| Overdue date header | `VaultTimelineOverdue` | Red, bold |
| Today date header | `VaultTimelineToday` | Yellow, bold |
| Upcoming date header | `VaultTimelineUpcoming` | Green, bold |
| Overdue age badge | `VaultTimelineOverdueBadge` | Red bg |
| Task text | `VaultTimelineTask` | Normal |
| Priority marker | `VaultTimelineP1` / `VaultTimelineP2` | Red / Orange |
| Axis line | `VaultTimelineDim` | Dim/surface2 |
| No-due section | `VaultTimelineUndated` | Italic, dim |

#### Time Navigation

The timeline supports scrolling through time:

```lua
local state = {
  center_date = engine.today(),  -- Date at the "today" column
  range_days = 14,               -- Days visible in each direction
  granularity = "day",           -- "day", "week", "month"
}

local function shift_range(offset)
  local y, m, d = state.center_date:match("(%d+)-(%d+)-(%d+)")
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  t = t + offset * 86400
  state.center_date = os.date("%Y-%m-%d", t)
  redraw()
end
```

| Key | Action |
|-----|--------|
| `h` / `l` | Scroll 1 day backward/forward |
| `H` / `L` | Scroll 7 days backward/forward |
| `w` | Switch granularity to week grouping |
| `W` | Switch granularity to month grouping |
| `d` | Switch granularity to day grouping |
| `t` | Recenter on today |
| `<CR>` | Jump to task under cursor in source file |
| `f` | Open filter prompt (priority, project, text) |
| `q` / `<Esc>` | Close |

### Commands and Keybindings

```lua
function M.setup()
  vim.api.nvim_create_user_command("VaultTimeline", function()
    M.timeline()
  end, { desc = "Open task timeline view" })

  vim.keymap.set("n", "<leader>vxt", function()
    M.timeline()
  end, { desc = "Vault: task timeline", silent = true })
end
```

### Config Options

Add to `config.lua`:

```lua
M.timeline = {
  -- Number of days visible in each direction from today.
  range_days = 14,

  -- Default granularity: "day", "week", "month".
  default_granularity = "day",

  -- Whether to show completed/cancelled tasks.
  show_done = false,

  -- Whether to include a section for tasks without due dates.
  show_undated = true,

  -- Position of the "today" marker as a fraction of the buffer width.
  -- 0.33 means today is 1/3 from the left (more room for upcoming).
  today_position = 0.33,
}
```

---

## Sub-feature 3: Subtask Hierarchy Visualization

### Goal

Parse indented task lists as parent-child relationships and expose hierarchy
information for:

1. Tree-view display in task pickers and dedicated views.
2. Completion percentage tracking (virtual text on parent tasks).
3. Collapsible hierarchy in the Kanban and fzf pickers.

### Current State

The vault index extracts tasks via `extract_tasks()` (vault_index.lua, line 518).
Each task is stored as a flat entry with a `line` number but no information
about its indentation level or parent task. This means:

```markdown
- [ ] Implement search module
  - [x] Write tokenizer
  - [x] Write parser
  - [ ] Write filter pipeline
  - [ ] Integration tests
```

produces five independent task entries. There is no way to know that "Write
tokenizer" is a child of "Implement search module".

### Architecture

**New module:** `lua/andrew/vault/task_hierarchy.lua`

**Modification to:** `vault_index.lua` (`extract_tasks()`)

#### Phase 1: Extend Task Extraction

Modify `extract_tasks()` to record indentation level for each task:

```lua
-- In extract_tasks(), after matching status_char:
local indent = #(line:match("^(%s*)") or "")
local indent_level = math.floor(indent / 2) -- Normalize: 2 spaces = 1 level

tasks[#tasks + 1] = {
  text = text,
  status = status_char,
  completed = completed,
  line = line_num,
  tags = task_tags,
  due = task_meta.due,
  priority = task_meta.priority,
  repeat_rule = task_meta.repeat_rule,
  completion = task_meta.completion,
  scheduled = task_meta.scheduled,
  fields = task_meta.fields,
  indent_level = indent_level,  -- NEW
}
```

This is a minimal, backward-compatible change. The `indent_level` field is
additive; existing code that does not reference it continues to work.

**Schema version:** Bump `SCHEMA_VERSION` to 4. The persisted index will be
rebuilt on first load after the upgrade (existing behavior for version bumps).

#### Phase 2: Build Parent-Child Relationships

The hierarchy module reconstructs the tree from flat task lists using
indentation levels. This runs on-demand (not during indexing) to keep the
index lean.

```lua
--- Build a tree from a flat task list using indent levels.
--- Each task gains `children` (list) and `parent_line` (number|nil) fields.
---@param tasks table[] flat task list from vault index entry
---@return table[] root tasks (indent_level 0) with nested children
function M.build_tree(tasks)
  if not tasks or #tasks == 0 then return {} end

  local roots = {}
  local stack = {} -- { task, indent_level } -- ancestors

  for _, task in ipairs(tasks) do
    task.children = {}
    local level = task.indent_level or 0

    -- Pop stack until we find the parent (indent_level < current)
    while #stack > 0 and stack[#stack].indent_level >= level do
      stack[#stack] = nil
    end

    if #stack > 0 then
      -- This task is a child of the top of stack
      local parent = stack[#stack]
      parent.children[#parent.children + 1] = task
      task.parent_line = parent.line
    else
      -- Root-level task
      roots[#roots + 1] = task
      task.parent_line = nil
    end

    stack[#stack + 1] = task
  end

  return roots
end
```

#### Phase 3: Completion Percentage

```lua
--- Calculate completion stats for a task tree node.
---@param task table task with children[]
---@return number done count
---@return number total count
function M.completion_stats(task)
  if not task.children or #task.children == 0 then
    return task.completed and 1 or 0, 1
  end

  local done = 0
  local total = 0
  for _, child in ipairs(task.children) do
    local d, t = M.completion_stats(child)
    done = done + d
    total = total + t
  end
  return done, total
end
```

#### Phase 4: Virtual Text on Parent Tasks

Display completion percentage as inline virtual text on parent tasks in normal
buffers (not just the dedicated view):

```lua
--- Render completion percentage virtual text on parent tasks in the current buffer.
---@param bufnr number
function M.render_completion_vtext(bufnr)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return end

  local bufpath = vim.api.nvim_buf_get_name(bufnr)
  local rel_path = engine.vault_relative(bufpath)
  if not rel_path then return end

  local entry = idx.files[rel_path]
  if not entry or not entry.tasks then return end

  local roots = M.build_tree(entry.tasks)
  local ns = vim.api.nvim_create_namespace("vault_task_hierarchy")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for _, root in ipairs(roots) do
    if root.children and #root.children > 0 then
      local done, total = M.completion_stats(root)
      local pct = math.floor(done / total * 100)
      local text = string.format(" [%d/%d %d%%]", done, total, pct)
      local hl = pct == 100 and "VaultHierarchyComplete" or "VaultHierarchyProgress"

      vim.api.nvim_buf_set_extmark(bufnr, ns, root.line - 1, 0, {
        virt_text = { { text, hl } },
        virt_text_pos = "eol",
      })
    end
  end
end
```

Trigger via autocmd on `BufReadPost` and `TextChanged` (debounced):

```lua
vim.api.nvim_create_autocmd({ "BufReadPost", "TextChanged", "TextChangedI" }, {
  group = augroup,
  pattern = "*.md",
  callback = function(ev)
    if engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
      -- Debounced: only re-render after 500ms of inactivity
      M._schedule_render(ev.buf)
    end
  end,
})
```

#### Phase 5: Tree View Display

A dedicated `:VaultTaskTree` command shows a collapsible tree in a float:

```
  ▼ [ ] Implement search module                    [0/4  0%]
    ├─ [x] Write tokenizer
    ├─ [x] Write parser
    ├─ [ ] Write filter pipeline
    └─ [ ] Integration tests

  ▼ [/] Refactor vault index                       [2/3 67%]
    ├─ [x] Extract inline fields
    ├─ [x] Add generation tracking
    └─ [ ] Optimize persistence

  ▶ [ ] Write documentation                        [0/5  0%]
```

Navigation:

| Key | Action |
|-----|--------|
| `<CR>` | Jump to task in source file |
| `<Tab>` | Toggle collapse/expand of children |
| `zo` / `zc` | Expand / collapse (vim fold style) |
| `zR` / `zM` | Expand all / collapse all |
| `q` / `<Esc>` | Close |

### Highlight Groups

| Group | Visual | Used For |
|-------|--------|----------|
| `VaultHierarchyProgress` | Yellow, italic | Incomplete % on parent |
| `VaultHierarchyComplete` | Green, italic | 100% on parent |
| `VaultHierarchyConnector` | Dim | Tree lines (vertical pipe, corner) |
| `VaultHierarchyParent` | Bold | Parent task text in tree view |

### Config Options

Add to `config.lua`:

```lua
M.hierarchy = {
  -- Show completion % virtual text on parent tasks in normal buffers.
  show_completion_vtext = true,

  -- Debounce interval for re-rendering virtual text after edits.
  debounce_ms = 500,

  -- Indent detection: number of spaces per indent level.
  indent_size = 2,

  -- Default collapse state in tree view: "expanded" or "collapsed".
  default_fold = "expanded",
}
```

### Commands and Keybindings

```lua
function M.setup()
  vim.api.nvim_create_user_command("VaultTaskTree", function()
    M.show_tree()
  end, { desc = "Show task hierarchy tree" })

  vim.keymap.set("n", "<leader>vxh", function()
    M.show_tree()
  end, { desc = "Vault: task hierarchy", silent = true })
end
```

---

## Sub-feature 4: Task Notifications for Overdue Items

### Goal

Proactively notify the user about overdue tasks when entering the vault,
without requiring them to run a search query.

### Architecture

**New module:** `lua/andrew/vault/task_notify.lua`

#### Overdue Detection

```lua
--- Count overdue tasks from the vault index.
--- A task is overdue if: due < today AND status is not "x" (done) or "-" (cancelled).
---@return number overdue_count
---@return table[] overdue_tasks (capped at display_limit)
local function find_overdue()
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return 0, {} end

  local today = engine.today()
  local overdue = {}

  for rel_path, entry in pairs(idx.files) do
    if entry.tasks then
      for _, task in ipairs(entry.tasks) do
        if task.due
          and task.due < today
          and task.status ~= "x"
          and task.status ~= "-"
        then
          overdue[#overdue + 1] = {
            text = task.text,
            due = task.due,
            priority = task.priority,
            file = rel_path,
            abs_path = entry.abs_path,
            line = task.line,
            days_overdue = days_between(task.due, today),
          }
        end
      end
    end
  end

  -- Sort by days overdue (most overdue first), then priority
  table.sort(overdue, function(a, b)
    if a.days_overdue ~= b.days_overdue then
      return a.days_overdue > b.days_overdue
    end
    return (a.priority or 999) < (b.priority or 999)
  end)

  return #overdue, overdue
end
```

#### Date Arithmetic Helper

```lua
--- Calculate the number of days between two YYYY-MM-DD date strings.
---@param from_str string
---@param to_str string
---@return number days (positive if to > from)
local function days_between(from_str, to_str)
  local fy, fm, fd = from_str:match("(%d+)-(%d+)-(%d+)")
  local ty, tm, td = to_str:match("(%d+)-(%d+)-(%d+)")
  if not fy or not ty then return 0 end

  local from_ts = os.time({ year = tonumber(fy), month = tonumber(fm), day = tonumber(fd), hour = 12 })
  local to_ts = os.time({ year = tonumber(ty), month = tonumber(tm), day = tonumber(td), hour = 12 })

  return math.floor((to_ts - from_ts) / 86400)
end
```

#### Notification Trigger

Fires on `BufEnter` for vault markdown files, throttled to at most once per
configured interval:

```lua
local _last_check = 0
local _snooze_until = 0

--- Check for overdue tasks and notify if any exist.
local function check_overdue()
  local now = os.time()

  -- Respect snooze
  if now < _snooze_until then return end

  -- Throttle: don't check more than once per interval
  local interval = (config.task_notify and config.task_notify.check_interval) or 300
  if now - _last_check < interval then return end
  _last_check = now

  local count, tasks = find_overdue()
  if count == 0 then return end

  -- Build notification message
  local msg = count .. " overdue task" .. (count > 1 and "s" or "")
  if count <= 3 then
    -- Show details for small counts
    local details = {}
    for i = 1, math.min(count, 3) do
      local t = tasks[i]
      details[#details + 1] = string.format(
        "  %s (%dd overdue)", truncate(t.text, 40), t.days_overdue
      )
    end
    msg = msg .. ":\n" .. table.concat(details, "\n")
  end

  vim.notify(msg, vim.log.levels.WARN, {
    title = "Vault: Overdue Tasks",
    id = "vault_overdue",
    replace = "vault_overdue",
  })

  -- Optional: system notification
  if config.task_notify and config.task_notify.system_notify then
    local summary = count .. " overdue vault task" .. (count > 1 and "s" or "")
    vim.fn.jobstart({ "notify-send", "-u", "normal", "Vault", summary }, { detach = true })
  end
end
```

#### Overdue Task Listing

The `:VaultOverdue` command opens all overdue tasks in an fzf-lua picker:

```lua
--- Open an fzf-lua picker with all overdue tasks.
function M.list_overdue()
  local count, tasks = find_overdue()

  if count == 0 then
    vim.notify("No overdue tasks", vim.log.levels.INFO)
    return
  end

  local fzf = require("fzf-lua")
  local entries = {}
  for _, task in ipairs(tasks) do
    local label = string.format(
      "[%dd] %s",
      task.days_overdue,
      task.abs_path .. ":" .. task.line .. ":1:- [" .. (task.status or " ") .. "] " .. task.text
    )
    entries[#entries + 1] = label
  end

  fzf.fzf_exec(entries, vim.tbl_extend("force",
    engine.vault_fzf_opts("Overdue tasks (" .. count .. ")"),
    { previewer = "builtin" }
  ))
end
```

#### Snooze Mechanism

```lua
--- Snooze overdue notifications for a specified duration.
---@param minutes number minutes to snooze (default: config value or 60)
function M.snooze(minutes)
  minutes = minutes or (config.task_notify and config.task_notify.snooze_minutes) or 60
  _snooze_until = os.time() + minutes * 60
  vim.notify(
    "Overdue notifications snoozed for " .. minutes .. " minutes",
    vim.log.levels.INFO
  )
end
```

### Commands and Keybindings

```lua
function M.setup()
  vim.api.nvim_create_user_command("VaultOverdue", function()
    M.list_overdue()
  end, { desc = "List all overdue tasks" })

  vim.api.nvim_create_user_command("VaultOverdueSnooze", function(args)
    local minutes = tonumber(args.args) or nil
    M.snooze(minutes)
  end, { nargs = "?", desc = "Snooze overdue notifications" })

  vim.keymap.set("n", "<leader>vxd", function()
    M.list_overdue()
  end, { desc = "Vault: overdue tasks", silent = true })

  -- Register autocmd for periodic checks
  local augroup = vim.api.nvim_create_augroup("VaultTaskNotify", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    pattern = "*.md",
    callback = function(ev)
      if engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
        -- Defer to avoid blocking buffer load
        vim.defer_fn(check_overdue, 500)
      end
    end,
  })
end
```

### Config Options

Add to `config.lua`:

```lua
M.task_notify = {
  -- Enable overdue task notifications.
  enabled = true,

  -- Minimum seconds between overdue checks.
  check_interval = 300,  -- 5 minutes

  -- Default snooze duration in minutes.
  snooze_minutes = 60,

  -- Use system notifications via notify-send (Linux).
  system_notify = false,

  -- Notification style: "count" (just the number) or "detail" (show task names).
  style = "detail",

  -- Maximum number of task details to show in notification.
  detail_limit = 3,
}
```

---

## Sub-feature 5: Strikethrough Completed Tasks

This sub-feature is fully specified in `improvements/14-strikethrough-completed-tasks.md`.

### Summary

- Add `scope_highlight = "RenderMarkdownCheckedScope"` to the `checked` state
  in render-markdown.nvim checkbox config.
- Add `scope_highlight = "RenderMarkdownCancelledScope"` to the `cancelled`
  custom state.
- Define `RenderMarkdownCheckedScope` and `RenderMarkdownCancelledScope` in the
  soft-paper theme with `{ fg = c.fg_faint, strikethrough = true }`.

### Files Modified

| File | Change |
|------|--------|
| `lua/andrew/plugins/render-markdown.lua` | Add `scope_highlight` to checked and cancelled states |
| `lua/andrew/themes/soft-paper.lua` | Add two highlight groups |

### Estimated Changes

~20 lines across two files. See `improvements/14` for exact code.

---

## New Highlight Groups

All new highlight groups are registered through `colors.lua` following the
existing pattern.

### Palette Additions

Add to each palette table in `colors.lua`:

```lua
-- Kanban
kanban_header        = "<accent>",
kanban_overdue       = "<red>",
kanban_due_today     = "<yellow>",
kanban_p1            = "<red>",
kanban_p2            = "<peach>",
kanban_default       = "<fg>",
kanban_divider       = "<surface2>",

-- Timeline
timeline_overdue     = "<red>",
timeline_today       = "<yellow>",
timeline_upcoming    = "<green>",
timeline_overdue_bg  = "<red_bg>",
timeline_task        = "<fg>",
timeline_dim         = "<surface2>",
timeline_undated     = "<mauve>",

-- Hierarchy
hierarchy_progress   = "<yellow>",
hierarchy_complete   = "<green>",
hierarchy_connector  = "<surface2>",
hierarchy_parent     = "<fg>",
```

### Highlight Group Definitions

Add to `build_hl_groups()` in `colors.lua`:

```lua
-- Kanban
VaultKanbanHeader      = { bold = true, fg = p.kanban_header },
VaultKanbanOverdue     = { bold = true, fg = p.kanban_overdue },
VaultKanbanDueToday    = { bold = true, fg = p.kanban_due_today },
VaultKanbanP1          = { fg = p.kanban_p1 },
VaultKanbanP2          = { fg = p.kanban_p2 },
VaultKanbanDefault     = { fg = p.kanban_default },
VaultKanbanDivider     = { fg = p.kanban_divider },

-- Timeline
VaultTimelineOverdue   = { bold = true, fg = p.timeline_overdue },
VaultTimelineToday     = { bold = true, fg = p.timeline_today },
VaultTimelineUpcoming  = { bold = true, fg = p.timeline_upcoming },
VaultTimelineOverdueBadge = { fg = p.calendar_today_fg, bg = p.timeline_overdue },
VaultTimelineTask      = { fg = p.timeline_task },
VaultTimelineDim       = { fg = p.timeline_dim },
VaultTimelineUndated   = { italic = true, fg = p.timeline_undated },

-- Hierarchy
VaultHierarchyProgress   = { italic = true, fg = p.hierarchy_progress },
VaultHierarchyComplete   = { italic = true, fg = p.hierarchy_complete },
VaultHierarchyConnector  = { fg = p.hierarchy_connector },
VaultHierarchyParent     = { bold = true },
```

---

## Integration Points

### Integration with Existing Task Cycling (`<leader>mx`)

The `ftplugin/markdown.lua` checkbox cycling logic (lines 162-181) updates the
buffer text directly. After cycling, the `TextChanged` event fires, which
triggers:

1. **Hierarchy sub-feature:** Re-renders completion % virtual text (debounced).
2. **Vault index:** Picks up the change via the filesystem watcher or
   `BufWritePost`, increments `_generation`.
3. **Kanban/Timeline:** Next time they are opened, they read the updated index.
   If already open, they would need a manual refresh (`r` key) or an
   autocmd-based approach.

The Kanban's `set_task_status()` function mirrors the cycling logic to keep
behavior consistent (completion date handling, recurrence).

### Integration with Search System

The existing `task-due:<today` query and the overdue notification module both
need "overdue" semantics. They share the same vault index data but compute
independently. No new coupling is introduced -- the notification module is
self-contained.

### Integration with Calendar

The calendar already shows due-date indicators. The timeline view is
complementary: the calendar shows a month at a time with per-day indicators,
while the timeline shows a scrollable date axis with task details. Both read
from the vault index and use `_generation` for cache invalidation.

---

## Files to Create

| File | Description | Est. Lines |
|------|-------------|------------|
| `lua/andrew/vault/task_kanban.lua` | Kanban board: collection, rendering, navigation, status moves | ~450 |
| `lua/andrew/vault/task_timeline.lua` | Timeline view: collection, axis rendering, time navigation | ~400 |
| `lua/andrew/vault/task_hierarchy.lua` | Hierarchy tree, completion %, virtual text, tree view | ~350 |
| `lua/andrew/vault/task_notify.lua` | Overdue detection, notification, snooze, fzf listing | ~200 |

## Files to Modify

| File | Change | Est. Lines Changed |
|------|--------|-------------------|
| `lua/andrew/vault/vault_index.lua` | Add `indent_level` to task extraction; bump SCHEMA_VERSION to 4 | ~5 |
| `lua/andrew/vault/config.lua` | Add `kanban`, `timeline`, `hierarchy`, `task_notify` sections | ~60 |
| `lua/andrew/vault/colors.lua` | Add palette entries and highlight groups for kanban, timeline, hierarchy | ~50 |
| `lua/andrew/vault/init.lua` | Require and setup new modules | ~12 |
| `lua/andrew/plugins/render-markdown.lua` | Add `scope_highlight` to checked/cancelled states | ~8 |
| `lua/andrew/themes/soft-paper.lua` | Add strikethrough highlight groups | ~4 |

---

## Edge Cases

### No Tasks in Vault

All views guard with `if total == 0 then vim.notify("No tasks found") return end`.
The Kanban, Timeline, and Tree views never open an empty float.

### Hundreds of Tasks

- **Kanban:** `config.kanban.max_per_column` (default 50) truncates each column
  with a "... N more" footer. Cards are rendered as 3-line blocks, so 50 tasks
  per column = ~150 lines per column. With 5 columns, the buffer is ~150 lines
  tall (scrollable).

- **Timeline:** Tasks are grouped by date. Even with hundreds of tasks, the
  detail zone only renders tasks within the visible date range
  (`range_days * 2` days). Tasks outside the range are not rendered until the
  user scrolls.

- **Tree view:** The tree is rendered lazily. Collapsed parents show only the
  summary line. Expanding all with hundreds of tasks is supported (the buffer
  grows, but Neovim handles multi-thousand-line buffers without issue).

- **Notifications:** `find_overdue()` iterates all tasks but only collects
  overdue ones. The notification shows at most `detail_limit` (default 3) task
  names regardless of total overdue count.

### Tasks Without Due Dates

- **Kanban:** Shows all tasks regardless of due date. The due field is simply
  absent from the card metadata line.

- **Timeline:** Undated tasks are collected separately. If `config.timeline.show_undated`
  is true, they appear in a "No Due Date" section at the bottom of the detail
  zone.

- **Notifications:** Only tasks with explicit `due` dates are considered
  overdue. Tasks without due dates are never flagged.

### Tasks in Non-Markdown Files

The vault index only parses `.md` files. Tasks in other file types are
invisible to all views. This matches existing behavior across all vault modules.

### Concurrent File Edits

When the Kanban `set_task_status()` writes to a file that is open in another
buffer, it calls `vim.cmd("edit!")` on that buffer to reload it. If the file is
open in a split alongside the Kanban float, the user sees the change reflected
immediately. If the file has unsaved changes, `edit!` discards them -- this is
acceptable because `set_task_status()` already wrote the file (merging its own
change). A future improvement could detect unsaved changes and warn before
overwriting.

### Kanban Column Configuration

If `config.kanban.columns` is set to a subset (e.g., `{" ", "/", "x"}` to hide
cancelled and deferred), tasks in excluded columns are silently omitted. The
board adapts its column count and width automatically.

### Index Not Ready

All views check `idx:is_ready()` before proceeding. If the index is still
building (e.g., on first launch with a large vault), the user sees
"Vault index not ready" and can retry after the build completes. The Kanban and
Timeline views do not fall back to ripgrep (unlike `tasks.lua`) because their
structured rendering requires parsed metadata that ripgrep cannot provide.

---

## Implementation Order

Recommended implementation sequence:

1. **Sub-feature 5: Strikethrough** -- Smallest change (~20 lines), immediate
   visual improvement, no new modules. Can be done independently. See
   `improvements/14` for complete implementation steps.

2. **Sub-feature 4: Notifications** -- Small module (~200 lines), simple logic,
   high daily-use value. Provides overdue awareness without requiring the user
   to open any view.

3. **Sub-feature 3: Hierarchy** -- Requires the `indent_level` change to
   `vault_index.lua` which is a prerequisite for hierarchy-aware features in
   Kanban and Timeline. The virtual text completion % provides immediate value
   in normal editing.

4. **Sub-feature 1: Kanban** -- Largest module, most complex rendering. Benefits
   from having hierarchy data available (can show subtask counts on cards).

5. **Sub-feature 2: Timeline** -- Can reuse filter and rendering patterns from
   Kanban. Builds on the established scratch-buffer-with-extmarks pattern.

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `vault_index.lua` | Task data source (singleton) | Yes |
| `ui.lua` | `create_float_display()` for all views | Yes |
| `engine.lua` | `vault_path`, `today()`, `register_cache()`, `is_vault_path()` | Yes |
| `config.lua` | `task_states`, new config sections | Yes |
| `colors.lua` | New highlight groups | Yes |
| `recurrence.lua` | Called from Kanban `set_task_status()` for [x] transitions | Yes (for Kanban) |
| `date_utils.lua` | `resolve_date()`, `start_of_day()` for timeline date math | Yes (for Timeline) |
| `fzf-lua` | Overdue task picker, filter prompts | Yes (for Notifications, optional for filters) |
| `render-markdown.nvim` | Strikethrough via `scope_highlight` | Yes (for sub-feature 5) |

No new external plugin dependencies are introduced.

---

## Testing

### Kanban

1. Open `:VaultKanban` with tasks in multiple states. Verify columns show
   correct counts and tasks.
2. Press `m` on a task in "Open" column. Verify it moves to "In Progress" and
   the source file checkbox changes to `[/]`.
3. Press `m` on a task to move it to `[x]`. Verify `[completion:: YYYY-MM-DD]`
   is appended in the source file.
4. Press `p` and set priority filter to 1. Verify only P1 tasks remain.
5. Press `r` to reset filters. Verify all tasks reappear.
6. Test with an empty vault (no tasks). Verify notification and no float.
7. Test with 100+ tasks. Verify column truncation and scroll behavior.

### Timeline

1. Open `:VaultTimeline` with tasks having various due dates. Verify overdue
   zone (red), today (yellow), upcoming (green).
2. Press `l` to scroll forward. Verify new dates appear and old ones disappear.
3. Press `t` to recenter on today.
4. Press `w` to switch to week granularity. Verify tasks group by week.
5. Test with all tasks undated. Verify only the "No Due Date" section shows.
6. Test with tasks due years in the future. Verify scrolling works.

### Hierarchy

1. Create a file with parent + child tasks at various indentation levels.
2. Verify completion % virtual text appears on parent tasks (e.g., "[2/4 50%]").
3. Cycle a child task to `[x]` via `<leader>mx`. Verify % updates after
   debounce.
4. Open `:VaultTaskTree`. Verify tree structure matches indentation.
5. Press `<Tab>` on a parent. Verify children collapse/expand.
6. Test with deeply nested tasks (3+ levels). Verify correct tree nesting.
7. Test with a flat list (no children). Verify no % virtual text appears.

### Notifications

1. Create a task with `[due:: YYYY-MM-DD]` set to yesterday. Open a vault file.
   Verify notification appears within 500ms.
2. Run `:VaultOverdueSnooze 1` (1 minute). Verify no notification on next
   BufEnter. Verify notification resumes after 1 minute.
3. Run `:VaultOverdue`. Verify fzf picker shows overdue tasks sorted by days
   overdue.
4. Complete all overdue tasks. Verify notification no longer appears.
5. Test with `config.task_notify.enabled = false`. Verify no autocmd fires.

### Strikethrough

See `improvements/14-strikethrough-completed-tasks.md`, Testing section.
