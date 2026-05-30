# 37: Fix Vault Index Concurrent Build Race Condition

## Problem Statement

`build_async()` and `update_file()`/`update_files_batch()` can run concurrently,
leading to silently lost updates. When the filesystem watcher triggers
`update_files_batch()` during an active async build, the update is either:

1. **Silently discarded** by the guard at engine.lua line 925 (`if idx._building then`), or
2. **Overwritten** by the async build's subsequent batch processing, which writes
   `self.files[rel_path] = entry` using stale filesystem snapshots captured at the
   start of the build.

### Concrete Race Scenario

```
Time    build_async()                     Filesystem Watcher
----    --------------------------------  ----------------------------------
T0      _detect_changes() runs, captures
        mtime snapshot of all files.
        File "Note.md" has mtime=100.

T1      Coroutine yields after batch 1.
        "Note.md" not yet processed.

T2                                        User saves "Note.md" externally.
                                          mtime becomes 200.

T3                                        on_fs_event fires, debounce expires.
                                          idx._building == true, so engine.lua
                                          line 925 skips the update entirely.
                                          Only invalidate_caches(scope="all")
                                          is called — the INDEX is NOT updated.

T4      Coroutine resumes. Processes
        "Note.md" from the changed list
        captured at T0. Parses the NEW
        file content (mtime=200) — this
        part is actually correct.
        But the entry was already in the
        changed list, so it gets parsed.

T5      build_async completes. Rebuilds
        derived indexes. Notifies
        subscribers.
```

**Worse scenario — file NOT in the changed list:**

```
Time    build_async()                     Filesystem Watcher
----    --------------------------------  ----------------------------------
T0      _detect_changes() runs. "Note.md"
        has mtime=100, matches index.
        NOT added to changed list.

T1      Coroutine yields.

T2                                        User saves "Note.md". mtime=200.

T3                                        on_fs_event fires, debounce expires.
                                          idx._building == true → SKIPPED.
                                          The update is LOST.

T4      build_async completes. "Note.md"
        was never re-parsed. Index still
        has stale data from the previous
        persist (mtime=100 content).

        No subscriber is aware the file
        changed. Stale data persists until
        next build_async() or manual save.
```

This second scenario is the truly dangerous one: the file was not in the initial
change set, and the watcher update was discarded, so the index permanently holds
stale data until the next full rebuild.

## Current Code Analysis

### `build_async()` (vault_index.lua, line 1184)

```lua
function M.VaultIndex:build_async(callback)
  if self._building then return end   -- line 1185: guard against concurrent builds
  self._building = true               -- line 1186: set flag

  -- ...coroutine body...
  local changed, deleted = self:_detect_changes()  -- line 1192: snapshot at start

  -- Batched processing with coroutine.yield() between batches
  for i = 1, total, _batch_size do
    -- parse files, write to self.files
    self.files[file.rel_path] = entry  -- line 1225: direct mutation
    coroutine.yield()                  -- line 1244: yield to event loop
  end

  self._building = false               -- line 1250: clear flag
  self:_notify_update()                -- line 1252
end
```

Key observations:
- `_detect_changes()` on line 1192 captures a point-in-time snapshot of the filesystem.
- Between `coroutine.yield()` calls (line 1244), the Neovim event loop runs, which
  means `vim.schedule`'d callbacks (including fs watcher debounce handlers) can execute.
- `self.files` is mutated directly in the coroutine with no synchronization.
- `_building` is set to `false` only after all processing completes (line 1250).

### `update_files_batch()` (vault_index.lua, line 1329)

```lua
function M.VaultIndex:update_files_batch(abs_paths)
  -- ...
  self.files[rel_path] = entry          -- line 1355: direct mutation
  -- ...
  self:_rebuild_name_index()            -- line 1364
  self:_recompute_inlinks_incremental() -- line 1365
  self:_notify_update(ctx)             -- line 1378
end
```

This function has no awareness of `_building` state. It directly mutates `self.files`
and rebuilds derived indexes. If called during a build, the derived indexes it
computes would immediately be overwritten when the build completes.

### Engine fs watcher guard (engine.lua, line 924-929)

```lua
if idx._building then
  -- A full build is in progress; it will pick up these changes.
  -- skip_index: build_async is already running
  M.invalidate_caches({ scope = "all", skip_index = true })
else
  idx:update_files_batch(paths)
end
```

The comment "it will pick up these changes" is **incorrect** for files that were
not in the initial change set. The build's `_detect_changes()` already ran; it will
not re-scan the filesystem. Files changed after `_detect_changes()` but before
the build completes are silently lost.

### `update_file()` (vault_index.lua, line 1304)

```lua
function M.VaultIndex:update_file(abs_path)
  self:update_files_batch({ abs_path })
end
```

A thin wrapper. Also called from `engine.invalidate_caches()` (line 69) and from
`rename.lua` (line 361), `wikilinks.lua` (line 353), and `graph.lua` (line 720).
None of these callers check `_building`.

### `remove_file()` (vault_index.lua, line 1309)

Same issue: directly mutates `self.files` and rebuilds derived indexes with no
awareness of an in-progress build. Called from `rename.lua` (line 360).

## Proposed Solution

Add a pending-update queue that collects file mutations during an active async
build. When the build completes, drain the queue and apply all deferred updates
in a single batch.

### Design

1. **New fields on VaultIndex:**
   - `_pending_updates: table<string, "update"|"delete">` -- maps abs_path to operation
   - (No `vim.uv` mutex needed; Lua is single-threaded and coroutines yield cooperatively)

2. **Guard in `update_file()`, `update_files_batch()`, and `remove_file()`:**
   - If `self._building` is true, enqueue the paths and return immediately.

3. **Drain step at end of `build_async()`:**
   - After `self._building = false`, check if `_pending_updates` has entries.
   - If so, apply them via `update_files_batch()` / `remove_file()`.

4. **Engine.lua guard simplification:**
   - Remove the `if idx._building` branch; let `update_files_batch()` handle
     queueing internally. This centralizes the logic in vault_index.lua.

### Why a simple Lua table is sufficient

Neovim runs in a single OS thread. The coroutine used by `build_async()` yields
control via `coroutine.yield()` + `vim.schedule(step)`. Between yields, no other
Lua code can run. The fs watcher callback runs in the event loop (via
`vim.schedule_wrap`), which only executes between coroutine resumes. Therefore,
a simple boolean flag + table queue is race-free -- no mutex is needed.

## Detailed Code Changes

### 1. Add new fields to VaultIndex

**File:** `lua/andrew/vault/vault_index.lua`
**Function:** `M.VaultIndex.new()` (line 86)

```lua
-- BEFORE (line 86-101):
function M.VaultIndex.new(vault_path)
  local self = setmetatable({}, M.VaultIndex)
  self.vault_path = vault_path:gsub("/$", "")
  self.files = {}
  self._name_index = {}
  self._alias_index = {}
  self._inlinks = {}
  self._persist_timer = nil
  self._generation = 0
  self._subscribers = {}
  self._ready = false
  self._building = false
  self._collisions = {}
  self._collision_notified = false
  return self
end

-- AFTER:
function M.VaultIndex.new(vault_path)
  local self = setmetatable({}, M.VaultIndex)
  self.vault_path = vault_path:gsub("/$", "")
  self.files = {}
  self._name_index = {}
  self._alias_index = {}
  self._inlinks = {}
  self._persist_timer = nil
  self._generation = 0
  self._subscribers = {}
  self._ready = false
  self._building = false
  self._collisions = {}
  self._collision_notified = false
  self._pending_updates = {}  -- abs_path -> "update"|"delete" (queued during builds)
  return self
end
```

Also update the class annotation (line 27-38):

```lua
-- BEFORE:
---@class VaultIndex
---@field vault_path string
---@field files table<string, VaultIndexEntry>
---@field _name_index table<string, string[]>
---@field _alias_index table<string, string[]>
---@field _inlinks table<string, table[]>
---@field _persist_timer uv.uv_timer_t|nil
---@field _generation number
---@field _subscribers function[]
---@field _ready boolean
---@field _building boolean
---@field _collisions table[]

-- AFTER:
---@class VaultIndex
---@field vault_path string
---@field files table<string, VaultIndexEntry>
---@field _name_index table<string, string[]>
---@field _alias_index table<string, string[]>
---@field _inlinks table<string, table[]>
---@field _persist_timer uv.uv_timer_t|nil
---@field _generation number
---@field _subscribers function[]
---@field _ready boolean
---@field _building boolean
---@field _collisions table[]
---@field _pending_updates table<string, string>
```

### 2. Add queue-draining helper

**File:** `lua/andrew/vault/vault_index.lua`
**Location:** After `update_files_batch()` (after line 1380)

```lua
--- Drain pending updates that were queued during an async build.
--- Called after build_async() completes. Applies all queued updates/deletes
--- in a single batch to minimize derived-index rebuilds.
function M.VaultIndex:_drain_pending_updates()
  local pending = self._pending_updates
  self._pending_updates = {}

  if not next(pending) then return end

  local update_paths = {}
  local delete_paths = {}

  for abs_path, op in pairs(pending) do
    if op == "delete" then
      delete_paths[#delete_paths + 1] = abs_path
    else
      update_paths[#update_paths + 1] = abs_path
    end
  end

  -- Process deletes
  for _, abs_path in ipairs(delete_paths) do
    self:remove_file(abs_path)
  end

  -- Process updates as a single batch
  if #update_paths > 0 then
    self:update_files_batch(update_paths)
  end
end
```

### 3. Guard `update_files_batch()` to queue during builds

**File:** `lua/andrew/vault/vault_index.lua`
**Function:** `M.VaultIndex:update_files_batch()` (line 1329)

```lua
-- BEFORE (line 1329-1380):
function M.VaultIndex:update_files_batch(abs_paths)
  local prefix = self.vault_path .. "/"
  local old_outlinks_map = {}
  -- ... rest of function

-- AFTER:
function M.VaultIndex:update_files_batch(abs_paths)
  -- Queue updates if an async build is in progress
  if self._building then
    for _, abs_path in ipairs(abs_paths) do
      self._pending_updates[abs_path] = "update"
    end
    return
  end

  local prefix = self.vault_path .. "/"
  local old_outlinks_map = {}
  -- ... rest of function unchanged
```

### 4. Guard `remove_file()` to queue during builds

**File:** `lua/andrew/vault/vault_index.lua`
**Function:** `M.VaultIndex:remove_file()` (line 1309)

```lua
-- BEFORE (line 1309-1323):
function M.VaultIndex:remove_file(abs_path)
  local prefix = self.vault_path .. "/"
  if abs_path:sub(1, #prefix) ~= prefix then return end
  local rel_path = abs_path:sub(#prefix + 1)
  -- ...

-- AFTER:
function M.VaultIndex:remove_file(abs_path)
  -- Queue deletion if an async build is in progress
  if self._building then
    self._pending_updates[abs_path] = "delete"
    return
  end

  local prefix = self.vault_path .. "/"
  if abs_path:sub(1, #prefix) ~= prefix then return end
  local rel_path = abs_path:sub(#prefix + 1)
  -- ... rest unchanged
```

### 5. Drain the queue at the end of `build_async()`

**File:** `lua/andrew/vault/vault_index.lua`
**Function:** `M.VaultIndex:build_async()` (line 1184)

```lua
-- BEFORE (lines 1247-1252, inside coroutine body):
    self:_rebuild_name_index()
    self:_recompute_inlinks()
    self._ready = true
    self._building = false
    self:_schedule_persist()
    self:_notify_update()

-- AFTER:
    self:_rebuild_name_index()
    self:_recompute_inlinks()
    self._ready = true
    self._building = false
    self:_schedule_persist()
    self:_notify_update()

    -- Apply any updates that were queued while the build was running.
    -- Must happen after _building = false so the drain calls go through
    -- the normal (non-queuing) path.
    self:_drain_pending_updates()
```

### 6. Simplify engine.lua fs watcher handler

**File:** `lua/andrew/vault/engine.lua`
**Location:** Lines 924-939

```lua
-- BEFORE (lines 924-939):
    if #paths > 0 then
      if idx._building then
        -- A full build is in progress; it will pick up these changes.
        -- skip_index: build_async is already running
        M.invalidate_caches({ scope = "all", skip_index = true })
      else
        idx:update_files_batch(paths)
        -- skip_index: we already updated via update_files_batch above
        if #paths > 10 then
          M.invalidate_caches({ scope = "all", skip_index = true })
        else
          for _, p in ipairs(paths) do
            M.invalidate_caches({ scope = "file", path = p, skip_index = true })
          end
        end
      end

-- AFTER (lines 924-939):
    if #paths > 0 then
      -- update_files_batch queues internally if a build is in progress,
      -- so we no longer need to check idx._building here.
      idx:update_files_batch(paths)
      -- skip_index: we already called update_files_batch above
      if #paths > 10 then
        M.invalidate_caches({ scope = "all", skip_index = true })
      else
        for _, p in ipairs(paths) do
          M.invalidate_caches({ scope = "file", path = p, skip_index = true })
        end
      end
```

### 7. Error handling in `build_async()` coroutine error path

The error handler at line 1290 also needs to drain pending updates:

```lua
-- BEFORE (lines 1286-1297):
  local function step()
    if coroutine.status(co) == "dead" then return end
    local ok, err = coroutine.resume(co)
    if not ok then
      self._building = false
      vim.notify("Vault index error: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if coroutine.status(co) ~= "dead" then
      vim.schedule(step)
    end
  end

-- AFTER:
  local function step()
    if coroutine.status(co) == "dead" then return end
    local ok, err = coroutine.resume(co)
    if not ok then
      self._building = false
      vim.notify("Vault index error: " .. tostring(err), vim.log.levels.ERROR)
      -- Drain any updates queued during the failed build
      self:_drain_pending_updates()
      return
    end
    if coroutine.status(co) ~= "dead" then
      vim.schedule(step)
    end
  end
```

## Edge Cases

### 1. File updated multiple times during a build

If a file is modified at T2 and again at T4 while a build runs from T1-T6, the
fs watcher will fire twice. Both calls to `update_files_batch()` will write to
`self._pending_updates[abs_path] = "update"`, which is idempotent (same key,
same value). When the queue is drained at T6+, the file is parsed once from its
final state on disk. This is correct -- intermediate states are not meaningful
for an index.

### 2. File deleted during a build

If a file is deleted during a build:

- **File was in the build's change list:** `build_async` will try to parse it
  via `_parse_file()`. `io.open()` will return nil, so the entry is not added
  to `self.files`. If there was an existing entry, it remains from the persisted
  index. Meanwhile, `remove_file()` queues `_pending_updates[abs_path] = "delete"`.
  When drained, the stale entry is removed. Correct.

- **File was NOT in the build's change list:** The existing entry stays in
  `self.files` throughout the build. `remove_file()` queues the deletion. After
  drain, the entry is removed. Correct.

### 3. File created, then deleted during a build

The watcher fires "update" then "delete" for the same path. Since
`_pending_updates` uses the abs_path as key, the final value will be `"delete"`.
The drain will call `remove_file()`, which is a no-op if the file was never in
the index. Correct.

### 4. File deleted, then recreated during a build

The watcher fires "delete" then "update" (or "change"). The final value in
`_pending_updates` will be `"update"`. The drain calls `update_files_batch()`,
which stats and parses the file from its current state. The build may have
already parsed the file from its pre-deletion content (if it was in the change
list) or left the old entry (if not). Either way, the drain overwrites with the
correct current state. Correct.

### 5. `build_async()` called while pending updates exist

This cannot happen in practice because `build_async()` returns immediately if
`_building` is true (line 1185). A second `build_async()` call while pending
updates exist would only occur if triggered manually after a build completes
but before drain finishes. Since drain runs synchronously inside the coroutine
(or step function), this is not possible.

### 6. `update_file()` called from non-watcher paths during a build

`update_file()` delegates to `update_files_batch()`, which now queues during
builds. Callers like `rename.lua`, `wikilinks.lua`, and `graph.lua` will have
their updates deferred until the build completes. This is acceptable because:
- The build will complete within a few seconds at most.
- Derived indexes (name_index, inlinks) are rebuilt when the drain runs.
- The user sees the correct state once everything settles.

However, callers that expect `update_file()` to be synchronous (e.g., rename.lua
calling `remove_file()` + `update_file()` in sequence) need consideration. Since
both operations go into the same `_pending_updates` table, the final operation
wins. For rename (delete old + update new), these are different abs_paths, so
both operations are preserved. Correct.

### 7. `build_async()` errors partway through

The error handler now calls `_drain_pending_updates()`, so queued updates are
not permanently lost. However, `self.files` may be in an inconsistent state
(some files parsed, others not). The drain will apply updates on top of this
partial state, which is the best we can do without transactional semantics.

## Testing Strategy

### Unit tests

1. **Queue during build:**
   - Start `build_async()` on a small vault.
   - Before build completes, call `update_files_batch()` with a known file.
   - Verify the file appears in `_pending_updates`.
   - After build completes, verify the file's entry reflects the latest content.

2. **Delete during build:**
   - Start `build_async()`.
   - Call `remove_file()` during the build.
   - Verify `_pending_updates[abs_path] == "delete"`.
   - After build, verify file is not in `self.files`.

3. **Multiple updates coalesce:**
   - During a build, call `update_files_batch({file_a})` three times.
   - Verify `_pending_updates` has exactly one entry for `file_a`.
   - After drain, file is parsed once.

4. **Delete-then-update wins:**
   - During a build, call `remove_file(path)` then `update_files_batch({path})`.
   - Verify `_pending_updates[path] == "update"` (last write wins).

5. **Update-then-delete wins:**
   - During a build, call `update_files_batch({path})` then `remove_file(path)`.
   - Verify `_pending_updates[path] == "delete"`.

6. **No-op when no pending:**
   - Build completes with empty `_pending_updates`.
   - Verify `_drain_pending_updates()` returns without side effects.
   - Verify no extra `_notify_update()` call.

### Integration tests

7. **Simulated watcher race:**
   - Create a vault with 100+ files (to ensure multi-batch processing).
   - Start `build_async()`.
   - Modify a file via `io.open()`/write during the build.
   - Manually fire the watcher callback.
   - Verify final index state matches the file's latest content.

8. **Rename during build:**
   - Start `build_async()`.
   - Call `remove_file(old)` + `update_file(new)`.
   - Verify both operations are queued and applied correctly.

### Manual testing

9. Open a large vault. While the initial index build runs (visible via progress
   notifications), save a file from another editor. After "Index ready" appears,
   verify the saved file's metadata is current via `:VaultIndexStatus` or by
   checking a search/tag query that depends on the changed content.

## Migration Notes

### Backward Compatibility

- **No breaking API changes.** `update_file()`, `update_files_batch()`, and
  `remove_file()` retain their signatures. Callers are unaffected.

- **Behavioral change:** These functions now return immediately (without
  applying the update) when a build is in progress. Callers that rely on
  synchronous application of updates during builds will see deferred behavior.
  In practice, no current callers depend on this -- the engine.lua watcher
  already had a no-op branch for `_building == true`.

- **New field `_pending_updates`:** Added to VaultIndex instances. Existing
  persisted index files are unaffected (the field is runtime-only).

- **Schema version:** No change needed. The persistent index format is unchanged;
  only runtime behavior is modified.

### Rollback

If issues arise, reverting the changes to `vault_index.lua` and `engine.lua`
restores the previous behavior. No data migration is needed. The
`_pending_updates` field is ephemeral and not persisted.
