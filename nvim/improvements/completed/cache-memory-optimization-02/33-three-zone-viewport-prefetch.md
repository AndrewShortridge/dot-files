# 33. Three-Zone Viewport Prefetch

## Problem

The current codebase has a split viewport strategy: `embed.lua` uses
viewport-restricted lazy rendering via `viewport.lua` (`pad_first`/`pad_last`
with `config.viewport.padding_lines = 50`), while pipeline-driven modules
(`tag_highlights.lua`, `wikilink_highlights.lua`) and standalone modules
(`task_hierarchy.lua`, `footnotes.lua`) render the full buffer or optionally
restrict to `get_visible_range()`.

This introduces **scroll pop-in** for the modules that do restrict to the
viewport. When the user scrolls (particularly fast scrolling with `<C-d>`,
`<C-u>`, or mouse wheel), newly visible lines enter the viewport undecorated.
The next render cycle (triggered by `WinScrolled` via
`highlight_coordinator.setup()` → `M.schedule()`) detects these lines and applies
decorations, but there is a perceptible delay — the coordinator debounce
(200ms for viewport-only, 30ms for full) plus module processing time — during
which raw undecorated text is visible.

The effect is most noticeable for:

- **Embed renders:** `![[Note]]` lines show raw text before virtual text
  content is computed and displayed. Embed rendering is the most expensive
  per-line operation (involves file reads via `warm_embed_cache()`, heading/
  block-id lookup). The pop-in window can be 200-500ms. Currently mitigated
  by `config.embed.lazy_scroll_debounce_ms = 80` and `padding_lines = 50`,
  but fast scrolling still outruns the padding.
- **Footnote renders:** When `opts.full = false`, footnotes only render
  references in the visible range. Definitions are always parsed full-buffer,
  but virtual text extmarks for references pop in on scroll.
- **Wikilink highlights:** Currently rendered full-buffer via the transform
  pipeline, so no pop-in. But if viewport restriction is adopted for large
  files, pop-in would appear.
- **Tag highlights:** Same as wikilinks — currently full-buffer via pipeline.
- **Task hierarchy:** Currently full-buffer via `render_completion_vtext()`.
  No pop-in, but expensive for large task trees.

The fundamental issue is that viewport restriction is reactive — it only
renders what is *currently* visible, with no anticipation of what *will be*
visible after a scroll.

## Inspiration

Zed's `crates/editor/src/inlay_hint_cache.rs` implements a `QueryRanges`
system (lines 749-754) that divides the document around the viewport into
three zones:

```rust
// Lines 749-754
#[derive(Debug, Clone)]
struct QueryRanges {
    before_visible: Vec<Range<language::Anchor>>,
    visible: Vec<Range<language::Anchor>>,
    after_visible: Vec<Range<language::Anchor>>,
}
```

With methods `is_empty()` (line 756) and `into_sorted_query_ranges()`
(line 760, concatenates all zones into a single sorted vector).

Zone computation at `determine_query_ranges()` (lines 772-838):

```rust
// Prefetch zone size = 1x the visible range length (line 786)
let excerpt_visible_len = excerpt_visible_range.end - excerpt_visible_range.start;

// After visible zone (lines 798-814)
let after_range_end_offset = after_visible_range_start
    .saturating_add(excerpt_visible_len)  // 1x visible height (line 807)
    .min(full_excerpt_range_end_offset)
    .min(buffer.len());

// Before visible zone (lines 816-831)
let before_range_start_offset = before_visible_range_end
    .saturating_sub(excerpt_visible_len)  // 1x visible height (line 825)
    .max(full_excerpt_range_start_offset);
```

Note: There is no named `prefetch_multiplier` constant in Zed — the invisible
zone size is literally `excerpt_visible_len` (1× visible length) on each side.

Key design properties from Zed's implementation:

- **Zone sizing:** Each prefetch zone equals the viewport height. One full
  "page" of content is pre-queried above and below — enough to cover a
  `<C-u>` / `<C-d>` half-page scroll without cache misses.
- **Two-phase priority:** The visible zone is fetched immediately (awaited
  before proceeding). Invisible zones (both before and after, chained
  together) are fetched after a **flat 400ms delay**
  (`INVISIBLE_RANGES_HINTS_REQUEST_DELAY_MILLIS = 400`, line 841).
  The delay timer is created immediately after visible fetches start
  (line 871) and awaited at line 898, before Phase 2 begins.
- **No scroll direction tracking:** Zed does **not** differentiate between
  before_visible and after_visible priority. Both invisible zones are chained
  and fetched equally after the same 400ms delay. This is a deliberate
  simplicity trade-off.
- **Range deduplication:** `TasksForRanges` (lines 48-52) tracks
  `sorted_ranges` of already-cached regions.
  `remove_cached_ranges_from_query()` (lines 168-229) subtracts
  already-cached ranges from new queries via gap-filling iteration, so
  only genuinely new line ranges are fetched on scroll (append strategy).
  Full re-query only happens on invalidation (edit or LSP refresh).
- **Five-case invalidation:** `invalidate_range()` (lines 231-261) handles
  non-overlap, full containment, split, left trim, and right trim — ensuring
  surgical cache updates rather than full clears.
- **Two-tier debounce:** Separate `invalidate_debounce` (from
  `inlay_hint_settings.edit_debounce_ms`) and `append_debounce` (from
  `inlay_hint_settings.scroll_debounce_ms`) durations (lines 43-44,
  274-275), chosen based on `InvalidationStrategy` (lines 64-80:
  `RefreshRequested`, `BufferEdited`, `None`). Selection logic at
  lines 407-414 in `spawn_hint_refresh`. Zero values disable
  debounce (via `debounce_value()` helper, lines 666-672).
- **Rate limiting:** `Arc<Semaphore>` with `MAX_CONCURRENT_LSP_REQUESTS = 5`
  (line 840) prevents flooding the LSP server. Visible range queries
  (where `query.invalidate.should_invalidate()` is true) bypass the
  semaphore entirely (lines 945-952). Invisible range queries acquire the
  semaphore — if no permit is available, they block until one frees, then
  check if the range has scrolled away to avoid wasted work (lines
  945-988).
- **Scroll event separation:** `SCROLL_EVENT_SEPARATION = 28ms` in
  `crates/editor/src/scroll.rs` (line 27) prevents thrashing from rapid
  scroll events. The `OngoingScroll` struct (lines 67-71, methods through
  ~127) implements axis-locked filtering with `UNLOCK_PERCENT = 1.9`
  (line 82) and `UNLOCK_LOWER_BOUND = px(6.)` (line 83) for axis
  switching. The broader `ScrollManager` struct (lines 153-169) also
  manages minimap thumb state (lines 407-444), local/remote autoscroll
  distinction (lines 157-159, for collaborative editing), per-item scroll
  position persistence to database (lines 299-317),
  `forbid_vertical_scroll` (lines 282-289, 455-461, 519-521, 533-537)
  for single-line mode, and edit prediction preview integration (lines
  594-595).
- **Two-phase task dispatch:** `new_update_task()` (lines 843-926)
  implements the actual two-phase strategy: Phase 1 queries all visible
  ranges immediately via `future::join_all()` (lines 850-869), then waits
  `INVISIBLE_RANGES_HINTS_REQUEST_DELAY_MILLIS` (400ms, delay created at
  line 871, awaited at line 898), then Phase 2 chains `before_visible` +
  `after_visible` ranges (lines 899-924). Phase 2 passes `false` to
  `fetch_and_update_hints()` (ranges already invalidated by Phase 1).
  Failed ranges are invalidated via `invalidate_range()` (lines 875-896).

## Current Codebase State

### Existing `viewport.lua`

`lua/andrew/vault/viewport.lua` (110 lines) already provides:

```lua
--- @class ViewportRange
--- @field first number    1-indexed first visible line
--- @field last number     1-indexed last visible line
--- @field pad_first number  first - padding (clamped to 1)
--- @field pad_last number   last + padding (clamped to line_count)
--- @field height number     viewport height in lines

M.get_range(winid)          -- cached viewport range
M.refresh(winid)            -- refresh + save previous for diff
M.should_cleanup(lnum, winid) -- true if line beyond cleanup_threshold
M.newly_visible(winid)      -- ranges newly visible since last refresh
```

Key features already present:
- Per-window caching (`_ranges[winid]`)
- Previous range tracking (`_prev_ranges[winid]`) for diff detection
- `newly_visible()` returns `{first, last}` ranges for newly visible sections
- Padding via `config.viewport.padding_lines = 50` (flat, not proportional)

### Existing `config.viewport`

```lua
-- config.lua lines 881-885
M.viewport = {
  padding_lines = 50,           -- Extra lines rendered beyond visible viewport edges
  cleanup_threshold = 3.0,      -- Multiplier: GC placements beyond this × viewport_height from edge
  full_buffer_threshold = 200,  -- Files with fewer lines skip viewport restriction (BufEnter uses full=true)
}
```

### Existing `config.pipeline`

```lua
-- config.lua lines 870-876
M.pipeline = {
  line_cache_max = 10000,       -- Max cached lines per buffer before eviction
  full_reparse_threshold = 100, -- Threshold for full reparse vs incremental
  content_dedup = true,         -- Skip re-tokenizing lines with unchanged text
  use_lpeg = true,              -- Use LPEG tokenizer
  batch_extmarks = true,        -- Use nvim_call_atomic for extmark operations
}
```

### Existing Architecture

- **`highlight_coordinator.lua`** (404 lines): Central dispatch hub. Registers updaters
  via `M.register()` (line 227), executes via `M.run_all()` (lines 254-286)
  which first runs `transform_pipeline.run()` for pipeline consumers,
  then dispatches to uncovered updaters (checked via
  `pipeline.is_updater_covered(name)`). Uses shared `render_arena` scopes
  and per-buffer `frame_cache` (from `frame_cache.lua`, Doc 32) for each
  `run_all()` invocation. Owns the `WinScrolled` autocmd directly in
  `M.setup()` (lines 332-342, not routed through event_dispatch). Also
  handles `VaultCacheInvalidate` user events via
  `filter_utils.should_invalidate_buffer()`. `BufDelete` cleanup (lines
  370-375) closes timers, clears frame caches, detaches pipeline.
  `M.schedule()` (lines 240-248) debounces at 30ms (full) / 200ms
  (viewport-only). `M.on_buf_write()` (lines 382-386) handles BufWritePost.
  `M.get_frame_cache()` (lines 399-401) exposes per-buffer
  frame cache. Also provides utility functions: `M.clear_extmarks()`
  (lines 25-31), `M.make_toggle()` (lines 37-52), `M.make_jump()` (lines 59-88),
  `M.cached_positions()` (lines 95-104), `M.cached_value()` (lines 112-121),
  `M.setup_buf_cleanup()` (lines 127-134), `M.make_refresh_command()` (lines
  139-144), `M.make_scanner_nav()` (lines 150-155), `M.make_scan_nav()` (lines
  164-176), `M.register_nav_keymaps()` (lines 185-196). Does **not** import
  `viewport.lua` directly — only reads `config.viewport.full_buffer_threshold`.
  **Note:** `embed.lua` does NOT register as a coordinator updater
  — it manages its own namespace (`VaultEmbed`), WinScrolled handler,
  and frame cache independently. `task_hierarchy.lua` also does NOT
  register — it uses its own `_schedule_render()` with
  `cleanup.debounce()`. `footnotes.lua` defines a `coordinated_update()`
  function (lines 489-496) but is **not currently registered** with the
  coordinator via `coordinator.register()` — it is lazy-loaded (Tier 3)
  and only has command/keymap registrations. Only `autolink.lua` (line
  414: `coordinator.register("autolink", M.coordinated_update, ..., 60)`)
  currently registers as a non-pipeline updater.
- **`transform_pipeline.lua`** (214 lines): 4-layer processing via `M.run()` (lines
  56-145): line_tracker → line_parse_cache → semantic_resolution →
  render_diff. Does NOT accept `opts.start_line`/`opts.end_line` — processes
  either dirty lines from `line_tracker.consume()` or all lines (full reparse
  when `opts.full = true`, line 68). Handles tag_highlights, wikilink_highlights,
  highlights, and inline_fields as pipeline consumers. Coverage checked via
  `M.is_updater_covered()` (line 196). Footnotes and autolink are
  NOT covered (footnotes uses `coordinated_update`, autolink uses
  substring matching). Dirty-line threshold (~100 lines, `config.pipeline.full_reparse_threshold`)
  forces full reparse when exceeded. `M.detach()` (lines 170-176) clears
  all pipeline state for a buffer.
- **`render_diff.lua`**: Extmark spec diffing via `M.apply_diff()`
  with `nvim_call_atomic()` batching (when
  `config.pipeline.batch_extmarks = true`, default). `spec_key()`
  generates unique key `{ns}:{line}:{col}:{type_tag}:{end_col}`.
  `opts_equal()` fast-compares hl_group, end_col, end_row,
  priority for extmark ID reuse. Falls back to individual pcalls on
  atomic failure. `M.invalidate(bufnr)` clears cached
  specs for buffer.
- **`event_dispatch.lua`** (246 lines): Centralized autocmd routing for TextChanged,
  TextChangedI, InsertLeave (lines 122-150), BufEnter (lines 105-112, via
  adaptive coalescer), FileType markdown, BufWritePost (lines 191-204),
  and VimLeavePre. Does **not** handle `WinScrolled` — that is owned by
  `highlight_coordinator.setup()`. Does **not** handle BufDelete/BufWipeout
  — buffer cleanup is owned by `highlight_coordinator.setup()` (lines
  370-375). Does **not** reference `viewport.lua`. Routes
  TextChanged/TextChangedI to `highlight_coordinator.schedule()`.
- **`render_arena.lua`**: Pool-based ephemeral allocation scopes with
  `begin_scope()` / `end_scope()` / `alloc_table()` / `alloc_array()`.
  Warm pool (200 tables default), max 2000. Debug validation mode wraps
  tables in use-after-free proxies.
- **`resource_cleanup.lua`** (218 lines): `cleanup.debounce(existing, delay_ms,
  callback)` (lines 47-55) — closes existing timer, creates new
  `vim.uv.new_timer()`, wraps callback in `vim.schedule_wrap()`, returns
  new timer for caller to store. Also provides `cleanup.close_timer()`
  (lines 21-29) / `cleanup.close_timer_in()` (lines 34-39),
  `cleanup.on_buf_delete()` (lines 97-103) for buffer lifecycle,
  `cleanup.repeating()` (lines 65-73) for interval timers,
  `cleanup.subscription_handle()` (lines 155-203) for vault index
  subscriptions with auto-resubscribe on vault switch.
- **`frame_cache.lua`** (Doc 32, implemented): Dual-frame render cache.
  `M.new(opts)`, `M:get(key)` (promotes from previous frame on hit),
  `M:set(key, value)`, `M:finish_frame()` (swaps current→previous),
  `M:get_stats()`. Also exports `M.copy_virt_lines()` for deep-copying
  virtual text lines. **Two independent cache pools:** coordinator
  creates `_buf_caches[bufnr]` (used by task_hierarchy via
  `get_frame_cache()`; footnotes `coordinated_update` passes
  `opts.frame_cache` but is not currently registered); embed.lua creates
  its own `_frame_caches[bufnr]` (line 23, used internally). Both are
  `FrameCache` instances with the same API.

### Module Viewport Status

| Module | Lines | Viewport Restricted? | Mechanism | Frame Cache? |
|--------|-------|---------------------|-----------|--------------|
| `embed.lua` | 1004 | Yes (when `config.embed.lazy`) | `viewport.refresh()` → `pad_first`/`pad_last` via `render_in_range()` (line 494). Own `WinScrolled` handler (lines 875-930) with `lazy_scroll_debounce_ms = 80`. **Not a coordinator updater** — manages own namespace (`VaultEmbed`), own WinScrolled, own frame cache. | Yes (own `_frame_caches` (line 23), virt_lines for note embeds via `FrameCache.copy_virt_lines()`) |
| `footnotes.lua` | 656 | Optional (`opts.full`) | `coordinated_update()` (lines 489-496) defined but **not registered** with coordinator. `render_footnotes()` (lines 339-487): if `full=true` full buffer; if `full=false` uses `get_visible_range()` (line 353). Does NOT accept `opts.start_line`/`opts.end_line`. Arena scopes for virt_lines allocation. | Yes (virt_lines deep copies, keys `bufnr:tick:ref_row:id`) |
| `tag_highlights.lua` | 118 | No | Pipeline consumer. Uses `pipeline_token_iter(bufnr, "tag")` for navigation. | No |
| `wikilink_highlights.lua` | 56 | No | Minimal pipeline consumer — toggle/setup only, rendering delegated to pipeline. | No |
| `task_hierarchy.lua` | 662 | No | **Not a coordinator updater** — uses own `_schedule_render()` (lines 169-176) with `cleanup.debounce()`. `render_completion_vtext()` (lines 106-161) does full buffer. Generation-cached tree via `filter_utils.is_cache_gen_valid()`. Triggered by TextChanged/TextChangedI via event_dispatch. | Yes (label/hl pairs, keys `bufnr:line:done:total`) |

## Design

### Three-Zone Architecture

Extend the existing `viewport.lua` with zone computation. The viewport is
divided into three contiguous zones for each window:

```
Line 0
  ...
  ┌─────────────────────────┐
  │   prefetch_above zone   │  height = viewport_height * multiplier
  │   (delayed render)      │
  ├─────────────────────────┤  ← viewport.first (vim.fn.line('w0'))
  │                         │
  │   visible zone          │  height = viewport_height
  │   (immediate render)    │
  │                         │
  ├─────────────────────────┤  ← viewport.last (vim.fn.line('w$'))
  │   prefetch_below zone   │  height = viewport_height * multiplier
  │   (delayed render)      │
  └─────────────────────────┘
  ...
Line N (end of buffer)
```

### Zone Computation

Add to existing `viewport.lua`:

```lua
--- @class ViewportZones
--- @field above { start_line: number, end_line: number }
--- @field visible { start_line: number, end_line: number }
--- @field below { start_line: number, end_line: number }
--- @field viewport_height number
--- @field prefetch_size number

--- Compute three zones around the current viewport.
--- Extends the existing get_range() with proportional prefetch zones.
--- @param winid? number
--- @return ViewportZones
function M.get_zones(winid)
  local range = M.refresh(winid)  -- reuse existing refresh logic
  winid = winid or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local buf_line_count = vim.api.nvim_buf_line_count(bufnr)
  local multiplier = config.viewport.prefetch_multiplier
  local prefetch_size = math.floor(range.height * multiplier)

  return {
    above = {
      start_line = math.max(1, range.first - prefetch_size),
      end_line = math.max(0, range.first - 1),
    },
    visible = {
      start_line = range.first,
      end_line = range.last,
    },
    below = {
      start_line = math.min(buf_line_count + 1, range.last + 1),
      end_line = math.min(buf_line_count, range.last + prefetch_size),
    },
    viewport_height = range.height,
    prefetch_size = prefetch_size,
  }
end

--- Classify a line into its zone.
--- @param line number 1-indexed line number
--- @param zones ViewportZones
--- @return "visible"|"above"|"below"|nil
function M.in_zone(line, zones)
  if line >= zones.visible.start_line and line <= zones.visible.end_line then
    return "visible"
  elseif line >= zones.above.start_line and line <= zones.above.end_line then
    return "above"
  elseif line >= zones.below.start_line and line <= zones.below.end_line then
    return "below"
  end
  return nil
end

--- Get the full range spanning all three zones.
--- @param zones ViewportZones
--- @return number first, number last
function M.get_full_range(zones)
  return zones.above.start_line, zones.below.end_line
end
```

### Two-Phase Render Dispatch

Following Zed's approach (visible immediately, invisible after flat delay),
**without** scroll direction tracking (matching Zed's deliberate simplicity):

| Phase | Zone | Debounce | Trigger |
|-------|------|----------|---------|
| 1 (immediate) | `visible` | Coordinator's standard (30ms full / 200ms viewport) | `WinScrolled`, `TextChanged` |
| 2 (delayed) | `above` + `below` | `config.viewport.prefetch_debounce_ms` (400ms) | `WinScrolled` only |

Both prefetch zones use the same delay. This matches Zed's design and avoids
the complexity of scroll direction tracking, which provides marginal benefit
given that the prefetch delay (400ms) is already long enough for most scroll
events to coalesce.

### Prefetch Scheduler

Add to `viewport.lua`:

```lua
local cleanup = require("andrew.vault.resource_cleanup")

--- @type table<string, uv.uv_timer_t> "bufnr:winid:zone" → timer
local _prefetch_timers = {}

--- Schedule a prefetch callback with debounce.
--- Uses cleanup.debounce() for consistent timer management.
--- @param bufnr number
--- @param winid number
--- @param zone_name "above"|"below"
--- @param callback fun()
function M.schedule_prefetch(bufnr, winid, zone_name, callback)
  local key = bufnr .. ":" .. winid .. ":" .. zone_name
  local debounce_ms = config.viewport.prefetch_debounce_ms

  _prefetch_timers[key] = cleanup.debounce(_prefetch_timers[key], debounce_ms, function()
    _prefetch_timers[key] = nil
    if vim.api.nvim_buf_is_valid(bufnr)
      and vim.api.nvim_win_is_valid(winid) then
      callback()
    end
  end)
end

--- Cancel all prefetch timers for a buffer (or buffer+window).
--- @param bufnr number
--- @param winid? number
function M.cancel_prefetch(bufnr, winid)
  local prefix = tostring(bufnr) .. ":"
  if winid then prefix = prefix .. winid .. ":" end
  for key, timer in pairs(_prefetch_timers) do
    if key:sub(1, #prefix) == prefix then
      cleanup.close_timer(timer)
      _prefetch_timers[key] = nil
    end
  end
end
```

### Zone Stability (Range Deduplication)

Following Zed's `remove_cached_ranges_from_query()` pattern, track which
ranges have already been prefetched to avoid redundant work:

```lua
--- @type table<string, ViewportZones> "bufnr:winid" → last prefetched zones
local _prefetched_zones = {}

--- Check which prefetch zones have changed since last prefetch.
--- Returns flags indicating whether each zone needs re-rendering.
--- @param bufnr number
--- @param winid number
--- @param new_zones ViewportZones
--- @return boolean above_changed, boolean below_changed
function M.prefetch_zones_changed(bufnr, winid, new_zones)
  local key = bufnr .. ":" .. winid
  local old = _prefetched_zones[key]
  _prefetched_zones[key] = new_zones

  if not old then return true, true end
  local above_changed = old.above.start_line ~= new_zones.above.start_line
    or old.above.end_line ~= new_zones.above.end_line
  local below_changed = old.below.start_line ~= new_zones.below.start_line
    or old.below.end_line ~= new_zones.below.end_line
  return above_changed, below_changed
end
```

If the viewport has not moved since the last prefetch (same zone boundaries),
prefetch zones are not re-rendered. This avoids redundant work during typing
(where `TextChanged` fires but the viewport is stable). The visible zone is
still re-rendered because content may have changed.

## Target Modules

Modules ranked by prefetch benefit, accounting for current viewport status:

1. **`embed.lua`** — **Highest benefit.** Already viewport-restricted via
   `config.embed.lazy`. Currently uses flat `padding_lines = 50` which is
   insufficient for fast scrolling. Proportional prefetch (1× viewport
   height) adapts to window size. Embed content extraction (`warm_embed_cache`,
   `render_single_embed`) is the most expensive per-line operation. The
   existing `render_in_range(descs, ctx, top, bot)` (lines 372-387)
   already accepts line range parameters. **Note:** embed is NOT a
   coordinator updater — it manages its own lifecycle (namespace, scroll
   handler, frame cache). Prefetch dispatch must either register embed
   with the coordinator or call `embed.on_prefetch()` directly.

2. **`footnotes.lua`** (656 lines) — **Moderate benefit.** Already has
   optional viewport restriction (`opts.full = false` uses
   `get_visible_range()` in `render_footnotes()`, line 353). The
   `coordinated_update()` (lines 489-496) entry point is defined but
   **not currently registered** with the coordinator — footnotes is
   lazy-loaded (Tier 3) with only command/keymap registrations. To
   participate in prefetch, footnotes must first be registered via
   `coordinator.register("footnotes", ...)`, then `render_footnotes()`
   (lines 339-487) extended to accept zone ranges via `opts.start_line`
   / `opts.end_line` (currently not supported — only accepts `silent`,
   `full`, `bufnr`, `arena`, `frame_cache`). Uses
   `pipeline_token_iter(bufnr, "footnote")` to locate references.
   Definition parsing remains full-buffer (definitions may be off-screen),
   but reference rendering benefits from prefetch (lines 450-452 filter
   refs by range). Already uses arena scopes for virt_lines allocation
   (lines 374-375, 396) and frame cache for rendered output (cache
   lookup at lines 383-394, storage at lines 432-435, keys
   `bufnr:tick:ref_row:id`).

3. **`tag_highlights.lua`** — **Lower benefit for current architecture.** Uses
   `line_parse_cache.pipeline_token_iter()` which processes the full buffer
   through the transform pipeline. Viewport restriction would require the
   pipeline itself to become zone-aware (Layer 1 parse cache already has
   viewport-aware LRU eviction). The module is fast (pipeline-cached tokens),
   so pop-in is unlikely even without prefetch.

4. **`wikilink_highlights.lua`** — **Same as tag_highlights.** Thin wrapper
   delegating to the transform pipeline. No standalone rendering logic to
   zone-restrict.

5. **`task_hierarchy.lua`** (662 lines) — **Lower benefit.** NOT a
   coordinator updater — uses own `_schedule_render()` (lines 169-176)
   with `cleanup.debounce()`. `render_completion_vtext()` (lines 106-161)
   does full-buffer clear (line 111: `nvim_buf_clear_namespace` with
   0, -1) and re-render. Generation-cached tree building with
   `filter_utils.is_cache_gen_valid()` (line 127). Debounced at
   `config.hierarchy.debounce_ms`. Has per-buffer frame caches (lines
   29-35) for label/hl pairs (cache at lines 141-150, keys
   `bufnr:line:done:total`). Task trees are typically not viewport-dense
   enough for noticeable pop-in.

### Pipeline Modules (tag_highlights, wikilink_highlights)

These modules flow through `transform_pipeline.lua`:

```
line_tracker (dirty lines) → line_parse_cache (tokens) → semantic_resolution → render_diff
```

Zone-awareness for pipeline modules requires changes at the **pipeline layer**,
not individual modules. The pipeline would need to:

1. Accept a line range in `pipeline.run(bufnr, code_excl, opts)` via
   `opts.start_line` / `opts.end_line`
2. Have `line_tracker` filter dirty lines to the range
3. Have `render_diff` scope `nvim_call_atomic()` operations to the range

This is a larger architectural change than zone-dispatching standalone
modules. Consider deferring pipeline zone-awareness to a separate doc.

## Implementation Steps

### Step 1: Extend Existing `viewport.lua`

File: `lua/andrew/vault/viewport.lua` (extend, not replace)

Add `get_zones()`, `in_zone()`, `get_full_range()`, `schedule_prefetch()`,
`cancel_prefetch()`, and `prefetch_zones_changed()` as described in the
Design section above. These build on the existing `M.refresh()` and
`_ranges`/`_prev_ranges` infrastructure.

Update `M.clear_state()` (which currently does not exist in viewport.lua —
cleanup is handled by per-window cache expiry) to also clear
`_prefetched_zones` and cancel prefetch timers:

```lua
function M.clear_state(bufnr, winid)
  M.cancel_prefetch(bufnr, winid)
  if winid then
    local key = bufnr .. ":" .. winid
    _prefetched_zones[key] = nil
    _ranges[winid] = nil
    _prev_ranges[winid] = nil
  else
    -- Clear all windows for this buffer
    for k, _ in pairs(_prefetched_zones) do
      if k:match("^" .. bufnr .. ":") then
        _prefetched_zones[k] = nil
      end
    end
  end
end
```

### Step 2: Update `config.viewport`

Extend the existing config section (do not replace existing fields):

```lua
M.viewport = {
  padding_lines = 50,           -- (existing) Extra lines for embed lazy rendering
  cleanup_threshold = 3.0,      -- (existing) GC threshold multiplier
  full_buffer_threshold = 200,  -- (existing) Small-file full-render threshold

  -- NEW: Three-zone prefetch settings
  prefetch_multiplier = 1.0,    -- Prefetch zone size as viewport height multiple
  prefetch_debounce_ms = 400,   -- Delay before prefetch zone rendering (matches Zed)
}
```

Note: `padding_lines` is retained for embed.lua's existing lazy rendering
path. The prefetch system uses proportional `prefetch_multiplier` instead.
Embed.lua should migrate from `padding_lines` to `get_zones()` as part of
this work, at which point `padding_lines` becomes deprecated.

### Step 3: Modify `highlight_coordinator.lua`

The coordinator already handles `WinScrolled` directly in `M.setup()`
(lines 332-342) via `M.schedule(bufnr, { full = false })`. Note:
`WinScrolled` is **not** routed through `event_dispatch.lua` — the
coordinator owns this autocmd directly. Add zone-aware prefetch dispatch
to the existing handler:

```lua
local viewport = require("andrew.vault.viewport")

--- Current WinScrolled handler (highlight_coordinator.lua M.setup(), lines 332-342):
vim.api.nvim_create_autocmd("WinScrolled", {
  group = _augroup,
  callback = function()
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].filetype == "markdown"
      and engine.is_vault_path(vim.api.nvim_buf_get_name(bufnr))
    then
      -- Phase 1: Visible zone (existing behavior, 200ms debounce)
      M.schedule(bufnr, { full = false })

      -- Phase 2: Prefetch zones (new, 400ms debounce)
      local winid = vim.api.nvim_get_current_win()
      local zones = viewport.get_zones(winid)
      local above_changed, below_changed =
        viewport.prefetch_zones_changed(bufnr, winid, zones)

      if above_changed and zones.above.end_line >= zones.above.start_line then
        viewport.schedule_prefetch(bufnr, winid, "above", function()
          M.run_prefetch(bufnr, zones.above.start_line, zones.above.end_line)
        end)
      end

      if below_changed and zones.below.end_line >= zones.below.start_line then
        viewport.schedule_prefetch(bufnr, winid, "below", function()
          M.run_prefetch(bufnr, zones.below.start_line, zones.below.end_line)
        end)
      end
    end
  end,
})
```

Add `M.run_prefetch()` — a lighter version of `M.run_all()` that only
processes modules with prefetch support. Following the existing
`run_all()` pattern (lines 254-286), it uses arena scopes and frame cache:

```lua
--- Run prefetch rendering for a line range.
--- Only dispatches to modules that support range-based rendering.
--- Follows run_all() pattern: arena scope + frame_cache for consistency.
--- @param bufnr number
--- @param start_line number 1-indexed
--- @param end_line number 1-indexed
function M.run_prefetch(bufnr, start_line, end_line)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local stop = require("andrew.vault.memory_profiler").start_timer("hl_coord.run_prefetch")

  local arena_scope = render_arena.begin_scope()
  local fc = get_cache(bufnr)  -- per-buffer frame cache (via FrameCache.buf_get at line 216)

  local ok, err = pcall(function()
    -- Dispatch to prefetch-capable modules (skip pipeline-covered updaters)
    for _, updater in ipairs(_updaters) do
      if updater.enabled() and updater.supports_prefetch
        and not pipeline.is_updater_covered(updater.name) then
        local ok2, err2 = pcall(updater.fn, bufnr, nil, {
          full = false,
          prefetch = true,
          start_line = start_line,
          end_line = end_line,
          arena = arena_scope,
          frame_cache = fc,
        })
        if not ok2 then
          log.warn("prefetch error in %s: %s", updater.name, err2)
        end
      end
    end
  end)

  render_arena.end_scope(arena_scope)
  stop()
  if not ok then log.warn("run_prefetch failed: %s", err) end
end
```

Note: `run_prefetch()` does **not** call `pipeline.run()` or
`fc:finish_frame()`. Pipeline modules (tag_highlights, wikilink_highlights)
are not prefetch-capable. Frame cache entries are populated incrementally
by prefetch-capable modules (footnotes) and read back during subsequent
`run_all()` visible-zone renders.

**Important architectural note:** `embed.lua` currently does NOT register
as a coordinator updater and manages its own lifecycle (own namespace
`VaultEmbed`, own WinScrolled handler, own `_frame_caches` table). This
means `run_prefetch()` as written above would NOT dispatch to embed.lua
through the `_updaters` loop. Two approaches to resolve this:

1. **Register embed as an updater** (architectural change): Add
   `coordinator.register("embed", M.coordinated_update, ...)` to embed.lua
   and remove its standalone WinScrolled handler. This unifies the
   dispatch model but requires embed to accept the coordinator's
   `(bufnr, code_excl, opts)` interface.
2. **Direct embed prefetch call** (minimal change): Have `run_prefetch()`
   directly call `embed.on_prefetch(bufnr, start_line, end_line)` as a
   special case alongside the updater loop, keeping embed's independent
   lifecycle intact. This preserves embed's own frame cache.

Similarly, `task_hierarchy.lua` manages its own lifecycle via
`_schedule_render()`. It is not initially a prefetch target (see Target
Modules ranking), so this does not affect the initial implementation.

### Step 4: Migrate `embed.lua` to Zone-Based Prefetch

`embed.lua` (1004 lines) is the primary beneficiary. Replace the flat
`padding_lines` approach with zone-based rendering:

```lua
-- Current (embed.lua render_embeds, lines 490-494 within M.render_embeds lines 435-535):
if config.embed.lazy then
  local vp = viewport.refresh()
  render_in_range(descs, ctx, vp.pad_first, vp.pad_last)
end

-- New: Use get_zones() for visible range, prefetch for off-screen
if config.embed.lazy then
  local zones = viewport.get_zones()
  render_in_range(descs, ctx, zones.visible.start_line, zones.visible.end_line)
end
```

Register embed as a prefetch-capable updater (or handle via a dedicated
prefetch callback in the coordinator):

```lua
-- embed.lua on_prefetch (called by coordinator for prefetch zones)
function M.on_prefetch(bufnr, start_line, end_line)
  if not config.embed.lazy then return end
  if not state.is_embed_active(bufnr) then return end  -- uses is_embed_active (embed_state.lua:74), not is_rendering
  local ds = state._embed_descriptors[bufnr]
  if not ds then return end
  local descs = ds.list
  local ctx = build_render_ctx(bufnr, ...)  -- build_render_ctx at lines 115-143, includes frame_cache from get_frame_cache(bufnr) at line 141
  render_in_range(descs, ctx, start_line, end_line)  -- render_in_range at lines 372-387
end
```

Note: The guard uses `state.is_embed_active(bufnr)` (embed_state.lua:74)
which checks both `embeds_visible` and buffer validity. The module does
not have a `state.is_rendering` field. There is no `build_descriptors_cached`
function — descriptors are stored in `state._embed_descriptors[bufnr].list`
after being built by `build_descriptors()` (lines 163-191) during
`render_embeds()`.

The existing `render_in_range(descs, ctx, top, bot)` (lines 372-387)
already filters descriptors by `d.lnum >= top and d.lnum <= bot`, so it
works with zone ranges without modification. Frame cache integration is
already present — `render_single_embed()` (lines 246-370, frame cache
lookup at line 253) checks `ctx.frame_cache:get(cache_key)` before
doing expensive content extraction, so prefetched embeds benefit from
cache hits when they later enter the visible zone. Frame cache storage
uses `FrameCache.copy_virt_lines()` (line 363) for deep copying
before arena recycles tables.

### Step 5: Update `embed.lua` WinScrolled Handler

The existing WinScrolled handler in embed.lua (lines 875-930) uses its own
debounce (`config.embed.lazy_scroll_debounce_ms = 80`). This should be
unified with the coordinator's zone dispatch:

```lua
-- Current embed.lua WinScrolled handler (lines 875-930):
-- viewport.refresh() (line 884) → newly_visible() (line 885) →
-- check unrendered embeds in new ranges (lines 891-900) →
-- debounced render_in_range() with vp.pad_first/pad_last (line 923) →
-- gc_distant_placements() (line 927)

-- New: Let coordinator handle WinScrolled dispatch entirely.
-- Remove embed's standalone WinScrolled autocmd (lines 875-930).
-- Embed renders visible zone via coordinator's M.schedule() (Phase 1)
-- and prefetch zones via coordinator's M.run_prefetch() (Phase 2).
-- Retain gc_distant_placements() call — can be triggered from
-- coordinator's run_all() or a post-render hook.
```

This eliminates the dual-dispatch problem where both the coordinator and
embed have independent WinScrolled handlers with different debounce timings.

### Step 6: Handle Zone Overlap with Extmark Namespaces

Zones are strictly non-overlapping by construction:

```lua
-- By definition from get_zones():
-- above.end_line = visible.start_line - 1
-- below.start_line = visible.end_line + 1
assert(zones.above.end_line < zones.visible.start_line)
assert(zones.visible.end_line < zones.below.start_line)
```

Modules that use `nvim_buf_clear_namespace` with line ranges (embed,
footnotes) must scope clearing to the zone being rendered, not the full
buffer. The existing `render_diff.lua` already diffs against previous specs
and uses scoped `nvim_buf_set_extmark` / `nvim_buf_del_extmark`, which
naturally avoids cross-zone interference.

When the viewport scrolls, previously-prefetched lines that move into the
visible zone retain their extmarks. The render_diff module's spec diffing
prevents redundant re-application. For embed.lua, the existing generation
tracking (`check_generation()`, lines 385-395) and descriptor `d.rendered`
flag prevent re-rendering already-rendered embeds.

### Step 7: Cleanup Integration

Add `viewport.clear_state()` to the existing BufDelete handler in
`highlight_coordinator.setup()` (lines 370-375). Note: embed.lua has its
own BufDelete handler (lines 932-935) via `cleanup.on_buf_delete()` which
calls `state.clear_buffer_state()` and clears `_frame_caches[bufnr]`.

```lua
-- highlight_coordinator.lua M.setup() BufDelete handler (lines 370-375):
cleanup.on_buf_delete(_augroup, function(bufnr)
  cleanup.close_timer_in(_timers, bufnr)
  _buf_caches[bufnr] = nil
  local pipeline = require("andrew.vault.transform_pipeline")
  pipeline.detach(bufnr)
  viewport.clear_state(bufnr)  -- NEW: cancel prefetch timers + clear zone state
end)
```

Note: The current handler lazy-requires `transform_pipeline` inside the
callback (not at module level), so the `require` call is preserved.

Also add `viewport.clear_state()` to `M.teardown()` (lines 389-394)
for VimLeavePre cleanup. No changes needed in `event_dispatch.lua`
(246 lines) — it does not handle WinScrolled or BufDelete; both are
owned by the coordinator.

## API

```lua
local viewport = require("andrew.vault.viewport")

-- Existing API (unchanged):
local range = viewport.get_range(winid)    -- { first, last, pad_first, pad_last, height }
local range = viewport.refresh(winid)      -- refresh + save previous
local gc = viewport.should_cleanup(lnum)   -- true if beyond cleanup_threshold
local new = viewport.newly_visible(winid)  -- newly visible range(s) since last refresh

-- New API:
local zones = viewport.get_zones(winid)
-- zones.above   = { start_line = N, end_line = N }
-- zones.visible = { start_line = N, end_line = N }
-- zones.below   = { start_line = N, end_line = N }
-- zones.viewport_height = N
-- zones.prefetch_size   = N

local zone = viewport.in_zone(42, zones)   -- "visible" | "above" | "below" | nil
local first, last = viewport.get_full_range(zones)

-- Schedule prefetch with debounce (400ms default, flat for both zones)
viewport.schedule_prefetch(bufnr, winid, "below", function()
  render_module(bufnr, zones.below.start_line, zones.below.end_line)
end)

-- Check if zones changed since last prefetch (skip redundant work)
local above_chg, below_chg = viewport.prefetch_zones_changed(bufnr, winid, zones)

-- Cleanup
viewport.cancel_prefetch(bufnr, winid)
viewport.clear_state(bufnr, winid)
viewport.clear_state(bufnr)  -- all windows for buffer
```

## Configuration

Extend existing `lua/andrew/vault/config.lua` `M.viewport` section:

```lua
M.viewport = {
  -- (existing)
  padding_lines = 50,           -- DEPRECATED: use prefetch_multiplier instead
  cleanup_threshold = 3.0,      -- GC placements beyond this × viewport_height
  full_buffer_threshold = 200,  -- Files ≤200 lines use full rendering

  -- (new)
  prefetch_multiplier = 1.0,    -- Prefetch zone size as viewport height multiple
                                -- 1.0 = one full viewport above/below (covers <C-d>/<C-u>)
                                -- 0.5 = half viewport (less work, some fast-scroll pop-in)
                                -- 2.0 = two viewports (very smooth, more CPU/memory)

  prefetch_debounce_ms = 400,   -- Delay before prefetch zone rendering (ms)
                                -- Matches Zed's INVISIBLE_RANGES_HINTS_REQUEST_DELAY_MILLIS
                                -- Both zones use the same delay (no direction differentiation)
}
```

## Integration with Current Architecture

### Relationship to `viewport.lua` (Existing)

Doc 33 **extends** the existing `viewport.lua` rather than replacing it:

- `get_range()` / `refresh()` / `newly_visible()` / `should_cleanup()`
  remain unchanged and continue to serve embed.lua's existing lazy
  rendering path during migration.
- `get_zones()` builds on `refresh()` output, adding proportional prefetch
  zones.
- `schedule_prefetch()` uses `resource_cleanup.debounce()` for consistent
  timer lifecycle management.

### Relationship to `highlight_coordinator.lua`

The coordinator (404 lines) already owns the `WinScrolled` → `schedule()`
dispatch path directly in `M.setup()` (lines 332-342). `run_all()` (lines
254-286) uses shared arena scopes, per-buffer frame cache (`get_cache(bufnr)`,
lines 215-217), and `pipeline.is_updater_covered()` to avoid double-dispatching
pipeline consumers. The coordinator currently does **not** import `viewport.lua`
directly — it only reads `config.viewport.full_buffer_threshold`. Doc 33 adds
a `viewport` require and a second phase to the WinScrolled path:

1. **Phase 1 (existing):** `M.schedule(bufnr, { full = false })` (lines 240-248) →
   `M.run_all()` (lines 254-286) → `transform_pipeline.run()` + uncovered updater
   dispatch (with `opts.arena` and `opts.frame_cache`). Debounce: 200ms.
   Currently only `autolink` is registered as an uncovered updater (line 414
   in autolink.lua); `footnotes.coordinated_update()` (lines 489-496) exists
   but is not registered.
2. **Phase 2 (new):** `viewport.schedule_prefetch()` → `M.run_prefetch()`
   → prefetch-capable updaters + direct `embed.on_prefetch()` call (since
   embed is not a registered updater). Arena scope + frame cache for
   consistency with `run_all()`. Debounce: 400ms.

**Note:** Since embed.lua manages its own frame cache (`_frame_caches`,
line 23) independently from the coordinator's `_buf_caches` (line 213), `run_prefetch()`
should either: (a) call `embed.on_prefetch()` directly and let embed use
its own cache, or (b) first register embed as a coordinator updater to
unify the cache model (see Step 3 architectural note).

The existing `BufDelete` cleanup in `M.setup()` (lines 370-375) should
be extended to call `viewport.clear_state(bufnr)` alongside the existing
`cleanup.close_timer_in()` and `pipeline.detach()` calls. Embed.lua has
its own BufDelete handler (lines 932-935) which clears `_frame_caches[bufnr]`
independently.

### Relationship to `transform_pipeline.lua`

Pipeline modules (tag_highlights, wikilink_highlights, highlights,
inline_fields — as reported by `pipeline.is_updater_covered()`) are
**not** initially zone-aware. They continue to process the full buffer
through the pipeline's 4-layer architecture (214 lines). `M.run()` (lines
56-145) does not accept `opts.start_line`/`opts.end_line` — it processes
dirty lines or all lines. Footnotes and autolink are NOT covered by the
pipeline — they have special handling. Zone-restricting the pipeline is
a separate concern:

- `line_parse_cache.lua` already has viewport-aware LRU eviction (evicts
  lines furthest from visible center when cache exceeds max size).
- `render_diff.lua` already diffs extmark specs by unique key
  to avoid redundant API calls. Batches via `nvim_call_atomic()`.
- Dirty-line threshold (~100 lines) forces full reparse when exceeded,
  avoiding N × `buf_get_lines` calls.
- These existing optimizations provide partial zone-like behavior without
  explicit zone dispatch.

Full pipeline zone-awareness (restricting `line_tracker` dirty lines and
`render_diff` scope to zones) is deferred to a future doc.

### Relationship to `event_dispatch.lua`

Event dispatch (246 lines) does **not** handle `WinScrolled` — that
autocmd is owned directly by `highlight_coordinator.setup()` (lines
332-342). Event dispatch handles TextChanged/TextChangedI/InsertLeave
(lines 122-150) → `highlight_coordinator.schedule()` + `task_hierarchy`
+ `embed` triggers (routing at lines 135-148), BufEnter (lines 105-112,
via adaptive coalescer), FileType markdown (lines 158-184), BufWritePost
(lines 191-204) → `highlight_coordinator.on_buf_write()`, and VimLeavePre
teardown (lines 212-235). Event dispatch does **not** handle
BufDelete/BufWipeout and does **not** reference `viewport.lua`. The
coordinator's `setup()` WinScrolled handler gains the prefetch dispatch.
No changes needed in `event_dispatch.lua` — BufDelete cleanup is already
owned by the coordinator (lines 370-375) and embed.lua (lines 932-935).

### Relationship to `render_arena.lua` and `render_diff.lua`

Prefetch renders use arena scopes for ephemeral allocation, matching the
existing `run_all()` pattern. The arena's pool-based allocation (warm pool
of 200 tables, max 2000) ensures prefetch renders don't cause allocation
pressure. `alloc_table()` and `alloc_array()` are both available within
scope.

`render_diff.lua`'s atomic batching (via `nvim_call_atomic()` when
`config.pipeline.batch_extmarks = true`, default) works at per-line
granularity and is zone-agnostic — it handles whatever extmark specs are
produced. Diffing by unique key (`{ns}:{line}:{col}:{type}:{end_col}`)
means prefetch-produced extmarks on unchanged lines are not re-applied.

### Relationship to `embed.lua` Lazy Rendering

Embed.lua's current lazy rendering path (1004 lines) uses:
- `viewport.refresh()` → `pad_first` / `pad_last` (flat padding, lines 493-494)
- Its own `WinScrolled` autocmd (lines 875-930) with `lazy_scroll_debounce_ms = 80`
- `viewport.newly_visible()` (line 885) to detect newly visible ranges
- `viewport.get_range()` (line 915) in debounced callback for current padded range
- `render_in_range(descs, ctx, top, bot)` (lines 372-387) for scoped rendering
- `gc_distant_placements()` (lines 405-430) for off-screen image cleanup
- `check_generation()` (lines 394-399) to detect stale descriptor state
- Frame cache integration: `render_single_embed()` (lines 246-370, cache
  lookup at line 253) checks `ctx.frame_cache:get(cache_key)` before
  expensive content extraction
- Own `_frame_caches` table (line 23) with `get_frame_cache(bufnr)` (lines
  25-27) — independent from coordinator's `_buf_caches` (line 213). Uses
  deep-copied virt_lines via `FrameCache.copy_virt_lines()` (line 363)
  because arena tables are recycled. Calls `fc:finish_frame()` after full
  render (line 527).
- Guard via `state.is_embed_active(bufnr)` (line 911) — NOT
  `state.is_rendering` (which does not exist)
- Own BufDelete handler (lines 932-935) clears buffer state and `_frame_caches[bufnr]`

**Architectural note:** Embed does NOT register with
`highlight_coordinator.register()`. It is entirely self-managed: own
namespace (`VaultEmbed`), own WinScrolled handler (lines 875-930), own
frame cache (`_frame_caches`, line 23), own BufDelete handler (lines
932-935), own `render_embeds()` (lines 435-535) / `render_in_range()`
(lines 372-387) dispatch. This means coordinator's `run_all()` (lines
254-286) never touches embed — it is not in the `_updaters` list and is
not a pipeline consumer. Similarly, `footnotes.lua` has
`coordinated_update()` defined (lines 489-496) but is not registered
with the coordinator — it must be registered before it can participate in
prefetch dispatch.

Migration to zones:
1. Replace `pad_first`/`pad_last` with `get_zones().visible` for initial render
2. Remove embed's standalone `WinScrolled` handler (lines 875-930)
3. Either register embed as a coordinator updater (unifying lifecycle) OR
   have the coordinator call `embed.on_prefetch()` directly as a special
   case (preserving embed's independent model)
4. Retain `gc_distant_placements()` (lines 405-430, uses `should_cleanup()`, independent of zones)
5. Frame cache synergy: prefetch renders populate the cache (via
   `FrameCache.copy_virt_lines()`, line 363), visible-zone renders get
   cache hits (line 253) — no re-extraction needed
6. If embed remains independent, its own `_frame_caches` (line 23) serves
   the prefetch→visible cache warming path without changes

### Relationship to Doc 32 (Dual-Frame Render Cache) — Implemented

The frame cache (Doc 32) is **already implemented** and integrated into
embed.lua, footnotes.lua, and task_hierarchy.lua. The three-zone system
and frame cache are complementary:

- **Current state (frame cache active, no prefetch):** Frame cache stores
  rendered virt_lines/labels per buffer. Cache hits avoid expensive content
  extraction (embed file reads, footnote definition parsing). However,
  cache entries are only populated for lines that have been rendered in a
  previous render cycle — off-screen lines have no cache entries.
- **Two independent frame cache pools:** The coordinator manages
  `_buf_caches[bufnr]` (line 213, used by task_hierarchy via
  `opts.frame_cache`; footnotes has the interface but is not registered).
  Embed manages its own `_frame_caches[bufnr]` (line 23, used internally
  by `render_single_embed()`). Both use the same
  `FrameCache` class from `frame_cache.lua` with the same dual-frame
  `get()`/`set()`/`finish_frame()` API.
- **With three-zone prefetch:** Prefetch zone renders populate frame cache
  entries for off-screen lines. When those lines later enter the visible
  zone, the next render gets cache hits and skips the entire render
  function. This is the key synergy — prefetch does the expensive work
  once, frame cache makes the visible-zone render nearly free. For embed,
  this works naturally through its own `_frame_caches` (line 23) regardless
  of whether prefetch is dispatched by the coordinator or called directly.
- The coordinator's `run_all()` (lines 254-286) already passes
  `opts.frame_cache` to updaters. `run_prefetch()` follows the same
  pattern for coordinator-managed updaters. Embed's prefetch path uses
  its own cache.

## Expected Impact

### Scroll Pop-in Reduction

| Scenario                 | Current state | After doc 33 |
|--------------------------|---------------|--------------|
| `<C-d>` half-page down  | 80-200ms (embed lazy + padding) | 0ms (prefetched) |
| `<C-u>` half-page up    | 80-200ms (embed lazy + padding) | 0ms (prefetched) |
| `j` / `k` line scroll   | 0-50ms (padding covers) | 0ms |
| `<C-f>` full-page down  | 100-300ms pop-in | 0-50ms (partial hit) |
| `gg` / `G` jump to edge | 200-500ms pop-in | 200-500ms (no help) |
| Mouse wheel (fast)       | 80-200ms pop-in | 0-100ms |

Jumps to distant positions (`gg`, `G`, `:N`, search `/`) are not improved
because the destination is unpredictable. These are handled by the standard
visible-zone render on arrival. The existing `render_strategy()` returns
`"full"` for large jumps (> 2× viewport), which triggers `M.schedule(bufnr,
{ full = true })` with 30ms debounce.

### CPU Usage

Prefetch zones add render work only for prefetch-capable modules (initially
just embed.lua). Pipeline modules continue at full-buffer scope.

- Prefetch renders are debounced at 400ms, so rapid scrolling coalesces.
- `render_diff.lua` spec diffing prevents redundant extmark API calls.
- `render_arena.lua` scopes prevent ephemeral allocation leaks.
- Zone deduplication (`prefetch_zones_changed()`) skips unchanged zones.

Net CPU increase during scrolling: estimated 10-25% over current baseline
(lower than original estimate because only embed.lua initially participates,
and pipeline modules are unchanged).

### Memory

Prefetch zones increase active extmarks for embed.lua by up to 3× compared to
visible-only rendering. For a typical 50-line viewport with
`prefetch_multiplier = 1.0`:

- Current (visible + 50 padding): ~100 lines of embed extmarks
- Three-zone: ~150 lines of embed extmarks

Pipeline module extmarks (tags, wikilinks) are unchanged (already full-buffer).
`render_diff.lua` bounds extmark churn via spec diffing.

### Perceived Responsiveness

The primary goal is eliminating visible rendering artifacts during normal
scrolling for embed-heavy notes. Users should perceive embed content as
"always present" rather than "appearing after scroll." This is the most
impactful UX improvement for notes with dense `![[...]]` transclusions.
