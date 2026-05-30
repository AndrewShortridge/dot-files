# 23. RAII-Style Cleanup Guards

**Priority:** LOW (downgraded from MEDIUM — most gaps already addressed)
**Phase:** 2 (Scalability)
**Dependencies:** None (standalone pattern)
**Inspired by:** Zed's `Drop` trait implementations (`terminal.rs:1989-1993`, `lsp.rs:1417-1423`, `collab/rpc.rs:99-120`), `ConnectionGuard` pattern, `QueryCursorHandle` RAII return-to-pool (`syntax_map.rs:1901-1908`), `Subscription` dismiss pattern (`subscription.rs:158-203`)

---

## Current State Assessment

The vault codebase **already has substantial cleanup infrastructure** that addresses most of the originally identified gaps. This section documents what exists before proposing what remains.

### Existing Cleanup Infrastructure

#### 1. `resource_cleanup.lua` — Centralized Cleanup Utilities

The vault already has a dedicated cleanup module providing:

| Utility | Purpose |
|---------|---------|
| `M.close_timer(timer)` | Safe timer stop/close with nil + `is_closing()` checks, pcall-wrapped |
| `M.close_timer_in(dict, key)` | Close and remove timer from keyed dictionary |
| `M.debounce(existing, delay_ms, cb)` | Create debounced timer, closing existing first |
| `M.repeating(existing, delay_ms, repeat_ms, cb)` | Create repeating timer, closing existing first |
| `M.weak_callback(state, cb)` | Weak-reference wrapper — no-op if state is GC'd |
| `M.weak_ref(target)` | Weak reference with `.get()` and `.alive()` methods |
| `M.on_buf_delete(group, cb, opts)` | BufDelete + BufWipeout autocmd pair |
| `M.on_buf_delete_once(bufnr, cb)` | One-shot BufDelete + BufWipeout for specific buffer |
| `M.close_win(win)` | Close window if valid (pcall-wrapped) |
| `M.delete_buf(buf)` | Delete buffer if valid (pcall-wrapped) |
| `M.close_win_buf(win, buf)` | Combined close window + delete buffer |
| `M.subscription_handle(get_index, cb, opts)` | Managed subscription with idempotent unsubscribe and vault-switch detection |

#### 2. `embed_state.lua` — State Registry Pattern

The embed system uses a unified per-buffer state registry with registered cleanup functions:

```lua
-- embed_state.lua — state dict registry via register_state() helper (line 26-28)
-- Entries registered at lines 42-65:
_state_dicts = {
  { dict = M.embeds_visible },                                            -- line 42: simple set
  { dict = M.image_placements, cleanup = embed_images.clear_image_placements }, -- lines 43-50: pcall-wrapped close
  { dict = M._embed_deps,      cleanup = function(bufnr) M._embed_deps[bufnr] = nil end }, -- lines 51-53
  { dict = M._sync_timers,     cleanup = cleanup.close_timer_in },        -- lines 54-56
  { dict = M._image_retry_fired },                                        -- line 57: simple set
  { dict = M._embed_descriptors, cleanup = cleanup_async_timer },         -- lines 58-62
  { dict = M._scroll_timers,   cleanup = cleanup.close_timer_in },        -- lines 63-65
}

-- Atomic per-buffer cleanup (lines 89-108)
function M.clear_buffer_state(bufnr, opts)
  opts = opts or {}
  if opts.clear_namespace then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
  if opts.clear_images then opts.clear_images(bufnr) end
  for _, entry in ipairs(_state_dicts) do
    if entry.dict[bufnr] ~= nil then
      if entry.cleanup then entry.cleanup(bufnr) else entry.dict[bufnr] = nil end
    end
  end
  notify_dep_index_dirty()
end

-- Additional: gc_stale_buffers() (lines 111-126) — GCs entries for invalid buffers
-- Additional: cleanup_async_timer(ds, timer) (lines 77-83) — stops/closes async render timer
```

#### 3. `process_semaphore.lua` — Concurrency Control

Ripgrep processes use a semaphore pattern with:
- `M.new(max)` — create new semaphore with max concurrent permits (line 15)
- `M.acquire(sem, callback)` — acquires permit, returns cancel function (line 49)
- `M.try_acquire(sem)` — non-blocking acquire for sync fallback (line 77)
- `M.reset(sem)` — cancels all queued waiters (generation-based invalidation) (line 94)
- `M.stats(sem)` — debug info: `{ active, max, queued }` (line 102)
- Singleton `M.rg_semaphore()` bounded by `config.search.max_concurrent_rg` (line 116)

```lua
-- search_filter/ripgrep.lua spawn_rg_async (lines 190-236) — semaphore-bounded process spawn
semaphore.acquire(get_rg_sem(), function(release)
  process_obj = vim.system(args, {
    stdout = function(_, data) ... end,  -- streaming output
  }, function(result)
    release()  -- Line 223: always called in callback
    -- process results...
  end)
end)
-- Returns cancel function: process_obj:kill() + semaphore cancel (lines 230-235)
-- Also: run_rg_sync (line 296) uses try_acquire(); sync_binary (lines 353,355) parallel try_acquire()
-- Debug: M.semaphore_stats() (line 555), M.semaphore_reset() (line 562)
```

#### 4. VimLeavePre Teardown Chain

Centralized teardown in `event_dispatch.lua` (lines 212-232):

```
VimLeavePre → engine.teardown()             (line 216) → persists URL validation, closes vault log
            → highlight_coordinator.teardown() (line 219) → closes all _timers debounce timers
            → task_hierarchy.teardown()      (line 220) → closes all _timers (NO namespace clear)
            → autosave.teardown()            (line 221) → closes all _timers debounce timers
            → embed.teardown()               (line 224) → clears all buffer state, unsubscribes sync
            → connections.teardown()         (line 227) → unsubscribes from vault index updates
            → callout_folds.teardown()       (line 230) → persists fold state database

init.lua (lines 811-825):
            → cleanup.close_timer(focus_debounce_timer)  (line 815)
            → engine.stop_fs_watcher()                   (line 817)
            → idx:persist_now()                          (lines 818-820)
            → table_pool.clear_all()                     (line 823)
```

#### 5. Generation-Based Stale Detection

Async operations use generation counters to discard stale results. **13 modules** use this pattern:

| Module | Counter/Mechanism | Key Lines |
|--------|-------------------|-----------|
| `embed.lua` | Per-buffer `ds.generation` in `_embed_descriptors`, validated by `check_generation()` | 335-345 (check), 407-412 (init), 360 (async tick) |
| `search/advanced.lua` | Module-level `_search_generation`; closures capture and compare | 16 (decl), 28-29 (capture), 41, 150, 207, 264 (checks) |
| `completion_base.lua` | `_cached_gen` vs `vault_index._generation`; `build_generation` for internal invalidation | 142 (decl), 191 (increment), 235-237 (compare), 289-293 (capture) |
| `gen_cache.lua` | Generic cache factories: `gen_cache()` (single-value) and `keyed_gen_cache()` (multi-key) | 26-51 (single), 64-89 (keyed) |
| `connections.lua` | `_idf_gen` and `_note_data_gen` with TTL + generation double-check | 35, 47 (decl), 103-107 (get), 762-771 (validate) |
| `query/init.lua` | Uses `gen_cache.gen_cache()` with vault_path key function | 19-30 |
| `process_semaphore.lua` | `sem._generation` for queued-waiter cancellation | 50, 66 (capture), 95 (reset), 30 (drain check) |
| `embed_images.lua` | `_image_cache_generation` vs `_last_cache_generation` for image cache invalidation | 45-46 (decl), 55, 77, 84 (increment), 174-178 (validate) |
| `search_filter/match_field.lua` | `_section_cache_generation` for section cache clear | 59 (decl), 63-69 (validate+clear) |
| `search/live.lua` | `_prev_cache.gen` for incremental filtering cache | 38 (init), 62, 84 (validate+update) |
| `search/stats.lua` | `_agg_cache.gen` for field statistics | 157-159 (validate+rebuild) |
| `task_hierarchy.lua` | `_vtext_cache[bufnr].gen` + `rel_path` double-check | 116-123 (validate+rebuild) |
| `filter_utils.lua` | Shared `is_cache_gen_valid(cached, gen, gen_field)` helper used by 5+ modules | 237-247 |

#### 6. Per-Module Timer + BufDelete Cleanup

**13 modules** with timers follow consistent patterns:
- Per-buffer `_timers = {}` dictionary (4 modules) or module-level timer (5 modules) or state-embedded timer (4 modules)
- `cleanup.close_timer_in(_timers, bufnr)` on BufDelete and/or VimLeavePre via `M.teardown()`
- `cleanup.debounce()` / `cleanup.repeating()` for creation (always closes existing first)

| Module | Timer Type | Key Lines |
|--------|-----------|-----------|
| autosave | Per-buffer `_timers` | 19 (dict), 86 (debounce), 196 (BufDelete), 209 (teardown) |
| highlight_coordinator | Per-buffer `_timers` | 206 (dict), 233 (debounce), 308 (BufDelete), 323 (teardown) |
| task_hierarchy | Per-buffer `_timers` | 19 (dict), 150 (debounce), 527 (BufDelete), 569 (teardown) |
| embed_state | Per-buffer `_sync_timers` + `_scroll_timers` | 16, 20 (dicts), 54-56, 63-65 (registry cleanup) |
| embed_sync | Uses `state._sync_timers` | 50 (debounce) |
| embed.lua | Uses `state._scroll_timers` + `ds.async_timer` | 205 (cancel), 358 (repeating), 771 (debounce) |
| url_validate | Module-level `_persist_timer` | 19 (decl), 264 (debounce), 271 (close) |
| engine_watcher | Module-level `_fs_debounce_timer` | 51 (decl), 136 (debounce) |
| sidebar | State-embedded `update_timer` | 33 (field), 138 (close), 234 (debounce) |
| completion_base | State-embedded `state.timer` | 247 (cancel), 305, 328 (debounce) |
| vault_index | Instance `_persist_timer` | 156 (init), 569 (debounce), 580 (close) |
| init.lua | Module-level `focus_debounce_timer` | 672 (decl), 676 (debounce), 815 (close) |
| vault_index_collisions | One-shot debounce | 195 (debounce for notification) |

### Originally Identified Gaps — Status

| Module | Resource | Original Gap | Current Status |
|--------|----------|-------------|----------------|
| embed.lua | Image placements | Missing on render error | **FIXED** — `pcall()` in `create_placement()`, `safe_pcall` in `clear_image_placements()`, state registry cleanup via `embed_state._state_dicts` |
| preview.lua | Float window + buffer | Missing on content load error | **MITIGATED** — `target.resolve()` returns nil (never errors), `close_preview()` (lines 290-330) wraps all cleanup in pcall, `WinClosed` autocmd (line 457) catches external close, buffer reuse strategy (`bufhidden="hide"`, line 392) |
| search.lua | Ripgrep processes | Missing on early return | **FIXED** — `process_semaphore.lua` with acquire/release pattern, cancel function returns `process:kill()` (lines 230-235 of `search_filter/ripgrep.lua`), generation-based stale filtering |
| embed.lua | Debounce timer | Missing on re-entrant render | **FIXED** — `cancel_async_render()` (line 205) stops in-flight timer, `cleanup.debounce()` closes existing timer before creating new one |
| task_hierarchy.lua | Extmark namespace | Missing on buffer close race | **PARTIALLY FIXED** — BufDelete cleanup (line 527) and VimLeavePre teardown (line 569) both call `cleanup.close_timer_in()`, namespace cleared on re-render (line 150). Minor gap: no explicit namespace clear in BufDelete callback or teardown path |

---

## Remaining Problem

While the major resource leaks have been addressed through ad-hoc patterns, the codebase would benefit from a **formal guard abstraction** in specific scenarios:

### 1. Multi-Step Acquisition Without Atomic Cleanup

When a function acquires multiple resources sequentially, failure partway through leaves earlier resources orphaned until BufDelete/VimLeavePre catches them. Example from `preview.lua:M.preview()` (lines 337-464):

```lua
-- preview.lua (current — sequential acquisition)
function M.preview(details, parent_buf)
  -- Step 1: Create or reuse buffer (lines 375-392)
  local buf = state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)  -- Resource 1 (line 381)
    -- Reset keymap state flags (lines 383-390)
  end
  vim.bo[buf].bufhidden = "hide"  -- line 392
  -- Step 2: Create window (lines 397-407)
  local win = vim.api.nvim_open_win(buf, false, { ... })  -- Resource 2
  -- Step 3: State storage (lines 410-413)
  state.win = win; state.buf = buf; state.parent_buf = parent_buf
  -- Step 4: Setup autocmds (lines 440-463) — augroup "VaultPreviewClose"
  --   CursorMoved (441-448), BufLeave (449-456), WinClosed (457-463)

  -- If step 4 fails: win/buf exist but state.augroup is nil
  -- close_preview() (lines 290-330) safely handles this: pcall on augroup delete,
  -- cleanup.close_win on window, explicit keymap.del loop on parent buf keymaps
end
```

The existing `cleanup.close_win()` and `cleanup.delete_buf()` functions handle individual resources, but there's no mechanism to say "if anything fails after this point, undo all prior acquisitions."

### 2. Edit Float Save-on-Close Race

`edit_float.lua` (lines 85-95) creates a per-window WinClosed autocmd for auto-save. The augroup is scoped per-window (`"VaultEditFloat_" .. win`), and the autocmd uses `once = true` for self-cleanup:

```lua
-- edit_float.lua (current — lines 85-95)
local augroup = vim.api.nvim_create_augroup("VaultEditFloat_" .. win, { clear = true })
vim.api.nvim_create_autocmd("WinClosed", {
  group = augroup,
  pattern = tostring(win),
  once = true,  -- Auto-delete after first fire
  callback = function()
    save_float_buf(buf)  -- Checks buf validity + modified flag (lines 14-20)
    local ok, err = pcall(vim.api.nvim_del_augroup_by_id, augroup)
    if not ok then log.debug("del augroup failed: %s", err) end
  end,
})
```

### 3. Subscription Lifecycle Across Module Boundaries

`resource_cleanup.subscription_handle()` provides idempotent unsubscribe, but the pattern requires callers to remember to call `handle.unsubscribe()` in their teardown. A guard that auto-unsubscribes on scope exit would prevent subscription leaks if a module's teardown is skipped.

---

## Zed's Approach

Zed uses Rust's `Drop` trait for **deterministic, automatic cleanup**. Current implementations (verified March 2026):

### Core Patterns

```rust
// crates/collab/src/rpc.rs:92-120 — ConnectionGuard: atomic counter management
// MAX_CONCURRENT_CONNECTIONS = 512 (line 92), CONCURRENT_CONNECTIONS: AtomicUsize (line 94)
pub struct ConnectionGuard;  // line 99
impl ConnectionGuard {
    pub fn try_acquire() -> Result<Self, ()> {  // lines 101-113
        let current = CONCURRENT_CONNECTIONS.fetch_add(1, SeqCst);
        if current >= MAX_CONCURRENT_CONNECTIONS {
            CONCURRENT_CONNECTIONS.fetch_sub(1, SeqCst);
            return Err(());
        }
        Ok(ConnectionGuard)
    }
}
impl Drop for ConnectionGuard {  // lines 116-120
    fn drop(&mut self) {
        CONCURRENT_CONNECTIONS.fetch_sub(1, SeqCst);  // Always decrements
    }
}

// lsp.rs:1417-1423 — LanguageServer: graceful shutdown on drop
impl Drop for LanguageServer {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown() {
            self.executor.spawn(shutdown).detach();
        }
    }
}

// terminal.rs:1989-1993 — Terminal: PTY shutdown on drop
impl Drop for Terminal {
    fn drop(&mut self) {
        self.pty_tx.0.send(Msg::Shutdown).ok();
    }
}

// syntax_map.rs — QueryCursorHandle: return expensive object to pool
// Struct definition at line 224; QUERY_CURSORS pool defined in language.rs:94
impl Drop for QueryCursorHandle {  // lines 1901-1908
    fn drop(&mut self) {
        let mut cursor = self.0.take().unwrap();
        cursor.set_byte_range(0..usize::MAX);
        cursor.set_point_range(Point::zero().to_ts_point()..Point::MAX.to_ts_point());
        QUERY_CURSORS.lock().push(cursor)  // Recycle, don't deallocate
    }
}
// Also has Deref/DerefMut impls (lines 1887-1899)
```

### Additional Patterns Discovered

```rust
// crates/gpui/src/subscription.rs:158-203 — Callback-based cleanup with dismiss (detach)
pub struct Subscription {  // lines 158-161
    unsubscribe: Option<Box<dyn FnOnce() + 'static>>,
}
impl Subscription {
    pub fn detach(mut self) {  // lines 175-177
        self.unsubscribe.take();  // Prevent cleanup on drop (dismiss)
    }
    pub fn join(mut a: Self, mut b: Self) -> Self { /* lines 181-194: compose two subscriptions */ }
}
impl Drop for Subscription {  // lines 197-203
    fn drop(&mut self) {
        if let Some(unsubscribe) = self.unsubscribe.take() {
            unsubscribe();  // Auto-unsubscribe on drop
        }
    }
}

// crates/channel/src/channel_store/channel_index.rs — Deferred invariant maintenance
pub struct ChannelPathsInsertGuard<'a> { /* ... */ }
impl Drop for ChannelPathsInsertGuard<'_> {  // lines 92-100
    fn drop(&mut self) {
        self.channels_ordered.sort_by(/* ... */);  // Sort on scope exit
        self.channels_ordered.dedup();              // Dedup on scope exit
    }
}

// crates/gpui/src/text_system.rs — Object pool with Drop return
// Struct definition at lines 567-570; pool at TextSystem.wrapper_pool (line 52)
impl Drop for LineWrapperHandle {  // lines 572-584
    fn drop(&mut self) {
        let mut state = self.text_system.wrapper_pool.lock();
        let wrapper = self.wrapper.take().unwrap();
        state
            .get_mut(&FontIdWithSize { font_id: wrapper.font_id, font_size: wrapper.font_size })
            .unwrap()
            .push(wrapper);  // Return to font-keyed pool
    }
}
// Also has Deref/DerefMut impls (lines 586-598)

// crates/gpui/src/app/entity_map.rs:306-331 — Reference counting with cleanup queue
impl Drop for AnyEntity {
    fn drop(&mut self) {
        if let Some(entity_map) = self.entity_map.upgrade() {
            let entity_map = entity_map.upgradable_read();
            let prev_count = entity_map.counts.get(self.entity_id)
                .expect("detected over-release")
                .fetch_sub(1, SeqCst);
            if prev_count == 1 {
                let mut entity_map = RwLockUpgradableReadGuard::upgrade(entity_map);
                entity_map.dropped_entity_ids.push(self.entity_id);
            }
        }
    }
}

// crates/language_model/src/rate_limiter.rs:17-20 — Stream wrapper holding semaphore guard
// No explicit Drop impl — uses RAII via _guard field for automatic cleanup
pub struct RateLimitGuard<T> {
    inner: T,
    _guard: SemaphoreGuardArc,  // Released when stream completes/drops
}

// crates/gpui/src/window.rs:390-398 — Focus handle ref counting
impl Drop for FocusHandle {
    fn drop(&mut self) {
        self.handles.read().get(self.id).unwrap().ref_count.fetch_sub(1, SeqCst);
    }
}

// crates/project/src/project.rs:229-243 — Weak ref with manual retain count
impl Drop for RemotelyCreatedModelGuard {
    fn drop(&mut self) {
        if let Some(remote_models) = self.remote_models.upgrade() {
            let mut rm = remote_models.lock();
            rm.retain_count -= 1;
            if rm.retain_count == 0 {
                rm.buffers.clear();
                rm.worktrees.clear();
            }
        }
    }
}
```

Key insight: Zed's patterns go beyond simple cleanup — they include **dismiss/detach** (Subscription), **deferred batch operations** (ChannelPathsInsertGuard), **object pooling** (QueryCursorHandle, LineWrapperHandle), and **weak reference safety** (RemotelyCreatedModelGuard, AnyEntity).

---

## Solution

Create a `guard.lua` module providing scope-based cleanup guards for Lua. This extends `resource_cleanup.lua` with **composable, scope-aware** abstractions — not replacing the existing utilities but building on them.

### Core Guard Implementation

```lua
-- guard.lua

local M = {}

--- Create a cleanup guard that runs cleanup_fn when released.
--- @param cleanup_fn function The cleanup action to perform
--- @param name? string Guard name for debugging
--- @return table guard Object with :release() and :dismiss() methods
function M.new(cleanup_fn, name)
  local guard = {
    _cleanup = cleanup_fn,
    _name = name or "anonymous",
    _released = false,
    _dismissed = false,
  }
  return setmetatable(guard, { __index = Guard })
end

local Guard = {}

--- Explicitly release the guard, running cleanup immediately.
--- Safe to call multiple times (idempotent).
function Guard:release()
  if not self._released and not self._dismissed then
    self._released = true
    local ok, err = pcall(self._cleanup)
    if not ok then
      -- Log but don't propagate — cleanup errors shouldn't crash
      vim.schedule(function()
        vim.notify(
          string.format("Guard '%s' cleanup error: %s", self._name, err),
          vim.log.levels.WARN
        )
      end)
    end
  end
end

--- Dismiss the guard (cancel cleanup).
--- Call when the resource has been transferred to another owner.
--- Inspired by Zed's Subscription.detach() (subscription.rs:175-177)
function Guard:dismiss()
  self._dismissed = true
end

--- Check if guard is still active (not released or dismissed).
function Guard:is_active()
  return not self._released and not self._dismissed
end
```

### Scope Guard (pcall-based RAII)

```lua
--- Execute a function with automatic cleanup on exit.
--- Cleanup runs whether fn succeeds or fails.
--- @param setup_fn function() Acquire resources, return them
--- @param body_fn function(resources) Main logic using resources
--- @param cleanup_fn function(resources) Cleanup regardless of outcome
--- @return boolean ok, any result_or_error
function M.scope(setup_fn, body_fn, cleanup_fn)
  local ok_setup, resources = pcall(setup_fn)
  if not ok_setup then
    return false, resources  -- Setup failed, nothing to clean
  end

  local ok, result = pcall(body_fn, resources)

  -- Always cleanup, even if body_fn errored
  local ok_cleanup, cleanup_err = pcall(cleanup_fn, resources)
  if not ok_cleanup then
    vim.schedule(function()
      vim.notify("Scope cleanup error: " .. tostring(cleanup_err), vim.log.levels.WARN)
    end)
  end

  if not ok then
    return false, result  -- Propagate body error
  end
  return true, result
end
```

### Multi-Guard (Multiple Resources)

```lua
--- Manage multiple cleanup guards with ordered release (LIFO).
--- @return table multi_guard
function M.multi()
  local guards = {}

  local mg = {}

  --- Add a cleanup action. Cleanups run in reverse order (LIFO).
  --- @param cleanup_fn function
  --- @param name? string
  --- @return table guard Individual guard handle
  function mg:add(cleanup_fn, name)
    local g = M.new(cleanup_fn, name)
    guards[#guards + 1] = g
    return g
  end

  --- Release all guards in reverse order.
  function mg:release_all()
    for i = #guards, 1, -1 do
      guards[i]:release()
    end
  end

  --- Dismiss all guards.
  function mg:dismiss_all()
    for i = 1, #guards do
      guards[i]:dismiss()
    end
  end

  --- Execute body with automatic cleanup of all guards on exit.
  --- @param body_fn function(mg) Function receiving multi_guard for adding guards
  --- @return boolean ok, any result_or_error
  function mg:run(body_fn)
    local ok, result = pcall(body_fn, mg)
    mg:release_all()
    if not ok then
      return false, result
    end
    return true, result
  end

  return mg
end
```

### Specialized Guards (Wrappers Around Existing resource_cleanup Utilities)

```lua
--- Create a guard for a uv timer.
--- Delegates to resource_cleanup.close_timer() internally.
--- @param timer userdata uv_timer_t handle
--- @return table guard
function M.timer(timer)
  return M.new(function()
    cleanup.close_timer(timer)  -- Reuse existing utility
  end, "timer")
end

--- Create a guard for a scratch buffer.
--- Delegates to resource_cleanup.delete_buf() internally.
--- @param bufnr integer Buffer number
--- @return table guard
function M.buffer(bufnr)
  return M.new(function()
    cleanup.delete_buf(bufnr)  -- Reuse existing utility
  end, "buffer:" .. tostring(bufnr))
end

--- Create a guard for a floating window (optionally with associated buffer).
--- Delegates to resource_cleanup.close_win() / close_win_buf() internally.
--- @param win integer Window ID
--- @param buf? integer Optional associated buffer
--- @return table guard
function M.window(win, buf)
  return M.new(function()
    if buf then
      cleanup.close_win_buf(win, buf)  -- Reuse existing utility
    else
      cleanup.close_win(win)
    end
  end, "window:" .. tostring(win))
end

--- Create a guard for a spawned process.
--- @param handle table vim.system handle
--- @return table guard
function M.process(handle)
  return M.new(function()
    if handle and not handle:is_closing() then
      handle:kill("sigterm")
    end
  end, "process")
end

--- Create a guard that decrements a counter on release.
--- Inspired by Zed's ConnectionGuard (collab/rpc.rs:99-120).
--- @param counter table Table with a numeric field to decrement
--- @param field string Field name in counter table
--- @return table guard
function M.counter(counter, field)
  counter[field] = (counter[field] or 0) + 1
  return M.new(function()
    counter[field] = counter[field] - 1
  end, "counter:" .. field)
end
```

---

## Integration Targets

### 1. Preview Float — Multi-Step Acquisition Guard

The preview module's `M.preview()` (lines 337-464) creates buffer, window, keymaps, and augroup sequentially. If any step after window creation fails, earlier resources are partially initialized.

```lua
-- preview.lua (current — lines 337-464, sequential acquisition)
function M.preview(details, parent_buf)
  -- Lines 337-360: early returns (already active, no link found)
  local buf = state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)  -- line 381
    -- Lines 383-390: reset keymap state flags
  end
  vim.bo[buf].bufhidden = "hide"  -- line 392

  local win = vim.api.nvim_open_win(buf, false, { ... })  -- line 397
  state.win = win; state.buf = buf  -- lines 410-413
  -- Lines 440-463: augroup "VaultPreviewClose" with CursorMoved, BufLeave, WinClosed
  -- If augroup setup fails: win/buf exist but close_preview() handles gracefully
end

-- preview.lua (with multi-guard)
function M.preview(details, parent_buf)
  local target = target_mod.resolve(details, parent_buf)
  if not target then return end

  local mg = guard.multi()
  local ok, err = mg:run(function(g)
    local buf = state.buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "hide"
      g:add(function() cleanup.delete_buf(buf) end, "preview_buf")
    end

    local win = vim.api.nvim_open_win(buf, false, { ... })
    g:add(function() cleanup.close_win(win) end, "preview_win")

    setup_markdown_rendering()  -- Uses pcall(require, "render-markdown") internally
    setup_keymaps(buf, win)
    setup_autocmds(buf, win)

    -- All setup succeeded: transfer ownership, dismiss guards
    state.win = win
    state.buf = buf
    g:dismiss_all()
  end)

  if not ok then log.error("Preview open failed: %s", err) end
end
```

**Note:** In practice, `close_preview()` (lines 290-330) already handles partial state gracefully: pcall on augroup delete (line 308), `cleanup.close_win()` on window (line 314), explicit `keymap.del` loop on parent buf keymaps (lines 300-305). `setup_markdown_rendering()` (lines 80-93) uses pcall internally. The guard adds defense-in-depth for future changes rather than fixing a current bug.

### 2. Edit Float — Window + Augroup Lifecycle

`edit_float.lua` (lines 23-96) creates window, keymaps, and per-window augroup. The guard ensures cleanup if buffer load or keymap setup fails.

```lua
-- edit_float.lua (current — lines 23-96)
function M.edit_link()
  -- Lines 24-35: early validation (no link, note resolution)
  local buf = vim.fn.bufadd(path)   -- line 46
  vim.fn.bufload(buf)               -- line 47
  local win = vim.api.nvim_open_win(buf, true, { ... })  -- line 52 (focused)
  -- Lines 71-82: save_and_close keymaps (q, <Esc><Esc>, <C-s>)
  local augroup = vim.api.nvim_create_augroup("VaultEditFloat_" .. win, { clear = true })  -- line 85
  -- Lines 86-95: WinClosed autocmd (once=true), saves buf + deletes augroup
  -- If setup fails: win + augroup leak until manual close
end

-- edit_float.lua (with multi-guard)
function M.edit_link()
  local mg = guard.multi()
  local ok, err = mg:run(function(g)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)

    local win = vim.api.nvim_open_win(buf, true, { ... })
    g:add(function() cleanup.close_win(win) end, "edit_win")

    local augroup = vim.api.nvim_create_augroup("VaultEditFloat_" .. win, { clear = true })
    g:add(function() pcall(vim.api.nvim_del_augroup_by_id, augroup) end, "edit_augroup")

    setup_save_keymaps(buf, win)
    setup_close_autocmd(win, buf, augroup)

    g:dismiss_all()  -- Setup complete, autocmd owns cleanup now
  end)

  if not ok then log.error("Edit float failed: %s", err) end
end
```

### 3. Subscription Guard

Wraps `resource_cleanup.subscription_handle()` with scope-based auto-unsubscribe, preventing subscription leaks if a module's teardown is skipped.

```lua
-- guard.lua addition
function M.subscription(handle)
  return M.new(function()
    handle.unsubscribe()
  end, "subscription")
end

-- Usage in a module
function M.setup()
  local sub_handle = cleanup.subscription_handle(get_index, on_update)
  sub_handle.ensure()
  -- Store guard alongside handle
  state._sub_guard = guard.subscription(sub_handle)
end

function M.teardown()
  if state._sub_guard then
    state._sub_guard:release()  -- Guaranteed unsubscribe
  end
end
```

### 4. Temporary Namespace Guard

For modules that create temporary namespaces during rendering (e.g., `task_hierarchy.lua` where namespace clear is missing from both BufDelete callback at line 527 and teardown at line 569):

```lua
-- task_hierarchy.lua — current gap: no namespace clear in teardown
-- With guard:
function M.render(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)  -- Pre-clear (already exists, line 150)
  local ng = guard.new(function()
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end, "task_hierarchy_ns")

  local ok, err = pcall(do_render, bufnr, ns)
  if not ok then
    ng:release()  -- Clear partial extmarks on error
    log.warn("Task hierarchy render failed: %s", err)
    return
  end
  ng:dismiss()  -- Render succeeded, extmarks stay
end
```

---

## Configuration

```lua
-- config.lua additions
M.guards = {
  enabled = true,
  log_cleanup_errors = true,    -- Log cleanup failures (uses vault_log)
  warn_unreleased = false,      -- Warn if guard GC'd without release (debug mode)
}
```

---

## Debug Support: Unreleased Guard Detection

For development, detect guards that were neither released nor dismissed:

```lua
-- guard.lua (debug mode addition)
if config and config.guards and config.guards.warn_unreleased then
  -- Use __gc on a proxy userdata to detect abandoned guards
  local function make_leak_detector(guard_name)
    local ud = newproxy(true)
    getmetatable(ud).__gc = function()
      vim.schedule(function()
        vim.notify(
          string.format("Guard '%s' was never released or dismissed!", guard_name),
          vim.log.levels.WARN
        )
      end)
    end
    return ud
  end

  -- In M.new(), add leak detector to guard
  -- guard._detector = make_leak_detector(name)
  -- In Guard:release() and Guard:dismiss(), nil out _detector
end
```

---

## Validation

1. **Error path test:** Verify cleanup runs when body_fn errors:
   ```lua
   local cleaned = false
   guard.scope(
     function() return {} end,
     function() error("test error") end,
     function() cleaned = true end
   )
   assert(cleaned, "Cleanup should run on error")
   ```

2. **Multi-guard LIFO test:** Verify guards release in reverse order

3. **Idempotency test:** Call `release()` twice — should not error or double-clean

4. **Dismiss test:** Dismissed guard should not run cleanup

5. **Counter accuracy:** Verify counter always returns to zero after N operations with random errors

6. **Memory test:** Verify no resource leaks after 1000 guarded operations with 10% error rate

7. **Integration with resource_cleanup:** Verify guard.timer/buffer/window delegates correctly to existing utilities

---

## Expected Impact

### Priority Downgrade Rationale

The original document identified 5 cleanup gaps. Investigation shows:
- **4 of 5 are fully addressed** by existing infrastructure (resource_cleanup.lua, embed_state registry, process_semaphore, generation-based stale detection)
- **1 partially addressed** (task_hierarchy.lua namespace clear missing from teardown — minor)
- No active resource leak bugs were identified

The guard module provides **defense-in-depth** and **composability** rather than fixing active bugs.

### Remaining Value

| Benefit | Example |
|---------|---------|
| Multi-resource atomic cleanup | Preview float: if step 4 of 5 fails, undo steps 1-3 |
| Dismiss pattern | Transfer ownership without cleanup (matches Zed's Subscription.detach) |
| Self-documenting lifecycle | Guard at acquisition point makes resource scope visible |
| Future-proofing | New modules get cleanup for free by using guards |
| Composability | `mg:run()` + LIFO release handles complex acquisition sequences |

### Code Quality

- **Builds on resource_cleanup.lua:** Guards delegate to existing utilities — no duplication
- **Opt-in adoption:** Existing code works unchanged; guards adopted incrementally
- **Consistent with Zed patterns:** release/dismiss maps to Drop/detach

### Memory Impact

Guards primarily prevent **future** resource leaks as the codebase grows. Current infrastructure handles existing cases well. The main risk scenario is new modules or refactors that introduce multi-step acquisition without proper error-path cleanup.
