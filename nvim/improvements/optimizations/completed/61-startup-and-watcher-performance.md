# 61 --- Startup & Filesystem Watcher Performance

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

Two targeted optimizations for the vault initialization pipeline and
filesystem watcher, addressing a blocking fallback scan and eager directory
scanning on mkdir.

> **Modules affected:** `engine.lua`, `engine_watcher.lua`

---

## 1. Remove Blocking Fallback in get_name_cache() — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/engine.lua` (lines 454-478)

`get_name_cache()` has a synchronous fallback that spawns `fd` or `find` and
blocks the entire event loop:

```lua
-- engine.lua:454-478 (simplified)
function M.get_name_cache()
    -- Try vault index first
    local vi = require("andrew.vault.vault_index")
    local idx = vi.current()
    if idx and idx:is_ready() then
        return idx:get_name_cache()
    end

    -- BLOCKING FALLBACK: synchronous shell command
    local cmd = { "fd", "--type", "f", "--extension", "md", ... }
    local result = vim.system(cmd, { text = true }):wait()  -- BLOCKS EVENT LOOP
    -- ... process result ...
end
```

This fallback was needed before the vault index existed, but now the vault
index is initialized early in the startup sequence. The blocking fallback can
fire during a narrow window between `init.lua` loading and the vault index
becoming ready.

**Impact:** 200-1000ms blocking during startup on large vaults.

### Proposed Solution

Replace the blocking fallback with a non-blocking empty cache return. Callers
already handle empty results gracefully (empty pickers, no completions).

### Code Changes

```lua
function M.get_name_cache()
    local vi = require("andrew.vault.vault_index")
    local idx = vi.current()
    if idx and idx:is_ready() then
        return idx:get_name_cache()
    end

    -- Non-blocking: return empty cache, callers handle gracefully
    log.debug("vault index not ready, returning empty name cache")
    return { paths = {}, names = {} }
end
```

### Expected Performance Improvement

- **Before:** 200-1000ms blocking on startup (vault-size dependent)
- **After:** 0ms blocking. Empty cache returned instantly; vault index
  populates asynchronously and subsequent calls return full data.

### Risk Assessment

- **Temporary empty results:** During the brief window before the vault index
  is ready, completion and pickers show no results. This window is typically
  <500ms and users are unlikely to invoke these features that quickly.
- **No regression path:** The synchronous fallback was a legacy mechanism.
  The vault index is the authoritative source. If the index fails to build,
  users can run `:VaultIndexRebuild` manually.

---

## 2. Skip Preemptive Directory Scan on mkdir — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/engine_watcher.lua` (lines 47-63)

When a new directory is created (Linux inotify path), the watcher immediately
scans the directory for `.md` files:

```lua
-- engine_watcher.lua:47-63
if stat and stat.type == "directory" and not watcher_skip_dirs()[filename] then
    add_dir_watch(vault, abs_path)
    -- Preemptive scan for .md files created before watch was established
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
```

This scan is defensive — it catches `.md` files created in a directory before
the watch is established (race condition). However, in practice:

1. Most new directories are created empty (user creates folder, then files)
2. When bulk-importing, the files trigger their own creation events
3. The scan is synchronous and blocks the event callback

### Proposed Solution

Remove the preemptive scan. Rely on the filesystem watch (now established) to
catch any files created after the watch is set up. For the narrow race window,
add a single deferred re-scan after a short delay.

### Code Changes

```lua
if stat and stat.type == "directory" and not watcher_skip_dirs()[filename] then
    add_dir_watch(vault, abs_path)

    -- Deferred scan: catch files created before watch was established
    -- (narrow race window). Non-blocking.
    vim.defer_fn(function()
        local dir_handle = vim.uv.fs_scandir(abs_path)
        if dir_handle then
            local found_any = false
            while true do
                local name, ftype = vim.uv.fs_scandir_next(dir_handle)
                if not name then break end
                if ftype == "file" and name:match("%.md$") then
                    if not _pending_changed_files[abs_path .. "/" .. name] then
                        _pending_changed_files[abs_path .. "/" .. name] = true
                        _pending_count = _pending_count + 1
                        found_any = true
                    end
                end
            end
            if found_any then
                -- Trigger debounce to process the newly found files
                on_fs_event(vault, base_dir, nil, filename, nil)
            end
        end
    end, 100)  -- 100ms delay — enough for the watch to be established
end
```

### Expected Performance Improvement

- **Before:** Synchronous directory scan blocking the event callback
- **After:** Non-blocking deferred scan with 100ms delay

For deeply nested vault structures where multiple directories are created
simultaneously (e.g., unzipping an archive), the deferred approach avoids
stacking synchronous scans.

### Risk Assessment

- **Race window:** Files created between `add_dir_watch()` and the deferred
  scan (0-100ms window) are caught by the filesystem watch. Files created
  before `add_dir_watch()` are caught by the deferred scan. No gap.
- **Duplicate processing:** The `_pending_changed_files` table deduplicates.
  A file caught by both the watch and the deferred scan is processed once.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Remove blocking fallback (#1) | Low | High | Low |
| 2 | Deferred directory scan (#2) | Low | Low | Low |

Both are 5-10 line changes each.

---

## Testing Strategy

### Blocking Fallback (#1)
1. Delete the persisted vault index. Start Neovim. Verify no blocking during
   startup (empty cache returned, index builds asynchronously).
2. After index builds, verify completion and pickers work normally.

### Deferred Directory Scan (#2)
1. Create a new directory in the vault. Add a `.md` file inside it.
   Verify the file appears in the vault index after debounce.
2. Bulk import a folder with many `.md` files. Verify all are indexed.

---

## Related Documents

- Doc 59-startup-lazy-loading covers broader phased module loading and lazy initialization.
- Doc 63-engine-startup-performance covers engine/watcher fast-path optimizations.
