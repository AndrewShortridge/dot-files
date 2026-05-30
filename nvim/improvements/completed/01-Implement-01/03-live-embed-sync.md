# Live Embed Sync

## Problem Statement

Embedded note transclusions (`![[...]]`) in the vault plugin are rendered as
virtual text extmarks by `embed.lua`. Once rendered, these embeds are static
snapshots: if the source note changes (edited in another buffer, modified by an
external tool, or synced from another machine), the embedded content remains
stale until the user manually triggers a refresh.

**Current refresh mechanisms:**

- `:VaultEmbedRender` -- manual command, requires user to remember to run it
- `:VaultEmbedToggle` -- manual toggle off/on
- `BufReadPost` -- renders on first load only (150ms deferred)
- `BufEnter` -- re-renders only if `embeds_visible[bufnr]` is falsy (i.e., the
  embeds were cleared or never rendered)

**UX problems this causes:**

1. **Stale content.** A user edits `NoteA.md` in one buffer, then switches to
   `NoteB.md` which embeds `![[NoteA]]`. The embed still shows the old content.
   The user must manually run `:VaultEmbedRender` to see the update.

2. **External edits invisible.** Files changed by Obsidian, git operations, or
   sync tools (Syncthing, iCloud) are not reflected in embeds until the user
   closes and re-opens the buffer.

3. **Same-file embeds during editing.** Same-file embeds (`![[#Heading]]`,
   `![[^blockid]]`) use live buffer lines, so they are accurate at render time.
   But edits to the buffer after the initial render do not trigger a re-render,
   so even same-file embeds drift out of sync.

4. **No awareness of which embeds are affected.** When any vault file changes,
   there is no mechanism to determine which open buffers have embeds pointing at
   that file and selectively refresh only those buffers.

The vault already has the infrastructure to detect file changes in real time:
`engine.lua` runs a `vim.uv.new_fs_event()` watcher on the vault root, and
`vault_index.lua` provides a subscriber system (`subscribe()` /
`_notify_update()`) that fires whenever the index is updated. The embed module
simply does not hook into any of these signals.

## Current Architecture

### embed.lua

The embed module (`lua/andrew/vault/embed.lua`) is self-contained:

- **Namespace:** `VaultEmbed` -- all extmarks and virtual text live here
- **State tracking:** `embeds_visible[bufnr]` tracks whether embeds are
  currently rendered in each buffer (boolean or `"pending"`)
- **Image placements:** `image_placements[bufnr]` tracks snacks.nvim image
  placement objects for cleanup
- **Rendering:** `render_embeds(opts)` is the single entry point. It:
  1. Validates the buffer is a vault path
  2. Clears all existing extmarks and image placements
  3. Scans every line for `![[...]]` patterns
  4. For image embeds: creates snacks.nvim placements
  5. For note embeds: recursively resolves content via `resolve_embed_lines()`
     and creates virtual text extmarks
  6. Sets `embeds_visible[bufnr] = true`

Key detail: `render_embeds()` always does a **full re-render** -- it clears
everything and rebuilds from scratch. There is no mechanism for partial or
targeted updates.

### vault_index.lua subscriber system

The vault index (`lua/andrew/vault/vault_index.lua`) already has a
publish-subscribe system:

```lua
--- Subscribe to index updates. Returns an unsubscribe function.
function M.VaultIndex:subscribe(fn)
  self._subscribers[#self._subscribers + 1] = fn
  return function()
    for i, sub in ipairs(self._subscribers) do
      if sub == fn then
        table.remove(self._subscribers, i)
        return
      end
    end
  end
end

--- Notify all subscribers.
function M.VaultIndex:_notify_update()
  self._generation = self._generation + 1
  for _, fn in ipairs(self._subscribers) do
    pcall(fn, self._generation)
  end
end
```

`_notify_update()` is called at the end of:
- `build_sync()` -- full synchronous build
- `build_async()` -- after coroutine completes
- `update_file(abs_path)` -- single-file update (from fs watcher or
  `BufWritePost`)
- `remove_file(abs_path)` -- file deletion
- `update_files_batch(abs_paths)` -- batch update

The subscriber callback receives the new generation number.

### engine.lua filesystem watcher

The filesystem watcher in `engine.lua` (lines 917-994) uses
`vim.uv.new_fs_event()` with `{ recursive = true }` on the vault root. When a
`.md` file changes:

1. It debounces for `config.index.watch_debounce_ms` (default 500ms)
2. Calls `vault_index:update_file(abs_path)` for targeted updates (or
   `build_async()` if no specific filename is available)
3. Calls `engine.invalidate_caches({ scope = "all" })` for backward compat

The watcher callback receives the changed filename (relative to the vault root)
and event flags. On Linux, `recursive = true` may not work reliably with
inotify, so the watcher is already designed to handle `filename = nil`.

### Data flow gap

```
  External edit / BufWritePost
          |
    fs_event / invalidate_caches
          |
    vault_index:update_file()
          |
    vault_index:_notify_update()     <-- subscribers notified
          |
          X                          <-- embed.lua is NOT subscribed
          |
    (embeds remain stale)
```

## Proposed Solution

### Overview

Subscribe `embed.lua` to vault index update notifications. When a file changes,
determine which open buffers have embeds referencing that file, and selectively
re-render only those buffers. Additionally, handle same-file edits via
`TextChanged`/`InsertLeave` autocmds with debouncing.

### Architecture after implementation

```
  External edit / BufWritePost / TextChanged
          |
    fs_event / autocmd
          |
    vault_index:update_file(changed_path)
          |
    vault_index:_notify_update(generation, { changed_paths })
          |                                          |
    [other subscribers]               embed.lua subscriber
                                             |
                                   _on_index_update(changed_paths)
                                             |
                                   match changed_paths against
                                   _embed_deps[bufnr] registry
                                             |
                              for each affected bufnr:
                                   debounced render_embeds({ silent = true })
```

### Key design decisions

**1. Full re-render vs. surgical extmark update**

Decision: **Full re-render per affected buffer.**

Rationale: The current `render_embeds()` function is designed as a full
clear-and-rebuild operation. Attempting to surgically update individual extmarks
would require:
- Tracking which extmark corresponds to which embed target
- Handling extmark position shifts when lines are added/removed above
- Managing image placement lifecycle for individual embeds
- Handling nested embeds where a single source change can cascade

The cost of a full re-render is minimal for a single buffer (typically < 5ms
for a buffer with a dozen embeds). The optimization of limiting re-renders to
only affected buffers provides the meaningful performance win.

**2. Dependency tracking**

Decision: **Build a dependency map (`_embed_deps`) during `render_embeds()`.**

Each time a buffer is rendered, record which source files its embeds reference.
Store as `_embed_deps[bufnr] = { [abs_path] = true, ... }`. When a file
changes, iterate the map to find affected buffers. This avoids scanning all
open buffers on every change.

**3. Debouncing strategy**

Decision: **Per-buffer debounce timer with a configurable interval.**

Multiple rapid changes (e.g., typing in a source file, or a git operation
touching many files) should coalesce into a single re-render per affected
buffer. Use a separate timer per bufnr to avoid one buffer's debounce blocking
another's.

Default debounce: 300ms (balances responsiveness with CPU cost).

**4. Image embeds vs. text embeds**

Decision: **Treat identically -- full re-render handles both.**

Image embeds require clearing and recreating snacks.nvim placements. Since the
full re-render already handles this correctly (via `clear_image_placements()`
and re-creation), there is no need for special handling. Image files rarely
change during editing sessions, and when they do (e.g., re-exporting a
diagram), the fs watcher will catch it.

**5. Same-file embed updates**

Decision: **Use `TextChanged` and `InsertLeave` autocmds with a longer
debounce (500ms).**

Same-file embeds (`![[#Heading]]`, `![[^blockid]]`) use live buffer lines, so
they are accurate at render time but become stale as the user edits. A
`TextChanged` autocmd with debouncing allows these to stay reasonably fresh
without excessive re-renders during active typing.

**6. Notification to vault_index subscriber: passing changed paths**

Decision: **Extend `_notify_update()` to pass the changed file path(s) as an
optional second argument.** This allows the embed subscriber to determine
affected buffers without re-scanning.

Currently `_notify_update()` only passes the generation number. The change is
backward-compatible: existing subscribers that accept only one argument will
still work via `pcall()`.

## Implementation Steps

### Step 1: Add embed sync configuration to config.lua

Add a new `embed.sync` subsection to `config.lua`:

```lua
M.embed = {
  max_lines = 20,
  max_depth = 5,
  -- Live sync settings
  sync = {
    enabled = true,           -- Enable live embed sync
    debounce_ms = 300,        -- Debounce for cross-file changes
    self_debounce_ms = 500,   -- Debounce for same-file (TextChanged) updates
  },
}
```

### Step 2: Extend vault_index `_notify_update()` to pass changed paths

In `vault_index.lua`, modify `_notify_update()` to accept and forward context:

```lua
--- Notify all subscribers.
---@param context? { changed_paths?: string[], deleted_paths?: string[] }
function M.VaultIndex:_notify_update(context)
  self._generation = self._generation + 1
  for _, fn in ipairs(self._subscribers) do
    pcall(fn, self._generation, context)
  end
end
```

Update all call sites to pass context where available:

- `update_file(abs_path)`: pass `{ changed_paths = { abs_path } }` or
  `{ deleted_paths = { abs_path } }` depending on whether the file was
  deleted
- `remove_file(abs_path)`: pass `{ deleted_paths = { abs_path } }`
- `update_files_batch(abs_paths)`: pass `{ changed_paths = changed_abs_paths,
  deleted_paths = deleted_abs_paths }`
- `build_sync()`, `build_async()`: pass `nil` (full rebuild -- all embeds
  should re-render)

### Step 3: Add dependency tracking to embed.lua

Add module-level state for tracking which files each buffer's embeds depend on:

```lua
-- Track which source files each buffer's embeds reference.
-- _embed_deps[bufnr] = { [abs_path] = true, ... }
local _embed_deps = {}
```

Modify `render_embeds()` to populate the dependency map during rendering. Add a
local table at the start of the function, populate it as embeds are resolved,
then store it after the render loop:

```lua
function M.render_embeds(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local bufpath = vim.api.nvim_buf_get_name(bufnr)

  if not engine.is_vault_path(bufpath) then
    return
  end

  -- Track dependencies for this render pass
  local deps = {}

  -- ... (existing clear + render logic) ...

  -- Inside the note embed branch, after resolving a path:
  --   if path then
  --     deps[path] = true   -- <-- ADD THIS
  --     ...
  --   end

  -- Inside the image embed branch, after resolving:
  --   if src then
  --     deps[src] = true    -- <-- ADD THIS
  --     ...
  --   end

  -- After the render loop completes:
  _embed_deps[bufnr] = deps
  embeds_visible[bufnr] = true

  -- ... (existing stats notification) ...
end
```

Also update `clear_embeds()` and the `BufDelete`/`BufWipeout` autocmd to clean
up `_embed_deps`:

```lua
function M.clear_embeds()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  clear_image_placements(bufnr)
  _embed_deps[bufnr] = nil
  embeds_visible[bufnr] = false
end
```

### Step 4: Add the vault index subscriber in embed.lua setup()

In the `setup()` function, subscribe to vault index updates and trigger
re-renders for affected buffers:

```lua
-- Per-buffer debounce timers for live sync
local _sync_timers = {}  -- bufnr -> uv_timer_t

--- Schedule a debounced re-render for a specific buffer.
---@param bufnr number
---@param delay_ms number
local function schedule_rerender(bufnr, delay_ms)
  -- Cancel any pending timer for this buffer
  if _sync_timers[bufnr] then
    _sync_timers[bufnr]:stop()
    _sync_timers[bufnr]:close()
    _sync_timers[bufnr] = nil
  end

  local timer = vim.uv.new_timer()
  if not timer then return end

  _sync_timers[bufnr] = timer
  timer:start(delay_ms, 0, vim.schedule_wrap(function()
    -- Clean up timer
    if _sync_timers[bufnr] == timer then
      _sync_timers[bufnr] = nil
    end
    timer:stop()
    timer:close()

    -- Guard: buffer still valid and embeds are visible
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not embeds_visible[bufnr] then return end

    -- Save and restore current buffer if needed
    local cur_buf = vim.api.nvim_get_current_buf()
    if cur_buf == bufnr then
      M.render_embeds({ silent = true })
    else
      -- For non-current buffers, we need to temporarily switch context.
      -- However, render_embeds() uses nvim_get_current_buf() internally.
      -- Instead, store the bufnr and add a render_embeds_for_buf() variant,
      -- or defer until the buffer is entered.
      -- Simplest approach: mark as needing refresh, re-render on BufEnter.
      embeds_visible[bufnr] = false  -- triggers BufEnter re-render
    end
  end))
end

--- Handle vault index update notification.
---@param generation number
---@param context? { changed_paths?: string[], deleted_paths?: string[] }
local function on_index_update(generation, context)
  if not config.embed.sync or not config.embed.sync.enabled then
    return
  end

  local debounce_ms = (config.embed.sync and config.embed.sync.debounce_ms)
    or 300

  if not context then
    -- Full rebuild (no specific paths) -- re-render all visible embed buffers
    for bufnr, visible in pairs(embeds_visible) do
      if visible and vim.api.nvim_buf_is_valid(bufnr) then
        schedule_rerender(bufnr, debounce_ms)
      end
    end
    return
  end

  -- Build a set of all changed/deleted paths
  local affected_paths = {}
  for _, p in ipairs(context.changed_paths or {}) do
    affected_paths[p] = true
  end
  for _, p in ipairs(context.deleted_paths or {}) do
    affected_paths[p] = true
  end

  -- Find buffers whose embeds reference any affected path
  for bufnr, deps in pairs(_embed_deps) do
    if embeds_visible[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
      for dep_path in pairs(deps) do
        if affected_paths[dep_path] then
          schedule_rerender(bufnr, debounce_ms)
          break  -- one match is enough to trigger re-render
        end
      end
    end
  end
end
```

In `setup()`, after the autocmd definitions:

```lua
-- Subscribe to vault index updates for live embed sync
vim.defer_fn(function()
  local vault_index_mod = package.loaded["andrew.vault.vault_index"]
  if not vault_index_mod then return end
  local idx = vault_index_mod.current()
  if idx then
    idx:subscribe(on_index_update)
  end
end, 200)  -- Defer to ensure vault index is initialized
```

### Step 5: Add render_embeds_buf() for non-current buffer rendering

To support re-rendering embeds in a buffer that is not currently active (e.g.,
when a cross-file change is detected while editing a different buffer), add a
buffer-targeted variant:

```lua
--- Render embeds for a specific buffer (may not be the current buffer).
--- Falls back to marking the buffer as needing refresh if it's not current.
---@param bufnr number
---@param opts? { silent?: boolean }
function M.render_embeds_buf(bufnr, opts)
  if vim.api.nvim_get_current_buf() == bufnr then
    M.render_embeds(opts)
    return
  end

  -- For non-current buffers: mark as needing refresh.
  -- The BufEnter autocmd will trigger re-render when the user switches to it.
  if embeds_visible[bufnr] then
    embeds_visible[bufnr] = false
  end
end
```

Update `schedule_rerender()` to use this function instead of the manual
current-buffer check.

### Step 6: Add TextChanged/InsertLeave autocmds for same-file embeds

In `setup()`, add autocmds for same-file embed updates. These handle the case
where the user is editing a buffer that contains embeds referencing its own
headings or block IDs:

```lua
-- Debounced re-render on text changes (for same-file embeds).
-- Only fires if the buffer has visible embeds that reference itself.
vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
  group = augroup,
  pattern = "*.md",
  callback = function(ev)
    if not config.embed.sync or not config.embed.sync.enabled then return end
    if not embeds_visible[ev.buf] then return end

    local bufpath = vim.api.nvim_buf_get_name(ev.buf)
    if not engine.is_vault_path(bufpath) then return end

    -- Only re-render if the buffer has self-referencing embeds
    local deps = _embed_deps[ev.buf]
    if deps and deps[bufpath] then
      local delay = (config.embed.sync and config.embed.sync.self_debounce_ms)
        or 500
      schedule_rerender(ev.buf, delay)
    end
  end,
})
```

### Step 7: Pass changed paths through vault_index notify calls

Update `vault_index.lua` call sites. In `update_file()`:

```lua
function M.VaultIndex:update_file(abs_path)
  -- ... (existing logic) ...

  self:_rebuild_name_index()
  self:_recompute_inlinks_incremental(old_outlinks_map, changed_rel_paths, deleted_rel_paths)
  self:_schedule_persist()

  -- Pass context to subscribers
  local context = {}
  if #changed_rel_paths > 0 then
    context.changed_paths = { abs_path }
  end
  if #deleted_rel_paths > 0 then
    context.deleted_paths = { abs_path }
  end
  self:_notify_update(context)
end
```

In `remove_file()`:

```lua
function M.VaultIndex:remove_file(abs_path)
  -- ... (existing logic) ...
  self:_notify_update({ deleted_paths = { abs_path } })
end
```

In `update_files_batch()`:

```lua
function M.VaultIndex:update_files_batch(abs_paths)
  -- ... (existing logic tracking changed/deleted) ...

  if #changed_rel_paths > 0 or #deleted_rel_paths > 0 then
    -- ... (existing rebuild logic) ...

    -- Build abs path lists for context
    local changed_abs = {}
    for _, rel in ipairs(changed_rel_paths) do
      changed_abs[#changed_abs + 1] = self.vault_path .. "/" .. rel
    end
    local deleted_abs = {}
    for _, rel in ipairs(deleted_rel_paths) do
      deleted_abs[#deleted_abs + 1] = self.vault_path .. "/" .. rel
    end
    self:_notify_update({ changed_paths = changed_abs, deleted_paths = deleted_abs })
  end
end
```

In `build_sync()` and `build_async()`, pass `nil` to indicate a full rebuild
(all embeds should be re-rendered):

```lua
self:_notify_update(nil)  -- full rebuild -- no specific paths
```

### Step 8: Clean up timers on buffer delete and VimLeavePre

Extend the existing `BufDelete`/`BufWipeout` autocmd to also clean up sync
timers:

```lua
vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = augroup,
  callback = function(ev)
    clear_image_placements(ev.buf)
    embeds_visible[ev.buf] = nil
    _embed_deps[ev.buf] = nil

    -- Clean up sync timer
    if _sync_timers[ev.buf] then
      pcall(function()
        _sync_timers[ev.buf]:stop()
        _sync_timers[ev.buf]:close()
      end)
      _sync_timers[ev.buf] = nil
    end
  end,
})
```

Add a `VimLeavePre` autocmd to clean up all timers:

```lua
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = augroup,
  callback = function()
    for bufnr, timer in pairs(_sync_timers) do
      pcall(function()
        timer:stop()
        timer:close()
      end)
      _sync_timers[bufnr] = nil
    end
  end,
})
```

### Step 9: Add a :VaultEmbedSync command for manual re-subscription

If the vault index is not yet initialized when `embed.setup()` runs (race
condition on startup), the subscription will be missed. Add a command and
a fallback mechanism:

```lua
-- Track subscription state
local _subscribed = false

local function ensure_subscription()
  if _subscribed then return true end
  local vault_index_mod = package.loaded["andrew.vault.vault_index"]
  if not vault_index_mod then return false end
  local idx = vault_index_mod.current()
  if not idx then return false end
  idx:subscribe(on_index_update)
  _subscribed = true
  return true
end

vim.api.nvim_create_user_command("VaultEmbedSync", function()
  if ensure_subscription() then
    vim.notify("Vault: embed sync active", vim.log.levels.INFO)
  else
    vim.notify("Vault: index not available, sync not started", vim.log.levels.WARN)
  end
end, { desc = "Vault: ensure embed live sync is active" })
```

Also call `ensure_subscription()` in the `BufEnter` autocmd as a lazy fallback:

```lua
vim.api.nvim_create_autocmd("BufEnter", {
  group = augroup,
  pattern = "*.md",
  callback = function(ev)
    local bufpath = vim.api.nvim_buf_get_name(ev.buf)
    if not engine.is_vault_path(bufpath) then return end

    -- Lazy subscription attempt
    ensure_subscription()

    if not embeds_visible[ev.buf] then
      -- ... (existing deferred render logic) ...
    end
  end,
})
```

## Edge Cases

### Circular embeds

Circular embeds are already handled by `resolve_embed_lines()` via the
`visited_set` cycle detection mechanism. This is not affected by live sync --
the re-render will simply re-detect and display the cycle indicator.

No additional handling is needed for live sync. If file A embeds B and B embeds
A, a change to A will trigger a re-render of B (which will show the cycle
indicator for the A embed), and vice versa.

### Rapid edits (typing in source file)

The debounce mechanism ensures that rapid edits coalesce into a single
re-render. The two debounce intervals are:

- **Cross-file changes (300ms):** The vault index's fs watcher already debounces
  at 500ms (`config.index.watch_debounce_ms`). The embed sync adds its own
  300ms debounce on top, but in practice the fs watcher debounce dominates.
  Total latency from save to embed update: ~500-800ms.

- **Same-file TextChanged (500ms):** Fires only after typing pauses. Does NOT
  fire during active insert mode typing (only on `InsertLeave` and when
  Neovim detects text changes in normal mode).

If the user is typing extremely fast in a source file and has it open in a
split alongside a buffer embedding it, the total latency chain is:

```
keystroke -> BufWritePost (if autosave) -> fs_event (500ms debounce) ->
  vault_index:update_file() -> _notify_update() -> embed subscriber ->
  schedule_rerender (300ms debounce) -> render_embeds()
```

This is intentionally not real-time. Real-time updates during typing would be
distracting and wasteful.

### Deleted files

When a source file is deleted:

1. The fs watcher fires, vault index calls `update_file()` which detects
   `stat = nil` and removes the entry.
2. `_notify_update({ deleted_paths = { abs_path } })` fires.
3. The embed subscriber finds buffers with `_embed_deps[bufnr][abs_path]`.
4. `render_embeds()` is triggered. During rendering, `resolve_embed()` returns
   `nil` for the deleted note, and the embed is rendered as
   `"![[NoteName]] (not found)"` -- the existing behavior.

No special handling needed.

### Renamed files

Renames appear as a delete + create pair from the filesystem watcher's
perspective. The sequence:

1. Delete event for old path -> embed shows "(not found)"
2. Create event for new path -> if the embed uses the note name (not a full
   path), `resolve_embed()` will find the renamed file by its new name. If
   the wikilink uses the old name, it will remain "(not found)" until the user
   updates the link text.

This is correct behavior -- the embed module cannot know that a rename occurred
(the link text references the old name). The vault index subscriber handles
both events naturally.

### Buffer not currently visible

When a buffer has embeds but is not the current buffer (e.g., in a hidden
split, or in a different tab), `render_embeds()` cannot be called directly
because it uses `nvim_get_current_buf()`. The solution from Step 5 handles
this: set `embeds_visible[bufnr] = false`, which triggers a re-render on the
next `BufEnter`.

This means non-visible buffers will have a brief delay (until focus) before
showing updated embeds. This is an acceptable trade-off. Users typically only
care about the buffer they are looking at.

### Vault index not yet ready

On startup, the vault index may not be ready when `embed.setup()` runs. The
deferred subscription in Step 9 handles this -- `ensure_subscription()` is
called on each `BufEnter`, so the subscription will be established as soon as
the index is available.

If the index is still building when an embed is rendered, `render_embeds()`
works fine because it resolves links through `wikilinks.resolve_link()` which
has its own fallback paths. The dependency map will be populated correctly
regardless of index readiness.

### Multiple embeds of the same source in one buffer

A buffer might embed the same note multiple times (e.g., different sections):
`![[Note#Heading1]]` and `![[Note#Heading2]]`. Both resolve to the same source
path. The dependency map stores `deps[abs_path] = true`, so a change to the
source triggers a single re-render that updates both embeds. No issue here.

### Embeds of non-existent files

If a buffer contains `![[NonExistent]]`, the embed renders as "(not found)" and
`resolve_embed()` returns `nil`. The dependency map will not contain an entry
for this embed (no path to track). If the file is later created, the fs watcher
will trigger a vault index update, which fires `_notify_update()` with the new
file's path. Since no buffer has this path in `_embed_deps`, no re-render is
triggered -- which means the "(not found)" embed will not auto-update.

To handle this edge case, the `on_index_update()` handler should also check
whether any buffer has unresolved embeds that match a newly created file. One
approach: when `render_embeds()` encounters a "(not found)" embed, record the
unresolved name in a separate set `_unresolved_embeds[bufnr] = { name_lower =
true, ... }`. On index update with new files, check if any unresolved name now
resolves. This is a minor enhancement that can be deferred to a follow-up.

### Image file changes

Image files (`.png`, `.jpg`, etc.) are not `.md` files, so the vault index's fs
watcher (which filters for `*.md` only) will not detect changes. The
`engine.lua` fs watcher also filters for `.md`:

```lua
if filename and not filename:match("%.md$") then
  return
end
```

To support live image updates, the fs watcher filter would need to be
broadened, or a separate watcher for image directories could be added. This is
out of scope for this improvement -- image changes are rare and can be handled
by manual `:VaultEmbedRender`.

## Files Modified

### Modified files:

1. **`lua/andrew/vault/config.lua`**
   - Add `sync` subsection to `M.embed` with `enabled`, `debounce_ms`,
     `self_debounce_ms`

2. **`lua/andrew/vault/vault_index.lua`**
   - Modify `_notify_update()` signature to accept optional context table
   - Update `update_file()` to pass `{ changed_paths, deleted_paths }` context
   - Update `remove_file()` to pass `{ deleted_paths }` context
   - Update `update_files_batch()` to pass path context
   - Update `build_sync()` and `build_async()` to pass `nil` context

3. **`lua/andrew/vault/embed.lua`**
   - Add `_embed_deps` module state for dependency tracking
   - Add `_sync_timers` module state for per-buffer debounce timers
   - Add `_subscribed` flag and `ensure_subscription()` function
   - Modify `render_embeds()` to populate `_embed_deps[bufnr]` during
     rendering
   - Modify `clear_embeds()` to clean up `_embed_deps[bufnr]`
   - Add `on_index_update()` subscriber callback
   - Add `schedule_rerender()` helper
   - Add `render_embeds_buf()` for non-current-buffer targeting
   - Add `TextChanged`/`InsertLeave` autocmds for same-file sync
   - Add `:VaultEmbedSync` command
   - Extend `BufDelete`/`BufWipeout` cleanup to include deps and timers
   - Add `VimLeavePre` cleanup for timers
   - Extend `BufEnter` autocmd to call `ensure_subscription()`
   - Extend `debug_info()` to show sync state (subscription active, dep
     count, timer count)

### No new files needed.

## Testing Plan

### Manual verification steps

**1. Cross-file embed sync (basic case):**
- Open `NoteA.md` which contains `![[NoteB]]`
- Verify embeds render on load
- Open `NoteB.md` in a split
- Edit `NoteB.md` and save (`:w`)
- Switch focus back to `NoteA.md`
- Expected: embed content reflects the saved changes within ~1 second

**2. Cross-file sync without split (fs watcher path):**
- Open `NoteA.md` which contains `![[NoteB]]`
- In a terminal, edit `NoteB.md` with another editor and save
- Wait 1 second
- Expected: if `NoteA.md` is current buffer, embed auto-refreshes. If not,
  embed refreshes on next `BufEnter`.

**3. Same-file heading embed sync:**
- Open a file with `![[#SomeHeading]]` and content under that heading
- Verify the embed renders the heading's content
- Edit the content under `## SomeHeading`
- Leave insert mode
- Expected: embed virtual text updates within 500ms

**4. Deleted file embed:**
- Open `NoteA.md` with `![[NoteB]]`
- Delete `NoteB.md` from disk
- Wait 1 second
- Expected: embed changes to show "(not found)"

**5. Debounce verification (rapid saves):**
- Open `NoteA.md` with embeds
- In another split, rapidly save `NoteB.md` multiple times (`:w` repeated)
- Expected: `NoteA.md` embeds re-render at most once per debounce window,
  not once per save

**6. Multiple buffers with shared dependency:**
- Open `NoteA.md` (embeds `![[Shared]]`) and `NoteC.md` (also embeds
  `![[Shared]]`)
- Edit `Shared.md` and save
- Expected: both `NoteA.md` and `NoteC.md` re-render their embeds

**7. Toggle off disables sync:**
- Open a vault file with embeds
- Run `:VaultEmbedClear`
- Edit the source file and save
- Expected: no re-render (embeds are cleared, not visible)
- Run `:VaultEmbedRender` -- embeds appear with fresh content

**8. Sync disabled via config:**
- Set `config.embed.sync.enabled = false`
- Verify no auto-refresh occurs on source file changes

**9. Image embed (no auto-refresh):**
- Open a file with `![[photo.png]]`
- Replace `photo.png` on disk
- Expected: image does NOT auto-refresh (image changes are out of scope)
- Run `:VaultEmbedRender` -- image refreshes

**10. Startup race condition:**
- Ensure vault index is slow to initialize (e.g., large vault)
- Open a vault file immediately
- Expected: embeds render from initial `BufReadPost`. When index becomes
  ready, subscription is established via `BufEnter` lazy check.

### Debug verification

Run `:VaultEmbedDebug` and verify:
- "Sync subscription: active" (or "inactive" if index not ready)
- "Embed dependencies (buf N): K files" showing the count of tracked deps
- "Active sync timers: N" showing any pending debounce timers

### Performance verification

- Open a buffer with 20+ embeds referencing 10+ different files
- Trigger a source file change
- Verify the re-render completes without visible UI stutter
- Profile with `:lua vim.uv.hrtime()` around `render_embeds()` -- should be
  < 10ms for typical buffer sizes
