# 74 --- Inline Fields & Link Scan Efficiency

> This document is a self-contained implementation guide. Each optimization below is unique to this document.

Targeted improvements for the inline field highlighting system and link
scanner, addressing triple-scan parsing, quadratic overlap checking, and
quadratic position tracking in name scanning.

> **Modules affected:** `inline_fields.lua`, `link_scan.lua`

---

## 1. Unified Field-Finding Pass in Inline Fields — Status: IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/inline_fields.lua` (lines 294-323)

`parse_line()` calls three separate field-finding functions sequentially,
each scanning the same line independently:

```lua
local function parse_line(line, lnum)
  local fields = {}
  -- Pass 1: bracketed fields [key:: value]
  local bracket = find_bracket_fields(line, lnum)     -- lines 76-154
  vim.list_extend(fields, bracket)
  -- Pass 2: parenthesized fields (key:: value)
  local paren = find_paren_fields(line, lnum)          -- lines 160-213
  vim.list_extend(fields, paren)
  -- Pass 3: standalone fields key:: value
  local standalone = find_standalone_fields(line, lnum) -- lines 220-288
  -- ... overlap check ...
  vim.list_extend(fields, standalone)
  return fields
end
```

Each function scans the line with its own `string.find()` loop. For a
line with 3 inline fields, the line is scanned 3 times.

**Complexity:** O(3 * line_length) per line with inline fields.

### Proposed Solution

Merge the three field-finding functions into a single scan that checks
all three delimiters at each position:

### Code Changes

```lua
local function find_all_fields(line, lnum)
  local fields = {}
  local pos = 1
  while pos <= #line do
    local bracket_open = line:find("%[", pos, true)
    local paren_open = line:find("%(", pos, true)
    local standalone_sep = line:find("::", pos, true)

    -- Find earliest delimiter
    local earliest = math.min(
      bracket_open or math.huge,
      paren_open or math.huge,
      standalone_sep or math.huge
    )
    if earliest == math.huge then break end

    if earliest == bracket_open then
      local field, end_pos = try_parse_bracket(line, lnum, bracket_open)
      if field then
        fields[#fields + 1] = field
        pos = end_pos + 1
      else
        pos = bracket_open + 1
      end
    elseif earliest == paren_open then
      local field, end_pos = try_parse_paren(line, lnum, paren_open)
      if field then
        fields[#fields + 1] = field
        pos = end_pos + 1
      else
        pos = paren_open + 1
      end
    else
      local field, end_pos = try_parse_standalone(line, lnum, standalone_sep)
      if field then
        fields[#fields + 1] = field
        pos = end_pos + 1
      else
        pos = standalone_sep + 2
      end
    end
  end
  return fields
end
```

### Expected Performance Improvement

For a buffer with 50 lines containing inline fields:

- **Before:** 50 * 3 = 150 line scans
- **After:** 50 single-pass scans

~3x reduction in line scanning work.

### Risk Assessment

- **Correctness:** The merged scanner processes delimiters in positional
  order, which naturally resolves overlaps without a separate check.
- **Standalone vs bracket priority:** Brackets and parens are checked
  first at each position (same priority as current code).

---

## 2. Eliminate O(n^2) Overlap Check in Inline Fields — Status: IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/inline_fields.lua` (lines 309-320)

After finding standalone fields, an overlap check compares each
standalone field against all bracket/paren fields:

```lua
for _, sf in ipairs(standalone) do
  local dominated = false
  for _, f in ipairs(fields) do
    if sf.col_start >= f.col_start and sf.col_end <= f.col_end then
      dominated = true
      break
    end
  end
  if not dominated then
    fields[#fields + 1] = sf
  end
end
```

For a line with N bracket fields and M standalone fields, this is
O(N * M) comparisons.

### Proposed Solution

If using the unified scanner from optimization #1, overlaps are
naturally impossible since the scanner advances past consumed regions.
If keeping separate passes, use an interval bitset:

### Code Changes

```lua
-- Build occupied ranges from bracket/paren fields
local occupied = {}
for _, f in ipairs(fields) do
  for col = f.col_start, f.col_end do
    occupied[col] = true
  end
end

-- Filter standalone fields in O(1) per field
for _, sf in ipairs(standalone) do
  if not occupied[sf.col_start] then
    fields[#fields + 1] = sf
  end
end
```

### Expected Performance Improvement

- **Before:** O(N * M) comparisons per line
- **After:** O(N + M) with bitset (O(1) lookup per standalone)

### Risk Assessment

- **Memory:** Bitset size = line length. For 200-char lines: 200 entries.
  Negligible and garbage collected per line.

---

## 3. Cached Buffer Fields for Navigation — Status: IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/inline_fields.lua` (lines 478-502, 513, 613)

`get_buffer_fields(bufnr)` rescans the entire buffer on every call.
It is called from `jump_field()` (navigation) and other entry points,
triggering a full reparse even when the buffer hasn't changed:

```lua
function M.get_buffer_fields(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local all_fields = {}
  for i, line in ipairs(lines) do
    local fields = parse_line(line, i)
    -- ... accumulate ...
  end
  return all_fields
end
```

### Proposed Solution

Cache parsed fields with changedtick invalidation:

### Code Changes

```lua
local _field_cache = {}  -- bufnr -> { tick, fields }

function M.get_buffer_fields(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = _field_cache[bufnr]
  if cached and cached.tick == tick then
    return cached.fields
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local all_fields = {}
  for i, line in ipairs(lines) do
    local fields = parse_line(line, i)
    for _, f in ipairs(fields) do
      all_fields[#all_fields + 1] = f
    end
  end

  _field_cache[bufnr] = { tick = tick, fields = all_fields }
  return all_fields
end

-- Cleanup on buffer delete
vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  callback = function(ev) _field_cache[ev.buf] = nil end,
})
```

### Expected Performance Improvement

For navigating inline fields (j/k jumps) in a 500-line buffer:

- **Before:** Full 500-line reparse per jump
- **After:** O(1) cache hit per jump (until buffer changes)

### Risk Assessment

- **Staleness:** changedtick ensures fresh data on any edit.
- **Memory:** One field array per buffer. Cleaned on BufDelete.

---

## 4. Interval-Based Position Tracking in Link Scan — Status: IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/link_scan.lua` (lines 283-289)

`is_position_taken()` checks whether a candidate match overlaps with
any already-found link. It iterates all existing matches linearly:

```lua
local function is_position_taken(matches, line_idx, col_start, col_end)
  for _, m in ipairs(matches) do
    if m.line == line_idx then
      if col_start < m.col_end and col_end > m.col_start then
        return true
      end
    end
  end
  return false
end
```

For a line with 20 autolinks and 10 wikilinks, each new candidate
checks against all 30 existing matches: O(N^2) per line.

### Proposed Solution

Maintain a per-line sorted interval list with binary search, or use a
simpler per-line column bitset:

### Code Changes

```lua
-- Per-line occupied columns (reset each line)
local line_occupied = {}  -- line_idx -> { col_start -> col_end }

local function mark_taken(line_idx, col_start, col_end)
  if not line_occupied[line_idx] then
    line_occupied[line_idx] = {}
  end
  line_occupied[line_idx][col_start] = col_end
end

local function is_position_taken(line_idx, col_start, col_end)
  local occupied = line_occupied[line_idx]
  if not occupied then return false end
  for ostart, oend in pairs(occupied) do
    if col_start < oend and col_end > ostart then
      return true
    end
  end
  return false
end
```

### Expected Performance Improvement

For a line with 30 links:

- **Before:** 30 * 29 / 2 = 435 overlap checks (triangular)
- **After:** 30 hash lookups with ~5 entries per line average

Reduces from O(N^2) to O(N * K) where K = links per line (typically
small, making it effectively O(N)).

### Risk Assessment

- **Hash collisions:** Lua tables handle this well for integer keys.
- **Reset cost:** `line_occupied = {}` per line is O(1).

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Cached buffer fields (#3) | Low | High | Low |
| 2 | Unified field scan (#1) | Medium | Medium | Low |
| 3 | Interval position tracking (#4) | Medium | Medium | Low |
| 4 | Overlap check elimination (#2) | Low | Low | Low |

---

## Testing Strategy

### Unified Field Scan (#1)
1. Open a file with mixed bracket, paren, and standalone fields.
   Verify all three types render correctly.
2. Test edge case: `[key:: value] (other:: val)` on same line.
3. Verify standalone fields don't overlap bracket/paren regions.

### Cached Buffer Fields (#3)
1. Jump between inline fields with `]f`/`[f`. Verify correct targets.
2. Edit a field value. Verify next jump reflects the change.
3. Open 5 buffers with fields. Verify cache per-buffer isolation.

### Position Tracking (#4)
1. Open a file with dense autolinks (20+ per line). Verify correct
   highlighting without overlap.
2. Test with wikilinks adjacent to autolinks on same line.

---

## Related Documents

Standalone — no overlapping optimizations in other documents.
