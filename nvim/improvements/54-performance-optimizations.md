# 54 --- Performance Optimizations (Index, Embeds, Images)

Four targeted performance improvements for the vault plugin, addressing
quadratic algorithms in the index, wasteful off-screen rendering in embeds,
and redundant filesystem I/O in image resolution.

> **Architecture note:** The vault index and embed systems have been refactored
> into submodules. The codebase now uses:
>
> - `vault_index.lua` (634 lines) — core index, delegates to submodules
> - `vault_index_build.lua` — async build and batch update logic
> - `vault_index_inlinks.lua` — inlink computation (full and incremental)
> - `vault_index_collisions.lua` — collision detection, notification, detail UI
> - `vault_index_parser.lua` — single-file parsing
> - `embed.lua` — main render orchestration
> - `embed_state.lua` — shared state dicts, parsing utilities, GC
> - `embed_images.lua` — image resolution, snacks placement integration
> - `embed_resolver.lua` — recursive content resolution
> - `embed_sync.lua` — vault index subscription, debounced re-renders
> - `engine_watcher.lua` — filesystem watcher (platform-aware)

---

## 1. Incremental Inlinks Recomputation

### Problem Analysis

**File:** `lua/andrew/vault/vault_index_inlinks.lua` (lines 80-89)

The full `I.recompute()` function is called via `_recompute_inlinks()` in three
places (all in `vault_index.lua`):

1. `load()` (line 165) — cold start from persisted JSON
2. `build_sync()` (line 453) — synchronous full rebuild
3. `build_async()` via `vault_index_build.lua` (line 81) — async full rebuild

Each call is **O(N * M)** where N = total files in the vault and M = average
outlinks per file. The `I.recompute()` function:

1. Calls `build_resolution_tables(files)` (lines 11-32) — iterates all files to
   build three lookup tables (by_name, by_path, by_alias). This alone is O(N).
2. Iterates every file's outlinks via `resolve_outlinks_into()`, resolving each
   link target through the lookup tables.
3. Builds the entire inlinks table from scratch.

```lua
-- Current implementation (vault_index_inlinks.lua, lines 80-89)
function I.recompute(files)
  local by_name, by_path, by_alias = build_resolution_tables(files) -- O(N)
  local inlinks = {}

  for _, source_entry in pairs(files) do                            -- O(N)
    resolve_outlinks_into(source_entry, by_path, by_name, by_alias, inlinks) -- O(M)
  end

  return inlinks
end
```

An incremental version (`I.recompute_incremental`) already exists (lines 98-145)
and is used by `update_files_batch()` in `vault_index_build.lua` (line 178).
However, the **full rebuild path** (`build_async`) still calls the non-incremental
version, which does redundant work when only a subset of files actually changed.

**Complexity:**
- Full rebuild: O(N * M) every time, even if only 5 of 2000 files changed.
- For a vault with 2000 files averaging 10 outlinks each, that is 20,000 link
  resolution operations on every `build_async()`.

### Proposed Solution

Modify `build_async()` in `vault_index_build.lua` to use
`_recompute_inlinks_incremental()` instead of the full `_recompute_inlinks()`
when operating on a diff (i.e., not a cold start). The key insight is that
`build_async()` already knows exactly which files changed and which were deleted
— these are the outputs of `_detect_changes()`.

**Key difference from `update_files_batch()`:** The incremental inlinks method
(`I.recompute_incremental`) does NOT require an `old_outlinks_map` parameter.
It takes `(files, inlinks, changed_rel_paths, deleted_rel_paths)` and handles
old-contribution removal by scanning the existing `inlinks` table for entries
whose source path matches the affected files (Phase 1), then re-resolves
outlinks for changed files (Phase 2).

**Algorithm:**

1. Collect `changed_rel_paths` and `deleted_rel_paths` during the batch loop.
2. After reparsing, call `_recompute_inlinks_incremental()` with those lists.
3. Reserve full `_recompute_inlinks()` for cold starts (no existing `_inlinks`).

**Data structure changes:** None. The existing `_inlinks` table structure and
the incremental method's interface are sufficient.

### Code Changes

**File: `lua/andrew/vault/vault_index_build.lua`**

**Before (lines 43-85):**

```lua
    -- Process deletions immediately
    for _, rel_path in ipairs(deleted) do
      index.files[rel_path] = nil
    end

    -- Process changed files in batches
    local processed = 0
    local batch_count = 0
    for i = 1, total, config.index.batch_size do
      -- ... batch processing ...
      coroutine.yield()
    end

    index:_rebuild_name_index()
    index:_recompute_inlinks()      -- <-- always full rebuild
    index._ready = true
```

**After:**

```lua
    -- Process deletions immediately
    local deleted_rel_paths = {}
    for _, rel_path in ipairs(deleted) do
      index.files[rel_path] = nil
      deleted_rel_paths[#deleted_rel_paths + 1] = rel_path
    end

    -- Process changed files in batches
    local processed = 0
    local batch_count = 0
    local changed_rel_paths = {}
    for i = 1, total, config.index.batch_size do
      local batch_end = math.min(i + config.index.batch_size - 1, total)
      for j = i, batch_end do
        local file = changed[j]
        local entry = parser.parse_file(file.abs_path, file.rel_path, file.stat)
        if entry then
          index.files[file.rel_path] = entry
          changed_rel_paths[#changed_rel_paths + 1] = file.rel_path
        end
        processed = processed + 1
      end
      batch_count = batch_count + 1
      -- ... progress notification ...
      coroutine.yield()
    end

    index:_rebuild_name_index()

    -- Use incremental inlinks when we have an existing inlinks table to
    -- patch. On cold start (no persisted index loaded), fall back to full
    -- rebuild since there is nothing to incrementally update.
    if is_cold_start or not index._inlinks or not next(index._inlinks) then
      index:_recompute_inlinks()
    else
      index:_recompute_inlinks_incremental(changed_rel_paths, deleted_rel_paths)
    end

    index._ready = true
```

### Expected Performance Improvement

For a warm `build_async()` where K files changed out of N total:

- **Before:** O(N * M) for full inlink rebuild (via `I.recompute`)
- **After:** O(K * M_inlinks + K * M_outlinks) where M_inlinks is the average
  inlinks per target of changed files, and M_outlinks is the outlinks of
  changed files only.

For the common case of 1-5 files changed in a 2000-file vault, this reduces
inlink recomputation from ~20,000 operations to ~50-250 operations — roughly
a **40-100x improvement**.

Note: `I.recompute_incremental` still calls `build_resolution_tables(files)`
(line 136) for Phase 2 link resolution, which is O(N). This is a potential
further optimization target (reuse existing `_name_index` / `_alias_index`
instead of rebuilding resolution tables).

The cold start path (no persisted index) remains unchanged since there is no
existing inlinks table to patch.

### Risk Assessment

- **Correctness:** The incremental method is already battle-tested by
  `update_files_batch()` (line 178 of `vault_index_build.lua`). The same
  two-phase algorithm (remove old contributions by scanning `inlinks` for
  affected source stems, then add new contributions via `resolve_outlinks_into`)
  is applied. No old outlinks snapshot is needed — the incremental method
  handles this internally.
- **Resolution table freshness:** `I.recompute_incremental` builds
  `build_resolution_tables()` from `files` (line 136), which by the time it
  runs will contain all new entries. This is correct — the same pattern used
  by `update_files_batch()`.
- **Edge case — renamed files:** A file renamed externally appears as a
  deletion + creation. Both will be in the changed/deleted lists, so the
  incremental path handles them correctly.
- **Regression path:** If the incremental result ever diverges from the full
  rebuild, the `:VaultIndexRebuild` command calls `build_sync()` (line 449 of
  `vault_index.lua`) which uses full `_recompute_inlinks()`, providing manual
  recovery.

---

## 2. Hash-Based Collision Detection

### Problem Analysis

**File:** `lua/andrew/vault/vault_index_collisions.lua` (lines 15-114)

The `C.detect()` function receives two pre-built indexes: `name_idx` (lowercase
name -> list of abs_paths) and `alias_idx` (lowercase alias -> list of
abs_paths). It is called from `_detect_collisions()` in `vault_index.lua`
(lines 417-424), which delegates to this module.

There are three separate passes with some redundant work:

1. **Pass 1 (alias-alias, lines 31-49):** Iterates all `alias_idx` entries,
   calls `unique_paths()` on each, checks `#uniq > 1`.
2. **Pass 2 (name-alias, lines 51-88):** Iterates all `alias_idx` entries
   again, looks up `name_idx[key]`, builds sets, computes set difference.
3. **Pass 3 (basename, lines 90-111):** Iterates all `name_idx` entries,
   filters out folder-qualified entries, calls `unique_paths()`.

The `unique_paths()` helper (lines 19-29) is a local function inside
`C.detect()`:

```lua
-- Current implementation (vault_index_collisions.lua, lines 19-29)
local function unique_paths(paths)
  local seen = {}
  local result = {}
  for _, p in ipairs(paths) do
    if not seen[p] then
      seen[p] = true
      result[#result + 1] = p
    end
  end
  return result
end
```

Each call allocates a new `seen` table and `result` table. For single-entry
lists (the ~95% common case), this is wasteful.

**Complexity:**
- Pass 1: O(A) where A = total alias entries
- Pass 2: O(A) again (separate loop over same `alias_idx`)
- Pass 3: O(K) where K = total name_idx keys
- `unique_paths()` allocations: one per alias key (pass 1) + one per basename
  key (pass 3) = A + K allocations, most producing single-element results

### Proposed Solution

**Optimization 1: Skip `unique_paths()` for single-entry lists.**

Add an early-exit: when `#paths <= 1`, return `paths` directly. This avoids
table allocation for the ~95% common case.

**Optimization 2: Merge Pass 1 and Pass 2 into a single loop.**

Both iterate over `alias_idx`. Combine them to avoid the second traversal.

**Optimization 3: Deduplicate at index build time (alternative).**

The `_rebuild_name_index()` method (lines 330-343 of `vault_index.lua`) uses
`add_entry_to_indexes()` (lines 313-327). Paths can appear twice for the same
key when a file's `basename_lower` equals its `rel_stem`. Adding dedup at
insertion time would make `unique_paths()` unnecessary in `C.detect()`.

### Code Changes

**Approach: Early-exit + merged passes in `vault_index_collisions.lua`**

**Before (lines 15-114 of `vault_index_collisions.lua`):** Three separate
iteration passes, `unique_paths()` called for every key.

**After:**

```lua
function C.detect(name_idx, alias_idx, rel_path_fn)
  local collisions = {}

  -- Helper: deduplicate only when needed (avoids alloc for single-entry case)
  local function dedup_paths(paths)
    if #paths <= 1 then return paths end
    local seen = {}
    local result = {}
    for _, p in ipairs(paths) do
      if not seen[p] then
        seen[p] = true
        result[#result + 1] = p
      end
    end
    return result
  end

  -- Combined alias pass: detect alias-alias AND name-alias in one loop
  for key, alias_paths in pairs(alias_idx) do
    local uniq_alias = dedup_paths(alias_paths)

    -- 1. Alias-alias collisions
    if #uniq_alias > 1 then
      local files = {}
      for _, p in ipairs(uniq_alias) do
        files[#files + 1] = rel_path_fn(p)
      end
      collisions[#collisions + 1] = {
        type = "alias-alias",
        key = key,
        files = files,
        message = string.format(
          'Alias "%s" defined by %d files: %s',
          key, #files, table.concat(files, ", ")
        ),
      }
    end

    -- 2. Name-alias collisions (piggyback on the same loop)
    local name_paths = name_idx[key]
    if name_paths then
      local alias_set = {}
      for _, p in ipairs(uniq_alias) do alias_set[p] = true end
      local name_set = {}
      for _, p in ipairs(name_paths) do name_set[p] = true end

      local conflicting = {}
      for p in pairs(alias_set) do
        if not name_set[p] then
          conflicting[#conflicting + 1] = rel_path_fn(p)
        end
      end

      if #conflicting > 0 then
        local name_files = {}
        for p in pairs(name_set) do
          name_files[#name_files + 1] = rel_path_fn(p)
        end
        collisions[#collisions + 1] = {
          type = "name-alias",
          key = key,
          name_files = name_files,
          alias_files = conflicting,
          message = string.format(
            'Name-alias conflict on "%s": name in %s, alias in %s',
            key,
            table.concat(name_files, ", "),
            table.concat(conflicting, ", ")
          ),
        }
      end
    end
  end

  -- 3. Basename collisions (with early-exit optimization)
  for name, paths in pairs(name_idx) do
    if not name:find("/") and #paths > 1 then
      local uniq = dedup_paths(paths)
      if #uniq > 1 then
        local files = {}
        for _, p in ipairs(uniq) do
          files[#files + 1] = rel_path_fn(p)
        end
        collisions[#collisions + 1] = {
          type = "basename",
          key = name,
          files = files,
          message = string.format(
            'Basename "%s" shared by %d files: %s',
            name, #files, table.concat(files, ", ")
          ),
        }
      end
    end
  end

  return collisions
end
```

**Alternative: Deduplicate at index build time**

A more impactful optimization is to deduplicate paths in
`add_entry_to_indexes()` (lines 313-327 of `vault_index.lua`), so
`C.detect()` can assume paths are already unique. This would use a secondary
set per key during `_rebuild_name_index()`:

```lua
-- In add_entry_to_indexes(), guard each insertion:
local function add_entry_to_indexes(entry, name_idx, alias_idx, name_seen, alias_seen)
  local lower, rel_stem, aliases = entry_index_keys(entry)

  -- Basename
  if not name_idx[lower] then
    name_idx[lower] = {}
    name_seen[lower] = {}
  end
  if not name_seen[lower][entry.abs_path] then
    name_seen[lower][entry.abs_path] = true
    name_idx[lower][#name_idx[lower] + 1] = entry.abs_path
  end

  -- Rel stem
  if rel_stem then
    if not name_idx[rel_stem] then
      name_idx[rel_stem] = {}
      name_seen[rel_stem] = {}
    end
    if not name_seen[rel_stem][entry.abs_path] then
      name_seen[rel_stem][entry.abs_path] = true
      name_idx[rel_stem][#name_idx[rel_stem] + 1] = entry.abs_path
    end
  end

  -- Aliases
  for _, alias in ipairs(aliases) do
    if not alias_idx[alias] then
      alias_idx[alias] = {}
      alias_seen[alias] = {}
    end
    if not alias_seen[alias][entry.abs_path] then
      alias_seen[alias][entry.abs_path] = true
      alias_idx[alias][#alias_idx[alias] + 1] = entry.abs_path
    end
  end
end
```

With this change, `C.detect()` can remove all `unique_paths()` / `dedup_paths()`
calls and use the paths directly, since they are guaranteed unique.

### Expected Performance Improvement

- **Before:** 3 separate passes (2 over alias_idx, 1 over name_idx) +
  `unique_paths()` table allocation per key per applicable pass.
- **After (merged passes):** 1 pass over alias_idx + 1 pass over name_idx.
  `dedup_paths()` short-circuits for single-entry lists (~95% of keys).
- **After (dedup at build time):** Zero dedup calls in `C.detect()`.

The improvement is modest in absolute terms (collision detection is already
fast), but eliminates unnecessary GC pressure from throwaway table allocations.

### Risk Assessment

- **Correctness:** The merged-passes approach produces identical collision
  lists — only the iteration order changes (irrelevant since collisions are
  stored as an unordered list).
- **Dedup at build time:** Changes the contract of `name_idx` / `alias_idx`
  (paths guaranteed unique). No current code relies on counting duplicates.
- **Incremental name index:** `_update_name_index_incremental()` (lines
  354-408 of `vault_index.lua`) would also need the `seen` sets if using the
  build-time dedup approach. It currently uses `add_entry_to_indexes()` in
  Phase 2 (line 397), so the `seen` tracking would need to persist on `self`.
- **Collision detection skip:** `_update_name_index_incremental` already skips
  collision detection for small batches (< 5 files, line 405). This is
  orthogonal to the dedup optimization.

---

## 3. Lazy Embed Rendering

### Problem Analysis

**File:** `lua/andrew/vault/embed.lua` (lines 61-212)

The `render_embeds()` function processes **every** `![[...]]` embed in the
buffer in a single synchronous pass. It uses `iterate_embeds()` (from
`embed_state.lua`) which scans all buffer lines calling `find_embed_spans()`
(lines 85-97 of `embed_state.lua`). Each embed requires:

- Pattern matching (`find_embed_spans` in `embed_state.lua`)
- Image check (`is_image_embed` in `embed_images.lua`, lines 47-55)
- For images: `resolve_image()` (up to 9 `fs_stat` calls per image, in
  `embed_images.lua` lines 84-89), snacks placement creation via
  `create_placement()` (lines 127-146)
- For notes: `resolve_embed()` (wikilink resolution via `embed_resolver.lua`),
  `resolve_embed_lines()` (recursive content resolution with file I/O),
  extmark creation

A vault note with 20 embeds can block the UI for 200-500ms. Embeds 500+ lines
below the viewport are rendered with the same priority as visible ones.

**Current render flow:**

```
BufReadPost → 150ms defer → render_embeds()   (embed.lua:492-505)
BufEnter    → 50ms defer  → render_embeds()    (embed.lua:507-523)
TextChanged → debounce    → render_embeds_buf() (embed.lua:525-541, via embed_sync.lua)
  → iterate_embeds(lines, callback)     ← synchronous, top-to-bottom
      for each embed span:
        if image: resolve_image() + create_placement()
        if note:  resolve_embed() + resolve_embed_lines() + set_extmark()
  → store deps, mark visible
```

**Key observations:**
- No viewport awareness: renders line 1 through EOF equally.
- No incremental rendering: all-or-nothing.
- `WinScrolled` is not monitored — scrolling to new embed regions does not
  trigger rendering of previously deferred embeds.
- The `max_total_lines` budget (line 91-92) is consumed top-down, which may
  exhaust the budget on off-screen embeds above the viewport.

### Proposed Solution

Split rendering into two phases:

1. **Phase 1 (synchronous, immediate):** Scan all lines to build an embed
   manifest (line number, span, inner text, type). Render only embeds within
   the visible viewport plus a configurable margin.
2. **Phase 2 (deferred, on-scroll):** Use a `WinScrolled` autocmd to detect
   viewport changes and render newly visible embeds from the manifest.

**Data structures:**

```lua
-- New state in embed_state.lua:
-- Per-buffer embed manifest: describes every embed without resolving content.
-- M._embed_manifest[bufnr] = {
--   { lnum = 1-indexed line, s = col_start, e = col_end, inner = "...",
--     is_image = bool, rendered = false, lines_used = nil },
--   ...
-- }
M._embed_manifest = {}

-- Scroll handler tracking
M._scroll_handlers = {}  -- bufnr -> true (autocmd installed)
M._scroll_timers = {}    -- bufnr -> uv_timer_t
```

```lua
-- Config additions (in config.lua, M.embed section):
lazy = {
  enabled = true,
  margin = 50,              -- extra lines above/below viewport to pre-render
  scroll_debounce_ms = 80,  -- debounce for WinScrolled handler
},
```

### Code Changes

**Phase 1: Build manifest + render visible**

```lua
-- In embed.lua (new helper functions)

--- Build a manifest of all embed locations without resolving content.
--- Lightweight scan: pattern matching only, no I/O.
---@param lines string[]  buffer lines
---@return table[]  manifest entries
local function build_embed_manifest(lines)
  local manifest = {}
  iterate_embeds(lines, function(i, inner, s, e)
    manifest[#manifest + 1] = {
      lnum = i,
      s = s,
      e = e,
      inner = inner,
      is_image = images.is_image_embed(inner),
      rendered = false,
    }
  end)
  return manifest
end

--- Get the visible line range for the current window.
---@param winid number
---@param margin number  extra lines above/below to include
---@return number top_line  1-indexed first visible line
---@return number bot_line  1-indexed last visible line
local function visible_range(winid, margin)
  local top = vim.fn.line("w0", winid)
  local bot = vim.fn.line("w$", winid)
  return math.max(1, top - margin), bot + margin
end
```

**Modified `render_embeds()` in `embed.lua`:**

```lua
function M.render_embeds(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local bufpath = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_path(bufpath) then return end

  -- Clear existing state
  vim.api.nvim_buf_clear_namespace(bufnr, state.ns, 0, -1)
  images.clear_image_placements(bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local lazy_cfg = config.embed.lazy or {}
  local lazy_enabled = lazy_cfg.enabled ~= false
  local margin = lazy_cfg.margin or 50

  -- Always build the full manifest (cheap: pattern matching only)
  local manifest = build_embed_manifest(lines)
  state._embed_manifest[bufnr] = manifest

  if lazy_enabled then
    -- Render only visible + margin embeds
    local winid = vim.api.nvim_get_current_win()
    local top, bot = visible_range(winid, margin)
    render_manifest_range(bufnr, bufpath, lines, manifest, top, bot, opts)
    -- Install scroll handler if not already present
    ensure_scroll_handler(bufnr)
  else
    -- Legacy: render everything
    render_manifest_range(bufnr, bufpath, lines, manifest, 1, #lines, opts)
  end

  state.embeds_visible[bufnr] = true
  state._image_retry_fired[bufnr] = false
  -- ... (retry logic unchanged) ...
end
```

**`render_manifest_range()` — renders a subset of manifest entries**

```lua
--- Render embeds in the manifest that fall within [top, bot] and are not
--- already rendered. Contains the same image/note logic as current
--- render_embeds() callback (lines 102-192), but operates on manifest entries.
---@param bufnr number
---@param bufpath string
---@param lines string[]
---@param manifest table[]
---@param top number  1-indexed inclusive
---@param bot number  1-indexed inclusive
---@param opts table
local function render_manifest_range(bufnr, bufpath, lines, manifest, top, bot, opts)
  local PlacementMod, snacks_doc_cfg = images.init_snacks_image()
  local merge = (Snacks and Snacks.config and Snacks.config.merge)
    or function(...) return vim.tbl_deep_extend("force", ...) end

  local deps = state._embed_deps[bufnr] or {}
  local max_total = config.embed.max_total_lines or 150
  local total_remaining = max_total > 0 and max_total or nil

  for _, entry in ipairs(manifest) do
    if entry.rendered then
      -- Deduct budget for already-rendered note embeds
      if not entry.is_image and entry.lines_used and total_remaining then
        total_remaining = total_remaining - entry.lines_used - 2
      end
      goto continue
    end

    -- Skip entries outside the requested range
    if entry.lnum < top or entry.lnum > bot then
      goto continue
    end

    entry.rendered = true

    if entry.is_image then
      -- ... image placement creation (same as current lines 103-130) ...
    else
      -- ... note embed resolution + extmark creation (same as current lines 131-191) ...
      -- Store lines_used on the entry for budget tracking:
      -- entry.lines_used = lines_used
    end

    ::continue::
  end

  state._embed_deps[bufnr] = deps
end
```

**Phase 2: Scroll handler**

```lua
--- Install a WinScrolled autocmd to render newly visible embeds.
local function ensure_scroll_handler(bufnr)
  if state._scroll_handlers[bufnr] then return end
  state._scroll_handlers[bufnr] = true

  local lazy_cfg = config.embed.lazy or {}
  local debounce_ms = lazy_cfg.scroll_debounce_ms or 80
  local margin = lazy_cfg.margin or 50

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = vim.api.nvim_create_augroup("VaultEmbedScroll_" .. bufnr, { clear = true }),
    callback = function()
      local cur_buf = vim.api.nvim_get_current_buf()
      if cur_buf ~= bufnr then return end
      if not state.embeds_visible[bufnr] then return end

      local manifest = state._embed_manifest[bufnr]
      if not manifest then return end

      -- Check if any unrendered embeds are now in range
      local winid = vim.api.nvim_get_current_win()
      local top, bot = visible_range(winid, margin)
      local needs_render = false
      for _, entry in ipairs(manifest) do
        if not entry.rendered and entry.lnum >= top and entry.lnum <= bot then
          needs_render = true
          break
        end
      end

      if not needs_render then return end

      -- Debounced render
      if state._scroll_timers[bufnr] then
        state._scroll_timers[bufnr]:stop()
      else
        state._scroll_timers[bufnr] = vim.uv.new_timer()
      end
      state._scroll_timers[bufnr]:start(debounce_ms, 0, vim.schedule_wrap(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        if not state.embeds_visible[bufnr] then return end
        local cur_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local bufpath_now = vim.api.nvim_buf_get_name(bufnr)
        render_manifest_range(bufnr, bufpath_now, cur_lines, manifest, top, bot, { silent = true })
      end))
    end,
  })
end
```

**Cleanup additions:**

Add to `clear_embeds()` (line 215 of `embed.lua`) and the `BufDelete`/
`BufWipeout` autocmd (line 543 of `embed.lua`):

```lua
state._embed_manifest[bufnr] = nil
state._scroll_handlers[bufnr] = nil
if state._scroll_timers[bufnr] then
  state._scroll_timers[bufnr]:stop()
  state._scroll_timers[bufnr]:close()
  state._scroll_timers[bufnr] = nil
end
```

**Optional: Off-screen image cleanup (memory optimization):**

```lua
--- Close image placements far outside the viewport to free GPU memory.
---@param bufnr number
---@param manifest table[]
---@param top number  visible range top (with margin)
---@param bot number  visible range bottom (with margin)
local function cleanup_offscreen_images(bufnr, manifest, top, bot)
  local cleanup_margin = (config.embed.lazy and config.embed.lazy.margin or 50) * 2
  local cleanup_top = top - cleanup_margin
  local cleanup_bot = bot + cleanup_margin

  for _, entry in ipairs(manifest) do
    if entry.is_image and entry.rendered and entry.placement then
      if entry.lnum < cleanup_top or entry.lnum > cleanup_bot then
        pcall(function() entry.placement:close() end)
        entry.placement = nil
        entry.rendered = false  -- allow re-render when scrolled back
      end
    end
  end
end
```

### Expected Performance Improvement

For a buffer with 20 embeds where only 5 are visible:

- **Before:** All 20 embeds resolved synchronously. ~200-500ms blocking.
- **After:** 5 embeds resolved immediately (~50-125ms), remaining 15 deferred.
  User sees content 4x faster. Scrolling to new regions triggers incremental
  rendering with 80ms debounce — imperceptible to the user.

For buffers where all embeds are visible (short files), there is no overhead
beyond the manifest scan which is O(lines) pattern matching — negligible
compared to the I/O cost of resolving embeds.

### Risk Assessment

- **Budget accounting:** The `max_total_lines` budget must be tracked across
  incremental renders. The manifest stores `lines_used` per entry, and the
  range renderer deducts previously rendered entries before starting. This
  changes behavior compared to the strictly top-down budget of the current
  implementation (embeds rendered first because they were visible consume
  budget before later-visible embeds). Document this in the config comment.
- **Extmark invalidation:** When the buffer is edited (TextChanged), the
  manifest becomes stale (line numbers may shift). The existing TextChanged
  handler (lines 525-541 of `embed.lua`) already triggers re-rendering via
  `embed_sync.lua`, which rebuilds the manifest from scratch. No additional
  invalidation logic is needed.
- **WinScrolled frequency:** `WinScrolled` fires on every scroll event. The
  debounce timer and the early `needs_render` check ensure minimal overhead.
  The `needs_render` scan is O(manifest size) but only checks boolean flags.
- **State cleanup:** New state variables (`_embed_manifest`, `_scroll_handlers`,
  `_scroll_timers`) must be cleaned up in `clear_embeds()`, `BufDelete`/
  `BufWipeout` autocmd, and `VimLeavePre`.
- **Backward compatibility:** Controlled by `config.embed.lazy.enabled` which
  defaults to `true`. Set to `false` to restore current behavior.

---

## 4. Image Location Cache

### Problem Analysis

**File:** `lua/andrew/vault/embed_images.lua` (lines 84-89)

The `M.resolve_image()` function searches for an image file by trying up to
9 candidate paths via `vim.uv.fs_stat()`:

```lua
-- Current implementation (embed_images.lua, lines 68-89)
function M.get_image_search_paths(image_name, bufpath)
  local buf_dir = vim.fs.dirname(bufpath)
  local paths = {
    buf_dir .. "/" .. image_name,
    engine.vault_path .. "/" .. image_name,
  }
  for _, dir in ipairs(IMAGE_SEARCH_DIRS) do
    paths[#paths + 1] = engine.vault_path .. "/" .. dir .. "/" .. image_name
  end
  return paths
end

function M.resolve_image(image_name, bufpath)
  for _, candidate in ipairs(M.get_image_search_paths(image_name, bufpath)) do
    if vim.uv.fs_stat(candidate) then return candidate end
  end
  return nil, "image not found: " .. tostring(image_name)
end
```

`IMAGE_SEARCH_DIRS` is defined at line 10:
```lua
local IMAGE_SEARCH_DIRS = { "attachments", "assets", "images", "img", "media", "static", "public" }
```

Each call performs up to 9 `fs_stat()` syscalls. For a buffer with 10 image
embeds, this is up to 90 syscalls per render. Since `render_embeds()` is called
on `BufReadPost`, `BufEnter`, and `TextChanged` (debounced), the same images
are re-resolved repeatedly.

Worse, if images consistently live in `attachments/` (index 5 of 9 in the
search order: buf_dir, vault_root, then 7 search dirs), each resolution must
fail 4 times before finding the file.

**Note:** `embed_images.lua` already has `M.invalidate_snacks_env()` (lines
14-23) for invalidating the Snacks terminal env cache, but this is unrelated
to image path resolution caching. There is currently **no caching** of resolved
image paths.

### Proposed Solution

Add a module-level cache in `embed_images.lua` mapping
`(image_name, bufpath_dir)` to the resolved absolute path (or `false` for
"not found"). Invalidate entries when the filesystem watcher fires events in
image directories.

**Cache structure:**

```lua
-- In embed_images.lua (module-level):

--- Image resolution cache.
--- Key: image_name .. "\0" .. buf_dir (NUL separator avoids ambiguity)
--- Value: absolute path (string) or false (not found)
---@type table<string, string|false>
local _image_cache = {}

--- Generation counter: incremented on any fs watcher event that might
--- affect image resolution. When the generation changes, the cache is
--- cleared wholesale (simple and correct).
local _image_cache_generation = 0
local _last_cache_generation = 0
```

### Code Changes

**New `resolve_image` with caching (in `embed_images.lua`):**

```lua
--- Invalidate the image path cache. Called by the filesystem watcher when
--- events occur in image directories, or manually via :VaultEmbedClear.
function M.invalidate_image_cache()
  _image_cache_generation = _image_cache_generation + 1
end

function M.resolve_image(image_name, bufpath)
  -- Check if cache needs wholesale invalidation
  if _last_cache_generation ~= _image_cache_generation then
    _image_cache = {}
    _last_cache_generation = _image_cache_generation
  end

  local buf_dir = vim.fs.dirname(bufpath)
  local cache_key = image_name .. "\0" .. buf_dir

  local cached = _image_cache[cache_key]
  if cached ~= nil then
    -- cached is either an absolute path string or false (not found)
    return cached or nil
  end

  -- Cache miss: perform the actual search
  for _, candidate in ipairs(M.get_image_search_paths(image_name, bufpath)) do
    if vim.uv.fs_stat(candidate) then
      _image_cache[cache_key] = candidate
      return candidate
    end
  end

  _image_cache[cache_key] = false
  return nil, "image not found: " .. tostring(image_name)
end
```

**Search directory reordering (bonus optimization):**

Track which directory most recently produced a hit, and try it first for
subsequent lookups. This turns the common "all images in attachments/" case
from 5 stats to 1 stat:

```lua
--- Last successful search path index (locality heuristic).
local _last_hit_idx = nil

function M.resolve_image(image_name, bufpath)
  -- ... cache check as above ...

  local paths = M.get_image_search_paths(image_name, bufpath)

  -- Try the last successful directory first (locality heuristic)
  if _last_hit_idx and _last_hit_idx <= #paths then
    local candidate = paths[_last_hit_idx]
    if vim.uv.fs_stat(candidate) then
      _image_cache[cache_key] = candidate
      return candidate
    end
  end

  -- Full search
  for idx, candidate in ipairs(paths) do
    if vim.uv.fs_stat(candidate) then
      _last_hit_idx = idx
      _image_cache[cache_key] = candidate
      return candidate
    end
  end

  _image_cache[cache_key] = false
  return nil, "image not found: " .. tostring(image_name)
end
```

**Filesystem watcher integration (`engine_watcher.lua`):**

The watcher's `on_fs_event()` callback (lines 40-122 of `engine_watcher.lua`)
currently only tracks `.md` file changes (line 67: `filename:match("%.md$")`).
Non-`.md` events in image directories are silently ignored (lines 72-75).

To integrate image cache invalidation, add a check for image directory events
**before** the `.md` filter:

```lua
-- In engine_watcher.lua, on_fs_event(), after line 64 (Linux dir watch)
-- and before line 67 (.md filter):

-- Check if the event is in an image directory — invalidate image cache
if filename then
  local base_dir_name = vim.fs.dirname(filename)
  base_dir_name = base_dir_name and base_dir_name:match("([^/]+)$")
  if not base_dir_name then
    base_dir_name = filename:match("([^/]+)$")  -- for files in image dirs
  end
  local image_dirs_set = {
    attachments = true, assets = true, images = true,
    img = true, media = true, static = true, public = true,
  }
  -- Also check if the filename itself has an image extension
  local ext = filename:match("%.(%w+)$")
  local image_exts = { png=1, jpg=1, jpeg=1, gif=1, svg=1, webp=1, bmp=1 }
  if (base_dir_name and image_dirs_set[base_dir_name])
    or (ext and image_exts[ext:lower()]) then
    local embed_images = package.loaded["andrew.vault.embed_images"]
    if embed_images then
      embed_images.invalidate_image_cache()
    end
  end
end
```

**Note:** The watcher currently returns early for non-`.md` events when no
`.md` changes are pending (lines 72-75). The image cache invalidation must
happen **before** this early return. The debounce timer for index updates is
separate and unaffected.

**Cache cleanup in `clear_embeds()` (line 215 of `embed.lua`):**

```lua
function M.clear_embeds()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(bufnr, state.ns, 0, -1)
  images.clear_image_placements(bufnr)
  state._embed_deps[bufnr] = nil
  state.embeds_visible[bufnr] = false
  -- Note: do NOT clear image cache here -- it's shared across buffers
  -- and the resolved paths are still valid. Only invalidate on fs events.
end
```

### Expected Performance Improvement

For a buffer with 10 image embeds, all in `attachments/`:

- **Before:** 10 * 5 = 50 `fs_stat` calls per `render_embeds()` invocation
  (assuming attachments/ is hit at index 5 in the search path). On TextChanged
  re-renders, the same 50 stats repeat.
- **After (cache only):** 50 stats on first render, 0 on subsequent renders
  of the same buffer (cache hits). Cross-buffer benefit: if buffer B references
  the same images as buffer A, cache hits avoid all stats.
- **After (cache + reorder):** ~10 stats on first render (last-hit heuristic
  hits attachments/ on first try for images 2-10), 0 on subsequent renders.

The `fs_stat` syscall is cheap (~1-5us per call on SSD), so the absolute
time saved is modest (~50-250us per render). However, the benefit compounds
with:
- Frequent re-renders (TextChanged debounce at 500ms via `config.embed.sync.self_debounce_ms`)
- Large numbers of image embeds
- Network-mounted vaults where stat latency is higher

### Risk Assessment

- **Stale cache:** The generation-based invalidation is conservative — any
  filesystem event in an image directory clears the entire cache. This may
  cause unnecessary misses but never returns stale data.
- **Watcher coverage:** The watcher currently only fires `on_fs_event` for
  events within the vault directory tree. Images outside the vault (e.g.,
  absolute paths) are not covered, but this matches the current resolution
  logic which only searches within the vault.
- **Memory:** Each cache entry is one string key (~50 bytes) and one string
  value (~100 bytes). For 1000 unique images, this is ~150KB — negligible.
- **Cache key correctness:** The NUL separator ensures no ambiguity. Image
  names never contain NUL.
- **Cross-buffer sharing:** The cache is module-level (not per-buffer), so
  images referenced by multiple buffers benefit. This is correct because
  `resolve_image()` depends only on `image_name` and `buf_dir`.
- **Not-found caching:** Caching `false` for missing images prevents repeated
  stat storms for broken image references. The fs watcher invalidation ensures
  newly added images are discovered after the cache clears.
- **Existing `invalidate_snacks_env()`:** This existing function (lines 14-23
  of `embed_images.lua`) is unrelated — it clears the Snacks terminal
  environment cache for placeholder detection, not image path resolution.
  The two invalidation mechanisms are independent.

---

## Implementation Order

The four optimizations are independent and can be implemented in any order.
Recommended sequencing by effort/impact ratio:

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Image Location Cache (#4) | Low | Medium | Low |
| 2 | Hash-Based Collision Detection (#2) | Low | Low | Low |
| 3 | Incremental Inlinks in build_async (#1) | Medium | High | Low |
| 4 | Lazy Embed Rendering (#3) | High | High | Medium |

**#4 (Image Cache)** is a self-contained change to `embed_images.lua` with no
architectural implications. Ship it first to establish the caching pattern.

**#2 (Collision Detection)** is a straightforward refactor within
`vault_index_collisions.lua` and optionally `vault_index.lua`'s
`add_entry_to_indexes()`. No new state, no new APIs.

**#1 (Incremental Inlinks)** requires collecting `changed_rel_paths` and
`deleted_rel_paths` in `vault_index_build.lua`'s `build_async()` and routing
them to `_recompute_inlinks_incremental()`. The incremental method's interface
already matches (no old_outlinks_map needed). The cold-start fallback ensures
safety.

**#3 (Lazy Embeds)** is the largest change, introducing a new manifest data
structure in `embed_state.lua`, scroll handler, and viewport-aware rendering
in `embed.lua`. It interacts with the existing TextChanged debounce (lines
525-541), image retry logic (via `embed_images.schedule_retry()`), and live
sync system (`embed_sync.lua`). Implement after the simpler optimizations are
stable.

---

## Testing Strategy

### Incremental Inlinks (#1)

1. **Consistency test:** After a warm `build_async()`, compare
   `index._inlinks` against a freshly computed `inlinks_mod.recompute(index.files)`
   result. They must be identical (modulo order within inlink lists).
2. **Rename test:** Rename a file externally, trigger watcher. Verify inlinks
   for the old path are removed and inlinks for the new path are correct.
3. **Cold start test:** Delete the persisted index, restart Neovim. Verify
   full `_recompute_inlinks()` is used (not incremental).

### Collision Detection (#2)

1. **Parity test:** Compare collision output before and after the refactor
   for a vault with known collisions. Use `:VaultIndexCollisions` or inspect
   `index._collisions` directly.
2. **No-collision vault:** Verify zero collisions detected (no false
   positives from the optimization).

### Lazy Embed Rendering (#3)

1. **Viewport test:** Open a long file with embeds at lines 1, 50, 200, 500.
   Verify only embeds near the viewport are rendered initially. Scroll down
   and verify line-200 and line-500 embeds appear.
2. **Budget test:** Set `max_total_lines = 30`. Verify budget is respected
   across incremental renders (not exceeded by scroll-triggered renders).
3. **TextChanged test:** Edit a line with an embed. Verify the manifest is
   rebuilt and the embed re-renders correctly.
4. **Disable test:** Set `config.embed.lazy.enabled = false`. Verify all
   embeds render immediately (legacy behavior).

### Image Cache (#4)

1. **Cache hit test:** Call `resolve_image("test.png", bufpath)` twice.
   Verify the second call does not invoke `fs_stat` (mock or trace).
2. **Invalidation test:** Add a new image file to `attachments/`. Trigger
   `invalidate_image_cache()`. Verify the next `resolve_image()` call finds
   the new file.
3. **Not-found caching:** Call `resolve_image("nonexistent.png", bufpath)`.
   Verify subsequent calls return `nil` without stat calls. Invalidate cache,
   verify fresh lookup occurs.
