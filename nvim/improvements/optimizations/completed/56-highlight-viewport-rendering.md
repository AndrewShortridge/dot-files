# 56 --- Viewport-Aware Highlight Rendering & Autocmd Consolidation

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

Four highlight modules (`highlights.lua`, `wikilink_highlights.lua`,
`tag_highlights.lua`, `footnotes.lua`) all perform full-buffer scans on every
TextChanged event. This document covers viewport-aware rendering,
code exclusion caching, per-buffer debounce timers, and consolidated
autocmd handling.

---

## 1. Viewport-Aware Highlight Rendering — IMPLEMENTED

### Problem Analysis

**Files:**
- `lua/andrew/vault/highlights.lua` (line 42): `nvim_buf_get_lines(bufnr, 0, -1, false)`
- `lua/andrew/vault/wikilink_highlights.lua` (line 66): full buffer scan
- `lua/andrew/vault/tag_highlights.lua` (line 95): full buffer scan
- `lua/andrew/vault/footnotes.lua` (lines 101-140): `parse_all_footnotes()` scans entire buffer

Every highlight module fetches ALL buffer lines and processes them
top-to-bottom, creating extmarks for off-screen content with the same
priority as visible content. On a 1000-line note, this creates hundreds of
extmarks that the user cannot see.

The embed system already implements viewport-aware rendering via
`config.embed.lazy` with a margin-based approach. The highlight modules
should adopt the same pattern.

### Proposed Solution

Add a shared `visible_range(winid, margin)` utility and modify each
highlight module's update function to:

1. **On TextChanged/TextChangedI:** Render only visible + margin lines
2. **On BufEnter/BufWritePost:** Render full buffer (ensures complete state)
3. **On WinScrolled:** Render newly visible lines not yet highlighted

### Code Changes

**File: `lua/andrew/vault/highlight_utils.lua` (new shared utility)**

```lua
local M = {}

--- Get the visible line range for a window with configurable margin.
---@param winid number
---@param margin number  extra lines above/below viewport
---@return number top  1-indexed first line (clamped to 1)
---@return number bot  1-indexed last line
function M.visible_range(winid, margin)
  margin = margin or 50
  local top = vim.fn.line("w0", winid)
  local bot = vim.fn.line("w$", winid)
  return math.max(1, top - margin), bot + margin
end

--- Clear extmarks only within a line range.
---@param bufnr number
---@param ns number  namespace
---@param top number  0-indexed start line
---@param bot number  0-indexed end line (exclusive)
function M.clear_range(bufnr, ns, top, bot)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, top, bot)
end

return M
```

**Modified update pattern (example: `highlights.lua`)**

```lua
-- Before:
function M.update(bufnr)
  clear(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- ... process all lines ...
end

-- After:
function M.update(bufnr, opts)
  opts = opts or {}
  local full = opts.full or false
  local margin = config.highlight_marks.viewport_margin or 50

  if full then
    clear(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    process_lines(bufnr, lines, 0)
  else
    local winid = vim.api.nvim_get_current_win()
    local top, bot = hl_utils.visible_range(winid, margin)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    bot = math.min(bot, line_count)

    -- Clear only the visible range, then re-highlight it
    hl_utils.clear_range(bufnr, M.ns, top - 1, bot)
    local lines = vim.api.nvim_buf_get_lines(bufnr, top - 1, bot, false)
    process_lines(bufnr, lines, top - 1)  -- offset for correct extmark rows
  end
end
```

**Autocmd routing:**

```lua
-- TextChanged/TextChangedI → viewport-only update
schedule_update(bufnr, { full = false })

-- BufEnter, BufWritePost → full update
schedule_update(bufnr, { full = true })

-- WinScrolled → viewport-only update (debounced)
schedule_update(bufnr, { full = false })
```

### Config Additions

```lua
-- In config.lua, per highlight module:
M.highlight_marks.viewport_margin = 50
M.wikilink_highlights.viewport_margin = 50
M.tag_highlights.viewport_margin = 50
M.footnotes.viewport_margin = 50
```

### Expected Performance Improvement

For a 1000-line buffer where 50 lines are visible:

- **Before:** 1000 lines scanned, ~200 extmarks created (all modules combined)
- **After:** ~150 lines scanned (50 visible + 50 margin each side), ~30 extmarks
- **Reduction:** ~85% fewer lines processed on TextChanged events

### Risk Assessment

- **Incomplete highlights on scroll:** The WinScrolled handler fills in
  newly visible regions. A brief flash of unhighlighted content may be
  visible during fast scrolling, mitigated by the margin buffer.
- **Full render on BufEnter:** Ensures complete state when switching buffers.
- **Extmark persistence:** Extmarks outside the viewport from previous full
  renders remain valid. Only the viewport range is cleared and re-rendered
  on TextChanged.

---

## 2. Code Exclusion Caching — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/link_scan.lua` (lines 27-76)

`build_code_exclusion(bufnr)` performs two treesitter parses per call:

1. Lines 30-48: `vim.treesitter.get_parser(bufnr, "markdown")` + two query
   executions (fenced_code_block, indented_code_block)
2. Lines 51-64: `vim.treesitter.get_parser(bufnr, "markdown_inline")` + one
   query execution (code_span)

This function is called independently by:
- `highlights.lua:43` — `build_code_exclusion(bufnr)`
- `tag_highlights.lua:96` — `build_code_exclusion(bufnr)`
- `autolink.lua` via `link_scan.scan_buffer_names` (line 256)

On a single `TextChanged` event, if all three highlight modules are enabled,
the same treesitter parse happens **3 times** within the same event loop tick.

### Proposed Solution

Cache the code exclusion closure per `(bufnr, changedtick)`. The buffer's
`changedtick` increments on every edit, providing a natural invalidation key.

### Code Changes

**File: `lua/andrew/vault/link_scan.lua`**

```lua
local _excl_cache = {}  -- bufnr -> { tick = number, excl = function }

function M.build_code_exclusion(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = _excl_cache[bufnr]
  if cached and cached.tick == tick then
    return cached.excl
  end

  -- ... existing treesitter-based implementation (lines 28-75) ...
  local is_in_code = function(row, col) ... end

  _excl_cache[bufnr] = { tick = tick, excl = is_in_code }
  return is_in_code
end

-- Cleanup on BufDelete
function M.invalidate_cache(bufnr)
  _excl_cache[bufnr] = nil
end
```

### Expected Performance Improvement

- **Before:** 3 treesitter parses per TextChanged event (one per highlight module)
- **After:** 1 treesitter parse per TextChanged event (cached for subsequent callers)

Treesitter parsing is the most expensive operation in the highlight pipeline
(~5-20ms per parse on a 1000-line markdown file). Eliminating 2 redundant
parses saves ~10-40ms per keystroke.

Even without the coordinator, the changedtick cache prevents redundant work
when the same module re-renders without edits (e.g., WinScrolled events).

### Risk Assessment

- **Staleness:** Using `changedtick` as the cache key ensures the cache is
  automatically invalidated when the buffer content changes. No explicit
  invalidation is needed except on `BufDelete`.
- **Memory:** One closure + ranges array per buffer. Negligible.

---

## 3. Per-Buffer Debounce Timers — IMPLEMENTED

### Problem Analysis

**Files:**
- `lua/andrew/vault/highlights.lua` (line 14)
- `lua/andrew/vault/tag_highlights.lua` (line 14)
- `lua/andrew/vault/wikilink_highlights.lua` (line 15)
- `lua/andrew/vault/autolink.lua` (line 15)

Each module uses a **single global timer** for debouncing:

```lua
---@type uv.uv_timer_t|nil
local timer = nil
```

When editing two vault buffers in split windows, only one timer exists per
module. Switching between buffers causes the timer to be cancelled and
restarted, potentially dropping highlight updates for the previous buffer.

### Proposed Solution

Replace the single global timer with a per-buffer timer dictionary.

### Code Changes

**In each highlight module (e.g. highlights.lua):**

```lua
-- Before:
local timer = nil

-- After:
local timers = {}  -- bufnr -> uv_timer_t

-- In the debounce section of setup():
-- Before:
cleanup.close_timer(timer)
timer = vim.uv.new_timer()
timer:start(delay, 0, vim.schedule_wrap(function()
    apply(bufnr)
end))

-- After:
if timers[bufnr] then
    timers[bufnr]:stop()
else
    timers[bufnr] = vim.uv.new_timer()
end
timers[bufnr]:start(delay, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
        apply(bufnr)
    end
end))

-- Cleanup on BufDelete:
vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    callback = function(ev)
        if timers[ev.buf] then
            cleanup.close_timer(timers[ev.buf])
            timers[ev.buf] = nil
        end
    end,
})
```

### Expected Performance Improvement

No measurable performance improvement, but fixes a correctness issue where
multi-buffer editing could drop highlight updates.

### Risk Assessment

- **Timer leak:** BufDelete/BufWipeout cleanup prevents accumulation.
- **Memory:** One timer handle per open vault buffer. Typical usage: 2-5 buffers.

---

## 4. Consolidated Autocmd Handler / Highlight Coordinator — IMPLEMENTED

### Problem Analysis

**Files:** All 4 highlight modules + autolink + embed

Each module registers its own TextChanged/TextChangedI autocmd:
- `highlights.lua` (line 208)
- `wikilink_highlights.lua` (line 256)
- `tag_highlights.lua` (line 297)
- `autolink.lua` (line 382)

One keystroke fires TextChanged, which triggers 4+ independent debounce
timers. Each timer independently fetches buffer lines, builds code exclusion
ranges, and processes the buffer.

### Proposed Solution

Create a `highlight_coordinator.lua` module that:

1. Registers a single autocmd per event type
2. Maintains a single debounce timer per buffer
3. After debounce fires, calls all registered highlight updaters in sequence
4. Shares buffer lines and code exclusion data across all updaters

### Code Changes

**File: `lua/andrew/vault/highlight_coordinator.lua` (new module)**

```lua
local M = {}
local config = require("andrew.vault.config")
local link_scan = require("andrew.vault.link_scan")

local _updaters = {}       -- { {fn, name, priority}, ... }
local _timers = {}         -- bufnr -> uv_timer_t
local _augroup = nil

--- Register a highlight updater function.
---@param name string  module name for debugging
---@param fn function  function(bufnr, lines, code_excl, opts)
---@param priority number  execution order (lower = first)
function M.register(name, fn, priority)
  _updaters[#_updaters + 1] = { fn = fn, name = name, priority = priority or 50 }
  table.sort(_updaters, function(a, b) return a.priority < b.priority end)
end

--- Schedule a coordinated update for a buffer.
---@param bufnr number
---@param opts table  { full = bool }
function M.schedule(bufnr, opts)
  opts = opts or {}
  local debounce_ms = config.highlight_coordinator
    and config.highlight_coordinator.debounce_ms or 200

  if _timers[bufnr] then
    _timers[bufnr]:stop()
  else
    _timers[bufnr] = vim.uv.new_timer()
  end

  _timers[bufnr]:start(debounce_ms, 0, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    M.run_all(bufnr, opts)
  end))
end

--- Execute all registered updaters for a buffer.
function M.run_all(bufnr, opts)
  -- Build shared context once
  local code_excl = link_scan.build_code_exclusion(bufnr)

  for _, updater in ipairs(_updaters) do
    local ok, err = pcall(updater.fn, bufnr, code_excl, opts)
    if not ok then
      vim.schedule(function()
        vim.notify("Vault highlight error in " .. updater.name .. ": " .. err,
          vim.log.levels.WARN)
      end)
    end
  end
end

function M.setup()
  _augroup = vim.api.nvim_create_augroup("VaultHighlightCoordinator", { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = _augroup,
    pattern = "*.md",
    callback = function(ev)
      M.schedule(ev.buf, { full = false })
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = _augroup,
    pattern = "*.md",
    callback = function(ev)
      M.schedule(ev.buf, { full = true })
    end,
  })

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = _augroup,
    callback = function()
      local bufnr = vim.api.nvim_get_current_buf()
      if vim.bo[bufnr].filetype == "markdown" then
        M.schedule(bufnr, { full = false })
      end
    end,
  })
end

return M
```

### Expected Performance Improvement

- **Before:** 4 separate debounce timers, 4 separate code exclusion builds,
  4 separate buffer line fetches per TextChanged
- **After:** 1 debounce timer, 1 code exclusion build, shared across all
  updaters
- **Savings:** ~75% reduction in treesitter parsing overhead (code exclusion
  is the most expensive shared operation)

### Risk Assessment

- **Module independence:** Each highlight module can still be disabled
  independently via config. The coordinator checks enable flags before calling.
- **Error isolation:** `pcall()` wraps each updater so one failure doesn't
  block others.
- **Migration path:** Existing per-module autocmds can be removed gradually.
  During transition, both old and new handlers can coexist (with the old
  ones checking a "coordinator_active" flag to skip).

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Code Exclusion Caching (#2) | Low | Medium | Low |
| 2 | Per-Buffer Debounce Timers (#3) | Low | Correctness | Low |
| 3 | Viewport-Aware Rendering (#1) | Medium | High | Medium |
| 4 | Consolidated Autocmd Handler (#4) | High | Medium | Medium |

#2 is self-contained and benefits all modules immediately. #3 fixes a
correctness bug. #1 requires updating 4 modules but has the largest impact.
#4 is an architectural change that should follow once #1 proves the
viewport pattern works.

---

## Testing Strategy

### Viewport-Aware Rendering (#1)
1. Open a 1000-line note with highlights throughout. Verify only visible
   region is highlighted on TextChanged.
2. Scroll down. Verify newly visible highlights appear within debounce period.
3. Run `:VaultHighlightDebug` (or similar) to confirm extmark count is
   proportional to viewport, not buffer size.
4. Verify BufEnter triggers full render (all highlights present after switch).

### Code Exclusion Caching (#2)
1. Call `build_code_exclusion()` twice with no edits. Verify second call
   returns cached closure (check with identity comparison).
2. Edit buffer. Verify next call returns fresh closure.
3. Delete buffer. Verify cache entry is cleaned up.

### Per-Buffer Debounce Timers (#3)
1. Open two vault buffers in split. Edit both rapidly.
2. Verify both buffers have correct, up-to-date highlights.

### Consolidated Autocmd (#4)
1. Register all 4 highlight modules with coordinator.
2. Edit a line. Verify all 4 highlight types update with a single debounce.
3. Disable one module via config. Verify others still render.
4. Introduce an error in one module. Verify others still render.

---

## Related Documents

- Doc 63-engine-startup-performance #3 covers code exclusion algorithm optimization (different aspect — internal linear scan, vs. caching here).
