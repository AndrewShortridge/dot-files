# 16 — Subscription Lifecycle Management

## Priority: LOW (downgraded from MEDIUM — most issues already addressed)
## Inspired By: Zed's `Subscription`/`SubscriberSet` auto-cleanup in `gpui/src/subscription.rs`

## Current State (Already Implemented)

The vault index subscription system **already has robust lifecycle management**. The
original assessment was based on an earlier codebase version. Here is what exists today:

### vault_index.lua Subscribe/Unsubscribe

`subscribe()` (Lines 203-213):
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
```

`_notify_update()` (Lines 217-223):
```lua
--- Notify all subscribers.
---@param context? { changed_paths?: string[], deleted_paths?: string[] }
function M.VaultIndex:_notify_update(context)
  self._generation = self._generation + 1
  for _, fn in ipairs(self._subscribers) do
    local ok, err = pcall(fn, self._generation, context)
    if not ok then log.debug("subscriber notification failed: %s", err) end
  end
end
```

Field initialization: `self._subscribers = {}` (Line 161), `self._generation = 0` (Line 157).

Key features already present:
- **Unsubscribe closure returned** from `subscribe()` — callers store and invoke it
- **pcall wrapping** — subscriber errors logged, don't crash other subscribers
- **Generation + context** — callbacks receive `(generation, { changed_paths?, deleted_paths? })`

### Active Subscribers (Only 2 Modules)

**embed_sync.lua:**

`ensure_subscription()` (Lines 96-105):
```lua
--- Ensure the vault index subscription is active.
---@return boolean
function M.ensure_subscription()
  if state._subscribed then return true end  -- idempotency guard
  local vault_index_mod = package.loaded["andrew.vault.vault_index"]
  if not vault_index_mod then return false end
  local idx = vault_index_mod.current()
  if not idx then return false end
  state._unsubscribe_fn = idx:subscribe(M.on_index_update)
  state._subscribed = true
  return true
end
```

`unsubscribe()` (Lines 108-114):
```lua
--- Unsubscribe from vault index updates.
function M.unsubscribe()
  if state._unsubscribe_fn then
    state._unsubscribe_fn()
  end
  state._subscribed = false
  state._unsubscribe_fn = nil
end
```

`on_index_update()` (Lines 56-92) — sophisticated callback with inverted dependency index:
- Early-return guard: skips if `config.embed.sync.enabled` is false
- Without context: re-renders all active embed buffers (full rebuild path)
- With context: uses `_dep_to_bufs` inverted index for O(changed_paths) lookups
  instead of O(buffers × deps), only re-rendering buffers that depend on changed files
- `ensure_dep_index()` lazily builds the inverted dependency map
- `schedule_rerender()` debounces per-buffer re-renders via `config.embed.sync.debounce_ms`

State tracked in `embed_state.lua` (`_subscribed` Line 18, `_unsubscribe_fn` Line 19).
Subscription state is intentionally NOT part of the per-buffer cleanup registry — it's
module-global and persists across buffer changes, requiring explicit teardown via
`embed_sync.unsubscribe()`.
Cleanup called from `embed.teardown()` (Lines 809-814) via `event_dispatch.lua` on VimLeavePre:
```lua
function M.teardown()
  for bufnr in pairs(state.all_tracked_buffers()) do
    state.clear_buffer_state(bufnr, clear_state_cbs)
  end
  sync.unsubscribe()
end
```

**connections.lua:**

Module-level state (Lines 33-36):
```lua
local _pending_changed = {}   -- rel_path -> true (files changed since last compute)
local _pending_full_clear = false  -- true when subscriber context was nil (full rebuild)
local _unsubscribe = nil      -- unsubscribe function from vault_index:subscribe()
local _subscribed_idx = nil   -- vault index instance we subscribed to (detect vault switch)
```

`on_index_update()` (Lines 930-946) — handles both full rebuilds and incremental updates:
- Without context (nil): sets `_pending_full_clear = true` (full rebuild on next compute)
- With context: converts absolute paths to vault-relative and adds to `_pending_changed` set

`ensure_subscription()` (Lines 950-960):
```lua
local function ensure_subscription()
  local idx = vault_index.current()
  if not idx then return end
  if _unsubscribe and _subscribed_idx == idx then return end
  if _unsubscribe then
    _unsubscribe()  -- unsubscribe from old vault
  end
  _unsubscribe = idx:subscribe(on_index_update)
  _subscribed_idx = idx
end
```

`unsubscribe()` (Lines 963-969):
```lua
function unsubscribe()
  if _unsubscribe then
    _unsubscribe()
    _unsubscribe = nil
  end
  _subscribed_idx = nil
end
```

- **Vault switch detection** via `_subscribed_idx` instance comparison — re-subscribes when vault changes
- Called from `prepare_compute()` (Line 656), `M.setup()` (Line 1014), and indirectly via
  `M.invalidate_cache()` (Line 52) which calls `unsubscribe()`
- Subscription status checked in stats function (Lines 999-1010) via `subscribed = _unsubscribe ~= nil`
- `prepare_compute()` (Lines 654-698) uses `_pending_full_clear` and `_pending_changed` to decide
  between incremental vs full cache clear before graph computation; incremental path removes
  individual entries from `_note_data_cache` (Lines 666-671), full clear path calls
  `_note_data_cache:clear()` (Lines 663-665)

### Non-Subscriber Modules (Generation Polling)

These modules do NOT subscribe — they poll `vault_index._generation` at access time:

- **`gen_cache.lua`** — Core factory providing two cache patterns (zero external deps,
  uses `package.loaded` to fetch vault_index via `current_index()` helper at Lines 13-16):
  - `gen_cache(build_fn, opts)` (Lines 25-55) — single-value cache with `cached_gen`/`cached_key`/
    `cached_value` state (Lines 26-28), invalidates when `idx._generation` changes; optional
    `opts.key_fn` for composite keys (e.g., vault path switching)
  - `keyed_gen_cache(build_fn)` (Lines 63-90) — multi-key cache with `cached_gen`/`entries` state
    (Lines 64-65), clears ALL entries on generation change, lazy per-key rebuild on miss
  - Both return objects with `get()` and `invalidate()` methods; register with `engine.register_cache()`

- **`completion_base.lua`** — `cache_valid()` (Lines 200-213) checks `idx._generation ~= cached_index_gen`
  (tracked at Line 121); updates `cached_index_gen` after build (Line 265).
  Field cache memoization via `_field_cache` in `build_kv_single_pass()` (Lines 474-566) uses
  per-(vault_path, field_name, generation) cache keys (`_field_cache` declared Line 88, cleared
  in `M.invalidate_all()` Line 96). Cache registered with `engine.register_cache()`
  (Lines 100-112) with invalidate callback that clears all sources AND `_field_cache`.

- **`calendar.lua`** — Uses `gen_cache.gen_cache()` for deadline cache (Lines 123-127, with
  `key_fn` for vault path switching) and `gen_cache.keyed_gen_cache()` for per-month log cache
  (Lines 177-200, keyed by `"YYYY-MM"` format). Both registered with `engine.register_cache()`
  in `M.setup()` (Lines 675-688).

- **`query/init.lua`** — Uses `gen_cache.gen_cache()` for query index cache (Lines 17-30,
  with `key_fn` for vault path switching) with incremental update support via retained
  `_prev_index` (Line 17). Smart build strategy: if `_prev_index` exists and matches current
  vault, calls `update_incremental()`; otherwise creates new Index with `build_sync()`.
  Registered with `engine.register_cache()` (Lines 46-61); invalidation sets `_prev_index = nil`
  to force full rebuild. Manual rebuild via `M.rebuild_index()` (Lines 38-43).

- **`connections.lua`** — Manual generation tracking (NOT via gen_cache) for IDF cache
  (`_idf_gen` Line 25) and note data cache (`_note_data_gen` Line 30). Uses subscriber pattern
  for incremental tag updates based on file change notifications rather than full rebuilds.
  `get_vault_index()` helper (Lines 61-65) extracts `_generation` for manual cache validation.

### Existing Cleanup Infrastructure

**resource_cleanup.lua** — Centralized utility module (8 exports):
- `close_timer(timer)` (Lines 9-17) — stops/closes with pcall wrapping, handles nil/already-closing
- `close_timer_in(dict, key)` (Lines 22-27) — dict-based timer cleanup + removal
- `debounce(existing, delay_ms, callback)` (Lines 35-41) — timer debounce with old timer cleanup
- `repeating(existing, delay_ms, repeat_ms, callback)` (Lines 51-57) — repeating timer with initial delay
- `on_buf_delete(group, callback, opts)` (Lines 64-70) — BufDelete + BufWipeout pair helper
- `close_win(win)` (Lines 74-78) — close window if valid (pcall-wrapped)
- `delete_buf(buf)` (Lines 82-86) — delete buffer if valid (force=true, pcall-wrapped)
- `close_win_buf(win, buf)` (Lines 91-94) — window + buffer cleanup (calls close_win then delete_buf)

**event_dispatch.lua** — Centralized autocmd dispatcher:
- Single `VaultEventDispatch` augroup (Line 58) replaces 14+ independent autocmds
- Dispatches: BufEnter (coalesced, Lines 104-111), TextChanged/TextChangedI/InsertLeave
  (Lines 121-149), FileType markdown (Lines 157-183), BufWritePost (Lines 190-203)
- VimLeavePre teardown chain (Lines 211-228) orchestrates 6 modules in order:
  1. `engine.teardown()` (Line 215) — URL validation persist + log close
  2. `highlight_coordinator.teardown()` (Line 218) — highlight render timers
  3. `task_hierarchy.teardown()` (Line 219) — task hierarchy timers
  4. `autosave.teardown()` (Line 220) — autosave cleanup
  5. `embed.teardown()` (Line 223) — embed state & sync cleanup
  6. `callout_folds.teardown()` (Line 226) — persistent state saves
- `M.close()` (Lines 231-236) — closes BufEnter coalescer on shutdown

**embed_state.lua** — State registry pattern:
- `register_state(dict, cleanup_fn)` (Lines 27-29) for unified GC
- 7 state dicts registered (Lines 43-66): `embeds_visible`, `image_placements` (with
  `embed_images.clear_image_placements` cleanup), `_embed_deps`, `_sync_timers` (timer cleanup),
  `_image_retry_fired`, `_embed_descriptors` (async timer cleanup), `_scroll_timers` (timer cleanup)
- `clear_buffer_state(bufnr, opts)` (Lines 90-109) iterates registry and invokes cleanup functions,
  then calls `notify_dep_index_dirty()` (Line 108)
- `gc_stale_buffers()` (Line 126) — removes stale entries, calls `notify_dep_index_dirty()` if deps changed
- `notify_dep_index_dirty()` (Lines 35-40) signals embed_sync via package.loaded (avoids circular require)

**highlight_coordinator.lua** — Unified BufDelete cleanup:
- `setup_buf_cleanup(group, ns, cache_tables)` (Lines 124-131) clears extmarks + cache entries
- `teardown()` (Lines 321-325) closes all debounced timers on VimLeavePre

## Remaining Gaps

The following issues from the original assessment are still relevant:

### 1. No Weak References for Closure-Captured State
Lua has no built-in weak reference for function closures. While the current 2 subscribers
are well-managed, closures still capture upvalues that prevent GC of module state.

### 2. No Buffer-Scoped Subscriptions
If a future module needs per-buffer subscriptions to the vault index (e.g., a buffer-local
embed watcher), there's no built-in pattern for auto-unsubscribing on BufDelete.

### 3. No Subscriber Introspection
There's no way to query how many subscribers are active or debug subscription state
(unlike `resource_cleanup.lua` which has structured cleanup).

## Proposed Enhancements (Scoped Down)

Given that the core subscribe/unsubscribe lifecycle is already solid, the proposal is
reduced to targeted additions rather than a full subscription manager replacement.

### 1. Add Weak Callback Utility

For modules that want closure-captured state to be GC-eligible:

```lua
--- Create a weak-reference wrapper for a module's state.
--- The callback becomes a no-op when the referenced state is GC'd.
---
---@param state table The module state to weakly reference
---@param callback function(state, ...) Called with state if still alive
---@return function(...) Wrapped callback
local function weak_callback(state, callback)
  local weak = setmetatable({ ref = state }, { __mode = "v" })

  return function(...)
    local s = weak.ref
    if s then
      callback(s, ...)
    end
    -- If s is nil, state was GC'd — callback is a no-op
  end
end
```

This could live in `resource_cleanup.lua` alongside the existing cleanup utilities,
rather than requiring a new module.

### 2. Add Subscriber Count/Debug to VaultIndex

Small addition to `vault_index.lua` for introspection:

```lua
--- Get count of active subscribers.
---@return number
function M.VaultIndex:subscriber_count()
  return #self._subscribers
end
```

Integrate with existing `:VaultIndexStatus` command output.

## Zed Reference (Actual Implementation)

### Subscription struct (`crates/gpui/src/subscription.rs:158-203`) ✓ Verified

```rust
/// A handle to a subscription created by GPUI. When dropped, the subscription
/// is cancelled and the callback will no longer be invoked.
#[must_use]
pub struct Subscription {                                    // Lines 158-160
    unsubscribe: Option<Box<dyn FnOnce() + 'static>>,
}

impl Subscription {
    pub fn new(unsubscribe: impl 'static + FnOnce()) -> Self {  // Lines 166-170
        Self { unsubscribe: Some(Box::new(unsubscribe)) }
    }

    /// Detaches the subscription — callback persists until entity drops
    pub fn detach(mut self) {                                // Lines 175-177
        self.unsubscribe.take();
    }

    /// Joins two subscriptions into one handle
    pub fn join(mut a: Self, mut b: Self) -> Self {          // Lines 181-194
        let a_unsub = a.unsubscribe.take();
        let b_unsub = b.unsubscribe.take();
        Self {
            unsubscribe: Some(Box::new(move || {
                if let Some(f) = a_unsub { f(); }
                if let Some(f) = b_unsub { f(); }
            })),
        }
    }
}

impl Drop for Subscription {                                // Lines 197-203
    fn drop(&mut self) {
        if let Some(unsubscribe) = self.unsubscribe.take() {
            unsubscribe();
        }
    }
}
```

Key design: Rust's `Drop` trait auto-invokes unsubscribe when Subscription goes out of scope.
The Lua equivalent is the returned closure pattern already used in `vault_index.lua`.

### SubscriberSet (`crates/gpui/src/subscription.rs:10-153`) ✓ Verified

Internal collection managing subscriber storage (`Rc<RefCell<SubscriberSetState>>`),
with internal `SubscriberSetState` (Lines 20-24) holding `subscribers` BTreeMap,
`dropped_subscribers` BTreeSet, and `next_subscriber_id` counter.

Internal `Subscriber` struct (Lines 26-29) holds `active: Rc<Cell<bool>>` and `callback`:
```rust
struct Subscriber<Callback> {
    active: Rc<Cell<bool>>,
    callback: Callback,
}
```

Methods:
- `new()` (Lines 36-42) — creates empty subscriber set
- `insert()` (Lines 48-93) — returns `(Subscription, impl FnOnce() + use<EmitterKey, Callback>)` — subscriptions start **inactive**
  by default; two-phase activation prevents notifications during setup
- `remove()` (Lines 95-112) — extracts all callbacks for an entity (only **active** subscribers);
  used in entity cleanup
- `retain()` (Lines 116-153) — safely iterates during mutations — handles reentrant subscribe/unsubscribe
  via deferred `dropped_subscribers` set; takes subscribers out during iteration, merges new ones back

### WeakEntity (`crates/gpui/src/app/entity_map.rs:653-690`) ✓ Verified (upgrade at 685-690)

```rust
#[derive(Deref, DerefMut)]
pub struct WeakEntity<T> {                              // Lines 653-660
    #[deref]
    #[deref_mut]
    any_entity: AnyWeakEntity,
    entity_type: PhantomData<T>,
}

impl<T: 'static> WeakEntity<T> {
    pub fn upgrade(&self) -> Option<Entity<T>> {        // Lines 685-690
        Some(Entity {
            any_entity: self.any_entity.upgrade()?,
            entity_type: self.entity_type,
        })
    }
}
```

`AnyWeakEntity` (Lines 514-520) holds `Weak<RwLock<EntityRefCounts>>`:
```rust
pub struct AnyWeakEntity {
    pub(crate) entity_id: EntityId,
    entity_type: TypeId,
    entity_ref_counts: Weak<RwLock<EntityRefCounts>>,
}
```

`EntityRefCounts` (Lines 63-68) uses `SlotMap<EntityId, AtomicUsize>` for lock-free per-entity
ref counting, with `dropped_entity_ids: Vec<EntityId>` tracking and optional
`leak_detector: LeakDetector` (conditional on test/leak-detection feature).

`AnyWeakEntity::upgrade()` (Lines 539-563) uses `atomic_incr_if_not_zero` CAS loop
(`gpui/src/util.rs:88-99`, SeqCst ordering, `compare_exchange_weak`) for safe concurrent
upgrade attempts. Returns `None` if entity ref count is 0 or entity_id is in `dropped_entity_ids`.

### Context-Level Subscriptions (`crates/gpui/src/app/context.rs:52-165+`) ✓ Verified

Core subscription methods (Lines 52-165):

```rust
pub fn observe<W>(&mut self, entity: &Entity<W>,       // Lines 52-70
    mut on_notify: impl FnMut(&mut T, Entity<W>, &mut Context<T>) + 'static,
) -> Subscription {
    let this = self.weak_entity();  // capture weak ref to self
    self.app.observe_internal(entity, move |e, cx| {
        if let Some(this) = this.upgrade() {
            this.update(cx, |this, cx| on_notify(this, e, cx));
            true   // keep subscription
        } else {
            false  // entity gone, remove subscription
        }
    })
}
```

Additional core methods in Lines 52-165:
- `subscribe()` (Lines 73-92) — event subscription with WeakEntity capture (Line 83)
- `subscribe_self()` (Lines 95-107) — self-event subscription
- `on_release()` (Lines 110-123) — release callback
- `observe_release()` (Lines 126-148) — observe another entity's release
- `observe_global()` (Lines 151-165) — global event observation, captures `handle = weak_entity()`

Window-scoped subscription methods (Lines 283-656, 15+ methods total):
- `observe_in()` (Lines 283-316), `subscribe_in()` (Lines 321-357)
- `on_release_in()` (Lines 363-370), `observe_release_in()` (Lines 373-392)
- `observe_window_bounds()` (Lines 395-410), `observe_window_activation()` (Lines 413-428)
- `observe_window_appearance()` (Lines 431-446), `observe_keystrokes()` (Lines 451-476)
- `observe_pending_input()` (Lines 479-494)
- `on_focus()` (Lines 498-519), `on_focus_in()` (Lines 524-543)
- `on_blur()` (Lines 547-568), `on_focus_lost()` (Lines 574-589), `on_focus_out()` (Lines 593-620)
- `observe_global_in()` (Lines 637-656)

`weak_entity()` defined at Lines 46-48: `pub fn weak_entity(&self) -> WeakEntity<T>`

All methods follow the same pattern: capture `self.weak_entity()` → upgrade on each callback
→ return `true` to keep or `false` to auto-remove subscription.
Two return style variants: explicit `true`/`false` (e.g., observe, subscribe) and `.is_ok()`
(e.g., observe_global, observe_window_bounds, focus methods).
Exception: `subscribe_self()` uses strong `self.entity()` capture (safe because callback is self).
Window-scoped methods additionally capture `downgrade()` on observed entities and use
`.upgrade().zip()` to safely pair both entities before accessing.
The Lua equivalent is the `weak_callback` utility proposed above.

### Entity Cleanup (`crates/gpui/src/app.rs:935-950`) ✓ Verified

```rust
fn release_dropped_entities(&mut self) {       // Line 935
    loop {
        let dropped = self.entities.take_dropped();  // Line 937
        if dropped.is_empty() { break; }
        for (entity_id, mut entity) in dropped {
            self.observers.remove(&entity_id);           // Line 943 — bulk remove
            self.event_listeners.remove(&entity_id);     // Line 944 — bulk remove
            for release_callback in self.release_listeners.remove(&entity_id) {  // Line 945
                release_callback(entity.as_mut(), self);
            }
        }
    }
}
```

App struct SubscriberSet fields (Lines 260-280):
- `new_entity_observers: SubscriberSet<TypeId, NewEntityListener>` (Line 260)
- `observers: SubscriberSet<EntityId, Handler>` (Line 271, init Line 342)
- `event_listeners: SubscriberSet<EntityId, (TypeId, Listener)>` (Line 273, init Line 345)
- `keystroke_observers: SubscriberSet<(), KeystrokeObserver>` (Line 274)
- `keystroke_interceptors: SubscriberSet<(), KeystrokeObserver>` (Line 275)
- `keyboard_layout_observers: SubscriberSet<(), Handler>` (Line 276)
- `release_listeners: SubscriberSet<EntityId, ReleaseListener>` (Line 277, init Line 346)
- `global_observers: SubscriberSet<TypeId, Handler>` (Line 278)
- `quit_observers: SubscriberSet<(), QuitHandler>` (Line 279)
- `window_closed_observers: SubscriberSet<(), WindowClosedHandler>` (Line 280)

Type aliases (Lines 231-238):
- `Handler = Box<dyn FnMut(&mut App) -> bool + 'static>` (Line 231)
- `Listener = Box<dyn FnMut(&dyn Any, &mut App) -> bool + 'static>` (Line 232)
- `KeystrokeObserver = Box<dyn FnMut(&KeystrokeEvent, &mut Window, &mut App) -> bool + 'static>` (Lines 233-234)
- `QuitHandler = Box<dyn FnOnce(&mut App) -> LocalBoxFuture<'static, ()> + 'static>` (Line 235)
- `WindowClosedHandler = Box<dyn FnMut(&mut App)>` (Line 236)
- `ReleaseListener = Box<dyn FnOnce(&mut dyn Any, &mut App) + 'static>` (Line 237)
- `NewEntityListener = Box<dyn FnMut(AnyEntity, &mut Option<&mut Window>, &mut App) + 'static>` (Line 238)

Called as the **first step** of `flush_effects()` (Lines 875-930) at Line 877,
before processing any pending effects. All observers/listeners for a dropped entity
are removed in bulk. This is analogous to the vault index clearing `_subscribers`
when a vault instance is replaced (handled by connections.lua's vault switch detection).

## Expected Impact (Revised)

| Issue | Current State | Proposed Enhancement |
|-------|--------------|---------------------|
| Duplicate subscriptions (dev reload) | **Already handled** — idempotency guards in both subscribers | N/A |
| Unsubscribe mechanism | **Already exists** — returned closure from subscribe() | N/A |
| Error isolation | **Already exists** — pcall wrapping in _notify_update | N/A |
| VimLeavePre cleanup | **Already exists** — event_dispatch teardown chain | N/A |
| Vault switch handling | **Already exists** — connections.lua _subscribed_idx check | N/A |
| Buffer-scoped subscribers | Not yet needed | Can be added if needed in the future |
| Weak closure references | No weak tables used | `weak_callback` utility |
| Subscriber introspection | Not available | `subscriber_count()` + :VaultIndexStatus |

**Memory savings:** Minimal — only 2 well-managed subscribers exist. The weak_callback
utility would prevent theoretical leaks if more subscribers are added in the future.

**Priority justification:** Downgraded to LOW because the core lifecycle management
(subscribe/unsubscribe/idempotency/error handling/teardown) is already in place.
The remaining enhancements are defensive additions for future extensibility.

## Testing Strategy

1. `weak_callback()` — create weak callback, nil the state, force GC, verify no-op
2. `subscriber_count()` — verify count matches expected (currently 2 after full init)
3. Existing regression: reload module, verify no duplicate subscribers (already works)

## Dependencies

- No new modules needed — enhancements fit into existing `vault_index.lua` and `resource_cleanup.lua`
- Only 2 active subscribers to consider: embed_sync.lua, connections.lua
- Other modules (completion, calendar, query) use generation polling — unaffected

## Risk Assessment

- **Very low risk:** All enhancements are additive, existing API unchanged
- **No migration needed:** Current subscribe/unsubscribe pattern continues to work
- **weak_callback:** Pure Lua weak table — well-understood semantics
