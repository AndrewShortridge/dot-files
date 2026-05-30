# 37. Scan Completion Waiters

## Problem

Multiple modules need the vault index to reach a "ready" state or a specific generation before proceeding. The current codebase uses several ad-hoc patterns to deal with this:

1. **Polling with `vim.defer_fn`**: Modules like `embed.lua` schedule deferred calls via `vim.defer_fn` with `config.embed.render_delay_ms` (150ms, lines 986-990), `on_buf_enter` (50ms, lines 1070-1074), and `sync.ensure_subscription` (200ms, lines 1059-1061). `task_notify.lua` uses `config.task_notify.init_delay_ms` (500ms, lines 259-263). These waste timer resources and introduce unpredictable latency (the defer interval may be too long or too short). Note: `embed.lua` does NOT reference `vault_index` or `is_ready()` — it relies entirely on timing heuristics and state flags (`embeds_visible`, `is_embed_active`). The `is_valid_current_buf()` helper (lines 974-976) guards deferred callbacks.

2. **Silent skip with `is_ready()` guards**: `search/live.lua` checks in `search_advanced_live()` (line 24, function at line 17) and `search_in_files()` (line 169, function at line 158), calling `notify.warn()` (lines 25, 170) and returning early. `calendar.lua` checks in `scan_dates_from_index()` (line 122, function at lines 119-135) and returns empty indicators with only a debug log. In both cases the user operation is lost entirely — the user must manually retry.

3. **Graceful fallback**: `search/advanced.lua` (lines 354-363) checks `is_ready()` and falls back to plain ripgrep text search via `fzf.grep()` when the index is not ready, with an optional `notify.index_not_ready()` message (line 356, helper defined in `notify.lua` lines 47-51). This preserves the operation but loses advanced query features.

4. **Non-blocking empty return**: `engine.lua`'s `get_name_cache()` (lines 659-668) checks `is_ready()` and returns an empty `{ paths = {}, names = {} }` cache. `completion.lua`'s `build_iter` (lines 269-343) returns `nil` at line 271 via `completion_base.get_ready_index()` (lines 554-559), and `completion_base.lua` has an `index_is_building()` guard (lines 195-213) with a 30-second timeout fallback via `conf("index_build_timeout_secs", 30)`. The async build entry point is `build_items_async` (lines 359-494), which checks `index_is_building()` at lines 413 and 436.

5. **Persistent subscribers via `_subscribers`**: The `subscribe(opts)` mechanism (lines 237-254) fires callbacks on every generation increment. Subscribers accept either a function or `{ fn, interests }` for filtered updates. The `_subscribers` field is initialized at line 187 in the constructor (`SubscriberEntry` class at lines 113-115). The subscriber notification loop is at lines 429-438 within `_notify_update()`. This is appropriate for modules that need continuous updates (like live search), but wasteful for modules that only need to know "the index is ready now" once during initialization.

6. **`config.task_notify.init_delay_ms` timer**: `task_notify.lua` uses a fixed 500ms delay timer (lines 259-263, config at line 746) as a heuristic for "the index is probably ready by now." This is fragile — too short on slow machines, unnecessarily slow on fast ones. The `is_ready()` check also appears at line 19 inside the `_overdue_cache` generator (a `task_utils.gen_cache` instance, lines 18-49). The `check_overdue()` function (lines 68-120) includes its own throttling via `config.task_notify.check_interval` (300s) and snooze logic.

There is no mechanism to say "call me exactly once when generation >= X" or "call me exactly once when the index becomes ready." This leads to duplicated logic, wasted cycles, and initialization races.

## Inspiration

Zed's `crates/worktree/src/worktree.rs` maintains a waiter queue on the `RemoteWorktree` struct (lines 144-156, field at line 152):

```rust
snapshot_subscriptions: VecDeque<(usize, oneshot::Sender<()>)>,
```

Callers invoke `wait_for_snapshot(scan_id)` (lines 2173-2195) which returns a `Future` that resolves when `completed_scan_id >= scan_id`. The implementation:

```rust
pub fn wait_for_snapshot(
    &mut self,
    scan_id: usize,
) -> impl Future<Output = Result<()>> + use<> {
    let (tx, rx) = oneshot::channel();
    if self.observed_snapshot(scan_id) {
        let _ = tx.send(());
    } else if self.disconnected {
        drop(tx);
    } else {
        match self
            .snapshot_subscriptions
            .binary_search_by_key(&scan_id, |probe| probe.0)
        {
            Ok(ix) | Err(ix) => self.snapshot_subscriptions.insert(ix, (scan_id, tx)),
        }
    }

    async move {
        rx.await?;
        Ok(())
    }
}
```

Resolution happens on the foreground task (lines 655-662) after each snapshot update:

```rust
while let Some((scan_id, _)) = this.snapshot_subscriptions.front() {
    if this.observed_snapshot(*scan_id) {
        let (_, tx) = this.snapshot_subscriptions.pop_front().unwrap();
        let _ = tx.send(());
    } else {
        break;
    }
}
```

The helper `observed_snapshot()` (lines 2169-2171) compares against `completed_scan_id` (field at line 178 in the `Snapshot` struct, lines 159-179):

```rust
fn observed_snapshot(&self, scan_id: usize) -> bool {
    self.completed_scan_id >= scan_id
}
```

Call sites include `expand_entry()` (lines 992-1016, wait at line 1009), `expand_all_for_entry()` (lines 1018-1042, wait at line 1035), `insert_entry()` (lines 2197-2214, wait at line 2203), and `delete_entry()` (lines 2216-2243 RemoteWorktree impl, wait at line 2232). Note: `handle_delete_entry()` (lines 1069-1089) does not call `wait_for_snapshot()` directly — it delegates to `delete_entry()`, which does call `wait_for_snapshot()`. Additionally, `disconnected_from_host()` (lines 2118-2122) calls `self.snapshot_subscriptions.clear()` (line 2120) to clean up on disconnect.

This gives callers a clean, composable primitive: "wait until this specific state is reached, then proceed." No polling, no persistent subscriptions, no guessing delays.

## Design

### Waiter Structure

```lua
--- @class VaultWaiter
--- @field id number       Unique waiter ID (for cancellation)
--- @field generation number  Target generation to wait for (0 = wait for ready)
--- @field callback function  Called with (current_generation) when condition met
--- @field description string|nil  Optional debug label
```

### Waiter List

The vault index maintains a sorted list of waiters:

```lua
-- In vault_index instance fields (constructor at lines 168-213):
self._waiters = {}       -- sorted by generation (ascending)
self._waiter_seq = 0     -- monotonic ID counter
```

### Registration

```lua
--- Wait for the index to reach a specific generation.
--- If the condition is already met, callback fires immediately (synchronous).
--- @param generation number  Target generation (fires when _generation >= generation)
--- @param callback function  Called with (current_generation)
--- @param description string|nil  Debug label
--- @return function cancel  Call to remove the waiter
function M.VaultIndex:wait_for(generation, callback, description)
  -- Fast path: condition already met
  if self._generation >= generation then
    callback(self._generation)
    return function() end  -- no-op cancel
  end

  -- Safety cap (reuse existing coalescer cap pattern)
  if #self._waiters >= config.index.max_waiters then
    log.warn("waiter cap reached (%d), dropping oldest", config.index.max_waiters)
    table.remove(self._waiters, 1)
  end

  self._waiter_seq = self._waiter_seq + 1
  local waiter = {
    id = self._waiter_seq,
    generation = generation,
    callback = callback,
    description = description,
  }

  -- Insert sorted by generation (ascending)
  local inserted = false
  for i, w in ipairs(self._waiters) do
    if generation < w.generation then
      table.insert(self._waiters, i, waiter)
      inserted = true
      break
    end
  end
  if not inserted then
    self._waiters[#self._waiters + 1] = waiter
  end

  -- Return cancel handle
  local id = waiter.id
  return function()
    for i, w in ipairs(self._waiters) do
      if w.id == id then
        table.remove(self._waiters, i)
        return
      end
    end
  end
end
```

### Ready Waiter (Convenience)

```lua
--- Wait for the index to become ready.
--- "Ready" means _ready == true (at least one successful load/build).
--- @param callback function  Called with (current_generation)
--- @param description string|nil  Debug label
--- @return function cancel
function M.VaultIndex:wait_for_ready(callback, description)
  -- Fast path
  if self._ready then
    callback(self._generation)
    return function() end
  end

  -- Use generation 1 as the sentinel: the first completed build sets _generation >= 1
  -- But we also need to handle the case where _ready is set without generation advancing
  -- (e.g., loading persisted index sets _ready in load())

  self._waiter_seq = self._waiter_seq + 1
  local waiter = {
    id = self._waiter_seq,
    generation = 0,  -- special: 0 means "wait for _ready"
    callback = callback,
    description = description or "wait_for_ready",
    ready_waiter = true,
  }

  -- Ready waiters go at the front (they fire on any generation if _ready is true)
  table.insert(self._waiters, 1, waiter)

  local id = waiter.id
  return function()
    for i, w in ipairs(self._waiters) do
      if w.id == id then
        table.remove(self._waiters, i)
        return
      end
    end
  end
end
```

### Firing Waiters

```lua
--- Check and fire any waiters whose conditions are met.
--- Called after _generation increments or _ready becomes true.
function M.VaultIndex:_check_waiters()
  local still_waiting = {}
  for _, waiter in ipairs(self._waiters) do
    local should_fire = false

    if waiter.ready_waiter then
      should_fire = self._ready
    else
      should_fire = self._generation >= waiter.generation
    end

    if should_fire then
      local ok, err = pcall(waiter.callback, self._generation)
      if not ok then
        log.error("waiter '%s' callback failed: %s", waiter.description or "?", err)
      end
    else
      still_waiting[#still_waiting + 1] = waiter
    end
  end
  self._waiters = still_waiting
end
```

### Integration Points in vault_index.lua

The four critical state-transition points where `_check_waiters()` must be called:

```lua
-- In load() (line 775) after setting _ready = true:
function M.VaultIndex:load()
  -- ... existing load logic (lines 678-778) ...
  self:_rebuild_precomputed_sets()
  -- Build hierarchical summary tree from loaded files
  if config.summary_tree and config.summary_tree.enabled then
    self._summary_tree:build_from_files(self.files)
  end
  self._ready = true        -- LINE 775
  self:_check_waiters()     -- NEW: fire ready waiters
  log.debug("loaded persisted index (%d files)", self._file_count)
  return true, nil
end

-- In _notify_update() (line 410) after incrementing _generation:
function M.VaultIndex:_notify_update(context)
  self._generation = self._generation + 1  -- LINE 411
  self:_check_waiters()     -- NEW: fire generation waiters
  -- ... existing subscriber notification (lines 413-439) ...
end

-- In _apply_staged() (line 578) after setting _ready = true:
function M.VaultIndex:_apply_staged(...)
  -- ... existing apply logic (lines 521-577) ...
  self._ready = true        -- LINE 578
  self:_check_waiters()     -- NEW: fire ready waiters (async build path)
  self._building = false    -- LINE 579
  -- ... persist scheduling, _notify_update (lines 580-583) ...
end

-- In build_sync() (line 1448) after setting _ready = true:
function M.VaultIndex:build_sync()
  -- ... existing build logic (lines 1438-1452) ...
  self._ready = true        -- LINE 1448
  self:_check_waiters()     -- NEW: fire ready waiters (sync build path)
  self:_schedule_persist()
  self:_notify_update()
end
```

**Note:** `_finish_build()` does not exist. The actual generation increment happens in `_notify_update()` (line 411). `_ready` is set in three places: `load()` (line 775), `_apply_staged()` (line 578), and `build_sync()` (line 1448). The `_apply_staged()` method (lines 521-631) is the completion handler for async builds. The `_notify_update()` method starts at line 410.

## Target Modules

### embed.lua (Deferred Rendering)

Currently uses three `vim.defer_fn` calls:
- `config.embed.render_delay_ms` (150ms) in `BufReadPost` autocmd (lines 980-992, defer at 986-990)
- 50ms in `on_buf_enter` (lines 1066-1076, defer at 1070-1074)
- 200ms for `sync.ensure_subscription()` (lines 1059-1061)

**Important:** `embed.lua` does NOT reference `vault_index` or call `is_ready()` anywhere. It relies entirely on timing heuristics and state flags (`embeds_visible`, `is_embed_active`). Migration requires adding a `vault_index` require.

Replace the timing heuristic with a waiter:

```lua
-- Before (BufReadPost autocmd, lines 980-992):
state.embeds_visible[ev.buf] = "pending"
vim.defer_fn(function()
  if is_valid_current_buf(ev.buf) and state.embeds_visible[ev.buf] == "pending" then
    M.render_embeds({ silent = true })
  end
end, config.embed.render_delay_ms)

-- After:
state.embeds_visible[ev.buf] = "pending"
local vault_index = require("andrew.vault.vault_index")
local idx = vault_index.current()
if idx then
  idx:wait_for_ready(function()
    vim.schedule(function()
      if is_valid_current_buf(ev.buf) and state.embeds_visible[ev.buf] == "pending" then
        M.render_embeds({ silent = true })
      end
    end)
  end, "embed.render_on_open")
end
```

Similarly for `on_buf_enter` (lines 1066-1076, defer at 1070-1074):

```lua
-- Before:
function M.on_buf_enter(ctx)
  sync.ensure_subscription()
  state.gc_stale_buffers()
  if not state.embeds_visible[ctx.bufnr] then
    vim.defer_fn(function()
      if is_valid_current_buf(ctx.bufnr) then
        M.render_embeds({ silent = true })
      end
    end, 50)
  end
end

-- After:
function M.on_buf_enter(ctx)
  sync.ensure_subscription()
  state.gc_stale_buffers()
  if not state.embeds_visible[ctx.bufnr] then
    local vault_index = require("andrew.vault.vault_index")
    local idx = vault_index.current()
    if idx then
      idx:wait_for_ready(function()
        vim.schedule(function()
          if is_valid_current_buf(ctx.bufnr) then
            M.render_embeds({ silent = true })
          end
        end)
      end, "embed.render_on_enter")
    end
  end
end
```

**Note:** The third `vim.defer_fn` (200ms for `sync.ensure_subscription()` at line 1059) is an initialization concern, not an index-readiness concern, and should NOT be migrated to a waiter.

### completion.lua / completion_base.lua (First Build)

Currently `completion_base.get_ready_index()` (lines 554-559) returns `nil` when the index isn't ready, causing `build_iter` (completion.lua:269) to return `nil` and yield no items. The `index_is_building()` guard (lines 195-213) has a 30-second timeout fallback via `conf("index_build_timeout_secs", 30)` at line 203. The `build_items_async()` function (lines 359-494) checks `index_is_building()` at lines 413 and 436 and returns early with an empty callback. The local `invalidate()` function (lines 215-222) clears `cached_items` and `_cached_gen`. `M.empty_response` is defined at line 542. With waiters, the completion source can register for notification and trigger a rebuild:

```lua
-- In completion_base.lua, modify the not-ready path in build_items_async:
if not idx or not idx:is_ready() then
  if idx then
    idx:wait_for_ready(function()
      -- Invalidate cache so next completion trigger rebuilds
      invalidate()
    end, "completion.first_ready")
  end
  callback(M.empty_response)
  return
end
```

### search/live.lua (Ready Guard)

Currently warns and returns early at two call sites:
- `search_advanced_live()` (line 24, function at line 17): `notify.warn("index not ready for advanced live search")`
- `search_in_files()` (line 169, function at line 158): `notify.warn("index not ready for search in files")`

Instead, show a message and auto-execute when ready:

```lua
-- Before (search/live.lua:23-26, function at line 17):
local idx = get_vault_index().current()
if not idx or not idx:is_ready() then
  notify.warn("index not ready for advanced live search")
  return
end

-- After:
local idx = get_vault_index().current()
if not idx or not idx:is_ready() then
  notify.info("Index building, search will start when ready...")
  if idx then
    idx:wait_for_ready(function()
      vim.schedule(function()
        M.search_advanced_live()
      end)
    end, "search.live.deferred")
  end
  return
end
```

Apply the same pattern to `search_in_files()` (line 169).

### search/advanced.lua (Fallback Guard)

Currently falls back to plain ripgrep text search (lines 353-363) using `fzf.grep()` when the index is not ready. With waiters, the advanced search can be deferred instead of degraded:

```lua
-- Before (search/advanced.lua:354-363, function at line 337):
local idx = vault_index.current()
if not idx or not idx:is_ready() then
  if not opts.silent then
    notify.index_not_ready("falling back to text search")
  end
  fzf.grep(engine.vault_fzf_opts("Vault advanced", {
    search = query_string,
    rg_opts = engine.rg_base_opts(),
  }))
  return
end

-- After:
local idx = vault_index.current()
if not idx or not idx:is_ready() then
  if idx then
    notify.info("Index building, advanced search will start when ready...")
    idx:wait_for_ready(function()
      vim.schedule(function()
        M.execute_advanced_query(query_string, opts)
      end)
    end, "search.advanced.deferred")
  else
    -- No index at all, fall back to text search
    if not opts.silent then
      notify.index_not_ready("falling back to text search")
    end
    fzf.grep(engine.vault_fzf_opts("Vault advanced", {
      search = query_string,
      rg_opts = engine.rg_base_opts(),
    }))
  end
  return
end
```

### calendar.lua (Deadline Scan)

Currently checks `is_ready()` in `scan_dates_from_index()` (line 122) and silently returns empty indicators with only a debug log (lines 122-135). The `_deadline_cache` (lines 140-180) is a `gen_cache` instance with automatic generation-based invalidation and partial update support. Cache invalidation is registered in `M.setup()` at lines 727-759 via the engine cache registration system (`engine.register_cache()` at line 728). The `redraw()` local function (lines 502-524) handles calendar UI refresh. Replace with a waiter that triggers a cache invalidation and calendar refresh:

```lua
-- Before (calendar.lua:119-135):
local function scan_dates_from_index()
  local stop = require("andrew.vault.memory_profiler").start_timer("calendar.scan_dates")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    log.debug("index not ready, returning empty dates")
    stop()
    return {}, nil
  end

-- After:
local function scan_dates_from_index()
  local stop = require("andrew.vault.memory_profiler").start_timer("calendar.scan_dates")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    log.debug("index not ready, deferring deadline scan")
    if idx then
      idx:wait_for_ready(function()
        vim.schedule(function()
          _deadline_cache:invalidate()
          -- Trigger calendar refresh if visible
          -- (calendar UI module should expose a refresh method)
        end)
      end, "calendar.indicators")
    end
    stop()
    return {}, nil
  end
```

**Note:** The `_deadline_cache` is a `gen_cache` instance (lines 140-180) created via `gen_cache.gen_cache(function(_idx) return scan_dates_from_index() end, {...})` with a `partial_fn` for incremental updates (lines 144-179). Cache invalidation is registered in `M.setup()` at lines 727-759 via `engine.register_cache()` (line 728). The `invalidate()` call forces the next access to re-run `scan_dates_from_index()`. The `redraw()` local function (lines 502-524) handles calendar UI refresh. There is no public `M.refresh_indicators()` method — the waiter can simply invalidate the cache so the next calendar render picks up the data.

### engine.lua (Name Cache)

Currently `get_name_cache()` (lines 659-668) returns an empty `{ paths = {}, names = {} }` cache when the index isn't ready (line 667), with a debug log at line 667. When ready, it checks `is_ready()` at line 661 and delegates to `idx:get_name_cache()` (line 663). This is acceptable since callers handle empty caches gracefully, but a waiter could improve first-use latency:

```lua
-- The non-blocking pattern in engine.lua is acceptable as-is.
-- Callers already handle empty caches. No migration required unless
-- specific callers need guaranteed populated caches on first call.
```

### task_notify.lua (Overdue Check)

Currently uses `vim.defer_fn` with `config.task_notify.init_delay_ms` (500ms) in `on_buf_enter` (lines 259-263, defer at 260-262). The `check_overdue()` function (lines 68-120) includes its own throttling via `check_interval` (line 78, default 300s) and snooze logic (lines 74-75). The `is_ready()` check also appears at line 19 inside the `_overdue_cache` generator (lines 18-49). Replace with a waiter:

```lua
-- Before (task_notify.lua:259-263):
function M.on_buf_enter(_ctx)
  vim.defer_fn(function()
    check_overdue()
  end, config.task_notify.init_delay_ms)
end

-- After:
function M.on_buf_enter(_ctx)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if idx then
    idx:wait_for_ready(function()
      vim.schedule(function()
        check_overdue()
      end)
    end, "task_notify.overdue")
  end
end
```

## Implementation Steps

### Step 1: Add waiter fields to VaultIndex

In `vault_index.lua`, add to the constructor `M.VaultIndex.new()` (lines 168-213, after existing field initialization around line 201):

```lua
function M.VaultIndex.new(vault_path)
  local self = setmetatable({}, { __index = M.VaultIndex })
  -- ... existing fields (lines 175-201) ...
  self._waiters = {}
  self._waiter_seq = 0
  return self
end
```

### Step 2: Implement wait_for, wait_for_ready, and _check_waiters

Add the three functions as described in the Design section above. All three are methods on the `M.VaultIndex` instance.

### Step 3: Wire _check_waiters into existing lifecycle

Add `self:_check_waiters()` calls at the four critical state-transition points:
- In `load()` (after line 775) after `self._ready = true`
- In `_notify_update()` (after line 411) after `self._generation` increments
- In `_apply_staged()` (after line 578, method at lines 521-631) after `self._ready = true` (async build completion)
- In `build_sync()` (after line 1448) after `self._ready = true`

### Step 4: Add config.index.max_waiters

In `config.lua`, add to the existing `M.index` section (lines 340-384, after `use_snapshots` at line 383). The `M.coalescer` section (lines 862-865) already uses `max_waiters = 50` at line 863:

```lua
M.index = {
  -- ... existing fields (lines 340-383: skip_dirs, batch_size, persist_debounce_ms,
  --   persist_min_interval_ms, watch, watch_debounce_ms, warn_collisions,
  --   show_progress, progress_threshold, collision_notify_ms, use_snapshots) ...
  use_snapshots = true,
  max_waiters = 50,  -- Safety cap (matches existing config.coalescer.max_waiters pattern at line 863)
}
```

**Note:** `config.coalescer.max_waiters` (line 863) already uses 50 as the cap value for a similar pattern, so this is consistent.

### Step 5: Add :VaultIndexWaiters debug command

```lua
vim.api.nvim_create_user_command("VaultIndexWaiters", function()
  local idx = vault_index.current()
  if not idx then
    notify.warn("No active vault index")
    return
  end
  local lines = {
    string.format("Generation: %d | Ready: %s", idx._generation, tostring(idx._ready)),
    string.format("Waiters: %d / %d", #idx._waiters, config.index.max_waiters),
    "",
  }
  for i, w in ipairs(idx._waiters) do
    lines[#lines + 1] = string.format(
      "  [%d] id=%d gen=%d %s%s",
      i, w.id, w.generation,
      w.ready_waiter and "(ready) " or "",
      w.description or ""
    )
  end
  -- Display in scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)
end, {})
```

### Step 6: Migrate target modules

Replace patterns in the following modules as described in the Target Modules section:

| Module | File(s) | Current Pattern | Lines |
|--------|---------|-----------------|-------|
| embed | `embed.lua` | `vim.defer_fn` with `render_delay_ms` (150ms) | 980-992 (defer 986-990), 1066-1076 (defer 1070-1074) |
| embed | `embed.lua` | `vim.defer_fn` for `sync.ensure_subscription` (200ms) | 1059-1061 (keep as-is) |
| task_notify | `task_notify.lua` | `vim.defer_fn` with `init_delay_ms` (500ms) | 259-263 (defer 260-262) |
| search/live | `search/live.lua` | `notify.warn()` + silent return | 24, 169 |
| search/advanced | `search/advanced.lua` | Fallback to `fzf.grep()` | 354-363 |
| calendar | `calendar.lua` | Debug log + empty return | 119-135 |
| completion | `completion_base.lua` | `nil` return + building timeout | 554-559, 195-213, 413, 436 |

**Note:** `engine.lua`'s `get_name_cache()` (lines 659-668) pattern is acceptable as-is — callers handle empty caches gracefully.

### Step 7: Remove stale config values

After migration:
- `config.task_notify.init_delay_ms` (line 746 in config.lua, used at line 262 in task_notify.lua) can be removed — the waiter replaces the timing heuristic entirely.
- `config.embed.render_delay_ms` (line 90 in config.lua, used at line 990 in embed.lua) may still be useful for non-waiter scenarios (e.g., debouncing rapid BufEnter events) — evaluate whether to keep or remove.

**Note:** `config.autolink.init_delay_ms` does not exist in the current codebase.

## Integration with Existing Subscribers

The waiter system complements, not replaces, the existing `subscribe(opts)` mechanism (vault_index.lua:237-254):

| Aspect | `subscribe(opts)` | Waiters |
|---|---|---|
| Lifetime | Persistent (fires on every generation) | One-shot (fires once, then removed) |
| Target | Any generation increment (with optional `interests` filter) | Specific generation or ready state |
| Use case | Live UI updates (search, graph, completion cache invalidation) | Initialization, deferred operations |
| Cancellation | Unsubscribe function returned at registration | Cancel handle returned at registration |
| Callback frequency | Every build cycle (filtered by interests) | Exactly once |
| Callback signature | `fn(generation, inv_ctx)` (see `_notify_update` starting at line 410) | `fn(current_generation)` |

Subscribers are for "keep me updated." Waiters are for "tell me when X happens, then forget about me."

Modules that currently misuse `subscribe(opts)` for one-shot initialization (register, fire once, immediately unsubscribe) should migrate to `wait_for` or `wait_for_ready` for clarity.

## Important: vim.schedule in Waiter Callbacks

Since `_check_waiters()` fires synchronously inside `_notify_update()`, `load()`, `_apply_staged()`, and `build_sync()`, waiter callbacks that perform UI operations (opening windows, rendering extmarks, triggering fzf) **must wrap those operations in `vim.schedule()`**. This is critical because:

- `_notify_update()` (starting at line 410) may be called from within a coroutine (the async build pipeline)
- `_apply_staged()` (lines 521-631) is called from within the async build coroutine, and itself calls `_notify_update()`
- `load()` (lines 678-778) and `build_sync()` (lines 1438-1452) run synchronously but callers may not expect re-entrant UI operations

The target module examples above include `vim.schedule()` wrapping where needed.

## Configuration

```lua
-- In config.lua, within M.index (lines 340-384, after use_snapshots at line 383)
M.index = {
  -- ... existing fields (skip_dirs at 342-348, batch_size at 351, persist_debounce_ms at 354,
  --   persist_min_interval_ms at 357, watch at 360, watch_debounce_ms at 363,
  --   warn_collisions at 367, show_progress at 370, progress_threshold at 374,
  --   collision_notify_ms at 377, use_snapshots at 383) ...
  max_waiters = 50,  -- Safety cap to prevent unbounded waiter accumulation
  -- (matches config.coalescer.max_waiters at line 863)
}
```

The `max_waiters` cap prevents pathological cases where a bug registers waiters in a loop. When the cap is reached, the oldest waiter is evicted with a warning log. In normal operation, the waiter count should stay well under 10 (one per module initialization).

## Expected Impact

- **Eliminate polling patterns**: No more `vim.defer_fn` retry loops for index readiness. Modules register a waiter and are called back precisely when the condition is met.
- **Reduce unnecessary deferred calls**: `config.task_notify.init_delay_ms` (currently 500ms) and `config.embed.render_delay_ms` (currently 150ms) add artificial latency. Waiters fire as soon as the index is ready, which may be 50ms or 2000ms depending on vault size — always optimal.
- **No lost operations**: Search queries that arrive before the index is ready are deferred and executed automatically, instead of being silently dropped or degraded to plain text search.
- **Calendar auto-refresh**: Calendar deadline indicators that would have been empty on first render are automatically populated once the index is ready.
- **Cleaner initialization sequences**: Module init becomes `wait_for_ready` registrations instead of `vim.defer_fn` callbacks with timing heuristics.
- **Debugging**: `:VaultIndexWaiters` shows exactly what is waiting and for what, making initialization timing issues visible.
- **Minimal overhead**: The waiter list is typically 0-5 entries. Checking and firing is O(W) where W is the waiter count — negligible compared to the index build itself.
