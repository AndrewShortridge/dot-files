# 30 — Table Creation Helper

## Problem

The `vim-table-mode` plugin handles table formatting and cell navigation after a
table exists, but there is no quick way to scaffold a new table from dimensions.
Creating a 5-column, 10-row table currently requires manually typing `|` and
`---` separators line by line, then letting `vim-table-mode` auto-align. The
existing LuaSnip snippets (`tbl` and `table`) produce fixed 2-column and
3-column tables with a single data row — they cannot generate arbitrary
dimensions.

### Current State

| Component | What It Does | Limitation |
|-----------|-------------|------------|
| **vim-table-mode** (`<leader>Tm`) | Auto-formats tables, tab navigation between cells | Requires a table to already exist; no scaffolding command |
| **`tbl` snippet** | Inserts a 2-column, 1-row table with `Header 1 \| Header 2` | Fixed dimensions; no way to specify column/row count |
| **`table` snippet** | Inserts a 3-column, 1-row table with `Header 1 \| Header 2 \| Header 3` | Fixed dimensions; same limitation |
| **`:TableModeToggle`** | Enables table-mode auto-formatting | Does not create tables |
| **No `:TableCreate` command** | — | Cannot scaffold NxM tables from the command line |
| **No interactive prompt** | — | No keymap to prompt for dimensions and optional headers |

### Why Current Design Cannot Do It

The `tbl` and `table` snippets use static `text_node` and `insert_node` calls
with hardcoded column counts. LuaSnip's `dynamic_node` can generate nodes at
expansion time based on user input, but the current snippets do not use this
mechanism. There is also no Lua utility function for generating a table string
from dimensions, so even a command-based approach has no building block to call.

---

## Goal

1. A `:TableCreate CxR` command scaffolds a C-column, R-row markdown table with
   header separator at the cursor position (e.g., `:TableCreate 3x4` produces
   3 columns and 4 data rows, plus the header row and separator row).
2. `:TableCreate CxR Name|Age|City` accepts optional pipe-delimited header names
   that replace the default `Header 1`, `Header 2`, etc. placeholders.
3. `:TableCreate CxR Name|Age|City l|c|r` accepts optional alignment specifiers
   as a third argument (`l` = left `:---`, `c` = center `:---:`, `r` = right
   `---:`), defaulting to left-aligned `---` when omitted.
4. `<leader>mT` prompts interactively for dimensions and optional headers, then
   inserts the table.
5. The `tbl` LuaSnip snippet is enhanced with a `dynamic_node` that reads column
   and row counts from the first insert node and generates the appropriate table.
6. Generated tables are properly aligned with consistent `|` separators, padded
   cells, and a `---` header separator row.
7. `vim-table-mode` is auto-enabled after table creation so the user can
   immediately tab between cells and have auto-alignment on edits.
8. All table creation logic lives in a single utility function
   (`generate_table()`) that the command, keymap, and snippet all share.

---

## Approach

### Architecture

A single utility function `generate_table(cols, rows, headers, alignments)`
returns a list of strings (one per line) representing the markdown table. Three
consumers call this function:

```
generate_table(cols, rows, headers, alignments) -> string[]
    ^           ^           ^           ^
    |           |           |           |
:TableCreate   <leader>mT  tbl snippet (dynamic_node)
```

The function lives in `ftplugin/markdown.lua` as a local, since all three
consumers are defined in that same file (the command and keymap) or in
`luasnippets/markdown.lua` (the snippet). For the snippet's access, the function
is exposed via a small module at `lua/andrew/utils/table-gen.lua` that the
snippet file can `require()`.

### Generated Table Format

For `:TableCreate 3x2 Name|Age|City c|l|r`:

```markdown
| Name | Age | City |
|:----:|-----|-----:|
|      |     |      |
|      |     |      |
```

Rules:
- Header cells are padded to at least 4 characters (the width of `---` plus
  padding) or the header text width, whichever is larger.
- The separator row uses `---` variants based on alignment: `----` (default/left),
  `:---` (explicit left), `:---:` (center), `---:` (right).
- Data rows contain empty cells padded to match the column width.
- When no headers are provided, defaults to `Header 1`, `Header 2`, etc.
- When no alignments are provided, defaults to `---` (unspecified, which
  renders as left-aligned in most markdown renderers).

### Alignment Specifier Parsing

The third argument to `:TableCreate` (or the third prompt answer) is a
pipe-delimited string of single characters:

| Specifier | Separator | Meaning |
|-----------|-----------|---------|
| `l` or `-` | `----` | Left-aligned (default) |
| `c` | `:---:` | Center-aligned |
| `r` | `---:` | Right-aligned |

If fewer alignment specifiers are provided than columns, remaining columns
default to left-aligned. Extra specifiers are ignored.

---

## Implementation Steps

### Step 1: Create `lua/andrew/utils/table-gen.lua`

This module contains the pure-function table generator with no Neovim API
dependencies (it only returns strings), making it testable and reusable.

**File: `lua/andrew/utils/table-gen.lua`** (new)

```lua
--- Markdown table generation utility.
--- Pure function: returns a list of strings, no side effects.

local M = {}

--- Map a single alignment character to a separator cell.
--- @param char string  "l", "c", "r", or "-"
--- @param width number  Minimum content width (not counting outer pipes/spaces)
--- @return string  The separator cell content (e.g., ":---:", "----", "---:")
local function align_separator(char, width)
  local min_dashes = math.max(width, 3)
  if char == "c" then
    return ":" .. string.rep("-", min_dashes - 2) .. ":"
  elseif char == "r" then
    return string.rep("-", min_dashes - 1) .. ":"
  else
    -- "l" or default: plain dashes (no colon = left-aligned by convention)
    return string.rep("-", min_dashes)
  end
end

--- Generate a markdown table as a list of strings.
--- @param cols number  Number of columns (>= 1)
--- @param rows number  Number of data rows (>= 0; 0 = header + separator only)
--- @param headers? string[]  Optional header names (defaults to "Header 1", etc.)
--- @param alignments? string  Optional pipe-delimited alignment string (e.g., "l|c|r")
--- @return string[]  Lines of the generated table
function M.generate(cols, rows, headers, alignments)
  cols = math.max(1, math.floor(cols))
  rows = math.max(0, math.floor(rows))

  -- Build header names
  local hdrs = {}
  for c = 1, cols do
    hdrs[c] = (headers and headers[c] and headers[c] ~= "")
      and headers[c]
      or ("Header " .. c)
  end

  -- Parse alignment specifiers
  local aligns = {}
  if alignments and alignments ~= "" then
    for spec in alignments:gmatch("[^|]+") do
      aligns[#aligns + 1] = spec:match("^%s*(.-)%s*$"):sub(1, 1):lower()
    end
  end

  -- Compute column widths: max of header text and minimum separator width (3)
  local widths = {}
  for c = 1, cols do
    widths[c] = math.max(#hdrs[c], 3)
  end

  -- Build header row
  local header_cells = {}
  for c = 1, cols do
    header_cells[c] = " " .. hdrs[c] .. string.rep(" ", widths[c] - #hdrs[c]) .. " "
  end
  local header_line = "|" .. table.concat(header_cells, "|") .. "|"

  -- Build separator row
  local sep_cells = {}
  for c = 1, cols do
    local a = aligns[c] or "-"
    sep_cells[c] = " " .. align_separator(a, widths[c]) .. " "
  end
  local sep_line = "|" .. table.concat(sep_cells, "|") .. "|"

  -- Build data rows
  local empty_cells = {}
  for c = 1, cols do
    empty_cells[c] = " " .. string.rep(" ", widths[c]) .. " "
  end
  local empty_line = "|" .. table.concat(empty_cells, "|") .. "|"

  -- Assemble lines
  local lines = { header_line, sep_line }
  for _ = 1, rows do
    lines[#lines + 1] = empty_line
  end

  return lines
end

--- Parse a dimension string like "3x4" into cols, rows.
--- @param dim string  Dimension string (e.g., "3x4", "5X2")
--- @return number? cols, number? rows  Parsed values, or nil if invalid
function M.parse_dimensions(dim)
  local c, r = dim:match("^(%d+)[xX](%d+)$")
  if c and r then
    return tonumber(c), tonumber(r)
  end
  return nil, nil
end

--- Parse a pipe-delimited header string into a list of names.
--- @param header_str string  e.g., "Name|Age|City"
--- @return string[]
function M.parse_headers(header_str)
  local headers = {}
  for name in header_str:gmatch("[^|]+") do
    headers[#headers + 1] = name:match("^%s*(.-)%s*$") -- trim whitespace
  end
  return headers
end

return M
```

### Step 2: Add `:TableCreate` Command and `<leader>mT` Keymap

Both are added to `ftplugin/markdown.lua` in a new section after the existing
"Spell Checking Toggle" section and before the which-key registration.

**File: `ftplugin/markdown.lua`** (modify — append before which-key block)

```lua
-- =============================================================================
-- Table Creation Helper
-- =============================================================================

local table_gen = require("andrew.utils.table-gen")

--- Insert a generated table at the cursor position and enable table mode.
--- @param cols number
--- @param rows number
--- @param headers? string[]
--- @param alignments? string
local function insert_table(cols, rows, headers, alignments)
  local lines = table_gen.generate(cols, rows, headers, alignments)

  -- Insert at current cursor line
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] -- 1-indexed
  vim.api.nvim_buf_set_lines(0, row - 1, row - 1, false, lines)

  -- Move cursor to the first header cell (row 1, after "| ")
  vim.api.nvim_win_set_cursor(0, { row, 2 })

  -- Auto-enable vim-table-mode for immediate cell navigation
  if vim.fn.exists(":TableModeEnable") == 2 then
    vim.cmd("TableModeEnable")
  end

  vim.notify(
    string.format("Created %dx%d table", cols, rows),
    vim.log.levels.INFO
  )
end

--- :TableCreate command handler.
--- Usage:
---   :TableCreate 3x4
---   :TableCreate 3x4 Name|Age|City
---   :TableCreate 3x4 Name|Age|City l|c|r
vim.api.nvim_buf_create_user_command(0, "TableCreate", function(opts)
  local args = opts.fargs
  if #args < 1 then
    vim.notify("Usage: :TableCreate CxR [headers] [alignments]", vim.log.levels.ERROR)
    return
  end

  local cols, rows = table_gen.parse_dimensions(args[1])
  if not cols then
    vim.notify("Invalid dimensions: " .. args[1] .. " (expected CxR, e.g., 3x4)", vim.log.levels.ERROR)
    return
  end

  local headers = nil
  if args[2] then
    headers = table_gen.parse_headers(args[2])
  end

  local alignments = args[3] or nil

  insert_table(cols, rows, headers, alignments)
end, {
  nargs = "+",
  desc = "Create a markdown table with CxR dimensions",
})

--- <leader>mT: Interactive table creation prompt.
map("<leader>mT", function()
  vim.ui.input({ prompt = "Table dimensions (CxR): " }, function(dim)
    if not dim or dim == "" then
      return
    end

    local cols, rows = table_gen.parse_dimensions(dim)
    if not cols then
      vim.notify("Invalid dimensions: " .. dim .. " (expected CxR, e.g., 3x4)", vim.log.levels.ERROR)
      return
    end

    vim.ui.input({ prompt = "Headers (pipe-separated, or empty for defaults): " }, function(header_str)
      local headers = nil
      if header_str and header_str ~= "" then
        headers = table_gen.parse_headers(header_str)
      end

      vim.ui.input({ prompt = "Alignment (l|c|r per column, or empty for default): " }, function(align_str)
        local alignments = nil
        if align_str and align_str ~= "" then
          alignments = align_str
        end

        insert_table(cols, rows, headers, alignments)
      end)
    end)
  end)
end, "Create table (interactive)")
```

### Step 3: Enhance the `tbl` LuaSnip Snippet

Replace the static `tbl` snippet with a dynamic version that reads a dimension
string from the first insert node and generates the table body. The original
`tbl` (2-column) and `table` (3-column) snippets are kept as-is for users who
prefer the simple static versions; the new dynamic snippet uses the trigger
`tblx` to avoid breaking existing muscle memory.

**File: `luasnippets/markdown.lua`** (modify)

Add `d` (dynamic_node) and `sn` (snippet_node) to the imports at the top:

```lua
local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node
local i = ls.insert_node
local c = ls.choice_node
local f = ls.function_node
local d = ls.dynamic_node
local sn = ls.snippet_node
local fmt = require("luasnip.extras.fmt").fmt
local rep = require("luasnip.extras").rep
local tex = require("andrew.utils.tex")
local footnotes = require("andrew.vault.footnotes")
```

Then add the dynamic snippet in the "Table snippet" section, after the existing
`tbl` and `table` snippets:

```lua
  ---------------------------------------------------------------------------
  -- Dynamic table snippet (dimension-based)
  ---------------------------------------------------------------------------

  s({ trig = "tblx", desc = "Markdown table (dynamic: type CxR then Tab)" }, {
    i(1, "3x2"),
    d(2, function(args)
      local table_gen = require("andrew.utils.table-gen")
      local dim = args[1][1] or "3x2"
      local cols, rows = table_gen.parse_dimensions(dim)
      if not cols then
        cols, rows = 3, 2
      end
      local lines = table_gen.generate(cols, rows)

      -- Build text nodes: first line starts on a new line after the dimension
      local text_lines = { "" } -- blank line after dimension text
      for _, line in ipairs(lines) do
        text_lines[#text_lines + 1] = line
      end

      return sn(nil, {
        t(text_lines),
      })
    end, { 1 }),
  }),
```

**How it works:**

1. User types `tblx` and expands. The first insert node shows `3x2` (default).
2. User types their desired dimensions (e.g., `5x3`) and presses `<Tab>`.
3. The `dynamic_node` fires, calls `table_gen.generate(5, 3)`, and replaces node
   2 with the generated table text.
4. The snippet is now fully expanded with the table inserted below.

**Limitation:** LuaSnip dynamic nodes regenerate when the triggering insert node
changes, but the generated table is static text (`text_node`), not further
insert nodes. This means the user cannot tab into individual cells via the
snippet. However, once the table is inserted, `vim-table-mode` provides `<Tab>`
navigation between cells, which is the expected editing flow.

### Step 4: Register in which-key

**File: `ftplugin/markdown.lua`** (modify — in the which-key block)

Add the new command and keymap to the which-key registration for discoverability:

```lua
local ok, wk = pcall(require, "which-key")
if ok then
  wk.add({
    { "<leader>m", group = "Markdown", buffer = 0 },
    { "<leader>mT", desc = "Create table (interactive)", buffer = 0 },
    -- ... existing entries ...
  })
end
```

---

## Summary of File Changes

| File | Change | Type |
|------|--------|------|
| `lua/andrew/utils/table-gen.lua` | Table generation utility (`generate`, `parse_dimensions`, `parse_headers`) | **New** |
| `ftplugin/markdown.lua` | Add `:TableCreate` command, `<leader>mT` keymap, `insert_table()` helper | Modify |
| `luasnippets/markdown.lua` | Add `d` and `sn` imports; add `tblx` dynamic snippet | Modify |

---

## Testing

### 1. `:TableCreate` Command

Open a markdown buffer and test:

```vim
" Basic 3x4 table with default headers
:TableCreate 3x4
```

Expected output at cursor:

```markdown
| Header 1 | Header 2 | Header 3 |
| -------- | -------- | -------- |
|          |          |          |
|          |          |          |
|          |          |          |
|          |          |          |
```

```vim
" With custom headers
:TableCreate 3x2 Name|Age|City
```

Expected:

```markdown
| Name | Age | City |
| ---- | --- | ---- |
|      |     |      |
|      |     |      |
```

```vim
" With headers and alignment
:TableCreate 3x2 Name|Age|City l|c|r
```

Expected:

```markdown
| Name | Age | City |
| ---- |:---:|----: |
|      |     |      |
|      |     |      |
```

```vim
" Edge: single column
:TableCreate 1x3
```

Expected:

```markdown
| Header 1 |
| -------- |
|          |
|          |
|          |
```

```vim
" Edge: header-only (0 data rows)
:TableCreate 2x0 Key|Value
```

Expected:

```markdown
| Key | Value |
| --- | ----- |
```

```vim
" Error: invalid dimensions
:TableCreate abc
" Expected: error notification "Invalid dimensions: abc"

" Error: no arguments
:TableCreate
" Expected: error notification with usage message
```

### 2. `<leader>mT` Interactive Prompt

1. Press `<leader>mT` in a markdown buffer.
2. At "Table dimensions (CxR):" prompt, type `4x3` and press Enter.
3. At "Headers" prompt, type `ID|Name|Status|Notes` and press Enter.
4. At "Alignment" prompt, type `l|l|c|l` and press Enter.
5. Expected: a 4-column, 3-row table with those headers and center-aligned
   Status column.
6. Expected: `vim-table-mode` is now active (verify with `:TableModeToggle`
   showing it toggles OFF, meaning it was ON).

Test cancellation:
1. Press `<leader>mT`, then press Escape at the dimensions prompt.
2. Expected: no table inserted, no error.

### 3. `tblx` Snippet

1. In insert mode, type `tblx` and trigger snippet expansion (e.g., `<Tab>` or
   `<C-k>` depending on LuaSnip config).
2. Default text `3x2` appears highlighted.
3. Type `4x3` to replace it, then press `<Tab>`.
4. Expected: a 4-column, 3-row table appears below.
5. Press `<Tab>` — cursor should move into the table cells via
   `vim-table-mode`'s cell navigation (not LuaSnip's jump, since the snippet is
   now fully expanded).

### 4. vim-table-mode Integration

After any table creation method:

1. Verify table mode is active: type inside a cell and press `<Tab>`. Cursor
   should move to the next cell.
2. Type text that exceeds the cell width. The column should auto-expand on
   leaving the cell (vim-table-mode behavior).
3. Add a new row by pressing `|` at the end of the last row.

### 5. Existing Snippets Unaffected

1. Type `tbl` and expand. Expected: the original 2-column static table.
2. Type `table` and expand. Expected: the original 3-column static table.
3. Both should work exactly as before.

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| **`vim-table-mode` not loaded** | `:TableModeEnable` call fails | Guarded with `vim.fn.exists(":TableModeEnable") == 2` check; table is still inserted, just without auto-enable. User sees a notification about the created table regardless. |
| **LuaSnip `dynamic_node` regeneration lag** | On slow machines, typing dimensions and pressing Tab may have a brief delay | The `table_gen.generate()` function is pure string manipulation with no I/O; even a 100x100 table generates in < 1ms. No practical concern. |
| **Existing `tbl`/`table` snippets** | Users with muscle memory for `tbl` might expect the new behavior | The dynamic snippet uses `tblx` (separate trigger) to avoid breaking existing behavior. The static `tbl` and `table` snippets are untouched. |
| **Header count mismatch** | User provides fewer headers than columns (e.g., `4x2 A\|B`) | `generate()` falls back to `Header N` for missing columns. Extra headers beyond the column count are silently ignored. |
| **Alignment count mismatch** | User provides fewer alignments than columns | Missing alignments default to left-aligned `---`. Extra alignments are ignored. |
| **`:TableCreate` in non-markdown buffers** | Command is buffer-local (created with `nvim_buf_create_user_command(0, ...)`) | The command only exists in markdown buffers because it is defined in `ftplugin/markdown.lua`. No conflict with other filetypes. |
| **Cursor position after insertion** | Lines inserted above cursor could shift content | `nvim_buf_set_lines` with `row-1, row-1` inserts ABOVE the cursor line. The cursor is then explicitly moved to the first header cell. Existing content below is pushed down. |
| **Large tables (e.g., 100x100)** | Could produce many lines and dominate the buffer | No hard limit imposed. The `:TableCreate` command works with any dimensions. If this becomes a concern, a `max_rows`/`max_cols` guard (e.g., 50) could be added with a confirmation prompt. |
| **`table-gen.lua` as a new module** | Adds a file to `lua/andrew/utils/` | This is the established location for utility modules (`tex-motions.lua`, `md-textobjects.lua`, `tex.lua` are all there). Follows existing conventions. |
| **Dynamic node does not provide tabstops in cells** | User cannot Tab through individual cells via LuaSnip | This is by design. After snippet expansion, vim-table-mode's `<Tab>` takes over for cell navigation. Documenting this in the snippet description (`"type CxR then Tab"`) sets the right expectation. |
