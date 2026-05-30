# 11 -- Inline Field Completion via blink.cmp

## Problem

The vault supports **inline fields** using `key:: value`, `[key:: value]`, and
`(key:: value)` syntax. These fields are:

- **Highlighted** in the buffer by `inline_fields.lua` (extmark-based, with
  type-aware value coloring).
- **Indexed** by `vault_index.lua` (`extract_inline_fields()` on line 487),
  stored per-entry as `entry.inline_fields` (a `table<string, string>` mapping
  key names to their last-seen value in each file).
- **Queryable** by the search and DQL systems (`search_filter.lua` line 170,
  `query/index.lua` line 113).

However, there is **no auto-completion** for inline fields. The only completion
assistance is a rudimentary `vim.fn.complete()` popup triggered by `<C-x><C-f>`
in `inline_fields.lua` (line 669), which:

1. Only completes **field key names**, not values.
2. Uses `vim.fn.complete()` instead of the blink.cmp framework, so it does not
   integrate with the main completion menu.
3. Pulls known keys from the query index (`query.get_index().pages`) rather than
   the vault index directly -- an older code path that creates an unnecessary
   dependency on the DQL query system.
4. Only triggers inside `[` or `(` delimiters, missing standalone fields
   (`key:: value` at line start).

### User impact

- Users must remember field key names from memory, leading to inconsistency
  (`due-date` vs `due_date` vs `dueDate`).
- Users must remember valid values for a key. For example, after typing
  `status::`, the user has no way to see that `In Progress`, `Blocked`, and
  `Complete` are the values used across the vault.
- The `<C-x><C-f>` keybinding is non-discoverable and conflicts with the
  standard "file path completion" expectation for that chord.

## Current Architecture

### Inline field parsing in vault_index.lua

**File:** `lua/andrew/vault/vault_index.lua`, lines 486-505

```lua
local function extract_inline_fields(body)
  local fields = {}
  for line in body:gmatch("[^\n]+") do
    if line:match("^%s*[-*] %[.%] ") then goto continue end
    for key, value in line:gmatch("([%w_%-]+)::%s*(.-)%s*$") do
      if not key:match("^https?$") then
        fields[key] = vim.trim(value)
      end
    end
    for key, value in line:gmatch("%[([%w_%-]+)::%s*(.-)%]") do
      fields[key] = vim.trim(value)
    end
    for key, value in line:gmatch("%(([%w_%-]+)::%s*(.-)%)") do
      fields[key] = vim.trim(value)
    end
    ::continue::
  end
  return fields
end
```

This stores `inline_fields` as a flat `table<string, string>` on each
`VaultIndexEntry` (line 563). The key limitation for completion is that **only
the last value per key per file is stored** -- if a file uses `status:: Draft`
on line 10 and `status:: Complete` on line 50, only `"Complete"` is retained.
For completion purposes this is acceptable: we aggregate values across all files,
so both values will appear from different files.

### Inline field highlighting in inline_fields.lua

**File:** `lua/andrew/vault/inline_fields.lua`

This module provides:

- `parse_line(line, row)` -- parses all three syntaxes (bracket, paren,
  standalone) into `InlineField` objects with precise byte offsets (line 366).
- `M.get_buffer_fields(bufnr)` -- extracts all fields from a buffer, excluding
  code blocks and frontmatter (line 551).
- `M.get_known_keys()` -- collects field keys from the query index + current
  buffer (line 585).
- `M.complete_field_key()` -- the rudimentary `vim.fn.complete()` popup (line
  669).

### Existing completion sources (pattern reference)

The vault uses `completion_base.lua` to create blink.cmp sources with standard
boilerplate. Three vault completion sources exist:

| Source | File | Trigger | What it completes |
|--------|------|---------|-------------------|
| `wikilinks` | `completion.lua` | `[[`, `#`, `^` | Note names, headings, block IDs |
| `vault_tags` | `completion_tags.lua` | `#` (inline tag) | Tag names with frequency counts |
| `vault_frontmatter` | `completion_frontmatter.lua` | Inside YAML frontmatter | Property names + values |

**Registration** in `blink-cmp.lua` (line 86):

```lua
markdown = { "wikilinks", "vault_tags", "vault_frontmatter", "lsp", "snippets", "path", "buffer", "spell" },
```

Each source follows the `completion_base.create_source()` pattern:

1. **`build(vault_path, callback)`** -- called once (async) to populate items.
   Results are cached and invalidated on vault changes.
2. **`get_completions(self, ctx, items, callback)`** -- called on each keystroke.
   Receives the cached items from `build`. Examines cursor context to decide
   what to return.
3. **`resolve_item(self, item, callback)`** (optional) -- lazy-loads extra data
   (documentation preview) when the user highlights an item.

The `completion_frontmatter.lua` source is the closest architectural analogue:
it provides both **property name** and **property value** completion, switching
based on cursor context (line starts with `key: ` vs. typing a new key). It
returns a structured `{ names: items[], values: table<string, items[]> }` object
from `build`, not a flat items array.

### blink.cmp source registration

Sources are registered in `blink-cmp.lua` under `sources.providers` and added
to `sources.per_filetype.markdown`. Each provider specifies:

- `name` -- display name shown in the completion menu's source column.
- `module` -- Lua module path implementing the blink.cmp source interface.
- `min_keyword_length` -- minimum characters before triggering.
- `score_offset` -- priority relative to other sources.
- `fallbacks` -- sources to suppress when this source is active.

## Proposed Solution

### Overview

Create a new blink.cmp completion source `completion_inline_fields.lua` that
provides:

1. **Field key completion** -- when typing in a position where an inline field
   key is expected (after `[`, `(`, or at line start), suggest known field key
   names with frequency counts and `:: ` suffix insertion.
2. **Field value completion** -- when typing after `key:: ` (or `[key:: ` or
   `(key:: `), suggest known values for that specific key, drawn from the vault
   index's `inline_fields` data across all files.

The source follows the established `completion_base.create_source()` pattern
and mirrors the dual-mode (name vs. value) design of
`completion_frontmatter.lua`.

### Architecture

```
User types:  [sta         or   status:: In
              |                        |
              v                        v
         Key context              Value context
         detected                 detected (key="status")
              |                        |
              v                        v
         Return key items         Return value items
         (sorted by freq)         for "status" key
              |                        |
              v                        v
         label: "status"          label: "In Progress"
         insertText: "status:: "  insertText: "In Progress"
         desc: "42 notes"         desc: "18 notes"
```

### Data flow

```
vault_index.files
    |
    v (build phase: iterate all entries)
entry.inline_fields = { status = "Active", priority = "3", ... }
    |
    v (accumulate across all files)
key_counts: { status = 42, priority = 38, ... }
key_values: { status = { Active = 18, Draft = 12, ... }, ... }
    |
    v (merge known_values from config.lua)
key_values.status += config.status_values (if any gaps)
    |
    v (build completion items)
{ names = name_items[], values = { [key] = value_items[] } }
```

## Implementation Steps

### Step 1: Create `completion_inline_fields.lua`

**New file:** `lua/andrew/vault/completion_inline_fields.lua`

```lua
local config = require("andrew.vault.config")
local base = require("andrew.vault.completion_base")

-- Well-known inline field values (mirrors completion_frontmatter.lua pattern)
local known_values = {
  status = config.status_values,
  priority = vim.tbl_map(tostring, config.priority_values),
  maturity = config.maturity_values,
  type = config.note_types,
}

local empty = { is_incomplete_forward = false, is_incomplete_backward = false, items = {} }

return base.create_source({
  --- Scan the vault index for all inline field keys and their values.
  ---@param vault_path string
  ---@param callback fun(items: table)
  build = function(vault_path, callback)
    local vault_index_mod = package.loaded["andrew.vault.vault_index"]
    if vault_index_mod then
      local idx = vault_index_mod.current()
      if idx and idx:is_ready() and idx.vault_path == vault_path:gsub("/$", "") then
        local key_counts = {}
        local key_values = {} -- key -> { value -> count }

        for _, entry in pairs(idx.files) do
          if entry.inline_fields then
            for key, val in pairs(entry.inline_fields) do
              key_counts[key] = (key_counts[key] or 0) + 1
              if val ~= "" then
                if not key_values[key] then key_values[key] = {} end
                key_values[key][val] = (key_values[key][val] or 0) + 1
              end
            end
          end
        end

        -- Build sorted key name items
        local names_list = {}
        for name in pairs(key_counts) do
          names_list[#names_list + 1] = name
        end
        table.sort(names_list)

        local name_items = {}
        for _, name in ipairs(names_list) do
          local count = key_counts[name]
          name_items[#name_items + 1] = {
            label = name,
            insertText = name .. ":: ",
            filterText = name,
            kind = 10, -- Property
            sortText = base.freq_sort_text(count, name),
            labelDetails = {
              description = base.count_label(count),
            },
          }
        end

        -- Merge known values with discovered values
        for key, presets in pairs(known_values) do
          if not key_values[key] then
            key_values[key] = {}
          end
          for _, v in ipairs(presets) do
            if not key_values[key][tostring(v)] then
              key_values[key][tostring(v)] = 0
            end
          end
        end

        -- Build value items per key
        local value_items = {}
        for key, vals in pairs(key_values) do
          local val_list = {}
          for v in pairs(vals) do
            val_list[#val_list + 1] = v
          end
          table.sort(val_list)

          local items = {}
          for _, v in ipairs(val_list) do
            local count = vals[v]
            local desc = count > 0 and base.count_label(count) or "suggested"
            items[#items + 1] = {
              label = v,
              insertText = v,
              filterText = v,
              kind = 12, -- Value
              sortText = base.freq_sort_text(count, v),
              labelDetails = {
                description = desc,
              },
            }
          end
          value_items[key] = items
        end

        callback({ names = name_items, values = value_items })
        return
      end
    end

    -- Index not ready; return empty
    callback({ names = {}, values = {} })
  end,

  --- Context-aware completion: field keys or field values.
  ---@param self table
  ---@param ctx table
  ---@param items table  { names: table[], values: table<string, table[]> }
  ---@param callback fun(response: table)
  get_completions = function(self, ctx, items, callback)
    local line = ctx.line
    local col = ctx.cursor[2]
    local before = line:sub(1, col)

    -- ── Value completion ──
    -- Standalone: `key:: partial` at line start (with optional list marker)
    local standalone_key = before:match("^%s*[-*]?%s*([%w_%-]+)::%s+")
      or before:match("^([%w_%-]+)::%s+")
    if standalone_key then
      local val_items = items.values and items.values[standalone_key] or {}
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = val_items })
      return
    end

    -- Bracketed: `[key:: partial`
    local bracket_key = before:match("%[([%w_%-]+)::%s+[^%]]*$")
    if bracket_key then
      local val_items = items.values and items.values[bracket_key] or {}
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = val_items })
      return
    end

    -- Parenthesized: `(key:: partial`
    local paren_key = before:match("%(([%w_%-]+)::%s+[^%)]*$")
    if paren_key then
      local val_items = items.values and items.values[paren_key] or {}
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = val_items })
      return
    end

    -- ── Key completion ──
    -- After `[` (but not `[[` which is a wikilink)
    if before:match("%[[%w_%-]*$") and not before:match("%[%[[%w_%-]*$") then
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items.names or {} })
      return
    end

    -- After `(`
    if before:match("%([%w_%-]*$") then
      -- Exclude markdown link targets: ](url
      if not before:match("%]%([%w_%-]*$") then
        callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items.names or {} })
        return
      end
    end

    -- Standalone key at line start: `key` being typed (no :: yet)
    -- Only trigger when cursor is at the very start of a line (possibly after
    -- a list marker) and typing what looks like a field key.
    local line_key_prefix = before:match("^%s*[-*]%s+([%w_%-]+)$")
      or before:match("^([%w_%-]+)$")
    if line_key_prefix then
      -- Only suggest if at least one character has been typed and we have
      -- matching keys (avoid polluting completion on every line start)
      if #line_key_prefix >= 2 then
        callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items.names or {} })
        return
      end
    end

    callback(empty)
  end,
})
```

### Step 2: Register the source in blink-cmp.lua

**File:** `lua/andrew/plugins/blink-cmp.lua`

**2a.** Add provider definition (after `vault_frontmatter` on line 124):

```lua
vault_inline_fields = {
  name = "Fields",
  module = "andrew.vault.completion_inline_fields",
  min_keyword_length = 0,
  score_offset = 11,
  fallbacks = {},
},
```

**`score_offset = 11`** places it below frontmatter (14) and tags (12) but
above spell (-5) and buffer (0). Inline field completion is contextual and
should not dominate the menu when the user is typing prose.

**2b.** Add to the markdown filetype source list (line 86):

```lua
markdown = {
  "wikilinks", "vault_tags", "vault_frontmatter", "vault_inline_fields",
  "lsp", "snippets", "path", "buffer", "spell"
},
```

### Step 3: Add trigger character support (optional enhancement)

The source does not need explicit trigger characters because blink.cmp will
invoke `get_completions` on every keystroke for enabled sources. The
`get_completions` function handles context detection internally (like
`completion_tags.lua` does).

However, for optimal responsiveness after typing `::`, we can add trigger
characters:

```lua
-- At module level, after create_source()
local source = base.create_source({ ... })

function source:get_trigger_characters()
  return { ":" }
end

return source
```

This ensures blink.cmp re-queries the source immediately when `:` is typed
(the second `:` in `::` triggers value completion). Without this, there may be
a slight delay before value suggestions appear.

### Step 4: Remove legacy completion from inline_fields.lua

**File:** `lua/andrew/vault/inline_fields.lua`

**4a.** Remove the `M.complete_field_key()` function (lines 669-709).

**4b.** Remove the `M.get_known_keys()` function (lines 585-620). This is only
used by `complete_field_key()` and can be removed with it. If any external
consumer references it, keep it but mark it as deprecated.

**4c.** Remove the `<C-x><C-f>` keymap registration (lines 807-813):

```lua
-- Remove this block from the FileType autocmd callback:
vim.keymap.set("i", "<C-x><C-f>", function()
  M.complete_field_key()
end, {
  buffer = ev.buf,
  desc = "Complete inline field key",
  silent = true,
})
```

**4d.** Remove the `pcall(require, "andrew.vault.query")` dependency inside
`get_known_keys()`. This eliminates the coupling between inline field
completion and the DQL query system.

### Step 5: Update config.lua (optional)

**File:** `lua/andrew/vault/config.lua`

Add inline field completion-specific config under the existing
`M.inline_fields` section if needed in the future. For now, no config changes
are required -- the known values are sourced from the existing
`config.status_values`, `config.priority_values`, `config.maturity_values`, and
`config.note_types`.

If custom known values are desired later:

```lua
M.inline_fields = {
  enabled = true,
  debounce_ms = 200,
  -- Predefined values for inline field completion (merged with vault-wide values)
  known_values = {
    -- status = { "Not Started", "In Progress", "Complete" },
    -- priority = { "1", "2", "3", "4", "5" },
  },
}
```

## Detailed Context Detection

The `get_completions` function must distinguish six cursor positions. The
detection logic uses the text before the cursor (`before`) and pattern matching.

### Position 1: Value after standalone field key

```
status:: In|
^^^^^^^^^---  key="status", completing value
```

Pattern: `before:match("^%s*[-*]?%s*([%w_%-]+)::%s+")`

The `%s+` after `::` is critical -- it ensures the `::` separator is complete
and the user has typed a space, signaling they are now entering the value.

### Position 2: Value after bracketed field key

```
[status:: In|]
^^^^^^^^^^---  key="status", completing value
```

Pattern: `before:match("%[([%w_%-]+)::%s+[^%]]*$")`

The `[^%]]*$` ensures we are still inside the brackets (no closing `]` yet).

### Position 3: Value after parenthesized field key

```
(status:: In|)
^^^^^^^^^^---  key="status", completing value
```

Pattern: `before:match("%(([%w_%-]+)::%s+[^%)]*$")`

### Position 4: Key after opening bracket

```
[sta|
 ^^^  completing key name
```

Pattern: `before:match("%[[%w_%-]*$") and not before:match("%[%[[%w_%-]*$")`

The negative lookahead for `[[` prevents triggering inside wikilinks. This is
essential to avoid conflicts with the wikilinks completion source.

### Position 5: Key after opening parenthesis

```
(sta|
 ^^^  completing key name
```

Pattern: `before:match("%([%w_%-]*$")` with exclusion for `](` (markdown link
targets).

### Position 6: Key at line start (standalone)

```
sta|
^^^  completing key name (standalone field)
```

Pattern: `before:match("^([%w_%-]+)$")` or `before:match("^%s*[-*]%s+([%w_%-]+)$")`

This is the trickiest case. A bare word at the start of a line could be a field
key OR the beginning of prose. To avoid false positives, we require at least 2
characters before showing suggestions. The user can always trigger completion
manually with `<C-Space>` if they want suggestions earlier.

### Non-trigger positions (must return empty)

- Inside a wikilink: `[[sta|` -- handled by wikilinks source.
- Inside frontmatter: the frontmatter source handles YAML property completion.
  Inline fields do not appear inside frontmatter (guarded by the vault index
  parser which operates on `body` text only).
- Inside a code block or code span: the source does not need to check this
  because inline field highlighting already excludes code regions, and blink.cmp
  respects treesitter context for most sources.
- After `::` with no space: `status::|` -- the user hasn't finished typing the
  separator or hasn't started the value. Return empty to avoid premature
  suggestions.

## Key Design Decisions

### 1. Separate source vs. extending inline_fields.lua

**Decision:** Create a new `completion_inline_fields.lua` module rather than
adding blink.cmp source logic to `inline_fields.lua`.

**Rationale:** The existing vault completion sources (`completion.lua`,
`completion_tags.lua`, `completion_frontmatter.lua`) all live in dedicated
files following the `completion_*.lua` naming convention. The `inline_fields.lua`
module is responsible for highlighting and field extraction, not completion. A
separate module maintains the single-responsibility principle and follows the
established codebase pattern.

### 2. Vault index as sole data source

**Decision:** Use `vault_index.files[*].inline_fields` as the sole source for
field keys and values, instead of the query index or ripgrep.

**Rationale:**
- The vault index is already the single source of truth (as noted in MEMORY.md).
- `entry.inline_fields` contains exactly what we need: key-value pairs per file.
- The query index (`query/index.lua`) re-parses these into typed objects (Date,
  Link, etc.) which is unnecessary for completion (we want raw string values).
- The `get_known_keys()` function in `inline_fields.lua` used the query index
  as a workaround before the vault index existed. The vault index is simpler
  and has no circular dependency risk.

### 3. Key insertion text includes `:: `

**Decision:** `insertText` for key completions is `key .. ":: "` (key + double
colon + space).

**Rationale:** This matches the `completion_frontmatter.lua` pattern where
property names insert with `": "` suffix (line 57: `insertText = name .. ": "`).
The user selects a key and can immediately start typing the value. The space
after `::` is the standard Dataview convention.

### 4. Frequency-based sorting

**Decision:** Sort completion items by frequency (descending) using
`base.freq_sort_text()`, with the count shown in `labelDetails.description`.

**Rationale:** This matches the established pattern in `completion_tags.lua`
and `completion_frontmatter.lua`. Fields used across many notes are likely the
ones the user wants, so they should appear first. The count label ("42 notes")
provides useful context about field prevalence.

### 5. `score_offset = 11` (below tags and frontmatter)

**Decision:** The inline field source has lower priority than vault-specific
sources but higher than generic sources.

**Rationale:** The priority stack is:
- wikilinks (15) -- highest, triggers on `[[`
- vault_frontmatter (14) -- high, only active in frontmatter
- vault_tags (12) -- triggers on `#`
- vault_inline_fields (11) -- contextual, only in field positions
- lsp, snippets, path, buffer -- generic fallbacks
- spell (-5) -- lowest

Inline field completion should not dominate when the user is typing prose
(most keystrokes). The context detection in `get_completions` ensures items
are only returned when the cursor is in a recognizable field position.

### 6. No frontmatter exclusion needed in the source

**Decision:** The `get_completions` function does not explicitly check whether
the cursor is inside frontmatter (unlike `completion_frontmatter.lua` which
checks `fm_parser.cursor_in_frontmatter()`).

**Rationale:** The `completion_frontmatter.lua` source returns empty when NOT
in frontmatter. The inline field source returns empty based on its own pattern
matching. In frontmatter, the cursor position won't match inline field patterns
(`[key::`, `(key::`, `key::` at line start) because frontmatter uses `key: `
(single colon, no double colon). The two sources are naturally mutually
exclusive based on syntax differences.

### 7. Bracket/paren key completion does not auto-close delimiters

**Decision:** When completing a key after `[`, the `insertText` is `key:: `
without appending `]`. Similarly for `(`.

**Rationale:** Many users have autopairs plugins (like nvim-autopairs) that
auto-insert the closing delimiter. Adding `]` to `insertText` would double
the bracket. The user types `[`, autopairs inserts `]`, the user types inside,
and our completion inserts `status:: `. The final result is `[status:: ]` with
the cursor before `]`, ready for value entry.

If the user does NOT have autopairs, they type `[`, our completion inserts
`status:: `, and they type the value and manually close with `]`. This is
acceptable.

## Edge Cases

### Empty vault index

If the vault index is not ready (startup, first-time indexing), `build`
returns `{ names = {}, values = {} }`. No completions appear. This is
self-correcting: the `completion_base.lua` invalidation system will trigger a
rebuild once the index is ready (via `invalidate_all()` called on focus gain
or fs events).

### Key with no known values

If a field key exists across files but always has empty values (e.g.,
`tags::`), `key_values[key]` will be empty or missing. Value completion for
that key returns an empty list. This is correct -- we have nothing to suggest.

### Multiple values for the same key in one file

The vault index's `extract_inline_fields()` stores only the **last** value
per key per file (due to the `fields[key] = vim.trim(value)` overwrite on
line 492). If a file has:

```
status:: Draft
status:: Complete
```

Only `"Complete"` is stored for that file. Across the vault, both values will
appear from different files, but value counts may be slightly undercounted for
files with repeated keys. This is a pre-existing limitation of the vault index
and is acceptable for completion purposes.

### Wikilink inside field value

A field value like `author:: [[John Smith]]` is stored as `"[[John Smith]]"`
in the vault index. The completion source will suggest this raw string
including the brackets. When the user selects it, the full string including
`[[` and `]]` is inserted. This is the correct behavior -- the field value
is the complete wikilink syntax.

### Conflict with wikilinks source

When typing `[[key`, both the wikilinks source and the inline field source
could potentially match. The context detection explicitly excludes `[[`
patterns:

```lua
if before:match("%[[%w_%-]*$") and not before:match("%[%[[%w_%-]*$") then
```

This ensures `[[sta` triggers wikilinks (note name completion), while `[sta`
triggers inline field (key completion). The double-bracket check is critical.

### Conflict with frontmatter source

Inside frontmatter, the cursor position matches patterns like `key: value`
(single colon). The inline field source looks for `key:: value` (double colon).
These patterns do not overlap, so both sources can be active for markdown
buffers without conflict.

### List marker prefix

Standalone fields can appear after list markers:

```
- status:: Active
* priority:: 3
```

The key detection pattern `before:match("^%s*[-*]?%s*([%w_%-]+)::%s+")`
handles optional list markers. The value completion correctly identifies the
key regardless of the list prefix.

### Field key names that look like URLs

Keys like `http` or `https` are excluded by the vault index parser
(`key:match("^https?$")`). They will never appear in completion. This matches
the behavior of `inline_fields.lua`'s highlighting.

### Standalone key at line start: false positives

A bare word at line start (Position 6) could be the start of a sentence rather
than a field key. The 2-character minimum and blink.cmp's fuzzy matching
mitigate this: only matching field key names will appear, and they score lower
than LSP/snippet results. If this proves too noisy in practice, the
standalone key detection can be removed entirely (users would use `[` or `(`
to trigger key completion).

## Files Modified

### New

1. **`lua/andrew/vault/completion_inline_fields.lua`**
   - New blink.cmp source module following the `completion_base.create_source()`
     pattern.
   - `build()`: aggregates inline field keys and values from the vault index.
   - `get_completions()`: context-aware completion (key vs. value) based on
     cursor position pattern matching.

### Modified

2. **`lua/andrew/plugins/blink-cmp.lua`**
   - Add `vault_inline_fields` provider definition under `sources.providers`.
   - Add `"vault_inline_fields"` to the `markdown` filetype source list.

3. **`lua/andrew/vault/inline_fields.lua`**
   - Remove `M.complete_field_key()` function (lines 669-709).
   - Remove `M.get_known_keys()` function (lines 585-620).
   - Remove `<C-x><C-f>` keymap registration (lines 807-813).

### Not Modified

- `vault_index.lua` -- no changes needed; `extract_inline_fields()` already
  provides the data we need.
- `config.lua` -- no new configuration required for initial implementation.
- `completion_base.lua` -- the factory pattern supports the new source without
  changes.
- `query/index.lua` -- the new source bypasses the DQL query system entirely.
- `inline_fields.lua` highlighting logic -- unchanged; only the legacy
  completion code is removed.

## Testing Plan

### Key Completion

1. **Bracket key completion:**
   - Type `[` in a vault note body. Verify field key suggestions appear.
   - Type `[sta` and verify "status" is suggested.
   - Accept "status". Verify `[status:: ` is inserted (with trailing space).
   - Verify the frequency count is shown (e.g., "42 notes").

2. **Paren key completion:**
   - Type `(` in the body. Verify field key suggestions appear.
   - Accept a key. Verify `(key:: ` is inserted.

3. **Standalone key completion:**
   - At line start, type `st`. Verify "status" appears if it exists in the
     vault index.
   - After a list marker, type `- pr`. Verify "priority" appears.

4. **No trigger inside wikilinks:**
   - Type `[[sta`. Verify note name suggestions appear (from wikilinks source),
     NOT field key suggestions.

5. **No trigger inside frontmatter:**
   - Inside YAML frontmatter, type `sta`. Verify frontmatter property
     suggestions appear (from vault_frontmatter source), NOT inline field
     suggestions.

### Value Completion

6. **Standalone value completion:**
   - Type `status:: ` (key + double colon + space). Verify value suggestions
     for "status" appear (e.g., "In Progress", "Complete", "Draft").
   - Verify frequency counts are shown.
   - Accept a value. Verify it is inserted.

7. **Bracket value completion:**
   - Type `[status:: `. Verify value suggestions appear.

8. **Paren value completion:**
   - Type `(status:: `. Verify value suggestions appear.

9. **Known values merged:**
   - For "priority", verify both discovered values from the vault AND predefined
     values from `config.priority_values` appear.
   - Predefined values not yet used in the vault should show "suggested" instead
     of a count.

10. **Unknown key value completion:**
    - Type `unknownkey:: `. Verify empty completion (no error).

### Integration

11. **Co-existence with other sources:**
    - In a markdown buffer, verify all sources still work: wikilinks (`[[`),
      tags (`#`), frontmatter (inside `---`), LSP, snippets, path, buffer,
      spell.

12. **Cache invalidation:**
    - Add a new inline field to a note and save. Open another note and type
      `[`. Verify the new field key appears (after cache invalidation on
      focus gain or fs event).

13. **Source label in menu:**
    - Verify inline field items show "Fields" in the source column of the
      completion menu.

### Cleanup Verification

14. **Legacy removal:**
    - Verify `<C-x><C-f>` no longer triggers the old `vim.fn.complete()` popup
      in markdown buffers.
    - Verify `M.get_known_keys` is no longer accessible on the inline_fields
      module (or is marked deprecated if kept).
    - Verify no errors when loading `inline_fields.lua` (no broken references
      to removed functions).

### Edge Cases

15. **Empty vault (no inline fields anywhere):**
    - Verify empty completion, no errors.

16. **Vault index not ready:**
    - Restart Neovim and immediately open a markdown file. Type `[sta`.
    - Verify graceful empty result (no errors). After index builds, retry
      and verify suggestions now appear.

17. **Very long field values:**
    - If a field value is extremely long (200+ characters), verify it appears
      truncated or handled gracefully in the completion menu.
