# Engine & Startup Performance

This document is a self-contained implementation guide. Each optimization
below is unique to this document.

Three targeted optimizations for the watcher, display width calculations,
and code exclusion closures.

> **Modules affected:** `engine_watcher.lua`, `preview.lua`, `footnotes.lua`,
> `embed.lua`, `link_scan.lua`

---

## 1. Watcher Filesystem Optimization

### Problem Analysis

**File:** `lua/andrew/vault/engine_watcher.lua` (lines 40-64)

On Linux (inotify), the `on_fs_event()` callback calls `vim.uv.fs_stat()`
synchronously for every filesystem event to check if the path is a directory:

```lua
local function on_fs_event(vault, base_dir, err_msg, filename, _events)
  if not _platform_recursive then
    local stat = vim.uv.fs_stat(abs_path)       -- sync stat on every event
    if stat and stat.type == "directory" ... then
      add_dir_watch(vault, abs_path)
      local dir_handle = vim.uv.fs_scandir(abs_path)  -- sync dir scan
      ...
    end
  end
```

During a git checkout or sync that touches hundreds of files, this results
in hundreds of synchronous `fs_stat` calls. Most events are for `.md` files,
which don't need the directory check.

### Proposed Solution

Add a fast-path check before `fs_stat`: if the filename has a known file
extension, skip the directory check entirely.

```lua
local function on_fs_event(vault, base_dir, err_msg, filename, _events)
  if err_msg then return end
  if not filename then return end

  local abs_path = base_dir .. "/" .. filename

  -- Fast path: known file extensions skip the directory stat
  local has_ext = filename:match("%.%w+$")

  if not _platform_recursive and not has_ext then
    -- Only stat when the name looks like it could be a directory
    local stat = vim.uv.fs_stat(abs_path)
    if stat and stat.type == "directory" and not watcher_skip_dirs()[filename] then
      add_dir_watch(vault, abs_path)
      -- NOTE: The preemptive directory scan below is separately optimized
      -- in Doc 61-startup-and-watcher-performance #2 (deferred scan).
      -- This optimization (#1) focuses on the fast-path extension check
      -- to skip the fs_stat call entirely for files with extensions.
      local dir_handle = vim.uv.fs_scandir(abs_path)
      if dir_handle then
        while true do
          local name, ftype = vim.uv.fs_scandir_next(dir_handle)
          if not name then break end
          if ftype == "file" and name:match("%.md$") then
            _pending_changed_files[abs_path .. "/" .. name] = true
          end
        end
      end
    end
  end

  -- ... rest of event handling (image cache invalidation, .md check) ...
end
```

### Expected Performance Improvement

- **Before:** 1 `fs_stat` per filesystem event on Linux
- **After:** `fs_stat` only for extensionless paths (likely directories)

During a bulk operation touching 500 files, this eliminates ~490 synchronous
stat calls (assuming ~98% have file extensions).

### Risk Assessment

- **Edge case:** A directory named without an extension (e.g., `notes`) will
  correctly trigger the stat path. A directory named `foo.bar` will be missed
  on the fast path, but it will be discovered on the next vault index rebuild.
- **Existing behavior preserved:** The `.md` file handling and image cache
  invalidation logic (lines 66-80) runs regardless of this optimization.

---

## 2. Display Width Fast Path

### Problem Analysis

**Files:** `preview.lua` (lines 64-66), `footnotes.lua` (line ~484),
`embed.lua` (line ~39)

Multiple modules compute the display width of text content by calling
`vim.fn.strdisplaywidth()` in a loop:

```lua
-- preview.lua:64-66
for _, l in ipairs(lines) do
  width = math.max(width, vim.fn.strdisplaywidth(l))
end
```

`vim.fn.strdisplaywidth()` is a VimScript function call that:
1. Crosses the Lua → VimScript boundary
2. Processes the full string to handle multibyte characters and tab stops

For ASCII-dominant vault notes, this is unnecessary overhead. A 200-line
preview with ASCII content makes 200 cross-language calls when `#line`
would suffice.

### Proposed Solution

Add a fast-path that checks for ASCII-only content before falling back to
the Vim API. This can be a shared utility.

```lua
-- In a shared utility (e.g., link_scan.lua or a new helpers.lua)

--- Fast display width: uses string length for ASCII-only lines,
--- falls back to vim.fn.strdisplaywidth for lines with multibyte chars.
---@param s string
---@return number
local function display_width(s)
  -- If every byte is in the ASCII printable range (0x20-0x7E) or tab,
  -- string length equals display width (tabs excluded for simplicity).
  -- The find pattern matches the first non-ASCII byte.
  if not s:find("[\128-\255\t]") then
    return #s
  end
  return vim.fn.strdisplaywidth(s)
end
```

Replace `vim.fn.strdisplaywidth(l)` with `display_width(l)` in:
- `preview.lua:65`
- `footnotes.lua:~484`
- `embed.lua:~39`

### Expected Performance Improvement

For ASCII-dominant content (typical English vault notes):

- **Before:** N cross-language VimScript calls per width calculation loop
- **After:** N fast Lua string scans (no cross-language overhead)

The improvement is modest per-call (~1-5us saved per line), but in preview
rendering with 200+ lines, it adds up to measurable latency reduction.

### Risk Assessment

- **Correctness:** The ASCII fast-path returns exactly the same result as
  `strdisplaywidth` for lines containing only printable ASCII. Lines with
  multibyte characters or tabs correctly fall back to the Vim API.
- **Tab handling:** Lines with tabs are routed to `strdisplaywidth` which
  handles tab stops correctly. The fast path excludes tabs via `\t` in the
  pattern.

---

## 3. Code Exclusion Closure Linear Scan Optimization

### Problem Analysis

**File:** `link_scan.lua` (lines 66-75)

The closure returned by `build_code_exclusion()` performs a linear scan of
all code block ranges for every `(row, col)` check:

```lua
return function(row, col)
  for _, r in ipairs(ranges) do
    local sr, sc, er, ec = r[1], r[2], r[3], r[4]
    if row > sr and row < er then return true end
    if row == sr and row == er and col >= sc and col < ec then return true end
    if row == sr and row ~= er and col >= sc then return true end
    if row == er and row ~= sr and col < ec then return true end
  end
  return false
end
```

For a file with 20 code blocks and 500 lines to scan, this is 500 × 20 =
10,000 range comparisons per highlight pass. The ranges are sorted by start
position (treesitter returns them in document order), but no binary search
is used.

### Proposed Solution

Pre-build a row-indexed lookup for O(1) average-case checks:

```lua
return function(row, col)
  -- Fast check: is this row entirely inside any code block?
  if row_set[row] then return true end

  -- Boundary check: only needed for first/last rows of code blocks
  local boundaries = boundary_rows[row]
  if not boundaries then return false end

  for _, r in ipairs(boundaries) do
    local sr, sc, er, ec = r[1], r[2], r[3], r[4]
    if row == sr and row == er and col >= sc and col < ec then return true end
    if row == sr and row ~= er and col >= sc then return true end
    if row == er and row ~= sr and col < ec then return true end
  end
  return false
end
```

Where `row_set` is a hash set of all rows strictly inside a code block
(excluding first/last rows which need column checks), and `boundary_rows`
maps first/last rows to their range entries.

```lua
-- Build indexes after collecting ranges:
local row_set = {}
local boundary_rows = {}

for _, r in ipairs(ranges) do
  local sr, er = r[1], r[3]
  -- Interior rows: fully inside the block
  for row = sr + 1, er - 1 do
    row_set[row] = true
  end
  -- Boundary rows: need column checks
  if not boundary_rows[sr] then boundary_rows[sr] = {} end
  boundary_rows[sr][#boundary_rows[sr] + 1] = r
  if er ~= sr then
    if not boundary_rows[er] then boundary_rows[er] = {} end
    boundary_rows[er][#boundary_rows[er] + 1] = r
  end
end
```

### Expected Performance Improvement

- **Before:** O(R) range comparisons per check (R = number of code blocks)
- **After:** O(1) hash lookup for interior rows, O(B) for boundary rows
  where B is typically 1-2

For a file with 20 code blocks and 500 check calls, this reduces from
10,000 comparisons to ~500 hash lookups + ~40 boundary comparisons.

### Risk Assessment

- **Memory:** The `row_set` table stores one entry per interior code block
  row. For a 1000-line file with 200 lines in code blocks, this is ~200
  entries (~3KB). Negligible.
- **Correctness:** The boundary row logic handles all four cases from the
  original code (single-line blocks, multi-line start, multi-line end).
- **Build cost:** The pre-indexing loop is O(total code block lines), which
  is already dominated by the treesitter parsing cost.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Code exclusion row index (#3) | Low | Medium | Low |
| 2 | Watcher fast-path (#1) | Low | Low-Medium | Low |
| 3 | Display width fast path (#2) | Low | Low | Low |

All three optimizations are independent and self-contained. **#3** affects
the most modules and should be implemented first. **#1** and **#2** target
specific use cases (bulk filesystem operations and preview rendering).

---

## Testing Strategy

### Watcher Fast-Path (#1)
1. Create 100 `.md` files in vault. Verify no `fs_stat` calls for the events
   (add instrumentation or check watcher stats).
2. Create a new directory (no extension). Verify it gets watched.
3. Rename a file to remove its extension. Verify it doesn't break indexing.

### Display Width (#2)
1. Preview a note with only ASCII content. Verify correct width.
2. Preview a note with CJK characters. Verify correct width (falls back).
3. Preview a note with tabs. Verify correct width (falls back).

### Code Exclusion Row Index (#3)
1. File with nested code blocks: verify highlights skip all code regions.
2. Single-line inline code: verify column-level exclusion works.
3. File with no code blocks: verify no false positives.

---

## Related Documents

- Doc 56-highlight-viewport-rendering covers code exclusion caching by changedtick (different aspect — caching vs. algorithm here in #3).
- Doc 59-startup-lazy-loading and Doc 61-startup-and-watcher-performance cover broader startup optimizations.
- Doc 61-startup-and-watcher-performance #2 covers deferring the preemptive directory scan itself (complementary to the fast-path extension check in #1 here).
