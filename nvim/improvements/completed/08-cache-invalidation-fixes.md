# 08 - Cache Invalidation Fixes

## Problem Statement

The vault system maintains several in-memory caches that map note names to file
paths, track headings, store completion items, and hold deadline data.  These
caches are invalidated almost exclusively via `BufWritePost` autocmds, which
means any filesystem change that does **not** originate from an active Neovim
buffer goes unnoticed until the next full rebuild.  Three specific gaps:

1. **External edits are invisible.**  Running `git pull`, syncing via Obsidian
   mobile, or editing a file in another editor never fires `BufWritePost`.  The
   wikilink cache, name cache, completion caches, and link diagnostics all
   continue to serve stale data until the user happens to save an unrelated
   `.md` file inside Neovim.

2. **Vault switch leaves stale caches.**  `engine.switch_vault()` (line 14 of
   `engine.lua`) changes `M.vault_path` and emits a notification, but does not
   touch any of the downstream caches.  The wikilink cache in `wikilinks.lua`
   does compare `cache_vault` against `engine.vault_path` on next access (line
   49), but other caches -- `linkdiag._heading_cache`, `completion_base`
   invalidators, `calendar._deadline_cache`, `frecency._db` -- are not
   explicitly cleared.  This causes transient stale data if the user runs a
   command before the TTL-based caches expire.

3. **Heading cache trusts mtime alone.**  `linkdiag.get_headings()` (line 29)
   caches by `filepath` keyed on `stat.mtime.sec`.  If a file is replaced
   atomically (e.g. `git checkout`, `mv tmp file.md`) the replacement may carry
   an identical mtime-second but a different inode.  The cache incorrectly
   serves the old headings.

---

## Current Behavior (detailed)

### Cache 1: Wikilink resolution cache (`wikilinks.lua`)

| Item | Detail |
|------|--------|
| File | `lua/andrew/vault/wikilinks.lua` |
| State variables | `cache` (table, line 7), `cache_valid` (bool, line 8), `cache_vault` (string, line 9) |
| Build function | `build_cache()` (line 11) -- walks vault via `vim.fs.find`, indexes by lowercase basename and frontmatter aliases |
| Guard function | `ensure_cache()` (line 48) -- rebuilds if `cache_valid == false` or `cache_vault ~= engine.vault_path` |
| Invalidation | `M.invalidate_cache()` (line 44) -- sets `cache_valid = false` |
| Triggers | `BufWritePost *.md` autocmd (line 417, only if `engine.is_vault_path(bufpath)`) |
| External callers | `rename.lua` line 257 calls `invalidate_cache()` after a rename operation |
| Gap | No trigger for external filesystem changes.  No explicit clear on vault switch (the `cache_vault` comparison is a lazy workaround, but between switch and first `resolve_link` call, `cache` still holds the old vault's data). |

### Cache 2: Shared name cache (`engine.lua`)

| Item | Detail |
|------|--------|
| File | `lua/andrew/vault/engine.lua` |
| State variables | `_name_cache` (table, line 417), `_name_cache_vault` (string, line 418), `_name_cache_ts` (number, line 419) |
| TTL | `NAME_CACHE_TTL = 10` seconds (line 420) |
| Build function | `M.get_name_cache()` (line 424) -- runs `fd`/`find`, indexes by basename and relative path stem |
| Invalidation | `M.invalidate_name_cache()` (line 463) -- sets `_name_cache_ts = 0` |
| Triggers | `BufWritePost *.md` in `linkdiag.lua` (line 501), `linkcheck.lua` (line 352); `BufDelete *.md` in `linkdiag.lua` (line 513), `linkcheck.lua` (line 348) |
| Gap | Same as wikilinks cache -- no external-edit awareness.  Has TTL-based expiry (10s), which partially mitigates the issue but still leaves a window where stale data is served.  `switch_vault()` does not call `invalidate_name_cache()`. |

### Cache 3: Heading cache (`linkdiag.lua`)

| Item | Detail |
|------|--------|
| File | `lua/andrew/vault/linkdiag.lua` |
| State variable | `M._heading_cache` (table, line 8) -- keyed by filepath |
| Cache entry | `{ mtime = stat.mtime.sec, slugs = {...}, headings = {...} }` (line 54) |
| Validation | Compares `cached.mtime == stat.mtime.sec` (line 34) |
| Invalidation | Per-file on `BufWritePost` -- deletes `M._heading_cache[saved_path]` (line 504-505) |
| Gap | **mtime-second granularity** -- two different file versions can share the same mtime second (atomic replace, fast git operations).  **No inode tracking** -- a replaced file with the same mtime but different inode will serve stale headings.  **No full cache clear on vault switch** -- entries from the previous vault remain keyed by absolute path (harmless but wastes memory). |

### Cache 4: Completion sources (`completion_base.lua`)

| Item | Detail |
|------|--------|
| File | `lua/andrew/vault/completion_base.lua` |
| State variables | Per-source: `cached_items`, `cached_vault`, `build_generation` (lines 51-54) |
| Invalidation | Shared `BufWritePost *.md` autocmd (line 8) calls every registered invalidator |
| Gap | No external-edit trigger.  No vault-switch trigger (the `cached_vault == engine.vault_path` check on line 100/111 is a lazy guard but does not proactively rebuild). |

### Cache 5: Calendar deadline cache (`calendar.lua`)

| Item | Detail |
|------|--------|
| File | `lua/andrew/vault/calendar.lua` |
| State variable | `_deadline_cache` (table, line 86) with `vault_path`, `built_at`, `deadlines` |
| TTL | `DEADLINE_CACHE_TTL = 60` seconds (line 87) |
| Invalidation | `M.invalidate_deadline_cache()` (line 187) -- sets `_deadline_cache = nil` |
| Triggers | None automatic (caller must invoke explicitly) |
| Gap | Never automatically invalidated on file save or external edit. |

### Cache 6: Frecency database (`frecency.lua`)

| Item | Detail |
|------|--------|
| File | `lua/andrew/vault/frecency.lua` |
| State variables | `_db` (table, line 20), `_db_vault` (string, line 21) |
| Validation | Compares `_db_vault == engine.vault_path` (line 27) |
| Gap | Lazy vault comparison works but never explicitly cleared on switch. |

---

## Fix 1: FocusGained autocmd for cache refresh

### Rationale

When the user alt-tabs back to Neovim after running `git pull` or syncing
Obsidian, `FocusGained` fires.  This is the most reliable single event for
detecting external changes without polling.

### Implementation

Add to `engine.lua` as a new function and autocmd, called from `init.lua`.

#### `lua/andrew/vault/engine.lua` -- add after line 464 (after `invalidate_name_cache`)

```lua
--- Invalidate ALL vault caches.
--- Call this on events that signal external filesystem changes (FocusGained, vault switch).
function M.invalidate_all_caches()
  -- 1. Engine's own name cache
  M.invalidate_name_cache()

  -- 2. Wikilink resolution cache
  local ok_wl, wikilinks = pcall(require, "andrew.vault.wikilinks")
  if ok_wl and wikilinks.invalidate_cache then
    wikilinks.invalidate_cache()
  end

  -- 3. Linkdiag heading cache
  local ok_ld, linkdiag = pcall(require, "andrew.vault.linkdiag")
  if ok_ld then
    linkdiag._heading_cache = {}
  end

  -- 4. Calendar deadline cache
  local ok_cal, calendar = pcall(require, "andrew.vault.calendar")
  if ok_cal and calendar.invalidate_deadline_cache then
    calendar.invalidate_deadline_cache()
  end

  -- 5. Completion sources (fire all registered invalidators)
  local ok_cb, comp_base = pcall(require, "andrew.vault.completion_base")
  if ok_cb and comp_base.invalidate_all then
    comp_base.invalidate_all()
  end
end
```

#### `lua/andrew/vault/completion_base.lua` -- add after line 15 (after the autocmd block)

```lua
--- Invalidate all registered completion source caches.
--- Called by engine.invalidate_all_caches().
function M.invalidate_all()
  for _, invalidate in ipairs(all_invalidators) do
    invalidate()
  end
end
```

Insert this between line 16 and line 18 (before the `find_md_cmd` function).

#### `lua/andrew/vault/init.lua` -- add after line 207 (after VaultSwitch command, before `return M`)

```lua
-- FocusGained: invalidate caches to pick up external file changes
-- (git pull, Obsidian mobile sync, edits in other editors)
local focus_group = vim.api.nvim_create_augroup("VaultFocusRefresh", { clear = true })

local focus_debounce_timer = nil
vim.api.nvim_create_autocmd("FocusGained", {
  group = focus_group,
  callback = function()
    -- Debounce: FocusGained can fire in rapid succession (window manager quirks)
    if focus_debounce_timer then
      focus_debounce_timer:stop()
    end
    focus_debounce_timer = vim.defer_fn(function()
      focus_debounce_timer = nil
      engine.invalidate_all_caches()
      -- Re-validate link diagnostics in the current buffer if it's a vault markdown file
      local bufnr = vim.api.nvim_get_current_buf()
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if bufname:match("%.md$") and engine.is_vault_path(bufname) then
        local ok_ld, linkdiag = pcall(require, "andrew.vault.linkdiag")
        if ok_ld and linkdiag.enabled then
          linkdiag.validate(bufnr)
        end
      end
    end, 200)
  end,
})
```

### Insertion points

| File | After line | What to add |
|------|-----------|-------------|
| `lua/andrew/vault/engine.lua` | 465 (after `end` of `invalidate_name_cache`) | `invalidate_all_caches()` function |
| `lua/andrew/vault/completion_base.lua` | 16 (after the autocmd `end`) | `M.invalidate_all()` function |
| `lua/andrew/vault/init.lua` | 207 (after `VaultSwitch` keybinding) | FocusGained autocmd block |

---

## Fix 2: `vim.uv` file watcher for the vault root

### Rationale

`FocusGained` only fires when Neovim regains focus.  If a background sync
process modifies files while Neovim is in the foreground (e.g., an inotify-
triggered sync daemon, or `git pull` from a tmux split), the caches remain
stale.  A `vim.uv.new_fs_event()` watcher on the vault root provides real-time
notification.

### Caveats

- `fs_event` on Linux uses inotify, which is **not recursive** by default.
  `vim.uv.fs_event` with the `recursive = true` flag works on macOS (FSEvents)
  but on Linux it only watches the immediate directory.  To cover subdirectories
  on Linux, we watch the vault root and debounce aggressively -- any change in
  the top-level directory (e.g., `.git` lock files during pull) triggers a
  deferred cache invalidation.
- For full recursive coverage on Linux, an alternative is to use a single watcher
  combined with checking file mtimes on the debounced callback.  Since the caches
  already do full vault scans on rebuild, the watcher's job is simply to *trigger*
  the invalidation, not to identify which files changed.

### Implementation

#### `lua/andrew/vault/engine.lua` -- add after `invalidate_all_caches()`

```lua
-- ---------------------------------------------------------------------------
-- File system watcher for external change detection
-- ---------------------------------------------------------------------------
local _fs_watcher = nil
local _fs_watcher_path = nil
local _fs_debounce_timer = nil
local FS_DEBOUNCE_MS = 500

--- Start watching the current vault root for filesystem changes.
--- Automatically stops any previous watcher.
function M.start_fs_watcher()
  M.stop_fs_watcher()

  local vault = M.vault_path
  if not vault or vim.fn.isdirectory(vault) == 0 then
    return
  end

  local watcher = vim.uv.new_fs_event()
  if not watcher then
    return
  end

  local ok, err = watcher:start(vault, { recursive = true }, function(err_msg, filename, events)
    if err_msg then
      return
    end
    -- Only care about .md file changes (ignore .git internals, .obsidian, etc.)
    if filename and not filename:match("%.md$") then
      return
    end
    -- Debounce: batch rapid changes into a single invalidation
    if _fs_debounce_timer then
      _fs_debounce_timer:stop()
    end
    _fs_debounce_timer = vim.uv.new_timer()
    if _fs_debounce_timer then
      _fs_debounce_timer:start(FS_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        _fs_debounce_timer:stop()
        _fs_debounce_timer:close()
        _fs_debounce_timer = nil
        M.invalidate_all_caches()
      end))
    end
  end)

  if not ok then
    watcher:close()
    return
  end

  _fs_watcher = watcher
  _fs_watcher_path = vault
end

--- Stop the current filesystem watcher, if any.
function M.stop_fs_watcher()
  if _fs_watcher then
    pcall(function()
      _fs_watcher:stop()
      _fs_watcher:close()
    end)
    _fs_watcher = nil
    _fs_watcher_path = nil
  end
  if _fs_debounce_timer then
    pcall(function()
      _fs_debounce_timer:stop()
      _fs_debounce_timer:close()
    end)
    _fs_debounce_timer = nil
  end
end
```

#### `lua/andrew/vault/init.lua` -- add after the FocusGained block

```lua
-- Start filesystem watcher for real-time external change detection
engine.start_fs_watcher()
```

### Insertion points

| File | After line | What to add |
|------|-----------|-------------|
| `lua/andrew/vault/engine.lua` | After `invalidate_all_caches()` | `start_fs_watcher()` / `stop_fs_watcher()` functions |
| `lua/andrew/vault/init.lua` | After the FocusGained autocmd block | `engine.start_fs_watcher()` call |

### Linux note on recursive watching

On Linux, `vim.uv.new_fs_event` with `recursive = true` may not be supported
(depends on kernel version and libuv build).  If the watcher only fires for
top-level changes, two fallback strategies:

1. **Accept top-level only**: Most git operations touch files in the vault root
   (`.git/` lock files, index).  The watcher will fire on `git pull` even if it
   does not see individual subdirectory changes.  Since the `.md` filter would
   miss `.git` files, **remove the `.md` filter** and instead rely purely on
   debouncing:

   ```lua
   -- Remove the filename filter for Linux compatibility:
   -- if filename and not filename:match("%.md$") then return end
   ```

2. **Supplement with FocusGained**: The watcher catches foreground changes; the
   FocusGained autocmd (Fix 1) catches everything else when the user returns.

---

## Fix 3: Clear all caches on vault switch

### Rationale

`engine.switch_vault()` updates `M.vault_path` but leaves all caches populated
with data from the previous vault.  While some caches compare `vault_path`
lazily, this leaves a window where stale data is served.  An explicit
invalidation ensures consistency.

### Implementation

#### `lua/andrew/vault/engine.lua` -- modify `switch_vault()` (line 14)

Replace the current `switch_vault` function (lines 14-22):

```lua
--- Switch to a different vault by name.
---@param name string vault name from M.vaults
function M.switch_vault(name)
  local path = M.vaults[name]
  if not path then
    vim.notify("Vault: unknown vault '" .. name .. "'", vim.log.levels.ERROR)
    return
  end
  local old_path = M.vault_path
  M.vault_path = path

  -- Invalidate all downstream caches
  M.invalidate_all_caches()

  -- Restart the filesystem watcher for the new vault root
  if M.start_fs_watcher then
    M.start_fs_watcher()
  end

  vim.notify("Vault: switched to " .. name .. " (" .. path .. ")", vim.log.levels.INFO)
end
```

**Note on ordering**: `invalidate_all_caches()` is defined later in the file
than `switch_vault()`.  Since Lua resolves `M.invalidate_all_caches` at call
time (not definition time), this works as long as both functions are on the
same module table `M`.  However, if you prefer to avoid any potential issues
with module loading order, move `switch_vault` to after the cache functions, or
use a forward reference pattern.  In practice, since `switch_vault` is only
called interactively (never at module load time), the forward reference is safe.

### Insertion point

| File | Lines | What to change |
|------|-------|----------------|
| `lua/andrew/vault/engine.lua` | 14-22 (replace entire `switch_vault` function) | Add `invalidate_all_caches()` and `start_fs_watcher()` calls |

---

## Fix 4: Improve heading cache with inode tracking

### Rationale

The heading cache in `linkdiag.lua` uses `stat.mtime.sec` as its validity key.
This fails when a file is atomically replaced (e.g., `git checkout`, `rsync`,
or `mv tmp.md note.md`): the new file may have the same mtime-second but
different content.  Adding the inode number (`stat.ino`) as a secondary key
eliminates this class of false cache hits.

### Implementation

#### `lua/andrew/vault/linkdiag.lua` -- modify `get_headings()` (lines 29-60)

Replace the function:

```lua
--- Extract headings from a file, returning both a slug set and ordered raw heading list.
--- Results are cached by filepath, mtime, and inode for correctness.
---@param filepath string absolute path to a markdown file
---@return table<string, boolean> slug_set, string[] raw_headings
function M.get_headings(filepath)
  local stat = vim.uv.fs_stat(filepath)
  if not stat then return {}, {} end

  local cached = M._heading_cache[filepath]
  if cached
    and cached.mtime == stat.mtime.sec
    and cached.ino == stat.ino
    and cached.size == stat.size
  then
    return cached.slugs, cached.headings
  end

  local slugs = {}
  local headings = {}
  local f = io.open(filepath, "r")
  if not f then return {}, {} end

  for line in f:lines() do
    local heading_text = line:match("^#+%s+(.*)")
    if heading_text then
      -- Trim trailing whitespace
      heading_text = heading_text:gsub("%s+$", "")
      headings[#headings + 1] = heading_text
      slugs[link_utils.heading_to_slug(heading_text)] = true
    end
  end
  f:close()

  M._heading_cache[filepath] = {
    mtime = stat.mtime.sec,
    ino = stat.ino,
    size = stat.size,
    slugs = slugs,
    headings = headings,
  }
  return slugs, headings
end
```

Changes from the original:

1. **Line 34 equivalent**: Cache validity now checks three fields: `mtime`,
   `ino` (inode number), and `size` (file size in bytes).  The inode catches
   atomic file replacements.  The size provides an additional cheap guard
   against content changes within the same second.
2. **Line 54-58 equivalent**: Cache entry now stores `ino` and `size` alongside
   `mtime`.

Also update the comment on line 7-8 to reflect the new structure:

```lua
-- Heading cache: filepath -> { mtime, ino, size, slugs = {slug=true}, headings = {"raw heading", ...} }
M._heading_cache = {}
```

### Insertion point

| File | Lines | What to change |
|------|-------|----------------|
| `lua/andrew/vault/linkdiag.lua` | 7-8 | Update cache structure comment |
| `lua/andrew/vault/linkdiag.lua` | 29-60 (replace entire `get_headings` function) | Add `ino` and `size` checks |

---

## Full Implementation: Consolidated Diff

Below is a summary of every change, in order, with exact line references.

### File: `lua/andrew/vault/engine.lua`

**Change A** -- Replace `switch_vault` (lines 14-22):

```lua
function M.switch_vault(name)
  local path = M.vaults[name]
  if not path then
    vim.notify("Vault: unknown vault '" .. name .. "'", vim.log.levels.ERROR)
    return
  end
  M.vault_path = path

  -- Invalidate all downstream caches immediately
  M.invalidate_all_caches()

  -- Restart filesystem watcher for the new vault root
  if M.start_fs_watcher then
    M.start_fs_watcher()
  end

  vim.notify("Vault: switched to " .. name .. " (" .. path .. ")", vim.log.levels.INFO)
end
```

**Change B** -- Add after `invalidate_name_cache()` (after line 465):

```lua
--- Invalidate ALL vault caches system-wide.
--- Call on FocusGained, fs_event, vault switch, or any event signaling
--- external filesystem changes.
function M.invalidate_all_caches()
  -- 1. Engine's own name cache
  M.invalidate_name_cache()

  -- 2. Wikilink resolution cache
  local ok_wl, wikilinks = pcall(require, "andrew.vault.wikilinks")
  if ok_wl and wikilinks.invalidate_cache then
    wikilinks.invalidate_cache()
  end

  -- 3. Linkdiag heading cache
  local ok_ld, linkdiag = pcall(require, "andrew.vault.linkdiag")
  if ok_ld then
    linkdiag._heading_cache = {}
  end

  -- 4. Calendar deadline cache
  local ok_cal, calendar = pcall(require, "andrew.vault.calendar")
  if ok_cal and calendar.invalidate_deadline_cache then
    calendar.invalidate_deadline_cache()
  end

  -- 5. Completion sources (fire all registered invalidators)
  local ok_cb, comp_base = pcall(require, "andrew.vault.completion_base")
  if ok_cb and comp_base.invalidate_all then
    comp_base.invalidate_all()
  end
end

-- ---------------------------------------------------------------------------
-- Filesystem watcher for external change detection
-- ---------------------------------------------------------------------------
local _fs_watcher = nil
local _fs_watcher_path = nil
local _fs_debounce_timer = nil
local FS_DEBOUNCE_MS = 500

--- Start watching the current vault root for filesystem changes.
--- Stops any previous watcher first.  On change to any .md file, debounces
--- and then invalidates all caches.
function M.start_fs_watcher()
  M.stop_fs_watcher()

  local vault = M.vault_path
  if not vault or vim.fn.isdirectory(vault) == 0 then
    return
  end

  local watcher = vim.uv.new_fs_event()
  if not watcher then
    return
  end

  local ok, err = watcher:start(vault, { recursive = true }, function(err_msg, filename, events)
    if err_msg then
      return
    end
    -- Filter: only invalidate for .md file changes.
    -- On Linux where recursive=true may not work, remove this filter
    -- and rely on debouncing alone (see note in docs).
    if filename and not filename:match("%.md$") then
      return
    end
    -- Debounce rapid changes into a single invalidation
    if _fs_debounce_timer then
      _fs_debounce_timer:stop()
    end
    _fs_debounce_timer = vim.uv.new_timer()
    if _fs_debounce_timer then
      _fs_debounce_timer:start(FS_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        if _fs_debounce_timer then
          _fs_debounce_timer:stop()
          _fs_debounce_timer:close()
          _fs_debounce_timer = nil
        end
        M.invalidate_all_caches()
      end))
    end
  end)

  if not ok then
    watcher:close()
    return
  end

  _fs_watcher = watcher
  _fs_watcher_path = vault
end

--- Stop the current filesystem watcher.
function M.stop_fs_watcher()
  if _fs_watcher then
    pcall(function()
      _fs_watcher:stop()
      _fs_watcher:close()
    end)
    _fs_watcher = nil
    _fs_watcher_path = nil
  end
  if _fs_debounce_timer then
    pcall(function()
      _fs_debounce_timer:stop()
      _fs_debounce_timer:close()
    end)
    _fs_debounce_timer = nil
  end
end
```

### File: `lua/andrew/vault/completion_base.lua`

**Change C** -- Add after line 16 (after the `BufWritePost` autocmd block):

```lua
--- Invalidate all registered completion source caches.
--- Called by engine.invalidate_all_caches() on FocusGained / fs_event / vault switch.
function M.invalidate_all()
  for _, invalidate in ipairs(all_invalidators) do
    invalidate()
  end
end
```

### File: `lua/andrew/vault/linkdiag.lua`

**Change D** -- Replace comment on lines 7-8:

```lua
-- Heading cache: filepath -> { mtime, ino, size, slugs = {slug=true}, headings = {"raw heading", ...} }
M._heading_cache = {}
```

**Change E** -- Replace `get_headings()` function (lines 29-60):

```lua
function M.get_headings(filepath)
  local stat = vim.uv.fs_stat(filepath)
  if not stat then return {}, {} end

  local cached = M._heading_cache[filepath]
  if cached
    and cached.mtime == stat.mtime.sec
    and cached.ino == stat.ino
    and cached.size == stat.size
  then
    return cached.slugs, cached.headings
  end

  local slugs = {}
  local headings = {}
  local f = io.open(filepath, "r")
  if not f then return {}, {} end

  for line in f:lines() do
    local heading_text = line:match("^#+%s+(.*)")
    if heading_text then
      heading_text = heading_text:gsub("%s+$", "")
      headings[#headings + 1] = heading_text
      slugs[link_utils.heading_to_slug(heading_text)] = true
    end
  end
  f:close()

  M._heading_cache[filepath] = {
    mtime = stat.mtime.sec,
    ino = stat.ino,
    size = stat.size,
    slugs = slugs,
    headings = headings,
  }
  return slugs, headings
end
```

### File: `lua/andrew/vault/init.lua`

**Change F** -- Add after line 211 (after the VaultSwitch keymap, before `return M`):

```lua
-- ---------------------------------------------------------------------------
-- External change detection
-- ---------------------------------------------------------------------------

-- FocusGained: invalidate caches to pick up external file changes
-- (git pull, Obsidian mobile sync, edits in other editors)
local focus_group = vim.api.nvim_create_augroup("VaultFocusRefresh", { clear = true })
local focus_debounce_timer = nil

vim.api.nvim_create_autocmd("FocusGained", {
  group = focus_group,
  callback = function()
    -- Debounce: FocusGained can fire in rapid succession
    if focus_debounce_timer then
      focus_debounce_timer:stop()
    end
    focus_debounce_timer = vim.defer_fn(function()
      focus_debounce_timer = nil
      engine.invalidate_all_caches()
      -- Re-validate link diagnostics in the current buffer
      local bufnr = vim.api.nvim_get_current_buf()
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if bufname:match("%.md$") and engine.is_vault_path(bufname) then
        local ok_ld, linkdiag = pcall(require, "andrew.vault.linkdiag")
        if ok_ld and linkdiag.enabled then
          linkdiag.validate(bufnr)
        end
      end
    end, 200)
  end,
})

-- Filesystem watcher: real-time detection of external changes while Neovim
-- is in the foreground (covers tmux splits, background sync daemons, etc.)
engine.start_fs_watcher()
```

---

## Performance Considerations

### Debouncing strategy

| Event source | Debounce delay | Rationale |
|-------------|---------------|-----------|
| `FocusGained` | 200ms | Window managers may fire multiple events on alt-tab |
| `fs_event` | 500ms | `git pull` can modify dozens of files in rapid succession; wait for the operation to settle |
| `BufWritePost` | None (immediate) | Single file save, user expects instant feedback |

### Partial vs full cache rebuilds

The current implementation uses **lazy invalidation**: caches are marked invalid
immediately, but actual rebuilding is deferred until the next access.  This is
the right approach for several reasons:

1. **FocusGained fires even when no files changed.**  Eagerly rebuilding on
   every alt-tab would waste CPU.  Lazy invalidation costs nothing if no cache
   is queried.

2. **fs_event may fire for non-vault files.**  The `.md` filter in the watcher
   reduces false positives, but debouncing + lazy rebuild is still cheaper than
   eager scanning.

3. **The wikilink cache rebuild (`build_cache`) walks the entire vault.**  At
   ~1000 files this takes ~50ms (acceptable), but at 10k+ files it would become
   noticeable.  Lazy invalidation ensures this cost is paid only when needed.

### Memory management for heading cache

The heading cache (`linkdiag._heading_cache`) grows unboundedly as files are
visited.  The full cache clear on vault switch (Fix 3) and on FocusGained
(Fix 1) provides periodic cleanup.  If memory becomes a concern, consider
adding an LRU eviction policy or a max-entries cap:

```lua
-- Optional: cap heading cache at 500 entries
local MAX_HEADING_CACHE = 500
if vim.tbl_count(M._heading_cache) > MAX_HEADING_CACHE then
  -- Simple strategy: clear the whole cache
  M._heading_cache = {}
end
```

### fs_event resource usage

Each `vim.uv.new_fs_event()` consumes one inotify watch (Linux) or one
FSEvents stream (macOS).  A single watcher on the vault root with
`recursive = true` is efficient.  The default Linux inotify limit
(`/proc/sys/fs/inotify/max_user_watches`) is typically 8192+, so one watcher
is negligible.

---

## Testing

### Test 1: FocusGained invalidation

1. Open a vault note in Neovim: `nvim ~/Documents/Obsidian-Vault/Obsidian-Vault/some-note.md`
2. In another terminal, create a new note:
   ```bash
   echo "# Test Note" > ~/Documents/Obsidian-Vault/Obsidian-Vault/test-focus-note.md
   ```
3. Alt-tab back to Neovim.
4. Type `[[test-focus-note` -- the completion/resolution should find the new file.
5. Verify: `:lua print(require("andrew.vault.wikilinks").resolve_link("test-focus-note"))` should return the new file's path.
6. Clean up:
   ```bash
   rm ~/Documents/Obsidian-Vault/Obsidian-Vault/test-focus-note.md
   ```

### Test 2: Filesystem watcher

1. Open a vault note in Neovim.
2. In a **tmux split** (Neovim stays focused):
   ```bash
   echo "# Watcher Test" > ~/Documents/Obsidian-Vault/Obsidian-Vault/test-watcher-note.md
   ```
3. Wait 1 second (for debounce).
4. In Neovim: `:lua print(require("andrew.vault.wikilinks").resolve_link("test-watcher-note"))` -- should resolve.
5. Clean up the test file.

### Test 3: Vault switch cache clearing

1. Open a note from the Main vault.
2. Run `:VaultSwitch` and select "Personal".
3. Immediately check: `:lua print(vim.inspect(require("andrew.vault.linkdiag")._heading_cache))` -- should be `{}` (empty).
4. `:lua print(require("andrew.vault.wikilinks").resolve_link("some-main-vault-only-note"))` -- should return `nil`.

### Test 4: Heading cache inode tracking

1. Open a vault note that contains wikilinks with heading anchors.
2. In another terminal, atomically replace a linked note:
   ```bash
   cd ~/Documents/Obsidian-Vault/Obsidian-Vault
   cp target-note.md target-note.md.bak
   # Create a version with different headings
   echo -e "# New Heading\n\nContent" > target-note.md.new
   # Atomic replace (preserves mtime if using touch -r)
   touch -r target-note.md target-note.md.new
   mv target-note.md.new target-note.md
   ```
3. In Neovim, run `:VaultLinkDiag` on the file that links to `target-note#Old Heading`.
4. The diagnostic should now report "Broken heading" for the old heading, proving the cache was invalidated despite the same mtime.
5. Restore: `mv target-note.md.bak target-note.md`

### Test 5: Verify debouncing

1. Open Neovim with a vault note.
2. In another terminal, rapidly create/delete files:
   ```bash
   for i in $(seq 1 20); do
     echo "# Note $i" > ~/Documents/Obsidian-Vault/Obsidian-Vault/rapid-test-$i.md
   done
   ```
3. Check that Neovim remains responsive (no UI freeze from 20 synchronous cache rebuilds).
4. After 1 second, verify one of the files resolves:
   ```
   :lua print(require("andrew.vault.wikilinks").resolve_link("rapid-test-15"))
   ```
5. Clean up: `rm ~/Documents/Obsidian-Vault/Obsidian-Vault/rapid-test-*.md`

### Test 6: No regression on BufWritePost

1. Open a vault note, add a wikilink to a non-existent note: `[[new-note-test]]`.
2. Save the file (`:w`).
3. Verify diagnostics show "Broken link" for `[[new-note-test]]`.
4. Create the note: Open `[[new-note-test]]` with `gf`, write content, save.
5. Go back to the original note and save again.
6. Verify the diagnostic clears (link is now valid).

---

## Summary of all caches and their invalidation after these fixes

| Cache | Module | Invalidated by BufWritePost | Invalidated by FocusGained | Invalidated by fs_event | Invalidated by vault switch | Extra validity checks |
|-------|--------|----------------------------|---------------------------|------------------------|-----------------------------|----------------------|
| Wikilink resolution | `wikilinks.lua` | Yes (line 417) | Yes (via `invalidate_all_caches`) | Yes (via `invalidate_all_caches`) | Yes (via `invalidate_all_caches`) | `cache_vault != engine.vault_path` |
| Name cache | `engine.lua` | Yes (linkdiag line 501, linkcheck line 352) | Yes | Yes | Yes | TTL 10s + vault comparison |
| Heading cache | `linkdiag.lua` | Yes (per-file, line 504) | Yes (full clear) | Yes (full clear) | Yes (full clear) | mtime + inode + size |
| Completion sources | `completion_base.lua` | Yes (line 8) | Yes (via `invalidate_all`) | Yes (via `invalidate_all`) | Yes (via `invalidate_all`) | `cached_vault == engine.vault_path` |
| Deadline cache | `calendar.lua` | No (manual only) | Yes | Yes | Yes | TTL 60s + vault comparison |
| Frecency DB | `frecency.lua` | N/A (JSON-backed) | N/A (lazy vault check) | N/A | N/A (lazy vault check) | `_db_vault == engine.vault_path` |
