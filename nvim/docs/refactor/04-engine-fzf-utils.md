# Feature 04: `engine.rg_base_opts()` / `engine.vault_fzf_opts()` / `engine.vault_fzf_actions()`

## Dependencies
- **None** — foundational utility.
- **Depended on by:** Feature 06 (config.scopes), Feature 19 (tasks.lua dedup)

## Problem

### 4a: `rg_opts` string repeated 7+ times
The exact same ripgrep options string appears verbatim in 7 places across 3 files:
```lua
'--column --line-number --no-heading --color=always --smart-case --glob "*.md"'
```
- `search.lua:32,74,96`
- `tags.lua:115`
- `saved_searches.lua:138,147,158`
- `tasks.lua:13,30,44`

Some variants append `-e` or use a dynamic glob. The base string is always the same.

### 4b: fzf-lua base options block repeated 10+ times
```lua
{
  cwd = engine.vault_path,
  prompt = "...",
  file_icons = true,
  git_icons = false,
}
```
Appears in: search.lua (4x), tags.lua (1x), saved_searches.lua (3x), tasks.lua (3x), frecency.lua (2x), pins.lua (1x), navigate.lua (1x)

### 4c: fzf-lua file actions table repeated 5+ times
```lua
actions = {
  ["default"] = fzf.actions.file_edit,
  ["ctrl-s"] = fzf.actions.file_split,
  ["ctrl-v"] = fzf.actions.file_vsplit,
  ["ctrl-t"] = fzf.actions.file_tabedit,
}
```
Appears in: frecency.lua (2x), pins.lua (1x), navigate.lua (1x+)

## Files to Modify
1. `lua/andrew/vault/engine.lua` — Add constants and helper functions
2. `lua/andrew/vault/search.lua` — Use shared opts (4 call sites)
3. `lua/andrew/vault/tags.lua` — Use shared opts (1 call site)
4. `lua/andrew/vault/saved_searches.lua` — Use shared opts (3 call sites)
5. `lua/andrew/vault/tasks.lua` — Use shared opts (3 call sites)
6. `lua/andrew/vault/frecency.lua` — Use shared opts + actions (2 call sites)
7. `lua/andrew/vault/pins.lua` — Use shared opts + actions (1 call site)
8. `lua/andrew/vault/navigate.lua` — Use shared actions (1+ call sites)

## Implementation Steps

### Step 1: Add to engine.lua

```lua
--- Base ripgrep options for vault-wide searches.
--- @param glob? string  File glob pattern (default: "*.md")
--- @return string
function M.rg_base_opts(glob)
  glob = glob or "*.md"
  return '--column --line-number --no-heading --color=always --smart-case --glob "' .. glob .. '"'
end

--- Common fzf-lua options for vault pickers.
--- @param prompt string  The prompt text (without trailing "> ")
--- @param extra? table   Additional options to merge
--- @return table
function M.vault_fzf_opts(prompt, extra)
  local opts = {
    cwd = M.vault_path,
    prompt = prompt .. "> ",
    file_icons = true,
    git_icons = false,
  }
  if extra then
    for k, v in pairs(extra) do
      opts[k] = v
    end
  end
  return opts
end

--- Standard fzf-lua actions for file open/split/vsplit/tab.
--- @return table
function M.vault_fzf_actions()
  local fzf = require("fzf-lua")
  return {
    ["default"] = fzf.actions.file_edit,
    ["ctrl-s"] = fzf.actions.file_split,
    ["ctrl-v"] = fzf.actions.file_vsplit,
    ["ctrl-t"] = fzf.actions.file_tabedit,
  }
end
```

### Step 2: Update consumers

**Example transformation in search.lua:**

Before:
```lua
fzf.grep({
  cwd = engine.vault_path,
  prompt = "Vault search> ",
  file_icons = true,
  git_icons = false,
  rg_opts = '--column --line-number --no-heading --color=always --smart-case --glob "*.md"',
})
```

After:
```lua
fzf.grep(engine.vault_fzf_opts("Vault search", {
  rg_opts = engine.rg_base_opts(),
}))
```

**For tasks.lua** (which appends `-e` to rg_opts):
```lua
rg_opts = engine.rg_base_opts() .. " -e",
```

**For saved_searches.lua** (which uses dynamic glob):
```lua
rg_opts = engine.rg_base_opts(glob),
```

**For frecency.lua and pins.lua** (which use file actions):
```lua
actions = engine.vault_fzf_actions(),
```

## Testing
- `VaultSearch`, `VaultSearchNotes`, `VaultSearchFiltered`, `VaultSearchType` — all should work identically
- `VaultTags` — tag picker works
- `VaultTasks`, `VaultTasksAll`, `VaultTasksByState` — task grep works
- `VaultFiles`, `VaultRecent` — frecency picker works with split/vsplit/tab
- `VaultPins` — pin picker works
- `VaultSearchList` — saved searches work with dynamic globs

## Estimated Impact
- **Lines removed:** ~40
- **Lines added:** ~25
- **Net reduction:** ~15 lines, eliminates magic string duplication
