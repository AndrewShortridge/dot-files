# Vault Index Progress Indicator on Cold Start

## Problem

When Neovim launches for the first time (or after clearing `.vault-index/index.json`),
the vault index must scan and parse every `.md` file in the vault. During this scan:

- There is **no visual feedback** that indexing is happening
- The user has no way to know how many files remain or how long it will take
- Vault-dependent features (wikilink resolution, backlinks, tag search, completions)
  silently return incomplete results until the build finishes
- On a large vault (500+ files), the async build can take several seconds, during
  which the user may think Neovim is frozen or that vault features are broken
- Incremental rebuilds (warm start with a persisted index) are typically fast (<100ms
  for a handful of changed files) but still produce no feedback, even when a bulk
  external change (e.g., git checkout, Obsidian sync) triggers a large diff

## Current State

### Startup Lifecycle (`init.lua` lines 373-380)

The vault index is initialized at the end of the main `init.lua` module load:

```lua
local vi = require("andrew.vault.vault_index")

if engine.vault_path and engine.vault_path ~= "" then
  local idx = vi.get(engine.vault_path)
  idx:load()          -- Load persisted index (synchronous, fast)
  idx:build_async()   -- Start incremental diff + re-parse (async, coroutine)
end
```

- `load()` reads `.vault-index/index.json`, decodes JSON, rebuilds derived indexes
  (`_rebuild_name_index`, `_recompute_inlinks`), and sets `_ready = true`. On a cold
  start, the file does not exist, so `load()` returns `false` and `_ready` stays
  `false`.
- `build_async()` creates a coroutine that runs `_detect_changes()` followed by
  batched `_parse_file()` calls, yielding between batches via `coroutine.yield()`.

### `build_async()` (`vault_index.lua` lines 1061-1110)

```lua
function M.VaultIndex:build_async(callback)
  if self._building then return end
  self._building = true

  local co = coroutine.create(function()
    local changed, deleted = self:_detect_changes()

    -- Process deletions immediately
    for _, rel_path in ipairs(deleted) do
      self.files[rel_path] = nil
    end

    -- Process changed files in batches
    for i = 1, #changed, _batch_size do
      local batch_end = math.min(i + _batch_size - 1, #changed)
      for j = i, batch_end do
        local file = changed[j]
        local entry = self:_parse_file(file.abs_path, file.rel_path, file.stat)
        if entry then
          self.files[file.rel_path] = entry
        end
      end
      coroutine.yield()
    end

    self:_rebuild_name_index()
    self:_recompute_inlinks()
    self._ready = true
    self._building = false
    self:_schedule_persist()
    self:_notify_update()

    if callback then callback() end
  end)

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

  vim.schedule(step)
end
```

Key observations:

- **`_detect_changes()`** runs first and walks the entire vault directory tree
  synchronously within the coroutine. This is the most expensive phase on cold start
  because every file is "changed" (nothing in `self.files` yet). It returns a
  `changed` list with every `.md` file and an empty `deleted` list.
- **Batch processing** iterates `changed` in chunks of `_batch_size` (default 20,
  configurable via `config.index.batch_size`). Each batch calls `_parse_file()` for
  each file (reads content, parses frontmatter, extracts tags/headings/links/tasks),
  then `coroutine.yield()` returns control. The `step()` function re-schedules via
  `vim.schedule(step)` to process the next batch.
- **Post-processing** (`_rebuild_name_index`, `_recompute_inlinks`) runs after all
  files are parsed. This is a single synchronous block within the coroutine (no yield).
- **No progress tracking**: the coroutine has no concept of total files, current
  position, or elapsed time. The only notification is the error path.
- **No completion notification**: when the build finishes, `_notify_update()` fires
  subscriber callbacks but produces no user-visible message.

### `_detect_changes()` (`vault_index.lua` lines 580-626)

This function walks the filesystem and compares `mtime`/`size` against stored entries:

```lua
function M.VaultIndex:_detect_changes()
  local changed = {}
  local seen = {}

  local function walk(abs_dir, rel_dir)
    -- ... recursive fs_scandir ...
    -- For each .md file: if not in self.files or mtime/size differs, add to changed
  end

  walk(self.vault_path, "")

  -- Detect deletions: entries in self.files not seen on disk
  local deleted = {}
  for rel_path in pairs(self.files) do
    if not seen[rel_path] then
      deleted[#deleted + 1] = rel_path
    end
  end

  return changed, deleted
end
```

On cold start (empty `self.files`), every file is added to `changed` and `deleted` is
empty. On warm start with a persisted index, only files with changed mtime/size appear
in `changed`, and files removed from disk appear in `deleted`.

### Existing Notifications

The only existing notification in `build_async()` is the error handler:

```lua
vim.notify("Vault index error: " .. tostring(err), vim.log.levels.ERROR)
```

The `VaultIndexRebuild` command (synchronous rebuild) has a completion message:

```lua
vim.notify("Vault index rebuilt: " .. idx:file_count() .. " files", vim.log.levels.INFO)
```

There is no progress or completion notification for the normal async startup path.

### Cold Start vs Warm Start

| Scenario | `load()` result | `_detect_changes()` `changed` count | Duration |
|----------|-----------------|--------------------------------------|----------|
| Cold start (no index.json) | `false` | All vault `.md` files | 1-10s+ |
| Warm start (fresh index) | `true` | 0 (no changes) | <10ms |
| Warm start (few edits) | `true` | 1-5 files | <50ms |
| Warm start (git checkout) | `true` | 10-100+ files | 200ms-2s |
| Warm start (stale index) | `true` | Many files | 1-5s |

### Config (`config.lua` lines 244-271)

```lua
M.index = {
  storage = "vault",
  sync_timeout_ms = 100,
  batch_size = 20,
  persist_debounce_ms = 5000,
  watch = true,
  watch_debounce_ms = 500,
  debug = false,
  warn_collisions = true,
}
```

No progress-related options exist.

## Solution

Add non-intrusive progress notifications during `build_async()` that show:

1. **Start message** (cold start only): `"Vault: Indexing [0/500]..."`
2. **Periodic updates** (every N batches): `"Vault: Indexing [150/500] 30%"`
3. **Completion message**: `"Vault: Index ready (500 files, 1.2s)"`
4. **Incremental update message** (when significant): `"Vault: Updated index (12 files, 0.3s)"`

Use `vim.notify()` with a stable notification ID so notification plugins that support
replacement (snacks.nvim notifier, nvim-notify, fidget.nvim) can update in-place rather
than stacking multiple messages. For the built-in `vim.notify`, messages simply replace
each other in the command line area.

### Design Decisions

- **Threshold for showing progress**: only show progress notifications when `#changed > 50`.
  Small incremental updates (1-50 files) complete fast enough that progress is unnecessary.
  They still get a completion message if `#changed > 0` and `config.index.show_progress`
  is enabled.
- **Completion message always shown on cold start**: regardless of file count, because the
  user needs confirmation that the index is ready and vault features are fully operational.
- **Notification level**: `vim.log.levels.INFO` for progress and completion,
  `vim.log.levels.ERROR` for errors (already exists).
- **Update frequency**: notify every `progress_batch_interval` batches (default: 5,
  meaning every 100 files at default batch_size of 20). This avoids excessive redraws
  while still providing meaningful feedback.
- **Timing**: use `vim.uv.hrtime()` for nanosecond precision, converted to seconds for
  display.
- **Configurable**: `config.index.show_progress = true` (default enabled). Can be
  disabled by users who find the notifications distracting.
- **No external dependencies**: uses only `vim.notify()` and `vim.uv.hrtime()`. Works
  with any notification backend or the built-in command line.

### Notification Format

| Scenario | Message | Level |
|----------|---------|-------|
| Cold start begin | `Vault: Indexing vault [0/523]...` | INFO |
| Cold start progress | `Vault: Indexing [140/523] 27%` | INFO |
| Cold start complete | `Vault: Index ready (523 files, 2.1s)` | INFO |
| Incremental (large) begin | `Vault: Updating index [0/87]...` | INFO |
| Incremental (large) progress | `Vault: Updating index [60/87] 69%` | INFO |
| Incremental (large) complete | `Vault: Index updated (87 files changed, 0.8s)` | INFO |
| Incremental (small) complete | `Vault: Index updated (3 files, 0.1s)` | INFO |
| Error | `Vault index error: [message]` | ERROR |

Cold start is distinguished from incremental by checking whether `self._ready` was
already `true` before `build_async()` began (i.e., whether `load()` succeeded).

## Implementation Steps

### Step 1: Add Config Options

**File**: `lua/andrew/vault/config.lua`

Add `show_progress` and `progress_threshold` to the `M.index` table:

```lua
M.index = {
  -- ... existing fields ...

  -- Show progress notifications during index builds.
  show_progress = true,

  -- Minimum number of changed files before showing progress bar.
  -- Below this threshold, only the completion message is shown.
  progress_threshold = 50,
}
```

### Step 2: Add Progress State and Helpers to `build_async()`

**File**: `lua/andrew/vault/vault_index.lua`

Add module-level configuration variables alongside the existing `_batch_size` and
`_persist_debounce_ms`:

```lua
local _show_progress = true
local _progress_threshold = 50
```

Update `M.configure()` to accept the new options:

```lua
function M.configure(opts)
  if opts.batch_size then _batch_size = opts.batch_size end
  if opts.persist_debounce_ms then _persist_debounce_ms = opts.persist_debounce_ms end
  if opts.show_progress ~= nil then _show_progress = opts.show_progress end
  if opts.progress_threshold then _progress_threshold = opts.progress_threshold end
end
```

### Step 3: Add a Notification Helper with Stable ID

**File**: `lua/andrew/vault/vault_index.lua`

Add a helper that passes a consistent `id` field for notification plugins that support
replacement. The built-in `vim.notify` ignores extra keys in the opts table, so this is
safe.

```lua
--- Emit a progress notification. Uses a stable ID so plugins that support
--- notification replacement (snacks.nvim, nvim-notify) update in-place.
---@param msg string
---@param level number vim.log.levels.*
local function progress_notify(msg, level)
  vim.notify(msg, level, {
    title = "Vault Index",
    id = "vault_index_progress",
    -- For nvim-notify: replace existing notification with same id
    replace = "vault_index_progress",
  })
end
```

### Step 4: Modify `build_async()` to Track and Report Progress

**File**: `lua/andrew/vault/vault_index.lua`, function `build_async()` (line 1061)

Replace the current implementation with progress tracking. The key changes are:

1. Record `start_time` before the coroutine begins
2. Determine `is_cold_start` from `self._ready` state before building
3. After `_detect_changes()`, compute `total` and decide whether to show progress
4. Inside the batch loop, emit periodic progress notifications
5. After completion, emit a summary notification

```lua
function M.VaultIndex:build_async(callback)
  if self._building then return end
  self._building = true

  local start_time = vim.uv.hrtime()
  local is_cold_start = not self._ready

  local co = coroutine.create(function()
    local changed, deleted = self:_detect_changes()

    local total = #changed
    local total_deleted = #deleted
    local show_progress = _show_progress
      and (total >= _progress_threshold or is_cold_start)
    local batch_notify_interval = 5  -- notify every N batches

    -- Initial notification
    if show_progress and total > 0 then
      local verb = is_cold_start and "Indexing vault" or "Updating index"
      vim.schedule(function()
        progress_notify(
          string.format("Vault: %s [0/%d]...", verb, total),
          vim.log.levels.INFO
        )
      end)
    end

    -- Process deletions immediately
    for _, rel_path in ipairs(deleted) do
      self.files[rel_path] = nil
    end

    -- Process changed files in batches
    local processed = 0
    local batch_count = 0
    for i = 1, total, _batch_size do
      local batch_end = math.min(i + _batch_size - 1, total)
      for j = i, batch_end do
        local file = changed[j]
        local entry = self:_parse_file(file.abs_path, file.rel_path, file.stat)
        if entry then
          self.files[file.rel_path] = entry
        end
        processed = processed + 1
      end
      batch_count = batch_count + 1

      -- Periodic progress notification
      if show_progress and total > 0 and batch_count % batch_notify_interval == 0 then
        local pct = math.floor(processed / total * 100)
        local verb = is_cold_start and "Indexing" or "Updating index"
        vim.schedule(function()
          progress_notify(
            string.format("Vault: %s [%d/%d] %d%%", verb, processed, total, pct),
            vim.log.levels.INFO
          )
        end)
      end

      coroutine.yield()
    end

    self:_rebuild_name_index()
    self:_recompute_inlinks()
    self._ready = true
    self._building = false
    self:_schedule_persist()
    self:_notify_update()

    -- Completion notification
    if _show_progress and (total > 0 or total_deleted > 0 or is_cold_start) then
      local elapsed = (vim.uv.hrtime() - start_time) / 1e9
      local msg
      if is_cold_start then
        msg = string.format(
          "Vault: Index ready (%d files, %.1fs)",
          self:file_count(), elapsed
        )
      elseif total > 0 or total_deleted > 0 then
        local parts = {}
        if total > 0 then
          parts[#parts + 1] = total .. " updated"
        end
        if total_deleted > 0 then
          parts[#parts + 1] = total_deleted .. " removed"
        end
        msg = string.format(
          "Vault: Index updated (%s, %.1fs)",
          table.concat(parts, ", "), elapsed
        )
      end
      if msg then
        vim.schedule(function()
          progress_notify(msg, vim.log.levels.INFO)
        end)
      end
    end

    if callback then callback() end
  end)

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

  vim.schedule(step)
end
```

### Step 5: Pass New Config Values in `engine.lua`

**File**: `lua/andrew/vault/engine.lua`, function `prebuild_name_cache_async()` (line 862)

Add the new config fields to the `configure()` call:

```lua
vault_index_mod.configure({
  batch_size = config.index.batch_size,
  persist_debounce_ms = config.index.persist_debounce_ms,
  show_progress = config.index.show_progress,
  progress_threshold = config.index.progress_threshold,
})
```

### Step 6: Pass Config Values in `init.lua` Bootstrap Path

**File**: `lua/andrew/vault/init.lua`, lines 373-380

The `init.lua` bootstrap path creates the index directly without going through
`prebuild_name_cache_async()`. It needs to also call `configure()`:

```lua
local vi = require("andrew.vault.vault_index")
local config = require("andrew.vault.config")

-- Pass config values before first use (vault_index has no require to avoid circular deps)
vi.configure({
  batch_size = config.index.batch_size,
  persist_debounce_ms = config.index.persist_debounce_ms,
  show_progress = config.index.show_progress,
  progress_threshold = config.index.progress_threshold,
})

if engine.vault_path and engine.vault_path ~= "" then
  local idx = vi.get(engine.vault_path)
  idx:load()
  idx:build_async()
end
```

## Files to Modify

| File | Changes |
|------|---------|
| `lua/andrew/vault/config.lua` | Add `show_progress = true` and `progress_threshold = 50` to `M.index` |
| `lua/andrew/vault/vault_index.lua` | Add `_show_progress`/`_progress_threshold` locals, update `configure()`, add `progress_notify()` helper, rewrite `build_async()` with progress tracking |
| `lua/andrew/vault/engine.lua` | Pass `show_progress` and `progress_threshold` in `configure()` call |
| `lua/andrew/vault/init.lua` | Add `configure()` call before `build_async()` in bootstrap path |

## Edge Cases

1. **Empty vault (0 files)**: `_detect_changes()` returns empty `changed` and `deleted`.
   On cold start, the completion message shows `"Vault: Index ready (0 files, 0.0s)"`.
   On warm start, no notification is emitted (nothing changed).

2. **Vault with only deleted files**: `changed` is empty, `deleted` is non-empty. The
   completion message shows `"Vault: Index updated (N removed, 0.1s)"`. No progress bar
   is shown (no parsing work to track).

3. **`build_async()` called while already building**: The `if self._building then return`
   guard prevents double-building. The second call is silently dropped. This is correct
   because the first build will pick up all changes.

4. **`show_progress = false`**: All `progress_notify()` calls are gated behind
   `_show_progress`. No notifications are emitted during builds. The error notification
   is NOT gated (errors should always be visible).

5. **Very fast cold start (small vault, <50 files)**: Falls below `progress_threshold`
   but `is_cold_start` is true, so progress is still shown. The initial and completion
   messages fire, but no intermediate progress updates (the build completes in 1-2
   batches, which is below `batch_notify_interval`).

6. **Coroutine error during build**: The existing error handler fires
   `vim.notify("Vault index error: ...")` with `ERROR` level. This is independent of
   the progress system and always visible.

7. **`vim.schedule` ordering**: Progress notifications use `vim.schedule()` inside the
   coroutine. Since `step()` also uses `vim.schedule()`, the notification for batch N
   is guaranteed to fire before batch N+1 begins processing. This ensures the progress
   numbers are accurate when displayed.

8. **Notification plugin not installed**: The `opts` table passed to `vim.notify()`
   contains extra keys (`id`, `replace`, `title`) that the built-in `vim.notify`
   ignores. Messages appear in the command line and are overwritten by subsequent
   messages, which is acceptable behavior.

## Performance Considerations

- **`vim.schedule` cost per notification**: Each `progress_notify()` call adds one
  `vim.schedule` callback. With `batch_notify_interval = 5` and `batch_size = 20`,
  notifications fire every 100 files. A 500-file vault produces ~5 progress
  notifications total. Negligible overhead.

- **`vim.uv.hrtime()` cost**: Called twice (start and end). Nanosecond timer read is
  essentially free.

- **No notification on every file**: The batch loop processes 20 files per yield. The
  notification fires every 5 yields (100 files). This avoids flooding the notification
  system.

- **String formatting**: `string.format()` is called only when a notification is emitted
  (every 100 files), not per-file. Negligible cost.

- **`_detect_changes()` phase**: This is the longest synchronous block in the coroutine
  (walks the entire filesystem before any yield). On very large vaults, this can block
  the event loop for 100ms+. The initial notification fires via `vim.schedule` after
  `_detect_changes()` returns (before the first batch). A future improvement could add
  yields within the walk itself, but that is out of scope for this change.

## Testing

### Manual Test Cases

1. **Cold start**: Delete `.vault-index/index.json`, restart Neovim. Verify:
   - Initial message appears: `"Vault: Indexing vault [0/N]..."`
   - Progress updates appear periodically (if vault has 100+ files)
   - Completion message appears: `"Vault: Index ready (N files, X.Xs)"`
   - File count matches actual vault `.md` files

2. **Warm start (no changes)**: Start Neovim normally. Verify:
   - No progress notifications appear
   - No completion notification appears

3. **Warm start (few changes)**: Edit 3 files externally, restart Neovim. Verify:
   - No progress bar (below threshold)
   - Completion message: `"Vault: Index updated (3 updated, 0.1s)"`

4. **Warm start (bulk changes)**: Check out a different git branch with many changed
   files, restart Neovim. Verify:
   - Progress notifications appear if >50 files changed
   - Completion message shows correct count and timing

5. **Disabled progress**: Set `config.index.show_progress = false`, restart. Verify:
   - No progress or completion notifications on cold start
   - Error notifications still appear if the index build fails

6. **`:VaultIndexStatus`**: Run after cold start completes. Verify file count matches
   the count reported in the completion notification.

### Verification Checklist

- [ ] Cold start shows progress and completion notifications
- [ ] Warm start with no changes produces no notifications
- [ ] Warm start with few changes (<50) shows only completion, no progress bar
- [ ] Warm start with many changes (>50) shows progress updates
- [ ] `show_progress = false` suppresses all progress/completion messages
- [ ] Error notifications still fire when `show_progress = false`
- [ ] File count in completion message matches `:VaultIndexStatus`
- [ ] Elapsed time in completion message is reasonable
- [ ] No duplicate notifications (build_async guard prevents double-build)
- [ ] Notification plugins that support replacement show a single updating message
- [ ] Built-in vim.notify shows messages in command line without errors
