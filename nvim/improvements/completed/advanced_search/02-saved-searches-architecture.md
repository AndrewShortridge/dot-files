# Saved Searches Architecture

## Overview

`lua/andrew/vault/saved_searches.lua` (296 lines) provides persistent,
vault-scoped search storage with fzf-lua integration. Searches are stored as
JSON at the vault root.

## Dependencies

```lua
local engine = require("andrew.vault.engine")   -- json_store, run, input, select, fzf opts
local config = require("andrew.vault.config")   -- scopes, labels
-- Lazy: require("fzf-lua")
```

## Module-Level State

### `last_search`
```lua
local last_search = nil
-- Shape: { query: string, scope: string, type: string } | nil
```
Tracks most recently executed search. Set by `search.lua` via
`set_last_search()`. Used by `save_last()` for quick-save.

### `defaults`
Three built-in searches seeded when `.vault-searches.json` doesn't exist:
```lua
{
  { name = "Overdue tasks",    query = "\\[due:: .*\\].*\\[ \\]", scope = "all",     type = "grep" },
  { name = "Recent literature", query = "",                        scope = "library", type = "grep" },
  { name = "Open tasks",       query = "- \\[ \\]",               scope = "all",     type = "grep" },
}
```

### `store`
```lua
local store = engine.json_store(".vault-searches.json", defaults)
```
Returns `{ load(), save(data), path() }` -- JSON persistence scoped to current vault.

## JSON Schema: `.vault-searches.json`

```json
[
  {
    "name": "string (required, unique key for upsert)",
    "query": "string (ripgrep pattern, empty for live_grep)",
    "scope": "string (key from config.scopes: all|projects|areas|...)",
    "type": "string (grep|type)"
  }
]
```

## Scope Helpers

```lua
local function scope_to_glob(scope)
  -- config.scope_glob(scope) or "**/*.md"
end

local function scope_label(scope)
  -- config.scope_label(scope) or scope
end
```

## Execute Search Logic

### `execute_search(entry)` (private)

Sets `last_search = { query = entry.query, scope = entry.scope, type = entry.type }`
then dispatches by `entry.type`:

| Condition                | fzf-lua Call           | Pattern                      |
|--------------------------|------------------------|------------------------------|
| `type == "type"`         | `fzf.grep()`           | `^type:\s+` .. query         |
| `query == ""`            | `fzf.live_grep()`      | Interactive (user types)     |
| `query ~= ""`           | `fzf.grep()`           | Stored regex pattern         |

All calls use `engine.vault_fzf_opts()` with prompt `"Saved [name]"` or
`"Saved [name | scope_label]"` and `rg_base_opts(glob)`.

## Public API

### `M.save(name, query, scope, search_type)`
- Validates name is non-empty
- Creates entry `{ name, query, scope, type }`
- Loads current searches from store
- **Upsert by name**: replaces if name exists, appends if new
- Persists to JSON
- Notifies on success

### `M.list()`
- Loads all saved searches
- Returns early if empty (with notification)
- Builds display strings: `"name  [scope_label]  query"`
- Creates lookup map: `display_string -> entry`
- Opens fzf picker with `"Saved searches> "` prompt
- On selection: calls `execute_search(entry)`

### `M.delete(name)`
- Loads searches, filters out matching name
- Warns if not found
- Persists filtered list

### `M.pick_delete()`
- Extracts name list from saved searches
- Opens fzf picker with `"Delete saved search> "` prompt
- On selection: calls `M.delete(selected_name)`

### `M.save_last()`
- Checks `last_search` exists (warns if not)
- Uses `engine.run()` coroutine for async UI
- Prompts: `"Save search as: "`
- Calls `M.save(name, last_search.query, last_search.scope, last_search.type)`

### `M.set_last_search(query, scope, search_type)`
```lua
function M.set_last_search(query, scope, search_type)
  last_search = {
    query = query or "",
    scope = scope or "all",
    type = search_type or "grep",
  }
end
```
Called by `search.lua` after every search execution.

### `M.save_interactive()`
- Uses `engine.run()` coroutine
- Sequential prompts:
  1. `"Search name: "` via `engine.input()`
  2. `"Query pattern: "` via `engine.input()`
  3. `"Search scope"` via `engine.select()` from scope keys
  4. `"Search type"` via `engine.select()` from `{ "grep", "type" }`
- Returns early at any cancellation
- Calls `M.save(name, query, scope, search_type)`

## Commands & Keymaps

| Command              | Behavior                                     | Keymap       |
|----------------------|----------------------------------------------|--------------|
| `:VaultSearchSave [name]` | With arg: save last search as name. Without: prompt for name | -- |
| `:VaultSearchList`   | Open saved searches picker                   | `<leader>vfS`|
| `:VaultSearchDelete` | Open delete picker                           | --           |

## Integration Points

### From `search.lua` (tracking)
Every search function calls `track()` which calls `set_last_search()`:
- `search()`: `track("", "all", "grep")`
- `search_notes()`: `track("", "all", "grep")`
- `search_filtered()`: `track("", selected.key, "grep")`
- `search_by_type()`: `track(choice, "all", "type")`

### From `init.lua` (setup)
```lua
require("andrew.vault.saved_searches").setup()
```

## Changes Needed for Advanced Search

The spec proposes extending the saved search entry schema:

```lua
-- Current:  { name, query, scope, type }
-- Extended: { name, query, scope, type, advanced = true|nil }
```

When `entry.advanced == true`, `execute_search` dispatches to the advanced
search pipeline instead of plain ripgrep:

```lua
local function execute_search(entry)
  if entry.advanced then
    local search = require("andrew.vault.search")
    search.execute_advanced_query(entry.query)
    return
  end
  -- ... existing ripgrep-based execution ...
end
```

Additional changes:
- `save_interactive()` gains "advanced" as a search type option
- `save_last()` records whether last search was advanced
- `set_last_search()` accepts an optional `advanced` flag
