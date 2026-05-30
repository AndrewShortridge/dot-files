# 78 --- Highlight Navigation & Outline Deduplication

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

Targeted improvements addressing duplicate full-buffer scans for
navigation in highlight modules, double-iteration in outline building,
and redundant rendering setup in preview floats.

> **Modules affected:** `highlights.lua`, `tag_highlights.lua`,
> `inline_fields.lua`, `outline.lua`, `preview.lua`

---

## 1. Shared Scan Results for Highlight Navigation

### Problem Analysis

**File:** `lua/andrew/vault/highlights.lua` (lines 42-95, 136-159)

The highlights module scans the full buffer twice independently:

1. `apply(bufnr)` (lines 42-95): Scans all lines for `==highlight==`
   patterns and applies extmarks
2. `jump_highlight()` (lines 136-159): Scans all lines again with
   identical pattern matching to build a position list for navigation

```lua
-- apply() at line 42:
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
for i, line in ipairs(lines) do
  -- find ==highlight== patterns
end

-- jump_highlight() at line 136:
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
for i, line in ipairs(lines) do
  -- find ==highlight== patterns (identical logic)
end
```

**Same pattern in tag_highlights.lua** (lines 95 and 215-246):
`apply()` and `jump_tag()` both scan the full buffer independently
with the same tag-matching logic.

### Proposed Solution

Cache the positions found during `apply()` and reuse them in
`jump_*()` navigation functions:

### Code Changes

```lua
-- Module-level cache:
local _positions = {}  -- bufnr -> { tick, positions }

local function apply(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local positions = {}

  -- Clear and apply extmarks (existing logic)
  for i, line in ipairs(lines) do
    -- ... find patterns, apply extmarks ...
    -- Also record positions:
    positions[#positions + 1] = { row = i - 1, col = col_start }
  end

  -- Cache for navigation
  _positions[bufnr] = {
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
    positions = positions,
  }
end

local function jump_highlight(direction)
  local bufnr = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = _positions[bufnr]

  local positions
  if cached and cached.tick == tick then
    positions = cached.positions  -- O(1) cache hit
  else
    -- Fallback: rescan if apply() hasn't run yet
    positions = scan_positions(bufnr)
  end

  -- Binary search or linear search for next/prev position
  -- ... existing navigation logic using positions ...
end
```

### Expected Performance Improvement

For navigating highlights in a 1000-line buffer:

- **Before:** 1000-line rescan per `]h`/`[h` keypress
- **After:** O(1) cache lookup + O(log N) binary search on positions

### Risk Assessment

- **Stale positions:** Changedtick ensures rescan if buffer changed
  since last `apply()`. Navigation between `apply()` calls falls
  back to direct scanning.
- **Memory:** Position array is small (~100 entries for typical files).

---

## 2. Same Pattern for Tag Navigation

### Problem Analysis

**File:** `lua/andrew/vault/tag_highlights.lua` (lines 95, 215-246)

Identical duplication pattern as highlights.lua:

```lua
-- apply() at line 95:
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
for i, line in ipairs(lines) do
  -- find #tag patterns, skip frontmatter/headings
end

-- jump_tag() at line 215:
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
for i, line in ipairs(lines) do
  -- find #tag patterns (same frontmatter/heading skip logic)
end
```

Both functions skip the same lines (frontmatter, headings, code blocks)
and apply the same tag regex.

### Proposed Solution

Same as optimization #1: cache tag positions during `apply()` and
reuse in `jump_tag()`.

### Code Changes

```lua
-- Module-level cache (same pattern as highlights.lua):
local _tag_positions = {}  -- bufnr -> { tick, positions }

-- In apply():
-- After finding each tag, record: { row, col, tag_text }
_tag_positions[bufnr] = { tick = tick, positions = positions }

-- In jump_tag():
local cached = _tag_positions[bufnr]
if cached and cached.tick == tick then
  -- Use cached positions for navigation
end
```

### Expected Performance Improvement

Same as #1: eliminates duplicate full-buffer scan per navigation.

---

## 3. Single-Pass Outline Building

### Problem Analysis

**File:** `lua/andrew/vault/outline.lua` (lines 28-50)

`build_outline()` iterates headings twice:

1. **First pass** (lines 28-39): Treesitter iteration to build `raw`
   table with heading text and level
2. **Second pass** (lines 44-50): Iterates `raw` to compute display
   widths for alignment

```lua
-- Pass 1: collect headings
local raw = {}
for _, heading in ipairs(headings) do
  local line = vim.api.nvim_buf_get_lines(buf, heading.row, heading.row + 1, false)[1]
  raw[#raw + 1] = { text = line, level = heading.level, row = heading.row }
end

-- Pass 2: compute widths
local max_w = 0
for _, r in ipairs(raw) do
  max_w = math.max(max_w, vim.fn.strdisplaywidth(r.text))
end
```

Additionally, pass 1 fetches lines one-at-a-time with individual API
calls (line 30).

### Proposed Solution

Fetch all lines once, then compute widths during the heading collection
pass:

### Code Changes

```lua
local function build_outline(buf, headings)
  -- Fetch all lines once (instead of per-heading API calls)
  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- Single pass: collect headings AND compute max width
  local raw = {}
  local max_w = 0
  for _, heading in ipairs(headings) do
    local line = all_lines[heading.row + 1]  -- 1-indexed
    if line then
      local w = vim.fn.strdisplaywidth(line)
      max_w = math.max(max_w, w)
      raw[#raw + 1] = {
        text = line,
        level = heading.level,
        row = heading.row,
        width = w,  -- pre-computed
      }
    end
  end

  return raw, max_w
end
```

### Expected Performance Improvement

For a file with 50 headings:

- **Before:** 50 individual `nvim_buf_get_lines()` API calls + 50
  `strdisplaywidth()` calls in second pass = 100 cross-boundary calls
- **After:** 1 `nvim_buf_get_lines()` call + 50 `strdisplaywidth()`
  calls in same pass = 51 calls

~50% reduction in API boundary crossings.

### Risk Assessment

- **Memory:** Full buffer in memory. For 2000-line files: ~100KB.
  Acceptable for user-initiated outline operation.
- **Heading row validity:** Already guaranteed by treesitter extraction.

---

## ~~4. Deduplicated Rendering Setup in Preview~~ → Consolidated

> **Consolidated into Doc 61-calendar-task-ui-optimizations.md Section 3
> ("Preview Float Reuse").**
>
> Doc 61 #3 covers preview buffer reuse, setup state tracking
> (`_treesitter_started`, `_keymaps_set`), and breadcrumb caching.
> The setup deduplication and width caching proposed here are naturally
> subsumed by that buffer-reuse approach — when the buffer is reused,
> redundant setup calls and width recomputation are eliminated.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Highlight navigation cache (#1) | Low | Medium | Low |
| 2 | Tag navigation cache (#2) | Low | Medium | Low |
| 3 | Outline single-pass (#3) | Low | Medium | Low |
| ~~4~~ | ~~Preview dedup (#4)~~ | — | — | — | → Consolidated into Doc 61 #3 |

---

## Testing Strategy

### Highlight Navigation Cache (#1)
1. Open a file with 20 highlights. Press `]h`/`[h`. Verify correct
   navigation to each highlight.
2. Edit a highlight (add/remove). Press `]h`. Verify updated positions.
3. Verify no stale jump targets after editing.

### Tag Navigation Cache (#2)
1. Open a file with 15 tags. Press `]t`/`[t`. Verify correct navigation.
2. Add a tag in frontmatter. Verify it's skipped (frontmatter tags
   are not inline tags).
3. Add a tag in a heading. Verify it's skipped.

### Outline Single-Pass (#3)
1. Open outline for a file with 50 headings. Verify all headings appear.
2. Verify alignment is correct (max_w computed correctly).
3. Test with a file containing headings with CJK characters.

### ~~Preview Dedup (#4)~~ → See Doc 61 #3

---

## Related Documents

- Doc 61-calendar-task-ui-optimizations #3 is the canonical source for preview float optimization (buffer reuse + setup dedup). Former #4 here consolidated there.
- Doc 56-highlight-viewport-rendering covers viewport-scoped highlight rendering (complementary to #1-#2 here).
