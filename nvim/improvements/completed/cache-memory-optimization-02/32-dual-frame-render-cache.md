# 32. Dual-Frame Render Cache

## Problem

The vault plugin's rendering architecture has evolved significantly since this
document was first drafted. A three-layer **transform pipeline** now handles
most highlight modules:

- **Layer 1 — Line Parse Cache** (`line_parse_cache.lua`): LPEG tokenizer with
  per-line caching and changedtick validation. Skips re-tokenization when line
  text is unchanged (content dedup via string interning).
- **Layer 2 — Semantic Resolution** (`semantic_resolution.lua`): Resolves
  tokens against vault index with generation-based staleness detection.
- **Layer 3 — Render Diff** (`render_diff.lua`): Diffs new extmark specs
  against `_prev_specs[bufnr]` and batches only changed extmarks via
  `nvim_call_atomic`.

Pipeline consumers (`tag_highlights`, `wikilink_highlights`, `highlights`,
`inline_fields`) already benefit from incremental dirty-line rendering and
extmark diffing. They do **not** use the "clear all + rebuild" pattern described
in the original draft.

However, two categories of remaining work are not covered by the pipeline:

1. **Non-pipeline renderers** — modules like `embed.lua`, `footnotes.lua`, and
   `task_hierarchy.lua` are **not** part of the transform pipeline. Their dispatch
   varies: `embed.lua` and `task_hierarchy.lua` have independent render cycles
   driven by their own autocmds via `event_dispatch.lua`. `footnotes.lua` has a
   `coordinated_update()` entry point but is lazy-loaded via Tier 3 commands
   rather than self-registering as a coordinator updater. Only `autolink` is
   currently registered in the coordinator's `_updaters[]` fallback loop. These
   modules manage their own caching with varying sophistication:
   - `embed.lua`: descriptor pools, render arenas, file cache, LRU image path
     cache, viewport-based lazy rendering — but no cross-cycle content dedup.
     A re-render still rebuilds all virtual text tables for every visible embed.
   - `footnotes.lua`: changedtick-validated footnote map cache, pipeline token
     iteration for reference positions, render arena for virtual text — but
     clears the entire namespace and rebuilds all extmarks on each cycle.
   - `task_hierarchy.lua`: generation-based tree cache, changedtick vtext
     cache, LRU fold state — but clears the `vault_task_hierarchy` namespace
     and re-places all completion extmarks on each render.

2. **Expensive computation behind cache misses** — even within the pipeline,
   semantic resolution (Layer 2) re-resolves all tokens on every line when
   the vault index generation changes (e.g., after a file save elsewhere in
   the vault). Resolution results are cached per-buffer in
   `_cache[bufnr].resolved[ln]` with generation validation, so they persist
   across cycles when the generation is stable. However, a single generation
   bump triggers re-resolution of all tokens on all lines, even when the
   underlying link targets haven't actually changed. A frame cache could
   retain resolution results across generation bumps for tokens whose
   resolution would produce identical results.

The dual-frame cache targets these gaps: providing automatic expiration for
non-pipeline renderers and a secondary retention layer for expensive computations
that the pipeline's per-line cache already handles at the tokenization level
but not at the resolution or virtual-text-construction level.

**Note on dispatch architecture:** Because `embed.lua` and `task_hierarchy.lua`
have independent render cycles (not routed through the coordinator), each
module must own its own `FrameCache` instance and call `finish_frame()` at its
own cycle boundary. The coordinator only manages the frame cache lifecycle for
updaters in its `_updaters[]` loop (currently just `autolink`). `footnotes.lua`
is called via `coordinated_update()` when active, so it can receive the
coordinator's cache via `opts.frame_cache`.

## Inspiration

Zed's `crates/gpui/src/text_system/line_layout.rs` implements a
`LineLayoutCache` with a two-frame retention policy.

### Actual Zed Implementation (verified against source)

**`LineLayoutCache` struct (lines 392-396) and `FrameCache` struct (lines 398-404):**

```rust
pub(crate) struct LineLayoutCache {
    previous_frame: Mutex<FrameCache>,
    current_frame: RwLock<FrameCache>,
    platform_text_system: Arc<dyn PlatformTextSystem>,
}

#[derive(Default)]
struct FrameCache {
    lines: FxHashMap<Arc<CacheKey>, Arc<LineLayout>>,
    wrapped_lines: FxHashMap<Arc<CacheKey>, Arc<WrappedLineLayout>>,
    used_lines: Vec<Arc<CacheKey>>,
    used_wrapped_lines: Vec<Arc<CacheKey>>,
}
```

**`LineLayoutIndex` type (lines 406-410):**

```rust
#[derive(Clone, Default)]
pub(crate) struct LineLayoutIndex {
    lines_index: usize,
    wrapped_lines_index: usize,
}
```

Key details:
- `current_frame` uses `RwLock` (upgradable reads for promotion without
  releasing the lock). `previous_frame` uses `Mutex`.
- Each `FrameCache` stores entries in both a `FxHashMap` (O(1) lookup) and
  a `Vec` (insertion-order tracking for range-based reuse).
- **No explicit `max_entries` or eviction policy.** Memory is bounded
  implicitly by the two-generation lifetime: entries unused for two
  consecutive frames are discarded when the old `previous_frame` is cleared.

**Lookup with promotion** (from `layout_line_internal()`, lines 546-605):

1. Acquire upgradable read lock on `current_frame`.
2. Check `current_frame.lines.get(key)` — if hit, return (hot path).
3. Upgrade read lock to write lock.
4. Check `previous_frame.lines.remove_entry(key)` — if found, insert into
   `current_frame.lines`, append key to `current_frame.used_lines`, return
   (promotion).
5. On miss: compute layout, insert into `current_frame`, return.

**`finish_frame()` (lines 458-466):**

```rust
pub fn finish_frame(&self) {
    let mut prev_frame = self.previous_frame.lock();
    let mut curr_frame = self.current_frame.write();
    std::mem::swap(&mut *prev_frame, &mut *curr_frame);
    curr_frame.lines.clear();
    curr_frame.wrapped_lines.clear();
    curr_frame.used_lines.clear();
    curr_frame.used_wrapped_lines.clear();
}
```

Uses `mem::swap` (O(1) pointer swap) rather than drop + reallocate. After
the swap, clears the now-`current_frame` (which held the old `previous`
data). Called by `Window::draw()` at the render-to-next-render boundary.

**`reuse_layouts(range)` (lines 429-448):**

```rust
pub fn reuse_layouts(&self, range: Range<LineLayoutIndex>) {
    // ...
    for key in &previous_frame.used_lines[range.start..range.end] {
        if let Some((key, line)) = previous_frame.lines.remove_entry(key) {
            current_frame.lines.insert(key, line);
        }
        current_frame.used_lines.push(key.clone());
    }
    // Same for wrapped_lines...
}
```

Bulk-promotes a **contiguous range** of entries from previous to current
frame. Used by elements that know their content hasn't changed and can
declare reuse by index range rather than individual key lookups.

**`truncate_layouts(index)` (lines 450-456):**

Truncates `used_lines` and `used_wrapped_lines` vectors to specific indices.
Used when an element's layout is partially invalidated mid-frame.

**Broader Window-level pattern:**

The `LineLayoutCache` is embedded in the Window's frame management
(`crates/gpui/src/window.rs`, lines 841-842):

```rust
pub(crate) rendered_frame: Frame,
pub(crate) next_frame: Frame,
```

`Window::draw()` (lines 1837-1904) executes a four-step frame boundary:

1. `self.text_system().finish_frame()` — swaps the line layout cache's
   two frames (line 1859).
2. `self.next_frame.finish(&mut self.rendered_frame)` — transfers accessed
   element states from the previous frame into the current frame via
   `remove_entry()`, then calls `self.scene.finish()` to finalize the scene
   graph (line 1860). Only states in `accessed_element_states` are promoted;
   unused states are dropped.
3. `mem::swap(&mut self.rendered_frame, &mut self.next_frame)` — O(1)
   pointer swap makes the completed frame the rendered frame (line 1865).
4. `self.next_frame.clear()` — clears the now-empty frame for the next
   render cycle (line 1866).

The `Frame` struct itself (lines 665-686) holds focus, window_active,
element_states, accessed_element_states, mouse_listeners, dispatch_tree,
scene, hitboxes, window_control_hitboxes, deferred_draws, input_handlers,
tooltip_requests, cursor_styles, tab_handles, and debug/inspector fields.
`Frame::finish()` (lines 802-812) promotes accessed element states from the
previous frame via `remove_entry()` and also calls `self.scene.finish()` to
finalize the scene graph. The line layout cache's two-frame cycle is
synchronized with the window's overall frame boundary — both swap at the
same point in `draw()`.

### What Transfers to Lua

- The core get/promote/set/finish_frame pattern maps directly.
- Lua lacks RwLock/Mutex, but Neovim's single-threaded event loop means no
  locking is needed.
- The `used_lines` Vec (insertion-order tracking) is only needed for
  `reuse_layouts()` range-based bulk promotion. In the Lua port, modules
  access entries by key, so the Vec is unnecessary. The simpler two-table
  design suffices.
- Zed has no `max_entries`; the Lua port adds an optional cap as a safety
  valve since Lua's GC is less aggressive than Rust's drop semantics.

## Design

### FrameCache Module

A generic dual-frame cache container implemented as a Lua module at
`lua/andrew/vault/frame_cache.lua`. The cache is parameterized by key type
(string) and value type (any Lua value).

```
FrameCache
  previous: table<string, any>   -- entries from prior render cycle
  current:  table<string, any>   -- entries from active render cycle
  current_count: number          -- size of current frame
  previous_count: number         -- size of previous frame
  max_entries: number|nil        -- optional cap per frame
  stats: { hits: number, misses: number, promotions: number, evictions: number }
```

### Lookup Semantics

`get(key)`:

1. Check `current[key]`. If found, return value (hot hit).
2. Check `previous[key]`. If found, **promote**: move to `current`, remove from
   `previous`, increment `stats.promotions`, return value (warm hit).
3. Return `nil` (miss), increment `stats.misses`.

This two-level lookup is the core mechanism. Stable content (unchanged between
renders) is promoted on first access each cycle. Content that disappears from
the buffer is simply never looked up and falls off after one idle cycle.

### Insertion

`set(key, value)`:

1. If `max_entries` is set and `current_count >= max_entries`, skip insertion
   and increment `stats.evictions`.
2. Insert into `current[key]`, increment `current_count` if key was not already
   present.

### Frame Transition

`finish_frame()`:

1. Drop `previous` (Lua GC handles deallocation).
2. `previous = current`, `previous_count = current_count`.
3. `current = {}`, `current_count = 0`.

Called once at the end of each render cycle for a given buffer.

### Cache Key Strategy

Each consuming module defines its own key format. Keys are designed to work
with the module's actual data model:

| Module                    | Key Format                                      | Cached Value                                     |
|---------------------------|-------------------------------------------------|--------------------------------------------------|
| `embed.lua`               | `"{bufnr}:{line}:{embed_inner}"`                | `{ virt_lines, is_image, deps }`                 |
| `footnotes.lua`           | `"{bufnr}:{ref_row}:{footnote_id}"`             | `{ virt_lines }` (arena-allocated virtual text)   |
| `task_hierarchy.lua`      | `"{bufnr}:{root_line}:{done}:{total}"`          | `{ label, hl_group }`                            |
| `semantic_resolution`     | `"{bufnr}:{line}:{token_key}:{index_gen}"`      | `ResolvedToken` (status, target, hl_group)       |

**Note on pipeline consumers:** `tag_highlights` and `wikilink_highlights`
already have effective caching via the three-layer pipeline
(line_parse_cache + semantic_resolution + render_diff). The frame cache is
**not** intended to replace or duplicate this pipeline. It targets the
legacy updaters and the semantic resolution layer's cross-generation gap.

Keys include the line number, so moving a line (insert/delete above) naturally
invalidates the entry. This is intentional: line-shifted content is cheap to
re-render, and the alternative (content-addressed keys) adds complexity for
marginal gain.

## Current Architecture (As-Is)

Understanding the existing rendering infrastructure is essential for correct
integration. The following describes the actual state of each target module.

### highlight_coordinator.lua (371 lines)

Orchestrates highlight rendering with a two-path dispatch in `M.run_all()`
(lines 245-275):

1. **Pipeline path** (lines 254-256): `pipeline.attach(bufnr)` (idempotent),
   then `pipeline.run(bufnr, code_excl, opts)`. Handles `wikilink_highlights`,
   `tag_highlights`, `highlights`, `inline_fields` via three-layer pipeline
   (parse cache → semantic resolution → render diff).
2. **Legacy updater path** (lines 259-266): Iterates registered `_updaters[]`,
   skipping any where `pipeline.is_updater_covered(updater.name)` returns true.
   Currently only `autolink` is registered here. **`embed.lua` and
   `task_hierarchy.lua` are NOT in this loop** — they have independent render
   cycles via `event_dispatch.lua`. `footnotes.lua` has `coordinated_update()`
   but is lazy-loaded via Tier 3 commands, not self-registered.

Per-buffer state:
- `_timers[bufnr]`: Debounce timer (30ms full, 200ms partial via
  `resource_cleanup.debounce()`)
- Arena scoping: `render_arena.begin_scope()` / `end_scope()` per cycle
  (lines 247, 269)
- Shared `code_excl` context: `link_scan.build_code_exclusion(bufnr)` built
  once and passed to all updaters (line 252)

Buffer cleanup (lines 346-350): `cleanup.on_buf_delete(_augroup, callback)`
closes the debounce timer and calls `pipeline.detach(bufnr)`.

The natural `finish_frame()` insertion point is at line ~269, after
`render_arena.end_scope(arena_scope)` but before `opts.arena = nil` (line 270)
and the profiler `stop()` call (line 271).

### embed.lua (940 lines)

The heaviest rendering module. **Has its own independent render cycle** — not
dispatched via the coordinator's `_updaters[]` loop. Entry points are
`M.render_embeds(opts)` (lines 399-496), `M.on_buf_enter(ctx)` (lines
906-916), and `M.on_text_changed(bufnr, file)` (lines 921-930), all routed
through `event_dispatch.lua`.

Current caching infrastructure:

- **embed_state.lua**: Per-buffer `_embed_descriptors[bufnr]` with generation
  counter and descriptor lists. Namespace: `"VaultEmbed"`.
- **Descriptor pool** (`_desc_pool`): Recycles descriptor objects to reduce GC,
  sized via `config.pools.embed_descriptor`
- **Render arena**: Per-embed scopes within per-buffer arena scope. Each embed
  gets `render_arena.begin_scope()` → `alloc_table()` for virt_lines →
  `end_scope()` after extmark placement (lines 277-331).
- **File cache** (`file_cache.read(path)`): Pre-warms cross-file embed content
  via `warm_embed_cache()` before render loop
- **Image LRU cache** (`embed_images.lua`): `config.cache.image_path_max`
  entries with locality heuristic (`_last_hit_idx`)
- **Viewport-based lazy rendering**: Only renders embeds in viewport + padding
  via `render_in_range()`; off-screen embeds render on `WinScrolled`
- **Image GC**: `gc_distant_placements()` closes Snacks placements far
  off-screen
- **Stale buffer GC**: `state.gc_stale_buffers()` on `BufEnter`
- **Request coalescer**: Deduplicates concurrent renders per buffer

**Render cycle** (in `M.render_embeds()`):
1. Clear: `nvim_buf_clear_namespace(bufnr, state.ns, 0, -1)` +
   `images.clear_image_placements(bufnr)` (lines 428-429)
2. Begin render arena scope (line 436)
3. Initialize render dependencies via `init_render_deps()` (line 439)
4. Get buffer lines (line 441)
5. Build descriptors via `build_descriptors()` (line 443)
6. Warm file cache for cross-file embeds via `warm_embed_cache()` (line 444)
7. Release old descriptor pool, create new generation (lines 445-450)
8. Build render context via `build_render_ctx()` (line 452)
9. Iterate descriptors → `render_single_embed(desc, ctx)` (lines 457-463)
10. Update dependency tracking (line 466)
11. End arena scope (line 485)

**Gap the frame cache addresses:** Even with all this infrastructure, a
re-render still rebuilds virtual text tables for every visible embed. The
frame cache can skip the `extract_content → build_virt_lines` pipeline for
embeds whose content hasn't changed, identified by matching
`{bufnr}:{line}:{embed_inner}` keys.

### tag_highlights.lua (118 lines) — Pipeline Consumer

A thin facade that:
- Creates namespace `"vault_tag_hl"`
- Registers a pipeline consumer in `pipeline_consumers.lua` (lines 125-161)
- Uses category-based highlight groups (`VaultTag`, `VaultTagProject`, etc.)
- Produces 2 extmarks per tag: hash char + tag text, both priority 190
- Navigation cache: `_nav_cache[bufnr] = { tick, positions }` with
  changedtick validation

**Already well-cached** via the three-layer pipeline. The frame cache is
**not needed** for this module's extmark rendering. However, the navigation
cache (`scan_tags_pipeline_aware()`) could optionally use a frame cache for
position data if scan cost becomes measurable.

### wikilink_highlights.lua (56 lines) — Pipeline Consumer

An even thinner facade:
- Creates namespace `"vault_wikilink_hl"`
- Registered as pipeline consumer with three-layer processing:
  - Layer 1: LPEG tokenization of `[[...]]` patterns
  - Layer 2: Semantic resolution via `wikilinks.resolve_link()` against vault
    index, with generation-based staleness
  - Layer 3: Render diff producing 4+ extmarks per link (brackets, name,
    heading, alias) with priority 200

**The semantic resolution layer is a secondary frame cache opportunity.**
Resolution results are already cached per-buffer in
`_cache[bufnr].resolved[ln]` with generation tracking (172-line module).
However, when the vault index generation bumps (e.g., saving a different
file), `is_stale()` triggers re-resolution of all wikilinks on every line.
Most resolutions produce identical results. A frame cache keyed by
`{bufnr}:{line}:{token_key}:{index_gen}` could retain stable resolution
results across generation changes, falling back to re-resolution only on
actual misses.

### task_hierarchy.lua (596 lines)

**Has its own independent render cycle** — not dispatched via the coordinator's
`_updaters[]` loop. Entry point is `M.render_completion_vtext(bufnr)` (lines
98-140), triggered by `BufReadPost` autocmd (lines 517-521) and TextChanged
events via `event_dispatch.lua`. Setup at `M.setup()` (lines 494-581).

Provides two features:
- **Virtual text** on parent task lines: ` [done/total percentage%]` at eol
- **Dedicated tree view float**: `:VaultTaskTree` with fold/collapse state

Current caching:
- `_vtext_cache[bufnr]`: `{gen, rel_path, roots}` — generation validated via
  `filter_utils.is_cache_gen_valid(cached, gen)` (line 119)
- `_tree_cache`: `task_utils.gen_cache()` factory for file entries (lines
  260-293), invalidated by vault index generation changes
- `_fold_state`: LRU cache via `lru.new(config.cache.fold_state_max or 500)`
  (line 23)

**Render pattern** (lines 98-140): Clears `vault_task_hierarchy` namespace
at line 103 (`nvim_buf_clear_namespace(bufnr, ns, 0, -1)`). Then iterates
roots, calls `M.completion_stats(root)` (recursive tree traversal, lines
78-90), formats label, and places extmarks with `virt_text_pos = "eol"` and
`hl_mode = "combine"`. Highlight group is `"VaultHierarchyComplete"` (100%)
or `"VaultHierarchyProgress"`.

The frame cache can skip `completion_stats()` recomputation
and extmark recreation when `{bufnr}:{root_line}:{done}:{total}` keys match.

### footnotes.lua (632 lines)

Provides footnote reference/definition virtual text with borders. Has
`M.coordinated_update(bufnr, _code_excl, opts)` (lines 470-473) which
delegates to `M.render_footnotes()` with `silent = true` and arena
passthrough. Lazy-loaded via Tier 3 commands — does **not** self-register
in the coordinator's `_updaters[]`.

Current caching:
- `_fn_cache[bufnr]`: `{tick, fn_map}` — changedtick-validated via
  `hl_coord.cached_value(_fn_cache, bufnr, parse_all_footnotes)` (line 152)
- Pipeline token iteration: `lpc.pipeline_token_iter(bufnr, "footnote")`
  (lines 418-433) for reference positions — filters `not token.subtype`
  (references only, not definitions)
- Render arena: Uses parent arena passthrough pattern — if `opts.arena`
  provided, nests within it; otherwise creates own scope (lines 370-371)

**Render pattern** (`M.render_footnotes()`, lines 337-464):
- Full render: `nvim_buf_clear_namespace(bufnr, ns, 0, -1)` (line 345)
- Partial render: clears only visible range (line 350)
- Iterates pipeline tokens, builds virt_lines per reference via arena-allocated
  tables: header (`footnote_header(id)`), content lines (2-space indent),
  truncation indicator, footer
- Extmark: `nvim_buf_set_extmark(bufnr, ns, ref_row, 0, { virt_lines, virt_lines_above = false })` (line 409)

The frame cache can skip virtual text reconstruction when
`{bufnr}:{ref_row}:{footnote_id}` keys match — the expensive part is
`read_definition_content()` (lines 65-102) and virt_lines construction.

## Target Modules (Revised)

Priority ordering reflects actual remaining gaps, not the original draft's
assumption of "clear all + rebuild" everywhere:

1. **`embed.lua`** (HIGH) — Heaviest consumer. Frame cache avoids rebuilding
   virtual text tables and file reads for unchanged embeds. Integrates with
   existing descriptor pool and render arena.

2. **`footnotes.lua`** (MEDIUM) — Avoids virt_lines reconstruction for
   unchanged footnote references. Namespace-clear + rebuild is the current
   pattern; frame cache changes this to selective rebuild on miss only.

3. **`task_hierarchy.lua`** (MEDIUM) — Avoids `completion_stats()` tree
   traversal and extmark recreation for unchanged task completions.

4. **`semantic_resolution.lua`** (LOW-MEDIUM) — Optional secondary cache
   layer. Resolution results are already cached per-buffer with generation
   validation in `_cache[bufnr].resolved[ln]` (172-line module). The frame
   cache would reduce unnecessary re-resolution when generation bumps don't
   affect the current buffer's links — currently `is_stale()` triggers
   full re-resolution of all lines on any generation change.

5. **`highlight_coordinator.lua`** — Owns `finish_frame()` lifecycle for
   updaters in its `_updaters[]` loop (currently `autolink`). Also provides
   `opts.frame_cache` to `footnotes.coordinated_update()` when called.
   Does not consume the cache directly.

**Dispatch ownership summary:**
- **Coordinator-managed cache**: `autolink` (registered updater), `footnotes`
  (via `coordinated_update()` opts passthrough)
- **Self-managed cache**: `embed.lua` (own render cycle via event_dispatch),
  `task_hierarchy.lua` (own render cycle via event_dispatch + BufReadPost)

**Explicitly excluded:**
- `tag_highlights.lua` — Fully served by the three-layer pipeline.
- `wikilink_highlights.lua` — Fully served by the three-layer pipeline
  (semantic resolution opportunity listed separately above).

## Implementation Steps

### Step 1: Create `frame_cache.lua` Module

File: `lua/andrew/vault/frame_cache.lua`

```lua
local M = {}
M.__index = M

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    previous = {},
    current = {},
    current_count = 0,
    previous_count = 0,
    max_entries = opts.max_entries,
    stats = { hits = 0, misses = 0, promotions = 0, evictions = 0 },
  }, M)
end

function M:get(key)
  local val = self.current[key]
  if val ~= nil then
    self.stats.hits = self.stats.hits + 1
    return val
  end

  val = self.previous[key]
  if val ~= nil then
    -- Promote from previous to current
    self.previous[key] = nil
    self.previous_count = self.previous_count - 1
    self.current[key] = val
    self.current_count = self.current_count + 1
    self.stats.promotions = self.stats.promotions + 1
    return val
  end

  self.stats.misses = self.stats.misses + 1
  return nil
end

function M:set(key, value)
  if self.max_entries and self.current_count >= self.max_entries then
    if not self.current[key] then
      self.stats.evictions = self.stats.evictions + 1
      return false
    end
  end
  if not self.current[key] then
    self.current_count = self.current_count + 1
  end
  self.current[key] = value
  return true
end

function M:finish_frame()
  self.previous = self.current
  self.previous_count = self.current_count
  self.current = {}
  self.current_count = 0
end

function M:clear()
  self.previous = {}
  self.current = {}
  self.previous_count = 0
  self.current_count = 0
end

function M:size()
  return self.current_count + self.previous_count
end

function M:get_stats()
  return {
    hits = self.stats.hits,
    misses = self.stats.misses,
    promotions = self.stats.promotions,
    evictions = self.stats.evictions,
    current_entries = self.current_count,
    previous_entries = self.previous_count,
    total_entries = self.current_count + self.previous_count,
  }
end

function M:reset_stats()
  self.stats = { hits = 0, misses = 0, promotions = 0, evictions = 0 }
end

return M
```

### Step 2: Integrate Frame Cache Lifecycle

Because modules have different dispatch paths, the frame cache integration is
**per-module rather than centralized in the coordinator**:

- **Coordinator-owned cache**: For updaters in the `_updaters[]` loop (currently
  `autolink`, and `footnotes` when called via `coordinated_update()`). The
  coordinator creates a per-buffer `FrameCache`, passes it via `opts.frame_cache`,
  and calls `finish_frame()` at cycle end.
- **Module-owned caches**: `embed.lua` and `task_hierarchy.lua` have independent
  render cycles, so each creates and manages its own `FrameCache` instance,
  calling `finish_frame()` at the end of their own render functions.

#### Coordinator integration (`highlight_coordinator.lua`)

```lua
-- In highlight_coordinator.lua
local FrameCache = require("andrew.vault.frame_cache")

-- Per-buffer cache registry (alongside existing _timers)
local buf_caches = {} -- bufnr → FrameCache

local function get_cache(bufnr)
  if not buf_caches[bufnr] then
    buf_caches[bufnr] = FrameCache.new({
      max_entries = config.render_cache.max_entries_per_frame,
    })
  end
  return buf_caches[bufnr]
end
```

**Integration point in `M.run_all()`** (lines 245-275):

```lua
function M.run_all(bufnr, opts)
  -- ... existing validation ...
  local arena_scope = render_arena.begin_scope()  -- line 247
  opts.arena = arena_scope                         -- line 248
  opts.frame_cache = config.render_cache.enabled and get_cache(bufnr) or nil

  local code_excl = link_scan.build_code_exclusion(bufnr)  -- line 252

  -- Pipeline path (tags, wikilinks, highlights, inline_fields)
  -- These modules already have render_diff; frame_cache is not passed to them.
  pipeline.attach(bufnr)                                   -- line 255
  pipeline.run(bufnr, code_excl, opts)                     -- line 256

  -- Legacy updater path — currently only autolink.
  -- footnotes.coordinated_update() also receives opts when called.
  -- embed.lua and task_hierarchy.lua are NOT here (own render cycles).
  for _, updater in ipairs(_updaters) do
    if updater.enabled() and not pipeline.is_updater_covered(updater.name) then
      local ok, err = pcall(updater.fn, bufnr, code_excl, opts)
      -- ... error handling ...
    end
  end

  render_arena.end_scope(arena_scope)                      -- line 269
  if opts.frame_cache then opts.frame_cache:finish_frame() end
  opts.arena = nil                                         -- line 270
  stop()
end
```

**Buffer cleanup** — extend the existing `cleanup.on_buf_delete()` handler
(lines 346-350, which already takes `_augroup` as first argument):

```lua
-- In the existing cleanup.on_buf_delete(_augroup, function(bufnr) ... end):
-- Add: buf_caches[bufnr] = nil
```

**Memory profiler registration** — use the `register_counter(spec)` API
(which takes a spec table with `name`, `get_count`, and `description` fields):

```lua
memory_profiler.register_counter({
  name = "frame_caches",
  get_count = function()
    local count = 0
    for _, cache in pairs(buf_caches) do count = count + cache:size() end
    return count
  end,
  description = "highlight coordinator per-buffer dual-frame render caches",
})
```

### Step 3: Adapt `embed.lua` (Highest Priority)

Because embed.lua has its own independent render cycle (via `event_dispatch.lua`,
not the coordinator), it owns its own `FrameCache` instance:

```lua
-- Module-level in embed.lua
local FrameCache = require("andrew.vault.frame_cache")
local _frame_caches = {} -- bufnr → FrameCache

local function get_frame_cache(bufnr)
  if not config.render_cache.enabled then return nil end
  if not _frame_caches[bufnr] then
    _frame_caches[bufnr] = FrameCache.new({
      max_entries = config.render_cache.max_entries_per_frame,
    })
  end
  return _frame_caches[bufnr]
end
```

The frame cache slots in at the `render_single_embed()` level (lines 238-334)
to skip virt_lines construction. The cache is threaded through `ctx`:

```lua
-- In M.render_embeds(), add to build_render_ctx():
--   ctx.frame_cache = get_frame_cache(bufnr)

-- In render_single_embed(desc, ctx)
local function render_single_embed(desc, ctx)
  local fc = ctx.frame_cache
  local cache_key = ctx.bufnr .. ":" .. desc.lnum .. ":" .. desc.inner

  if fc then
    local cached = fc:get(cache_key)
    if cached then
      if desc.is_image then
        -- Image embeds: verify placement still exists before reusing
        if cached.placement and not cached.placement:is_closed() then
          desc.rendered = true
          desc.lines_used = cached.lines_used
          return cached.stats
        end
        -- Placement closed; fall through to re-render
      else
        -- Note embeds: re-place extmark with cached virt_lines
        -- (extmarks are cleared at cycle start via nvim_buf_clear_namespace;
        -- position is from current buffer parse, not cached)
        vim.api.nvim_buf_set_extmark(ctx.bufnr, state.ns, desc.lnum - 1, 0, {
          virt_lines = cached.virt_lines,
          virt_lines_above = false,
        })
        desc.rendered = true
        desc.lines_used = cached.lines_used
        return cached.stats
      end
    end
  end

  -- ... existing render logic (resolve, extract content, build virt_lines) ...
  -- Note: virt_lines for cache storage must be allocated OUTSIDE the
  -- render arena (normal Lua tables), since arena tables are recycled
  -- at scope end. The arena-allocated copy is used for the current cycle's
  -- extmark; a separate copy is stored in the frame cache.

  -- After successful render, store in frame cache:
  if fc then
    fc:set(cache_key, {
      virt_lines = virt_lines_copy, -- deep copy, NOT arena-allocated
      placement = placement,         -- for image embeds
      lines_used = desc.lines_used,
      stats = { images = N, notes = N, errors = N },
    })
  end
end
```

**At end of `M.render_embeds()` (after line ~466), call `finish_frame()`:**

```lua
  -- After all embeds rendered, before stats reporting:
  local fc = get_frame_cache(bufnr)
  if fc then fc:finish_frame() end
```

**Buffer cleanup** — add to existing `cleanup.on_buf_delete()` handler (lines
893-895, which calls `state.clear_buffer_state(bufnr, clear_state_cbs)`) or
register via `cleanup.on_buf_delete_once(bufnr, function() _frame_caches[bufnr] = nil end)`.
Note: `cleanup.on_buf_delete_once(bufnr, callback)` is at resource_cleanup.lua
lines 109-115.

**Key insight:** The frame cache here does NOT replace the descriptor pool,
render arena, file cache, or image LRU — it adds a layer that skips the
entire `resolve → read → build_virt_lines` pipeline when content is unchanged.

### Step 4: Adapt `footnotes.lua`

Footnotes receives its frame cache via `opts.frame_cache` from the coordinator
(when called via `M.coordinated_update(bufnr, _code_excl, opts)` at lines
470-473). It can also be called directly via `:VaultFootnotes` command, in
which case `opts.frame_cache` will be nil and rendering proceeds unconditionally.

Replace the current "clear namespace + rebuild all" pattern with selective
rebuild on cache miss within `M.render_footnotes()` (lines 337-464):

```lua
-- In M.render_footnotes(opts)
local function render_footnotes(opts)
  -- ... existing: parse opts, determine range ...
  local fc = opts and opts.frame_cache
  local fn_map = parse_all_footnotes_cached(bufnr)  -- existing changedtick cache

  -- Still clear namespace (extmarks may have shifted due to line changes)
  -- Full: nvim_buf_clear_namespace(bufnr, ns, 0, -1) (line 345)
  -- Partial: clear visible range only (line 350)

  -- Iterate via pipeline token iterator (lines 418-433)
  local iter = lpc.pipeline_token_iter(bufnr, "footnote")
  if iter then
    for line_nr, token in iter do
      if not token.subtype then  -- references only
        local id = token.captures[1]
        local info = fn_map[id]
        if info and line_nr >= range_start and line_nr < range_end then
          local cache_key = bufnr .. ":" .. line_nr .. ":" .. id
          local cached = fc and fc:get(cache_key)

          if cached then
            -- Re-place extmark with cached virt_lines
            vim.api.nvim_buf_set_extmark(bufnr, ns, line_nr, 0, {
              virt_lines = cached.virt_lines,
              virt_lines_above = false,
            })
          else
            -- ... existing render_ref_at() logic: read_definition_content,
            -- build header/content/footer via arena-allocated tables ...
            -- Note: virt_lines stored in cache must be non-arena copies
            local virt_lines = build_footnote_virt_lines(id, info)
            vim.api.nvim_buf_set_extmark(bufnr, ns, line_nr, 0, {
              virt_lines = virt_lines,
              virt_lines_above = false,
            })
            if fc then fc:set(cache_key, { virt_lines = virt_lines }) end
          end
        end
      end
    end
  end
end
```

The cache saves the cost of `read_definition_content()` (lines 65-102) and
virt_lines table construction on cache hits. The namespace clear + re-place
pattern ensures correct positioning even when lines shift.

**Note:** Since footnotes uses the coordinator's frame cache (not its own),
`finish_frame()` is called by the coordinator at cycle end — footnotes does
not need its own lifecycle management.

### Step 5: Adapt `task_hierarchy.lua`

Because task_hierarchy.lua has its own independent render cycle (via
`event_dispatch.lua` and `BufReadPost` autocmd, not the coordinator), it owns
its own `FrameCache` instance:

```lua
-- Module-level in task_hierarchy.lua
local FrameCache = require("andrew.vault.frame_cache")
local _frame_caches = {} -- bufnr → FrameCache

local function get_frame_cache(bufnr)
  if not config.render_cache.enabled then return nil end
  if not _frame_caches[bufnr] then
    _frame_caches[bufnr] = FrameCache.new({
      max_entries = config.render_cache.max_entries_per_frame,
    })
  end
  return _frame_caches[bufnr]
end
```

**Integration in `M.render_completion_vtext(bufnr)` (lines 98-140):**

```lua
function M.render_completion_vtext(bufnr)
  -- ... existing validation, _vtext_cache lookup ...
  local fc = get_frame_cache(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)  -- line 103

  for _, root in ipairs(roots) do
    local done, total = M.completion_stats(root)  -- recursive tree traversal
    local cache_key = bufnr .. ":" .. root.line .. ":" .. done .. ":" .. total

    local cached = fc and fc:get(cache_key)
    if cached then
      -- Re-place with cached label and hl group
      vim.api.nvim_buf_set_extmark(bufnr, ns, root.line - 1, 0, {
        virt_text = { { cached.label, cached.hl } },
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
    else
      local label = string.format(" [%d/%d %d%%]", done, total,
        total > 0 and math.floor(done / total * 100) or 0)
      local hl = (done == total) and "VaultHierarchyComplete"
        or "VaultHierarchyProgress"
      vim.api.nvim_buf_set_extmark(bufnr, ns, root.line - 1, 0, {
        virt_text = { { label, hl } },
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
      if fc then fc:set(cache_key, { label = label, hl = hl }) end
    end
  end

  -- finish_frame() at end of render cycle
  if fc then fc:finish_frame() end
end
```

**Buffer cleanup** — add to existing cache invalidation handler (lines 543,
551-555) and buffer deletion handler (lines 525-533):
```lua
_frame_caches[bufnr] = nil
```

**Note:** `M.completion_stats()` (lines 78-90) still runs to compute the cache
key (done/total are part of the key). The savings come from skipping label
formatting and extmark creation on hits. For a more aggressive optimization,
the tree traversal itself could be cached separately using the existing
`_vtext_cache[bufnr]` with `filter_utils.is_cache_gen_valid()` generation
validation.

### Step 6: Add `:VaultRenderCacheDebug` Command

```lua
vim.api.nvim_create_user_command("VaultRenderCacheDebug", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local cache = buf_caches[bufnr]
  if not cache then
    notify.warn("No render cache for buffer " .. bufnr)
    return
  end
  local s = cache:get_stats()
  local lines = {
    "Render Cache (buf " .. bufnr .. ")",
    "  Current frame:  " .. s.current_entries .. " entries",
    "  Previous frame: " .. s.previous_entries .. " entries",
    "  Total:          " .. s.total_entries .. " entries",
    "  Hits:           " .. s.hits,
    "  Misses:         " .. s.misses,
    "  Promotions:     " .. s.promotions,
    "  Evictions:      " .. s.evictions,
    "  Hit rate:       " .. string.format("%.1f%%",
      s.hits > 0 and (s.hits / (s.hits + s.misses) * 100) or 0),
  }
  -- Use vault_log and notify patterns consistent with other debug commands
  local log = require("andrew.vault.vault_log").scope("frame_cache")
  log.info(table.concat(lines, "\n"))
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, { desc = "Show render cache statistics for current buffer" })
```

### Step 7: Buffer Cleanup

Each module with its own `_frame_caches` table must clean up on buffer
deletion. The cleanup patterns differ based on the module's dispatch path:

**Coordinator-owned cache** (`highlight_coordinator.lua`): Extend the existing
`cleanup.on_buf_delete(_augroup, callback)` handler at lines 346-350:

```lua
-- In the existing cleanup.on_buf_delete(_augroup, function(bufnr) ... end):
cleanup.close_timer_in(_timers, bufnr)  -- existing
pipeline.detach(bufnr)                  -- existing
buf_caches[bufnr] = nil                 -- NEW: release frame cache
```

**Module-owned caches** (`embed.lua`, `task_hierarchy.lua`): Use
`cleanup.on_buf_delete_once(bufnr, callback)` for per-buffer one-shot cleanup,
or add to existing buffer deletion handlers:

```lua
-- embed.lua: add to existing cleanup.on_buf_delete() handler (lines 893-895)
-- or state.gc_stale_buffers()
_frame_caches[bufnr] = nil

-- task_hierarchy.lua: add to existing BufDelete handler (lines 525-533) and
-- cache invalidation handler (lines 543, 551-555)
_frame_caches[bufnr] = nil
```

**Memory profiler registration** — use the `register_counter(spec)` API
(takes a spec table with `name`, `get_count`, and `description` fields):

```lua
-- In each module that owns frame caches:
memory_profiler.register_counter({
  name = "embed_frame_caches",  -- or "task_hierarchy_frame_caches", etc.
  get_count = function()
    local count = 0
    for _, cache in pairs(_frame_caches) do count = count + cache:size() end
    return count
  end,
  description = "embed per-buffer dual-frame render caches",
})
```

## API

```lua
local FrameCache = require("andrew.vault.frame_cache")

-- Create a new cache (no max_entries mirrors Zed's unbounded approach)
local cache = FrameCache.new()

-- Or with optional safety cap
local cache = FrameCache.new({ max_entries = 2000 })

-- Store a render result
cache:set("42:10:MyNote", { virt_lines = {...}, lines_used = 5 })

-- Retrieve (checks current, then promotes from previous)
local entry = cache:get("42:10:MyNote")

-- End of render cycle — swap frames
cache:finish_frame()

-- Introspection
local stats = cache:get_stats()
-- → { hits=N, misses=N, promotions=N, evictions=N,
--     current_entries=N, previous_entries=N, total_entries=N }

-- Reset counters (e.g., for benchmarking a single cycle)
cache:reset_stats()

-- Full clear (e.g., on major buffer change like `:edit!`)
cache:clear()

-- Total entry count across both frames
local n = cache:size()
```

## Configuration

Add to `lua/andrew/vault/config.lua` after `M.profiler` (lines 913-920,
currently the last section in the file, with `return M` at line 922):

```lua
M.render_cache = {
  -- Master toggle. When false, opts.frame_cache is nil and legacy updaters
  -- render unconditionally (current behavior). Allows quick disable if cache
  -- introduces regressions.
  enabled = true,

  -- Maximum entries per frame per buffer. Prevents runaway memory in
  -- extremely large files (e.g., 10k-line vault notes). When exceeded,
  -- new entries are silently dropped (eviction counter incremented).
  -- nil = unlimited (matches Zed's approach, relying on two-generation
  -- lifetime for implicit eviction).
  max_entries_per_frame = nil,
}
```

Modules receive `opts.frame_cache` from the coordinator. When
`config.render_cache.enabled` is false, the coordinator passes `nil` and
modules fall back to unconditional rendering.

## Expected Impact

### Performance (Revised)

Impact estimates are revised to account for existing optimizations:

- **Embed rendering** (main target): Avoids redundant file reads, content
  extraction, and virt_lines table construction for unchanged embeds. On a
  typical `TextChanged` event editing line 42, embeds on other lines produce
  cache hits and skip the entire `resolve → read → build_virt_lines` pipeline.
  Estimated **50-70% reduction** in embed render time for single-line edits.

- **Footnote rendering:** Avoids `read_definition_content()` and virt_lines
  construction on cache hits. Estimated **40-60% reduction** in footnote
  render time (the namespace-clear + re-place pattern means extmark API calls
  still happen, but the computation behind them is skipped).

- **Task hierarchy:** Avoids label formatting and hl group selection on cache
  hits. Moderate savings since `completion_stats()` tree traversal still runs
  for key computation. Estimated **20-30% reduction**.

- **Tag/wikilink highlights:** No change — already served by the three-layer
  pipeline with render diffing.

### Memory

- Without `max_entries_per_frame` (default nil): bounded at ~2x the working
  set of a single frame per buffer. For a 500-line vault note with ~5 embeds,
  ~20 footnote refs, and ~15 parent tasks, this is ~80 entries × ~200 bytes
  = ~32 KB per buffer across both frames.
- With `max_entries_per_frame = 2000`: hard cap at ~800 KB per buffer.
- `cleanup.on_buf_delete()` ensures closed buffers release cache memory.
- Compared to current unbounded state in embed descriptors, this is a strict
  improvement in memory predictability.
- Integrates with existing `memory_profiler` counter system for observability.

### Render Cycle Timing

Conservative estimate for a 500-line vault note with ~5 embeds, ~20 footnote
references, and ~15 parent tasks (single-line edit):

| Metric                    | Before (current)  | After (dual-frame)  |
|---------------------------|--------------------|---------------------|
| Embed virt_lines builds   | ~5 (all visible)   | ~0-1 (misses only)  |
| Embed file reads          | 0-5 (file cache)   | 0 (frame cache)     |
| Footnote virt_lines builds| ~20 (all refs)     | ~0-2 (misses only)  |
| Task tree traversals      | ~15 (all roots)    | ~15 (for key comp)  |
| Tag/wikilink extmarks     | unchanged          | unchanged           |

**Note:** Tag and wikilink extmark counts are already optimized by the
pipeline's render_diff layer and are not affected by this change.

## Risks

### Interaction with Existing Caching Layers

**Risk:** The frame cache adds a fourth caching layer alongside
line_parse_cache, semantic_resolution, and render_diff. Cache coherence
across layers could become difficult to reason about.

**Mitigation:** The frame cache operates only on non-pipeline renderers that
are **not** processed by the transform pipeline. There is no overlap: pipeline
consumers (tags, wikilinks, highlights, inline_fields) use the three-layer
pipeline, while non-pipeline renderers (embeds, footnotes, tasks) use the
frame cache. Each module owns its cache independently: `embed.lua` and
`task_hierarchy.lua` manage their own `_frame_caches` tables, while
`footnotes.lua` receives the coordinator's cache via `opts.frame_cache`.
The frame cache is never passed to `transform_pipeline.run()`.

### Key Invalidation Accuracy

**Risk:** Line-number-based keys become stale when lines are inserted or
deleted above cached content. A tag on line 50 moves to line 51 after an
insert on line 10, but the cache still holds a key for line 50.

**Mitigation:** For embed.lua, the existing pattern clears all extmarks in
the namespace at the start of each render cycle. For footnotes, the
namespace-clear pattern is explicit. Cache hits re-place extmarks at current
positions parsed from the buffer. The cache value is the *content* of the
decoration (virt_lines, label text), not the position — position is always
recomputed from the current buffer state. Cache hits avoid the *computation*
cost (file reads, content extraction, virt_lines construction), not the
*placement* cost.

### Memory During Transition

**Risk:** During `finish_frame()`, both the old `previous` and the outgoing
`current` exist momentarily. This peaks at 3x a single frame's memory.

**Mitigation:** Lua's garbage collector handles this naturally. The old
`previous` table is unreferenced immediately. The `render_arena` already
handles similar transient memory for virtual text tables. If memory pressure
is a concern, `collectgarbage("step")` can be called after `finish_frame()`,
but this should not be necessary in practice.

### Cache Coherence with Undo

**Risk:** `u` (undo) can restore buffer content to a previous state. Cache
entries from the pre-undo state may not match the restored content.

**Mitigation:** Undo triggers `TextChanged`, which initiates a render cycle.
Line content is re-parsed, and cache keys are regenerated from current buffer
state. Stale entries from the pre-undo state naturally expire after one frame
(they exist in `previous` but are never promoted because the keys have
changed). No special undo handling is required.

### Interaction with Viewport Restriction

**Risk:** Viewport-restricted rendering only processes visible lines. Cached
entries for lines that scroll out of view are never promoted and expire after
one frame. When the user scrolls back, those entries are cache misses.

**Mitigation:** This is the intended behavior — the cache retains the
*working set*, not the full buffer. The existing `viewport.lua` padding
extends the render range beyond the visible viewport, and embed.lua's lazy
rendering with `WinScrolled` debounce already handles scroll-back re-renders.
The frame cache complements this by preserving content for the visible range
across consecutive edits.

### Interaction with Render Arena

**Risk:** Virtual text tables allocated via `render_arena.alloc_table()` are
recycled when the arena scope ends. If the frame cache stores references to
arena-allocated tables, those references become dangling after scope end.

**Mitigation:** Frame cache values for virt_lines must be allocated outside
the render arena (using normal Lua table constructors, not
`render_arena.alloc_table(scope_id)`). The render arena should only be used
for ephemeral intermediate tables that are consumed within the same scope.
Cache entries that persist across frames must own their data independently.
This is especially important in `embed.lua` where `render_single_embed()`
uses per-embed arena scopes (lines 277-331) — the arena-allocated virt_lines
are consumed by `nvim_buf_set_extmark()` (which copies the data), but a
separate non-arena copy must be made for frame cache storage.
