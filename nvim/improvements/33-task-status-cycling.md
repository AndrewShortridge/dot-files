# 33 — Task Status Cycling Command

**Priority:** Medium
**Summary:** Add a `:VaultTaskToggle` command and `<leader>vxt` / `<leader>vxT` keymaps to cycle task checkbox state forward and backward through the configured `config.task_states` order, with recurrence handling, completion metadata, and vault index updates.

---

## Current State

### What Exists

| Component | What It Does | Limitation |
|-----------|-------------|------------|
| **`ftplugin/markdown.lua` `<leader>mx`** | Cycles checkbox state forward using `checkbox_next` lookup table built from `config.task_states` | Buffer-local to markdown ftplugin; no reverse cycle; no `:VaultTaskToggle` command; only available in the current buffer |
| **`task_kanban.lua` `set_task_status()`** | Sets a task to a specific status from the Kanban board; handles completion dates, recurrence, file I/O, buffer reload | Only accessible from within the Kanban float; operates on a task object (not cursor line); writes directly to disk via `readfile`/`writefile` |
| **`recurrence.lua` `handle_recurrence()`** | When a task is marked `[x]`, checks for `[repeat:: ...]` field and creates a new recurring task above | Called from both `ftplugin/markdown.lua` and `task_kanban.lua`; well-tested |
| **No `:VaultTaskToggle` command** | -- | Cannot cycle task state via command mode |
| **No reverse cycle keymap** | -- | User must cycle forward through all states to reach a previous state |
| **No vault-wide keymap** | -- | `<leader>mx` is defined in `ftplugin/markdown.lua` only; the `<leader>vx` task group in `tasks.lua` has no toggle entry |

### How `<leader>mx` Currently Works

In `ftplugin/markdown.lua` (lines 49-181), the existing checkbox cycling logic:

1. Builds `checkbox_cycle` array from `config.task_states`: `{" ", "/", "x", "-", ">"}`
2. Builds `checkbox_next` lookup: `{[" "]="/", ["/"]="x", ["x"]="-", ["-"]=">", [">"]=" "}`
3. On `<leader>mx`, parses the current line for `- [.]` pattern
4. Looks up `checkbox_next[mark]` to get the next state
5. When cycling to `x`: strips old `[completion:: ...]`, appends `[completion:: YYYY-MM-DD]`
6. When cycling away from `x`: strips `[completion:: ...]`
7. When the new mark is `x`: calls `recurrence.handle_recurrence(line_nr)`

```lua
-- Current implementation in ftplugin/markdown.lua
map("<leader>mx", function()
  local line = vim.api.nvim_get_current_line()
  local prefix, mark, rest = line:match("^(.*%- %[)(.)(%].*)$")
  if not prefix then
    return
  end
  local next_mark = checkbox_next[mark] or " "
  -- Add completion date when cycling to [x], remove when cycling away
  if next_mark == "x" then
    rest = rest:gsub("%s*%[completion::[^%]]*%]", "")
    rest = rest .. " [completion:: " .. os.date("%Y-%m-%d") .. "]"
  elseif mark == "x" then
    rest = rest:gsub("%s*%[completion::[^%]]*%]", "")
  end
  vim.api.nvim_set_current_line(prefix .. next_mark .. rest)
  if next_mark == "x" then
    local line_nr = vim.api.nvim_win_get_cursor(0)[1]
    require("andrew.vault.recurrence").handle_recurrence(line_nr)
  end
end, "Cycle checkbox")
```

### Why Current Design Is Insufficient

1. **No reverse cycling.** With 5 states, cycling past the desired state requires 4 more presses. A `<leader>vxT` (shift-T) reverse cycle halves average presses.
2. **No command-mode interface.** `:VaultTaskToggle` would allow scripting, macros, and visual-mode batch toggling.
3. **No vault index update.** The current `<leader>mx` modifies the buffer line but does not trigger a vault index re-parse of the file. The task status in the index becomes stale until the next file save or watcher event.
4. **Duplicated logic.** The checkbox cycling logic in `ftplugin/markdown.lua` and the status mutation logic in `task_kanban.lua` are independent implementations of similar behavior. A shared function in `tasks.lua` would eliminate this duplication.
5. **No visual feedback.** The user has no confirmation of the state change beyond seeing the character change in the line. A brief notification or virtual text flash would confirm the transition (especially useful for marks like ` ` vs `-` that are visually subtle).

---

## Goal

1. A shared `M.cycle_task(direction)` function in `tasks.lua` that handles forward and reverse task checkbox cycling on the cursor line.
2. `:VaultTaskToggle` command (no args = forward cycle, `!` = reverse cycle).
3. `<leader>vxt` keymap for forward cycle, `<leader>vxT` for reverse cycle (in the vault task group).
4. Existing `<leader>mx` in `ftplugin/markdown.lua` delegates to the shared function instead of duplicating logic.
5. Vault index is updated after the status change so downstream consumers (kanban, search, calendar) see the new state immediately.
6. Visual feedback via a brief inline virtual text flash showing the transition (e.g., "[ ] -> [/]").
7. Configurable cycle order via `config.task_states` (already the case; the new code respects this).

---

## Approach

### Architecture

```
config.task_states  -->  tasks.cycle_task(direction)
                              |
                    +---------+---------+
                    |                   |
              :VaultTaskToggle    <leader>vxt / vxT
                    |                   |
                    v                   v
              (same function)     (same function)
                    |
          +---------+---------+---------+
          |         |         |         |
     parse line  mutate    recurrence  index update
                  line     (if -> x)   (schedule)
```

The central function `M.cycle_task(direction)` lives in `tasks.lua` and:

1. Reads the current line under the cursor.
2. Parses the `- [.] ` task checkbox pattern.
3. Computes the next/previous mark from `config.task_states`.
4. Handles completion metadata (`[completion:: ...]`) on transitions to/from `x`.
5. Calls `recurrence.handle_recurrence()` when transitioning to `x`.
6. Triggers `vault_index:update_file()` for the current buffer path.
7. Shows a brief virtual text flash indicating the state transition.

### Cycle Order

Forward: follows `config.task_states` order, wrapping at the end.
Reverse: follows `config.task_states` order in reverse, wrapping at the beginning.

Default cycle (from `config.task_states`):
```
Forward:  [ ] -> [/] -> [x] -> [-] -> [>] -> [ ]
Reverse:  [ ] -> [>] -> [-] -> [x] -> [/] -> [ ]
```

### Completion Metadata Rules

| Transition | Action |
|-----------|--------|
| Any -> `x` | Strip old `[completion:: ...]` if present, append `[completion:: YYYY-MM-DD]` |
| `x` -> Any | Strip `[completion:: ...]` |
| Non-x -> Non-x | No completion metadata change |

### Recurrence Rules

| Transition | Action |
|-----------|--------|
| Any -> `x` | Call `recurrence.handle_recurrence(line_nr)` |
| Any other | No recurrence action |

Note: `handle_recurrence` is idempotent in the sense that it only acts if the task line contains a `[repeat:: ...]` field. Safe to call unconditionally on `x` transitions.

### Index Update Strategy

After mutating the line, schedule a deferred vault index update:

```lua
vim.schedule(function()
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if idx then
    idx:update_file(vim.api.nvim_buf_get_name(0))
  end
end)
```

This is deferred via `vim.schedule` because:
- The buffer line has already been modified by `nvim_set_current_line`.
- `update_file` reads the file from disk, so we need the buffer to be flushed (or we rely on the watcher). However, since the buffer is modified but not yet saved, `update_file` would read the stale disk version. Instead, we should trigger the filesystem watcher's debounced re-index, which will pick up the change on the next save. Alternatively, we can force a save + update.

**Revised strategy:** Since the buffer may not be saved yet, and the vault index reads from disk, the best approach is:
1. After line mutation, if autosave is enabled, the `FocusLost`/`BufLeave` events will save and trigger the watcher.
2. For immediate feedback, we can call `idx:update_file()` only if the buffer has been written. Otherwise, mark the buffer as modified and let the normal save -> watcher -> index pipeline handle it.
3. For the common case (user cycles task state and continues editing), the watcher debounce (500ms default) will update the index after the next save. This is acceptable.

Simpler approach: just let the existing filesystem watcher handle it. The index will update within 500ms of the next save. No explicit `update_file` call needed from the cycling function. The Kanban board's `set_task_status()` already relies on `writefile` + buffer reload, but for in-buffer cycling, the standard save->watch pipeline is sufficient.

### Visual Feedback

A brief virtual text extmark at the end of the line showing the transition, cleared after 1.5 seconds:

```lua
local ns_flash = vim.api.nvim_create_namespace("vault_task_flash")

local function flash_transition(line_nr, old_mark, new_mark)
  local label_map = {}
  for _, s in ipairs(config.task_states) do
    label_map[s.mark] = s.label
  end
  local msg = string.format("[%s] %s -> [%s] %s",
    old_mark, label_map[old_mark] or "?",
    new_mark, label_map[new_mark] or "?")
  vim.api.nvim_buf_set_extmark(0, ns_flash, line_nr - 1, 0, {
    virt_text = { { "  " .. msg, "DiagnosticHint" } },
    virt_text_pos = "eol",
  })
  vim.defer_fn(function()
    pcall(vim.api.nvim_buf_del_extmark, 0, ns_flash, 1)
  end, 1500)
end
```

---

## Implementation Steps

### Step 1: Add `cycle_task()` to `tasks.lua`

**File: `lua/andrew/vault/tasks.lua`** (modify)

Add the shared cycling function and supporting helpers before the `setup()` function:

```lua
local recurrence = require("andrew.vault.recurrence")

local ns_flash = vim.api.nvim_create_namespace("vault_task_flash")

--- Build forward and reverse lookup tables from config.task_states.
---@return table forward, table reverse
local function build_cycle_maps()
  local marks = {}
  for _, state in ipairs(config.task_states) do
    marks[#marks + 1] = state.mark
  end
  local fwd = {}
  local rev = {}
  for i, v in ipairs(marks) do
    fwd[v] = marks[i % #marks + 1]
    rev[v] = marks[(i - 2) % #marks + 1]
  end
  return fwd, rev
end

--- Show a brief virtual text flash indicating the state transition.
---@param bufnr number
---@param line_nr number 1-indexed
---@param old_mark string
---@param new_mark string
local function flash_transition(bufnr, line_nr, old_mark, new_mark)
  local label_map = {}
  for _, s in ipairs(config.task_states) do
    label_map[s.mark] = s.label
  end
  local msg = string.format("[%s] %s -> [%s] %s",
    old_mark, label_map[old_mark] or "?",
    new_mark, label_map[new_mark] or "?")

  -- Clear any previous flash extmarks
  vim.api.nvim_buf_clear_namespace(bufnr, ns_flash, 0, -1)

  local id = vim.api.nvim_buf_set_extmark(bufnr, ns_flash, line_nr - 1, 0, {
    virt_text = { { "  " .. msg, "DiagnosticHint" } },
    virt_text_pos = "eol",
  })
  vim.defer_fn(function()
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_flash, id)
  end, 1500)
end

--- Cycle the task checkbox state on the current cursor line.
--- Handles completion metadata, recurrence, and visual feedback.
---@param direction? "forward"|"backward"  Default: "forward"
---@return boolean true if a task was cycled, false otherwise
function M.cycle_task(direction)
  direction = direction or "forward"
  local fwd, rev = build_cycle_maps()
  local cycle_map = direction == "backward" and rev or fwd

  local bufnr = vim.api.nvim_get_current_buf()
  local line_nr = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, line_nr - 1, line_nr, false)[1]
  if not line then
    return false
  end

  local prefix, mark, rest = line:match("^(.*%- %[)(.)(%].*)$")
  if not prefix then
    vim.notify("No task checkbox on current line", vim.log.levels.WARN)
    return false
  end

  local new_mark = cycle_map[mark]
  if not new_mark then
    -- Unknown mark, fall back to first state
    new_mark = config.task_states[1] and config.task_states[1].mark or " "
  end

  -- Handle completion metadata
  if new_mark == "x" and mark ~= "x" then
    rest = rest:gsub("%s*%[completion::[^%]]*%]", "")
    rest = rest .. " [completion:: " .. os.date("%Y-%m-%d") .. "]"
  elseif new_mark ~= "x" and mark == "x" then
    rest = rest:gsub("%s*%[completion::[^%]]*%]", "")
  end

  -- Apply the change
  vim.api.nvim_buf_set_lines(bufnr, line_nr - 1, line_nr, false, {
    prefix .. new_mark .. rest,
  })

  -- Handle recurrence when completing a task
  if new_mark == "x" then
    -- Recurrence may insert a line above, shifting our line down.
    -- handle_recurrence uses the current buffer (0), so it works on the active buffer.
    local created = recurrence.handle_recurrence(line_nr)
    if created then
      -- The new recurring task was inserted above, so our completed task
      -- is now at line_nr + 1. Adjust cursor to stay on the completed task.
      vim.api.nvim_win_set_cursor(0, { line_nr + 1, vim.api.nvim_win_get_cursor(0)[2] })
      line_nr = line_nr + 1
    end
  end

  -- Visual feedback
  flash_transition(bufnr, line_nr, mark, new_mark)

  return true
end
```

### Step 2: Add `:VaultTaskToggle` Command and Keymaps in `setup()`

**File: `lua/andrew/vault/tasks.lua`** (modify `setup()`)

Add to the existing `setup()` function, after the current keymaps:

```lua
function M.setup()
  -- ... existing commands and keymaps ...

  -- Task cycling command
  vim.api.nvim_create_user_command("VaultTaskToggle", function(args)
    local direction = args.bang and "backward" or "forward"
    M.cycle_task(direction)
  end, {
    bang = true,
    desc = "Cycle task checkbox state (! = reverse)",
  })

  -- Task cycling keymaps in the <leader>vx group
  vim.keymap.set("n", "<leader>vxt", function()
    M.cycle_task("forward")
  end, { desc = "Task: cycle forward", silent = true })

  vim.keymap.set("n", "<leader>vxT", function()
    M.cycle_task("backward")
  end, { desc = "Task: cycle backward", silent = true })
end
```

### Step 3: Delegate `<leader>mx` to the Shared Function

**File: `ftplugin/markdown.lua`** (modify)

Replace the existing `<leader>mx` implementation (lines 162-181) with a delegation to the shared function:

**Before:**

```lua
map("<leader>mx", function()
  local line = vim.api.nvim_get_current_line()
  local prefix, mark, rest = line:match("^(.*%- %[)(.)(%].*)$")
  if not prefix then
    return
  end
  local next_mark = checkbox_next[mark] or " "
  -- Add completion date when cycling to [x], remove when cycling away
  if next_mark == "x" then
    rest = rest:gsub("%s*%[completion::[^%]]*%]", "")
    rest = rest .. " [completion:: " .. os.date("%Y-%m-%d") .. "]"
  elseif mark == "x" then
    rest = rest:gsub("%s*%[completion::[^%]]*%]", "")
  end
  vim.api.nvim_set_current_line(prefix .. next_mark .. rest)
  if next_mark == "x" then
    local line_nr = vim.api.nvim_win_get_cursor(0)[1]
    require("andrew.vault.recurrence").handle_recurrence(line_nr)
  end
end, "Cycle checkbox")
```

**After:**

```lua
map("<leader>mx", function()
  require("andrew.vault.tasks").cycle_task("forward")
end, "Cycle checkbox")
```

The `checkbox_cycle`, `checkbox_next`, and related code at lines 50-58 of `ftplugin/markdown.lua` can be removed since they are no longer used:

**Remove:**

```lua
-- Cycle checkbox states from vault config
local vault_config = require("andrew.vault.config")
local checkbox_cycle = {}
for _, state in ipairs(vault_config.task_states) do
  checkbox_cycle[#checkbox_cycle + 1] = state.mark
end
local checkbox_next = {}
for i, v in ipairs(checkbox_cycle) do
  checkbox_next[v] = checkbox_cycle[i % #checkbox_cycle + 1]
end
```

Note: `vault_config` is still required elsewhere in this file (if used), but specifically for the checkbox cycling it is no longer needed. Verify no other code in the file references `checkbox_cycle` or `checkbox_next` before removing. A search confirms they are only used by the `<leader>mx` handler.

### Step 4: Register with which-key

**File: `ftplugin/markdown.lua`** (modify the which-key block)

The `<leader>mx` entry already exists. No change needed there since the keymap description is the same. The `<leader>vxt` and `<leader>vxT` keymaps are global (not buffer-local), so they should be registered in the vault's which-key setup, not in `ftplugin/markdown.lua`.

**File: `lua/andrew/vault/tasks.lua`** (in `setup()`, after keymaps)

If which-key registration is desired for the vault `<leader>vx` group, it is typically handled by the vault `init.lua` which-key block. The keymaps themselves already have `desc` fields, which which-key auto-discovers. No additional registration is strictly needed.

---

## Before / After Examples

### Example 1: Forward Cycle on Open Task

**Before (cursor on this line):**
```markdown
- [ ] Review the pull request [due:: 2026-03-05] [priority:: 2]
```

**After pressing `<leader>vxt`:**
```markdown
- [/] Review the pull request [due:: 2026-03-05] [priority:: 2]
```

Virtual text flash at EOL: `  [ ] open -> [/] in-progress` (disappears after 1.5s)

### Example 2: Forward Cycle to Done (with completion date)

**Before:**
```markdown
- [/] Review the pull request [due:: 2026-03-05] [priority:: 2]
```

**After pressing `<leader>vxt`:**
```markdown
- [x] Review the pull request [due:: 2026-03-05] [priority:: 2] [completion:: 2026-03-02]
```

### Example 3: Forward Cycle to Done with Recurrence

**Before:**
```markdown
- [/] Weekly standup notes [due:: 2026-03-02] [repeat:: every week]
```

**After pressing `<leader>vxt`:**
```markdown
- [ ] Weekly standup notes [due:: 2026-03-09] [repeat:: every week]
- [x] Weekly standup notes [due:: 2026-03-02] [repeat:: every week] [completion:: 2026-03-02]
```

A new open task is inserted above with the next due date. Cursor moves to the completed task.

### Example 4: Reverse Cycle from Done

**Before:**
```markdown
- [x] Fix the bug [completion:: 2026-03-01]
```

**After pressing `<leader>vxT`:**
```markdown
- [/] Fix the bug
```

Completion date is stripped. Virtual text flash: `  [x] done -> [/] in-progress`

### Example 5: Reverse Cycle Wrapping

**Before:**
```markdown
- [ ] New task
```

**After pressing `<leader>vxT`:**
```markdown
- [>] New task
```

Wraps from the first state to the last state.

### Example 6: Command Mode

```vim
:VaultTaskToggle      " Forward cycle
:VaultTaskToggle!     " Reverse cycle
```

### Example 7: No Task on Line

**Before (cursor on a non-task line):**
```markdown
Some regular paragraph text.
```

**After pressing `<leader>vxt`:**

Notification: "No task checkbox on current line" (WARN level). No line modification.

---

## Test Cases

### 1. Forward Cycle Through All States

1. Create a task: `- [ ] Test task`
2. Press `<leader>vxt` five times.
3. Expected states in order: `[/]`, `[x]`, `[-]`, `[>]`, `[ ]` (wraps back to open).
4. Verify completion date is added only at `[x]` step and removed when cycling past `[x]`.

### 2. Reverse Cycle Through All States

1. Create a task: `- [ ] Test task`
2. Press `<leader>vxT` five times.
3. Expected states in order: `[>]`, `[-]`, `[x]`, `[/]`, `[ ]` (wraps back to open).
4. Verify completion date is added at `[x]` step and removed when cycling past.

### 3. Completion Date Management

1. Task: `- [/] In progress task`
2. Forward cycle to `[x]`.
3. Verify line now contains `[completion:: YYYY-MM-DD]` with today's date.
4. Forward cycle to `[-]`.
5. Verify `[completion:: ...]` has been removed.
6. Forward cycle to `[>]`, then `[ ]`, then `[/]`, then `[x]` again.
7. Verify a fresh `[completion:: ...]` with today's date is appended.

### 4. Existing Completion Date Replacement

1. Task: `- [/] Old task [completion:: 2025-01-01]`
2. Forward cycle to `[x]`.
3. Verify old completion date is stripped and a new one with today's date is appended (not duplicated).

### 5. Recurrence on Completion

1. Task: `- [ ] Recurring [due:: 2026-03-02] [repeat:: every week]`
2. Forward cycle twice to reach `[x]`.
3. Verify a new task `- [ ] Recurring [due:: 2026-03-09] [repeat:: every week]` is inserted above.
4. Verify the completed task has `[completion:: 2026-03-02]`.
5. Verify cursor is on the completed task (line below the new recurring task).

### 6. Recurrence Does Not Trigger on Reverse

1. Task: `- [-] Recurring [due:: 2026-03-02] [repeat:: every week]`
2. Reverse cycle to `[x]`.
3. Verify recurrence DOES trigger (any transition to `[x]` triggers recurrence, regardless of direction).

### 7. Non-Task Line

1. Place cursor on a line: `Some paragraph text.`
2. Press `<leader>vxt`.
3. Verify warning notification: "No task checkbox on current line".
4. Verify line is unchanged.

### 8. Command Mode

1. Task: `- [ ] Command test`
2. Run `:VaultTaskToggle`. Verify state becomes `[/]`.
3. Run `:VaultTaskToggle!`. Verify state goes back to `[ ]`.

### 9. `<leader>mx` Delegation

1. Open a markdown file with a task: `- [ ] Ftplugin test`
2. Press `<leader>mx`. Verify it cycles forward (same behavior as before).
3. Verify visual feedback flash appears.
4. Verify the `<leader>mx` and `<leader>vxt` keymaps both work and produce identical results.

### 10. Indented / Nested Tasks

1. Task: `    - [ ] Nested subtask` (indented with spaces)
2. Press `<leader>vxt`.
3. Verify the pattern matches correctly and cycles to `[/]` without breaking indentation.

### 11. Task with Special Characters

1. Task: `- [ ] Fix the "quoted" bug (parentheses) [due:: 2026-03-05]`
2. Cycle through all states forward and backward.
3. Verify no corruption of special characters in the task text.

### 12. Visual Feedback

1. Cycle any task.
2. Verify virtual text appears at EOL showing the transition.
3. Wait 1.5 seconds. Verify the virtual text disappears.
4. Rapidly cycle 3 times. Verify only the latest flash is shown (previous ones cleared).

---

## Summary of File Changes

| File | Change | Type |
|------|--------|------|
| `lua/andrew/vault/tasks.lua` | Add `cycle_task()`, `build_cycle_maps()`, `flash_transition()`, `:VaultTaskToggle` command, `<leader>vxt` / `<leader>vxT` keymaps | Modify |
| `ftplugin/markdown.lua` | Replace `<leader>mx` inline logic with delegation to `tasks.cycle_task()`; remove unused `checkbox_cycle` / `checkbox_next` locals | Modify |

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| **`require("andrew.vault.tasks")` in ftplugin** | Circular dependency or load-order issue | `tasks.lua` only requires `config` and `engine`, both of which are already loaded before any markdown buffer opens. The `recurrence` and `vault_index` requires are inline (lazy). No circular dependency risk. |
| **Recurrence line insertion shifts cursor** | After `handle_recurrence` inserts a new line above, the cursor could be on the wrong line | The implementation detects the return value of `handle_recurrence()` and adjusts the cursor to `line_nr + 1` when a recurring task was created. |
| **Virtual text flash on deleted buffer** | If the buffer is closed within 1.5s of the flash, `del_extmark` would fail | The `defer_fn` callback is wrapped in `pcall`, so a deleted buffer causes no error. |
| **Unknown mark character** | A task with a mark not in `config.task_states` (e.g., `[?]`) would have no cycle mapping | Falls back to the first configured state (`" "` by default). |
| **`<leader>mx` behavior change** | Users accustomed to `<leader>mx` now see a visual flash they did not see before | The flash is unobtrusive (virtual text at EOL, auto-clears). Net positive for usability. |
| **Index staleness after cycle** | The vault index reads from disk; unsaved buffer changes are not reflected | Acceptable: the standard save -> watcher -> index pipeline updates within 500ms of saving. This matches existing behavior for all other in-buffer edits. |
| **`build_cycle_maps()` called on every cycle** | Rebuilds the lookup tables each time | The function is trivially fast (5 iterations over `config.task_states`). If needed, the maps can be cached at module level and rebuilt only if `config.task_states` changes, but this optimization is unnecessary for a 5-element table. |
| **Bang (`!`) syntax for reverse** | Users may not discover the reverse cycle via `:VaultTaskToggle!` | The `<leader>vxT` keymap is the primary reverse interface; the bang is a secondary power-user feature. Both are documented in `desc` fields for which-key discoverability. |
