# Feature 16: Frontmatter Parsing Consolidation

## Dependencies
- **Feature 02** (engine.read_file / read_file_lines) — for file reading
- **Feature 06** (link_utils module exists) — optional, but the frontmatter parser could live in link_utils or a new module
- **Depended on by:** Nothing directly, but simplifies future frontmatter work

## Problem
There are **6+ independent frontmatter parsing implementations** across the vault module. Each re-implements the `---` delimiter detection and key-value extraction:

| File | Lines | What it does | Data source |
|---|---|---|---|
| `query/index.lua` | 386-455 | Most comprehensive: splits frontmatter, parses all fields, handles lists, scalars, booleans, dates, wikilinks | File content string |
| `metaedit.lua` | 59-98 (`find_frontmatter`) | Scans buffer for `---` delimiters, finds a specific field by name | Buffer lines (nvim API) |
| `frontmatter.lua` | 18-31 | Detects `---`, finds `modified:` field only | Buffer lines (nvim API) |
| `completion.lua` | 10-48 (`parse_frontmatter`) | Opens file, parses key-value pairs, handles lists and inline arrays | File I/O |
| `wikilinks.lua` | 13-52 (`read_aliases`) | Opens file, detects `---`, extracts `aliases` field (inline array + block list) | File I/O |
| `navigate.lua` | 98-129 (`read_frontmatter_field`) | Opens file, scans first 30 lines, extracts single field | File I/O |
| `autofile.lua` | 23-34 (`parse_frontmatter`) | Scans buffer lines, returns all key-value pairs | Buffer lines |
| `breadcrumbs.lua` | 9-18 (`buf_frontmatter`) | Scans buffer lines, returns single field value | Buffer lines |
| `completion_frontmatter.lua` | 24-46 (`in_frontmatter`) | Checks if cursor position is inside frontmatter | Buffer lines |

Additionally, YAML scalar parsing is duplicated between:
- `metaedit.lua:33-48` (`parse_value`) — booleans, numbers, quoted strings
- `query/index.lua:528-569` (`_parse_scalar`) — booleans, numbers, quoted strings, dates, wikilinks (superset)
- `completion_frontmatter.lua:101,119` — inline quote-stripping

## Strategy

Rather than trying to unify all 6+ parsers into one (they operate on different data sources — buffer lines vs file content vs file path), create **two shared parsers** that cover all use cases:

1. **`frontmatter.parse_buffer(bufnr, max_lines)`** — works on buffer lines, returns `{ start_line, end_line, fields }`. Used by: frontmatter.lua, metaedit.lua, autofile.lua, breadcrumbs.lua, completion_frontmatter.lua
2. **`frontmatter.parse_file(filepath, max_lines)`** — works on file content via I/O, returns `{ fields }`. Used by: completion.lua, wikilinks.lua, navigate.lua

Both delegate to a shared **`frontmatter.parse_lines(lines)`** that does the actual YAML-like parsing.

## Files to Modify
1. **CREATE** `lua/andrew/vault/frontmatter_parser.lua` — New shared parser (or extend existing `frontmatter.lua`)
2. `lua/andrew/vault/frontmatter.lua` — Use shared parser for `modified:` timestamp logic
3. `lua/andrew/vault/metaedit.lua` — Replace `find_frontmatter` (lines 59-98) with shared parser
4. `lua/andrew/vault/autofile.lua` — Replace `parse_frontmatter` (lines 23-34) with shared parser
5. `lua/andrew/vault/breadcrumbs.lua` — Replace `buf_frontmatter` (lines 9-18) with shared parser
6. `lua/andrew/vault/completion.lua` — Replace `parse_frontmatter` (lines 10-48) with shared parser
7. `lua/andrew/vault/wikilinks.lua` — Replace `read_aliases` (lines 13-52) with shared parser
8. `lua/andrew/vault/navigate.lua` — Replace `read_frontmatter_field` (lines 98-129) with shared parser
9. `lua/andrew/vault/completion_frontmatter.lua` — Use shared boundary detection for `in_frontmatter`

## Implementation Steps

### Step 1: Create `lua/andrew/vault/frontmatter_parser.lua`

```lua
local M = {}

local config = require("andrew.vault.config")

--- Parse a scalar YAML value string into a typed Lua value.
--- Handles: booleans, numbers, quoted strings, bare strings.
--- @param raw string
--- @return any
function M.parse_value(raw)
  if raw == nil or raw == "" then return "" end
  raw = vim.trim(raw)
  -- Booleans
  if raw == "true" then return true end
  if raw == "false" then return false end
  -- Numbers
  local num = tonumber(raw)
  if num then return num end
  -- Quoted strings (double or single)
  local dq = raw:match('^"(.*)"$')
  if dq then return dq end
  local sq = raw:match("^'(.*)'$")
  if sq then return sq end
  -- Wikilink
  local wl = raw:match("^%[%[(.-)%]%]$")
  if wl then return wl end
  -- Bare string
  return raw
end

--- Parse frontmatter from an array of lines.
--- Expects lines[1] == "---". Parses until closing "---".
--- @param lines string[]  Array of file/buffer lines
--- @param max_lines? number  Max lines to scan (default: config.frontmatter.max_scan_lines or 40)
--- @return { start_line: number, end_line: number, fields: table<string, any> }|nil
function M.parse_lines(lines, max_lines)
  max_lines = max_lines or (config.frontmatter and config.frontmatter.max_scan_lines) or 40
  if #lines == 0 or lines[1] ~= "---" then return nil end

  local fields = {}
  local current_key = nil
  local current_list = nil

  for i = 2, math.min(#lines, max_lines) do
    local line = lines[i]

    -- Closing delimiter
    if line == "---" or line == "..." then
      -- Flush any pending list
      if current_key and current_list then
        fields[current_key] = current_list
      end
      return { start_line = 1, end_line = i, fields = fields }
    end

    -- List item (indented "- value")
    local list_item = line:match("^%s+-%s+(.+)$")
    if list_item and current_key then
      if not current_list then current_list = {} end
      current_list[#current_list + 1] = M.parse_value(list_item)
      goto continue
    end

    -- Top-level key: value
    local key, val = line:match("^([%w_%-]+):%s*(.*)$")
    if key then
      -- Flush previous list
      if current_key and current_list then
        fields[current_key] = current_list
      end
      current_key = key
      current_list = nil

      val = vim.trim(val)
      if val == "" then
        -- Key with no inline value — expect block list below
        current_list = {}
      else
        -- Check for inline array [a, b, c]
        local inner = val:match("^%[(.*)%]$")
        if inner then
          local items = {}
          for item in inner:gmatch("[^,]+") do
            items[#items + 1] = M.parse_value(vim.trim(item))
          end
          fields[key] = items
          current_key = nil
        else
          fields[key] = M.parse_value(val)
          current_key = nil
        end
      end
    end

    ::continue::
  end

  -- Unclosed frontmatter — return nil
  return nil
end

--- Parse frontmatter from a buffer.
--- @param bufnr number  Buffer number
--- @param max_lines? number
--- @return { start_line: number, end_line: number, fields: table<string, any> }|nil
function M.parse_buffer(bufnr, max_lines)
  max_lines = max_lines or (config.frontmatter and config.frontmatter.max_scan_lines) or 40
  local n = math.min(vim.api.nvim_buf_line_count(bufnr), max_lines)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)
  return M.parse_lines(lines, max_lines)
end

--- Parse frontmatter from a file path.
--- @param filepath string  Absolute file path
--- @param max_lines? number
--- @return { start_line: number, end_line: number, fields: table<string, any> }|nil
function M.parse_file(filepath, max_lines)
  max_lines = max_lines or (config.frontmatter and config.frontmatter.max_scan_lines) or 40
  local f = io.open(filepath, "r")
  if not f then return nil end
  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
    if #lines >= max_lines then break end
  end
  f:close()
  return M.parse_lines(lines, max_lines)
end

--- Get a single field value from buffer frontmatter.
--- @param bufnr number
--- @param field string
--- @return any|nil
function M.buf_field(bufnr, field)
  local fm = M.parse_buffer(bufnr)
  return fm and fm.fields[field] or nil
end

--- Get a single field value from a file's frontmatter.
--- @param filepath string
--- @param field string
--- @return any|nil
function M.file_field(filepath, field)
  local fm = M.parse_file(filepath)
  return fm and fm.fields[field] or nil
end

--- Check if cursor is inside frontmatter in the given buffer.
--- @param bufnr number
--- @param row number  0-indexed row
--- @return boolean
function M.cursor_in_frontmatter(bufnr, row)
  local fm = M.parse_buffer(bufnr)
  if not fm then return false end
  return row >= fm.start_line - 1 and row <= fm.end_line - 1
end

return M
```

### Step 2: Update consumers

**breadcrumbs.lua** — Replace `buf_frontmatter` (lines 9-18):
```lua
local fm_parser = require("andrew.vault.frontmatter_parser")
-- Replace: buf_frontmatter(bufnr, "parent-project")
-- With:    fm_parser.buf_field(bufnr, "parent-project")
```

**navigate.lua** — Replace `read_frontmatter_field` (lines 98-129):
```lua
local fm_parser = require("andrew.vault.frontmatter_parser")
-- Replace: read_frontmatter_field(filepath, "date")
-- With:    fm_parser.file_field(filepath, "date")
```

**autofile.lua** — Replace `parse_frontmatter` (lines 23-34):
```lua
local fm_parser = require("andrew.vault.frontmatter_parser")
-- Replace: local fm = parse_frontmatter(bufnr)
-- With:    local result = fm_parser.parse_buffer(bufnr)
--          local fm = result and result.fields or {}
```

**wikilinks.lua** — Replace `read_aliases` (lines 13-52):
```lua
local fm_parser = require("andrew.vault.frontmatter_parser")
-- Replace: local aliases = read_aliases(path)
-- With:    local fm = fm_parser.parse_file(path)
--          local aliases = fm and fm.fields.aliases or {}
```

**completion.lua** — Replace `parse_frontmatter` (lines 10-48):
```lua
local fm_parser = require("andrew.vault.frontmatter_parser")
-- Replace: local fm = parse_frontmatter(abs_path)
-- With:    local result = fm_parser.parse_file(abs_path)
--          local fm = result and result.fields or {}
```

**completion_frontmatter.lua** — Replace `in_frontmatter` (lines 24-46):
```lua
local fm_parser = require("andrew.vault.frontmatter_parser")
-- Replace: if not in_frontmatter(ctx) then return callback(empty) end
-- With:    if not fm_parser.cursor_in_frontmatter(0, ctx.cursor[1] - 1) then return callback(empty) end
```

**frontmatter.lua** — The `modified:` timestamp logic is special (it needs to know the exact line to replace). It can still use `parse_buffer` for boundary detection:
```lua
local fm_parser = require("andrew.vault.frontmatter_parser")
local fm = fm_parser.parse_buffer(bufnr)
if not fm then return end  -- no frontmatter
-- Now search lines fm.start_line to fm.end_line for "modified:" and replace
```

**metaedit.lua** — `find_frontmatter` (lines 59-98) can be replaced with `parse_buffer`, but metaedit needs the raw line numbers for in-place editing. Use `fm.start_line` and `fm.end_line`:
```lua
local fm_parser = require("andrew.vault.frontmatter_parser")
local fm = fm_parser.parse_buffer(bufnr)
-- fm.start_line / fm.end_line give the boundary for editing
-- fm.fields gives the parsed values
```

## Caveats
- **metaedit.lua** needs line-level access for inserting/replacing fields. The shared parser provides `start_line`/`end_line` boundaries, but metaedit may still need to scan individual lines within that range. This is acceptable — the boundary detection and field parsing are still shared.
- **frontmatter.lua** timestamp update needs undojoin semantics. The shared parser does not handle writes — it's read-only. frontmatter.lua keeps its write logic.
- **query/index.lua** has the most comprehensive parser and also handles inline fields in body text. Do NOT replace it — the query engine has its own performance requirements and deeper parsing. The shared parser covers the 8 simpler consumers.

## Testing
- Save a `.md` file with frontmatter — `modified:` timestamp updates correctly
- `VaultMetaEdit` / `VaultMetaCycle` — field editing works
- `VaultAutoFile` — suggests correct directory based on `type:` field
- Breadcrumbs winbar — shows correct `parent-project` value
- `gf` on alias-named wikilinks — resolves via frontmatter aliases
- Completion `[[` — shows aliases in completion items
- Completion inside frontmatter — `in_frontmatter` detection works
- Navigate daily logs — `read_frontmatter_field` for `date:` works

## Estimated Impact
- **Lines removed:** ~120 (8 separate parser implementations)
- **Lines added:** ~90 (shared parser module)
- **Net reduction:** ~30 lines
- **Primary benefit:** Single source of truth for frontmatter parsing behavior, consistent value coercion, one place to fix YAML edge cases
