# Feature 08: Consolidate Wikilink-Under-Cursor + `resolve_link` Imports

## Dependencies
- **Feature 06** (link_utils module must exist)
- **Depended on by:** Nothing directly, but improves consistency

## Problem

### 8a: Wikilink-under-cursor — 3 copies
- `wikilinks.lua:95-120` (`get_wikilink_under_cursor`) — returns name only
- `wikilinks.lua:125-174` (`get_wikilink_details_under_cursor`) — superset, returns {name, heading, block_id, alias}
- `preview.lua:60-81` (`get_wikilink_under_cursor`) — copy-pasted from the first, slightly different regex (`"^([^|#]+)"` vs `"^([^|#%^]+)"`)

The first function in wikilinks.lua is completely redundant — it's a subset of the second. preview.lua has its own copy instead of importing.

### 8b: resolve_link — 3 implementations, only 1 used
- `wikilinks.lua:199-230` (`resolve_link`) — **exported** at line 531, cached, alias-aware, proximity disambiguation
- `backlinks.lua:13-25` (`resolve_link`) — simple direct-path + `vim.fs.find`, NOT imported from wikilinks
- `preview.lua:86-100` (`resolve_link`) — character-for-character identical to backlinks.lua, NOT imported from wikilinks

Both backlinks.lua and preview.lua reimplement a simpler (and less capable) version of what wikilinks.lua already exports.

## Files to Modify
1. `lua/andrew/vault/link_utils.lua` — Move `get_wikilink_under_cursor` here (or keep in wikilinks.lua and export)
2. `lua/andrew/vault/wikilinks.lua` — Remove redundant `get_wikilink_under_cursor` (lines 95-120), keep only the `_details` version
3. `lua/andrew/vault/preview.lua` — Delete local `get_wikilink_under_cursor` (lines 60-81) and `resolve_link` (lines 86-100); import from wikilinks
4. `lua/andrew/vault/backlinks.lua` — Delete local `resolve_link` (lines 13-25); import from wikilinks

## Implementation Steps

### Step 1: Move cursor extraction to link_utils.lua

Add to `link_utils.lua`:

```lua
--- Get the wikilink target under the cursor.
--- Returns nil if cursor is not on a wikilink.
--- @return { name: string, heading: string|nil, block_id: string|nil, alias: string|nil }|nil
function M.get_wikilink_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  local start = 1
  while true do
    local open_start, open_end = line:find("%[%[", start)
    if not open_start then return nil end
    local close_start, close_end = line:find("%]%]", open_end + 1)
    if not close_start then return nil end

    if col >= open_start and col <= close_end then
      local inner = line:sub(open_end + 1, close_start - 1)
      return M.parse_target(inner)
    end

    start = close_end + 1
  end
end
```

This replaces both `get_wikilink_under_cursor` (name-only) and `get_wikilink_details_under_cursor` (full parse) with a single function that returns the full parse result. Callers that only need the name can use `.name`.

### Step 2: Update wikilinks.lua

- Delete `get_wikilink_under_cursor` (lines 95-120)
- Replace `get_wikilink_details_under_cursor` (lines 125-174) with a thin wrapper or direct import:
```lua
local link_utils = require("andrew.vault.link_utils")

-- In follow_link and anywhere that called get_wikilink_details_under_cursor:
local details = link_utils.get_wikilink_under_cursor()
if not details then return end
```
- Keep `resolve_link` in wikilinks.lua (it has module-specific caching), continue exporting it

### Step 3: Update preview.lua

Delete both local functions (lines 60-100). Replace with imports:
```lua
local link_utils = require("andrew.vault.link_utils")
local wikilinks = require("andrew.vault.wikilinks")

-- In preview functions:
local details = link_utils.get_wikilink_under_cursor()
if not details then return end
local path = wikilinks.resolve_link(details.name)
```

### Step 4: Update backlinks.lua

Delete local `resolve_link` (lines 13-25). Import from wikilinks:
```lua
local wikilinks = require("andrew.vault.wikilinks")

-- Replace resolve_link(name) calls with:
local path = wikilinks.resolve_link(name)
```

Benefits: backlinks now gets alias-aware resolution and proximity disambiguation for free.

### Step 5: Also update embed.lua

`embed.lua:13-26` has `resolve_embed` which calls `wikilinks.resolve_link` then falls back to `vim.fs.find`. The fallback is probably unnecessary since wikilinks.resolve_link already does a thorough search. Verify and simplify:
```lua
-- Before:
local function resolve_embed(name)
  local path = wikilinks.resolve_link(name)
  if path then return path end
  local results = vim.fs.find(name .. ".md", { path = engine.vault_path, type = "file", limit = 1 })
  return results[1]
end

-- After (if wikilinks.resolve_link is comprehensive enough):
local resolve_embed = wikilinks.resolve_link
```

If the fallback is genuinely needed (e.g., for non-.md embeds), keep it but document why.

## Testing
- `gf` on `[[Note]]`, `[[Note#Heading]]`, `[[Note^block]]`, `[[Note|Alias]]` — all navigate correctly
- `K` on a wikilink (preview) — shows correct note preview
- `<leader>vE` on a wikilink — opens editable float for correct note
- `VaultBacklinks` — finds backlinks correctly (now with alias/proximity resolution)
- `VaultEmbedRender` — embeds resolve correctly

## Estimated Impact
- **Lines removed:** ~80
- **Lines added:** ~20
- **Net reduction:** ~60 lines
- **Bonus:** backlinks.lua and preview.lua now get alias-aware resolution for free
