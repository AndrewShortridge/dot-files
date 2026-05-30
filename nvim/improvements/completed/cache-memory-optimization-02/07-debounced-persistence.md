# 07 — Debounced Persistence & Write Coalescing

## Priority: LOW
## Estimated Effort: Small

## Problem

The vault index persistence system is already well-designed with:
- Debounced full writes (5s default via `config.index.persist_debounce_ms`)
- WAL-based delta persistence (`changes.jsonl` JSONL append for incremental changes)
- Async I/O via `vim.uv.fs_open/fs_write/fs_close` for full persists
- Generation tracking (`_generation` vs `_last_persisted_generation`) to skip no-op persists
- `_persist_in_flight` guard preventing concurrent async writes
- Blocking sync write on VimLeavePre via `persist_now()` for safety
- Derived field exclusion via `strip_derived()` using lazy `__index` metatable
  (omits `tag_set`, `heading_slugs`, `block_id_set`, `abs_path`, `basename`,
  `basename_lower`, `folder` — ~30% smaller JSON)
- WAL auto-compaction: full persist triggered when `_wal_count > 1000`

The remaining improvement opportunity is **adaptive debouncing** to reduce
redundant full persists during burst editing sessions.

## Current Implementation

### Persistence Architecture

The system uses a hybrid WAL + snapshot approach:

```
.vault-index/
  index.json          -- Full snapshot (written on full persist or shutdown)
  changes.jsonl       -- JSONL append-only WAL (incremental deltas)
```

**Startup**: `load()` reads `index.json`, replays `changes.jsonl` WAL entries,
then calls `_rebuild_derived_fields()` to reconstruct lazy-computed fields.

### Key Methods (OOP style: `VaultIndex:method()`)

- **`_schedule_persist(changed_rel_paths, deleted_rel_paths)`** — dispatches
  to WAL delta path (with paths) or debounced full persist (without paths)
- **`_persist_delta(changed, deleted)`** — appends `{"op":"set",...}` /
  `{"op":"del",...}` lines to `changes.jsonl` via synchronous `io.open("a")`
  (~<2ms per call)
- **`_persist()`** — async full persist via `vim.uv.fs_open/fs_write/fs_close`;
  strips derived fields, encodes full index to JSON; truncates WAL on success
  only if no new deltas arrived during async write
- **`persist_now()`** — blocking sync persist via `io.open("w")` for
  VimLeavePre; supersedes any in-flight async write; always truncates WAL
- **`_truncate_wal()`** — empties `changes.jsonl` and resets `_wal_count`
- **`_prepare_persist_data(caller)`** — closes persist timer, returns nil if
  generation unchanged, strips derived fields from all entries, encodes JSON

### Constructor Fields (vault_index.lua)

```lua
self._persist_timer = nil              -- uv timer for debounced persistence
self._generation = 0                   -- incremented on every index change
self._last_persisted_generation = 0    -- generation of last successful persist
self._persist_in_flight = false        -- guard against concurrent async writes
self._wal_count = 0                    -- WAL entry count (triggers compaction >1000)
self._index_dir = vault_path .. "/.vault-index"
```

Note: `_last_persist_time` does NOT exist yet — proposed below.

### Generation & In-Flight Guards

- `_generation` incremented in `_notify_update()` after each index change
- `_prepare_persist_data()` returns nil if `_generation == _last_persisted_generation`
- `_persist_in_flight` flag prevents concurrent async writes
- `_wal_count` tracks WAL entries; triggers full persist at >1000 entries

### Trigger Points

- **`vault_index_build.lua: build_async()`** — calls `_schedule_persist()`
  (no paths → debounced full persist) after async build completes
- **`vault_index_build.lua: update_files_batch()`** — calls
  `_schedule_persist(changed, deleted)` (with paths → WAL delta)
- **`init.lua: VimLeavePre`** — calls `persist_now()` for sync shutdown;
  also closes focus debounce timer and stops fs watcher

### Initialization Lifecycle (init.lua)

```lua
local idx = vi.get(engine.vault_path)
vim.defer_fn(function()
  idx:load()          -- Load persisted index from disk
  idx:build_async()   -- Start incremental build
end, 50)
```

Note: `configure()` is NOT called from engine.lua for vault_index. The config
values are read directly from `config.index.*` within vault_index.lua.

### Configuration

```lua
-- config.lua (M.index section)
M.index.persist_debounce_ms = 5000   -- debounce for full persists
M.index.batch_size = 20              -- files per parse batch in async build
```

## Zed Inspiration

Zed's persistence approach (verified against current codebase):

1. **100ms debounced workspace serialization**:
   `serialize_workspace()` in `crates/workspace/src/workspace.rs` spawns a
   background task via `cx.spawn_in()` that waits 100ms (hardcoded
   `Duration::from_millis(100)`), collects workspace state on the main thread,
   then calls `serialize_workspace_internal()`. The `_schedule_serialize:
   Option<Task<()>>` field prevents duplicate scheduling. A separate item
   serialization path uses `SERIALIZATION_THROTTLE_TIME` (200ms) throttling
   with `ready_chunks(200)` batching (CHUNK_SIZE=200) and HashMap
   deduplication by `item_id`
2. **WAL mode SQLite**: `PRAGMA journal_mode=WAL` set in `DB_INITIALIZE_QUERY`
   in `crates/db/src/db.rs`, along with `PRAGMA synchronous=NORMAL`,
   `PRAGMA busy_timeout=1`, `PRAGMA case_sensitive_like=TRUE`.
   `PRAGMA foreign_keys=TRUE` is set separately in `CONNECTION_INITIALIZE_QUERY`
   (per-connection rather than per-database)
3. **Savepoint transactions**: `with_savepoint(name, f)` and
   `with_savepoint_rollback(name, f)` utility functions in
   `crates/sqlez/src/savepoint.rs` provide nestable savepoints — auto-rollback
   on error, release on success. Used by `save_workspace()` via
   `with_savepoint("update_worktrees")` for atomic multi-table updates.
   (No `SavepointTracker` struct — just standalone functions on `Connection`)
4. **Background write thread**: `background_thread_queue()` in
   `crates/sqlez/src/thread_safe_connection.rs` spawns a dedicated thread per
   database URI. All writes are queued via `std::sync::mpsc::channel` and
   executed sequentially on this background thread. Write closures are
   fire-and-forget (`Box<dyn FnOnce()>`). Reads use `ThreadLocal<Connection>`
   — each thread gets its own connection via `get_or()` lazy initialization

### In-Memory Structural Sharing (Not Disk Persistence)

Zed's `entries_by_path` is a `SumTree<Entry>` — a persistent immutable B-tree
with structural sharing (`crates/sum_tree/`). The `edit()` method applies sorted
`Edit<Entry>` operations (Insert/Remove) in O(n log n), creating a new tree
version that shares unchanged nodes with the old version via `Arc::make_mut()`
copy-on-write semantics.

This is an **in-memory optimization**, not a disk persistence pattern. Zed's
worktree state is NOT persisted to disk — it's rebuilt from the filesystem on
every startup. The structural sharing reduces memory allocation during
incremental updates. Entry change detection uses `inode` and `mtime` fields
(no `content_hash` on worktree entries).

### BLAKE3 Hashing

Zed uses BLAKE3 in the semantic index (`crates/semantic_index/src/summary_index.rs`)
for content-addressed storage of LLM summaries. The hash is computed over both
file path and file contents, stored as a hex string (`Blake3Digest` type). This
is used for deduplication in the semantic index — NOT for worktree change
detection or persistence optimization.

### Scan Request Coalescing

Zed's background filesystem scanner coalesces pending scan requests via greedy
channel draining (`try_recv()` loop in `next_scan_request()`). Multiple queued
`ScanRequest { relative_paths, done }` structs are merged into a single batch
by extending both the path list and the barrier sender list, reducing redundant
filesystem traversals.

## Implementation

### Adaptive Debounce for Burst Edits

The only remaining improvement. During heavy editing (e.g., find-and-replace
across files), the current system writes WAL deltas per-batch (fast, <2ms each)
and only triggers full persist when WAL exceeds 1000 entries. However, if a full
persist IS triggered (e.g., after `build_async()`), rapid successive triggers
could cause redundant writes. An adaptive minimum interval would prevent this:

```lua
-- In vault_index.lua, add to VaultIndex fields:
---@field _last_persist_time number
-- Initialize in constructor:
self._last_persist_time = 0

function M.VaultIndex:_schedule_persist(changed_rel_paths, deleted_rel_paths)
  if changed_rel_paths or deleted_rel_paths then
    -- Incremental change: write delta to WAL (fast, <2ms)
    self:_persist_delta(changed_rel_paths or {}, deleted_rel_paths or {})
    -- Only schedule full persist if WAL is getting large
    if self._wal_count > 1000 then
      self:_schedule_full_persist()
    end
  else
    -- Full rebuild: schedule debounced full persist with adaptive delay
    self:_schedule_full_persist()
  end
end

-- New helper: adaptive delay based on time since last full persist
function M.VaultIndex:_schedule_full_persist()
  local now = vim.uv.now()
  local since_last = now - self._last_persist_time
  local min_interval = config.index.persist_min_interval_ms

  local delay = math.max(
    config.index.persist_debounce_ms,
    min_interval - since_last
  )

  self._persist_timer = cleanup.debounce(self._persist_timer, delay, function()
    self:_persist()
    self._last_persist_time = vim.uv.now()
  end)
end
```

### Config Addition

```lua
-- config.lua (M.index section)
M.index.persist_debounce_ms = 5000          -- existing
M.index.persist_min_interval_ms = 10000     -- new: minimum gap between full persists
M.index.batch_size = 20                     -- existing
```

## Expected Impact

| Change | Disk I/O Reduction | Memory Impact |
|--------|-------------------|---------------|
| Adaptive debounce | Fewer full persists during bursts | None |

Note: Delta persistence (WAL), derived field exclusion, generation-based no-op
detection, and in-flight guards are all already implemented.

## Risk Assessment

- **Adaptive debounce** is low-risk and the only remaining change —
  straightforward addition to the existing `_schedule_persist()` timer logic
- No risk to WAL replay, crash safety, or startup behavior

## Testing

- Trigger `build_async()` twice in rapid succession, verify only 1 full persist
  happens (not 2)
- Verify `persist_min_interval_ms` prevents full persists closer than the
  configured interval
- Verify WAL deltas still write immediately (adaptive debounce only affects
  full persists, not WAL appends)
- Note: no dedicated `vault_index_spec.lua` exists yet; persistence tests
  would need to be added alongside this change
