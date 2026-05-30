# 27 — Linux Recursive Filesystem Watcher

**Priority:** High (resolved)
**Status:** Implemented (see `completed/01-filesystem-watcher.md` for original plan)
**Files:** `lua/andrew/vault/engine.lua`, `lua/andrew/vault/init.lua`, `lua/andrew/vault/config.lua`

## Summary

On Linux, libuv's `uv_fs_event_t` wraps inotify, which does **not** support
recursive directory watching. The `{ recursive = true }` flag passed to
`vim.uv.new_fs_event():start()` is silently ignored on Linux — only the
specified directory itself is monitored. Subdirectory changes from external
tools (git pull, Syncthing, terminal file operations) were invisible to the
vault index.

The fix: detect the platform at runtime and, on Linux, walk all vault
subdirectories to set up individual inotify watches per directory. On macOS
(FSEvents) and Windows (ReadDirectoryChanges), a single recursive watch
suffices.

This feature was implemented as part of improvement `01-filesystem-watcher.md`.
This document serves as the authoritative technical reference for the current
implementation.

---

## Current Behavior Analysis

### Platform Detection

`engine.lua` line 850–853 — `platform_supports_recursive_watch()`:

```lua
local function platform_supports_recursive_watch()
  local sysname = vim.uv.os_uname().sysname
  return sysname == "Darwin" or sysname == "Windows_NT"
end
```

On Linux (`sysname == "Linux"`), this returns `false`, triggering the
per-directory code path. On macOS and Windows, it returns `true`, using a
single `{ recursive = true }` watch.

### Skip Directories

`engine.lua` line 857–859 — `watcher_skip_dirs()`:

```lua
local function watcher_skip_dirs()
  return require("andrew.vault.config").index.skip_dirs
end
```

Reads from `config.lua` line 333–339:

```lua
M.index = {
  skip_dirs = {
    [".obsidian"] = true,
    [".git"] = true,
    [".trash"] = true,
    [".vault-index"] = true,
    ["node_modules"] = true,
  },
  -- ...
}
```

Both `vault_index.lua` and `engine.lua` share this config, avoiding
duplication and circular dependencies (engine requires config; vault_index
receives skip_dirs via `configure()`).

### Module-Level State

`engine.lua` lines 861–872:

```lua
local _fs_watchers = {}            -- abs_dir -> uv_fs_event_t
local _fs_watcher_vault = nil
local _fs_debounce_timer = nil
local _pending_changed_files = {}  -- abs_path -> true
local _inotify_limit_warned = false
local _watcher_stats = {
  started_at = nil,
  dirs_watched = 0,
  events_received = 0,
  last_event_at = nil,
  last_event_file = nil,
}
```

- `_fs_watchers`: Maps each watched directory's absolute path to its
  `uv_fs_event_t` handle. On macOS, contains a single entry (vault root). On
  Linux, contains one entry per vault subdirectory.
- `_pending_changed_files`: Set (table with `abs_path -> true`) that
  accumulates all `.md` file changes during the debounce window. Replaces the
  old single-variable `_pending_changed_file` that lost all but the last event.
- `_inotify_limit_warned`: Ensures the inotify limit warning fires at most
  once per watcher session.

### Per-Directory Watch Setup

`engine.lua` lines 970–1010 — `add_dir_watch()`:

```lua
add_dir_watch = function(vault, abs_dir)
  if _fs_watchers[abs_dir] then return end

  local watcher = vim.uv.new_fs_event()
  if not watcher then return end

  local ok, _err = watcher:start(abs_dir, {}, function(err_msg, filename, events)
    on_fs_event(vault, abs_dir, err_msg, filename, events)
  end)

  if not ok then
    watcher:close()
    -- Warn once about inotify limit
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

  _fs_watchers[abs_dir] = watcher
  _watcher_stats.dirs_watched = _watcher_stats.dirs_watched + 1

  -- Recurse into subdirectories
  local handle = vim.uv.fs_scandir(abs_dir)
  if handle then
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if ftype == "directory" and not watcher_skip_dirs()[name] then
        add_dir_watch(vault, abs_dir .. "/" .. name)
      end
    end
  end
end
```

Key details:
- Each directory gets its own `uv_fs_event_t` with `{}` opts (no recursive
  flag — inotify watches exactly the directory given).
- `watcher:start()` returns `(ok, err)`. On failure (e.g., inotify limit
  reached), the handle is closed and a one-time warning is emitted via
  `vim.schedule` (safe from the libuv callback context).
- After establishing the watch, `fs_scandir` enumerates children. Directories
  not in `skip_dirs` are recursively watched. This is a synchronous depth-first
  walk at startup.
- The idempotency guard (`if _fs_watchers[abs_dir] then return end`) prevents
  double-watching the same directory.

### Event Callback

`engine.lua` lines 878–966 — `on_fs_event()`:

```lua
local function on_fs_event(vault, base_dir, err_msg, filename, _events)
  if err_msg then return end

  if filename then
    local abs_path = base_dir .. "/" .. filename

    -- Check if a new directory was created (Linux only)
    if not platform_supports_recursive_watch() then
      local stat = vim.uv.fs_stat(abs_path)
      if stat and stat.type == "directory" and not watcher_skip_dirs()[filename] then
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
      end
    end

    -- Only track .md file changes
    if filename:match("%.md$") then
      _pending_changed_files[abs_path] = true
      _watcher_stats.events_received = _watcher_stats.events_received + 1
      _watcher_stats.last_event_at = os.time()
      _watcher_stats.last_event_file = abs_path
    elseif vim.tbl_count(_pending_changed_files) == 0 then
      return
    end
  end

  -- Debounce: reset timer on each event
  -- ... (timer lifecycle below)
end
```

**New directory handling (Linux only):**

When a parent directory's watcher fires with a filename that `fs_stat` reveals
is a directory, `add_dir_watch()` is called to establish monitoring on the new
subdirectory. A race condition exists: files may be created in the new
directory between its creation and the watch being established. To cover this
gap, the callback immediately scans the new directory for `.md` files and adds
them to `_pending_changed_files`.

**Non-.md event optimization:**

If the filename does not end in `.md` and no `.md` files are pending, the
callback returns early without touching the debounce timer. This avoids
unnecessary timer churn from non-markdown file events (e.g., `.obsidian/`
config writes that leak through, image saves, etc.).

### Debounce and Batch Update

`engine.lua` lines 917–965 (within `on_fs_event`):

```lua
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
    else
      idx:build_async()
      M.invalidate_caches({ scope = "all", skip_index = true })
    end
  end))
```

**Timer lifecycle:** On each event, the previous timer is stopped AND closed
before creating a new one. This prevents handle leaks that occurred in the
original implementation (which only stopped, never closed).

**Batch processing:** All accumulated paths are consumed atomically via
`vim.tbl_keys(_pending_changed_files)`, then the set is cleared. This ensures
no events are lost between the read and reset.

**Build-in-progress guard:** If `idx._building` is true (a full async index
build is running), the batch update is skipped — the build will incorporate
these changes. Only cache invalidation fires so downstream modules know to
refresh.

**Adaptive invalidation scope:** For <= 10 files, per-file invalidation is
used (calls each registered cache's `invalidate_file()` if available). For
> 10 files, a single `scope = "all"` is more efficient.

**`skip_index = true`:** Passed to `invalidate_caches()` because the index
was already updated directly via `update_files_batch()` — prevents redundant
`idx:update_file()` calls from inside `invalidate_caches`.

### Watcher Startup

`engine.lua` lines 1012–1053 — `start_fs_watcher()`:

```lua
function M.start_fs_watcher()
  M.stop_fs_watcher()

  local config_mod = require("andrew.vault.config")
  if not config_mod.index.watch then return end

  local vault = M.vault_path
  if not vault or vim.fn.isdirectory(vault) == 0 then return end

  _fs_watcher_vault = vault
  _inotify_limit_warned = false
  _watcher_stats = { ... }

  if platform_supports_recursive_watch() then
    -- macOS/Windows: single recursive watch
    local watcher = vim.uv.new_fs_event()
    watcher:start(vault, { recursive = true }, function(...) ... end)
    _fs_watchers[vault] = watcher
    _watcher_stats.dirs_watched = 1
  else
    -- Linux: per-directory inotify watches
    add_dir_watch(vault, vault)
  end
end
```

- Respects `config.index.watch` — returns immediately if disabled.
- Calls `stop_fs_watcher()` first to clean up any existing watches.
- Platform branch: macOS/Windows get a single recursive watch; Linux walks
  subdirectories via `add_dir_watch()`.

### Watcher Shutdown

`engine.lua` lines 1056–1076 — `stop_fs_watcher()`:

```lua
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
```

Iterates all watcher handles, stops and closes each (wrapped in `pcall` for
safety — handles may already be invalid if the directory was deleted). Also
cleans up the debounce timer and pending file set.

### Watcher Status API

`engine.lua` lines 1079–1092 — `watcher_status()`:

```lua
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

### `:VaultWatcherStatus` Command

`init.lua` lines 471–505:

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
  -- ... uptime, last event time, last file, pending count
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, { desc = "Show filesystem watcher status" })
```

Also integrated into `:VaultIndexStatus` (init.lua lines 455–469) as a
summary line:

```lua
"  Watcher: " .. (ws.active and ("active, " .. ws.dirs_watched .. " dirs") or "inactive"),
```

---

## Configuration Options

All settings live in `config.lua` under `M.index`:

| Setting | Default | Description |
|---------|---------|-------------|
| `watch` | `true` | Enable/disable filesystem watcher entirely |
| `watch_debounce_ms` | `500` | Debounce interval for batching fs events (ms) |
| `skip_dirs` | `{".obsidian", ".git", ...}` | Directories excluded from watching and indexing |

To disable the watcher (e.g., on network/FUSE filesystems where inotify does
not work):

```lua
-- In config.lua
M.index.watch = false
```

The `FocusGained` autocmd and `BufWritePost` handling continue to provide
change detection as fallback when the watcher is disabled.

---

## inotify Limit Considerations

### The Limit

Linux limits per-user inotify watch descriptors via:

```
/proc/sys/fs/inotify/max_user_watches
```

Default on most distributions is **65536** (some set 524288). Each
per-directory watch in the vault consumes one descriptor.

### Typical Vault Impact

A vault with 100 directories uses 100 inotify watches — well within limits.
However, other applications also consume watches:

| Application | Typical watches |
|-------------|----------------|
| VS Code | 5,000–20,000 |
| Syncthing | 1,000–10,000 |
| Systemd | 100–500 |
| Vault plugin | 50–200 |

### When the Limit is Reached

If `watcher:start()` fails (returns `ok = false`), the implementation:

1. Closes the failed handle immediately
2. Emits a single warning notification (not repeated for subsequent failures)
3. Continues — directories that could not be watched simply lack real-time
   detection; changes are picked up on `FocusGained`

### Increasing the Limit

```bash
# Temporary (until reboot)
echo 524288 | sudo tee /proc/sys/fs/inotify/max_user_watches

# Permanent
echo 'fs.inotify.max_user_watches=524288' | sudo tee /etc/sysctl.d/50-inotify.conf
sudo sysctl -p /etc/sysctl.d/50-inotify.conf
```

### Current inotify Limit Warning

`engine.lua` lines 981–993 (inside `add_dir_watch`):

```lua
if not ok then
  watcher:close()
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

---

## Performance Considerations

### Startup Cost

The initial directory walk (`add_dir_watch` recursion) is synchronous and runs
during `init.lua` load. Each directory requires:

- 1 `uv_fs_event_init` + 1 `inotify_add_watch` syscall (via `watcher:start`)
- 1 `fs_scandir` + N `fs_scandir_next` calls to enumerate children

**Measured cost:** ~0.5–1ms per directory on modern Linux with SSD storage. A
vault with 50 directories adds ~25–50ms to startup — comparable to the index
load time and not noticeable.

For very large vaults (500+ directories), this could be made asynchronous via
coroutine scheduling, but this has not been needed in practice.

### Memory Overhead

Each `uv_fs_event_t` handle is a lightweight libuv object (~200 bytes). 100
watchers use ~20KB — negligible.

The `_pending_changed_files` set is bounded by the debounce window. During a
`git checkout` touching 500 files, the set briefly holds 500 string keys
(~50KB) before being consumed.

### Event Storm Handling

A `git checkout` or Syncthing sync can trigger hundreds of inotify events in
rapid succession. The debounce timer (default 500ms) collapses all events
within the window into a single `update_files_batch()` call. The batch
function:

1. Iterates `abs_paths`, calling `fs_stat` + `_parse_file` for each
2. Rebuilds name/alias indexes once (not per file)
3. Recomputes inlinks incrementally
4. Schedules a single persist

The adaptive invalidation threshold (>10 files -> `scope = "all"`) avoids
firing hundreds of per-file autocmds.

---

## Vault Index Integration

### `update_files_batch(abs_paths)`

`vault_index.lua` lines 1344–1395:

For each path in the batch:
- Captures old outlinks (for incremental inlink recomputation)
- Calls `fs_stat` — if nil, marks file as deleted; otherwise re-parses
- After processing all paths, rebuilds name index once, recomputes inlinks
  incrementally, schedules persist, and notifies subscribers with
  `changed_paths` and `deleted_paths` context

### `update_file(abs_path)`

`vault_index.lua` lines 1284–1342:

Single-file variant. Used by `invalidate_caches({ scope = "file" })` when
the watcher is not the caller (`skip_index = false`). Follows the same
parse-rebuild-notify pattern.

### Subscriber Notification

After `update_files_batch`, the index increments `_generation` and calls all
registered subscribers with:

```lua
{ changed_paths = { ... }, deleted_paths = { ... } }
```

Downstream modules (embed sync, connection graph, query system) use generation
tracking to detect when they need to refresh.

---

## Before/After Comparison

### Before (original single-watcher implementation)

```lua
-- engine.lua (old)
local _fs_watcher = nil
local _fs_watcher_path = nil
local _fs_debounce_timer = nil
local _pending_changed_file = nil  -- SINGLE file, last one wins

function M.start_fs_watcher()
  M.stop_fs_watcher()
  -- Did NOT check config.index.watch
  local vault = M.vault_path
  local watcher = vim.uv.new_fs_event()

  watcher:start(vault, { recursive = true }, function(err_msg, filename, events)
    -- recursive = true silently ignored on Linux
    if filename and not filename:match("%.md$") then return end
    if filename then
      _pending_changed_file = vault .. "/" .. filename  -- OVERWRITES previous
    else
      _pending_changed_file = nil
    end
    if _fs_debounce_timer then
      _fs_debounce_timer:stop()
      -- NEVER closed — handle leak
    end
    _fs_debounce_timer = vim.uv.new_timer()
    _fs_debounce_timer:start(FS_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
      local idx = vault_index_mod.current()
      if idx then
        if _pending_changed_file then
          idx:update_file(_pending_changed_file)  -- SINGLE file update
        else
          idx:build_async()
        end
      end
      M.invalidate_caches({ scope = "all" })  -- ALWAYS full invalidation
    end))
  end)
  _fs_watcher = watcher
end
```

**Problems:**
1. `recursive = true` silently ignored on Linux — only vault root watched
2. Single `_pending_changed_file` — rapid events overwrite, losing all but last
3. `config.index.watch` never checked
4. Timer handle leak (stopped but never closed)
5. Always `scope = "all"` invalidation even for single-file changes
6. No status reporting
7. No batch update support

### After (current implementation)

```lua
-- engine.lua (current) — abbreviated, see full code at lines 846-1092

local function platform_supports_recursive_watch()
  local sysname = vim.uv.os_uname().sysname
  return sysname == "Darwin" or sysname == "Windows_NT"
end

local _fs_watchers = {}            -- abs_dir -> uv_fs_event_t (MULTIPLE)
local _pending_changed_files = {}  -- abs_path -> true (SET accumulation)

local function on_fs_event(vault, base_dir, err_msg, filename, _events)
  -- Handles new directory creation (adds watch + scans for .md files)
  -- Accumulates .md changes into _pending_changed_files set
  -- Debounce timer: stop + CLOSE old, create new
  -- On fire: update_files_batch(paths), adaptive invalidation
end

add_dir_watch = function(vault, abs_dir)
  -- Per-directory inotify watch with skip_dirs filtering
  -- Recursion into subdirectories
  -- inotify limit warning (once per session)
end

function M.start_fs_watcher()
  -- Checks config.index.watch
  -- Platform branch: recursive (macOS/Win) vs per-directory (Linux)
end

function M.watcher_status()
  -- Full diagnostics: active, dirs_watched, events, uptime, etc.
end
```

**Fixes:**
1. Per-directory inotify watches on Linux — all subdirectories monitored
2. Set accumulation — all changed files during debounce window preserved
3. `config.index.watch` respected
4. Timer handles properly closed (no leaks)
5. Adaptive invalidation: per-file for small batches, full for large
6. `:VaultWatcherStatus` command for diagnostics
7. `update_files_batch()` used for efficient multi-file updates
8. New directory detection with race-condition coverage (post-watch scan)
9. inotify limit warning with graceful degradation

---

## Test Plan

### Manual Verification

1. **Watcher health check:**
   - Open a vault file in Neovim
   - Run `:VaultWatcherStatus`
   - Verify: `Active: true`, `Mode: per-directory (inotify)`,
     `Directories watched` > 1 (should match vault subdirectory count)

2. **Subdirectory change detection:**
   - In a terminal: `echo "# Test" > ~/Documents/Obsidian-Vault/Obsidian-Vault/Projects/test-watcher.md`
   - Wait 1 second (debounce)
   - In Neovim: search for "test-watcher" via vault search
   - Run `:VaultIndexStatus` — file count should have incremented
   - Run `:VaultWatcherStatus` — `Events received` > 0

3. **Multi-file batch (git pull simulation):**
   ```bash
   for i in {1..10}; do
     touch ~/Documents/Obsidian-Vault/Obsidian-Vault/Projects/batch-test-$i.md
   done
   ```
   - Wait 1 second
   - `:VaultWatcherStatus` — events_received shows ~10
   - `:VaultIndexStatus` — generation incremented once (batching confirmed)

4. **New directory detection:**
   ```bash
   mkdir -p ~/Documents/Obsidian-Vault/Obsidian-Vault/TestNewDir
   echo "# New" > ~/Documents/Obsidian-Vault/Obsidian-Vault/TestNewDir/new-note.md
   ```
   - Wait 1 second
   - `:VaultWatcherStatus` — `Directories watched` should have incremented
   - Search for "new-note" — should appear

5. **File deletion detection:**
   ```bash
   rm ~/Documents/Obsidian-Vault/Obsidian-Vault/Projects/test-watcher.md
   ```
   - Wait 1 second
   - `:VaultIndexStatus` — file count decremented
   - Search for "test-watcher" — should not appear

6. **Watcher disable:**
   - Set `config.index.watch = false` in config.lua
   - Restart Neovim
   - `:VaultWatcherStatus` — `Active: false`
   - Create a file externally — not detected until window focus returns

7. **Vault switch:**
   - `:VaultSwitch` and select a different vault
   - `:VaultWatcherStatus` — vault_path changed, dirs_watched reflects new vault

8. **Debounce verification:**
   ```bash
   for i in {1..50}; do touch ~/Documents/Obsidian-Vault/Obsidian-Vault/Log/debounce-$i.md; done
   ```
   - `:VaultWatcherStatus` — events_received climbs
   - `:VaultIndexStatus` — generation incremented only once

### Regression Checks

- `BufWritePost` invalidation still works (internal edits independent of watcher)
- `FocusGained` invalidation still works as fallback
- `:VaultIndexRebuild` works independently of watcher
- Embed sync refreshes on index subscriber notifications
- Completion, wikilink highlights, and link diagnostics update after external changes
- Calendar indicators update after external task metadata changes

---

## Files Modified (from original implementation)

| File | Changes |
|------|---------|
| `lua/andrew/vault/engine.lua` | Rewrote filesystem watcher: `platform_supports_recursive_watch()`, `on_fs_event()`, `add_dir_watch()`, `start_fs_watcher()`, `stop_fs_watcher()`, `watcher_status()`. Replaced single-variable tracking with set accumulation, added per-directory Linux watches, timer lifecycle fixes, adaptive invalidation, inotify limit warning. |
| `lua/andrew/vault/init.lua` | Added `:VaultWatcherStatus` command. Integrated watcher summary into `:VaultIndexStatus`. |
| `lua/andrew/vault/config.lua` | Added `skip_dirs` to `M.index` (shared between vault_index and engine watcher). Settings `watch`, `watch_debounce_ms` already existed. |
| `lua/andrew/vault/vault_index.lua` | No changes needed — `update_files_batch()` already existed. `SKIP_DIRS` now receives values from config via `configure()`. |
