# 67 --- Index Persistence & Maintenance Efficiency

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

Three targeted optimizations for the vault index lifecycle, addressing expensive
JSON serialization of the full index, unbatched per-file cache invalidation in
the watcher, and graph traversal path normalization overhead.

> **Modules affected:** `vault_index.lua`, `engine_watcher.lua`,
> `filter_utils.lua`, `connections.lua`

---

## 1. Change-Aware Index Persistence

**Status:** IMPLEMENTED (generation skip + async writes + `_persist_in_flight` guard)

### Problem Analysis

**File:** `lua/andrew/vault/vault_index.lua` (lines 184-212)

The `_persist()` function JSON-encodes the **entire** `self.files` table on
every persist call:

```lua
-- vault_index.lua:191-197
local data = {
  version = SCHEMA_VERSION,
  vault_path = self._vault_path,
  files = self.files,
}
local ok, json_str = pcall(vim.json.encode, data)
```

For a 2000-file vault with rich metadata (tags, headings, block_ids, tasks,
outlinks, inline_fields), the JSON string can be 10-50 MB. The encoding is
done synchronously in the main Lua thread.

Persistence is triggered by `_schedule_persist()` with a debounce of
`config.index.persist_debounce_ms` (default 5000ms). During active editing
with the filesystem watcher firing, this can encode the full index every
5 seconds even when only 1-2 files changed.

**Complexity:** O(total_entries * avg_entry_size) for JSON encoding, plus
O(json_length) for file write. For a 50MB JSON, this is ~50-200ms of
blocking work.

### Proposed Solution

Track whether any files have actually changed since the last persist. Skip
persistence entirely when the index is clean. Use a generation counter
(already available as `self._generation`) to detect changes.

### Code Changes

**File: `lua/andrew/vault/vault_index.lua`**

**Add a persist-generation tracker:**

```lua
-- In VaultIndex constructor / init:
self._last_persisted_generation = 0
```

**Modified `_persist()`:**

```lua
function VaultIndex:_persist()
  -- Skip if nothing changed since last persist
  if self._generation == self._last_persisted_generation then
    return
  end

  local data = {
    version = SCHEMA_VERSION,
    vault_path = self._vault_path,
    files = self.files,
  }
  local ok, json_str = pcall(vim.json.encode, data)
  if not ok then
    log.error("Failed to encode index: %s", json_str)
    return
  end

  local path = self:_persist_path()
  -- ... mkdir, write file ...

  self._last_persisted_generation = self._generation
  log.info("Persisted index (%d files, gen %d)",
    self:file_count(), self._generation)
end
```

**Further optimization -- async file write:**

```lua
function VaultIndex:_persist()
  if self._generation == self._last_persisted_generation then
    return
  end

  local data = {
    version = SCHEMA_VERSION,
    vault_path = self._vault_path,
    files = self.files,
  }
  local ok, json_str = pcall(vim.json.encode, data)
  if not ok then
    log.error("Failed to encode index: %s", json_str)
    return
  end

  local path = self:_persist_path()
  local gen = self._generation

  -- Write asynchronously to avoid blocking the event loop
  vim.uv.fs_open(path, "w", 438, function(err_open, fd)
    if err_open then
      log.error("Failed to open index file: %s", err_open)
      return
    end
    vim.uv.fs_write(fd, json_str, -1, function(err_write)
      vim.uv.fs_close(fd)
      if err_write then
        log.error("Failed to write index: %s", err_write)
        return
      end
      vim.schedule(function()
        self._last_persisted_generation = gen
      end)
    end)
  end)
end
```

### Expected Performance Improvement

For a session where the user edits 5 files over 10 minutes:

- **Before:** ~120 full JSON encodes (every 5s debounce) = 120 * 50-200ms
  = 6-24s total encoding time
- **After:** 5 JSON encodes (only when generation changes) + async writes

~24x reduction in encoding calls. The remaining encodes still process the
full index, but they are far less frequent. The async write path eliminates
main-thread blocking for disk I/O.

### Risk Assessment

- **Correctness:** `_generation` is incremented on every `update_files_batch()`
  and `build_async()` completion. It reliably tracks content changes.
- **Data loss:** If Neovim crashes between a generation change and the async
  write completing, the persisted index is stale by one generation. On next
  startup, `build_async()` detects the mtime/size diff and reindexes changed
  files — identical to current behavior on crash.
- **Concurrent writes:** The async write does not protect against concurrent
  `_persist()` calls. The debounce timer prevents rapid-fire calls, and the
  generation check prevents redundant writes. For additional safety, add an
  `_persist_in_flight` flag.

---

## 2. Batched Watcher Cache Invalidation

**Status:** IMPLEMENTED (scope="files" in watcher, engine, highlight_coordinator, linkdiag; shared `should_invalidate_buffer()` helper in filter_utils.lua; init.lua autocmds consolidated; dead `scope="file"` (singular) branches removed)

### Problem Analysis

**File:** `lua/andrew/vault/engine_watcher.lua` (lines 123-126)

The debounced watcher callback invalidates caches per-file in a loop:

```lua
-- engine_watcher.lua:123-126
for _, p in ipairs(paths) do
  _engine.invalidate_caches({ scope = "file", path = p, skip_index = true })
end
```

Each `invalidate_caches()` call triggers a `VaultCacheInvalidate` autocmd
(or equivalent notification). For 5 changed files, this dispatches 5 separate
invalidation events, each potentially causing downstream modules to clear and
rebuild their caches independently.

The same function (line 116) handles the batch case differently: when
`#paths > 10`, it fires a single `scope = "all"` invalidation. But for
1-10 files, it fires N individual events.

**Complexity:** O(changed_files * listener_count) autocmd dispatches.

### Proposed Solution

Batch per-file invalidations into a single call that passes all affected
paths. Downstream listeners receive one event with a list of paths to
invalidate, reducing autocmd dispatch overhead.

### Code Changes

**File: `lua/andrew/vault/engine_watcher.lua`**

**Before (lines 116-126):**

```lua
if #paths > 10 then
  _engine.invalidate_caches({
    scope = "all",
    source = "watcher",
    skip_index = true,
  })
else
  for _, p in ipairs(paths) do
    _engine.invalidate_caches({ scope = "file", path = p, skip_index = true })
  end
end
```

**After:**

```lua
if #paths > 10 then
  _engine.invalidate_caches({
    scope = "all",
    source = "watcher",
    skip_index = true,
  })
else
  _engine.invalidate_caches({
    scope = "files",
    paths = paths,
    source = "watcher",
    skip_index = true,
  })
end
```

**File: `lua/andrew/vault/engine.lua`** (in `invalidate_caches`):

Add handling for the new `scope = "files"` variant:

```lua
function M.invalidate_caches(opts)
  opts = opts or {}
  local scope = opts.scope or "all"

  if scope == "files" then
    -- Batch invalidation: notify listeners once with all paths
    vim.api.nvim_exec_autocmds("User", {
      pattern = "VaultCacheInvalidate",
      data = {
        scope = "files",
        paths = opts.paths,
        source = opts.source,
        skip_index = opts.skip_index,
      },
    })
    return
  end

  -- ... existing "file" and "all" handling ...
end
```

**Downstream listener update example:**

```lua
-- In modules that listen for VaultCacheInvalidate:
vim.api.nvim_create_autocmd("User", {
  pattern = "VaultCacheInvalidate",
  callback = function(ev)
    local data = ev.data or {}
    if data.scope == "all" then
      clear_all_caches()
    elseif data.scope == "files" then
      for _, path in ipairs(data.paths or {}) do
        clear_cache_for_file(path)
      end
    elseif data.scope == "file" then
      clear_cache_for_file(data.path)
    end
  end,
})
```

### Expected Performance Improvement

For 5 changed files with 8 cache listeners:

- **Before:** 5 autocmd dispatches * 8 listener callbacks = 40 callback invocations
- **After:** 1 autocmd dispatch * 8 listener callbacks = 8 callback invocations

~5x reduction in autocmd dispatch overhead. Each listener still processes
all 5 paths, but the event loop overhead (autocmd matching, callback
scheduling) is reduced to 1/5th.

### Risk Assessment

- **Backward compatibility:** The new `scope = "files"` is additive. Existing
  listeners that only handle `"file"` and `"all"` will ignore the new scope
  unless updated. Add a fallback in `invalidate_caches()` that falls back to
  per-file dispatch if the listener API hasn't been updated.
- **Listener migration:** Each listener module needs a one-line change to
  handle `scope = "files"`. This can be done incrementally — the fallback
  ensures no breakage.
- **Autocmd data size:** Passing 10 paths in the autocmd data is well within
  Neovim's limits.

---

## 3. Memoized Path Resolution in Graph Traversal

> This optimization is the canonical source for resolve_in_index per-traversal memoization (also referenced from doc 60-graph-connections-performance).

**Status:** IMPLEMENTED (filter_utils.create_memoized_resolver used in graph_traversal.lua and connections.lua)

### Problem Analysis

**File:** `lua/andrew/vault/filter_utils.lua` (lines 64-84)

The `resolve_in_index()` function normalizes a link path and resolves it to
a vault index entry. It performs 4 string operations per call:

```lua
-- filter_utils.lua:64-84
function M.resolve_in_index(idx, link_path)
  local raw = link_path:match("^([^#^]+)") or link_path  -- strip heading/block
  raw = vim.trim(raw)                                     -- trim whitespace
  if raw == "" then return nil end
  local lower = raw:lower()                               -- lowercase

  -- Try direct rel_path match (2 table lookups)
  local entry = idx.files[lower .. ".md"] or idx.files[lower]
  if entry then return entry.rel_path end

  -- Fall back to name resolution
  return idx:resolve_name(lower)
end
```

This function is called in graph traversal for **every outlink of every
visited node**. For a depth-3 BFS with 500 reachable nodes averaging 5
outlinks each, that's 2500 calls — each performing regex matching, trimming,
lowercasing, string concatenation (`.md` suffix), and 2+ table lookups.

**Also in:** `connections.lua` (lines 270-282) where `build_note_data()`
normalizes outlink paths with similar string operations for every candidate.

**Complexity:** O(reachable_nodes * avg_outlinks * string_ops) per graph query.

### Proposed Solution

Add per-traversal memoization. Create a local cache at the start of the
graph traversal that maps raw link_path to resolved rel_path. Subsequent
lookups for the same link_path return in O(1).

### Code Changes

**File: `lua/andrew/vault/filter_utils.lua`**

```lua
--- Create a memoized resolver for use within a single traversal.
--- Returns a function with the same signature as resolve_in_index()
--- but caches results.
---@param idx table  vault index
---@return function  memoized resolver: (link_path) -> rel_path|nil
function M.create_memoized_resolver(idx)
  local cache = {}

  return function(link_path)
    local cached = cache[link_path]
    if cached ~= nil then
      -- cached is either a string (resolved path) or false (not found)
      return cached or nil
    end

    local result = M.resolve_in_index(idx, link_path)
    cache[link_path] = result or false
    return result
  end
end
```

**File: `lua/andrew/vault/search_filter/graph_traversal.lua`**

```lua
-- At the start of collect_reachable():
local resolve = filter_utils.create_memoized_resolver(index)

-- In the BFS loop, replace:
--   local target_rel = filter_utils.resolve_in_index(index, link.path or "")
-- with:
local target_rel = resolve(link.path or "")
```

**File: `lua/andrew/vault/connections.lua`**

```lua
-- In M.compute(), before the scoring loop:
local resolve = filter_utils.create_memoized_resolver(index)

-- In build_note_data(), use resolve() instead of manual normalization:
for _, link in ipairs(page.file.outlinks) do
  local target_rel = resolve(link.path or "")
  if target_rel then
    outlink_targets[target_rel] = true
  end
end
```

### Expected Performance Improvement

For a depth-3 graph traversal with 500 nodes and 2500 outlinks:

Many outlinks point to the same targets (hub notes, MOCs, index pages).
Assuming 40% cache hit rate (1000 unique, 1500 repeated):

- **Before:** 2500 * (regex + trim + lower + concat + 2 lookups) = 2500 full resolutions
- **After:** 1000 full resolutions + 1500 cache hits = ~60% reduction

For `connections.lua` with 1000 candidates x 5 outlinks = 5000 resolutions,
the cache hit rate is higher since many notes link to the same popular targets.

### Risk Assessment

- **Cache lifetime:** The memoized resolver is created per-traversal (local
  variable). No stale data across traversals. Garbage collected after
  traversal completes.
- **Memory:** One entry per unique link_path encountered. For 1000 unique
  paths, ~50KB — negligible.
- **Correctness:** The resolver produces identical results to direct
  `resolve_in_index()` calls. The only difference is caching `false` for
  not-found paths (avoiding repeated failed lookups).
- **Index staleness:** The vault index is not modified during a single
  traversal, so cached resolutions remain valid throughout.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Memoized Path Resolution (#3) | Low | Medium | Low |
| 2 | Batched Invalidation (#2) | Medium | Medium | Low |
| 3 | Change-Aware Persistence (#1) | Medium | High | Low |

**#3 (Path Resolution)** is a self-contained utility with immediate benefit
for graph queries and connection scoring.

**#2 (Batched Invalidation)** requires updating both the watcher and
downstream listeners. The fallback mechanism ensures safe incremental
rollout.

**#1 (Persistence)** has the highest impact but requires careful handling
of the async write path and generation tracking.

---

## Testing Strategy

### Change-Aware Persistence (#1)

1. Edit a file, wait for debounce. Verify index is persisted (check mtime).
2. Wait another 5s without edits. Verify no second persist (generation
   unchanged).
3. Kill Neovim after an edit. Restart and verify `build_async()` reindexes
   the changed file.

### Batched Invalidation (#2)

1. Change 5 files simultaneously. Verify listeners receive one event with
   all 5 paths.
2. Change 15 files. Verify fallback to `scope = "all"`.
3. Verify downstream caches are correctly invalidated for all paths.

### Memoized Path Resolution (#3)

1. Compare graph traversal results with and without memoization for a known
   graph structure.
2. Verify cache hit rates via debug logging.
3. Benchmark `M.compute()` with memoized vs direct resolution on a 1000-file
   vault.

---

## Related Documents

- Doc 60-graph #4b originally proposed a similar resolve cache (consolidated here). Doc 60-index-persistence-memory covers WAL-based persistence (complementary).
