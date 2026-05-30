# 31 — Block ID Completion Enhancement

**Priority:** Medium
**Status:** Implemented
**Depends on:** 03-block-id-completion (completed)

## Summary

Enhance block ID completion across all three trigger paths (standalone `^`,
same-file `[[^`, cross-file `[[Note^`) with:

1. `completion_kind = "block"` data tagging for source label differentiation
2. `filterText` combining block ID + content text for fuzzy matching by content
3. Lazy `resolve_item` loading surrounding context (3 lines before/after) for cross-file blocks
4. Source name display as "Block" instead of "Wikilinks" in the completion menu
5. Inline documentation with surrounding context for same-file block items

These changes bring block ID completion to full parity with heading completion,
which already has `completion_kind = "heading"`, lazy `resolve_item` previews,
and "Heading" source labeling.

---

## Current Behavior Analysis

### Three Block Completion Paths

Block ID completion activates in three distinct contexts, all handled in
`get_completions()` in `lua/andrew/vault/completion.lua`:

**Path 1: Standalone `^partial` (outside wikilinks)**
- Trigger: typing `^` outside `[[` brackets (line 201)
- Source: live buffer lines via `get_blocks()` (line 207)
- Scope: current file only

**Path 2: Same-file `[[^partial`**
- Trigger: `[[^` with empty note name (line 257)
- Source: live buffer lines via `get_blocks()` (line 260)
- Scope: current file only

**Path 3: Cross-file `[[Note^partial`**
- Trigger: `[[SomeName^` with non-empty note name (line 277)
- Source: vault index `entry.block_ids` (line 284)
- Scope: target file via `resolve_note_via_index()` (line 281)

### Vault Index Block ID Storage

**File:** `lua/andrew/vault/vault_index.lua`, lines 385-401

```lua
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

Each vault index entry stores:
- `entry.block_ids`: array of `{ id: string, text: string, line: number }`
- `entry.block_id_set`: `table<string, boolean>` for O(1) existence checks

### Local Buffer Block Scanner

**File:** `lua/andrew/vault/completion.lua`, lines 4-14

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

Uses the same extraction pattern as `vault_index.lua:extract_block_ids()`.

### Helper: `build_context_lines()`

**File:** `lua/andrew/vault/completion.lua`, lines 24-34

```lua
local function build_context_lines(lines, target_line, context_width)
  context_width = context_width or 2
  local doc = {}
  local start = math.max(1, target_line - context_width)
  local stop = math.min(#lines, target_line + context_width)
  for j = start, stop do
    local prefix = j == target_line and ">>> " or "    "
    doc[#doc + 1] = prefix .. "L" .. j .. ": " .. lines[j]
  end
  return table.concat(doc, "\n")
end
```

Builds a plaintext context window with the target line highlighted via `>>>`.
Default context width is 2 lines before/after. Used by same-file block paths
for inline documentation.

### Helper: `truncate_preview()`

**File:** `lua/andrew/vault/completion.lua`, lines 16-22

```lua
local function truncate_preview(text, max_len)
  max_len = max_len or 60
  if #text > max_len then
    return text:sub(1, max_len - 3) .. "..."
  end
  return text
end
```

Truncates block text for `labelDetails.description` display (60 chars max).

### Blink-cmp Source Registration

**File:** `lua/andrew/plugins/blink-cmp.lua`, lines 96-112

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
      elseif item.data and item.data.completion_kind == "block" then
        item.source_name = "Block"
      end
    end
    return items
  end,
},
```

The `transform_items` callback dispatches on `item.data.completion_kind` to
relabel items in the completion menu source column.

---

## Detailed Implementation

### Change 1: Add `completion_kind = "block"` to completion items

All three block completion paths attach `data = { completion_kind = "block" }`
to their items. Cross-file items additionally include `abs_path` and
`block_line` for lazy `resolve_item` context loading.

#### Path 1: Standalone `^partial`

**File:** `lua/andrew/vault/completion.lua`, lines 209-221

Before (from original 03 spec):
```lua
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
```

After (current implementation):
```lua
block_items[#block_items + 1] = {
  label = "^" .. b.id,
  insertText = b.id,
  filterText = b.id .. " " .. b.text,
  kind = 22,
  labelDetails = { description = truncate_preview(b.text) },
  documentation = {
    kind = "plaintext",
    value = build_context_lines(buf_lines, b.line),
  },
  data = { completion_kind = "block" },
}
```

Changes:
- Added `data = { completion_kind = "block" }` for `transform_items` dispatch
- Added `filterText = b.id .. " " .. b.text` for content-based fuzzy matching
- Replaced inline `"Line N: text"` documentation with `build_context_lines()` context window
- Used `truncate_preview()` for consistent `labelDetails` truncation

#### Path 2: Same-file `[[^partial`

**File:** `lua/andrew/vault/completion.lua`, lines 262-274

Before (from original 03 spec):
```lua
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
```

After (current implementation):
```lua
block_items[#block_items + 1] = {
  label = b.id,
  insertText = b.id .. "]]",
  filterText = b.id .. " " .. b.text,
  kind = 22,
  labelDetails = { description = truncate_preview(b.text) },
  documentation = {
    kind = "plaintext",
    value = build_context_lines(lines, b.line),
  },
  data = { completion_kind = "block" },
}
```

Changes:
- Added `data = { completion_kind = "block" }`
- Added `filterText = b.id .. " " .. b.text`
- Replaced single-line documentation with `build_context_lines()` (2-line context window)
- Used `truncate_preview()` for `labelDetails`

#### Path 3: Cross-file `[[Note^partial`

**File:** `lua/andrew/vault/completion.lua`, lines 285-301

Before (from original 03 spec):
```lua
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
```

After (current implementation):
```lua
block_items[#block_items + 1] = {
  label = b.id,
  insertText = b.id .. "]]",
  filterText = b.id .. " " .. (b.text or ""),
  kind = 22,
  labelDetails = { description = truncate_preview(b.text or "") },
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
```

Changes:
- Added `data = { completion_kind = "block", abs_path = ..., block_line = ... }`
- Added `filterText = b.id .. " " .. (b.text or "")`
- Used `truncate_preview()` for `labelDetails`
- Kept inline `documentation` as fallback; `resolve_item` enriches on highlight

### Change 2: `filterText` for content-based matching

Block IDs are typically auto-generated random strings (e.g., `blk-a7x2f9`).
Users remember content, not IDs. Setting `filterText` to `b.id .. " " .. b.text`
allows blink-cmp's fuzzy matcher to score against the block's content text.

**Example:** A block with ID `blk-abc123` on a line containing "This is the
introduction paragraph" gets `filterText = "blk-abc123 This is the introduction
paragraph"`. Typing `[[Note^intro` fuzzy-matches "intro" against the filterText
and surfaces this block.

Applied uniformly to all three paths:
- Standalone: `filterText = b.id .. " " .. b.text` (line 213)
- Same-file: `filterText = b.id .. " " .. b.text` (line 266)
- Cross-file: `filterText = b.id .. " " .. (b.text or "")` (line 288, guards nil text)

### Change 3: Lazy `resolve_item` with surrounding context

**File:** `lua/andrew/vault/completion.lua`, lines 371-417

The `resolve_item` function handles lazy documentation loading when the user
highlights an item in the completion menu. A new branch (before the existing
heading branch) handles `completion_kind == "block"`:

```lua
resolve_item = function(self, item, callback)
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

**Behavior:**
- Only activates for cross-file blocks (`item.data.abs_path` is present)
- Reads file from disk, collecting lines `[block_line - 3, block_line + 3]`
- Uses early termination (`break` at `block_line + context_after`) to avoid
  reading entire large files
- Formats a 7-line context window with the block line marked `>>>`
- Falls back gracefully if file is missing or `block_line` is nil
- Same-file block items do NOT go through `resolve_item` because they already
  have full context from `build_context_lines()` and lack `abs_path` in `data`

**Context window format (plaintext):**
```
    L42: Previous paragraph text continues here
    L43: and wraps to this line.
    L44:
>>> L45: This is the block content. ^blk-abc123
    L46:
    L47: Next paragraph starts here with
    L48: additional context about the topic.
```

### Change 4: Source name "Block" in completion menu

**File:** `lua/andrew/plugins/blink-cmp.lua`, lines 102-111

The `transform_items` callback relabels completion items based on
`completion_kind`:

Before (heading only):
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

After (heading + block):
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

**Result:** The completion menu source column shows:
- "Wikilinks" for note name completions (default)
- "Heading" for `[[Note#` or `[[#` heading completions
- "Block" for `[[Note^`, `[[^`, or standalone `^` block completions

### Change 5: Documentation preview with context

Same-file block items (paths 1 and 2) use `build_context_lines()` to provide
an inline context window in the documentation panel. This replaces the
previous single-line `"Line N: text"` format with a multi-line view showing
2 lines before and after the block line.

Cross-file block items (path 3) retain a minimal inline fallback (`"Line N:
text"`) that is replaced by the full 3-line context window when the user
highlights the item (via `resolve_item`).

**Design rationale for split approach:**
- Same-file items have buffer lines in memory -- context is free to compute
  inline during `get_completions`
- Cross-file items would require file I/O per block item during
  `get_completions`, which is wasteful since users typically inspect only 1-2
  items; `resolve_item` defers I/O until highlight

---

## Test Cases

### Functional Tests

1. **Cross-file block source label:**
   Open a vault note. Type `[[ExistingNote^` and verify block IDs appear.
   Confirm the source column shows "Block" (not "Wikilinks").

2. **Cross-file block fuzzy filtering by content:**
   Type `[[ExistingNote^` then type a word from the block's content text.
   Verify the block item is matched and ranked by blink-cmp fuzzy scoring.

3. **Cross-file block `resolve_item` context:**
   Type `[[ExistingNote^` and arrow-key to highlight a block item.
   Verify the documentation panel shows 3 lines before, block line with `>>>`,
   and 3 lines after. Verify line numbers are correct.

4. **Same-file block completion with context:**
   Add a block ID to the current buffer (e.g., `Some text ^blk-test01`).
   Type `[[^` and verify block IDs appear with surrounding context in the
   documentation panel. Confirm the source column shows "Block".

5. **Same-file block with unsaved changes:**
   Add a new block ID to the buffer without saving. Type `[[^` and verify the
   new block appears. Delete a block ID without saving and verify it no longer
   appears.

6. **Standalone block completion:**
   Type `^blk` outside of `[[` and verify current-buffer block IDs appear.
   Confirm source column shows "Block" and context is shown in documentation.

7. **Content-based filtering for same-file blocks:**
   Type `[[^` then type a word from a block's associated text. Verify the
   correct block is matched.

8. **Embed syntax (`![[Note^blk-id]]`):**
   Type `![[ExistingNote^` and verify block IDs appear with all features.

9. **Autopairs bracket handling:**
   With autopairs enabled, type `[[Note^` (which auto-inserts `]]`).
   Verify accepted block items do not double the closing brackets.

### Regression Tests

10. **Note name completion unchanged:**
    Type `[[` and verify note names and aliases still appear with "Wikilinks"
    source label. Accept a note and verify correct insertion.

11. **Heading completion unchanged:**
    Type `[[Note#` and verify headings still appear with "Heading" source label.
    Highlight a heading and verify lazy preview still loads.

12. **Heading `resolve_item` not broken:**
    Type `[[Note#` and highlight a heading item. Verify the documentation panel
    shows heading content preview (markdown format, not block context format).

### Edge Case Tests

13. **Block ID on empty line:**
    Create a line containing only `^blk-empty01`. Type `[[^` and verify the
    block appears with empty description but surrounding context in documentation.

14. **Note with no block IDs:**
    Type `[[NoteWithNoBlocks^` and verify empty completion (no error).

15. **Index not ready:**
    Restart Neovim. Immediately type `[[Note^` before index finishes. Verify
    graceful empty result (no errors).

16. **Very long block text:**
    Create a line with 200+ characters followed by `^blk-long01`. Verify
    `labelDetails` truncates at 60 characters with `...`. Verify `filterText`
    includes the full text (not truncated).

17. **Multiple blocks on adjacent lines:**
    Create three consecutive lines each with block IDs. Type `[[^` and verify
    all three appear. Highlight the middle one and verify context shows the
    other two.

18. **Cross-file `resolve_item` with deleted file:**
    Build completion list, then delete the target file before highlighting.
    Verify the item falls back to inline documentation without error.

19. **Block IDs containing hyphens:**
    Test block IDs like `blk-abc-123` and `my-custom-block`. Verify matching
    and display work correctly.

---

## Files Modified

### Modified

1. **`lua/andrew/vault/completion.lua`**
   - Lines 209-221: Standalone `^` path -- added `data`, `filterText`, context docs
   - Lines 262-274: Same-file `[[^` path -- added `data`, `filterText`, context docs
   - Lines 285-301: Cross-file `[[Note^` path -- added `data`, `filterText`, inline fallback docs
   - Lines 371-417: `resolve_item` -- added block context lazy loading branch
   - Lines 16-22: Added `truncate_preview()` helper
   - Lines 24-34: Added `build_context_lines()` helper

2. **`lua/andrew/plugins/blink-cmp.lua`**
   - Lines 102-111: Extended `transform_items` to relabel `completion_kind == "block"`
     items with `source_name = "Block"`

### Not Modified

- **`lua/andrew/vault/completion_base.lua`** -- factory pattern unchanged;
  `build`/`get_completions`/`resolve_item` lifecycle hooks are unchanged.
- **`lua/andrew/vault/vault_index.lua`** -- `block_ids` already stores
  `{ id, text, line }` objects with `block_id_set` lookup table. No new
  fields or methods needed.
- **`lua/andrew/vault/link_utils.lua`** -- `parse_target()` and
  `read_block_content()` unchanged.
- **`lua/andrew/vault/blockid.lua`** -- block ID generation unrelated to
  completion.
- **`lua/andrew/vault/config.lua`** -- no new configuration values.

---

## Design Decisions

### 1. `completion_kind` tagging follows heading pattern

The `data.completion_kind` field follows the pattern established by heading
completion (`data.completion_kind = "heading"`). This is a zero-cost,
non-breaking addition -- the `data` field is an opaque bag on blink-cmp items.
Both `transform_items` and `resolve_item` dispatch on `completion_kind`, so
the pattern ensures consistency across item types.

### 2. `filterText` includes both ID and text

Block IDs are typically auto-generated (`blk-a7x2f9`). Users think in content
terms, not ID terms. Including `b.text` in `filterText` enables content-based
fuzzy matching without changing the displayed `label` (which remains the clean
block ID). blink-cmp uses `filterText` for fuzzy scoring when present, falling
back to `label` otherwise.

The cross-file path guards against nil text: `b.id .. " " .. (b.text or "")`.
Same-file paths can omit the guard because `get_blocks()` always returns a
string for `text` (possibly empty).

### 3. Split inline vs lazy documentation

Same-file items build context inline via `build_context_lines()` because buffer
lines are already in memory. Cross-file items keep a minimal inline fallback
(`"Line N: text"`) and defer full context loading to `resolve_item` to avoid
file I/O during `get_completions` -- the user will typically inspect only 1-2
items.

### 4. Context window size

Same-file: 2 lines before/after (default `context_width` in `build_context_lines`).
Cross-file (`resolve_item`): 3 lines before/after (7 lines total).

The cross-file window is larger because it is loaded lazily (one-time cost)
and needs to compensate for the user not having the file open. Same-file uses
a smaller window since the user already has the file context.

### 5. Standalone `^` remains same-file only

Standalone `^partial` outside wikilinks is a same-file concept. Cross-file
block references always use `[[Note^blk-id]]` syntax. Offering blocks from
other files in the standalone path would be noisy and semantically incorrect.
