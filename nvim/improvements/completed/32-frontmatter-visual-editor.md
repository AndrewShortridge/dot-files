# 32 — Frontmatter Visual Editor

## Problem

Editing frontmatter in vault notes requires invoking explicit commands (`:VaultMetaEdit status "In Progress"`, `<leader>vms`, `<leader>vmf`) or manually editing raw YAML text. Each command targets a single field and provides no overview of the note's current metadata. To understand what frontmatter a note has, the user must scroll to the top and read the raw YAML block — there is no structured, at-a-glance view.

Obsidian's Properties panel shows all frontmatter fields in a sidebar with inline editing, type-aware controls (toggles for booleans, date pickers for dates, chips for tags), and one-click field addition. The current vault module has nothing comparable.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **frontmatter.lua** | Auto-creates/updates `created`/`modified` timestamps on `BufWritePre` | `lua/andrew/vault/frontmatter.lua` |
| **frontmatter_parser.lua** | Parses YAML frontmatter into `{ start_line, end_line, fields }` from buffer/file/lines | `lua/andrew/vault/frontmatter_parser.lua` |
| **metaedit.lua** | `set_field`, `cycle_field`, `toggle_field`, `increment_field`, `pick_and_set` via commands/keymaps | `lua/andrew/vault/metaedit.lua` |
| **config.lua** | Canonical value lists (`status_values`, `priority_values`, `maturity_values`, `note_types`) | `lua/andrew/vault/config.lua` |
| **vault_index.lua** | Indexes all notes with parsed frontmatter, tags, aliases; provides `all_tags()`, `all_entries()` | `lua/andrew/vault/vault_index.lua` |
| **ui.lua** | `create_float_input()` and `create_float_display()` helpers for floating windows | `lua/andrew/vault/ui.lua` |

### What Is Missing

1. No **visual overview** of all frontmatter fields for the current note in a single view.
2. No **inline editing** — the user must either type commands or edit raw YAML directly.
3. No **type-aware controls** — booleans require knowing to use `VaultMetaToggle`, dates have no picker, list fields have no multi-value interface.
4. No **field name completion** — adding a new field requires knowing the exact YAML key.
5. No **value suggestions** derived from the vault index (e.g., all existing tag values, all `type` values used across the vault).
6. No **live preview** — changes via MetaEdit commands do not show in any panel; the user must scroll to frontmatter to verify.

---

## Goal

Add a floating frontmatter editor panel so that:

1. `<leader>vM` opens a floating window showing all frontmatter fields for the current note in an editable form.
2. Fields are displayed as `key: value` lines with syntax highlighting for types (string, list, date, boolean, number).
3. List fields (tags, aliases) are shown as comma-separated with easy add/remove semantics.
4. `<Tab>` / `<S-Tab>` navigate between fields within the float.
5. `<CR>` on a field opens inline editing with completion from config canonical values and vault index.
6. `a` adds a new field with completion for known field names.
7. `dd` deletes a field.
8. Changes are written back to the source buffer frontmatter on `q` (close) or live as each field is confirmed.
9. Live sync: edits in the panel update the source buffer in real-time (each confirmed field change is immediately written back).
10. Type-aware editing: boolean fields toggle on `<CR>`, date fields show a date prompt, list fields show a comma-separated editor with tag/alias completion, cycle fields show a picker.
11. New module at `lua/andrew/vault/frontmatter_editor.lua`.
12. Integration with `vault_index` for field name and value suggestions.
13. `:VaultFrontmatterEdit` command as an alternative to the keymap.

---

## Approach

### Architecture

Create a new module `lua/andrew/vault/frontmatter_editor.lua` that:

1. Parses the current buffer's frontmatter via `frontmatter_parser.parse_buffer()`.
2. Opens a floating window with a custom buffer displaying field rows.
3. Tracks an internal ordered field list (`_fields`) as the canonical state, each entry carrying the key, value, type, and display string.
4. Renders the float buffer content from `_fields` (one line per field) with extmark-based highlighting.
5. Provides buffer-local keymaps for navigation, editing, adding, deleting.
6. On each edit confirmation, writes the change back to the source buffer immediately via `metaedit.set_field()` for scalar fields and a new `set_list_field()` for list fields.
7. On close (`q`), ensures the float is cleaned up. No deferred batch write — all changes are already live.

### Float Layout

```
 ┌─ Frontmatter: Note Title ─────────────────────┐
 │  created:   2026-02-20T14:30:00               │
 │  modified:  2026-02-26T09:15:22               │
 │  type:      simulation                        │
 │  status:    In Progress                       │
 │  priority:  2                                 │
 │  tags:      project/cfd, methodology, active  │
 │  aliases:   CFD Setup, cfd-setup              │
 │  draft:     false                             │
 │                                               │
 │  [a]dd  [dd]elete  [CR]edit  [q]uit           │
 └───────────────────────────────────────────────┘
```

- Width: `min(80, editor_width * 0.6)`, dynamically sized to content.
- Height: `field_count + 3` (fields + blank line + help line + padding).
- Position: centered in the editor.
- Border: `"rounded"` with title showing the note name.
- The help line at the bottom is a virtual text extmark (not an editable line).

### Field Type Detection

Each field value is classified into a type that determines its editing behavior:

```lua
---@alias FieldType "string"|"number"|"boolean"|"date"|"list"|"cycle"

--- Detect the type of a frontmatter field for editing purposes.
---@param key string
---@param value any
---@return FieldType
local function detect_field_type(key, value)
  -- Check if this key has a known cycle list
  if CYCLE_FIELDS[key] then return "cycle" end
  -- Explicit type checks
  if type(value) == "boolean" then return "boolean" end
  if type(value) == "number" then return "number" end
  if type(value) == "table" then return "list" end
  -- Date detection: ISO 8601 pattern
  if type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%d") then
    return "date"
  end
  return "string"
end
```

### Cycle Field Registry

Fields that have canonical value lists from `config.lua` are treated as cycle fields — `<CR>` opens a small picker instead of free-text input:

```lua
local config = require("andrew.vault.config")

--- Fields with known cycle values.
local CYCLE_FIELDS = {
  status = config.status_values,
  priority = config.priority_values,
  maturity = config.maturity_values,
  type = config.note_types,
}
```

### Highlight Groups

The editor uses distinct highlight groups for each field type, defined in `setup()`:

| Highlight Group | Used For | Default Link |
|----------------|---------|-------------|
| `VaultFmEditorKey` | Field name (left of `:`) | `@property` |
| `VaultFmEditorString` | String values | `@string` |
| `VaultFmEditorNumber` | Number values | `@number` |
| `VaultFmEditorBoolean` | Boolean values | `@boolean` |
| `VaultFmEditorDate` | Date/timestamp values | `@string.special` |
| `VaultFmEditorList` | Comma-separated list values | `@punctuation.delimiter` |
| `VaultFmEditorHelp` | Help line at bottom | `Comment` |
| `VaultFmEditorCursor` | Current field highlight | `CursorLine` |

### Internal State

```lua
---@class FmEditorField
---@field key string            YAML key name
---@field value any             Parsed Lua value (string, number, boolean, table)
---@field type FieldType        Detected type
---@field original_value any    Value when the editor was opened (for dirty detection)

---@class FmEditorState
---@field source_buf number     Buffer number of the source markdown file
---@field source_win number     Window ID of the source file (for cursor restore)
---@field float_buf number      Buffer number of the floating editor
---@field float_win number      Window ID of the floating editor
---@field fields FmEditorField[] Ordered list of fields
---@field cursor_row number     Current highlighted field row (1-indexed into fields)
---@field ns number             Namespace ID for extmarks
---@field closed boolean        Whether the editor has been closed
```

### Two-Way Sync Strategy

The editor uses an **immediate write-through** strategy:

1. **Float to source**: Every confirmed field edit (pressing `<CR>` after changing a value, toggling a boolean, selecting from a picker) immediately calls `metaedit.set_field()` or `set_list_field()` to update the source buffer. This reuses the existing MetaEdit infrastructure which handles creating frontmatter, inserting missing fields, and replacing existing field lines.

2. **Source to float**: Not implemented in the initial version. The float shows the state at open time plus user edits within the float. If the user edits the source buffer directly while the float is open (unlikely since focus is in the float), they should close and reopen the editor. A `BufModifiedSet` autocmd guard prevents stale reads.

3. **No batch mode**: There is no "pending changes" queue. Each edit is atomic and immediately reflected in the source buffer. The user sees the undo history grow with each field change, and `u` in the source buffer after closing the editor undoes the last field change.

### Vault Index Integration for Suggestions

When editing a field value, the editor queries the vault index for existing values used across the vault:

```lua
--- Collect all unique values for a frontmatter field across the vault.
---@param field_name string
---@return string[]
local function vault_field_values(field_name)
  local vi = require("andrew.vault.vault_index")
  local idx = vi.current()
  if not idx or not idx:is_ready() then return {} end

  local seen = {}
  local values = {}
  for _, entry in pairs(idx.files) do
    local fm = entry.frontmatter
    if fm and fm[field_name] ~= nil then
      local v = fm[field_name]
      if type(v) == "table" then
        for _, item in ipairs(v) do
          local s = tostring(item)
          if not seen[s] then
            seen[s] = true
            values[#values + 1] = s
          end
        end
      else
        local s = tostring(v)
        if not seen[s] then
          seen[s] = true
          values[#values + 1] = s
        end
      end
    end
  end
  table.sort(values)
  return values
end
```

For **field name** suggestions (when adding a new field with `a`), the editor collects all unique frontmatter keys from the vault index:

```lua
--- Collect all unique frontmatter field names across the vault.
---@return string[]
local function vault_field_names()
  local vi = require("andrew.vault.vault_index")
  local idx = vi.current()
  if not idx or not idx:is_ready() then return {} end

  local seen = {}
  local names = {}
  for _, entry in pairs(idx.files) do
    local fm = entry.frontmatter
    if fm then
      for key in pairs(fm) do
        if not seen[key] then
          seen[key] = true
          names[#names + 1] = key
        end
      end
    end
  end
  table.sort(names)
  return names
end
```

---

## Implementation Steps

### Step 1: Create the new module

**File:** `lua/andrew/vault/frontmatter_editor.lua`

```lua
local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local fm_parser = require("andrew.vault.frontmatter_parser")
local metaedit = require("andrew.vault.metaedit")

local M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local NS = vim.api.nvim_create_namespace("vault_fm_editor")

--- Fields with known cycle values.
local CYCLE_FIELDS = {
  status = config.status_values,
  priority = config.priority_values,
  maturity = config.maturity_values,
  type = config.note_types,
}

--- YAML special characters requiring quoting.
local yaml_special = '[:%#%[%{\'"]'

-- ---------------------------------------------------------------------------
-- Field type detection
-- ---------------------------------------------------------------------------

---@alias FieldType "string"|"number"|"boolean"|"date"|"list"|"cycle"

---@param key string
---@param value any
---@return FieldType
local function detect_field_type(key, value)
  if CYCLE_FIELDS[key] then return "cycle" end
  if type(value) == "boolean" then return "boolean" end
  if type(value) == "number" then return "number" end
  if type(value) == "table" then return "list" end
  if type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%d") then
    return "date"
  end
  return "string"
end

-- ---------------------------------------------------------------------------
-- Highlight group -> FieldType mapping
-- ---------------------------------------------------------------------------

local TYPE_HIGHLIGHTS = {
  string  = "VaultFmEditorString",
  number  = "VaultFmEditorNumber",
  boolean = "VaultFmEditorBoolean",
  date    = "VaultFmEditorDate",
  list    = "VaultFmEditorList",
  cycle   = "VaultFmEditorString",
}

-- ---------------------------------------------------------------------------
-- Value formatting
-- ---------------------------------------------------------------------------

--- Format a field value for display in the editor.
---@param value any
---@param field_type FieldType
---@return string
local function format_display_value(value, field_type)
  if field_type == "list" and type(value) == "table" then
    return table.concat(vim.tbl_map(tostring, value), ", ")
  end
  if field_type == "boolean" then
    return value and "true" or "false"
  end
  return tostring(value)
end

--- Format a value for YAML output.
---@param val any
---@return string
local function format_yaml_value(val)
  if type(val) == "boolean" then
    return val and "true" or "false"
  end
  if type(val) == "number" then
    return tostring(val)
  end
  local s = tostring(val)
  if s:match(yaml_special) then
    return '"' .. s:gsub('"', '\\"') .. '"'
  end
  return s
end

-- ---------------------------------------------------------------------------
-- Vault index integration
-- ---------------------------------------------------------------------------

--- Collect all unique values for a frontmatter field across the vault.
---@param field_name string
---@return string[]
local function vault_field_values(field_name)
  local vi = require("andrew.vault.vault_index")
  local idx = vi.current()
  if not idx or not idx:is_ready() then return {} end

  local seen = {}
  local values = {}
  for _, entry in pairs(idx.files) do
    local fm = entry.frontmatter
    if fm and fm[field_name] ~= nil then
      local v = fm[field_name]
      if type(v) == "table" then
        for _, item in ipairs(v) do
          local s = tostring(item)
          if not seen[s] then
            seen[s] = true
            values[#values + 1] = s
          end
        end
      else
        local s = tostring(v)
        if not seen[s] then
          seen[s] = true
          values[#values + 1] = s
        end
      end
    end
  end
  table.sort(values)
  return values
end

--- Collect all unique frontmatter field names across the vault.
---@return string[]
local function vault_field_names()
  local vi = require("andrew.vault.vault_index")
  local idx = vi.current()
  if not idx or not idx:is_ready() then return {} end

  local seen = {}
  local names = {}
  for _, entry in pairs(idx.files) do
    local fm = entry.frontmatter
    if fm then
      for key in pairs(fm) do
        if not seen[key] then
          seen[key] = true
          names[#names + 1] = key
        end
      end
    end
  end
  table.sort(names)
  return names
end

-- ---------------------------------------------------------------------------
-- List field write-back
-- ---------------------------------------------------------------------------

--- Write a list-typed field back to the source buffer as YAML block list.
--- Replaces the entire field (key line + indented list items) in frontmatter.
---@param source_buf number
---@param key string
---@param items string[]
local function set_list_field(source_buf, key, items)
  local fm = fm_parser.parse_buffer(source_buf)
  if not fm then
    -- No frontmatter — create one with this list field
    local lines = { "---", key .. ":" }
    for _, item in ipairs(items) do
      lines[#lines + 1] = "  - " .. format_yaml_value(item)
    end
    lines[#lines + 1] = "---"
    pcall(vim.cmd, "undojoin")
    vim.api.nvim_buf_set_lines(source_buf, 0, 0, false, lines)
    return
  end

  -- Find the key line and its extent (including indented list items below it)
  local buf_lines = vim.api.nvim_buf_get_lines(source_buf, 0, fm.end_line, false)
  local key_lnum = nil -- 1-indexed
  local key_pat = "^" .. vim.pesc(key) .. ":%s*"

  for i = fm.start_line + 1, fm.end_line - 1 do
    if buf_lines[i]:match(key_pat) then
      key_lnum = i
      break
    end
  end

  if key_lnum then
    -- Find extent: key line + any indented list items below it
    local extent_end = key_lnum
    for i = key_lnum + 1, fm.end_line - 1 do
      if buf_lines[i]:match("^%s+%-") then
        extent_end = i
      else
        break
      end
    end

    -- Build replacement lines
    local new_lines = { key .. ":" }
    for _, item in ipairs(items) do
      new_lines[#new_lines + 1] = "  - " .. format_yaml_value(item)
    end

    pcall(vim.cmd, "undojoin")
    vim.api.nvim_buf_set_lines(source_buf, key_lnum - 1, extent_end, false, new_lines)
  else
    -- Field not present: insert before closing ---
    local new_lines = { key .. ":" }
    for _, item in ipairs(items) do
      new_lines[#new_lines + 1] = "  - " .. format_yaml_value(item)
    end
    pcall(vim.cmd, "undojoin")
    vim.api.nvim_buf_set_lines(source_buf, fm.end_line - 1, fm.end_line - 1, false, new_lines)
  end
end

-- ---------------------------------------------------------------------------
-- Delete field from source buffer
-- ---------------------------------------------------------------------------

--- Remove a frontmatter field (key line + any indented list items) from the source buffer.
---@param source_buf number
---@param key string
local function delete_field(source_buf, key)
  local fm = fm_parser.parse_buffer(source_buf)
  if not fm then return end

  local buf_lines = vim.api.nvim_buf_get_lines(source_buf, 0, fm.end_line, false)
  local key_pat = "^" .. vim.pesc(key) .. ":%s*"
  local key_lnum = nil

  for i = fm.start_line + 1, fm.end_line - 1 do
    if buf_lines[i]:match(key_pat) then
      key_lnum = i
      break
    end
  end

  if not key_lnum then return end

  -- Find extent (key line + indented list items)
  local extent_end = key_lnum
  for i = key_lnum + 1, fm.end_line - 1 do
    if buf_lines[i]:match("^%s+%-") then
      extent_end = i
    else
      break
    end
  end

  pcall(vim.cmd, "undojoin")
  vim.api.nvim_buf_set_lines(source_buf, key_lnum - 1, extent_end, false, {})
end

-- ---------------------------------------------------------------------------
-- Editor state
-- ---------------------------------------------------------------------------

---@class FmEditorField
---@field key string
---@field value any
---@field type FieldType
---@field original_value any

---@class FmEditorState
---@field source_buf number
---@field source_win number
---@field float_buf number
---@field float_win number
---@field fields FmEditorField[]
---@field cursor_row number
---@field ns number
---@field closed boolean

---@type FmEditorState|nil
local _state = nil

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Compute the maximum key width for alignment.
---@param fields FmEditorField[]
---@return number
local function max_key_width(fields)
  local max_w = 0
  for _, f in ipairs(fields) do
    if #f.key > max_w then max_w = #f.key end
  end
  return max_w
end

--- Render the float buffer contents from the current field state.
local function render()
  if not _state or _state.closed then return end

  local buf = _state.float_buf
  if not vim.api.nvim_buf_is_valid(buf) then return end

  vim.bo[buf].modifiable = true

  local key_w = max_key_width(_state.fields)
  local lines = {}
  for _, f in ipairs(_state.fields) do
    local display_val = format_display_value(f.value, f.type)
    local padding = string.rep(" ", key_w - #f.key)
    lines[#lines + 1] = "  " .. f.key .. padding .. ":  " .. display_val
  end

  -- Blank line + help text
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  [a]dd  [dd]elete  [CR]edit  [Tab]next  [q]uit"

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Apply highlights via extmarks
  vim.api.nvim_buf_clear_namespace(buf, _state.ns, 0, -1)

  for i, f in ipairs(_state.fields) do
    local row = i - 1 -- 0-indexed
    local padding = string.rep(" ", key_w - #f.key)
    local key_start = 2 -- after "  "
    local key_end = key_start + #f.key
    local val_start = key_end + #padding + 3 -- ":  "
    local display_val = format_display_value(f.value, f.type)
    local val_end = val_start + #display_val

    -- Key highlight
    vim.api.nvim_buf_set_extmark(buf, _state.ns, row, key_start, {
      end_col = key_end,
      hl_group = "VaultFmEditorKey",
    })

    -- Value highlight
    local hl = TYPE_HIGHLIGHTS[f.type] or "VaultFmEditorString"
    vim.api.nvim_buf_set_extmark(buf, _state.ns, row, val_start, {
      end_col = val_end,
      hl_group = hl,
    })
  end

  -- Help line highlight
  local help_row = #_state.fields + 1
  if help_row < vim.api.nvim_buf_line_count(buf) then
    local help_line = lines[#lines]
    vim.api.nvim_buf_set_extmark(buf, _state.ns, help_row, 0, {
      end_col = #help_line,
      hl_group = "VaultFmEditorHelp",
    })
  end

  -- Cursor line highlight
  if _state.cursor_row >= 1 and _state.cursor_row <= #_state.fields then
    vim.api.nvim_buf_set_extmark(buf, _state.ns, _state.cursor_row - 1, 0, {
      end_row = _state.cursor_row - 1,
      end_col = #lines[_state.cursor_row],
      hl_group = "VaultFmEditorCursor",
    })
  end

  -- Position cursor
  if vim.api.nvim_win_is_valid(_state.float_win) then
    local target_row = math.min(_state.cursor_row, #_state.fields)
    if target_row >= 1 then
      vim.api.nvim_win_set_cursor(_state.float_win, { target_row, 2 })
    end
  end
end

-- ---------------------------------------------------------------------------
-- Edit actions
-- ---------------------------------------------------------------------------

--- Edit a string/number/date field via inline input.
---@param field FmEditorField
---@param field_idx number
local function edit_string_field(field, field_idx)
  local suggestions = vault_field_values(field.key)
  -- Merge with canonical values if they exist
  local canonical = CYCLE_FIELDS[field.key]
  if canonical then
    for _, v in ipairs(canonical) do
      local s = tostring(v)
      local found = false
      for _, existing in ipairs(suggestions) do
        if existing == s then found = true; break end
      end
      if not found then
        suggestions[#suggestions + 1] = s
      end
    end
  end

  engine.run(function()
    local current = format_display_value(field.value, field.type)
    local new_val = engine.input({
      prompt = field.key .. " = ",
      default = current,
      completion = function(_, _, _)
        return suggestions
      end,
    })
    if new_val == nil then return end -- cancelled

    -- Coerce to appropriate Lua type
    local coerced = fm_parser.parse_value(new_val)
    _state.fields[field_idx].value = coerced
    _state.fields[field_idx].type = detect_field_type(field.key, coerced)

    -- Write back to source buffer
    metaedit.set_field(field.key, coerced)

    -- Re-render the float
    render()
  end)
end

--- Edit a boolean field by toggling.
---@param field FmEditorField
---@param field_idx number
local function edit_boolean_field(field, field_idx)
  local new_val = not field.value
  _state.fields[field_idx].value = new_val

  -- Write back to source
  metaedit.set_field(field.key, new_val)

  render()
end

--- Edit a cycle field via picker.
---@param field FmEditorField
---@param field_idx number
local function edit_cycle_field(field, field_idx)
  local values = CYCLE_FIELDS[field.key]
  if not values then return end

  engine.run(function()
    local items = vim.tbl_map(tostring, values)
    local choice = engine.select(items, { prompt = field.key })
    if not choice then return end

    -- Find the original typed value
    for _, v in ipairs(values) do
      if tostring(v) == choice then
        _state.fields[field_idx].value = v
        _state.fields[field_idx].type = detect_field_type(field.key, v)
        metaedit.set_field(field.key, v)
        render()
        return
      end
    end
  end)
end

--- Edit a list field via comma-separated input with tag/value completion.
---@param field FmEditorField
---@param field_idx number
local function edit_list_field(field, field_idx)
  local suggestions = vault_field_values(field.key)

  -- For tags field, also pull from all_tags()
  if field.key == "tags" then
    local vi = require("andrew.vault.vault_index")
    local idx = vi.current()
    if idx and idx:is_ready() then
      for _, tag in ipairs(idx:all_tags()) do
        local found = false
        for _, s in ipairs(suggestions) do
          if s == tag then found = true; break end
        end
        if not found then
          suggestions[#suggestions + 1] = tag
        end
      end
    end
  end

  engine.run(function()
    local current = format_display_value(field.value, "list")
    local new_val = engine.input({
      prompt = field.key .. " (comma-separated) = ",
      default = current,
      completion = function(_, _, _)
        return suggestions
      end,
    })
    if new_val == nil then return end

    -- Parse comma-separated items
    local items = {}
    for item in new_val:gmatch("[^,]+") do
      local trimmed = vim.trim(item)
      if trimmed ~= "" then
        items[#items + 1] = trimmed
      end
    end

    _state.fields[field_idx].value = items
    _state.fields[field_idx].type = "list"

    -- Write back as YAML block list
    set_list_field(_state.source_buf, field.key, items)

    render()
  end)
end

--- Edit a date field with a date prompt showing the current value.
---@param field FmEditorField
---@param field_idx number
local function edit_date_field(field, field_idx)
  engine.run(function()
    local current = tostring(field.value)
    local new_val = engine.input({
      prompt = field.key .. " (date) = ",
      default = current,
    })
    if new_val == nil then return end

    _state.fields[field_idx].value = new_val
    _state.fields[field_idx].type = detect_field_type(field.key, new_val)
    metaedit.set_field(field.key, new_val)
    render()
  end)
end

--- Dispatch to the appropriate edit function based on field type.
local function edit_current_field()
  if not _state or _state.closed then return end
  local idx = _state.cursor_row
  if idx < 1 or idx > #_state.fields then return end

  local field = _state.fields[idx]

  if field.type == "boolean" then
    edit_boolean_field(field, idx)
  elseif field.type == "cycle" then
    edit_cycle_field(field, idx)
  elseif field.type == "list" then
    edit_list_field(field, idx)
  elseif field.type == "date" then
    edit_date_field(field, idx)
  else
    edit_string_field(field, idx)
  end
end

--- Add a new field.
local function add_field()
  if not _state or _state.closed then return end

  local known_names = vault_field_names()

  engine.run(function()
    local key = engine.input({
      prompt = "Field name: ",
      completion = function(_, _, _)
        return known_names
      end,
    })
    if not key or key == "" then return end

    -- Check for duplicates
    for _, f in ipairs(_state.fields) do
      if f.key == key then
        vim.notify("Field '" .. key .. "' already exists. Press <CR> to edit it.", vim.log.levels.WARN)
        return
      end
    end

    -- Determine a sensible default value based on key name
    local default_val = ""
    if CYCLE_FIELDS[key] then
      default_val = CYCLE_FIELDS[key][1]
    elseif key == "tags" or key == "aliases" then
      default_val = {}
    elseif key == "draft" or key == "published" then
      default_val = false
    end

    local new_field = {
      key = key,
      value = default_val,
      type = detect_field_type(key, default_val),
      original_value = nil,
    }
    _state.fields[#_state.fields + 1] = new_field
    _state.cursor_row = #_state.fields

    -- Write to source buffer
    if type(default_val) == "table" then
      set_list_field(_state.source_buf, key, default_val)
    else
      metaedit.set_field(key, default_val)
    end

    -- Resize the float to accommodate the new field
    resize_float()
    render()

    -- Immediately open the editor for the new field
    vim.schedule(function()
      edit_current_field()
    end)
  end)
end

--- Delete the current field.
local function delete_current_field()
  if not _state or _state.closed then return end
  local idx = _state.cursor_row
  if idx < 1 or idx > #_state.fields then return end

  local field = _state.fields[idx]

  -- Protect system fields
  if field.key == "created" or field.key == "modified" then
    vim.notify("Cannot delete system field '" .. field.key .. "'", vim.log.levels.WARN)
    return
  end

  -- Remove from source buffer
  delete_field(_state.source_buf, field.key)

  -- Remove from internal state
  table.remove(_state.fields, idx)
  if _state.cursor_row > #_state.fields then
    _state.cursor_row = math.max(1, #_state.fields)
  end

  resize_float()
  render()
  vim.notify("Deleted field: " .. field.key, vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- Float window management
-- ---------------------------------------------------------------------------

--- Compute float dimensions from current field count.
---@return number width, number height
local function float_dimensions()
  local ui = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
  local field_count = _state and #_state.fields or 0
  local height = field_count + 3 -- fields + blank + help + top padding
  height = math.max(height, 5) -- minimum height
  height = math.min(height, math.floor(ui.height * 0.8))

  -- Width: based on longest line content
  local width = 50 -- minimum
  if _state then
    local key_w = max_key_width(_state.fields)
    for _, f in ipairs(_state.fields) do
      local val_len = #format_display_value(f.value, f.type)
      local line_len = 2 + key_w + 3 + val_len + 4 -- padding + key + ":  " + value + margin
      if line_len > width then width = line_len end
    end
  end
  width = math.min(width, math.floor(ui.width * 0.6))
  width = math.max(width, 50)

  return width, height
end

--- Resize the float window to fit current content.
function resize_float()
  if not _state or _state.closed then return end
  if not vim.api.nvim_win_is_valid(_state.float_win) then return end

  local width, height = float_dimensions()
  local ui = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
  local col = math.floor((ui.width - width) / 2)
  local row = math.floor((ui.height - height) / 2)

  vim.api.nvim_win_set_config(_state.float_win, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
  })
end

--- Close the editor float and clean up state.
local function close_editor()
  if not _state or _state.closed then return end
  _state.closed = true

  if vim.api.nvim_win_is_valid(_state.float_win) then
    vim.api.nvim_win_close(_state.float_win, true)
  end

  -- Restore focus to source window
  if vim.api.nvim_win_is_valid(_state.source_win) then
    vim.api.nvim_set_current_win(_state.source_win)
  end

  _state = nil
end

--- Navigate to the next field.
local function next_field()
  if not _state or _state.closed or #_state.fields == 0 then return end
  _state.cursor_row = (_state.cursor_row % #_state.fields) + 1
  render()
end

--- Navigate to the previous field.
local function prev_field()
  if not _state or _state.closed or #_state.fields == 0 then return end
  _state.cursor_row = ((_state.cursor_row - 2) % #_state.fields) + 1
  render()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Open the frontmatter visual editor for the current buffer.
function M.open()
  local source_buf = vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  local bufpath = vim.api.nvim_buf_get_name(source_buf)

  if not engine.is_vault_path(bufpath) then
    vim.notify("Vault: not a vault file", vim.log.levels.WARN)
    return
  end

  -- Close any existing editor
  if _state and not _state.closed then
    close_editor()
  end

  -- Parse current frontmatter
  local fm = fm_parser.parse_buffer(source_buf)
  local fields = {}

  if fm and fm.fields then
    -- Preserve key ordering by re-reading lines to determine order
    local buf_lines = vim.api.nvim_buf_get_lines(source_buf, 0, fm.end_line, false)
    local ordered_keys = {}
    local seen_keys = {}

    for i = fm.start_line + 1, fm.end_line - 1 do
      local key = buf_lines[i]:match("^([%w_%-]+):")
      if key and not seen_keys[key] then
        seen_keys[key] = true
        ordered_keys[#ordered_keys + 1] = key
      end
    end

    for _, key in ipairs(ordered_keys) do
      local value = fm.fields[key]
      if value ~= nil then
        fields[#fields + 1] = {
          key = key,
          value = value,
          type = detect_field_type(key, value),
          original_value = vim.deepcopy(value),
        }
      end
    end
  end

  -- If no frontmatter exists, start with an empty editor
  if #fields == 0 then
    fields = {}
  end

  -- Initialize state
  _state = {
    source_buf = source_buf,
    source_win = source_win,
    float_buf = nil,
    float_win = nil,
    fields = fields,
    cursor_row = #fields > 0 and 1 or 0,
    ns = NS,
    closed = false,
  }

  -- Create float buffer
  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[float_buf].bufhidden = "wipe"
  vim.bo[float_buf].buftype = "nofile"
  vim.bo[float_buf].swapfile = false
  _state.float_buf = float_buf

  -- Open float window
  local width, height = float_dimensions()
  local ui = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
  local col = math.floor((ui.width - width) / 2)
  local row = math.floor((ui.height - height) / 2)

  local note_name = vim.fn.fnamemodify(bufpath, ":t:r")
  local float_win = vim.api.nvim_open_win(float_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = " Frontmatter: " .. note_name .. " ",
    title_pos = "center",
    noautocmd = true,
  })
  _state.float_win = float_win

  vim.wo[float_win].cursorline = false
  vim.wo[float_win].wrap = false
  vim.wo[float_win].number = false
  vim.wo[float_win].relativenumber = false
  vim.wo[float_win].signcolumn = "no"

  -- Render initial content
  render()

  -- Set up keymaps
  local kopts = { buffer = float_buf, nowait = true, silent = true }

  vim.keymap.set("n", "q",       close_editor,        vim.tbl_extend("force", kopts, { desc = "Close editor" }))
  vim.keymap.set("n", "<Esc>",   close_editor,        vim.tbl_extend("force", kopts, { desc = "Close editor" }))
  vim.keymap.set("n", "<CR>",    edit_current_field,   vim.tbl_extend("force", kopts, { desc = "Edit field" }))
  vim.keymap.set("n", "<Tab>",   next_field,           vim.tbl_extend("force", kopts, { desc = "Next field" }))
  vim.keymap.set("n", "<S-Tab>", prev_field,           vim.tbl_extend("force", kopts, { desc = "Previous field" }))
  vim.keymap.set("n", "j",       next_field,           vim.tbl_extend("force", kopts, { desc = "Next field" }))
  vim.keymap.set("n", "k",       prev_field,           vim.tbl_extend("force", kopts, { desc = "Previous field" }))
  vim.keymap.set("n", "a",       add_field,            vim.tbl_extend("force", kopts, { desc = "Add field" }))
  vim.keymap.set("n", "dd",      delete_current_field, vim.tbl_extend("force", kopts, { desc = "Delete field" }))

  -- Close on BufLeave
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = float_buf,
    once = true,
    callback = function()
      vim.schedule(close_editor)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  -- Define highlight groups
  local hl_defaults = {
    VaultFmEditorKey     = { link = "@property" },
    VaultFmEditorString  = { link = "@string" },
    VaultFmEditorNumber  = { link = "@number" },
    VaultFmEditorBoolean = { link = "@boolean" },
    VaultFmEditorDate    = { link = "@string.special" },
    VaultFmEditorList    = { link = "@punctuation.delimiter" },
    VaultFmEditorHelp    = { link = "Comment" },
    VaultFmEditorCursor  = { link = "CursorLine" },
  }
  for name, def in pairs(hl_defaults) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", { default = true }, def))
  end

  -- Command
  vim.api.nvim_create_user_command("VaultFrontmatterEdit", function()
    M.open()
  end, { desc = "Open frontmatter visual editor" })

  -- Buffer-local keymap for markdown files
  local group = vim.api.nvim_create_augroup("VaultFrontmatterEditor", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vM", function()
        M.open()
      end, {
        buffer = ev.buf,
        desc = "Frontmatter: visual editor",
        silent = true,
      })
    end,
  })
end

return M
```

### Step 2: Add `set_list_field` to metaedit.lua (optional refactor)

The `set_list_field()` function is defined locally in `frontmatter_editor.lua` because it needs buffer-specific targeting (the source buffer, not necessarily the current buffer). If list field editing is desired from MetaEdit commands in the future, this function could be promoted to `metaedit.lua` as a public API. For now, it stays local to avoid changing the MetaEdit interface.

### Step 3: Register in vault init

**File:** `lua/andrew/vault/init.lua`

Add after the MetaEdit setup line:

```lua
-- Load frontmatter visual editor
require("andrew.vault.frontmatter_editor").setup()
```

### Step 4: Forward declaration fix

The `resize_float()` function is referenced by `add_field()` and `delete_current_field()` but defined later in the file. Add a forward declaration at the top of the module-level scope:

```lua
-- Forward declaration (defined below float window management)
local resize_float
```

Then change the definition from `function resize_float()` to the assignment form:

```lua
resize_float = function()
  -- ... body ...
end
```

This pattern matches how other vault modules handle forward references.

---

## Testing

### Manual Verification

1. **Open the editor on a note with existing frontmatter:**

   Open a vault note that has several frontmatter fields (created, modified, type, status, tags, etc.).

   Press `<leader>vM` or run `:VaultFrontmatterEdit`.

   **Expected:**
   - A centered floating window appears with the title "Frontmatter: NoteName".
   - All frontmatter fields are listed, one per line, in their original order.
   - Keys are left-aligned with padding, values are syntax-highlighted by type.
   - A help line at the bottom shows available keybindings.
   - The first field is highlighted.

2. **Navigate between fields:**

   Press `j`, `k`, `<Tab>`, `<S-Tab>`.

   **Expected:**
   - The cursor highlight moves between fields.
   - Wraps around at the top/bottom.

3. **Edit a string field:**

   Navigate to `type` and press `<CR>`.

   **Expected:**
   - If `type` is a cycle field, a picker appears with `config.note_types` values.
   - Selecting a value updates the float display and the source buffer frontmatter.

4. **Toggle a boolean field:**

   Navigate to `draft` (if present) and press `<CR>`.

   **Expected:**
   - The value toggles between `true` and `false` immediately.
   - The source buffer shows the updated value.

5. **Edit a list field:**

   Navigate to `tags` and press `<CR>`.

   **Expected:**
   - An input prompt appears with the current tags as comma-separated text.
   - Typing provides completion from vault-wide tag values.
   - Confirming updates the source buffer with a YAML block list.

6. **Add a new field:**

   Press `a`.

   **Expected:**
   - A prompt asks for the field name with completion from vault-wide field names.
   - After entering a name, the field appears in the editor with a default value.
   - The edit prompt opens immediately for the new field.
   - The source buffer gains the new field in its frontmatter.

7. **Delete a field:**

   Navigate to a non-system field and press `dd`.

   **Expected:**
   - The field is removed from the float and from the source buffer frontmatter.
   - System fields (`created`, `modified`) cannot be deleted (warning shown).

8. **Close the editor:**

   Press `q` or `<Esc>`.

   **Expected:**
   - The float closes.
   - Focus returns to the source window.
   - All changes are already in the source buffer (no pending writes).

9. **Open on a note with no frontmatter:**

   Open a new note with no `---` block. Press `<leader>vM`.

   **Expected:**
   - The editor opens with an empty field list.
   - Pressing `a` to add a field creates the frontmatter block in the source buffer.

10. **Undo integration:**

    Edit two fields, close the editor, then press `u` twice in the source buffer.

    **Expected:**
    - Each `u` undoes one field change (each field write is a separate undo entry joined via `undojoin`).

### Performance Verification

The editor should open instantly since `parse_buffer()` is already O(1) (scans up to `max_scan_lines` = 200 lines). The vault index queries for suggestions are only executed on edit actions, not on open.

```vim
:lua local s = vim.uv.hrtime(); require("andrew.vault.frontmatter_editor").open(); print(("%.1f ms"):format((vim.uv.hrtime() - s) / 1e6))
```

**Target:** < 10ms to open the editor float.

### Automated Test

Add to `tests/test_vault_fixes.lua`:

```lua
-- Test: frontmatter_editor module structure
do
  local source = io.open("lua/andrew/vault/frontmatter_editor.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    assert_true(content:find("detect_field_type") ~= nil, "has field type detection")
    assert_true(content:find("vault_field_values") ~= nil, "has vault value suggestions")
    assert_true(content:find("vault_field_names") ~= nil, "has vault field name suggestions")
    assert_true(content:find("set_list_field") ~= nil, "has list field write-back")
    assert_true(content:find("delete_field") ~= nil, "has field deletion")
    assert_true(content:find("edit_boolean_field") ~= nil, "has boolean toggle")
    assert_true(content:find("edit_cycle_field") ~= nil, "has cycle picker")
    assert_true(content:find("edit_list_field") ~= nil, "has list editor")
    assert_true(content:find("VaultFrontmatterEdit") ~= nil, "has command")
    assert_true(content:find("<leader>vM") ~= nil, "has keymap")
    assert_true(content:find("render") ~= nil, "has render function")
    assert_true(content:find("close_editor") ~= nil, "has close function")
  end
end
```

---

## Risks & Mitigations

### Risk Assessment: Low-Medium

| Risk | Impact | Likelihood | Mitigation |
|------|--------|-----------|-----------|
| Float focus issues on `engine.input()`/`engine.select()` | Picker opens but float loses focus | Medium | `engine.run()` handles coroutine suspension; the float is non-modal so pickers can overlay it. If focus is lost, `BufLeave` autocmd closes the editor gracefully. |
| `set_list_field()` corrupts YAML structure | Source buffer frontmatter becomes unparseable | Low | The function uses the same `fm_parser.parse_buffer()` boundary detection as MetaEdit. Indented list detection uses the same `^%s+%-` pattern as the parser. |
| `undojoin` fails when editing from float context | Each field change becomes a separate undo entry (harmless but noisy) | Low | `pcall(vim.cmd, "undojoin")` is already the standard pattern used by `metaedit.lua` and `frontmatter.lua`. Failure is silent and non-breaking. |
| Concurrent editing of source buffer while float is open | Float shows stale data | Low | Users rarely edit the source buffer while the float has focus. The close-and-reopen workflow is the recommended recovery. A future enhancement could add `BufModifiedSet` sync. |
| Large number of frontmatter fields (20+) | Float window too tall for small terminals | Low | Height is capped at `80%` of editor height. Fields beyond the visible area can be scrolled to with `j`/`k`. |
| `delete_field` removes list items that span multiple lines | Line math error leaves orphaned `  -` lines | Low | Extent detection scans forward from the key line collecting all `^%s+%-` lines, matching the same pattern used by the parser. Tested manually on block lists with 1, 5, and 10 items. |
| `resize_float` called after field add/delete | Float resize causes flicker | Very Low | `nvim_win_set_config()` is a single atomic call. The visual update is one frame. |
| MetaEdit `set_field` targets current buffer, not source buffer | If another buffer gets focus during edit, the wrong buffer is modified | Low | `metaedit.set_field()` operates on `nvim_get_current_buf()` which is the float buffer, not the source. **This must be addressed**: the editor should temporarily set the current buffer to the source before calling `set_field`, or use the buffer-explicit functions. See implementation note below. |

### Critical Implementation Note: Buffer Context for MetaEdit

The existing `metaedit.set_field()` calls `vim.api.nvim_get_current_buf()` internally. When the float has focus, the current buffer is the float buffer, not the source markdown file. This means `set_field()` would attempt to modify the float buffer's frontmatter (which does not exist).

**Solution**: Wrap all `metaedit.set_field()` calls with `vim.api.nvim_buf_call()` to temporarily switch the buffer context:

```lua
--- Write a scalar field back to the source buffer, respecting MetaEdit's buffer context.
---@param source_buf number
---@param key string
---@param value any
local function write_field_to_source(source_buf, key, value)
  vim.api.nvim_buf_call(source_buf, function()
    metaedit.set_field(key, value)
  end)
end
```

Replace all direct `metaedit.set_field()` calls in the edit functions with `write_field_to_source(_state.source_buf, key, value)`. This is essential for correctness.

### Backwards Compatibility

- **No existing modules modified** (except adding one `require` line in `init.lua`).
- **No config changes required** — the editor reads existing `config.status_values`, `config.priority_values`, `config.maturity_values`, and `config.note_types` without any additions.
- **MetaEdit keymaps unchanged** — `<leader>vms`, `<leader>vmp`, `<leader>vmf` etc. continue to work as before. The visual editor is an alternative, not a replacement.
- **`<leader>vM` does not conflict** — the `M` is uppercase and distinct from `<leader>vm*` (lowercase `m` prefix for MetaEdit field keymaps).

### Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| Note with no frontmatter | Editor opens empty; `a` creates the `---` block |
| Note with unclosed frontmatter (missing closing `---`) | `parse_buffer()` returns nil; editor opens empty with notification |
| Field with multiline string value | Displayed as single line (truncated); editing replaces with single-line value |
| Field with nested YAML objects | Displayed as stringified table; editing replaces with flat value (limitation) |
| Field value containing commas (non-list) | Detected as string type, not list; comma-separated parsing only for list fields |
| Inline array syntax `[a, b, c]` | Parsed as list by `frontmatter_parser.lua`; displayed and edited as comma-separated |
| Block list syntax (indented `- item`) | Parsed as list by `frontmatter_parser.lua`; written back as block list |
| Empty list field `tags:` with no items | Parsed as empty table; displayed as empty string; editing allows adding items |
| Non-vault markdown file | `is_vault_path()` check prevents opening; warning notification |
| Already-open editor (second `<leader>vM`) | Existing editor closed, new one opened |
| Source buffer deleted while editor is open | `nvim_buf_is_valid()` checks prevent crashes; editor closes gracefully |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `engine.lua` | `is_vault_path()`, `vault_path`, `engine.run()`, `engine.input()`, `engine.select()` | Yes |
| `config.lua` | `status_values`, `priority_values`, `maturity_values`, `note_types` for cycle fields | Yes |
| `frontmatter_parser.lua` | `parse_buffer()` for reading frontmatter, `parse_value()` for type coercion | Yes |
| `metaedit.lua` | `set_field()` for writing scalar values back to the source buffer | Yes |
| `vault_index.lua` | `all_tags()`, field name/value collection for completion suggestions | Optional (degrades to no completion) |
| `ui.lua` | Not used directly (the editor manages its own float for full control) | No |

---

## Key Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/frontmatter_editor.lua` | **New file** — complete module |
| `lua/andrew/vault/init.lua` | Add `require("andrew.vault.frontmatter_editor").setup()` |

---

## Future Enhancements

These are explicitly **out of scope** for this implementation but noted for future consideration:

1. **Sidebar mode** — An alternative to the centered float: a vertical split on the right side that stays open as the user edits the note body. Requires more complex focus management and `BufModifiedSet` sync from source to sidebar.
2. **Drag-and-drop field reordering** — Move fields up/down to control their order in the YAML output. Currently fields are written in their original order.
3. **Nested object editing** — Support for YAML objects (e.g., `metadata: { author: "...", version: 1 }`). Currently these are stringified.
4. **Date picker widget** — Instead of a text prompt for date fields, show a calendar-style date picker using `vim.ui.select()` with generated date options.
5. **Multi-value select for list fields** — Instead of comma-separated text input, show a checkbox-style picker for list fields (similar to Obsidian's tag multi-select).
6. **Real-time two-way sync** — Watch the source buffer for external frontmatter changes and update the editor float. Requires `nvim_buf_attach()` with on_lines callback.
7. **Template-aware defaults** — When adding a field, suggest default values based on the note's template type (e.g., simulation notes default to `status: Not Started`).
