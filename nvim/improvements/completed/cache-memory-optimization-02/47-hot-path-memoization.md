# 47. Hot-Path Memoization

## Problem

Several vault operations perform expensive lookups repeatedly within a single
operation scope (render pass, search filter, completion build) without caching
intermediate results. The vault already has multiple caching primitives —
`filter_utils.create_memoized_resolver()`, `memoize.lua` (MemoizedCheck),
`gen_cache.lua`, `file_cache.lua`, `frame_cache.lua`, `render_arena.lua` — but
some hot paths still have avoidable redundant work.

### ~~1. wikilinks.resolve_link() — repeated resolution in embed render~~ COMPLETED

`embed_resolver.resolve_embed()` (embed_resolver.lua:16-21) calls
`wikilinks.resolve_link()` for every embed in a buffer. `resolve_link()`
(wikilinks.lua:162-189) performs three-stage resolution: relative path check →
vault index lookup (via `link_utils.resolve_note_via_index()`) → temporal alias
fallback. This is called in three places during a render pass:

- `warm_embed_cache()` (embed.lua:207-219) calls `resolver.resolve_embed()` per
  embed to pre-read cross-file targets into `file_cache`.
- `render_single_embed()` (embed.lua:251-377, resolve call at line 259) calls
  `resolver.resolve_embed()` again per embed during actual rendering.
- Dependency tracking at embed.lua:260 (non-image) and embed.lua:284 (image),
  with `update_deps()` (defined at lines 35-38) called at embed.lua:600
  (render_embeds), embed.lua:655 (do_render_pass), and embed.lua:1091 (scroll
  handler passes deps to do_render_pass).

The render orchestrator `render_embeds()` (embed.lua:448-636) creates an arena
scope at line 510 and calls `warm_embed_cache()` at line 541. It builds render
context via `build_render_ctx()` (embed.lua:128-146, called at line 576) which is
passed to render functions. Two rendering paths exist: lazy mode (lines 578-592,
renders visible zone, defers prefetch zones via `scheduler.schedule()`) and
legacy mode (lines 593-598, synchronous loop).

When a buffer contains multiple embeds pointing to the same note (e.g.,
`![[Reference Note#Section1]]`, `![[Reference Note#Section2]]`), the same name
is resolved from scratch each time — once in warm-up and once in render. A buffer
with 15 embeds referencing 4 unique notes runs up to 30+ full resolutions (15 in
warm-up + 15 in render + dependency tracking) instead of 4.

**What's already cached:** `file_cache.lua` (LRU with mtime validation) caches
file content after the first disk read. `frame_cache.lua` caches rendered
virt_lines across frames. `warm_embed_cache()` uses a `seen` table (arena-
allocated at line 208) to avoid duplicate `file_cache.read()` calls. But the
`resolve_embed()` → `resolve_link()` path itself (relative path check, vault
index lookup by name, alias check, temporal alias fallback) has no per-render-
pass memoization.

### ~~2. frecency.ranked_files() — globpath instead of vault index~~ COMPLETED

~~`frecency.ranked_files()` calls `vim.fn.globpath()` on every invocation.~~

**Status:** Already implemented. `frecency.lua` (lines 105-140, index path at
117-131) now uses
`vault_index.current()` with `idx:snapshot_files()` as the primary path, falling
back to `vim.fn.globpath()` only when the index is not ready:

```lua
local idx = vault_index.current()
local all_rels
if idx and idx:is_ready() then
  all_rels = {}
  for rel_path in pairs(idx:snapshot_files()) do
    all_rels[#all_rels + 1] = rel_path
  end
else
  -- Fallback: filesystem glob when index not ready
  local all_files = vim.fn.globpath(engine.vault_path, "**/*.md", false, true)
  all_rels = {}
  for _, f in ipairs(all_files) do
    all_rels[#all_rels + 1] = engine.vault_relative(f)
  end
end
```

### ~~3. embed.lua / link_utils.lua — repeated cross-file reads~~ COMPLETED

~~`read_all_lines()` performs `io.open`/read/close per call with no caching.~~

**Status:** Already implemented via `file_cache.lua`. `link_utils.read_all_lines()`
(link_utils.lua:229-234) delegates to `file_cache.read()`:

```lua
local function read_all_lines(source)
  if type(source) == "table" then
    return source
  end
  return file_cache.read(source)
end
```

`file_cache.lua` (read at lines 39-71, get_section at lines 78-103) is an LRU
cache with mtime-based invalidation, weighted capacity limits
(`config.cache.file_content_bytes`, `config.cache.file_content_max`), and
section-level caching via `get_section()`. `resolve_content()`
(link_utils.lua:375-426) uses `file_cache.get_section()` for heading sections
(line 284) and block references (line 337), and `file_cache.read()` for
full-file reads (line 418). `link_utils.read_heading_section()` and
`read_block_content()` use `file_cache.get_section()` for section-level caching.

### ~~4. link_utils.resolve_content() — no content caching~~ COMPLETED

See Problem #3 above — resolved by the same `file_cache.lua` integration.

### ~~5. search_filter.build_filter_context() — date recomputation~~ COMPLETED

`build_filter_context()` (search_filter.lua:170-243) pre-resolves date values
like `"today"`, `"7d"`, `"this-week"` into timestamps via
`date_utils.resolve_date()` (date_utils.lua:136-218). This is correctly cached
within a single `evaluate()` call via `ctx.resolved_dates`. However, when live
search calls `evaluate()` on every keystroke, each call builds a fresh context
(via `prepare_evaluate()` at line 421-455) and re-resolves the same date strings.

`evaluate()` (search_filter.lua:457-491) creates its own arena scope at line 459
and calls `prepare_evaluate()` (lines 421-455) at line 461 to build context,
extract pre-checks (bloom filters, set lookups), and return a predicate function.
`evaluate_async()` (search_filter.lua:505-553) follows the same pattern, creating
its own arena scope at line 518 and calling `prepare_evaluate()` at lines
520-521.

The context now uses `render_arena` for scope-local allocation, including
additional fields beyond dates:

```lua
function M.build_filter_context(ast, index, arena_scope)
  local alloc = arena_scope and render_arena.alloc_table or nil
  local ctx = alloc and alloc(arena_scope) or {}
  ctx.resolved_dates = alloc and alloc(arena_scope) or {}
  ctx.parsed_tags = alloc and alloc(arena_scope) or {}
  ctx.numeric_values = alloc and alloc(arena_scope) or {}
  ctx.bloom_pre_checked = alloc and alloc(arena_scope) or {}
  -- ...
end
```

`date_utils.lua` has its own module-level LRU cache (`_parse_cache` at line 91,
sized via `config.cache.date_parse_max`) for ISO datetime parsing
(`parse_iso_datetime()` at lines 86-126), but this only covers
`parse_iso_datetime()`, not `resolve_date()` (lines 151-218). Task date
resolution has a
separate `resolve_task_date_cached()` in `match_task.lua` (lines 89-105).

Values like `"today"` change at most once per day but are recomputed hundreds of
times per session.

### ~~6. connections.lua IDF computation~~ COMPLETED

~~`connections.lua` uses manual `_idf_cache`/`_idf_gen`/`_idf_total` variables.~~

**Status:** Already refactored. IDF is now served directly from
`vault_index._summary_tree` (O(1) lookup), as noted at connections.lua:46.
The `ensure_idf()` function (lines 632-637) retrieves IDF data via
`vi._summary_tree:query("")`:

```lua
-- connections.lua:46:
-- IDF is now served directly from vault_index._summary_tree (O(1) lookup).

-- ensure_idf() at lines 632-637:
local root = vi._summary_tree:query("")
return root.tag_file_counts, root.file_count
```

The connection cache itself (lines 36-44, `config.cache.connections_bytes` /
`config.cache.connections_max` / `weighers.connections`) uses a weighted LRU
(`lru_cache.new_weighted()`) with generation + TTL validation
(`filter_utils.is_cache_gen_valid()` at lines 702-714):

```lua
local ttl = config.connections.cache_ttl
local now = vim.uv.now() / 1000
local cached = _cache:get(source_rel_path)
if filter_utils.is_cache_gen_valid(cached, index_gen_check, "index_gen")
  and (now - cached.timestamp) < ttl
then
  return cached.results
end
```

## Existing Caching Infrastructure

The vault now has a rich set of caching primitives. This section documents them
so that new memoization work builds on existing patterns rather than duplicating
them.

### memoize.lua — MemoizedCheck (version-keyed per-key cache)

`memoize.lua` provides a `MemoizedCheck` class (lines 9-17 type def, constructor,
`:get()`) that pairs a version function with a computation
function. Cached results are returned when the version matches, recomputed
otherwise. Includes eviction (configurable via `config.memoize.max_entries`),
`:invalidate(key)` (lines 67-74), `:clear()` (lines 76-80), and debug stats
(`_hits`, `_misses`).

```lua
local memoize = require("andrew.vault.memoize")

local check = memoize.new(
  memoize.changedtick,          -- version_fn(key)
  function(bufnr) return expensive_scan(bufnr) end,
  "my_check"                    -- optional name for debug
)
local result = check:get(bufnr)
```

Pre-built version functions (lines 131-152): `changedtick()`,
`index_generation()`, `changedtick_and_generation()` (composite string
"tick:gen").

### gen_cache.lua — Generation-based caching

`gen_cache.lua` provides two factories tied to `vault_index._generation`:

- `gen_cache.gen_cache(build_fn, opts)` (lines 25-85) — Single-value cache,
  invalidated when generation changes. Supports composite keys via `opts.key_fn`
  and incremental updates via `opts.partial_fn` (called when generation advances
  by exactly 1, avoiding full recomputation).
- `gen_cache.keyed_gen_cache(build_fn)` (lines 93-133) — Multi-key cache, all
  entries invalidated when generation changes. Tracks evictions separately.

```lua
local gen_cache = require("andrew.vault.gen_cache")

local my_cache = gen_cache.gen_cache(function(idx)
  return expensive_computation(idx)
end)
local result = my_cache.get()
```

### file_cache.lua — LRU file content cache

Weighted LRU cache with mtime-based invalidation (`read()` at lines 39-71,
`get_section()` at lines 78-103). Two tiers:
- `_cache` — Full file content (only unlimited reads cached)
- `_section_cache` — Heading/block extractions (keyed by path + `\0` + fragment)

Additional API: `invalidate(path)` removes a file and all its sections,
`clear()` empties both caches, `stats()` returns size/hits/misses/bytes.

### filter_utils.create_memoized_resolver() — Scope-local index resolution

(Lines 52-64)

```lua
function M.create_memoized_resolver(idx, arena_scope)
  local cache = arena_scope and require("andrew.vault.render_arena").alloc_table(arena_scope) or {}
  return function(link_path)
    local cached = cache[link_path]
    if cached ~= nil then return cached or nil end
    local result = M.resolve_in_index(idx, link_path) or false
    cache[link_path] = result
    return result or nil
  end
end
```

Used in: `filter_utils.bfs_init()`, `search_filter.build_filter_context()`
(line 240), `connections.lua`, `graph/search_graph.lua`.
All call sites pass an optional `arena_scope` for render_arena-managed allocation.

### Other caches

- `frame_cache.lua` — Two-frame promotion cache for rendered virt_lines
- `render_arena.lua` — Scope-local table allocation (GC'd at scope exit).
  `begin_scope()` (lines 119-130), `alloc_table(scope_id)` (lines 136-165),
  `alloc_array(scope_id, capacity)` (lines 172-192, LuaJIT pre-sized array),
  `end_scope(scope_id)` (lines 197-232), `is_valid(scope_id)` (lines 237-240).
- `line_parse_cache.lua` — Line parsing cache
- `lru_cache.lua` — Generic LRU / weighted LRU implementation
- `cache_weighers.lua` — Weight functions for cache sizing
- `date_utils._parse_cache` (line 91) — LRU for ISO datetime parsing
  (`parse_iso_datetime()` at lines 86-126), sized via `config.cache.date_parse_max`.
  Separate from per-evaluate `ctx.resolved_dates`. `resolve_date()` at lines
  151-218 has no dedicated cache.
- `slug.lua` — Maintains its own LRU cache for heading-to-slug conversions
  (used by `link_utils.heading_to_slug` at line 144)

## Inspiration

### Zed's version-gated caching (buffer.rs)

**File:** `crates/language/src/buffer.rs`

Zed caches `has_unsaved_edits` as a `Cell<(clock::Global, bool)>` tuple
(line 127):

```rust
/// Memoize calls to has_changes_since(saved_version).
/// The contents of a cell are (self.version, has_changes) at the time of a last call.
has_unsaved_edits: Cell<(clock::Global, bool)>,
```

The memoization implementation (lines 1945-1958):

```rust
fn has_unsaved_edits(&self) -> bool {
    let (last_version, has_unsaved_edits) = self.has_unsaved_edits.take();

    if last_version == self.version {
        self.has_unsaved_edits
            .set((last_version, has_unsaved_edits));
        return has_unsaved_edits;
    }

    let has_edits = self.has_edits_since(&self.saved_version);
    self.has_unsaved_edits
        .set((self.version.clone(), has_edits));
    has_edits
}
```

The boolean is only recomputed when the buffer's Lamport clock version advances
past the cached version. This eliminates redundant diff-based comparisons that
would otherwise run on every frame or event.

**Vault analogue:** `memoize.lua` MemoizedCheck implements the same pattern.

### Existing vault pattern: filter_utils.create_memoized_resolver()

See "Existing Caching Infrastructure" section above. This scope-local
memoization pattern is used in 4 locations. Now accepts an optional `arena_scope`
parameter for render_arena-managed allocation.

### Zed's line layout cache (line_layout.rs)

**File:** `crates/gpui/src/text_system/line_layout.rs`

Zed's text layout system uses a double-buffered frame cache (lines 392-404):

```rust
// Lines 392-396
pub(crate) struct LineLayoutCache {
    previous_frame: Mutex<FrameCache>,
    current_frame: RwLock<FrameCache>,
    platform_text_system: Arc<dyn PlatformTextSystem>,
}

// Lines 398-404
#[derive(Default)]
struct FrameCache {
    lines: FxHashMap<Arc<CacheKey>, Arc<LineLayout>>,
    wrapped_lines: FxHashMap<Arc<CacheKey>, Arc<WrappedLineLayout>>,
    used_lines: Vec<Arc<CacheKey>>,
    used_wrapped_lines: Vec<Arc<CacheKey>>,
}
```

Cache keys (`CacheKey` at lines 619-626) combine text content (`SharedString`),
font size (`Pixels`), styling runs (`SmallVec<[FontRun; 1]>`), optional
`wrap_width`, and optional `force_width`. A borrowed `CacheKeyRef` variant
enables zero-copy lookups.
On `finish_frame()` (lines 458-466), current/previous frames are swapped —
the previous frame serves as a fallback for cache lookups before recomputation.
`LineLayoutCache` (lines 392-396) is separate from `FrameCache` (lines 398-404).

**Vault analogue:** `frame_cache.lua` implements the same two-frame promotion
pattern for embed virt_lines.

### Zed's InlayHintCache — versioned multi-key cache with debounce

**File:** `crates/editor/src/inlay_hint_cache.rs`

The `InlayHintCache` struct (lines 34-46) uses a global `version: usize` counter
(line 37) incremented on settings changes, along with `enabled`, `modifiers_override`,
`update_tasks`, `refresh_task`, debounce durations, and an `lsp_request_limiter`.
Per-excerpt entries in `CachedExcerptHints` (lines 55-61) track
`buffer_version: clock::Global` (line 57) for Lamport-clock-based invalidation.
Three invalidation strategies via `InvalidationStrategy` enum (lines 65-80):
`RefreshRequested` (full), `BufferEdited` (debounced), `None` (append mode).

**Vault analogue:** `gen_cache.lua` uses `vault_index._generation` as the version
counter. `connections.lua` (lines 706-713) uses generation + TTL for invalidation.

### Zed's SyntaxSnapshot — multi-version tracking

**File:** `crates/language/src/syntax_map.rs`

Tracks `parsed_version` (`clock::Global`, updated at line 785 after reparsing),
`interpolated_version` (`clock::Global`, updated at line 290 in `interpolate()`),
`language_registry_version` (`usize`, checked at line 417 against
`registry.version()`), and `update_count` (`usize`, incremented at line 450)
independently (struct at lines 29-36). Different version domains invalidate
different parts of the cache — a language registry change re-parses layers,
while an edit interpolates existing layers.

**Vault analogue:** `memoize.changedtick_and_generation()` composes two version
domains (buffer edits + index changes) into a single composite version string.

## Design

~~Two remaining memoization opportunities, building on existing infrastructure:~~ BOTH COMPLETED

```
Pattern A: Scope-Local Path Memo    Pattern B: Session-Stable Date Memo
+-------------------------+        +---------------------------+
| created at render_embeds|        | day = "2026-03-31"        |
| scope entry             |        | today_ts = ...            |
|                         |        |                           |
| cache = {} (arena)      |        | if day changed:           |
| GC'd at scope exit      |        |   reset cache             |
+-------------------------+        | else: return cached       |
 lifetime: one render pass          +---------------------------+
                                    lifetime: until day changes
```

### ~~Pattern A: Scope-Local Path Memo for Embed Rendering~~ COMPLETED

~~For batch operations where the same note name is resolved multiple times within a
single render pass. Uses `render_arena` for allocation so the cache is GC'd at
scope exit.~~

**Status:** Already implemented. `create_resolve_memo()` (embed.lua:118-131) creates
a scope-local memoized resolver for `resolve_embed()` with the same false-sentinel
pattern as `filter_utils.create_memoized_resolver()`. Called at line 549 in
`render_embeds()`, passed to `warm_embed_cache()` at line 550, and stored in the
render context via `build_render_ctx()` at line 585. `render_single_embed()` uses
`ctx.resolve_fn` at line 267 instead of calling `resolver.resolve_embed()` directly.

### ~~Pattern B: Session-Stable Date Memo~~ COMPLETED

~~For date values that change at most once per day. A module-level cache keyed by
date string, invalidated when the calendar day changes.~~ This lifts the per-call
`ctx.resolved_dates` caching to persist across `evaluate()` invocations.

## Target Application Points

### ~~1. embed.lua — Scope memo for resolve_embed() path resolution~~ COMPLETED

**Status:** Already implemented. `create_resolve_memo()` (embed.lua:118-131) is an
arena-allocated scope-local memo created at line 549 and passed to both
`warm_embed_cache()` (line 550) and `build_render_ctx()` (line 585). All render-path
resolution goes through `ctx.resolve_fn` (line 267).

**Original analysis:** `warm_embed_cache()` (embed.lua:207-219) calls
`resolver.resolve_embed()` per embed (line 212). `render_single_embed()`
(embed.lua:251-377, resolve call at line 259) calls it again. Dependency tracking
happens at lines 260 (non-image) and 284 (image), with `update_deps()` (defined
at lines 35-38) called at lines 600 (render_embeds) and 655 (do_render_pass at
lines 646-656, shared between on_prefetch and scroll handler at line 1091). No
memoization on the resolution path itself.

**What's already cached:** The `seen` table in `warm_embed_cache()` (arena-
allocated at line 208) deduplicates `file_cache.read()` calls but not the
`resolve_embed()` calls themselves. `file_cache.lua` caches file content after
the first disk read. `frame_cache` (checked at lines 264-277 in
`render_single_embed()`, stored at lines 369-372) caches rendered virt_lines
output.

**Change:** Create a scope-local memo at the top of the render closure in
`render_embeds()` (embed.lua:448-636, arena scope at line 510) that memoizes
`resolve_embed()` results by name. Pass this memo to both `warm_embed_cache()`
(called at line 541) and through the render context (`build_render_ctx()` at
lines 128-146, called at line 576) to `render_single_embed()`.

```lua
-- In render_embeds(), after arena_scope = render_arena.begin_scope() (line 510):
local resolve_memo = arena_scope and render_arena.alloc_table(arena_scope) or {}

-- Memoized resolve_embed wrapper
local function memo_resolve(name)
  local cached = resolve_memo[name]
  if cached ~= nil then
    return cached ~= false and cached or nil
  end
  local result = resolver.resolve_embed(name, bufpath) or false
  resolve_memo[name] = result
  return result or nil
end
```

Update `warm_embed_cache()` (currently takes `descs, bufpath, arena_scope`) to
accept and use the memo function as a fourth parameter:

```lua
local function warm_embed_cache(descs, bufpath, arena_scope, resolve_fn)
  local seen = arena_scope and render_arena.alloc_table(arena_scope) or {}
  for _, desc in ipairs(descs) do
    if not desc.is_image then
      local details = link_utils.parse_target(desc.inner)
      local path = resolve_fn(details.name)  -- uses memo
      if path and path ~= bufpath and not seen[path] then
        seen[path] = true
        file_cache.read(path)
      end
    end
  end
end
```

Update the call site at line 541: `warm_embed_cache(new_descs, bufpath, arena_scope, memo_resolve)`

Update `render_single_embed()` to use `ctx.resolve_fn` instead of calling
`resolver.resolve_embed()` directly:

```lua
-- In render_single_embed() (line 259):
path = ctx.resolve_fn(details.name)  -- instead of resolver.resolve_embed(details.name, bufpath)
```

**Impact:** A buffer with 15 embeds from 4 unique notes: 4 `resolve_link()` calls
instead of up to 30 (87% reduction). The `file_cache` already handles content
deduplication — this adds resolution deduplication on top.

### ~~2. search_filter.lua — Daily memo for date resolution~~ COMPLETED

**Status:** Already implemented. Module-level `_date_memo`/`_date_memo_day` with
`get_or_reset_date_memo()` (search_filter.lua:52-65) provides cross-evaluate caching.
`resolve_and_cache_date()` (lines 193-204) uses the two-tier lookup: daily memo first,
then `date_utils.resolve_date()` on miss.

**Original analysis:** `build_filter_context()` (search_filter.lua:170-243) creates a fresh
`ctx.resolved_dates` table per `evaluate()` call. The nested
`resolve_and_cache_date(val)` helper (lines 178-182) calls
`date_utils.resolve_date(val)` and stores the result or `false` sentinel. In live
search, `evaluate()` (lines 457-491) and `evaluate_async()` (lines 505-553)
are called on every keystroke, each time creating a new arena scope (line 459
or 518), calling `prepare_evaluate()` (lines 421-455) at line 461 or 520-521
which calls `build_filter_context()` at line 437, and re-resolving identical
date values.

The function uses `render_arena` for scope allocation (lines 171-176), including
`ctx.parsed_tags`, `ctx.numeric_values`, and `ctx.bloom_pre_checked` alongside
`ctx.resolved_dates`. But the date cache is still per-call.

Note: `date_utils._parse_cache` (LRU at line 91) caches ISO datetime parsing
(lines 86-126) but not `resolve_date()` results (lines 151-218).
`match_task.lua` has a separate `resolve_task_date_cached()` (lines 89-105) for
forward/backward-looking task date resolution.

**Change:** Lift date resolution to a module-level daily memo. This replaces the
per-call `resolve_and_cache_date()` (lines 178-182) with a two-tier lookup:

```lua
-- Module-level: persists across evaluate() calls, resets at midnight
local _date_memo = nil
local _date_memo_day = nil

local function get_or_reset_date_memo()
  local today = os.date("%Y-%m-%d")
  if today ~= _date_memo_day then
    _date_memo_day = today
    _date_memo = {}
  end
  return _date_memo
end

-- In build_filter_context() (replaces lines 178-182):
local function resolve_and_cache_date(val)
  if val and ctx.resolved_dates[val] == nil then
    local daily = get_or_reset_date_memo()
    if daily[val] ~= nil then
      ctx.resolved_dates[val] = daily[val]
    else
      local result = date_utils.resolve_date(val) or false
      daily[val] = result
      ctx.resolved_dates[val] = result
    end
  end
end
```

**Impact:** In live search with 30 keystrokes, date values like `"today"`,
`"7d"`, `"this-week"` are resolved once per day instead of 30 times. Individual
savings are microseconds, but the pattern eliminates an entire category of
unnecessary `os.time()` and string parsing.

**Caveat:** `ctx.resolved_dates` is still populated per-evaluate for use by
downstream match functions. The daily memo serves as a warm source, not a
replacement for the context table. The AST walk still needs to discover which
date values appear in the query.

## Implementation — ALL STEPS COMPLETED

### ~~Step 1: Add scope memo for resolve_embed in embed.lua~~ COMPLETED

Modify `render_embeds()` (embed.lua:448-636) to create a scope-local memo for
path resolution:

1. After `render_arena.begin_scope()` (line 510), create a memo table via
   `render_arena.alloc_table(arena_scope)`.
2. Create a `memo_resolve(name)` closure that caches `resolver.resolve_embed()`
   results (same false-sentinel pattern as `filter_utils.create_memoized_resolver`
   at lines 52-64).
3. Pass `memo_resolve` to `warm_embed_cache()` (line 541) as a new parameter.
4. Store `memo_resolve` in the render context (`build_render_ctx()` at lines
   128-146, add `resolve_fn` field) so `render_single_embed()` (line 259) and
   the dependency tracking calls (lines 600, 655, 1091) can use it instead of
   calling `resolver.resolve_embed()` directly. Dependency tracking at lines
   260 and 284 already uses the resolved path from the same call, so no
   additional changes are needed there.

This is backward-compatible: the memo is internal to the render pass and does not
change any public API.

### ~~Step 2: Add daily memo to search_filter.lua~~ COMPLETED

~~1. Add module-level `_date_memo` / `_date_memo_day` variables.~~
~~2. Add `get_or_reset_date_memo()` helper that resets the cache at midnight.~~
~~3. Modify `resolve_and_cache_date()` (lines 178-182) to check the daily memo
   before calling `date_utils.resolve_date()`.~~
~~4. Populate the daily memo on miss so subsequent `evaluate()` and
   `evaluate_async()` calls benefit.~~

All four sub-steps implemented at search_filter.lua:52-65 and :193-204.

## API

No new public API is introduced. Both changes are internal optimizations:

- **Embed resolve memo:** Internal to `render_embeds()`, allocated via
  `render_arena`, invisible to callers.
- **Date daily memo:** Module-level private state in `search_filter.lua`,
  invisible to callers. `build_filter_context()` signature unchanged.

## Relationship to Existing Patterns

### Extends filter_utils.create_memoized_resolver()

The embed resolve memo is the same pattern — a scope-local cache keyed by string,
with `false` sentinel for not-found. The difference is the target function
(`resolve_embed` instead of `resolve_in_index`) and the scope (render pass
instead of filter evaluation).

### Complements memoize.lua (MemoizedCheck)

MemoizedCheck is for version-keyed caches that persist across calls (e.g.,
buffer state checks keyed by changedtick). The embed resolve memo is
scope-local (one render pass). The date daily memo is session-stable (one day).
These are different invalidation lifetimes — MemoizedCheck handles the
"until-version-changes" lifetime, while these two changes handle "until-scope-
exits" and "until-day-changes" respectively.

### Complements gen_cache.lua

`gen_cache.lua` ties cache invalidation to `vault_index._generation`. The embed
resolve memo is finer-grained (one render pass) and the date memo is coarser-
grained (one day). Neither depends on vault index generation.

### Complements file_cache.lua

`file_cache.lua` caches file content (the I/O layer). The embed resolve memo
caches path resolution (the lookup layer above I/O). Together they form a
pipeline: resolve_memo avoids redundant name → path lookups, file_cache avoids
redundant path → content reads.

### Complements doc 34 (Memoized State Checks)

Doc 34 focuses on boolean state checks (is_vault_file, has_frontmatter,
has_embeds) cached via `(version, result)` tuples — now implemented as
`memoize.lua` MemoizedCheck. Doc 47 addresses **data-producing functions**
(path resolution, date resolution) in batch contexts.

| Aspect       | Doc 34 (MemoizedCheck)       | Doc 47 (remaining)          |
|--------------|------------------------------|-----------------------------|
| Return type  | Boolean                      | Paths, timestamps           |
| Cache key    | bufnr + changedtick          | name string, date string    |
| Lifetime     | Until version changes         | Scope (render) or day       |
| Primary users| Autocmds, guards             | Batch operations            |

### Complements doc 15 (Preview Render Caching)

Doc 15 caches rendered preview content. Doc 47 caches inputs to rendering
(resolved paths). The two form a pipeline: doc 47 avoids redundant I/O to
produce content, doc 15 avoids redundant rendering of that content.

## Configuration

No new config entries required. Both optimizations are zero-config:

- **Embed resolve memo:** Arena-allocated, bounded by number of unique embed
  names per buffer (typically < 50). GC'd when render_arena scope exits.
- **Date daily memo:** Bounded by number of unique date strings in queries
  (typically < 20). Reset at midnight.

## Expected Impact

### Embed rendering (primary target)

A buffer with 15 embeds from 4 unique files:
- **Path resolution:** 4 `resolve_link()` calls instead of up to 30 (87%
  reduction across warm-up + render)
- **File I/O:** Already addressed by `file_cache.lua` — no additional change
  needed
- **Estimated time saving:** ~5-15ms per render pass (resolution overhead,
  not I/O)

### Live search date resolution

- **30 keystrokes x 5 date values = 150 resolve_date() calls** reduced to
  **5 calls per day** (96% reduction within a session)
- Individual savings are microseconds, but eliminates unnecessary `os.time()`
  and string parsing during rapid typing

### Already completed (no further action needed)

- **Frecency file listing:** Vault index replaces globpath (50-100ms saving on
  2000-file vault). Globpath retained as fallback only.
- **File content caching:** `file_cache.lua` with LRU + mtime validation
  replaces raw `io.open` per call (70%+ reduction in file I/O).
- **IDF computation:** Served from `vault_index._summary_tree` (O(1)),
  connection cache uses weighted LRU with generation + TTL.

## Risks

1. **Scope memo retaining stale data within a render pass:** If a file is modified
   on disk by an external process during a render pass, the scope memo will serve
   the pre-modification resolution for subsequent embeds from that note. This is
   acceptable — the render pass is a point-in-time snapshot, and the next render
   (triggered by file watcher or autocmd) will read fresh content.

2. **Daily memo crossing midnight:** If a user is actively searching at midnight,
   date values cached from 23:59 will be served until the next query after
   00:00. The window is at most one query. For `"today"`, this means one query
   could filter against yesterday's date. This is negligible in practice.

3. **False sharing in scope memo:** If two conceptually different lookups use the
   same key string, they would collide. This is avoided by having the embed
   resolve memo keyed solely by embed name (the only dimension of its lookup).
