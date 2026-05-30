# 43. Watch-Style Event Coalescing

## Priority: MEDIUM
## Inspired By: Zed's custom `watch` crate (`crates/watch/src/watch.rs`) and legacy `postage::watch` channels across 26+ files including `git_ui/src/project_diff.rs`, `project/src/git_store.rs`, `agent_ui/src/inline_assistant.rs`, `project/src/lsp_store.rs`, `git_ui/src/file_diff_view.rs`, `call/src/call_impl/mod.rs`, and others

## Problem

The vault uses `resource_cleanup.debounce()` extensively (13 call sites across highlight_coordinator,
engine_watcher, sidebar, embed, embed_sync, autosave, vault_index, url_validate, task_hierarchy,
viewport, completion_base, vault_index_collisions, and init.lua) to batch rapid events. Debounce works by delaying execution
until N ms after the *last* event -- but it has two fundamental limitations:

1. **Added latency**: Debounce always adds its full delay before firing. A 200ms debounce means the
   user waits 200ms after their last keystroke before seeing highlight updates, even if the system
   could process the update in <1ms. This latency is the *price* of coalescing.

2. **No cross-event collapse**: Debounce timers are per-source. If 5 different buffers trigger
   `BufWritePost` within 100ms, the debounced handler fires once but may still iterate over each
   event individually. There is no mechanism to say "something changed -- re-evaluate all state"
   without tracking which specific things changed.

### Concrete Examples

**highlight_coordinator.lua** -- `schedule()` uses a per-buffer debounce timer (30ms for full,
200ms for partial/viewport). If `TextChanged` fires 8 times in 50ms (bulk paste), the debounce
correctly collapses them into one `run_all()` call. But that single call happens 200ms later. With
watch-style coalescing, it would fire on the *next tick* (~0ms delay) after the last event in the
current event loop iteration.

**engine_watcher.lua** -- The filesystem watcher debounces at `config.index.watch_debounce_ms`
(500ms). A `git checkout` that touches 50 .md files produces 50 filesystem events accumulated into
`_pending_changed_files`. The debounce collapses them, but the `update_files_batch()` call doesn't
start until 500ms after the last file is written. With coalescing, the update would start on the
next tick after the burst ends.

**sidebar.lua** -- `schedule_render()` debounces at `config.sidebar.update_debounce_ms` (150ms).
Rapid buffer switches (e.g., `:bnext` held down) each trigger a sidebar render. The debounce helps,
but the sidebar is always 150ms behind the current buffer.

**embed_sync.lua** -- Cross-file change events use `config.embed.sync.debounce_ms` (300ms) for
index-triggered re-renders and `config.embed.sync.self_debounce_ms` (500ms) for same-file
TextChanged updates. Multiple embed invalidation signals (e.g., saving two transcluded notes in
rapid succession) each reset the timer, adding cumulative delay.

### All Current Debounce Call Sites

| # | Module | Delay | Trigger | Callback |
|---|--------|-------|---------|----------|
| 1 | highlight_coordinator.lua | 30ms (full) / 200ms (partial) | TextChanged, BufEnter, BufWritePost, VaultCacheInvalidate | `M.run_all(bufnr, opts)` |
| 2 | sidebar.lua | 150ms (`config.sidebar.update_debounce_ms`) | BufEnter, VaultCacheInvalidate | `M.render()` |
| 3 | embed.lua | 80ms (`config.embed.lazy_scroll_debounce_ms`) | WinScrolled | Render newly visible embeds |
| 4 | embed_sync.lua | 300ms / 500ms (`config.embed.sync.{debounce_ms,self_debounce_ms}`) | Vault index update, TextChanged | `embed.render_embeds_buf(bufnr)` |
| 5 | engine_watcher.lua | 500ms (`config.index.watch_debounce_ms`) | Filesystem events | `idx:update_files_batch(paths)` |
| 6 | autosave.lua | 1000ms (`config.autosave.debounce_ms`) | TextChanged, InsertLeave, BufLeave | `save_buffer(bufnr)` |
| 7 | task_hierarchy.lua | 500ms (`config.hierarchy.debounce_ms`) | Task completion state change | `M.render_completion_vtext(bufnr)` |
| 8 | vault_index.lua | 5000-10000ms (`config.index.persist_debounce_ms` + adaptive `persist_min_interval_ms`) | Index invalidation/rebuild (WAL overflow or full rebuild) | `self:_persist()` via `_schedule_full_persist()` |
| 9 | url_validate.lua | 5000ms (`config.url_validation.cache_persist_debounce_ms`) | Cache dirty | `M._persist()` |
| 10 | viewport.lua | 400ms (`config.viewport.prefetch_debounce_ms`) | WinScrolled, resize | Prefetch callback |
| 11 | init.lua | 200ms | FocusGained | `engine.invalidate_caches()` |
| 12 | vault_index_collisions.lua | 5000ms (`config.index.collision_notify_ms`) | Collision detection | Auto-dismiss popup |
| 13 | completion_base.lua (legacy + coroutine) | 250ms default (`config.completion.debounce_ms`) | Completion source build | `opts.build()` (legacy, line 418) / coroutine build (line 448) |

### Existing Coalescing Primitives

The vault already has two coalescing primitives beyond debounce:

1. **`event_coalescer.lua`** (lines 1-115) -- Batches autocmd events by buffer into a pending table,
   flushes after `delay_ms` (default 16ms, configured via `config.events.buf_enter_coalesce_ms`)
   or when `max_batch` (default 32) is reached. Supports adaptive delay for rapid buffer switching
   (`config.events.rapid_switch_threshold_ms` = 50ms, `config.events.rapid_switch_delay_ms` = 200ms).
   **Key difference from watch**: it accumulates per-buffer event data (not just a dirty flag) and
   delivers the entire batch to the handler. It reuses a single timer (not create/close per event
   like debounce).

2. **`request_coalescer.lua`** (lines 1-439) -- Deduplicates concurrent identical operations
   (shared-future pattern). Multiple callers requesting the same key join a single in-flight
   execution. 5 named pools with independent config: url_validate (`max_waiters=10, timeout=30s,
   linger=200ms`), embed (`10/30s/100ms`), search (`50/30s/100ms`), index_rebuild (`50/60s/50ms`),
   connections (`20/30s/100ms`). Tracks statistics: `total_operations`, `total_coalesced`,
   `coalesce_rate`. **Different concern**: operates at the operation level (dedup), not the signal
   level (collapse).

### The Missing Primitive

Debounce answers: "Wait until things calm down, then act."
Event coalescer answers: "Batch events by buffer, flush after delay or batch-size threshold."
Request coalescer answers: "Deduplicate identical concurrent operations."
Watch coalescing answers: "Act as soon as possible, but only once per event loop tick."

The vault has the first three primitives but not the fourth. Many of the 150-500ms debounce delays
exist not because the operation is expensive (it isn't -- highlight_coordinator processes all
updaters in <5ms), but because there was no way to say "next tick" without either `vim.schedule`
(which doesn't coalesce) or `vim.defer_fn(fn, 0)` (which does coalesce but requires manual
dirty-flag management at each call site).

## Zed Inspiration

Zed uses two watch channel implementations: a **custom `watch` crate** (`crates/watch/src/watch.rs`)
for newer code, and the legacy **`postage::watch`** for older modules. The custom crate is simpler
and better suited to Zed's async patterns.

### Zed's Custom Watch Crate (`crates/watch/src/watch.rs`)

The custom implementation uses version-based coalescing:

```rust
// Core state (line 41)
struct State<T> {
    value: T,
    wakers: BTreeMap<WakerId, Waker>,   // Track waiting receivers
    next_waker_id: WakerId,
    version: usize,                      // Incremented on each send
    closed: bool,
}

// Create a channel (line 13)
pub fn channel<T>(value: T) -> (Sender<T>, Receiver<T>)
// NOTE: No channel_with() -- that API exists only in postage::watch

// Sender API
impl<T> Sender<T> {
    pub fn send(&mut self, value: T) -> Result<(), NoReceiverError>
    pub fn receiver(&self) -> Receiver<T>  // Create new receiver
}

// Receiver API
impl<T> Receiver<T> {
    pub fn borrow(&mut self) -> MappedRwLockReadGuard<'_, T>  // Read current value, marks as seen
    pub fn changed(&mut self) -> impl Future<Output = Result<(), NoSenderError>>
}
impl<T: Clone> Receiver<T> {
    pub async fn recv(&mut self) -> Result<T, NoSenderError>  // changed() + borrow().clone()
}
```

**Coalescing mechanism**: Each `send()` increments `state.version` via `wrapping_add(1)` (line 71)
and wakes all registered wakers from the BTreeMap (lines 75-77). Each receiver tracks its last-seen
version. When `changed()` is polled, if `version != receiver.version` (line 112), it immediately
resolves. If versions match, it registers a waker via `RwLockUpgradableReadGuard` (line 121) and
returns `Pending`. Multiple sends between polls produce a single wakeup because only the version
delta matters, not the count.

**Thread safety**: Uses `Arc<RwLock<State<T>>>` with `parking_lot` locks. Sender has an
`Arc::get_mut` optimization (lines 63-67) -- returns `NoReceiverError` immediately when no receivers
exist. Sender drop sets `closed = true` and wakes all receivers (they get `NoSenderError`). Changed
future drop unregisters waker from BTreeMap (lines 141-150).

### inline_assistant.rs -- Inline edit highlight refresh (custom watch crate)

```rust
// crates/agent_ui/src/inline_assistant.rs
struct EditorInlineAssists {
    assist_ids: Vec<InlineAssistId>,
    highlight_updates: watch::Sender<()>,  // Custom Zed watch crate (line 1554)
    _update_highlights: Task<Result<()>>,
    _subscriptions: Vec<gpui::Subscription>,
}

// Channel creation (line 1566):
let (highlight_updates_tx, mut highlight_updates_rx) = watch::channel(());

// Producer: send() directly (not borrow_mut()):
editor_assists.highlight_updates.send(()).ok();  // lines 1043, 1130, 1726

// Consumer: changed().await (not next()):
_update_highlights: cx.spawn({
    let editor = editor.downgrade();
    async move |cx| {
        while let Ok(()) = highlight_updates_rx.changed().await {
            let editor = editor.upgrade().context("editor was dropped")?;
            cx.update_global(|assistant: &mut InlineAssistant, cx| {
                assistant.update_editor_highlights(&editor, cx);
            })?;
        }
        Ok(())
    }
}),
```

Multiple inline assists modified in rapid succession -> single `update_editor_highlights()` call.

### project_diff.rs -- Buffer diff recalculation (legacy postage::watch)

```rust
// crates/git_ui/src/project_diff.rs
pub struct ProjectDiff {
    update_needed: postage::watch::Sender<()>,  // line 61
    _task: Task<Result<()>>,
    // ...
}

// Channel creation (line 204):
let (mut send, recv) = postage::watch::channel::<()>();

// Producer: borrow_mut() pattern (lines 181, 197, 210):
*this.update_needed.borrow_mut() = ();  // git store event
*this.update_needed.borrow_mut() = ();  // settings change
*send.borrow_mut() = ();                // initial kick

// Consumer: next().await (lines 511-533):
while let Some(_) = recv.next().await {
    let buffers_to_load = this.update(cx, |this, cx| this.load_buffers(cx))?;
    for buffer_to_load in buffers_to_load {
        if let Some(buffer) = buffer_to_load.await.log_err() {
            cx.update(|window, cx| {
                this.update(cx, |this, cx| this.register_buffer(buffer, window, cx)).ok();
            })?;
        }
    }
    this.update(cx, |this, cx| {
        this.pending_scroll.take();
        cx.notify();
    })?;
}
```

Triggered by `GitStoreEvent::ActiveRepositoryChanged`, `RepositoryUpdated`, `ConflictsUpdated`,
and settings changes. Multiple git events coalesce into a single `load_buffers()` call.

### git_store.rs -- Diff recalculation state (legacy postage::watch)

```rust
// crates/project/src/git_store.rs
struct BufferGitState {
    recalculating_tx: postage::watch::Sender<bool>,  // line 99
    // ...
}

// Channel creation (line 2204):
recalculating_tx: postage::watch::channel_with(false).0,

// Producer: borrow_mut() for state transitions:
*self.recalculating_tx.borrow_mut() = true;   // start (line 2375)
*this.recalculating_tx.borrow_mut() = false;  // cancel (line 2444)
*this.recalculating_tx.borrow_mut() = false;  // complete (line 2501)

// Consumer: subscribe + recv loop (lines 2310-2319):
pub fn wait_for_recalculation(&mut self) -> Option<impl Future<Output = ()>> {
    if *self.recalculating_tx.borrow() {
        let mut rx = self.recalculating_tx.subscribe();
        return Some(async move {
            loop {
                let is_recalculating = rx.recv().await;
                if is_recalculating != Some(true) { break; }
            }
        });
    } else { None }
}
```

Here the watch channel carries meaningful state (`bool`) rather than just a dirty signal (`()`).
Multiple recalculation triggers are coalesced by the boolean: if already recalculating, subsequent
triggers are no-ops until completion.

### Other Zed Watch Usage (26+ files)

**Custom watch crate (`crates/watch`):**
- **`language/src/buffer.rs`** (line 946): `watch::channel(ParseStatus::Idle)` tracks parser state
- **`git_ui/src/file_diff_view.rs`** (line 106): `watch::channel(())` coalesces buffer change events
- **`git_ui/src/text_diff_view.rs`** (line 169): `watch::channel(())` coalesces buffer change events
- **`call/src/call_impl/room.rs`** (line 130): `watch::channel(())` for room update completion
- **`project/src/lsp_store.rs`** (lines 3550, 3759, 3848): `_maintain_workspace_config` channels for workspace config maintenance
- **`assistant_tool/src/action_log.rs`** (line 275): `watch::channel(())` for git diff updates, used in `select_biased!` with `.fuse()` pattern
- **`assistant_tools/src/edit_agent.rs`** (line 458): `watch::channel()` for `Option<Range<usize>>` edit range tracking
- **`eval/src/eval.rs`** (line 389): `watch::channel(None)` for settings change observation
- **`channel/src/channel_store.rs`** (line 224): `watch::channel()` for `bool` channels_loaded status
- **`zed/src/main.rs`** (line 429): `watch::channel()` for `Option<NodeBinaryOptions>` dynamic config
- **`node_runtime/src/node_runtime.rs`** (line 63): receiver for `Option<NodeBinaryOptions>`

**Legacy postage::watch (note: `channel_with()` is postage-only, not custom watch):**
- **`client/src/client.rs`** (line 414): `postage::watch::channel_with(Status::SignedOut)` tracks connection status
- **`worktree/src/worktree.rs`** (lines 558, 593): `postage::watch::channel_with(true)` tracks directory scan state
- **`project/src/image_store.rs`** (line 375): `postage::watch::channel()` for async image load coordination
- **`agent/src/thread.rs`** (lines 366, 452): `postage::watch::channel()` for `DetailedSummaryState`
- **`call/src/call_impl/mod.rs`** (line 99): `postage::watch::channel()` for `Option<IncomingCall>` state (aliased as `use postage::watch`)
- **`project/src/lsp_store.rs`** (line 7412): `postage::watch::channel()` for settings change coalescing (mixed with custom watch in same file)
- **`supermaven/src/supermaven.rs`** (line 140): `postage::watch::channel()` for update notifications
- **`agent_servers/src/claude.rs`** (line 98): `watch::channel()` for thread state tracking
- **`zeta/src/zeta.rs`** (line 1178): `postage::watch::channel_with::<bool>(false)` for open source detection
- **`language/src/language_registry.rs`** (line 277): `postage::watch::channel()` for LSP adapter subscription

### Additional Zed Coalescing Patterns

- **`DebouncedDelay`** (`crates/project/src/debounced_delay.rs`, lines 1-54): Custom debounce using
  `oneshot::channel` for cancellation + `futures::select_biased!` to race timer vs cancel. Chains
  `previous_task.await` for sequential execution. `fire_new()` cancels previous via `channel.send(())`
- **`EventCoalescer`** (`crates/client/src/telemetry/event_coalescer.rs`, lines 1-67): Telemetry event
  batching with 20s `COALESCE_TIMEOUT` + environment grouping. Single events get 1ms simulated duration.
  Returns `Option<(start, end, environment)>` -- `Some` when coalescing ends, `None` while batching
- **Scroll coalescing** (`crates/editor/src/element.rs`, line 6733): `delta.coalesce(event.delta)`
  accumulates scroll wheel events within a frame. Implementation in `gpui/src/interactive.rs`
  (lines 313-330): same-direction deltas are summed, opposite-direction deltas are replaced
- **Inlay hint debounce** (`crates/editor/src/inlay_hint_cache.rs`, lines 40-45, 408-418): Separate
  debounce durations for edit (`invalidate_debounce`) vs scroll (`append_debounce`) invalidation,
  settings-driven via `edit_debounce_ms` / `scroll_debounce_ms`. 0ms disables debounce (returns `None`)
- **`OneAtATime`** (`crates/call/src/call_impl/mod.rs`, lines 35-64): Prevents concurrent task
  execution -- new spawned task cancels previous one via `oneshot::Sender`. Used for join debouncing
- **`select_biased!` coalescing** (`crates/assistant_tool/src/action_log.rs`, lines 295-310):
  Multiple watch channels raced via `select_biased!` with `.fuse()` -- naturally coalesces when
  multiple sources fire between loop iterations
- **`try_recv()` draining** (`crates/supermaven/src/supermaven.rs` line 141, `project/src/lsp_store.rs`
  line 7413): `postage::stream::Stream::try_recv(&mut rx)` drains initial watch value to avoid
  spurious wakeups on channel creation
- **Stream batching** (`crates/semantic_index/src/embedding_index.rs`, lines 285-318): Uses
  `futures_batch::ChunksTimeoutStreamExt` to group embeddings into provider-sized batches with timeout

### The Pattern

Zed's custom watch crate holds **only the latest value** with a **version counter**. Multiple rapid
sends increment the version but only produce a single receiver wakeup. The key API difference from
the legacy postage crate:

| Aspect | Postage (`postage::watch`) | Custom (`crates/watch`) |
|--------|---------------------------|------------------------|
| Send | `*tx.borrow_mut() = value` | `tx.send(value)` |
| Receive | `rx.next().await` / `rx.recv().await` | `rx.changed().await` / `rx.recv().await` |
| New receiver | `tx.subscribe()` | `tx.receiver()` |
| Read current | `tx.borrow()` / `rx.borrow()` | `rx.borrow()` (marks as seen) |
| Init with value | `channel_with(value)` | Not available (use `channel(value)`) |
| Coalescing | Overwrite stored value | Version increment (`wrapping_add`) + waker notification |
| No-receiver opt | N/A | `Arc::get_mut` returns `NoReceiverError` immediately |

Watch coalescing provides: **minimal latency + maximal collapse**. The receiver fires on the next
async tick, not after an arbitrary delay.

## Proposed Design for Vault

### Core Module: `lua/andrew/vault/watch_channel.lua`

```lua
--- Watch-style coalescing channel.
--- Holds only the latest value; multiple sends between event loop ticks
--- collapse into a single subscriber notification.
---
--- Unlike debounce (which adds N ms of latency), watch coalescing fires
--- on the NEXT event loop tick after any send(). Multiple rapid sends
--- within the same tick produce exactly one callback invocation.
---
--- Unlike event_coalescer.lua (which batches per-buffer event data and
--- flushes after a configurable delay/batch-size), watch_channel is a
--- lower-level primitive: it carries a single latest value and fires on
--- the next tick with zero delay.
---
--- Inspired by Zed's custom watch crate (crates/watch/src/watch.rs).

local M = {}

---@class WatchChannel
---@field _value any           The latest value
---@field _dirty boolean       Whether a send has occurred since last notify
---@field _timer uv.uv_timer_t|nil  Scheduled notification timer
---@field _subscribers fun(value: any)[]  Registered callbacks
---@field _closed boolean      Whether the channel has been closed

---@param initial any  Initial value (can be nil)
---@return fun(value: any) send  Function to send a new value
---@return WatchChannelHandle handle  Object with subscribe/close methods
function M.new(initial)
  ---@type WatchChannel
  local state = {
    _value = initial,
    _dirty = false,
    _timer = nil,
    _subscribers = {},
    _closed = false,
  }

  --- Notify all subscribers with the current value and reset dirty flag.
  local function notify()
    state._dirty = false
    state._timer = nil
    if state._closed then return end

    local val = state._value
    for _, cb in ipairs(state._subscribers) do
      cb(val)
    end
  end

  --- Send a new value into the channel.
  --- If already dirty (a notification is pending), the value is updated
  --- in place without scheduling an additional notification -- this is
  --- what produces the coalescing behavior.
  ---@param value any
  local function send(value)
    if state._closed then return end

    state._value = value

    if not state._dirty then
      state._dirty = true
      -- Schedule notification on the next event loop tick.
      -- vim.uv timer with 0ms delay fires after the current Lua call stack
      -- unwinds back to the event loop, coalescing all sends in this tick.
      if state._timer then
        pcall(function() state._timer:stop() end)
      end
      local t = vim.uv.new_timer()
      if t then
        state._timer = t
        t:start(0, 0, vim.schedule_wrap(notify))
      end
    end
  end

  ---@class WatchChannelHandle
  local handle = {}

  --- Register a callback that fires once per coalesced batch of sends.
  ---@param callback fun(value: any)
  ---@return fun() unsubscribe  Call to remove the subscription
  function handle.subscribe(callback)
    table.insert(state._subscribers, callback)
    return function()
      for i, cb in ipairs(state._subscribers) do
        if cb == callback then
          table.remove(state._subscribers, i)
          return
        end
      end
    end
  end

  --- Get the current value without subscribing.
  ---@return any
  function handle.get()
    return state._value
  end

  --- Close the channel and release the timer.
  function handle.close()
    state._closed = true
    state._subscribers = {}
    if state._timer then
      pcall(function()
        state._timer:stop()
        if not state._timer:is_closing() then
          state._timer:close()
        end
      end)
      state._timer = nil
    end
  end

  return send, handle
end

return M
```

### API Summary

```lua
local watch = require("andrew.vault.watch_channel")

-- Create a channel
local send, handle = watch.new(nil)  -- initial value

-- Producer side: signal that state changed
send(true)    -- stores value, schedules notification
send(true)    -- same tick -> overwrites value, NO additional notification
send(true)    -- same tick -> overwrites value, NO additional notification
-- Result: ONE callback fires on the next tick

-- Consumer side: react to changes
local unsub = handle.subscribe(function(value)
  -- Called once per coalesced batch
  -- value is always the LATEST value sent
end)

-- Read current value without waiting
local current = handle.get()

-- Cleanup
unsub()         -- remove one subscriber
handle.close()  -- close channel, release timer, remove all subscribers
```

### Key Design Decisions

1. **0ms timer, not `vim.schedule`**: A bare `vim.schedule` fires after the current callback but
   before the event loop yields. A 0ms `uv_timer_t` fires after the event loop tick completes,
   ensuring all synchronous sends within a single autocmd cascade are coalesced. This is the
   critical difference -- `vim.schedule` would fire between autocmd handlers, defeating coalescing.

2. **Dirty flag guards re-scheduling**: Once `_dirty` is set, subsequent `send()` calls update the
   value but do not create additional timers. Only `notify()` clears the flag, allowing the next
   `send()` to schedule again. This prevents timer accumulation.

3. **Value semantics, not unit signals**: Unlike Zed's `watch::channel(())` (which only signals
   "dirty"), this channel carries a value. This enables use cases like "the active buffer changed
   to X" where the subscriber needs to know the new state, not just that something changed. For
   pure dirty signaling, use `send(true)` or `send(nil)`.

4. **No mutex needed**: All operations run on Neovim's single main thread. The `uv_timer_t`
   callback is `vim.schedule_wrap`'d, so `notify()` also runs on the main thread. No concurrent
   access is possible.

5. **Relationship to event_coalescer.lua**: The event coalescer batches per-buffer event data and
   delivers the full batch. Watch channel is simpler: one latest value, one notification. Use
   event_coalescer when you need per-buffer event context; use watch_channel when you only need
   "something changed, re-evaluate."

## Use Cases in Vault

### 1. highlight_coordinator.lua -- Buffer change -> single re-highlight

Current pattern (debounce with latency):

```lua
-- highlight_coordinator.lua (current, lines 241-252)
function M.schedule(bufnr, opts)
  opts = opts or {}
  local debounce_ms = opts.full and 30 or 200

  _timers[bufnr] = cleanup.debounce(_timers[bufnr], debounce_ms, function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    M.run_all(bufnr, opts)
  end)
end
```

Watch-style coalescing (next-tick, zero latency):

```lua
-- highlight_coordinator.lua (proposed)
local watch = require("andrew.vault.watch_channel")

---@type table<number, { send: fun(opts: table), handle: WatchChannelHandle }>
local _channels = {}

local function get_channel(bufnr)
  if not _channels[bufnr] then
    local send, handle = watch.new(nil)
    handle.subscribe(function(opts)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        _channels[bufnr].handle.close()
        _channels[bufnr] = nil
        return
      end
      M.run_all(bufnr, opts or {})
    end)
    _channels[bufnr] = { send = send, handle = handle }
  end
  return _channels[bufnr]
end

function M.schedule(bufnr, opts)
  local ch = get_channel(bufnr)
  ch.send(opts or {})
  -- 8 rapid TextChanged events -> 8 send() calls -> 1 run_all() on next tick
end
```

**Impact**: Highlight updates fire ~0ms after the last event instead of 200ms. For typing, the
200ms debounce was needed to avoid per-keystroke re-highlighting. With coalescing, all keystrokes
within a single event loop tick coalesce into one update, but each tick still triggers an update.
For expensive updaters, the module can combine coalescing (for collapse) with debounce (for
rate-limiting) -- see "Combining with Debounce" below.

### 2. engine_watcher.lua -- Filesystem events -> single index update

Current pattern:

```lua
-- engine_watcher.lua (current, lines 134-166)
-- _pending_changed_files accumulates abs_path -> true, _pending_count tracks size
-- File paths accumulated in on_fs_event() (lines 120-124) when filename matches MD_EXTENSION
_fs_debounce_timer = cleanup.debounce(_fs_debounce_timer, debounce_ms, function()
  local paths = vim.tbl_keys(_pending_changed_files)
  _pending_changed_files = {}
  _pending_count = 0

  local vault_index_mod = package.loaded["andrew.vault.vault_index"]
  if not vault_index_mod then return end
  local idx = vault_index_mod.current()
  if not idx or idx.vault_path ~= vault:gsub("/$", "") then return end

  -- Scoped invalidation: small batches use per-file, large use "all"
  if #paths > 0 then
    if idx._building then
      _engine.invalidate_caches({ scope = "all", skip_index = true })
    else
      idx:update_files_batch(paths)
      if #paths > 10 then
        _engine.invalidate_caches({ scope = "all", skip_index = true })
      else
        _engine.invalidate_caches({ scope = "files", paths = paths, skip_index = true })
      end
    end
  end
end)
```

The watcher already accumulates paths into `_pending_changed_files` and processes them in batch.
The debounce delay (500ms) exists because filesystem events arrive in rapid bursts. With watch
coalescing, the watcher would still accumulate paths, but the batch would fire on the next tick
after the burst ends rather than 500ms later:

```lua
-- engine_watcher.lua (proposed)
local watch = require("andrew.vault.watch_channel")

local _fs_send, _fs_handle = watch.new(nil)
_fs_handle.subscribe(function()
  local paths = vim.tbl_keys(_pending_changed_files)
  _pending_changed_files = {}
  _pending_count = 0
  if #paths > 0 then
    if idx._building then
      _engine.invalidate_caches({ scope = "all", skip_index = true })
    else
      idx:update_files_batch(paths)
      if #paths > 10 then
        _engine.invalidate_caches({ scope = "all", skip_index = true })
      else
        _engine.invalidate_caches({ scope = "files", paths = paths, skip_index = true })
      end
    end
  end
end)

-- In the fs event callback (on_fs_event):
local function on_fs_event(path)
  _pending_changed_files[path] = true
  _pending_count = _pending_count + 1
  _fs_send(true)  -- Coalesces: 50 events -> 1 update_files_batch call
end
```

**Caveat**: Filesystem events may arrive spread across multiple ticks (the OS delivers them in
micro-batches, especially on Linux where inotify watches are per-directory). For this use case,
a hybrid approach -- coalescing with a short debounce floor -- may be preferable. See "Combining
with Debounce" below.

### 3. embed_sync.lua -- Embed invalidation -> single re-render

Current pattern: embed_sync.lua uses debounce timers per buffer via `state._sync_timers[bufnr]`.
Cross-file changes debounce at `config.embed.sync.debounce_ms` (300ms), same-file TextChanged
at `config.embed.sync.self_debounce_ms` (500ms). The module maintains an inverted dependency index
(`_dep_to_bufs`) mapping dependency paths to affected buffer sets.

```lua
-- embed_sync.lua (current, lines 46-59)
function M.schedule_rerender(bufnr, delay_ms)
  state._sync_timers[bufnr] = cleanup.debounce(state._sync_timers[bufnr], delay_ms, function()
    state._sync_timers[bufnr] = nil

    if not state.is_embed_active(bufnr) then return end

    local embed = require("andrew.vault.embed")
    local fc = embed.get_frame_cache(bufnr)
    if fc then fc:clear() end
    embed.render_embeds_buf(bufnr, { silent = true })
  end)
end
```

With watch coalescing:

```lua
-- embed_sync.lua (proposed)
local watch = require("andrew.vault.watch_channel")

---@type table<number, { send: fun(any), handle: WatchChannelHandle }>
local _embed_channels = {}

local function invalidate_embeds(bufnr)
  if not _embed_channels[bufnr] then
    local send, handle = watch.new(nil)
    handle.subscribe(function()
      if not state.is_embed_active(bufnr) then return end
      local embed = require("andrew.vault.embed")
      local fc = embed.get_frame_cache(bufnr)
      if fc then fc:clear() end
      embed.render_embeds_buf(bufnr, { silent = true })
    end)
    _embed_channels[bufnr] = { send = send, handle = handle }
  end
  _embed_channels[bufnr].send(true)
end
```

### 4. sidebar.lua -- State change -> single panel update

Current pattern:

```lua
-- sidebar.lua (current, lines 232-237)
local function schedule_render()
  if not _state.visible then return end
  _state.update_timer = cleanup.debounce(_state.update_timer, config.sidebar.update_debounce_ms, function()
    M.render()
  end)
end
```

With watch coalescing:

```lua
-- sidebar.lua (proposed)
local _sidebar_send, _sidebar_handle = watch.new(nil)
_sidebar_handle.subscribe(function()
  if _state.visible then
    M.render()
  end
end)

local function schedule_render()
  if not _state.visible then return end
  _sidebar_send(true)
end
```

**Impact**: Sidebar updates on the next tick instead of 150ms later. During rapid `:bnext` cycling,
the sidebar still only renders once per tick (coalesced), but it renders the *current* buffer's
panel, not a 150ms-stale one.

## Combining with Debounce

Some operations need both coalescing (collapse rapid events) and rate-limiting (don't fire too
frequently). The two primitives compose cleanly:

```lua
--- Coalesce-then-debounce: collapse events into dirty signal, then debounce
--- the actual work. The watch channel collapses 50 sends into 1 notification;
--- the debounce timer ensures the work runs at most once per interval.
local watch = require("andrew.vault.watch_channel")
local cleanup = require("andrew.vault.resource_cleanup")

local _debounce_timer = nil
local send, handle = watch.new(nil)

handle.subscribe(function()
  -- Watch fires on next tick; debounce adds rate-limiting
  _debounce_timer = cleanup.debounce(_debounce_timer, 100, function()
    do_expensive_work()
  end)
end)

-- Producer: rapid events
send(true)  -- tick 1: watch fires -> debounce starts (100ms)
send(true)  -- tick 1: coalesced (no additional watch fire)
-- tick 2 (1ms later): nothing happens
send(true)  -- tick 3 (5ms later): watch fires -> debounce resets (100ms from now)
-- tick 103: debounce fires -> do_expensive_work() runs once
```

This gives the best of both worlds:
- **Coalescing**: 50 events in one tick -> 1 watch notification
- **Rate-limiting**: work runs at most once per 100ms even if events span multiple ticks

### When to Use Which

| Pattern | Latency | Coalescing | Use When |
|---------|---------|------------|----------|
| `vim.schedule` | ~0ms | None | Single deferred call, no batching needed |
| `watch_channel` | ~0ms (next tick) | Within-tick | State sync, fast operations (<5ms) |
| `event_coalescer` | configurable (16ms default) | Within-window + batch-size | Per-buffer event data batching, adaptive delay |
| `request_coalescer` | N/A | Operation-level | Dedup concurrent identical operations |
| `cleanup.debounce` | N ms | All within window | Expensive operations, user-input settling |
| `watch + debounce` | N ms | Both within-tick and across ticks | Expensive operations with bursty triggers |

## Implementation Steps

### Step 1: Create `lua/andrew/vault/watch_channel.lua`

Implement the module as shown in the Proposed Design section. No external dependencies -- the
module uses only `vim.uv.new_timer()`, `vim.schedule_wrap`, and `pcall`.

### Step 2: Add tests

```lua
-- Test: multiple sends coalesce into one notification
local watch = require("andrew.vault.watch_channel")
local call_count = 0
local last_value = nil

local send, handle = watch.new(nil)
handle.subscribe(function(val)
  call_count = call_count + 1
  last_value = val
end)

-- Simulate rapid sends (all within one Lua call stack)
send("a")
send("b")
send("c")

-- At this point: call_count == 0 (notification is scheduled, not fired)
-- After event loop tick: call_count == 1, last_value == "c"
```

```lua
-- Test: sends after notification schedule a new notification
local send, handle = watch.new(nil)
local values = {}

handle.subscribe(function(val) table.insert(values, val) end)

send("first")
-- After tick: values == {"first"}

-- Later:
send("second")
-- After tick: values == {"first", "second"}
```

```lua
-- Test: unsubscribe prevents callback
local send, handle = watch.new(nil)
local called = false

local unsub = handle.subscribe(function() called = true end)
unsub()
send("ignored")
-- After tick: called == false
```

```lua
-- Test: close releases resources
local send, handle = watch.new(nil)
local called = false

handle.subscribe(function() called = true end)
handle.close()
send("ignored")  -- No error, silently ignored
-- After tick: called == false
```

### Step 3: Integrate into highlight_coordinator.lua (primary target)

Replace the per-buffer debounce timer with a per-buffer watch channel. The highlight updaters
are fast enough (<5ms total) to run on every tick. If profiling shows otherwise, add a debounce
floor as shown in "Combining with Debounce."

Note: `run_all()` already uses shared computation (link_scan code exclusion computed once, passed
to all updaters), region-based invalidation tracking, and dual-frame caching via `FrameCache`.
Watch coalescing improves the scheduling layer without changing the execution pipeline.

### Step 4: Integrate into sidebar.lua

Replace the 150ms `schedule_render()` debounce with a watch channel. The sidebar `M.render()` is
lightweight (queries panel module, writes virtual text to scratch buffer) and benefits from minimal
latency. Clean up channel on sidebar close (existing `close_sidebar()` already handles timer cleanup).

### Step 5: Integrate into engine_watcher.lua (hybrid approach)

Use a watch channel to coalesce filesystem events, but keep a short debounce (50-100ms) before
triggering `update_files_batch()`. Filesystem event bursts can span multiple ticks (especially on
Linux with per-directory inotify watches and incremental `start_incremental_watches()` setup), so
pure coalescing may fire too early (before the burst completes).

### Step 6: Integrate into embed_sync.lua

Replace `state._sync_timers[bufnr]` debounce with watch channels for cross-file embed invalidation.
Keep `state._scroll_timers[bufnr]` as debounce in embed.lua (line 1039) -- scroll events are
continuous and need rate-limiting at `config.embed.lazy_scroll_debounce_ms` (80ms).

### Step 7: Cleanup GC for per-buffer channels

Add a `BufDelete`/`BufWipeout` autocmd (or integrate with existing cleanup) to close channels
for buffers that are no longer valid. The existing `setup_buf_cleanup()` helper in
highlight_coordinator.lua and the `BufWipeout` cleanup in embed_state.lua (lines 58-69) already
handle per-buffer resource teardown and can be extended:

```lua
-- In highlight_coordinator.lua or a shared lifecycle hook
vim.api.nvim_create_autocmd("BufWipeout", {
  group = augroup,
  callback = function(ev)
    local ch = _channels[ev.buf]
    if ch then
      ch.handle.close()
      _channels[ev.buf] = nil
    end
  end,
})
```

## Comparison with Existing Patterns

### vs. `resource_cleanup.debounce()`

| Aspect | `cleanup.debounce` | `watch_channel` |
|--------|-------------------|-----------------|
| Latency | N ms (configurable) | ~0ms (next event loop tick) |
| Coalescing | All events within window | All events within same tick |
| Timer lifecycle | New timer per call via `close_timer(existing)` then `uv.new_timer()` (lines 47-55 of resource_cleanup.lua) | One timer, reused across sends |
| Timer churn | High (create/close per debounce reset, tracked in `_active_timers` weak table) | Low (one timer per dirty cycle) |
| Value tracking | None (fire-and-forget) | Holds latest value |
| Subscriber model | Single callback | Multiple subscribers |
| Best for | Expensive ops, input settling | State sync, fast ops |

### vs. `event_coalescer.lua`

| Aspect | `event_coalescer` | `watch_channel` |
|--------|------------------|-----------------|
| Data model | Per-buffer event table (batch) | Single latest value |
| Coalescing window | Configurable `delay_ms` (default 16ms) | 0ms (next tick) |
| Batch size trigger | `max_batch` forces flush | N/A (always next tick) |
| Adaptive delay | Yes (rapid switching detection) | No (always 0ms) |
| Timer reuse | Yes (single timer, stopped/restarted) | Yes (single timer per dirty cycle) |
| Best for | Batching per-buffer event context | Pure dirty signaling, state sync |

### vs. `request_coalescer.lua`

| Aspect | `request_coalescer` | `watch_channel` |
|--------|--------------------|-----------------| 
| Purpose | Dedup concurrent identical operations | Collapse rapid signals |
| Model | Shared-future: multiple callers join one op | Latest-value broadcast |
| Cancellation | Per-subscriber cancel handles | Unsubscribe function |
| Late arrivals | `done_linger_ms` caches result | N/A (fire-and-forget) |
| Best for | Expensive async ops (URL validation, search) | Cheap sync state updates |

### vs. Doc 11 (Autocmd Event Batching)

Doc 11's structural batching is now implemented in `event_coalescer.lua`. Watch coalescing is a
complementary lower-level primitive that event_coalescer could use internally:

- **event_coalescer**: "Group these 8 BufEnter handlers into one dispatch" (structural batching)
- **watch_channel**: "Collapse rapid signals into one wakeup" (temporal coalescing)

The highlight_coordinator already implements structural batching (shared context, pipeline
dispatch). Doc 43 adds temporal coalescing on top -- the coordinator receives one `schedule()`
call per event, and the watch channel collapses multiple `schedule()` calls into a single
`run_all()`.

### vs. Doc 41 (Operation Counter Staleness)

Doc 41 detects when async results are stale upon arrival. Doc 43 prevents redundant async
operations from being started in the first place:

- **Doc 41**: "This result is from operation #3, but we're now on #5 -- discard it"
- **Doc 43**: "5 events fired, but we only start 1 operation (on the next tick)"

The two are complementary. A watch-coalesced operation that is still async (e.g., index rebuild)
should use an operation counter to detect staleness of its results.

## Expected Impact

### Performance

- **Timer churn reduction**: `cleanup.debounce` creates and closes a `uv_timer_t` on every
  event (because each debounce reset requires a new timer). Watch channels reuse a single timer
  per dirty cycle. For highlight_coordinator receiving 30 TextChanged events per second during
  typing, this eliminates ~29 timer create/close cycles per second per buffer. (Note:
  `event_coalescer.lua` already reuses its timer via stop/restart, so the churn reduction
  applies specifically to the ~14 `cleanup.debounce` call sites.)

- **Handler invocations**: For burst events (paste, bulk operations), coalescing reduces handler
  invocations similarly to debounce -- both fire once per burst. The win over debounce is latency,
  not invocation count: coalescing fires ~150-500ms sooner depending on the replaced debounce.

- **Perceived responsiveness**: Sidebar, highlights, and embeds update on the next tick (~0ms)
  instead of after debounce delay (150-500ms). For operations that complete in <5ms, the delay
  was pure waste.

### Memory

- **Per channel**: One table (5 fields) + one `uv_timer_t` + subscriber list. Lighter than
  debounce (which allocates a new `uv_timer_t` per reset).
- **Per buffer**: One channel per use case (highlight, embed_sync, sidebar). Approximately 2-3
  channels per buffer, ~200 bytes total. Negligible.

## Risks

1. **Overly aggressive updates**: Without debounce, fast operations that were previously
   rate-limited may fire too frequently. For example, if highlight_coordinator's `run_all()`
   takes 8ms and TextChanged fires every 10ms during fast typing, the CPU load is ~80%.
   Mitigation: profile first, add debounce floor only where needed (the hybrid pattern).

2. **Tick boundary sensitivity**: Coalescing depends on events arriving within the same event
   loop tick. If autocmd handlers are spread across multiple `vim.schedule` calls, they may land
   in different ticks and not coalesce. Mitigation: this is the same tick behavior as current
   debounce; coalescing is strictly better (it fires sooner with at least as much collapse).

3. **Subscriber ordering**: Callbacks fire in registration order. If one subscriber triggers a
   `send()` on the same channel, it schedules a new notification for the *next* tick (not
   re-entrant). This is correct behavior but may surprise developers expecting synchronous
   propagation.

4. **GC for per-buffer channels**: Channels for deleted buffers must be explicitly closed to
   release timers. Forgetting to clean up leaks one `uv_timer_t` per dead buffer. Mitigation:
   extend existing `BufWipeout` cleanup in highlight_coordinator's `setup_buf_cleanup()` and
   embed_state.lua's buffer cleanup (lines 58-69), plus periodic GC sweep (same pattern as
   embed_state's stale buffer cleanup).

5. **Interaction with event_coalescer.lua**: Some call sites might benefit from event_coalescer's
   adaptive delay during rapid buffer switching (`:bufdo`-style). Watch channel's 0ms coalescing
   would fire on every tick during rapid switching. Mitigation: for those specific sites, keep
   event_coalescer or use the hybrid watch+debounce pattern.
