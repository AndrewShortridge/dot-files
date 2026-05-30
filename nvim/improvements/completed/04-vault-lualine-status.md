# Vault Status in Lualine

## Problem

The vault system has rich metadata available in real time -- backlink counts,
broken link counts, orphan counts, index readiness, total file counts, active
vault name -- but none of this is visible at a glance. Today, accessing this
data requires running explicit commands:

| Data | Current Access | Limitation |
|------|---------------|------------|
| Backlinks for current note | `<leader>vfb` opens fzf picker | Transient; no persistent count visible |
| Broken links in buffer | `<leader>vcb` runs `linkcheck.check_buffer()` | Manual; no ambient awareness |
| Orphan notes | `<leader>vco` runs `linkcheck.check_orphans()` | Async ripgrep; seconds to complete |
| Index status | `:VaultIndexStatus` | Command-only; no visual indicator during builds |
| Active vault name | Only shown on `switch_vault()` notification | Forgotten after dismissal |
| Total note count | `:VaultIndexStatus` | Not visible during editing |

**UX consequences:**

1. The user has no ambient awareness of how well-connected the current note is.
   A note with 0 backlinks might benefit from being linked from other notes, but
   the user would never know without manually running the backlinks picker.
2. Broken links accumulate silently. The user must remember to periodically run
   link checks.
3. During index builds (cold start, git checkout), there is no persistent
   indicator that vault features are degraded. The progress notification from
   `build_async()` disappears after completion, but the user may open a vault
   file mid-build and not realize the index is still building.
4. When working with multiple vaults, the active vault is not displayed anywhere
   persistent after the initial switch notification.

A lualine status component solves all of these by providing a compact, always-
visible summary in the status line. This is a lighter-weight alternative to a
persistent sidebar panel and requires no new window management, layout changes,
or split logic.

## Current Architecture

### Lualine Configuration

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/plugins/lualine.lua`

The lualine config uses a custom OneDark-inspired theme with global statusline
(`laststatus = 3`). Sections are:

| Section | Contents |
|---------|----------|
| `lualine_a` | Mode |
| `lualine_b` | Branch, diff |
| `lualine_c` | Filename (relative path) |
| `lualine_x` | Lazy updates, workspace diagnostics, buffer diagnostics, encoding, fileformat, filetype |
| `lualine_y` | Word count (markdown only), progress |
| `lualine_z` | Location (line:col) |

The word count component (lines 238-246) is already a markdown-conditional
function component and serves as a pattern for the vault status component:

```lua
{
  function()
    local wc = vim.fn.wordcount().words
    return wc .. "w"
  end,
  cond = function()
    return vim.bo.filetype == "markdown"
  end,
  color = { fg = colors.cyan },
},
```

The workspace diagnostics component (lines 170-195) demonstrates multi-colored
inline highlight groups using `%#HighlightGroup#` statusline syntax:

```lua
{
  function()
    local ws = _G.fortran_workspace_diagnostics or { errors = 0, warnings = 0 }
    -- ...
    vim.api.nvim_set_hl(0, "LualineWsFolder", { fg = "#c678dd" })
    vim.api.nvim_set_hl(0, "LualineWsError", { fg = "#e06c75" })
    local result = "%#LualineWsFolder#\u{f0256}"
    if ws.errors > 0 then
      result = result .. "%#LualineWsError#  " .. ws.errors
    end
    return result .. "%*"
  end,
  cond = function() ... end,
},
```

This pattern (inline highlight groups) is directly applicable to the vault
status component for coloring different metrics differently.

### Vault Index API

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/vault_index.lua`

The vault index singleton exposes all the data needed:

| Method / Field | Returns | Use |
|---|---|---|
| `M.current()` | `VaultIndex\|nil` | Get singleton (nil if not initialized) |
| `idx:is_ready()` | `boolean` | Index queryable? |
| `idx._building` | `boolean` | Async build in progress? |
| `idx:file_count()` | `number` | Total indexed `.md` files |
| `idx:get_inlinks(rel_path)` | `table[]` | Inbound links to a file |
| `idx:get_entry_by_abs(abs_path)` | `VaultIndexEntry\|nil` | Entry for current buffer |
| `idx._generation` | `number` | Monotonically increasing counter, bumped on every update |
| `idx:subscribe(fn)` | `fun()` (unsubscribe) | Callback on index updates |
| `idx.files` | `table<string, VaultIndexEntry>` | All indexed entries |

The subscriber system (`subscribe` / `_notify_update`) fires on every index
mutation: `build_sync()`, `build_async()` completion, `update_file()`,
`update_files_batch()`, and `remove_file()`. This is ideal for cache
invalidation in the lualine component.

### Backlinks Module

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/backlinks.lua`

`current_file_index_info()` (lines 11-22) demonstrates the pattern for getting
the current buffer's index entry:

```lua
local function current_file_index_info()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then return nil, nil end
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return nil, nil end
  local entry = idx:get_entry_by_abs(bufname)
  if not entry then return nil, nil end
  return entry.rel_path, idx
end
```

Backlink count for the current note is then:
```lua
local inlinks = idx:get_inlinks(rel_path)
local backlink_count = #inlinks
```

### Link Diagnostics Module

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/linkdiag.lua`

`linkdiag.validate()` (lines 139-291) computes broken link diagnostics for the
current buffer and stores them via `vim.diagnostic.set(M.ns, bufnr, diags)`.
The broken link count can be retrieved without re-running validation:

```lua
local diags = vim.diagnostic.get(bufnr, { namespace = linkdiag.ns })
local broken_count = #diags
```

This is O(1) since diagnostics are already computed and cached by the
diagnostic system. The `linkdiag.ns` namespace (`vim.api.nvim_create_namespace
("vault_linkdiag")`) isolates vault diagnostics from LSP diagnostics.

### Link Check Module (Orphans)

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/linkcheck.lua`

`check_orphans()` (lines 421-491) computes orphan notes, but it does so via an
async ripgrep call. This is too expensive for a statusline component. However,
orphan count can be computed directly from the vault index:

```lua
local function count_orphans(idx)
  local count = 0
  for rel_path, entry in pairs(idx.files) do
    local inlinks = idx:get_inlinks(rel_path)
    if #inlinks == 0 then
      count = count + 1
    end
  end
  return count
end
```

This iterates all files once -- O(n) where n is the file count. For a 500-file
vault this is <1ms. However, it should be cached and recomputed only on index
generation changes.

### Engine Module (Vault Name)

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/engine.lua`

The active vault name is resolved by reverse-looking up `engine.vault_path` in
`engine.vaults` (lines 551-556):

```lua
vault = function(_vars)
  for name, path in pairs(M.vaults) do
    if path == M.vault_path then return name end
  end
  return vim.fn.fnamemodify(M.vault_path, ":t")
end,
```

This is a simple table scan (2 entries currently: "Main" and "Personal").

## Solution

Create a new module `lua/andrew/vault/lualine.lua` that exposes a lualine-
compatible component function. This module:

1. **Caches** computed vault metrics (backlinks, broken links, orphans, etc.)
   keyed by index generation and buffer number.
2. **Subscribes** to vault index updates to invalidate the cache.
3. **Returns** a formatted string with inline highlight groups for multi-colored
   display.
4. **Provides a `cond` function** that returns `true` only when the current
   buffer is a vault markdown file.

The component is inserted into `lualine_x` (right of center, before
diagnostics) in the lualine config.

### Display Format

The component shows a compact string with icons and counts:

```
 Main  3  0  12/523
```

Where:
- ` Main` -- vault icon + active vault name (always shown when in vault)
- ` 3` -- backlink count for current note (blue)
- ` 0` -- broken link count in current buffer (red if >0, green if 0)
- `12/523` -- orphan count / total file count (yellow if orphans >0, dimmed otherwise)

When the index is building, the component shows a spinner:

```
 Main  building...
```

When the index is not ready (cold start, no persisted data), the component
shows a minimal indicator:

```
 Main  ...
```

### Highlight Groups

Define custom highlight groups using the existing color palette from lualine:

| Group | Color | Usage |
|-------|-------|-------|
| `LualineVaultIcon` | `colors.purple` (`#c678dd`) | Vault icon |
| `LualineVaultName` | `colors.fg` (`#abb2bf`) | Vault name |
| `LualineVaultBacklinks` | `colors.blue` (`#61afef`) | Backlink count |
| `LualineVaultBrokenNone` | `colors.green` (`#98c379`) | Zero broken links |
| `LualineVaultBrokenSome` | `colors.red` (`#e06c75`) | Non-zero broken links |
| `LualineVaultOrphans` | `colors.yellow` (`#e5c07b`) | Orphan/total count |
| `LualineVaultBuilding` | `colors.yellow` (`#e5c07b`) | Building indicator |
| `LualineVaultDimmed` | `colors.lightgray` (`#5c6370`) | Dimmed secondary info |

### Design Decisions

1. **Separate module, not inline.** The lualine component function could be
   defined inline in the plugin spec, but a separate module allows testing,
   caching, and subscription management without cluttering the lualine config.

2. **Cache by generation + bufnr.** The vault index `_generation` field
   increments on every update. Caching vault-wide metrics (orphan count, total
   files) by generation and per-buffer metrics (backlinks, broken links) by
   `bufnr + generation` avoids redundant computation. Lualine calls component
   functions on every statusline redraw (~10-50 times per second during
   scrolling), so the function must return in <1ms.

3. **No ripgrep for orphans.** The existing `check_orphans()` uses ripgrep
   which is too slow for a statusline. Computing orphans from the index's
   `_inlinks` table is O(n) but fast (<1ms for 500 files) and only runs when
   the generation changes.

4. **Diagnostics for broken link count.** Reading `vim.diagnostic.get()` is
   the cheapest path since `linkdiag.validate()` already runs on `BufEnter` and
   `VaultCacheInvalidate` events. No re-validation needed.

5. **Spinner for building state.** A simple rotating character (`|`, `/`, `-`,
   `\`) driven by a `vim.uv.new_timer()` provides visual feedback during long
   builds without any polling overhead.

6. **Conditional visibility.** The component is completely hidden when the
   current buffer is not a vault markdown file, using lualine's `cond` callback.

7. **No new config section.** The component is self-contained and always active
   when in a vault buffer. If users want to hide it, they can remove it from
   their lualine sections. A future `config.lualine.enabled` toggle could be
   added if needed.

8. **Click actions (future).** Lualine supports `on_click` callbacks. These
   could open the backlinks picker, link check, or orphan finder. This is noted
   as a future enhancement and not implemented in the initial version to keep
   scope manageable.

## Implementation

### New File: `lua/andrew/vault/lualine.lua`

This is the core of the feature. It exposes `M.component()`, `M.cond()`, and
`M.init()`.

```lua
-- lualine.lua — Vault status component for lualine
-- Displays: vault name, backlink count, broken link count, orphan/total count

local M = {}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local _cache = {
  -- Vault-wide (keyed by generation)
  generation = -1,
  orphan_count = 0,
  file_count = 0,
  vault_name = "",

  -- Per-buffer (keyed by bufnr + generation)
  bufnr = -1,
  buf_generation = -1,
  backlink_count = 0,
  broken_count = 0,
}

-- Spinner state for building indicator
local _spinner = {
  frames = { "|", "/", "-", "\\" },
  index = 1,
  timer = nil,
  active = false,
}

-- Track subscription to avoid double-subscribing
local _subscribed = false

-- ---------------------------------------------------------------------------
-- Highlight groups
-- ---------------------------------------------------------------------------

local _hl_defined = false

local function ensure_highlights()
  if _hl_defined then return end
  _hl_defined = true

  vim.api.nvim_set_hl(0, "LualineVaultIcon", { fg = "#c678dd" })
  vim.api.nvim_set_hl(0, "LualineVaultName", { fg = "#abb2bf" })
  vim.api.nvim_set_hl(0, "LualineVaultBacklinks", { fg = "#61afef" })
  vim.api.nvim_set_hl(0, "LualineVaultBrokenNone", { fg = "#98c379" })
  vim.api.nvim_set_hl(0, "LualineVaultBrokenSome", { fg = "#e06c75" })
  vim.api.nvim_set_hl(0, "LualineVaultOrphans", { fg = "#e5c07b" })
  vim.api.nvim_set_hl(0, "LualineVaultBuilding", { fg = "#e5c07b" })
  vim.api.nvim_set_hl(0, "LualineVaultDimmed", { fg = "#5c6370" })
end

-- ---------------------------------------------------------------------------
-- Cache computation
-- ---------------------------------------------------------------------------

--- Get the active vault name from engine.vaults reverse lookup.
---@return string
local function get_vault_name()
  local engine = require("andrew.vault.engine")
  for name, path in pairs(engine.vaults) do
    if path == engine.vault_path then return name end
  end
  return vim.fn.fnamemodify(engine.vault_path or "", ":t")
end

--- Count orphan notes (notes with zero inbound links).
--- O(n) over all indexed files but only runs on generation change.
---@param idx VaultIndex
---@return number
local function count_orphans(idx)
  local count = 0
  for rel_path, _ in pairs(idx.files) do
    local inlinks = idx._inlinks[rel_path]
    if not inlinks or #inlinks == 0 then
      count = count + 1
    end
  end
  return count
end

--- Refresh vault-wide cached metrics if the index generation has changed.
local function refresh_vault_cache()
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    _cache.generation = -1
    _cache.orphan_count = 0
    _cache.file_count = 0
    _cache.vault_name = get_vault_name()
    return
  end

  if idx._generation == _cache.generation then return end

  _cache.generation = idx._generation
  _cache.file_count = idx:file_count()
  _cache.orphan_count = count_orphans(idx)
  _cache.vault_name = get_vault_name()
end

--- Refresh per-buffer cached metrics if the buffer or generation has changed.
local function refresh_buffer_cache()
  local bufnr = vim.api.nvim_get_current_buf()
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()

  if not idx or not idx:is_ready() then
    _cache.bufnr = bufnr
    _cache.buf_generation = -1
    _cache.backlink_count = 0
    _cache.broken_count = 0
    return
  end

  -- Skip if buffer and generation haven't changed
  if bufnr == _cache.bufnr and idx._generation == _cache.buf_generation then
    return
  end

  _cache.bufnr = bufnr
  _cache.buf_generation = idx._generation

  -- Backlink count
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local entry = idx:get_entry_by_abs(bufname)
  if entry then
    local inlinks = idx:get_inlinks(entry.rel_path)
    _cache.backlink_count = #inlinks
  else
    _cache.backlink_count = 0
  end

  -- Broken link count from diagnostics namespace
  local linkdiag = package.loaded["andrew.vault.linkdiag"]
  if linkdiag and linkdiag.ns then
    local diags = vim.diagnostic.get(bufnr, { namespace = linkdiag.ns })
    _cache.broken_count = #diags
  else
    _cache.broken_count = 0
  end
end

-- ---------------------------------------------------------------------------
-- Spinner management
-- ---------------------------------------------------------------------------

local function start_spinner()
  if _spinner.active then return end
  _spinner.active = true
  _spinner.timer = vim.uv.new_timer()
  if _spinner.timer then
    _spinner.timer:start(0, 120, vim.schedule_wrap(function()
      _spinner.index = (_spinner.index % #_spinner.frames) + 1
      -- Trigger lualine refresh (lightweight)
      pcall(require("lualine").refresh)
    end))
  end
end

local function stop_spinner()
  if not _spinner.active then return end
  _spinner.active = false
  if _spinner.timer then
    _spinner.timer:stop()
    _spinner.timer:close()
    _spinner.timer = nil
  end
end

-- ---------------------------------------------------------------------------
-- Subscription
-- ---------------------------------------------------------------------------

--- Subscribe to vault index updates for cache invalidation.
--- Called once on first component render.
local function ensure_subscribed()
  if _subscribed then return end
  _subscribed = true

  -- Subscribe to index updates
  -- Use a deferred check because the index may not exist at load time
  vim.api.nvim_create_autocmd("User", {
    pattern = "VaultCacheInvalidate",
    callback = function()
      -- Force cache refresh on next render
      _cache.generation = -1
      _cache.buf_generation = -1
    end,
  })

  -- Also subscribe to BufEnter for per-buffer updates
  vim.api.nvim_create_autocmd("BufEnter", {
    callback = function()
      _cache.buf_generation = -1
    end,
  })

  -- Subscribe to diagnostic changes for broken link count updates
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    callback = function()
      _cache.buf_generation = -1
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Condition function for lualine: only show when current buffer is a vault
--- markdown file.
---@return boolean
function M.cond()
  if vim.bo.filetype ~= "markdown" then return false end
  local engine = require("andrew.vault.engine")
  if not engine.vault_path then return false end
  local bufname = vim.api.nvim_buf_get_name(0)
  return bufname ~= "" and engine.is_vault_path(bufname)
end

--- Main component function for lualine.
--- Returns a formatted string with inline highlight groups.
---@return string
function M.component()
  ensure_highlights()
  ensure_subscribed()

  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()

  local vault_name = get_vault_name()
  local parts = {}

  -- Vault icon and name (always shown)
  parts[#parts + 1] = "%#LualineVaultIcon#\u{f0219}"
  parts[#parts + 1] = "%#LualineVaultName# " .. vault_name

  if not idx or not idx:is_ready() then
    -- Index not ready at all
    parts[#parts + 1] = "%#LualineVaultBuilding# \u{f141a} ..."
    return table.concat(parts) .. "%*"
  end

  if idx._building then
    -- Index is building (incremental or cold)
    start_spinner()
    local frame = _spinner.frames[_spinner.index]
    parts[#parts + 1] = "%#LualineVaultBuilding# " .. frame .. " building..."
    return table.concat(parts) .. "%*"
  else
    stop_spinner()
  end

  -- Refresh caches
  refresh_vault_cache()
  refresh_buffer_cache()

  -- Backlink count
  parts[#parts + 1] = "%#LualineVaultBacklinks# \u{f0c1} " .. _cache.backlink_count

  -- Broken link count
  if _cache.broken_count > 0 then
    parts[#parts + 1] = "%#LualineVaultBrokenSome# \u{f127} " .. _cache.broken_count
  else
    parts[#parts + 1] = "%#LualineVaultBrokenNone# \u{f127} 0"
  end

  -- Orphan count / total file count
  if _cache.orphan_count > 0 then
    parts[#parts + 1] = "%#LualineVaultOrphans# \u{f29c} "
      .. _cache.orphan_count .. "/" .. _cache.file_count
  else
    parts[#parts + 1] = "%#LualineVaultDimmed# \u{f29c} "
      .. _cache.orphan_count .. "/" .. _cache.file_count
  end

  return table.concat(parts) .. "%*"
end

return M
```

### Modified File: `lua/andrew/plugins/lualine.lua`

Insert the vault status component into `lualine_x`, before the diagnostics
component. The vault component uses a `cond` function so it only appears when
editing vault markdown files.

**Location:** After the lazy plugin updates component (line 165) and before the
workspace diagnostics component (line 170).

Add a new entry in the `lualine_x` section:

```lua
lualine_x = {
  -- Lazy plugin updates indicator
  {
    lazy_status.updates,
    cond = lazy_status.has_updates,
    color = { fg = colors.yellow },
  },

  -- NEW: Vault status component
  {
    function()
      return require("andrew.vault.lualine").component()
    end,
    cond = function()
      return require("andrew.vault.lualine").cond()
    end,
    -- No color here -- the component uses inline highlight groups
  },

  -- Workspace diagnostics (from <leader>lw Fortran lint) [existing]
  -- ...
```

The `require()` calls are inside the function bodies so the vault module is
lazily loaded -- it is not required at lualine setup time, only when a vault
markdown buffer is active.

### No Changes to Vault Modules

The vault lualine module reads data from existing APIs:

- `vault_index.current()` / `idx:is_ready()` / `idx._building` / `idx._generation`
- `idx:get_entry_by_abs()` / `idx:get_inlinks()`
- `idx:file_count()` / `idx.files`
- `vim.diagnostic.get(bufnr, { namespace = linkdiag.ns })`
- `engine.vault_path` / `engine.vaults` / `engine.is_vault_path()`

No modifications to `vault_index.lua`, `backlinks.lua`, `linkcheck.lua`,
`linkdiag.lua`, `engine.lua`, or `config.lua` are required. The lualine module
is purely a read-only consumer.

## Step-by-Step Implementation Plan

### Step 1: Create `lua/andrew/vault/lualine.lua`

Create the new module with the full implementation shown above. Key structure:

1. Cache state table with generation tracking
2. Highlight group definitions
3. `count_orphans(idx)` helper
4. `refresh_vault_cache()` and `refresh_buffer_cache()` functions
5. Spinner with `vim.uv.new_timer()` at 120ms interval
6. Subscription to `VaultCacheInvalidate`, `BufEnter`, and `DiagnosticChanged`
7. `M.cond()` function
8. `M.component()` function

### Step 2: Add Component to Lualine Config

Edit `/home/andrew-cmmg/.config/nvim/lua/andrew/plugins/lualine.lua`:

Insert a new component entry in the `lualine_x` section between the lazy
updates indicator and the workspace diagnostics component.

### Step 3: Test Basic Rendering

1. Open a vault markdown file
2. Verify the component appears in the statusline
3. Verify it hides when switching to a non-vault buffer
4. Verify it hides when switching to a non-markdown buffer

### Step 4: Test Index States

1. Delete `.vault-index/index.json` and restart
2. Verify "building..." with spinner appears during cold start
3. Verify counts appear after build completes
4. Edit a file and verify backlink count updates after save

### Step 5: Test Click Actions (Future)

Not implemented in initial version. Placeholder for:
- Click on backlink count -> open backlinks picker
- Click on broken count -> run link check
- Click on orphan count -> run orphan finder

## Files to Create

| File | Purpose |
|------|---------|
| `lua/andrew/vault/lualine.lua` | Vault status lualine component module |

## Files to Modify

| File | Changes |
|------|---------|
| `lua/andrew/plugins/lualine.lua` | Add vault status component to `lualine_x` section |

## Edge Cases

1. **Vault index not initialized.** `vault_index.current()` returns `nil`
   before the first vault file is opened. The component shows only the vault
   name and a "..." indicator. Once the index initializes (triggered by
   `BufReadPost` in `engine.lua` lines 1021-1041), the component will show
   full metrics on next statusline redraw.

2. **Index building (cold start).** `idx:is_ready()` returns `false` and
   `idx._building` is `true`. The component shows "building..." with a spinner.
   When `build_async()` completes, `_notify_update()` fires, the
   `VaultCacheInvalidate` autocmd invalidates the cache, and the next redraw
   shows the full metrics.

3. **Index building (incremental).** After a persisted index is loaded,
   `is_ready()` is `true` but `_building` may also be `true` during the
   incremental diff. In this case, the component shows full metrics (from the
   persisted data) but with a building indicator appended. This was a design
   choice: showing stale-but-useful data is better than hiding everything.
   **Revision:** To keep the display simple and consistent, the building
   indicator replaces the metrics during any build. The persisted data is
   typically very close to current anyway.

4. **Multiple vaults.** `engine.vaults` has two entries ("Main", "Personal").
   On `switch_vault()`, `engine.vault_path` changes, and `invalidate_all_caches`
   is called. The `VaultCacheInvalidate` autocmd invalidates the lualine cache,
   so the next redraw picks up the new vault name and resets all counts. During
   the transition, `vault_index.current()` may briefly return the old index
   (until the new one is created and built), causing a momentary mismatch. The
   generation check ensures the cache is fully refreshed once the new index is
   ready.

5. **Non-vault markdown file.** `engine.is_vault_path(bufname)` returns `false`
   for markdown files outside the vault (e.g., a README.md in a git repo). The
   `cond` function hides the component entirely.

6. **Empty buffer (no file name).** `vim.api.nvim_buf_get_name(0)` returns `""`.
   `cond` returns `false`. Component hidden.

7. **Buffer with no index entry.** A brand-new unsaved vault file will not have
   an entry in `idx.files`. `idx:get_entry_by_abs()` returns `nil`. The
   backlink count shows 0 (correct -- a new file has no backlinks). The broken
   link count comes from diagnostics, which runs independently.

8. **linkdiag module not loaded.** If the user has not opened a vault file yet,
   `package.loaded["andrew.vault.linkdiag"]` is `nil`. The broken link count
   defaults to 0. Once linkdiag loads (on first `FileType markdown` event in a
   vault buffer), the diagnostic namespace becomes available.

9. **Statusline redraw frequency.** Lualine redraws on every cursor movement,
   mode change, and timer event. The component function must be fast (<1ms).
   The generation-based cache ensures that `count_orphans()` (the most expensive
   operation at O(n)) runs at most once per index update, not per redraw. All
   other operations are O(1) table lookups.

10. **Spinner timer cleanup.** The spinner timer is stopped when the build
    completes. If Neovim exits while the spinner is active, the timer is garbage
    collected. No explicit cleanup on `VimLeavePre` is needed because
    `vim.uv.new_timer()` handles this.

11. **Highlight group persistence across colorscheme changes.** If the user
    changes colorscheme, the custom highlight groups are overwritten. The
    `_hl_defined` flag prevents re-definition. To handle colorscheme changes,
    a `ColorScheme` autocmd could reset `_hl_defined = false`. This is a minor
    concern since the vault theme is tightly coupled to OneDark already.

12. **Orphan count includes daily logs and templates.** Every file without
    inbound links counts as an orphan, including daily logs (which may not be
    linked from anywhere). This is intentional -- it matches the behavior of
    `check_orphans()`. A future enhancement could exclude certain directories
    (e.g., `Log/`) from the orphan count, but that is out of scope.

## Performance Considerations

| Operation | Cost | Frequency |
|-----------|------|-----------|
| `vault_index.current()` | O(1) module global | Every redraw |
| `idx:is_ready()` | O(1) field access | Every redraw |
| `idx._building` | O(1) field access | Every redraw |
| `idx._generation` | O(1) field access | Every redraw |
| `get_vault_name()` | O(k) where k = number of vaults (2) | On generation change |
| `idx:get_entry_by_abs()` | O(1) string sub + table lookup | On generation/buffer change |
| `idx:get_inlinks()` | O(1) table lookup | On generation/buffer change |
| `count_orphans()` | O(n) where n = file count | On generation change only |
| `vim.diagnostic.get()` | O(d) where d = diagnostic count | On generation/buffer change |
| `ensure_highlights()` | O(1) after first call (flag check) | Every redraw |
| String concatenation | O(p) where p = number of parts (~8) | Every redraw |

For a 500-file vault: `count_orphans()` runs in <1ms. All other operations are
<0.1ms. The total component function time is <0.5ms per redraw, well within
lualine's performance budget.

The spinner timer fires at 120ms intervals but only calls `lualine.refresh()`
which is a lightweight statusline redraw. This is active only during builds
(typically 1-10 seconds).

## Testing

### Manual Test Cases

1. **Component visibility:**
   - Open a vault `.md` file -- component should appear
   - Open a non-vault `.md` file -- component should disappear
   - Open a non-markdown file -- component should disappear
   - Return to the vault file -- component should reappear

2. **Vault name display:**
   - With "Main" vault active, verify "Main" appears
   - Run `:VaultSwitch` to "Personal", verify name changes

3. **Backlink count:**
   - Open a well-linked note, verify count > 0
   - Open a new/isolated note, verify count = 0
   - Create a link to the note from another file, save, verify count increases

4. **Broken link count:**
   - Open a file with no broken links, verify 0 (green)
   - Add a broken wikilink `[[Nonexistent Note]]`, save, wait for linkdiag to
     run, verify count = 1 (red)
   - Fix the link, save, verify count returns to 0

5. **Orphan count / total:**
   - After index build, verify total matches `:VaultIndexStatus` count
   - Create a new unlinked note, save, verify orphan count increases
   - Add a link to that note from another file, save, verify orphan count
     decreases

6. **Building state:**
   - Delete `.vault-index/index.json`, restart Neovim, open a vault file
   - Verify spinner + "building..." appears
   - Wait for build to complete, verify full metrics appear

7. **Cold start (index not loaded yet):**
   - On fresh Neovim launch, quickly open a vault file before the deferred
     `prebuild_name_cache_async()` runs
   - Verify "..." indicator appears briefly, then transitions to building or
     full metrics

### Verification Checklist

- [ ] Component appears only for vault markdown files
- [ ] Component hidden for non-vault and non-markdown buffers
- [ ] Vault name matches active vault
- [ ] Backlink count matches `<leader>vfb` picker count
- [ ] Broken link count matches `<leader>vcb` result
- [ ] Orphan count is consistent with `<leader>vco`
- [ ] Total file count matches `:VaultIndexStatus`
- [ ] Spinner appears during index builds
- [ ] Spinner stops after build completes
- [ ] Cache invalidates on file save (index update)
- [ ] Cache invalidates on buffer switch
- [ ] Cache invalidates on diagnostic change
- [ ] No visible lag or flicker during normal editing
- [ ] Colors match the OneDark palette
- [ ] Component does not error when vault index is nil
- [ ] Component does not error when linkdiag is not loaded
