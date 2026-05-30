# Saved Search Integration

## Overview

The saved searches module (`saved_searches.lua`) needs minimal changes to
support advanced search queries. The key change is adding an `advanced` flag
to the entry schema and dispatching accordingly.

## Schema Change

### Current Entry Schema
```json
{
  "name": "string",
  "query": "string (ripgrep pattern)",
  "scope": "string (scope key)",
  "type": "string (grep|type)"
}
```

### Extended Entry Schema
```json
{
  "name": "string",
  "query": "string (raw query string for advanced, ripgrep pattern for grep)",
  "scope": "string (scope key)",
  "type": "string (grep|type)",
  "advanced": true
}
```

The `advanced` field is optional (nil for existing entries). When `true`,
the query string is parsed by the search query parser instead of being
passed directly to ripgrep.

## Execute Search Changes

### Current Dispatch
```lua
local function execute_search(entry)
  last_search = { query = entry.query, scope = entry.scope, type = entry.type }
  local fzf = require("fzf-lua")
  local glob = scope_to_glob(entry.scope)
  local label = scope_label(entry.scope)

  if entry.type == "type" then
    fzf.grep(engine.vault_fzf_opts("Saved [" .. entry.name .. "]", {
      search = "^type:\\s+" .. entry.query,
      no_esc = true,
      rg_opts = engine.rg_base_opts(glob),
    }))
  elseif entry.query == "" then
    fzf.live_grep(engine.vault_fzf_opts("Saved [" .. entry.name .. " | " .. label .. "]", {
      rg_opts = engine.rg_base_opts(glob),
    }))
  else
    fzf.grep(engine.vault_fzf_opts("Saved [" .. entry.name .. "]", {
      search = entry.query,
      no_esc = true,
      rg_opts = engine.rg_base_opts(glob),
    }))
  end
end
```

### New Dispatch (with advanced support)
```lua
local function execute_search(entry)
  last_search = {
    query = entry.query,
    scope = entry.scope,
    type = entry.type,
    advanced = entry.advanced or false,
  }

  -- Advanced search: dispatch to search module
  if entry.advanced then
    local search = require("andrew.vault.search")
    search.execute_advanced_query(entry.query)
    return
  end

  -- ... existing ripgrep-based execution unchanged ...
end
```

## set_last_search Changes

### Current
```lua
function M.set_last_search(query, scope, search_type)
  last_search = {
    query = query or "",
    scope = scope or "all",
    type = search_type or "grep",
  }
end
```

### Extended
```lua
function M.set_last_search(query, scope, search_type, advanced)
  last_search = {
    query = query or "",
    scope = scope or "all",
    type = search_type or "grep",
    advanced = advanced or false,
  }
end
```

## save Changes

### Current
```lua
function M.save(name, query, scope, search_type)
  local entry = { name = name, query = query, scope = scope, type = search_type }
  -- ...
end
```

### Extended
```lua
function M.save(name, query, scope, search_type, advanced)
  local entry = {
    name = name,
    query = query,
    scope = scope,
    type = search_type,
    advanced = advanced or nil,  -- omit from JSON when false
  }
  -- ...
end
```

## save_last Changes

```lua
function M.save_last()
  if not last_search then
    vim.notify("No recent search to save", vim.log.levels.WARN)
    return
  end

  engine.run(function()
    local name = engine.input({ prompt = "Save search as: " })
    if not name or name == "" then return end
    M.save(name, last_search.query, last_search.scope, last_search.type, last_search.advanced)
  end)
end
```

## save_interactive Changes

```lua
function M.save_interactive()
  engine.run(function()
    local name = engine.input({ prompt = "Search name: " })
    if not name or name == "" then return end

    local query = engine.input({ prompt = "Query pattern: " })
    if not query then return end

    local scope = engine.select(scope_keys(), { prompt = "Search scope" })
    if not scope then return end

    -- Extended: offer "advanced" as a search type option
    local search_type = engine.select(
      { "grep", "type", "advanced" },
      { prompt = "Search type" }
    )
    if not search_type then return end

    local advanced = search_type == "advanced"
    if advanced then search_type = "grep" end  -- normalize type field

    M.save(name, query, scope, search_type, advanced)
  end)
end
```

## Display Changes in `list()`

Advanced searches are visually distinguished in the picker:

```lua
function M.list()
  local searches = store.load()
  if #searches == 0 then
    vim.notify("No saved searches", vim.log.levels.INFO)
    return
  end

  local entries = {}
  local lookup = {}
  for _, s in ipairs(searches) do
    local prefix = s.advanced and "[ADV] " or ""
    local display = prefix .. s.name
      .. "  [" .. scope_label(s.scope) .. "]"
      .. (s.query ~= "" and ("  " .. s.query) or "")
    entries[#entries + 1] = display
    lookup[display] = s
  end

  -- ... fzf picker as before ...
end
```

## Backward Compatibility

- Existing `.vault-searches.json` files have no `advanced` field
- When loading, `entry.advanced` is `nil` (falsy) → existing dispatch works
- New advanced entries add `"advanced": true` to JSON
- Old saved searches continue to work without modification
- The `advanced` field is only written when true (nil/omitted when false)

## search.lua Tracking Changes

### Current tracking call
```lua
local function track(query, scope, search_type)
  require("andrew.vault.saved_searches").set_last_search(query, scope, search_type)
end
```

### Extended tracking for advanced search
```lua
local function track(query, scope, search_type, advanced)
  require("andrew.vault.saved_searches").set_last_search(query, scope, search_type, advanced)
end
```

Called in new functions:
```lua
function M.search_advanced()
  -- ... after query execution ...
  track(query_string, "all", "grep", true)
end
```

## JSON Examples

### Existing saved search (unchanged)
```json
{
  "name": "Open tasks",
  "query": "- \\[ \\]",
  "scope": "all",
  "type": "grep"
}
```

### New advanced saved search
```json
{
  "name": "Active meetings",
  "query": "type:meeting tag:active modified:>30d",
  "scope": "all",
  "type": "grep",
  "advanced": true
}
```

### Mixed file with both types
```json
[
  {
    "name": "Open tasks",
    "query": "- \\[ \\]",
    "scope": "all",
    "type": "grep"
  },
  {
    "name": "Active meetings",
    "query": "type:meeting tag:active modified:>30d",
    "scope": "all",
    "type": "grep",
    "advanced": true
  },
  {
    "name": "Priority items",
    "query": "priority:>3 -tag:archived",
    "scope": "projects",
    "type": "grep",
    "advanced": true
  }
]
```

## Design Decision: Raw Query String Storage

Advanced queries are stored as the raw query string, not the serialized AST.
Reasons:
1. **Human-readable**: Users can read and edit the JSON file
2. **Forward-compatible**: If query syntax evolves, old queries are re-parsed
3. **Compact**: Query strings are shorter than AST JSON
4. **Debuggable**: Easy to copy/paste query strings for testing
