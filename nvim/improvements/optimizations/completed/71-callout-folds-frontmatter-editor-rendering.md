# 71 --- Callout Folds & Frontmatter Editor Rendering

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

Targeted improvements for the callout fold system and frontmatter editor
float, addressing quadratic block boundary scanning, redundant field
iteration in the editor, and synchronous file existence checks.

> **Modules affected:** `callout_folds.lua`, `frontmatter_editor.lua`

---

## 1. Single-Pass Callout Block Boundary Detection

### Problem Analysis

**File:** `lua/andrew/vault/callout_folds.lua` (lines 186-246)

The fold restore function uses nested loops to find callout block boundaries:

```lua
local i = 1
while i <= line_count do
  local line = lines[i]
  if line:match("^>%s*%[!") then       -- Found callout start
    -- Inner loop to find block end
    local j = i + 1
    while j <= line_count do
      if not lines[j]:match("^>") then  -- End of block
        break
      end
      j = j + 1
    end
    -- Process block from i to j-1
    i = j
  else
    i = i + 1
  end
end
```

While this looks O(N) due to the advancing index, the same pattern is
repeated in multiple functions (`fold_all`, `unfold_all`, `toggle_fold`,
`restore_folds`), each independently scanning the buffer for callout
blocks. A single scan building a block map would serve all operations.

Additionally, `restore_folds()` (line 186) reads the fold state from the
persisted file and applies folds for each saved block, where each fold
application calls `vim.api.nvim_buf_set_lines()` or fold manipulation.
If there are 20 callout blocks, that's 20 separate API calls.

### Proposed Solution

Build a callout block map once per changedtick, cache it, and reuse
across all fold operations.

### Code Changes

```lua
local _block_cache = {}  -- bufnr -> { tick, blocks }

--- Build callout block boundaries map.
---@param bufnr number
---@return table[]  { { start_line, end_line, level, title }, ... }
local function get_callout_blocks(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = _block_cache[bufnr]
  if cached and cached.tick == tick then
    return cached.blocks
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = {}
  local i = 1
  while i <= #lines do
    local title = lines[i]:match("^>%s*%[!(.-)%]")
    if title then
      local start = i
      i = i + 1
      while i <= #lines and lines[i]:match("^>") do
        i = i + 1
      end
      blocks[#blocks + 1] = {
        start_line = start,
        end_line = i - 1,
        title = title,
      }
    else
      i = i + 1
    end
  end

  _block_cache[bufnr] = { tick = tick, blocks = blocks }
  return blocks
end

-- Cleanup
vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  callback = function(ev) _block_cache[ev.buf] = nil end,
})
```

Then `fold_all`, `unfold_all`, `toggle_fold`, and `restore_folds` all
use `get_callout_blocks(bufnr)` instead of their own scan loops.

### Expected Performance Improvement

- **Before:** 4 independent block scans across fold operations
- **After:** 1 scan per changedtick, cached for all operations

For a buffer with 200 lines and 15 callout blocks, opening the buffer
and restoring folds: 4 * 200 = 800 line scans -> 200 line scans.

### Risk Assessment

- **Changedtick invalidation:** Editing inside a callout block changes
  the buffer's changedtick, forcing a re-scan. This ensures block
  boundaries are always current.
- **Nested callouts:** The scan correctly handles nested `>` lines as
  part of the outer block. No nesting-level tracking needed for fold
  purposes.

---

## 2. Merged Field Iteration in Frontmatter Editor

### Problem Analysis

**File:** `lua/andrew/vault/frontmatter_editor.lua` (lines 51-105, 131-140)

The frontmatter editor iterates the field list multiple times per render:

1. **Lines 45:** `max_key_width(fields)` — iterates all fields for max width
2. **Lines 51-55:** First pass — build display lines
3. **Lines 66-105:** Second pass — apply highlights

The float dimensions calculation also iterates fields separately:

4. **Lines 131-132:** `max_key_width(fields)` again
5. **Lines 136-140:** Separate loop for `max_w` calculation

```lua
-- Pass 1: width
local kw = type_utils.max_key_width(fields)

-- Pass 2: display lines
for _, f in ipairs(fields) do
  lines[#lines + 1] = format_field(f, kw)
end

-- Pass 3: highlights
for i, f in ipairs(fields) do
  apply_field_highlight(buf, i, f, kw)
end
```

### Proposed Solution

Merge passes 1-3 into a single iteration that computes max width, builds
display lines, and records highlight positions simultaneously.

### Code Changes

```lua
local function render_fields(buf, fields)
  -- Single pass: compute widths, build lines, collect highlight info
  local max_kw = 0
  for _, f in ipairs(fields) do
    max_kw = math.max(max_kw, #f.key)
  end

  local lines = {}
  local highlights = {}
  for i, f in ipairs(fields) do
    lines[i] = format_field(f, max_kw)
    highlights[i] = {
      key_end = max_kw,
      val_start = max_kw + 3,  -- ": " separator
      val_type = type(f.value),
    }
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Apply highlights from pre-computed positions
  for i, hl in ipairs(highlights) do
    apply_field_highlight(buf, i - 1, hl)
  end
end
```

### Expected Performance Improvement

For a frontmatter with 20 fields:

- **Before:** 4-5 iterations over fields (max_width + display + highlights
  + dimensions)
- **After:** 2 iterations (max_width scan + merged display/highlight)

~60% reduction in field iteration count.

### Risk Assessment

- **Highlight accuracy:** Pre-computed positions depend on `format_field`
  output being deterministic given `max_kw`. This is guaranteed since
  `format_field` pads to `max_kw`.

---

## 3. Deferred File Existence Check in Fold State Load

### Problem Analysis

**File:** `lua/andrew/vault/callout_folds.lua` (line 31)

When loading persisted fold state, `vim.fn.filereadable(abs)` is called
for every cached entry to prune deleted files:

```lua
for abs, folds in pairs(loaded) do
  if vim.fn.filereadable(abs) == 1 then
    _fold_state[abs] = folds
  end
end
```

For 100 cached files, this is 100 synchronous filesystem checks at startup.

### Proposed Solution

Skip the existence check during load. Prune stale entries lazily when
accessing fold state for a specific file (at that point, the file is
guaranteed to exist since the buffer is open).

### Code Changes

```lua
-- Load: accept all entries without existence check
for abs, folds in pairs(loaded) do
  _fold_state[abs] = folds
end

-- Prune on next persist (during VimLeavePre or periodic save)
local function prune_stale_entries()
  for abs in pairs(_fold_state) do
    if vim.fn.filereadable(abs) ~= 1 then
      _fold_state[abs] = nil
    end
  end
end
```

### Expected Performance Improvement

- **Before:** 100 `filereadable()` calls during startup
- **After:** 0 filesystem calls during startup; pruning deferred to save

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Callout block caching (#1) | Medium | High | Low |
| 2 | Frontmatter editor merge (#2) | Medium | Medium | Low |
| 3 | Deferred fold state check (#3) | Low | Low | Low |

---

## Testing Strategy

### Callout Block Caching (#1)
1. Open a file with 10 callout blocks. Run fold/unfold/toggle operations.
   Verify correct fold state at each step.
2. Edit inside a callout (add/remove `>` line). Verify block boundaries
   update correctly on next fold operation.
3. Delete buffer. Verify cache is cleaned up.

### Frontmatter Editor Merge (#2)
1. Open frontmatter editor on a file with 20 fields. Verify correct
   display and highlight alignment.
2. Edit a field value. Verify highlights update on re-render.

### Deferred Fold Check (#3)
1. Start Neovim with 100 files in fold state cache. Verify no startup delay.
2. Delete a file. Restart. Verify stale entry is pruned on next save.

---

## Related Documents

Standalone — no overlapping optimizations in other documents.
