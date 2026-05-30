# 49 --- Incremental Index Rebuild (Partial File Reparse)

## Motivation

The vault index (`vault_index.lua`) is the single source of truth for all
vault metadata -- frontmatter, aliases, tags, headings, block IDs, outlinks,
tasks, and inline fields. Its `build_async()` method performs an incremental
diff against the filesystem: it walks every directory, stats every `.md` file,
compares mtime+size against the stored entry, and reparses only changed files.

While this is incremental at the **parse** level (unchanged files are skipped),
the **filesystem scan** itself is O(N) where N is the total number of `.md`
files. For a vault with 2000+ notes across nested directories, this scan runs
`fs_scandir` + `fs_stat` on every file, which takes noticeable time even when
nothing has changed.

The irony is that we already know which file changed. The filesystem watcher
(`engine.lua`) receives the exact filename in its `on_fs_event` callback.
The `BufWritePost` autocmd (`init.lua`) has the buffer path. Both of these
already pass the path to the index -- but the watcher previously had to
trigger `build_async()` as a fallback, and the full O(N) scan was the only
rebuild path available.

**Since then, `update_file()` and `update_files_batch()` have been
implemented.** The watcher and BufWritePost handler now use these targeted
methods. However, there are still remaining inefficiencies and edge cases
worth addressing:

1. **`_rebuild_name_index()` is O(N) on every single-file update.** Both
   `update_file()` and `update_files_batch()` call `_rebuild_name_index()`
   which iterates over ALL files to rebuild the name and alias indexes from
   scratch, even when only one file changed.

2. **`FocusGained` triggers a full `build_async()`.** When Neovim regains
   focus (e.g., switching back from a terminal), `init.lua` calls
   `invalidate_caches({ scope = "all" })` which in turn calls
   `build_async()`, doing the full O(N) filesystem walk.

3. **No incremental `_rebuild_name_index()` exists.** The name index and
   alias index could be surgically updated for just the changed files, but
   currently the entire index is rebuilt from scratch on every update.

---

## Current State Analysis

### File: `lua/andrew/vault/vault_index.lua`

#### `build_async()` (line 1184)

The main async rebuild path. Creates a coroutine that:

1. Calls `_detect_changes()` which walks the entire filesystem tree via
   `fs_scandir` recursively, stats every `.md` file, and compares against
   stored mtime+size.
2. Processes deletions immediately.
3. Reparses changed files in batches of `_batch_size` (default 20), yielding
   between batches to avoid blocking the UI.
4. Calls `_rebuild_name_index()` and `_recompute_inlinks()` (both O(N)).
5. Bumps generation, notifies subscribers, schedules persist.

```lua
function M.VaultIndex:build_async(callback)
  if self._building then return end
  self._building = true
  -- ...
  local co = coroutine.create(function()
    local changed, deleted = self:_detect_changes()  -- O(N) walk
    -- ... process deletions, reparse changed files in batches ...
    self:_rebuild_name_index()       -- O(N) full rebuild
    self:_recompute_inlinks()        -- O(N) full rebuild
    self._ready = true
    self._building = false
    self:_schedule_persist()
    self:_notify_update()
  end)
  -- ...
end
```

#### `_detect_changes()` (line 717)

The O(N) filesystem walk. Recursively scans every directory, stats every
`.md` file, compares mtime+size:

```lua
function M.VaultIndex:_detect_changes()
  local changed = {}
  local seen = {}

  local function walk(abs_dir, rel_dir)
    local handle = vim.uv.fs_scandir(abs_dir)
    -- ... recurse directories, stat every .md file ...
    -- Compares entry.mtime and entry.size against stat
  end

  walk(self.vault_path, "")

  -- Detect deletions: files in index but not seen on disk
  local deleted = {}
  for rel_path in pairs(self.files) do
    if not seen[rel_path] then
      deleted[#deleted + 1] = rel_path
    end
  end

  return changed, deleted
end
```

#### `update_file()` (line 1304) and `update_files_batch()` (line 1329)

The existing single/batch file update methods. These are already wired up
and working:

```lua
function M.VaultIndex:update_file(abs_path)
  self:update_files_batch({ abs_path })
end

function M.VaultIndex:update_files_batch(abs_paths)
  -- ... stat + parse each file, handle deletions ...
  if #changed_rel_paths > 0 or #deleted_rel_paths > 0 then
    self:_rebuild_name_index()                    -- O(N) full rebuild
    self:_recompute_inlinks_incremental(...)      -- O(affected) incremental
    self:_schedule_persist()
    self:_notify_update(ctx)
  end
end
```

Note that `_recompute_inlinks_incremental()` is already O(affected) -- it
only removes old inlink contributions from affected sources and adds new
ones. But `_rebuild_name_index()` is still O(N).

#### `_rebuild_name_index()` (line 770)

Iterates over ALL files to rebuild `_name_index` and `_alias_index` from
scratch:

```lua
function M.VaultIndex:_rebuild_name_index()
  local name_idx = {}
  local alias_idx = {}

  for _, entry in pairs(self.files) do         -- O(N)
    local lower = entry.basename_lower
    -- ... add to name_idx by basename, rel_stem ...
    -- ... add to alias_idx by aliases ...
  end

  self._name_index = name_idx
  self._alias_index = alias_idx
  self:_detect_collisions(name_idx, alias_idx)  -- O(N)
end
```

#### `_recompute_inlinks_incremental()` (line 1099)

Already implements surgical inlink updates. Removes old contributions from
affected sources, then re-resolves outlinks for changed files. This is the
model we want to follow for name/alias indexes.

#### `remove_file()` (line 1309)

Handles file deletion:

```lua
function M.VaultIndex:remove_file(abs_path)
  -- ... compute rel_path, save old outlinks ...
  self.files[rel_path] = nil
  self:_rebuild_name_index()                             -- O(N)
  self:_recompute_inlinks_incremental(..., {}, { rel_path })
  self:_schedule_persist()
  self:_notify_update(...)
end
```

Again calls the full `_rebuild_name_index()`.

### File: `lua/andrew/vault/engine.lua`

#### Filesystem watcher (line 912)

The debounced watcher callback already uses targeted updates:

```lua
-- Inside the debounce timer callback:
if #paths > 0 then
  if idx._building then
    M.invalidate_caches({ scope = "all", skip_index = true })
  else
    idx:update_files_batch(paths)
    if #paths > 10 then
      M.invalidate_caches({ scope = "all", skip_index = true })
    else
      for _, p in ipairs(paths) do
        M.invalidate_caches({ scope = "file", path = p, skip_index = true })
      end
    end
  end
end
```

This is already correct. When the watcher knows which files changed, it
calls `update_files_batch()` directly instead of `build_async()`.

#### `invalidate_caches()` (line 37)

Routes to vault index based on scope:

```lua
if scope == "file" and path then
  idx:update_file(path)
elseif scope == "all" then
  idx:build_async()
end
```

The `scope == "all"` path triggers the full O(N) `build_async()`. This is
hit by the `FocusGained` autocmd.

### File: `lua/andrew/vault/init.lua`

#### `BufWritePost` handler (line 325)

```lua
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
```

This correctly uses `scope = "file"` which routes to `update_file()`.
No changes needed here.

#### `FocusGained` handler (line 362)

```lua
vim.api.nvim_create_autocmd("FocusGained", {
  group = inv_group,
  callback = function()
    cleanup.close_timer(focus_debounce_timer)
    focus_debounce_timer = vim.defer_fn(function()
      focus_debounce_timer = nil
      engine.invalidate_caches({ scope = "all" })
    end, 200)
  end,
})
```

This uses `scope = "all"` which triggers a full `build_async()`. This is
the correct behavior for `FocusGained` (we don't know what changed while
Neovim was in the background), but it should be noted that if the filesystem
watcher is active, external changes are already being tracked. The
`FocusGained` handler exists as a safety net for cases where the watcher
misses events.

---

## Implementation

### Target Files

| File | Change Type |
|------|-------------|
| `lua/andrew/vault/vault_index.lua` | Add incremental name/alias index methods |
| `lua/andrew/vault/engine.lua` | No changes needed (already uses targeted updates) |
| `lua/andrew/vault/init.lua` | Optimize FocusGained handler |

---

### Change 1: Add Incremental Name/Alias Index Update

#### Problem

`_rebuild_name_index()` iterates over ALL files every time ANY file changes.
For a single-file save, this means scanning 2000+ entries just to update one
file's name and alias contributions.

#### Method: `_update_name_index_incremental(old_entries, new_entries)`

Add a new method that surgically removes old name/alias contributions and
adds new ones, operating only on the changed files. The existing
`_rebuild_name_index()` remains for full rebuilds (initial load,
`:VaultIndexRebuild`).

#### Code to Add

Insert after `_rebuild_name_index()` (after line 804, before
`_detect_collisions()`):

```lua
--- Incrementally update the name and alias indexes for changed files.
--- Removes old contributions from old_entries, adds new ones from the
--- current self.files state for the given rel_paths.
---
--- This is O(changed) instead of O(N) for _rebuild_name_index().
---
---@param old_entries table<string, VaultIndexEntry|nil>  rel_path -> old entry (nil if new file)
---@param changed_rel_paths string[]  files that were re-parsed (still exist)
---@param deleted_rel_paths string[]  files that were removed
function M.VaultIndex:_update_name_index_incremental(old_entries, changed_rel_paths, deleted_rel_paths)
  local name_idx = self._name_index
  local alias_idx = self._alias_index

  -- Helper: remove a specific abs_path from a list in an index table.
  local function remove_from_list(idx_table, key, abs_path)
    local list = idx_table[key]
    if not list then return end
    for i = #list, 1, -1 do
      if list[i] == abs_path then
        table.remove(list, i)
      end
    end
    if #list == 0 then
      idx_table[key] = nil
    end
  end

  -- Helper: add abs_path to a list in an index table.
  local function add_to_list(idx_table, key, abs_path)
    if not idx_table[key] then
      idx_table[key] = {}
    end
    idx_table[key][#idx_table[key] + 1] = abs_path
  end

  -- Phase 1: Remove old contributions for ALL affected files (changed + deleted).
  local all_affected = {}
  for _, rp in ipairs(changed_rel_paths) do all_affected[#all_affected + 1] = rp end
  for _, rp in ipairs(deleted_rel_paths) do all_affected[#all_affected + 1] = rp end

  for _, rel_path in ipairs(all_affected) do
    local old = old_entries[rel_path]
    if not old then goto next_remove end

    -- Remove basename entry
    remove_from_list(name_idx, old.basename_lower, old.abs_path)

    -- Remove rel_stem entry
    local old_rel_stem = old.rel_path:gsub("%.md$", ""):lower()
    if old_rel_stem ~= old.basename_lower then
      remove_from_list(name_idx, old_rel_stem, old.abs_path)
    end

    -- Remove alias entries
    for _, alias in ipairs(old.aliases) do
      remove_from_list(alias_idx, alias, old.abs_path)
    end

    ::next_remove::
  end

  -- Phase 2: Add new contributions for changed (non-deleted) files.
  for _, rel_path in ipairs(changed_rel_paths) do
    local entry = self.files[rel_path]
    if not entry then goto next_add end

    -- Add basename
    add_to_list(name_idx, entry.basename_lower, entry.abs_path)

    -- Add rel_stem
    local rel_stem = entry.rel_path:gsub("%.md$", ""):lower()
    if rel_stem ~= entry.basename_lower then
      add_to_list(name_idx, rel_stem, entry.abs_path)
    end

    -- Add aliases
    for _, alias in ipairs(entry.aliases) do
      add_to_list(alias_idx, alias, entry.abs_path)
    end

    ::next_add::
  end

  -- Collision detection: skip for small batches (< 5 files) to avoid
  -- the O(N) scan in _detect_collisions(). The next full build will
  -- catch any new collisions.
  local total_affected = #changed_rel_paths + #deleted_rel_paths
  if total_affected >= 5 then
    self:_detect_collisions(name_idx, alias_idx)
  end
end
```

---

### Change 2: Wire Up Incremental Name Index in `update_files_batch()`

#### Problem

`update_files_batch()` calls `_rebuild_name_index()` (O(N)) even though it
has the exact old entries available. It should use
`_update_name_index_incremental()` instead.

#### Current Code (lines 1329-1380)

```lua
function M.VaultIndex:update_files_batch(abs_paths)
  local prefix = self.vault_path .. "/"
  local old_outlinks_map = {}
  local changed_rel_paths = {}
  local deleted_rel_paths = {}

  for _, abs_path in ipairs(abs_paths) do
    if abs_path:sub(1, #prefix) ~= prefix then goto continue end
    local rel_path = abs_path:sub(#prefix + 1)
    if not rel_path:match("%.md$") then goto continue end

    local old_entry = self.files[rel_path]
    if old_entry then
      old_outlinks_map[rel_path] = old_entry.outlinks or {}
    end

    local stat = vim.uv.fs_stat(abs_path)
    if not stat then
      if old_entry then
        self.files[rel_path] = nil
        deleted_rel_paths[#deleted_rel_paths + 1] = rel_path
      end
    else
      local entry = self:_parse_file(abs_path, rel_path, stat)
      if entry then
        self.files[rel_path] = entry
        changed_rel_paths[#changed_rel_paths + 1] = rel_path
      end
    end

    ::continue::
  end

  if #changed_rel_paths > 0 or #deleted_rel_paths > 0 then
    self:_rebuild_name_index()                                         -- HERE
    self:_recompute_inlinks_incremental(old_outlinks_map, changed_rel_paths, deleted_rel_paths)
    self:_schedule_persist()
    -- ... notify ...
  end
end
```

#### Modified Code

The key change is saving the old entries before overwriting them, and
calling the incremental method instead of the full rebuild:

```lua
function M.VaultIndex:update_files_batch(abs_paths)
  local prefix = self.vault_path .. "/"
  local old_outlinks_map = {}
  local old_entries = {}                                               -- NEW
  local changed_rel_paths = {}
  local deleted_rel_paths = {}

  for _, abs_path in ipairs(abs_paths) do
    if abs_path:sub(1, #prefix) ~= prefix then goto continue end
    local rel_path = abs_path:sub(#prefix + 1)
    if not rel_path:match("%.md$") then goto continue end

    local old_entry = self.files[rel_path]
    if old_entry then
      old_outlinks_map[rel_path] = old_entry.outlinks or {}
      old_entries[rel_path] = old_entry                                -- NEW
    end

    local stat = vim.uv.fs_stat(abs_path)
    if not stat then
      if old_entry then
        self.files[rel_path] = nil
        deleted_rel_paths[#deleted_rel_paths + 1] = rel_path
      end
    else
      local entry = self:_parse_file(abs_path, rel_path, stat)
      if entry then
        self.files[rel_path] = entry
        changed_rel_paths[#changed_rel_paths + 1] = rel_path
      end
    end

    ::continue::
  end

  if #changed_rel_paths > 0 or #deleted_rel_paths > 0 then
    self:_update_name_index_incremental(                               -- CHANGED
      old_entries, changed_rel_paths, deleted_rel_paths
    )
    self:_recompute_inlinks_incremental(old_outlinks_map, changed_rel_paths, deleted_rel_paths)
    self:_schedule_persist()
    local ctx = {}
    if #changed_rel_paths > 0 then
      local changed = {}
      for i, rp in ipairs(changed_rel_paths) do changed[i] = prefix .. rp end
      ctx.changed_paths = changed
    end
    if #deleted_rel_paths > 0 then
      local deleted = {}
      for i, rp in ipairs(deleted_rel_paths) do deleted[i] = prefix .. rp end
      ctx.deleted_paths = deleted
    end
    self:_notify_update(ctx)
  end
end
```

#### Before/After for `update_files_batch()`

**Before** (lines 1329-1365):

```lua
  local old_outlinks_map = {}
  local changed_rel_paths = {}
  local deleted_rel_paths = {}

  for _, abs_path in ipairs(abs_paths) do
    -- ...
    local old_entry = self.files[rel_path]
    if old_entry then
      old_outlinks_map[rel_path] = old_entry.outlinks or {}
    end
    -- ...
  end

  if #changed_rel_paths > 0 or #deleted_rel_paths > 0 then
    self:_rebuild_name_index()
```

**After:**

```lua
  local old_outlinks_map = {}
  local old_entries = {}
  local changed_rel_paths = {}
  local deleted_rel_paths = {}

  for _, abs_path in ipairs(abs_paths) do
    -- ...
    local old_entry = self.files[rel_path]
    if old_entry then
      old_outlinks_map[rel_path] = old_entry.outlinks or {}
      old_entries[rel_path] = old_entry
    end
    -- ...
  end

  if #changed_rel_paths > 0 or #deleted_rel_paths > 0 then
    self:_update_name_index_incremental(old_entries, changed_rel_paths, deleted_rel_paths)
```

---

### Change 3: Wire Up Incremental Name Index in `remove_file()`

#### Current Code (lines 1309-1323)

```lua
function M.VaultIndex:remove_file(abs_path)
  local prefix = self.vault_path .. "/"
  if abs_path:sub(1, #prefix) ~= prefix then return end
  local rel_path = abs_path:sub(#prefix + 1)

  local old_entry = self.files[rel_path]
  if old_entry then
    local old_outlinks_map = { [rel_path] = old_entry.outlinks or {} }
    self.files[rel_path] = nil
    self:_rebuild_name_index()
    self:_recompute_inlinks_incremental(old_outlinks_map, {}, { rel_path })
    self:_schedule_persist()
    self:_notify_update({ deleted_paths = { abs_path } })
  end
end
```

#### Modified Code

```lua
function M.VaultIndex:remove_file(abs_path)
  local prefix = self.vault_path .. "/"
  if abs_path:sub(1, #prefix) ~= prefix then return end
  local rel_path = abs_path:sub(#prefix + 1)

  local old_entry = self.files[rel_path]
  if old_entry then
    local old_outlinks_map = { [rel_path] = old_entry.outlinks or {} }
    local old_entries = { [rel_path] = old_entry }
    self.files[rel_path] = nil
    self:_update_name_index_incremental(old_entries, {}, { rel_path })  -- CHANGED
    self:_recompute_inlinks_incremental(old_outlinks_map, {}, { rel_path })
    self:_schedule_persist()
    self:_notify_update({ deleted_paths = { abs_path } })
  end
end
```

#### Before/After

**Before** (line 1318):

```lua
    self:_rebuild_name_index()
```

**After:**

```lua
    local old_entries = { [rel_path] = old_entry }
    -- ...
    self:_update_name_index_incremental(old_entries, {}, { rel_path })
```

---

### Change 4: Optimize `FocusGained` Handler

#### Problem

The `FocusGained` autocmd in `init.lua` (line 362) triggers
`invalidate_caches({ scope = "all" })` which calls `build_async()`. This is
the full O(N) filesystem walk. When the filesystem watcher is already active
and tracking changes, `FocusGained` is redundant for index updates -- the
watcher will have already queued any changes that occurred while Neovim was
in the background.

#### Solution

Skip the vault index rebuild in `FocusGained` when the filesystem watcher is
active. The watcher's debounce timer will fire and handle any pending changes.
Only fall through to `build_async()` when the watcher is not running (e.g.,
watcher disabled in config, or inotify limit reached).

#### Current Code (`init.lua`, lines 361-371)

```lua
local focus_debounce_timer = nil
vim.api.nvim_create_autocmd("FocusGained", {
  group = inv_group,
  callback = function()
    cleanup.close_timer(focus_debounce_timer)
    focus_debounce_timer = vim.defer_fn(function()
      focus_debounce_timer = nil
      engine.invalidate_caches({ scope = "all" })
    end, 200)
  end,
})
```

#### Modified Code

```lua
local focus_debounce_timer = nil
vim.api.nvim_create_autocmd("FocusGained", {
  group = inv_group,
  callback = function()
    cleanup.close_timer(focus_debounce_timer)
    focus_debounce_timer = vim.defer_fn(function()
      focus_debounce_timer = nil
      -- When the fs watcher is active, it already tracks external changes.
      -- Only invalidate downstream caches (skip the O(N) index rebuild).
      local ws = engine.watcher_status()
      if ws.active then
        engine.invalidate_caches({ scope = "all", skip_index = true })
      else
        engine.invalidate_caches({ scope = "all" })
      end
    end, 200)
  end,
})
```

#### Before/After

**Before** (line 369):

```lua
      engine.invalidate_caches({ scope = "all" })
```

**After:**

```lua
      local ws = engine.watcher_status()
      if ws.active then
        engine.invalidate_caches({ scope = "all", skip_index = true })
      else
        engine.invalidate_caches({ scope = "all" })
      end
```

---

## Edge Cases

### File Rename

A rename is observed by the filesystem watcher as two events: a deletion of
the old path and a creation of the new path. The watcher's debounce window
(configurable via `config.index.watch_debounce_ms`) batches these together,
so both paths arrive in a single `update_files_batch()` call. The batch
method handles this correctly:

- Old path: `fs_stat` returns nil, entry removed from `self.files`, added
  to `deleted_rel_paths`.
- New path: `fs_stat` succeeds, file parsed, entry added to `self.files`,
  added to `changed_rel_paths`.
- `_update_name_index_incremental()` removes the old name/alias entries and
  adds the new ones.
- `_recompute_inlinks_incremental()` removes old inlink contributions and
  resolves new outlinks.

No special handling needed. The existing debounce+batch design covers this.

### Concurrent `build_async()` and `update_file()`

The watcher already handles this. If `idx._building` is true when the
debounce fires, it skips the targeted update and falls back to cache
invalidation only:

```lua
if idx._building then
  M.invalidate_caches({ scope = "all", skip_index = true })
```

The running `build_async()` will pick up the changes in its own filesystem
walk (it reads the current state of the disk). When it completes, it calls
`_rebuild_name_index()` and `_recompute_inlinks()` which will reflect the
latest state.

### New File (No Old Entry)

When a file is created, `old_entries[rel_path]` is nil. The incremental
name index update's Phase 1 (removal) skips files with no old entry via
the `if not old then goto next_remove end` guard. Phase 2 (addition) adds
the new file's name and alias contributions normally.

### Collision Detection After Incremental Updates

Full collision detection (`_detect_collisions()`) is O(N) because it scans
all name and alias index entries. To avoid running this on every single-file
save, the incremental method skips collision detection for small batches
(fewer than 5 files). Collisions will be detected on the next full rebuild
(`:VaultIndexRebuild`, startup, or `FocusGained` without watcher).

This is acceptable because collisions are informational warnings, not
correctness-critical. A user creating a collision will see the warning the
next time the full index is rebuilt.

---

## Performance Analysis

### Before (Single-File Save)

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| `update_file()` delegates to `update_files_batch()` | | |
| `fs_stat` + `_parse_file` for 1 file | O(1) | Already targeted |
| `_rebuild_name_index()` | **O(N)** | Iterates all 2000+ files |
| `_detect_collisions()` inside `_rebuild_name_index()` | **O(N)** | Scans all indexes |
| `_recompute_inlinks_incremental()` | O(affected) | Already incremental |
| **Total** | **O(N)** | Dominated by name index rebuild |

### After (Single-File Save)

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| `update_file()` delegates to `update_files_batch()` | | |
| `fs_stat` + `_parse_file` for 1 file | O(1) | Unchanged |
| `_update_name_index_incremental()` | **O(1)** | Removes old, adds new for 1 file |
| Collision detection skipped (batch < 5) | **O(0)** | Deferred to next full build |
| `_recompute_inlinks_incremental()` | O(affected) | Unchanged |
| **Total** | **O(1)** | Constant time per file |

### Full Rebuild (Unchanged)

`build_async()`, `build_sync()`, and `:VaultIndexRebuild` continue to use
the existing `_rebuild_name_index()` and `_recompute_inlinks()` methods.
These are unchanged and remain O(N), which is correct for full rebuilds.

### FocusGained (With Active Watcher)

| Before | After |
|--------|-------|
| Full `build_async()` = O(N) walk | `skip_index = true` = O(0) for index |

When the watcher is active, the watcher has already queued any changes. The
`FocusGained` handler only needs to invalidate downstream caches (embed
rendering, wikilink highlights, etc.), not re-walk the filesystem.

---

## Testing Instructions

### 1. Single-File Update Performance

1. Open a vault note and ensure the vault index is ready (`:VaultIndexStatus`
   shows `Ready: true`).
2. Add a temporary debug timer around the name index update. In
   `update_files_batch()`, add before and after the incremental call:
   ```lua
   local t0 = vim.uv.hrtime()
   self:_update_name_index_incremental(old_entries, changed_rel_paths, deleted_rel_paths)
   local dt = (vim.uv.hrtime() - t0) / 1e6
   vim.schedule(function()
     vim.notify(string.format("Name index update: %.2f ms", dt))
   end)
   ```
3. Save the file (`:w`). The notification should show sub-millisecond timing
   (typically < 0.1 ms for a single file).
4. Compare with the old `_rebuild_name_index()` by temporarily switching
   back. For a 2000+ note vault, the full rebuild should be noticeably
   slower (5-20 ms).

### 2. Name Index Correctness

1. Open a vault note and add a new alias in frontmatter:
   ```yaml
   aliases: [test-incremental-alias]
   ```
2. Save the file.
3. Try to navigate to the note using the alias:
   - `gf` on `[[test-incremental-alias]]` in another note.
   - Or use the vault search/picker to find it.
4. Verify the alias resolves correctly.
5. Remove the alias, save, and verify it no longer resolves.

### 3. File Deletion

1. Create a temporary test note: `echo "# Test" > ~/path/to/vault/test-delete.md`
2. Wait for the watcher debounce to fire (check `:VaultIndexStatus` for
   generation bump).
3. Verify the file appears in the index (search for "test-delete").
4. Delete the file: `rm ~/path/to/vault/test-delete.md`
5. Wait for the watcher debounce.
6. Verify the file is gone from the index. Its name and aliases should no
   longer resolve.

### 4. File Rename

1. Create a test note.
2. Rename it: `mv test-old.md test-new.md`
3. Wait for the watcher debounce.
4. Verify "test-old" no longer resolves and "test-new" does.
5. Verify inlinks are updated: if another note linked to `[[test-old]]`,
   that inlink should be gone from test-new's inlink list (the link target
   resolution happens dynamically, so the link text would need to be
   updated separately -- this is expected behavior).

### 5. FocusGained Optimization

1. Ensure the filesystem watcher is active (`:VaultWatcherStatus` shows
   `Active: true`).
2. Switch away from Neovim (e.g., to a terminal in another tmux pane).
3. Make a change to a vault file externally.
4. Switch back to Neovim.
5. The watcher should pick up the change via its debounce (check
   `:VaultWatcherStatus` for `Events received` count).
6. No full `build_async()` should be triggered (add a temporary
   `vim.notify("build_async called")` at the top of `build_async()` to
   verify).

### 6. Collision Detection Deferred for Small Batches

1. Create two notes with the same basename in different folders.
2. Save one of them.
3. Verify that no collision notification appears (batch size < 5, collision
   detection skipped).
4. Run `:VaultIndexRebuild`.
5. Verify the collision notification now appears (full rebuild runs
   `_detect_collisions()`).

---

## Summary of Changes

| File | Lines Changed | Description |
|------|---------------|-------------|
| `lua/andrew/vault/vault_index.lua` | ~80 added | Add `_update_name_index_incremental()` method |
| `lua/andrew/vault/vault_index.lua` | ~5 changed | `update_files_batch()`: save old entries, call incremental method |
| `lua/andrew/vault/vault_index.lua` | ~3 changed | `remove_file()`: call incremental method instead of full rebuild |
| `lua/andrew/vault/init.lua` | ~6 changed | `FocusGained`: skip index rebuild when watcher is active |

No new files. No new dependencies. No changes to engine.lua (already using
targeted updates). The existing `_rebuild_name_index()` remains for full
rebuilds and is unchanged.
