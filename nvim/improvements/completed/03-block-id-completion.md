# 03 — Block ID Completion in Wikilinks

## Problem Statement

The completion system (`completion.lua`) already handles three wikilink
completion modes:

1. **Note name completion** (`[[partial`) -- returns note basenames and aliases
   from the vault index.
2. **Heading completion** (`[[Note#partial` or `[[#partial`) -- returns headings
   from the vault index (cross-file) or live buffer (same-file).
3. **Block ID completion** (`[[Note^partial` or `[[^partial`) -- returns block
   IDs from the vault index (cross-file) or live buffer (same-file).

Additionally, a fourth mode handles **standalone block ID references** (`^partial`
outside of `[[`) by scanning the current buffer for block IDs.

All four modes are already implemented and functional. However, the block ID
completion experience has several gaps compared to heading completion:

### Current Limitations

1. **No `completion_kind` data tag for block items.** Heading completion items
   carry `data = { completion_kind = "heading" }`, which allows the
   `transform_items` callback in blink-cmp to relabel them as `source_name =
   "Heading"` in the completion menu. Block completion items carry no such tag,
   so they display as "Wikilinks" in the source column -- indistinguishable from
   note completions.

2. **No lazy documentation for cross-file block items.** Heading completion uses
   `resolve_item` to lazily load content previews when the user highlights an
   item. Cross-file block items include inline `documentation` (line number +
   text), but this comes from the vault index's `block_ids` array which stores
   `{ id, text, line }`. The text field can be empty for block IDs on
   otherwise-empty lines (e.g., a list item's block ID where the text was
   stripped). There is no `resolve_item` path to enrich block items with
   surrounding context.

3. **No surrounding-context preview for block completions.** When completing
   `[[Note^blk-abc123]]`, the documentation panel shows only the single line
   containing the block ID. For headings, the documentation panel shows the
   heading plus up to 8 lines of content beneath it. Block references would
   benefit from similar context: showing 2-3 lines before and after the block
   ID line to help the user confirm they are referencing the right paragraph.

4. **Standalone block ID completion (`^partial`) lacks vault index integration.**
   The standalone `^partial` path (lines 181-210 of `completion.lua`) only
   scans the current buffer. It does not offer block IDs from other files.
   This is arguably correct behavior (standalone `^id` is a same-file concept),
   but worth documenting as a deliberate design choice.

5. **No `filterText` enrichment for block items.** Note completion items have
   `filterText = name` (the relative path), allowing fuzzy matching on
   subfolder paths. Block items use only the `label` (the block ID itself) for
   filtering. Since block IDs are typically random (`blk-abc123`), the user
   cannot fuzzy-filter by the block's content text. Adding the line text to
   `filterText` would allow typing content words to find the right block.

## Current Architecture

### Completion Flow

The completion system is built on `blink.cmp`. The vault wikilink source is
registered as `andrew.vault.completion` in the blink-cmp plugin config.

**Source registration** (`lua/andrew/plugins/blink-cmp.lua`, line 98):

```lua
wikilinks = {
  name = "Wikilinks",
  module = "andrew.vault.completion",
  min_keyword_length = 0,
  score_offset = 15,
  fallbacks = {},
  transform_items = function(_, items)
    for _, item in ipairs(items) do
      if item.data and item.data.completion_kind == "heading" then
        item.source_name = "Heading"
      end
    end
    return items
  end,
},
```

The `transform_items` callback currently only relabels heading items. Block
items pass through with the default "Wikilinks" source name.

**Base factory** (`completion_base.lua`):

`create_source(opts)` provides caching, invalidation, async build, and the
`get_completions` / `resolve` lifecycle hooks. The `build` callback populates
the note name item cache. The `get_completions` callback receives the cached
items and dispatches to one of four modes based on cursor context.

**Trigger characters** (`completion.lua`, line 479-481):

```lua
function source:get_trigger_characters()
  return { "[", "#", "^" }
end
```

### Block Completion: Cross-File Path

**File:** `lua/andrew/vault/completion.lua`, lines 237-289

When the cursor matches `!?%[%[(.-)%^[^%]]*$`, the code extracts
`block_note_name`. For cross-file (non-empty name):

```lua
local base_name = block_note_name:match("^([^#]+)") or block_note_name
base_name = vim.trim(base_name)
local entry = resolve_note_via_index(base_name)
if entry and entry.block_ids and #entry.block_ids > 0 then
  local block_items = {}
  for _, b in ipairs(entry.block_ids) do
    local preview = b.text or ""
    if #preview > 60 then
      preview = preview:sub(1, 57) .. "..."
    end
    block_items[#block_items + 1] = {
      label = b.id,
      insertText = b.id .. "]]",
      kind = 22,
      labelDetails = { description = preview },
      documentation = (b.text and b.text ~= "") and {
        kind = "plaintext",
        value = "Line " .. b.line .. ": " .. b.text,
      } or nil,
    }
  end
  callback({ ... items = block_items })
```

**Observations:**
- Uses vault index `entry.block_ids` (array of `{ id, text, line }`).
- No `data` field on block items -- cannot be distinguished from note items
  in `transform_items`.
- No `filterText` -- only the block ID label is used for fuzzy matching.
- `documentation` is set inline (not lazily via `resolve_item`).
- `kind = 22` (Struct in LSP completion kind) -- same as headings.

### Block Completion: Same-File Path

**File:** `lua/andrew/vault/completion.lua`, lines 239-260

When `block_note_name == ""` (same-file `[[^`), the code reads the live buffer:

```lua
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local blocks = get_blocks(lines)
local block_items = {}
for _, b in ipairs(blocks) do
  local preview = b.text
  if #preview > 60 then
    preview = preview:sub(1, 57) .. "..."
  end
  block_items[#block_items + 1] = {
    label = b.id,
    insertText = b.id .. "]]",
    kind = 22,
    labelDetails = { description = preview },
    documentation = {
      kind = "plaintext",
      value = "Line " .. b.line .. ": " .. b.text,
    },
  }
end
```

**Observations:**
- Same item structure as cross-file, but reads from live buffer via
  `get_blocks()`.
- Also lacks `data` field and `filterText`.

### Standalone Block ID Path

**File:** `lua/andrew/vault/completion.lua`, lines 179-210

When `^partial` is typed outside `[[`, scans current buffer only:

```lua
if not before:match("!?%[%[") then
  local block_prefix = before:match("%^([%w%-]*)$")
  if block_prefix then
    local buf_path = vim.api.nvim_buf_get_name(0)
    if buf_path ~= "" then
      local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      local blocks = get_blocks(buf_lines)
      local block_items = {}
      for _, b in ipairs(blocks) do
        ...
        block_items[#block_items + 1] = {
          label = "^" .. b.id,
          insertText = b.id,
          kind = 22,
          labelDetails = { description = preview },
          documentation = { ... },
        }
      end
      callback({ ... items = block_items })
```

**Note:** The `label` here includes `^` prefix (for display), but `insertText`
does not (the `^` is already typed). This is correct behavior.

### Vault Index Block ID Data

**File:** `lua/andrew/vault/vault_index.lua`

The `_parse_file()` method (line 534) calls `extract_block_ids(content)` which
returns structured objects:

```lua
-- vault_index.lua lines 384-401
local function extract_block_ids(content)
  local blocks = {}
  local seen = {}
  local line_num = 0
  for line in content:gmatch("[^\n]*") do
    line_num = line_num + 1
    local id = line:match("%^([%w%-]+)%s*$")
    if id and not seen[id] then
      seen[id] = true
      local text = line:gsub("%s*%^[%w%-]+%s*$", "")
      blocks[#blocks + 1] = { id = id, text = text, line = line_num }
    end
  end
  return blocks
end
```

Each entry in `entry.block_ids` is `{ id: string, text: string, line: number }`.
Additionally, `entry.block_id_set` provides O(1) existence lookup:

```lua
-- vault_index.lua lines 540-543
local block_id_set = {}
for _, b in ipairs(block_ids) do
  block_id_set[b.id] = true
end
```

### Helper: `resolve_note_via_index()`

**File:** `lua/andrew/vault/completion.lua`, lines 67-110

Resolves a note name to its vault index entry using `idx:resolve_name()` with
proximity-based disambiguation when multiple files share the same basename. This
function is already used by both heading and block completion for cross-file
lookups.

### Helper: `get_blocks()`

**File:** `lua/andrew/vault/completion.lua`, lines 4-14

Scans buffer lines for block IDs, returning `{ id, text, line }` objects.
Used by same-file block completion and standalone `^partial` completion:

```lua
local function get_blocks(lines)
  local blocks = {}
  for i, line in ipairs(lines) do
    local block_id = line:match("%^([%w%-]+)%s*$")
    if block_id then
      local text = line:gsub("%s*%^[%w%-]+%s*$", "")
      blocks[#blocks + 1] = { id = block_id, text = text, line = i }
    end
  end
  return blocks
end
```

### Heading Completion for Comparison

Cross-file heading items include a `data` field:

```lua
data = {
  completion_kind = "heading",
  abs_path = target_path,
  heading_line = h.line,
  heading_level = h.level,
},
```

And `resolve_item` handles them lazily (lines 352-401 of `completion.lua`):
reads the file at `abs_path`, seeks to `heading_line`, extracts 8 lines of
content below, and sets `item.documentation` with markdown-formatted preview.

## Proposed Changes

### Overview

Five targeted changes to bring block ID completion to parity with heading
completion:

1. Add `completion_kind = "block"` data tag to block items.
2. Add `filterText` with block line text for content-based fuzzy matching.
3. Add a `resolve_item` path for cross-file block items with surrounding
   context.
4. Add a `transform_items` entry in blink-cmp config to relabel block items.
5. Improve same-file block item documentation with surrounding context.

These changes are additive -- they enhance existing working functionality
without restructuring the completion flow.

### Change 1: Add `data` field to block completion items

Add `data = { completion_kind = "block" }` to all block completion items so
they can be distinguished in `transform_items` and handled in `resolve_item`.

For cross-file block items, include the `abs_path` and `block_line` for lazy
context loading:

```lua
data = {
  completion_kind = "block",
  abs_path = entry.abs_path,  -- for resolve_item context loading
  block_line = b.line,        -- 1-indexed line number
},
```

For same-file block items (both `[[^` and standalone `^`), the data is simpler
since context can be loaded from the live buffer:

```lua
data = {
  completion_kind = "block",
},
```

### Change 2: Add `filterText` for content-based filtering

Block IDs are typically random strings like `blk-a7x2f9`. Users often remember
the content of the block, not its ID. Adding the line text to `filterText`
allows typing content words to narrow down the block list.

For all block items, set:

```lua
filterText = b.id .. " " .. (b.text or ""),
```

This means typing `[[Note^intro` would match a block ID `blk-abc123` on a line
containing "This is the introduction paragraph" because "intro" fuzzy-matches
against the filterText.

### Change 3: Add `resolve_item` path for cross-file blocks

Add a new branch in `resolve_item` (before the heading branch) that loads
surrounding context for block items:

```lua
-- Block preview: lazy-load surrounding context
if item.data and item.data.completion_kind == "block" and item.data.abs_path then
  local path = item.data.abs_path
  local block_line = item.data.block_line

  local f = io.open(path, "r")
  if not f then
    callback(item)
    return
  end

  local lines = {}
  local line_num = 0
  local context_before = 3
  local context_after = 3
  local start_line = math.max(1, block_line - context_before)

  for line in f:lines() do
    line_num = line_num + 1
    if line_num >= start_line and line_num <= block_line + context_after then
      lines[#lines + 1] = { num = line_num, text = line }
    end
    if line_num > block_line + context_after then break end
  end
  f:close()

  -- Build preview with the block line highlighted
  local preview_parts = {}
  for _, l in ipairs(lines) do
    local prefix = l.num == block_line and ">>> " or "    "
    preview_parts[#preview_parts + 1] = prefix .. "L" .. l.num .. ": " .. l.text
  end

  if #preview_parts > 0 then
    item.documentation = {
      kind = "plaintext",
      value = table.concat(preview_parts, "\n"),
    }
  end

  callback(item)
  return
end
```

This loads 3 lines before and 3 lines after the block ID line, with the block
line itself marked with `>>>`. The result shows the surrounding paragraph
context, helping the user verify they selected the right block.

### Change 4: Update `transform_items` in blink-cmp config

**File:** `lua/andrew/plugins/blink-cmp.lua`, lines 102-109

Extend the existing `transform_items` callback to also relabel block items:

```lua
transform_items = function(_, items)
  for _, item in ipairs(items) do
    if item.data and item.data.completion_kind == "heading" then
      item.source_name = "Heading"
    elseif item.data and item.data.completion_kind == "block" then
      item.source_name = "Block"
    end
  end
  return items
end,
```

This displays "Block" in the source column instead of "Wikilinks" for block
completion items, making it immediately clear what type of completion is being
offered.

### Change 5: Improve same-file block documentation with context

For same-file block completions (both `[[^` and standalone `^`), we already
have access to the buffer lines. Instead of showing only the single block line,
show 2 lines of surrounding context:

```lua
-- Build documentation with surrounding context
local doc_lines = {}
local start = math.max(1, b.line - 2)
local stop = math.min(#lines, b.line + 2)
for j = start, stop do
  local prefix = j == b.line and ">>> " or "    "
  doc_lines[#doc_lines + 1] = prefix .. "L" .. j .. ": " .. lines[j]
end

block_items[#block_items + 1] = {
  label = b.id,
  insertText = b.id .. "]]",
  filterText = b.id .. " " .. b.text,
  kind = 22,
  labelDetails = { description = preview },
  documentation = {
    kind = "plaintext",
    value = table.concat(doc_lines, "\n"),
  },
  data = { completion_kind = "block" },
}
```

## Implementation Steps

### Step 1: Add `data` and `filterText` to cross-file block items

**File:** `lua/andrew/vault/completion.lua`

Replace the cross-file block item construction (lines 266-284):

**Current:**

```lua
if entry and entry.block_ids and #entry.block_ids > 0 then
  local block_items = {}
  for _, b in ipairs(entry.block_ids) do
    local preview = b.text or ""
    if #preview > 60 then
      preview = preview:sub(1, 57) .. "..."
    end
    block_items[#block_items + 1] = {
      label = b.id,
      insertText = b.id .. "]]",
      kind = 22,
      labelDetails = { description = preview },
      documentation = (b.text and b.text ~= "") and {
        kind = "plaintext",
        value = "Line " .. b.line .. ": " .. b.text,
      } or nil,
    }
  end
```

**Proposed:**

```lua
if entry and entry.block_ids and #entry.block_ids > 0 then
  local block_items = {}
  for _, b in ipairs(entry.block_ids) do
    local preview = b.text or ""
    if #preview > 60 then
      preview = preview:sub(1, 57) .. "..."
    end
    block_items[#block_items + 1] = {
      label = b.id,
      insertText = b.id .. "]]",
      filterText = b.id .. " " .. (b.text or ""),
      kind = 22,
      labelDetails = { description = preview },
      -- Inline documentation as fallback; enriched by resolve_item
      documentation = (b.text and b.text ~= "") and {
        kind = "plaintext",
        value = "Line " .. b.line .. ": " .. b.text,
      } or nil,
      data = {
        completion_kind = "block",
        abs_path = entry.abs_path,
        block_line = b.line,
      },
    }
  end
```

### Step 2: Add `data` and `filterText` to same-file block items (wikilink)

**File:** `lua/andrew/vault/completion.lua`

Update the same-file block item construction (lines 243-259).

**Current:**

```lua
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local blocks = get_blocks(lines)
local block_items = {}
for _, b in ipairs(blocks) do
  local preview = b.text
  if #preview > 60 then
    preview = preview:sub(1, 57) .. "..."
  end
  block_items[#block_items + 1] = {
    label = b.id,
    insertText = b.id .. "]]",
    kind = 22,
    labelDetails = { description = preview },
    documentation = {
      kind = "plaintext",
      value = "Line " .. b.line .. ": " .. b.text,
    },
  }
end
```

**Proposed:**

```lua
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local blocks = get_blocks(lines)
local block_items = {}
for _, b in ipairs(blocks) do
  local preview = b.text
  if #preview > 60 then
    preview = preview:sub(1, 57) .. "..."
  end

  -- Build documentation with surrounding context
  local doc_lines = {}
  local start = math.max(1, b.line - 2)
  local stop = math.min(#lines, b.line + 2)
  for j = start, stop do
    local prefix = j == b.line and ">>> " or "    "
    doc_lines[#doc_lines + 1] = prefix .. "L" .. j .. ": " .. lines[j]
  end

  block_items[#block_items + 1] = {
    label = b.id,
    insertText = b.id .. "]]",
    filterText = b.id .. " " .. b.text,
    kind = 22,
    labelDetails = { description = preview },
    documentation = {
      kind = "plaintext",
      value = table.concat(doc_lines, "\n"),
    },
    data = { completion_kind = "block" },
  }
end
```

### Step 3: Add `data` and `filterText` to standalone block items

**File:** `lua/andrew/vault/completion.lua`

Update the standalone block item construction (lines 188-205).

**Current:**

```lua
for _, b in ipairs(blocks) do
  local preview = b.text
  if #preview > 60 then
    preview = preview:sub(1, 57) .. "..."
  end
  block_items[#block_items + 1] = {
    label = "^" .. b.id,
    insertText = b.id,
    kind = 22,
    labelDetails = { description = preview },
    documentation = {
      kind = "plaintext",
      value = "Line " .. b.line .. ": " .. b.text,
    },
  }
end
```

**Proposed:**

```lua
for _, b in ipairs(blocks) do
  local preview = b.text
  if #preview > 60 then
    preview = preview:sub(1, 57) .. "..."
  end

  -- Build documentation with surrounding context
  local doc_lines = {}
  local start = math.max(1, b.line - 2)
  local stop = math.min(#buf_lines, b.line + 2)
  for j = start, stop do
    local prefix = j == b.line and ">>> " or "    "
    doc_lines[#doc_lines + 1] = prefix .. "L" .. j .. ": " .. buf_lines[j]
  end

  block_items[#block_items + 1] = {
    label = "^" .. b.id,
    insertText = b.id,
    filterText = b.id .. " " .. b.text,
    kind = 22,
    labelDetails = { description = preview },
    documentation = {
      kind = "plaintext",
      value = table.concat(doc_lines, "\n"),
    },
    data = { completion_kind = "block" },
  }
end
```

### Step 4: Add `resolve_item` handler for cross-file block items

**File:** `lua/andrew/vault/completion.lua`

In the `resolve_item` function (line 352), add a new branch **before** the
existing heading branch. The heading branch checks
`item.data.completion_kind == "heading"`; the new block branch checks
`item.data.completion_kind == "block"`.

Insert before line 353:

```lua
-- Block context preview: lazy-load surrounding lines from disk
if item.data and item.data.completion_kind == "block" and item.data.abs_path then
  local path = item.data.abs_path
  local block_line = item.data.block_line
  if not block_line then
    callback(item)
    return
  end

  local f = io.open(path, "r")
  if not f then
    callback(item)
    return
  end

  local context_before = 3
  local context_after = 3
  local start_line = math.max(1, block_line - context_before)
  local collected = {}
  local line_num = 0

  for line in f:lines() do
    line_num = line_num + 1
    if line_num >= start_line then
      collected[#collected + 1] = { num = line_num, text = line }
    end
    if line_num >= block_line + context_after then break end
  end
  f:close()

  -- Build preview with the block line highlighted
  local preview_parts = {}
  for _, l in ipairs(collected) do
    local prefix = l.num == block_line and ">>> " or "    "
    preview_parts[#preview_parts + 1] = prefix .. "L" .. l.num .. ": " .. l.text
  end

  if #preview_parts > 0 then
    item.documentation = {
      kind = "plaintext",
      value = table.concat(preview_parts, "\n"),
    }
  end

  callback(item)
  return
end
```

This replaces the single-line inline documentation with a multi-line context
window when the user highlights the item in the completion menu.

### Step 5: Update `transform_items` in blink-cmp config

**File:** `lua/andrew/plugins/blink-cmp.lua`

Replace lines 102-109:

**Current:**

```lua
transform_items = function(_, items)
  for _, item in ipairs(items) do
    if item.data and item.data.completion_kind == "heading" then
      item.source_name = "Heading"
    end
  end
  return items
end,
```

**Proposed:**

```lua
transform_items = function(_, items)
  for _, item in ipairs(items) do
    if item.data and item.data.completion_kind == "heading" then
      item.source_name = "Heading"
    elseif item.data and item.data.completion_kind == "block" then
      item.source_name = "Block"
    end
  end
  return items
end,
```

## Edge Cases

### Block IDs on empty lines

A block ID can appear on an otherwise-empty line: `^blk-abc123`. After
stripping the block marker, `b.text` is `""`. The `filterText` becomes
`"blk-abc123 "` (trailing space), which is harmless. The `labelDetails`
description shows an empty string. The `documentation` panel (via
`resolve_item`) still shows surrounding context lines, which provides useful
context even when the block line itself is bare.

### Block IDs on list items

A common pattern is `- Some list item ^blk-abc123`. The text `- Some list item`
is preserved and shown in `labelDetails` and `filterText`. The surrounding
context in `resolve_item` shows adjacent list items, helping the user identify
the right block.

### Very large files

The `resolve_item` file read uses early termination:
`if line_num >= block_line + context_after then break end`. For a block at line
5000 of a 10000-line file, it reads 5003 lines and discards the first 4997.
This is the same approach used by the heading `resolve_item` handler (which
reads up to `heading_line + 20` lines). For extremely large files (50K+ lines),
this could be slow on the first highlight, but subsequent highlights benefit
from filesystem cache.

An optimization (not in this proposal but worth noting) would be to use
`io.open` with `f:seek()` to skip ahead, but Lua's line-by-line `f:lines()`
does not support seeking by line number, only by byte offset. The current
approach is consistent with the existing heading handler.

### Autopairs bracket handling

The existing bracket-stripping logic (lines 215-233 of `completion.lua`)
handles the case where autopairs has already inserted `]]` after the cursor.
It wraps the original callback and strips `]]` from `insertText` when the
closing brackets are already present. This logic applies uniformly to all
completion items returned by the callback, including block items. No special
handling needed.

### Block IDs containing hyphens

The block ID pattern `%^([%w%-]+)%s*$` matches alphanumeric characters and
hyphens. Block IDs like `blk-abc-123` or `my-block` are handled correctly.
The `filterText` concatenation uses a space separator (`b.id .. " " .. b.text`),
so hyphens in the ID do not interfere with content text matching.

### Same note name in multiple folders

When multiple notes share a basename (e.g., `Projects/Alpha.md` and
`Archive/Alpha.md`), `resolve_note_via_index()` uses proximity-based
disambiguation to select the closest match. This is already implemented
(lines 78-98 of `completion.lua`) and works identically for block completion
as for heading completion.

### Index not ready

If the vault index is not ready when the user types `[[Note^`,
`resolve_note_via_index()` returns `nil` and the completion returns an empty
list. This matches the existing behavior for heading completion. Block IDs
become available once the index finishes building (typically within a few
hundred milliseconds of startup).

### Standalone `^` completion outside vault files

The standalone `^partial` path checks `buf_path ~= ""` before scanning. If
the buffer has no name (untitled buffer), it returns empty. If the buffer is
not a markdown file, the source's `enabled()` check (`vim.bo.filetype ==
"markdown"`) prevents the source from activating at all. No additional guards
needed.

### Cross-file `resolve_item` with deleted file

If a file existed when the completion list was built but was deleted before the
user highlights the item, `io.open(path, "r")` returns nil and the handler
calls `callback(item)` without modifying documentation. The user sees the
original inline documentation (line number + text from the index), which is
stale but not incorrect.

## Files Modified

### Modified

1. **`lua/andrew/vault/completion.lua`**
   - Add `data = { completion_kind = "block", ... }` to all three block
     completion paths (cross-file, same-file wikilink, standalone).
   - Add `filterText = b.id .. " " .. (b.text or "")` to all block items.
   - Add surrounding context to same-file and standalone block item
     `documentation`.
   - Add `resolve_item` branch for cross-file block items (before the heading
     branch).

2. **`lua/andrew/plugins/blink-cmp.lua`**
   - Extend `transform_items` to relabel `completion_kind == "block"` items
     with `source_name = "Block"`.

### Not Modified

- **`lua/andrew/vault/completion_base.lua`** -- no changes needed; the
  `build`/`get_completions`/`resolve_item` factory pattern is unchanged.
- **`lua/andrew/vault/vault_index.lua`** -- no changes needed; `block_ids`
  already stores `{ id, text, line }` objects with the `block_id_set` lookup
  table. The existing `extract_block_ids()` function is sufficient.
- **`lua/andrew/vault/blockid.lua`** -- block ID generation module, unrelated
  to completion.
- **`lua/andrew/vault/link_utils.lua`** -- link parsing is unchanged.
- **`lua/andrew/vault/config.lua`** -- no new configuration values needed.

## Key Design Decisions

### 1. `completion_kind` tagging pattern

**Decision:** Add `data.completion_kind = "block"` following the existing
pattern established by heading completions (`data.completion_kind = "heading"`).

**Rationale:** This is a zero-cost, non-breaking addition. The `data` field is
an opaque bag attached to blink-cmp items; adding keys does not affect other
completion behavior. The `transform_items` callback and `resolve_item` handler
both dispatch on `completion_kind`, so using the same pattern ensures
consistency.

### 2. `filterText` includes both ID and text

**Decision:** Set `filterText = b.id .. " " .. (b.text or "")` so users can
match by either the block ID or the line content.

**Rationale:** Block IDs are typically auto-generated random strings
(`blk-a7x2f9`). Users think in terms of content ("that paragraph about
X"), not IDs. Including the text in `filterText` enables content-based
fuzzy matching without changing the displayed `label` (which remains the
clean block ID). blink-cmp uses `filterText` for fuzzy scoring when
present, falling back to `label` otherwise.

### 3. Surrounding context in `resolve_item` vs inline

**Decision:** For cross-file block items, provide minimal inline
documentation (line number + text) and enrich with surrounding context
lazily via `resolve_item`. For same-file block items, provide surrounding
context inline (since buffer lines are already in memory).

**Rationale:** Cross-file `resolve_item` requires file I/O, which should
be deferred until the user actually highlights the item. Building context
for all block items upfront would read the file once per item, which is
wasteful when the user will likely only inspect 1-2 items. Same-file
items already have the buffer lines in memory, so building context inline
is free.

### 4. Context window size (3 lines before/after)

**Decision:** Show 3 lines before and 3 lines after the block ID line
(7 lines total, with the block line highlighted).

**Rationale:** Block references typically point to a paragraph or list
item. Three lines of context is enough to show the full paragraph in most
cases while keeping the documentation panel compact. Heading completions
show up to 8 lines of content after the heading; block context is
symmetric (before + after) because the block ID is often at the end of its
content, so preceding context is essential.

### 5. Standalone `^` remains same-file only

**Decision:** Do not add cross-file block ID completion for standalone
`^partial` (outside of `[[`).

**Rationale:** A standalone `^blk-id` is a block ID reference within the
same note (used for `[[^blk-id]]` shorthand or as an anchor). Cross-file
block references always use the `[[Note^blk-id]]` syntax. Offering blocks
from other files in the standalone path would be confusing and noisy.

## Testing Plan

### Manual Testing

1. **Cross-file block completion with source label:**
   - Open a vault note. Type `[[ExistingNote^` and verify block IDs appear.
   - Confirm the source column shows "Block" (not "Wikilinks").
   - Confirm `labelDetails` shows the line text preview.

2. **Cross-file block fuzzy filtering by content:**
   - Type `[[ExistingNote^` then type a word from the block's content text.
   - Verify the block item is matched and ranked by blink-cmp fuzzy scoring.
   - Verify a random string that does not appear in any block text yields no
     matches (or low-scored matches).

3. **Cross-file block `resolve_item` context:**
   - Type `[[ExistingNote^` and arrow-key to highlight a block item.
   - Verify the documentation panel shows surrounding context (3 lines
     before, block line with `>>>`, 3 lines after).
   - Verify line numbers are correct.

4. **Same-file block completion with context:**
   - Add a block ID to the current buffer (e.g., `Some text ^blk-test01`).
   - Type `[[^` and verify block IDs appear with surrounding context in the
     documentation panel.
   - Confirm the source column shows "Block".

5. **Same-file block with unsaved changes:**
   - Add a new block ID to the buffer without saving.
   - Type `[[^` and verify the new block appears.
   - Delete a block ID without saving and verify it no longer appears.

6. **Standalone block completion:**
   - Type `^blk` outside of `[[` and verify current-buffer block IDs appear.
   - Confirm the source column shows "Block".
   - Confirm surrounding context is shown in documentation.

7. **Content-based filtering for same-file blocks:**
   - Type `[[^` then type a word from a block's associated text.
   - Verify the correct block is matched.

8. **Embed syntax (`![[Note^blk-id]]`):**
   - Type `![[ExistingNote^` and verify block IDs appear.
   - Confirm all features (source label, context, filtering) work identically.

9. **Autopairs bracket handling:**
   - With autopairs enabled, type `[[Note^` (which auto-inserts `]]`).
   - Verify accepted block items do not double the closing brackets.

### Regression Testing

10. **Note name completion unchanged:**
    - Type `[[` and verify note names and aliases still appear with
      "Wikilinks" source label.
    - Accept a note and verify correct insertion.

11. **Heading completion unchanged:**
    - Type `[[Note#` and verify headings still appear with "Heading"
      source label.
    - Highlight a heading and verify lazy preview still loads.

12. **Heading `resolve_item` not broken:**
    - Type `[[Note#` and highlight a heading item.
    - Verify the documentation panel shows heading content preview (not
      block context format).

### Edge Case Testing

13. **Block ID on empty line:**
    - Create a line containing only `^blk-empty01`.
    - Type `[[^` and verify the block appears with empty description.
    - Verify surrounding context is shown in documentation.

14. **Note with no block IDs:**
    - Type `[[NoteWithNoBlocks^` and verify empty completion (no error).

15. **Index not ready:**
    - Restart Neovim. Immediately type `[[Note^` before index finishes.
    - Verify graceful empty result (no errors).

16. **Very long block text:**
    - Create a line with 200+ characters followed by `^blk-long01`.
    - Verify `labelDetails` truncates at 60 characters with `...`.
    - Verify `filterText` includes the full text (not truncated).

17. **Multiple blocks on adjacent lines:**
    - Create three consecutive lines each with block IDs.
    - Type `[[^` and verify all three appear.
    - Highlight the middle one and verify context shows the other two.
