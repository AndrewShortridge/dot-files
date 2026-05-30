# 19. Weak Table GC Integration

**Priority:** MEDIUM
**Phase:** 2 (Scalability)
**Dependencies:** None (standalone pattern)
**Inspired by:** Zed's `Weak<>`/`WeakEntity<>` reference patterns across 50+ files (934 `WeakEntity` uses, 47 `Weak<>` uses). Core patterns in: `ssh_session.rs:1277-1340,2300`, `client.rs:420-449`, `buffer.rs:128,2006-2022`, `text/subscription.rs:8-48`, `extension_host.rs:120,1707`, `image_store.rs:277-343`, `agent_diff.rs:119-143,960,1283-1297`, `semantic_index.rs:33,241-248`, `indexing.rs:17,42-48`, `proto_client.rs:17-33,56`, `terminals.rs:27,404-415`, `context_store.rs:66-85`, `inline_completion_registry.rs:17`, `workspace.rs:849-851,1071,1073,1083`, `message_editor.rs:80`, `lsp.rs:177`. Additional patterns in: `livekit_client/playback.rs:32,144,156` (Weak<Task<T>>), `async_context.rs:18+` (Weak<AppCell>), `connection_manager.rs:20+` (WeakEntity<Project> sets), `server_tree.rs:50+` (Weak<InnerTreeNode> newtypes), `telemetry.rs:233+` (async shutdown detection), `entity_map.rs:90` (slot reservation), `mac_watcher.rs:14+` (Weak<BTreeMap> for file watcher cleanup), `peer.rs:511` (stream cancellation), plus 30+ UI components (`agent_panel.rs`, `context_picker.rs`, `inline_prompt_editor.rs`, `terminal_inline_assistant.rs`, `quick_action_bar.rs`, `component_preview.rs`, etc.)

---

## Problem

Multiple vault modules maintain caches keyed by objects that may become unreachable (buffers, file paths, parsed data). While explicit BufDelete/BufWipeout cleanup is now comprehensive, weak tables can serve as a **defense-in-depth safety net** — automatically reclaiming memory for computed results that outlive their usefulness even when no buffer event fires.

### Current State: Buffer-Keyed Caches (All Have Explicit Cleanup)

All buffer-keyed caches now have proper BufDelete/BufWipeout cleanup via `resource_cleanup.on_buf_delete()` or `highlight_coordinator.setup_buf_cleanup()`:

1. **link_scan.lua** — `_code_exclusion_cache[bufnr]` (line 10), `_frontmatter_cache[bufnr]` (line 11) (cleanup via `M.clear_cache` + `on_buf_delete`, lines 165-172)
2. **footnotes.lua** — `_fn_cache[bufnr]` (line 20), `footnotes_visible[bufnr]` (line 19) (cleanup via `hl_coord.setup_buf_cleanup`, line 640; cached via `hl_coord.cached_value`, line 153)
3. **task_hierarchy.lua** — `_vtext_cache[bufnr]` (line 27), `_timers[bufnr]` (line 19), `_tree_cache` (gen_cache, lines 260-293) (cleanup via `on_buf_delete`, lines 526-529; engine cache registration lines 534-560; `M.teardown()` lines 567-571)
4. **highlights.lua** — `_nav_cache[bufnr]` (line 11) (cleanup via `hl_coord.setup_buf_cleanup`, line 145; coordinated update via `hl_coord.make_coordinated_update`, line 109)
5. **tag_highlights.lua** — `_nav_cache[bufnr]` (line 11) (cleanup via `hl_coord.setup_buf_cleanup`, line 217; coordinated update line 181)
6. **inline_fields.lua** — `_field_cache[bufnr]` (line 14) (cleanup via `hl_coord.setup_buf_cleanup`, line 448; changedtick validation lines 339-343)
7. **frontmatter_parser.lua** — `_fm_range_cache[bufnr]` (line 139) (cleanup via `on_buf_delete`, lines 142-143; changedtick validation lines 152-159)
8. **callout_folds.lua** — `_block_cache[bufnr]` (line 14) (cleanup via `on_buf_delete`, line 309; engine cache registration lines 311-334; `M.teardown()` lines 376-381 saves DB on VimLeavePre)
9. **embed_state.lua** — 7 registered state dicts: `embeds_visible` (line 13), `image_placements` (line 14), `_embed_deps` (line 15), `_sync_timers` (line 16), `_image_retry_fired` (line 17), `_embed_descriptors` (line 19), `_scroll_timers` (line 20) — all cleaned via `_state_dicts` registry (line 24) with `register_state()` (lines 26-28) and per-dict custom cleanup functions (lines 42-65)
10. **autolink.lua** — `matches_by_extmark` (line 38, extmark_id → AutoLinkMatch) with `clear(bufnr)` (lines 46-53) removing extmark entries before namespace clearing. Cleanup via `cleanup.on_buf_delete` (line 353, `{ pattern = "*.md" }`)
11. **autosave.lua** — `_timers[bufnr]` (line 19) (cleanup via `remove_autocmds()` which closes all pending timers, line 131; debounce via `cleanup.debounce`, line 86)
12. **wikilink_highlights.lua** — extmarks only, no cache tables (cleanup delegated to highlight_coordinator)
13. **highlight_coordinator.lua** — `_timers[bufnr]` (line 206) (cleanup via `on_buf_delete`, lines 307-309; debounce at line 233; `M.teardown()` lines 321-325 closes all timers on VimLeavePre)
14. **embed.lua** — delegates to `state.clear_buffer_state(bufnr)` via embed_state; uses `update_deps(bufnr, deps)` for per-buffer dependency management
15. **sidebar.lua** — `_state` singleton (lines 26-34) with `update_timer` (line 33) (cleanup via `close_sidebar()` lines 136-147 + `on_buf_delete_once()` lines 126-130)
16. **task_timeline.lua** — `_timeline_cache` using `task_utils.gen_cache()` (lines 30-71) with custom `key_fn` (cleanup via generation-based invalidation, no explicit BufDelete needed since cache is global). Also `_render_cache` (line 246) for render state.
17. **navigate.lua** — `_weekly_cache` (line 11, `{ dir_mtime, reviews }` structure) for weekly review render cache
18. **graph/render.lua** — `_pad_cache` (line 19, setmetatable-based with custom `__index`)
19. **embed_images.lua** — `_image_cache` (line 42, simple LRU via `lru.new(config.cache.image_path_max)`) for image path resolution
20. **url_validate.lua** — Disk-persisted URL validation cache (`_cache`, line 16) with debounced writes. Also `_inflight` (line 10), `_domain_last_request` (line 13), `_cache_dirty` (line 18), `_persist_timer` (line 19)
21. **search/live.lua** — `_prev_cache` (line 38, `{ query, ast, file_set, gen }`) for incremental search filtering with generation-based invalidation
22. **search/stats.lua** — `_agg_cache` (line 8, `{ gen, fields }`) for field value aggregation, manually generation-tracked (not using gen_cache module)
23. **frontmatter_editor.lua** — `_state._render_cache` (line 77, `{ kw, disp_values }`) for cached rendering data reused in float_dimensions
24. **breadcrumbs.lua** — `M._click_targets` (line 44) lookup table mapping minwid indices to directory paths
25. **embed_images.lua** — additional: `_image_cache_generation` (line 45), `_last_cache_generation` (line 46), `_last_hit_idx` (line 49, locality heuristic)

**Function-scoped temporary caches (not persistent, no cleanup needed):**
- **linkcheck.lua** — `heading_cache`, `block_id_cache` (lines 158-160, created fresh per `M.check_buffer()` call)
- **linkdiag.lua** — `heading_cache` (line 146, per-`M.validate()` call, `filepath -> slug_set`)
- **backlinks.lua** — `file_lines_cache` (lines 86, 90, 110, per-function call for batched file reads)
- **sidebar_backlinks.lua** — `file_lines_cache` (line 45, passed through for inlink source caching)
- **filter_utils.lua** — optional `cache` parameter in `resolve_in_index()` (lines 80-100, caller-provided dedup cache); memoized resolver factory `create_memoized_resolver()` (lines 50-62)

**These are NOT leak targets.** Explicit cleanup is deterministic and preferable for buffer lifecycle. Weak tables are unnecessary here.

### Remaining Opportunities for Weak Tables

1. **Computed data caches with no lifecycle event:**
   - Graph BFS traversal results (`_bfs_cache` in `graph_filter/traversal.lua`, line 31) — uses **weighted LRU** (`lru.new_weighted({ max_bytes, max_items, weigher })`) with memory-bounded eviction + generation-based staleness detection. Entries contain BfsCacheEntry structs (visited sets, frontiers, forward/backlink nodes, memoized resolver).
   - Connection note data (`_note_data_cache` in `connections.lua`, lines 41-45) — **weighted LRU**, entries reference pre-computed ConnectionNoteData (tags, outlinks, inlinks, neighbors, timestamps) per note
   - Connection results (`_cache` in `connections.lua`, lines 22-26) — **weighted LRU** with dependency tracking for per-file invalidation (lines 1001-1011)

2. **Subscriber closures capturing module state:**
   - vault_index `_subscribers` (field at line 107, initialized line 161) list holds closures; `subscribe()` returns unsubscribe closure (lines 203-213); `subscriber_count()` accessor (lines 217-219); `_notify_update()` increments `_generation` (line 224) and calls all subscribers with pcall (lines 223-229). Notification context: `{ changed_paths?, deleted_paths? }` (nil context = full rebuild).
   - connections.lua subscriber closure `on_index_update()` (lines 949-965) captures `_pending_changed`, `_pending_full_clear`, `engine`; subscription via `subscription_handle()` (lines 968-970); `_subscription` stored at line 52; `ensure_subscription()` at lines 974-976; `unsubscribe()` at lines 984-986
   - embed_sync.lua subscriber `M.on_index_update()` (lines 60-96) captures `_dep_to_bufs`, `_dep_index_dirty`, `state`, `config`; subscription via `subscription_handle()` (lines 103-106); lazy init via `init_subscription()` (lines 100-107) with `_subscription_initialized` flag (line 11); `M.ensure_subscription()` (lines 111-114); `M.unsubscribe()` (lines 117-121)
   - Mitigated: `resource_cleanup.subscription_handle()` provides idempotent `ensure()/unsubscribe()` lifecycle with vault-switch detection
   - Weak callbacks would add a second layer of safety

3. **Unbounded non-buffer caches:**
   - `_field_cache` in completion_base.lua (line 89, keyed by `"vault_path\0field_name"`, generation-based memoization, cleared via `M.invalidate_all()` at lines 93-98 but no size bound; registered with engine cache registry at lines 101-113 as `"completions"`)
   - `_idf_cache` in connections.lua (line 32, simple table with `_idf_gen` at line 34 and `_idf_file_tags` at line 35, incrementally updated via `update_tag_idf_incremental()` at lines 109-165)
   - `_prev_cache` in search/live.lua (line 38, `{ query, ast, file_set, gen }`) — incremental search result filtering, generation-based invalidation but no explicit size bound
   - `_agg_cache` in search/stats.lua (line 8, `{ gen, fields }`) — manually generation-tracked field aggregation, unbounded fields table

4. **Additional weighted LRU caches (bounded, defense-in-depth only):**
   - `file_cache.lua` — file content cache (lines 20-24) and section cache (lines 25-29), weighted LRU with `config.cache.file_content_bytes`/`config.cache.section_cache_bytes`. Public API: `read()` (lines 37-69), `get_section()` (lines 76-101), `invalidate()` (lines 106-120), `clear()` (lines 123-129), `stats()` (lines 133-154)
   - `search_filter/match_field.lua` — section outlinks cache (lines 54-58), weighted LRU with `config.cache.section_outlinks_bytes`

5. **Generation-based caches (gen_cache.lua users beyond task_hierarchy/timeline):**
   - `task_notify.lua` — overdue tasks cache (line 18)
   - `task_kanban.lua` — kanban board cache (line 35)
   - `calendar.lua` — deadline cache (line 123) and log cache (line 177)
   - `query/init.lua` — query index cache (line 19)

### Existing Infrastructure

The following cleanup mechanisms are already in place:

- **`resource_cleanup.on_buf_delete(group, callback, opts)`** — centralized BufDelete+BufWipeout pair (lines 81-87). Used by 14+ modules including link_scan, callout_folds, highlight_coordinator, task_hierarchy, frontmatter_parser, embed.
- **`resource_cleanup.on_buf_delete_once(bufnr, callback)`** — one-shot buffer cleanup (lines 93-99). Used by sidebar.lua (lines 126-130).
- **`resource_cleanup.weak_callback(state, callback)`** — **already implemented** (lines 65-74), creates weak-reference wrapper so callback becomes no-op when state is GC'd. Currently unused by any subscriber.
- **`resource_cleanup.subscription_handle(get_index, on_update)`** — idempotent subscribe/unsubscribe lifecycle with vault-switch detection (lines 130-159). Returns `{ ensure(), unsubscribe(), is_active() }`. Used by connections.lua (lines 968-970) and embed_sync.lua (lines 103-106). Handle stored in embed_state._subscription (line 18).
- **`resource_cleanup` additional helpers:** `close_timer(timer)` (lines 9-17), `close_timer_in(dict, key)` (lines 22-27), `debounce(existing, delay_ms, callback)` (lines 35-41), `repeating(existing, delay_ms, repeat_ms, callback)` (lines 51-57), `close_win(win)` (lines 103-107), `delete_buf(buf)` (lines 111-115), `close_win_buf(win, buf)` (lines 120-123)
- **`highlight_coordinator.setup_buf_cleanup(group, ns, cache_tables)`** — clears extmarks + cache entries on BufDelete, pattern-filtered to `*.md` (lines 124-131)
- **`highlight_coordinator.make_coordinated_update(M, process_fn, cache)`** — creates coordinated update function for highlight modules (used by highlights.lua line 109, tag_highlights.lua line 181)
- **`embed_state.clear_buffer_state(bufnr, opts)`** — unified registry-based buffer state cleanup across 7 state dicts (lines 89-108)
- **`embed_state.gc_stale_buffers()`** — sweeps invalid buffer entries from all state dicts (lines 111-126)
- **`embed_state.register_state(dict, cleanup_fn)`** — registers state dict with optional custom cleanup function (lines 26-28)
- **`engine.register_cache(spec)`** — central cache registry (`_cache_registry` at line 32) with CacheSpec interface (lines 34-39), coordinated invalidation via `invalidate_caches(opts)` (lines 60-113), cache_stats() (lines 117-127), and `:VaultCacheDebug` stats via `cache_debug()` (lines 157-302). LRU config mappings at `LRU_CONFIG_KEYS` (lines 132-141) and `WEIGHTED_CACHE_NAMES` (lines 147-152).
- **`lru_cache.lua`** — two variants: `M.new(max_size)` simple count-bounded LRU (lines 8-93) and `M.new_weighted({ max_bytes, weigher, max_items? })` memory-weighted LRU with doubly-linked list for O(1) promote/evict (lines 114-240). Weighted variant includes `stats()` method (lines 203-211). Used by graph traversal and connections.
- **`string_intern.lua`** — bounded string pool (lines 10-28) with hit/miss stats and all-at-once eviction (lines 44-54). `M.stats()` at lines 68-77. Additional: `M.intern_lower()` (lines 60-63), `M.clear()` (lines 81-84), `M.reset_stats()` (lines 88-91). Used by vault_index folder paths, completion descriptions.
- **`gen_cache.lua`** — standalone generation-based cache factory. `M.gen_cache(build_fn, opts)` (lines 25-55) for single-value caches; `M.keyed_gen_cache(build_fn)` (lines 63-90) for multi-key caches. Uses `package.loaded` for lazy vault_index access. Aliased via `task_utils.gen_cache` (line 169) and `task_utils.keyed_gen_cache` (line 176). Used by: task_hierarchy.lua (`_tree_cache`, lines 260-293), task_timeline.lua (`_timeline_cache`, lines 30-71), task_notify.lua (line 18), task_kanban.lua (line 35), calendar.lua (lines 123, 177), query/init.lua (line 19).
- **`cache_weighers.lua`** — dedicated weigher functions for weighted LRU caches. Provides: `M.lines_entry()` (aliases: `file_content`, `section_lines`), `M.connections()`, `M.note_data()`, `M.section_outlinks()`, `M.bfs_result()`. Used by file_cache.lua, connections.lua, graph_filter/traversal.lua, search_filter/match_field.lua.
- **`file_cache.lua`** — weighted LRU caches for file content (lines 20-24, `config.cache.file_content_bytes`) and section data (lines 25-29, `config.cache.section_cache_bytes`). Registered with engine cache registry.

### Zed's Approach

Zed uses `Weak<T>` references extensively across several patterns:

```rust
// 1. Connection pool auto-cleans expired connections (remote/src/ssh_session.rs:1277-1280)
enum ConnectionPoolEntry {
    Connecting(Shared<Task<Result<Arc<dyn RemoteConnection>, Arc<anyhow::Error>>>>),
    Connected(Weak<dyn RemoteConnection>),  // Auto-invalidates when Arc dropped
}
// ConnectionPool struct (lines 1282-1285) with Global impl (line 1287)
// upgrade() checks liveness, remove() on failure (line 1307):
if let Some(ssh) = ssh.upgrade() {
    if !ssh.has_been_killed() { return Task::ready(Ok(ssh)).shared(); }
}
self.connections.remove(&opts);
// Arc::downgrade() on successful connection (line 1335), remove() on error (line 1340)

// 2. Buffer change tracking with automatic cleanup (language/src/buffer.rs:128, 2006-2022)
change_bits: Vec<rc::Weak<Cell<bool>>>
// record_changes() uses binary_search for dedup insertion (lines 2006-2013)
// was_changed() uses retain() to filter dead weak refs (lines 2015-2022):
self.change_bits.retain(|change_bit| {
    change_bit.upgrade().map_or(false, |bit| { bit.replace(true); true })
});

// 3. Subscriptions use Weak to avoid preventing client Drop (client/src/client.rs:420-449)
pub enum Subscription {
    Entity { client: Weak<Client>, id: (TypeId, u64) },
    Message { client: Weak<Client>, id: TypeId },
}
// Drop impl upgrades safely (lines 431-449) — cleanup skipped if client already dropped
// Entity variant removes from entities_by_type_and_remote_id (line 436)
// Message variant removes from entity_types_by_message_type + message_handlers (lines 443-444)

// 4. Topic/subscriber pattern — retain() auto-prunes dead subscribers (text/src/subscription.rs:8-11, 35-48)
pub struct Topic(Mutex<Vec<Weak<Mutex<Patch<usize>>>>>);
// subscribe() creates Arc, stores downgrade (lines 14-18)
// publish() retains only subscribers that upgrade() successfully (lines 35-48)

// 5. Global app state held via Weak to avoid shutdown ordering issues (workspace/src/workspace.rs:849-851)
struct GlobalAppState(Weak<AppState>);
// global(cx) retrieves weak ref (line 885), try_global() safe variant (line 888), set_global() stores it (line 892)

// 6. Type-safe weak wrappers (rpc/src/proto_client.rs:17-33)
pub struct AnyProtoClient(Arc<dyn ProtoClient>);  // Strong wrapper (lines 17-24)
impl AnyProtoClient {
    pub fn downgrade(&self) -> AnyWeakProtoClient { AnyWeakProtoClient(Arc::downgrade(&self.0)) }
}
pub struct AnyWeakProtoClient(Weak<dyn ProtoClient>);  // Weak wrapper (lines 26-33)
impl AnyWeakProtoClient {
    pub fn upgrade(&self) -> Option<AnyProtoClient> { self.0.upgrade().map(AnyProtoClient) }
}

// 7. SSH client cache with auto-pruning (extension_host/src/extension_host.rs:120, 1707)
pub ssh_clients: HashMap<String, WeakEntity<SshRemoteClient>>,
// WeakEntity<SshRemoteClient> parameter at line 1707 for client management
// Lookup + upgrade check, insertion via downgrade

// 8. Terminal handle cache with release observers (project/src/terminals.rs:27, 404-415)
pub(crate) local_handles: Vec<WeakEntity<terminal::Terminal>>,
// observe_release() auto-removes handle on terminal drop (position-based removal, lines 404-415)
// Getter: local_terminal_handles() (line 613)

// 9. Project index cache with release-based cleanup (semantic_index/src/semantic_index.rs:33)
project_indices: HashMap<WeakEntity<Project>, Entity<ProjectIndex>>,
// Insertion via downgrade (lines 241-243), observe_release removal (lines 245-248)

// 10. Image cache with weak values and upgrade accessor (project/src/image_store.rs:277-343)
image_store: WeakEntity<ImageStore>,  // line 277 in LocalImageStore
opened_images: HashMap<ImageId, WeakEntity<ImageItem>>,  // line 283
// images() iterator filters via upgrade() (lines 333-337):
self.opened_images.values().filter_map(|image| image.upgrade())
// get() also uses upgrade pattern (lines 339-343)

// 11. Multi-level weak maps for editor associations (agent_ui/src/agent_diff.rs:960, 1283-1297)
// WeakEntity<Editor> in enum variant (line 960)
reviewing_editors: HashMap<WeakEntity<Editor>, EditorState>,  // line 1283
workspace_threads: HashMap<WeakEntity<Workspace>, WorkspaceThread>,  // line 1284
singleton_editors: HashMap<WeakEntity<Buffer>, HashMap<WeakEntity<Editor>, Subscription>>,  // line 1297

// 12. Indexing entry cleanup via Drop (semantic_index/src/indexing.rs:17, 42-48)
set: Weak<IndexingEntrySet>,  // line 17 in IndexingEntryHandle
// Drop impl upgrades to remove entry and signal (lines 42-48):
impl Drop for IndexingEntryHandle {
    fn drop(&mut self) {
        if let Some(set) = self.set.upgrade() {
            set.tx.send_blocking(()).ok();
            set.entry_ids.lock().remove(&self.entry_id);
        }
    }
}
// Arc::downgrade() on handle creation (line 33)

// 13. Context store with strong/weak enum (assistant_context/src/context_store.rs:66-85)
enum ContextHandle {
    Weak(WeakEntity<AssistantContext>),
    Strong(Entity<AssistantContext>),
}
// upgrade() and downgrade() dispatch by variant (lines 72-84)

// 14. Message editor with mixed strong/weak entity fields (agent_ui/src/message_editor.rs:80-85)
workspace: WeakEntity<Workspace>,  // line 80
context_store: Entity<ContextStore>,  // line 83 (Strong — refactored from WeakEntity)
// thread_store and text_thread_store also present as WeakEntity fields

// 15. WeakEntity<Editor> as HashMap key (zed/src/zed/inline_completion_registry.rs:17)
let editors: Rc<RefCell<HashMap<WeakEntity<Editor>, AnyWindowHandle>>> = Rc::default();

// 16. LSP handler cleanup via Weak (lsp/src/lsp.rs:177)
io_handlers: Option<Weak<Mutex<HashMap<i32, IoHandler>>>>,

// 17. Weak<Self> as function parameter for async message handling (remote/src/ssh_session.rs:2300)
fn start_handling_messages(this: Weak<Self>, ...)
// Allows spawned async task to hold non-preventing reference to connection

// 18. Weak enum wrapper for polymorphic thread types (agent_ui/src/agent_diff.rs:119-143)
pub enum WeakAgentDiffThread {
    Native(WeakEntity<Thread>),
    AcpThread(WeakEntity<AcpThread>),
}
// upgrade() dispatches by variant (lines 124-130), downgrade() on AgentDiffThread (lines 96-103)
// AgentDiffPane holds workspace: WeakEntity<Workspace> (lines 148, 181)

// 19. AnyWeakEntity in proto message handler set (rpc/src/proto_client.rs:56)
entities_by_message_type: HashMap<TypeId, AnyWeakEntity>,

// 20. WeakEntity<Pane> for workspace pane tracking (workspace/src/workspace.rs:1071-1083)
panes_by_item: HashMap<EntityId, WeakEntity<Pane>>,           // line 1071
last_active_center_pane: Option<WeakEntity<Pane>>,             // line 1073
last_leaders_by_pane: HashMap<WeakEntity<Pane>, CollaboratorId>, // line 1083

// === NEW PATTERNS (not in original doc) ===

// 21. Weak<Task<T>> for deferred background operations (livekit_client/src/livekit_client/playback.rs:32,144,156)
_output_task: RefCell<Weak<Task<()>>>
// start_output() upgrades weak ref; if dead, spawns new task and stores downgrade (lazy singleton)

// 22. Weak<AppCell> for cross-thread async context (gpui/src/app/async_context.rs:18+)
pub(crate) app: Weak<AppCell>,
// Async contexts hold weak ref to detect app shutdown: app.upgrade().context("app was released")?

// 23. WeakEntity<Project> sets for cancellable async ops (project/src/connection_manager.rs:20,49)
projects: HashSet<WeakEntity<Project>>,
// Spawned tasks check upgrade() to detect when owning project is dropped

// 24. Weak<InnerTreeNode> newtype for lazy LSP hierarchy (project/src/manifest_tree/server_tree.rs:50,75)
pub struct LanguageServerTreeNode(Weak<InnerTreeNode>);
// Defers initialization via OnceLock; server_id() returns Option via upgrade()

// 25. Arc::downgrade() for async shutdown detection (client/src/telemetry.rs:233-236)
let weak = Arc::downgrade(&client);
drop(client);
// Long-running status loop: if client dropped, app is shutting down

// 26. Arc::downgrade() for entity slot reservation (gpui/src/app/entity_map.rs:90)
Slot(Entity::new(id, Arc::downgrade(&self.ref_counts)))
// Allows async entity creation before actual value insertion

// 27. Weak<BTreeMap> for file watcher resource management (fs/src/mac_watcher.rs:14,36,61)
handles: Weak<Mutex<BTreeMap<PathBuf, fsevent::Handle>>>,
// Detects when channel receiver dropped to stop spawning watch threads

// 28. Arc::downgrade() for stream cancellation (rpc/src/peer.rs:511)
let stream_response_channels = Arc::downgrade(&stream_response_channels);
// Allows cancelling streaming if no more subscribers without deadlock

// 29. Weak<RefCell<T>> for native FFI callback safety (gpui/src/platform/mac/status_item.rs:147,377)
// Stores weak references in raw pointers for Objective-C callback safety
// Prevents memory leaks when native framework holds references to Rust objects

// 30. X11ClientStatePtr newtype wrapper (gpui/src/platform/linux/x11/client.rs:222,226)
pub struct X11ClientStatePtr(pub Weak<RefCell<X11ClientState>>);
// try_lock() upgrades weak ref and wraps in client type

// 31. Rc::downgrade() for platform reopen callbacks (gpui/src/app.rs:201-206)
let this = Rc::downgrade(&self.0);
self.0.borrow_mut().platform.on_reopen(Box::new(move || {
    if let Some(app) = this.upgrade() { callback(&mut app.borrow_mut()); }
}));

// 32. WeakEntity<Project> with generation-based pruning (semantic_index/src/project_index.rs:63,110)
project: WeakEntity<Project>,
// Combined retain() + generation check to prune stale weak entries

// 33+ WeakEntity<Workspace> proliferates across 30+ UI components:
//   agent_panel.rs, context_picker.rs, inline_prompt_editor.rs,
//   terminal_inline_assistant.rs, quick_action_bar.rs, component_preview.rs,
//   welcome.rs, outline_panel.rs, headless_host.rs, completion_provider.rs,
//   thread_view.rs, zeta.rs, etc.
```

**Common Zed patterns:** (1) `retain()` to auto-prune dead weak refs during iteration, (2) `upgrade()` with graceful fallback on failure, (3) `Arc::downgrade()` at subscription time to break cycles, (4) `observe_release()` for deterministic cleanup on entity drop, (5) `WeakEntity<T>` as HashMap keys/values for caches that auto-invalidate, (6) strong/weak enum variants for dual ownership strategies, (7) `Drop` impls with `upgrade()` for cleanup-on-release patterns, (8) `Weak<Self>` as function parameters for spawned async tasks, (9) `Weak<Task<T>>` for lazy singleton background tasks, (10) `Weak<AppCell>` / `Arc::downgrade()` for async shutdown detection in spawned tasks, (11) newtype wrappers around `Weak<T>` for ergonomic domain-specific upgrade semantics, (12) `Weak` in raw pointers for native FFI callback safety (macOS/Windows/X11).

---

## Solution

Leverage Lua's **weak table** mechanism (`__mode` metamethod) as a **safety net layer** complementing the existing explicit cleanup infrastructure. Weak tables are most valuable for computed result caches with no natural lifecycle event, not for buffer-keyed state (which already has deterministic cleanup).

### Lua Weak Table Fundamentals

```lua
-- Weak values: GC can collect values if no other strong refs exist
local weak_v = setmetatable({}, { __mode = "v" })

-- Weak keys: GC can collect keys if no other strong refs exist
local weak_k = setmetatable({}, { __mode = "k" })

-- Both weak: GC can collect either key or value
local weak_kv = setmetatable({}, { __mode = "kv" })
```

**Key constraint:** Weak references only work with **tables, functions, threads, and userdata** — not strings or numbers. Buffer numbers (integers) cannot be weak keys directly. This requires a wrapper strategy.

### Pattern 1: Weak Value Cache for Computed Results

> **NOT IMPLEMENTED — removed as dead code.** `weak_cache.lua` was evaluated and
> removed; the inline `setmetatable({}, { __mode = "v" })` pattern in
> `resource_cleanup.lua` is sufficient. The code block below is kept for reference only.

For caches storing computed tables/arrays that can be recomputed on miss:

```lua
-- weak_cache.lua

local M = {}

--- Create a cache with weak values.
--- Cached tables are automatically collected when no other references exist.
--- @param name string Cache name for debugging
--- @return table cache The weak-value cache table
function M.new_weak_values(name)
  local cache = setmetatable({}, { __mode = "v" })
  return cache
end

--- Create a cache with weak keys.
--- Entries are removed when the key object is garbage collected.
--- @return table cache The weak-key cache table
function M.new_weak_keys()
  return setmetatable({}, { __mode = "k" })
end
```

### Pattern 2: Buffer Handle Wrapper for Weak Keys

Since buffer numbers are integers (not GC-eligible), wrap them in table handles:

```lua
-- buf_handle.lua

local M = {}

-- Map bufnr -> handle table (strong reference kept alive by buffer existence)
local _handles = {}

--- Get or create a GC-eligible handle for a buffer number.
--- Handle stays alive as long as buffer is valid.
--- @param bufnr integer
--- @return table handle A table that can be used as weak key
function M.get(bufnr)
  if _handles[bufnr] then
    return _handles[bufnr]
  end
  local handle = { bufnr = bufnr }
  _handles[bufnr] = handle
  return handle
end

--- Release handle for a buffer (call on BufDelete/BufWipeout).
--- Once released, weak references to this handle become nil on next GC.
--- @param bufnr integer
function M.release(bufnr)
  _handles[bufnr] = nil
end

-- Single autocmd to release all buffer handles
vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = vim.api.nvim_create_augroup("VaultBufHandles", { clear = true }),
  callback = function(ev)
    M.release(ev.buf)
  end,
})

return M
```

**Note:** This pattern adds complexity (handle indirection, extra autocmd) on top of the existing `on_buf_delete` cleanup that already works well. Consider only if buffer-keyed weak tables provide measurable benefit beyond current cleanup.

### Pattern 3: Weak Subscriber References (Already Partially Implemented)

`resource_cleanup.weak_callback()` already exists at lines 65-74:

```lua
-- resource_cleanup.lua (EXISTING, lines 65-74)
function M.weak_callback(state, callback)
  local weak = setmetatable({ ref = state }, { __mode = "v" })
  return function(...)
    local s = weak.ref
    if s then
      callback(s, ...)
    end
  end
end
```

An optional `weak_ref.new(target)` wrapper could complement this for cases where you need to check liveness without a callback:

```lua
-- Could be added to resource_cleanup.lua

--- Create a weak reference to a table.
--- If the target is garbage collected, ref:get() returns nil.
--- @param target table The object to weakly reference
--- @return table ref Weak reference with :get() method
function M.weak_ref(target)
  local container = setmetatable({ target }, { __mode = "v" })
  return {
    get = function()
      return container[1]
    end,
    alive = function()
      return container[1] ~= nil
    end,
  }
end
```

---

## Integration Targets

### 1. Graph BFS Traversal Result Caching

**Current state:** `_bfs_cache` in `graph_filter/traversal.lua` (lines 31-35) is a **weighted LRU** cache:
```lua
local _bfs_cache = lru.new_weighted({
  max_bytes = config.cache.bfs_traversal_bytes,
  max_items = config.cache.bfs_traversal_max,
  weigher = weighers.bfs_result,
})
```
Entries contain `BfsCacheEntry` structs (lines 19-29) with visited sets, frontiers, forward/backlink nodes, and memoized resolvers. Invalidated via `M.invalidate_bfs_cache()` (lines 39-41) and generation-based staleness detection in `check_cache()` using `filter_utils.is_cache_gen_valid()` (line 130). Cache storage via `store_and_return()` (lines 218-244). Stats: `bfs_cache_size()` (lines 283-285), `bfs_cache_stats()` (lines 289-294).

**Opportunity:** The weighted LRU already provides **memory-bounded** eviction (not just count-bounded). Between search operations, BFS results are unused but occupy memory up to `max_bytes`. A weak-value layer could allow GC to reclaim entries when no active search holds a reference.

**Assessment:** Low value. The weighted LRU already bounds memory by byte count, and the custom weigher ensures accurate memory accounting. Deep copies mean results are independent — weak values would only help if callers hold references transiently. Skip unless profiling shows BFS cache as a significant memory contributor.

### 2. Vault Index Subscribers

**Current state:** `vault_index._subscribers` (field at line 107) is a plain array of functions. `subscribe()` returns an unsubscribe closure (lines 203-213). `_notify_update()` calls all subscribers with pcall and logs failures (lines 223-229). Two modules currently subscribe:

- **connections.lua** — `on_index_update()` (lines 949-965) captures `_pending_changed`, `_pending_full_clear`, `engine`. Tracks changed file rel_paths for deferred per-file invalidation. `_subscription` stored at line 52. Subscription via `cleanup.subscription_handle()` (lines 968-970). `ensure_subscription()` (lines 974-976) called at setup and in `prepare_compute()`. `unsubscribe()` (lines 984-986) for teardown.
- **embed_sync.lua** — `M.on_index_update()` (lines 60-96) captures `_dep_to_bufs` (inverted dependency index), `_dep_index_dirty`, `state`, `config`. Uses O(changed_paths) inverted index lookups to schedule targeted buffer re-renders. Subscription via `cleanup.subscription_handle()` (lines 103-106). Handle stored in `embed_state._subscription` (line 18). Lazy init via `init_subscription()` (lines 100-107) with `_subscription_initialized` guard (line 11). `M.ensure_subscription()` (lines 111-114). `M.unsubscribe()` (lines 117-121).

Both use the `subscription_handle()` pattern which provides idempotent `ensure()/unsubscribe()` with vault-switch detection.

**Opportunity:** Use `resource_cleanup.weak_callback()` (already implemented, currently unused) when subscribing, so if a module's state is GC'd the callback becomes a no-op:

```lua
-- connections.lua (current, lines 949-970)
local function on_index_update(_gen, context)
  -- Closure captures: _pending_changed, _pending_full_clear, engine
  if not context then _pending_full_clear = true; return end
  for _, list in ipairs({ context.changed_paths, context.deleted_paths }) do
    if list then for _, abs_path in ipairs(list) do
      local rel = engine.vault_relative(abs_path)
      if rel then _pending_changed[rel] = true end
    end end
  end
end
_subscription = cleanup.subscription_handle(function() return vault_index.current() end, on_index_update)

-- connections.lua (with weak callback)
local module_state = { idf_cache = _idf_cache, note_data_cache = _note_data_cache, ... }
local weak_cb = cleanup.weak_callback(module_state, function(state, gen, context)
  -- Access caches via state.idf_cache, state.note_data_cache
  ...
end)
_subscription = cleanup.subscription_handle(get_index, weak_cb)
```

**Assessment:** Medium value. The subscription_handle pattern already provides explicit unsubscribe. Weak callbacks add defense-in-depth but require restructuring how connections.lua accesses its caches (moving from module locals to a state table). Consider for new subscribers, not worth refactoring existing ones.

### 3. Highlight Position Caches

**Current state:** All highlight caches (`_nav_cache` in highlights.lua, tag_highlights.lua; `_field_cache` in inline_fields.lua; `_fn_cache` in footnotes.lua) already have deterministic BufDelete cleanup via `hl_coord.setup_buf_cleanup()`.

**Assessment:** No value. Existing cleanup is reliable and deterministic. Adding weak table indirection via buf_handle would add complexity without benefit.

### 4. Completion Description Deduplication

**Current state:** Already implemented via `string_intern.lua` with bounded pools. `completion.lua` uses `_desc_pool = string_intern.new(500)` (line 153) with `intern_desc()` (lines 155-160). Pool is reset on each rebuild (lines 214-215).

**Assessment:** No value — **already solved**. String interning is the correct approach since Lua strings are never collected from weak tables. The existing bounded pool with explicit reset is superior to any weak table approach.

### 5. Embed Dependency Tracking

**Current state:** `embed_state._embed_deps[bufnr]` (line 15) tracks per-buffer image paths. Comprehensive cleanup exists:
- `embed_state.clear_buffer_state(bufnr)` (lines 89-108) — unified registry-based cleanup
- `embed_state.gc_stale_buffers()` (lines 111-120+) — sweeps invalid buffers
- State dict registration with custom cleanup functions (lines 42-65)

**Assessment:** No value. The embed_state registry pattern is more sophisticated than weak tables — it handles timers, placements, and other resources that require explicit teardown, not just memory reclamation. Weak tables cannot replace this.

### 6. Completion Base Field Cache

**Current state:** `_field_cache` in `completion_base.lua` (line 89) is keyed by `"vault_path\0field_name"` strings with generation tracking via `filter_utils.is_cache_gen_valid()`. Memoization in `M.build_kv_single_pass()` — stores `{ gen, result }` per cache key. Cleared during `M.invalidate_all()` (lines 93-98) via `_field_cache = {}` but has no size bound or eviction. Registered with engine cache registry as `"completions"` (lines 101-113). Completion source factory (`M.create_source`) provides per-source caches with generation tracking and async/sync build modes.

**Assessment:** Low value. String keys cannot be weak. Generation tracking already handles staleness. Could benefit from an LRU bound instead.

### 7. Connections IDF Cache

**Current state:** `_idf_cache` in `connections.lua` (line 32) is a simple table (`tag -> doc_count`) with generation tracking (`_idf_gen` at line 34). Built via `build_tag_idf(files)` (lines 91-105). Incrementally updated via `update_tag_idf_incremental()` when generation changes (lines 109-165). Also tracks `_idf_file_tags` (line 35, `rel_path -> {tag=true}`) for incremental diff computation. Set to nil on vault switch (line 60).

**Assessment:** No value. The cache is a flat lookup table (strings/numbers), not table-valued. Generation tracking ensures freshness. Incremental updates minimize recomputation. No weak table opportunity.

---

## Revised Recommendations

Given the current state of the codebase, the value proposition of weak tables has **significantly narrowed** compared to the original document. The explicit cleanup infrastructure (`resource_cleanup`, `highlight_coordinator`, `embed_state`, `engine.register_cache`, `lru_cache`, `string_intern`) is comprehensive and well-tested.

### Still Valuable

1. **`resource_cleanup.weak_callback()`** — Already implemented, ready for use. Apply to **new** vault_index subscribers as a low-cost safety net alongside `subscription_handle()`.

2. **Weak-value wrapper for short-lived computed results** — For any future cache storing transient computation results (not buffer-keyed, not string-keyed) where LRU bounds are overkill.

### Not Recommended (Changed from Original)

3. **buf_handle.lua** — Buffer-keyed caches all have deterministic BufDelete cleanup. The handle indirection adds complexity for no measurable benefit.

4. **Weak tables for highlight caches** — Already cleaned up deterministically.

5. **Weak tables for completion descriptions** — Already solved by `string_intern.lua`.

6. **Weak tables for embed dependencies** — Already solved by embed_state registry + gc_stale_buffers.

---

## Limitations & Caveats

### Lua Weak Table Constraints

1. **Strings are never weak:** Lua interns all strings; they're never collected from weak tables. Use explicit eviction (LRU via `lru_cache.lua`) or bounded pools (`string_intern.lua`) for string-keyed caches.

2. **Numbers are never weak:** Integer keys (like bufnr) cannot be weak keys. The buf_handle wrapper pattern works but adds complexity over the existing `on_buf_delete` infrastructure.

3. **GC timing is non-deterministic:** Weak entries may persist for multiple GC cycles. Don't rely on immediate cleanup — use weak tables for **memory pressure relief**, not **correctness**.

4. **Resurrection:** If a finalizer (`__gc`) resurrects an object by storing it in a strong reference, the weak table entry reappears. Avoid complex finalizer chains.

5. **Performance:** Weak tables have slightly higher GC overhead (collector must scan them). Limit to caches with genuine lifetime concerns, not every table.

### When to Use Weak Tables vs Existing Infrastructure

| Scenario | Weak Tables | Existing Solution |
|----------|------------|-------------------|
| Buffer-keyed highlight/parse caches | No | `hl_coord.setup_buf_cleanup()` ✅ |
| Buffer-keyed embed state (7 dicts) | No | `embed_state` registry + `gc_stale_buffers()` ✅ |
| Buffer-keyed general state | No | `resource_cleanup.on_buf_delete()` ✅ |
| Memory-bounded computed results | No | `lru_cache.new_weighted()` + `cache_weighers.lua` ✅ |
| Count-bounded computed results | No | `lru_cache.new()` ✅ |
| String deduplication | No (strings not collected) | `string_intern.lua` ✅ |
| Subscriber closure safety | Yes (`weak_callback`) | Also `subscription_handle()` ✅ |
| Transient computation results (no lifecycle event) | Yes | No existing solution |
| Cache coordination / invalidation | No | `engine.register_cache()` ✅ |
| Generation-based staleness | No | `gen_cache.lua` + `filter_utils.is_cache_gen_valid()` ✅ |
| Disk-persisted validation caches | No | `url_validate.lua` (debounced writes) ✅ |
| Image/path resolution caches | No | `embed_images.lua` (count LRU + generation) ✅ |
| Incremental search filtering | No | `search/live.lua` `_prev_cache` (generation) ✅ |
| Field aggregation caches | No | `search/stats.lua` `_agg_cache` (generation) ✅ |
| Function-scoped temp caches | No | Lua GC handles on function return ✅ |
| Timer/resource management | No | `resource_cleanup` helpers (close_timer, debounce, etc.) ✅ |

---

## Configuration

No new configuration section needed. The existing `resource_cleanup.weak_callback()` is unconditional and has no config overhead. If weak-value caches are added in the future, they should be transparent (no feature flags — either the pattern is correct or it isn't).

### Current Cache Config Reference (`config.cache.*`, lines 821-840)

| Key | Value | Type |
|-----|-------|------|
| `slug_max` | 2000 | count LRU |
| `date_parse_max` | 5000 | count LRU |
| `connections_max` | 500 | count+weighted LRU |
| `section_cache_max` | 200 | count+weighted LRU |
| `note_data_max` | 1000 | count+weighted LRU |
| `display_width_max` | 2000 | count LRU |
| `bfs_traversal_max` | 100 | count+weighted LRU |
| `image_path_max` | 500 | count LRU |
| `file_content_max` | 100 | count+weighted LRU |
| `file_content_bytes` | 5 MB | weighted LRU |
| `section_cache_bytes` | 2 MB | weighted LRU |
| `section_outlinks_bytes` | 2 MB | weighted LRU |
| `connections_bytes` | 3 MB | weighted LRU |
| `note_data_bytes` | 2 MB | weighted LRU |
| `bfs_traversal_bytes` | 1 MB | weighted LRU |

Total memory budget: ~15 MB across all weighted LRU caches.

### Current Intern Pool Config Reference (`config.intern.*`, lines 851-857)

| Key | Value | Purpose |
|-----|-------|---------|
| `tag_pool_max` | — | Tag string deduplication |
| `fm_key_pool_max` | — | Frontmatter key deduplication |
| `fm_value_pool_max` | — | Frontmatter value deduplication |
| `folder_pool_max` | — | Folder path deduplication |
| `lowercase_pool_max` | — | Case-insensitive string deduplication |

---

## Validation

1. **weak_callback test (existing implementation):**
   ```lua
   local cleanup = require("andrew.vault.resource_cleanup")
   local state = { data = "test" }
   local called = false
   local cb = cleanup.weak_callback(state, function(s, arg)
     called = true
     assert(s.data == "test")
   end)
   cb("hello")
   assert(called, "Callback should fire when state is alive")

   called = false
   state = nil
   collectgarbage("collect")
   cb("hello")  -- Should be no-op
   assert(not called, "Callback should be no-op after state GC'd")
   ```

2. **GC cooperation test (weak_cache.lua was evaluated and removed — not needed):**
   ```lua
   local weak = setmetatable({}, { __mode = "v" })
   local data = { "test" }
   weak["key"] = data
   data = nil
   collectgarbage("collect")
   assert(weak["key"] == nil, "Weak value should be collected")
   ```

3. **Memory measurement (to validate need):**
   - Open 50 buffers, populate caches, close all buffers
   - With existing cleanup: measure retained cache memory after BufDelete events
   - If near-zero: weak tables provide no additional benefit
   - If significant: identify which caches lack cleanup and fix directly

---

## Expected Impact

| Area | Current State | Weak Table Benefit |
|------|-------------|-------------------|
| Buffer-keyed caches (30+ caches across 25 modules) | BufDelete cleanup via on_buf_delete/setup_buf_cleanup/state_dict registry | None — already deterministic |
| Graph BFS cache | Weighted LRU (byte-bounded) + generation invalidation | Marginal — weighted LRU already bounds by memory |
| Connection results cache | Weighted LRU + dependency-graph invalidation | Marginal — weighted LRU already bounds |
| Connection note data cache | Weighted LRU + subscriber invalidation | Marginal — weighted LRU already bounds |
| Connection IDF cache | Simple table + incremental gen-based update | None — flat lookup table, not table-valued |
| File content/section caches | Weighted LRU (file_cache.lua, 5MB+2MB budgets) | None — weighted LRU already bounds |
| Section outlinks cache | Weighted LRU (search_filter/match_field.lua, 2MB budget) | None — weighted LRU already bounds |
| Generation-based caches (6 modules) | gen_cache.lua with vault_index generation tracking | None — automatic staleness via generation |
| Subscriber closures (2 subscribers) | subscription_handle() with ensure/unsubscribe lifecycle | Safety net via weak_callback (already available) |
| Embed dependencies (7 state dicts) | Registry cleanup + gc_stale_buffers() + per-dict custom cleanup | None — already comprehensive |
| String pools | string_intern.lua (bounded, explicit, with intern_lower/clear/reset_stats) | None — strings not GC-eligible |
| Completion field cache | Simple table + generation-based memoization | None — string keys, could use LRU bound |
| Image path cache | Count LRU (embed_images.lua, 500 entries) + generation + locality heuristic | None — count-bounded LRU |
| URL validation cache | Disk-persisted (url_validate.lua) + inflight tracking + domain rate limiting | None — persistence, not memory |
| Search live cache | `_prev_cache` generation-tracked incremental filtering (search/live.lua) | None — single-entry cache, negligible memory |
| Search stats aggregation | `_agg_cache` manually generation-tracked (search/stats.lua) | None — rebuilt on generation change |
| Frontmatter editor render cache | `_render_cache` in `_state` (frontmatter_editor.lua) | None — per-editor singleton |
| Function-scoped temp caches (5 modules) | linkcheck, linkdiag, backlinks, sidebar_backlinks, filter_utils | None — GC'd on function return |

**Primary remaining value:** `weak_callback()` as a defense-in-depth layer for subscriber patterns, and as a building block for any future transient computation caches. The codebase has matured past the point where weak tables are a primary memory management strategy — the explicit cleanup infrastructure is comprehensive (~15 MB total memory budget across 6 weighted LRU caches, 9+ count-bounded LRU caches, 6+ generation-based caches, 30+ buffer-keyed caches with deterministic cleanup, and 5+ intern pools).
