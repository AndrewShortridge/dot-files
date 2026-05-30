# 48 --- Persistent Highlight Cache (Changed-Line-Only Updates)

## Motivation

The three highlight modules -- `wikilink_highlights.lua`, `tag_highlights.lua`,
and `highlights.lua` (==text== marks) -- currently re-apply highlights to the
**entire buffer** on every debounced update. Their shared pattern looks like
this:

```lua
clear(bufnr)                                        -- wipe ALL extmarks
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
for i, line in ipairs(lines) do ... end             -- re-scan every line
```

For a 500-line markdown note, a single keystroke in insert mode triggers:

1. One `nvim_buf_clear_namespace` call (removes all extmarks).
2. 500 iterations of the inner scan loop.
3. Hundreds of `nvim_buf_set_extmark` calls to re-create every highlight.

The 150ms/200ms debounce reduces the frequency but does not change the
fundamental O(N) cost per update. Profiling with `:VaultPerfBench` shows that
`wikilink_highlights.apply` is the single most expensive operation during
typing in large vault files, because it also calls `resolve_link()` and
`heading_exists()` for every wikilink on every pass.

**Goal:** Track which lines actually changed, and only clear/re-apply
extmarks in those dirty regions. Full-buffer refresh remains available as a
fallback for bulk operations (paste, undo, toggle, initial load).

---

## Current State Analysis

### File: `lua/andrew/vault/wikilink_highlights.lua` (322 lines)

| Component | Lines | Description |
|-----------|-------|-------------|
| `resolve_link()` | 23-27 | Delegates to `wikilinks.resolve_link()` (cached) |
| `heading_exists()` | 30-38 | Fetches heading slug set via `linkdiag` |
| `clear(bufnr)` | 46-48 | `nvim_buf_clear_namespace(bufnr, ns, 0, -1)` -- wipes everything |
| `apply(bufnr)` | 52-184 | Full-buffer scan: `get_lines(0, -1)`, iterate all lines, pattern match `[[...]]`, resolve each link, set extmarks |
| `schedule_update(bufnr)` | 195-203 | Single shared timer, debounce 150ms, calls `apply(bufnr)` |
| Autocmds | 234-258 | `BufEnter`/`BufWritePost` (deferred apply), `TextChanged`/`TextChangedI` (debounced), `BufDelete` (clear), `User VaultCacheInvalidate` (deferred apply) |

**Key observation:** `apply()` always reads all lines and clears the entire
namespace. There is no mechanism to limit the scan to a subset of lines.

### File: `lua/andrew/vault/tag_highlights.lua` (374 lines)

Same structure as wikilink_highlights. Additional dependencies:

- `build_code_exclusion(bufnr)` -- treesitter query for code blocks/spans.
  Returns a closure over a flat list of row/col ranges. This is **buffer-global**
  and must be rebuilt (or at least range-checked) when lines shift.
- `get_frontmatter_range(bufnr)` -- scans first 200 lines for `---` delimiters.
  Cheap, but result can change if editing near the top of the file.

### File: `lua/andrew/vault/highlights.lua` (269 lines)

Simplest of the three. Matches `==[^=]+==` patterns per line. Same clear-all +
scan-all structure. Uses `build_code_exclusion` and `get_frontmatter_range`.

### Common Pattern Across All Three

```
TextChanged / TextChangedI
  -> schedule_update(bufnr)        [debounce timer]
     -> apply(bufnr)
        -> clear(bufnr)            [nvim_buf_clear_namespace 0..-1]
        -> get_lines(0, -1)        [read entire buffer]
        -> for each line: scan + set_extmark
```

### No Existing `nvim_buf_attach` Usage

Grep confirms no module in `lua/andrew/` currently uses `nvim_buf_attach`.
This improvement introduces it for the first time.

---

## Implementation

### Architecture Overview

```
nvim_buf_attach on_lines callback
  |
  v
dirty_tracker.mark_dirty(bufnr, start_row, old_end, new_end)
  |  merges into per-buffer dirty region set
  |
  v
TextChanged / TextChangedI  (existing autocmds, unchanged)
  |
  v
schedule_update(bufnr)  (existing debounce, unchanged)
  |
  v
apply(bufnr)  <-- CHANGED: checks dirty_tracker
  |
  +-- has dirty regions? --> apply_region(bufnr, region)
  |     clear extmarks in [region.start - MARGIN, region.end + MARGIN]
  |     scan only those lines
  |     set extmarks for matches found
  |     dirty_tracker.clear(bufnr)
  |
  +-- no dirty regions (full refresh request)?
  |     --> apply_full(bufnr)  (original behavior)
  |
  +-- force_full flag set? (paste, undo, toggle, initial load)
        --> apply_full(bufnr)
```

### New File: `lua/andrew/vault/dirty_tracker.lua`

A shared utility that all three highlight modules use. It tracks which line
ranges have been modified since the last highlight pass.

```lua
--- dirty_tracker.lua — Per-buffer dirty line region tracking.
---
--- Used by highlight modules to avoid full-buffer re-scans.
--- Tracks changed line ranges reported by nvim_buf_attach's on_lines callback
--- and merges overlapping/adjacent ranges.

local M = {}

--- Per-buffer state.
--- Key: bufnr, Value: { regions = {{start, end}}, generation = number, attached = bool }
---@type table<number, { regions: {[1]: number, [2]: number}[], generation: number, attached: boolean, force_full: boolean }>
local buffers = {}

--- Context margin: extra lines above/below each dirty region to re-scan.
--- Needed because multi-line constructs (code blocks, frontmatter) can affect
--- highlighting of adjacent lines.
local MARGIN = 2

--- Get or create buffer state.
---@param bufnr number
---@return table
local function get_state(bufnr)
  if not buffers[bufnr] then
    buffers[bufnr] = {
      regions = {},
      generation = 0,
      attached = false,
      force_full = false,
    }
  end
  return buffers[bufnr]
end

--- Mark a range of lines as dirty.
--- Called from the nvim_buf_attach on_lines callback.
---@param bufnr number
---@param start_row number 0-indexed first changed line
---@param old_end_row number 0-indexed old end (exclusive) -- the range that was removed
---@param new_end_row number 0-indexed new end (exclusive) -- the range that replaced it
function M.mark_dirty(bufnr, start_row, old_end_row, new_end_row)
  local state = get_state(bufnr)

  -- If the edit changed the number of lines, downstream extmarks may have
  -- shifted. For multi-line insertions/deletions we force a full refresh
  -- because extmark positions in regions below the edit are now stale.
  local lines_added = new_end_row - old_end_row
  if math.abs(lines_added) > 5 then
    state.force_full = true
    return
  end

  -- For smaller edits, record the dirty region as the union of old and new.
  local region_end = math.max(old_end_row, new_end_row)
  local new_region = { start_row, region_end }

  -- Merge with existing regions that overlap or are adjacent (within MARGIN).
  local merged = {}
  local did_merge = false
  for _, r in ipairs(state.regions) do
    if new_region[1] <= r[2] + MARGIN and new_region[2] >= r[1] - MARGIN then
      -- Overlapping or adjacent: expand new_region to cover both
      new_region[1] = math.min(new_region[1], r[1])
      new_region[2] = math.max(new_region[2], r[2])
      did_merge = true
    else
      merged[#merged + 1] = r
    end
  end
  merged[#merged + 1] = new_region
  state.regions = merged
  state.generation = state.generation + 1

  -- Safety: if too many disjoint regions accumulate, force full refresh
  if #state.regions > 10 then
    state.force_full = true
  end
end

--- Check whether a full refresh is needed (or if incremental is possible).
---@param bufnr number
---@return boolean force_full
---@return {[1]: number, [2]: number}[] regions  dirty regions (empty if force_full)
function M.get_dirty(bufnr)
  local state = get_state(bufnr)
  if state.force_full then
    return true, {}
  end
  return false, state.regions
end

--- Check if there are any pending dirty regions.
---@param bufnr number
---@return boolean
function M.has_dirty(bufnr)
  local state = buffers[bufnr]
  if not state then return false end
  return state.force_full or #state.regions > 0
end

--- Clear dirty state after a highlight pass completes.
---@param bufnr number
function M.clear(bufnr)
  local state = buffers[bufnr]
  if not state then return end
  state.regions = {}
  state.force_full = false
end

--- Force the next update to do a full refresh.
--- Called by toggle, VaultCacheInvalidate, and manual refresh commands.
---@param bufnr number
function M.force_full(bufnr)
  local state = get_state(bufnr)
  state.force_full = true
end

--- Attach the on_lines callback to a buffer (idempotent).
--- Returns true if already attached or newly attached.
---@param bufnr number
---@return boolean
function M.attach(bufnr)
  local state = get_state(bufnr)
  if state.attached then return true end

  local ok = vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buf, _, start_row, old_end_row, new_end_row)
      M.mark_dirty(buf, start_row, old_end_row, new_end_row)
    end,
    on_detach = function(_, buf)
      buffers[buf] = nil
    end,
  })

  if ok then
    state.attached = true
  end
  return ok
end

--- Detach tracking for a buffer (cleanup).
---@param bufnr number
function M.detach(bufnr)
  buffers[bufnr] = nil
  -- Note: nvim_buf_attach does not have a detach API; the callback returns
  -- true from on_lines to detach. Since we only nil out the state here,
  -- the on_lines callback will simply call mark_dirty on a fresh state
  -- (which is harmless) or the on_detach callback will clean up.
end

--- Get the context margin value.
---@return number
function M.margin()
  return MARGIN
end

return M
```

### Target File Changes

All changes are in three existing files. No new plugin dependencies.

---

### Changes to `lua/andrew/vault/wikilink_highlights.lua`

This is the primary module. The other two follow the same pattern.

#### Change 1: Add dirty_tracker require

**Before** (lines 1-3):

```lua
local engine = require("andrew.vault.engine")
local link_utils = require("andrew.vault.link_utils")
local cleanup = require("andrew.vault.resource_cleanup")
```

**After:**

```lua
local engine = require("andrew.vault.engine")
local link_utils = require("andrew.vault.link_utils")
local cleanup = require("andrew.vault.resource_cleanup")
local dirty_tracker = require("andrew.vault.dirty_tracker")
```

#### Change 2: Add region-aware clear function

**Before** (lines 44-48):

```lua
--- Clear all wikilink highlights from a buffer.
---@param bufnr number
local function clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
end
```

**After:**

```lua
--- Clear all wikilink highlights from a buffer.
---@param bufnr number
local function clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
end

--- Clear wikilink highlights in a specific line range.
---@param bufnr number
---@param start_row number 0-indexed inclusive
---@param end_row number 0-indexed exclusive
local function clear_region(bufnr, start_row, end_row)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, start_row, end_row)
end
```

#### Change 3: Extract line-scanning logic into a helper

The inner loop body of `apply()` (lines 66-183) is extracted into a new
function that can operate on an arbitrary line range. This is the key
refactor that enables both full and partial updates.

**Before** (lines 50-184, the full `apply` function):

```lua
--- Scan buffer and apply resolution-aware highlights to all wikilinks.
---@param bufnr number
local function apply(bufnr)
  if not M.enabled then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local fname = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_path(fname) then
    clear(bufnr)
    return
  end

  clear(bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for i, line in ipairs(lines) do
    -- ... (120 lines of wikilink scanning and extmark setting)
  end
end
```

**After:**

```lua
--- Scan a range of buffer lines and apply wikilink highlights.
--- Does NOT clear extmarks -- caller is responsible for clearing the range first.
---@param bufnr number
---@param start_row number 0-indexed inclusive
---@param end_row number 0-indexed exclusive (-1 for end of buffer)
local function apply_lines(bufnr, start_row, end_row)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if end_row == -1 then end_row = line_count end
  start_row = math.max(0, start_row)
  end_row = math.min(end_row, line_count)

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)

  for i, line in ipairs(lines) do
    local row = start_row + i - 1  -- 0-indexed absolute row

    -- (The entire inner loop body from the original apply(), unchanged,
    --  but using `row` instead of `i - 1` for the extmark row parameter.)

    local pos = 1
    while true do
      local open = line:find("%[%[", pos, false)
      if not open then break end

      local is_embed = open > 1 and line:sub(open - 1, open - 1) == "!"
      local close = line:find("]]", open + 2, true)
      if not close then break end
      pos = close + 2
      if is_embed then goto continue end

      local inner = line:sub(open + 2, close - 1)
      local parsed = link_utils.parse_target(inner)
      local target = parsed.name
      local heading = parsed.heading
      local alias = parsed.alias

      if target:match("^https?://") then goto continue end

      local bracket_open_start = open - 1
      local bracket_open_end = open + 1
      local text_start = open + 1
      local text_end = close - 1
      local bracket_close_start = close - 1
      local bracket_close_end = close + 1

      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, bracket_open_start, {
        end_col = bracket_open_end,
        hl_group = "VaultWikiLinkBracket",
        hl_mode = "combine",
        priority = 200,
      })
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, bracket_close_start, {
        end_col = bracket_close_end,
        hl_group = "VaultWikiLinkBracket",
        hl_mode = "combine",
        priority = 200,
      })

      if target == "" then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, text_start, {
          end_col = text_end,
          hl_group = "VaultWikiLinkSelf",
          hl_mode = "combine",
          priority = 200,
        })
      else
        local resolved_path = resolve_link(target)

        if not resolved_path then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, text_start, {
            end_col = text_end,
            hl_group = "VaultWikiLinkBroken",
            hl_mode = "combine",
            priority = 200,
          })
        else
          local name_byte_end = text_start + #target

          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, text_start, {
            end_col = math.min(name_byte_end, text_end),
            hl_group = "VaultWikiLinkValid",
            hl_mode = "combine",
            priority = 200,
          })

          if heading then
            local hash_pos = line:find("#", open + 2 + #target, true)
            if hash_pos then
              local heading_start = hash_pos - 1
              local heading_end_pos = heading_start + 1 + #heading
              local h_exists = heading_exists(resolved_path, heading)
              local heading_hl = h_exists
                and "VaultWikiLinkHeading"
                or "VaultWikiLinkHeadingBroken"
              pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, heading_start, {
                end_col = math.min(heading_end_pos, text_end),
                hl_group = heading_hl,
                hl_mode = "combine",
                priority = 200,
              })
            end
          end

          if alias then
            local pipe_pos = line:find("|", open + 2, true)
            if pipe_pos and pipe_pos < close then
              pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, pipe_pos, {
                end_col = text_end,
                hl_group = "VaultWikiLinkAlias",
                hl_mode = "combine",
                priority = 200,
              })
            end
          end
        end
      end

      ::continue::
    end
  end
end

--- Full-buffer highlight application (used for initial load, toggle, cache invalidation).
---@param bufnr number
local function apply_full(bufnr)
  if not M.enabled then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local fname = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_path(fname) then
    clear(bufnr)
    return
  end

  clear(bufnr)
  apply_lines(bufnr, 0, -1)
end

--- Smart apply: uses dirty regions when available, falls back to full refresh.
---@param bufnr number
local function apply(bufnr)
  if not M.enabled then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local fname = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_path(fname) then
    clear(bufnr)
    return
  end

  local force_full, regions = dirty_tracker.get_dirty(bufnr)

  if force_full or #regions == 0 then
    -- No dirty tracking data (first run) or forced full: scan everything
    clear(bufnr)
    apply_lines(bufnr, 0, -1)
  else
    -- Incremental: only re-scan dirty regions with margin
    local margin = dirty_tracker.margin()
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    for _, region in ipairs(regions) do
      local r_start = math.max(0, region[1] - margin)
      local r_end = math.min(line_count, region[2] + margin)
      clear_region(bufnr, r_start, r_end)
      apply_lines(bufnr, r_start, r_end)
    end
  end

  dirty_tracker.clear(bufnr)
end
```

#### Change 4: Attach dirty tracker in setup and force full on cache invalidation

**Before** (lines 234-246, BufEnter autocmd):

```lua
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if M.enabled and engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
        -- Defer slightly to let linkdiag and wikilinks caches settle
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            apply(ev.buf)
          end
        end, 50)
      end
    end,
  })
```

**After:**

```lua
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if M.enabled and engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
        -- Attach dirty tracker (idempotent)
        dirty_tracker.attach(ev.buf)
        -- Force full refresh on BufEnter (initial load) and BufWritePost
        dirty_tracker.force_full(ev.buf)
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            apply(ev.buf)
          end
        end, 50)
      end
    end,
  })
```

**Before** (lines 270-286, VaultCacheInvalidate autocmd):

```lua
  vim.api.nvim_create_autocmd("User", {
    pattern = "VaultCacheInvalidate",
    callback = function()
      if not M.enabled then return end
      local bufnr = vim.api.nvim_get_current_buf()
      if vim.api.nvim_buf_is_valid(bufnr) then
        local bufname = vim.api.nvim_buf_get_name(bufnr)
        if bufname:match("%.md$") and engine.is_vault_path(bufname) then
          vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
              apply(bufnr)
            end
          end, 100)
        end
      end
    end,
  })
```

**After:**

```lua
  vim.api.nvim_create_autocmd("User", {
    pattern = "VaultCacheInvalidate",
    callback = function()
      if not M.enabled then return end
      local bufnr = vim.api.nvim_get_current_buf()
      if vim.api.nvim_buf_is_valid(bufnr) then
        local bufname = vim.api.nvim_buf_get_name(bufnr)
        if bufname:match("%.md$") and engine.is_vault_path(bufname) then
          -- Cache invalidation means link resolution results may have changed;
          -- force full refresh so all links are re-resolved.
          dirty_tracker.force_full(bufnr)
          vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
              apply(bufnr)
            end
          end, 100)
        end
      end
    end,
  })
```

#### Change 5: Force full on manual refresh and toggle

**Before** (lines 293-295):

```lua
  vim.api.nvim_create_user_command("VaultWikilinkHLRefresh", function()
    apply(vim.api.nvim_get_current_buf())
  end, { desc = "Refresh wikilink highlights in current buffer" })
```

**After:**

```lua
  vim.api.nvim_create_user_command("VaultWikilinkHLRefresh", function()
    local bufnr = vim.api.nvim_get_current_buf()
    dirty_tracker.force_full(bufnr)
    apply(bufnr)
  end, { desc = "Refresh wikilink highlights in current buffer" })
```

**Before** (toggle function, lines 209-223):

```lua
function M.toggle()
  M.enabled = not M.enabled
  if M.enabled then
    local bufnr = vim.api.nvim_get_current_buf()
    apply(bufnr)
  else
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      clear(buf)
    end
  end
  vim.notify(
    "Vault: wikilink highlights " .. (M.enabled and "ON" or "OFF"),
    vim.log.levels.INFO
  )
end
```

**After:**

```lua
function M.toggle()
  M.enabled = not M.enabled
  if M.enabled then
    local bufnr = vim.api.nvim_get_current_buf()
    dirty_tracker.force_full(bufnr)
    apply(bufnr)
  else
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      clear(buf)
    end
  end
  vim.notify(
    "Vault: wikilink highlights " .. (M.enabled and "ON" or "OFF"),
    vim.log.levels.INFO
  )
end
```

#### Change 6: Clean up dirty tracker on BufDelete

**Before** (lines 261-267):

```lua
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      clear(ev.buf)
    end,
  })
```

**After:**

```lua
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      clear(ev.buf)
      dirty_tracker.detach(ev.buf)
    end,
  })
```

---

### Pattern for `tag_highlights.lua`

The changes follow an identical structure. The key differences:

1. **Add `dirty_tracker` require** at the top (same as wikilink_highlights).

2. **Add `clear_region()`** alongside the existing `clear()`.

3. **Extract `apply_lines(bufnr, start_row, end_row)`** from the current
   `apply()`. The tag scanning loop body is moved into this function. The
   `build_code_exclusion()` and `get_frontmatter_range()` calls remain
   **inside `apply_lines()`** because:

   - `build_code_exclusion()` returns a closure over the full buffer's
     treesitter tree. It must be called once per apply pass (it is not
     expensive -- typically <1ms). The closure itself correctly handles
     arbitrary (row, col) queries, so it works fine for partial scans.
   - `get_frontmatter_range()` is called once per apply pass. The result
     is valid for the whole buffer.

   These two calls are not line-range-dependent; they operate on the full
   buffer tree. The overhead of calling them on a partial update is
   negligible compared to the savings from scanning fewer lines.

4. **Same `apply()` smart dispatch** as wikilink_highlights: check
   `dirty_tracker.get_dirty()`, iterate regions with margin, or fall back to
   full.

5. **Same autocmd changes**: attach tracker on `BufEnter`, force full on
   `BufWritePost`/toggle/refresh, detach on `BufDelete`.

### Pattern for `highlights.lua`

Identical pattern. The `==[^=]+==` scanning is the simplest of the three and
benefits the least (since highlight marks are less common than wikilinks or
tags), but applying the same pattern keeps all three modules consistent and
avoids a different code path that could diverge over time.

---

### Edge Cases

#### Undo/Redo

Neovim's undo fires `on_lines` with the affected range. A single `u` keystroke
that reverts a one-line edit will report a single-line dirty region -- the
incremental path handles this correctly. A `u` that reverts a multi-line paste
will report a large range; if `math.abs(lines_added) > 5`, dirty_tracker
forces a full refresh, which is the correct behavior for bulk undo.

#### Paste Operations

Pasting 20 lines triggers `on_lines` with `new_end_row - old_end_row = 20`.
The `> 5` threshold in `mark_dirty()` will set `force_full = true`, falling
back to the original full-buffer scan. This is intentional: pasting is a
one-time operation, not a per-keystroke cost.

#### Vault Index Generation Changes

When `VaultCacheInvalidate` fires, link resolution results may have changed
for any wikilink in the buffer (a renamed note could flip valid/broken status).
The autocmd handler calls `dirty_tracker.force_full(bufnr)` to ensure all
links are re-resolved. This is correct: index rebuilds are infrequent and
their effect is global.

#### Code Block Context for Tags

The `build_code_exclusion()` closure checks whether a (row, col) position is
inside a code block anywhere in the buffer. Since the closure is built from
the full treesitter parse, it remains correct even when only a subset of lines
is being scanned. If the user edits inside a code fence, the dirty region
includes those lines, treesitter re-parses, and `build_code_exclusion()` is
called fresh at the start of `apply_lines()`.

#### Frontmatter Edits

If a line within the frontmatter range is edited, the dirty region will cover
those lines. `get_frontmatter_range()` is called per pass and returns the
current boundaries. Lines inside frontmatter are skipped by the tag/highlight
scanners. If the edit changes the frontmatter boundaries themselves (e.g.,
deleting the closing `---`), the margin-expanded dirty region will likely
cover the affected area. Worst case, the next `BufWritePost` forces a full
refresh.

---

## Expected Performance

### Baseline (Current)

For a 500-line markdown file with 40 wikilinks, 15 tags, and 5 highlight
marks:

| Operation | Cost per debounced update |
|-----------|-------------------------|
| `nvim_buf_clear_namespace` | 1 call (all extmarks) |
| `nvim_buf_get_lines` | 500 lines read |
| Wikilink pattern matching | 500 iterations |
| `resolve_link()` calls | 40 (one per wikilink) |
| `nvim_buf_set_extmark` | ~80 calls (brackets + text per link) |
| Total extmark churn | ~80 destroyed + ~80 created |

### After Change (Incremental, Single-Line Edit)

For the same file, editing one line that contains 1 wikilink:

| Operation | Cost per debounced update |
|-----------|-------------------------|
| `nvim_buf_clear_namespace` | 1 call (5-line region: changed line +/- 2 margin) |
| `nvim_buf_get_lines` | 5 lines read |
| Wikilink pattern matching | 5 iterations |
| `resolve_link()` calls | ~1-2 (only links in the 5-line window) |
| `nvim_buf_set_extmark` | ~2-4 calls |
| Total extmark churn | ~2-4 destroyed + ~2-4 created |

**Expected speedup: ~100x fewer lines scanned, ~20x fewer extmark operations
per keystroke.** The `resolve_link()` savings are the most significant because
each call involves a hash lookup against the vault index cache.

### Overhead of Dirty Tracking

- `on_lines` callback: runs synchronously in Neovim's event loop. The
  callback body is ~20 lines of arithmetic and table manipulation -- sub-
  microsecond.
- Per-buffer state table: negligible memory (a handful of {start, end} pairs
  that are cleared after each apply pass).
- `nvim_buf_attach`: one-time cost per buffer, automatically cleaned up on
  buffer delete.

---

## Testing Instructions

### 1. Verify Dirty Tracker Module Loads

1. Open Neovim and source the vault.
2. Run `:lua print(vim.inspect(require("andrew.vault.dirty_tracker")))` --
   should print a table with `mark_dirty`, `get_dirty`, `clear`, `attach`,
   `detach`, `force_full`, `has_dirty`, `margin` functions.

### 2. Incremental Wikilink Highlights

1. Open a large vault markdown file (300+ lines) with several wikilinks.
2. Verify all wikilinks are highlighted on initial load (full refresh path).
3. Position cursor on a line containing a wikilink. Type `ciw` and replace
   the link text. After the debounce (150ms), the highlight on that line
   should update. Highlights on all other lines should remain unchanged.
4. Position cursor on a line with NO wikilinks. Add a new wikilink by typing
   `[[SomeNote]]`. After debounce, the new link should be highlighted. Other
   lines should be unaffected.
5. Verify broken link highlighting: type `[[NonExistentNote12345]]`. After
   debounce, it should show the broken link highlight.

### 3. Incremental Tag Highlights

1. Open a vault markdown file with inline tags (e.g., `#project/active`).
2. Verify all tags are highlighted on initial load.
3. Add a new tag on an empty line: type `#status/blocked`. After debounce
   (200ms), the new tag should be highlighted with the correct category
   color. Existing tags should remain highlighted.
4. Delete a tag from a line. After debounce, the highlight should be removed
   from that line only.

### 4. Incremental Highlight Marks

1. Open a vault file with `==highlighted text==` marks.
2. Verify they render on load.
3. Add `==new highlight==` on a blank line. After debounce, it should render.
4. Remove the `==` delimiters from an existing highlight. After debounce,
   the highlight should disappear from that line.

### 5. Full Refresh Fallback

1. Open a large vault file.
2. Paste a large block of text (10+ lines) with `p` or `P`. After debounce,
   all highlights in the buffer should be correct (full refresh path due to
   large insertion).
3. Undo the paste with `u`. Highlights should be correct after debounce.
4. Run `:VaultWikilinkHLRefresh` -- should force a full refresh (verify via
   `:lua print(require("andrew.vault.dirty_tracker").has_dirty(0))` being
   false after the refresh completes).

### 6. Toggle and Cache Invalidation

1. Run `:VaultWikilinkHLToggle` to turn highlights off. All wikilink
   highlights should disappear.
2. Run `:VaultWikilinkHLToggle` again. All highlights should reappear (full
   refresh).
3. Rename a note in the vault (e.g., via `:VaultRename`). After the
   `VaultCacheInvalidate` event, wikilinks to that note should update their
   valid/broken status across the entire buffer (full refresh).

### 7. Verify No Stale Extmarks

1. Open a vault file. Note the highlights.
2. Make 20 single-line edits in different parts of the file, waiting for
   debounce between each.
3. Run `:VaultWikilinkHLRefresh` (force full). The result should be
   identical to the incrementally-updated state -- no missing or extra
   highlights.

This is the definitive correctness test: the incremental result must always
match what a full refresh would produce.

---

## Summary of Changes

| File | Lines Added | Lines Modified | Description |
|------|-------------|----------------|-------------|
| `lua/andrew/vault/dirty_tracker.lua` | ~130 | -- | New shared module: per-buffer dirty line tracking via `nvim_buf_attach` |
| `lua/andrew/vault/wikilink_highlights.lua` | ~40 | ~30 | Add `apply_lines()`, smart `apply()` dispatch, attach/force_full/detach in autocmds |
| `lua/andrew/vault/tag_highlights.lua` | ~35 | ~25 | Same pattern as wikilink_highlights |
| `lua/andrew/vault/highlights.lua` | ~30 | ~20 | Same pattern as wikilink_highlights |

No changes to `config.lua` (debounce values remain unchanged). No new plugin
dependencies. The `dirty_tracker.lua` module has zero requires (pure Lua +
`vim.api`), matching the zero-dependency pattern of `vault_index.lua`.
