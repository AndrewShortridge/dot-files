# 59 --- Completion & Link Resolution Performance

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

Three targeted optimizations for link resolution utilities and completion,
addressing quadratic path comparison, inefficient link jumping, and
redundant heading slug computation.

> **Modules affected:** `link_utils.lua`, `wikilinks.lua`, `completion.lua`

---

## 1. Efficient Path Proximity Scoring — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/link_utils.lua` (lines 403-427)

`M.pick_closest(paths)` scores each candidate path by character-by-character
prefix matching against the current buffer's directory. Two issues:

1. **`string.sub(i, i)` per character:** Creates a new string object for every
   character comparison. For two 80-character paths, this allocates 160 strings.
2. **`vim.fn.fnamemodify(path, ":h")` per path:** Cross-language call (Lua →
   VimScript) for each candidate, when pure Lua path extraction suffices.

```lua
-- link_utils.lua:403-427
function M.pick_closest(paths)
  if #paths == 1 then return paths[1] end
  local current_dir = vim.fn.expand("%:p:h")
  local best_path = paths[1]
  local best_score = math.huge
  for _, path in ipairs(paths) do
    local dir = vim.fn.fnamemodify(path, ":h")       -- VimScript call per path
    local common = 0
    for i = 1, math.min(#dir, #current_dir) do
      if dir:sub(i, i) == current_dir:sub(i, i) then -- 2 string allocs per char
        common = common + 1
      else
        break
      end
    end
    local score = (#dir - common) + (#current_dir - common)
    if score < best_score then
      best_score = score
      best_path = path
    end
  end
  return best_path
end
```

**Complexity:** O(P * C) where P = paths, C = max path length. Each character
comparison allocates two temporary strings.

### Proposed Solution

Replace character-by-character comparison with `string.byte()` (zero-allocation)
and replace `vim.fn.fnamemodify` with pure Lua dirname.

### Code Changes

```lua
--- Pure Lua dirname (avoids vim.fn cross-language call).
local function lua_dirname(path)
    return path:match("^(.+)/[^/]*$") or path
end

function M.pick_closest(paths)
    if #paths == 1 then return paths[1] end
    local current_dir = vim.fn.expand("%:p:h")
    local best_path = paths[1]
    local best_score = math.huge

    for _, path in ipairs(paths) do
        local dir = lua_dirname(path)
        -- Byte-level comparison: zero allocations
        local min_len = math.min(#dir, #current_dir)
        local common = 0
        for i = 1, min_len do
            if dir:byte(i) == current_dir:byte(i) then
                common = common + 1
            else
                break
            end
        end
        local score = (#dir - common) + (#current_dir - common)
        if score < best_score then
            best_score = score
            best_path = path
        end
    end
    return best_path
end
```

### Expected Performance Improvement

- **String allocations:** Reduced from 2 * C per path to 0 (byte comparison)
- **VimScript calls:** Reduced from P to 0 (pure Lua dirname)

For 10 candidate paths with 80-char directories: 1600 string allocations → 0.

### Risk Assessment

- **Correctness:** `string.byte()` comparison is equivalent to character
  comparison for ASCII paths. Non-ASCII paths are handled correctly since
  byte-level prefix matching produces the same common-prefix length.
- **Dirname:** The Lua pattern `^(.+)/[^/]*$` matches the same as
  `vim.fn.fnamemodify(path, ":h")` for absolute paths (which is all
  `pick_closest` receives).

---

## 2. Direct Link Navigation Without Full Collection — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/wikilinks.lua` (lines 397-459)

`jump_link(direction)` collects **all links** in the buffer, sorts them, then
finds the nearest one in the given direction. This involves:

1. Full buffer scan collecting every wikilink and markdown link
2. Table allocation per link (`{ row = i, col = s }`)
3. Full sort of all links by position
4. Linear search for the target link

```lua
-- wikilinks.lua:397-459 (simplified)
for i, line in ipairs(lines) do
  -- Find wikilinks
  while true do
    local s = line:find("%[%[", start)
    if not s then break end
    table.insert(links, { row = i, col = s })  -- allocation per link
    start = s + 2
  end
  -- Find markdown links
  while true do
    local s = line:find("%[.-%]%(.-%)", start)
    if not s then break end
    table.insert(links, { row = i, col = s })  -- allocation per link
    start = s + 1
  end
end
table.sort(links, function(a, b) ... end)  -- sort all links
```

For a buffer with 200 links: 200 table allocations + O(200 log 200) sort.

**Complexity:** O(L * P + N log N) where L = lines, P = patterns, N = links

### Proposed Solution

Find the target link directly without collecting all links. For forward
navigation, scan from the cursor position forward and return the first link
found. For backward, scan backward.

### Code Changes

```lua
local function jump_link(direction)
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local cur_row, cur_col = cursor[1], cursor[2] + 1  -- 1-indexed

    if direction == "forward" then
        -- Scan from cursor position forward
        for i = cur_row, #lines do
            local line = lines[i]
            local search_start = (i == cur_row) and (cur_col + 1) or 1
            local best_col = nil

            -- Check wikilinks
            local pos = search_start
            while true do
                local s = line:find("%[%[", pos)
                if not s then break end
                if not best_col or s < best_col then best_col = s end
                break  -- first match on this line is the closest
            end

            -- Check markdown links
            pos = search_start
            while true do
                local s = line:find("%[.-%]%(.-%)", pos)
                if not s then break end
                if not best_col or s < best_col then best_col = s end
                break
            end

            if best_col then
                vim.api.nvim_win_set_cursor(0, { i, best_col - 1 })
                return true
            end
        end
    else  -- backward
        for i = cur_row, 1, -1 do
            local line = lines[i]
            local search_end = (i == cur_row) and (cur_col - 1) or #line
            local best_col = nil

            -- Find last wikilink before search_end
            local pos = 1
            while true do
                local s = line:find("%[%[", pos)
                if not s or s > search_end then break end
                best_col = s  -- keep updating to find the last match
                pos = s + 2
            end

            -- Find last markdown link before search_end
            pos = 1
            while true do
                local s = line:find("%[.-%]%(.-%)", pos)
                if not s or s > search_end then break end
                if not best_col or s > best_col then best_col = s end
                pos = s + 1
            end

            if best_col then
                vim.api.nvim_win_set_cursor(0, { i, best_col - 1 })
                return true
            end
        end
    end

    return false
end
```

### Expected Performance Improvement

- **Before:** Scan entire buffer + 200 allocations + sort → ~2-5ms
- **After:** Scan from cursor to nearest link → ~0.1-0.5ms (early exit)

For forward navigation at line 10 of a 500-line buffer with a link on line 12:
scans only 3 lines instead of 500.

### Risk Assessment

- **Edge case — links at cursor:** The current implementation skips the link
  under the cursor (for "next link" behavior). The new implementation must
  replicate this by starting search at `cur_col + 1` for forward.
- **Pattern consistency:** Both wikilink and markdown link patterns are checked
  on the same line. The new approach picks the earliest match (forward) or
  latest match (backward), same as the sorted approach.
- **Wrap-around:** The current implementation does not wrap around (no cycling
  from last link to first). The new implementation preserves this behavior.

---

## 3. Cached Heading Slug in find_heading_line — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/link_utils.lua` (lines 143-152)

`M.find_heading_line(lines, heading)` computes `heading_to_slug()` for **every
heading** in the file until it finds a match:

```lua
function M.find_heading_line(lines, heading)
  local target_slug = M.heading_to_slug(heading)
  for i, l in ipairs(lines) do
    local text = l:match("^#+%s+(.*)")              -- regex per line
    if text and M.heading_to_slug(text) == target_slug then  -- slug per heading
      return i
    end
  end
  return nil
end
```

`heading_to_slug()` involves `lower()`, `gsub` for special chars, and `gsub`
for spaces → hyphens. For a file with 50 headings, this is 50 slug computations
even though the target is found on the 3rd heading.

### Proposed Solution

Add a fast early-exit check before computing the slug: skip lines that don't
start with `#`. Additionally, the slug computation itself is already fast, but
can be avoided entirely when the vault index has pre-computed heading slugs.

### Code Changes

```lua
function M.find_heading_line(lines, heading)
    local target_slug = M.heading_to_slug(heading)
    for i, l in ipairs(lines) do
        -- Fast check: skip non-heading lines without regex
        local first = l:byte(1)
        if first ~= 35 then goto continue end  -- 35 = '#'

        local text = l:match("^#+%s+(.*)")
        if text and M.heading_to_slug(text) == target_slug then
            return i
        end
        ::continue::
    end
    return nil
end
```

**Alternative: Use vault index heading data when available:**

```lua
function M.find_heading_line_indexed(rel_path, heading)
    local vi = require("andrew.vault.vault_index")
    local idx = vi.current()
    if not idx or not idx:is_ready() then return nil end
    local entry = idx.files[rel_path]
    if not entry or not entry.headings then return nil end

    local target_slug = M.heading_to_slug(heading)
    for _, h in ipairs(entry.headings) do
        if h.slug == target_slug then
            return h.line
        end
    end
    return nil
end
```

### Expected Performance Improvement

- **Byte check:** Eliminates regex evaluation for ~90% of lines (non-headings).
- **Index path:** O(headings) with pre-computed slugs vs O(lines) with regex.

### Risk Assessment

- **Byte check:** `#` is always ASCII 35. Safe for UTF-8 content since headings
  must start with `#`.
- **Index path:** Heading line numbers in the index may be stale if the buffer
  has been edited since the last index update. Use the byte-check optimization
  for buffer-based lookups and reserve the index path for cross-file navigation.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Path proximity scoring (#1) | Low | High | Low |
| 2 | Heading slug fast path (#3) | Low | Low | Low |
| 3 | Direct link navigation (#2) | Medium | Medium | Low |

#1 is a drop-in replacement with zero API changes. #3 is a one-line
optimization. #2 is larger but eliminates unnecessary sorting.

---

## Testing Strategy

### Path Proximity (#1)
1. With two files `notes/a.md` and `projects/b.md`, open `notes/c.md`.
   Verify `pick_closest` returns `notes/a.md`.
2. Profile: verify zero string allocations in the comparison loop.

### Link Navigation (#2)
1. Open a buffer with 50 links. Press `]l` (forward) and `[l` (backward).
   Verify cursor lands on the correct next/previous link.
2. Test at buffer boundaries (first link, last link).
3. Test with mixed wikilinks and markdown links on the same line.

### Heading Slug (#3)
1. Open a file with 50 headings. Call `find_heading_line` for the 40th heading.
   Verify correct line number returned.

---

## Related Documents

- Doc 81-cross-module-caching #1 covers heading_to_slug memoization at module level (complementary to #3 here which uses vault index data).

