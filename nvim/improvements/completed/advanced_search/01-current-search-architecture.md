# Current Search Architecture

## Overview

The vault search system is a thin wrapper around fzf-lua's ripgrep integration,
providing four search modes with tracking for the saved search feature. Total
implementation: ~114 lines in `search.lua`.

## Module: `lua/andrew/vault/search.lua`

### Dependencies

```lua
local engine = require("andrew.vault.engine")   -- vault path, fzf opts, rg opts
local config = require("andrew.vault.config")   -- scopes, note_types
-- Lazy requires (inside functions to avoid circular deps):
--   require("fzf-lua")
--   require("andrew.vault.saved_searches")
```

### Private: `track(query, scope, search_type)`

Records search metadata for the quick-save feature. Calls
`saved_searches.set_last_search()` lazily to avoid circular dependency at load
time.

```lua
local function track(query, scope, search_type)
  require("andrew.vault.saved_searches").set_last_search(query, scope, search_type)
end
```

### Public Functions

#### `M.search()` -- Full Vault Grep

```lua
function M.search()
  track("", "all", "grep")
  require("fzf-lua").live_grep(engine.vault_fzf_opts("Vault search"))
end
```

- Uses `live_grep` (interactive: user types query in fzf)
- Searches all files in vault (no glob restriction by default)
- Tracks empty query, scope "all", type "grep"

#### `M.search_notes()` -- Markdown-Only Grep

```lua
function M.search_notes()
  track("", "all", "grep")
  require("fzf-lua").live_grep(engine.vault_fzf_opts("Vault notes", {
    rg_opts = engine.rg_base_opts(),  -- adds --glob "*.md"
  }))
end
```

- Same as `search()` but restricted to `*.md` files via `rg_base_opts()`
- Uses `live_grep` for interactive search

#### `M.search_filtered()` -- Scoped Grep

```lua
function M.search_filtered()
  -- 1. Build label list from config.scopes
  -- 2. vim.ui.select(labels, ...) to pick scope
  -- 3. Find selected scope config by label match
  -- 4. track("", selected.key, "grep")
  -- 5. fzf.live_grep with rg_base_opts(selected.glob)
end
```

- Two-step flow: first select scope, then type query in fzf
- Scopes come from `config.scopes` (8 entries: all, projects, areas, log, etc.)
- Each scope maps to a glob pattern (e.g., `Projects/**/*.md`)

#### `M.search_by_type()` -- Frontmatter Type Search

```lua
function M.search_by_type()
  -- 1. vim.ui.select(config.note_types, ...) to pick type
  -- 2. track(choice, "all", "type")
  -- 3. fzf.grep with search = "^type:\\s+" .. choice
end
```

- Uses `fzf.grep()` (fixed pattern, not interactive)
- Pattern `^type:\s+meeting` matches YAML frontmatter
- `no_esc = true` allows regex in the search pattern
- Tracks chosen type as query, type "type"

### Commands & Keymaps (registered in `M.setup()`)

| Command              | Function           | Keymap       | Mnemonic              |
|----------------------|--------------------|--------------|-----------------------|
| `:VaultSearch`       | `M.search()`       | `<leader>vfs`| vault find search     |
| `:VaultSearchNotes`  | `M.search_notes()` | `<leader>vfn`| vault find notes      |
| `:VaultSearchFiltered`| `M.search_filtered()`| `<leader>vfD`| vault find Directory |
| `:VaultSearchType`   | `M.search_by_type()`| `<leader>vfy`| vault find tYpe      |

### Data Flow

```
User triggers search
        |
        v
  track(query, scope, type)
        |
        v
  saved_searches.set_last_search(...)  --> stores in module-level last_search
        |
        v
  fzf-lua.live_grep() or fzf-lua.grep()
        |
        v
  ripgrep runs with:
    cwd = vault_path
    rg_opts = --column --line-number --no-heading --color=always --smart-case --glob "*.md"
        |
        v
  User selects result --> file opens at matched line
```

## Module: `lua/andrew/vault/engine.lua` (Search Helpers)

### `engine.rg_base_opts(glob)`

```lua
function M.rg_base_opts(glob)
  glob = glob or "*.md"
  return '--column --line-number --no-heading --color=always --smart-case --glob "' .. glob .. '"'
end
```

Returns ripgrep CLI flags as a single string. The `--smart-case` flag provides
case-insensitive search unless the query contains uppercase characters.

### `engine.vault_fzf_opts(prompt, extra)`

```lua
function M.vault_fzf_opts(prompt, extra)
  local opts = {
    cwd = M.vault_path,
    prompt = prompt .. "> ",
    file_icons = true,
    git_icons = false,
  }
  if extra then
    for k, v in pairs(extra) do opts[k] = v end
  end
  return opts
end
```

Standard fzf-lua options builder. The `extra` table is shallow-merged, allowing
callers to override or add options like `rg_opts`, `search`, `no_esc`,
`previewer`, `actions`, `fzf_opts`.

### `engine.vault_fzf_actions()`

```lua
function M.vault_fzf_actions()
  local fzf = require("fzf-lua")
  return {
    ["default"] = fzf.actions.file_edit,   -- Enter: open file
    ["ctrl-s"]  = fzf.actions.file_split,  -- Ctrl-S: horizontal split
    ["ctrl-v"]  = fzf.actions.file_vsplit, -- Ctrl-V: vertical split
    ["ctrl-t"]  = fzf.actions.file_tabedit,-- Ctrl-T: new tab
  }
end
```

### Other Reusable Helpers

| Helper                | Purpose                                           |
|-----------------------|---------------------------------------------------|
| `engine.run(fn)`      | Coroutine wrapper for async UI flows              |
| `engine.input(opts)`  | Yields in coroutine, resumes with vim.ui.input    |
| `engine.select(items, opts)` | Yields in coroutine, resumes with vim.ui.select |
| `engine.json_store(filename, defaults)` | JSON persistence at vault root   |
| `engine.vault_path`   | Current vault root directory                      |
| `engine.is_vault_path(path)` | Check if path is inside vault              |
| `engine.vault_relative(path)` | Convert absolute to vault-relative path  |

## fzf-lua Integration Patterns Used in Codebase

### Pattern 1: Live Grep (Interactive)
```lua
fzf.live_grep(engine.vault_fzf_opts("Prompt", { rg_opts = ... }))
```
Used by: `search()`, `search_notes()`, `search_filtered()`, saved searches (empty query)

### Pattern 2: Fixed Pattern Grep
```lua
fzf.grep(engine.vault_fzf_opts("Prompt", {
  search = "regex_pattern",
  no_esc = true,
  rg_opts = engine.rg_base_opts(glob),
}))
```
Used by: `search_by_type()`, backlinks, tags, saved searches (non-empty query)

### Pattern 3: Custom Entry List
```lua
fzf.fzf_exec(entries_array, {
  prompt = "Prompt> ",
  actions = { ["default"] = function(selected) ... end },
})
```
Used by: saved searches picker, tags picker, outline, footnotes, pickers

### Pattern 4: Command-Based Entry Generation
```lua
fzf.fzf_exec("fd --type f --extension md ...", engine.vault_fzf_opts("Prompt", {
  actions = engine.vault_fzf_actions(),
}))
```
Used by: tag management (multi-select file picker)

### Pattern 5: Formatted Entries with Lookup Table
```lua
local entries, lookup = {}, {}
for _, item in ipairs(items) do
  local display = format(item)
  entries[#entries + 1] = display
  lookup[display] = item
end
fzf.fzf_exec(entries, {
  actions = { ["default"] = function(sel) process(lookup[sel[1]]) end },
})
```
Used by: saved searches list, breadcrumbs, connections

### Not Yet Used (Needed for Advanced Search)

**`fzf.fzf_live()` with function provider:**
```lua
fzf.fzf_live(function(query)
  -- Called on each keystroke with current query text
  -- Return command string or entry array
  return results
end, opts)
```
This pattern is not used anywhere in the current codebase but is required for
the live advanced search mode.

**`--files-from` with ripgrep:**
No existing usage. Advanced search needs this to restrict ripgrep to
metadata-matched files.

## Limitations

1. **No boolean logic** -- Cannot express `meeting AND urgent`
2. **No metadata filtering** -- Cannot filter by frontmatter fields except `type`
3. **No date range queries** -- Cannot find notes modified in last 7 days
4. **No field-aware search** -- Cannot filter by inline field values
5. **Saved searches are text-only** -- Cannot persist structured queries
6. **No query composition** -- Each search function is a separate entry point
