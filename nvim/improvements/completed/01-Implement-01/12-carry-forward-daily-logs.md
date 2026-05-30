# Carry-Forward for Daily Logs

## Problem Statement

Uncompleted tasks in daily log notes get lost when a new day begins. If a user
does not manually review yesterday's daily log before creating today's, open
and in-progress tasks silently vanish into the archive. Over time this erodes
trust in the daily planning workflow: tasks added to "Other Priorities" or
"Today's Focus" are effectively write-only unless the user remembers to revisit
old notes.

The carry-forward feature should automatically migrate incomplete tasks from the
most recent previous daily log into today's note when it is created, giving the
user a clear view of outstanding work without manual copy-paste.

## Current Architecture

### Daily Note Creation Paths

There are **three** code paths that create daily log notes. This is the central
architectural issue for this improvement:

**Path 1: Template system (`templates/daily_log.lua`)**

Called via `:VaultDaily` or `<leader>vtd`, which routes through `init.lua` ->
`run_template("Daily Log")` -> `daily_log.run(engine, pickers)`.

```lua
-- templates/daily_log.lua
function M.run(e, p)
  local date = e.today()
  local content = M.generate(e, date)
  e.write_note(config.dirs.log .. "/" .. date, content)
end
```

This path **already has carry-forward implemented**. The `generate()` function
calls `find_carryforward_tasks()` which scans the Log directory for the most
recent previous daily log, extracts incomplete tasks (open `[ ]` and
in-progress `[/]`), and inserts them under a "### Carried Forward" heading
inside the "## Morning Plan" section.

**Path 2: Navigate module (`navigate.lua`)**

Called via daily navigation commands (`:VaultDailyToday`, `:VaultDailyPrev`,
`:VaultDailyNext`) and the `<leader>vdt` keybinding. Routes through
`navigate.lua` -> `create_daily(date)`:

```lua
-- navigate.lua
local function create_daily(date)
  local daily_log = require("andrew.vault.templates.daily_log")
  local content = daily_log.generate(engine, date)
  engine.write_note(config.dirs.log .. "/" .. date, content)
end
```

This path **also has carry-forward** because it delegates to the same
`daily_log.generate()` function.

**Path 3: Calendar module (`calendar.lua`)**

Called when pressing `<CR>` on a date in the calendar float that has no existing
log. Routes through `calendar.lua` -> `open_or_create_log()`:

```lua
-- calendar.lua (lines 540-602)
local function open_or_create_log(date, y, m, day)
  local path = engine.vault_path .. "/Log/" .. date .. ".md"
  if vim.fn.filereadable(path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  else
    -- Builds content inline with string concatenation
    -- NO carry-forward logic
    local content = "---\n" .. "type: log\n" .. ...
    engine.run(function()
      engine.write_note(config.dirs.log .. "/" .. date, content)
    end)
  end
end
```

This path **does NOT have carry-forward**. It builds the daily log content
inline using raw string concatenation, duplicating the template structure but
missing the carry-forward section entirely. It also lacks any call to
`daily_log.generate()`.

### Task Data Structures

**Vault index task schema** (from `vault_index.lua`):

```lua
---@class VaultTask
---@field text string     -- Task text (everything after "- [x] ")
---@field status string   -- Character inside brackets: " ", "x", "/", "-", ">"
---@field completed boolean
---@field line number     -- 1-indexed line number
---@field tags string[]   -- Inline tags on the task line
```

The vault index extracts tasks from every file during indexing. Each
`VaultIndexEntry.tasks` is an array of `VaultTask` objects. The index does NOT
currently store the raw line text (with indentation and inline fields), only the
text after the checkbox marker.

**Task states** (from `config.lua`):

| Mark | Label | Carry forward? |
|------|-------|----------------|
| ` `  | open | Yes |
| `/`  | in-progress | Yes |
| `x`  | done | No |
| `-`  | cancelled | No |
| `>`  | deferred | Configurable (see below) |

**Existing carry-forward implementation** (`templates/daily_log.lua`):

```lua
local function extract_incomplete_tasks(filepath)
  local tasks = {}
  local f = io.open(filepath, "r")
  if not f then return tasks end
  for line in f:lines() do
    if line:match("^%s*- %[[ /]%]") then
      local text = line:match("^%s*- %[.%]%s+(.+)")
      if text and text ~= "" then
        local mark = line:match("^%s*- %[(.)%]")
        tasks[#tasks + 1] = "- [" .. mark .. "] " .. text
      end
    end
  end
  f:close()
  return tasks
end
```

Key observations about the existing implementation:
- Only carries `[ ]` (open) and `[/]` (in-progress) tasks
- Skips placeholder tasks with no text after the checkbox
- Normalizes all tasks to top-level indentation (strips leading whitespace)
- Preserves the original checkbox state (open stays open, in-progress stays in-progress)
- Preserves inline fields like `[due:: ...]`, `[repeat:: ...]` on the task line
- Only looks at the single most recent previous daily log (not multiple days back)
- Does NOT handle sub-tasks or nested indentation

The previous-log finder:

```lua
local function find_carryforward_tasks(vault_path, log_dir, date)
  local dir = vault_path .. "/" .. log_dir
  local entries = vim.fn.readdir(dir)
  local logs = {}
  for _, name in ipairs(entries) do
    local d = name:match("^(%d%d%d%d%-%d%d%-%d%d)%.md$")
    if d and d < date then
      logs[#logs + 1] = d
    end
  end
  table.sort(logs, function(a, b) return a > b end)
  local prev_date = logs[1] -- Most recent before target date
  ...
end
```

This scans all files in the Log directory, filters to dates before the target,
sorts descending, and picks the first (most recent). This handles gaps
correctly: if there is no log for yesterday but there is one for three days ago,
it will carry forward from three days ago.

### Recurrence System

The recurrence module (`recurrence.lua`) handles tasks with `[repeat:: ...]`
inline fields. When a task is checked `[x]`, `handle_recurrence()` creates a
new unchecked copy above the completed line with an updated due date. This is
orthogonal to carry-forward: recurring tasks that were completed yesterday will
already have spawned their next occurrence. Recurring tasks that were NOT
completed will be carried forward as regular open tasks.

### Template System

Templates are registered in `templates/init.lua` and each exports:
- `name`: display name for the picker
- `run(engine, pickers)`: creates the note
- `generate(engine, date)` (optional): returns content string without writing

The daily log template's `generate()` function is the canonical source for daily
note content. The calendar module's inline template is a duplicated, divergent
copy.

## Proposed Solution

The improvement consists of two parts:

### Part 1: Unify daily log creation (eliminate Path 3 duplication)

Refactor `calendar.lua`'s `open_or_create_log()` to delegate to the same
`daily_log.generate()` function used by the template system and navigate module.
This is the highest-impact change: it ensures carry-forward works regardless of
how a daily log is created.

### Part 2: Enhance the carry-forward system

Improve the existing carry-forward implementation with:
1. Configurable lookback depth (how many days back to scan)
2. Deferred task handling (opt-in carry-forward for `[>]` tasks)
3. Sub-task preservation (carry parent + children as a group)
4. Duplicate prevention (avoid re-carrying tasks already carried forward)
5. Source attribution (link back to the originating daily log)
6. Carry-forward notification (inform user when tasks are carried)

## Implementation Steps

### Step 1: Unify calendar daily log creation

**File: `lua/andrew/vault/calendar.lua`**

Replace the inline template in `open_or_create_log()` with a call to the
shared `daily_log.generate()`:

```lua
local function open_or_create_log(date, y, m, day)
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
```

This eliminates ~50 lines of duplicated template content and ensures
carry-forward, due-today queries, and any future template enhancements
automatically apply to calendar-created logs.

The `y`, `m`, `day` parameters to `open_or_create_log` become unused for
content generation (the `date` string is sufficient). They can be kept for the
function signature to avoid changing callers, or removed if desired.

### Step 2: Add carry-forward configuration

**File: `lua/andrew/vault/config.lua`**

Add a new configuration section:

```lua
-- ---------------------------------------------------------------------------
-- Carry-forward (daily log task migration)
-- ---------------------------------------------------------------------------
M.carry_forward = {
  enabled = true,

  -- Maximum number of previous daily logs to scan for incomplete tasks.
  -- 1 = only the most recent previous log (default, current behavior).
  -- 7 = scan up to a week back, accumulating all incomplete tasks.
  lookback = 1,

  -- Task states to carry forward. Keys are checkbox characters.
  -- " " = open, "/" = in-progress, ">" = deferred
  states = {
    [" "] = true,   -- open tasks
    ["/"] = true,   -- in-progress tasks
    [">"] = false,  -- deferred tasks (opt-in)
  },

  -- Preserve sub-task hierarchy. When true, if a parent task is carried,
  -- its indented sub-tasks are carried as a group.
  preserve_subtasks = true,

  -- Add a backlink to the source daily log in the carry-forward callout.
  -- When false, the callout just says "Incomplete tasks carried forward".
  source_link = true,

  -- Show a notification when tasks are carried forward.
  notify = true,

  -- Heading under which carried tasks are inserted.
  heading = "### Carried Forward",

  -- Sections in the daily log to scan for tasks (heading text patterns).
  -- If empty, scans the entire file.
  scan_sections = {},

  -- Sections to SKIP when scanning for tasks (e.g., "Completed Today").
  skip_sections = { "Completed Today", "Tomorrow's Priorities" },
}
```

### Step 3: Enhance task extraction

**File: `lua/andrew/vault/templates/daily_log.lua`**

Replace the current `extract_incomplete_tasks()` with a more capable version
that supports the new configuration options.

```lua
--- Extract incomplete tasks from a daily log file, respecting configuration.
---@param filepath string absolute path to a daily log
---@param opts table carry_forward config
---@return string[] tasks raw lines (preserving indentation for sub-tasks)
local function extract_incomplete_tasks(filepath, opts)
  local tasks = {}
  local f = io.open(filepath, "r")
  if not f then return tasks end

  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()

  -- Build section map if skip_sections is configured
  local skip_ranges = {}
  if opts.skip_sections and #opts.skip_sections > 0 then
    skip_ranges = compute_skip_ranges(lines, opts.skip_sections)
  end

  -- Track which lines are inside skipped sections
  local function is_skipped(line_num)
    for _, range in ipairs(skip_ranges) do
      if line_num >= range.start and line_num <= range.stop then
        return true
      end
    end
    return false
  end

  -- First pass: identify top-level incomplete tasks
  local task_groups = {}  -- { { start_line, end_line, lines = {...} } }
  local i = 1
  while i <= #lines do
    if is_skipped(i) then
      i = i + 1
      goto continue
    end

    local line = lines[i]
    local indent = line:match("^(%s*)")
    local mark = line:match("^%s*[-*] %[(.)%]")

    if mark and opts.states[mark] then
      -- Check for non-empty task text
      local text = line:match("^%s*[-*] %[.%]%s+(.+)")
      if text and text ~= "" then
        local group = { line }

        -- If preserving subtasks, collect indented children
        if opts.preserve_subtasks then
          local base_indent = #indent
          local j = i + 1
          while j <= #lines do
            local child_indent = #(lines[j]:match("^(%s*)") or "")
            if child_indent > base_indent and lines[j]:match("%S") then
              group[#group + 1] = lines[j]
              j = j + 1
            else
              break
            end
          end
        end

        task_groups[#task_groups + 1] = group
      end
    end

    i = i + 1
    ::continue::
  end

  -- Flatten groups into output, normalizing top-level indentation
  for _, group in ipairs(task_groups) do
    local base_indent = #(group[1]:match("^(%s*)") or "")
    for _, line in ipairs(group) do
      local current_indent = #(line:match("^(%s*)") or "")
      local relative_indent = current_indent - base_indent
      local stripped = line:gsub("^%s*", "")
      tasks[#tasks + 1] = string.rep("  ", relative_indent / 2) .. stripped
    end
  end

  return tasks
end

--- Compute line ranges for sections that should be skipped.
---@param lines string[]
---@param section_names string[]
---@return table[] ranges { {start=N, stop=N}, ... }
local function compute_skip_ranges(lines, section_names)
  local ranges = {}
  local name_set = {}
  for _, name in ipairs(section_names) do
    name_set[name:lower()] = true
  end

  local current_range = nil
  local current_level = nil

  for i, line in ipairs(lines) do
    local level_str, text = line:match("^(#+)%s+(.*)")
    if level_str then
      local level = #level_str
      local heading_text = vim.trim(text):lower()

      -- Close any open skip range when we hit a same-or-higher-level heading
      if current_range and level <= current_level then
        current_range.stop = i - 1
        ranges[#ranges + 1] = current_range
        current_range = nil
        current_level = nil
      end

      -- Start a new skip range if this heading matches
      if name_set[heading_text] then
        current_range = { start = i }
        current_level = level
      end
    end
  end

  -- Close any range open at EOF
  if current_range then
    current_range.stop = #lines
    ranges[#ranges + 1] = current_range
  end

  return ranges
end
```

### Step 4: Multi-day lookback with deduplication

**File: `lua/andrew/vault/templates/daily_log.lua`**

Enhance `find_carryforward_tasks()` to support multi-day lookback and prevent
duplicates (tasks carried from day 1 to day 2, then from day 2 to day 3,
should not appear twice):

```lua
--- Find carry-forward tasks from recent daily logs.
---@param vault_path string
---@param log_dir string
---@param date string YYYY-MM-DD target date
---@param opts table carry_forward config
---@return string[] tasks, string[] source_dates
local function find_carryforward_tasks(vault_path, log_dir, date, opts)
  local dir = vault_path .. "/" .. log_dir
  if vim.fn.isdirectory(dir) == 0 then
    return {}, {}
  end

  -- Collect and sort previous daily log dates
  local entries = vim.fn.readdir(dir)
  local logs = {}
  for _, name in ipairs(entries) do
    local d = name:match("^(%d%d%d%d%-%d%d%-%d%d)%.md$")
    if d and d < date then
      logs[#logs + 1] = d
    end
  end
  table.sort(logs, function(a, b) return a > b end)

  -- Scan up to `lookback` previous logs
  local max_logs = math.min(opts.lookback or 1, #logs)
  local all_tasks = {}
  local seen_tasks = {}  -- normalized text -> true (deduplication)
  local source_dates = {}

  for idx = 1, max_logs do
    local prev_date = logs[idx]
    local prev_path = dir .. "/" .. prev_date .. ".md"
    local tasks = extract_incomplete_tasks(prev_path, opts)

    local found_new = false
    for _, task in ipairs(tasks) do
      -- Normalize for dedup: strip leading whitespace, lowercase
      local key = task:gsub("^%s+", ""):lower()
      if not seen_tasks[key] then
        seen_tasks[key] = true
        all_tasks[#all_tasks + 1] = task
        found_new = true
      end
    end

    if found_new then
      source_dates[#source_dates + 1] = prev_date
    end
  end

  return all_tasks, source_dates
end
```

### Step 5: Update the generate function

**File: `lua/andrew/vault/templates/daily_log.lua`**

Update `M.generate()` to use the enhanced carry-forward:

```lua
function M.generate(e, date)
  local yesterday = e.date_offset_from(date, -1)
  local tomorrow = e.date_offset_from(date, 1)
  local weekday_long = e.format_weekday(date)

  local cf_opts = config.carry_forward or {}
  local carry_section = ""

  if cf_opts.enabled ~= false then
    local carried, source_dates = find_carryforward_tasks(
      e.vault_path, config.dirs.log, date, cf_opts
    )

    if #carried > 0 then
      carry_section = cf_opts.heading .. "\n\n"

      -- Build source attribution
      if cf_opts.source_link ~= false and #source_dates > 0 then
        local links = {}
        for _, d in ipairs(source_dates) do
          links[#links + 1] = "[[" .. d .. "]]"
        end
        carry_section = carry_section
          .. "> [!info] Incomplete tasks from "
          .. table.concat(links, ", ") .. "\n\n"
      end

      for _, task in ipairs(carried) do
        carry_section = carry_section .. task .. "\n"
      end
      carry_section = carry_section .. "\n"

      -- Notify if configured
      if cf_opts.notify then
        vim.schedule(function()
          vim.notify(
            "Vault: carried forward " .. #carried .. " task(s) from "
              .. table.concat(source_dates, ", "),
            vim.log.levels.INFO
          )
        end)
      end
    end
  end

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
    .. carry_section
    .. "### Today's Focus\n\n"
    -- ... (rest of template unchanged)

  return content
end
```

### Step 6: Add carry-forward command for existing logs

**File: `lua/andrew/vault/templates/daily_log.lua`** (new exported function)

For daily logs that already exist, provide a command to retroactively carry
forward tasks into the current buffer:

```lua
--- Insert carried-forward tasks into an existing daily log buffer.
--- Finds the "## Morning Plan" heading and inserts after it.
---@param bufnr number buffer number (0 for current)
function M.carry_forward_into_buffer(bufnr)
  bufnr = bufnr or 0
  local bufpath = vim.api.nvim_buf_get_name(bufnr)
  local date = vim.fn.fnamemodify(bufpath, ":t:r"):match("(%d%d%d%d%-%d%d%-%d%d)")
  if not date then
    vim.notify("Vault: buffer is not a daily log", vim.log.levels.WARN)
    return
  end

  local cf_opts = config.carry_forward or {}
  local carried, source_dates = find_carryforward_tasks(
    engine.vault_path, config.dirs.log, date, cf_opts
  )

  if #carried == 0 then
    vim.notify("Vault: no tasks to carry forward", vim.log.levels.INFO)
    return
  end

  -- Check if carry-forward section already exists
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local heading = cf_opts.heading or "### Carried Forward"
  for _, line in ipairs(lines) do
    if line:match("^" .. vim.pesc(heading)) then
      vim.notify("Vault: carry-forward section already exists", vim.log.levels.WARN)
      return
    end
  end

  -- Find insertion point: after "## Morning Plan" heading
  local insert_line = nil
  for i, line in ipairs(lines) do
    if line:match("^## Morning Plan") then
      insert_line = i + 1  -- After the heading (0-indexed for nvim API = i)
      -- Skip blank line after heading
      if lines[insert_line + 1] and lines[insert_line + 1] == "" then
        insert_line = insert_line + 1
      end
      break
    end
  end

  if not insert_line then
    vim.notify("Vault: could not find '## Morning Plan' heading", vim.log.levels.WARN)
    return
  end

  -- Build insertion lines
  local insert = { "", heading, "" }
  if cf_opts.source_link ~= false and #source_dates > 0 then
    local links = {}
    for _, d in ipairs(source_dates) do
      links[#links + 1] = "[[" .. d .. "]]"
    end
    insert[#insert + 1] = "> [!info] Incomplete tasks from "
      .. table.concat(links, ", ")
    insert[#insert + 1] = ""
  end
  for _, task in ipairs(carried) do
    insert[#insert + 1] = task
  end
  insert[#insert + 1] = ""

  vim.api.nvim_buf_set_lines(bufnr, insert_line, insert_line, false, insert)
  vim.notify(
    "Vault: carried forward " .. #carried .. " task(s)",
    vim.log.levels.INFO
  )
end
```

### Step 7: Register commands and keybindings

**File: `lua/andrew/vault/navigate.lua`** (in `setup()`)

```lua
vim.api.nvim_create_user_command("VaultCarryForward", function()
  local daily_log = require("andrew.vault.templates.daily_log")
  daily_log.carry_forward_into_buffer(0)
end, { desc = "Carry forward incomplete tasks into current daily log" })
```

**File: `lua/andrew/vault/navigate.lua`** (in the FileType markdown autocmd)

```lua
vim.keymap.set("n", "<leader>vdc", function()
  local daily_log = require("andrew.vault.templates.daily_log")
  daily_log.carry_forward_into_buffer(0)
end, { buffer = ev.buf, desc = "Carry forward tasks", silent = true })
```

## Key Design Decisions

### How far back to look

**Default: 1 (most recent previous log only).** Configurable via
`config.carry_forward.lookback`.

Rationale: Looking back exactly one log is the common case for daily usage. A
user who skips a weekend will still get carry-forward because the scanner finds
the most recent log by date, not by calendar adjacency. If someone takes a week
off, looking back 1 log means they only see tasks from their last working day,
which is usually correct.

Multi-day lookback (e.g., `lookback = 7`) addresses edge cases where tasks were
added to intermediate days that never got carried. However, this increases the
risk of surfacing stale tasks. The deduplication logic prevents the same task
from appearing multiple times when scanning multiple logs.

### Task formatting preservation

The original task line is preserved as-is (minus leading whitespace
normalization), including:
- Inline fields: `[due:: 2026-03-01]`, `[repeat:: every week]`
- Tags: `#project/alpha`
- Wikilinks: `[[Project Alpha]]`
- Priority markers

This ensures metadata is not lost during carry-forward and tasks remain
actionable in their new location.

### Where to insert

Carried tasks are inserted inside the "## Morning Plan" section, under a
dedicated "### Carried Forward" sub-heading. This placement:
- Makes carried tasks immediately visible during morning planning
- Keeps them separate from fresh tasks (user can distinguish what's new vs.
  outstanding)
- Is above "Today's Focus" so the user reviews outstanding work before
  committing to new priorities

### Opt-in vs. automatic

**Automatic by default**, configurable to disable. The carry-forward runs as
part of daily log generation -- it is not a separate step. This matches the
principle of least surprise: when you create a daily log, it should show you
what's outstanding.

The `enabled` config flag allows users to opt out. The `:VaultCarryForward`
command allows manual triggering for logs that already exist.

### Handling deferred tasks

Deferred tasks (`[>]`) are **not** carried forward by default. The `>` state
semantically means "intentionally postponed" -- the user made a conscious
decision to defer. Carrying them forward every day defeats the purpose of
deferral.

Users who want deferred tasks carried can set `states[">"] = true` in the
config.

### Handling partially completed tasks

A task is only carried if its checkbox matches one of the configured carry
states. There is no concept of "partially completed" at the task level in the
current system. Sub-tasks (indented children of a parent task) are handled by
the `preserve_subtasks` option:

- If `preserve_subtasks = true` and a parent task is incomplete, all its
  children (including completed sub-tasks) are carried as a group. This
  preserves context.
- If `preserve_subtasks = false`, only top-level incomplete tasks are carried
  (current behavior).

## Edge Cases

### Weekends and gaps

The scanner finds the most recent log by date string comparison (`d < date`),
not by calendar arithmetic. A Friday-to-Monday gap, a week-long vacation, or
any arbitrary gap is handled correctly: the most recent log is always found
regardless of how many days elapsed.

### Sub-tasks with mixed completion states

When `preserve_subtasks = true`:
```markdown
- [ ] Write report               <- incomplete (carried)
  - [x] Draft introduction       <- complete child (carried with parent)
  - [ ] Write methodology        <- incomplete child (carried with parent)
  - [ ] Write results            <- incomplete child (carried with parent)
```

The entire group is carried. This preserves the user's progress tracking. If
only the incomplete sub-tasks were carried, the context of what was already done
would be lost.

When `preserve_subtasks = false`:
```markdown
- [ ] Write report               <- carried (flat)
```

Sub-tasks are ignored entirely.

### Tasks with inline context

Tasks containing wikilinks, inline fields, and metadata are preserved verbatim:
```markdown
- [ ] Review [[Project Alpha]] proposal [due:: 2026-03-01] #review
```

This line is carried exactly as-is.

### Duplicate prevention

**Within a single log:** The deduplication key is the normalized task text
(stripped of leading whitespace, lowercased). If the same task text appears
multiple times in a log, only the first occurrence is carried.

**Across multiple logs (lookback > 1):** The same deduplication applies. A task
present in both Monday's and Tuesday's logs is only carried once.

**Re-carry prevention:** When `carry_forward_into_buffer()` is called on an
existing log, it checks whether a carry-forward section already exists and
refuses to insert a second one. For template-based creation, this is not an
issue since the template only generates content once.

**Carried tasks from carried sections:** A subtle edge case: if Monday's log
carries task X from Friday, and Tuesday's log scans Monday, it will find task X
in Monday's "Carried Forward" section. This is correct behavior -- the task is
still incomplete and should be carried again. The dedup key prevents it from
appearing twice if it also appeared in Monday's other sections.

### Empty daily logs

If the previous log exists but contains no incomplete tasks (everything was
completed or cancelled), the carry-forward section is simply omitted from the
new log. No empty "### Carried Forward" heading is generated.

### First daily log ever

If there are no previous daily logs in the vault, `find_carryforward_tasks()`
returns an empty list and no carry-forward section is generated. This is already
handled by the existing implementation.

### Tasks in "Tomorrow's Priorities"

The `skip_sections` config defaults to `["Completed Today", "Tomorrow's
Priorities"]`. Tasks listed under "Tomorrow's Priorities" in yesterday's log
are NOT carried forward by default. Rationale: these are aspirational entries
that become the new day's "Today's Focus" or "Other Priorities" -- they should
be freshly entered, not auto-migrated with their old checkbox state.

However, some users may want these carried. The `skip_sections` config is
user-customizable.

### Recurring tasks that are incomplete

If a task has `[repeat:: every day]` and is still `[ ]` (never completed), it
is carried forward normally. The recurrence system only triggers on completion
(`[x]`), so there is no conflict between carry-forward and recurrence.

If a recurring task was completed yesterday, `handle_recurrence()` would have
already created the next occurrence above the completed line. That next
occurrence might be `[ ]` and would be carried forward -- which is correct.

## Files Modified

### Modified files

1. **`lua/andrew/vault/calendar.lua`**
   - Replace inline daily log template in `open_or_create_log()` with call to
     `daily_log.generate()`
   - Remove ~50 lines of duplicated template string concatenation
   - Simplify function signature (date string is sufficient, no need for
     separate y/m/day)

2. **`lua/andrew/vault/templates/daily_log.lua`**
   - Enhance `extract_incomplete_tasks()` with configurable states, sub-task
     preservation, and section skipping
   - Add `compute_skip_ranges()` helper function
   - Enhance `find_carryforward_tasks()` with multi-day lookback and
     deduplication
   - Update `M.generate()` to use config-driven carry-forward
   - Add `M.carry_forward_into_buffer()` for retroactive carry-forward into
     existing logs
   - Ensure `engine` module is accessible (may need to add as parameter or
     require at module level for the buffer function)

3. **`lua/andrew/vault/config.lua`**
   - Add `M.carry_forward` configuration section with all options

4. **`lua/andrew/vault/navigate.lua`**
   - Register `:VaultCarryForward` command in `setup()`
   - Add `<leader>vdc` keybinding for manual carry-forward

### No new files required

All changes fit within existing modules. The carry-forward logic is a natural
extension of `templates/daily_log.lua`.

## Testing Plan

### Unit-level tests

1. **Task extraction basics**
   - Create a mock daily log with open, in-progress, done, cancelled, and
     deferred tasks.
   - Call `extract_incomplete_tasks()` with default config.
   - Verify only `[ ]` and `[/]` tasks are returned.
   - Verify placeholder tasks (empty text after checkbox) are skipped.

2. **Configurable task states**
   - Set `states[">"] = true` in config.
   - Verify deferred tasks are now included.
   - Set `states["/"] = false`.
   - Verify in-progress tasks are excluded.

3. **Sub-task preservation**
   - Create a log with a parent task and 3 indented sub-tasks (mixed
     completion).
   - With `preserve_subtasks = true`, verify the entire group is carried.
   - With `preserve_subtasks = false`, verify only the parent line is carried.

4. **Section skipping**
   - Create a log with tasks under "Completed Today" and "Tomorrow's
     Priorities" headings.
   - Verify these tasks are NOT carried forward with default config.
   - Set `skip_sections = {}` and verify they ARE carried.

5. **Deduplication**
   - Create two logs with overlapping tasks.
   - Set `lookback = 2`.
   - Verify each unique task appears exactly once.

6. **Gap handling**
   - Create logs for Monday and Thursday (no Tue/Wed).
   - Generate a Friday log.
   - Verify carry-forward pulls from Thursday's log, not Monday's.

7. **Inline field preservation**
   - Create tasks with `[due:: ...]`, `[repeat:: ...]`, `#tags`, `[[links]]`.
   - Verify all metadata is preserved in carried-forward output.

### Integration tests (in Neovim)

8. **Template path carry-forward**
   - Create a daily log via `:VaultDaily` with known incomplete tasks in
     the previous log.
   - Open the created file and verify the "Carried Forward" section exists
     with the correct tasks.

9. **Navigate path carry-forward**
   - Use `:VaultDailyToday` to navigate to today (non-existent).
   - Accept creation prompt.
   - Verify carry-forward section is present.

10. **Calendar path carry-forward**
    - Open `:VaultCalendar`, navigate to a date with no log but with a
      previous log containing incomplete tasks.
    - Press `<CR>` to create.
    - Verify carry-forward section is present (this validates the unification
      fix).

11. **Retroactive carry-forward**
    - Open an existing daily log that has no carry-forward section.
    - Run `:VaultCarryForward`.
    - Verify tasks are inserted under "## Morning Plan".
    - Run `:VaultCarryForward` again.
    - Verify it refuses to insert a duplicate section.

12. **Notification**
    - Create a daily log with carry-forward.
    - Verify a notification appears: "Vault: carried forward N task(s) from
      YYYY-MM-DD".
    - Set `config.carry_forward.notify = false`.
    - Verify no notification.

13. **Empty carry-forward**
    - Create a previous log where all tasks are completed.
    - Create today's log.
    - Verify no "Carried Forward" section appears.

### Regression tests

14. **Calendar log equivalence**
    - Create a daily log via the calendar and via the template picker for the
      same date (in separate test runs).
    - Diff the generated content.
    - Verify they are identical (this confirms the unification fix).

15. **Existing daily log navigation**
    - Open an existing daily log via the calendar (`<CR>` on a date with a log).
    - Verify it opens the file without modification (no accidental re-creation).

16. **Recurrence interaction**
    - Create a previous log with a completed recurring task and its spawned
      next occurrence.
    - Create today's log.
    - Verify the spawned (incomplete) next occurrence is carried, but the
      completed instance is not.
