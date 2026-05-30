# Filesystem Watcher for Vault Index

## Current State

The vault plugin already has a filesystem watcher implemented in `engine.lua`
(lines 921-1018) using `vim.uv.new_fs_event()`. It watches the vault root
directory with `{ recursive = true }` and debounces change events (default
500ms via `config.index.watch_debounce_ms`). On detecting a `.md` file change,
it either calls `idx:update_file()` for a targeted update or `idx:build_async()`
as a fallback, then invalidates all downstream caches.

### Current Watcher Implementation

```lua
-- engine.lua lines 921-998
local _fs_watcher = nil
local _fs_watcher_path = nil
local _fs_debounce_timer = nil
local FS_DEBOUNCE_MS = require("andrew.vault.config").index.watch_debounce_ms

function M.start_fs_watcher()
  M.stop_fs_watcher()
  local vault = M.vault_path
  local watcher = vim.uv.new_fs_event()
  local _pending_changed_file = nil

  watcher:start(vault, { recursive = true }, function(err_msg, filename, events)
    if filename and not filename:match("%.md$") then return end
    if filename then
      _pending_changed_file = vault .. "/" .. filename
    else
      _pending_changed_file = nil
    end
    -- Debounce into a single index update
    if _fs_debounce_timer then _fs_debounce_timer:stop() end
    _fs_debounce_timer = vim.uv.new_timer()
    _fs_debounce_timer:start(FS_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
      -- Update vault index (targeted or full)
      local idx = vault_index_mod.current()
      if idx then
        if _pending_changed_file then
          idx:update_file(_pending_changed_file)
        else
          idx:build_async()
        end
      end
      M.invalidate_caches({ scope = "all" })
    end))
  end)
  _fs_watcher = watcher
  _fs_watcher_path = vault
end
```

### Initialization Lifecycle

The watcher is started once in `init.lua` (line 370):

```lua
engine.start_fs_watcher()
```

It is also restarted on vault switch (`engine.switch_vault()`, line 127-129):

```lua
if M.start_fs_watcher then
  M.start_fs_watcher()
end
```

Separately, the vault index is initialized in `init.lua` (lines 376-392):

```lua
vi.configure({ ... })
local idx = vi.get(engine.vault_path)
idx:load()        -- Load persisted index (ready immediately)
idx:build_async() -- Incremental diff against filesystem
```

And persisted on exit (lines 395-403):

```lua
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    local idx = vi.current()
    if idx then idx:persist_now() end
  end,
})
```

### Supporting Infrastructure

**Vault index subscriber system** (`vault_index.lua` lines 108-129):

Downstream modules can subscribe to index updates via
`idx:subscribe(fn)`. The callback receives `(generation, context)` where
`context` optionally contains `changed_paths` and `deleted_paths`. This is
already used by the query system and connections module to avoid TTL polling.

**Cache registry** (`engine.lua` lines 9-102):

The `engine.invalidate_caches()` system iterates all registered caches. When
the fs watcher fires, it calls `invalidate_caches({ scope = "all" })` after
updating the vault index, which in turn fires the `VaultCacheInvalidate` User
autocmd for downstream consumers.

**Unified invalidation autocmds** (`init.lua` lines 250-302):

A consolidated `VaultCacheInvalidation` augroup handles `BufWritePost`,
`FileChangedShellPost`, `BufDelete`, and `FocusGained` events. These trigger
`invalidate_caches()` with appropriate scope.

### Config Settings

`config.lua` already defines watcher-related settings (lines 274-308):

```lua
M.index = {
  watch = true,             -- Enable filesystem watcher
  watch_debounce_ms = 500,  -- Debounce interval for fs events
  -- ... other index settings
}
```

## Problem

### 1. `recursive = true` is Unreliable on Linux

The `vim.uv.new_fs_event()` API wraps libuv's `uv_fs_event_t`, which uses
`inotify` on Linux. libuv's inotify backend **does not support recursive
watching** -- the `UV_FS_EVENT_RECURSIVE` flag is silently ignored. The call
succeeds without error, but only the top-level directory receives events.

This means on Linux (which is the target platform -- kernel 6.17.9), the
watcher only detects changes to files directly in the vault root. Changes in
subdirectories (`Projects/`, `Log/`, `Areas/`, etc.) are invisible.

The current code acknowledges this limitation in a comment (line 950-951):

```lua
-- On Linux where recursive=true may not work, remove this filter
-- and rely on debouncing alone (see note in docs).
```

But no actual fallback is implemented. The `.md` filter remains, and no
per-subdirectory watches are set up.

### 2. Only the Last Changed File is Tracked

The watcher stores only a single `_pending_changed_file` variable (line 957):

```lua
_pending_changed_file = vault .. "/" .. filename
```

If multiple files change within the debounce window (common during `git pull`,
Syncthing sync, or batch operations), only the last file's path is preserved.
All other changes are lost. The debounced callback then calls
`idx:update_file()` for that single file, leaving other modified files stale
until the next `FocusGained` or manual rebuild.

### 3. `config.index.watch` is Never Checked

The config has `watch = true` (line 290) but `start_fs_watcher()` never reads
this value. The watcher always starts regardless of the setting. Users on
network drives or FUSE filesystems who want to disable the watcher have no way
to do so without editing the source.

### 4. `invalidate_caches({ scope = "all" })` is Too Broad

Every fs watcher event triggers a full cache invalidation (`scope = "all"`),
even when the watcher knows exactly which file changed. The cache registry
supports `scope = "file"` with per-file invalidators, but the watcher does not
use it. This means a single-file external edit flushes every cache in the
system.

### 5. No Watcher Status Visibility

There is no way to inspect the watcher state -- whether it is running, which
path it watches, or whether it has received any events. The
`:VaultIndexStatus` command shows index readiness but not watcher health. On
Linux where recursive watching silently fails, the user has no indication that
subdirectory monitoring is broken.

### 6. Watcher Timer Leak on Rapid Events

The debounce timer creates a new `vim.uv.new_timer()` on every event (line
966) but only stops the previous one -- it never closes it. If the previous
timer was stopped but not closed, the handle leaks. Over a long session with
frequent fs events, this can accumulate stale timer handles.

### 7. No Batch Update Support

When the watcher falls back to `idx:build_async()` (no filename available), it
triggers a full directory walk and diff. The vault index already has
`update_files_batch(abs_paths)` (line 1264) which is more efficient for
multiple known files, but the watcher never uses it.

## Proposed Changes

### Overview

Replace the current single-`fs_event` watcher with a robust, Linux-aware
implementation that:

1. Watches each subdirectory individually on Linux (per-directory inotify
   watches)
2. Accumulates all changed files during the debounce window
3. Uses targeted `update_files_batch()` instead of single-file or full rebuild
4. Respects `config.index.watch`
5. Provides watcher status via `:VaultWatcherStatus`
6. Properly manages timer and handle lifecycles

### Architecture

```
                     +-------------------+
                     |  Filesystem       |
                     |  (.md files)      |
                     +--------+----------+
                              |
              per-directory inotify watches
              (one fs_event per subdirectory)
                              |
                     +--------v----------+
                     |  Event Collector  |
                     |  (accumulates     |
                     |   changed paths   |
                     |   during debounce)|
                     +--------+----------+
                              |
                     debounce timer fires
                              |
                     +--------v----------+
                     |  Batch Updater    |
                     |  update_files_    |
                     |  batch(paths)     |
                     +--------+----------+
                              |
                     +--------v----------+
                     |  Cache Invalidate |
                     |  scope="file" for |
                     |  each changed path|
                     +--------+----------+
                              |
                     +--------v----------+
                     |  Subscribers      |
                     |  (embed sync,     |
                     |   highlights,     |
                     |   diagnostics)    |
                     +-------------------+
```

### File Changes

**Modified files:**

| File | Changes |
|------|---------|
| `lua/andrew/vault/engine.lua` | Rewrite `start_fs_watcher()` / `stop_fs_watcher()`, add `watcher_status()`, add per-directory watch logic |
| `lua/andrew/vault/init.lua` | Add `:VaultWatcherStatus` command, gate `start_fs_watcher()` on `config.index.watch` |
| `lua/andrew/vault/config.lua` | No changes needed (settings already exist) |
| `lua/andrew/vault/vault_index.lua` | No changes needed (`update_files_batch` already exists) |

**No new files required.** All changes fit within the existing module
structure.

## Implementation Plan

### Step 1: Respect `config.index.watch`

**File:** `lua/andrew/vault/engine.lua`, `start_fs_watcher()`

Gate watcher startup on the config setting:

```lua
function M.start_fs_watcher()
  M.stop_fs_watcher()

  local config = require("andrew.vault.config")
  if not config.index.watch then
    return
  end

  local vault = M.vault_path
  if not vault or vim.fn.isdirectory(vault) == 0 then
    return
  end
  -- ... rest of implementation
end
```

**File:** `lua/andrew/vault/init.lua`, line 370

The call `engine.start_fs_watcher()` remains as-is since the guard is inside
the function itself.

### Step 2: Accumulate Changed Files During Debounce

Replace the single `_pending_changed_file` variable with a set that
accumulates all changed paths during the debounce window.

**File:** `lua/andrew/vault/engine.lua`

Replace:

```lua
local _pending_changed_file = nil
```

With:

```lua
local _pending_changed_files = {}  -- abs_path -> true (accumulated during debounce)
```

In the callback, accumulate instead of overwrite:

```lua
-- Old:
if filename then
  _pending_changed_file = vault .. "/" .. filename
else
  _pending_changed_file = nil
end

-- New:
if filename then
  _pending_changed_files[vault .. "/" .. filename] = true
end
```

In the debounced handler, consume the accumulated set:

```lua
-- Old:
if _pending_changed_file then
  idx:update_file(_pending_changed_file)
else
  idx:build_async()
end
_pending_changed_file = nil

-- New:
local paths = vim.tbl_keys(_pending_changed_files)
_pending_changed_files = {}

if #paths > 0 then
  idx:update_files_batch(paths)
  -- Use file-scoped invalidation for each changed file
  for _, abs_path in ipairs(paths) do
    M.invalidate_caches({ scope = "file", path = abs_path })
  end
else
  -- No filenames available (platform limitation) — full rebuild
  idx:build_async()
  M.invalidate_caches({ scope = "all" })
end
```

### Step 3: Fix Timer Handle Leak

The current code creates a new timer on each event without closing the old one
(only stops it). Fix by closing before creating.

**File:** `lua/andrew/vault/engine.lua`

Replace:

```lua
if _fs_debounce_timer then
  _fs_debounce_timer:stop()
end
_fs_debounce_timer = vim.uv.new_timer()
```

With:

```lua
if _fs_debounce_timer then
  _fs_debounce_timer:stop()
  _fs_debounce_timer:close()
  _fs_debounce_timer = nil
end
_fs_debounce_timer = vim.uv.new_timer()
```

### Step 4: Per-Directory Watching on Linux

This is the core change. On Linux, `uv_fs_event` with `recursive = true` only
watches the top-level directory. We need to set up individual watches on every
subdirectory in the vault.

**File:** `lua/andrew/vault/engine.lua`

Add a platform detection helper:

```lua
--- Check if the platform supports recursive fs_event watching.
--- macOS (kqueue/FSEvents) and Windows (ReadDirectoryChanges) support it.
--- Linux (inotify) does NOT — the recursive flag is silently ignored.
---@return boolean
local function platform_supports_recursive_watch()
  local sysname = vim.uv.os_uname().sysname
  return sysname == "Darwin" or sysname == "Windows_NT"
end
```

Rewrite `start_fs_watcher()` to use per-directory watches on Linux:

```lua
local _fs_watchers = {}          -- abs_dir -> uv_fs_event_t handle
local _fs_watcher_vault = nil    -- tracked vault path
local _fs_debounce_timer = nil
local _pending_changed_files = {}
local _watcher_stats = {
  started_at = nil,
  dirs_watched = 0,
  events_received = 0,
  last_event_at = nil,
  last_event_file = nil,
}

--- Shared callback for all fs_event watchers.
---@param vault string  vault root path
---@param base_dir string  the directory this watcher is attached to
---@param err_msg string|nil
---@param filename string|nil  relative to base_dir
---@param events table
local function on_fs_event(vault, base_dir, err_msg, filename, events)
  if err_msg then return end

  -- On Linux, directory creation/deletion events may arrive here.
  -- If a new directory is created, we need to add a watch for it.
  -- If a directory is deleted, the watch handle becomes invalid (libuv
  -- handles this gracefully — the callback just stops firing).
  if filename then
    local abs_path = base_dir .. "/" .. filename
    local stat = vim.uv.fs_stat(abs_path)

    if stat and stat.type == "directory" and not SKIP_DIRS[filename] then
      -- New subdirectory appeared — add a watch for it and recurse
      add_dir_watch(vault, abs_path)
      return
    end

    -- Only track .md file changes
    if not filename:match("%.md$") then return end

    _pending_changed_files[abs_path] = true
    _watcher_stats.events_received = _watcher_stats.events_received + 1
    _watcher_stats.last_event_at = os.time()
    _watcher_stats.last_event_file = abs_path
  end

  -- Debounce: reset timer on each event
  local config = require("andrew.vault.config")
  local debounce_ms = config.index.watch_debounce_ms

  if _fs_debounce_timer then
    _fs_debounce_timer:stop()
    _fs_debounce_timer:close()
    _fs_debounce_timer = nil
  end

  _fs_debounce_timer = vim.uv.new_timer()
  if not _fs_debounce_timer then return end

  _fs_debounce_timer:start(debounce_ms, 0, vim.schedule_wrap(function()
    if _fs_debounce_timer then
      _fs_debounce_timer:stop()
      _fs_debounce_timer:close()
      _fs_debounce_timer = nil
    end

    -- Consume accumulated changed files
    local paths = vim.tbl_keys(_pending_changed_files)
    _pending_changed_files = {}

    local vault_index_mod = package.loaded["andrew.vault.vault_index"]
    if not vault_index_mod then return end
    local idx = vault_index_mod.current()
    if not idx or idx.vault_path ~= vault:gsub("/$", "") then return end

    if #paths > 0 then
      idx:update_files_batch(paths)
      for _, abs_path in ipairs(paths) do
        M.invalidate_caches({ scope = "file", path = abs_path })
      end
    else
      idx:build_async()
      M.invalidate_caches({ scope = "all" })
    end
  end))
end

--- Add a fs_event watch on a single directory.
--- On Linux, also recurse into subdirectories.
---@param vault string  vault root path
---@param abs_dir string  directory to watch
local function add_dir_watch(vault, abs_dir)
  -- Skip if already watching this directory
  if _fs_watchers[abs_dir] then return end

  local watcher = vim.uv.new_fs_event()
  if not watcher then return end

  local ok, err = watcher:start(abs_dir, {}, function(err_msg, filename, events)
    on_fs_event(vault, abs_dir, err_msg, filename, events)
  end)

  if not ok then
    watcher:close()
    return
  end

  _fs_watchers[abs_dir] = watcher
  _watcher_stats.dirs_watched = _watcher_stats.dirs_watched + 1

  -- Recurse into subdirectories (for Linux per-dir watching)
  local handle = vim.uv.fs_scandir(abs_dir)
  if handle then
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if ftype == "directory" and not SKIP_DIRS[name] then
        add_dir_watch(vault, abs_dir .. "/" .. name)
      end
    end
  end
end

function M.start_fs_watcher()
  M.stop_fs_watcher()

  local config = require("andrew.vault.config")
  if not config.index.watch then
    return
  end

  local vault = M.vault_path
  if not vault or vim.fn.isdirectory(vault) == 0 then
    return
  end

  _fs_watcher_vault = vault
  _watcher_stats = {
    started_at = os.time(),
    dirs_watched = 0,
    events_received = 0,
    last_event_at = nil,
    last_event_file = nil,
  }

  if platform_supports_recursive_watch() then
    -- macOS/Windows: single recursive watch on vault root
    local watcher = vim.uv.new_fs_event()
    if not watcher then return end

    local ok, err = watcher:start(vault, { recursive = true },
      function(err_msg, filename, events)
        on_fs_event(vault, vault, err_msg, filename, events)
      end)

    if not ok then
      watcher:close()
      return
    end

    _fs_watchers[vault] = watcher
    _watcher_stats.dirs_watched = 1
  else
    -- Linux: per-directory watches (inotify does not support recursive)
    add_dir_watch(vault, vault)
  end
end
```

### Step 5: Handle New Directory Creation

When a new subdirectory is created in the vault (e.g., `mkdir Projects/Alpha`),
the per-directory watcher on `Projects/` receives an event with the directory
name. The callback in Step 4 detects this via `fs_stat` and calls
`add_dir_watch()` to start monitoring the new directory.

However, there is a race condition: files may be created in the new directory
between the directory creation event and the watch being established. To handle
this, after adding the watch, scan the new directory for any `.md` files that
may have appeared:

```lua
if stat and stat.type == "directory" and not SKIP_DIRS[filename] then
  add_dir_watch(vault, abs_path)
  -- Scan for .md files that may have been created before the watch started
  local dir_handle = vim.uv.fs_scandir(abs_path)
  if dir_handle then
    while true do
      local name, ftype = vim.uv.fs_scandir_next(dir_handle)
      if not name then break end
      if ftype == "file" and name:match("%.md$") then
        _pending_changed_files[abs_path .. "/" .. name] = true
      end
    end
  end
  return
end
```

### Step 6: Clean Up `stop_fs_watcher()`

**File:** `lua/andrew/vault/engine.lua`

Update to close all per-directory watchers:

```lua
function M.stop_fs_watcher()
  for dir, watcher in pairs(_fs_watchers) do
    pcall(function()
      watcher:stop()
      watcher:close()
    end)
  end
  _fs_watchers = {}
  _fs_watcher_vault = nil
  _watcher_stats.dirs_watched = 0

  if _fs_debounce_timer then
    pcall(function()
      _fs_debounce_timer:stop()
      _fs_debounce_timer:close()
    end)
    _fs_debounce_timer = nil
  end

  _pending_changed_files = {}
end
```

### Step 7: Add Watcher Status API

**File:** `lua/andrew/vault/engine.lua`

```lua
--- Get filesystem watcher status for diagnostics.
---@return table
function M.watcher_status()
  return {
    active = vim.tbl_count(_fs_watchers) > 0,
    vault_path = _fs_watcher_vault,
    recursive = platform_supports_recursive_watch(),
    dirs_watched = _watcher_stats.dirs_watched,
    events_received = _watcher_stats.events_received,
    started_at = _watcher_stats.started_at,
    last_event_at = _watcher_stats.last_event_at,
    last_event_file = _watcher_stats.last_event_file,
    pending_files = vim.tbl_count(_pending_changed_files),
  }
end
```

**File:** `lua/andrew/vault/init.lua`

Add a `:VaultWatcherStatus` command:

```lua
vim.api.nvim_create_user_command("VaultWatcherStatus", function()
  local status = engine.watcher_status()
  local lines = {
    "Vault Filesystem Watcher",
    string.rep("=", 40),
    "  Active: " .. tostring(status.active),
    "  Vault: " .. (status.vault_path or "none"),
    "  Mode: " .. (status.recursive and "recursive (single watch)"
                     or "per-directory (inotify)"),
    "  Directories watched: " .. status.dirs_watched,
    "  Events received: " .. status.events_received,
  }

  if status.started_at then
    local uptime = os.time() - status.started_at
    local h = math.floor(uptime / 3600)
    local m = math.floor((uptime % 3600) / 60)
    lines[#lines + 1] = string.format("  Uptime: %dh %dm", h, m)
  end

  if status.last_event_at then
    local ago = os.time() - status.last_event_at
    lines[#lines + 1] = string.format("  Last event: %ds ago", ago)
    if status.last_event_file then
      local rel = status.last_event_file
      if status.vault_path then
        rel = status.last_event_file:sub(#status.vault_path + 2)
      end
      lines[#lines + 1] = "  Last file: " .. rel
    end
  end

  if status.pending_files > 0 then
    lines[#lines + 1] = "  Pending (in debounce): " .. status.pending_files
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, { desc = "Show filesystem watcher status" })
```

### Step 8: Update `:VaultIndexStatus` to Include Watcher Info

**File:** `lua/andrew/vault/init.lua`

Extend the existing `:VaultIndexStatus` command (lines 415-430) to include a
watcher summary line:

```lua
vim.api.nvim_create_user_command("VaultIndexStatus", function()
  local idx = vi.current()
  if not idx then
    vim.notify("Vault index not initialized", vim.log.levels.WARN)
    return
  end
  local ws = engine.watcher_status()
  local lines = {
    "Vault Index Status",
    string.rep("=", 40),
    "  Vault: " .. idx.vault_path,
    "  Files: " .. idx:file_count(),
    "  Ready: " .. tostring(idx:is_ready()),
    "  Generation: " .. idx._generation,
    "  Watcher: " .. (ws.active and ("active, " .. ws.dirs_watched .. " dirs")
                        or "inactive"),
  }
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, { desc = "Show vault index status" })
```

## Complete Rewritten `start_fs_watcher()` / `stop_fs_watcher()`

This is the full implementation that replaces `engine.lua` lines 920-1018:

```lua
-- ---------------------------------------------------------------------------
-- Filesystem watcher for external change detection
-- ---------------------------------------------------------------------------

--- Check if the platform supports recursive fs_event watching.
local function platform_supports_recursive_watch()
  local sysname = vim.uv.os_uname().sysname
  return sysname == "Darwin" or sysname == "Windows_NT"
end

local _fs_watchers = {}            -- abs_dir -> uv_fs_event_t
local _fs_watcher_vault = nil
local _fs_debounce_timer = nil
local _pending_changed_files = {}  -- abs_path -> true
local _watcher_stats = {
  started_at = nil,
  dirs_watched = 0,
  events_received = 0,
  last_event_at = nil,
  last_event_file = nil,
}

-- Forward declaration for mutual recursion with on_fs_event
local add_dir_watch

--- Shared callback for all fs_event watchers.
local function on_fs_event(vault, base_dir, err_msg, filename, _events)
  if err_msg then return end

  if filename then
    local abs_path = base_dir .. "/" .. filename

    -- Check if a new directory was created (Linux only — need to add a watch)
    if not platform_supports_recursive_watch() then
      local stat = vim.uv.fs_stat(abs_path)
      if stat and stat.type == "directory" and not SKIP_DIRS[filename] then
        add_dir_watch(vault, abs_path)
        -- Scan for .md files created before watch was established
        local dir_handle = vim.uv.fs_scandir(abs_path)
        if dir_handle then
          while true do
            local name, ftype = vim.uv.fs_scandir_next(dir_handle)
            if not name then break end
            if ftype == "file" and name:match("%.md$") then
              _pending_changed_files[abs_path .. "/" .. name] = true
            end
          end
        end
        -- Fall through to trigger debounce (the new dir's .md files if any)
      end
    end

    -- Only track .md file changes for index updates
    if filename:match("%.md$") then
      _pending_changed_files[abs_path] = true
      _watcher_stats.events_received = _watcher_stats.events_received + 1
      _watcher_stats.last_event_at = os.time()
      _watcher_stats.last_event_file = abs_path
    elseif vim.tbl_count(_pending_changed_files) == 0 then
      -- Non-.md file change and no .md changes pending — skip debounce
      return
    end
  end

  -- Debounce: reset timer on each event
  local config_mod = require("andrew.vault.config")
  local debounce_ms = config_mod.index.watch_debounce_ms

  if _fs_debounce_timer then
    _fs_debounce_timer:stop()
    _fs_debounce_timer:close()
    _fs_debounce_timer = nil
  end

  _fs_debounce_timer = vim.uv.new_timer()
  if not _fs_debounce_timer then return end

  _fs_debounce_timer:start(debounce_ms, 0, vim.schedule_wrap(function()
    if _fs_debounce_timer then
      _fs_debounce_timer:stop()
      _fs_debounce_timer:close()
      _fs_debounce_timer = nil
    end

    local paths = vim.tbl_keys(_pending_changed_files)
    _pending_changed_files = {}

    local vault_index_mod = package.loaded["andrew.vault.vault_index"]
    if not vault_index_mod then return end
    local idx = vault_index_mod.current()
    if not idx or idx.vault_path ~= vault:gsub("/$", "") then return end

    if #paths > 0 then
      idx:update_files_batch(paths)
      for _, p in ipairs(paths) do
        M.invalidate_caches({ scope = "file", path = p })
      end
    else
      idx:build_async()
      M.invalidate_caches({ scope = "all" })
    end
  end))
end

--- Add a fs_event watch on a single directory.
--- On Linux, recurses into subdirectories.
add_dir_watch = function(vault, abs_dir)
  if _fs_watchers[abs_dir] then return end

  local watcher = vim.uv.new_fs_event()
  if not watcher then return end

  local ok, _err = watcher:start(abs_dir, {}, function(err_msg, filename, events)
    on_fs_event(vault, abs_dir, err_msg, filename, events)
  end)

  if not ok then
    watcher:close()
    return
  end

  _fs_watchers[abs_dir] = watcher
  _watcher_stats.dirs_watched = _watcher_stats.dirs_watched + 1

  -- Recurse into subdirectories
  local handle = vim.uv.fs_scandir(abs_dir)
  if handle then
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if ftype == "directory" and not SKIP_DIRS[name] then
        add_dir_watch(vault, abs_dir .. "/" .. name)
      end
    end
  end
end

--- Start watching the current vault root for filesystem changes.
function M.start_fs_watcher()
  M.stop_fs_watcher()

  local config_mod = require("andrew.vault.config")
  if not config_mod.index.watch then return end

  local vault = M.vault_path
  if not vault or vim.fn.isdirectory(vault) == 0 then return end

  _fs_watcher_vault = vault
  _watcher_stats = {
    started_at = os.time(),
    dirs_watched = 0,
    events_received = 0,
    last_event_at = nil,
    last_event_file = nil,
  }

  if platform_supports_recursive_watch() then
    -- macOS/Windows: single recursive watch
    local watcher = vim.uv.new_fs_event()
    if not watcher then return end

    local ok, _err = watcher:start(vault, { recursive = true },
      function(err_msg, filename, events)
        on_fs_event(vault, vault, err_msg, filename, events)
      end)

    if not ok then
      watcher:close()
      return
    end

    _fs_watchers[vault] = watcher
    _watcher_stats.dirs_watched = 1
  else
    -- Linux: per-directory inotify watches
    add_dir_watch(vault, vault)
  end
end

--- Stop the current filesystem watcher.
function M.stop_fs_watcher()
  for _, watcher in pairs(_fs_watchers) do
    pcall(function()
      watcher:stop()
      watcher:close()
    end)
  end
  _fs_watchers = {}
  _fs_watcher_vault = nil
  _watcher_stats.dirs_watched = 0

  if _fs_debounce_timer then
    pcall(function()
      _fs_debounce_timer:stop()
      _fs_debounce_timer:close()
    end)
    _fs_debounce_timer = nil
  end

  _pending_changed_files = {}
end

--- Get filesystem watcher status.
---@return table
function M.watcher_status()
  return {
    active = vim.tbl_count(_fs_watchers) > 0,
    vault_path = _fs_watcher_vault,
    recursive = platform_supports_recursive_watch(),
    dirs_watched = _watcher_stats.dirs_watched,
    events_received = _watcher_stats.events_received,
    started_at = _watcher_stats.started_at,
    last_event_at = _watcher_stats.last_event_at,
    last_event_file = _watcher_stats.last_event_file,
    pending_files = vim.tbl_count(_pending_changed_files),
  }
end
```

## Edge Cases and Considerations

### 1. inotify Watch Limit

Each per-directory watch consumes one inotify watch descriptor. The default
Linux limit is 65536 (`/proc/sys/fs/inotify/max_user_watches`), which is more
than sufficient for a typical vault (dozens to low hundreds of directories).
However, if other applications (VS Code, Syncthing) also consume inotify
watches, the system could approach the limit.

**Mitigation:** Log a warning if `watcher:start()` fails (which happens when
the inotify limit is reached) and fall back gracefully -- the watcher for that
directory simply won't be active, and changes there will be picked up on the
next `FocusGained` event.

```lua
if not ok then
  watcher:close()
  -- Only warn once to avoid spam
  if not _inotify_limit_warned then
    _inotify_limit_warned = true
    vim.schedule(function()
      vim.notify(
        "Vault: fs watcher could not watch " .. abs_dir
        .. " (inotify limit?). Some external changes may not be detected.",
        vim.log.levels.WARN
      )
    end)
  end
  return
end
```

### 2. Directory Rename Events

When a directory is renamed, inotify fires a `rename` event on both the old
and new names. The old watch handle becomes invalid (libuv stops delivering
events for it). The new directory name appears as a creation event on the
parent directory.

**Handling:** The `on_fs_event` callback already handles new directory
creation by calling `add_dir_watch()`. Stale watches on deleted/renamed
directories are harmless (libuv marks them as inactive) but waste a handle.
The `stop_fs_watcher()` function cleans up all handles.

For a more proactive cleanup, we could periodically prune watches whose
directories no longer exist. However, this adds complexity with little benefit
since directory renames in a vault are rare and handles are cleaned up on the
next `start_fs_watcher()` call (vault switch, Neovim restart).

### 3. Symlinks

The vault may contain symlinked directories (e.g., `Areas/` symlinked to a
shared directory). `vim.uv.fs_scandir` follows symlinks by default, so
`add_dir_watch()` will watch the symlink target. However, if the symlink
itself changes (re-pointed to a different target), the watch on the old target
remains active and the new target is unwatched.

**Mitigation:** The `FocusGained` full invalidation handles this case. For
most vaults, symlinks are static.

### 4. `.obsidian`, `.git`, `.vault-index` Directories

The `SKIP_DIRS` set in `vault_index.lua` (line 18-24) already excludes these
directories from indexing. The watcher should also skip them to avoid wasting
inotify handles on directories whose changes are irrelevant.

The `add_dir_watch` implementation in Step 4 already checks `SKIP_DIRS[name]`
before recursing. However, the `SKIP_DIRS` table is defined in
`vault_index.lua`, not `engine.lua`. The watcher code needs access to it.

**Options:**

a) **Import from vault_index** -- but this creates a dependency
   (`engine.lua` -> `vault_index.lua`). Currently `engine.lua` only references
   `vault_index` via `package.loaded` (lazy), which is by design to avoid
   circular dependencies.

b) **Duplicate the set in engine.lua** -- simple, maintainable given the set
   is small and stable.

c) **Move SKIP_DIRS to config.lua** -- cleanest, since both modules already
   require config.

**Recommendation:** Option (c). Add to `config.lua`:

```lua
M.index.skip_dirs = {
  [".obsidian"] = true,
  [".git"] = true,
  [".trash"] = true,
  [".vault-index"] = true,
  ["node_modules"] = true,
}
```

Then both `vault_index.lua` and `engine.lua` read from
`config.index.skip_dirs`. This is a separate refactor that can be done
alongside or after the watcher changes.

For the initial implementation, duplicating the set in `engine.lua` is
acceptable and avoids scope creep. The watcher already defines `SKIP_DIRS`
indirectly through its `.md` filter -- the main concern is not watching
`.git/objects/` (which has thousands of files). Adding a local `SKIP_DIRS`
constant to `engine.lua` near the watcher code is the simplest approach.

### 5. Rapid File Creation (e.g., `git checkout`)

A `git checkout` that touches 200 files will fire 200+ inotify events in rapid
succession. The debounce timer (500ms) absorbs these into a single
`update_files_batch()` call. The batch function already handles multiple files
efficiently (single rebuild of name index and inlinks).

However, `invalidate_caches({ scope = "file", path = p })` is called in a
loop for each file. Each call iterates the cache registry and fires the
`VaultCacheInvalidate` User autocmd. For 200 files, this means 200 autocmd
firings.

**Optimization:** Use a single `scope = "all"` invalidation when the batch
size exceeds a threshold:

```lua
if #paths > 0 then
  idx:update_files_batch(paths)
  if #paths > 10 then
    -- Many files changed — full invalidation is more efficient
    M.invalidate_caches({ scope = "all" })
  else
    for _, p in ipairs(paths) do
      M.invalidate_caches({ scope = "file", path = p })
    end
  end
end
```

### 6. Watcher on Network/FUSE Filesystems

inotify does not work on network filesystems (NFS, CIFS, SSHFS) or FUSE-based
sync mounts. For these cases, `config.index.watch = false` is the correct
setting. The `FocusGained` autocmd and `BufWritePost` handling continue to
work normally, providing change detection on focus return and local saves.

### 7. Startup Performance

On a vault with 50 directories, `add_dir_watch()` creates 50 `fs_event`
handles during startup. Each handle creation involves a `uv_fs_event_init` +
`inotify_add_watch` syscall, plus a `fs_scandir` + `fs_scandir_next` loop to
discover subdirectories.

**Estimated cost:** ~1ms per directory (measured by libuv benchmarks on modern
Linux). For 50 directories, total startup cost is ~50ms -- acceptable given
the index load + async build already takes 50-100ms.

For very large vaults (500+ directories), the initial watch setup could be
deferred to a coroutine to avoid blocking:

```lua
-- Optional: async watch setup for large vaults
local function add_dir_watch_async(vault, abs_dir, callback)
  local co = coroutine.create(function()
    add_dir_watch(vault, abs_dir)
    if callback then callback() end
  end)
  -- ... coroutine step scheduling as in build_async
end
```

This is not needed for the initial implementation but is a possible future
optimization.

### 8. Events During `build_async()`

If the watcher detects changes while `build_async()` is already running (e.g.,
during initial startup), the accumulated files will be processed after the
build completes. Since `update_files_batch()` checks `fs_stat()` for each
file, it correctly handles the case where a file was already processed by
the ongoing build.

However, if `build_async()` is in progress and the watcher calls
`update_files_batch()`, the two operations could interleave. The `_building`
flag in `vault_index.lua` prevents concurrent `build_async()` calls, but
`update_files_batch()` is synchronous and has no such guard.

**Mitigation:** Check `idx._building` before calling `update_files_batch()`:

```lua
if #paths > 0 then
  if idx._building then
    -- A full build is in progress; it will pick up these changes.
    -- Just invalidate caches so downstream modules know to refresh.
    M.invalidate_caches({ scope = "all" })
  else
    idx:update_files_batch(paths)
    -- ... invalidation
  end
end
```

## Testing Strategy

### Manual Verification

1. **Basic watcher health:**
   - Open a vault file in Neovim
   - Run `:VaultWatcherStatus`
   - Verify: active = true, mode = "per-directory (inotify)", dirs_watched > 1
   - Verify dirs_watched roughly matches the number of vault subdirectories

2. **Subdirectory change detection:**
   - In a terminal, create a new file: `echo "# Test" > ~/vault/Projects/test-watcher.md`
   - Wait 1 second (debounce)
   - In Neovim, verify the file appears in vault search/completion
   - Run `:VaultIndexStatus` -- verify file count incremented
   - Run `:VaultWatcherStatus` -- verify events_received > 0

3. **Multi-file batch (git pull simulation):**
   - In a terminal, touch 10 vault files: `for i in {1..10}; do touch ~/vault/Projects/note$i.md; done`
   - Wait 1 second
   - Run `:VaultWatcherStatus` -- verify events_received shows ~10 events
   - Run `:VaultIndexStatus` -- verify the index generation incremented once
     (not 10 times, confirming batching works)

4. **New directory detection:**
   - In a terminal: `mkdir ~/vault/TestDir && echo "# New" > ~/vault/TestDir/new.md`
   - Wait 1 second
   - Verify `new.md` is discoverable via vault search
   - Run `:VaultWatcherStatus` -- verify dirs_watched incremented

5. **Watcher disable:**
   - Set `config.index.watch = false` in config.lua
   - Restart Neovim
   - Run `:VaultWatcherStatus` -- verify active = false
   - Create a file externally -- verify it is NOT detected until `FocusGained`

6. **Vault switch:**
   - Run `:VaultSwitch` and select a different vault
   - Run `:VaultWatcherStatus` -- verify vault_path changed and dirs_watched
     reflects the new vault's directory structure

7. **File deletion detection:**
   - In a terminal: `rm ~/vault/Projects/test-watcher.md`
   - Wait 1 second
   - Verify the file no longer appears in vault search
   - Run `:VaultIndexStatus` -- verify file count decremented

8. **Debounce verification:**
   - Create 50 files rapidly in a terminal loop
   - Monitor `:VaultWatcherStatus` -- events_received should climb, but
     `:VaultIndexStatus` generation should only increment by 1 (single
     batched update)

### Automated Verification

Since the watcher is event-driven and depends on OS kernel behavior, automated
testing is limited. The key testable components are:

- **`platform_supports_recursive_watch()`:** Test on macOS and Linux to verify
  correct return values.
- **`_pending_changed_files` accumulation:** Mock the callback to verify
  multiple events accumulate correctly.
- **Debounce timer lifecycle:** Verify no timer leaks by checking
  `vim.uv.metrics()` handle counts before and after a burst of events.

### Regression Checks

- Verify that `BufWritePost` invalidation still works (internal edits should
  not depend on the watcher)
- Verify that `FocusGained` invalidation still works as a fallback
- Verify that `:VaultIndexRebuild` still works independently of the watcher
- Verify that embed sync continues to refresh on index updates (the subscriber
  system is unchanged)
- Verify that completion, wikilink highlights, and link diagnostics update
  after external file changes
