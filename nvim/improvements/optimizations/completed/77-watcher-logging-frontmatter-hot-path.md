# 77 --- Watcher, Logging & Frontmatter Hot Path

This document is a self-contained implementation guide. Each optimization
below is unique to this document.

Targeted improvements for per-event overhead in the filesystem watcher,
unconditional string formatting in the logger, and missing changedtick
caching in frontmatter cursor detection.

> **Modules affected:** `engine_watcher.lua`, `vault_log.lua`,
> `frontmatter_parser.lua`

---

## 1. Cached Skip-Dirs Set in Watcher

### Problem Analysis

**File:** `lua/andrew/vault/engine_watcher.lua` (line 20)

`watcher_skip_dirs()` is called on every filesystem event to check
whether the changed path should be ignored:

```lua
local function watcher_skip_dirs()
  return require("andrew.vault.config").index.skip_dirs
end
```

While `require()` is cached after first call, this still involves a
table lookup chain (`package.loaded -> config -> index -> skip_dirs`)
on every single filesystem event. During bulk operations (git pull,
file sync), hundreds of events fire per second.

### Proposed Solution

Cache the skip_dirs set as a module-level variable:

### Code Changes

```lua
-- Module level:
local _skip_dirs = nil

local function get_skip_dirs()
  if not _skip_dirs then
    _skip_dirs = require("andrew.vault.config").index.skip_dirs
  end
  return _skip_dirs
end
```

### Expected Performance Improvement

For a git pull touching 100 files (100 fs events):

- **Before:** 100 require chain lookups
- **After:** 1 lookup + 99 local variable reads

Minor per-event savings, but eliminates unnecessary work on a
high-frequency path.

### Risk Assessment

- **Config changes:** Skip dirs don't change after init. No staleness.

---

## 2. Counter-Based Pending File Tracking

### Problem Analysis

**File:** `lua/andrew/vault/engine_watcher.lua` (lines 84, 239, 247)

The watcher uses `vim.tbl_count()` to check pending file count:

```lua
-- Line 84: in debounce callback
elseif vim.tbl_count(_pending_changed_files) == 0 then
  return  -- nothing to process

-- Line 239: in watcher_status()
active = vim.tbl_count(_fs_watchers) > 0,

-- Line 247: in watcher_status()
pending_files = vim.tbl_count(_pending_changed_files),
```

`vim.tbl_count()` is O(N) — it iterates the entire table to count
entries. For `_pending_changed_files` with 50 queued changes, this
scans all 50 entries just to check if the table is empty.

### Proposed Solution

Maintain counter variables alongside the tables:

### Code Changes

```lua
-- Module level:
local _pending_count = 0
local _watcher_count = 0

-- When adding a pending file:
if not _pending_changed_files[rel_path] then
  _pending_changed_files[rel_path] = true
  _pending_count = _pending_count + 1
end

-- When processing pending files:
_pending_changed_files = {}
_pending_count = 0

-- When adding/removing watchers:
_watcher_count = _watcher_count + 1  -- on add
_watcher_count = _watcher_count - 1  -- on remove

-- Replace vim.tbl_count checks:
-- Line 84:
elseif _pending_count == 0 then return end

-- Line 239:
active = _watcher_count > 0,

-- Line 247:
pending_files = _pending_count,
```

### Expected Performance Improvement

- **Before:** O(N) per debounce callback and status query
- **After:** O(1) counter reads

For a debounce firing every 200ms with 30 pending files:

- **Before:** 30 iterations * 5 fires/sec = 150 iterations/sec
- **After:** 5 counter reads/sec

### Risk Assessment

- **Counter accuracy:** Must update on every add/clear/remove path.
  Simple to verify since `_pending_changed_files` is only modified
  in two places (accumulate and clear).

---

## 3. Cached Image Extensions Set

### Problem Analysis

**File:** `lua/andrew/vault/engine_watcher.lua` (line 69)

On every filesystem event, the image extensions list is fetched from
config:

```lua
local image_exts = require("andrew.vault.config").embed.image_exts
```

This is used to check whether a changed file is an image (to trigger
embed cache invalidation). The extension list never changes after init.

### Proposed Solution

Cache as module-level variable:

### Code Changes

```lua
-- Module level:
local _image_exts = nil

local function get_image_exts()
  if not _image_exts then
    _image_exts = {}
    for _, ext in ipairs(require("andrew.vault.config").embed.image_exts) do
      _image_exts[ext] = true  -- set for O(1) lookup
    end
  end
  return _image_exts
end

-- In event handler:
local ext = abs_path:match("%.([^.]+)$")
if ext and get_image_exts()[ext:lower()] then
  -- trigger embed cache invalidation
end
```

### Expected Performance Improvement

- **Before:** Config chain lookup + list iteration per event
- **After:** O(1) set lookup per event

### Risk Assessment

- **Config changes:** Image extensions don't change after init.

---

## 4. Early-Exit in Logger Before String Formatting

### Problem Analysis

**File:** `lua/andrew/vault/vault_log.lua` (lines 51-81)

`emit()` formats the log message unconditionally, even when neither
notify nor file output will use it:

```lua
local function emit(level_name, prefix, fmt, ...)
  local level_num = LEVELS[level_name]
  local ok, msg = pcall(string.format, fmt, ...)  -- ALWAYS formats
  if not ok then msg = fmt end
  local full = prefix ~= "" and ("[vault:" .. prefix .. "] " .. msg)
                             or ("[vault] " .. msg)  -- ALWAYS concatenates

  if level_num >= _min_notify_level then
    vim.notify(full, level_num)
  end

  if level_num >= _min_file_level then
    -- write to file
  end
end
```

For debug-level logging with notify at ERROR and file at WARN, every
`log.debug(...)` call still formats the string and concatenates the
prefix, only to discard the result.

### Proposed Solution

Add early-exit before formatting:

### Code Changes

```lua
local function emit(level_name, prefix, fmt, ...)
  local level_num = LEVELS[level_name]

  -- Early exit: skip all work if both outputs are filtered
  if level_num < _min_notify_level and level_num < _min_file_level then
    return
  end

  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = fmt end
  local full = prefix ~= "" and ("[vault:" .. prefix .. "] " .. msg)
                             or ("[vault] " .. msg)

  if level_num >= _min_notify_level then
    vim.notify(full, level_num)
  end

  if level_num >= _min_file_level then
    -- write to file
  end
end
```

### Expected Performance Improvement

For a session with 1000 debug log calls and notify_level=ERROR,
file_level=WARN:

- **Before:** 1000 `string.format()` + 1000 concatenation = 2000
  string allocations (all discarded)
- **After:** 1000 level comparisons (integers), 0 string allocations

Eliminates all overhead from filtered debug logging.

### Risk Assessment

- **Correctness:** The early-exit condition exactly mirrors the
  existing output conditions. No behavior change for messages that
  would have been output.

---

## 5. Changedtick-Cached cursor_in_frontmatter()

### Problem Analysis

**File:** `lua/andrew/vault/frontmatter_parser.lua` (lines 150-163)

`cursor_in_frontmatter()` fetches buffer lines and scans for the
frontmatter boundary on every call:

```lua
function M.cursor_in_frontmatter(bufnr, row)
  local n = math.min(vim.api.nvim_buf_line_count(bufnr), max_lines)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)
  if #lines == 0 or lines[1] ~= "---" then return false end
  for i = 2, #lines do
    if lines[i] == "---" then
      return row < i
    end
  end
  return false
end
```

This is called from completion providers and highlight modules, which
may invoke it multiple times per keystroke. Each call fetches lines
from the buffer and scans them linearly.

### Proposed Solution

Cache the frontmatter end line with changedtick invalidation:

### Code Changes

```lua
local _fm_range_cache = {}  -- bufnr -> { tick, end_line }

function M.cursor_in_frontmatter(bufnr, row)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = _fm_range_cache[bufnr]
  if cached and cached.tick == tick then
    return cached.end_line and row < cached.end_line
  end

  local n = math.min(vim.api.nvim_buf_line_count(bufnr), max_lines)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)

  local end_line = nil
  if #lines > 0 and lines[1] == "---" then
    for i = 2, #lines do
      if lines[i] == "---" then
        end_line = i
        break
      end
    end
  end

  _fm_range_cache[bufnr] = { tick = tick, end_line = end_line }
  return end_line and row < end_line
end

-- Cleanup
vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  callback = function(ev) _fm_range_cache[ev.buf] = nil end,
})
```

### Expected Performance Improvement

For 3 modules calling `cursor_in_frontmatter()` per keystroke:

- **Before:** 3 buffer line fetches + 3 linear scans per keystroke
- **After:** 1 fetch + 1 scan (first call) + 2 cache hits

~3x reduction in frontmatter boundary detection.

### Risk Assessment

- **Changedtick:** Editing inside frontmatter changes the tick,
  forcing a re-scan. Ensures correct boundary detection.
- **Memory:** One entry per buffer. Cleaned on BufDelete.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Logger early-exit (#4) | Low | High | Low |
| 2 | FM cursor cache (#5) | Low | Medium | Low |
| 3 | Counter-based tracking (#2) | Low | Medium | Low |
| 4 | Cached skip-dirs (#1) | Low | Low | Low |
| 5 | Image ext cache (#3) | Low | Low | Low |

---

## Testing Strategy

### Logger Early-Exit (#4)
1. Set log levels to ERROR/WARN. Generate debug log calls. Verify no
   output and no performance impact.
2. Set log level to DEBUG. Verify messages appear correctly.

### FM Cursor Cache (#5)
1. Place cursor in frontmatter. Verify `cursor_in_frontmatter()` returns
   true.
2. Edit frontmatter boundary. Verify cache invalidates correctly.
3. Move cursor below frontmatter. Verify returns false.

### Counter-Based Tracking (#2)
1. Run `:VaultWatcherStatus`. Verify correct pending file count.
2. Trigger bulk file changes. Verify counter stays accurate.

---

## Related Documents

- Doc 63-engine-startup-performance #1 covers watcher fast-path extension check (complementary).
- Doc 61-startup-and-watcher-performance covers watcher startup deferral.
