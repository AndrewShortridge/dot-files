# frontmatter_editor.lua Refactoring Plan

## File Stats
- **File:** `lua/andrew/vault/frontmatter_editor.lua`
- **Lines:** 983
- **Dead Code:** None
- **Public API:** `M.open()`, `M.delete_field()`, `M.setup()`

## Current Structure

| Section | Lines | Purpose |
|---------|-------|---------|
| Imports & Setup | 1-18 | 7 deps, CYCLE_FIELDS constant |
| Type Detection & Formatting | 20-72 | `detect_field_type()`, `format_display_value()`, `format_yaml_value()` |
| Vault Index Integration | 74-135 | `vault_field_values()`, `vault_field_names()` |
| Buffer Context Wrapper | 137-152 | `write_field_to_source()` |
| List Field Write-back | 154-228 | `set_list_field()` |
| Field Deletion | 230-279 | `M.delete_field()` |
| Editor State | 281-299 | FmEditorField, FmEditorState types, `_state` singleton |
| Rendering | 301-399 | `max_key_width()`, `render()` -- display logic & extmarks |
| Edit Actions | 401-592 | `edit_string_field()`, `edit_boolean_field()`, `edit_cycle_field()`, `edit_list_field()`, `edit_date_field()`, `edit_field()` |
| Add Field | 594-666 | `add_field()` |
| Delete Current Field | 668-695 | `delete_current_field()` |
| Float Window Mgmt | 697-762 | `float_dimensions()`, `resize_float()`, `close_editor()`, `next_field()`, `prev_field()` |
| Public API | 764-929 | `M.open()` -- main UI orchestrator |
| Setup | 931-981 | Highlights, commands, keymaps |

## Duplicated Logic Patterns

### 1. Field Location Scanning (3x -- lines 186-208, 247-267)

Both `set_list_field()` and `M.delete_field()` use identical logic to find a frontmatter
field's start/end lines:

```lua
local pat = "^" .. vim.pesc(key) .. ":%s*(.*)"
for i = fm.start_line + 1, fm.end_line - 1 do
  if not field_start then
    local raw = lines[i]:match(pat)
    if raw then field_start = i; field_end = i
      for j = i + 1, fm.end_line - 1 do
        if lines[j]:match("^%s+%-") then field_end = j else break end
      end
    end
  end
end
```

**Fix:** Extract `find_field_extent(lines, fm, key)` returning `field_start, field_end`.

### 2. Prefix-Matching Completion (3x -- lines 417-426, 498-507, 603-612)

All three use identical prefix-matching completion:

```lua
completion = function(_, line, _)
  local matches = {}
  local prefix = line:lower()
  for _, v in ipairs(existing) do
    if v:lower():find(prefix, 1, true) == 1 then matches[#matches + 1] = v end
  end
  return matches
end
```

**Fix:** Extract `make_prefix_completion(candidates)` factory.

### 3. Cycle Value Selection (2x -- lines 456-472, 629-640)

Both convert cycle values to strings, select via UI, then find original typed value.

**Fix:** Extract `select_from_cycle(values, prompt)`.

### 4. Buffer Line Reading (3x -- lines 168-173, 239-244, 808-812)

```lua
local max = config.frontmatter.max_scan_lines
local line_count = vim.api.nvim_buf_line_count(source_buf)
local limit = math.min(line_count, max)
local lines = vim.api.nvim_buf_get_lines(source_buf, 0, limit, false)
```

**Fix:** Extract `read_frontmatter_lines(source_buf)`.

## Cross-File Duplication

- `detect_field_type()` is duplicated in `sidebar_meta.lua` (lines 28-36). Extract to
  shared `fm_type_utils.lua`.

## Proposed Extraction Plan

### Subsystem A: Type Utils -> `frontmatter_editor/type_utils.lua` (~60 lines)

**Functions:** `detect_field_type()`, `format_display_value()`, `format_yaml_value()`,
`max_key_width()`

**Rationale:** Shareable with sidebar_meta.lua. No editor state dependency.

### Subsystem B: Field Operations -> `frontmatter_editor/field_ops.lua` (~180 lines)

**Functions:** `write_field_to_source()`, `set_list_field()`, `M.delete_field()`,
`find_field_extent()` (new), `read_frontmatter_lines()` (new)

**Rationale:** All operate on source buffer. Testable independently.

### Subsystem C: Field Editors -> `frontmatter_editor/editors.lua` (~250 lines)

**Functions:** `edit_string_field()`, `edit_boolean_field()`, `edit_cycle_field()`,
`edit_list_field()`, `edit_date_field()`, `edit_field()`, `make_prefix_completion()` (new),
`select_from_cycle()` (new)

**Rationale:** Self-contained edit dispatchers.

### Subsystem D: Vault Queries -> `frontmatter_editor/vault_queries.lua` (~50 lines)

**Functions:** `vault_field_values()`, `vault_field_names()`

**Rationale:** Decoupled from UI. Only used for completion suggestions.

## External Callers

- `init.lua:230` -- `.setup()`
- `sidebar_meta.lua:339` -- `.open()`
- `sidebar_meta.lua:355` -- `.delete_field(source_buf, key)`

## Implementation Order

1. Extract type utils (shareable, eliminates sidebar_meta duplication)
2. Extract field ops (dedup field scanning, buffer reading)
3. Extract editors (dedup completion, cycle selection)
4. Extract vault queries (optional, small)

## Expected Result

- `frontmatter_editor.lua`: ~450 lines (state, render, float UI, M.open, M.setup)
- `frontmatter_editor/type_utils.lua`: ~60 lines
- `frontmatter_editor/field_ops.lua`: ~180 lines
- `frontmatter_editor/editors.lua`: ~250 lines
- `frontmatter_editor/vault_queries.lua`: ~50 lines
