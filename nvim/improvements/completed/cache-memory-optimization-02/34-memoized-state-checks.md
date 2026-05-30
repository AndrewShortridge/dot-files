# 34. Memoized State Checks

## Problem

Many vault modules perform repeated boolean checks on the same buffer state.
The most pervasive is `engine.is_vault_path(path)`, called from 36 sites
across highlight modules, embed renderer, autocmd guards, event dispatch,
connections, completion, and more. Each call resolves a buffer name and does a
string prefix match against `M.vault_path`. While individually cheap, the
sheer call volume on every buffer event cycle adds up.

Several other checks — frontmatter presence, embed presence, task detection —
are already cached per-buffer via ad-hoc changedtick patterns scattered across
individual modules (`highlight_coordinator.cached_positions()`,
`highlight_coordinator.cached_value()`, `link_scan.get_frontmatter_range()`,
`frontmatter_parser.cursor_in_frontmatter()`, `callout_folds.get_callout_blocks()`,
`inline_fields.get_buffer_fields()`). These work but are inconsistent: each
module maintains its own cache table, cleanup logic, and invalidation strategy.

For example, a single `TextChanged` event (dispatched via `event_dispatch.lua`
to `highlight_coordinator.schedule()`) can trigger:
- `engine.is_vault_path()` from `highlight_coordinator.lua` (3 autocmd guards
  at lines 373, 389, 427), `event_dispatch.lua` (3 guards at lines 77, 131,
  197), `embed.lua` (2 guards at lines 443, 907 + debug at 719), and 24+
  other modules
- `frontmatter_parser.parse_buffer()` from `frontmatter_editor.lua` (line
  235), `sidebar_meta.lua` (line 74), `autofile.lua` (lines 62, 98), and
  `frontmatter_parser.lua` itself (line 120, via `buf_field`) —
  `frontmatter.lua` imports the parser but does NOT call `parse_buffer`
- `embed_state.iterate_embeds()` from `embed.lua` autocmd callbacks
- `link_scan.build_code_exclusion()` from highlight pipeline

The redundant `is_vault_path()` calls are the biggest win target because they
lack any caching today and fire on every guard check.

## Existing Caching Infrastructure

The vault already has several caching primitives that this design must
integrate with (not duplicate):

| Module | Pattern | Scope |
|--------|---------|-------|
| `highlight_coordinator.lua` | `cached_positions(cache, bufnr, scan_fn)` (lines 96-105) / `cached_value(cache, bufnr, compute_fn)` (lines 113-122) — changedtick-validated per-buffer caches | Highlight data |
| `frame_cache.lua` | Dual-frame render cache with promotion, stats, max entries | Render output dedup |
| `line_parse_cache.lua` | Single-pass LPeg tokenizer with incremental line-level invalidation | Token stream |
| `lru_cache.lua` | Bounded LRU with hash table + ordered eviction | General memoization |
| `string_intern.lua` | String dedup pool with bulk eviction | Repeated strings |
| `resource_cleanup.lua` | `on_buf_delete(group, callback, opts)` (lines 97-103) — registers both BufDelete + BufWipeout | Lifecycle |
| `link_scan.lua` | `get_frontmatter_range(bufnr)` — changedtick cache (lines 119-144, cache table at line 14) | Frontmatter bounds |
| `frontmatter_parser.lua` | `cursor_in_frontmatter(bufnr, row)` — changedtick cache (lines 153-186, cache table at line 141) | Cursor context |
| `callout_folds.lua` | `get_callout_blocks(bufnr, suffixed_only?)` — changedtick cache with dual-key lookup (suffixed/all) per bufnr (lines 23-56, cache table at line 14, stats tracking at lines 15-17) | Callout ranges |
| `inline_fields.lua` | `get_buffer_fields(bufnr)` — changedtick cache (lines 262-295, cache table at line 15) | Field parsing |

Additionally, `engine.lua` itself has a central cache registry system (lines
28-127) with `M.register_cache(spec)` (lines 52-56), `M.invalidate_caches(opts)`
(lines 60-113), `M.cache_stats()` (lines 117-127), and `M.cache_debug()`
(lines 157-302). A new MemoizedCheck module should register with this system
for visibility in `:VaultCacheDebug` output.

The common ad-hoc pattern used by these modules is:
```lua
local tick = vim.api.nvim_buf_get_changedtick(bufnr)
local cached = _cache[bufnr]
if cached and cached.tick == tick then
  return cached.result
end
-- Recompute...
_cache[bufnr] = { tick = tick, result = computed_value }
```

This document proposes a generic utility that formalizes this pattern, adds
automatic cleanup, and provides a single place to apply it to currently
un-cached checks (primarily `is_vault_path`).

## Inspiration

Zed's `crates/language/src/buffer.rs` line 127 (with doc comment at lines 125-126) uses:
```rust
/// Memoize calls to has_changes_since(saved_version).
/// The contents of a cell are (self.version, has_changes) at the time of a last call.
has_unsaved_edits: Cell<(clock::Global, bool)>,
```

Implementation at lines 1945-1958:
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

The same `(version, cached_result)` pattern appears in Zed's
`DocumentColorData` (lsp_store.rs:3565-3571 — pairs `colors_for_version: Global`
with cached `colors: HashMap<LanguageServerId, HashSet<DocumentColor>>` plus
`cache_version: usize` and `colors_update: Option<(Global, DocumentColorTask)>`),
`CachedExcerptHints` (inlay_hint_cache.rs:54-61 — `#[derive(Debug)]` at
line 54, pairs `buffer_version: Global` with `ordered_hints: Vec<InlayId>`,
`hints_by_id: HashMap<InlayId, InlayHint>`, plus `version: usize` and
`buffer_id: BufferId`), and `BufferColors`
(lsp_colors.rs:26-31 — pairs `cache_version_used: usize` with rendered
`colors: Vec<(Range<Anchor>, DocumentColor, InlayId)>` and
`inlay_colors: HashMap<InlayId, usize>`).

The pattern is minimal — a single tuple per check — yet eliminates entire
categories of redundant work. The key insight is that most state checks are
pure functions of a small number of version inputs (buffer changedtick, index
generation, vault_path), and caching against those versions is both cheap and
highly effective.

## Design

A generic memoization utility that pairs a version function with a computation
function. The version function returns a lightweight value (number, string, or
table) that changes only when the computation's inputs change. The cached
result is returned immediately when the version matches; otherwise the
computation runs and the cache updates.

### Core Components

**MemoizedCheck** — a single cached check instance:
- `version_fn(key)` — returns current version for the given key (e.g., bufnr)
- `compute_fn(key)` — performs the expensive computation
- `_cache[key] = { version, result }` — per-key cache entries
- `:get(key)` — cache-aware accessor

**Per-buffer cleanup** — uses the existing `resource_cleanup.on_buf_delete()`
infrastructure to remove cache entries for deleted buffers, preventing memory
leaks for long-running sessions. This avoids creating a separate autocmd group
when the vault already has a unified cleanup system.

**Version sources** — three primary version inputs cover all current use cases:
1. `vim.api.nvim_buf_get_changedtick(bufnr)` — buffer content changes
2. `vault_index._generation` — index rebuild/update events (initialized at
   vault_index.lua:182, incremented in `_notify_update()` at lines 412-441
   which also classifies invalidation context, tracks stats, and notifies
   subscribers with interest-based filtering; with
   `_aggregates_gen` at line 194 for lazy aggregate cache invalidation via
   `_ensure_aggregates()` at lines 1787-1872, generation check at line 1788,
   generation update at line 1871; also assigned at line 1630 in
   `_rebuild_name_index()` as `_generation + 1` to force recompute on next
   aggregate query)
3. File mtime via `vim.uv.fs_stat()` — on-disk file changes (rare checks only)

### Cache Key Strategy

Most checks are keyed by `bufnr` (integer), giving O(1) table lookup. For
cross-buffer checks (e.g., "does note X exist in the index?"), the key is the
note path string. Mixed keys are not supported per instance — each
MemoizedCheck uses a single key type.

## Target Checks

### 1. engine.is_vault_path(path)

**Current implementation** (`engine.lua` lines 506-508):
```lua
function M.is_vault_path(path)
  return path ~= "" and vim.startswith(path, M.vault_path)
end
```

**Current cost:** String prefix match on every call. Called from 36 sites
across the codebase — `engine.lua` itself (2 internal uses at lines 515,
626), `highlight_coordinator.lua` (3 autocmd guards at lines 373, 389, 427),
`event_dispatch.lua` (3 guards at lines 77, 131, 197), `embed.lua` (2 guards
at lines 443, 907 + debug at 719), `callout_folds.lua` (4 guards at lines
177, 222, 241, 273), `connections.lua` (2 at lines 945, 1006),
`wikilinks.lua` (2 at lines 325, 330), `autofile.lua` (2 at lines 60, 96),
`unlinked.lua` (2 at lines 77, 113), `sidebar.lua` (line 408), `rename.lua`
(line 26), `graph.lua` (2 at lines 35, 142), `frecency.lua` (line 82),
`frontmatter_editor.lua` (line 224), `linkdiag.lua` (line 587), `init.lua`
(line 669), `task_hierarchy.lua` (line 534), `frontmatter.lua` (line 16),
`unlinked/names.lua` (line 13), `autolink.lua` (line 67), and `autosave.lua`
(line 56). Most callers pass `vim.api.nvim_buf_get_name(bufnr)` then call
`is_vault_path(name)`.

**Memoization approach:** Add a bufnr-keyed wrapper `is_vault_buf(bufnr)` that
caches the result. The version is the buffer name + vault_path (both
effectively immutable per buffer). The existing `is_vault_path(path)` remains
unchanged for non-buffer callers.

**Version source:** `vim.api.nvim_buf_get_name(bufnr) .. "|" .. M.vault_path`
— buffer name is immutable for a given bufnr, and vault_path changes only on
vault switch (extremely rare).

**Invalidation:** Cleared on `BufDelete`/`BufWipeout` via resource_cleanup.

### 2. Frontmatter presence detection

**Current implementation:** Already partially cached in two places:
- `link_scan.get_frontmatter_range(bufnr)` (lines 119-144, cache at line 14)
  — changedtick-cached, scans up to 200 lines for `---` delimiters, returns
  0-indexed range
- `frontmatter_parser.cursor_in_frontmatter(bufnr, row)` (lines 153-186,
  cache at line 141) — changedtick-cached, checks first line for `---` then
  scans for closing. Cache stores `end_line` which can be `false` (no FM),
  `nil` (unclosed FM), or a number (closed FM boundary)

**Current cost:** `frontmatter_parser.parse_buffer(bufnr)` (lines 108-113) is
NOT cached and is called from `frontmatter_editor.lua` (line 235),
`sidebar_meta.lua` (line 74), `autofile.lua` (lines 62, 98), and
`frontmatter_parser.lua` itself (line 120, via `buf_field` helper) on each
invocation. Note: `frontmatter.lua` imports the parser module but does NOT
call `parse_buffer` directly.

**Memoization approach:** Wrap `frontmatter_parser.parse_buffer()` in a
MemoizedCheck using changedtick. This consolidates the ad-hoc caching in
`link_scan` and `cursor_in_frontmatter` into one canonical cached parse.

**Version source:** `nvim_buf_get_changedtick(bufnr)`.

**Invalidation:** On any buffer edit.

### 3. Embed presence in buffer

**Current implementation:** `embed_state.iterate_embeds(lines, callback)` at
`embed_state.lua` lines 195-204 scans all lines using
`embed_state.find_embed_spans(line)` (line 158) which calls
`line:find(EMBED_PAT, pos)`. Pattern defined as `pat.EMBED_DETECT` =
`"!%[%[.-%]%]"` from `patterns.lua` line 21.

**Current cost:** Full buffer line scan on each call. Called from embed.lua
autocmd callbacks for render decisions.

**Version source:** `nvim_buf_get_changedtick(bufnr)`.

**Invalidation:** On any buffer edit.

### 4. Task presence detection

**Current implementation:** Task detection uses `pat.TASK_DETECT` =
`"^%s*[-*] %[(.)%] "` from `patterns.lua` line 74. Task counting at the
vault level goes through `vault_index` task entries (used by `stats.lua`
lines 171-176 and `task_notify.lua`), not buffer scanning.

**Current cost:** Buffer-level task presence checks (for highlighting via
`line_parse_cache.lua` LPeg tokenizer) are already handled by the pipeline
cache system. The remaining uncached path is in `tasks.lua` which uses
`pat.TASK_CHECKBOX` for checkbox toggling (not a hot path).

**Memoization approach:** Lower priority than targets 1-3. The pipeline cache
already handles the hot path. A MemoizedCheck for "buffer has any tasks"
boolean could benefit status indicators if added in the future.

**Version source:** `nvim_buf_get_changedtick(bufnr)`.

**Note:** The status line (`lua/andrew/plugins/lualine.lua`) does NOT currently
poll for embed, task, or link presence — it focuses on mode, git info,
diagnostics, word count, and progress. This removes the urgency for targets
3-5 from the original plan.

## Implementation Steps

### Step 1: Create the memoize module

Create `lua/andrew/vault/memoize.lua` with the core MemoizedCheck class:

```lua
local M = {}

local config = require("andrew.vault.config")

---@class MemoizedCheck
---@field _version_fn fun(key: any): any
---@field _compute_fn fun(key: any): any
---@field _cache table<any, {version: any, result: any}>
---@field _entry_count number
---@field _name string|nil
local MemoizedCheck = {}
MemoizedCheck.__index = MemoizedCheck

--- Create a new memoized check.
---@param version_fn fun(key: any): any  Returns current version for key
---@param compute_fn fun(key: any): any  Expensive computation to cache
---@param name? string  Optional name for debug output
---@return MemoizedCheck
function M.new(version_fn, compute_fn, name)
  local self = setmetatable({
    _version_fn = version_fn,
    _compute_fn = compute_fn,
    _cache = {},
    _entry_count = 0,
    _name = name,
  }, MemoizedCheck)
  return self
end

--- Get the cached or freshly computed result for the given key.
---@param key any  Cache key (typically bufnr)
---@return any result
function MemoizedCheck:get(key)
  local current_version = self._version_fn(key)
  local entry = self._cache[key]

  if entry and entry.version == current_version then
    return entry.result
  end

  -- Evict if at capacity and this is a new key
  if not entry and self._entry_count >= (config.memoize.max_entries or 100) then
    self:_evict_one()
  end

  local result = self._compute_fn(key)

  if not entry then
    self._entry_count = self._entry_count + 1
  end

  self._cache[key] = { version = current_version, result = result }
  return result
end

--- Remove a specific key from the cache (e.g., on BufDelete).
---@param key any
function MemoizedCheck:invalidate(key)
  if self._cache[key] then
    self._cache[key] = nil
    self._entry_count = self._entry_count - 1
  end
end

--- Clear all cached entries.
function MemoizedCheck:clear()
  self._cache = {}
  self._entry_count = 0
end

--- Evict one arbitrary entry when at capacity.
function MemoizedCheck:_evict_one()
  local evict_key = next(self._cache)
  if evict_key then
    self._cache[evict_key] = nil
    self._entry_count = self._entry_count - 1
  end
end

return M
```

### Step 2: Create the buffer cleanup registry

Integrate with the existing `resource_cleanup.on_buf_delete()` infrastructure
rather than creating a standalone autocmd:

```lua
-- In memoize.lua, add registry and cleanup setup:

local _registered = {}
local _cleanup_installed = false

--- Register a MemoizedCheck for automatic buffer cleanup.
---@param check MemoizedCheck
function M.register_buf_cleanup(check)
  table.insert(_registered, check)

  if not _cleanup_installed then
    _cleanup_installed = true
    local cleanup = require("andrew.vault.resource_cleanup")
    cleanup.on_buf_delete(
      vim.api.nvim_create_augroup("VaultMemoizeCleanup", { clear = true }),
      function(bufnr)
        for _, c in ipairs(_registered) do
          c:invalidate(bufnr)
        end
      end
    )
  end
end
```

### Step 3: Create common version functions

Provide pre-built version functions for the three standard version sources:

```lua
--- Version function: buffer changedtick.
---@param bufnr number
---@return number
function M.changedtick(bufnr)
  return vim.api.nvim_buf_get_changedtick(bufnr)
end

--- Version function: vault index generation.
---@return number
function M.index_generation(_key)
  local vault_index = require("andrew.vault.vault_index")
  return vault_index._generation or 0
end

--- Version function: composite of changedtick + index generation.
---@param bufnr number
---@return string
function M.changedtick_and_generation(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local vault_index = require("andrew.vault.vault_index")
  local gen = vault_index._generation or 0
  return tick .. ":" .. gen
end
```

### Step 4: Apply to engine.is_vault_path — add bufnr-keyed wrapper

Add a new `is_vault_buf(bufnr)` function alongside the existing
`is_vault_path(path)`. Callers that already have a bufnr (most autocmd guards)
switch to the cached version; callers with only a path continue using the
uncached `is_vault_path()`:

```lua
-- In engine.lua:
local memo = require("andrew.vault.memoize")

local is_vault_check = memo.new(
  function(bufnr)
    -- Version: buffer name + vault_path (both effectively immutable per buffer)
    local name = vim.api.nvim_buf_get_name(bufnr)
    return name .. "|" .. (M.vault_path or "")
  end,
  function(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    return M.is_vault_path(name)
  end,
  "is_vault_buf"
)
memo.register_buf_cleanup(is_vault_check)

--- Cached version of is_vault_path for buffer-keyed callers.
---@param bufnr? number  Buffer number (defaults to current)
---@return boolean
function M.is_vault_buf(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return is_vault_check:get(bufnr)
end
```

**Migration:** The highest-impact callers to migrate are:
- `highlight_coordinator.lua` lines 373, 389, 427 (3 calls per event cycle)
- `event_dispatch.lua` lines 77, 131, 197 (3 calls per event cycle)
- `embed.lua` lines 443, 907 (2 guard calls per render)
- `callout_folds.lua` lines 177, 222, 241, 273 (4 calls)

These 12 call sites (plus `autolink.lua:67`) account for the majority of
`is_vault_path` invocations on every buffer event. Each changes from:
```lua
-- Before:
if not engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then return end
-- After:
if not engine.is_vault_buf(ev.buf) then return end
```

The remaining 23 callers (including 2 internal engine.lua uses) can migrate
incrementally.

### Step 5: Apply to frontmatter presence

Wrap `frontmatter_parser.parse_buffer()` to provide a cached frontmatter
presence check:

```lua
-- In frontmatter_parser.lua or a shared checks module:
local memo = require("andrew.vault.memoize")

local cached_parse = memo.new(memo.changedtick, function(bufnr)
  return M.parse_buffer(bufnr)  -- returns parsed fm table or nil
end, "frontmatter_parse")
memo.register_buf_cleanup(cached_parse)

--- Cached frontmatter parse — returns parsed frontmatter or nil.
---@param bufnr number
---@return table|nil
function M.parse_buffer_cached(bufnr)
  return cached_parse:get(bufnr)
end
```

This subsumes the ad-hoc changedtick caches in `link_scan.get_frontmatter_range()`
and `frontmatter_parser.cursor_in_frontmatter()`. Those can be refactored to
call `parse_buffer_cached()` and derive their results from it. The additional
callers (`sidebar_meta.lua`, `autofile.lua`, `frontmatter_parser.buf_field`)
would also benefit from the cached wrapper.

### Step 6: Apply to embed presence (optional, lower priority)

```lua
local pat = require("andrew.vault.patterns")
local state = require("andrew.vault.embed_state")

local has_embeds = memo.new(memo.changedtick, function(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, line in ipairs(lines) do
    if line:find(pat.EMBED_OPEN) then
      return true
    end
  end
  return false
end, "has_embeds")
memo.register_buf_cleanup(has_embeds)
```

**Note:** This is lower priority because the status line does not poll embed
presence. The primary beneficiary would be `embed.lua` render-decision guards.

### Step 7: Add debug command

```lua
-- In memoize.lua:
function M.setup_commands()
  vim.api.nvim_create_user_command("VaultMemoDebug", function()
    local lines = { "Memoized State Checks:" }
    for i, check in ipairs(_registered) do
      local label = check._name or ("check_" .. i)
      table.insert(lines, string.format("  %s: %d entries", label, check._entry_count))
    end
    table.insert(lines, string.format("Total registered: %d", #_registered))
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "Show memoized check statistics" })
end
```

## API

```lua
local memo = require("andrew.vault.memoize")

-- Create a memoized check with custom version and compute functions
local check = memo.new(
  function(bufnr) return vim.api.nvim_buf_get_changedtick(bufnr) end,
  function(bufnr) return expensive_computation(bufnr) end,
  "my_check"  -- optional name for debug output
)

-- Register for automatic cleanup on BufDelete/BufWipeout
memo.register_buf_cleanup(check)

-- Use: returns cached result if changedtick unchanged
local result = check:get(bufnr)

-- Manual invalidation (rarely needed — BufDelete handles it)
check:invalidate(bufnr)

-- Full reset
check:clear()

-- Pre-built version functions
memo.changedtick(bufnr)              -- buffer content version
memo.index_generation(key)            -- vault index generation
memo.changedtick_and_generation(bufnr) -- composite version
```

## Configuration

Add to `config.lua` (alongside existing `M.cache` at lines 794-814,
`M.intern` at lines 825-831, `M.pools` at lines 836-842, `M.arena` at lines
847-851, `M.pipeline` at lines 870-876, and `M.render_cache` at lines
927-939):

```lua
M.memoize = {
  max_entries = 100,  -- Maximum cache entries per MemoizedCheck instance
}
```

The `max_entries` cap prevents unbounded growth in sessions that open many
buffers. 100 is generous — most sessions have fewer than 20 buffers open. The
eviction strategy is simple (arbitrary key removal) because the cost of a cache
miss is merely one recomputation, and eviction should be exceedingly rare in
practice.

## Expected Impact

- **is_vault_path (via is_vault_buf)**: Called from 36 sites, with 13
  high-frequency autocmd guards firing on every buffer event. With memoization,
  only the first call per buffer computes the path check; subsequent calls in
  the same event cycle return instantly. The `vim.api.nvim_buf_get_name()` +
  `vim.startswith()` calls are eliminated for all but the first invocation.
  Estimated 90%+ reduction in path-matching work per event cycle.

- **Frontmatter parse**: `parse_buffer()` is called from
  `frontmatter_editor.lua` (line 235) without caching. With a cached wrapper,
  repeated calls within the same changedtick are free.
  Additionally, ad-hoc changedtick caches in `link_scan` and
  `frontmatter_parser` can be consolidated. Estimated 50-60% reduction in
  frontmatter parsing work.

- **Embed presence** (lower priority): The status line does NOT poll embed
  presence, reducing the urgency. The primary beneficiary is `embed.lua`
  render-decision guards. Estimated 30-40% reduction in embed scanning for
  buffers that are checked multiple times per event cycle.

- **Overall**: The biggest win is `is_vault_buf` — it eliminates the most
  frequently repeated un-cached check in the system. For a stable buffer (no
  edits), all memoized checks become O(1) version comparisons. For actively
  edited buffers, redundant same-tick calls are eliminated. Net reduction in
  redundant computation: 70-80% for `is_vault_path` callers, 40-60% for
  frontmatter parsing.

- **Memory cost**: Negligible. Each cache entry is a version value + a result.
  100 entries per check instance, ~3 instances = ~300 entries total, well under
  1 KB.

## Relationship to Existing Caches

This module does NOT replace the existing caching infrastructure:

- **`highlight_coordinator.cached_positions()` / `cached_value()`** — These
  remain for highlight-specific data that is tightly coupled to the render
  pipeline. MemoizedCheck targets cross-cutting boolean/structural checks.

- **`frame_cache.lua`** — Dual-frame render cache operates at a different
  granularity (per-line render output). No overlap.

- **`line_parse_cache.lua`** — LPeg tokenizer with incremental invalidation.
  Handles per-line token extraction. No overlap.

- **`lru_cache.lua`** — Two implementations: simple LRU (`M.new(max_size)`,
  lines 8-93) and weighted LRU with doubly-linked list (`M.new_weighted(opts)`,
  lines 114-248). MemoizedCheck is version-aware (auto-invalidates on version
  change); LRU is not. They serve different use cases.

- **Ad-hoc changedtick caches** in `link_scan`, `frontmatter_parser`,
  `callout_folds`, `inline_fields` — These CAN be incrementally migrated to
  MemoizedCheck for consistency, but there is no urgency. The ad-hoc pattern
  works correctly; MemoizedCheck merely provides a standardized version with
  automatic cleanup.
