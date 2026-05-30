# Footnotes Parsing & Extmark pcall Batching

> This document is a self-contained implementation guide. Each optimization below is unique to this document.

Two targeted optimizations addressing full-buffer footnote parsing on every
render and excessive per-extmark pcall wrapping in highlight modules.

> **Modules affected:** `footnotes.lua`, `wikilink_highlights.lua`,
> `highlights.lua`, `tag_highlights.lua`

---

## 1. Cached Footnote Parsing — Status: IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/footnotes.lua` (lines 101-140, 344-431)

`render_footnotes()` calls `parse_all_footnotes(bufnr)` which:

1. Fetches ALL buffer lines: `vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)`
2. Iterates every line matching footnote patterns (REF_PAT, DEF_PAT)
3. For each definition, calls `read_definition_content()` which scans forward
   up to 50+ continuation lines

This full parse happens on:
- `BufReadPost` (auto-render, line ~351)
- Manual `:VaultFootnotes` command
- Any re-render triggered by buffer changes

The footnote map is rebuilt from scratch every time, even though footnote
positions rarely change between renders (they only move when the user edits
near a footnote definition or reference).

### Proposed Solution

Cache the parsed footnote map per buffer with `changedtick` invalidation:

```lua
-- Module level in footnotes.lua:
local _fn_cache = {}  -- bufnr -> { tick, fn_map }

local function parse_all_footnotes_cached(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = _fn_cache[bufnr]
  if cached and cached.tick == tick then
    return cached.fn_map
  end

  local fn_map = parse_all_footnotes(bufnr)
  _fn_cache[bufnr] = { tick = tick, fn_map = fn_map }
  return fn_map
end

-- Clean up on BufDelete:
vim.api.nvim_create_autocmd("BufDelete", {
  callback = function(ev) _fn_cache[ev.buf] = nil end,
})
```

Use `parse_all_footnotes_cached()` in:
- `render_footnotes()` (line ~351)
- `list()` (line ~232) — currently parses all footnotes just to show a picker

### Expected Performance Improvement

- **Before:** Full parse on every render (O(lines) + O(definitions × continuation))
- **After:** O(1) cache hit when buffer hasn't changed between renders

The footnote auto-render fires on `BufReadPost` and potentially on window
focus. Without edits, subsequent renders are free.

### Risk Assessment

- **Correctness:** `changedtick` ensures the cache is never stale relative
  to buffer content. Any edit increments the tick, forcing a reparse.
- **Memory:** One footnote map per buffer. For typical notes with <20
  footnotes, this is negligible.

---

## 2. Reduce Per-Extmark pcall Overhead — Status: IMPLEMENTED

### Problem Analysis

**Files:** `wikilink_highlights.lua` (lines 101-184),
`highlights.lua` (lines 66-88), `tag_highlights.lua` (lines 149-165)

Every individual `nvim_buf_set_extmark` call is wrapped in `pcall()`:

```lua
-- wikilink_highlights.lua:101-107 (repeated 6 times per wikilink)
local ok, err = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, bracket_open_start, {
  end_col = bracket_open_end,
  hl_group = "VaultWikiLinkBracket",
  hl_mode = "combine",
  priority = 200,
})
if not ok then log.debug("extmark failed at row %d: %s", row, err) end
```

`wikilink_highlights.lua` can set 4-6 extmarks per wikilink (opening bracket,
closing bracket, text, heading, alias, broken). For a file with 50 wikilinks,
this is 200-300 individual `pcall()` invocations. Each `pcall` creates a
protected call frame and handles exceptions.

The only error that can occur is an invalid buffer or out-of-range position.
Both are preventable: the buffer is validated at the top of `apply()`, and
positions come from `line:find()` on the actual buffer content.

### Proposed Solution

Replace per-extmark `pcall` with a single `pcall` around the entire apply
loop. If any extmark fails, log it once and continue:

```lua
-- wikilink_highlights.lua: wrap the main loop
local function apply(bufnr)
  if not M.enabled then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  -- ... validation ...

  clear(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local ok, err = pcall(function()
    for i, line in ipairs(lines) do
      -- ... all extmark logic without individual pcall wrapping ...
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, bracket_open_start, {
        end_col = bracket_open_end,
        hl_group = "VaultWikiLinkBracket",
        hl_mode = "combine",
        priority = 200,
      })
      -- ... remaining extmarks ...
    end
  end)
  if not ok then
    log.debug("highlight apply failed: %s", err)
  end
end
```

Apply the same pattern to `highlights.lua` and `tag_highlights.lua`.

### Expected Performance Improvement

- **Before:** 200-300 `pcall` invocations per wikilink highlight pass
- **After:** 1 `pcall` invocation wrapping the entire pass

The per-call overhead of `pcall` is ~0.1-0.5us in LuaJIT. For 300 calls,
that's 30-150us — modest but free to eliminate.

More importantly, this reduces code volume significantly: ~60 lines of
repetitive error handling removed from `wikilink_highlights.lua` alone.

### Risk Assessment

- **Error granularity:** With a single pcall, an error on one extmark aborts
  all remaining extmarks for that buffer. In practice, extmark errors only
  occur when the buffer becomes invalid (race condition), in which case
  aborting early is the correct behavior.
- **Debugging:** The error message from the single pcall includes the failing
  line/position. For more granularity during development, the individual
  pcall pattern can be temporarily restored.
- **Alternative:** If preserving per-extmark resilience is important, use
  `xpcall` with a lightweight error handler that doesn't format strings:
  ```lua
  local function try_extmark(bufnr, ns, row, col, opts)
    local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, opts)
    return ok  -- skip logging on failure
  end
  ```
  This eliminates the `log.debug` + string format overhead (the expensive
  part) while retaining per-extmark error tolerance.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Cached footnote parsing (#1) | Low | Medium | Low |
| 2 | Reduce pcall overhead (#2) | Low | Low | Low |

Both changes are independent and can be implemented in either order.

---

## Testing Strategy

### Cached Footnote Parsing (#1)
1. Open a file with 10 footnotes. Render footnotes. Render again without
   editing — verify cache hit (no reparse).
2. Edit a footnote definition. Re-render — verify updated content appears.
3. Delete buffer — verify cache entry is cleaned up.

### pcall Batching (#2)
1. Open a file with 50 wikilinks. Verify all highlights render correctly.
2. Simulate invalid buffer (close buffer during highlight pass) — verify
   error is caught and logged once (not 300 times).
3. Verify no highlight regressions in files with edge cases (empty links,
   self-references, broken headings).

---

## Related Documents

- Doc 56-highlight-viewport-rendering #2 covers `build_code_exclusion()` caching by changedtick in `link_scan.lua` — same caching pattern as #1 here but for a different function. Both are independent implementations.
- Doc 56-highlight-viewport-rendering #4 (coordinator) proposes sharing code exclusion data across highlight modules, which interacts with the pcall batching in #2 here (both affect the same highlight `apply()` functions).
