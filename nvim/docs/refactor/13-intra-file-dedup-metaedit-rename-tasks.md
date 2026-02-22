# Feature 13: Intra-File Deduplication — `metaedit.lua`, `rename.lua`, `tasks.lua`

## Dependencies
- **None** — self-contained intra-file refactors.
- **Depended on by:** Nothing

## Problem

### 13a: metaedit.lua — Value coercion duplicated (exact copy)

Lines 302-310 (in the `VaultMetaEdit` command handler):

```lua
-- Try to coerce to number or boolean
if value == "true" then
  M.set_field(field, true)
elseif value == "false" then
  M.set_field(field, false)
elseif tonumber(value) then
  M.set_field(field, tonumber(value))
else
  M.set_field(field, value)
end
```

Lines 390-398 (in the `<leader>vmf` keymap handler):

```lua
-- Coerce typed input
if value == "true" then
  M.set_field(field, true)
elseif value == "false" then
  M.set_field(field, false)
elseif tonumber(value) then
  M.set_field(field, tonumber(value))
else
  M.set_field(field, value)
end
```

These two blocks are character-for-character identical.

**Additional context:** The file already contains a `parse_value` local function (lines 33-48) that performs equivalent coercion — parsing `"true"`/`"false"` to booleans, numeric strings to numbers, and stripping surrounding quotes from quoted strings. The two duplicate blocks essentially re-implement a subset of `parse_value` inline. The new `coerce_and_set` helper should call `parse_value` internally rather than duplicating the coercion logic a third way.

### 13b: rename.lua — apply_rename_changes re-scans the vault independently

The rename workflow calls two separate functions that each run a full vault scan:

**`collect_rename_changes` (lines 76-130):** runs `rg --files-with-matches`, reads each matching file, applies the wikilink `gsub` line by line, and records per-line change entries. Returns `{ changes, file_count, link_count }`. Used by both `M.rename_preview` (for quickfix display) and `M.rename` (for the confirmation summary).

**`apply_rename_changes` (lines 137-171):** runs `rg --files-with-matches` again with the same pattern, reads each file again, applies the same wikilink `gsub` again — but this time at the whole-file level and actually writes the results to disk. Returns `modified_files, link_count`.

The concrete call sequence in `M.rename` (lines 268-285):

```lua
-- Collect changes for the confirmation summary
local info = collect_rename_changes(old_name, name)

-- Confirmation prompt
local prompt = "Renaming '" .. old_name .. "' -> '" .. name .. "' will update "
  .. info.link_count .. " references in " .. info.file_count .. " files. Proceed? [y/N]: "
local answer = engine.input({ prompt = prompt })
if not answer or answer:lower() ~= "y" then
  vim.notify("Vault: rename cancelled", vim.log.levels.INFO)
  return
end

-- Save current buffer if modified
if vim.bo.modified then
  vim.cmd("write")
end

-- Apply wikilink changes
local modified_files, link_count = apply_rename_changes(old_name, name)
```

This means every confirmed rename triggers two full vault scans, two full file reads of all matching files, and two full wikilink gsub passes. The second scan can yield different results if the vault changes between the collect and apply calls (e.g. if another process modifies files), but in practice the duplication is pure waste.

**The fix:** `collect_rename_changes` should accumulate the new file content alongside the per-line diff entries, so that `apply_rename_changes` can write directly from those cached results without re-scanning.

### 13c: tasks.lua — `M.tasks()` is a hardcoded copy of `M.tasks_by_state(" ")`

`M.tasks` (lines 7-18):

```lua
function M.tasks()
  local fzf = require("fzf-lua")
  fzf.grep({
    cwd = engine.vault_path,
    search = "- \\[ \\]",
    prompt = "Vault tasks> ",
    file_icons = true,
    git_icons = false,
    no_esc = true,
    rg_opts = '--column --line-number --no-heading --color=always --glob "*.md" -e',
  })
end
```

`M.tasks_by_state` (lines 22-34):

```lua
function M.tasks_by_state(mark)
  local fzf = require("fzf-lua")
  local escaped = mark:gsub("[%-]", "\\%0")
  fzf.grep({
    cwd = engine.vault_path,
    search = "- \\[" .. escaped .. "\\]",
    prompt = "Vault tasks [" .. mark .. "]> ",
    file_icons = true,
    git_icons = false,
    no_esc = true,
    rg_opts = '--column --line-number --no-heading --color=always --glob "*.md" -e',
  })
end
```

Calling `M.tasks_by_state(" ")` produces `search = "- \\[ \\]"` — exactly what `M.tasks` hardcodes. `M.tasks` is entirely redundant.

Additionally, all three public functions (`tasks`, `tasks_by_state`, `tasks_all`) share an identical `fzf.grep` call shape with only `search` and `prompt` differing. The options table (`cwd`, `file_icons`, `git_icons`, `no_esc`, `rg_opts`) is copy-pasted verbatim three times.

## Files to Modify

1. `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/metaedit.lua` — Extract `coerce_and_set` helper
2. `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/rename.lua` — Refactor `apply_rename_changes` to consume collected results
3. `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/tasks.lua` — Extract `grep_tasks` helper, make `M.tasks` delegate to `M.tasks_by_state`

---

## Implementation Steps

### Step 1: metaedit.lua — Extract `coerce_and_set(field, raw_value)`

The existing `parse_value` function (lines 33-48) already handles the boolean and number coercion. The new helper should reuse it rather than repeat the same conditional chain a third time.

Add the following local function after `parse_value` (around line 49), before the frontmatter scanning section:

```lua
--- Parse a raw string value and set the corresponding frontmatter field.
--- Delegates type coercion to parse_value: "true"/"false" -> boolean,
--- numeric strings -> number, else plain string.
--- @param field string  frontmatter field name
--- @param raw_value string  raw string typed by the user
local function coerce_and_set(field, raw_value)
  M.set_field(field, parse_value(raw_value))
end
```

**Replace lines 301-310** inside the `VaultMetaEdit` command handler:

Before:
```lua
    local field = args[1]
    local value = table.concat(vim.list_slice(args, 2), " ")
    -- Try to coerce to number or boolean
    if value == "true" then
      M.set_field(field, true)
    elseif value == "false" then
      M.set_field(field, false)
    elseif tonumber(value) then
      M.set_field(field, tonumber(value))
    else
      M.set_field(field, value)
    end
```

After:
```lua
    local field = args[1]
    local value = table.concat(vim.list_slice(args, 2), " ")
    coerce_and_set(field, value)
```

**Replace lines 389-398** inside the `<leader>vmf` keymap callback:

Before:
```lua
          -- Coerce typed input
          if value == "true" then
            M.set_field(field, true)
          elseif value == "false" then
            M.set_field(field, false)
          elseif tonumber(value) then
            M.set_field(field, tonumber(value))
          else
            M.set_field(field, value)
          end
```

After:
```lua
          coerce_and_set(field, value)
```

**Behaviour note:** `parse_value` also strips surrounding quote characters (`"..."` and `'...'`) from the raw string. This is slightly different from what the inline blocks did previously (which treated quoted strings as bare strings). In practice this is an improvement — if a user types `"hello"` at the prompt they will get `hello` stored, which is the expected YAML behaviour. If you want to preserve the old literal-string behaviour for user-typed input only, use a simpler helper that omits the quote-stripping:

```lua
local function coerce_and_set(field, raw_value)
  local v = vim.trim(raw_value)
  if v == "true" then
    M.set_field(field, true)
  elseif v == "false" then
    M.set_field(field, false)
  elseif tonumber(v) then
    M.set_field(field, tonumber(v))
  else
    M.set_field(field, v)
  end
end
```

Either variant eliminates the duplication. Prefer the `parse_value`-delegating form for consistency.

---

### Step 2: rename.lua — Refactor `apply_rename_changes` to consume collected results

#### 2a: Extend `collect_rename_changes` to also accumulate new file content

The current return value is:
```lua
return {
  changes = changes,       -- per-line diff entries for quickfix
  file_count = file_count,
  link_count = link_count,
}
```

Add a `file_writes` table that maps each modified file path to its fully-rewritten content:

```lua
local function collect_rename_changes(old_name, new_name)
  local escaped = rg_escape(old_name)
  local pattern = "\\[\\[" .. escaped .. "(\\]\\]|\\|[^\\]]*\\]\\]|#[^\\]]*\\]\\])"
  local result = vim.system({
    "rg", "--files-with-matches", "--glob", "*.md", "--ignore-case",
    pattern, engine.vault_path,
  }):wait()

  local changes = {}
  local file_set = {}
  local file_writes = {}   -- NEW: path -> new_content
  local link_count = 0

  if result.stdout and result.stdout ~= "" then
    for file_path in result.stdout:gmatch("[^\n]+") do
      local content = read_file(file_path)
      if content then
        local new_content_lines = {}
        local lnum = 0
        local file_changed = false

        for line in content:gmatch("([^\n]*)\n?") do
          lnum = lnum + 1
          local new_line = line:gsub("%[%[(.-)%]%]", function(inner)
            local target = inner:match("^([^|#]+)") or inner
            target = vim.trim(target)
            if target:lower() == old_name:lower() then
              local suffix = inner:sub(#target + 1)
              link_count = link_count + 1
              return "[[" .. new_name .. suffix .. "]]"
            end
            return "[[" .. inner .. "]]"
          end)

          if new_line ~= line then
            changes[#changes + 1] = {
              filename = file_path,
              lnum = lnum,
              old_text = line,
              new_text = new_line,
            }
            file_set[file_path] = true
            file_changed = true
          end

          new_content_lines[#new_content_lines + 1] = new_line
        end

        if file_changed then
          file_writes[file_path] = table.concat(new_content_lines, "\n")
        end
      end
    end
  end

  local file_count = 0
  for _ in pairs(file_set) do
    file_count = file_count + 1
  end

  return {
    changes = changes,
    file_count = file_count,
    link_count = link_count,
    file_writes = file_writes,   -- NEW
  }
end
```

**Important:** The original `collect_rename_changes` iterated lines with `content:gmatch("([^\n]*)\n?")` and the original `apply_rename_changes` used a whole-file `content:gsub(...)`. The line-by-line approach accumulates via `new_content_lines`. When joining with `table.concat(new_content_lines, "\n")` verify the trailing-newline behaviour matches the original file. If `content` ends with `\n`, the final `gmatch` iteration will produce a trailing empty string, causing `table.concat` to append `\n` correctly. Test with files that do and do not end in a newline before shipping.

#### 2b: Rewrite `apply_rename_changes` to accept collected results

Replace the current `apply_rename_changes(old_name, new_name)` function (lines 137-171) with:

```lua
--- Write collected wikilink changes to disk.
--- @param info table  return value of collect_rename_changes
--- @return string[], number  modified_files, link_count
local function apply_rename_changes(info)
  local modified_files = {}
  for path, new_content in pairs(info.file_writes) do
    if write_file(path, new_content) then
      modified_files[#modified_files + 1] = path
    end
  end
  return modified_files, info.link_count
end
```

#### 2c: Update `M.rename` to pass the collected info to `apply_rename_changes`

The call site in `M.rename` currently calls both functions independently. Change the `do_rename` inner function so that `apply_rename_changes` receives the already-collected `info`:

Before (lines 268-285):
```lua
    -- Collect changes for the confirmation summary
    local info = collect_rename_changes(old_name, name)

    -- Confirmation prompt
    local prompt = ...
    local answer = engine.input({ prompt = prompt })
    if not answer or answer:lower() ~= "y" then
      ...
      return
    end

    if vim.bo.modified then
      vim.cmd("write")
    end

    -- Apply wikilink changes
    local modified_files, link_count = apply_rename_changes(old_name, name)
```

After:
```lua
    -- Collect changes for the confirmation summary (single vault scan)
    local info = collect_rename_changes(old_name, name)

    -- Confirmation prompt
    local prompt = ...
    local answer = engine.input({ prompt = prompt })
    if not answer or answer:lower() ~= "y" then
      ...
      return
    end

    if vim.bo.modified then
      vim.cmd("write")
    end

    -- Apply wikilink changes from collected results (no second scan)
    local modified_files, link_count = apply_rename_changes(info)
```

No other changes to `M.rename` or `M.rename_preview` are needed. `M.rename_preview` already only calls `collect_rename_changes` and never calls `apply_rename_changes`.

#### 2d: Remove the old `apply_rename_changes` signature from any command bindings

`apply_rename_changes` is a local function and not exposed on `M`, so no external callers exist. The signature change is internal only.

---

### Step 3: tasks.lua — Extract `grep_tasks`, delegate `M.tasks` to `M.tasks_by_state`

#### 3a: Extract `grep_tasks(search, prompt)` local helper

The three public functions share an identical `fzf.grep` options table. Extract it:

```lua
local fzf = require("fzf-lua")
local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local M = {}

--- Internal: run fzf-lua grep over vault markdown files for a task pattern.
--- @param search string  ripgrep search pattern (no_esc = true, so raw regex)
--- @param prompt string  fzf prompt label ("> " is appended automatically)
local function grep_tasks(search, prompt)
  fzf.grep({
    cwd = engine.vault_path,
    search = search,
    prompt = prompt .. "> ",
    file_icons = true,
    git_icons = false,
    no_esc = true,
    rg_opts = '--column --line-number --no-heading --color=always --glob "*.md" -e',
  })
end
```

Note: move the `require("fzf-lua")` call to the top of the file (module level) rather than inside each function. This is consistent with how `engine` and `config` are already required at the top.

#### 3b: Rewrite the three public functions

```lua
--- Open tasks — unchecked boxes (- [ ])
function M.tasks()
  M.tasks_by_state(" ")
end

--- Tasks filtered by checkbox state.
--- @param mark string  single character: " ", "x", "/", "-", ">" etc.
function M.tasks_by_state(mark)
  local escaped = mark:gsub("[%-]", "\\%0")
  grep_tasks("- \\[" .. escaped .. "\\]", "Vault tasks [" .. mark .. "]")
end

--- All tasks regardless of checkbox state.
function M.tasks_all()
  grep_tasks("- \\[.\\]", "Vault tasks (all)")
end
```

`M.tasks` now delegates to `M.tasks_by_state(" ")`, which produces `search = "- \\[ \\]"` — identical to the hardcoded string it previously used. The `VaultTasks` command and `<leader>vxo` keymap call `M.tasks()` and require no changes.

#### 3c: `M.setup` is unchanged

The `M.setup` function (commands and keymaps) requires no edits. `VaultTasks` already calls `M.tasks()`, which now simply calls `M.tasks_by_state(" ")`. Behaviour is identical.

---

## Full Resulting File Skeletons

### metaedit.lua skeleton (showing changed sections only)

```lua
local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local M = {}

local yaml_special = '[:%#%[%{\'"]'

local function format_value(val) ... end   -- unchanged

local function parse_value(raw) ... end    -- unchanged

--- Parse a raw user-typed string and set the frontmatter field.
--- Delegates coercion to parse_value.
--- @param field string
--- @param raw_value string
local function coerce_and_set(field, raw_value)
  M.set_field(field, parse_value(raw_value))
end

-- ... rest of local helpers unchanged ...

function M.setup()
  -- ...
  vim.api.nvim_create_user_command("VaultMetaEdit", function(opts)
    local args = vim.split(vim.trim(opts.args), "%s+", { trimempty = true })
    if #args < 2 then
      vim.notify("Usage: VaultMetaEdit [field] [value]", vim.log.levels.WARN)
      return
    end
    local field = args[1]
    local value = table.concat(vim.list_slice(args, 2), " ")
    coerce_and_set(field, value)   -- was: inline if/elseif chain
  end, { ... })

  -- ...

  vim.keymap.set("n", "<leader>vmf", function()
    engine.run(function()
      local field = engine.input({ prompt = "Field name: " })
      if not field or field == "" then return end
      local value = engine.input({ prompt = field .. " = " })
      if not value then return end
      coerce_and_set(field, value)   -- was: inline if/elseif chain
    end)
  end, ...)
end

return M
```

### tasks.lua skeleton (full replacement)

```lua
local fzf = require("fzf-lua")
local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local M = {}

--- Internal: grep vault markdown files for a task search pattern.
--- @param search string
--- @param prompt string
local function grep_tasks(search, prompt)
  fzf.grep({
    cwd = engine.vault_path,
    search = search,
    prompt = prompt .. "> ",
    file_icons = true,
    git_icons = false,
    no_esc = true,
    rg_opts = '--column --line-number --no-heading --color=always --glob "*.md" -e',
  })
end

--- Collect all open tasks (- [ ]) across the vault and show in fzf-lua.
function M.tasks()
  M.tasks_by_state(" ")
end

--- Collect tasks matching a specific checkbox state.
--- @param mark string  single char: " ", "/", "x", "-", ">"
function M.tasks_by_state(mark)
  local escaped = mark:gsub("[%-]", "\\%0")
  grep_tasks("- \\[" .. escaped .. "\\]", "Vault tasks [" .. mark .. "]")
end

--- Show all tasks regardless of state.
function M.tasks_all()
  grep_tasks("- \\[.\\]", "Vault tasks (all)")
end

function M.setup()
  vim.api.nvim_create_user_command("VaultTasks", function()
    M.tasks()
  end, { desc = "Show open tasks across vault" })

  vim.api.nvim_create_user_command("VaultTasksAll", function()
    M.tasks_all()
  end, { desc = "Show all tasks across vault (any state)" })

  vim.api.nvim_create_user_command("VaultTasksByState", function(args)
    local mark = args.args
    if mark == "" then
      mark = " "
    end
    M.tasks_by_state(mark)
  end, {
    nargs = "?",
    desc = "Show tasks with specific checkbox state",
  })

  vim.keymap.set("n", "<leader>vxo", function()
    M.tasks()
  end, { desc = "Tasks: open", silent = true })

  vim.keymap.set("n", "<leader>vxa", function()
    M.tasks_all()
  end, { desc = "Tasks: all", silent = true })

  vim.keymap.set("n", "<leader>vxs", function()
    engine.run(function()
      local states = {}
      for _, s in ipairs(config.task_states) do
        states[#states + 1] = s.mark .. " (" .. s.label .. ")"
      end
      local choice = engine.select(states, { prompt = "Task state" })
      if choice then
        M.tasks_by_state(choice:sub(1, 1))
      end
    end)
  end, { desc = "Tasks: by state", silent = true })
end

return M
```

---

## Pitfalls and Edge Cases

### metaedit.lua

**`parse_value` strips quotes.** If a user types `"In Progress"` at the `<leader>vmf` prompt intending the literal value `"In Progress"` (with quotes), the new `coerce_and_set` will strip the quotes and store `In Progress`. The old inline block would have stored the quoted string verbatim. This is almost certainly the desired behaviour (matching YAML semantics), but it is a subtle behaviour change. Document it or use the simpler variant of `coerce_and_set` that only handles boolean/number coercion if you want to preserve exact user input.

**`tonumber` on leading-zero strings.** `tonumber("007")` returns `7`. If a user types `007` expecting to store the string `"007"`, both the old and new code will store the integer `7`. This is pre-existing behaviour, not introduced by this refactor.

### rename.lua

**Trailing newline fidelity.** The `content:gmatch("([^\n]*)\n?")` iterator produces a trailing empty string for files that end in `\n`. When reconstructing via `table.concat(lines, "\n")`, this trailing empty string becomes a trailing `\n`, which is correct. Files that do not end in `\n` will not get a spurious trailing newline added. Verify this with a test file that has no trailing newline.

**Content mutated between collect and apply.** The refactored flow writes collected content that was snapshotted at collection time. If any other process modifies the vault between `collect_rename_changes` returning and `apply_rename_changes` writing, those external changes will be clobbered for files that had wikilink updates. This is an inherent race condition in the original code as well (just a smaller window), so it is acceptable.

**`write_file` failure handling.** The current `write_file` (lines 39-47) returns `false` on failure. The new `apply_rename_changes` checks this and excludes failed paths from `modified_files`, then returns a count that will differ from `info.link_count`. Ensure the caller's notification message remains accurate:

```lua
-- In M.rename:
local modified_files, link_count = apply_rename_changes(info)
vim.notify(
  "Renamed '" .. old_name .. "' -> '" .. name
    .. "' (" .. link_count .. " links in " .. #modified_files .. " files)",
  vim.log.levels.INFO
)
```

If some writes fail, `link_count` still reflects all found links but `#modified_files` will be under-counted. Consider reporting this discrepancy if `#modified_files < info.file_count`.

### tasks.lua

**`M.tasks` prompt change.** Previously `M.tasks()` used `prompt = "Vault tasks> "`. After the refactor it delegates to `M.tasks_by_state(" ")` which uses `prompt = "Vault tasks [ ]> "` (with a space character between the brackets). This is a minor cosmetic change. If you want the original prompt text, keep `M.tasks` as a direct `grep_tasks` call:

```lua
function M.tasks()
  grep_tasks("- \\[ \\]", "Vault tasks")
end
```

This is still DRY (the options table is no longer duplicated) while preserving the prompt text.

**`fzf` required at module level.** Moving `require("fzf-lua")` to the top of the file means fzf-lua is loaded when `tasks.lua` is first required, not lazily on first call. If fzf-lua itself does lazy setup this should be fine. If startup time is a concern, keep the `require` inside `grep_tasks`.

---

## Testing

### metaedit.lua

Open any markdown file with existing frontmatter.

1. `:VaultMetaEdit status "In Progress"` — confirm `status: In Progress` is written (no quotes).
2. `:VaultMetaEdit draft true` — confirm `draft: true` (boolean, not string).
3. `:VaultMetaEdit priority 3` — confirm `priority: 3` (number, not string).
4. `:VaultMetaEdit title hello` — confirm `title: hello`.
5. `<leader>vmf` → enter `status` → enter `Complete` — confirm field is updated.
6. `<leader>vmf` → enter `draft` → enter `false` — confirm `draft: false`.
7. `<leader>vmf` → enter `priority` → enter `42` — confirm `priority: 42`.
8. Open a file with no frontmatter, run `:VaultMetaEdit newfield value` — confirm frontmatter block is created.

### rename.lua

Setup: create a note `TestNote.md` and several other notes that contain `[[TestNote]]`.

1. Open `TestNote.md`. Run `:VaultRenamePreview RenamedNote` — confirm quickfix list shows all wikilink lines with before/after, no files are written.
2. After step 1, verify that `TestNote.md` still exists and no wikilinks have changed (dry-run only).
3. Run `:VaultRename RenamedNote` — confirm prompt shows correct link count, answer `y`.
4. Verify: `TestNote.md` no longer exists; `RenamedNote.md` exists; all `[[TestNote]]` references in other files are now `[[RenamedNote]]`; all `[[TestNote|alias]]` references are now `[[RenamedNote|alias]]`; all `[[TestNote#heading]]` references are now `[[RenamedNote#heading]]`.
5. Run `:VaultLinkCheck` (if available) to confirm no orphaned wikilinks remain.
6. Verify that open buffers pointing to updated files have been reloaded (no stale content).
7. Rename a note that has zero wikilinks referencing it — confirm the notify message says `0 links in 0 files` and the file rename still succeeds.

### tasks.lua

1. `:VaultTasks` — fzf picker opens, shows unchecked `- [ ]` tasks from vault markdown files.
2. `:VaultTasksAll` — picker shows tasks with any checkbox state.
3. `:VaultTasksByState x` — picker shows only `- [x]` completed tasks.
4. `:VaultTasksByState` (no argument) — defaults to space, same result as `:VaultTasks`.
5. `<leader>vxo` — same as `:VaultTasks`.
6. `<leader>vxa` — same as `:VaultTasksAll`.
7. `<leader>vxs` — presents state picker from `config.task_states`, selecting a state opens the filtered task view.
8. Confirm that `- [-]` (cancelled) tasks appear in `:VaultTasksByState -` and in `:VaultTasksAll` but not in `:VaultTasks`.

---

## Estimated Impact

| File | Lines removed | Lines added | Net |
|---|---|---|---|
| `metaedit.lua` | ~10 (two 5-line if/elseif blocks) | ~7 (helper + 2 call sites) | ~-3 |
| `rename.lua` | ~35 (entire `apply_rename_changes` body, second rg scan) | ~10 (file_writes accumulation, new apply body) | ~-25 |
| `tasks.lua` | ~20 (duplicate fzf.grep tables, M.tasks body) | ~8 (grep_tasks helper, delegating M.tasks) | ~-12 |
| **Total** | | | **~-40 lines** |

Beyond line count, the rename refactor eliminates a full vault scan and full file read pass on every confirmed rename, which is a meaningful performance improvement for large vaults.
