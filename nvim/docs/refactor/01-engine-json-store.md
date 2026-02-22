# Feature 01: `engine.json_store(filename)`

## Dependencies
- **None** — this is a foundational utility with no prerequisites.
- **Depended on by:** Feature 06 (config.scopes) indirectly, any future JSON-persisted state.

## Problem
Three modules independently implement identical JSON load/save logic:
- `lua/andrew/vault/frecency.lua` (lines 24-62) — `.vault-frecency.json`
- `lua/andrew/vault/saved_searches.lua` (lines 72-113) — `.vault-searches.json`
- `lua/andrew/vault/pins.lua` (lines 7-56) — `.vault-pins.json`

Each has:
- A `*_path()` function returning `engine.vault_path .. "/.vault-<name>.json"`
- A `load_*()` function: `io.open → read("*a") → pcall(vim.json.decode) → fallback to {}`
- A `save_*()` function: `io.open("w") → vim.json.encode → write → close`

The code is character-for-character identical except for variable names and the JSON filename.

## Files to Modify
1. `lua/andrew/vault/engine.lua` — Add `M.json_store(filename)` factory function
2. `lua/andrew/vault/frecency.lua` — Replace `db_path`, `load_db`, `save_db` with store instance
3. `lua/andrew/vault/saved_searches.lua` — Replace `storage_path`, `load_searches`, `save_searches`
4. `lua/andrew/vault/pins.lua` — Replace `pins_path`, `load_pins`, `save_pins`

## Implementation Steps

### Step 1: Add `M.json_store()` to engine.lua

Add this function to `lua/andrew/vault/engine.lua` (after the existing utility functions, around line 120):

```lua
--- Create a JSON-backed persistent store scoped to the current vault.
--- @param filename string  The filename (e.g. ".vault-frecency.json")
--- @param defaults? table  Default value when file missing/corrupt
--- @return { load: fun(): table, save: fun(data: table), path: fun(): string }
function M.json_store(filename, defaults)
  defaults = defaults or {}

  local function path()
    return M.vault_path .. "/" .. filename
  end

  local function load()
    local file = io.open(path(), "r")
    if not file then return vim.deepcopy(defaults) end
    local raw = file:read("*a")
    file:close()
    if raw == "" then return vim.deepcopy(defaults) end
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then return vim.deepcopy(defaults) end
    return decoded
  end

  local function save(data)
    local file = io.open(path(), "w")
    if not file then
      vim.notify("Vault: failed to write " .. path(), vim.log.levels.WARN)
      return
    end
    file:write(vim.json.encode(data))
    file:close()
  end

  return { load = load, save = save, path = path }
end
```

### Step 2: Refactor frecency.lua

Replace lines 24-62 (the `db_path`, `load_db`, `save_db` functions) with:

```lua
local store = engine.json_store(".vault-frecency.json")

-- Replace all calls to load_db() with store.load()
-- Replace all calls to save_db(data) with store.save(data)
-- Replace all calls to db_path() with store.path()
```

Keep the module-level `_db` cache variable if frecency needs in-memory caching between calls — just initialize it from `store.load()`.

### Step 3: Refactor saved_searches.lua

Replace lines 72-113 with:

```lua
local store = engine.json_store(".vault-searches.json", defaults)
-- defaults is the existing `defaults` table at line 10-70

-- Replace load_searches() → store.load()
-- Replace save_searches(data) → store.save(data)
-- Replace storage_path() → store.path()
```

Note: `saved_searches.lua` has a special "seed defaults" behavior when the file does not exist (lines 83-89). The `defaults` parameter to `json_store` handles this — pass the defaults table as the second argument.

### Step 4: Refactor pins.lua

Replace lines 7-56 with:

```lua
local store = engine.json_store(".vault-pins.json")

-- Replace load_pins() → store.load()
-- Replace save_pins(data) → store.save(data)
-- Replace pins_path() → store.path()
```

## Testing
- Open Neovim, pin a note (`VaultPin`), close and reopen — verify pin persists
- Access frecency file picker (`VaultFiles`) — verify frecency data loads
- Save a search (`VaultSearchSave`), close and reopen — verify it persists
- Switch vaults (`VaultSwitch`) — verify each vault has its own JSON files
- Test with missing JSON files (delete them) — verify graceful fallback to defaults

## Estimated Impact
- **Lines removed:** ~80
- **Lines added:** ~25
- **Net reduction:** ~55 lines
