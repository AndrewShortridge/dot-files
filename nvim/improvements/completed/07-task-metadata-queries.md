# Task Metadata Queries

## Problem Statement

The vault's advanced search system supports basic task filtering via `task:""`,
`task-todo:""`, and `task-done:""` operators, but these only test for the
*existence* of tasks or match plain text within the task body. Users cannot
filter tasks by their structured inline metadata -- due dates, priority levels,
recurrence rules, completion dates, or task-specific tags. This is a significant
gap because the vault's task format already encodes rich metadata:

```markdown
- [ ] Review paper draft [due:: 2026-03-01] [priority:: 1] #urgent #project/alpha
- [x] Submit proposal [due:: 2026-02-20] [priority:: 2] [completion:: 2026-02-19]
- [ ] Weekly standup notes [due:: 2026-03-03] [repeat:: every week]
```

The vault index already extracts tasks from every file during indexing
(`vault_index.lua`, line 448: `extract_tasks()`), but the extracted `VaultTask`
objects store only `text`, `status`, `completed`, `line`, and `tags` -- the raw
task text is preserved but the inline fields embedded within it (`[due:: ...]`,
`[priority:: ...]`, `[repeat:: ...]`, `[completion:: ...]`) are never parsed
into structured fields. Meanwhile, `extract_inline_fields()` (line 490)
explicitly *skips* task lines (`if line:match("^%s*[-*] %[.%] ") then goto
continue end`), so task-level metadata lives in a blind spot.

### What Users Cannot Do Today

1. **Find overdue tasks:** `task-due:<today` (tasks with due dates in the past)
2. **Find tasks due this week:** `task-due:this-week`
3. **Find high-priority tasks:** `task-priority:1` or `task-priority:<=2`
4. **Find tasks by tag:** `task-tag:urgent` (distinct from note-level `tag:`)
5. **Find recurring tasks:** `has:task-repeat` or `task-repeat:every week`
6. **Combine task metadata with note metadata:**
   `type:project task-due:<7d task-priority:<=2`

### Current Workaround

The only way to find overdue tasks today is the saved search "Overdue tasks"
(`saved_searches.lua`, line 13), which uses a raw ripgrep pattern:
`\\[due:: .*\\].*\\[ \\]`. This is fragile -- it cannot compare dates, cannot
filter by priority, and breaks if the inline field format varies slightly.

The calendar module (`calendar.lua`, line 74: `scan_deadlines()`) independently
scans the vault with ripgrep for `[due:: YYYY-MM-DD]` patterns, but this is a
separate code path that does not integrate with the search system.

## Current Architecture

### VaultTask Schema (`vault_index.lua`, line 470)

The current task extraction produces objects with this shape:

```lua
---@class VaultTask
---@field text string      -- Everything after "- [x] " (raw text including inline fields)
---@field status string    -- Checkbox char: " ", "/", "x", "-", ">"
---@field completed boolean -- true when status is "x" or "X"
---@field line number       -- 1-indexed line number in the file
---@field tags string[]     -- Inline tags extracted from task text (#word patterns)
```

The `text` field contains the full task body including any `[due:: ...]`,
`[priority:: ...]`, etc. substrings, but these are never parsed further.

### extract_tasks() (`vault_index.lua`, lines 448-484)

```lua
local function extract_tasks(body)
  local tasks = {}
  local lines = vim.split(body, "\n", { plain = true })
  local in_code_fence = false

  for line_num, line in ipairs(lines) do
    if line:match("^%s*```") then
      in_code_fence = not in_code_fence
    end
    if in_code_fence then goto continue end

    local status_char = line:match("^%s*[-*] %[(.)%] ")
    if status_char then
      local text = line:match("^%s*[-*] %[.%] (.*)")
      if text then
        local completed = (status_char == "x" or status_char == "X")
        local task_tags = {}
        for tag in text:gmatch("#([%w_%-][%w_%-/]*)") do
          if not tag:match("^%d+$") then
            task_tags[#task_tags + 1] = tag
          end
        end
        tasks[#tasks + 1] = {
          text = text,
          status = status_char,
          completed = completed,
          line = line_num,
          tags = task_tags,
        }
      end
    end

    ::continue::
  end

  return tasks
end
```

Key observations:
- Tags are already extracted from task text (line 465-469).
- Inline fields within task text (`[key:: value]`) are completely ignored.
- The `extract_inline_fields()` function (line 487) explicitly skips task lines,
  so `[due:: ...]` on a task line does not appear in `entry.inline_fields`.

### match_task() (`search_filter.lua`, lines 441-483)

The current task matcher supports three variants:

| Syntax | Variant | Behavior |
|--------|---------|----------|
| `task:""` | `any` | File has any task |
| `task:pattern` | `any` | Any task text contains pattern (substring) |
| `task-todo:""` | `todo` | File has task with status `" "` |
| `task-todo:pattern` | `todo` | Open task text contains pattern |
| `task-done:""` | `done` | File has task with `completed == true` |
| `task-done:pattern` | `done` | Completed task text contains pattern |

There is no support for querying task metadata fields (due, priority, repeat,
completion) or task-specific tags with semantic awareness.

### Task States (`config.lua`, lines 32-38)

```lua
M.task_states = {
  { mark = " ", label = "open" },
  { mark = "/", label = "in-progress" },
  { mark = "x", label = "done" },
  { mark = "-", label = "cancelled" },
  { mark = ">", label = "deferred" },
}
```

### Tokenizer (`search_query.lua`, lines 101-109)

The tokenizer recognizes `task:`, `task-todo:`, and `task-done:` as special
prefixes and produces `TK.TASK` tokens with `{ variant, pattern }`. New
task-metadata prefixes will need to be added here.

### Inline Field Patterns in Use

From `recurrence.lua`, `calendar.lua`, `templates/task.lua`, and
`templates/project_dashboard.lua`, the standard task inline field format is:

```
[key:: value]
```

Common fields observed across the codebase:
- `[due:: YYYY-MM-DD]` -- due date
- `[priority:: N]` -- priority level (numeric, 1-5)
- `[repeat:: rule]` -- recurrence rule string
- `[completion:: YYYY-MM-DD]` -- date the task was completed
- `[scheduled:: YYYY-MM-DD]` -- scheduled start date (not yet widely used)

## Proposed Solution

### Overview

Extend the task extraction pipeline to parse inline metadata fields from task
text, add new search filter operators for querying those fields, and update the
tokenizer, filter, completion, and help systems to expose the new capabilities.

The changes span four modules:

1. **`vault_index.lua`** -- Parse inline fields from task text during indexing
2. **`search_query.lua`** -- Recognize new `task-*:` prefixes in the tokenizer
3. **`search_filter.lua`** -- Evaluate task metadata queries against index entries
4. **`search.lua`** -- Update completion and help text
5. **`config.lua`** -- Add task metadata configuration

### New Query Syntax

```
# Task due date filtering
task-due:today               Tasks due today
task-due:<today              Overdue tasks (due before today)
task-due:this-week           Tasks due this week
task-due:<7d                 Tasks due within the next 7 days
task-due:>30d                Tasks due more than 30 days from now
task-due:2026-03-01          Tasks due on a specific date
task-due:2026-03..2026-04    Tasks due in March 2026

# Task priority filtering
task-priority:1              Tasks with priority 1
task-priority:<=2            Tasks with priority 1 or 2 (high)
task-priority:1..3           Tasks with priority in range 1-3

# Task tag filtering (distinct from note-level tag:)
task-tag:urgent              Tasks with #urgent tag
task-tag:project/alpha       Tasks tagged #project/alpha (or child)

# Task state filtering (extends existing)
task-state:open              Same as task-todo:""
task-state:in-progress       Tasks with "/" checkbox
task-state:deferred          Tasks with ">" checkbox
task-state:cancelled         Tasks with "-" checkbox

# Task recurrence and completion
task-repeat:""               Tasks that have a recurrence rule
task-completion:<7d          Tasks completed within the last 7 days

# Combined queries
task-todo:"" task-due:<today task-priority:<=2
  Open tasks that are overdue AND high priority

type:project task-due:this-week -task-done:""
  Project notes with tasks due this week that are not yet done
```

### Semantic Note on Due Date Direction

Due dates differ semantically from `created`/`modified` timestamps. For
`modified:<7d`, the "relative duration inversion" makes `<7d` mean "less than 7
days ago" (recent). For due dates, the direction is *forward-looking*:
`task-due:<7d` should mean "due within the next 7 days" (upcoming), and
`task-due:>7d` should mean "due more than 7 days from now."

This requires a different resolution strategy for the `Nd` pattern on due dates:
resolve as "N days from now" (future) rather than "N days ago" (past), and do
NOT apply the operator inversion used for `created`/`modified`. The user's
mental model for due dates is: `<7d` = "sooner than 7 days" = "due soon."

## Implementation Plan

### Step 1: Extend VaultTask Schema

**File: `lua/andrew/vault/vault_index.lua`**

Add parsed inline fields to the VaultTask structure:

```lua
---@class VaultTask
---@field text string
---@field status string
---@field completed boolean
---@field line number
---@field tags string[]
---@field due string|nil        -- "YYYY-MM-DD" or nil
---@field priority number|nil   -- numeric priority or nil
---@field repeat_rule string|nil -- raw recurrence rule string or nil
---@field completion string|nil -- "YYYY-MM-DD" completion date or nil
---@field scheduled string|nil  -- "YYYY-MM-DD" scheduled date or nil
---@field fields table|nil      -- all other [key:: value] pairs (catch-all)
```

### Step 2: Parse Task Inline Fields During Indexing

**File: `lua/andrew/vault/vault_index.lua`**

Add a new helper function `parse_task_fields()` and call it from
`extract_tasks()`.

```lua
--- Parse inline fields from task text.
--- Extracts [key:: value] patterns and returns structured metadata.
---@param text string task text (everything after "- [x] ")
---@return table fields { due?, priority?, repeat_rule?, completion?, scheduled?, fields? }
local function parse_task_fields(text)
  local result = {}
  local extra = {}

  for key, value in text:gmatch("%[([%w_%-]+)::%s*(.-)%]") do
    local k = key:lower()
    value = vim.trim(value)

    if k == "due" then
      -- Validate as YYYY-MM-DD
      if value:match("^%d%d%d%d%-%d%d%-%d%d$") then
        result.due = value
      end
    elseif k == "priority" then
      local n = tonumber(value)
      if n then
        result.priority = n
      end
    elseif k == "repeat" then
      if value ~= "" then
        result.repeat_rule = value
      end
    elseif k == "completion" then
      if value:match("^%d%d%d%d%-%d%d%-%d%d$") then
        result.completion = value
      end
    elseif k == "scheduled" then
      if value:match("^%d%d%d%d%-%d%d%-%d%d$") then
        result.scheduled = value
      end
    else
      if value ~= "" then
        extra[k] = value
      end
    end
  end

  -- Also check (key:: value) parenthesized form
  for key, value in text:gmatch("%(([%w_%-]+)::%s*(.-)%)") do
    local k = key:lower()
    value = vim.trim(value)
    if k == "due" and value:match("^%d%d%d%d%-%d%d%-%d%d$") then
      result.due = result.due or value
    elseif k == "priority" then
      result.priority = result.priority or tonumber(value)
    elseif k == "repeat" and value ~= "" then
      result.repeat_rule = result.repeat_rule or value
    elseif k == "completion" and value:match("^%d%d%d%d%-%d%d%-%d%d$") then
      result.completion = result.completion or value
    elseif k == "scheduled" and value:match("^%d%d%d%d%-%d%d%-%d%d$") then
      result.scheduled = result.scheduled or value
    elseif value ~= "" then
      extra[k] = extra[k] or value
    end
  end

  if next(extra) then
    result.fields = extra
  end

  return result
end
```

**Modify `extract_tasks()`** (line 470) to call `parse_task_fields()` and merge
the results into each task object:

```lua
        -- EXISTING: lines 470-476
        local task_meta = parse_task_fields(text)
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
        }
```

**Impact on index size:** Each task gains 5-6 additional fields, most of which
will be nil for tasks without inline metadata. Lua tables with nil-valued keys
use no memory for those keys. JSON serialization will include only non-nil
values. For a vault with 500 tasks, this adds approximately 2-5 KB to the
persisted index.

**Schema version:** Bump `SCHEMA_VERSION` from `2` to `3` (line 9) to trigger a
full rebuild when the new code first loads. This ensures existing persisted
indexes are rebuilt with the new task metadata fields.

### Step 3: Add New Token Types to the Tokenizer

**File: `lua/andrew/vault/search_query.lua`**

Extend the `parse_field_token()` function (line 81) to recognize the new
`task-*:` prefixes. The current code (line 102) handles `task`, `task-todo`,
and `task-done`:

```lua
  -- CURRENT (line 102):
  if name == "task" or name == "task-todo" or name == "task-done" then
```

**Replace with expanded task prefix handling:**

```lua
  -- Task filters: task:*, task-todo:*, task-done:*, task-due:*, etc.
  if name == "task" or name:sub(1, 5) == "task-" then
    -- Legacy variants: task, task-todo, task-done
    if name == "task" then
      return token(TK.TASK, { variant = "any", pattern = raw_value }, pos)
    elseif name == "task-todo" then
      return token(TK.TASK, { variant = "todo", pattern = raw_value }, pos)
    elseif name == "task-done" then
      return token(TK.TASK, { variant = "done", pattern = raw_value }, pos)
    end

    -- Task metadata variants: task-due, task-priority, task-tag, etc.
    local meta_field = name:sub(6) -- strip "task-" prefix
    if meta_field == "due" or meta_field == "priority" or meta_field == "tag"
      or meta_field == "state" or meta_field == "repeat"
      or meta_field == "completion" or meta_field == "scheduled" then
      local op, value, value2 = parse_field_value(raw_value)
      return token(TK.TASK, {
        variant = "meta",
        meta_field = meta_field,
        op = op,
        value = value,
        value2 = value2,
      }, pos)
    end

    -- Unknown task- prefix: treat as text
    return nil
  end
```

The `TK.TASK` token now carries either the existing `{ variant, pattern }` shape
or a new `{ variant = "meta", meta_field, op, value, value2 }` shape. The
parser (`parse_primary`, line 366) already passes through the token value
unchanged:

```lua
  if tok.type == TK.TASK then
    P:advance()
    return { type = "task", variant = tok.value.variant, pattern = tok.value.pattern }
  end
```

**Update the parser** to also propagate the new fields:

```lua
  if tok.type == TK.TASK then
    P:advance()
    local v = tok.value
    if v.variant == "meta" then
      return {
        type = "task",
        variant = "meta",
        meta_field = v.meta_field,
        op = v.op,
        value = v.value,
        value2 = v.value2,
      }
    end
    return { type = "task", variant = v.variant, pattern = v.pattern }
  end
```

### Step 4: Extend match_task() in the Filter Pipeline

**File: `lua/andrew/vault/search_filter.lua`**

The current `match_task()` function (lines 441-483) handles three variants:
`any`, `todo`, and `done`. Add handling for the new `meta` variant and `state`.

```lua
local function match_task(node, entry)
  if not entry.tasks or #entry.tasks == 0 then return false end

  local variant = node.variant
  local pattern = node.pattern
  local has_pattern = pattern and pattern ~= ""

  -- Existing variants: any, todo, done (unchanged)
  if variant == "any" then
    if not has_pattern then return true end
    for _, task in ipairs(entry.tasks) do
      if task.text and task.text:lower():find(pattern:lower(), 1, true) then
        return true
      end
    end
    return false
  end

  if variant == "todo" then
    for _, task in ipairs(entry.tasks) do
      if task.status == " " then
        if not has_pattern then return true end
        if task.text and task.text:lower():find(pattern:lower(), 1, true) then
          return true
        end
      end
    end
    return false
  end

  if variant == "done" then
    for _, task in ipairs(entry.tasks) do
      if task.completed then
        if not has_pattern then return true end
        if task.text and task.text:lower():find(pattern:lower(), 1, true) then
          return true
        end
      end
    end
    return false
  end

  -- NEW: state variant (task-state:label)
  if variant == "state" then
    local target_mark = resolve_state_mark(node.value)
    if not target_mark then return false end
    for _, task in ipairs(entry.tasks) do
      if task.status == target_mark then return true end
    end
    return false
  end

  -- NEW: meta variant (task-due:, task-priority:, task-tag:, etc.)
  if variant == "meta" then
    return match_task_meta(node, entry.tasks)
  end

  return false
end
```

**Add the `resolve_state_mark()` helper:**

```lua
--- Map a state label to its checkbox character.
--- Accepts both the label name and the raw character.
---@param label string e.g. "open", "in-progress", "done", "cancelled", "deferred"
---@return string|nil mark single character for checkbox
local function resolve_state_mark(label)
  if not label or label == "" then return nil end
  -- Direct character (single char)
  if #label == 1 then return label end
  -- Label lookup from config
  local lower = label:lower()
  for _, state in ipairs(config.task_states) do
    if state.label == lower then return state.mark end
  end
  return nil
end
```

**Add the `match_task_meta()` function:**

```lua
--- Evaluate a task-metadata query against a file's task list.
--- Returns true if ANY task in the file matches the condition.
---@param node table task AST node with variant="meta"
---@param tasks VaultTask[] the file's task list
---@return boolean
local function match_task_meta(node, tasks)
  local meta_field = node.meta_field
  local op = node.op
  local value = node.value
  local value2 = node.value2

  -- Empty value with = operator means "field exists on any task"
  if op == "=" and (value == nil or value == "") then
    return match_task_meta_exists(meta_field, tasks)
  end

  if meta_field == "due" then
    return match_task_date(tasks, "due", op, value, value2)
  end

  if meta_field == "scheduled" then
    return match_task_date(tasks, "scheduled", op, value, value2)
  end

  if meta_field == "completion" then
    return match_task_date(tasks, "completion", op, value, value2)
  end

  if meta_field == "priority" then
    return match_task_priority(tasks, op, value, value2)
  end

  if meta_field == "tag" then
    return match_task_tag(tasks, value)
  end

  if meta_field == "repeat" then
    return match_task_repeat(tasks, op, value)
  end

  if meta_field == "state" then
    local target_mark = resolve_state_mark(value)
    if not target_mark then return false end
    for _, task in ipairs(tasks) do
      if task.status == target_mark then return true end
    end
    return false
  end

  return false
end
```

**Add the task metadata match helpers:**

```lua
--- Check if any task has a non-nil value for the given metadata field.
---@param field_name string "due", "priority", "repeat_rule", "completion", "scheduled"
---@param tasks VaultTask[]
---@return boolean
local function match_task_meta_exists(field_name, tasks)
  -- Map meta_field names to VaultTask field names
  local key = field_name
  if field_name == "repeat" then key = "repeat_rule" end

  for _, task in ipairs(tasks) do
    if task[key] ~= nil then return true end
  end
  return false
end

--- Match a task date field (due, scheduled, completion) against a query.
--- Due dates use FORWARD-looking resolution for Nd patterns:
---   task-due:<7d = "due within the next 7 days"
---   task-due:>7d = "due more than 7 days from now"
--- Completion dates use BACKWARD-looking resolution (same as modified:):
---   task-completion:<7d = "completed less than 7 days ago"
---@param tasks VaultTask[]
---@param field_name string "due"|"scheduled"|"completion"
---@param op string
---@param value string
---@param value2 string|nil
---@return boolean
local function match_task_date(tasks, field_name, op, value, value2)
  local forward_looking = (field_name == "due" or field_name == "scheduled")

  for _, task in ipairs(tasks) do
    local date_str = task[field_name]
    if date_str then
      local task_ts = date_utils.parse_iso_datetime(date_str)
      if task_ts then
        if op == "=" then
          -- Range keywords (this-week, last-7d, etc.)
          local range_start, range_end = date_utils.resolve_date_range(value)
          if range_start then
            if task_ts >= range_start and task_ts < range_end then return true end
            goto next_task
          end
          -- Single-day match
          local filter_ts = resolve_task_date(value, forward_looking)
          if filter_ts and same_day(task_ts, filter_ts) then return true end
          goto next_task
        end

        if op == ".." then
          local lo = resolve_task_date(value, forward_looking)
          local hi = resolve_task_date(value2, forward_looking)
          if lo and hi then
            if task_ts >= lo and task_ts < hi + 86400 then return true end
          end
          goto next_task
        end

        -- Comparison operators
        local filter_ts = resolve_task_date(value, forward_looking)
        if filter_ts then
          local effective_op = op
          -- For forward-looking dates (due, scheduled), do NOT invert Nd operators.
          -- task-due:<7d = "due sooner than 7 days from now" = task_ts < threshold
          -- For backward-looking dates (completion), invert (same as modified:).
          if not forward_looking and date_utils.is_relative_duration(value) then
            effective_op = invert_op(op)
          end
          if compare_num(task_ts, effective_op, filter_ts) then return true end
        end
      end
    end
    ::next_task::
  end
  return false
end
```

**Add `resolve_task_date()`** -- a date resolver that supports both directions:

```lua
--- Resolve a date value for task queries.
--- For forward-looking fields (due, scheduled), Nd patterns resolve to
--- N days FROM NOW (future). For backward-looking fields, delegates to
--- date_utils.resolve_date() which resolves Nd to N days AGO.
---@param value string date value string
---@param forward_looking boolean if true, Nd resolves to future
---@return number|nil timestamp
local function resolve_task_date(value, forward_looking)
  if not value or value == "" then return nil end

  -- For forward-looking resolution, intercept the Nd pattern
  if forward_looking then
    local n = value:lower():match("^(%d+)d$")
    if n then
      local t = os.date("*t")
      t.day = t.day + tonumber(n)  -- FUTURE, not past
      return date_utils.start_of_day(t)
    end
  end

  -- All other patterns (today, yesterday, this-week, YYYY-MM-DD, backward Nd)
  -- delegate to the standard resolver
  return date_utils.resolve_date(value)
end
```

**Add `match_task_priority()`:**

```lua
--- Match task priority field.
---@param tasks VaultTask[]
---@param op string
---@param value string
---@param value2 string|nil
---@return boolean
local function match_task_priority(tasks, op, value, value2)
  local num_filter = tonumber(value)
  if not num_filter then return false end

  for _, task in ipairs(tasks) do
    if task.priority then
      if op == ".." then
        local num_filter2 = tonumber(value2)
        if num_filter2 and num_filter <= task.priority
          and task.priority <= num_filter2 then
          return true
        end
      elseif compare_num(task.priority, op, num_filter) then
        return true
      end
    end
  end
  return false
end
```

**Add `match_task_tag()`:**

```lua
--- Match task-level tags (distinct from note-level tags).
--- Uses the same prefix-match logic as note-level tag matching.
---@param tasks VaultTask[]
---@param target string tag to match (without #)
---@return boolean
local function match_task_tag(tasks, target)
  if not target or target == "" then return false end
  local lower_target = target:lower()
  local prefix = lower_target .. "/"

  for _, task in ipairs(tasks) do
    if task.tags then
      for _, tag in ipairs(task.tags) do
        local lower_tag = tag:lower()
        if lower_tag == lower_target or lower_tag:sub(1, #prefix) == prefix then
          return true
        end
      end
    end
  end
  return false
end
```

**Add `match_task_repeat()`:**

```lua
--- Match task recurrence rules.
--- With = operator and empty value: checks existence.
--- With = operator and value: substring match on the rule string.
---@param tasks VaultTask[]
---@param op string
---@param value string
---@return boolean
local function match_task_repeat(tasks, op, value)
  if op ~= "=" then return false end
  for _, task in ipairs(tasks) do
    if task.repeat_rule then
      if value == "" or value == nil then return true end
      if task.repeat_rule:lower():find(value:lower(), 1, true) then
        return true
      end
    end
  end
  return false
end
```

### Step 5: Update Completion and Help

**File: `lua/andrew/vault/search.lua`**

Update `_complete_advanced()` (line 462) to suggest the new task prefixes:

```lua
  -- In the "Special prefixes" section (line 480), add:
  for _, prefix in ipairs({
    "has:", "task:", "task-todo:", "task-done:",
    "task-due:", "task-priority:", "task-tag:",
    "task-state:", "task-repeat:", "task-completion:",
    "task-scheduled:",
  }) do
    if prefix:sub(1, #lead) == lead then
      candidates[#candidates + 1] = prefix
    end
  end
```

Add value completion for the new task prefixes:

```lua
  -- After task-state: suggest state labels
  if lead:match("^task%-state:") then
    local prefix = "task-state:"
    local rest = lead:sub(#prefix + 1)
    for _, state in ipairs(config.task_states) do
      if state.label:sub(1, #rest) == rest then
        candidates[#candidates + 1] = prefix .. state.label
      end
    end
  end

  -- After task-priority: suggest priority values
  if lead:match("^task%-priority:") then
    local prefix = "task-priority:"
    local rest = lead:sub(#prefix + 1)
    for _, p in ipairs(config.priority_values) do
      local ps = tostring(p)
      if ps:sub(1, #rest) == rest then
        candidates[#candidates + 1] = prefix .. ps
      end
    end
  end

  -- After task-due: and similar date fields: suggest date shortcuts
  local date_task_prefixes = { "task-due:", "task-completion:", "task-scheduled:" }
  for _, dp in ipairs(date_task_prefixes) do
    if lead:match("^" .. dp:gsub("%-", "%%-")) then
      local rest = lead:sub(#dp + 1)
      for _, shortcut in ipairs({
        "today", "yesterday", "this-week", "last-week",
        "this-month", "last-month", "<7d", "<30d",
      }) do
        if shortcut:sub(1, #rest) == rest then
          candidates[#candidates + 1] = dp .. shortcut
        end
      end
    end
  end
```

Update `search_help()` (line 371) to document the new task filters:

```lua
    -- Replace the existing "Task Filters:" section with:
    "Task Filters:",
    "  task:\"\"                  Any task",
    "  task-todo:\"\"             Open tasks",
    "  task-done:\"\"             Completed tasks",
    "  task-due:<today          Overdue tasks",
    "  task-due:this-week       Tasks due this week",
    "  task-due:<7d             Due within 7 days",
    "  task-priority:1          Priority 1 tasks",
    "  task-priority:<=2        High priority (1-2)",
    "  task-priority:1..3       Priority range",
    "  task-tag:urgent          Tasks tagged #urgent",
    "  task-state:in-progress   In-progress tasks",
    "  task-repeat:\"\"           Recurring tasks",
    "  task-completion:<7d      Recently completed",
    "  has:tasks                Files with tasks",
```

Also update the `SEARCH_HEADER` compact hint (line 84):

```lua
local SEARCH_HEADER = table.concat({
  "field:value  tag:x  task-due:<7d  task-priority:1  has:tags  created:>7d",
  "AND  OR  NOT  -excluded  (a OR b) AND c   |  Ctrl-/ full help",
}, "\n")
```

### Step 6: Update Configuration

**File: `lua/andrew/vault/config.lua`**

Add task metadata field names to `config.search.builtin_fields` for completion
awareness. No new config section is needed -- the existing `task_states` and
`priority_values` tables already serve as the canonical value sources.

```lua
  -- In M.search.builtin_fields (line 330), no changes needed.
  -- The task-* prefixes are handled by the "Special prefixes" completion path,
  -- not the builtin_fields path (they are not field:value, they are task-*:value).
```

Add `has:` target entries for the new task metadata:

```lua
  -- In M.search.has_targets (line 341), add task-specific targets:
  has_targets = {
    "tags", "aliases", "tasks", "outlinks", "inlinks", "frontmatter",
    -- Task-specific (Note: has:task-due checks if any task has a due date)
  },
```

Actually, for `has:task-due`, this is better served by the `task-due:""` syntax
(empty value = "exists"). No change to `has_targets` is needed.

### Step 7: Update Saved Searches

**File: `lua/andrew/vault/saved_searches.lua`**

Update the built-in default searches to use the new syntax:

```lua
local defaults = {
  {
    name = "Overdue tasks",
    query = "task-todo:\"\" task-due:<today",
    scope = "all",
    type = "advanced",     -- was "grep"
    advanced = true,
  },
  {
    name = "Due this week",
    query = "task-todo:\"\" task-due:this-week",
    scope = "all",
    type = "advanced",
    advanced = true,
  },
  {
    name = "High priority open",
    query = "task-todo:\"\" task-priority:<=2",
    scope = "all",
    type = "advanced",
    advanced = true,
  },
  -- ... keep existing defaults too
}
```

Note: Changing defaults only affects new vaults. Existing `.vault-searches.json`
files are not modified. Users can create new saved searches with the new syntax.

## Edge Cases and Considerations

### 1. Tasks Without Inline Fields

Most tasks in a vault will not have `[due:: ...]` or `[priority:: ...]` metadata.
For these tasks, the new VaultTask fields (`due`, `priority`, etc.) are simply
`nil`. The matchers handle this correctly: `match_task_date()` skips tasks where
`task[field_name]` is nil, so `task-due:<today` only considers tasks that
actually have a due date.

### 2. Multiple Tasks Per File

The `match_task_meta()` function returns `true` if *any* task in the file
matches the condition. This is consistent with the existing `task-todo:""` and
`task-done:""` behavior. For users who want to find files where *all* tasks
match, a future `task-all-due:<today` variant could be added, but this is out of
scope for v1.

### 3. Date Resolution Direction

The most subtle design decision is the `Nd` resolution direction for due dates:

| Query | Forward-looking (due, scheduled) | Backward-looking (completion, modified) |
|-------|----------------------------------|----------------------------------------|
| `<7d` | Due within the next 7 days | Modified within the last 7 days |
| `>7d` | Due more than 7 days from now | Modified more than 7 days ago |
| `<today` | Due before today (overdue) | Modified before today |
| `=today` | Due today | Modified today |

This avoids the confusion of `task-due:<7d` meaning "due less than 7 days AGO"
which would be counter-intuitive for a forward-looking field. The `today`,
`this-week`, and absolute date values work identically in both directions.

### 4. Priority Value Semantics

The vault uses numeric priorities 1-5 where 1 is highest (most urgent) and 5 is
lowest (from `config.priority_values`). The query `task-priority:<=2` means
"priority 1 or 2" which are the two highest levels. This is consistent with
the existing `priority:` note-level field handling in `match_field()` (line 269).

### 5. Tag Case Sensitivity

Task tags are stored as raw strings in the `tags` array (line 464 of
`vault_index.lua`). The extraction pattern `#([%w_%-][%w_%-/]*)` preserves
original case. The `match_task_tag()` function performs case-insensitive
comparison, matching the behavior of note-level `tag:` filtering via
`vault_index.tag_matches()`.

### 6. Index Schema Migration

Bumping `SCHEMA_VERSION` from 2 to 3 means the first load after upgrade will
trigger a full rebuild of the persisted index. The `load()` method in
`vault_index.lua` checks the schema version and discards stale data. This is the
established pattern -- the version bump from 1 to 2 worked the same way. The
rebuild happens asynchronously via `build_async()` and does not block startup.

### 7. Backward Compatibility

The new `task-*:` prefixes are purely additive. Existing queries (`task:""`,
`task-todo:""`, `task-done:""`) continue to work identically. The tokenizer
change uses an `if/elseif` cascade that checks legacy variants first, so there
is no risk of breaking existing queries.

### 8. Interaction with extract_inline_fields()

The `extract_inline_fields()` function (line 490) will continue to skip task
lines. This is correct -- task-level inline fields belong to the task, not to
the note. The `entry.inline_fields` table contains note-level fields; task
metadata is stored per-task in `entry.tasks[i].due`, etc. This clean separation
avoids collisions (e.g., a note might have both a note-level `[priority:: 3]`
and a task-level `[priority:: 1]`).

### 9. Performance

The `match_task_meta()` function iterates over all tasks in a file for each task
metadata filter. For a file with N tasks and M task-meta filters combined with
AND, the worst case is O(N * M) per file. In practice, N is small (most files
have < 20 tasks) and M is 1-3, so this is negligible compared to the O(files)
outer loop.

Parsing inline fields from task text during indexing adds a small per-task cost
(2-3 `gmatch` calls per task). For a vault with 1000 tasks, this adds < 5ms to
the total index build time.

### 10. Parenthesized vs Bracketed Inline Fields

The codebase uses two inline field syntaxes: `[key:: value]` (Dataview standard)
and `(key:: value)` (Dataview alternate). The `parse_task_fields()` function
checks both patterns, matching the behavior of `extract_inline_fields()` (lines
496-501). The bracketed form is more common in the template files.

### 11. The `task-state:` vs Existing Task Variants

`task-state:open` overlaps semantically with `task-todo:""`. Both check for
`status == " "`. The difference is syntactic consistency: `task-state:` uses
the config-defined label names and accepts all 5 states, while `task-todo:""` is
the legacy compact form. Both will continue to work. Users who prefer the
shorter form can keep using `task-todo:""`.

## Files Modified

### Modified Files

1. **`lua/andrew/vault/vault_index.lua`**
   - Add `parse_task_fields()` helper function (new, ~50 lines)
   - Modify `extract_tasks()` to call `parse_task_fields()` and populate new fields
   - Bump `SCHEMA_VERSION` from 2 to 3

2. **`lua/andrew/vault/search_query.lua`**
   - Extend `parse_field_token()` to recognize `task-due:`, `task-priority:`,
     `task-tag:`, `task-state:`, `task-repeat:`, `task-completion:`,
     `task-scheduled:` prefixes
   - Extend `parse_primary()` to propagate `meta_field`, `op`, `value`, `value2`
     for the new `variant = "meta"` task nodes

3. **`lua/andrew/vault/search_filter.lua`**
   - Add `resolve_state_mark()` helper
   - Add `resolve_task_date()` helper (forward/backward-looking Nd resolution)
   - Add `match_task_meta()` dispatcher
   - Add `match_task_meta_exists()` for empty-value existence checks
   - Add `match_task_date()` for due/scheduled/completion date queries
   - Add `match_task_priority()` for numeric priority comparison
   - Add `match_task_tag()` for task-level tag matching
   - Add `match_task_repeat()` for recurrence rule matching
   - Extend `match_task()` to handle `variant = "meta"` and `variant = "state"`

4. **`lua/andrew/vault/search.lua`**
   - Update `_complete_advanced()` with new task prefixes and value completions
   - Update `search_help()` with new task filter documentation
   - Update `SEARCH_HEADER` compact hint

5. **`lua/andrew/vault/saved_searches.lua`**
   - Update built-in `defaults` with advanced task queries (optional, only
     affects new vaults)

### Unchanged Files (benefit indirectly)

- **`config.lua`** -- No changes. Existing `task_states` and `priority_values`
  already provide the canonical value lists.
- **`recurrence.lua`** -- No changes. The `parse_rule()` function could be
  reused if `task-repeat:` ever needs semantic rule matching, but for v1 the
  substring match on the raw rule string is sufficient.
- **`date_utils.lua`** -- No changes. All date resolution functions are reused
  as-is. The forward-looking `Nd` resolution is handled locally in
  `search_filter.lua` via `resolve_task_date()` to avoid polluting the shared
  utility with query-specific semantics.
- **`calendar.lua`** -- No changes. The `scan_deadlines()` function uses ripgrep
  independently. A future improvement could switch it to use the vault index's
  task metadata instead, but that is out of scope.
- **`tasks.lua`** -- No changes. The fzf-lua task browser uses ripgrep directly
  and is unrelated to the advanced search pipeline.

## Testing Strategy

### Unit Tests: Tokenizer

1. `task-due:today` -> `TK.TASK { variant="meta", meta_field="due", op="=", value="today" }`
2. `task-due:<7d` -> `TK.TASK { variant="meta", meta_field="due", op="<", value="7d" }`
3. `task-due:2026-03-01..2026-03-31` -> `TK.TASK { variant="meta", meta_field="due", op="..", value="2026-03-01", value2="2026-03-31" }`
4. `task-priority:<=2` -> `TK.TASK { variant="meta", meta_field="priority", op="<=", value="2" }`
5. `task-tag:urgent` -> `TK.TASK { variant="meta", meta_field="tag", op="=", value="urgent" }`
6. `task-state:in-progress` -> `TK.TASK { variant="meta", meta_field="state", op="=", value="in-progress" }`
7. `task-repeat:""` -> `TK.TASK { variant="meta", meta_field="repeat", op="=", value="" }`
8. Legacy: `task-todo:""` -> `TK.TASK { variant="todo", pattern="" }` (unchanged)
9. Unknown: `task-foo:bar` -> `nil` (falls through to TEXT token)

### Unit Tests: Task Field Parsing

Create a mock task text and verify `parse_task_fields()`:

```lua
local text = 'Review paper [due:: 2026-03-01] [priority:: 1] #urgent #review'
local fields = parse_task_fields(text)
assert(fields.due == "2026-03-01")
assert(fields.priority == 1)
assert(fields.repeat_rule == nil)
assert(fields.completion == nil)
```

Edge cases:
- Empty due date: `[due:: ]` -> `due = nil` (fails YYYY-MM-DD validation)
- Non-numeric priority: `[priority:: high]` -> `priority = nil`
- Multiple due dates: first one wins (from `[key:: value]` pattern)
- Parenthesized form: `(due:: 2026-03-01)` -> `due = "2026-03-01"`
- Mixed forms: `[due:: 2026-03-01] (priority:: 2)` -> both parsed

### Unit Tests: Filter Matching

Create mock VaultIndexEntry tables with task arrays:

```lua
local entry = {
  tasks = {
    { text = "Task A", status = " ", completed = false, line = 1,
      tags = { "urgent" }, due = "2026-03-01", priority = 1 },
    { text = "Task B", status = "x", completed = true, line = 2,
      tags = { "review" }, due = "2026-02-15", priority = 3,
      completion = "2026-02-14" },
  }
}
```

Test cases:
1. `task-due:2026-03-01` matches (Task A)
2. `task-due:<today` matches if 2026-03-01 is in the past
3. `task-priority:1` matches (Task A)
4. `task-priority:<=2` matches (Task A has priority 1)
5. `task-priority:>2` matches (Task B has priority 3)
6. `task-tag:urgent` matches (Task A)
7. `task-tag:review` matches (Task B)
8. `task-tag:nonexistent` does not match
9. `task-completion:<30d` matches if Task B's completion is within 30 days
10. `task-due:""` matches (existence: Task A and B both have due dates)
11. `task-repeat:""` does not match (no tasks have repeat_rule)

### Unit Tests: Forward-Looking Date Resolution

```lua
-- Assuming today is 2026-02-27:
-- task-due:<7d -> threshold = 2026-03-06 (7 days from now)
--   Task with due=2026-03-01 matches (<7d = due before March 6)
-- task-due:>7d -> threshold = 2026-03-06
--   Task with due=2026-03-10 matches (>7d = due after March 6)
```

Verify that `resolve_task_date("7d", true)` returns a date 7 days in the future,
while `resolve_task_date("7d", false)` (or `date_utils.resolve_date("7d")`)
returns a date 7 days in the past.

### Integration Tests

1. Index a file with tasks containing inline fields, verify the index entry has
   populated `tasks[i].due`, `tasks[i].priority`, etc.
2. Run `:VaultSearchAdvanced` with `task-due:<today`, verify only files with
   overdue tasks appear.
3. Run `task-todo:"" task-priority:<=2`, verify intersection works (open tasks
   with high priority).
4. Run `task-tag:urgent -task-done:""`, verify it finds files with urgent tasks
   that are not completed.
5. Verify Tab completion in the advanced search prompt offers `task-due:`,
   `task-priority:`, etc.
6. Verify `:VaultSearchHelp` shows the updated task filter documentation.

### Regression Tests

1. `task:""` still matches any file with tasks.
2. `task-todo:""` still matches files with open tasks.
3. `task-done:""` still matches files with completed tasks.
4. `task:pattern` still performs substring search on task text.
5. Existing saved searches with `task-todo:""` continue to work.

## Implementation Order

1. **vault_index.lua** -- Add `parse_task_fields()` and modify `extract_tasks()`.
   Bump schema version. This is the foundation; all other changes depend on the
   new data being available in the index.

2. **search_query.lua** -- Extend the tokenizer and parser. This can be tested
   independently with unit tests against token/AST output.

3. **search_filter.lua** -- Add the match helpers. This requires both (1) and
   (2) to be complete. Test with mock entries.

4. **search.lua** -- Update completion, help, and header. Cosmetic; depends on
   (2) for the prefix list but can be done in parallel with (3).

5. **saved_searches.lua** -- Update defaults. Lowest priority; optional.

Estimated scope: ~200 lines of new code, ~30 lines of modified code across 4
files. No new files. No new dependencies.
