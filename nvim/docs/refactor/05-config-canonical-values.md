# Feature 05: Canonical Value Lists and Scopes in `config.lua`

## Dependencies
- **None** — foundational configuration.
- **Depended on by:** Feature 20 (hardcoded directory paths)

## Problem

### 5a: Status/Priority/Maturity values are INCONSISTENT across files (BUG)

**metaedit.lua:286-288:**
```lua
local status_values = { "Not Started", "In Progress", "Blocked", "Complete", "Cancelled" }
local priority_values = { 1, 2, 3, 4, 5 }
local maturity_values = { "Seed", "Developing", "Mature", "Evergreen" }
```

**completion_frontmatter.lua:13-17:**
```lua
local known_values = {
  status = { "Active", "Complete", "On Hold", "Archived", "Draft", "In Progress" },
  priority = { "High", "Medium", "Low", "Critical", "None" },
}
```

These are **different lists** — `completion_frontmatter.lua` suggests statuses like "Active", "On Hold", "Archived" that `metaedit.lua` does not know about, and uses string priorities where metaedit uses numbers. Users get inconsistent completions vs cycle values.

Also hardcoded in templates:
- `templates/task.lua:9` — status list
- `templates/concept.lua:71` — maturity list
- `quicktask.lua:29` — `"status: Not Started"`, `"priority: 3"`

### 5b: Scope-to-glob mapping defined twice

**search.lua:37-43:**
```lua
local scopes = {
  { label = "All notes", glob = "**/*.md", key = "all" },
  { label = "Projects", glob = config.dirs.projects .. "/**/*.md", key = "projects" },
  ...
}
```

**saved_searches.lua:39-48 + 54-63:** Two separate tables (`scope_to_glob` and `scope_label`) that define the same mapping. saved_searches even includes "library" which search.lua is missing.

## Files to Modify
1. `lua/andrew/vault/config.lua` — Add `M.status_values`, `M.priority_values`, `M.maturity_values`, `M.priority_default`, `M.status_default`, `M.scopes`
2. `lua/andrew/vault/metaedit.lua` — Replace hardcoded lists (lines 286-288) with `config.*_values`
3. `lua/andrew/vault/completion_frontmatter.lua` — Replace `known_values` (lines 13-17) with config references
4. `lua/andrew/vault/templates/task.lua` — Reference `config.status_values`
5. `lua/andrew/vault/templates/concept.lua` — Reference `config.maturity_values`
6. `lua/andrew/vault/quicktask.lua` — Reference `config.status_default`, `config.priority_default`
7. `lua/andrew/vault/search.lua` — Replace local `scopes` (lines 37-43) with `config.scopes`
8. `lua/andrew/vault/saved_searches.lua` — Replace `scope_to_glob` and `scope_label` (lines 39-63) with `config.scopes`

## Implementation Steps

### Step 1: Add canonical values to config.lua

```lua
-- Canonical field value lists (single source of truth)
M.status_values = { "Not Started", "In Progress", "Blocked", "Complete", "Cancelled" }
M.status_default = "Not Started"

M.priority_values = { 1, 2, 3, 4, 5 }
M.priority_default = 3

M.maturity_values = { "Seed", "Developing", "Mature", "Evergreen" }

-- Vault search scopes
M.scopes = {
  { key = "all",      label = "All notes", glob = "**/*.md" },
  { key = "projects", label = "Projects",  glob = M.dirs.projects .. "/**/*.md" },
  { key = "areas",    label = "Areas",     glob = M.dirs.areas .. "/**/*.md" },
  { key = "log",      label = "Log",       glob = M.dirs.log .. "/**/*.md" },
  { key = "domains",  label = "Domains",   glob = M.dirs.domains .. "/**/*.md" },
  { key = "library",  label = "Library",   glob = M.dirs.library .. "/**/*.md" },
}

--- Helper: get scope glob by key
--- @param key string
--- @return string|nil
function M.scope_glob(key)
  for _, s in ipairs(M.scopes) do
    if s.key == key then return s.glob end
  end
  return nil
end

--- Helper: get scope label by key
--- @param key string
--- @return string|nil
function M.scope_label(key)
  for _, s in ipairs(M.scopes) do
    if s.key == key then return s.label end
  end
  return nil
end
```

### Step 2: Update metaedit.lua
Replace lines 286-288:
```lua
local status_values = config.status_values
local priority_values = config.priority_values
local maturity_values = config.maturity_values
```

### Step 3: Update completion_frontmatter.lua
Replace lines 13-17 `known_values`:
```lua
local known_values = {
  type = config.note_types,
  status = config.status_values,
  priority = vim.tbl_map(tostring, config.priority_values),
  maturity = config.maturity_values,
}
```
Note: completion needs string representations of priority values for display.

### Step 4: Update templates
- `templates/task.lua` — Replace hardcoded status list with `require("andrew.vault.config").status_values`
- `templates/concept.lua` — Replace hardcoded maturity list with `config.maturity_values`

### Step 5: Update quicktask.lua
```lua
"status: " .. config.status_default,
"priority: " .. config.priority_default,
```

### Step 6: Update search.lua
Replace local `scopes` table (lines 37-43) with `config.scopes`. The `search_filtered()` function builds a picker from this list — adjust to use `config.scopes` directly.

### Step 7: Update saved_searches.lua
Delete `scope_to_glob` (lines 39-48) and `scope_label` (lines 54-63). Replace with:
```lua
local function scope_to_glob(scope)
  return config.scope_glob(scope) or "**/*.md"
end

local function scope_label(scope)
  return config.scope_label(scope) or scope
end
```

## Testing
- `VaultMetaCycle` on status field — cycles through correct values
- Open a `.md` file, type `status: ` in frontmatter — completion shows matching values
- `VaultSearchFiltered` — shows all scopes including Library
- `VaultSearchSave` then `VaultSearchList` — saved search scopes resolve correctly
- Create a new task via template — has correct default status/priority
- `VaultQuickTask` — creates task with correct defaults

## Estimated Impact
- **Lines removed:** ~35
- **Lines added:** ~30
- **Fixes:** Status/priority inconsistency bug between metaedit and completion
- **Fixes:** Missing "library" scope in search.lua
