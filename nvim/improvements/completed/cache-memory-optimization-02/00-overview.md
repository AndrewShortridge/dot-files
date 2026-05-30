# Cache & Memory Optimization Plan — Overview

## Context

This optimization plan is informed by a deep analysis of:
1. The current nvim vault plugin codebase (~32,000 lines across 179 Lua modules)
2. The Zed editor's memory optimization architecture (Rust, ~500K+ lines)

The vault plugin already has a solid foundation — generation-based cache invalidation,
incremental indexing, async coroutine builds, and centralized resource cleanup. These
documents identify targeted improvements inspired by Zed's production-grade patterns.

## Document Index

| # | Document | Priority | Scope |
|---|----------|----------|-------|
| 01 | [LRU Cache Infrastructure](01-lru-cache-infrastructure.md) | HIGH | New utility module |
| 02 | [Bounded Caches & Eviction](02-bounded-caches-and-eviction.md) | HIGH | slug, section, image caches |
| 03 | [Timer & Resource Leak Fixes](03-timer-resource-leak-fixes.md) | HIGH | task_hierarchy, footnotes, link_scan |
| 04 | [Completion Memory Optimization](04-completion-memory-optimization.md) | MEDIUM | completion_base, completion.lua |
| 05 | [Search Result Streaming & Limits](05-search-result-streaming.md) | MEDIUM | search_filter, ripgrep, advanced |
| 06 | [Connections Cache Optimization](06-connections-cache-optimization.md) | MEDIUM | connections.lua scoring |
| 07 | [Debounced Persistence & Write Coalescing](07-debounced-persistence.md) | LOW | vault_index persistence |
| 08 | [Progressive Search Filtering](08-progressive-search-filtering.md) | LOW | live search |
| 09 | [Index Memory Reduction](09-index-memory-reduction.md) | LOW | vault_index data structures |
| 10 | [Concurrent Process Limiting](10-concurrent-process-limiting.md) | HIGH | ripgrep spawns, semaphore |
| 11 | [Autocmd Event Batching](11-autocmd-event-batching.md) | MEDIUM | event coalescing, BufEnter cascade |
| 12 | [String Interning Infrastructure](12-string-interning-infrastructure.md) | MEDIUM | tag/FM/path deduplication |
| 13 | [Early Exit Pre-Filtering](13-early-exit-prefiltering.md) | MEDIUM | CharBag, completion/search |
| 14 | [Cooperative Yielding](14-cooperative-yielding.md) | MEDIUM | search/filter UI responsiveness |
| 15 | [Preview & Render Caching](15-preview-render-caching.md) | LOW | file content cache, mtime gating |
| 16 | [Subscription Lifecycle Management](16-subscription-lifecycle-management.md) | MEDIUM | subscriber cleanup, weak refs |
| 17 | [Snapshot-Based Index Reads](17-snapshot-based-index-reads.md) | LOW | consistency during async builds |
| 18 | [Memory-Weighted Cache Eviction](18-memory-weighted-cache-eviction.md) | MEDIUM | byte-budget LRU, weigher functions |
| 19 | [Weak Table GC Integration](19-weak-table-gc-integration.md) | MEDIUM | Lua weak tables, auto-cleanup |
| 20 | [Table/Object Pooling](20-table-object-pooling.md) | MEDIUM | reuse tables, reduce GC pressure |
| 21 | [Stale Operation Cancellation](21-stale-operation-cancellation.md) | HIGH | monotonic IDs, cancel flags |
| 22 | [Chunked Pipeline Processing](22-chunked-pipeline-processing.md) | MEDIUM | streaming reduce, top-K, backpressure |
| 23 | [RAII-Style Cleanup Guards](23-cleanup-guards.md) | MEDIUM | scope guards, deterministic cleanup |
| 24 | [Per-Render Arena Allocation](24-per-render-arena-allocation.md) | MEDIUM | scope-based bulk alloc/dealloc |
| 25 | [Concurrent Request Deduplication](25-concurrent-request-deduplication.md) | HIGH | shared futures, coalescing |
| 26 | [Viewport-Restricted Rendering](26-viewport-restricted-rendering.md) | HIGH | visible-range-only rendering |
| 27 | [Layered Transform Pipeline](27-layered-transform-pipeline.md) | MEDIUM | incremental multi-layer display |
| 28 | [Pattern Compilation Cache](28-pattern-compilation-cache.md) | LOW | centralized patterns, regex cache |
| 29 | [Tiered Cache Invalidation](29-tiered-cache-invalidation.md) | HIGH | full/partial/additive invalidation |
| 30 | [Structural Sharing for Collections](30-structural-sharing-for-collections.md) | MEDIUM | Arc-style sub-table sharing |
| 31 | [Memory Profiling Infrastructure](31-memory-profiling-infrastructure.md) | MEDIUM | unified diagnostics, cache stats |
| 32 | [Dual-Frame Render Cache](32-dual-frame-render-cache.md) | HIGH | two-gen cache swap, render replay |
| 33 | [Three-Zone Viewport Prefetch](33-three-zone-viewport-prefetch.md) | HIGH | visible + above/below prefetch zones |
| 34 | [Memoized State Checks](34-memoized-state-checks.md) | HIGH | (version, result) tuple caching |
| 35 | [Invalidation Region Tracking](35-invalidation-region-tracking.md) | HIGH | region-scoped validity |
| 36 | [Hierarchical Summary Index](36-hierarchical-summary-index.md) | MEDIUM | O(log N) subtree aggregates |
| 37 | [Scan Completion Waiters](37-scan-completion-waiters.md) | MEDIUM | one-shot async waiters |
| 38 | [Syntactic Content Chunking](38-syntactic-content-chunking.md) | MEDIUM | digest-based chunk caching |
| 39 | [Shared Future Deduplication](39-shared-future-deduplication.md) | MEDIUM | multi-consumer shared tasks |
| 40 | [Rate-Limited Domain Queuing](40-rate-limited-domain-queuing.md) | MEDIUM | fair per-domain queuing |
| 41 | [Operation Counter Staleness](41-operation-counter-staleness.md) | HIGH | dual counter stale detection |
| 42 | [Content-Hash Change Detection](42-content-hash-change-detection.md) | HIGH | content digest skip re-parse |
| 43 | [Watch-Style Event Coalescing](43-watch-style-event-coalescing.md) | MEDIUM | single-value collapse channels |
| 44 | [Threshold-Based Batch Drain](44-threshold-based-batch-drain.md) | MEDIUM | count/byte threshold batching |
| 45 | [Prioritized Async Work Scheduling](45-prioritized-async-work-scheduling.md) | HIGH | visible-first scheduling |
| 46 | [Generational Slot Map Entity Storage](46-generational-slot-map-entity-storage.md) | LOW | O(1) dense entity store |
| 47 | [Hot-Path Memoization](47-hot-path-memoization.md) | HIGH | scope/versioned/session memo |
| 48 | [Idle-Time Proactive Cache Warming](48-idle-time-proactive-cache-warming.md) | MEDIUM | CursorHold prefetch |

## Prioritization Rationale

**HIGH** — Fixes active memory leaks or prevents unbounded growth in hot paths.
These should be addressed first as they affect long editing sessions.

**MEDIUM** — Reduces peak memory for large vaults (5K+ notes). Important for
scalability but not causing issues at typical vault sizes (<2K notes).

**LOW** — Micro-optimizations and architectural improvements that improve memory
efficiency but have smaller absolute impact.

## Key Patterns from Zed

The following Zed patterns are most applicable to the Lua/Neovim context:

1. **Bounded LRU caches** (VecDeque ring buffer, max_capacity)
2. **Result limits** (MAX_SEARCH_RESULT_FILES = 5000, MAX_SEARCH_RESULT_RANGES = 10000)
3. **Debounced write coalescing** (100ms workspace serialization)
4. **Generation-based invalidation** (already used — validate and extend)
5. **Lazy resolution** (resolve only visible items, expand range on scroll)
6. **Early exit filtering** (CharBag superset check before expensive scoring)
7. **Object pooling** (reuse expensive allocations across operations)
8. **Semaphore-based concurrency limiting** (Arc<Semaphore> for LSP/process bounds)
9. **Event batching** (ready_chunks(128), DebouncedDelay for coalescing)
10. **String interning** (SharedString, Arc<str> for path/name deduplication)
11. **Cooperative yielding** (YIELD_INTERVAL = 20000 in search hot paths)
12. **Weak references & subscription cleanup** (WeakEntity auto-prunes dead refs)
13. **Immutable snapshots** (WorktreeSnapshot for consistent concurrent reads)
14. **Render caching** (markdown_cache in CompletionsMenu, last_loaded_file dedup)
15. **Per-frame bump arena** (arena.rs scope-based bulk alloc/dealloc for UI elements)
16. **Shared future deduplication** (buffer_store.rs Shared<Task> coalesces identical requests)
17. **Windowed virtual rendering** (uniform_list.rs renders only visible items)
18. **Layered display transforms** (display_map.rs incremental multi-layer chain)
19. **Three-tier invalidation** (inlay_hint_cache.rs Full/Partial/Additive strategy)
20. **Arc structural sharing** (BufferSnapshot shares unchanged sub-trees across versions)

## Current Architecture Strengths (Preserve)

- Generation-based cache invalidation throughout (elegant, no TTL polling)
- Incremental name/alias/inlinks index updates (O(changed) not O(N))
- Async coroutine builds with batch yielding (UI-responsive)
- Centralized resource_cleanup.lua (timer/debounce management)
- Per-buffer BufDelete cleanup in highlight modules
- gc_stale_buffers() in embed system

## Phase 3: New Optimizations (Docs 10-17)

Documents 10-17 were identified through a second deep analysis of the Zed codebase,
focusing on patterns not covered by the original 9 documents:

| Phase | Documents | Priority | Focus |
|-------|-----------|----------|-------|
| 3a | 10 (Process Limiting) | HIGH | Bound concurrent rg spawns |
| 3b | 11, 12, 13, 14, 16 | MEDIUM | Event batching, string interning, pre-filtering, yielding, subscriptions |
| 3c | 15, 17 | LOW | File content caching, snapshot consistency |

**Recommended implementation order (Phase 3):**
1. Doc 10 (Concurrent Process Limiting) — standalone, high impact on live search
2. Doc 16 (Subscription Lifecycle) — standalone, prevents accumulation leaks
3. Doc 12 (String Interning) — standalone, complements doc 09
4. Doc 13 (Early Exit Pre-Filtering) — standalone, complements docs 04/08
5. Doc 14 (Cooperative Yielding) — standalone, complements doc 05
6. Doc 11 (Event Batching) — larger scope, coordinates with highlight_coordinator
7. Docs 15, 17 — low priority, implement when other optimizations are stable

## Phase 4: New Optimizations (Docs 18-23)

Documents 18-23 were identified through a third deep analysis of the Zed codebase,
focusing on advanced patterns not covered by the original 17 documents. These target
GC pressure reduction, deterministic cleanup, and pipeline efficiency.

| Phase | Documents | Priority | Focus |
|-------|-----------|----------|-------|
| 4a | 21 (Stale Operation Cancellation) | HIGH | Monotonic IDs + cancel flags for live search, completion, connections |
| 4b | 18, 20, 22, 23 | MEDIUM | Memory-weighted eviction, table pooling, chunked pipelines, cleanup guards |
| 4c | 19 | MEDIUM | Lua weak table integration for automatic GC cooperation |

**Key Zed patterns informing Phase 4:**

15. **Memory-weighted eviction** (Moka cache weigher functions — budget by bytes, not items)
16. **Weak references for automatic cleanup** (Weak<> everywhere — connections, subscriptions, buffers)
17. **Object pooling** (QUERY_CURSORS static pool with Drop-based return)
18. **Monotonic operation IDs** (file_finder search_count for stale result rejection)
19. **Ready-chunks pipeline** (ready_chunks(64) for bounded batch processing with backpressure)
20. **RAII cleanup guards** (Drop trait for timers, connections, processes, counters)

**Recommended implementation order (Phase 4):**
1. Doc 21 (Stale Operation Cancellation) — HIGH, standalone, 50-80% wasted CPU reduction
2. Doc 23 (Cleanup Guards) — standalone, prevents resource leaks on error paths
3. Doc 18 (Memory-Weighted Eviction) — extends doc 01 LRU, predictable memory budgets
4. Doc 22 (Chunked Pipeline) — extends doc 14, 97% peak memory reduction for search
5. Doc 20 (Table Pooling) — standalone, 90% GC pressure reduction in hot paths
6. Doc 19 (Weak Table GC) — standalone safety net, complements docs 02/03/16

**Cross-document dependencies (Phase 4):**
- Doc 18 extends Doc 01 (LRU) with weigher API
- Doc 21 complements Doc 10 (Process Limiting) — cancel stale operations + limit concurrent ones
- Doc 22 extends Doc 14 (Cooperative Yielding) with pipeline abstractions
- Doc 19 complements Docs 02/03/16 — weak tables as safety net behind explicit cleanup
- Doc 20 and Doc 22 compose well — pooled tables flowing through chunked pipelines

## Phase 5: New Optimizations (Docs 24-31)

Documents 24-31 were identified through a fourth deep analysis of the Zed codebase,
focusing on architectural patterns not covered by the original 23 documents. These target
rendering efficiency, invalidation granularity, request deduplication, and observability.

| Phase | Documents | Priority | Focus |
|-------|-----------|----------|-------|
| 5a | 25 (Request Dedup), 26 (Viewport Rendering), 29 (Tiered Invalidation) | HIGH | Eliminate redundant work at macro level |
| 5b | 24, 27, 30, 31 | MEDIUM | Arena allocation, layered pipeline, structural sharing, profiling |
| 5c | 28 | LOW | Pattern compilation caching |

**Key Zed patterns informing Phase 5:**

21. **Per-frame bump arena** (arena.rs — scope-based bulk allocation/deallocation)
22. **Shared future deduplication** (buffer_store.rs — Shared<Task> coalesces identical requests)
23. **Windowed/virtual list rendering** (uniform_list.rs — only render visible items)
24. **Layered display map** (display_map.rs — Buffer→Inlay→Fold→Tab→Wrap→Block chain)
25. **LazyLock regex caching** (search.rs — compile once, reuse forever)
26. **Three-tier invalidation** (inlay_hint_cache.rs — Full/Partial/Additive)
27. **Arc structural sharing** (BufferSnapshot — unchanged sub-trees shared across versions)
28. **Entity leak detector** (entity_map.rs — debug-mode allocation tracking and assertions)

**Recommended implementation order (Phase 5):**
1. Doc 29 (Tiered Invalidation) — HIGH, reduces 80-95% of unnecessary cache rebuilds
2. Doc 26 (Viewport-Restricted Rendering) — HIGH, 90%+ fewer extmarks in large files
3. Doc 25 (Request Deduplication) — HIGH, eliminates duplicate async work
4. Doc 31 (Memory Profiling) — MEDIUM, enables measurement of all other optimizations
5. Doc 27 (Layered Transform Pipeline) — MEDIUM, 85% fewer buffer reads per edit
6. Doc 30 (Structural Sharing) — MEDIUM, 40-60% fewer table allocations in index updates
7. Doc 24 (Per-Render Arena) — MEDIUM, 60-80% GC reduction in render cycles
8. Doc 28 (Pattern Compilation Cache) — LOW, modest perf gain, significant code quality win

**Cross-document dependencies (Phase 5):**
- Doc 24 (Arena) complements Doc 20 (Pooling) — arena for scope-scoped, pooling for type-scoped
- Doc 25 (Dedup) complements Doc 21 (Cancellation) — dedup identical + cancel stale
- Doc 26 (Viewport) complements Doc 27 (Pipeline) — pipeline produces, viewport restricts
- Doc 27 (Pipeline) complements Doc 28 (Patterns) — shared patterns feed shared parse layer
- Doc 29 (Tiered) complements Doc 16 (Subscriptions) — subscribers declare interests
- Doc 30 (Sharing) complements Docs 09/12 — table-level sharing + string interning + lazy fields
- Doc 31 (Profiling) validates ALL other optimizations — implement early for measurement

## Phase 6: Zed-Inspired Deep Optimizations (Docs 32-41)

Documents 32-41 were identified through a fifth deep analysis of the Zed codebase,
cross-referenced against the current nvim vault implementation. These target render
caching patterns, viewport prefetch strategies, memoization, region-based invalidation,
hierarchical indexing, async coordination, and staleness detection — all patterns
actively used in Zed's production code but not yet represented in the vault plugin.

| Phase | Documents | Priority | Focus |
|-------|-----------|----------|-------|
| 6a | 32 (Dual-Frame Render Cache), 35 (Invalidation Region Tracking) | HIGH | Render efficiency: avoid full-buffer recomputation |
| 6b | 33 (Three-Zone Viewport Prefetch), 34 (Memoized State Checks), 41 (Operation Counter Staleness) | HIGH | Smooth scrolling, redundant check elimination, stale result detection |
| 6c | 36 (Hierarchical Summary Index), 37 (Scan Completion Waiters), 39 (Shared Future Dedup) | MEDIUM | Index query efficiency, async coordination |
| 6d | 38 (Syntactic Content Chunking), 40 (Rate-Limited Domain Queuing) | MEDIUM | Incremental parsing, fair URL validation |

### Document Details

| # | Document | Priority | Zed Inspiration |
|---|----------|----------|-----------------|
| 32 | [Dual-Frame Render Cache](32-dual-frame-render-cache.md) | HIGH | `line_layout.rs` FrameCache with previous/current swap |
| 33 | [Three-Zone Viewport Prefetch](33-three-zone-viewport-prefetch.md) | HIGH | `inlay_hint_cache.rs` QueryRanges (before/visible/after) |
| 34 | [Memoized State Checks](34-memoized-state-checks.md) | HIGH | `buffer.rs` has_unsaved_edits (version, result) tuple |
| 35 | [Invalidation Region Tracking](35-invalidation-region-tracking.md) | HIGH | `editor.rs` InvalidationStack region-based validity |
| 36 | [Hierarchical Summary Index](36-hierarchical-summary-index.md) | MEDIUM | `sum_tree.rs` cached subtree summaries |
| 37 | [Scan Completion Waiters](37-scan-completion-waiters.md) | MEDIUM | `worktree.rs` snapshot_subscriptions one-shot waiters |
| 38 | [Syntactic Content Chunking](38-syntactic-content-chunking.md) | MEDIUM | `chunking.rs` syntax-aware splits with SHA256 digests |
| 39 | [Shared Future Deduplication](39-shared-future-deduplication.md) | MEDIUM | `Shared<Task>` concurrent consumer pattern |
| 40 | [Rate-Limited Domain Queuing](40-rate-limited-domain-queuing.md) | MEDIUM | `rate_limiter.rs` semaphore guards with fair queuing |
| 41 | [Operation Counter Staleness](41-operation-counter-staleness.md) | HIGH | `git_store.rs` dual operation counters |

### Key Zed Patterns Informing Phase 6

29. **Dual-frame cache swap** (line_layout.rs — previous/current frame caches, promote-on-hit, discard at frame end)
30. **Three-zone viewport query** (inlay_hint_cache.rs — visible + prefetch above/below, scroll-direction priority)
31. **Memoized boolean checks** (buffer.rs — (version, result) tuple avoids re-evaluation of unchanged state)
32. **Invalidation region stack** (editor.rs — track valid regions, invalidate only on boundary exit)
33. **Hierarchical summary tree** (sum_tree.rs — O(log N) aggregate queries via cached subtree summaries)
34. **Scan completion subscriptions** (worktree.rs — one-shot waiters for specific scan_id completion)
35. **Syntax-aware content chunking** (chunking.rs — 1KB-8KB chunks with digest-based change detection)
36. **Shared task futures** (git_store.rs — Shared<Task> lets multiple callers await same in-flight operation)
37. **Semaphore-guarded rate limiting** (rate_limiter.rs — RAII guards with fair queuing, not skip-on-busy)
38. **Operation counter staleness** (git_store.rs — dual counters detect stale async results on completion)

### Recommended Implementation Order (Phase 6)

1. Doc 41 (Operation Counter Staleness) — standalone, lightweight, fixes race conditions across 5+ modules
2. Doc 34 (Memoized State Checks) — standalone, eliminates 80-90% of redundant boolean checks
3. Doc 32 (Dual-Frame Render Cache) — standalone utility, 60-80% render work reduction
4. Doc 35 (Invalidation Region Tracking) — extends autocmd integration, 90%+ reduction for localized edits
5. Doc 33 (Three-Zone Viewport Prefetch) — extends doc 26, eliminates scroll pop-in
6. Doc 37 (Scan Completion Waiters) — extends vault_index, replaces polling patterns
7. Doc 39 (Shared Future Dedup) — complements doc 25, eliminates duplicate in-flight work
8. Doc 36 (Hierarchical Summary Index) — extends vault_index, O(log N) aggregates
9. Doc 38 (Syntactic Content Chunking) — extends vault_index parser, reduces re-parse by ~90%
10. Doc 40 (Rate-Limited Domain Queuing) — extends url_validate, ensures 100% validation coverage

### Cross-Document Dependencies (Phase 6)

- Doc 32 (Dual-Frame Cache) complements Doc 26 (Viewport Rendering) — frame cache stores viewport renders
- Doc 33 (Three-Zone Prefetch) extends Doc 26 (Viewport Rendering) — adds prefetch zones around viewport
- Doc 34 (Memoized Checks) complements Doc 29 (Tiered Invalidation) — memoization reduces invalidation cost
- Doc 35 (Region Tracking) complements Doc 32 (Dual-Frame Cache) — regions determine which cache entries to preserve
- Doc 36 (Summary Index) extends Doc 09 (Index Memory) — hierarchical structure replaces flat aggregation
- Doc 37 (Completion Waiters) extends Doc 16 (Subscription Lifecycle) — one-shot waiters vs persistent subscribers
- Doc 38 (Content Chunking) extends Doc 09 (Index Memory) — chunk-level caching within files
- Doc 39 (Shared Future Dedup) extends Doc 25 (Request Dedup) — in-flight sharing vs time-window coalescing
- Doc 40 (Rate-Limited Queuing) extends Doc 10 (Process Limiting) — queuing vs semaphore for external requests
- Doc 41 (Operation Counters) extends Doc 21 (Stale Cancellation) — detect staleness on completion vs cancel in-flight

## Phase 7: Cross-Cutting Optimization Patterns (Docs 42-48)

Documents 42-48 were identified through a sixth deep analysis of the Zed codebase,
cross-referenced against the current vault implementation and all existing optimization
documents (01-41). These target patterns that cut across multiple modules: content-based
change detection, event coalescing primitives, batch processing, priority scheduling,
entity lifecycle management, memoization infrastructure, and proactive cache warming.

| Phase | Documents | Priority | Focus |
|-------|-----------|----------|-------|
| 7a | 42 (Content-Hash Detection), 45 (Prioritized Scheduling), 47 (Hot-Path Memoization) | HIGH | Eliminate redundant work at fundamental level |
| 7b | 43 (Event Coalescing), 44 (Batch Drain), 48 (Cache Warming) | MEDIUM | New scheduling and batching primitives |
| 7c | 46 (Generational Slot Map) | LOW | Advanced entity lifecycle infrastructure |

### Document Details

| # | Document | Priority | Zed Inspiration |
|---|----------|----------|-----------------|
| 42 | [Content-Hash Change Detection](42-content-hash-change-detection.md) | HIGH | `embedding_index.rs` SHA-256 chunk digests for true change detection |
| 43 | [Watch-Style Event Coalescing](43-watch-style-event-coalescing.md) | MEDIUM | `postage::watch` single-value channels in project_diff, git_store |
| 44 | [Threshold-Based Batch Drain](44-threshold-based-batch-drain.md) | MEDIUM | `summary_backlog.rs` count+byte thresholds, `ready_chunks(64)` |
| 45 | [Prioritized Async Work Scheduling](45-prioritized-async-work-scheduling.md) | HIGH | `inlay_hint_cache.rs` visible-first fetching, executor priority |
| 46 | [Generational Slot Map Entity Storage](46-generational-slot-map-entity-storage.md) | LOW | `entity_map.rs` SlotMap with generational IDs, leak detection |
| 47 | [Hot-Path Memoization](47-hot-path-memoization.md) | HIGH | `buffer.rs` (version, result) tuples, scope-local memo factories |
| 48 | [Idle-Time Proactive Cache Warming](48-idle-time-proactive-cache-warming.md) | MEDIUM | `inlay_hint_cache.rs` invisible range prefetch, WrapMap background work |

### Key Zed Patterns Informing Phase 7

39. **Content-hash change detection** (embedding_index.rs — SHA-256 digests skip re-indexing unchanged content)
40. **Watch-channel coalescing** (postage::watch — single-value channels collapse rapid events)
41. **Threshold-based batch drain** (summary_backlog.rs — count OR byte threshold triggers batch processing)
42. **Visible-first async scheduling** (inlay_hint_cache.rs — visible range fetched before off-screen)
43. **Generational slot map** (entity_map.rs — O(1) dense storage with ABA safety and leak detection)
44. **Scope-local memoization** (buffer.rs — version-gated result caching, no external cache infrastructure)
45. **Idle-time cache warming** (WrapMap, inlay hints — prefetch during user idle periods)

### Recommended Implementation Order (Phase 7)

1. Doc 47 (Hot-Path Memoization) — standalone utility, eliminates 50-95% redundant computation
2. Doc 42 (Content-Hash Detection) — standalone, 90-99% parse cost avoided for touched-unchanged files
3. Doc 45 (Prioritized Scheduling) — standalone, 50-70% faster perceived responsiveness
4. Doc 43 (Event Coalescing) — standalone utility, near-zero latency state synchronization
5. Doc 44 (Batch Drain) — standalone utility, predictable memory and batch sizes
6. Doc 48 (Cache Warming) — depends on docs 45/47, eliminates cold-start latency
7. Doc 46 (Slot Map) — advanced infrastructure, improves correctness and debuggability

### Cross-Document Dependencies (Phase 7)

- Doc 42 (Content-Hash) complements Doc 09 (Index Memory) — hash stored alongside index entries
- Doc 43 (Event Coalescing) complements Doc 11 (Event Batching) — coalescing is temporal, batching is structural
- Doc 44 (Batch Drain) extends Doc 22 (Chunked Pipeline) — batch drain accumulates incoming, pipeline chunks existing
- Doc 45 (Scheduling) complements Docs 14, 21, 26 — priority ordering across yielding, cancellation, viewport
- Doc 46 (Slot Map) complements Docs 16, 19 — generational safety alongside subscription lifecycle and weak tables
- Doc 47 (Memoization) extends Doc 34 (Memoized State Checks) — general memoize.lua powers doc 34's patterns
- Doc 48 (Cache Warming) depends on Docs 45, 47 — uses scheduler for idle scheduling, memo for freshness checks
