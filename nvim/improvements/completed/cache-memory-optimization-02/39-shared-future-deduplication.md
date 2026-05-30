# 39. Shared Future Deduplication

## Current State

The codebase already implements significant deduplication infrastructure. This document has been updated to reflect what exists and identify remaining gaps.

### What Already Exists

**`request_coalescer.lua`** — A singleton module providing keyed operation deduplication:

```lua
-- API surface:
M.request(key, operation_fn, callback)     -- Core: deduplicate by key
M.request_async(key, operation_fn)         -- Coroutine wrapper (yields until result)
M.cancel(key)                              -- Cancel in-flight + notify waiters
M.is_pending(key)                          -- Check if key in-flight
M.waiter_count(key)                        -- Get subscriber count
M.pending_keys()                           -- Debug: list all in-flight keys
M.stats()                                  -- Stats: total_operations, coalesced, cancelled, coalesce_rate
M.configure(opts)                          -- Set max_waiters, timeout_ms
M._resolve_entry(key, result, err)         -- Internal: manually resolve an entry (used by embed.lua for synchronous completion)
M._reset()                                 -- Testing: reset all state
```

Internal state: `_in_flight` table (line 13) maps keys to `{ waiters = {callbacks}, timer = uv_timer|nil }` (lines 38-42). Uses `vim.uv.new_timer()` (line 47) for timeouts, `resource_cleanup.close_timer()` for cleanup, `vim.schedule_wrap()` (line 49) for async marshalling. Re-entrancy safe: removes entry from `_in_flight` (line 94) before invoking waiter callbacks (lines 98-104). All operations and callbacks wrapped in `pcall`. Dependencies: `vault_log` (line 9), `resource_cleanup` (line 10). Stats at `M._stats` (line 196), config at `M._config` (line 197). API entry points: `M.request` (line 22), `M.request_async` (line 122), `M.cancel` (line 138), `M.is_pending` (line 150), `M.waiter_count` (line 157), `M.pending_keys` (line 164), `M.stats` (line 174), `M.configure` (line 201).

**Already integrated into:**

| Module | Key Pattern | Purpose |
|--------|------------|---------|
| `vault_index_build.lua:281` | `"index_rebuild"` | Deduplicates concurrent `build_async()` calls (require at line 10) |
| `embed.lua:466-614` | `"embed_render:" .. bufnr` | Embed rendering coalescing (require line 17; `is_pending` line 466, `cancel` line 472, `request` line 497, `_resolve_entry` line 612, `is_pending` in prefetch line 632; forced renders cancel existing then re-request) |
| `connections.lua:771-773` | `"connections:" .. source_rel_path` | Connection scoring deduplication (require at line 14; key at line 771, `request` line 773) |
| `search_filter.lua:503-572` | `"search:" .. ast_hash(ast)` (+ `:restricted` suffix when `opts.restrict_to`) | Search evaluation deduplication via `evaluate_async()` (require at line 23; key at line 507, suffix at lines 508-510, `is_pending` line 513, join line 514, `cancel` lines 525/570, `request` line 531) |

**`vault_index.build_async()`** — Already uses `coalescer.request("index_rebuild", ...)` at vault_index_build.lua:281 (not a simple `_building` flag). Multiple concurrent callers join the existing in-flight build and all receive the result when it completes. The `_building` flag is only used as a secondary guard to prevent `update_files_batch()` during a full async build. `_apply_staged()` sets `_ready = true` and `_building = false` atomically after all mutations complete.

**`embed.lua` cross-file reads** — Already uses a 4-layer caching system:
1. `file_cache.lua` — LRU weighted cache: `_cache` (lines 21-26 init, `config.cache.file_content_bytes` = 5 MB, `config.cache.file_content_max` = 100) for full file contents with mtime invalidation (`vim.uv.fs_stat()`, mtime check at lines 47-50); `_section_cache` (lines 27-31, `config.cache.section_cache_bytes` = 2 MB, `config.cache.section_cache_max` = 200) for heading/block extractions keyed by `path .. "\0" .. fragment`. API: `read()` (lines 39-71), `get_section()` (lines 78-103), `invalidate()` (lines 108-122, scans section_cache by path prefix), `stats()` (lines 135-156).
2. `frame_cache.lua` — Two-generation per-buffer cache for rendered virtual text (`virt_lines`). Structure (lines 4-14): `previous`/`current` generation tables (lines 7-8), `current_count`/`previous_count` (lines 9-10), `max_entries` (line 11), stats (line 12). Key: `bufnr:lnum:inner`. `get()` (lines 16-36) promotes from previous→current on hit. `set()` (lines 38-50) stores in current with capacity check. `finish_frame()` (lines 52-57) rotates current→previous. Deep-copies virt_lines via `FrameCache.copy_virt_lines()` (lines 106-114, per-segment copy to survive arena recycling). Per-buffer via `buf_get()` (lines 91-100) using `config.render_cache.max_entries_per_frame` and `config.render_cache.enabled`.
3. `warm_embed_cache()` (embed.lua:204-216) — Pre-render pass with `seen` set (optionally arena-allocated) ensures each unique file read exactly once per render cycle. Called at line 530 from `M.render_embeds()`.
4. Request coalescer (embed.lua:460-632) — `"embed_render:" .. bufnr` key prevents concurrent duplicate renders per buffer (`coalesce_key` at lines 460/631, `is_pending` at 466/632, `cancel` at 472, `request` at 497, `_resolve_entry` at 612, `finish_frame` at 606-607).

Render flow: `warm_embed_cache()` pre-populates file_cache → `render_single_embed()` checks frame_cache (lines 264-266) → on miss, reads from file_cache → stores rendered output in frame_cache (lines 367-369).

**BFS graph traversal** — `connections.lua` does NOT perform BFS (it uses multi-signal scoring with 1-hop direct links + 2-hop bridge counting via set intersection, capped at `max_2hop_bridges=5`). BFS is used by:
- `search_filter/graph_traversal.lua` (232 lines) — Delegates to `bfs.lua` (sync `bfs.traverse()` at line 71, async `bfs.traverse_async()` at line 159). `prepare_bfs_opts()` (lines 35-58) builds shared BFS options (config refs: `config.search.graph_max_depth` at line 36, `config.graph.max_nodes` at line 39). `collect_reachable()` (lines 67-73) does sync BFS with zero caching. `precompute_graph_sets()` (lines 118-143) caches results by `graph_id` at the AST query level only (within a single call), NOT at the BFS traversal level. `precompute_graph_sets_async()` (lines 174-229) processes graph nodes sequentially with cancellation (`collect_reachable_async()` at lines 152-164). `ast_contains_graph()` (lines 100-110) checks for graph: nodes in AST. Re-exported via `search_filter.lua`.
- `graph_filter/traversal.lua` (339 lines) — Has its own `_bfs_cache` (LRU weighted, lines 36-41, `config.cache.bfs_traversal_bytes` = 1 MB, `config.cache.bfs_traversal_max` = 100). Keyed by `center_rel`. `check_cache()` (lines 149-208) returns one of three outcomes: exact hit (copies + returns sorted nodes), extend (copies visited/frontier/nodes for incremental BFS), or miss (fresh traversal). `make_bfs_opts()` (lines 216-228) builds BFS options from setup (config ref: `config.graph.max_nodes` at line 216). `store_and_return()` (lines 242-268) pre-sorts node lists before caching (immutable cached data). `collect_at_depth_async()` (lines 282-315) is the main public entry point with arena allocation (`render_arena.begin_scope()` at line 297, cleanup at lines 303/312). Validates via `filter_utils.is_cache_gen_valid(cached, gen)` + `state_hash` match. Tracks hits/misses/evictions via global counters (lines 32-34). Classified nodes as forward_like/backlink_like/all_nodes via `make_on_discover()` (lines 64-87). Debug API: `bfs_cache_size()` (lines 319-321), `bfs_cache_stats()` (lines 325-330), `bfs_cache_counters()` (lines 334-336), `invalidate_bfs_cache()` (lines 45-47).
- `bfs.lua` (210 lines) — Core stateless BFS engine. `process_node_links()` (lines 44-100) processes outlinks/inlinks per node. `collect_frontier()` (lines 108-116) helper collects remaining frontier items. `run_bfs_loop()` (lines 124-165) is the main BFS loop with iterator hook for async yielding. Two public entry points: `traverse(opts)` (line 170-172, sync) and `traverse_async(opts, async_opts)` (lines 189-207, cooperative yielding every `config.graph.bfs_batch_size` = 100 nodes at line 193). Returns `{ node_count, truncated, frontier }` — frontier enables incremental extension by consumers. Supports optional `arena_scope` for ephemeral queue allocations (via `render_arena` required at line 5). All state passed via `opts`; no internal caching.

**Completion sources** — Already have generation-based staleness detection:
- `completion_base.lua:329-342` — `cache_valid()` checks `idx._generation ~= _cached_gen` (line 337) and vault path match; intentionally does NOT use `filter_utils.is_cache_gen_valid()` — serves stale cache when vault_index isn't ready
- `completion_base.lua:619-717` — `build_kv_single_pass()` memoized by `vault_path .. "\0" .. field_name` (line 620-622) with generation validation via `filter_utils.is_cache_gen_valid()` (lines 624-627), uses `idx:snapshot_files()` (line 656), result stored at lines 714-716, shared between frontmatter and inline_fields sources
- Per-source state: `_cached_gen` (line 172), `build_generation` counter (line 173), `active_state` (line 176) — all scoped per `create_source()` closure
- Field cache: module-level `_field_cache = {}` (line 107) shared across all sources for `build_kv_single_pass` memoization
- Debounce via `resource_cleanup.debounce()` (default 250ms, sourced via `conf("debounce_ms", 250)` at line 179) prevents rebuild storms; timer in `active_state.timer`
- Cancellation: `active_state.cancelled` flag (line 345) checked at each coroutine yield; `cancel_active()` (lines 345-354) cleans up timer + sets flag; `build_generation` counter (line 173) detects stale builds during debounce delay
- `invalidate()` (lines 215-222) releases cached items to pool and increments `build_generation`
- `index_is_building()` (lines 195-213) with 30-second timeout fallback
- No use of request_coalescer (manual generation tracking preferred due to async coroutine build + debounce + vault-switch detection)

**Config** (`config.lua:877-881`):
```lua
M.coalescer = {
  max_waiters = 50,
  timeout_ms = 30000,
}
```

Related pool config (`config.lua:851-858`):
```lua
M.pools = {
  enabled = true,
  connection_result = 200,
  connection_breakdown = 200,
  completion_item = 1000,
  embed_descriptor = 50,
}
```

Arena config (`config.lua:862-867`):
```lua
M.arena = {
  initial_pool_size = 200,
  max_pool_size = 2000,
  debug_validation = false,
}
```

Related cache config (`config.lua:810-830`):
```lua
M.cache = {
  -- Count-based limits
  slug_max = 2000,
  date_parse_max = 5000,
  connections_max = 500,
  section_cache_max = 200,
  note_data_max = 1000,
  display_width_max = 2000,
  bfs_traversal_max = 100,
  image_path_max = 500,
  fold_state_max = 500,
  file_content_max = 100,
  -- Memory-weighted byte budgets (total: 15 MB)
  file_content_bytes = 5 * 1024 * 1024,       -- 5 MB
  section_cache_bytes = 2 * 1024 * 1024,       -- 2 MB
  section_outlinks_bytes = 2 * 1024 * 1024,    -- 2 MB
  connections_bytes = 3 * 1024 * 1024,         -- 3 MB
  note_data_bytes = 2 * 1024 * 1024,           -- 2 MB
  bfs_traversal_bytes = 1 * 1024 * 1024,       -- 1 MB
}
```

**Debug commands** (init.lua):
- `:VaultCoalescerStats` (init.lua:1044-1061, registered in palette at line 1062) — Shows total operations, coalesced count, cancelled, in-flight, coalesce rate, and "duplicate requests avoided" summary via `notify.info_lines()`
- `:VaultCoalescerDebug` (init.lua:1064-1077, registered in palette at line 1077) — Lists in-flight operations with pending keys and waiter counts; shows "(none)" if empty
- Coalescer configured at init.lua:246: `require("andrew.vault.request_coalescer").configure(config.coalescer)`

## Remaining Problem

Despite the existing `request_coalescer`, there are architectural gaps that limit its usefulness in certain scenarios:

1. **Singleton architecture** — `request_coalescer` is a single global registry with module-level `_in_flight` and `_stats` tables. All modules share one namespace and one `max_waiters`/`timeout_ms` configuration, making it impossible to set different policies per use case (e.g., 5s timeout for BFS lookups vs. 30s for index rebuilds).

2. **No subscriber lifecycle management** — Once a callback is added to `entry.waiters`, it cannot be individually removed. The only option is `cancel(key)` which cancels the entire operation for all waiters via `_resolve_entry(key, nil, "cancelled")`. This prevents cleanup when a single subscriber (e.g., one embed line or one search evaluator) is no longer needed.

3. **No late-arrival handling** — Entries are removed from `_in_flight` immediately in `_resolve_entry()` before invoking waiter callbacks. If a new `request()` arrives after removal but during the same event loop tick (e.g., from a waiter callback), it starts a fresh operation rather than receiving the just-computed result.

4. **Cross-module BFS sharing gap** — `search_filter/graph_traversal.lua` and `graph_filter/traversal.lua` both delegate to `bfs.lua` but maintain independent result caches:
   - `search_filter/graph_traversal.lua`: No traversal-level cache at all (only AST query-level cache by `graph_id`)
   - `graph_filter/traversal.lua`: Sophisticated LRU `_bfs_cache` keyed by `center_rel` with incremental depth extension
   - When both modules compute BFS from the same center node with the same depth during the same event loop cycle, the BFS traversal runs twice. The graph_filter cache is not accessible to search_filter.

5. **No per-subscriber cancellation** — Cannot remove a single subscriber from an in-flight operation. Useful for UI components that unmount while an operation is pending. Currently embed.lua works around this by using `coalescer.cancel(key)` to cancel the entire render and restart (line 472), rather than removing a single embed's interest.

## Inspiration

### Zed's `Shared<Task<...>>` Pattern

Zed uses `Shared<Task<...>>` extensively (**49 occurrences** across the codebase as of March 2026) for async deduplication. The pattern appears in several variations:

#### 1. HashMap Deduplication (git_store.rs:77-78)

```rust
loading_diffs: HashMap<(BufferId, DiffKind), Shared<Task<Result<Entity<BufferDiff>, Arc<anyhow::Error>>>>>,
```

File: `crates/project/src/git_store.rs` (struct at line 70, field at lines 77-78, init at line 405)

Lifecycle:
1. First caller: `.entry(key).or_insert_with(|| { cx.spawn(...).shared() })` — creates and stores shared task (lines 592-609 for unstaged, lines 649-650 for uncommitted)
2. Subsequent callers: `.clone()` the existing `Shared` handle, `.await` the same result
3. On completion: `.remove(&key)` clears the entry (lines 680, 693 — both success and error paths); next request starts fresh

Same pattern used across 10+ modules:
- `buffer_store.rs` (line 36) — `loading_buffers: HashMap<ProjectPath, Shared<Task<...>>>` (uses match on Entry Occupied/Vacant at lines 795-796, remove at line 817, public iterator `loading_buffers()` at lines 936-942)
- `worktree_store.rs` (lines 63-64) — `loading_worktrees: HashMap<SanitizedPath, Shared<Task<...>>>` (contains_key guard at line 220, insert at lines 240-241, clone at line 243, remove at line 246)
- `environment.rs` (line 18) — `environments: HashMap<Arc<Path>, Shared<Task<Option<HashMap<String, String>>>>>` (entry().or_insert_with at lines 135-138)
- `indexed_docs/store.rs` (line 60) — `indexing_tasks_by_package: RwLock<HashMap<PackageName, Shared<Task<...>>>>` (RwLock for thread safety, return type at line 141, write remove at line 156, write insert at lines 189-191; also `database_future: Shared<BoxFuture<...>>` at line 57)
- `debugger/session.rs` (line 692) — `requests: HashMap<TypeId, HashMap<RequestSlot, Shared<Task<Option<()>>>>>` (struct at line 673, multi-level dedup via nested entry().or_default() at lines 1595-1597, remove at line 1676, entry().and_modify() at lines 1692-1696)
- `debugger/dap_store.rs` (line 873) — `load_shell_env_task: Shared<Task<Option<HashMap<String, String>>>>` in DapAdapterDelegate (struct at lines 865-896, constructor param at line 884)
- `project/src/lsp_store.rs` — `DocumentColorTask = Shared<Task<Result<DocumentColors, Arc<anyhow::Error>>>>` type alias (line 3563) + `colors_update: Option<(Global, DocumentColorTask)>` (line 3570) + `fetch_document_colors_for_buffer()` returns `Option<DocumentColorTask>` (line 6603) + calls environment at line 9875 returning `Shared<Task<Option<HashMap<String, String>>>>` + `load_shell_env_task: Shared<Task<Option<HashMap<String, String>>>>` (line 12256)
- `project/src/prettier_store.rs` — `installation_task: Option<Shared<Task<...>>>` (line 791) + `PrettierTask = Shared<Task<Result<Arc<Prettier>, Arc<anyhow::Error>>>>` type alias (line 797) + `prettier: Option<PrettierTask>` (line 802)
- `project.rs` — `get_buffer_environment()` and `get_directory_environment()` return `Shared<Task<...>>` (delegates to environment.rs at lines 1804, 1814; `get_buffer_environment()` at environment.rs:65, `get_worktree_environment()` at environment.rs:91, `get_directory_environment()` at environment.rs:125)
- `call/src/call_impl/mod.rs` (line 77) — `pending_room_creation: Option<Shared<Task<Result<Entity<Room>, Arc<anyhow::Error>>>>>` for collaborative room creation dedup (initialized at line 96, cloned at line 185, set at line 237, checked at line 301/350)

#### 2. Enum State Machine (channel_store.rs:148-151)

File: `crates/channel/src/channel_store.rs`

```rust
enum OpenEntityHandle<E> {
    Open(WeakEntity<E>),
    Loading(Shared<Task<Result<Entity<E>, Arc<anyhow::Error>>>>),
}
```

The `Loading` → `Open` transition (via `open_channel_resource` at lines 500-556):
- While loading: new requests clone the `Loading` task (no duplicate work) (clone at line 522)
- On success: enum transitions to `Open(entity.downgrade())` — stores weak reference (Task::ready at line 514-516, .shared() at line 538, stored at line 540, Open transition at line 547)
- On error: entry removed from map
- When weak ref upgrade fails: entry removed, next access triggers fresh load

Same enum pattern used in:
- `copilot.rs` (lines 152-157) — `CopilotServer::Starting { task: Shared<Task<()>> }` (line 154) + `SignInStatus::SigningIn { task: Shared<Task<Result<(), Arc<anyhow::Error>>>> }` (line 193) + public `Status::Starting { task: Shared<Task<()>> }` (line 203) + `reinstall()` returns `Shared<Task<()>>` (line 754)
- `semantic_index/src/worktree_index.rs` (lines 17-24) — `WorktreeIndexHandle::Loading { index: Shared<Task<...>> }` paired with `Loaded { index: Entity<WorktreeIndex> }`
- `repl/src/kernels/mod.rs` — `Kernel::StartingKernel(Shared<Task<()>>)` (line 196) in multi-variant enum, with separate `KernelStatus` enum mapped via `status()` method
- `assistant_context/src/assistant_context.rs` — `PendingSlashCommandStatus::Running { _task: Shared<Task<()>> }` (line 3012) + `PendingToolUseStatus::Running { _task: Shared<Task<()>> }` (line 3028) + `image: Shared<Task<Option<LanguageModelImage>>>` (line 635 in Content enum) (three distinct shared task patterns in one file)
- `agent/src/tool_use.rs` — `PendingToolUseStatus::Running { _task: Shared<Task<()>> }` (enum at lines 545-552, Running variant at line 550; mirrors assistant_context pattern)

#### 3. Eager Memoization (image_cache.rs:168-199)

File: `crates/gpui/src/elements/image_cache.rs`

Type alias at line 165: `pub type ImageLoadingTask = Shared<Task<Result<Arc<RenderImage>, ImageCacheError>>>`

Enum at lines 168-173:
```rust
pub enum ImageCacheItem {
    Loading(ImageLoadingTask),
    Loaded(Result<Arc<RenderImage>, ImageCacheError>),
}
```

`get()` method at lines 189-198:
```rust
impl ImageCacheItem {
    pub fn get(&mut self) -> Option<Result<Arc<RenderImage>, ImageCacheError>> {
        match self {
            ImageCacheItem::Loading(task) => {
                let res = task.now_or_never()?;  // Non-blocking poll (line 192)
                *self = ImageCacheItem::Loaded(res.clone());  // Cache result (line 193)
                Some(res)
            }
            ImageCacheItem::Loaded(res) => Some(res.clone()),
        }
    }
}
```

Combines shared futures with enum mutation: on first completion, the `Loading` variant is replaced with `Loaded`, avoiding repeated task polling in hot paths. `RetainAllImageCache` inserts `ImageCacheItem::Loading(task.clone())` at line 271 with task created via `cx.background_executor().spawn(fut).shared()` at line 270.

#### 4. Connection Pool with Weak References (ssh_session.rs:1277-1280)

File: `crates/remote/src/ssh_session.rs`

```rust
enum ConnectionPoolEntry {
    Connecting(Shared<Task<Result<Arc<dyn RemoteConnection>, Arc<anyhow::Error>>>>),
    Connected(Weak<dyn RemoteConnection>),
}
```

- `Connecting` variant at line 1278
- Stored in `struct ConnectionPool { connections: HashMap<SshConnectionOptions, ConnectionPoolEntry> }` (lines 1283-1285), implements `Global` (line 1287) for singleton access
- `connect()` method (lines 1290-1352): returns `Shared<Task<...>>` (return type at line 1295), matches on existing entry — returns clone if `Connecting`, upgrades weak ref if `Connected`, removes stale if upgrade fails
- `Connecting` state: multiple callers share the same connection task
- `Connected` state: stores `Weak` ref — when all `Arc` holders drop, the weak upgrade fails, triggering reconnection on next access
- Transition: `Connecting` → `Connected` upon successful connection

#### 5. Generation/Version Tracking (channel_store.rs:31)

File: `crates/channel/src/channel_store.rs` (lines 31-34)

```rust
struct NotesVersion {
    epoch: u64,               // Generation counter
    version: clock::Global,   // CRDT vector clock
}
```

- `latest_notes_version` vs `observed_notes_version` in `ChannelState` (lines 67-68) — detects staleness
- Public methods delegate to private ChannelState impl: `acknowledge_notes_version` (private lines 1287-1290): joins versions if epochs match, replaces if different
- `update_latest_notes_version` (private lines 1298-1301): same epoch→join, different→replace
- Epoch change: full invalidation. Same epoch, version change: incremental update
- Pattern applicable to vault index generation tracking (already implemented as `_generation` counter)

#### 6. Global Initialization Wrapper (prompt_store.rs:462)

File: `crates/prompt_store/src/prompt_store.rs`

```rust
pub struct GlobalPromptStore(Shared<Task<Result<Entity<PromptStore>, Arc<anyhow::Error>>>>);
```

Newtype pattern wrapping `Shared<Task>` for use as a GPUI context global (implements `Global` at line 464). Init at lines 32-43 uses `cx.spawn(...).shared()` then `cx.set_global(GlobalPromptStore(...))`. Access via GPUI's `cx.global()` pattern (standard Global trait).

#### 7. Return Type Pattern (workspace.rs, copilot.rs)

Methods return `Shared<Task<...>>` to allow callers to await duplicate operations:
- `copilot/src/copilot.rs` `reinstall()` (line 754) → `Shared<Task<()>>` (creates via `.shared()` at line 770, stores in `CopilotServer::Starting { task }`)
- `workspace/src/workspace.rs` `send_keystrokes_impl()` (line 2334) → `Shared<Task<()>>` (task assigned at line 2345)
- `gpui/src/app.rs` `fetch_asset()` (line 1674) → `(Shared<Task<A::Output>>, bool)` with first-load flag (stores in `loading_assets` HashMap at line 253, keyed by `(TypeId, hash(source))`, downcast at line 1680)

#### 8. AI/Agent Patterns (agent/)

- `agent/src/thread.rs` (line 383) — `initial_project_snapshot: Shared<Task<Option<Arc<ProjectSnapshot>>>>` (lazy init at lines 479-484 via `cx.foreground_executor().spawn(...).shared()`, deserialization at line 610 via `Task::ready(...).shared()`, serialized at lines 1181-1183)
- `agent/src/context.rs` (line 736 in `ImageContext` struct, lines 730-738) — `image_task: Shared<Task<Option<LanguageModelImage>>>` (uses `now_or_never()` for non-blocking poll in `image()` at line 757 and `status()` at line 761)
- `repl/src/notebook/cell.rs` (line 119) — `notebook_language: Shared<Task<Option<Arc<Language>>>>` (passed as parameter to `Cell::load()`)

#### 9. Additional Shared<Task> Patterns (Not Individually Documented Above)

| File | Field/Type | Purpose |
|------|-----------|---------|
| `agent_ui/src/message_editor.rs` (line 90) | `load_context_task: Option<Shared<Task<()>>>` | Tracks context loading state for agent UI |
| `assistant_tools/src/terminal_tool.rs` (line 48) | `determine_shell: Shared<Task<String>>` | Caches shell detection (one-time lazy init, created at lines 55-70 via `cx.background_spawn(...).shared()`) |
| `editor/src/editor.rs` (line 1160) | `load_diff_task: Option<Shared<Task<()>>>` | Diff loading state; `wait_for_diff_to_load()` (line 20968) exposes task to callers; set at lines 1943, 20028 |
| `gpui/src/app.rs` (line 1674) | `fetch_asset<A>() → (Shared<Task<A::Output>>, bool)` | Asset cache with first-load flag, keyed by `(TypeId, hash(source))` in `loading_assets` HashMap (line 253), downcast at line 1680 |
| `recent_projects/src/remote_servers.rs` (line 105) | `_path_task: Shared<Task<Option<()>>>` | SSH path resolution tracking (init at line 166, assigned at line 240) |
| `repl/src/notebook/cell.rs` (line 119) | `notebook_language: Shared<Task<Option<Arc<Language>>>>` | Language detection passed to `Cell::load()`, referenced in CodeCell at line 210 |
| `workspace/src/workspace.rs` (line 1050) | `task: Option<Shared<Task<()>>>` | In `DispatchingKeystrokes` struct (line 1047); `send_keystrokes_impl()` returns `Shared<Task<()>>` (line 2334) |
| `project/src/environment.rs` (lines 65, 91, 125) | `get_buffer_environment()` / `get_worktree_environment()` / `get_directory_environment()` → `Shared<Task<Option<HashMap<String, String>>>>` | Shell environment caching; delegated from project.rs (lines 1804, 1814) |

#### Key Cross-Cutting Patterns

| Pattern | Zed Usage | Lua Equivalent |
|---------|-----------|---------------|
| `.entry().or_insert_with()` | Atomic check-and-insert (environment.rs:135) | `if not pool[key] then pool[key] = ... end` |
| `.shared()` | Enable multiple awaiters | Callback list on promise object |
| `.clone()` on Shared | Cheap handle duplication | Table reference sharing |
| `Arc<anyhow::Error>` | Share error across boundaries | `err` string in callback |
| `WeakEntity` / `Weak` | Auto-cleanup on GC (ssh_session.rs Connected variant) | Not directly available in Lua |
| `now_or_never()` | Non-blocking poll (image_cache.rs:192, context.rs:757, 761) | Check `promise.done` flag |
| `util::defer` | Guaranteed cleanup | pcall + manual cleanup |
| Newtype wrapper | `GlobalPromptStore(Shared<...>)` | Module-level singleton table |
| Multi-level HashMap | `HashMap<TypeId, HashMap<Slot, Shared>>` (session.rs:692) | Nested table: `pool[category][key]` |
| `RwLock<HashMap<...>>` | Thread-safe shared map (indexed_docs/store.rs:59) | Not needed in single-threaded Lua |
| `Option<Shared<Task>>` | Optional in-progress tracking (editor.rs:1160, prettier_store.rs:791, message_editor.rs:90) | `if pending then ... end` |
| Type alias | `PrettierTask`, `DocumentColorTask`, `ImageLoadingTask` | Not applicable (duck typing) |

## Design

### Option A: Extend `request_coalescer.lua` (Recommended)

Rather than creating a new `shared_promise.lua` module, extend the existing `request_coalescer` to support the missing capabilities:

#### 1. Pool Factory — `M.new(opts)`

Allow creating independent pools with per-pool configuration:

```lua
-- Current (singleton):
local coalescer = require("andrew.vault.request_coalescer")
coalescer.request("key", fn, cb)

-- Extended (pool instances):
local coalescer = require("andrew.vault.request_coalescer")
local bfs_pool = coalescer.new({
  max_waiters = 10,
  timeout_ms = 5000,
  name = "bfs",  -- for debug logging
})
bfs_pool:request("bfs:note-a:2:both", fn, cb)
```

The existing singleton API continues to work (backwards compatible). `M.new()` returns pool objects with identical method signatures but independent state.

#### 2. Per-Subscriber Cancellation

Return a handle from `request()` that can cancel a single subscriber:

```lua
local handle = pool:request("key", compute_fn, callback)
-- Later, if this subscriber no longer needs the result:
handle:cancel()
-- If no subscribers remain, the operation is automatically cancelled
```

#### 3. Late-Arrival Safety

If a callback is registered for a key that just resolved (done but not yet garbage collected), invoke the callback immediately with the cached result:

```lua
function M:request(key, compute_fn, callback)
  local entry = self._in_flight[key]
  if entry then
    if entry.done then
      -- Late arrival: result already available
      vim.schedule(function() callback(entry.result, entry.err) end)
      return { cancel = function() end }
    end
    -- Join in-flight...
  end
  -- Start new...
end
```

#### 4. Shared BFS Pool

Create a dedicated BFS pool shared between `search_filter.lua` and `graph_filter/traversal.lua`:

```lua
-- In a new shared module or in bfs.lua:
local bfs_pool = coalescer.new({ timeout_ms = 5000, name = "bfs" })

function M.traverse_shared(opts, callback)
  local key = opts.center .. ":" .. opts.max_depth .. ":" .. opts.direction
  bfs_pool:request(key, function(resolve)
    local result = bfs.traverse(opts)
    resolve(result)
  end, callback)
end
```

### Option B: New `shared_promise.lua` Module

Create a standalone module as originally proposed. This has the advantage of a clean API surface but introduces a second deduplication primitive alongside `request_coalescer`.

**Recommendation:** Option A is preferred because:
- Avoids two parallel deduplication systems
- Existing integrations (5 modules) don't need migration
- The pool factory pattern (`M.new()`) gives the same isolation benefits
- Debug commands (`VaultCoalescerStats`, `VaultCoalescerDebug`) already exist and can be extended

## Target Operations (Updated)

### 1. BFS Graph Traversal — Shared Pool (NEW)

**Current state:** Two independent BFS consumers with no cross-module sharing:
- `search_filter/graph_traversal.lua` (231 lines) — Calls `bfs.traverse()` / `bfs.traverse_async()` via `collect_reachable()` (line 67-73) and `collect_reachable_async()` (line 152-164). Zero traversal-level caching; only AST query-level dedup within a single `precompute_graph_sets()` call (`sets[graph_id] = reachable` at line 130). Each search evaluation does fresh BFS.
- `graph_filter/traversal.lua` (338 lines) — Sophisticated LRU `_bfs_cache` keyed by `center_rel` (lines 36-41, 1 MB budget, 100 max items) with three-outcome cache check (exact/extend/miss at lines 149-208), incremental depth extension via frontier resumption, generation+state_hash validation, pre-sorted immutable cached data (lines 247-248), and copy-on-read semantics to prevent caller mutation of cache.

**Proposed:** Single `bfs_pool` shared between both modules. Key: `center_rel .. ":" .. depth .. ":" .. direction`.

**Impact:** When a `graph:` search filter and graph visualization are active simultaneously for the same center node, BFS is computed once instead of twice. Note: the graph_filter's incremental extension cache is more sophisticated than what coalescer provides — a shared pool would handle concurrent deduplication only, not replace the incremental cache.

### 2. vault_index.build_async() — ALREADY DONE

Already uses `coalescer.request("index_rebuild", ...)` at vault_index_build.lua:281. Multiple concurrent callers join the existing build. No changes needed.

### 3. Cross-file content reads in embed.lua — ALREADY DONE

4-layer caching: `file_cache.lua` (LRU weighted, mtime-validated) → `frame_cache.lua` (two-generation, per-embed virt_lines) → `warm_embed_cache()` (seen-set dedup) → request coalescer (`"embed_render:" .. bufnr`). Each unique file is read exactly once per render cycle. No changes needed.

### 4. Completion source rebuilds — ALREADY DONE

Generation tracking (`_cached_gen` vs `vault_index._generation` at completion_base.lua:337) prevents redundant rebuilds. `build_kv_single_pass()` memoized by `vault_path .. "\0" .. field_name` with generation validation (completion_base.lua:619-717), shared between frontmatter/inline_fields sources. Debounce via `resource_cleanup.debounce()` at 250ms. Cancellation via `active_state.cancelled` + `build_generation` counter. No changes needed.

### 5. Ripgrep Searches — Potential Future Target

Concurrent searches with identical queries (e.g., triggered by debounce overlap) could share the same ripgrep subprocess result. Key: hash of query string + search scope. Note: `search_filter.lua:evaluate_async()` already coalesces at the evaluation level via `"search:" .. ast_hash(ast)` key (lines 503-570), but the underlying ripgrep subprocess calls are not coalesced.

**Priority:** Low. The existing debounce in `search.lua` + evaluate_async coalescing already prevents most duplicate ripgrep invocations.

### 6. URL Validation in Link Diagnostics — Check Current State

Multiple links to the same URL in a buffer could share one HTTP HEAD request. This was the original motivation for `request_coalescer` (generalized from `url_validate._inflight`).

**Priority:** Low if already handled by `request_coalescer` integration.

## Implementation Steps (Revised) — ALL COMPLETE

1. **Add `M.new(opts)` pool factory to `request_coalescer.lua`** ✅
   - Returns pool instance with identical API to singleton
   - Per-pool `max_waiters`, `timeout_ms`, `done_linger_ms`, `name`
   - Dead singleton delegate methods removed (all 6 consumers use pool instances)

2. **Add per-subscriber cancellation** via returned handle objects ✅
   - `handle:cancel()` removes single callback from waiter list
   - Auto-cancel operation when last subscriber removed

3. **Add late-arrival safety** — `done_linger_ms` keeps resolved entries for late arrivals ✅

4. **Shared BFS pool** — REVERTED ✅
   - `bfs_shared.lua` was initially created with a coalescer pool, but BFS callers depend on
     side effects (mutation of `opts.visited`, invocation of `on_discover` callbacks) that cannot
     be shared across coalesced requests. Coalesced second callers would get empty results.
   - `bfs_shared.lua` now delegates directly to `bfs.lua` without coalescing.
   - Deduplication is already handled at higher levels: graph_filter's LRU `_bfs_cache` with
     incremental extension, and search_filter's AST-level coalescing via `evaluate_async()`.
   - BFS pool config removed from `config.coalescer.pools`.

5. **Extend debug commands** ✅
   - `:VaultCoalescerStats` shows per-pool stats
   - `:VaultCoalescerDebug` groups in-flight by pool name

6. **Add pool-level configuration** to `config.lua` ✅
   - 5 named pools: url_validate, embed, search, index_rebuild, connections
   - Late-registered pools receive stored config via `_pool_configs`

## Difference from Doc 25 (Concurrent Request Deduplication)

Doc 25 (if it exists in the improvement plans) focuses on **request coalescing**: batching multiple requests that arrive within a time window into a single operation. For example, debouncing 10 rapid `build_async()` calls within 200ms into one call.

This document (Doc 39) focuses on **result sharing**: if an operation is already in-flight when a new request arrives, the new request joins the existing operation rather than starting a duplicate. The distinction:

| Aspect | Doc 25: Coalescing | Doc 39: Shared Future |
|--------|--------------------|-----------------------|
| Trigger | Multiple requests in time window | Request while operation in-flight |
| Mechanism | Debounce/batch, start one operation | Join existing operation |
| When work starts | After debounce window closes | Immediately on first request |
| Latency | Added latency (debounce delay) | No added latency |
| Result sharing | No (each batch produces its own result) | Yes (all joiners get same result) |

They are complementary: coalescing reduces the number of operations started, shared futures ensure that operations which do start are not duplicated. The existing `request_coalescer.lua` already implements the shared future pattern at its core — this document proposes extending it with pool isolation and subscriber lifecycle management.

## Expected Impact (Revised)

### Already Realized

The following savings are **already in effect** via existing infrastructure:

- **vault_index.build_async()**: Multiple concurrent `BufEnter`/`BufReadPost` triggers coalesce into one build (via `request_coalescer` with `"index_rebuild"` key at vault_index_build.lua:281)
- **embed.lua**: 4-layer cache stack — file_cache LRU (5 MB, mtime-validated), frame_cache (two-generation virt_lines with promotion at lines 264-276/369-372), warm_embed_cache (seen-set dedup at line 530), request_coalescer (`"embed_render:" .. bufnr` with is_pending/cancel/request/_resolve_entry at lines 466-614)
- **Completion sources**: Generation tracking (`_cached_gen` vs `_generation` at completion_base.lua:337) prevents redundant rebuilds; `build_kv_single_pass()` memoization via module-level `_field_cache` (line 107) shared across frontmatter/inline_fields sources; debounce + cancellation via `active_state.cancelled` (line 345) + `build_generation` counter (line 173)
- **Search evaluation**: `evaluate_async()` coalesces identical search ASTs via `"search:" .. ast_hash(ast)` key (search_filter.lua:503-570, with separate join path for in-flight at lines 513-527)
- **Connection scoring**: `"connections:" .. source_rel_path` prevents duplicate scoring computations (connections.lua:771)
- **BFS (graph_filter)**: LRU `_bfs_cache` with three-outcome cache check (exact/extend/miss at traversal.lua:149-208), incremental depth extension via frontier resumption, pre-sorted immutable cached data (1 MB, 100 entries), generation+state_hash validation
- **Race conditions**: Staged apply pattern in `vault_index` eliminates interleaved writes

### Remaining Gains from This Proposal

- **Cross-module BFS sharing**: When graph search filter and graph visualization run simultaneously, BFS traversal runs twice (once in `search_filter/graph_traversal.lua` uncached via `collect_reachable()` at line 67-73, once in `graph_filter/traversal.lua` cached via `collect_at_depth_async()` at line 282-315). A shared pool would eliminate the duplicate traversal. Note: result shapes differ — search_filter needs flat `{rel_path → true}` sets, graph_filter needs classified node lists (forward_like/backlink_like/all_nodes) — so a shared pool would need to operate at the raw BFS level, with each consumer post-processing. Also note: graph_filter's incremental depth extension cache (frontier resumption) is more sophisticated than what a coalescer pool can provide — the pool would handle concurrent dedup only, not replace the LRU cache.
- **Per-pool configuration**: Different timeout/capacity policies per use case. Currently all 4 coalescer consumers share `max_waiters=50, timeout_ms=30000` (config.lua:877-881). Search evaluations and embed renders have very different timeout requirements.
- **Subscriber lifecycle**: Proper cleanup when UI components unmount during in-flight operations. Currently embed.lua works around this by cancelling the entire render (`coalescer.cancel(key)` at line 472) and restarting, rather than removing a single subscriber's interest. The `request()` API returns no handle — once a callback is in `entry.waiters`, it cannot be individually removed (only `cancel(key)` which notifies all waiters with "cancelled" error).
- **Debug visibility**: Per-pool stats enable targeted performance analysis. Current `:VaultCoalescerStats` (init.lua:1044-1061) and `:VaultCoalescerDebug` (init.lua:1064-1077) show only aggregate counts across all 4 consumers. VaultCoalescerDebug lists pending keys with waiter counts (iterates `pending_keys()` with `waiter_count()`).
