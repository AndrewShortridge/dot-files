# 26 — Viewport-Restricted Rendering

## Priority: HIGH
## Inspired By: Zed's `UniformList` windowed rendering and `DisplayMap` layered architecture

## Problem

The vault plugin renders extmarks, virtual text, and image placements for the **entire buffer**
regardless of what the user can actually see. For large notes, the vast majority of rendered
content is off-screen and wasted.

### Current Embed Flow (`embed.lua`, 880 lines)

```
render_embeds(opts) called on BufReadPost (150ms defer) / BufEnter:
  opts: { silent?: boolean, force?: boolean }
  → Pre-checks: exit if not vault markdown
  → Coalescer deduplication (lines 404-416):
    → Non-forced calls skip if render already in-flight
    → Forced calls (TextChanged) cancel existing render and restart
  → cancel_async_render(bufnr) (lines 204-208) — cancels async + scroll timers
  → Clears namespace and image placements (full buffer)
  → Arena scope begins (line 429) for ephemeral table allocation
  → init_render_deps() (lines 97-105) — returns PlacementMod, snacks_doc_cfg, merge fn
    → Caches merge function at module level (_cached_merge, line 91)
  → build_descriptors(lines) (lines 150-165) — scans ALL buffer lines for ![[...]] patterns
    → Uses state.iterate_embeds() with pattern matching, returns pool-allocated descriptors
    → Descriptor: { lnum, col_s, col_e, inner, is_image, rendered, lines_used }
    → Object pool: _desc_pool configured via config.pools.embed_descriptor
  → warm_embed_cache(descs, bufpath, arena_scope) — pre-reads cross-file targets
  → Manages generation counter for stale-check (_embed_descriptors[bufnr].generation)
  → build_render_ctx() — creates shared ctx with stats, deps, border_hl, etc.
  → Lazy mode (config.embed.lazy = true, default) (lines 447-456):
    → visible_range(config.embed.lazy_margin) (lines 219-223) returns (top, bot) via w0/w$ queries
    → render_in_range(descs, ctx, top, bot) (lines 333-342) — renders only visible embeds
    → If unrendered remain: render_remaining_async(bufnr, generation, ctx) (lines 360-391)
      → cleanup.repeating() timer: 16ms delay, 16ms repeat
      → Processes config.embed.lazy_batch_size (default 5) unrendered embeds per tick
      → Closure-based cursor tracking across ticks; generation check prevents stale renders
      → Eventually renders ALL off-screen embeds
  → Legacy mode (config.embed.lazy = false) (lines 457-462):
    → Synchronous render-all loop
  → update_deps(bufnr, ctx.deps) — tracks file dependencies for live sync
  → Image retry logic (1200ms) for DA3 terminal detection
  → Arena scope ends (line 483) — ephemeral tables returned to pool
  → Coalescer resolution (line 491) — coalescer._resolve_entry()

WinScrolled handler (lines 795-831):
  → Early exit if lazy disabled or embeds not visible
  → visible_range(config.embed.lazy_margin) — compute viewport
  → Scan descriptors for unrendered embeds in viewport
  → If found: cleanup.debounce(state._scroll_timers[bufnr], 80ms, callback)
    → Validates buffer + generation via check_generation() (embed.lua lines 349-354)
    → Initializes render deps, builds scroll context with silent mode
    → render_in_range() for newly visible embeds only
    → update_deps() for dependency tracking

Problem: Even with lazy=true, ALL embeds are eventually rendered via
render_remaining_async(). The 16ms repeating timer processes every off-screen embed
in batches of 5. Image placements are never cleaned up when they scroll far
off-screen (only on clear_embeds()). A 5000-line note with 50 embeds creates 50
placements regardless of viewport.
```

### State Management (`embed_state.lua`, 203 lines)

```
Per-buffer state dictionaries (lines 12-20):
  embeds_visible[bufnr]        — {embed_data} tracking visible embeds
  image_placements[bufnr]      — table[] of snacks placement objects
  _embed_deps[bufnr]           — table<string, true> file dependencies
  _embed_descriptors[bufnr]    — { generation, list, async_timer }
  _sync_timers[bufnr]          — uv_timer_t for live sync
  _scroll_timers[bufnr]        — uv_timer_t for WinScrolled debounce
  _image_retry_fired[bufnr]    — boolean flag

State registration system (lines 24-65): _state_dicts registry tracks all dicts
with custom cleanup functions (image_placements calls embed_images.clear_image_placements,
timers use cleanup.close_timer_in, descriptors clean up async_timer).

Unified cleanup: state.clear_buffer_state(bufnr, opts) (lines 89-108) iterates
all registered state dicts and calls their cleanup functions.
GC: state.gc_stale_buffers() (lines 111-126) removes entries for invalid buffers.
Active check: state.is_embed_active(bufnr) (lines 70-72) checks embeds_visible + buf validity.

Note: check_generation() lives in embed.lua (lines 349-354), NOT in embed_state.lua.
It validates buffer existence + generation match before async/scroll renders proceed.
```

### Current Highlight Flow (`highlight_coordinator.lua`)

```
Event routing: BufWritePost and TextChanged/TextChangedI are NOT directly in
highlight_coordinator.lua — they are delegated through event_dispatch.lua which
consolidates all event handling.

BufEnter (highlight_coordinator.lua lines 314-322):
  → schedule(bufnr, { full = true }) — 30ms debounce

BufWritePost (via event_dispatch.lua → on_buf_write, lines 370-372):
  → schedule(bufnr, { full = true }) — 30ms debounce

VaultCacheInvalidate (lines 340-358):
  → filter_utils.should_invalidate_buffer() check
  → schedule(bufnr, { full = true }) — 30ms debounce

TextChanged / TextChangedI (via event_dispatch.lua):
  → schedule(bufnr, { full = false }) — 200ms debounce

WinScrolled (lines 327-337):
  → schedule(bufnr, { full = false }) — 200ms debounce

schedule(bufnr, opts) (lines 268-279):
  → Debounce: opts.full ? 30ms : 200ms
  → cleanup.debounce(_timers[bufnr], debounce_ms, callback)
  → Callback: run_all(bufnr, opts)

run_all(bufnr, opts) (lines 281-308):
  → Arena scope: render_arena.begin_scope() / end_scope()
  → code_excl = link_scan.build_code_exclusion(bufnr) — cached per changedtick
  → Iterates _updaters[] sorted by priority
  → Each updater: enabled() check, then pcall(updater.fn, bufnr, code_excl, opts)

Updater registry (lines 244-266):
  _updaters[] = { fn, name, priority, enabled }
  M.register(name, fn, enabled_fn, priority) — default priority 50, auto-sorts

EXISTING VIEWPORT SUPPORT (make_coordinated_update factory, lines 146-184):
  When opts.full = true (lines 164-167):
    → clear_extmarks(ns, bufnr) — full buffer
    → start_line = 0, end_line = line_count
  When opts.full = false (lines 168-171):
    → link_scan.get_visible_range(bufnr) — returns (top-5, bot+5) 0-indexed
    → clear_extmarks(ns, bufnr, start_line, end_line) — range only
    → lines = nvim_buf_get_lines(bufnr, start_line, end_line) — range only
  Navigation cache: updated if process_fn() returns positions (lines 177-182)

link_scan.get_visible_range(bufnr, margin) (link_scan.lua lines 153-163):
  → margin defaults to 5 lines
  → Falls back to full buffer if bufnr not in current window (win_buf ~= bufnr)
  → Returns 0-indexed (start, end_exclusive) range
  → top = vim.fn.line("w0") - 1, bot = vim.fn.line("w$")
```

### Updater Viewport Status

| Updater | Method | Viewport on Incremental |
|---------|--------|------------------------|
| `highlights.lua` (==highlight== marks) | Factory (`make_coordinated_update`, line 108) | YES — via `get_visible_range()` in factory |
| `tag_highlights.lua` | Factory (`make_coordinated_update`, line 180) | YES — via `get_visible_range()` in factory |
| `wikilink_highlights.lua` | Direct implementation (lines 179-193) | YES — checks `opts.full` (line 185), calls `get_visible_range()` (line 189) |
| `footnotes.lua` | Direct implementation (lines 481-484) | YES — checks `opts.full` (line 362, defaults to true: `full ~= false`), calls `get_visible_range()` (line 371) |
| `inline_fields.lua` | Direct implementation (lines 395-438) | YES — checks `opts.full` (line 404), calls `get_visible_range()` (line 421) |
| `autolink.lua` | Direct implementation (lines 256-259) | YES — inverts via `visible_only = not opts.full` (line 258), calls `get_visible_range()` (line 78) |

Note: `highlight_marks.lua` does NOT exist. Only 2 modules (highlights, tag_highlights)
use the factory pattern; the other 4 implement `coordinated_update()` directly with
explicit viewport checks. All 6 properly support viewport-restricted rendering.

**Key finding**: All highlight updaters ALREADY support viewport-restricted rendering
on incremental updates (`opts.full = false`). The remaining issue is:
1. **BufEnter always does full=true** — scans entire buffer on every buffer entry
2. **BufWritePost always does full=true** (via event_dispatch.lua) — scans entire buffer on save
3. **No cleanup** of extmarks far off-screen during long editing sessions
4. **Embed system** still renders all embeds via async batches regardless of viewport

### Impact on Large Files

| Scenario | Current Work | Visible Work | Waste |
|----------|-------------|--------------|-------|
| 5000-line note, 50 embeds, viewport=50 lines | 50 embeds rendered (async batches) | ~3 visible | 94% |
| 5000-line note, 500 wikilinks, BufEnter | 500 extmarks (full=true) | ~30 visible | 94% |
| 5000-line note, 500 wikilinks, scroll | ~60 extmarks (5-line margin) | ~30 visible | ~50% |
| 20 image embeds, viewport shows 2 | 20 placements + conversions | 2 needed | 90% |
| BufEnter on large note (highlights) | Full scan (5000 lines) | 50 lines needed | 99% |

The cost is not just CPU — image placements consume terminal bandwidth (Kitty graphics
protocol), memory (converted image buffers), and file descriptors.

## Zed Reference

### UniformList (crates/gpui/src/elements/uniform_list.rs)

The actual Zed implementation uses a `prepaint` method (not `paint`) for layout and
visible range calculation:

```rust
// prepaint method (lines 230-452)
impl UniformList {
    fn prepaint(&mut self, ...) {
        let shared_scroll_offset = self.interactivity.scroll_offset.clone().unwrap();
        let scroll_offset = *shared_scroll_offset.borrow();

        // Scroll bounds validation (lines 305-321)
        let content_height =
            item_height * self.item_count + padding.top + padding.bottom;
        let min_vertical_scroll_offset = padded_bounds.size.height - content_height;
        if is_scrolled_vertically && scroll_offset.y < min_vertical_scroll_offset {
            shared_scroll_offset.borrow_mut().y = min_vertical_scroll_offset;
        }

        // Calculate visible range from scroll position (lines 371-378)
        let first_visible_element_ix =
            (-(scroll_offset.y + padding.top) / item_height).floor() as usize;
        let last_visible_element_ix = ((-scroll_offset.y + padded_bounds.size.height)
            / item_height)
            .ceil() as usize;
        let visible_range = first_visible_element_ix
            ..cmp::min(last_visible_element_ix, self.item_count);

        // Only render items in visible range (lines 383-388)
        let items = if y_flipped {
            let flipped_range = self.item_count.saturating_sub(visible_range.end)
                ..self.item_count.saturating_sub(visible_range.start);
            let mut items = (self.render_items)(flipped_range, window, cx);
            items.reverse();
            items
        } else {
            (self.render_items)(visible_range.clone(), window, cx)
        };

        // Position items within viewport (lines 393-401)
        for (ix, mut item) in items.into_iter().enumerate() {
            let item_origin = padded_bounds.origin
                + point(
                    scroll_offset.x + padding.left,
                    item_height * ix + scroll_offset.y + padding.top,
                );
            // ... layout and store
        }
    }
}
```

Key insights:
- `scroll_offset.y` is **negative** when scrolled down (more negative = further)
- Calculates exact visible range with floor/ceil — **no overdraw padding**
- `render_items` callback receives `Range<usize>` — only visible items are created
- Uses `SmallVec<[AnyElement; 64]>` for stack-allocated visible item storage
- `UniformListFrameState` stores only `SmallVec<[AnyElement; 32]>` — visible items only
- Supports Y-flip, scroll-to-item with strategies (Top, Center, ToPosition)
- Content masking clips items at list bounds: `window.with_content_mask(Some(content_mask), ...)`

### DisplayMap (crates/editor/src/display_map.rs)

The layered pipeline has **6 stages** (not 4):

```rust
// Pipeline architecture (lines 1-14 of display_map.rs):
// InlayMap    → decides where inlays (ghost text, hints) are displayed
//   ↓
// FoldMap     → tracks folded regions and fold indicators
//   ↓
// TabMap      → handles hard tabs in buffer
//   ↓
// WrapMap     → handles soft wrapping (Entity<WrapMap> — reactive)
//   ↓
// BlockMap    → tracks custom blocks (diagnostics, headers)
//   ↓
// DisplayMap  → adds background highlights (struct also holds CreaseMap auxiliary)

// Pipeline construction (DisplayMap::new, lines 125-165):
let (inlay_map, snapshot) = InlayMap::new(buffer_snapshot);       // line 141
let (fold_map, snapshot) = FoldMap::new(snapshot);                 // line 142
let (tab_map, snapshot) = TabMap::new(snapshot, tab_size);         // line 143
let (wrap_map, snapshot) = WrapMap::new(snapshot, font, font_size, wrap_width, cx); // line 144
let block_map = BlockMap::new(snapshot, buffer_header_height, excerpt_header_height); // line 145

// Pipeline sync chain in DisplayMap::snapshot() method (lines 167-194):
// Note: There is no single sync() on DisplayMap — orchestration happens in snapshot()
// and other operation-specific methods that chain the calls manually.
let (inlay_snapshot, edits) = self.inlay_map.sync(buffer_snapshot, edits);    // line 170
let (fold_snapshot, edits) = self.fold_map.read(inlay_snapshot.clone(), edits); // line 171
let (tab_snapshot, edits) = self.tab_map.sync(fold_snapshot.clone(), edits, tab_size); // line 173
let (wrap_snapshot, edits) = self.wrap_map.update(cx, |map, cx|              // lines 174-176
    map.sync(tab_snapshot.clone(), edits, cx));
let block_snapshot = self.block_map.read(wrap_snapshot.clone(), edits).snapshot; // line 177
```

### BlockMap Range Queries (block_map.rs, lines 1347-1375)

```rust
// BlockMap uses SumTree for O(log n) range queries
pub fn blocks_in_range(&self, rows: Range<u32>) -> impl Iterator<Item = (u32, &Block)> {
    let mut cursor = self.transforms.cursor::<BlockRow>(&());
    cursor.seek(&BlockRow(rows.start), Bias::Left);  // O(log n) seek
    while cursor.start().0 < rows.start && cursor.end().0 <= rows.start {
        cursor.next();
    }

    std::iter::from_fn(move || {
        while let Some(transform) = cursor.item() {
            let start_row = cursor.start().0;
            if start_row > rows.end { break; }  // Stop at viewport end
            if let Some(block) = &transform.block {
                cursor.next();
                return Some((start_row, block));
            } else {
                cursor.next();
            }
        }
        None
    })
}
```

Key techniques: Cursor seek for O(log n) start, early termination at range end, lazy
iterator returns only in-range blocks.

### Editor Element Viewport Calculation (element.rs, lines 8050-8059)

```rust
// Calculate visible row range from scroll position
let mut scroll_position = snapshot.scroll_position();
let start_row = DisplayRow(scroll_position.y as u32);
let max_row = snapshot.max_point().row();
let end_row = cmp::min(
    (scroll_position.y + height_in_lines).ceil() as u32,
    max_row.next_row().0,
);
let end_row = DisplayRow(end_row);

// Only layout visible lines (lines 8314-8322)
let mut line_layouts = Self::layout_lines(
    start_row..end_row,
    &snapshot, &self.style, editor_width,
    is_row_soft_wrapped, window, cx,
);
```

`layout_lines()` (lines 3246-3310) calls `snapshot.highlighted_chunks(rows, ...)` (line 3298)
which chains through the block map's `chunks()` method — all range-restricted. The editor
stores `visible_display_row_range: start_row..end_row` in `EditorLayout` (line 9099, populated
at line 8905) and all subsequent paint methods (cursors, selections, line numbers, hover
popovers) check `visible_display_row_range.contains()` before rendering.

Key insight: Zed uses **no overdraw padding** — the calculation is exact floor/ceil of
scroll position to viewport bounds. Verified: no padding rows are added between the
calculation (lines 8050-8059) and layout_lines() invocation (line 8314).

## Proposed Solution

### 1. Viewport Tracking Module (`viewport.lua`)

A centralized module that tracks per-window visible line ranges and provides them to
rendering subsystems. This **extends** the existing `link_scan.get_visible_range()` with
richer state: per-window caching, change detection, and cleanup thresholds.

```lua
--- Viewport tracking for rendering optimization.
--- Extends link_scan.get_visible_range() with per-window caching and change detection.

local M = {}
local config = require("andrew.vault.config")

--- @class ViewportRange
--- @field first number 1-indexed first visible line
--- @field last number 1-indexed last visible line
--- @field pad_first number first - padding (clamped to 1)
--- @field pad_last number last + padding (clamped to line_count)
--- @field height number viewport height in lines

--- @type table<number, ViewportRange> per-window cache
local _ranges = {}

--- @type table<number, ViewportRange> previous range (for diff detection)
local _prev_ranges = {}

--- Get the current viewport range for a window.
--- @param winid? number window ID (default: current)
--- @return ViewportRange
function M.get_range(winid)
  winid = winid or vim.api.nvim_get_current_win()
  local cached = _ranges[winid]
  if cached then return cached end
  return M.refresh(winid)
end

--- Refresh viewport range for a window.
--- @param winid? number
--- @return ViewportRange
function M.refresh(winid)
  winid = winid or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local padding = config.viewport.padding_lines

  -- Save previous for diff detection
  _prev_ranges[winid] = _ranges[winid]

  local first = vim.fn.line("w0", winid)
  local last = vim.fn.line("w$", winid)
  local range = {
    first = first,
    last = last,
    pad_first = math.max(1, first - padding),
    pad_last = math.min(line_count, last + padding),
    height = last - first + 1,
  }

  _ranges[winid] = range
  return range
end

--- Check if a line is within the padded viewport.
--- @param lnum number 1-indexed line number
--- @param winid? number
--- @return boolean
function M.in_range(lnum, winid)
  local r = M.get_range(winid)
  return lnum >= r.pad_first and lnum <= r.pad_last
end

--- Check if a line is far enough off-screen to warrant cleanup.
--- Returns true if the line is beyond cleanup_threshold * viewport_height
--- from the nearest viewport edge.
--- @param lnum number 1-indexed line number
--- @param winid? number
--- @return boolean
function M.should_cleanup(lnum, winid)
  local r = M.get_range(winid)
  local threshold = r.height * config.viewport.cleanup_threshold
  return lnum < (r.first - threshold) or lnum > (r.last + threshold)
end

--- Get lines that became newly visible since last refresh.
--- Returns nil if no previous range exists (first render).
--- @param winid? number
--- @return { first: number, last: number }[]|nil new_ranges
function M.newly_visible(winid)
  winid = winid or vim.api.nvim_get_current_win()
  local cur = _ranges[winid]
  local prev = _prev_ranges[winid]
  if not cur or not prev then return nil end

  local ranges = {}

  -- New lines above previous viewport
  if cur.pad_first < prev.pad_first then
    ranges[#ranges + 1] = { first = cur.pad_first, last = math.min(prev.pad_first - 1, cur.pad_last) }
  end

  -- New lines below previous viewport
  if cur.pad_last > prev.pad_last then
    ranges[#ranges + 1] = { first = math.max(prev.pad_last + 1, cur.pad_first), last = cur.pad_last }
  end

  return #ranges > 0 and ranges or nil
end

--- Determine render strategy based on scroll distance.
--- @param winid number
--- @return "incremental"|"full"
function M.render_strategy(winid)
  local cur = _ranges[winid]
  local prev = _prev_ranges[winid]
  if not prev then return "full" end

  local distance = math.abs(cur.first - prev.first)
  if distance > cur.height * 2 then
    return "full"  -- Large jump — clear and re-render
  end
  return "incremental"  -- Small scroll — extend only
end

--- Invalidate cached range for a window (e.g., on window close).
--- @param winid number
function M.invalidate(winid)
  _ranges[winid] = nil
  _prev_ranges[winid] = nil
end

return M
```

### 2. Embed Rendering Changes (`embed.lua`)

Replace the current "lazy batch" approach (render visible first, then eventually
render ALL off-screen via `render_remaining_async()`) with a viewport-restricted
approach (never render off-screen).

```lua
-- CURRENT (lazy mode, lines 447-456): render visible, then async-batch ALL remaining
if config.embed.lazy then
  local top, bot = visible_range(config.embed.lazy_margin)  -- w0/w$ query (lines 219-223)
  render_in_range(descs, ctx, top, bot)                     -- visible only (lines 333-342)
  if unrendered_count > 0 then
    render_remaining_async(bufnr, generation, ctx)           -- ALL off-screen (lines 360-391)
    -- ↑ cleanup.repeating(timer, 16, 16, fn) processes lazy_batch_size=5 per tick
    -- Closure-based cursor tracking; eventually renders every single off-screen embed
  end
end

-- PROPOSED: render padded viewport only, skip off-screen entirely
local vp = viewport.get_range()
render_in_range(descs, ctx, vp.pad_first, vp.pad_last)
-- No render_remaining_async() call. Off-screen embeds render on scroll.
-- Descriptors with rendered=false stay unrendered until scrolled into view.
```

#### Scroll-Triggered Extension

The existing WinScrolled handler (lines 795-831) already detects unrendered embeds
in the viewport via debounced `render_in_range()`. Adapt it to use `viewport.lua`
for change detection instead of inline `visible_range()` queries:

```lua
-- Adapted WinScrolled handler (replaces current lines 795-831)
vim.api.nvim_create_autocmd("WinScrolled", {
  group = _augroup,
  callback = function()
    if not config.embed.lazy then return end
    local bufnr = vim.api.nvim_get_current_buf()
    local ds = state._embed_descriptors[bufnr]
    if not ds or not state.embeds_visible[bufnr] then return end

    viewport.refresh()
    local new_ranges = viewport.newly_visible()
    if not new_ranges then return end

    -- Check if any unrendered embeds fall in newly visible ranges
    local need_render = false
    for _, range in ipairs(new_ranges) do
      for _, d in ipairs(ds.list) do
        if not d.rendered and d.lnum >= range.first and d.lnum <= range.last then
          need_render = true
          break
        end
      end
      if need_render then break end
    end
    if not need_render then return end

    -- Debounced render (reuse existing scroll timer infrastructure)
    state._scroll_timers[bufnr] = cleanup.debounce(
      state._scroll_timers[bufnr],
      config.embed.lazy_scroll_debounce_ms,
      function()
        if not state.is_embed_active(bufnr) then return end
        local cur_ds = check_generation(bufnr, ds.generation)
        if not cur_ds then return end

        local vp = viewport.get_range()
        local scroll_ctx = build_render_ctx(...)
        render_in_range(cur_ds.list, scroll_ctx, vp.pad_first, vp.pad_last)
        update_deps(bufnr, scroll_ctx.deps)

        -- GC: close image placements far off-screen
        gc_distant_placements(bufnr)
      end
    )
  end,
})
```

#### Image Placement GC

```lua
--- Close image placements that have scrolled far off-screen.
--- Uses viewport.should_cleanup() to determine threshold.
--- Marks associated descriptors as unrendered for re-render on scroll-back.
local function gc_distant_placements(bufnr)
  local placements = state.image_placements[bufnr]
  if not placements then return end

  for i = #placements, 1, -1 do
    local p = placements[i]
    if viewport.should_cleanup(p.lnum) then
      -- Close via snacks placement API (p is a placement object)
      local ok, _ = pcall(function()
        if p.close then p:close() end
      end)
      -- Find matching descriptor and mark unrendered
      local ds = state._embed_descriptors[bufnr]
      if ds then
        for _, desc in ipairs(ds.list) do
          if desc.lnum == p.lnum and desc.is_image then
            desc.rendered = false
            break
          end
        end
      end
      table.remove(placements, i)
    end
  end
end
```

### 3. Highlight Coordinator Changes (`highlight_coordinator.lua`)

The coordinator **already** supports viewport-restricted rendering via the
`make_coordinated_update()` factory and `link_scan.get_visible_range()`. The main
change is to make `BufEnter` viewport-aware for large files instead of always
using `full=true`.

```lua
-- CURRENT (lines 314-322): BufEnter always triggers full=true
vim.api.nvim_create_autocmd("BufEnter", {
  group = _augroup,
  pattern = "*.md",
  callback = function(ev)
    if engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
      M.schedule(ev.buf, { full = true })  -- scans entire buffer
    end
  end,
})

-- PROPOSED: BufEnter uses viewport for large files
vim.api.nvim_create_autocmd("BufEnter", {
  group = _augroup,
  pattern = "*.md",
  callback = function(ev)
    if engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
      local line_count = vim.api.nvim_buf_line_count(ev.buf)
      local full = line_count <= config.viewport.full_buffer_threshold
      M.schedule(ev.buf, { full = full })
    end
  end,
})

-- Also update on_buf_write (lines 370-372, called from event_dispatch.lua):
function M.on_buf_write(ctx)
  local line_count = vim.api.nvim_buf_line_count(ctx.bufnr)
  local full = line_count <= config.viewport.full_buffer_threshold
  M.schedule(ctx.bufnr, { full = full })
end

-- schedule() remains unchanged (lines 268-279: 30ms debounce for full, 200ms for incremental)
-- run_all() remains unchanged (lines 281-308) — opts.full flows to updaters via factory/direct
-- make_coordinated_update() (lines 146-184) already calls link_scan.get_visible_range() when !opts.full
-- Direct updaters (wikilink_highlights, footnotes, inline_fields, autolink) also check opts.full
```

**Note**: `link_scan.get_visible_range(bufnr, margin)` already provides the viewport
range with a 5-line margin. The new `viewport.lua` module adds richer state (per-window
caching, change detection, cleanup thresholds) for the embed system, while highlights
can continue using the simpler `get_visible_range()` approach.

### 4. Individual Highlight Updater Changes

**Minimal changes needed** — all updaters already respect `opts.full`:

- **Factory-based** (highlights.lua line 108, tag_highlights.lua line 180):
  Already handle viewport via `make_coordinated_update()`. No code changes needed.

- **Direct implementations** (wikilink_highlights lines 179-193, footnotes lines 481-484,
  inline_fields lines 395-438, autolink lines 256-259):
  Already check `opts.full` and call `get_visible_range()`. No code changes needed.
  Note: footnotes defaults to full (`full = opts.full ~= false`); autolink uses inverted
  logic (`visible_only = not opts.full`). Both achieve the same viewport restriction.

The only behavioral change is that `BufEnter` and `BufWritePost` on large files
(>threshold) will now pass `full=false`, causing these updaters to use their existing
viewport-restricted code paths.

### 5. Extmark Cleanup Strategy

Extmarks outside the viewport are not immediately cleared. Instead:

1. **On scroll forward**: Render new lines at the bottom of viewport. Extmarks at the
   top remain (Neovim handles them efficiently even if not displayed).
2. **On large jump** (viewport changes by > 2x height): Clear all extmarks, re-render
   viewport from scratch. Detected by `viewport.render_strategy()` returning `"full"`.
3. **Periodic GC** (optional): On a slow timer (e.g., 5s), clear extmarks beyond the
   cleanup threshold. This prevents unbounded extmark growth during long editing sessions.

## Integration Points

### Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/viewport.lua` | **New** — viewport tracking module with per-window cache, change detection |
| `lua/andrew/vault/config.lua` | Add `config.viewport.*` section (currently no viewport config exists) |
| `lua/andrew/vault/embed.lua` (880 lines) | Remove `render_remaining_async()` call (lines 360-391); use `viewport.get_range()` for initial render (lines 447-456); add `gc_distant_placements()` |
| `lua/andrew/vault/embed_state.lua` (203 lines) | No changes — existing state dicts and registration system sufficient |
| `lua/andrew/vault/highlight_coordinator.lua` | Change BufEnter (lines 314-322) and on_buf_write (lines 370-372) to use `full=false` for large files |

### Files NOT Modified (Already Viewport-Aware)

| File | Status |
|------|--------|
| `lua/andrew/vault/highlights.lua` | Factory-based (line 108), already viewport-restricted on `opts.full=false` |
| `lua/andrew/vault/tag_highlights.lua` | Factory-based (line 180), already viewport-restricted |
| `lua/andrew/vault/wikilink_highlights.lua` | Direct (lines 179-193), already checks `opts.full` and uses `get_visible_range()` |
| `lua/andrew/vault/footnotes.lua` | Direct (lines 481-484), already checks `opts.full` (defaults full via `~= false`) |
| `lua/andrew/vault/inline_fields.lua` | Direct (lines 395-438), already checks `opts.full` and uses `get_visible_range()` |
| `lua/andrew/vault/autolink.lua` | Direct (lines 256-259), uses inverted `visible_only = not opts.full` |
| `lua/andrew/vault/link_scan.lua` | `get_visible_range()` (lines 153-163) already exists, continues to serve highlight updaters |

### Interaction with Existing Systems

- **embed.lua lazy mode** (`config.embed.lazy`): Viewport restriction **eliminates** the
  need for `render_remaining_async()`. The existing `lazy_batch_size`, `lazy_margin`, and
  `lazy_scroll_debounce_ms` config keys are partially superseded:
  - `lazy_batch_size` — no longer needed (no async batches)
  - `lazy_margin` — replaced by `viewport.padding_lines`
  - `lazy_scroll_debounce_ms` — kept for scroll render debounce
  Migration: viewport mode replaces async batching as default. `config.embed.lazy` flag
  kept but its meaning changes from "lazy batch" to "viewport-restricted".

- **highlight_coordinator debounce**: The existing debounce timers (`_timers`) remain.
  The existing `schedule()` (lines 268-279) with 30ms/200ms debounce is unchanged.
  Viewport restriction reduces work per debounce tick on large files.

- **make_coordinated_update() factory** (lines 146-184): Already handles full vs viewport
  rendering. Only 2 updaters (highlights, tag_highlights) use the factory; the other 4
  (wikilink_highlights, footnotes, inline_fields, autolink) implement direct viewport
  checks. All 6 already support `full=false`. The only change is that more events
  trigger the viewport path.

- **event_dispatch.lua**: BufWritePost and TextChanged/TextChangedI are dispatched through
  event_dispatch.lua, not directly in highlight_coordinator. The BufWritePost handler calls
  `highlight_coordinator.on_buf_write(ctx)` (lines 370-372) which must also be updated
  to use viewport-aware `full` selection for large files.

- **link_scan.get_visible_range()**: Continues to serve highlight updaters with its
  5-line margin. The new `viewport.lua` module serves the embed system with richer
  state (change detection, cleanup thresholds, per-window caching).

- **embed.lua WinScrolled handler** (lines 795-831): Already exists with debounce +
  generation checking via `check_generation()` (embed.lua lines 349-354). Refactored
  to use `viewport.newly_visible()` instead of inline `visible_range()`.

- **Image placement lifecycle**: Currently placements are stored in
  `state.image_placements[bufnr]` and only cleaned on `clear_embeds()` /
  `clear_buffer_state()`. Viewport GC adds mid-session cleanup for off-screen images
  via `gc_distant_placements()`.

- **render_arena / table_pool**: No changes. Descriptors still pool-allocated via
  `_desc_pool` (configured via `config.pools.embed_descriptor`). Arena scopes used in
  both embed.lua (line 429) and highlight_coordinator run_all() (line 286). Per-embed
  arena scopes also used within render_single_embed() for ephemeral virt_lines tables.

- **embed_state.lua** (203 lines): No structural changes. Existing state dicts
  (`_embed_descriptors`, `image_placements`, `_scroll_timers`) and state registration
  system (lines 24-65) are sufficient. `check_generation()` in embed.lua (lines 349-354)
  continues to guard async/scroll renders. `gc_stale_buffers()` (lines 111-126) handles
  invalid buffer cleanup separately from viewport GC.

- **Doc 15 (Preview & Render Caching)**: Complementary. File cache reduces I/O cost
  per embed; viewport restriction reduces the number of embeds rendered at all.

## Configuration

```lua
-- In config.lua:
M.viewport = {
  padding_lines = 50,           -- Extra lines rendered beyond visible viewport
  cleanup_threshold = 3.0,      -- Multiplier: clean up extmarks/placements beyond
                                -- this × viewport_height from nearest edge
  scroll_debounce_ms = 50,      -- Debounce for viewport.refresh() on scroll
  full_buffer_threshold = 200,  -- Files with fewer lines skip viewport restriction
                                -- (BufEnter uses full=true for these)
  gc_interval_ms = 5000,        -- Optional periodic GC interval (0 = disabled)
}
```

### Config Rationale

- **padding_lines = 50**: Ensures smooth scrolling — user won't see blank areas while
  scrolling at normal speed. At 60fps with 3 lines/frame scroll speed, 50 lines gives
  ~16 frames of pre-rendered content. Note: Zed uses **zero** overdraw padding — the
  calculation is exact. We use 50 because terminal rendering has higher latency than
  GPU-accelerated rendering.

- **cleanup_threshold = 3.0**: Conservative — only cleans up content 3 viewport-heights
  away. Handles rapid scroll-back without re-rendering. A 50-line viewport cleans up
  beyond 150 lines distance.

- **full_buffer_threshold = 200**: Files under 200 lines get full rendering (no overhead
  from viewport tracking). Most vault notes are under 200 lines; the optimization
  targets the long-tail of large notes.

### Config Migration

| Old Key | Current Value | New Key | Notes |
|---------|---------------|---------|-------|
| `config.embed.lazy_margin` | 0 | `config.viewport.padding_lines` | Semantic replacement (currently 0, proposed 50) |
| `config.embed.lazy_batch_size` | 5 | (removed) | No async batches in viewport mode |
| `config.embed.lazy_scroll_debounce_ms` | 80 | Kept | Still used for embed scroll debounce |
| `config.embed.lazy` | true | Kept | Meaning changes: enables viewport-restricted rendering |

## Expected Impact

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Extmarks on BufEnter (5000-line file) | ~500 (full scan) | ~60 (viewport+padding) | 88% fewer |
| Image placements (20 images in file) | 20 (all via async batch) | 2-4 (visible only) | 80-90% fewer |
| Lines scanned on BufEnter (highlights) | 5000 (full=true) | 100-150 (full=false) | 97% less |
| Lines scanned on small scroll (highlights) | ~60 (already viewport) | ~60 (unchanged) | 0% (already good) |
| Lines scanned on BufEnter (embeds) | 5000 (build_descriptors) | 5000 (still full scan*) | 0% scanning, 90% less rendering |
| Image conversion processes | 20 (all via async batch) | 2-4 (on demand) | 80-90% fewer |
| Memory: image buffers | 20 converted images | 2-4 + GC | 80-90% reduction |
| Kitty protocol bandwidth | 20 placements sent | 2-4 placements sent | 80-90% reduction |

*Note: `build_descriptors()` still scans all buffer lines to build the descriptor list
(needed for scroll-triggered rendering). The savings come from not **rendering** off-screen
descriptors, not from avoiding the scan. A future optimization could defer descriptor
building to viewport ranges.

**Scrolling performance**: Unchanged for highlights (already viewport-restricted on
scroll via `opts.full=false`). For embeds, incremental rendering via
`viewport.newly_visible()` replaces the current approach of checking all unrendered
descriptors against the viewport.

**BufEnter latency**: For a 5000-line note with 50 embeds, current lazy mode renders
3 visible embeds synchronously then queues 47 more via `render_remaining_async()`.
Viewport mode renders 3-5 visible embeds and stops — no queued work, faster perceived
load. For highlights, BufEnter changes from full scan (5000 lines) to viewport scan
(~150 lines) on large files.

## Implementation Notes

### Ordering

1. **Phase 1**: `viewport.lua` module (standalone, no existing code changes)
2. **Phase 2**: Integrate into `embed.lua` — remove `render_remaining_async()`, use
   viewport for initial render range
3. **Phase 3**: Adapt embed WinScrolled handler to use `viewport.newly_visible()`
4. **Phase 4**: Add `gc_distant_placements()` for image placement cleanup
5. **Phase 5**: Change `highlight_coordinator.lua` BufEnter to use `full=false` for
   large files (low risk — all updaters already support this path)
6. **Phase 6**: Deprecate `config.embed.lazy_batch_size` and `config.embed.lazy_margin`

### Edge Cases

- **Folded lines**: `vim.fn.line("w0")` / `vim.fn.line("w$")` account for folds.
  Folded regions may cause the padded range to span more buffer lines than expected.
  This is acceptable — slightly over-rendering is better than missing content.

- **Split windows**: Multiple windows showing the same buffer. Each window has its own
  viewport range. Extmarks are shared across windows (Neovim API). Solution: render
  the union of all viewport ranges for a given buffer, or accept that the non-focused
  window may show unrendered regions until it gains focus.
  Note: `link_scan.get_visible_range()` already falls back to full buffer scan when
  `win_buf ~= bufnr` (current window doesn't show the target buffer).

- **Rapid scrolling (Page Down held)**: WinScrolled fires frequently. The debounce
  timer (80ms for embeds, 200ms for highlights) coalesces rapid scroll events. If the
  user scrolls past the padding zone before rendering completes, they briefly see
  unrendered embeds. The padding (50 lines) mitigates this for normal scroll speeds.

- **Go-to-line (`:123`)**: Large jump detected by `viewport.render_strategy()` returning
  `"full"`. Triggers viewport-scoped full render (clear + re-render viewport), not
  incremental.

- **Buffer line count changes** (insert/delete lines): `viewport.refresh()` re-queries
  `vim.fn.line()` which reflects the new layout. Embed descriptors track line numbers
  via extmark positions (Neovim adjusts extmark positions on text changes).

- **Concurrent render requests**: The existing debounce mechanism in
  `highlight_coordinator.lua` prevents concurrent renders for the same buffer. The
  embed system uses generation counters for stale-check.

### Compatibility with Existing Lazy Mode

The current `config.embed.lazy` system and the proposed viewport restriction solve
the same problem differently:

| Aspect | Lazy Mode (current) | Viewport Restriction (proposed) |
|--------|--------------------|---------------------------------|
| Off-screen embeds | Eventually rendered (16ms repeating timer, batch_size=5) | Never rendered until visible |
| Image placements | All created (via async batches) | Only visible created |
| Cleanup | None (until clear_embeds / clear_buffer_state) | Automatic GC via gc_distant_placements() |
| Scroll handling | Debounced render_in_range() for newly visible | viewport.newly_visible() for precise diff |
| Memory steady-state | All embeds in memory | Only viewport embeds rendered |
| Descriptor scan | Full buffer (build_descriptors) | Full buffer (unchanged*) |

*Descriptors are still built for the full buffer because the WinScrolled handler needs
them to know which embeds exist at any line. A future optimization could build
descriptors lazily per-range.

Migration: viewport restriction subsumes lazy mode's async batching. During transition,
both can coexist via config flags. Once viewport mode is proven stable, `lazy_batch_size`
and `lazy_margin` can be deprecated.

### Performance Measurement

Add `:VaultViewportDebug` command to expose:
- Current viewport range (first, last, padded) from `viewport.get_range()`
- Number of rendered vs total embeds (from `_embed_descriptors[bufnr].list`)
- Number of active vs total image placements (from `state.image_placements[bufnr]`)
- Extmark count in viewport vs total (via `nvim_buf_get_extmarks` with range)
- Last scroll render time
- Render strategy (incremental vs full) from `viewport.render_strategy()`

## Dependencies

- Independent of other docs in this series — can be implemented standalone
- Benefits from doc 01 (LRU Cache) if viewport tracking uses cached state
- Benefits from doc 15 (File Content Cache) — fewer embeds rendered means fewer cache
  entries needed, and cache hits are more valuable when only rendering visible embeds
- Complements doc 11 (Autocmd Event Batching) — viewport rendering reduces work per
  event, batching reduces event frequency
- Related: doc 33 (Three-Zone Viewport Prefetch) extends this with a more detailed
  viewport.lua specification including three-zone rendering. This doc (26) provides the
  foundational viewport restriction; doc 33 adds prefetch sophistication on top.
- Related: doc 56 (Highlight Viewport Rendering, completed) validated the viewport-aware
  highlight pattern that is now battle-tested in all 6 updaters

## Risk Assessment

- **Low risk**: Viewport range queries (`vim.fn.line`) are fast and well-tested
- **Low risk**: Highlight updater viewport path is already battle-tested (used on every
  scroll and text change) — BufEnter change just routes large files through same path
- **Medium risk**: Image placement GC must handle Snacks placement lifecycle correctly
  (close vs destroy, re-creation on scroll-back). Currently placements have `p:close()`
  method; need to verify it properly releases terminal resources.
- **Medium risk**: Removing `render_remaining_async()` means embeds stay unrendered
  until scrolled into view. If scroll handler has bugs, users could see missing embeds.
  Mitigated by `:VaultEmbedDebug` which already shows per-placement state.
- **Edge case risk**: Split windows showing same buffer need union-range logic
- **Regression risk**: Extmarks not rendered on initial load if viewport calculation
  is wrong — mitigated by full_buffer_threshold fallback for small files
- **Testing**: Can be validated by opening a large note, scrolling, and checking
  `:VaultViewportDebug` / `:VaultEmbedDebug` output
