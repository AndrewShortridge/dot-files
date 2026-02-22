# Feature 03: `engine.is_vault_path()` / `engine.vault_relative()` / `engine.current_note_name()`

## Dependencies
- **None** — foundational utility.
- **Depended on by:** Many features use these path checks. Should be implemented early.

## Problem

### 3a: "Is this path in the vault?" — 7 files, 3 different approaches
- `vim.startswith(path, engine.vault_path)` — embed.lua:196, graph.lua:393, rename.lua:23, wikilinks.lua:523, frontmatter.lua:14
- `path:sub(1, #vault) == vault` — frecency.lua:98, breadcrumbs.lua:36
- `path:find(vault, 1, true) == 1` — pins.lua:20

### 3b: Vault-relative path computation — 5 files
- `path:sub(#vault + 2)` — pins.lua:24, frecency.lua:99, breadcrumbs.lua:38, graph.lua:63, calendar.lua:138

### 3c: `current_note_name()` — identical in 2 files
- `graph.lua:30-36` and `rename.lua:9-15` — character-for-character identical:
```lua
local function current_note_name()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then return nil end
  return vim.fn.fnamemodify(bufname, ":t:r")
end
```

## Files to Modify
1. `lua/andrew/vault/engine.lua` — Add `M.is_vault_path(path)`, `M.vault_relative(path)`, `M.current_note_name()`
2. `lua/andrew/vault/embed.lua` — Replace inline check (line ~196)
3. `lua/andrew/vault/graph.lua` — Replace inline check (~393) + `current_note_name` (~30-36) + relative path (~63)
4. `lua/andrew/vault/rename.lua` — Replace inline check (~23) + `current_note_name` (~9-15)
5. `lua/andrew/vault/wikilinks.lua` — Replace inline check (~523)
6. `lua/andrew/vault/frontmatter.lua` — Replace inline check (~14)
7. `lua/andrew/vault/frecency.lua` — Replace inline check (~98) + relative path (~99)
8. `lua/andrew/vault/breadcrumbs.lua` — Replace inline check (~36) + relative path (~38)
9. `lua/andrew/vault/pins.lua` — Replace inline check (~20) + relative path (~24)
10. `lua/andrew/vault/calendar.lua` — Replace relative path (~138)

## Implementation Steps

### Step 1: Add to engine.lua

```lua
--- Check if an absolute path is inside the current vault.
--- @param path string
--- @return boolean
function M.is_vault_path(path)
  return path ~= "" and vim.startswith(path, M.vault_path)
end

--- Convert an absolute path to a vault-relative path.
--- Returns nil if path is not inside the vault.
--- @param path string
--- @return string|nil
function M.vault_relative(path)
  if not M.is_vault_path(path) then return nil end
  return path:sub(#M.vault_path + 2)
end

--- Get the basename (without extension) of the current buffer.
--- Returns nil if buffer has no name.
--- @return string|nil
function M.current_note_name()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then return nil end
  return vim.fn.fnamemodify(bufname, ":t:r")
end
```

### Step 2: Update all consumers

**For `is_vault_path`:** Replace all three idioms with `engine.is_vault_path(path)`:
- `if not vim.startswith(path, engine.vault_path) then` → `if not engine.is_vault_path(path) then`
- `if path:sub(1, #vault) ~= vault then` → `if not engine.is_vault_path(path) then`
- `if path:find(vault, 1, true) ~= 1 then` → `if not engine.is_vault_path(path) then`

**For `vault_relative`:** Replace `path:sub(#vault + 2)` with `engine.vault_relative(path)`:
- pins.lua line 24, frecency.lua line 99, breadcrumbs.lua line 38, graph.lua line 63, calendar.lua line 138

**For `current_note_name`:** Delete local function in graph.lua (30-36) and rename.lua (9-15). Replace calls with `engine.current_note_name()`.

### Caveats
- `breadcrumbs.lua` line 38 does `:gsub("%.md$", "")` after getting the relative path. Keep that as a separate step: `engine.vault_relative(path):gsub("%.md$", "")`.
- `pins.lua` line 17 does `vim.fn.resolve(engine.vault_path)` before the check. Consider whether `engine.is_vault_path` should resolve symlinks. Recommend keeping it simple (no resolve) and let pins.lua do its own resolve if needed.

## Testing
- Verify all vault features work when editing a file inside the vault
- Verify no false positives when editing a non-vault file
- Verify `VaultGraph` and `VaultRename` still detect the current note name correctly

## Estimated Impact
- **Lines removed:** ~30
- **Lines added:** ~15
- **Net reduction:** ~15 lines, plus consistency (one approach instead of three)
