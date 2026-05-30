# 29 — Tiered Cache Invalidation

## Priority: HIGH
## Phase: 2 (Scalability)
## Dependencies: None (standalone; complements Doc 16 Subscription Lifecycle Management)
## Inspired By: Zed's `InlayHintCache` three-level invalidation in `crates/editor/src/inlay_hint_cache.rs`, snapshot retention/pruning in `crates/project/src/lsp_store.rs`

---

## Zed's Approach

Zed's inlay hint cache defines three explicit invalidation levels that control how aggressively cached data is discarded:

```rust
// inlay_hint_cache.rs (lines 63-80)
/// A logic to apply when querying for new inlay hints and deciding what to do
/// with the old entries in the cache in case of conflicts.
#[derive(Debug, Clone, Copy)]
pub(super) enum InvalidationStrategy {
    /// Hints reset is requested by the LSP server.
    /// Demands to re-query all inlay hints needed and invalidate all cached entries,
    /// but does not require instant update with invalidation.
    ///
    /// Despite nothing forbids language server from sending this request on every edit,
    /// it is expected to be sent only when certain internal server state update,
    /// invisible for the editor otherwise.
    RefreshRequested,

    /// Multibuffer excerpt(s) and/or singleton buffer(s) were edited at least on one place.
    /// Neither editor nor LSP is able to tell which open file hints' are not affected,
    /// so all of them have to be invalidated, re-queried and do that fast enough to avoid
    /// being slow, but also debounce to avoid loading hints on every fast keystroke sequence.
    BufferEdited,

    /// A new file got opened/new excerpt was added to a multibuffer/a [multi]buffer
    /// was scrolled to a new position.
    /// No invalidation should be done at all, all new hints are added to the cache.
    ///
    /// A special case is the settings change: in addition to LSP capabilities, Zed allows
    /// omitting certain hint kinds (defined by the corresponding LSP part: type/parameter/other).
    /// This does not lead to cache invalidation, but would require cache usage for determining
    /// which hints are not displayed and issuing an update to inlays on the screen.
    None,
}
```

The key insight is that **not all changes require the same cache response**. The three levels operate across three dimensions:

1. **Cache level:** `should_invalidate()` (lines 110-115) returns `true` for `RefreshRequested` and `BufferEdited`, triggering cache clearing and pending task removal. Returns `false` for `None`, keeping all existing entries intact.
2. **Timing level:** `RefreshRequested`/`BufferEdited` use `invalidate_debounce` (sourced from `edit_debounce_ms` setting, lines 274, 303). `None` uses `append_debounce` (sourced from `scroll_debounce_ms`, lines 275, 304). Debounce selection at lines 407-414: `should_invalidate()` → `invalidate_debounce`, else → `append_debounce`.
3. **Hint removal level:** During `calculate_hint_updates` (lines 1082-1171, invalidation logic at lines 1135-1159), when `invalidate` is true, hints not in the fresh result set are removed from both the visible display and the cache. When false, fresh hints are merged additively.
4. **LSP request throttling:** When `invalidate=false` (scrolling), LSP requests are throttled to max 5 concurrent via semaphore (lines 945-952). When `invalidate=true`, the semaphore is bypassed to prioritize visible range updates.

Triggers (from `InlayHintRefreshReason` enum in `editor.rs` lines 1602-1611, mapping logic at lines 5066-5159):

| Reason | Strategy | ignore_debounce | When Triggered |
|--------|----------|-----------------|----------------|
| `ModifiersChanged(enabled)` | `RefreshRequested` if enabled | Yes | Modifiers (Ctrl/Cmd/Shift) held while viewing hints |
| `Toggle(enabled)` | `RefreshRequested` if enabled | Yes | Inlay hints toggled on/off |
| `SettingsChange(...)` | `RefreshRequested` | Yes | Settings (hint kinds) changed |
| `ExcerptsRemoved(...)` | Early return (no strategy) | Yes | Excerpts removed from multibuffer |
| `RefreshRequested` | `RefreshRequested` | No | LSP server requests refresh |
| `BufferEdited(...)` | `BufferEdited` | No | User edits buffer content |
| `NewLinesShown` | `None` | No | New buffer area scrolled into view |

Zed applies this same principle to LSP snapshots in `lsp_store.rs`:

- `OLD_VERSIONS_TO_RETAIN = 10` (line 2667) — at most ~11 snapshots per buffer per server
- Binary search for version lookup via `binary_search_by_key` (line 2686)
- Pruning applied reactively on every `buffer_snapshot_for_lsp_version()` call (line 2692): `snapshots.retain(|s| s.version + 10 >= requested_version)` — bounded history, no explicit scheduler

---

## Problem

### Current State of Invalidation

The vault plugin has **two invalidation pathways** that operate independently:

1. **Subscriber-based** (`vault_index._notify_update`): Subscribers receive `(generation, context)` where context contains `changed_paths` and `deleted_paths`. Currently used by `connections.lua` and `embed_sync.lua` for scoped invalidation.
2. **Generation-based** (`gen_cache` / manual generation comparison): Caches compare `idx._generation` against their stored generation on access. On mismatch, the entire cache is rebuilt. Used by `calendar.lua`, `task_kanban.lua`, `match_field.lua`, `completion_base.lua`, and `_ensure_aggregates()`.

The second pathway is the primary source of waste: `gen_cache.gen_cache()` (gen_cache.lua lines 25-55) does a full rebuild on _any_ generation change, regardless of what actually changed.

### Current Invalidation Flow

```
User saves note-A.md
  → vault_index incremental build processes 1 file
  → _apply_staged() calls _notify_update({ changed_paths = {"note-A.md"}, deleted_paths = {} })
  → _generation increments (e.g., 41 → 42)

Subscriber-based (scoped — ALREADY WORKING):
  connections.lua: on_index_update() → adds "note-A.md" to _pending_changed
    → prepare_compute() removes only note-A.md from _note_data_cache (incremental)
    → invalidate_file() removes note-A.md + dependents from _cache (LRU)
    → ensure_idf() does incremental IDF update via update_tag_idf_incremental()
  embed_sync.lua: on_index_update() → checks _dep_to_bufs inverted index
    → only rerenders buffers whose embeds depend on note-A.md

Generation-based (FULL REBUILD — the problem):
  completion_base.lua: cache_valid() sees _cached_gen (41) ≠ idx._generation (42)
    → invalidate() releases all pooled items, nulls cached_items
    → next completions() triggers full debounced async rebuild of all items
  calendar.lua: gen_cache.get() sees cached_gen (41) ≠ gen (42)
    → scan_dates_from_index() iterates ALL files via idx:snapshot_files()
  task_kanban.lua: gen_cache.get() sees cached_gen (41) ≠ gen (42)
    → task_utils.collect_tasks() iterates ALL files
  match_field.lua: maybe_invalidate_section_cache() sees gen ≠ _section_cache_generation
    → _section_cache:clear() wipes entire LRU + intern pool
  vault_index._ensure_aggregates(): _aggregates_gen (41) ≠ _generation (42)
    → iterates ALL files to rebuild _cached_tags, _cached_tag_counts, _cached_fm_keys,
      _cached_name_cache, _cached_sorted_names, _cached_aliases
```

### What Already Works

Several modules already have partial or scoped invalidation:

| Module | Current Behavior | Scoped? |
|--------|-----------------|---------|
| connections.lua (lines 1036-1052) | Subscriber-based: tracks `_pending_changed` per-file, `_pending_full_clear` as fallback. `invalidate_file()` (lines 1086-1104) removes source + dependents from LRU. Incremental IDF update via `update_tag_idf_incremental()` (lines 160-216). | **Yes** |
| embed_sync.lua (lines 64-100) | Subscriber-based: inverted dependency index (`_dep_to_bufs`), O(changed_paths) lookup. Falls back to full rerender when context is nil. | **Yes** |
| autolink.lua (lines 326-347) | No local cache — reads vault_index on demand, triggers `apply(bufnr)` re-render on invalidation via engine cache registry. | N/A (no cache) |
| completion_base.lua (lines 185-192, 227-240) | Full invalidation on generation mismatch. Item pool release + rebuild. Engine cache registry (lines 118-130). | **No** |
| calendar.lua (lines 124-128) | gen_cache: full rebuild via `scan_dates_from_index()` (lines 36-119) on any generation change. Already tracks file sources per date entry (rel_path, abs_file, line, kind). Engine registration at lines 675-692. | **No** |
| task_kanban.lua (lines 35-75) | gen_cache (via task_utils.gen_cache delegation) with composite keys: full rebuild on generation change. Two-level cache (raw_tasks via task_utils lines 210-215 + filtered buckets). Engine registration at lines 774-788. | **No** |
| match_field.lua (lines 53-71) | LRU section outlinks cache (weighted, NOT gen_cache): full `_section_cache:clear()` + `string_intern.clear(_lowercase_pool)` on generation mismatch via `maybe_invalidate_section_cache()` (lines 64-71). | **No** |
| vault_index._ensure_aggregates (lines 1160-1231) | Full rebuild of _cached_tags, _cached_tag_counts, _cached_fm_keys, _cached_name_cache, _cached_aliases, _cached_sorted_names on generation mismatch. Already has `_cached_tag_counts` (tag → count map, line 1211). | **No** |

### Waste Quantified

Consider a vault with 500 notes. User edits `daily-2026-03-07.md` and saves. Only modules that still do full rebuilds are counted:

| Cache | Entries Invalidated | Entries Actually Stale | Waste Ratio |
|-------|-------------------|----------------------|-------------|
| completion items | ~500 items released + rebuilt | 1 item changed | 500:1 |
| calendar dates (gen_cache) | All files rescanned | 1 file's dates | ~500:1 |
| task_kanban (gen_cache) | All tasks recollected | 1 file's tasks | ~500:1 |
| _cached_tags / _cached_fm_keys | Full rebuild from all files | Tags/keys from 1 file | ~500:1 |
| section outlinks cache | Entire LRU cleared | 1 file's sections | unbounded |

Note: connections.lua and embed_sync.lua are **NOT** in this table — they already do scoped invalidation.

### The Existing Context Object Is Underused

The subscriber system already passes a context object with `changed_paths` and `deleted_paths`:

```lua
-- vault_index.lua lines 224-229
---@param context? { changed_paths?: string[], deleted_paths?: string[] }
function M.VaultIndex:_notify_update(context)
  self._generation = self._generation + 1
  for _, fn in ipairs(self._subscribers) do
    local ok, err = pcall(fn, self._generation, context)
    if not ok then log.debug("subscriber notification failed: %s", err) end
  end
end
```

**Subscriber storage:** `self._subscribers` is a plain `function[]` array (type annotation at line 108, initialized at line 162). The `subscribe(fn)` method (lines 204-214) stores plain functions directly — NOT `{fn, interests}` tables.

**Path format note:** `_apply_staged()` (line 353) passes **relative paths** in context. `update_files_batch()` (vault_index_build.lua lines 190-250) converts to **absolute paths** (vault_path + "/" + rel_path at lines 237-245) before calling `_notify_update()` at line 248. Subscribers must handle both formats — connections.lua already does this via `engine.vault_relative(abs_path)` (line 1047).

Only `connections.lua` and `embed_sync.lua` currently subscribe and use context. The `gen_cache` consumers (calendar, kanban, aggregates) have no subscriber at all — they poll generation on access. The `engine.invalidate_caches()` dispatch (engine.lua lines 60-113) supports `invalidate_file(abs_path)` but only connections.lua implements it (at line 1086 via `engine.register_cache()`).

---

## Solution

Introduce a three-tier invalidation strategy where the vault index classifies each update by its scope, and cache consumers respond proportionally. This primarily targets the `gen_cache` consumers and `_ensure_aggregates()` that currently do full rebuilds.

### Tier Definitions

**Tier 1: FULL**

Triggered by events that invalidate the entire index state:

- `:VaultIndexRebuild` (explicit user request)
- Vault path switch (different vault opened)
- `FocusGained` after extended absence (external tools may have modified many files)
- Incremental build where changed file count exceeds `partial_file_threshold`
- `_notify_update(nil)` — no context available (connections.lua already handles this via `_pending_full_clear`)

Action: All caches clear completely and rebuild from scratch.

**Tier 2: PARTIAL**

Triggered by events that affect specific, identifiable files:

- Single or few files saved (`BufWritePost`)
- Incremental index update with `changed_paths` below threshold
- File rename or delete

Action: Caches invalidate only entries associated with the changed files. Unrelated entries remain valid.

**Tier 3: ADDITIVE**

Triggered by events that only expand the index:

- New file created (no existing entries affected)
- New alias added to an existing file (expands lookup, does not invalidate existing lookups)
- New tag appears for the first time

Action: Caches append new entries without clearing existing ones. No entry removal, no rebuild.

### Change Context Object

Extend the current context parameter with tier classification and change type detail:

```lua
---@class InvalidationContext
---@field tier "full"|"partial"|"additive"
---@field changed_paths string[]|nil    -- relative paths of changed files
---@field deleted_paths string[]|nil    -- relative paths of deleted files
---@field added_paths string[]|nil      -- relative paths of newly created files
---@field change_types ChangeTypes|nil  -- what kinds of data changed
---@field generation number             -- current _generation value

---@class ChangeTypes
---@field frontmatter boolean
---@field tags boolean
---@field headings boolean
---@field outlinks boolean
---@field tasks boolean
---@field aliases boolean
---@field block_ids boolean
```

### Tier Classification in vault_index.lua

The index determines the tier during `_notify_update` based on what happened:

```lua
--- Classify the invalidation tier based on the change context.
---@param context table|nil Raw context from _apply_staged or update_files_batch
---@return InvalidationContext
function M.VaultIndex:_classify_invalidation(context)
  if not context then
    -- No context = assume worst case
    return { tier = "full", generation = self._generation }
  end

  local changed = context.changed_paths or {}
  local deleted = context.deleted_paths or {}
  local added = context.added_paths or {}

  -- If too many files changed, escalate to full
  local total_affected = #changed + #deleted + #added
  if total_affected > config.invalidation.partial_file_threshold then
    return {
      tier = "full",
      generation = self._generation,
      changed_paths = changed,
      deleted_paths = deleted,
      added_paths = added,
    }
  end

  -- If only additions (no modifications or deletions), use additive tier
  if #changed == 0 and #deleted == 0 and #added > 0 then
    return {
      tier = "additive",
      generation = self._generation,
      added_paths = added,
      change_types = context.change_types,
    }
  end

  -- Default: partial invalidation scoped to affected files
  return {
    tier = "partial",
    generation = self._generation,
    changed_paths = changed,
    deleted_paths = deleted,
    added_paths = added,
    change_types = context.change_types,
  }
end
```

**Additive tier detection:** Currently `_apply_staged()` (vault_index.lua lines 312-354) receives `staged`, `deleted`, `old_entries`, `changed_rel_paths`, and `is_cold_start`. It does not separate newly-added files from modified files. To enable additive detection, the build must track which rel_paths are new (not previously in `self.files`). The old_entries parameter already provides this: if `old_entries[rel_path]` is nil, the file is new. Similarly, `update_files_batch()` (vault_index_build.lua lines 190-250) tracks `changed_rel_paths` and `deleted_rel_paths` but does not distinguish new from modified.

### Change Type Detection

During the incremental build, when a file is re-parsed, the index can diff the old and new entry to determine what actually changed. The `old_entries` parameter already flows through `_apply_staged()` (line 312) — this adds a diff step before `_notify_update`:

```lua
--- Compare old and new parsed entry to determine what changed.
---@param old_entry table|nil Previous index entry for this file
---@param new_entry table Newly parsed entry
---@return ChangeTypes
local function diff_entry(old_entry, new_entry)
  if not old_entry then
    -- New file: everything is "changed"
    return {
      frontmatter = true, tags = true, headings = true,
      outlinks = true, tasks = true, aliases = true, block_ids = true,
    }
  end
  return {
    frontmatter = not deep_equal(old_entry.frontmatter, new_entry.frontmatter),
    tags        = not shallow_set_equal(old_entry.tags, new_entry.tags),
    headings    = not shallow_list_equal(old_entry.headings, new_entry.headings),
    outlinks    = not shallow_set_equal(old_entry.outlinks, new_entry.outlinks),
    tasks       = not shallow_list_equal(old_entry.tasks, new_entry.tasks),
    aliases     = not shallow_set_equal(old_entry.aliases, new_entry.aliases),
    block_ids   = not shallow_set_equal(old_entry.block_ids, new_entry.block_ids),
  }
end
```

When multiple files change in one batch, the `change_types` fields are OR'd together.

---

## Subscriber-Side Integration

### Subscription With Interest Declaration

Subscribers declare which change types they care about. The index skips notification for subscribers whose interests do not overlap with the actual changes:

```lua
--- Enhanced subscribe: declare interests for filtered notifications.
--- Backward compatible: plain functions still work (receive all notifications).
---@param opts function|{ fn: function, interests?: string[] }
---@return function unsubscribe
function M.VaultIndex:subscribe(opts)
  local entry
  if type(opts) == "function" then
    entry = { fn = opts, interests = nil } -- nil = all interests
  else
    entry = { fn = opts.fn, interests = opts.interests }
  end

  self._subscribers[#self._subscribers + 1] = entry
  return function()
    for i, sub in ipairs(self._subscribers) do
      if sub == entry then
        table.remove(self._subscribers, i)
        return
      end
    end
  end
end

--- Check whether a subscriber's interests overlap with the change types.
---@param interests string[]|nil  Subscriber's declared interests (nil = match all)
---@param change_types ChangeTypes|nil  What changed (nil = assume all changed)
---@return boolean
local function interests_overlap(interests, change_types)
  if not interests or not change_types then return true end
  for _, field in ipairs(interests) do
    if change_types[field] then return true end
  end
  return false
end
```

This filtering is purely an optimization. Subscribers are always free to ignore notifications they do not care about. The interest declaration prevents the subscriber's callback from being called at all for irrelevant changes, avoiding function call overhead and any work the callback might do before checking relevance.

**Migration note:** The current subscriber system (vault_index.lua lines 204-214, type annotation at line 108: `---@field _subscribers function[]`) stores plain functions in `_subscribers`. This change wraps each entry in a `{ fn, interests }` table. The `_notify_update` dispatch (lines 224-229) must be updated to call `sub.fn(gen, ctx)` instead of `sub(gen, ctx)`. Existing plain-function subscribers (connections.lua's `cleanup.subscription_handle` wrapper at lines 1056-1058, embed_sync.lua's `M.on_index_update`) are auto-wrapped with `interests = nil`.

### Updated _notify_update

```lua
function M.VaultIndex:_notify_update(context)
  self._generation = self._generation + 1

  local inv_ctx = self:_classify_invalidation(context)

  for _, sub in ipairs(self._subscribers) do
    -- Skip subscribers whose interests do not overlap
    if inv_ctx.tier == "full"
        or interests_overlap(sub.interests, inv_ctx.change_types) then
      local ok, err = pcall(sub.fn, self._generation, inv_ctx)
      if not ok then log.debug("subscriber notification failed: %s", err) end
    end
  end
end
```

Note: `tier = "full"` always notifies all subscribers regardless of interest declarations.

### gen_cache Enhancement

The `gen_cache` factory (gen_cache.lua) provides two variants: `gen_cache()` (single-value, lines 25-55) and `keyed_gen_cache()` (multi-key, lines 63-90). Both do full rebuilds on any generation change — `gen_cache` rebuilds its single value, `keyed_gen_cache` clears all entries. `task_utils.lua` re-exports both (lines 169, 176). To support tiered invalidation, gen_cache consumers need to subscribe to vault_index and handle tiers. Two approaches:

**Option A: Subscribe instead of poll.** Convert gen_cache consumers to vault_index subscribers that receive `InvalidationContext` and act on the tier. This is the approach shown in the per-module sections below.

**Option B: Extend gen_cache with a partial builder.** Add an optional `partial_fn` to gen_cache that receives the context and updates the cached value in-place:

```lua
function M.gen_cache(build_fn, opts)
  local cached_gen = 0
  local cached_key = nil
  local cached_value = nil
  local key_fn = opts and opts.key_fn
  local partial_fn = opts and opts.partial_fn  -- NEW

  return {
    get = function(...)
      local idx = current_index()
      if not idx then return nil end

      local gen = idx._generation or 0
      local key = key_fn and key_fn(...) or nil

      if cached_value ~= nil and cached_gen == gen and (not key_fn or cached_key == key) then
        return cached_value
      end

      -- If partial builder exists and we have a cached value, try partial update
      if partial_fn and cached_value ~= nil and idx._last_inv_ctx then
        local ctx = idx._last_inv_ctx
        if ctx.tier ~= "full" then
          cached_value = partial_fn(cached_value, idx, ctx, ...)
          cached_gen = gen
          cached_key = key
          return cached_value
        end
      end

      cached_value = build_fn(idx, ...)
      cached_gen = gen
      cached_key = key
      return cached_value
    end,
    invalidate = function()
      cached_value = nil
      cached_gen = 0
      cached_key = nil
    end,
  }
end
```

Option A is recommended for modules that need fine-grained control. Option B is a lighter-weight path for simpler caches.

---

## Per-Module Tier Handling

### connections.lua — ALREADY SCOPED (minor enhancement)

connections.lua already has the most sophisticated invalidation in the codebase:

- **Subscriber-based tracking** (lines 1036-1052): `on_index_update(_gen, context)` populates `_pending_changed` with changed rel_paths, sets `_pending_full_clear` when context is nil.
- **Per-file LRU removal** (lines 1086-1104): `invalidate_file(abs_path)` removes the changed file's cache entry + all entries whose `deps` set includes the changed file.
- **Incremental IDF** (lines 160-216): `update_tag_idf_incremental(files)` handles added/removed/changed files by diffing `_idf_file_tags` — decrements old tag counts, increments new ones.
- **Note data incremental removal** (lines 736-783): `prepare_compute()` calls `ensure_subscription()`, then removes only `_pending_changed` entries from `_note_data_cache` LRU (lines 748-752), falls back to full clear when `_pending_full_clear` or subscriber is inactive (lines 745-747). Resets pending state at lines 754-755.
- **Subscription via cleanup** (lines 1056-1058): Uses `cleanup.subscription_handle()` wrapper with `weak_state = _state_anchor` for defense-in-depth against module unload.

**Remaining enhancement with tiered invalidation:**

```lua
-- connections.lua — enhanced subscriber using InvalidationContext
local function on_index_update(_gen, ctx)
  if ctx.tier == "full" then
    _pending_full_clear = true
    return
  end

  if ctx.tier == "additive" then
    -- New files don't affect existing connection scores.
    -- IDF changes slightly (new documents in corpus).
    -- Mark IDF stale so it incrementally updates on next compute.
    _idf_cache = nil
    _idf_gen = 0
    return
  end

  -- PARTIAL: existing behavior — track changed files for incremental removal
  for _, list in ipairs({ ctx.changed_paths, ctx.deleted_paths }) do
    if list then
      for _, path in ipairs(list) do
        -- Handle both abs and rel paths (context format varies by caller)
        local rel = engine.vault_relative(path) or path
        _pending_changed[rel] = true
      end
    end
  end
end

-- Subscribe with interests (NEW: interest declaration)
idx:subscribe({
  fn = on_index_update,
  interests = { "tags", "outlinks", "frontmatter", "aliases" },
})
```

**Net new work:** Add interest declaration. Add additive tier shortcut (skip `_pending_changed` tracking for pure additions). The partial path is already implemented.

### completion_base.lua — NEEDS PER-FILE SUPPORT

Currently: full invalidation only (lines 185-192). `invalidate()` releases all pooled items via `_item_pool:release_batch(cached_items)`, nulls `cached_items` and `_cached_gen`, increments `build_generation`. `cache_valid()` (lines 227-240) compares `idx._generation` against `_cached_gen` and also checks vault path. Registered with engine cache registry (lines 118-130) as `"completions"` with `M.invalidate_all` (clears all sources + `_field_cache`), but no `invalidate_file` implementation. Build paths: coroutine-based `build_iter` (lines 327-389, uses `yield_iter.run_async()` with adaptive batching) and legacy synchronous `build` (lines 303-325).

**Proposed tiered handler:**

```lua
-- completion_base.lua — tiered response via engine cache registry
-- Add invalidate_file to the cache spec:
engine.register_cache({
  name = source_name,
  module = "andrew.vault.completion_base",
  invalidate = invalidate,  -- existing full-clear path
  invalidate_file = function(abs_path)
    if not cached_items then return end
    local rel = engine.vault_relative(abs_path)
    if not rel then return end

    -- Remove stale item(s) for this file
    local new_items = {}
    for _, item in ipairs(cached_items) do
      if item.data and item.data.rel_path ~= rel
          or not item.data then
        new_items[#new_items + 1] = item
      else
        _item_pool:release(item)
      end
    end

    -- Rebuild item for changed file (if it still exists in index)
    local vi = package.loaded["andrew.vault.vault_index"]
    if vi then
      local idx = vi.current()
      if idx and idx.files[rel] then
        local item = opts.build_single and opts.build_single(rel, idx.files[rel])
        if item then new_items[#new_items + 1] = item end
      end
    end

    cached_items = new_items
    -- Update _cached_gen to current generation
    if vi then
      local idx = vi.current()
      if idx then _cached_gen = idx._generation end
    end
  end,
  stats = function() ... end,
})
```

**Prerequisite:** Each completion source's `create_source()` opts must provide a `build_single(rel_path, entry)` function that builds one completion item for one file. Currently `build_iter` builds all items iteratively — extracting the per-file logic into `build_single` is straightforward.

**Additive tier:** When `engine.invalidate_caches({ scope = "files", paths = ... })` is called for a new file, `invalidate_file` is invoked. If the file was not previously in `cached_items`, the handler simply appends it.

### calendar.lua — CONVERT FROM gen_cache TO SUBSCRIBER

Currently: `_deadline_cache = gen_cache.gen_cache(...)` (lines 124-128) with `key_fn` returning `engine.vault_path` for composite keying. On any generation change, `scan_dates_from_index()` (lines 36-119) iterates ALL files via `idx:snapshot_files()`. Also has `_log_cache = gen_cache.keyed_gen_cache(...)` (lines 178-201) for per-month Log directory scanning. Both caches registered with engine at lines 675-692.

The calendar cache already tracks file provenance: each date entry stores `{ text, file, abs_file, line, kind }` (lines 80-108) with deduplication by `(rel_path, date_str, kind)`.

**Proposed: replace gen_cache with subscriber + manual cache:**

```lua
-- calendar.lua — tiered response
local _deadline_data = nil       -- table<date_str, item[]>
local _deadline_gen = 0

local function handle_calendar_invalidation(_gen, ctx)
  if ctx.tier == "full" then
    _deadline_data = nil
    _deadline_gen = 0
    return
  end

  if not _deadline_data then return end  -- nothing cached yet

  if ctx.tier == "partial" then
    local affected = {}
    for _, p in ipairs(ctx.changed_paths or {}) do affected[p] = true end
    for _, p in ipairs(ctx.deleted_paths or {}) do affected[p] = true end

    -- Remove date entries contributed by affected files
    for date_str, items in pairs(_deadline_data) do
      for i = #items, 1, -1 do
        if affected[items[i].file] then
          table.remove(items, i)
        end
      end
      if #items == 0 then _deadline_data[date_str] = nil end
    end

    -- Rescan only affected files and merge their dates back in
    local idx = vault_index.current()
    if idx then
      for _, p in ipairs(ctx.changed_paths or {}) do
        local entry = idx.files[p]
        if entry then
          scan_single_file_dates(entry, p, _deadline_data)
        end
      end
    end

    _deadline_gen = _gen
    return
  end

  -- ADDITIVE: scan only new files, merge into existing cache
  if ctx.tier == "additive" then
    local idx = vault_index.current()
    if idx then
      for _, p in ipairs(ctx.added_paths or {}) do
        local entry = idx.files[p]
        if entry then
          scan_single_file_dates(entry, p, _deadline_data)
        end
      end
      _deadline_gen = _gen
    end
  end
end

-- Subscribe with interests
idx:subscribe({
  fn = handle_calendar_invalidation,
  interests = { "frontmatter", "tasks" },
})
```

**Required new function:** `scan_single_file_dates(entry, rel_path, date_table)` — extracted from the inner loop of `scan_dates_from_index()` (lines 44-116). Processes one file's configured indicators and merges results into the existing date table.

### match_field.lua — PER-FILE LRU REMOVAL

Currently: `maybe_invalidate_section_cache(index)` (lines 64-71) clears the entire `_section_cache` weighted LRU (configured via `config.cache.section_outlinks_bytes` / `config.cache.section_cache_max`) + `string_intern.clear(_lowercase_pool)` on any generation change.

The section cache is already keyed by `rel_path` (line 198: `_section_cache:get(rel)` in `get_section_outlinks()`), so per-file removal is straightforward:

```lua
--- Tiered section cache invalidation.
---@param index table VaultIndex instance
---@param ctx InvalidationContext|nil
function M.invalidate_section_cache(index, ctx)
  if not ctx or ctx.tier == "full" then
    _section_cache:clear()
    string_intern.clear(_lowercase_pool)
    _section_cache_generation = index and index._generation or 0
    return
  end

  if ctx.tier == "partial" then
    -- Only remove cache entries for changed/deleted files
    for _, list in ipairs({ ctx.changed_paths, ctx.deleted_paths }) do
      for _, p in ipairs(list or {}) do
        _section_cache:remove(p)
      end
    end
    _section_cache_generation = ctx.generation
    -- Note: intern pool is NOT cleared — entries for unchanged files remain valid
    return
  end

  -- ADDITIVE: new files have no existing cache entries. No action needed.
  _section_cache_generation = ctx.generation
end
```

**Savings:** For a 200-entry section cache, single-file edit removes 1 entry instead of clearing all 200.

### Aggregate Caches (_cached_tags, _cached_fm_keys)

These are sets/maps derived from all index entries. `_ensure_aggregates()` (vault_index.lua lines 1160-1231) rebuilds everything on generation mismatch.

**Existing infrastructure that helps:**
- `_cached_tag_counts` already exists (line 1211): `tag → count` map — this IS reference counting for tags.
- `old_entries` flows through `_apply_staged()` — available for diffing old vs new.

**What's still needed:** Reference counting for `_cached_fm_keys` (currently a flat sorted array, no counts). And `_cached_tags` is also a flat sorted array — the counts exist in `_cached_tag_counts` but the sorted array must be rebuilt from the counts on change.

```lua
-- vault_index.lua — tiered aggregate update
function M.VaultIndex:_update_aggregates_partial(ctx, old_entries)
  if not self._cached_tags or not self._cached_fm_keys then
    -- Never built; fall through to full rebuild
    self:_ensure_aggregates()
    return
  end

  local tags_changed = false
  local fm_keys_changed = false

  for _, rel_path in ipairs(ctx.changed_paths or {}) do
    local old_entry = old_entries and old_entries[rel_path]
    local new_entry = self.files[rel_path]

    -- Tags: decrement old counts, increment new counts
    if old_entry then
      for _, tag in ipairs(old_entry.tags or {}) do
        local count = (self._cached_tag_counts[tag] or 1) - 1
        if count <= 0 then
          self._cached_tag_counts[tag] = nil
          tags_changed = true
        else
          self._cached_tag_counts[tag] = count
        end
      end
    end
    if new_entry then
      for _, tag in ipairs(new_entry.tags or {}) do
        local prev = self._cached_tag_counts[tag]
        self._cached_tag_counts[tag] = (prev or 0) + 1
        if not prev then tags_changed = true end
      end
    end

    -- Frontmatter keys: same pattern (needs _cached_fm_key_counts)
    if old_entry and old_entry.frontmatter then
      for key in pairs(old_entry.frontmatter) do
        local count = (self._cached_fm_key_counts[key] or 1) - 1
        if count <= 0 then
          self._cached_fm_key_counts[key] = nil
          fm_keys_changed = true
        else
          self._cached_fm_key_counts[key] = count
        end
      end
    end
    if new_entry and new_entry.frontmatter then
      for key in pairs(new_entry.frontmatter) do
        local prev = self._cached_fm_key_counts[key]
        self._cached_fm_key_counts[key] = (prev or 0) + 1
        if not prev then fm_keys_changed = true end
      end
    end
  end

  -- Handle deletions (same pattern as above, only decrement)
  for _, rel_path in ipairs(ctx.deleted_paths or {}) do
    local old_entry = old_entries and old_entries[rel_path]
    if old_entry then
      for _, tag in ipairs(old_entry.tags or {}) do
        local count = (self._cached_tag_counts[tag] or 1) - 1
        if count <= 0 then
          self._cached_tag_counts[tag] = nil
          tags_changed = true
        else
          self._cached_tag_counts[tag] = count
        end
      end
      if old_entry.frontmatter then
        for key in pairs(old_entry.frontmatter) do
          local count = (self._cached_fm_key_counts[key] or 1) - 1
          if count <= 0 then
            self._cached_fm_key_counts[key] = nil
            fm_keys_changed = true
          else
            self._cached_fm_key_counts[key] = count
          end
        end
      end
    end
  end

  -- Only rebuild sorted arrays if membership changed
  if tags_changed then
    local tags = {}
    for tag in pairs(self._cached_tag_counts) do
      tags[#tags + 1] = tag
    end
    table.sort(tags)
    self._cached_tags = tags
  end
  if fm_keys_changed then
    local keys = {}
    for key in pairs(self._cached_fm_key_counts) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    self._cached_fm_keys = keys
  end

  -- _cached_name_cache and _cached_sorted_names: update incrementally
  -- (already handled by _update_name_index_incremental in _apply_staged)

  self._aggregates_gen = self._generation
end
```

**Prerequisite:** Add `_cached_fm_key_counts` field (similar to existing `_cached_tag_counts`). Initialize it during `_ensure_aggregates()` alongside `_cached_tags`.

---

## Configuration

```lua
-- config.lua additions (after M.index section which ends around line 384)
-- NOTE: No M.invalidation section currently exists in config.lua — this is new.
M.invalidation = {
  enable_tiered = true,         -- Master switch; false = current behavior (always full)
  partial_file_threshold = 50,  -- Files changed above this count → escalate to FULL tier
  debug = false,                -- Log tier classification decisions
}
```

**Rationale:**

- `enable_tiered = true` by default: the optimization is safe (worst case: a stale cache entry gets rebuilt on next access) and the benefit is significant.
- `partial_file_threshold = 50`: When 50+ files change simultaneously (e.g., bulk rename, git checkout), the overhead of per-file cache surgery exceeds the cost of a full rebuild. The threshold is configurable for vaults of different sizes. Compare with `config.index.progress_threshold = 50` (line 374) which uses the same heuristic for progress bar display.
- `debug = false`: Tier classification logging is useful during development but adds noise in production. When enabled, logs include the tier chosen, the number of affected files, and which change types were detected.

---

## Monitoring

Extend `:VaultIndexStatus` to show invalidation tier statistics:

```
Invalidation Stats:
  Total notifications:  247
  Tier breakdown:
    FULL:       3  (1.2%)    -- vault switch, 2 manual rebuilds
    PARTIAL:  231  (93.5%)   -- single-file saves
    ADDITIVE:  13  (5.3%)    -- new file creations
  Subscriber skips:    412   -- notifications filtered by interest mismatch
  Cache rebuilds saved: ~218 -- PARTIAL/ADDITIVE that would have been FULL
```

```lua
-- vault_index.lua stats tracking
self._inv_stats = {
  total = 0,
  full = 0,
  partial = 0,
  additive = 0,
  subscriber_skips = 0,
}
```

---

## Implementation Notes

### Backward Compatibility

The enhanced subscriber system is fully backward-compatible. Existing subscribers registered as plain functions (not `{ fn, interests }` tables) continue to work — they are auto-wrapped with `interests = nil` and receive all notifications regardless of tier, exactly as they do today. The `_notify_update` function detects whether each subscriber entry has a `.fn` field and dispatches accordingly.

**connections.lua compatibility:** connections.lua currently subscribes via `cleanup.subscription_handle()` (lines 1056-1058) which wraps the callback with `weak_state = _state_anchor`. The wrapper function will be auto-detected as a plain function subscriber. To use interest declarations, the subscription must be updated to pass `{ fn = on_index_update, interests = {...} }`.

**engine.invalidate_caches compatibility:** The engine cache registry (`register_cache()` at engine.lua lines 52-56, `invalidate_caches()` at lines 60-113) already supports `invalidate_file(abs_path)`. Modules that implement `invalidate_file` in their cache spec receive per-file calls when `engine.invalidate_caches({ scope = "files", paths = [...] })` is invoked (lines 73-75). This complements the subscriber system — engine dispatch handles the file watcher path, while subscribers handle the index build path.

### Change Type Detection Cost

Diffing old vs new entry in `diff_entry()` runs once per changed file during the incremental build. For the common case (1-3 files), this is negligible. The diff functions are shallow: tag comparison is O(tags), frontmatter comparison is O(keys), heading comparison is O(headings). No deep recursive comparison is needed because these fields are flat lists or single-level maps.

### Previous Entry Retention

The `old_entries` parameter already flows through the build pipeline: `build_async()` (vault_index_build.lua lines 68-76) captures old entries before mutation, and passes them to `_apply_staged()` (vault_index.lua line 312). `update_files_batch()` (lines 190-250) also captures old entries and passes them to `_update_name_index_incremental()` (line 232), `_recompute_inlinks_incremental()` (line 233), and `_update_precomputed_sets_incremental()` (line 234). To support change type detection, `old_entries` must be forwarded to `_notify_update()` and made available to `_classify_invalidation()` for diff computation.

This adds no additional memory — `old_entries` is already captured and scoped to the batch. The only change is passing it one level further.

### Aggregate Reference Counting

`_cached_tag_counts` already exists (vault_index.lua line 1211) as a `tag → count` map. `_cached_fm_key_counts` does NOT currently exist — converting `_cached_fm_keys` to reference-counted requires adding this field. One number per unique frontmatter key. For a vault with 50 unique frontmatter keys, this is negligible. Note: `_ensure_aggregates()` also rebuilds `_cached_aliases` (lines 1220-1225) and `_cached_sorted_names` (lines 1227-1229) — these are not addressed by this doc as they are already handled incrementally by `_update_name_index_incremental()` (lines 859-913) during `_apply_staged()`.

### Tier Escalation Safety

If a partial invalidation handler encounters an unexpected state (e.g., cache structure does not support per-file removal), it should fall back to full invalidation rather than silently producing incorrect results:

```lua
if ctx.tier == "partial" then
  local ok = pcall(partial_invalidate, ctx)
  if not ok then
    full_invalidate()
    log.warn("partial invalidation failed, fell back to full")
  end
  return
end
```

### Path Format Normalization

`_apply_staged()` passes **relative paths** in context. `update_files_batch()` passes **absolute paths**. Subscribers must handle both. Options:

1. **Normalize at source:** Ensure `_notify_update` always receives relative paths. This requires `update_files_batch()` to strip the vault_path prefix before calling `_notify_update`.
2. **Normalize at subscriber:** Each subscriber converts as needed (connections.lua already does this via `engine.vault_relative()`).

Option 1 is cleaner — normalize once at the source rather than in every subscriber.

### Interaction With Other Docs

- **Doc 16 (Subscription Lifecycle):** The interest-based filtering in this doc complements Doc 16's lifecycle management. A subscriber with declared interests that is also properly lifecycle-managed (auto-unsubscribe on module teardown) is both efficient and leak-free. connections.lua already uses `cleanup.subscription_handle()` for lifecycle management.
- **Doc 17 (Snapshot-Based Reads):** If snapshot reads are implemented, the `old_entries` retention needed for change-type detection can reuse the snapshot infrastructure rather than maintaining a separate copy.
- **Doc 21 (Stale Operation Cancellation):** Partial invalidation reduces the frequency of cancellation events. A single-file change that previously triggered a full rebuild (and cancelled in-progress operations) now triggers a scoped update that may not require cancellation at all.

### Thread Safety

Not applicable — Neovim's Lua runtime is single-threaded. All invalidation classification, subscriber notification, and cache updates run on the main thread. Coroutine yields during `build_async` are safe because `_notify_update` is called after the batch completes, not during it.

---

## Validation

1. **Tier classification:** Verify single-file save produces `tier = "partial"`, new file produces `tier = "additive"`, `:VaultIndexRebuild` produces `tier = "full"`.
2. **Interest filtering:** Verify a subscriber with `interests = {"tags"}` is NOT notified when only headings change. Verify it IS notified when tags change. Verify it is always notified on `tier = "full"`.
3. **Partial connections (existing):** Save `note-A.md`, verify `_pending_changed` contains note-A.md. Verify `_note_data_cache` removes only note-A.md on next `prepare_compute()`. Verify `invalidate_file()` removes note-A.md + dependents from `_cache` LRU.
4. **Partial completion (new):** Save `note-A.md`, verify `invalidate_file(abs_path)` removes and rebuilds only note-A.md's completion item. Verify items for all other notes are unchanged.
5. **Partial calendar (new):** Save a note with a due date change. Verify only that note's dates are rescanned. Verify other dates are untouched.
6. **Additive completion:** Create a new note. Verify it appears in completion items. Verify no existing items were rebuilt (check item count = old + 1).
7. **Aggregate ref counting:** Add a tag `#project` to two notes. Remove it from one. Verify `_cached_tag_counts["#project"]` decrements to 1 and the tag remains in `_cached_tags`. Remove from the second. Verify count drops to 0 and the tag disappears.
8. **Threshold escalation:** Simulate 51 files changed. Verify tier escalates to "full" when `partial_file_threshold = 50`.
9. **Fallback safety:** Introduce an error in the partial handler. Verify it falls back to full invalidation and logs a warning.
10. **Backward compat:** Register a plain function subscriber (no interests). Verify it receives all notifications at all tiers. Verify connections.lua's `cleanup.subscription_handle` wrapper works unchanged.
11. **Path normalization:** Verify context always contains relative paths in `_notify_update`, regardless of whether triggered by `_apply_staged` or `update_files_batch`.
12. **Section cache partial:** Save `note-A.md`, verify only `_section_cache:remove("note-A.md")` is called. Verify other section cache entries remain intact.

---

## Expected Impact

### Cache Rebuild Reduction

| Scenario | Current | With Tiered Invalidation | Reduction |
|----------|---------|--------------------------|-----------|
| Single file save | 5 gen_cache full rebuilds + connections (scoped) | 0 full rebuilds, 5 partial updates | ~80-90% |
| New note created | 5 gen_cache full rebuilds + connections (scoped) | 0 full rebuilds, 5 additive appends | ~90-95% |
| Rename 1 file | 5 gen_cache full rebuilds + connections (scoped) | Partial: targeted updates | ~80% |
| `:VaultIndexRebuild` | All caches full rebuild | All caches full rebuild | 0% (same) |
| Bulk import 100 files | All caches full rebuild | All caches full rebuild (threshold) | 0% (correct escalation) |

### Per-Module Savings (500-note vault, single-file save)

| Module | Current Work | With Tiered | Speedup |
|--------|-------------|-------------|---------|
| connections.lua | Already scoped: O(1) file removal + incremental IDF | Add interest filtering (skip unrelated notifications) | ~1.2x |
| completion_base.lua | Release all pooled items, full async rebuild (~500 items) | Remove + rebuild 1 item synchronously | ~500x |
| calendar.lua | gen_cache full rebuild: iterate all files | Remove + rescan 1 file's dates | ~500x |
| task_kanban.lua | gen_cache full rebuild: collect all tasks | Partial task recollection (1 file) | ~500x |
| _cached_tags/_cached_fm_keys | Iterate all 500 entries, rebuild sorted arrays | Decrement/increment counts for 1 file | ~500x |
| section outlinks cache | Clear entire 200-entry LRU | Remove 1 LRU entry | ~200x |
| embed_sync.lua | Already scoped: O(changed_paths) inverted index lookup | No change needed | 1x |

### Responsiveness Impact

- **Save-to-ready latency:** Currently, saving a file triggers full rebuilds in gen_cache consumers that can take 50-200ms across all caches. With tiered invalidation, the partial update path completes in <5ms for a single file. connections.lua and embed_sync.lua already achieve this.
- **Typing flow:** Completion items remain valid during partial updates. The user does not experience a gap where completions disappear and reappear (currently, `invalidate()` nulls `cached_items` causing a brief completion gap until the async rebuild completes).
- **Calendar rendering:** Calendar view does not flicker on unrelated file saves because its cache remains valid.
