# Heading/Block Anchor Completion

## Problem Statement

When typing a wikilink with a heading anchor (`[[Note Name#`) or block reference
(`[[Note Name^`), the completion system **reads the target file from disk** to
extract headings and block IDs. This works, but it is:

1. **Redundant.** The vault index (`vault_index.lua`) already stores `headings`
   and `block_ids` for every indexed file. The completion module ignores this
   data and re-parses files on every keystroke.

2. **Slower than necessary.** Each heading/block completion triggers a
   synchronous `io.open` + line-by-line read of the target file via
   `read_lines()` and then a full scan via `get_headings()` or `get_blocks()`.
   For large notes this adds latency to every completion popup update.

3. **Missing content previews for index-backed completions.** The current
   `get_headings()` in `completion.lua` builds content previews (up to 8 lines
   after each heading), which is valuable context. Block completions show the
   line text. These previews need to be preserved or improved.

4. **Inconsistent resolution.** The `resolve_note_path()` function in
   `completion.lua` resolves note names by iterating over the cached completion
   `items` list (which contains blink-cmp completion items) and matching labels.
   This is a reimplementation of note resolution that should delegate to the
   vault index, which already handles basename, relative path, and alias
   resolution with proximity-based disambiguation.

5. **Same-file headings/blocks read live buffer but cross-file ones read disk.**
   This is actually correct behavior (unsaved buffer changes should appear for
   same-file), but the distinction is not leveraged from the index for cross-file
   cases where the index data is sufficient.

## Current Architecture

### Completion Flow

The completion system is built on `blink.cmp` (a Neovim completion engine). The
vault wikilink source is registered as `andrew.vault.completion` in the blink-cmp
plugin config.

**Source registration** (`lua/andrew/plugins/blink-cmp.lua`):
```lua
wikilinks = {
  name = "Wikilinks",
  module = "andrew.vault.completion",
  min_keyword_length = 0,
  score_offset = 15,
  fallbacks = {},
},
```

**Base factory** (`completion_base.lua`):
- `create_source(opts)` provides standard boilerplate: caching, invalidation,
  async build, and the `get_completions` / `resolve` lifecycle hooks.
- The `build` callback is called once to populate the item cache (note name
  completion items).
- The `get_completions` callback receives `(self, ctx, items, callback)` where
  `items` is the cached list from `build`.

**Completion source** (`completion.lua`):

The source defines three trigger characters: `[`, `#`, `^`.

The `get_completions` callback handles four distinct completion modes, determined
by pattern matching on the text before the cursor:

1. **Standalone block ID** (`^partial` outside `[[`): completes block IDs from
   the current buffer.

2. **Block reference in wikilink** (`[[Note^partial` or `[[^partial`): reads the
   target file (or current buffer for same-file) and returns block IDs via
   `get_blocks()`.

3. **Heading reference in wikilink** (`[[Note#partial` or `[[#partial`): reads
   the target file (or current buffer for same-file) and returns headings via
   `get_headings()`.

4. **Note name completion** (`[[partial`): returns the pre-built `items` list
   (note names + aliases).

### Note Resolution in Completion

The `resolve_note_path(items, name)` function resolves a note name to a file
path by scanning the `items` array (blink-cmp completion items) for a matching
`label`. When multiple matches exist, it picks the one closest to the current
buffer's directory.

This duplicates logic already in `vault_index:resolve_name()` and the wikilinks
module.

### Data Available in Vault Index

Each `VaultIndexEntry` in `vault_index.files` contains:

```lua
entry.headings = {
  { text = "Introduction", slug = "introduction", level = 1, line = 5 },
  { text = "Sub Section",  slug = "sub-section",  level = 2, line = 12 },
  ...
}

entry.heading_slugs = {
  ["introduction"] = true,
  ["sub-section"] = true,
  ...
}

entry.block_ids = { "blk-abc123", "blk-def456", ... }
```

The `headings` array contains all the metadata needed for completion items:
heading text (for the label), level (for display), line number (for display),
and slug (for matching).

The `block_ids` array contains bare IDs (without the `^` prefix). However, it
does **not** store the associated line text or line number -- only the ID string.
This is a gap that affects the quality of block completion previews.

### Current Helper Functions

**`get_headings(lines)`** in `completion.lua`:
- Takes an array of lines, skips frontmatter, extracts headings with level,
  text, line number, order, and a content preview (up to 8 non-empty lines
  after the heading, stopping at the next heading).
- Returns an ordered array of heading objects.

**`get_blocks(lines)`** in `completion.lua`:
- Takes an array of lines, finds lines ending with `^block-id`.
- Returns objects with `id`, `text` (the line content without the block marker),
  and `line` (line number).

**`resolve_note_path(items, name)`** in `completion.lua`:
- Scans completion items for matching labels, disambiguates by directory
  proximity.

## Proposed Solution

### Overview

Refactor heading and block completion to use the vault index as the primary data
source for **cross-file** references, while keeping live buffer reads for
**same-file** references (to capture unsaved changes).

The changes are minimal and surgical -- the completion flow structure remains
identical, but the data source for cross-file heading/block lookups switches
from disk reads to index lookups.

### Key Changes

1. **Replace `resolve_note_path()` with vault index resolution.** Instead of
   scanning blink-cmp items, resolve note names via
   `vault_index:resolve_name()` with proximity disambiguation.

2. **Replace `read_lines()` + `get_headings()` for cross-file heading
   completion** with a direct read of `entry.headings` from the vault index.
   Content previews for headings are not in the index, so either:
   - (A) Accept no preview for cross-file headings (simpler, faster), or
   - (B) Add a lazy preview fetch in `resolve_item` (preview on demand), or
   - (C) Read the file only when building the completion items but use index
     data for the heading list and line numbers (hybrid approach).

   **Recommended: Option B** -- show heading metadata (level, line number) in the
   initial completion list, then load the content preview lazily when the user
   highlights a heading item in the completion menu (via `resolve_item`).

3. **Replace `read_lines()` + `get_blocks()` for cross-file block completion**
   with vault index `block_ids`. Since the index only stores IDs (no line text),
   either:
   - (A) Accept ID-only completion (no preview text), or
   - (B) Enhance the vault index to store block text alongside IDs, or
   - (C) Fall back to file read for block previews (hybrid).

   **Recommended: Option B** -- enhance vault index `extract_block_ids()` to also
   capture the associated line text and line number. This is a small change to
   the parser.

4. **Keep same-file references reading from the live buffer.** When `note_name`
   is empty (i.e., `[[#` or `[[^`), continue using
   `vim.api.nvim_buf_get_lines()` so unsaved edits are reflected immediately.

### Architecture After Changes

```
User types [[Note#    or    [[Note^
       |                         |
       v                         v
  Pattern match:            Pattern match:
  note_name = "Note"        block_note_name = "Note"
       |                         |
       v                         v
  resolve_note_via_index()  resolve_note_via_index()
       |                         |
       v                         v
  vault_index entry         vault_index entry
       |                         |
       v                         v
  entry.headings            entry.block_ids (enhanced)
       |                         |
       v                         v
  Build completion items    Build completion items
  (level, line, order)      (id, text, line)
       |                         |
       v                         v
  resolve_item: lazy        (preview already inline)
  load content preview
```

## Implementation Steps

### Step 1: Enhance vault index block ID extraction

Modify `extract_block_ids()` in `vault_index.lua` to return structured objects
instead of bare ID strings, capturing the line text and line number.

**Current** (`vault_index.lua` lines 368-383):
```lua
local function extract_block_ids(content)
  local ids = {}
  for id in content:gmatch("%^([%w%-]+)%s*\n") do
    ids[#ids + 1] = id
  end
  -- Also match block ID at end of file (no trailing newline)
  local last_id = content:match("%^([%w%-]+)%s*$")
  if last_id then
    local seen = false
    for _, id in ipairs(ids) do
      if id == last_id then seen = true; break end
    end
    if not seen then ids[#ids + 1] = last_id end
  end
  return ids
end
```

**Proposed:**
```lua
--- Extract block IDs from content with associated text and line numbers.
---@param content string
---@return table[] Array of { id: string, text: string, line: number }
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

This changes `block_ids` from `string[]` to `table[]`. All consumers of
`entry.block_ids` must be updated.

**Impact assessment -- consumers of `entry.block_ids`:**

Search for all uses of `block_ids` across the codebase to identify what needs
updating:

- `vault_index.lua` itself (`extract_block_ids`, `_parse_file`): updated above.
- `link_utils.lua` (`read_block_content`): does NOT use index block_ids; reads
  from file directly.
- `embed.lua`: uses `link_utils.read_block_content()`, not index block_ids.
- `linkdiag.lua` / `wikilink_highlights.lua`: may check `entry.block_ids` for
  existence validation -- need to update from `vim.tbl_contains(entry.block_ids, id)`
  to iterating objects or building a lookup set.

To maintain backward compatibility and avoid a large refactor, add a derived
`block_id_set` (a lookup table for quick existence checks) alongside the
structured `block_ids` array:

```lua
-- In _parse_file(), after extracting block_ids:
local block_id_set = {}
for _, b in ipairs(block_ids) do
  block_id_set[b.id] = true
end

return {
  ...
  block_ids = block_ids,       -- structured: { id, text, line }[]
  block_id_set = block_id_set, -- lookup: { [id] = true }
  ...
}
```

**Critical: update `VaultIndex:get_block_ids()`** (line 1279 of
`vault_index.lua`). This method converts `entry.block_ids` to a set and is used
by `linkcheck.lua`. It currently assumes each element is a string:

```lua
-- Current (will break):
for _, id in ipairs(entry.block_ids or {}) do
  set[id] = true
end

-- Updated:
for _, b in ipairs(entry.block_ids or {}) do
  set[b.id] = true
end
```

Alternatively, this method can simply return `entry.block_id_set` directly:

```lua
function M.VaultIndex:get_block_ids(abs_path)
  local prefix = self.vault_path .. "/"
  if abs_path:sub(1, #prefix) ~= prefix then return {} end
  local rel_path = abs_path:sub(#prefix + 1)
  local entry = self.files[rel_path]
  if not entry then return {} end
  return entry.block_id_set or {}
end
```

### Step 2: Add index-based note resolution to completion.lua

Replace `resolve_note_path()` with a function that uses the vault index.

**Current** (`completion.lua` lines 74-107):
```lua
local function resolve_note_path(items, name)
  -- Scans blink-cmp items for matching labels
  -- Disambiguates by directory proximity
  ...
end
```

**Proposed:**
```lua
--- Resolve a note name to its vault index entry using the vault index.
--- Returns the entry and its abs_path, or nil if not found.
--- Uses proximity to the current buffer when multiple notes share the same name.
---@param name string  Note name (basename or alias)
---@return VaultIndexEntry|nil entry
---@return string|nil abs_path
local function resolve_note_via_index(name)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return nil, nil end

  local paths = idx:resolve_name(name)
  if not paths or #paths == 0 then return nil, nil end

  local abs_path
  if #paths == 1 then
    abs_path = paths[1]
  else
    -- Multiple matches: pick the closest to the current buffer's directory
    local current_dir = vim.fn.expand("%:p:h")
    local best, best_score = paths[1], math.huge
    for _, path in ipairs(paths) do
      local dir = vim.fn.fnamemodify(path, ":h")
      local common = 0
      for i = 1, math.min(#dir, #current_dir) do
        if dir:sub(i, i) == current_dir:sub(i, i) then
          common = common + 1
        else
          break
        end
      end
      local score = (#dir - common) + (#current_dir - common)
      if score < best_score then
        best_score = score
        best = path
      end
    end
    abs_path = best
  end

  -- Find the entry by abs_path
  for _, entry in pairs(idx.files) do
    if entry.abs_path == abs_path then
      return entry, abs_path
    end
  end

  return nil, abs_path
end
```

**Optimization note:** The loop over `idx.files` to find an entry by `abs_path`
is O(N). For better performance, the vault index could maintain a reverse map
`abs_path -> rel_path`. However, since this only runs once per completion
trigger (not per item), O(N) is acceptable for vaults under 2000 files. If
needed, add `_abs_path_index` to vault_index later.

### Step 3: Refactor heading completion to use vault index

Replace the file-reading path in heading completion with index data.

**Current** (`completion.lua` lines 274-310):
```lua
-- Heading completion: [[Note Name#partial, [[#partial (same file), or ![[...#partial
local note_name = before:match("!?%[%[(.-)#[^%]]*$")
if note_name then
  local lines
  if note_name == "" then
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  else
    local target_path = resolve_note_path(items, note_name)
    if target_path then lines = read_lines(target_path) end
  end

  if lines then
    local headings = get_headings(lines)
    local heading_items = {}
    for _, h in ipairs(headings) do
      heading_items[#heading_items + 1] = {
        label = h.text,
        insertText = h.text .. "]]",
        kind = 22,
        sortText = string.format("%04d", h.order),
        labelDetails = {
          description = string.rep("#", h.level) .. " L" .. h.line,
        },
        documentation = h.preview ~= "" and {
          kind = "markdown",
          value = string.rep("#", h.level) .. " " .. h.text .. "\n\n" .. h.preview,
        } or nil,
        data = { completion_kind = "heading" },
      }
    end
    callback({ ... items = heading_items })
  else
    callback(empty)
  end
  return
end
```

**Proposed:**
```lua
-- Heading completion: [[Note Name#partial, [[#partial (same file), or ![[...#partial
local note_name = before:match("!?%[%[(.-)#[^%]]*$")
if note_name then
  if note_name == "" then
    -- Same-file: read live buffer (captures unsaved changes)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local headings = get_headings(lines)
    local heading_items = {}
    for _, h in ipairs(headings) do
      heading_items[#heading_items + 1] = {
        label = h.text,
        insertText = h.text .. "]]",
        kind = 22,
        sortText = string.format("%04d", h.order),
        labelDetails = {
          description = string.rep("#", h.level) .. " L" .. h.line,
        },
        documentation = h.preview ~= "" and {
          kind = "markdown",
          value = string.rep("#", h.level) .. " " .. h.text .. "\n\n" .. h.preview,
        } or nil,
        data = { completion_kind = "heading" },
      }
    end
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = heading_items })
  else
    -- Cross-file: use vault index
    local entry, target_path = resolve_note_via_index(note_name)
    if entry and entry.headings and #entry.headings > 0 then
      local heading_items = {}
      for order, h in ipairs(entry.headings) do
        heading_items[#heading_items + 1] = {
          label = h.text,
          insertText = h.text .. "]]",
          kind = 22,
          sortText = string.format("%04d", order),
          labelDetails = {
            description = string.rep("#", h.level) .. " L" .. h.line,
          },
          -- No inline preview; loaded lazily via resolve_item
          data = {
            completion_kind = "heading",
            abs_path = target_path,
            heading_line = h.line,
            heading_level = h.level,
          },
        }
      end
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = heading_items })
    else
      callback(empty)
    end
  end
  return
end
```

### Step 4: Refactor block completion to use vault index

Replace the file-reading path in block completion with index data.

**Current** (`completion.lua` lines 233-272):
```lua
-- Block completion: [[Note Name^partial, [[^partial (same file), or ![[...^partial
local block_note_name = before:match("!?%[%[(.-)%^[^%]]*$")
if block_note_name then
  local lines
  if block_note_name == "" then
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  else
    local base_name = block_note_name:match("^([^#]+)") or block_note_name
    base_name = vim.trim(base_name)
    local target_path = resolve_note_path(items, base_name)
    if target_path then lines = read_lines(target_path) end
  end

  if lines then
    local blocks = get_blocks(lines)
    local block_items = {}
    for _, b in ipairs(blocks) do
      ...
    end
    callback({ ... items = block_items })
  else
    callback(empty)
  end
  return
end
```

**Proposed:**
```lua
-- Block completion: [[Note Name^partial, [[^partial (same file), or ![[...^partial
local block_note_name = before:match("!?%[%[(.-)%^[^%]]*$")
if block_note_name then
  if block_note_name == "" then
    -- Same-file: read live buffer
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
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = block_items })
  else
    -- Cross-file: use vault index
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
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = block_items })
    else
      callback(empty)
    end
  end
  return
end
```

### Step 5: Add lazy heading preview in resolve_item

Extend `resolve_item` to handle heading completion items. When the user
highlights a heading in the completion menu, load the content preview from disk.

**Current `resolve_item`** only handles note-level items (items with
`data.abs_path` but no `completion_kind`).

**Add a heading branch:**
```lua
resolve_item = function(self, item, callback)
  -- Heading preview: lazy-load content under the heading
  if item.data and item.data.completion_kind == "heading" and item.data.abs_path then
    local path = item.data.abs_path
    local heading_line = item.data.heading_line
    local heading_level = item.data.heading_level

    local f = io.open(path, "r")
    if not f then
      callback(item)
      return
    end

    local lines = {}
    local line_num = 0
    for line in f:lines() do
      line_num = line_num + 1
      if line_num >= heading_line then
        lines[#lines + 1] = line
      end
      -- Read up to 20 lines past the heading
      if line_num > heading_line + 20 then break end
    end
    f:close()

    -- Extract preview: skip heading line, collect up to 8 non-empty lines
    -- until next same-or-higher-level heading
    local preview = {}
    for i = 2, #lines do
      local level_str = lines[i]:match("^(#+)%s+")
      if level_str and #level_str <= heading_level then break end
      if lines[i] ~= "" then
        preview[#preview + 1] = lines[i]
        if #preview >= 8 then break end
      end
    end

    if #preview > 0 then
      item.documentation = {
        kind = "markdown",
        value = lines[1] .. "\n\n" .. table.concat(preview, "\n"),
      }
    else
      item.documentation = {
        kind = "markdown",
        value = lines[1] or "",
      }
    end

    callback(item)
    return
  end

  -- Original note-level resolve logic...
  if not item.data or not item.data.abs_path then
    callback(item)
    return
  end
  ...
end,
```

### Step 6: Update block_ids consumers (if needed)

Search all files that reference `entry.block_ids` or `.block_ids` and update
them to handle the new structured format.

**Likely consumers:**
- `linkdiag.lua` -- if it validates block ID existence via the index
- `wikilink_highlights.lua` -- if it checks block reference validity

For each consumer, replace:
```lua
-- Old: block_ids is string[]
vim.tbl_contains(entry.block_ids, target_id)
```
with:
```lua
-- New: use block_id_set for O(1) lookup
entry.block_id_set and entry.block_id_set[target_id]
```

### Step 7: Remove dead code

After the refactor, the following can be removed from `completion.lua`:

- `read_lines()` -- no longer used for cross-file reads (same-file uses
  `vim.api.nvim_buf_get_lines()`)
- `resolve_note_path()` -- replaced by `resolve_note_via_index()`

The `get_headings()` and `get_blocks()` functions are still needed for same-file
completion (reading from the live buffer).

## Key Design Decisions

### 1. Same-file vs. cross-file split

**Decision:** Same-file references (`[[#Heading]]`, `[[^block]]`) continue to
read from the live buffer via `vim.api.nvim_buf_get_lines()`. Cross-file
references use the vault index.

**Rationale:** Same-file completions must reflect unsaved changes. The user may
have just added a heading and immediately want to reference it with `[[#`. The
vault index only updates on save (or on `build_async` triggered by fs events),
so it would miss unsaved edits. Cross-file notes are always read from disk
anyway, so the index is equivalent and faster.

### 2. Lazy preview loading for headings

**Decision:** Cross-file heading completion items show metadata (level, line
number) immediately, with content previews loaded on-demand via `resolve_item`.

**Rationale:** Building content previews requires reading the file and scanning
lines after each heading. For a note with 20 headings, this means reading 20
preview blocks. With lazy loading, only the highlighted item's preview is
loaded, which is faster for the common case where the user already knows which
heading they want.

### 3. Structured block_ids in the vault index

**Decision:** Change `block_ids` from `string[]` to `{ id, text, line }[]` in
the vault index, and add a `block_id_set` for O(1) existence checks.

**Rationale:** Block completion previews showing the associated line text are
significantly more useful than bare IDs. The additional storage cost is minimal
(one string + one number per block). The `block_id_set` lookup table avoids
breaking existing consumers that just need existence checks.

### 4. Trigger detection approach

**Decision:** Keep the existing pattern-matching approach for detecting `#` and
`^` triggers. No changes to trigger detection logic.

**Rationale:** The current regex patterns (`before:match("!?%[%[(.-)#[^%]]*$")`
and `before:match("!?%[%[(.-)%^[^%]]*$")`) correctly handle all wikilink
variants: `[[Note#`, `[[#`, `![[Note#`, `[[Note Name With Spaces#`. No bugs
have been reported with trigger detection; the issue is purely in data sourcing.

### 5. No fuzzy matching for headings/blocks

**Decision:** Heading and block completion items are returned as-is and filtered
by blink-cmp's built-in fuzzy matcher.

**Rationale:** blink-cmp already provides high-quality fuzzy matching on
completion item labels. Adding custom fuzzy logic would duplicate effort and
could conflict with blink-cmp's scoring. The `filterText` field can be set if
additional filter tokens are needed, but the heading text itself is sufficient.

### 6. Sorting strategy

**Decision:** Headings are sorted by document order (`sortText` = zero-padded
order index). Block IDs are unsorted (appearing in document order from the index
parser).

**Rationale:** Document order is the most intuitive sort for headings -- it
matches the note's outline structure. Users scanning for a heading expect to see
them in the order they appear in the document, not alphabetically.

## Edge Cases

### Non-existent notes

When the user types `[[NonExistent#`, `resolve_note_via_index()` returns nil
because the note is not in the index. The completion returns `empty` -- no
items. This is correct behavior: you cannot reference headings of a note that
does not exist.

### Notes with no headings

When `entry.headings` is empty or nil, the completion returns `empty`. This
matches the current behavior.

### Notes with no block IDs

When `entry.block_ids` is empty or nil, the completion returns `empty`. This
matches the current behavior.

### Alias resolution

A user might type `[[My Alias#` where "My Alias" is a frontmatter alias for a
note named "Actual Name". The vault index's `resolve_name()` checks both
`_name_index` and `_alias_index`, so aliases resolve correctly. The current
`resolve_note_path()` also handles this because aliases appear as completion
items with matching labels. Both approaches work.

### Same-file references (`[[#Heading]]`, `[[^block]]`)

Same-file references are detected by the empty note name (`note_name == ""`).
These continue to use live buffer reads. No change in behavior.

### Embed syntax (`![[Note#Heading]]`)

The regex pattern `!?%[%[(.-)#[^%]]*$` matches both `[[Note#` and `![[Note#`.
The `note_name` extracted is the same in both cases. Embed syntax works
identically to link syntax for completion purposes.

### Notes with identical basenames in different folders

When `resolve_name()` returns multiple paths, the proximity-based disambiguation
in `resolve_note_via_index()` picks the closest match. This mirrors the behavior
in the current `resolve_note_path()`.

### Pipe-aliased links (`[[Note|Display#`)

This is a malformed link -- the `#` is inside the alias portion, not the target.
The regex `!?%[%[(.-)#[^%]]*$` would capture `Note|Display` as the note name.
`resolve_note_via_index("Note|Display")` returns nil. This is acceptable: the
user should type `[[Note#Heading|Display]]` (anchor before alias).

### Index not ready

If `vault_index.current()` returns nil or `is_ready()` is false, the function
falls back gracefully: `resolve_note_via_index()` returns nil, and the
completion returns `empty`. Once the index is ready (usually within a few
hundred ms of startup), completions start working. This matches the existing
behavior where the `build` callback returns `{}` when the index is not ready.

### Stale index data

If a cross-file note's headings have changed but the index hasn't been updated
yet (e.g., the note was edited in another editor and the fs watcher hasn't
fired), the completion may show outdated headings. This is acceptable and
self-correcting: the index updates on save, on fs events, and on focus gain.
The user can also run `:VaultIndexRebuild`.

### Heading text containing special characters

Heading text like `## C++ Templates` or `## What's Next?` is stored as-is in
the index. The completion `label` shows the raw text. The `insertText` includes
the raw text plus `]]`. Obsidian handles these headings by slug matching, so the
link `[[Note#C++ Templates]]` resolves correctly via slug comparison.

## Files Modified

### Modified

1. **`lua/andrew/vault/vault_index.lua`**
   - Modify `extract_block_ids()` to return structured `{ id, text, line }[]`
     instead of `string[]`.
   - Add `block_id_set` to `_parse_file()` return value.

2. **`lua/andrew/vault/completion.lua`**
   - Add `resolve_note_via_index()` function.
   - Refactor heading completion branch to use vault index for cross-file.
   - Refactor block completion branch to use vault index for cross-file.
   - Extend `resolve_item` to handle heading preview lazy loading.
   - Remove `resolve_note_path()` function.
   - Remove `read_lines()` function.

3. **`lua/andrew/vault/vault_index.lua` -- `get_block_ids()` method**
   - Update `VaultIndex:get_block_ids()` (line 1279) to iterate `b.id` instead
     of bare strings, or return `entry.block_id_set` directly.
   - This method is consumed by `linkcheck.lua` (lines 197, 366) for block
     reference validation.
   - No other files directly iterate `entry.block_ids` from the index; they all
     go through `get_block_ids()` or use `link_utils.read_block_content()`.

### Not Modified

- `completion_base.lua` -- no changes needed; the `build`/`get_completions`
  factory pattern is unchanged.
- `link_utils.lua` -- no changes needed; its `read_block_content()` and
  `extract_headings()` operate on file content directly (used by embed.lua,
  preview.lua) and are unrelated to completion.
- `config.lua` -- no new configuration needed.
- `slug.lua` -- no changes.

## Testing Plan

### Manual Testing

1. **Cross-file heading completion:**
   - Open a vault note. Type `[[ExistingNote#` and verify headings appear.
   - Confirm heading levels (##, ###) are shown in label details.
   - Confirm document order is preserved.
   - Highlight a heading item and verify content preview loads.
   - Accept a heading and verify `[[ExistingNote#Heading Text]]` is inserted.

2. **Cross-file block completion:**
   - Open a vault note. Type `[[ExistingNote^` and verify block IDs appear.
   - Confirm line text previews are shown.
   - Accept a block and verify `[[ExistingNote^blk-id]]` is inserted.

3. **Same-file heading completion:**
   - Add a new heading to the current buffer (without saving).
   - Type `[[#` and verify the new heading appears.
   - Verify all existing headings appear with previews.

4. **Same-file block completion:**
   - Add a new block ID to the current buffer (without saving).
   - Type `[[^` and verify the new block ID appears.

5. **Alias resolution:**
   - Find a note with a frontmatter alias. Type `[[AliasName#` and verify
     headings from the aliased note appear.

6. **Non-existent note:**
   - Type `[[DoesNotExist#` and verify empty completion (no errors).

7. **Embed syntax:**
   - Type `![[ExistingNote#` and verify headings appear.
   - Type `![[ExistingNote^` and verify block IDs appear.

8. **Autopairs bracket handling:**
   - With autopairs enabled, type `[[Note#` (which auto-inserts `]]`).
   - Verify `insertText` correctly avoids doubling the closing brackets.

9. **Note with many headings (performance):**
   - Open a note with 50+ headings. Type `[[LargeNote#` and verify completion
     appears without noticeable delay.

10. **Standalone block ID:**
    - Type `^blk` outside of `[[`. Verify current-buffer block IDs still appear
      (this flow is unchanged).

### Regression Testing

11. **Normal note completion:**
    - Type `[[` and verify note names and aliases still appear.
    - Accept a note and verify correct insertion.

12. **Resolve item for notes:**
    - Highlight a note in `[[` completion and verify the preview (frontmatter +
      body) still loads correctly.

### Edge Case Testing

13. **Index not ready:**
    - Restart Neovim. Immediately type `[[Note#` before the index finishes
      building. Verify graceful empty result (no errors).

14. **Multiple notes with same name:**
    - If two notes share a basename (e.g., `Projects/Alpha.md` and
      `Archive/Alpha.md`), type `[[Alpha#` and verify headings from the
      proximity-closest match appear.

15. **Block ID format variations:**
    - Test with block IDs containing hyphens (`^blk-abc-123`).
    - Test with block IDs at end of file (no trailing newline).
    - Test with block IDs on otherwise empty lines.

### Automated Verification

16. **Index data integrity:**
    - Run `:VaultIndexStatus` and verify heading/block counts are reasonable.
    - Cross-check a few notes: open a note, count its headings manually,
      compare with `vault_index.current().files[rel_path].headings` count.

17. **Block ID set consistency:**
    - For a sample entry, verify every `block_ids[i].id` exists in
      `block_id_set`.
