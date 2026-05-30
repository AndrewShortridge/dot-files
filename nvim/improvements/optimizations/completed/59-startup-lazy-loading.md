# 59 --- Startup & Initialization Performance

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

The vault plugin loads 50+ modules synchronously during startup, blocks on
filesystem watcher creation, and parses the persisted index JSON before the
first keypress. This document proposes phased lazy loading, deferred watcher
initialization, and async index loading.

---

## 1. Phased Module Loading — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/init.lua` (lines 1-297, 449-557)

The `init.lua` file loads and calls `.setup()` on **50+ modules** in a single
synchronous chain during startup:

```lua
-- Lines 1-7: 7 core modules required immediately
local engine = require("andrew.vault.engine")
local pickers = require("andrew.vault.pickers")
local templates = require("andrew.vault.templates")
-- ...

-- Lines 149-297: 46+ module setup() calls
require("andrew.vault.wikilinks").setup()
require("andrew.vault.backlinks").setup()
require("andrew.vault.navigate").setup()
require("andrew.vault.search").setup()     -- Loads 5 sub-modules
require("andrew.vault.outline").setup()
-- ... 40+ more ...
```

Each `require()` loads the module file, which in turn loads its own
dependencies. The dependency chain means a single `init.lua` call pulls in
~100+ Lua files.

**Key expensive chains:**
- `search.setup()` → loads `search.advanced` → loads `search_query` +
  `search_filter` (8 sub-modules) → loads `date_utils`, `filter_utils`, etc.
- `embed` system → loads 4 sub-modules (`embed_state`, `embed_images`,
  `embed_resolver`, `embed_sync`)
- `graph` → loads 4 sub-modules
- `query` → loads 6 sub-modules

### Proposed Solution

Split module loading into 3 tiers:

**Tier 1 (Immediate):** Modules needed before the first buffer is displayed.
- `engine`, `config`, `vault_log`, `notify`, `resource_cleanup`
- `vault_index` (load persisted data)
- Core autocmd registration

**Tier 2 (On first markdown buffer):** Modules needed for editing features.
- `wikilinks`, `highlights`, `tag_highlights`, `wikilink_highlights`
- `autolink`, `footnotes`, `embed`
- `completion` sources
- `frontmatter`

**Tier 3 (On demand):** Modules only needed when user invokes a command.
- `search` (on `:VaultSearch`)
- `graph`, `connections` (on `:VaultGraph`, `:VaultConnections`)
- `tasks`, `task_timeline`, `task_kanban` (on `:VaultTasks`)
- `calendar` (on `:VaultCalendar`)
- `export`, `stats`, `sidebar`
- `link_repair`, `linkdiag`, `unlinked`
- `frontmatter_editor`, `metaedit`

### Code Changes

**File: `lua/andrew/vault/init.lua`**

Replace the monolithic setup chain with lazy registration:

```lua
-- Tier 1: Load immediately
local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
require("andrew.vault.vault_log")
require("andrew.vault.notify")

-- Tier 2: Load on first markdown BufEnter
local _tier2_loaded = false
local function load_tier2()
  if _tier2_loaded then return end
  _tier2_loaded = true

  require("andrew.vault.wikilinks").setup()
  require("andrew.vault.highlights").setup()
  require("andrew.vault.tag_highlights").setup()
  require("andrew.vault.wikilink_highlights").setup()
  require("andrew.vault.autolink").setup()
  require("andrew.vault.footnotes").setup()
  require("andrew.vault.embed").setup()
  require("andrew.vault.frontmatter").setup()
  require("andrew.vault.completion").setup()
  require("andrew.vault.completion_tags").setup()
  -- ... other editing-essential modules ...
end

vim.api.nvim_create_autocmd("BufEnter", {
  pattern = "*.md",
  once = true,  -- Only fire once, ever
  callback = function()
    if engine.is_vault_path(vim.api.nvim_buf_get_name(0)) then
      load_tier2()
    end
  end,
})

-- Tier 3: Lazy command registration (command loads module on first use)
local function lazy_command(name, module_path, method, opts)
  vim.api.nvim_create_user_command(name, function(args)
    local mod = require(module_path)
    if mod.setup and not mod._setup_done then
      mod.setup()
      mod._setup_done = true
    end
    mod[method](args)
  end, opts or {})
end

lazy_command("VaultSearch", "andrew.vault.search", "open", { nargs = "?" })
lazy_command("VaultGraph", "andrew.vault.graph", "open", {})
lazy_command("VaultConnections", "andrew.vault.connections", "show", {})
lazy_command("VaultCalendar", "andrew.vault.calendar", "toggle", {})
lazy_command("VaultTasks", "andrew.vault.tasks", "list", { nargs = "?" })
lazy_command("VaultTimeline", "andrew.vault.task_timeline", "timeline", {})
lazy_command("VaultStats", "andrew.vault.stats", "show", {})
lazy_command("VaultExport", "andrew.vault.export", "export", { nargs = "?" })
-- ... etc ...
```

### Expected Performance Improvement

Estimated module loading times (based on typical Lua require overhead):

- **Before:** ~50+ modules × ~2-5ms each = 100-250ms startup
- **After Tier 1:** ~5 modules = 10-25ms startup
- **Tier 2 on first BufEnter:** ~15 modules = 30-75ms (amortized, after
  user sees first buffer)
- **Tier 3:** loaded only when needed (0ms at startup)

**Net startup improvement:** 70-90% reduction in vault plugin startup time.

### Risk Assessment

- **Command availability:** Lazy commands are registered immediately (user
  can see them in `:command`), but module loading happens on first invoke.
  First invocation has a one-time delay.
- **Keybinding availability:** Keybindings that depend on Tier 2 modules
  (e.g., `gf` for wikilink follow) won't work until Tier 2 loads. Since
  BufEnter fires before the user can type, this is transparent.
- **Cross-module dependencies:** Some Tier 3 modules may subscribe to events
  or register with the vault index. These subscriptions would be delayed.
  Audit each module for startup-time side effects.
- **Migration complexity:** The main risk is subtle ordering dependencies
  between modules. Implement gradually — start by deferring the least
  interdependent modules (stats, export, sidebar).

---

## 2. Async Filesystem Watcher Initialization — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/engine_watcher.lua` (lines 138-220)

On Linux, `start_fs_watcher()` recursively scans every subdirectory to
install inotify watches:

```lua
function add_dir_watch(vault, abs_dir)
  -- Create inotify watch for abs_dir
  local handle = vim.uv.new_fs_event()
  handle:start(abs_dir, { recursive = false }, function(...) ... end)

  -- Recursively scan for subdirectories
  local scandir = vim.uv.fs_scandir(abs_dir)
  if scandir then
    while true do
      local name, ftype = vim.uv.fs_scandir_next(scandir)
      if not name then break end
      if ftype == "directory" and not skip_dirs[name] then
        add_dir_watch(vault, abs_dir .. "/" .. name)  -- Recursive call
      end
    end
  end
end
```

For a vault with 100 subdirectories, this blocks startup for 50-200ms
(100 `fs_scandir` + 100 `new_fs_event` + 100 `start` calls).

Called synchronously from `init.lua` line 449.

### Proposed Solution

Defer watcher initialization to after startup, and make the recursive
directory scan non-blocking using a coroutine.

### Code Changes

**File: `lua/andrew/vault/init.lua`**

```lua
-- Before:
engine.start_fs_watcher()

-- After:
vim.defer_fn(function()
  engine.start_fs_watcher()
end, 200)  -- Start 200ms after init, unblocking startup
```

**File: `lua/andrew/vault/engine_watcher.lua`**

Make the recursive scan incremental:

```lua
function W.start_fs_watcher()
  if _platform_recursive then
    -- macOS/Windows: single recursive watch (already fast)
    start_recursive_watch()
  else
    -- Linux: install watches incrementally via coroutine
    start_incremental_watches()
  end
end

local function start_incremental_watches()
  local vault = engine.vault_path
  local skip = watcher_skip_dirs()

  -- Install top-level watch immediately
  install_single_watch(vault)

  -- Scan subdirectories in batches via coroutine
  local dirs_to_scan = { vault }
  local co = coroutine.create(function()
    while #dirs_to_scan > 0 do
      local dir = table.remove(dirs_to_scan, 1)
      local scandir = vim.uv.fs_scandir(dir)
      if scandir then
        local batch = 0
        while true do
          local name, ftype = vim.uv.fs_scandir_next(scandir)
          if not name then break end
          if ftype == "directory" and not skip[name] then
            local sub = dir .. "/" .. name
            install_single_watch(sub)
            dirs_to_scan[#dirs_to_scan + 1] = sub
            batch = batch + 1
            if batch >= 10 then
              coroutine.yield()  -- Yield every 10 dirs to keep UI responsive
              batch = 0
            end
          end
        end
      end
    end
  end)

  -- Resume coroutine on event loop
  local function step()
    if coroutine.status(co) == "dead" then return end
    local ok, err = coroutine.resume(co)
    if not ok then
      log.error("watcher scan error: " .. tostring(err))
      return
    end
    if coroutine.status(co) ~= "dead" then
      vim.defer_fn(step, 1)  -- Continue on next event loop tick
    end
  end

  step()
end
```

### Expected Performance Improvement

- **Before:** 100 directories scanned synchronously = 50-200ms blocking
- **After:** Top-level watch installed immediately (<1ms), subdirectories
  scanned incrementally over ~10 event loop ticks (~10ms total, non-blocking)
- **User perception:** No startup delay from watcher. Files in deeply nested
  directories may have a 50-100ms window where changes aren't watched, which
  is acceptable.

### Risk Assessment

- **Brief unwatched period:** During the incremental scan, newly created
  subdirectories might be missed. The existing `FocusGained` handler
  (init.lua line 365) provides a safety net by triggering a re-scan.
- **Watch limit:** The total number of inotify watches is unchanged; only
  the timing of creation changes.

---

## 3. Async Index Loading — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/init.lua` (lines 455-462)

```lua
local idx = vi.get(engine.vault_path)
idx:load()           -- Synchronous JSON parse
idx:build_async()    -- Starts coroutine (non-blocking)
```

`idx:load()` (vault_index.lua line 133-185) reads and parses
`.vault-index/index.json` synchronously. For a 2000-file vault, this JSON
file can be 2-5MB, taking 20-100ms to parse.

### Proposed Solution

Defer the `load()` call to a timer, and make the index tolerate being
queried before loading completes.

### Code Changes

**File: `lua/andrew/vault/init.lua`**

```lua
-- Before:
local idx = vi.get(engine.vault_path)
idx:load()
idx:build_async()

-- After:
local idx = vi.get(engine.vault_path)
vim.defer_fn(function()
  idx:load()
  idx:build_async()
end, 50)  -- Load after initial render
```

The vault index already handles `_ready = false` state (modules check
`vault_index.current()` which returns nil if not ready). This means all
downstream consumers already have fallback behavior for when the index
isn't ready.

### Expected Performance Improvement

- **Before:** 20-100ms synchronous JSON parse during startup
- **After:** 0ms at startup; parse happens 50ms later in the background
- Effectively invisible to the user since the first buffer render completes
  before index loading starts.

### Risk Assessment

- **Modules querying before ready:** Already handled — `vault_index.current()`
  returns nil when not ready, and all consumers check this.
- **Autocmds firing before index ready:** BufReadPost handlers that need the
  index (e.g., embed rendering) already defer via timers (150ms for embeds).
  The 50ms load delay completes before these fire.

---

## 4. Lazy Search Submodule Loading — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/search.lua` (lines 71-75)

```lua
local advanced   = require("andrew.vault.search.advanced")
local prompt     = require("andrew.vault.search.prompt")
local live       = require("andrew.vault.search.live")
local help       = require("andrew.vault.search.help")
local completion = require("andrew.vault.search.completion")
```

These 5 modules (plus their transitive dependencies: `search_query`,
`search_filter` with 8 sub-modules) are loaded during `search.setup()`,
which is called from `init.lua`. The search system is only used when the
user explicitly invokes `:VaultSearch`.

### Proposed Solution

Use lazy require pattern:

```lua
-- Before:
local advanced = require("andrew.vault.search.advanced")

-- After:
local advanced
local function get_advanced()
  if not advanced then
    advanced = require("andrew.vault.search.advanced")
  end
  return advanced
end

-- Or more concisely with a lazy proxy:
local lazy = function(mod_path)
  local mod
  return setmetatable({}, {
    __index = function(_, key)
      if not mod then mod = require(mod_path) end
      return mod[key]
    end,
  })
end

local advanced   = lazy("andrew.vault.search.advanced")
local prompt     = lazy("andrew.vault.search.prompt")
local live       = lazy("andrew.vault.search.live")
local help       = lazy("andrew.vault.search.help")
local completion = lazy("andrew.vault.search.completion")
```

### Expected Performance Improvement

- **Before:** search.setup() loads ~15 modules transitively = 30-75ms
- **After:** search.setup() registers commands only = <1ms
- First `:VaultSearch` invocation has one-time ~30-75ms delay

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Async Index Loading (#3) | Low | Medium | Low |
| 2 | Async Watcher Init (#2) | Medium | Medium | Low |
| 3 | Lazy Search Submodules (#4) | Low | Medium | Low |
| 4 | Phased Module Loading (#1) | High | High | Medium |

Start with #3 and #4 (low effort, immediate gains). #2 requires careful
testing on Linux. #1 is the largest change but has the biggest impact.

---

## Testing Strategy

### Phased Module Loading (#1)
1. Measure startup time before/after with `:lua print(vim.fn.reltime())`.
2. Verify all commands work on first invocation.
3. Verify keybindings work in markdown buffers.
4. Verify no errors when opening non-vault markdown files.

### Async Watcher (#2)
1. Edit and save a file in a nested directory immediately after startup.
   Verify the index eventually picks up the change (within 1-2s).
2. Monitor inotify watch count with `ls /proc/self/fdinfo/ | wc -l`.

### Async Index Loading (#3)
1. Open a vault note immediately after startup. Verify embeds render
   (may show loading state briefly).
2. Verify `:VaultIndexStatus` shows "ready" within 1-2s of startup.

### Lazy Search (#4)
1. Invoke `:VaultSearch` and verify it works on first use.
2. Check that `search_query`, `search_filter` are not in `package.loaded`
   until first search invocation.

---

## Related Documents

- Doc 61-startup-and-watcher-performance covers additional startup optimizations (blocking fallback removal, directory scan deferral).
- Doc 63-engine-startup-performance covers engine/watcher startup optimizations.
