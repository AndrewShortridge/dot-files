# 35. Invalidation Region Tracking

## Problem

The vault rendering system has evolved significantly from naive full-buffer
re-rendering. The current architecture already includes:

- **`line_tracker.lua`**: Uses `nvim_buf_attach` with `on_bytes` to track dirty
  lines per buffer (marks individual rows or sets a `full` flag when line count
  changes)
- **`transform_pipeline.lua`**: A 4-layer pipeline (change tracking → line
  parse → semantic resolution → render diff) that replaces per-module scanning
- **`pipeline_consumers.lua`**: Wikilink, tag, highlight, and inline field
  rendering via pipeline consumer registration, not direct buffer iteration
- **`highlight_coordinator.lua`**: Centralized debounced dispatch (200ms for
  TextChanged, 30ms for full) with viewport-aware rendering and frame caching
- **`event_dispatch.lua`**: Unified autocmd routing — TextChanged/TextChangedI/
  InsertLeave flow through a single autocmd that dispatches to
  highlight_coordinator, embed, and task_hierarchy
- **`embed.lua`**: Descriptor-based rendering with frame cache, request
  coalescer, and viewport/lazy mode (`config.embed.lazy`)

However, there are still gaps in the invalidation model. Consider a 1000-line
vault note with 20 embedded transclusions. When the user edits line 50:

1. **`embed.lua`**: Still calls `vim.api.nvim_buf_clear_namespace(bufnr,
   state.ns, 0, -1)` (line 473) before every render — clearing ALL embed
   extmarks buffer-wide, even though only the edited region changed. The
   descriptor builder (`build_descriptors`) scans all buffer lines (line 486:
   `nvim_buf_get_lines(bufnr, 0, -1, false)`). Frame cache mitigates rebuild
   cost but not the scan/clear cost.

2. **`task_hierarchy.lua`**: `render_completion_vtext()` (lines 106-161)
   calls `vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)` (line 111)
   on every render, then iterates all root tasks to recompute completion
   stats and recreate extmarks. It now includes frame cache integration
   (lines 134, 141-150, 160) but still has no spatial restriction — the
   full namespace clear remains. Has its own per-buffer debounce timer
   (`_schedule_render` at lines 169-176) with generation-cached tree
   building inline (lines 123-132).

3. **`line_tracker.lua`**: Tracks dirty rows via `on_bytes` (lines 19-41)
   but sets `state.full = true` (line 29) whenever line count changes
   (`old_end_row ~= new_end_row`). This means most real edits (Enter key,
   deleting lines, pasting) fall back to full-buffer behavior. The
   `consume()` function (lines 48-62) returns `nil` when `full = true`,
   signaling callers to do full reparse — the dirty-row granularity is lost.

4. **Pipeline consumers** (wikilinks, tags, highlights, inline fields): Already
   benefit from the transform pipeline's change tracking, but the pipeline's
   Layer 0 (`line_tracker.consume()`) inherits the `full = true` fallback.

5. **Coordinated updaters** (footnotes, autolink): Called via
   highlight_coordinator with `opts.full` flag. `footnotes.lua` has viewport
   optimization (lines 357-369) with explicit range handling for prefetch
   zones, and changedtick-cached footnote map via `hl_coord.cached_value()`
   (line 162). Its `coordinated_update()` (lines 507-518) supports
   `start_line`/`end_line` for prefetch zones. `autolink.lua` has
   `visible_only` mode (lines 78-86) but its `clear()` function (lines
   49-57) calls `nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)` — removing
   all extmarks before re-applying.

The missing piece is **spatial invalidation** — knowing exactly which line
ranges changed and restricting both extmark clearing and re-scanning to those
ranges only. The existing `line_tracker` has the right idea but its `full`
fallback undermines it for the most common edit patterns (any edit that changes
line count).

## Inspiration

### Zed's InvalidationStack

Zed's `crates/editor/src/editor.rs` (line 1517) implements
`InvalidationStack<T>`, a stack of regions identified by `Anchor`-based ranges.
The `InvalidationRegion` trait (line 442) defines `fn ranges(&self) ->
&[Range<Anchor>]`. The `invalidate()` method (lines 23102-23126) checks whether
all current selections remain inside the topmost region's ranges — if any
selection has moved outside, the region is popped and the associated cached
state (e.g., snippet tabstops) is discarded.

```rust
// editor.rs:1517
struct InvalidationStack<T>(Vec<T>);

// editor.rs:442
trait InvalidationRegion {
    fn ranges(&self) -> &[Range<Anchor>];
}

// editor.rs:23101-23126
impl<T: InvalidationRegion> InvalidationStack<T> {
    fn invalidate<S>(&mut self, selections: &[Selection<S>], buffer: &MultiBufferSnapshot)
    where
        S: Clone + ToOffset,
    {
        while let Some(region) = self.last() {
            let all_selections_inside_invalidation_ranges =
                if selections.len() == region.ranges().len() {
                    selections
                        .iter()
                        .zip(region.ranges().iter().map(|r| r.to_offset(buffer)))
                        .all(|(selection, invalidation_range)| {
                            let head = selection.head().to_offset(buffer);
                            invalidation_range.start <= head && invalidation_range.end >= head
                        })
                } else {
                    false
                };

            if all_selections_inside_invalidation_ranges {
                break;
            } else {
                self.pop();
            }
        }
    }
}

// Supporting impls: Default (line 23129), Deref (line 23135),
// DerefMut (line 23143), InvalidationRegion for SnippetState (line 23149)
```

Used for `snippet_stack` (line 1019) and pattern reused by
`AutocloseRegion` (lines 1496-1500) and `InlineCompletionState`
(lines 632-637, with `invalidation_range: Range<Anchor>`).

The key insight: **Anchor-based ranges persist across buffer edits** — Neovim's
extmark system provides a similar capability, but the vault modules don't
leverage it for validity tracking.

### Zed's Display Layer Edit Propagation

Zed's `display_map.rs` (lines 167-194) demonstrates a pipeline where edits
cascade through 6 transformation layers (actual cascade at lines 170-177),
each consuming edit ranges from the previous layer and emitting translated
ranges for the next:

```
Buffer edits (byte offsets)          -- line 169: consumed from subscription
  → InlayMap.sync()  → Vec<InlayEdit>    -- line 170
  → FoldMap.read()   → Vec<FoldEdit>     -- line 171
  → TabMap.sync()    → Vec<TabEdit>      -- line 173
  → WrapMap.sync()   → Patch<u32>        -- line 176
  → BlockMap.read()  → final display     -- line 177
```

Each layer uses SumTree cursors with `cursor.slice()` and `cursor.suffix()` to
preserve unchanged regions — only the transforms that intersect the edit range
are rebuilt. Adjacent edits are coalesced via `consolidate_inlay_edits()`
(fold_map.rs lines 945-979) and `consolidate_fold_edits()` (fold_map.rs lines
981-1013) to reduce downstream work. Both consolidation functions live in
`fold_map.rs`, not split across files.

The `push_isomorphic()` pattern merges adjacent unchanged transforms to prevent
tree fragmentation — analogous to region coalescing in our design. It appears in
all four map layers: inlay_map.rs (line 1155), fold_map.rs (line 896),
block_map.rs (line 1051), and wrap_map.rs (line 883).

The key architectural pattern: **edits are translated through coordinate spaces
rather than triggering full recomputation**. Each layer only processes the
intersection of its transforms with the edit range.

### Relevance to Our Architecture

Our vault rendering system already has a layered pipeline
(`transform_pipeline.lua` Layers 0-3), but it lacks the edit-range propagation
that Zed demonstrates. Currently, Layer 0 consumes dirty lines from
`line_tracker` but discards spatial information when `full = true`. A
`RegionTracker` would provide the missing spatial dimension — telling each
layer and consumer exactly which line ranges need work.

## Design

### Core Data Structure

A `RegionTracker` maintains an ordered list of valid regions for a single
buffer. Each region represents a contiguous line range where cached rendering
data is known to be correct.

```
ValidRegion = {
  start_line: number,  -- 0-indexed, inclusive
  end_line: number,    -- 0-indexed, exclusive
  version: number,     -- changedtick when this region was validated
}
```

Regions are stored in a sorted array (by `start_line`), non-overlapping and
non-adjacent (adjacent regions are coalesced). The invariant is:

```
for i = 2, #regions do
  assert(regions[i].start_line > regions[i-1].end_line)
end
```

### Relationship to line_tracker.lua

`line_tracker.lua` already uses `nvim_buf_attach` with `on_bytes` (lines 19-41)
to track per-buffer dirty state. It maintains (line 10 type annotation, line 17
initialization):

```lua
_buffers[bufnr] = { tick = 0, dirty = {}, full = true }
```

Where `dirty` is a set of 0-indexed row numbers and `full` is a boolean that
triggers full-buffer reparse. The `full` flag is set at line 29 when
`old_end_row ~= new_end_row` (line count changed). The `consume()` function
(lines 48-62) returns `nil` when `full = true` and a sorted array of dirty
line numbers otherwise, then resets `full = false` (line 53).

The `RegionTracker` is **complementary**, not a replacement:

| Concern | line_tracker | RegionTracker |
|---------|-------------|---------------|
| Granularity | Per-row dirty set | Contiguous valid ranges |
| Fallback | `full = true` (loses all spatial info) | Removes overlapping regions (preserves rest) |
| Callback | `on_bytes` (byte-level) | `on_lines` (line-level) |
| Consumers | transform_pipeline Layer 0 | All renderers (embed, task_hierarchy, coordinated updaters) |
| Persistence | Consumed once per pipeline run | Persistent until edit invalidates |

The `RegionTracker` uses `on_lines` instead of `on_bytes` because its consumers
operate on line ranges (extmark clearing, `nvim_buf_get_lines`), and `on_lines`
provides exactly the `(first_line, last_line, new_last_line)` triple needed for
region arithmetic. Both callbacks can coexist on the same buffer — Neovim
supports multiple `nvim_buf_attach` subscriptions.

### Edit Processing

When `nvim_buf_attach`'s `on_lines` callback fires, it provides:
- `first_line`: first changed line (0-indexed)
- `last_line`: last line before the change (0-indexed, exclusive)
- `new_last_line`: last line after the change (0-indexed, exclusive)

The region tracker processes this as:

1. **Remove** any region that overlaps `[first_line, last_line)`
2. **Shift** all regions after `last_line` by `delta = new_last_line - last_line`
3. The gap `[first_line, new_last_line)` is now an invalid range

This preserves the validity of all regions that do not intersect the edit,
while correctly handling insertions (positive delta) and deletions (negative
delta). Unlike `line_tracker`'s `full = true` fallback, line-count changes
are handled gracefully via the delta shift.

### Renderer Integration

Each renderer checks the region tracker before processing a line or line range:

- If the range is fully valid, skip it
- If the range is partially valid, process only the invalid sub-ranges
- After processing, mark the newly rendered range as valid

This transforms full-buffer re-renders into incremental updates that touch
only the edited region plus a small margin.

## Target Modules

### embed.lua (highest remaining impact)

Embeds are the most expensive decoration: each `![[...]]` transclusion
involves path resolution, file reading, content extraction, and multi-line
virtual text creation.

**Current behavior** (embed.lua `render_embeds()` starts at line 437):
- `nvim_buf_clear_namespace(bufnr, state.ns, 0, -1)` (line 473) — clears ALL extmarks
- `embed_images.clear_image_placements(bufnr)` (line 474) — clears ALL image placements
- Inside coalescer callback: `nvim_buf_get_lines(bufnr, 0, -1, false)` (line 486) — reads ALL lines
- `build_descriptors(lines, bufnr)` (function at line 163) — pattern-matches ALL lines
  using pipeline token iteration with `lnum = line_nr + 1` (0→1 indexed conversion)
- Descriptor pool (`_desc_pool` at line 145) manages allocation/release
- Descriptor cache at `state._embed_descriptors[bufnr]` with generation tracking (line 495)
- Then either lazy/viewport render or full synchronous render

**With region tracking**: `build_descriptors` receives only invalid-range lines.
Extmarks outside the invalid range are preserved. Frame cache continues to
accelerate re-rendering within the invalid range. The viewport/lazy mode
(`config.embed.lazy`) further restricts to visible lines within invalid ranges.

**Integration point**: Before `build_descriptors()`, query
`tracker:get_invalid_ranges()`. Clear extmarks only in those ranges via
`nvim_buf_get_extmarks` + `nvim_buf_del_extmark` (range-scoped). After
rendering, `tracker:mark_valid()` for each processed range.

### task_hierarchy.lua (second highest impact)

**Current behavior** (task_hierarchy.lua lines 106-161):
- `render_completion_vtext()` calls
  `nvim_buf_clear_namespace(bufnr, ns, 0, -1)` (line 111) on every render
  (namespace created at line 15)
- Generation-cached tree building inline (lines 123-132) using
  `filter_utils.is_cache_gen_valid()` with `_vtext_cache[bufnr]`
- Frame cache integration (lines 134, 141-150) for label/highlight caching
- Iterates all root tasks via vault index, computes completion stats, creates
  extmarks for each; `fc:finish_frame()` at line 160
- Has its own per-buffer debounce timer via `_schedule_render` (lines 169-176)
  using `cleanup.debounce()` with `config.hierarchy.debounce_ms = 500`
- TextChanged autocmd removed — now dispatched via event_dispatch.lua (line 543)

**With region tracking**: Only clear and recreate extmarks for tasks whose line
falls within an invalid range. Task completion stats depend on child tasks, so
the invalid range must be expanded to include the nearest ancestor root task
(tasks at indent level 0). This is a bounded expansion — root tasks are
typically sparse.

**Integration point**: In `render_completion_vtext()`, replace full namespace
clear with range-scoped clear. Filter `roots` to only those intersecting
invalid ranges (expanded to root-task boundaries).

### Coordinated updaters via highlight_coordinator

The highlight coordinator (`highlight_coordinator.lua`) already passes
`opts.full` to updaters and supports viewport-restricted rendering. Key
functions: `run_all()` (lines 258-290), `schedule()` (lines 244-252, with
200ms/30ms debounce), BufDelete cleanup (lines 441-447), VaultCacheInvalidate
handler (lines 416-438). Updaters registered via `M.register()` (lines
229-239) with priority-sorted dispatch. Region tracking integrates at the
coordinator level:

**Current flow**:
```
event_dispatch (TextChanged) → highlight_coordinator.schedule(bufnr, { full = false })
  → 200ms debounce → run_all(bufnr, opts)
    → transform_pipeline.run(bufnr, code_excl, opts)
    → non-pipeline updaters (footnotes, autolink, etc.)
```

**With region tracking**:
```
event_dispatch (TextChanged) → highlight_coordinator.schedule(bufnr, { full = false })
  → 200ms debounce → run_all(bufnr, opts)
    → tracker = region_tracker.get(bufnr)
    → invalid_ranges = tracker:get_invalid_ranges()
    → opts.invalid_ranges = invalid_ranges
    → transform_pipeline.run(bufnr, code_excl, opts)
    → non-pipeline updaters receive opts.invalid_ranges
```

**footnotes.lua**: Already has viewport optimization (lines 357-369) with
explicit range handling for prefetch zones (`opts.start_line`/`opts.end_line`).
Changedtick-cached footnote map via `hl_coord.cached_value()` (line 162).
`coordinated_update()` (lines 507-518) supports prefetch zones. Frame cache
support integrated (line 344 import, lines 397-408 usage).
With `opts.invalid_ranges`, it can skip `render_ref_at()` for refs outside
invalid ranges. Frame cache continues to handle hit/miss within ranges.

**autolink.lua**: Already has `visible_only` mode (lines 78-86, used in
`coordinated_update` at lines 266-269). Its `clear()` function (lines 49-57) calls
`nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)` and cleans up
`matches_by_extmark` entries. With `opts.invalid_ranges`, clear extmarks only
in those ranges instead of calling `clear(bufnr)` (which removes all).

### Pipeline consumers (wikilinks, tags, highlights, inline fields) — lowest priority

Pipeline consumers in `pipeline_consumers.lua` already benefit from the
transform pipeline's token-based rendering. Wikilink consumer (lines 15-123,
priority 30) generates 4+ extmarks per link; tag consumer (lines 128-161,
priority 40) generates 2 extmarks per tag; inline field consumer (lines
209-268, priority 45) generates up to 5 extmarks per field; highlight
consumer (lines 166-204, priority 50) generates 3 extmarks per `==text==`.
All four consumers registered via `register_all()` (lines 277-283). The
pipeline's Layer 0 (lines 63-78 of `transform_pipeline.lua`) consumes
`line_tracker.consume(bufnr)` at line 64, which already provides dirty-line
information.

Region tracking could improve the pipeline by replacing `line_tracker`'s
`full = true` fallback with proper range arithmetic. However, the pipeline's
existing change-tracking is already reasonably efficient, making this the
lowest-priority integration.

**Potential integration**: Feed `RegionTracker`'s invalid ranges into
`line_tracker` as a replacement for the `full` flag. When `full` would
be set, instead mark only the `[first_line, new_last_line)` range as dirty
in `line_tracker.dirty`. This preserves the pipeline's existing consumer
interface while eliminating unnecessary full-buffer fallbacks.

## Implementation Steps

### Step 1: Create the region tracker module

Create `lua/andrew/vault/region_tracker.lua`:

```lua
local M = {}

local config = require("andrew.vault.config")
local log = require("andrew.vault.vault_log").scope("region_tracker")

---@class ValidRegion
---@field start_line number  0-indexed, inclusive
---@field end_line number    0-indexed, exclusive
---@field version number     changedtick when validated

---@class RegionTracker
---@field _bufnr number
---@field _regions ValidRegion[]
---@field _attached boolean
local RegionTracker = {}
RegionTracker.__index = RegionTracker

--- Create a new region tracker for a buffer.
---@param bufnr number
---@return RegionTracker
function M.new(bufnr)
  local self = setmetatable({
    _bufnr = bufnr,
    _regions = {},
    _attached = false,
  }, RegionTracker)
  self:_attach()
  return self
end

--- Attach to buffer via nvim_buf_attach to receive edit notifications.
--- Uses on_lines (not on_bytes) because consumers operate on line ranges.
--- Coexists with line_tracker.lua's on_bytes attachment on the same buffer.
function RegionTracker:_attach()
  if self._attached then return end

  local ok = vim.api.nvim_buf_attach(self._bufnr, false, {
    on_lines = function(_event, _buf, _tick, first_line, last_line, new_last_line)
      self:_on_lines(first_line, last_line, new_last_line)
    end,
    on_detach = function()
      self._attached = false
      self._regions = {}
    end,
  })

  if ok then
    self._attached = true
  else
    log.warn("Failed to attach to buffer %d", self._bufnr)
  end
end
```

### Step 2: Implement edit processing in on_lines

```lua
--- Process an edit notification from nvim_buf_attach.
--- Unlike line_tracker's on_bytes (which sets full=true on line count change),
--- this correctly handles insertions/deletions by shifting regions after the
--- edit point, preserving spatial information.
---@param first_line number  First changed line (0-indexed)
---@param last_line number   Old end of changed range (0-indexed, exclusive)
---@param new_last_line number  New end of changed range (0-indexed, exclusive)
function RegionTracker:_on_lines(first_line, last_line, new_last_line)
  local delta = new_last_line - last_line
  local new_regions = {}

  for _, region in ipairs(self._regions) do
    if region.end_line <= first_line then
      -- Region is entirely before the edit: keep unchanged
      table.insert(new_regions, region)
    elseif region.start_line >= last_line then
      -- Region is entirely after the edit: shift by delta
      table.insert(new_regions, {
        start_line = region.start_line + delta,
        end_line = region.end_line + delta,
        version = region.version,
      })
    elseif region.start_line < first_line and region.end_line > last_line then
      -- Edit is contained within region: split into two
      -- Left fragment (before edit)
      table.insert(new_regions, {
        start_line = region.start_line,
        end_line = first_line,
        version = region.version,
      })
      -- Right fragment (after edit, shifted)
      if region.end_line + delta > new_last_line then
        table.insert(new_regions, {
          start_line = new_last_line,
          end_line = region.end_line + delta,
          version = region.version,
        })
      end
    elseif region.start_line < first_line then
      -- Region overlaps edit start: truncate to before edit
      table.insert(new_regions, {
        start_line = region.start_line,
        end_line = first_line,
        version = region.version,
      })
    elseif region.end_line > last_line then
      -- Region overlaps edit end: truncate to after edit, shifted
      if region.end_line + delta > new_last_line then
        table.insert(new_regions, {
          start_line = new_last_line,
          end_line = region.end_line + delta,
          version = region.version,
        })
      end
    end
    -- else: region is fully contained in the edit range, discard it
  end

  self._regions = new_regions
  self:_enforce_limit()
end
```

### Step 3: Implement validity queries

```lua
--- Check if a specific line is within a valid region.
---@param line number  0-indexed line number
---@return boolean
function RegionTracker:is_valid(line)
  for _, region in ipairs(self._regions) do
    if line >= region.start_line and line < region.end_line then
      return true
    end
    if region.start_line > line then
      break  -- regions are sorted, no point continuing
    end
  end
  return false
end

--- Get all invalid ranges within the buffer's line count.
--- Returns ranges that are NOT covered by any valid region.
---@return {start_line: number, end_line: number}[]
function RegionTracker:get_invalid_ranges()
  local line_count = vim.api.nvim_buf_line_count(self._bufnr)
  local invalid = {}
  local cursor = 0

  for _, region in ipairs(self._regions) do
    if cursor < region.start_line then
      table.insert(invalid, {
        start_line = cursor,
        end_line = region.start_line,
      })
    end
    cursor = math.max(cursor, region.end_line)
  end

  if cursor < line_count then
    table.insert(invalid, {
      start_line = cursor,
      end_line = line_count,
    })
  end

  return invalid
end
```

### Step 4: Implement region marking and coalescing

```lua
--- Mark a line range as valid (after successful rendering).
---@param start_line number  0-indexed, inclusive
---@param end_line number    0-indexed, exclusive
function RegionTracker:mark_valid(start_line, end_line)
  if start_line >= end_line then return end

  local version = vim.api.nvim_buf_get_changedtick(self._bufnr)
  local new_region = {
    start_line = start_line,
    end_line = end_line,
    version = version,
  }

  -- Insert in sorted position
  local inserted = false
  for i, region in ipairs(self._regions) do
    if start_line <= region.start_line then
      table.insert(self._regions, i, new_region)
      inserted = true
      break
    end
  end
  if not inserted then
    table.insert(self._regions, new_region)
  end

  self:_coalesce()
  self:_enforce_limit()
end

--- Merge adjacent or overlapping valid regions.
function RegionTracker:_coalesce()
  if #self._regions <= 1 then return end

  local merged = { self._regions[1] }

  for i = 2, #self._regions do
    local prev = merged[#merged]
    local curr = self._regions[i]

    if curr.start_line <= prev.end_line then
      -- Overlapping or adjacent: merge
      prev.end_line = math.max(prev.end_line, curr.end_line)
      prev.version = math.max(prev.version, curr.version)
    else
      table.insert(merged, curr)
    end
  end

  self._regions = merged
end

--- Enforce max regions per buffer to bound memory and lookup time.
function RegionTracker:_enforce_limit()
  local max = config.region_tracker.max_per_buffer or 50
  while #self._regions > max do
    -- Remove the smallest region to maintain coverage
    local min_size = math.huge
    local min_idx = 1
    for i, region in ipairs(self._regions) do
      local size = region.end_line - region.start_line
      if size < min_size then
        min_size = size
        min_idx = i
      end
    end
    table.remove(self._regions, min_idx)
  end
end
```

### Step 5: Explicitly invalidate a range (for manual use)

```lua
--- Explicitly invalidate a line range, removing validity.
--- Used when a module knows its cached data is stale for reasons
--- other than buffer edits (e.g., index rebuild, config change).
---@param start_line number  0-indexed, inclusive
---@param end_line number    0-indexed, exclusive
function RegionTracker:invalidate_range(start_line, end_line)
  local new_regions = {}

  for _, region in ipairs(self._regions) do
    if region.end_line <= start_line or region.start_line >= end_line then
      -- No overlap: keep
      table.insert(new_regions, region)
    else
      -- Partial overlap: keep non-overlapping fragments
      if region.start_line < start_line then
        table.insert(new_regions, {
          start_line = region.start_line,
          end_line = start_line,
          version = region.version,
        })
      end
      if region.end_line > end_line then
        table.insert(new_regions, {
          start_line = end_line,
          end_line = region.end_line,
          version = region.version,
        })
      end
    end
  end

  self._regions = new_regions
end
```

### Step 6: Add buffer tracker registry with cleanup

```lua
-- Module-level registry of trackers by bufnr
local _trackers = {}

--- Get or create a RegionTracker for a buffer.
---@param bufnr number
---@return RegionTracker
function M.get(bufnr)
  if not _trackers[bufnr] then
    _trackers[bufnr] = M.new(bufnr)
  end
  return _trackers[bufnr]
end

--- Remove tracker for a buffer (called on BufDelete/BufWipeout).
---@param bufnr number
function M.remove(bufnr)
  _trackers[bufnr] = nil
end

--- Setup cleanup autocmd.
--- Uses resource_cleanup.on_buf_delete() (lines 97-102 of resource_cleanup.lua)
--- to handle both BufDelete and BufWipeout consistently with other vault modules.
function M.setup()
  local cleanup = require("andrew.vault.resource_cleanup")
  local augroup = vim.api.nvim_create_augroup("VaultRegionTrackerCleanup", { clear = true })
  cleanup.on_buf_delete(augroup, function(bufnr)
    M.remove(bufnr)
  end)
end
```

### Step 7: Integrate with embed.lua

Replace the full namespace clear and full-buffer line read in `render_embeds()`
(starts at line 437) with range-scoped operations. The existing
descriptor/frame-cache/pool architecture is preserved — only the scan scope
changes.

Current code (embed.lua lines 473-486):
```lua
-- CURRENT: clears everything, reads everything
vim.api.nvim_buf_clear_namespace(bufnr, state.ns, 0, -1)  -- line 473
embed_images.clear_image_placements(bufnr)                  -- line 474
-- ... inside coalescer.request callback:
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)  -- line 486
local descs = build_descriptors(lines, bufnr)  -- build_descriptors at line 163
```

Updated approach:
```lua
local region_tracker = require("andrew.vault.region_tracker")

-- Inside render_embeds(), after coalescer check:
local tracker = region_tracker.get(bufnr)
local invalid_ranges = tracker:get_invalid_ranges()

if #invalid_ranges == 0 and not opts.force then
  if not opts.silent then
    notify.info("Embeds up to date")
  end
  stop()
  return
end

-- Force: invalidate everything (used by :VaultEmbedRender)
if opts.force then
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  tracker:invalidate_range(0, line_count)
  invalid_ranges = tracker:get_invalid_ranges()
end

for _, range in ipairs(invalid_ranges) do
  -- Clear extmarks only in the invalid range (not buffer-wide)
  local existing = vim.api.nvim_buf_get_extmarks(
    bufnr, state.ns,
    { range.start_line, 0 },
    { range.end_line - 1, -1 },
    {}
  )
  for _, mark in ipairs(existing) do
    vim.api.nvim_buf_del_extmark(bufnr, state.ns, mark[1])
  end
  -- Clear image placements in range (requires embed_images.lua range support)
  -- NOTE: embed_images.clear_image_placements() (line 305) currently only
  -- supports full-buffer clear. A range variant is needed — see Risk section.
  embed_images.clear_image_placements_in_range(bufnr, range.start_line, range.end_line)

  -- Build descriptors only for this range
  local lines = vim.api.nvim_buf_get_lines(
    bufnr, range.start_line, range.end_line, false
  )
  local descs = build_descriptors(lines, bufnr, range.start_line)

  -- Render using existing descriptor pipeline (frame cache, lazy mode, etc.)
  local ctx = build_render_ctx(bufnr, bufpath, opts, descs, PlacementMod, snacks_doc_cfg, merge, nil, lines)
  for _, desc in ipairs(descs) do
    render_single_embed(desc, ctx)
  end

  tracker:mark_valid(range.start_line, range.end_line)
end
```

**Note**: `build_descriptors` (line 163) needs a `start_offset` parameter so
that descriptor `lnum` values are correct (absolute line numbers, not
range-relative). The current implementation computes `lnum = line_nr + 1`
(0→1 indexed conversion) from pipeline token iteration — it assumes lines
start from buffer line 0.

### Step 8: Integrate with task_hierarchy.lua

Replace full namespace clear in `render_completion_vtext()` (lines 106-161,
namespace at line 15, clear at line 111):

```lua
local region_tracker = require("andrew.vault.region_tracker")

function M.render_completion_vtext(bufnr)
  if not config.hierarchy.show_completion_vtext then return end

  local tracker = region_tracker.get(bufnr)
  local invalid_ranges = tracker:get_invalid_ranges()
  if #invalid_ranges == 0 then return end

  -- Get tasks from vault index (unchanged)
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return end
  local rel = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":.")
  local entry = idx:get(rel)
  if not entry or not entry.tasks or #entry.tasks == 0 then return end

  -- Build tree (generation-cached, unchanged)
  local roots = get_cached_tree(bufnr, entry)
  if not roots then return end

  -- Clear extmarks only in invalid ranges (not buffer-wide)
  for _, range in ipairs(invalid_ranges) do
    local existing = vim.api.nvim_buf_get_extmarks(
      bufnr, ns,
      { range.start_line, 0 },
      { range.end_line - 1, -1 },
      {}
    )
    for _, mark in ipairs(existing) do
      vim.api.nvim_buf_del_extmark(bufnr, ns, mark[1])
    end
  end

  -- Only render root tasks whose line falls within an invalid range
  for _, root in ipairs(roots) do
    local root_line = root.line - 1  -- convert to 0-indexed
    for _, range in ipairs(invalid_ranges) do
      if root_line >= range.start_line and root_line < range.end_line then
        local stats = M.completion_stats(root)
        if stats.total > 0 then
          -- Apply extmark (unchanged logic)
          vim.api.nvim_buf_set_extmark(bufnr, ns, root_line, 0, {
            virt_text = build_completion_vtext(stats),
            virt_text_pos = "eol",
          })
        end
        break
      end
    end
  end

  -- Mark all invalid ranges as valid
  for _, range in ipairs(invalid_ranges) do
    tracker:mark_valid(range.start_line, range.end_line)
  end
end
```

### Step 9: Integrate with highlight_coordinator.run_all()

Pass invalid ranges through the coordinator to all updaters. Currently
`opts` contains `full`, `arena`, `frame_cache`, and optionally `prefetch`,
`start_line`/`end_line` — but no `invalid_ranges`. This step adds it:

```lua
-- In highlight_coordinator.lua run_all() (lines 258-290):
local region_tracker = require("andrew.vault.region_tracker")

function M.run_all(bufnr, opts)
  local stop = require("andrew.vault.memory_profiler").start_timer("hl_coord.run_all")
  local arena_scope = render_arena.begin_scope()
  opts.arena = arena_scope
  opts.frame_cache = get_cache(bufnr)

  -- Inject invalid ranges for all updaters to use
  local tracker = region_tracker.get(bufnr)
  opts.invalid_ranges = tracker:get_invalid_ranges()

  local ok, err = pcall(function()
    local code_excl = link_scan.build_code_exclusion(bufnr)
    local pipeline = require("andrew.vault.transform_pipeline")
    pipeline.attach(bufnr)
    pipeline.run(bufnr, code_excl, opts)

    for _, updater in ipairs(_updaters) do
      if updater.enabled() and not pipeline.is_updater_covered(updater.name) then
        local ok2, err2 = pcall(updater.fn, bufnr, code_excl, opts)
        if not ok2 then
          log.warn("error in %s: %s", updater.name, err2)
        end
      end
    end
  end)

  -- Mark processed ranges as valid
  if opts.invalid_ranges then
    for _, range in ipairs(opts.invalid_ranges) do
      tracker:mark_valid(range.start_line, range.end_line)
    end
  end

  render_arena.end_scope(arena_scope)
  if opts.frame_cache then opts.frame_cache:finish_frame() end
  opts.arena = nil
  stop()
  if not ok then
    log.warn("run_all failed: %s", err)
  end
end
```

Coordinated updaters can then use `opts.invalid_ranges` to restrict their work:

```lua
-- Example: footnotes.lua coordinated_update
function M.coordinated_update(bufnr, code_excl, opts)
  local ranges = opts.invalid_ranges
  if ranges and #ranges == 0 then return end  -- nothing to do

  -- Existing logic, but clear/render only within invalid ranges
  -- ...
end
```

### Step 10: Add configuration

Add to `config.lua` alongside existing `invalidation` section (lines 900-904).
No `region_tracker` section currently exists — this is new:

```lua
M.region_tracker = {
  max_per_buffer = 50,       -- Maximum valid regions tracked per buffer
  coalesce_threshold = 5,    -- Minimum gap (lines) to keep regions separate
}
```

This sits alongside the existing related config sections:
- `config.invalidation` (lines 900-904): `enable_tiered`, `partial_file_threshold`, `debug`
- `config.viewport` (lines 881-888): `padding_lines`, `cleanup_threshold`,
  `full_buffer_threshold`, `render_margin`, `prefetch_multiplier`, `prefetch_debounce_ms`
- `config.pipeline` (lines 870-876): `line_cache_max`, `full_reparse_threshold`,
  `content_dedup`, `use_lpeg`, `batch_extmarks`
- `config.hierarchy` (lines 728-732): `show_completion_vtext`, `debounce_ms`, `default_fold`

## Integration with Existing Event Flow

### Current event routing (event_dispatch.lua lines 122-150)

Event routing documented at lines 125-131:
- highlight_coordinator: TextChanged + TextChangedI (NOT InsertLeave)
- embed: TextChanged + InsertLeave (NOT TextChangedI)
- task_hierarchy: TextChanged + TextChangedI (NOT InsertLeave)

```lua
vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
  group = _group,
  pattern = "*.md",
  callback = function(ev)
    local bufnr = ev.buf
    -- ... validation ...
    local event = ev.event

    -- highlight_coordinator: TextChanged + TextChangedI (lines 135-138)
    if event ~= "InsertLeave" then
      highlight_coordinator.schedule(bufnr, { full = false })
    end

    -- embed: TextChanged + InsertLeave (lines 140-143)
    if event ~= "TextChangedI" then
      embed.on_text_changed(bufnr, file)
    end

    -- task_hierarchy: TextChanged + TextChangedI (lines 145-148)
    if event ~= "InsertLeave" then
      task_hierarchy._schedule_render(bufnr)
    end
  end,
})
```

**Note**: `embed.on_text_changed()` (line 1010 in embed.lua) is a dependency
tracking hook — it only re-renders if a tracked dependency file changed via
`sync.schedule_rerender()`, gated by `config.embed.sync.enabled` and
`state.embeds_visible[bufnr]`.

### Ordering guarantee

`nvim_buf_attach`'s `on_lines` fires before `TextChanged` autocmds. This
means the region tracker has already processed the edit and updated its valid
regions by the time any autocmd callback executes. The existing
`line_tracker.lua`'s `on_bytes` also fires before `TextChanged`. Both fire
in attachment order, which is deterministic.

### Force re-render

Manual commands bypass region tracking:
- `:VaultEmbedRender`: calls `render_embeds()` which can pass `opts.force`
  to invalidate all regions first
- Highlight toggles via `hl_coord.make_toggle()`: call
  `highlight_coordinator.schedule(bufnr, { full = true })` which can
  invalidate all regions
- `:VaultIndexRebuild`: triggers `VaultCacheInvalidate` event (coordinator
  lines 416-438) which should also call `tracker:invalidate_range(0, line_count)`

### Cleanup on buffer delete

Region tracker cleanup integrates with the existing cleanup pattern used by
highlight_coordinator (lines 441-447) and other modules. `resource_cleanup`
(lines 97-102) creates autocmds for both `BufDelete` and `BufWipeout` events:

```lua
-- In highlight_coordinator.lua BufDelete handler (lines 441-447):
cleanup.on_buf_delete(_augroup, function(bufnr)
  cleanup.close_timer_in(_timers, bufnr)  -- line 442
  _buf_caches[bufnr] = nil                 -- line 443
  local pipeline = require("andrew.vault.transform_pipeline")
  pipeline.detach(bufnr)                   -- line 445
  viewport.clear_state(bufnr)              -- line 446
  region_tracker.remove(bufnr)             -- ADD THIS
end)
```

## Expected Impact

### Embed rendering (embed.lua)

A 1000-line file with 20 embeds, editing at line 50:
- **Before**: Full namespace clear + 1000-line read + 20 descriptors built +
  frame cache lookup for each = ~15ms (frame cache mitigates rebuild but not
  scan/clear)
- **After**: Range-scoped clear (~1 extmark) + ~5-line read + 1 descriptor +
  1 render = ~2ms
- **Reduction**: ~85%

### Task hierarchy (task_hierarchy.lua)

A 500-line file with 8 root task groups, editing at line 200:
- **Before**: Full namespace clear + all 8 root tasks evaluated + 8 extmarks
  recreated = ~5ms
- **After**: Range-scoped clear + 1 root task evaluated + 1 extmark = ~1ms
- **Reduction**: ~80%

### Coordinated updaters (footnotes, autolink)

A 500-line file, editing at line 200:
- **Before**: Full extmark clear + viewport or full scan = ~8ms
- **After**: Range-scoped clear + ~10-line scan = ~2ms
- **Reduction**: ~75%

### Pipeline consumers (wikilinks, tags, highlights, inline fields) — marginal

Pipeline consumers already benefit from transform_pipeline's change tracking.
Region tracking would eliminate the `line_tracker.full = true` fallback,
providing modest improvement for edits that change line count:
- **Reduction**: ~20-30% (only for line-count-changing edits)

### Overall

For localized edits (single-line typing), region tracking reduces re-render
work by 75-85% for embed and task_hierarchy — the two modules that still do
full namespace clears. The benefit is additive with existing optimizations
(frame cache, viewport restriction, debouncing).

For bulk edits (paste, undo/redo of large blocks), the invalid range may cover
a significant portion of the buffer, reducing the benefit. In the worst case
(entire buffer changed), region tracking adds negligible overhead (~0.1ms for
region bookkeeping) and falls back to full-buffer behavior.

## Risks

### Dual attachment complexity

The region tracker adds a second `nvim_buf_attach` alongside `line_tracker`'s
existing attachment. While Neovim supports multiple attachments, the two systems
track overlapping concerns (which lines changed) with different granularities
and semantics.

**Mitigation**: Consider whether `RegionTracker` could replace `line_tracker`
entirely, providing both dirty-row information (for the transform pipeline)
and valid-region tracking (for renderers). This would consolidate into a single
`nvim_buf_attach` with `on_bytes` for byte-level tracking and derived
line-level regions. Evaluate after initial implementation proves the concept.

### Line shift tracking complexity

The `on_lines` callback must correctly handle insertions, deletions, and
replacements. Off-by-one errors in line shifting can cause regions to drift
out of alignment with actual buffer content, leading to stale decorations
on wrong lines or missing decorations.

**Mitigation**: Comprehensive unit tests for the region tracker covering:
- Single-line insert/delete/replace
- Multi-line insert/delete
- Edit at region boundary (start, end, middle)
- Edit spanning multiple regions
- Edit at buffer start (line 0) and buffer end

### Stale decoration persistence

If a region is incorrectly marked as valid after its content has semantically
changed (e.g., a linked note was renamed but the local buffer's `![[...]]`
line was not edited), decorations in that region will remain stale until the
next full re-render.

**Mitigation**: External change events (index rebuild via `VaultCacheInvalidate`
autocmd at highlight_coordinator lines 416-438, vault-wide rename) call
`tracker:invalidate_range(0, line_count)` to force full re-render. The
`:VaultEmbedRender` command also forces full invalidation.

### Memory fragmentation

Rapid small edits across many locations can fragment the valid regions list,
creating many small entries. Each edit may split an existing region into two,
doubling the count.

**Mitigation**: The `coalesce_threshold` config merges nearby regions, and
`max_per_buffer` caps the total count. The `_enforce_limit()` method evicts
the smallest regions first, preserving coverage of the largest contiguous
valid areas.

### Interaction with undo/redo

Neovim's undo/redo can change arbitrary regions of the buffer in a single
operation. The `on_lines` callback handles this correctly (it reports the
actual changed range), but undo of a multi-site edit may produce multiple
`on_lines` callbacks in rapid succession.

**Mitigation**: Each `on_lines` callback is processed independently and
correctly. Multiple callbacks in one event loop iteration simply produce
multiple invalidations, which is correct behavior.

### build_descriptors offset parameter

The proposed embed.lua integration requires `build_descriptors` to accept a
`start_offset` parameter so descriptor `lnum` values reflect absolute buffer
lines (not range-relative indices). The current implementation (line 174)
uses 1-indexed iteration starting from line 1.

**Mitigation**: Add an optional `line_offset` parameter to `build_descriptors`.
When provided, `lnum` is calculated as `line_offset + i` instead of just `i`.
Default to 0 for backward compatibility with full-buffer calls.

### Image placement cleanup

The current `embed_images.clear_image_placements(bufnr)` (line 305 of
`embed_images.lua`) clears all placements buffer-wide by setting
`state.image_placements[bufnr] = nil` and closing each placement via
`p:close()`. Placements are created by `create_placement()` (lines 262-282)
and stored in `state.image_placements[bufnr]` (line 277), with each placement
tagged with `_vault_lnum` for viewport GC (line 276). Range-scoped embed
rendering requires a `clear_image_placements_in_range(bufnr, start, end)`
variant.

**Mitigation**: Since each placement has a `_vault_lnum` field, a range-scoped
clear can filter `state.image_placements[bufnr]` by lnum and close only those
placements that fall within the target range, preserving the rest.
