# 55 --- Frontmatter Schema System

## Motivation

The vault plugin currently treats frontmatter as an unstructured bag of
key-value pairs. Every note type -- task, concept, meeting, project -- uses the
same blank slate. There is no mechanism to declare which fields a note type
*requires*, what types those fields should be, or what values are valid. This
leads to several problems:

1. **Inconsistent metadata.** A "meeting" note might have `attendees` in one
   file and `participants` in another, or omit `date` entirely.
2. **No creation-time scaffolding.** When creating a new note from a template,
   the user must remember which fields to fill in. If the template omits a
   field, it stays missing forever.
3. **No validation feedback.** A misspelled enum value (`"In Progrss"`) or a
   missing required field goes undetected until a search query returns
   unexpected results.
4. **Completion is generic.** The frontmatter completion source
   (`completion_frontmatter.lua`) aggregates all field names and values across
   the entire vault. It cannot prioritize the fields that are relevant to the
   current note's type.
5. **The frontmatter editor is type-unaware.** `frontmatter_editor.lua` shows
   whatever fields exist. It cannot suggest missing required fields or flag
   invalid values.

A schema system solves all five problems by defining, per note type, the
expected fields with their types, constraints, and defaults.

---

## Current State Analysis

### Frontmatter parsing (`frontmatter_parser.lua`)

The parser handles scalars (string, number, boolean), wikilinks, quoted
strings, inline arrays (`[a, b, c]`), and block lists (`- item`). It exposes:

- `parse_value(raw)` -- coerce a raw YAML string to a typed Lua value
- `parse_lines(lines, max_lines)` -- parse frontmatter from line array
- `parse_buffer(bufnr)` / `parse_file(filepath)` -- convenience wrappers
- `cursor_in_frontmatter(bufnr, row)` -- detect if cursor is in FM block

**No type checking or constraint validation exists.** The parser is purely
structural: it returns `fields` as a flat `table<string, any>` with no notion
of expected types.

### Frontmatter auto-management (`frontmatter.lua`)

The `BufWritePre` autocmd in `frontmatter.lua` handles two things:

1. **Auto-create** a minimal frontmatter block (`created`, `modified`) if none
   exists.
2. **Auto-update** the `modified` timestamp on every save.

There is no validation step. The only "required" fields are `created` and
`modified`, and their presence is enforced implicitly by the auto-create logic
rather than by a declarative schema.

### Frontmatter editor (`frontmatter_editor.lua`)

The floating editor reads existing fields from the buffer, displays them in a
navigable list, and supports editing, adding, and deleting fields. Key details:

- `detect_field_type(key, value)` infers the display type from the key name
  (checking `CYCLE_FIELDS`) or the Lua value type. This is heuristic, not
  schema-driven.
- `CYCLE_FIELDS` maps `status`, `priority`, `maturity`, and `type` to their
  config-defined value lists. This is a hard-coded schema fragment.
- `vault_field_values(field_name)` and `vault_field_names()` query the vault
  index for all distinct field names/values -- useful for suggestions but not
  for validation.
- The "add field" action (`add_field()`) offers vault-wide field name
  suggestions but has no concept of "this note type expects these fields."

### Completion (`completion_frontmatter.lua`)

The nvim-cmp source provides two kinds of completions:

1. **Property name** completions -- all field names seen across the vault, plus
   frequency counts.
2. **Property value** completions -- all values seen for a given field, merged
   with `known_values` (which maps `type`, `status`, `priority`, `maturity` to
   their config lists).

There is no prioritization based on the current note's type. A "concept" note
gets the same suggestions as a "meeting" note.

### Metaedit (`metaedit.lua`)

Provides programmatic field manipulation: `set_field`, `cycle_field`,
`toggle_field`, `increment_field`, `pick_and_set`. All operations work on
arbitrary fields with no schema awareness.

### Config (`config.lua`)

Relevant existing config:

```lua
M.note_types = { "meeting", "analysis", "finding", "task", "simulation",
                 "literature", "concept", "log", "journal" }

M.status_values = { "Not Started", "In Progress", "Blocked", "Complete", "Cancelled" }
M.priority_values = { 1, 2, 3, 4, 5 }
M.maturity_values = { "Seed", "Developing", "Mature", "Evergreen" }

M.search.field_enums = { maturity = { "Seed", "Developing", "Mature", "Evergreen" } }
```

The `note_types`, `status_values`, `priority_values`, and `maturity_values`
arrays are the proto-schema -- they define valid values but are scattered across
unrelated config sections with no structural relationship to note types.

---

## Schema Definition Design

### Config format

Add a new top-level config section `M.frontmatter_schema` in `config.lua`. The
schema is a mapping from note type to a table of field definitions:

```lua
M.frontmatter_schema = {
  -- "_default" applies to ALL note types (merged as base).
  _default = {
    type     = { type = "enum",   required = true,  enum = M.note_types, description = "Note type" },
    created  = { type = "date",   required = false, auto = "created",    description = "Creation timestamp" },
    modified = { type = "date",   required = false, auto = "modified",   description = "Last modified timestamp" },
    tags     = { type = "list",   required = false, default = {},        description = "Tags" },
    aliases  = { type = "list",   required = false, default = {},        description = "Alternate names" },
  },

  task = {
    status   = { type = "enum",     required = true,  enum = M.status_values, default = M.status_default, description = "Task status" },
    priority = { type = "enum",     required = true,  enum = M.priority_values, default = M.priority_default, description = "Priority (1=highest)" },
    due      = { type = "date",     required = false, description = "Due date" },
    assigned = { type = "wikilink", required = false, description = "Assigned person" },
    project  = { type = "wikilink", required = false, description = "Parent project" },
  },

  concept = {
    maturity = { type = "enum",     required = false, enum = M.maturity_values, default = M.maturity_default, description = "Knowledge maturity" },
    domain   = { type = "string",   required = false, description = "Knowledge domain" },
    related  = { type = "list",     required = false, description = "Related concepts" },
  },

  meeting = {
    date        = { type = "date",     required = true,  default = "today",  description = "Meeting date" },
    attendees   = { type = "list",     required = true,  default = {},       description = "Meeting participants" },
    status      = { type = "enum",     required = false, enum = M.status_values, default = M.status_default, description = "Meeting status" },
    project     = { type = "wikilink", required = false, description = "Associated project" },
  },

  project = {
    status   = { type = "enum",     required = true,  enum = M.status_values, default = M.status_default, description = "Project status" },
    priority = { type = "enum",     required = true,  enum = M.priority_values, default = M.priority_default, description = "Project priority" },
    area     = { type = "wikilink", required = false, description = "Parent area" },
    due      = { type = "date",     required = false, description = "Project deadline" },
    goals    = { type = "list",     required = false, default = {}, description = "Project goals" },
  },
}
```

### Field definition structure

Each field definition is a table with the following keys:

| Key           | Type               | Required | Description                                           |
|---------------|--------------------|----------|-------------------------------------------------------|
| `type`        | string             | yes      | One of: `"string"`, `"number"`, `"date"`, `"boolean"`, `"list"`, `"wikilink"`, `"enum"` |
| `required`    | boolean            | no       | If true, validation warns when field is missing. Default: `false` |
| `default`     | any                | no       | Value to auto-populate on creation. Special value `"today"` expands to current date |
| `auto`        | string             | no       | Auto-managed field: `"created"` or `"modified"`. Skipped during manual validation |
| `enum`        | any[]              | no       | Valid values (only for `type = "enum"`). References existing config arrays |
| `description` | string             | no       | Human-readable description shown in editor and diagnostics |
| `item_type`   | string             | no       | For `type = "list"`: the type of each list element (default `"string"`) |

### Field types

| Type       | Lua type      | Validation rule                                                |
|------------|---------------|----------------------------------------------------------------|
| `string`   | string        | Must be a non-nil string                                       |
| `number`   | number        | Must be a number (tonumber succeeds)                           |
| `date`     | string        | Must match `%d%d%d%d%-%d%d%-%d%d` (optionally with time)      |
| `boolean`  | boolean       | Must be `true` or `false`                                      |
| `list`     | table         | Must be a sequential table                                     |
| `wikilink` | string        | Must be a string (wikilinks are stored as bare strings by the parser) |
| `enum`     | string/number | Must be a member of the `enum` array                           |

### Enum integration with `field_enums`

The existing `config.search.field_enums` table provides predefined enum values
for search completion. The schema system should be the authoritative source.
When a schema field has `type = "enum"` and an `enum` array, that array is also
surfaced to `field_enums` automatically (see integration section below).

### Schema merging

For a given note type, the effective schema is `_default` merged with the
type-specific definition. Type-specific fields override `_default` if the same
key appears in both:

```lua
effective_schema = vim.tbl_deep_extend("force", schema._default or {}, schema[note_type] or {})
```

---

## New Module: `frontmatter_schema.lua`

File: `lua/andrew/vault/frontmatter_schema.lua`

### Module overview

```lua
local config = require("andrew.vault.config")
local fm_parser = require("andrew.vault.frontmatter_parser")

local M = {}

--- Get the merged schema for a note type.
--- Returns _default fields merged with type-specific fields.
---@param note_type string|nil  If nil, returns _default only
---@return table<string, FieldSchema>
function M.get_schema(note_type)
  local schema = config.frontmatter_schema
  if not schema then return {} end

  local base = vim.deepcopy(schema._default or {})
  if note_type and schema[note_type] then
    base = vim.tbl_deep_extend("force", base, schema[note_type])
  end
  return base
end
```

### `get_required_fields(note_type)`

```lua
--- Get the list of required field names for a note type.
---@param note_type string|nil
---@return string[]
function M.get_required_fields(note_type)
  local schema = M.get_schema(note_type)
  local required = {}
  for name, def in pairs(schema) do
    if def.required then
      required[#required + 1] = name
    end
  end
  table.sort(required)
  return required
end
```

### `get_default_frontmatter(note_type)`

Returns a populated frontmatter table with all required fields set to their
defaults, suitable for insertion into a new note:

```lua
--- Build a default frontmatter table for a note type.
--- Populates required fields with defaults; includes optional fields that have defaults.
---@param note_type string
---@return table<string, any>
function M.get_default_frontmatter(note_type)
  local schema = M.get_schema(note_type)
  local fm = {}

  -- Always set the type field
  fm.type = note_type

  for name, def in pairs(schema) do
    -- Skip auto-managed fields (created/modified handled elsewhere)
    if def.auto then
      goto continue
    end

    if def.required or def.default ~= nil then
      local val = def.default
      -- Resolve special default values
      if val == "today" then
        val = os.date("%Y-%m-%d")
      elseif val == nil and def.required then
        -- Required field with no default: use type-appropriate empty value
        if def.type == "string" or def.type == "wikilink" then
          val = ""
        elseif def.type == "number" then
          val = 0
        elseif def.type == "date" then
          val = os.date("%Y-%m-%d")
        elseif def.type == "boolean" then
          val = false
        elseif def.type == "list" then
          val = {}
        elseif def.type == "enum" and def.enum and #def.enum > 0 then
          val = def.enum[1]
        end
      end

      if val ~= nil then
        fm[name] = val
      end
    end

    ::continue::
  end

  return fm
end
```

### `validate(frontmatter, note_type)`

The core validation function. Returns a structured result:

```lua
---@class SchemaError
---@field field string      Field name
---@field message string    Human-readable error message
---@field severity string   "error" (required missing, type mismatch) or "warn" (suggestion)

---@class ValidationResult
---@field valid boolean
---@field errors SchemaError[]

--- Validate a frontmatter table against the schema for a note type.
---@param frontmatter table<string, any>  Parsed frontmatter fields
---@param note_type string|nil            Note type (read from frontmatter.type if nil)
---@return ValidationResult
function M.validate(frontmatter, note_type)
  note_type = note_type or frontmatter.type
  local schema = M.get_schema(note_type)
  local errors = {}

  for name, def in pairs(schema) do
    -- Skip auto-managed fields
    if def.auto then
      goto continue
    end

    local value = frontmatter[name]

    -- Check required
    if def.required and (value == nil or value == "") then
      errors[#errors + 1] = {
        field = name,
        message = "Required field '" .. name .. "' is missing",
        severity = "error",
      }
      goto continue
    end

    -- Skip further checks if field is absent and optional
    if value == nil then
      goto continue
    end

    -- Type checking
    local type_ok, type_msg = M._check_type(value, def)
    if not type_ok then
      errors[#errors + 1] = {
        field = name,
        message = type_msg,
        severity = "error",
      }
    end

    -- Enum checking
    if def.type == "enum" and def.enum and value ~= nil then
      local found = false
      for _, allowed in ipairs(def.enum) do
        if tostring(value) == tostring(allowed) then
          found = true
          break
        end
      end
      if not found then
        errors[#errors + 1] = {
          field = name,
          message = "Field '" .. name .. "' has invalid value '"
            .. tostring(value) .. "'. Expected one of: "
            .. table.concat(vim.tbl_map(tostring, def.enum), ", "),
          severity = "error",
        }
      end
    end

    ::continue::
  end

  table.sort(errors, function(a, b)
    if a.severity ~= b.severity then
      return a.severity == "error"  -- errors first
    end
    return a.field < b.field
  end)

  return {
    valid = #errors == 0,
    errors = errors,
  }
end
```

### `_check_type(value, def)`

Internal type checker:

```lua
--- Check that a value matches the expected schema type.
---@param value any
---@param def table  Field definition
---@return boolean ok, string|nil message
function M._check_type(value, def)
  local expected = def.type
  if expected == "string" or expected == "wikilink" then
    if type(value) ~= "string" then
      return false, "Field '" .. (def.description or "?") .. "' expected string, got " .. type(value)
    end
  elseif expected == "number" then
    if type(value) ~= "number" then
      return false, "Field expected number, got " .. type(value)
    end
  elseif expected == "date" then
    if type(value) ~= "string" then
      return false, "Field expected date string, got " .. type(value)
    end
    if not value:match("^%d%d%d%d%-%d%d%-%d%d") then
      return false, "Field expected date format YYYY-MM-DD, got '" .. value .. "'"
    end
  elseif expected == "boolean" then
    if type(value) ~= "boolean" then
      return false, "Field expected boolean, got " .. type(value)
    end
  elseif expected == "list" then
    if type(value) ~= "table" then
      return false, "Field expected list, got " .. type(value)
    end
  elseif expected == "enum" then
    -- Enum value type is flexible (string or number); checked separately
  end
  return true, nil
end
```

### `get_missing_fields(frontmatter, note_type)`

Convenience helper for the frontmatter editor to show which fields are missing:

```lua
--- Get schema fields that are absent from the given frontmatter.
--- Returns both required and optional missing fields, tagged accordingly.
---@param frontmatter table<string, any>
---@param note_type string|nil
---@return { name: string, def: table, required: boolean }[]
function M.get_missing_fields(frontmatter, note_type)
  local schema = M.get_schema(note_type)
  local missing = {}

  for name, def in pairs(schema) do
    if not def.auto and frontmatter[name] == nil then
      missing[#missing + 1] = {
        name = name,
        def = def,
        required = def.required or false,
      }
    end
  end

  -- Sort: required fields first, then alphabetical
  table.sort(missing, function(a, b)
    if a.required ~= b.required then return a.required end
    return a.name < b.name
  end)

  return missing
end
```

### `get_field_enum(field_name, note_type)`

Return enum values for a field, consulting the schema:

```lua
--- Get enum values for a field, or nil if not an enum field.
---@param field_name string
---@param note_type string|nil
---@return any[]|nil
function M.get_field_enum(field_name, note_type)
  local schema = M.get_schema(note_type)
  local def = schema[field_name]
  if def and def.type == "enum" and def.enum then
    return def.enum
  end
  return nil
end
```

---

## Integration Points

### 1. Note creation -- auto-populate required fields

**File:** `lua/andrew/vault/user_templates.lua`

When `run_note()` creates a new note, if the template's `note_frontmatter`
specifies a `type` field, use the schema to fill in any required fields that the
template does not already provide.

```lua
-- In user_templates.lua: run_note(), after building fm_str from template

function M.run_note(template)
  local vars = M.collect_prompts(template)
  if not vars then return end
  vars.date = vars.date or engine.today()

  -- Build frontmatter from template
  local fm_map = template.note_frontmatter and vim.deepcopy(template.note_frontmatter) or {}

  -- Schema integration: fill required fields not already in the template
  local note_type = fm_map.type
  if note_type then
    note_type = engine.substitute(tostring(note_type), vars)
    local schema = require("andrew.vault.frontmatter_schema")
    local defaults = schema.get_default_frontmatter(note_type)
    for key, val in pairs(defaults) do
      if fm_map[key] == nil then
        fm_map[key] = val
      end
    end
  end

  local fm_str = ""
  if next(fm_map) then
    fm_str = M.build_frontmatter(fm_map, vars)
  end

  -- ... rest of function unchanged
end
```

**File:** `lua/andrew/vault/frontmatter.lua`

When the `BufWritePre` autocmd auto-creates frontmatter for a file that has
none, it currently only adds `created` and `modified`. If the buffer path can be
matched to a note type (by directory convention or by a prompting step), the
schema defaults should also be inserted. However, this is a stretch goal --
since the auto-create case is rare (the template system handles most creation),
the initial implementation can leave `frontmatter.lua` unchanged.

### 2. Validation on save (`BufWritePre`)

**File:** `lua/andrew/vault/frontmatter.lua`

Add a validation step after the timestamp update. Validation is non-blocking:
it sets diagnostics but does not prevent the save.

```lua
-- In frontmatter.lua: setup(), inside the BufWritePre callback, after
-- the modified-field update logic:

-- Schema validation (non-blocking)
local ok_schema, schema_mod = pcall(require, "andrew.vault.frontmatter_schema")
if ok_schema then
  -- Re-parse after our modifications
  local updated_lines = vim.api.nvim_buf_get_lines(ev.buf, 0, math.min(line_count + 4, max), false)
  local updated_fm = fm_parser.parse_lines(updated_lines, max)
  if updated_fm and updated_fm.fields then
    local result = schema_mod.validate(updated_fm.fields)
    schema_mod.set_diagnostics(ev.buf, result, updated_fm)
  end
end
```

### 3. Diagnostics display

**File:** `lua/andrew/vault/frontmatter_schema.lua`

Add diagnostic reporting using Neovim's built-in `vim.diagnostic` API:

```lua
local DIAG_NS = vim.api.nvim_create_namespace("vault_fm_schema")

--- Map a SchemaError to a vim.Diagnostic.
---@param err SchemaError
---@param fm_info table  Parsed frontmatter info (start_line, end_line, fields)
---@param buf_lines string[]  Buffer lines for field line resolution
---@return vim.Diagnostic
local function error_to_diagnostic(err, fm_info, buf_lines)
  -- Try to find the line of the offending field
  local lnum = fm_info.end_line - 2  -- default: line before closing ---
  local pat = "^" .. vim.pesc(err.field) .. ":%s*"
  for i = fm_info.start_line + 1, fm_info.end_line - 1 do
    if buf_lines[i] and buf_lines[i]:match(pat) then
      lnum = i - 1  -- 0-indexed
      break
    end
  end

  -- For missing fields, point to the closing --- line
  if err.message:match("missing") then
    lnum = fm_info.end_line - 2  -- 0-indexed line before closing ---
  end

  return {
    lnum = lnum,
    col = 0,
    message = err.message,
    severity = err.severity == "error"
      and vim.diagnostic.severity.WARN  -- WARN, not ERROR: don't block save
      or vim.diagnostic.severity.HINT,
    source = "vault-schema",
  }
end

--- Set vim.diagnostics for schema validation errors.
---@param bufnr number
---@param result ValidationResult
---@param fm_info table  Parsed frontmatter info
function M.set_diagnostics(bufnr, result, fm_info)
  if result.valid then
    vim.diagnostic.set(DIAG_NS, bufnr, {})
    return
  end

  local max = config.frontmatter.max_scan_lines
  local n = math.min(vim.api.nvim_buf_line_count(bufnr), max)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)

  local diagnostics = {}
  for _, err in ipairs(result.errors) do
    diagnostics[#diagnostics + 1] = error_to_diagnostic(err, fm_info, lines)
  end

  vim.diagnostic.set(DIAG_NS, bufnr, diagnostics)
end

--- Clear schema diagnostics for a buffer.
---@param bufnr number
function M.clear_diagnostics(bufnr)
  vim.diagnostic.set(DIAG_NS, bufnr, {})
end
```

The diagnostics use `WARN` severity (not `ERROR`) so they appear as yellow
signs/virtual text -- visible but not alarming. Missing required fields show at
the closing `---` line. Type mismatches and invalid enum values show at the
field's actual line.

### 4. Frontmatter editor -- schema-aware suggestions

**File:** `lua/andrew/vault/frontmatter_editor.lua`

#### 4a. Show missing required fields indicator

When opening the editor, detect the note type from existing frontmatter, query
the schema for missing fields, and display them in a separate section:

```lua
-- In frontmatter_editor.lua: at the top, add require
local schema_mod = nil
pcall(function() schema_mod = require("andrew.vault.frontmatter_schema") end)

-- In the render() function, after the field lines and before the help text:

-- Schema: show missing required fields
if schema_mod and _state then
  local note_type = nil
  for _, f in ipairs(_state.fields) do
    if f.key == "type" then note_type = tostring(f.value); break end
  end

  if note_type then
    local fm_table = {}
    for _, f in ipairs(_state.fields) do
      fm_table[f.key] = f.value
    end
    local missing = schema_mod.get_missing_fields(fm_table, note_type)

    if #missing > 0 then
      display_lines[#display_lines + 1] = ""
      display_lines[#display_lines + 1] = "  Missing fields:"
      for _, m in ipairs(missing) do
        local tag = m.required and " [required]" or " [optional]"
        local desc = m.def.description and ("  -- " .. m.def.description) or ""
        display_lines[#display_lines + 1] = "    + " .. m.name .. tag .. desc
      end
    end
  end
end
```

#### 4b. Schema-aware "add field" action

When the user presses `a` to add a field, prioritize missing schema fields
over the generic vault-wide field name list:

```lua
-- In frontmatter_editor.lua: add_field(), replace the field name input logic

local function add_field()
  if not _state then return end

  engine.run(function()
    -- Determine note type for schema lookup
    local note_type = nil
    for _, f in ipairs(_state.fields) do
      if f.key == "type" then note_type = tostring(f.value); break end
    end

    -- Build candidate list: schema missing fields first, then vault-wide names
    local candidates = {}
    local seen = {}

    -- Existing field keys (to exclude)
    for _, f in ipairs(_state.fields) do
      seen[f.key] = true
    end

    -- Schema missing fields (prioritized)
    if schema_mod and note_type then
      local missing = schema_mod.get_missing_fields(
        (function()
          local t = {}; for _, f in ipairs(_state.fields) do t[f.key] = f.value end; return t
        end)(),
        note_type
      )
      for _, m in ipairs(missing) do
        if not seen[m.name] then
          local tag = m.required and " [required]" or ""
          candidates[#candidates + 1] = m.name .. tag
          seen[m.name] = true
        end
      end
    end

    -- Vault-wide names (secondary)
    local known_names = vault_field_names()
    for _, name in ipairs(known_names) do
      if not seen[name] then
        candidates[#candidates + 1] = name
        seen[name] = true
      end
    end

    -- Let user pick or type freely
    local choice = engine.select(candidates, {
      prompt = "Add field",
    })
    if not choice then return end

    -- Strip "[required]" tag if present
    local new_key = choice:gsub("%s+%[required%]$", "")

    -- ... rest of add_field logic (determine default value, etc.)
    -- If schema defines a default for this field, use it:
    if schema_mod and note_type then
      local schema = schema_mod.get_schema(note_type)
      local def = schema[new_key]
      if def and def.default ~= nil then
        local val = def.default
        if val == "today" then val = os.date("%Y-%m-%d") end
        -- Use this as the pre-filled value in the input prompt
      end
    end
  end)
end
```

#### 4c. Validation indicator in editor title

When the editor opens, run validation and show the result in the float title:

```lua
-- In frontmatter_editor.lua: open(), after render()

if schema_mod then
  local note_type = fm.fields.type and tostring(fm.fields.type) or nil
  if note_type then
    local result = schema_mod.validate(fm.fields, note_type)
    local title = result.valid
      and " Frontmatter [valid] "
      or (" Frontmatter [" .. #result.errors .. " issue(s)] ")
    vim.api.nvim_win_set_config(float_win, { title = title, title_pos = "center" })
  end
end
```

### 5. Completion -- schema-aware prioritization

**File:** `lua/andrew/vault/completion_frontmatter.lua`

When providing property name completions, boost fields that are in the schema
for the current note type. Required fields get the highest sort priority.

```lua
-- In completion_frontmatter.lua: get_completions(), in the property name
-- completion branch

-- After callback for property name items, enhance with schema awareness:
local schema_mod = nil
pcall(function() schema_mod = require("andrew.vault.frontmatter_schema") end)

if schema_mod then
  local fm = fm_parser.parse_buffer(bufnr)
  local note_type = fm and fm.fields and fm.fields.type and tostring(fm.fields.type) or nil
  if note_type then
    local schema = schema_mod.get_schema(note_type)
    -- Boost schema fields in sort order
    for _, item in ipairs(items.names) do
      local def = schema[item.label]
      if def then
        if def.required then
          item.sortText = "0000_" .. item.label  -- highest priority
          item.labelDetails = item.labelDetails or {}
          item.labelDetails.detail = " [required]"
        else
          item.sortText = "0001_" .. item.label  -- second priority
          item.labelDetails = item.labelDetails or {}
          item.labelDetails.detail = " [schema]"
        end
      end
    end
  end
end
```

For value completions, when the field is an enum type in the schema, restrict
completions to the enum values (or at least boost them above vault-aggregated
values):

```lua
-- In the value completion branch:
if schema_mod and prop_key then
  local fm = fm_parser.parse_buffer(bufnr)
  local note_type = fm and fm.fields and fm.fields.type and tostring(fm.fields.type) or nil
  if note_type then
    local enum_vals = schema_mod.get_field_enum(prop_key, note_type)
    if enum_vals then
      -- Build enum-only completion items
      local enum_items = {}
      for _, v in ipairs(enum_vals) do
        enum_items[#enum_items + 1] = {
          label = tostring(v),
          insertText = tostring(v),
          filterText = tostring(v),
          kind = 13,  -- Enum
          sortText = "0000_" .. tostring(v),
          labelDetails = { description = "schema" },
        }
      end
      -- Prepend enum items to existing value items
      local merged = enum_items
      for _, existing in ipairs(val_items) do
        merged[#merged + 1] = existing
      end
      val_items = merged
    end
  end
end
```

### 6. Sync with `field_enums`

**File:** `lua/andrew/vault/frontmatter_schema.lua`

Add a function to extract all enum definitions from the schema for use by the
search system's `field_enums`:

```lua
--- Collect all enum definitions across all note types.
--- Returns a table mapping field_name -> values[], suitable for merging
--- into config.search.field_enums.
---@return table<string, any[]>
function M.collect_enums()
  local schema = config.frontmatter_schema
  if not schema then return {} end

  local enums = {}
  for _, type_schema in pairs(schema) do
    for name, def in pairs(type_schema) do
      if def.type == "enum" and def.enum and not enums[name] then
        enums[name] = def.enum
      end
    end
  end
  return enums
end
```

This can be called during search initialization to merge schema-defined enums
into `config.search.field_enums`, ensuring search field completion stays in
sync with the schema.

---

## Commands

### `:VaultSchemaValidate`

Validate the current buffer's frontmatter against its schema and display
results:

```lua
-- In frontmatter_schema.lua: setup()

function M.setup()
  vim.api.nvim_create_user_command("VaultSchemaValidate", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local fm = fm_parser.parse_buffer(bufnr)
    if not fm then
      vim.notify("No frontmatter found", vim.log.levels.WARN)
      return
    end

    local note_type = fm.fields.type and tostring(fm.fields.type) or nil
    local result = M.validate(fm.fields, note_type)
    M.set_diagnostics(bufnr, result, fm)

    if result.valid then
      vim.notify(
        "Schema: frontmatter is valid"
          .. (note_type and (" (type: " .. note_type .. ")") or " (no type field)"),
        vim.log.levels.INFO
      )
    else
      local lines = { "Schema validation errors:" }
      for _, err in ipairs(result.errors) do
        lines[#lines + 1] = "  " .. err.severity:upper() .. ": " .. err.message
      end
      vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN)
    end
  end, {
    desc = "Validate frontmatter against schema for current note type",
  })
```

### `:VaultSchemaShow`

Display the schema for a given note type (or the current buffer's type):

```lua
  vim.api.nvim_create_user_command("VaultSchemaShow", function(opts)
    local note_type = vim.trim(opts.args)
    if note_type == "" then
      -- Try to detect from current buffer
      local fm = fm_parser.parse_buffer(vim.api.nvim_get_current_buf())
      note_type = fm and fm.fields.type and tostring(fm.fields.type) or nil
    end

    if not note_type then
      vim.notify("Usage: VaultSchemaShow [type] (or open a note with a type field)", vim.log.levels.WARN)
      return
    end

    local schema = M.get_schema(note_type)
    if not schema or not next(schema) then
      vim.notify("No schema defined for type '" .. note_type .. "'", vim.log.levels.INFO)
      return
    end

    local lines = { "Schema for type: " .. note_type, string.rep("-", 40) }
    -- Sort: required first, then alphabetical
    local sorted = {}
    for name, def in pairs(schema) do
      sorted[#sorted + 1] = { name = name, def = def }
    end
    table.sort(sorted, function(a, b)
      local ar = a.def.required and 1 or 0
      local br = b.def.required and 1 or 0
      if ar ~= br then return ar > br end
      return a.name < b.name
    end)

    for _, entry in ipairs(sorted) do
      local def = entry.def
      local tag = def.required and " *" or ""
      local type_str = def.type
      if def.type == "enum" and def.enum then
        type_str = "enum(" .. table.concat(vim.tbl_map(tostring, def.enum), "|") .. ")"
      end
      local desc = def.description and ("  -- " .. def.description) or ""
      local default_str = ""
      if def.default ~= nil then
        if type(def.default) == "table" then
          default_str = "  [default: []]"
        else
          default_str = "  [default: " .. tostring(def.default) .. "]"
        end
      end
      lines[#lines + 1] = "  " .. entry.name .. tag .. " : " .. type_str .. default_str .. desc
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "  (* = required)"

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, {
    nargs = "?",
    desc = "Show the frontmatter schema for a note type",
    complete = function()
      return config.note_types
    end,
  })
```

### `:VaultSchemaFix`

Interactive command to add missing required fields with their default values:

```lua
  vim.api.nvim_create_user_command("VaultSchemaFix", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local fm = fm_parser.parse_buffer(bufnr)
    if not fm then
      vim.notify("No frontmatter found", vim.log.levels.WARN)
      return
    end

    local note_type = fm.fields.type and tostring(fm.fields.type) or nil
    if not note_type then
      vim.notify("No 'type' field in frontmatter -- cannot determine schema", vim.log.levels.WARN)
      return
    end

    local missing = M.get_missing_fields(fm.fields, note_type)
    local required_missing = vim.tbl_filter(function(m) return m.required end, missing)

    if #required_missing == 0 then
      vim.notify("All required fields are present", vim.log.levels.INFO)
      return
    end

    local metaedit = require("andrew.vault.metaedit")
    local count = 0
    for _, m in ipairs(required_missing) do
      local val = m.def.default
      if val == "today" then val = os.date("%Y-%m-%d") end
      if val == nil then
        if m.def.type == "enum" and m.def.enum and #m.def.enum > 0 then
          val = m.def.enum[1]
        elseif m.def.type == "list" then
          val = {}
        elseif m.def.type == "date" then
          val = os.date("%Y-%m-%d")
        elseif m.def.type == "boolean" then
          val = false
        else
          val = ""
        end
      end
      metaedit.set_field(m.name, val)
      count = count + 1
    end

    vim.notify("Schema: added " .. count .. " missing required field(s)", vim.log.levels.INFO)
  end, {
    desc = "Add missing required frontmatter fields with defaults",
  })
```

### Command palette and keymaps

```lua
  -- Register with palette
  local palette = require("andrew.vault.command_palette")
  palette.register_command("VaultSchemaValidate", "Validate frontmatter against schema", "Schema")
  palette.register_command("VaultSchemaShow", "Show schema for note type", "Schema")
  palette.register_command("VaultSchemaFix", "Add missing required fields", "Schema")
end
```

---

## Example Schemas

### Task

```lua
task = {
  status   = { type = "enum",     required = true,  enum = M.status_values,   default = M.status_default, description = "Task status" },
  priority = { type = "enum",     required = true,  enum = M.priority_values, default = M.priority_default, description = "Priority (1=highest, 5=lowest)" },
  due      = { type = "date",     required = false, description = "Due date (YYYY-MM-DD)" },
  assigned = { type = "wikilink", required = false, description = "Person assigned to this task" },
  project  = { type = "wikilink", required = false, description = "Parent project note" },
},
```

Expected behavior:
- New task notes auto-populate `status: Not Started` and `priority: 3`.
- Saving a task note with `status: donee` produces a diagnostic:
  `Field 'status' has invalid value 'donee'. Expected one of: Not Started, In Progress, Blocked, Complete, Cancelled`.
- The frontmatter editor shows `due`, `assigned`, `project` in the "Missing
  fields" section when absent.

### Concept

```lua
concept = {
  maturity = { type = "enum",   required = false, enum = M.maturity_values, default = M.maturity_default, description = "Knowledge maturity level" },
  domain   = { type = "string", required = false, description = "Knowledge domain or category" },
  related  = { type = "list",   required = false, description = "Related concept notes" },
},
```

Expected behavior:
- New concept notes auto-populate `maturity: Seed`.
- Completion for `maturity:` in frontmatter shows only `Seed`, `Developing`,
  `Mature`, `Evergreen` (not vault-aggregated values).

### Meeting

```lua
meeting = {
  date      = { type = "date",     required = true,  default = "today",  description = "Meeting date" },
  attendees = { type = "list",     required = true,  default = {},       description = "Meeting participants" },
  status    = { type = "enum",     required = false, enum = M.status_values, default = M.status_default, description = "Meeting status" },
  project   = { type = "wikilink", required = false, description = "Associated project" },
  agenda    = { type = "list",     required = false, description = "Agenda items" },
},
```

Expected behavior:
- New meeting notes auto-populate `date:` to today's date and create an empty
  `attendees:` list.
- Saving a meeting note without `date` produces a diagnostic:
  `Required field 'date' is missing`.

### Project

```lua
project = {
  status   = { type = "enum",     required = true,  enum = M.status_values,   default = M.status_default, description = "Project status" },
  priority = { type = "enum",     required = true,  enum = M.priority_values, default = M.priority_default, description = "Project priority" },
  area     = { type = "wikilink", required = false, description = "Parent area of responsibility" },
  due      = { type = "date",     required = false, description = "Project deadline" },
  goals    = { type = "list",     required = false, default = {}, description = "Project goals and deliverables" },
},
```

---

## Detailed Code Changes Summary

### New files

| File | Purpose |
|------|---------|
| `lua/andrew/vault/frontmatter_schema.lua` | Schema definition, validation, diagnostics, commands |

### Modified files

| File | Change |
|------|--------|
| `lua/andrew/vault/config.lua` | Add `M.frontmatter_schema` config section with `_default` + per-type schemas |
| `lua/andrew/vault/frontmatter.lua` | Call `schema.validate()` + `schema.set_diagnostics()` in `BufWritePre` after timestamp update |
| `lua/andrew/vault/frontmatter_editor.lua` | Import schema module; show missing fields in render; schema-aware `add_field()`; validation indicator in title |
| `lua/andrew/vault/completion_frontmatter.lua` | Boost schema fields in name completions; restrict enum field value completions to schema enum values |
| `lua/andrew/vault/user_templates.lua` | In `run_note()`, merge `get_default_frontmatter()` with template frontmatter |
| `lua/andrew/vault/init.lua` | Require and call `frontmatter_schema.setup()` during vault initialization |

### Unchanged files

| File | Reason |
|------|--------|
| `lua/andrew/vault/frontmatter_parser.lua` | Purely structural parser; no schema awareness needed |
| `lua/andrew/vault/metaedit.lua` | Low-level field manipulation; operates on explicit values, not schema |

---

## Design Decisions and Notes

1. **Validation is advisory, not blocking.** `BufWritePre` sets diagnostics but
   does not prevent the save. This avoids frustrating the user when they are
   mid-edit and have intentionally incomplete frontmatter.

2. **Schema is opt-in per note type.** Note types without a schema entry in
   `frontmatter_schema` are unconstrained. The `_default` schema applies
   universally but can be empty.

3. **`auto` fields are excluded from manual validation.** The `created` and
   `modified` fields are managed by `frontmatter.lua` and should not produce
   "missing required field" warnings during normal editing.

4. **Schema merging uses `_default` as a base.** This avoids repeating common
   fields (tags, aliases, type) in every note type definition.

5. **Enum values are compared as strings.** This matches the existing behavior
   in `metaedit.cycle_field()` and `frontmatter_parser.parse_value()`, where
   numeric priorities like `3` may be stored as the number `3` or the string
   `"3"`.

6. **Diagnostics use `WARN` severity.** Schema violations are not hard errors.
   They should be visible but not block the workflow. The `vim.diagnostic` API
   is used because it integrates with existing diagnostic UIs (signs, virtual
   text, trouble.nvim, etc.).

7. **The schema module has no circular dependencies.** It requires only
   `config` and `fm_parser`, which are leaf modules. All integration is done
   by the consuming modules requiring `frontmatter_schema` (not the reverse).

8. **Special default `"today"`.** The string `"today"` as a default value is
   expanded to `os.date("%Y-%m-%d")` at creation time. This provides a
   convenient shorthand without introducing a full expression language.
