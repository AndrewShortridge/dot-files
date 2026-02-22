# Feature 14: Replace Hardcoded Directory Paths with `config.dirs`

## Dependencies
- **Feature 05** (config canonical values) — scopes use `config.dirs`, should be consistent
- **Depended on by:** Nothing

## Problem
`config.lua` defines canonical directory names:
```lua
M.dirs = {
  log = "Log", projects = "Projects", areas = "Areas",
  domains = "Domains", library = "Library", methods = "Methods",
  people = "People", inbox = "Inbox.md",
}
```

But many files hardcode these strings directly, meaning a change to `config.dirs` would not propagate:

### Offending locations:

**pickers.lua** (does not even require config!):
- Line 11: `engine.vault_path .. "/Projects"`
- Line 51: `engine.vault_path .. "/Projects"`
- Line 88: `engine.vault_path .. "/Areas"`
- Line 109: `engine.vault_path .. "/Domains"`
- Line 146: `vault_path .. "/Projects"`
- Line 193: `vault_path .. "/Projects/"`

**capture.lua:**
- Line 125: `"Log/" .. date .. ".md"` — should use `config.dirs.log`
- Line 146: `"Inbox.md"` — should use `config.dirs.inbox`

**quicktask.lua:**
- Line 123: `"Projects/" .. project .. "/tasks/" .. slug`
- Line 126: `"Log/tasks/" .. slug`

**autofile.lua** (lines 7-15, `type_map`):
- Hardcodes `"Log"`, `"Log/journal"`, `"Log/tasks"`, `"Library"`, `"Methods"`, `"People"`, `"Domains"`, `"Projects"`, `"Areas"` — while `get_expected_dir` (lines 45-57) correctly uses `config.dirs`

**templates/daily_log.lua:**
- Line 144: `e.write_note("Log/" .. date, content)`

**templates/task.lua:**
- Line 63: `e.write_note("Projects/" .. project .. "/Tasks/" .. title, ...)`

**templates/meeting.lua:**
- Line 84: `dest = "Projects/" .. project .. "/Meetings/" .. title`

**templates/concept.lua:**
- Line 90: `e.write_note("Domains/" .. domain .. "/" .. title, ...)`

**templates/literature.lua** (likely):
- Hardcodes `"Library/"` path

## Files to Modify
1. `lua/andrew/vault/pickers.lua` — Add `require("andrew.vault.config")`, replace 6 hardcoded paths
2. `lua/andrew/vault/capture.lua` — Replace 2 hardcoded paths
3. `lua/andrew/vault/quicktask.lua` — Replace 2 hardcoded paths
4. `lua/andrew/vault/autofile.lua` — Rebuild `type_map` using `config.dirs`
5. `lua/andrew/vault/templates/daily_log.lua` — Replace hardcoded `"Log/"`
6. `lua/andrew/vault/templates/task.lua` — Replace hardcoded `"Projects/"`
7. `lua/andrew/vault/templates/meeting.lua` — Replace hardcoded `"Projects/"`
8. `lua/andrew/vault/templates/concept.lua` — Replace hardcoded `"Domains/"`
9. Any other templates with hardcoded paths (check literature.lua, simulation.lua, etc.)

## Implementation Steps

### Step 1: Update pickers.lua

Add at top:
```lua
local config = require("andrew.vault.config")
```

Replace all hardcoded paths:
```lua
-- Before:
local projects_dir = engine.vault_path .. "/Projects"
-- After:
local projects_dir = engine.vault_path .. "/" .. config.dirs.projects

-- Before:
local areas_dir = engine.vault_path .. "/Areas"
-- After:
local areas_dir = engine.vault_path .. "/" .. config.dirs.areas

-- Before:
local domains_dir = engine.vault_path .. "/Domains"
-- After:
local domains_dir = engine.vault_path .. "/" .. config.dirs.domains
```

### Step 2: Update capture.lua

```lua
-- Before (line 125):
local rel_path = "Log/" .. date .. ".md"
-- After:
local rel_path = config.dirs.log .. "/" .. date .. ".md"

-- Before (line 146):
local rel_path = "Inbox.md"
-- After:
local rel_path = config.dirs.inbox
```

### Step 3: Update quicktask.lua

```lua
-- Before (line 123):
rel_path = "Projects/" .. project .. "/tasks/" .. slug
-- After:
rel_path = config.dirs.projects .. "/" .. project .. "/tasks/" .. slug

-- Before (line 126):
rel_path = "Log/tasks/" .. slug
-- After:
rel_path = config.dirs.log .. "/tasks/" .. slug
```

### Step 4: Rebuild autofile.lua type_map

```lua
-- Before (lines 7-15):
M.type_map = {
  ["log"] = "Log",
  ["journal"] = "Log/journal",
  ["task"] = "Log/tasks",
  ["literature"] = "Library",
  ...
}

-- After:
local config = require("andrew.vault.config")
local d = config.dirs

M.type_map = {
  ["log"] = d.log,
  ["journal"] = d.log .. "/journal",
  ["task"] = d.log .. "/tasks",
  ["literature"] = d.library,
  ["methodology"] = d.methods,
  ["person"] = d.people,
  ["meeting"] = d.log,
  ["simulation"] = d.log,
  ["analysis"] = d.log,
  ["finding"] = d.log,
  ["concept"] = d.domains,
  ["domain-moc"] = d.domains,
  ["project-dashboard"] = d.projects,
  ["area-dashboard"] = d.areas,
}
```

### Step 5: Update templates

Each template that constructs a path should use `config.dirs`:

```lua
local config = require("andrew.vault.config")

-- daily_log.lua:
e.write_note(config.dirs.log .. "/" .. date, content)

-- task.lua:
e.write_note(config.dirs.projects .. "/" .. project .. "/Tasks/" .. title, ...)

-- meeting.lua:
dest = config.dirs.projects .. "/" .. project .. "/Meetings/" .. title

-- concept.lua:
e.write_note(config.dirs.domains .. "/" .. domain .. "/" .. title, ...)
```

### Step 6: Verify all templates

Run this grep to find any remaining hardcoded directory names in templates:
```
rg '"(Projects|Log|Domains|Library|Areas|Methods|People)/' lua/andrew/vault/templates/
```

Fix any additional occurrences found.

## Testing
- `VaultNew` with each template type — verify notes created in correct directories
- `VaultDaily` — verify daily log goes to Log/ directory
- `VaultCapture` — verify capture appends to correct daily log path
- `VaultCaptureInbox` — verify appends to Inbox.md
- `VaultQuickTask` — verify task note created in correct project/log directory
- `VaultAutoFile` — verify suggested directory matches actual type_map
- `VaultStickyProject` — verify project picker lists projects from correct directory
- Picker commands for Areas and Domains — verify they search correct paths

## Estimated Impact
- **Lines changed:** ~25 (simple substitutions)
- **Lines added:** ~5 (require statements)
- **Benefit:** If the user ever changes their vault directory structure, only `config.dirs` needs updating
