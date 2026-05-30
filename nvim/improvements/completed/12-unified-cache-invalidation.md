# Unified Cache Invalidation

## Current State

The vault module maintains **10 independent caching mechanisms** spread across 8
files.  Each cache has its own TTL, its own invalidation trigger(s), and its own
data structure.  There is already a centralized `engine.invalidate_all_caches()`
function that manually enumerates and calls each cache's invalidator, but it
requires explicit knowledge of every cache and is brittle to additions.

### Cache Catalog

#### 1. Wikilink Resolution Cache

| Attribute       | Detail |
|-----------------|--------|
| **Module**      | `wikilinks.lua` |
| **Variables**   | `cache` (table), `cache_valid` (bool), `cache_vault` (string), `cache_building` (bool) |
| **Data**        | Maps lowercase note basenames and frontmatter aliases to arrays of absolute file paths |
| **Population**  | `build_cache()` -- synchronous `fd`/`find` + frontmatter alias parsing; lazy on first `resolve_link()` call |
| **TTL**         | None (boolean flag; never expires unless explicitly invalidated) |
| **Invalidation** | `M.invalidate_cache()` sets `cache_valid = false` |
| **Triggers**    | `BufWritePost *.md` (only vault files); `engine.invalidate_all_caches()` |
| **Consumers**   | `resolve_link()`, `follow_link()`, `wikilink_highlights.lua`, `preview.lua`, `embed.lua`, `unlinked.lua` |

#### 2. Shared Name Cache

| Attribute       | Detail |
|-----------------|--------|
| **Module**      | `engine.lua` |
| **Variables**   | `_name_cache` (table), `_name_cache_vault` (string), `_name_cache_ts` (number) |
| **Data**        | `{ names: table<string, boolean>, paths: table<string, string> }` -- basenames + relative path stems mapped to absolute paths |
| **Population**  | `M.get_name_cache()` -- synchronous `fd`/`find`; `M.prebuild_name_cache_async()` -- async variant |
| **TTL**         | `NAME_CACHE_TTL = 10` seconds |
| **Invalidation** | `M.invalidate_name_cache()` sets `_name_cache_ts = 0` |
| **Triggers**    | `BufWritePost *.md` in `linkdiag.lua`; `BufDelete *.md` in `linkdiag.lua`; `engine.invalidate_all_caches()` |
| **Consumers**   | `linkdiag.lua`, `autolink.lua`, `wikilink_highlights.lua` (indirectly via wikilinks), `unlinked.lua` |

#### 3. Tag Collection Cache

| Attribute       | Detail |
|-----------------|--------|
| **Module**      | `tags.lua` |
| **Variables**   | `_tag_cache` (string[]), `_tag_cache_vault` (string), `_tag_cache_ts` (number) |
| **Data**        | Sorted array of unique tag strings from inline `#tags` and frontmatter `tags:` fields |
| **Population**  | `collect_tags(callback)` -- async dual ripgrep (inline + frontmatter), merged and sorted |
| **TTL**         | `TAG_CACHE_TTL = 15` seconds |
| **Invalidation** | `M.invalidate_cache()` sets `_tag_cache_ts = 0` |
| **Triggers**    | `BufWritePost *.md` (augroup `VaultTagCache`); `engine.invalidate_all_caches()` |
| **Consumers**   | `M.tags()`, `M.add_tag()`, `M.remove_tag()` |

#### 4. Heading Cache

| Attribute       | Detail |
|-----------------|--------|
| **Module**      | `linkdiag.lua` |
| **Variables**   | `M._heading_cache` (table: filepath -> `{ mtime, ino, size, slugs, headings }`) |
| **Data**        | Per-file heading slugs and raw heading text, keyed by absolute path |
| **Population**  | `M.get_headings(filepath)` -- synchronous `fs_stat` + `link_utils.extract_headings()` |
| **TTL**         | None (validates via `stat.mtime.sec`, `stat.ino`, `stat.size`) |
| **Invalidation** | Per-file: `M._heading_cache[saved_path] = nil` on `BufWritePost`; full: `linkdiag._heading_cache = {}` from `engine.invalidate_all_caches()` |
| **Triggers**    | `BufWritePost *.md` (per-file); `engine.invalidate_all_caches()` (full) |
| **Consumers**   | `M.validate()`, `M.find_closest_headings()`, `wikilink_highlights.lua` |

#### 5. Query Index

| Attribute       | Detail |
|-----------------|--------|
| **Module**      | `query/init.lua` |
| **Variables**   | `_index` (Index instance), `_index_mtime` (number) |
| **Data**        | Full vault index: pages with frontmatter, tags, outlinks, inlinks, tasks, lists |
| **Population**  | `get_index()` -- synchronous `Index.new():build_sync()` or `:update_incremental()` |
| **TTL**         | `config.query.index_ttl = 30` seconds |
| **Invalidation** | `M.rebuild_index()` sets `_index = nil, _index_mtime = 0` |
| **Triggers**    | Manual only (`:VaultQueryRebuild`); TTL-based expiry on next access |
| **Consumers**   | `execute_dql()`, `execute_lua()`, `execute_js()`, `render_block()`, `render_all()` |

#### 6. Connection Score Cache

| Attribute       | Detail |
|-----------------|--------|
| **Module**      | `connections.lua` |
| **Variables**   | `_cache` (table: rel_path -> `{ source_path, results, timestamp, index_ts }`), `_cache_vault` (string) |
| **Data**        | Per-source-note scored connection results with timestamps |
| **Population**  | `M.compute(source_rel_path)` -- builds index, runs multi-signal scoring |
| **TTL**         | `config.connections.cache_ttl = 60` seconds; also invalidated if `index_ts` changes |
| **Invalidation** | `M.invalidate_cache()` clears entire table; `M.invalidate_for(rel_path)` clears single entry |
| **Triggers**    | `BufWritePost *.md` (per-file + index timestamp reset); `engine.invalidate_all_caches()` |
| **Consumers**   | `M.related_notes()`, `M.debug_pair()` |

#### 7. Connections Index (Private)

| Attribute       | Detail |
|-----------------|--------|
| **Module**      | `connections.lua` |
| **Variables**   | `_index` (Index instance), `_index_ts` (number) |
| **Data**        | Same structure as query index (reuses `query.index.Index`) |
| **TTL**         | `config.connections.index_ttl = 30` seconds (default) |
| **Invalidation** | `_index_ts = 0` on `BufWritePost *.md` |
| **Triggers**    | `BufWritePost *.md` in connections setup |
| **Consumers**   | `get_index()` within connections.lua |

#### 8. Completion Source Caches

| Attribute       | Detail |
|-----------------|--------|
| **Module**      | `completion_base.lua` (framework); `completion.lua`, `completion_tags.lua`, `completion_frontmatter.lua` (sources) |
| **Variables**   | Per-source: `cached_items`, `cached_vault`, `build_generation` (inside closure) |
| **Data**        | Completion items for wikilinks (note names + aliases + headings), tags (with frequency), frontmatter properties (names + values) |
| **Population**  | Per-source `build()` function -- async `fd`/`find` + `rg` |
| **TTL**         | None (invalidated by generation counter) |
| **Invalidation** | `all_invalidators` table: shared `BufWritePost *.md` calls every registered invalidator; `M.invalidate_all()` exposed for external callers |
| **Triggers**    | `BufWritePost *.md` (augroup `VaultCompletionCacheAll`); `engine.invalidate_all_caches()` |
| **Consumers**   | blink.cmp completion engine |

#### 9. Calendar Deadline Cache

| Attribute       | Detail |
|-----------------|--------|
| **Module**      | `calendar.lua` |
| **Variables**   | `_deadline_cache` (table: `{ vault_path, built_at, deadlines }`) |
| **Data**        | Maps `"YYYY-MM-DD"` date strings to arrays of `{ text, file, abs_file, line }` |
| **Population**  | `scan_deadlines()` -- synchronous ripgrep scan for `due::` patterns |
| **TTL**         | `DEADLINE_CACHE_TTL = 60` seconds (uses `os.clock()`) |
| **Invalidation** | `M.invalidate_deadline_cache()` sets `_deadline_cache = nil` |
| **Triggers**    | `engine.invalidate_all_caches()` |
| **Consumers**   | `get_deadlines()`, calendar floating window |

#### 10. Callout Fold Persistence Cache

| Attribute       | Detail |
|-----------------|--------|
| **Module**      | `callout_folds.lua` |
| **Variables**   | `_db` (table), `_db_vault` (string) |
| **Data**        | Maps vault-relative paths to fingerprint -> fold state overrides (backed by `.vault-callout-folds.json`) |
| **Population**  | `load_db()` -- reads JSON store, auto-prunes deleted files |
| **TTL**         | None (in-memory cache of JSON file, reloaded on vault switch) |
| **Invalidation** | `M.invalidate()` sets `_db = nil, _db_vault = nil` |
| **Triggers**    | `engine.invalidate_all_caches()` |
| **Consumers**   | `M.record_toggle()`, `M.restore()`, `M.clear()`, `M.debug()` |

#### 11. Auto-Link Name Index

| Attribute       | Detail |
|-----------------|--------|
| **Module**      | `autolink.lua` |
| **Variables**   | `single_word_names` (array), `multi_word_names` (array), `name_set` (table), `index_vault` (string), `index_ts` (number) |
| **Data**        | Indexed note names split by word count for efficient text matching |
| **Population**  | `rebuild_index()` -- reads `engine.get_name_cache()`, partitions by word count, sorts multi-word longest-first |
| **TTL**         | `INDEX_TTL = 15` seconds |
| **Invalidation** | `M.invalidate_index()` sets `index_ts = 0` |
| **Triggers**    | `engine.invalidate_all_caches()` |
| **Consumers**   | `apply()` auto-link hint rendering |

#### 12. Frecency Database (JSON-backed)

| Attribute       | Detail |
|-----------------|--------|
| **Module**      | `frecency.lua` |
| **Variables**   | `_db` (table), `_db_vault` (string) |
| **Data**        | Maps vault-relative paths to `{ timestamps: number[] }` (backed by `.vault-frecency.json`) |
| **Population**  | `load_db()` -- reads JSON store |
| **TTL**         | None (in-memory cache of JSON file, reloaded on vault switch) |
| **Invalidation** | Implicit via vault-path comparison in `load_db()` |
| **Triggers**    | Vault switch (lazy) |
| **Consumers**   | `M.record()`, `M.ranked_files()`, `M.frequent_files()` |

### Existing Invalidation Infrastructure

The codebase already has a **centralized invalidation function** in `engine.lua`:

```lua
function M.invalidate_all_caches()
  -- 1. Engine's own name cache
  M.invalidate_name_cache()
  -- 2. Wikilink resolution cache
  pcall(require, "andrew.vault.wikilinks").invalidate_cache()
  -- 3. Linkdiag heading cache
  pcall(require, "andrew.vault.linkdiag")._heading_cache = {}
  -- 4. Calendar deadline cache
  pcall(require, "andrew.vault.calendar").invalidate_deadline_cache()
  -- 5. Completion sources
  pcall(require, "andrew.vault.completion_base").invalidate_all()
  -- 6. Tag collection cache
  pcall(require, "andrew.vault.tags").invalidate_cache()
  -- 7. Connection score cache
  pcall(require, "andrew.vault.connections").invalidate_cache()
  -- 8. Callout fold persistence cache
  pcall(require, "andrew.vault.callout_folds").invalidate()
  -- 9. Auto-link name index
  pcall(require, "andrew.vault.autolink").invalidate_index()
end
```

This function is called from three places:
1. **`FocusGained` autocmd** in `init.lua` (debounced 200ms)
2. **Filesystem watcher** in `engine.lua` (`start_fs_watcher()`, debounced 500ms)
3. **`switch_vault()`** in `engine.lua` (immediate)

Additionally, **individual caches have their own `BufWritePost *.md` autocmds**:
- `wikilinks.lua` -- augroup `VaultWikilinks`
- `tags.lua` -- augroup `VaultTagCache`
- `completion_base.lua` -- augroup `VaultCompletionCacheAll`
- `connections.lua` -- augroup `VaultConnections`
- `linkdiag.lua` -- augroup `VaultLinkDiag` (also `BufDelete`)

---

## Problem

### 1. Hard-Coded Cache Registry

`engine.invalidate_all_caches()` must be manually updated every time a new cache
is added.  It uses `pcall(require, ...)` to avoid load-order issues, but this
means a forgotten module silently keeps stale data.  The function currently lists
9 caches but must directly reference each module by name -- a maintenance burden
that scales poorly.

### 2. Redundant BufWritePost Autocmds

Six different modules create their own `BufWritePost *.md` autocmds for cache
invalidation.  Each autocmd fires independently on every markdown save, leading
to:
- **6 separate callbacks** executing on each `:w` of a vault file
- No coordination -- a single save triggers 6 `is_vault_path()` checks
- Some modules only invalidate their own cache; others (like `linkdiag.lua`)
  also invalidate `engine.invalidate_name_cache()`

### 3. No Granularity in Invalidation

The current `invalidate_all_caches()` is all-or-nothing.  When a single file
changes, every cache in the system is fully flushed -- including the query index
(which requires a full vault walk to rebuild), the connection score cache (which
is expensive to recompute), and the completion sources (which run async ripgrep).
This is wasteful for the common case of editing a single note.

### 4. Stale Data Scenarios

Despite the existing infrastructure, several gaps remain:
- **Query index** (`query/init.lua`) is NOT included in
  `invalidate_all_caches()`. A `git pull` that modifies vault files will leave
  the query index stale until its 30-second TTL expires.
- **Connections private index** (`connections.lua:_index_ts`) is NOT reset by
  `invalidate_all_caches()` -- only `_cache` is cleared, not the underlying
  index.
- **Frecency database** (`frecency.lua`) is never explicitly invalidated by
  external events (only vault-path comparison on load).

### 5. No Visibility Into Cache State

There is no way to inspect which caches are fresh, stale, or empty.  When
debugging a stale-data issue, the user must know the internal variable names and
check them via `:lua =`.  There is no `:VaultCacheStatus` command.

---

## Proposed Solution

Replace the hard-coded enumeration in `engine.invalidate_all_caches()` with a
**cache registry** that modules self-register into, and introduce a
**`VaultCacheInvalidate` User autocmd event** as a unified notification channel.

### Architecture

```
                        +-------------------+
                        |   Cache Registry  |
                        |  (engine.lua)     |
                        +--------+----------+
                                 |
          register()             |          invalidate()
   +--------+--------+----------+----------+---------+--------+
   |        |        |          |          |         |        |
   v        v        v          v          v         v        v
 wiki    names     tags      query     connect   comp_base  autolink
 links   cache    cache     index      cache      caches    index
   |        |        |          |          |         |        |
   +--------+--------+----------+----------+---------+--------+
                                 |
                                 v
                      User autocmd event:
                      VaultCacheInvalidate
                        (with payload)
```

The flow:
1. Each cache module calls `engine.register_cache(spec)` during `setup()`.
2. Invalidation triggers (BufWritePost, FocusGained, fs_event, vault switch)
   call `engine.invalidate_caches(opts)`.
3. `invalidate_caches()` iterates over registered caches, calls each
   invalidator, then fires `vim.api.nvim_exec_autocmds("User", { pattern = "VaultCacheInvalidate", ... })`.
4. Modules that need post-invalidation actions (e.g., re-rendering highlights)
   subscribe to the `VaultCacheInvalidate` event.

### Cache Registry API

New functions added to `engine.lua`:

```lua
--- Cache registry table.
--- @type table<string, CacheSpec>
M._cache_registry = {}

--- @class CacheSpec
--- @field name string           Unique cache identifier
--- @field module string         Module path for display
--- @field invalidate fun()      Full invalidation callback
--- @field invalidate_file? fun(abs_path: string)  Per-file invalidation (optional)
--- @field stats? fun(): CacheStats  Status reporting callback (optional)

--- @class CacheStats
--- @field entries number|nil    Number of cached entries
--- @field age_seconds number|nil Seconds since last build/refresh
--- @field vault string|nil      Vault path this cache is scoped to
--- @field ttl number|nil        Configured TTL in seconds (nil = no TTL)

--- Register a cache with the central registry.
--- @param spec CacheSpec
function M.register_cache(spec)
  assert(spec.name, "cache spec must have a name")
  assert(spec.invalidate, "cache spec must have an invalidate function")
  M._cache_registry[spec.name] = spec
end

--- Unregister a cache (for testing or dynamic module unloading).
--- @param name string
function M.unregister_cache(name)
  M._cache_registry[name] = nil
end

--- Invalidate caches matching the given criteria.
--- @param opts? { scope?: "all"|"file", path?: string, module?: string }
---   scope: "all" (default) flushes everything; "file" invalidates per-file only
---   path: absolute path of the changed file (required when scope="file")
---   module: invalidate only a specific module's cache by name
function M.invalidate_caches(opts)
  opts = opts or {}
  local scope = opts.scope or "all"
  local path = opts.path
  local module_name = opts.module

  local invalidated = {}

  for name, spec in pairs(M._cache_registry) do
    if module_name and name ~= module_name then
      goto continue
    end

    if scope == "file" and path and spec.invalidate_file then
      spec.invalidate_file(path)
    else
      spec.invalidate()
    end

    invalidated[#invalidated + 1] = name
    ::continue::
  end

  -- Fire the User autocmd so downstream listeners can react
  vim.api.nvim_exec_autocmds("User", {
    pattern = "VaultCacheInvalidate",
    data = {
      scope = scope,
      path = path,
      module = module_name,
      invalidated = invalidated,
    },
  })
end

--- Get status information for all registered caches.
--- @return table<string, CacheStats>
function M.cache_stats()
  local results = {}
  for name, spec in pairs(M._cache_registry) do
    if spec.stats then
      results[name] = spec.stats()
    else
      results[name] = { entries = nil, age_seconds = nil }
    end
  end
  return results
end
```

### Event System

#### VaultCacheInvalidate User Autocmd

The event is fired via `nvim_exec_autocmds` after invalidation completes.
Subscribers receive a `data` table in the callback argument:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "VaultCacheInvalidate",
  callback = function(ev)
    local data = ev.data
    -- data.scope:       "all" | "file"
    -- data.path:        string|nil  (the changed file, if scope="file")
    -- data.module:      string|nil  (if only one module was targeted)
    -- data.invalidated: string[]    (list of cache names that were invalidated)
  end,
})
```

**Use cases for subscribers:**
- `wikilink_highlights.lua` re-applies highlights after cache invalidation
- `linkdiag.lua` re-runs validation on the current buffer
- `autolink.lua` re-scans the current buffer for suggestions
- `embed.lua` re-renders embeds if underlying content changed

### Invalidation Triggers

#### Automatic Triggers

| Trigger | Event | Scope | Debounce |
|---------|-------|-------|----------|
| **Buffer save** | `BufWritePost *.md` | `file` (single path) | None |
| **Focus gained** | `FocusGained` | `all` | 200ms |
| **File changed externally** | `FileChangedShellPost` | `file` | None |
| **Filesystem watcher** | `fs_event` (libuv) | `all` | 500ms |
| **Vault switch** | `switch_vault()` call | `all` | None |
| **Buffer delete** | `BufDelete *.md` | `file` | None |

**Consolidation:** Replace the 6 separate `BufWritePost` autocmds with a single
one in `engine.lua` or `init.lua`:

```lua
local inv_group = vim.api.nvim_create_augroup("VaultCacheInvalidation", { clear = true })

-- Single BufWritePost handler replaces 6 module-specific ones
vim.api.nvim_create_autocmd("BufWritePost", {
  group = inv_group,
  pattern = "*.md",
  callback = function(ev)
    local bufpath = vim.api.nvim_buf_get_name(ev.buf)
    if engine.is_vault_path(bufpath) then
      engine.invalidate_caches({ scope = "file", path = bufpath })
    end
  end,
})

-- FileChangedShellPost: detect external edits to open buffers
vim.api.nvim_create_autocmd("FileChangedShellPost", {
  group = inv_group,
  pattern = "*.md",
  callback = function(ev)
    local bufpath = vim.api.nvim_buf_get_name(ev.buf)
    if engine.is_vault_path(bufpath) then
      engine.invalidate_caches({ scope = "file", path = bufpath })
    end
  end,
})

-- BufDelete: remove stale entries from per-file caches
vim.api.nvim_create_autocmd("BufDelete", {
  group = inv_group,
  pattern = "*.md",
  callback = function(ev)
    local bufpath = vim.api.nvim_buf_get_name(ev.buf)
    if engine.is_vault_path(bufpath) then
      engine.invalidate_caches({ scope = "file", path = bufpath })
    end
  end,
})

-- FocusGained: pick up external changes (git pull, Obsidian sync)
vim.api.nvim_create_autocmd("FocusGained", {
  group = inv_group,
  callback = function()
    -- Debounce via defer_fn (FocusGained can fire in rapid succession)
    vim.defer_fn(function()
      engine.invalidate_caches({ scope = "all" })
    end, 200)
  end,
})
```

#### Manual Trigger

```lua
vim.api.nvim_create_user_command("VaultCacheInvalidate", function(opts)
  local scope = "all"
  local module_name = nil
  if opts.args and opts.args ~= "" then
    module_name = opts.args
    scope = "all"
  end
  engine.invalidate_caches({ scope = scope, module = module_name })
  if module_name then
    vim.notify("Vault: invalidated cache '" .. module_name .. "'", vim.log.levels.INFO)
  else
    vim.notify("Vault: invalidated all caches", vim.log.levels.INFO)
  end
end, {
  nargs = "?",
  desc = "Invalidate vault caches (optionally specify a module name)",
  complete = function()
    local names = {}
    for name in pairs(engine._cache_registry) do
      names[#names + 1] = name
    end
    table.sort(names)
    return names
  end,
})
```

### Module Migration

Each module replaces its standalone invalidation mechanism with a
`register_cache()` call and removes its own `BufWritePost` autocmd (the
centralized one in `init.lua` handles it).

#### wikilinks.lua

**Before:**
```lua
-- Has own BufWritePost autocmd in setup()
vim.api.nvim_create_autocmd("BufWritePost", {
  group = group, pattern = "*.md",
  callback = function(ev) ... M.invalidate_cache() ... end,
})
```

**After:**
```lua
function M.setup()
  engine.register_cache({
    name = "wikilinks",
    module = "andrew.vault.wikilinks",
    invalidate = function()
      cache_valid = false
    end,
    invalidate_file = function(_path)
      -- A single file change could affect alias resolution, so full invalidate
      cache_valid = false
    end,
    stats = function()
      return {
        entries = cache_valid and vim.tbl_count(cache) or 0,
        age_seconds = nil, -- no TTL
        vault = cache_vault,
        ttl = nil,
      }
    end,
  })

  -- REMOVE: the BufWritePost autocmd (handled centrally)
  -- KEEP: BufReadPost prewarm, FileType keymaps
end
```

#### engine.lua (name cache)

**After:**
```lua
-- Register during module load (not in setup, since engine has no setup())
M.register_cache({
  name = "name_cache",
  module = "andrew.vault.engine",
  invalidate = function()
    _name_cache_ts = 0
  end,
  stats = function()
    return {
      entries = _name_cache and vim.tbl_count(_name_cache.names) or 0,
      age_seconds = _name_cache_ts > 0 and ((vim.uv.now() / 1000) - _name_cache_ts) or nil,
      vault = _name_cache_vault,
      ttl = NAME_CACHE_TTL,
    }
  end,
})
```

#### tags.lua

**Before:**
```lua
-- Has own BufWritePost autocmd and own augroup VaultTagCache
vim.api.nvim_create_autocmd("BufWritePost", {
  group = tag_group, pattern = "*.md",
  callback = function() _tag_cache_ts = 0 end,
})
```

**After:**
```lua
function M.setup()
  engine.register_cache({
    name = "tags",
    module = "andrew.vault.tags",
    invalidate = function()
      _tag_cache_ts = 0
    end,
    stats = function()
      return {
        entries = _tag_cache and #_tag_cache or 0,
        age_seconds = _tag_cache_ts > 0 and ((vim.uv.now() / 1000) - _tag_cache_ts) or nil,
        vault = _tag_cache_vault,
        ttl = TAG_CACHE_TTL,
      }
    end,
  })

  -- REMOVE: the BufWritePost autocmd
end
```

#### linkdiag.lua (heading cache)

**After:**
```lua
function M.setup()
  engine.register_cache({
    name = "heading_cache",
    module = "andrew.vault.linkdiag",
    invalidate = function()
      M._heading_cache = {}
    end,
    invalidate_file = function(abs_path)
      M._heading_cache[abs_path] = nil
    end,
    stats = function()
      return {
        entries = vim.tbl_count(M._heading_cache),
        age_seconds = nil,
        vault = nil,
        ttl = nil,
      }
    end,
  })

  -- REMOVE: engine.invalidate_name_cache() calls (handled centrally)
  -- KEEP: re-validation logic after invalidation (subscribe to VaultCacheInvalidate)
end
```

**Linkdiag re-validation subscriber:**
```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "VaultCacheInvalidate",
  callback = function(ev)
    if not M.enabled then return end
    local bufnr = vim.api.nvim_get_current_buf()
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if bufname:match("%.md$") and engine.is_vault_path(bufname) then
      M.validate(bufnr)
    end
  end,
})
```

#### query/init.lua

**After:**
```lua
-- Register in module body (query/init.lua runs at require time)
engine.register_cache({
  name = "query_index",
  module = "andrew.vault.query",
  invalidate = function()
    _index = nil
    _index_mtime = 0
  end,
  stats = function()
    return {
      entries = _index and vim.tbl_count(_index.pages) or 0,
      age_seconds = _index_mtime > 0 and (os.time() - _index_mtime) or nil,
      vault = _index and _index.vault_path or nil,
      ttl = config.query.index_ttl,
    }
  end,
})
```

#### connections.lua

**After:**
```lua
function M.setup()
  engine.register_cache({
    name = "connections",
    module = "andrew.vault.connections",
    invalidate = function()
      _cache = {}
      _index_ts = 0  -- Also reset the private index
    end,
    invalidate_file = function(abs_path)
      local rel = engine.vault_relative(abs_path)
      if rel then
        _cache[rel] = nil
        _index_ts = 0
      end
    end,
    stats = function()
      return {
        entries = vim.tbl_count(_cache),
        age_seconds = _index_ts > 0 and ((vim.uv.now() / 1000) - _index_ts) or nil,
        vault = _cache_vault,
        ttl = config.connections.cache_ttl,
      }
    end,
  })

  -- REMOVE: the BufWritePost autocmd
end
```

#### completion_base.lua

**After:**
```lua
-- Register in module body
engine.register_cache({
  name = "completions",
  module = "andrew.vault.completion_base",
  invalidate = M.invalidate_all,
  stats = function()
    return {
      entries = #all_invalidators,
      age_seconds = nil,
      vault = nil,
      ttl = nil,
    }
  end,
})

-- REMOVE: the BufWritePost autocmd (augroup VaultCompletionCacheAll)
```

#### calendar.lua

**After:**
```lua
-- In module body or setup
engine.register_cache({
  name = "calendar_deadlines",
  module = "andrew.vault.calendar",
  invalidate = function()
    _deadline_cache = nil
  end,
  stats = function()
    return {
      entries = _deadline_cache and vim.tbl_count(_deadline_cache.deadlines) or 0,
      age_seconds = _deadline_cache and (os.clock() - _deadline_cache.built_at) or nil,
      vault = _deadline_cache and _deadline_cache.vault_path or nil,
      ttl = DEADLINE_CACHE_TTL,
    }
  end,
})
```

#### callout_folds.lua

**After:**
```lua
function M.setup()
  engine.register_cache({
    name = "callout_folds",
    module = "andrew.vault.callout_folds",
    invalidate = function()
      _db = nil
      _db_vault = nil
    end,
    stats = function()
      return {
        entries = _db and vim.tbl_count(_db) or 0,
        age_seconds = nil,
        vault = _db_vault,
        ttl = nil,
      }
    end,
  })
end
```

#### autolink.lua

**After:**
```lua
function M.setup()
  engine.register_cache({
    name = "autolink_index",
    module = "andrew.vault.autolink",
    invalidate = function()
      index_ts = 0
    end,
    stats = function()
      return {
        entries = vim.tbl_count(name_set),
        age_seconds = index_ts > 0 and ((vim.uv.now() / 1000) - index_ts) or nil,
        vault = index_vault,
        ttl = INDEX_TTL,
      }
    end,
  })

  -- Auto-link VaultCacheInvalidate subscriber for re-rendering
  vim.api.nvim_create_autocmd("User", {
    pattern = "VaultCacheInvalidate",
    callback = function()
      if M.enabled then
        local bufnr = vim.api.nvim_get_current_buf()
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
              apply(bufnr)
            end
          end, 200)
        end
      end
    end,
  })
end
```

### Implementation Details

#### Rewritten `invalidate_all_caches()`

The existing function becomes a thin wrapper:

```lua
function M.invalidate_all_caches()
  M.invalidate_caches({ scope = "all" })
end
```

This preserves backward compatibility -- any code calling
`engine.invalidate_all_caches()` (such as `switch_vault()`) continues to work.

#### Existing `fs_watcher` Integration

The filesystem watcher callback in `engine.lua` changes from:

```lua
M.invalidate_all_caches()
```

to:

```lua
M.invalidate_caches({ scope = "all" })
```

#### Load-Order Safety

Caches that register in their module body (like `engine.lua`'s name cache) must
do so after `M._cache_registry` is initialized.  Since `_cache_registry` is
defined at module load time (top of `engine.lua`), and `engine.lua` is required
before any other vault module, this is naturally safe.

Caches that register during `setup()` (most modules) are called from `init.lua`
in a defined order, so no circular dependency issues arise.

#### Preventing Double Invalidation

With the centralized `BufWritePost` handler calling `invalidate_caches({ scope =
"file" })`, individual modules no longer need their own `BufWritePost` autocmds.
The migration must remove these autocmds to avoid double-invalidation:

- `wikilinks.lua` line 447-456: **remove**
- `tags.lua` lines 520-527: **remove**
- `completion_base.lua` lines 8-16: **remove**
- `connections.lua` lines 697-710: **remove**
- `linkdiag.lua` lines 490-499: **remove** (keep the re-validation subscriber)

### Commands

#### `:VaultCacheInvalidate [module]`

Manually invalidate all caches or a specific module's cache.

```
:VaultCacheInvalidate            " Invalidate all
:VaultCacheInvalidate wikilinks  " Invalidate only wikilinks cache
:VaultCacheInvalidate tags       " Invalidate only tags cache
```

Tab completion lists all registered cache names.

#### `:VaultCacheStatus`

Display cache health information in a floating window:

```lua
vim.api.nvim_create_user_command("VaultCacheStatus", function()
  local stats = engine.cache_stats()
  local lines = { "Vault Cache Status", string.rep("=", 40) }

  -- Sort by name for consistent display
  local names = {}
  for name in pairs(stats) do names[#names + 1] = name end
  table.sort(names)

  for _, name in ipairs(names) do
    local s = stats[name]
    local parts = { "  " .. name .. ":" }
    if s.entries then
      parts[#parts + 1] = s.entries .. " entries"
    end
    if s.age_seconds then
      parts[#parts + 1] = string.format("%.1fs old", s.age_seconds)
    end
    if s.ttl then
      parts[#parts + 1] = "TTL=" .. s.ttl .. "s"
    end
    if s.vault then
      parts[#parts + 1] = "vault=" .. vim.fn.fnamemodify(s.vault, ":t")
    end
    lines[#lines + 1] = table.concat(parts, "  ")
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Registered caches: " .. vim.tbl_count(engine._cache_registry)

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, { desc = "Show vault cache health status" })
```

### File Changes

#### New files

None.  All changes fit within existing files.

#### Modified files

| File | Changes |
|------|---------|
| `lua/andrew/vault/engine.lua` | Add `_cache_registry`, `register_cache()`, `unregister_cache()`, `invalidate_caches()`, `cache_stats()`.  Register name cache.  Rewrite `invalidate_all_caches()` as wrapper.  Update `fs_watcher` callback. |
| `lua/andrew/vault/init.lua` | Replace 6 module-specific `BufWritePost`/`BufDelete`/`FocusGained` autocmds with single consolidated augroup.  Add `FileChangedShellPost` handler.  Add `:VaultCacheInvalidate` and `:VaultCacheStatus` commands. |
| `lua/andrew/vault/wikilinks.lua` | Add `register_cache()` call in `setup()`.  Remove `BufWritePost` autocmd.  Keep `invalidate_cache()` (still used by `register_cache` spec). |
| `lua/andrew/vault/tags.lua` | Add `register_cache()` call in `setup()`.  Remove `BufWritePost` autocmd (augroup `VaultTagCache`). |
| `lua/andrew/vault/linkdiag.lua` | Add `register_cache()` with `invalidate_file` support.  Remove `engine.invalidate_name_cache()` calls from `BufWritePost` handler.  Add `VaultCacheInvalidate` subscriber for re-validation. |
| `lua/andrew/vault/connections.lua` | Add `register_cache()` with `invalidate_file` support.  Remove `BufWritePost` autocmd.  Also reset `_index_ts` in full invalidation. |
| `lua/andrew/vault/completion_base.lua` | Add `register_cache()` call.  Remove `BufWritePost` autocmd (augroup `VaultCompletionCacheAll`). |
| `lua/andrew/vault/calendar.lua` | Add `register_cache()` call. |
| `lua/andrew/vault/callout_folds.lua` | Add `register_cache()` call in `setup()`. |
| `lua/andrew/vault/autolink.lua` | Add `register_cache()` call in `setup()`.  Add `VaultCacheInvalidate` subscriber for re-rendering. |
| `lua/andrew/vault/query/init.lua` | Add `register_cache()` call for query index.  This fixes the gap where the query index was NOT included in `invalidate_all_caches()`. |
| `lua/andrew/vault/wikilink_highlights.lua` | Add `VaultCacheInvalidate` subscriber to re-apply highlights after invalidation. |

### Testing Plan

#### Unit Tests (manual verification)

1. **Registry population:**
   - Open a vault file, run `:lua =vim.tbl_count(require("andrew.vault.engine")._cache_registry)`
   - Verify count matches expected number of registered caches (11)
   - Run `:VaultCacheStatus` and verify all caches appear

2. **BufWritePost triggers file-scoped invalidation:**
   - Open a vault markdown file
   - Edit and save (`:w`)
   - Verify `VaultCacheInvalidate` event fires with `scope = "file"`
   - Verify per-file invalidators are called (e.g., heading cache for the saved file is cleared)

3. **FocusGained triggers full invalidation:**
   - Switch away from Neovim and back
   - Verify `VaultCacheInvalidate` event fires with `scope = "all"`
   - Run `:VaultCacheStatus` and verify all ages reset

4. **FileChangedShellPost triggers file-scoped invalidation:**
   - Open a vault file in Neovim
   - Modify it externally (`echo "test" >> file.md` in another terminal)
   - Focus back to Neovim (triggers checktime)
   - Verify the file's caches are invalidated

5. **Manual command works:**
   - `:VaultCacheInvalidate` -- verify "invalidated all caches" notification
   - `:VaultCacheInvalidate wikilinks` -- verify only wikilinks cache is invalidated
   - `:VaultCacheInvalidate nonexistent` -- verify graceful handling

6. **Vault switch invalidates all:**
   - `:VaultSwitch` to another vault
   - Verify all caches report the new vault path in `:VaultCacheStatus`

7. **No double invalidation:**
   - Add a counter to one cache's invalidate function
   - Save a vault file
   - Verify the counter increments by exactly 1 (not 2+)

8. **Query index now included:**
   - Run a dataview query (`:VaultQueryAll`)
   - Externally modify a file that affects query results
   - Focus back to Neovim (triggers FocusGained)
   - Re-run the query -- verify it reflects the external changes

9. **VaultCacheInvalidate event subscribers:**
   - Save a vault file
   - Verify link diagnostics re-run in current buffer
   - Verify wikilink highlights update
   - Verify autolink suggestions refresh (if enabled)

10. **Backward compatibility:**
    - Verify `engine.invalidate_all_caches()` still works (now delegates to `invalidate_caches()`)
    - Verify `switch_vault()` still calls invalidation
    - Verify filesystem watcher still triggers invalidation
