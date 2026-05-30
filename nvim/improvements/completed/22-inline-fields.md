# 22 — Inline Field Parsing and Highlighting

## Problem

Obsidian's Dataview plugin supports **inline fields** — metadata embedded directly in note prose using `[key:: value]` and `(key:: value)` syntax. The vault's query engine already extracts these fields during indexing (see `query/index.lua:_extract_inline_fields`), but there is **no visual feedback** in the buffer. Inline fields appear as plain bracketed text, indistinguishable from normal parenthetical remarks or markdown links.

This creates several problems:

1. **Invisible metadata** — users cannot tell at a glance which parts of a line are queryable fields vs. prose.
2. **No validation feedback** — there is no visual distinction between a well-formed field `[status:: Active]` and a typo like `[stauts:: Active]`.
3. **No completion** — users must remember field key names from memory, leading to inconsistency (`due-date` vs `due_date` vs `dueDate`).
4. **Standalone fields are ambiguous** — the bare `key:: value` syntax (without brackets) is easily confused with normal text containing colons.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **query/index.lua** | `_extract_inline_fields()` parses `key:: value`, `[key:: value]`, `(key:: value)` from body text during indexing | `lua/andrew/vault/query/index.lua` |
| **query/index.lua** | `_parse_scalar()` coerces field values to typed objects (Date, Link, number, boolean, string) | `lua/andrew/vault/query/index.lua` |
| **query/executor.lua** | Evaluates DQL expressions against page fields (including inline fields merged at top level) | `lua/andrew/vault/query/executor.lua` |
| **tag_highlights.lua** | Extmark-based highlighting with debounce, code exclusion, toggle — architectural template | `lua/andrew/vault/tag_highlights.lua` |
| **frontmatter.lua** | Frontmatter field auto-update on save (related metadata management) | `lua/andrew/vault/frontmatter.lua` |

### Why This Cannot Be Done With Treesitter

The `markdown_inline` parser has no concept of Dataview inline fields. The `[key:: value]` pattern is parsed as a plain `(shortcut_link)` or `(inline)` text node. A treesitter query cannot:

- Distinguish `[key:: value]` from `[link text]` or `[citation]`.
- Detect the `::` delimiter as semantically significant.
- Apply separate highlights to the key vs. the value.
- Exclude fields inside code blocks/spans.
- Integrate with the vault's field registry for validation.

**Conclusion**: An extmark-based Lua module is required.

---

## Goal

Add inline field parsing, highlighting, and completion so that:

1. Inline fields `[key:: value]` and `(key:: value)` are visually distinct — keys and values have different highlight groups.
2. Standalone fields `key:: value` (at line start or after list markers) are also highlighted.
3. Fields inside code blocks, code spans, and frontmatter are **not** highlighted.
4. Field values are type-aware — dates, links, and numbers get subtle visual cues.
5. Known field keys from the vault index are available as completion candidates.
6. Inline fields are fully queryable via the existing DQL engine (already implemented in index.lua; this doc ensures the highlighting module shares the same parsing logic).
7. Highlighting is performant — debounced, handles buffers with many fields.
8. Users can customize highlight colors via config.

---

## Approach

### Architecture

Create a new module `lua/andrew/vault/inline_fields.lua` that:

1. Scans buffer lines for all three inline field syntaxes using Lua patterns.
2. Filters out false positives (code blocks, code spans, frontmatter).
3. Applies extmarks with distinct highlight groups for brackets, key, separator, and value.
4. Runs on `BufEnter`, `TextChanged`, `TextChangedI` (debounced 200ms).
5. Shares code exclusion logic with `tag_highlights.lua` (same treesitter approach).
6. Exposes a field key registry for completion and validation.
7. Integrates with the query index to maintain a vault-wide field key inventory.

### Inline Field Patterns

Obsidian/Dataview supports three syntaxes:

| Syntax | Visibility | Example | Use Case |
|--------|-----------|---------|----------|
| `[key:: value]` | Rendered inline (brackets hidden in reading mode) | `[status:: Active]` | Inline metadata within prose |
| `(key:: value)` | Fully hidden in reading mode | `(priority:: 1)` | Hidden metadata |
| `key:: value` | Standalone (full line or after list marker) | `due:: 2026-03-01` | Prominent metadata fields |

**Key constraints:**
- Keys must be alphanumeric with hyphens and underscores: `[a-zA-Z][a-zA-Z0-9_-]*`
- The separator is `::` (two colons), optionally followed by whitespace
- Values extend to the closing bracket/paren, or to end of line for standalone fields
- A key with `::` but no value is valid (sets field to `nil`/empty)

### Lua Pattern Definitions

```lua
-- Bracketed: [key:: value] — brackets are part of the syntax
-- Captures: full_start, key, value, full_end (1-indexed byte positions)
local BRACKET_PATTERN = "%[([%w_%-]+)::%s*(.-)%]"

-- Parenthesized: (key:: value) — parens are part of the syntax
local PAREN_PATTERN = "%(([%w_%-]+)::%s*(.-)%)"

-- Standalone: key:: value at start of line or after list marker
-- Must be anchored: preceded by start-of-line, whitespace, or list marker (- or *)
-- Key must start at a word boundary
local STANDALONE_PATTERN = "^([%w_%-]+)::%s*(.-)%s*$"
local LIST_STANDALONE_PATTERN = "^(%s*[-*]%s+)([%w_%-]+)::%s*(.-)%s*$"
```

### False Positive Filters

| Pattern | Why It's Not a Field | Detection Method |
|---------|---------------------|------------------|
| `[text](url)` | Markdown link | Check for `](` immediately after `]` |
| `[^footnote]` | Footnote reference | Key starts with `^` |
| `[key:: value]` inside `` `code` `` | Code span | Treesitter: `code_span` node range |
| `[key:: value]` inside fenced block | Code block | Treesitter: `fenced_code_block` node range |
| YAML frontmatter lines | Not inline fields | Line range between `---` delimiters |
| `http://` or `https://` as key | URL false positive | Key matches `^https?$` |
| `[[wikilink]]` | Wikilink, not field | Presence of `[[` before content |

### Highlight Groups

| Group | Applies To | Default Style |
|-------|-----------|---------------|
| `VaultFieldBracket` | `[`, `]`, `(`, `)` delimiters | `fg = #5c6370` (gray) |
| `VaultFieldKey` | The key name | `fg = #e06c75` (red), `bold = true` |
| `VaultFieldSep` | The `::` separator | `fg = #5c6370` (gray) |
| `VaultFieldValue` | Generic text values | `fg = #98c379` (green) |
| `VaultFieldValueDate` | Date values (YYYY-MM-DD) | `fg = #e5c07b` (yellow) |
| `VaultFieldValueNumber` | Numeric values | `fg = #d19a66` (orange) |
| `VaultFieldValueLink` | Wikilink values `[[...]]` | `fg = #61afef` (blue), `underline = true` |
| `VaultFieldValueBool` | `true`/`false` values | `fg = #56b6c2` (cyan), `italic = true` |

Colors follow the OneDarkPro palette established by `tag_highlights.lua`.

### Value Type Detection

Values are classified for highlight purposes using simple pattern matching (no full parsing needed for display):

```lua
local function classify_value(value)
  local trimmed = vim.trim(value)
  if trimmed == "" then return "empty" end
  if trimmed == "true" or trimmed == "false" then return "boolean" end
  if trimmed:match("^%d%d%d%d%-%d%d%-%d%d") then return "date" end
  if tonumber(trimmed) then return "number" end
  if trimmed:match("^%[%[.+%]%]$") then return "link" end
  return "text"
end
```

---

## Implementation

### File: `lua/andrew/vault/inline_fields.lua`

```lua
local engine = require("andrew.vault.engine")

local M = {}

M.enabled = true
M.ns = vim.api.nvim_create_namespace("vault_inline_field_hl")

---@type uv.uv_timer_t|nil
local timer = nil
local DEBOUNCE_MS = 200

-- ---------------------------------------------------------------------------
-- Highlight groups
-- ---------------------------------------------------------------------------

local hl_groups = {
  VaultFieldBracket = { fg = "#5c6370" },
  VaultFieldKey = { fg = "#e06c75", bold = true },
  VaultFieldSep = { fg = "#5c6370" },
  VaultFieldValue = { fg = "#98c379" },
  VaultFieldValueDate = { fg = "#e5c07b" },
  VaultFieldValueNumber = { fg = "#d19a66" },
  VaultFieldValueLink = { fg = "#61afef", underline = true },
  VaultFieldValueBool = { fg = "#56b6c2", italic = true },
}

local function define_highlights()
  for group, attrs in pairs(hl_groups) do
    attrs.default = true
    vim.api.nvim_set_hl(0, group, attrs)
  end
end

-- ---------------------------------------------------------------------------
-- Value type classification
-- ---------------------------------------------------------------------------

--- Classify a field value string for highlight purposes.
---@param value string trimmed value text
---@return string type_name one of "empty", "boolean", "date", "number", "link", "text"
local function classify_value(value)
  local trimmed = vim.trim(value)
  if trimmed == "" then return "empty" end
  if trimmed == "true" or trimmed == "false" then return "boolean" end
  if trimmed:match("^%d%d%d%d%-%d%d%-%d%d") then return "date" end
  if tonumber(trimmed) then return "number" end
  if trimmed:match("^%[%[.+%]%]$") then return "link" end
  return "text"
end

--- Map a value type to its highlight group.
---@param vtype string from classify_value()
---@return string highlight_group
local function value_highlight(vtype)
  local map = {
    boolean = "VaultFieldValueBool",
    date = "VaultFieldValueDate",
    number = "VaultFieldValueNumber",
    link = "VaultFieldValueLink",
    text = "VaultFieldValue",
    empty = "VaultFieldValue",
  }
  return map[vtype] or "VaultFieldValue"
end

-- ---------------------------------------------------------------------------
-- Code block / code span / frontmatter exclusion
-- ---------------------------------------------------------------------------

--- Build a function that checks if a position is inside a code block or code span.
--- Reuses the same treesitter approach as tag_highlights.lua.
---@param bufnr number
---@return fun(row: number, col: number): boolean
local function build_code_exclusion(bufnr)
  local ranges = {}

  -- Fenced and indented code blocks from markdown parser
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
  if ok and parser then
    local tree = parser:parse()[1]
    if tree then
      local root = tree:root()

      for _, query_str in ipairs({
        "(fenced_code_block) @code",
        "(indented_code_block) @code",
      }) do
        local q_ok, query = pcall(vim.treesitter.query.parse, "markdown", query_str)
        if q_ok and query then
          for _, node in query:iter_captures(root, bufnr, 0, -1) do
            local sr, sc, er, ec = node:range()
            ranges[#ranges + 1] = { sr, sc, er, ec }
          end
        end
      end
    end
  end

  -- Inline code spans from markdown_inline parser
  local iok, iparser = pcall(vim.treesitter.get_parser, bufnr, "markdown_inline")
  if iok and iparser then
    local itrees = iparser:parse()
    for _, itree in ipairs(itrees) do
      local iroot = itree:root()
      local cs_ok, cs_query = pcall(vim.treesitter.query.parse, "markdown_inline", "(code_span) @code")
      if cs_ok and cs_query then
        for _, node in cs_query:iter_captures(iroot, bufnr, 0, -1) do
          local sr, sc, er, ec = node:range()
          ranges[#ranges + 1] = { sr, sc, er, ec }
        end
      end
    end
  end

  return function(row, col)
    for _, r in ipairs(ranges) do
      local sr, sc, er, ec = r[1], r[2], r[3], r[4]
      if row > sr and row < er then return true end
      if row == sr and row == er and col >= sc and col < ec then return true end
      if row == sr and row ~= er and col >= sc then return true end
      if row == er and row ~= sr and col < ec then return true end
    end
    return false
  end
end

--- Find the line range of YAML frontmatter (if present).
--- Returns (start_line, end_line) as 0-indexed, or nil if no frontmatter.
---@param bufnr number
---@return number|nil, number|nil
local function get_frontmatter_range(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(5, vim.api.nvim_buf_line_count(bufnr)), false)
  if not lines[1] or lines[1] ~= "---" then return nil, nil end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local max_scan = math.min(line_count, 200)
  for i = 2, max_scan do
    local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
    if line == "---" or line == "..." then
      return 0, i - 1 -- 0-indexed
    end
  end
  return nil, nil
end

-- ---------------------------------------------------------------------------
-- Field parsing
-- ---------------------------------------------------------------------------

--- A parsed inline field occurrence.
---@class InlineField
---@field key string field key name
---@field value string raw value text
---@field syntax "bracket"|"paren"|"standalone" which syntax form
---@field row number 0-indexed line number
---@field col_start number 0-indexed byte offset of the entire field (including delimiter)
---@field col_key_start number 0-indexed byte offset of key start
---@field col_key_end number 0-indexed byte offset past key end
---@field col_sep_start number 0-indexed byte offset of first ':'
---@field col_sep_end number 0-indexed byte offset past second ':'
---@field col_val_start number 0-indexed byte offset of value start
---@field col_val_end number 0-indexed byte offset past value end
---@field col_end number 0-indexed byte offset past the entire field (including delimiter)

--- Scan a single line for all bracketed inline fields: [key:: value]
--- Returns a list of InlineField tables.
---@param line string
---@param row number 0-indexed
---@return InlineField[]
local function find_bracket_fields(line, row)
  local fields = {}
  local pos = 1

  while pos <= #line do
    -- Find next '[' that could start a field
    local bracket_pos = line:find("%[", pos, false)
    if not bracket_pos then break end

    -- Must not be a wikilink: check for [[
    if line:sub(bracket_pos, bracket_pos + 1) == "[[" then
      pos = bracket_pos + 2
      goto continue
    end

    -- Must not be a footnote ref: [^
    if line:sub(bracket_pos + 1, bracket_pos + 1) == "^" then
      pos = bracket_pos + 2
      goto continue
    end

    -- Try to match [key:: value] starting at this position
    local key, value, match_end = line:match("^%[([%w_%-]+)::%s*(.-)%]()", bracket_pos)
    if key then
      -- Verify this is not a markdown link [text](url) — check char after ]
      local after_bracket = line:sub(match_end, match_end)
      if after_bracket == "(" then
        pos = match_end
        goto continue
      end

      -- Reject if key looks like a URL scheme
      if key:match("^https?$") then
        pos = match_end
        goto continue
      end

      -- Calculate precise byte positions (all 0-indexed)
      local col_bracket_open = bracket_pos - 1
      local col_key_start = bracket_pos -- 0-indexed: bracket_pos is 1-indexed pos of [, key starts at bracket_pos+1 (1-indexed) = bracket_pos (0-indexed)
      local col_key_end = col_key_start + #key
      local col_sep_start = col_key_end
      local col_sep_end = col_sep_start + 2  -- '::'

      -- Find actual value start (after :: and optional space)
      local after_sep = line:sub(col_sep_end + 1 + 1) -- convert back to 1-indexed
      local space_skip = 0
      if after_sep:sub(1, 1) == " " then space_skip = 1 end

      local col_val_start = col_sep_end + space_skip
      local col_val_end = col_val_start + #value
      local col_bracket_close = match_end - 2  -- 0-indexed position of ]
      local col_end = match_end - 1             -- 0-indexed position past ]

      fields[#fields + 1] = {
        key = key,
        value = value,
        syntax = "bracket",
        row = row,
        col_start = col_bracket_open,
        col_key_start = col_key_start,
        col_key_end = col_key_end,
        col_sep_start = col_sep_start,
        col_sep_end = col_sep_end,
        col_val_start = col_val_start,
        col_val_end = col_val_end,
        col_end = col_end,
      }

      pos = match_end
    else
      pos = bracket_pos + 1
    end

    ::continue::
  end

  return fields
end

--- Scan a single line for all parenthesized inline fields: (key:: value)
---@param line string
---@param row number 0-indexed
---@return InlineField[]
local function find_paren_fields(line, row)
  local fields = {}
  local pos = 1

  while pos <= #line do
    local paren_pos = line:find("%(", pos, false)
    if not paren_pos then break end

    local key, value, match_end = line:match("^%(([%w_%-]+)::%s*(.-)%)()", paren_pos)
    if key then
      if key:match("^https?$") then
        pos = match_end
        goto continue
      end

      local col_paren_open = paren_pos - 1
      local col_key_start = paren_pos  -- 0-indexed
      local col_key_end = col_key_start + #key
      local col_sep_start = col_key_end
      local col_sep_end = col_sep_start + 2

      local after_sep = line:sub(col_sep_end + 1 + 1)
      local space_skip = 0
      if after_sep:sub(1, 1) == " " then space_skip = 1 end

      local col_val_start = col_sep_end + space_skip
      local col_val_end = col_val_start + #value
      local col_end = match_end - 1

      fields[#fields + 1] = {
        key = key,
        value = value,
        syntax = "paren",
        row = row,
        col_start = col_paren_open,
        col_key_start = col_key_start,
        col_key_end = col_key_end,
        col_sep_start = col_sep_start,
        col_sep_end = col_sep_end,
        col_val_start = col_val_start,
        col_val_end = col_val_end,
        col_end = col_end,
      }

      pos = match_end
    else
      pos = paren_pos + 1
    end

    ::continue::
  end

  return fields
end

--- Scan a single line for standalone inline fields: key:: value
--- These must appear at the start of a line (optionally after a list marker).
---@param line string
---@param row number 0-indexed
---@return InlineField[]
local function find_standalone_fields(line, row)
  local fields = {}

  -- Pattern 1: list item with field — `- key:: value` or `* key:: value`
  local list_prefix, key, value = line:match("^(%s*[-*]%s+)([%w_%-]+)::%s*(.*)")
  if list_prefix and key then
    if not key:match("^https?$") then
      local col_key_start = #list_prefix  -- 0-indexed
      local col_key_end = col_key_start + #key
      local col_sep_start = col_key_end
      local col_sep_end = col_sep_start + 2
      -- Find value start (skip optional whitespace after ::)
      local rest_after_sep = line:sub(col_sep_end + 1 + 1)  -- 1-indexed
      local space_skip = 0
      if rest_after_sep:sub(1, 1) == " " then space_skip = 1 end
      local trimmed_value = vim.trim(value)
      local col_val_start = col_sep_end + space_skip
      local col_val_end = col_val_start + #trimmed_value

      fields[#fields + 1] = {
        key = key,
        value = trimmed_value,
        syntax = "standalone",
        row = row,
        col_start = col_key_start,
        col_key_start = col_key_start,
        col_key_end = col_key_end,
        col_sep_start = col_sep_start,
        col_sep_end = col_sep_end,
        col_val_start = col_val_start,
        col_val_end = col_val_end,
        col_end = #line,
      }
      return fields
    end
  end

  -- Pattern 2: bare line — `key:: value`
  key, value = line:match("^([%w_%-]+)::%s*(.*)")
  if key and not key:match("^https?$") then
    local col_key_start = 0
    local col_key_end = #key
    local col_sep_start = col_key_end
    local col_sep_end = col_sep_start + 2
    local rest_after_sep = line:sub(col_sep_end + 1 + 1)
    local space_skip = 0
    if rest_after_sep:sub(1, 1) == " " then space_skip = 1 end
    local trimmed_value = vim.trim(value)
    local col_val_start = col_sep_end + space_skip
    local col_val_end = col_val_start + #trimmed_value

    fields[#fields + 1] = {
      key = key,
      value = trimmed_value,
      syntax = "standalone",
      row = row,
      col_start = 0,
      col_key_start = col_key_start,
      col_key_end = col_key_end,
      col_sep_start = col_sep_start,
      col_sep_end = col_sep_end,
      col_val_start = col_val_start,
      col_val_end = col_val_end,
      col_end = #line,
    }
  end

  return fields
end

--- Parse all inline fields from a single line.
---@param line string
---@param row number 0-indexed
---@return InlineField[]
local function parse_line(line, row)
  local all = {}

  -- Bracketed fields: [key:: value]
  for _, f in ipairs(find_bracket_fields(line, row)) do
    all[#all + 1] = f
  end

  -- Parenthesized fields: (key:: value)
  for _, f in ipairs(find_paren_fields(line, row)) do
    all[#all + 1] = f
  end

  -- Standalone fields: key:: value (only if no bracketed/paren fields found on this line,
  -- to avoid double-matching lines like `status:: [priority:: 1]`)
  -- Actually, standalone matches anchor to line start, so they won't conflict with
  -- mid-line bracket fields. But we should still check.
  for _, f in ipairs(find_standalone_fields(line, row)) do
    -- Verify this standalone field doesn't overlap with any bracket/paren field
    local dominated = false
    for _, existing in ipairs(all) do
      if f.col_key_start >= existing.col_start and f.col_key_start < existing.col_end then
        dominated = true
        break
      end
    end
    if not dominated then
      all[#all + 1] = f
    end
  end

  return all
end

-- ---------------------------------------------------------------------------
-- Core highlight application
-- ---------------------------------------------------------------------------

--- Clear all inline field highlights from a buffer.
---@param bufnr number
local function clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
end

--- Place extmarks for a single parsed field.
---@param bufnr number
---@param field InlineField
local function highlight_field(bufnr, field)
  local row = field.row
  local priority = 185  -- below tags (190) and wikilinks (200)

  -- Opening delimiter (bracket or paren)
  if field.syntax == "bracket" or field.syntax == "paren" then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, field.col_start, {
      end_col = field.col_start + 1,
      hl_group = "VaultFieldBracket",
      hl_mode = "combine",
      priority = priority,
    })
  end

  -- Key
  pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, field.col_key_start, {
    end_col = field.col_key_end,
    hl_group = "VaultFieldKey",
    hl_mode = "combine",
    priority = priority,
  })

  -- Separator ::
  pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, field.col_sep_start, {
    end_col = field.col_sep_end,
    hl_group = "VaultFieldSep",
    hl_mode = "combine",
    priority = priority,
  })

  -- Value (type-aware highlighting)
  if field.value ~= "" then
    local vtype = classify_value(field.value)
    local vhl = value_highlight(vtype)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, field.col_val_start, {
      end_col = field.col_val_end,
      hl_group = vhl,
      hl_mode = "combine",
      priority = priority,
    })
  end

  -- Closing delimiter
  if field.syntax == "bracket" or field.syntax == "paren" then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, field.col_end - 1, {
      end_col = field.col_end,
      hl_group = "VaultFieldBracket",
      hl_mode = "combine",
      priority = priority,
    })
  end
end

--- Scan buffer and apply highlights to all inline fields.
---@param bufnr number
local function apply(bufnr)
  if not M.enabled then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local fname = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_path(fname) then
    clear(bufnr)
    return
  end

  clear(bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local is_in_code = build_code_exclusion(bufnr)
  local fm_start, fm_end = get_frontmatter_range(bufnr)

  for i, line in ipairs(lines) do
    local row = i - 1  -- 0-indexed

    -- Skip frontmatter lines
    if fm_start and fm_end and row >= fm_start and row <= fm_end then
      goto next_line
    end

    -- Parse all fields on this line
    local fields = parse_line(line, row)

    for _, field in ipairs(fields) do
      -- Skip fields inside code blocks/spans
      if not is_in_code(row, field.col_key_start) then
        highlight_field(bufnr, field)
      end
    end

    ::next_line::
  end
end

-- Expose for external use (benchmarking, testing)
M.apply = apply

-- ---------------------------------------------------------------------------
-- Debounced update
-- ---------------------------------------------------------------------------

---@param bufnr number
local function schedule_update(bufnr)
  if timer then
    timer:stop()
  end
  timer = vim.uv.new_timer()
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      apply(bufnr)
    end
  end))
end

-- ---------------------------------------------------------------------------
-- Toggle
-- ---------------------------------------------------------------------------

function M.toggle()
  M.enabled = not M.enabled
  if M.enabled then
    apply(vim.api.nvim_get_current_buf())
  else
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      clear(buf)
    end
  end
  vim.notify(
    "Vault: inline field highlights " .. (M.enabled and "ON" or "OFF"),
    vim.log.levels.INFO
  )
end

-- ---------------------------------------------------------------------------
-- Field extraction (for external consumers)
-- ---------------------------------------------------------------------------

--- Extract all inline fields from the current buffer.
--- Returns a list of { key, value, syntax, row, col_start } tables.
--- Useful for the field key registry and completion.
---@param bufnr number
---@return InlineField[]
function M.get_buffer_fields(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local is_in_code = build_code_exclusion(bufnr)
  local fm_start, fm_end = get_frontmatter_range(bufnr)
  local result = {}

  for i, line in ipairs(lines) do
    local row = i - 1
    if fm_start and fm_end and row >= fm_start and row <= fm_end then
      goto skip
    end

    local fields = parse_line(line, row)
    for _, field in ipairs(fields) do
      if not is_in_code(row, field.col_key_start) then
        result[#result + 1] = field
      end
    end

    ::skip::
  end

  return result
end

-- ---------------------------------------------------------------------------
-- Field key registry (vault-wide known keys)
-- ---------------------------------------------------------------------------

--- Collect all unique field keys across the vault index.
--- Returns a sorted list of key names that have been used in inline fields.
--- Falls back to scanning the current buffer if no index is available.
---@return string[]
function M.get_known_keys()
  local keys_set = {}

  -- Try to get keys from the query index (vault-wide)
  local ok, query = pcall(require, "andrew.vault.query")
  if ok and query.get_index then
    local index_ok, index = pcall(query.get_index)
    if index_ok and index and index.pages then
      for _, page in pairs(index.pages) do
        -- Inline fields are merged at the page top level.
        -- Known page.file fields to skip:
        local skip = {
          file = true,
        }
        for k, _ in pairs(page) do
          if type(k) == "string" and not skip[k] then
            keys_set[k] = true
          end
        end
      end
    end
  end

  -- Also scan current buffer for immediate field keys
  local bufnr = vim.api.nvim_get_current_buf()
  local buf_fields = M.get_buffer_fields(bufnr)
  for _, f in ipairs(buf_fields) do
    keys_set[f.key] = true
  end

  -- Convert to sorted list
  local keys = {}
  for k in pairs(keys_set) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

-- ---------------------------------------------------------------------------
-- Field navigation (jump to next/prev inline field)
-- ---------------------------------------------------------------------------

--- Jump to the next or previous inline field in the buffer.
---@param direction 1|-1 forward or backward
local function jump_field(direction)
  local bufnr = vim.api.nvim_get_current_buf()
  local all_fields = M.get_buffer_fields(bufnr)

  if #all_fields == 0 then return end

  local cur_row, cur_col = unpack(vim.api.nvim_win_get_cursor(0))
  cur_row = cur_row - 1  -- 0-indexed
  cur_col = cur_col       -- already 0-indexed

  if direction == 1 then
    for _, f in ipairs(all_fields) do
      if f.row > cur_row or (f.row == cur_row and f.col_start > cur_col) then
        vim.api.nvim_win_set_cursor(0, { f.row + 1, f.col_start })
        return
      end
    end
    -- Wrap to first
    local first = all_fields[1]
    vim.api.nvim_win_set_cursor(0, { first.row + 1, first.col_start })
  else
    for j = #all_fields, 1, -1 do
      local f = all_fields[j]
      if f.row < cur_row or (f.row == cur_row and f.col_start < cur_col) then
        vim.api.nvim_win_set_cursor(0, { f.row + 1, f.col_start })
        return
      end
    end
    -- Wrap to last
    local last = all_fields[#all_fields]
    vim.api.nvim_win_set_cursor(0, { last.row + 1, last.col_start })
  end
end

-- ---------------------------------------------------------------------------
-- Completion source
-- ---------------------------------------------------------------------------

--- Insert-mode completion for inline field keys.
--- Triggered when typing inside `[` or `(` before `::`.
--- Uses vim.fn.complete() for a simple popup.
function M.complete_field_key()
  local line = vim.api.nvim_get_current_line()
  local col = vim.fn.col(".")  -- 1-indexed cursor position

  -- Find the start of the current key being typed.
  -- Look backwards from cursor for [ or ( that would start an inline field.
  local prefix_start = nil
  local prefix = ""

  for i = col - 1, 1, -1 do
    local ch = line:sub(i, i)
    if ch == "[" or ch == "(" then
      prefix_start = i + 1  -- 1-indexed position after the bracket
      prefix = line:sub(prefix_start, col - 1)
      break
    elseif not ch:match("[%w_%-]") then
      break
    end
  end

  if not prefix_start then return end

  -- Don't complete if :: already present (we are past the key)
  local rest = line:sub(prefix_start)
  if rest:find("::") then return end

  -- Get known keys and filter by prefix
  local keys = M.get_known_keys()
  local matches = {}
  local lower_prefix = prefix:lower()

  for _, key in ipairs(keys) do
    if key:lower():sub(1, #lower_prefix) == lower_prefix then
      matches[#matches + 1] = key .. ":: "
    end
  end

  if #matches > 0 then
    vim.fn.complete(prefix_start, matches)
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  define_highlights()

  local group = vim.api.nvim_create_augroup("VaultInlineFieldHL", { clear = true })

  -- Apply on buffer enter and after writes
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if M.enabled and engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            apply(ev.buf)
          end
        end, 30)
      end
    end,
  })

  -- Debounced update on text changes
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if M.enabled and engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
        schedule_update(ev.buf)
      end
    end,
  })

  -- Re-define highlights when colorscheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = define_highlights,
  })

  -- Clean up on buffer delete
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      clear(ev.buf)
    end,
  })

  -- Commands
  vim.api.nvim_create_user_command("VaultFieldHLToggle", function()
    M.toggle()
  end, { desc = "Toggle inline field highlighting" })

  vim.api.nvim_create_user_command("VaultFieldHLRefresh", function()
    apply(vim.api.nvim_get_current_buf())
  end, { desc = "Refresh inline field highlights in current buffer" })

  vim.api.nvim_create_user_command("VaultFieldList", function()
    local fields = M.get_buffer_fields(vim.api.nvim_get_current_buf())
    if #fields == 0 then
      vim.notify("No inline fields found in this buffer", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, f in ipairs(fields) do
      items[#items + 1] = string.format(
        "L%d  %s [%s:: %s] (%s)",
        f.row + 1, f.syntax, f.key, f.value, classify_value(f.value)
      )
    end
    vim.notify(table.concat(items, "\n"), vim.log.levels.INFO)
  end, { desc = "List all inline fields in current buffer" })

  -- Buffer-local keymaps
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vft", function()
        M.toggle()
      end, {
        buffer = ev.buf,
        desc = "Fields: highlights toggle",
        silent = true,
      })

      vim.keymap.set("n", "]f", function()
        jump_field(1)
      end, {
        buffer = ev.buf,
        desc = "Next inline field",
        silent = true,
      })

      vim.keymap.set("n", "[f", function()
        jump_field(-1)
      end, {
        buffer = ev.buf,
        desc = "Previous inline field",
        silent = true,
      })

      vim.keymap.set("i", "<C-x><C-f>", function()
        M.complete_field_key()
      end, {
        buffer = ev.buf,
        desc = "Complete inline field key",
        silent = true,
      })
    end,
  })
end

return M
```

---

## Integration

### 1. Register in vault init

**File:** `lua/andrew/vault/init.lua`

Add after the `tag_highlights` setup line:

```lua
-- Load inline field highlighting
require("andrew.vault.inline_fields").setup()
```

### 2. Add config section

**File:** `lua/andrew/vault/config.lua`

Add to the config table:

```lua
-- ---------------------------------------------------------------------------
-- Inline field highlights
-- ---------------------------------------------------------------------------
M.inline_fields = {
  enabled = true,
  debounce_ms = 200,
}
```

### 3. Query index integration

The query index (`query/index.lua`) already parses inline fields via `_extract_inline_fields()`. The parsing logic in `inline_fields.lua` mirrors this exactly, ensuring consistency between what is highlighted and what is queryable.

The `_extract_inline_fields()` method (index.lua lines 579-609) handles:
- `key:: value` standalone on a line
- `[key:: value]` bracketed
- `(key:: value)` parenthesized

The same patterns are used in `inline_fields.lua` for highlighting. The key constraint `[%w_%-]+` and the `::` separator are identical in both modules.

**Field values are already queryable** via DQL:

```dataview
TABLE status, priority, due
FROM "Projects"
WHERE status = "Active"
SORT priority ASC
```

Where `status`, `priority`, and `due` can be either frontmatter fields or inline fields — the index merges them into the page table at the same level (index.lua lines 336-344).

### 4. Field key registry for completion

The `M.get_known_keys()` function aggregates field keys from:

1. **The vault index** — all page-level keys across all indexed files (covers both frontmatter and inline fields).
2. **The current buffer** — for immediate feedback on fields not yet in the index.

This list feeds the `<C-x><C-f>` insert-mode completion. Future improvement: integrate with nvim-cmp as a custom source.

---

## Keymaps

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| `n` | `<leader>vft` | `M.toggle()` | Toggle inline field highlighting on/off |
| `n` | `]f` | `jump_field(1)` | Jump to next inline field |
| `n` | `[f` | `jump_field(-1)` | Jump to previous inline field |
| `i` | `<C-x><C-f>` | `M.complete_field_key()` | Complete field key name |

Commands:

| Command | Description |
|---------|-------------|
| `:VaultFieldHLToggle` | Toggle inline field highlighting |
| `:VaultFieldHLRefresh` | Force refresh highlights in current buffer |
| `:VaultFieldList` | List all inline fields in current buffer (debug) |

---

## Testing

### Manual Verification

1. **Create a test note with various inline field patterns:**

   ```markdown
   ---
   title: Test Inline Fields
   status: Active
   ---

   # Inline Field Test

   This note has a bracketed field: [status:: Active] and continues with prose.

   A parenthesized field is hidden: (priority:: 1) in reading mode.

   Standalone fields on their own lines:

   due:: 2026-03-15
   assignee:: [[Alice]]
   completed:: false
   score:: 42

   Fields in list items:

   - priority:: 2
   - category:: Research
   - tags:: simulation, cfd

   ## Things That Should NOT Be Highlighted

   Normal brackets: [this is not a field] because no double colon.

   Markdown links: [click here](https://example.com) should not match.

   Wikilinks: [[Note Title]] should not match.

   Footnotes: [^1] should not match.

   Code spans: `[status:: Active]` should not highlight.

   ```python
   # This is code
   data = {"key:: value"}
   config["priority:: 1"]
   ```

   URLs: https://example.com should not match.
   ```

2. **Expected behavior:**
   - `[status:: Active]` — brackets gray, `status` red bold, `::` gray, `Active` green
   - `(priority:: 1)` — parens gray, `priority` red bold, `::` gray, `1` orange (number)
   - `due:: 2026-03-15` — `due` red bold, `::` gray, `2026-03-15` yellow (date)
   - `assignee:: [[Alice]]` — `assignee` red bold, `::` gray, `[[Alice]]` blue underlined (link)
   - `completed:: false` — `completed` red bold, `::` gray, `false` cyan italic (boolean)
   - `score:: 42` — `score` red bold, `::` gray, `42` orange (number)
   - List item fields highlighted same as standalone
   - Normal brackets, markdown links, wikilinks, footnotes — no highlight
   - Code spans and code blocks — no highlight
   - Frontmatter lines — no highlight

3. **Navigation:**
   - `]f` jumps to next inline field, `[f` jumps to previous
   - Wraps around at buffer boundaries

4. **Completion:**
   - Type `[` then `<C-x><C-f>` to see all known field keys
   - Type `[sta` then `<C-x><C-f>` to see filtered keys starting with "sta"

5. **Toggle:**
   - `<leader>vft` or `:VaultFieldHLToggle` turns highlights on/off

### Automated Test

Add to `tests/test_vault_fixes.lua`:

```lua
-- Test: inline_fields module structure
do
  local source = io.open("lua/andrew/vault/inline_fields.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    -- Core functionality present
    assert_true(content:find("VaultFieldKey") ~= nil, "defines VaultFieldKey highlight group")
    assert_true(content:find("VaultFieldValue") ~= nil, "defines VaultFieldValue group")
    assert_true(content:find("VaultFieldBracket") ~= nil, "defines VaultFieldBracket group")
    assert_true(content:find("nvim_buf_set_extmark") ~= nil, "uses extmarks")
    assert_true(content:find("build_code_exclusion") ~= nil, "has code block filtering")
    assert_true(content:find("find_bracket_fields") ~= nil, "parses bracket fields")
    assert_true(content:find("find_paren_fields") ~= nil, "parses paren fields")
    assert_true(content:find("find_standalone_fields") ~= nil, "parses standalone fields")
    assert_true(content:find("classify_value") ~= nil, "classifies value types")
    assert_true(content:find("schedule_update") ~= nil, "has debounced update")
    assert_true(content:find("jump_field") ~= nil, "has field navigation")
    assert_true(content:find("get_known_keys") ~= nil, "has key registry")
    assert_true(content:find("complete_field_key") ~= nil, "has key completion")
  end
end
```

### Unit Test for Parsing Logic

```lua
-- Test: inline field parsing correctness
do
  -- Simulate parse_line behavior
  local line1 = "This has [status:: Active] in it"
  local key, value = line1:match("%[([%w_%-]+)::%s*(.-)%]")
  assert_true(key == "status", "bracket field key extracted")
  assert_true(value == "Active", "bracket field value extracted")

  local line2 = "Hidden (priority:: 1) metadata"
  key, value = line2:match("%(([%w_%-]+)::%s*(.-)%)")
  assert_true(key == "priority", "paren field key extracted")
  assert_true(value == "1", "paren field value extracted")

  local line3 = "due:: 2026-03-15"
  key, value = line3:match("^([%w_%-]+)::%s*(.*)")
  assert_true(key == "due", "standalone field key extracted")
  assert_true(value == "2026-03-15", "standalone field value extracted")

  -- Negative cases
  local line4 = "[click here](https://example.com)"
  key = line4:match("%[([%w_%-]+)::%s*(.-)%]")
  assert_true(key == nil, "markdown link not matched as field")

  local line5 = "[[Note Title]]"
  key = line5:match("%[([%w_%-]+)::%s*(.-)%]")
  assert_true(key == nil, "wikilink not matched as field")

  local line6 = "[^footnote]"
  key = line6:match("%[([%w_%-]+)::%s*(.-)%]")
  assert_true(key == nil, "footnote not matched as field")
end
```

### Performance Verification

In a vault note with 30+ inline fields:

```vim
:lua local s = vim.uv.hrtime(); require("andrew.vault.inline_fields").apply(0); print(("%.1f ms"):format((vim.uv.hrtime() - s) / 1e6))
```

Target: < 15ms for a 30-field buffer. The main cost is `build_code_exclusion()` (treesitter parse) which runs once per update. Field pattern matching is fast Lua string scanning.

---

## Data Structures

### InlineField (parsed field occurrence)

```lua
---@class InlineField
---@field key string          -- "status", "due", "priority"
---@field value string        -- "Active", "2026-03-15", "1"
---@field syntax string       -- "bracket" | "paren" | "standalone"
---@field row number          -- 0-indexed line number
---@field col_start number    -- 0-indexed byte offset of full field start
---@field col_key_start number
---@field col_key_end number
---@field col_sep_start number
---@field col_sep_end number
---@field col_val_start number
---@field col_val_end number
---@field col_end number      -- 0-indexed byte offset past full field end
```

### Value Types (for highlighting)

| Type | Pattern | Highlight | Example |
|------|---------|-----------|---------|
| `text` | Default | `VaultFieldValue` (green) | `Active`, `Research` |
| `number` | `tonumber(v)` succeeds | `VaultFieldValueNumber` (orange) | `42`, `3.14` |
| `date` | `%d%d%d%d%-%d%d%-%d%d` | `VaultFieldValueDate` (yellow) | `2026-03-15` |
| `link` | `^%[%[.+%]%]$` | `VaultFieldValueLink` (blue underline) | `[[Alice]]` |
| `boolean` | `true` or `false` | `VaultFieldValueBool` (cyan italic) | `true`, `false` |
| `empty` | Trimmed to `""` | `VaultFieldValue` (green) | (empty value) |

### Page-Level Field Merge (in query/index.lua)

When the index builds a page, inline fields are merged at the page top level alongside frontmatter fields. Inline fields can **shadow** frontmatter fields (inline takes precedence since it's merged second):

```lua
-- index.lua lines 336-344
for k, v in pairs(fm_fields) do
  if k ~= "tags" then
    page[k] = v
  end
end
for k, v in pairs(body_fields) do
  page[k] = v   -- inline fields shadow frontmatter
end
```

This means a DQL query like `WHERE status = "Active"` works identically regardless of whether `status` is defined in frontmatter or as `[status:: Active]` in the body.

---

## Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| `[:: value]` (empty key) | Not highlighted — key pattern requires `[%w_%-]+` (at least one char) |
| `[key:value]` (single colon) | Not highlighted — requires `::` double colon |
| `[key ::value]` (space before ::) | Not highlighted — key pattern is `[%w_%-]+` followed immediately by `::` |
| `[key:: ]` (empty value) | Highlighted — key and separator shown, empty value |
| `[key::]` (no space, no value) | Highlighted — key and separator shown |
| `[my-key:: value]` (hyphenated key) | Highlighted — hyphens allowed in key pattern |
| `[my_key:: value]` (underscored key) | Highlighted — underscores allowed |
| `[KEY:: VALUE]` (uppercase) | Highlighted — case preserved, completion case-insensitive |
| `[a:: b] and [c:: d]` (multiple on one line) | Both highlighted independently |
| `(key:: value) [key:: value]` (mixed syntax) | Both highlighted with correct delimiters |
| `- [status:: Active]` (in list item) | Highlighted — list context does not affect bracket parsing |
| `- status:: Active` (standalone in list) | Highlighted — list marker detected, key starts after marker |
| `https://example.com` | Not highlighted — `https` key rejected by URL filter |
| `[text](url)` | Not highlighted — post-`]` `(` check rejects markdown links |
| `[[wikilink]]` | Not highlighted — `[[` detected as wikilink start |
| `[^footnote]` | Not highlighted — `^` after `[` detected as footnote |
| Empty buffer | No highlights, no errors |
| Non-vault markdown file | Skipped — `is_vault_path()` check |
| 1000+ line buffer | Debounced — only re-scans after 200ms idle |
| Field inside table cell `\| [k:: v] \|` | Highlighted — pipes do not interfere with bracket parsing |
| Nested brackets `[[key:: [[link]]]]` | Outer `[[` detected as wikilink, inner not parsed as field |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `engine.lua` | `is_vault_path()` for vault detection | Yes |
| `config.lua` | Inline field config section (optional) | No (fallback defaults) |
| `query/index.lua` | `_extract_inline_fields()` — shared parsing semantics | No (independent highlight module) |
| `query/` module | `get_index()` for vault-wide key registry | No (fallback to buffer-local keys) |
| Treesitter `markdown` parser | Code block exclusion | No (degrades gracefully) |
| Treesitter `markdown_inline` parser | Code span exclusion | No (degrades gracefully) |

---

## Key Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/inline_fields.lua` | **New file** — complete module |
| `lua/andrew/vault/init.lua` | Add `require("andrew.vault.inline_fields").setup()` |
| `lua/andrew/vault/config.lua` | Add `inline_fields` config section (optional) |

---

## Risk Assessment

**Risk: Low**

- New module, no existing code modified (except one `require` line in `init.lua` and one config block).
- Uses established patterns from `tag_highlights.lua` — same extmark approach, same debounce, same autocmd structure, same code exclusion.
- Extmarks with `priority = 185` won't conflict with tag highlights (190), wikilink highlights (200), render-markdown (1000+), or diagnostics (~10).
- Treesitter code exclusion degrades gracefully — if parser isn't available, fields inside code blocks may get highlighted (false positive, not false negative).
- Toggle command and `:VaultFieldHLRefresh` provide easy control.
- Parsing logic mirrors `query/index.lua:_extract_inline_fields()` exactly, so what gets highlighted matches what gets indexed. No hidden inconsistencies.

---

## Future Enhancements

1. **nvim-cmp source** — Replace the basic `vim.fn.complete()` with a proper nvim-cmp custom source for inline field key completion. Would provide fuzzy matching, documentation popups, and type annotations.

2. **Field value completion** — After typing `[status:: `, offer known values for the `status` key based on what other notes use (e.g., `Active`, `Complete`, `Blocked`).

3. **Field validation** — Underline or dim fields with unknown keys (keys not seen elsewhere in the vault), similar to how `linkdiag.lua` marks broken wikilinks.

4. **Inline field quick-edit** — `<leader>vfe` on a field opens a small prompt to change the value, updating the buffer in place.

5. **Virtual text type annotations** — Show a subtle type indicator after field values (e.g., a dim `date` or `link` label) using virtual text extmarks.

6. **Shared code exclusion utility** — Extract `build_code_exclusion()` and `get_frontmatter_range()` into a shared `highlight_utils.lua` module. Both `tag_highlights.lua` and `inline_fields.lua` use identical implementations. This refactoring is **not recommended yet** — the duplication is small and the modules are independently testable.

---

## Relationship to Existing Modules

### Tag Highlights (#19)

Both modules are independent extmark-based highlighting systems that follow the same architectural pattern:

- Same namespace/extmark approach
- Same debounce pattern
- Same autocmd structure (BufEnter, TextChanged, ColorScheme, BufDelete)
- Same code exclusion logic
- Compatible extmark priorities (tags: 190, inline fields: 185)
- Both register in `init.lua` with a single `require().setup()` call

### Query Engine

The inline fields module is the **visual counterpart** to the query engine's data extraction:

- `query/index.lua:_extract_inline_fields()` extracts field data for querying
- `inline_fields.lua` highlights those same fields for visual feedback
- Both use the same regex patterns and key constraints
- The key registry bridges both: index provides vault-wide keys, buffer provides local keys

### Frontmatter

Inline fields complement frontmatter:

- Frontmatter: structured YAML at the top of a note (managed by `frontmatter.lua`)
- Inline fields: metadata embedded in prose (managed by `inline_fields.lua`)
- Both are merged into the page table by `query/index.lua` for DQL queries
- Inline fields shadow frontmatter fields when both define the same key
