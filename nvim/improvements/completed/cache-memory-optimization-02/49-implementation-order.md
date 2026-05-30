# Implementation Order — Cache & Memory Optimization

## Methodology

This document was created by auditing all 48 optimization documents against the
current vault plugin codebase (March 8, 2026 audit, revision 3). Each item was
classified as IMPLEMENTED, PARTIALLY IMPLEMENTED, or NOT IMPLEMENTED, then
remaining work was ordered by:

1. **Priority** (HIGH > MEDIUM > LOW from the overview)
2. **Dependencies** (foundations before consumers)
3. **Standalone-ness** (independent items first to unlock parallel progress)
4. **Impact/effort ratio** (quick wins before large refactors)

---

## Current Status Summary

### Already Implemented (19 items — core value delivered)

These items have their primary optimization mechanism in place. Some have
extension opportunities noted in their individual docs, but the core pattern
is working and delivering value.

| # | Optimization | Implementation Evidence |
|---|---|---|
| 03 | Timer & Resource Leak Fixes | `resource_cleanup.lua` — safe wrappers with pcall, status checks, nil guards; BufDelete cleanup in task_hierarchy, footnotes, link_scan |
| 04 | Completion Memory Optimization | `completion_base.lua` — coroutine iterator with `build_iter`, batch yielding, cancellation flag |
| 06 | Connections Cache Optimization | `connections.lua` — 500-entry bounded scoring cache with generation tracking, top-K min-heap with early pruning, IDF caching per generation |
| 07 | Debounced Persistence & Write Coalescing | `vault_index.lua` — persist_debounce_ms timer coalescing, generation-skip on no-change, VimLeavePre flush via async I/O, _persist_in_flight guard |
| 08 | Progressive Search Filtering | `search/live.lua` — _prev_query, _prev_ast, _prev_file_set, _prev_index_gen caching; `search_filter.lua` — is_ast_superset() for AND-tree refinement with generation invalidation |
| 11 | Autocmd Event Batching | `highlight_coordinator.lua` — register()/schedule()/run_all() with shared code_excl context; consolidated BufEnter/TextChanged/WinScrolled autocmds with viewport vs full-buffer modes |
| 14 | Cooperative Yielding | `vault_index_build.lua` — coroutine.yield() every batch_size files; `completion_base.lua` — coroutine.yield() every batch_size items |
| 16 | Subscription Lifecycle Management | `vault_index.lua` — subscribe(fn) with unsubscribe() return value; _notify_update() with generation + context |
| 21 | Stale Operation Cancellation | `completion_base.lua` — monotonic build_generation + cancelled flag with multi-checkpoint checking; `vault_index_build.lua` — _building guard flag |
| 23 | RAII-Style Cleanup Guards | `resource_cleanup.lua` — close_timer(), close_win(), delete_buf(), debounce() with pcall wrappers; `embed_state.lua` — gc_dict(), gc_stale_buffers() with cascading cleanup |
| 26 | Viewport-Restricted Rendering | `embed.lua` — visible_range(margin) with lazy mode; `highlight_coordinator.lua` — viewport vs full-buffer modes on TextChanged/WinScrolled; `highlights.lua`, `tag_highlights.lua` — get_visible_range() conditional rendering; `link_scan.lua` — shared get_visible_range() |
| 29 | Tiered Cache Invalidation | `engine.lua` — register_cache() with invalidate (full) + invalidate_file (per-file) two-tier callbacks; VaultCacheInvalidate autocmd propagation |
| 31 | Memory Profiling Infrastructure | :VaultCacheStatus, :VaultCompletionDebug, :VaultEmbedDebug, :VaultIndexStatus commands; engine._cache_registry with stats callbacks |
| 34 | Memoized State Checks | `filter_utils.lua` — create_memoized_resolver(); `connections.lua` — generation-gated IDF cache (_idf_cache + _idf_gen); `calendar.lua` — _deadline_cache with generation validation; `vault_index.lua` — _aggregates_gen guard |
| 40 | Rate-Limited Domain Queuing | `url_validate.lua` — per-domain cooldown via _domain_last_request; check_rate_limit() with deferred retry via vim.defer_fn() (not skip-on-limit); max_concurrent limit with _inflight_count; validate_batch() queue processing |
| 41 | Operation Counter Staleness | `vault_index.lua` — _generation + _aggregates_gen dual counter pattern; `completion_base.lua` — build_generation + cached_index_gen for cross-module staleness |
| 43 | Watch-Style Event Coalescing | `engine_watcher.lua` — dirty-flag (_pending_changed_files + _pending_count) with debounce timer (_fs_debounce_timer); batch drain after 500ms timeout; `resource_cleanup.debounce()` primitive |
| 44 | Threshold-Based Batch Drain | `vault_index_build.lua` — config.index.batch_size (default 20) with progress notifications every 5 batches; `completion_base.lua` — config.completion.batch_size (default 50) |
| 47 | Hot-Path Memoization | `filter_utils.lua` — create_memoized_resolver() closure-based cache; `connections.lua` — generation-gated IDF cache; `vault_index.lua` — _ensure_aggregates() with lazy rebuild; `calendar.lua` — _deadline_cache |

### Partially Implemented (13 items — upgrade/extend)

| # | Optimization | Current State | Remaining Work | Modules |
|---|---|---|---|---|
| 02 | Bounded Caches & Eviction | slug (2000 max, reset-on-overflow), connections (500 max, reset-on-overflow), link_scan (per-buf BufDelete), section cache (generation-invalidated), embed_images (generation-invalidated, no size limit) | Replace reset-on-overflow with proper LRU eviction; add size limit to embed_images; add TTL pruning to url_validate._domain_last_request | slug, connections, embed_images, link_scan, search_filter/match_field |
| 05 | Search Result Streaming & Limits | config.search.max_files_from=500 for ripgrep file-list threshold; config.connections.max_results=30; config.graph.max_nodes=50; connections top-K heap with early pruning | Add global MAX_SEARCH_RESULT_FILES (5000) + MAX_SEARCH_RESULT_RANGES (10000) caps; add --max-count to ripgrep; early termination in search_filter.evaluate(); AND operator restrict right-side to left-side file set | search_filter, ripgrep, search, config |
| 09 | Index Memory Reduction | Pre-computed heading_slugs set + block_id_set; link lowercase fields pre-computed; task tags_lower | Per-entry field compression (drop nil fields), lazy frontmatter via metatables, deduplicate heading_slugs vs headings array, skip derived fields in JSON serialization | vault_index, vault_index_parser |
| 13 | Early Exit Pre-Filtering | AST-level pre-filtering via is_ast_superset() in search_filter; filter_utils early exits on include/exclude; task priority/date quick boolean checks | CharBag bitset for character-level pre-filtering before expensive fuzzy scoring; precomputed char sets stored in index entries | completion, search_filter, vault_index |
| 17 | Snapshot-Based Index Reads | Generation counter guards in vault_index, completion_base, search_filter; build_filter_context() pre-computes values per evaluate() call | Formal snapshot() method on VaultIndex; staged build pattern with atomic _apply_staged(); consistent iteration over frozen state | vault_index, vault_index_build, search_filter |
| 20 | Table/Object Pooling | `connections.lua` create_top_k(k) min-heap with bounded result collection; completion caching via generation | Standalone table_pool.lua with acquire()/release() API; integration into search_filter, embed, completion hot paths | search_filter, connections, embed, completion |
| 22 | Chunked Pipeline Processing | Batch yielding in vault_index_build + completion_base via coroutine.yield(); embed batch rendering with lazy_batch_size | Standalone pipeline.lua with streaming reduce, top-K accumulator, backpressure; apply to search_filter.evaluate() and ripgrep output processing | search_filter, connections, ripgrep |
| 25 | Concurrent Request Deduplication | url_validate._inflight per-URL dedup; completion_base async coalescing via debounce + generation; filter_utils.create_memoized_resolver() | Unified request_coalescer.lua utility; extend to embed, search, connections for N-callers-await-1-execution | vault_index, embed, search_filter, connections |
| 28 | Pattern Compilation Cache | `block_patterns.lua` centralizes block ID patterns (match_id, extract_from_lines, etc.) | Comprehensive patterns.lua covering wikilinks, embeds, tags, headings, inline fields; consolidate 7+ bracket-scanning loops; pre-bound iterator factories | link_utils, vault_index_parser, 20+ modules |
| 30 | Structural Sharing for Collections | Name/alias indexes store path references (not copies); incremental updates use old_entries snapshot; loaded entries reused directly | Explicit copy-on-write or Arc-style reference counting; immutable versioning of collection snapshots; avoid in-place mutation of shared entries | vault_index, vault_index_build |
| 33 | Three-Zone Viewport Prefetch | Uniform margin in visible_range(margin); embed lazy mode phases (visible sync, remaining async) | Explicit above/below zones with asymmetric sizing; scroll-direction tracking and priority; zone-specific debounce scheduling | highlight_coordinator, embed, all highlight modules |
| 36 | Hierarchical Summary Index | _ensure_aggregates() with generation-gated lazy rebuild; caches name_cache, tags, fm_keys, tag_counts | Replace O(N) full-file iteration with hierarchical tree structure; O(log N) per-update incremental aggregation | vault_index, stats, connections, graph |
| 48 | Idle-Time Proactive Cache Warming | engine.lua BufReadPost prewarm (prebuild_name_cache_async + URL cache load); completion_base pre-warming in source.new(); calendar _deadline_cache persists across navigation | CursorHold-triggered idle prefetch; systematic cache_warming.lua with priority-ordered warm queue and per-tick CPU budget; 5 warming strategies | completion, wikilinks, embed, connections |

### Not Implemented (16 items — new work)

| # | Optimization | Priority | New Modules | Key Modules Touched |
|---|---|---|---|---|
| 01 | LRU Cache Infrastructure | HIGH | lru_cache.lua | slug, connections, section caches |
| 10 | Concurrent Process Limiting | HIGH | process_semaphore.lua | ripgrep, search, query/init |
| 12 | String Interning Infrastructure | MEDIUM | string_intern.lua | vault_index, vault_index_parser |
| 15 | Preview & Render Caching | MEDIUM | file_cache.lua | preview, embed, embed_resolver |
| 18 | Memory-Weighted Cache Eviction | MEDIUM | -- (extends lru_cache.lua) | file_cache, search_filter, connections |
| 19 | Weak Table GC Integration | MEDIUM | weak_ref.lua *(weak_cache.lua removed as dead code; weak_callback integration into subscription_handle already complete)* | graph_filter, highlights, embed_state, connections |
| 24 | Per-Render Arena Allocation | MEDIUM | render_arena.lua | embed, highlights, search_filter, connections |
| 27 | Layered Transform Pipeline | MEDIUM | transform_pipeline.lua, line_tracker.lua | highlight_coordinator, all highlight modules, embed |
| 32 | Dual-Frame Render Cache | HIGH | frame_cache.lua | highlight_coordinator, all highlight modules, embed |
| 35 | Invalidation Region Tracking | HIGH | region_tracker.lua | embed, all highlight modules, highlight_coordinator |
| 37 | Scan Completion Waiters | MEDIUM | -- | vault_index, engine, completion, search, embed |
| 38 | Syntactic Content Chunking | MEDIUM | -- | vault_index_parser, vault_index_build |
| 39 | Shared Future Deduplication | MEDIUM | shared_future.lua | vault_index, embed, search_filter, connections |
| 42 | Content-Hash Change Detection | HIGH | -- | vault_index, vault_index_build, config |
| 45 | Prioritized Async Work Scheduling | HIGH | work_scheduler.lua | embed, completion_base, highlight_coordinator, vault_index |
| 46 | Generational Slot Map Entity Storage | LOW | slot_map.lua | embed_state, embed_images, highlight_coordinator |

---

## Recommended Implementation Order

### Tier 1: Foundations (implement first — other items depend on these)

Standalone utilities that unlock or improve multiple downstream items.

| Order | Doc | Name | Type | Effort | Modules | Rationale |
|-------|-----|------|------|--------|---------|-----------|
| 1 | 01 | LRU Cache Infrastructure | NEW | Small | New `lru_cache.lua` | Foundation for docs 02, 15, 18, 32. Pure data structure, no external deps. Unlocks proper eviction everywhere. |
| 2 | 02 | Bounded Caches & Eviction | UPGRADE | Small | slug, connections, embed_images, link_scan, match_field | Replace reset-on-overflow with LRU from doc 01. Drop-in replacement in 5+ cache sites. Currently slug resets entire 2000-entry cache on overflow; connections resets 500-entry cache; embed_images has no size limit. |
| 3 | 10 | Concurrent Process Limiting | NEW | Small | New `process_semaphore.lua`; ripgrep, search, query/init | Standalone semaphore capping ripgrep at ~3 concurrent. Prevents process exhaustion on nested AND/OR queries. Currently spawn_rg() calls vim.system() with no limit; parallel AND/OR spawning can peak at 5-15 concurrent rg instances. |

**Checkpoint:** All caches have proper eviction. Concurrent processes are bounded. No more unbounded growth vectors.

### Tier 2: High-Impact Standalone Wins

Independent high-priority items with strong impact/effort ratios.

| Order | Doc | Name | Type | Effort | Modules | Rationale |
|-------|-----|------|------|--------|---------|-----------|
| 4 | 42 | Content-Hash Change Detection | NEW | Small | vault_index, vault_index_build, config | SHA/CRC32 digest per file entry. Skips re-parse when mtime changes but content hasn't (git checkout, touch, save-no-change). 90-99% parse cost reduction. Requires SCHEMA_VERSION bump. Two-phase detection: mtime+size first, then hash if changed. Currently only mtime+size check (vault_index.lua:408-416). |
| 5 | 05 | Search Result Streaming & Limits | UPGRADE | Small | search_filter, ripgrep, search, config | Add MAX_SEARCH_RESULT_FILES (5000) + MAX_SEARCH_RESULT_RANGES (10000) caps with early termination. Prevents OOM on `*` queries. Currently evaluate() returns ALL matching files; no --max-count flag to ripgrep. Existing max_files_from=500 only controls ripgrep file-list mode, not result caps. |
| 6 | 32 | Dual-Frame Render Cache | NEW | Medium | New `frame_cache.lua`; highlight_coordinator, embed | Two-generation cache (previous/current) with promote-on-hit, finish_frame() swap. 60-80% render work reduction across embed, tag_highlights, wikilink_highlights, task_hierarchy, footnotes. No render caching exists today — every TextChanged recreates all extmarks within viewport. |
| 7 | 35 | Invalidation Region Tracking | NEW | Medium | New `region_tracker.lua`; embed, all highlight modules, highlight_coordinator | Track dirty line ranges within buffers via nvim_buf_attach() on_lines callback. Only re-render changed regions instead of full viewport. 90-98% reduction for localized edits (common case). Currently TextChanged triggers full-viewport re-scans despite highlight_coordinator viewport restriction. |

**Checkpoint:** Rendering and indexing are significantly more efficient. The two biggest CPU consumers (re-parsing unchanged files, re-rendering unchanged lines) are addressed.

### Tier 3: Scheduling & Prefetch

Improve perceived responsiveness and eliminate redundant async work.

| Order | Doc | Name | Type | Effort | Modules | Rationale |
|-------|-----|------|------|--------|---------|-----------|
| 8 | 45 | Prioritized Async Work Scheduling | NEW | Medium | New `work_scheduler.lua`; embed, completion_base, highlight_coordinator, vault_index | 4-level priority queue (CRITICAL/NORMAL/DEFERRED/IDLE) with starvation prevention. Currently all async work uses vim.schedule()/vim.defer_fn()/vim.uv.new_timer() in arbitrary order. No visible-first scheduling. All deps satisfied (docs 14, 21 done). |
| 9 | 33 | Three-Zone Viewport Prefetch | UPGRADE | Medium | New `viewport.lua`; highlight_coordinator, embed, all highlight modules | Asymmetric above/below prefetch zones with scroll-direction tracking and priority. Currently uniform margin only (lazy_margin config in embed). No scroll-direction detection. Extends doc 26 (viewport restriction fully implemented). Eliminates pop-in during `<C-d>`/`<C-u>` scrolling. |
| 10 | 48 | Idle-Time Proactive Cache Warming | UPGRADE | Medium | New `cache_warming.lua`; completion, wikilinks, embed, connections | CursorHold-triggered prefetch with priority-ordered warm queue and per-tick CPU budget (5ms). Existing BufReadPost prewarm and completion pre-warming cover initial load but not ongoing idle periods. 5 warming strategies: completion pre-build, adjacent file pre-read, connection pre-compute, code exclusion pre-parse, date context pre-resolve. Depends on docs 45, 33 for full benefit. |

**Checkpoint:** Scrolling and navigation feel instant. Background work is properly prioritized.

### Tier 4: Memory Efficiency

Reduce peak memory for large vaults (5K+ notes). Items ordered by dependency chain.

| Order | Doc | Name | Type | Effort | Modules | Rationale |
|-------|-----|------|------|--------|---------|-----------|
| 11 | 18 | Memory-Weighted Cache Eviction | NEW | Small | Extends lru_cache.lua (doc 01); file_cache, search_filter, connections | Add weigher function API to LRU. Budget by bytes, not item count. Predictable memory caps for variable-sized entries (file content, search results). |
| 12 | 12 | String Interning Infrastructure | NEW | Medium | New `string_intern.lua`; vault_index, vault_index_parser | Deduplicate repeated strings (tags, FM keys/values, folder paths). ~15.6MB savings for 10K vault. No string pool or interning exists today — Lua auto-interns literals but not computed strings from :lower()/:match(). Complements doc 09. |
| 13 | 20 | Table/Object Pooling | UPGRADE | Medium | New `table_pool.lua`; search_filter, connections, completion, embed | Standalone pool with acquire()/release() API. Currently only create_top_k() in connections provides bounded reuse. Need general pool for search match tables, connection data tables, embed descriptors. 90-98% allocation reduction in hot paths. |
| 14 | 19 | Weak Table GC Integration | NEW | Small | New `weak_ref.lua`; graph_filter, highlights, embed_state, connections | `__mode = "v"` / `"kv"` tables as safety net behind explicit cleanup. Zero weak table usage exists today. Auto-prune dead buffer/computation refs on GC. *(Note: weak_cache.lua removed as dead code; weak_callback integration into subscription_handle already complete.)* |
| 15 | 09 | Index Memory Reduction | UPGRADE | Medium | vault_index, vault_index_parser | Per-entry field compression (drop nil fields), lazy frontmatter via metatables, deduplicate heading_slugs vs headings array. Currently both heading_slugs set and headings array stored; derived lowercase fields (link._name_lower, stem_lower, basename_lower) persisted to JSON instead of recomputed on load. Benefits from doc 12 (interned strings). Reduces 42MB to ~25-30MB at 10K scale. |
| 16 | 15 | Preview & Render Caching | NEW | Small | New `file_cache.lua`; preview, embed, embed_resolver | Mtime-gated file content LRU cache. Uses doc 01 LRU + doc 18 weigher. No file content caching exists today — embed_resolver reads from buffer/disk on each call; preview reads fresh each time. 50-90% I/O reduction. |

**Checkpoint:** Memory usage is predictable and bounded at scale. GC pressure significantly reduced.

### Tier 5: Pipeline & Search Improvements

Improve search and filter performance for complex queries.

| Order | Doc | Name | Type | Effort | Modules | Rationale |
|-------|-----|------|------|--------|---------|-----------|
| 17 | 13 | Early Exit Pre-Filtering | UPGRADE | Medium | New `char_bag.lua`; completion, search_filter, vault_index | CharBag bitset superset check before expensive fuzzy scoring. Existing AST-level pre-filtering (is_ast_superset) and filter_utils early exits operate at query level, not candidate level. CharBag rejects 60-80% of candidates with O(1) bit check before match_entry(). Precomputed sets stored in index for has:tags and type:X queries. |
| 18 | 22 | Chunked Pipeline Processing | UPGRADE | Medium | New `pipeline.lua`; search_filter, connections, ripgrep | Streaming reduce + top-K accumulator + backpressure primitives. Currently batch yielding exists in vault_index_build + completion_base but no unified pipeline module. search_filter.evaluate() is synchronous with no chunking. 97% peak memory reduction for large result sets. |
| 19 | 39 | Shared Future Deduplication | NEW | Medium | New `shared_future.lua`; vault_index, embed, search_filter, connections | Unified utility replacing ad-hoc _inflight patterns. Currently only url_validate.lua has _inflight table (per-URL dedup, not shared futures). Need N callers await 1 execution with shared result across vault_index, embed, search. |
| 20 | 37 | Scan Completion Waiters | NEW | Small | vault_index, engine, completion, search, embed | True one-shot async waiter: register for specific scan_id completion, auto-unregister after fire. Currently only persistent _subscribers exist (vault_index.lua:105-126); modules use is_ready() guards that silently skip if index not ready. Replaces polling loops and deferred timer hacks. |

**Checkpoint:** Search is fast and memory-efficient even for complex multi-operator queries on large vaults.

### Tier 6: Advanced Rendering & Parsing

Architectural improvements to rendering and parsing pipelines.

| Order | Doc | Name | Type | Effort | Modules | Rationale |
|-------|-----|------|------|--------|---------|-----------|
| 21 | 27 | Layered Transform Pipeline | NEW | Large | New `transform_pipeline.lua`, `line_tracker.lua`; highlight_coordinator, all highlight modules, embed, linkdiag | Single buffer scan -> parse -> resolve -> render chain replacing 3+ independent nvim_buf_get_lines() calls per render cycle. Currently highlights.lua, wikilink_highlights.lua, and tag_highlights.lua each call nvim_buf_get_lines() independently. Coordinator shares autocmds and code_excl but not buffer line fetching. 85-98% fewer regex passes. Depends on doc 22 (pipeline primitives). |
| 22 | 24 | Per-Render Arena Allocation | NEW | Medium | New `render_arena.lua`; embed, highlights, search_filter, connections | Scope-based bulk alloc: arena:alloc() during render, arena:reset() at frame end. No arena pattern exists today — all tables use standard Lua GC. 60-80% GC pause reduction. Complements doc 20 (type-scoped pooling). |
| 23 | 38 | Syntactic Content Chunking | NEW | Large | vault_index_parser, vault_index_build | Syntax-aware 1-8KB chunks with SHA digests. Re-parse only changed chunks on edit. Currently single-pass full-file parsing on every mtime+size change (vault_index_parser.lua:442-528). No chunk splitting, digest computation, or differential re-parsing. ~90% parse cost reduction for large files. Extends doc 42 (file-level hashing to chunk-level). |

**Checkpoint:** Rendering pipeline is fully optimized. Parser handles large files efficiently.

### Tier 7: Structural & Architectural (implement last)

Larger architectural changes with lower urgency or diminishing returns.

| Order | Doc | Name | Type | Effort | Modules | Rationale |
|-------|-----|------|------|--------|---------|-----------|
| 24 | 30 | Structural Sharing for Collections | UPGRADE | Large | vault_index, vault_index_build, vault_index_parser | Formalize copy-on-write or Arc-style sharing for unchanged sub-tables across index versions. Currently name/alias indexes share path references and entries are reused directly, but no systematic CoW. Entries mutated in-place (e.g., adding rel_stem_lower). 98% GC churn reduction on incremental updates. High complexity. |
| 25 | 36 | Hierarchical Summary Index | UPGRADE | Large | New `summary_tree.lua`; vault_index, stats, connections, graph | O(log N) aggregate queries via cached subtree summaries. Current _ensure_aggregates() iterates all files in O(N) on every generation change (vault_index.lua:688-745). For 5K vault, every modification pays ~5K iteration cost. Generation caching avoids redundant rebuilds but each rebuild is still O(N). |
| 26 | 28 | Pattern Compilation Cache | UPGRADE | Small | Extend `block_patterns.lua` to comprehensive `patterns.lua`; 20+ consumer modules | Currently only block ID patterns centralized in block_patterns.lua. Wikilink, tag, heading, inline field patterns still hardcoded across highlights.lua, wikilink_highlights.lua, tag_highlights.lua, url_validate.lua, and 16+ other modules. Consolidate 7+ bracket-scanning loops. Primary value is maintainability. |
| 27 | 46 | Generational Slot Map Entity Storage | NEW | Large | New `slot_map.lua`; embed_state, embed_images, highlight_coordinator | Dense entity store with ABA-safe generational IDs + leak detection. Currently uses hash tables with natural keys; no ABA protection (buffer reuse can get stale state). Over-engineered for Lua's single-threaded model; implement only if embed entity bugs surface. |

### Partially Implemented Items — Extension Opportunities

These items are working but have extension opportunities documented in their
individual docs. They can be upgraded opportunistically alongside related tier work.

| # | Optimization | Extension Opportunity | Natural Pairing |
|---|---|---|---|
| 08 | Progressive Search Filtering | Expand is_ast_superset() to handle OR/NOT trees (currently AND-only) | With doc 22 (pipeline) |
| 17 | Snapshot-Based Index Reads | Formal snapshot() method; staged build pattern with atomic apply | With doc 30 (structural sharing) |
| 25 | Concurrent Request Deduplication | Unified request_coalescer.lua replacing ad-hoc patterns | With doc 39 (shared futures) |

---

## Full Dependency Graph

```
                    +---------------------------------------------+
                    |       ALREADY IMPLEMENTED (core)             |
                    |  03, 04, 06, 07, 08, 11, 14, 16, 21, 23,   |
                    |  26, 29, 31, 34, 40, 41, 43, 44, 47        |
                    +--------------------+------------------------+
                                         | (foundations satisfied)
                                         v
 +---- Doc 01 (LRU) -----------+---> Doc 02 (Bounded Caches upgrade)
 |                              +---> Doc 18 (Memory-Weighted Eviction) ---> Doc 15 (File Content Cache)
 |                              +---> Doc 32 (Dual-Frame Render Cache)
 |
 |    Doc 10 (Process Limiting) ---> standalone (no downstream deps)
 |
 |    Doc 42 (Content-Hash) ---> Doc 38 (Syntactic Chunking -- extends file-level to chunk-level)
 |
 |    Doc 26 (Viewport, DONE) --+---> Doc 33 (Three-Zone Prefetch)
 |                               +---> Doc 32 (Dual-Frame Cache -- viewport determines cache scope)
 |
 |    Doc 35 (Region Tracking) ---> Doc 32 (Dual-Frame Cache -- regions determine which entries to keep)
 |
 |    Doc 45 (Priority Scheduling) ---> Doc 48 (Cache Warming -- uses scheduler for idle work)
 |    Doc 33 (Three-Zone Prefetch) ---> Doc 48 (Cache Warming -- prefetch zones define what to warm)
 |
 |    Doc 20 (Table Pooling) --+---> Doc 22 (Chunked Pipeline -- pooled tables flow through pipeline)
 |                              +---> Doc 24 (Arena -- complementary: arena = scope-scoped, pool = type-scoped)
 |
 |    Doc 12 (String Interning) ---> Doc 09 (Index Memory -- interned strings + lazy fields compose)
 |                                   Doc 30 (Structural Sharing -- interning + sub-table sharing compose)
 |
 |    Doc 22 (Chunked Pipeline) ---> Doc 27 (Layered Pipeline -- pipeline primitives power layer chain)
 |
 |    Doc 25 (Request Dedup, PARTIAL) ---> Doc 39 (Shared Future -- generalizes ad-hoc patterns)
 |
 |    Doc 16 (Subscriptions, DONE) ---> Doc 37 (Scan Waiters -- one-shot waiters extend pub/sub)
 |
 |    Doc 47 (Memoization, DONE) ---> Doc 48 (Cache Warming -- uses memo for freshness checks)
 +------------------------------------------------------------------------
```

### Parallel Implementation Opportunities

These groups have no inter-dependencies and can be worked on simultaneously:

- **Group A** (Tier 1): Doc 01 -> 02, Doc 10 — independent of each other
- **Group B** (Tier 2): Doc 42, Doc 05 — independent of Tier 1 and each other
- **Group C** (Tier 4): Doc 12 + Doc 19 — all standalone utilities, no cross-deps
- **Group D** (Tier 5): Doc 13 + Doc 37 — independent search improvements
- **Group E** (Tier 2+3): Doc 35, Doc 45 — independent, can start after Tier 1

---

## Implementation Effort Estimates

| Effort | Meaning | Examples |
|--------|---------|---------|
| Small | 1-2 files, <200 lines | Doc 01 (new module), Doc 05 (add caps), Doc 19 (weak tables) |
| Medium | 3-6 files, 200-500 lines | Doc 32 (frame cache + coordinator), Doc 33 (viewport zones), Doc 13 (CharBag + integration), Doc 48 (warming + 5 strategies) |
| Large | 6+ files, 500+ lines | Doc 27 (pipeline refactor), Doc 38 (chunk parser), Doc 30 (structural sharing) |

---

## Audit Changelog (vs. Previous Assessment — Revision 4)

### Revision 3 → Revision 4 (March 8, 2026)

Full re-audit of all 48 documents against current codebase using 8 parallel
investigation agents. **No status changes.** All 48 classifications confirmed:

- **19 IMPLEMENTED**: 03, 04, 06, 07, 08, 11, 14, 16, 21, 23, 26, 29, 31, 34, 40, 41, 43, 44, 47
- **13 PARTIALLY IMPLEMENTED**: 02, 05, 09, 13, 17, 20, 22, 25, 28, 30, 33, 36, 48
- **16 NOT IMPLEMENTED**: 01, 10, 12, 15, 18, 19, 24, 27, 32, 35, 37, 38, 39, 42, 45, 46

Detailed confirmations with file:line evidence across all 48 documents:

**NOT IMPLEMENTED confirmations:**
- Doc 01 (LRU): No `lru_cache.lua`. `slug.lua:27-29` uses full-wipe (`_slug_cache = { [text] = slug }` on overflow). `date_utils.lua:43-45` has `PARSE_CACHE_MAX=5000` with same full-wipe pattern.
- Doc 10 (Process Limiting): `search_filter/ripgrep.lua:108-120` `spawn_rg()` has zero concurrency guards. Lines 207-211 and 245-249 spawn 2 concurrent rg per AND/OR node with no limiting. No `process_semaphore.lua`.
- Doc 12 (String Interning): No `string_intern.lua`. `vault_index_parser.lua:190` stores raw tag strings. Lines 232-239 compute `_name_lower`, `stem_lower`, `basename_lower` independently (no pool).
- Doc 15 (File Content Cache): No `file_cache.lua`. `preview.lua` reads files fresh on every K press. `embed_resolver.lua` re-reads from buffer/disk each call.
- Doc 18 (Memory-Weighted Eviction): No weigher function API anywhere. `connections.lua:14` uses `MAX_CACHE_ENTRIES = 500` (count-only, no byte budget).
- Doc 19 (Weak Tables): Zero `__mode` metamethod usage confirmed across entire vault codebase. No `weak_ref.lua`. *(weak_cache.lua removed as dead code; weak_callback integration into subscription_handle already complete.)*
- Doc 24 (Arena): No `render_arena.lua`. No `alloc_table()`, `alloc_array()`, or `with_scope()` patterns. All operations use `{}` for temporary tables.
- Doc 27 (Transform Pipeline): No `transform_pipeline.lua` or `line_tracker.lua`. `wikilink_highlights.lua:80` calls `nvim_buf_get_lines()` independently. Each highlight module maintains independent regex patterns.
- Doc 32 (Dual-Frame Cache): No `frame_cache.lua`. No per-buffer dual-frame caches. `tag_highlights.lua` and `wikilink_highlights.lua` do full-buffer clears and rebuilds on every render.
- Doc 35 (Region Tracking): No `region_tracker.lua`. No `nvim_buf_attach()` `on_lines` callback in any renderer. Full-viewport re-scans on every TextChanged.
- Doc 37 (Scan Waiters): `vault_index.lua:34-41` has `_subscribers` but NO `_waiters` list. No `wait_for()` or `wait_for_ready()` methods. Only persistent callbacks.
- Doc 38 (Content Chunking): `vault_index_parser.lua` is pure single-pass parsing. No chunk splitting, no SHA/digest. `vault_index.lua:17` shows `SCHEMA_VERSION = 4`.
- Doc 39 (Shared Futures): No `shared_promise.lua`. `url_validate.lua:8-10` has `_inflight = {}` (simple url→true set, not promise-based). `vault_index.lua:83` `_building` flag prevents re-entry but doesn't share result.
- Doc 42 (Content-Hash): `vault_index.lua:404-428` uses ONLY mtime+size detection. No `content_hash` field, no `compute_hash()`, no SHA/CRC32 computation.
- Doc 45 (Scheduling): No `work_scheduler.lua`. `embed.lua` uses `vim.defer_fn(fn, 150)`. `highlight_coordinator.lua` uses `cleanup.debounce()`. No priority levels.
- Doc 46 (Slot Map): No `slot_map.lua`. `embed_state.lua` uses direct hash tables with bufnr keys. No generational IDs or ABA protection.

**PARTIALLY IMPLEMENTED confirmations with specific gaps:**
- Doc 02: `slug.lua:27-29` resets entire 2000-entry cache on overflow. `embed_images.lua:19` has `_image_cache` with NO size limit (relies on generation invalidation). `url_validate.lua:12-13` `_domain_last_request` grows unbounded. `date_utils.lua:43-45` has `PARSE_CACHE_MAX=5000` with full-wipe. BufDelete cleanup ✓ in `task_hierarchy.lua:543-548`, `footnotes.lua:694-700`, `link_scan.lua:152-154`.
- Doc 05: `config.lua:426` has `max_files_from=500` for rg file-list. No `MAX_SEARCH_RESULT_FILES` or `MAX_SEARCH_RESULT_RANGES` caps. No `--max-count` to ripgrep. `search_filter/ripgrep.lua:202-236` AND operator doesn't restrict right to left's file set.
- Doc 09: `vault_index_parser.lua:199-216` creates both `headings` array AND `heading_slugs` set (not deduplicated). Links still have pre-computed `_name_lower`, `stem_lower` (lines 236-238). Full entry serialized to JSON (no derived field stripping).
- Doc 13: `search_filter.lua:103-132` `is_ast_superset()` ✓. `filter_utils.lua:138-150` early exits ✓. No `char_bag.lua` for character-level pre-filtering. No precomputed `_files_with_tags` sets in vault_index.
- Doc 17: `_generation` counter exists (`vault_index.lua:121`). Used by `completion_base.lua:96`, `connections.lua:49`. No formal `snapshot()` method. No staged build pattern. No atomic `_apply_staged()`.
- Doc 20: `connections.lua:354-414` `create_top_k(k)` min-heap ✓ with `insert()`, `min_score()`, `results()`. No generic `table_pool.lua` with `acquire()/release()`. No pool in search_filter, embed, or completion.
- Doc 22: `vault_index_build.lua:68-98` batch loop with `coroutine.yield()` ✓. `completion_base.lua:202-203` yields every `batch_size` ✓. `embed.lua:283-327` batch rendering ✓. `search_filter.lua:290-305` iterates all entries at once (no chunking). No `pipeline.lua` module.
- Doc 25: `url_validate.lua` has `_inflight` per-URL set. `completion_base.lua` has async coalescing via debounce+generation. `filter_utils.lua` has `create_memoized_resolver()`. No unified `request_coalescer.lua`.
- Doc 28: `block_patterns.lua` centralizes block ID patterns (`BLOCK_ID_PATTERN`, `BLOCK_ID_STRIP`, `match_id()`, `extract_from_lines()`). Wikilink pattern `"%[%[(.-)%]%]"` still duplicated across 15+ modules. Tag pattern duplicated in 4+ modules.
- Doc 30: Name/alias indexes store path references ✓. `old_entries` snapshot used in incremental updates ✓. Entries mutated in-place (e.g., `rel_stem_lower`). No `structural_sharing.lua`. No `arrays_equal()` or `share_unchanged()`.
- Doc 33: `embed.lua:174` `visible_range(margin)` ✓. `config.lua:96` `lazy_margin` ✓. No scroll-direction tracking. No asymmetric above/below prefetch zones. No `viewport.lua` module.
- Doc 36: `vault_index.lua:689` `_ensure_aggregates()` with `_aggregates_gen == _generation` guard ✓. Caches `_cached_tags`, `_cached_tag_counts`, `_cached_fm_keys`, `_cached_name_cache` ✓. Still O(N) full iteration (lines 699-723). No `summary_tree.lua`.
- Doc 48: `engine.lua` BufReadPost prewarm ✓. `completion_base.lua` pre-warming in `source.new()` ✓. `calendar.lua:72` `_deadline_cache` persists ✓. No `cache_warming.lua` module. No CursorHold idle prefetch. No systematic warming queue.

**IMPLEMENTED confirmations (selected highlights):**
- Doc 03: `resource_cleanup.lua:9-16` `close_timer()` with pcall ✓. `task_hierarchy.lua:543-548` BufDelete ✓. `footnotes.lua:694-700` BufDelete ✓.
- Doc 04: `completion_base.lua:118-236` coroutine iterator with `build_iter` ✓. Cancellation flag `state.cancelled` ✓. Debounce timer ✓.
- Doc 06: `connections.lua:14-18` 500-entry bounded cache ✓. Lines 354-414 top-K min-heap ✓. Lines 21-24 IDF cache with `_idf_gen` ✓. Lines 463-490 early pruning ✓.
- Doc 07: `vault_index.lua:233-237` `_schedule_persist()` with debounce ✓. Line 80 `_persist_in_flight` ✓. Line 249 generation skip ✓. Line 328-353 `persist_now()` for VimLeavePre ✓.
- Doc 08: `search/live.lua:32-35` `_prev_query`/`_prev_ast`/`_prev_file_set`/`_prev_index_gen` ✓. Lines 60-71 progressive filtering ✓. `search_filter.lua:103-136` `is_ast_superset()` ✓.
- Doc 11: `highlight_coordinator.lua:36-44` `register()` ✓. Lines 49-57 `schedule()` ✓. Lines 62-74 `run_all()` with shared `code_excl` ✓. Lines 76-145 consolidated autocmds ✓.
- Doc 14: `vault_index_build.lua:98` `coroutine.yield()` every batch ✓. `completion_base.lua:197-235` yields every `batch_size` ✓.
- Doc 16: `vault_index.lua:107-126` `subscribe(fn)` returns unsubscribe ✓. `_notify_update()` with generation+context ✓. `embed_sync.lua:62-80` manages subscription lifecycle ✓.
- Doc 21: `completion_base.lua:43` `active_state` with `cancelled` flag ✓. Line 106 cancellation ✓. Lines 158,163,184,209 multi-checkpoint checking ✓. `vault_index_build.lua:16-17` `_building` guard ✓.
- Doc 23: `resource_cleanup.lua` complete with `close_timer()`, `close_win()`, `delete_buf()`, `debounce()` ✓. `embed_state.lua:45-79` `gc_dict()`, `gc_stale_buffers()` ✓.
- Doc 26: `embed.lua` `visible_range(margin)` + lazy mode ✓. `highlight_coordinator.lua` viewport vs full-buffer modes ✓. `highlights.lua`, `tag_highlights.lua` `get_visible_range()` ✓.
- Doc 29: `engine.lua:18-34` `register_cache()` with `invalidate` + `invalidate_file` ✓. Lines 38-91 `invalidate_caches()` with `scope: "all"|"files"` ✓. `VaultCacheInvalidate` autocmd ✓.
- Doc 31: `:VaultCacheStatus`, `:VaultCompletionDebug`, `:VaultEmbedDebug`, `:VaultIndexStatus` commands ✓. `engine._cache_registry` with stats ✓.
- Doc 34: `filter_utils.lua` `create_memoized_resolver()` ✓. `connections.lua:21-24` `_idf_cache` + `_idf_gen` ✓. `calendar.lua` `_deadline_cache` ✓. `vault_index.lua` `_aggregates_gen` guard ✓.
- Doc 40: `url_validate.lua` `_domain_last_request` cooldown ✓. `check_rate_limit()` ✓. `max_concurrent` with `_inflight_count` ✓. `validate_batch()` ✓. Deferred retry via `vim.defer_fn()` ✓.
- Doc 41: `vault_index.lua` `_generation` + `_aggregates_gen` dual counter ✓. `completion_base.lua` `build_generation` + `cached_index_gen` ✓.
- Doc 43: `engine_watcher.lua:51-53` `_pending_changed_files` + `_pending_count` + `_fs_debounce_timer` ✓. Line 126 `cleanup.debounce()` with 500ms timeout ✓.
- Doc 44: `vault_index_build.lua:68` `config.index.batch_size` (default 20) ✓. `completion_base.lua:50` `config.completion.batch_size` (default 50) ✓.
- Doc 47: `filter_utils.lua` `create_memoized_resolver()` ✓. `connections.lua` generation-gated IDF ✓. `vault_index.lua` `_ensure_aggregates()` lazy rebuild ✓. `calendar.lua` `_deadline_cache` ✓.

### Revision 2 → Revision 3 (March 8, 2026)

Full re-audit of all 48 documents against current codebase. **No status changes.**
All 48 classifications confirmed:

- **19 IMPLEMENTED**: 03, 04, 06, 07, 08, 11, 14, 16, 21, 23, 26, 29, 31, 34, 40, 41, 43, 44, 47
- **13 PARTIALLY IMPLEMENTED**: 02, 05, 09, 13, 17, 20, 22, 25, 28, 30, 33, 36, 48
- **16 NOT IMPLEMENTED**: 01, 10, 12, 15, 18, 19, 24, 27, 32, 35, 37, 38, 39, 42, 45, 46

Key confirmations from deep code inspection:
- Doc 01 (LRU): Confirmed no `lru_cache.lua` exists; slug.lua comment references "LRU cache" but implementation is simple reset-on-overflow
- Doc 10 (Process Limiting): Confirmed `max_concurrent` only exists for URL validation (`config.url_validation.max_concurrent=5`), NOT for ripgrep; `spawn_rg()` has no concurrency guard
- Doc 19 (Weak Tables): Confirmed zero `__mode` metamethod usage across entire vault codebase
- Doc 24 (Arena): Confirmed no arena/bulk allocation patterns anywhere
- Doc 27 (Transform Pipeline): Confirmed each highlight module (`highlights.lua`, `tag_highlights.lua`, `wikilink_highlights.lua`) independently calls `nvim_buf_get_lines()`; only `code_excl` shared via coordinator
- Doc 30 (Structural Sharing): Confirmed incremental name/alias/inlinks updates with old_entries snapshot; entries mutated in-place (rel_stem_lower added); no formal CoW
- Doc 32 (Dual-Frame Cache): Confirmed no frame caching; every TextChanged recreates extmarks
- Doc 35 (Region Tracking): Confirmed no `nvim_buf_attach()` on_lines callback; no dirty line range tracking
- Doc 42 (Content-Hash): Confirmed only mtime+size detection (`vault_index.lua:404-428`); only unrelated SHA usage in `callout_folds.lua` for fold fingerprinting
- Doc 45 (Scheduling): Confirmed all async dispatch via `vim.schedule()`/`vim.defer_fn()`/`vim.uv.new_timer()` with no priority ordering
- Doc 48 (Cache Warming): Confirmed BufReadPost prewarm + completion pre-warming exist; no CursorHold idle prefetch or systematic `cache_warming.lua`

### Revision 1 → Revision 2

Key changes from the previous audit (revision 1 → revision 2):

| # | Previous Status | Current Status | Reason |
|---|---|---|---|
| 05 | NOT IMPLEMENTED | PARTIALLY IMPLEMENTED | config.search.max_files_from=500 exists for ripgrep file-list threshold; config.connections.max_results=30 and config.graph.max_nodes=50 provide per-module caps; connections top-K heap with early pruning |
| 08 | PARTIALLY IMPLEMENTED | IMPLEMENTED | All key components working: _prev_query/_prev_ast/_prev_file_set/_prev_index_gen caching in search/live.lua; is_ast_superset() with generation invalidation in search_filter.lua; progressive restriction via restrict_to parameter |
| 13 | NOT IMPLEMENTED | PARTIALLY IMPLEMENTED | AST-level pre-filtering found: is_ast_superset() in search_filter.lua; filter_utils early exits on include/exclude with quick boolean checks; missing CharBag bitset for candidate-level pre-filtering |
| 26 | PARTIALLY IMPLEMENTED | IMPLEMENTED | Comprehensive viewport handling found: embed.lua visible_range(margin) + lazy mode; highlight_coordinator.lua viewport vs full-buffer modes on TextChanged/WinScrolled; highlights.lua + tag_highlights.lua use shared get_visible_range() |
| 30 | NOT IMPLEMENTED | PARTIALLY IMPLEMENTED | Name/alias indexes store path references without duplication; loaded entries reused directly; incremental updates use old_entries snapshot; no formal CoW but reference sharing exists |
| 36 | NOT IMPLEMENTED | PARTIALLY IMPLEMENTED | _ensure_aggregates() with generation-gated lazy rebuild found (vault_index.lua:688-745); caches name_cache, tags, fm_keys, tag_counts; still O(N) iteration, no hierarchical tree |
| 40 | PARTIALLY IMPLEMENTED | IMPLEMENTED | Deferred retry via vim.defer_fn() found (not skip-on-limit); per-domain cooldown with check_rate_limit(); max_concurrent with _inflight_count; validate_batch() queue processing |
| 43 | PARTIALLY IMPLEMENTED | IMPLEMENTED | engine_watcher.lua implements dirty-flag pattern: _pending_changed_files + _pending_count + _fs_debounce_timer with cleanup.debounce(); batch drain after 500ms timeout |
| 48 | NOT IMPLEMENTED | PARTIALLY IMPLEMENTED | engine.lua BufReadPost prewarm with prebuild_name_cache_async() + URL cache load; completion_base pre-warming in source.new() constructor; calendar _deadline_cache persists across navigation; missing CursorHold idle prefetch |

### Historical Changelog (Original Assessment → Revision 1)

| # | Original Status | Revision 1 Status | Reason |
|---|---|---|---|
| 08 | NOT IMPLEMENTED | PARTIALLY IMPLEMENTED | Progressive filtering code found: _prev_query, _prev_ast, _prev_file_set in search/live.lua; is_ast_superset() in search_filter.lua |
| 15 | PARTIALLY IMPLEMENTED | NOT IMPLEMENTED | No file_cache.lua exists; no mtime-gated content caching found anywhere |
| 17 | IMPLEMENTED | PARTIALLY IMPLEMENTED | No formal snapshot() method on VaultIndex; completion_base captures state but no staged build or atomic apply |
| 20 | NOT IMPLEMENTED | PARTIALLY IMPLEMENTED | create_top_k(k) heap in connections.lua provides bounded result collection |
| 25 | IMPLEMENTED | PARTIALLY IMPLEMENTED | Core patterns exist (async coalescing, memoized resolver) but no unified dedup utility; multiple modules still lack deduplication |
| 27 | PARTIALLY IMPLEMENTED | NOT IMPLEMENTED | No pipeline modules exist; AST split is architectural (text vs metadata queries), not a rendering pipeline |
| 28 | NOT IMPLEMENTED | PARTIALLY IMPLEMENTED | block_patterns.lua exists with centralized block ID patterns |
| 35 | PARTIALLY IMPLEMENTED | NOT IMPLEMENTED | No region_tracker.lua; no nvim_buf_attach() on_lines tracking; no line-range dirty tracking in any module |
| 37 | PARTIALLY IMPLEMENTED | NOT IMPLEMENTED | Only persistent _subscribers exist; no one-shot waiter, no _waiters list, no wait_for() method |
| 39 | PARTIALLY IMPLEMENTED | NOT IMPLEMENTED | Only url_validate._inflight (ad-hoc, per-URL); no shared_future.lua module |
| 40 | IMPLEMENTED | PARTIALLY IMPLEMENTED | Per-domain cooldown exists but uses skip-on-limit instead of proper queuing |
| 43 | IMPLEMENTED | PARTIALLY IMPLEMENTED | Debounce exists in resource_cleanup but no watch-channel (dirty-flag + 0ms timer) primitive |
| 45 | PARTIALLY IMPLEMENTED | NOT IMPLEMENTED | No work_scheduler.lua; no priority queue; all async work dispatched arbitrarily via vim.schedule/defer_fn |
| 48 | PARTIALLY IMPLEMENTED | NOT IMPLEMENTED | No cache_warming.lua; no CursorHold prefetch; all caching purely reactive |

---

## Quick Reference: What To Implement Next

If you want the **single highest-impact next step**: **Doc 01 (LRU Cache Infrastructure)**
— it's a small standalone module that immediately improves doc 02's existing caches
and unlocks docs 18, 15, and 32.

If you want **fastest visible improvement**: **Doc 42 (Content-Hash Change Detection)**
— a small change to vault_index that eliminates redundant parsing on save-without-change,
which is a common user pattern (save file -> git checkout -> re-open).

If you want to **fix the biggest remaining risk**: **Doc 10 (Concurrent Process Limiting)**
— prevents unbounded ripgrep spawns on deeply nested search queries, which is the primary
remaining resource leak vector. Currently 5-15 concurrent rg instances can spawn.

If you want **maximum parallelism**: Start docs 01, 10, and 42 simultaneously — they
have zero overlap in modules touched and no shared dependencies.

If you want the **biggest rendering improvement**: **Doc 35 (Invalidation Region Tracking)**
— currently every TextChanged triggers full-viewport re-scans; region tracking reduces
re-render work by 90-98% for the common case of localized edits.
