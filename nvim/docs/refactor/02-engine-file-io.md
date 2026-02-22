# Feature 02: `engine.read_file()` / `engine.write_file()` / `engine.append_file()`

## Dependencies
- **None** — foundational utility.
- **Depended on by:** Feature 09 (link_utils.read_heading_section / read_block_content), Feature 16 (frontmatter parsing consolidation)

## Problem
Raw `io.open` / `read` / `write` / `close` file I/O with error handling is repeated in 5+ locations:
- `export.lua:80-91` — `read_file()` returns lines array
- `rename.lua:29-37` — `read_file()` returns string
- `embed.lua:32-49` — `read_file_lines()` returns lines with optional max
- `capture.lua:84-98` — `ensure_file()` writes if not exists
- `capture.lua:109-118` — `append_bullet()` appends to file
- `engine.lua:149-155` — `write_note()` writes content
- `blockid.lua:153-173` — reads then appends

Each has slightly different error messages and return types but the same core pattern.

## Files to Modify
1. `lua/andrew/vault/engine.lua` — Add `M.read_file(path)`, `M.read_file_lines(path, max)`, `M.write_file(path, content)`, `M.append_file(path, content)`
2. `lua/andrew/vault/export.lua` — Replace local `read_file` (lines 80-91)
3. `lua/andrew/vault/rename.lua` — Replace local `read_file` (lines 29-37) and `write_file` (lines 39-47)
4. `lua/andrew/vault/embed.lua` — Replace local `read_file_lines` (lines 32-49)
5. `lua/andrew/vault/capture.lua` — Simplify `ensure_file` and `append_bullet` using engine helpers
6. `lua/andrew/vault/blockid.lua` — Replace inline io.open/read/write (lines 153-173)

## Implementation Steps

### Step 1: Add file I/O helpers to engine.lua

```lua
--- Read entire file as a string. Returns nil on failure.
--- @param path string
--- @return string|nil
function M.read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

--- Read file as an array of lines. Returns empty table on failure.
--- @param path string
--- @param max_lines? number  Optional limit on lines read
--- @return string[]
function M.read_file_lines(path, max_lines)
  local f = io.open(path, "r")
  if not f then return {} end
  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
    if max_lines and #lines >= max_lines then break end
  end
  f:close()
  return lines
end

--- Write content to file, creating parent dirs. Returns success boolean.
--- @param path string
--- @param content string
--- @return boolean
function M.write_file(path, content)
  local dir = vim.fn.fnamemodify(path, ":h")
  M.ensure_dir(dir)
  local file, err = io.open(path, "w")
  if not file then
    vim.notify("Vault: failed to write " .. path .. ": " .. (err or "unknown"), vim.log.levels.WARN)
    return false
  end
  file:write(content)
  file:close()
  return true
end

--- Append content to file. Returns success boolean.
--- @param path string
--- @param content string
--- @return boolean
function M.append_file(path, content)
  local file, err = io.open(path, "a")
  if not file then
    vim.notify("Vault: failed to append to " .. path .. ": " .. (err or "unknown"), vim.log.levels.WARN)
    return false
  end
  file:write(content)
  file:close()
  return true
end
```

### Step 2: Update consumers

In each file, replace the local `read_file` / `write_file` / inline I/O with calls to `engine.read_file()`, `engine.read_file_lines()`, `engine.write_file()`, or `engine.append_file()`.

**export.lua:** Replace lines 80-91 local `read_file`. Change callers from `read_file(path)` to `engine.read_file_lines(path)`.

**rename.lua:** Delete local `read_file` (29-37) and `write_file` (39-47). Replace with `engine.read_file(path)` and `engine.write_file(path, content)`.

**embed.lua:** Delete local `read_file_lines` (32-49). Replace with `engine.read_file_lines(path, max)`. Note: embed.lua returns `{"[Could not read file]"}` on failure — add a nil check after the call:
```lua
local lines = engine.read_file_lines(path, max)
if #lines == 0 then return { "[Could not read file]" } end
```

**capture.lua:** Simplify `ensure_file` — use `engine.write_file`. Simplify `append_bullet` — use `engine.append_file`.

**blockid.lua:** Replace inline io.open read/write at lines 153-173 with `engine.read_file` and `engine.write_file`.

## Testing
- `VaultExport` — verify PDF/docx/html export still works
- `VaultRename` — verify rename updates wikilinks across vault
- `VaultEmbedRender` — verify embed transclusion renders
- `VaultCapture` — verify quick capture appends to daily log
- `VaultBlockIdLink` — verify block reference appended to target

## Estimated Impact
- **Lines removed:** ~50
- **Lines added:** ~30
- **Net reduction:** ~20 lines, plus centralized error handling
