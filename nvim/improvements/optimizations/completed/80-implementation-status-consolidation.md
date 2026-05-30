# 80 --- Implementation Status Consolidation

> This is a cross-reference status document, not an implementation guide.
> For individual implementations, see the specific optimization documents
> referenced below.

Cross-reference of all optimization documents (55-81) against the current
codebase state.

> **Purpose:** Single source of truth for implementation status. Each
> optimization document is self-contained with cross-references where
> complementary optimizations exist in other documents.
> Subsumed documents (56-rendering, 62) have been deleted.

---

## Fully Implemented Optimizations

| Optimization | Module(s) | Document |
|---|---|---|
| Generation tracking (_generation) | vault_index.lua | 76 |
| Generation-based completion cache | completion_base.lua | 57-completion |
| Completion cancellation mechanism | completion_base.lua | 57-completion |
| Configurable debounce_ms/batch_size | completion_base.lua | 57-completion |
| Coroutine chunked wikilink build | completion.lua | 57-completion |
| Tag hierarchy has_children detection | completion_tags.lua | 66 |
| Single-pass inline field parsing | completion_inline_fields.lua | 66 |
| BFS visited-table dedup (graph) | graph_filter/traversal.lua | 79 |
| Subgraph reach set memoization | search_filter/graph_traversal.lua | 79 |
| Tag sets pre-built in connections | connections.lua | 79 |
| Calendar generation-cached deadlines | calendar.lua | 61-calendar |
| Kanban spatial index for navigation | task_kanban.lua | 70 |
| Embed timer reuse (per-buffer) | embed_sync.lua, embed.lua | 68 |
| Single-pass embed descriptors | embed.lua | 68 |
| Backlinks batched file reading | backlinks.lua | 69 |
| Link extraction uses gmatch | link_utils.lua | 69 |
| Tag operations use vault index | tags.lua | 72 |
| Export single-pass pipeline | export.lua | 72 |
| Image extensions O(1) set lookup | config.lua | 77 |
| basename_lower on index entries | vault_index_parser.lua | 75 |
| Entry ctime/mtime as timestamps | vault_index_parser.lua | 57-search |
| Autolink viewport scaffolding | autolink.lua | 56-viewport |

---

## NOT Implemented — High Priority

### 1. Logger Early-Exit Before string.format
- **Document:** 77-watcher-logging-frontmatter-hot-path.md
- **File:** vault_log.lua:51-56
- **Impact:** Eliminates all string allocation for filtered debug calls

### 2. Changedtick-Cached Code Exclusion
- **Document:** 56-highlight-viewport-rendering.md
- **Files:** link_scan.lua (build_code_exclusion)
- **Impact:** 3-4x per debounce → 1 scan + cache hits

### 3. Highlight Viewport-Scoped Rendering
- **Document:** 56-highlight-viewport-rendering.md
- **Files:** highlights.lua, tag_highlights.lua, wikilink_highlights.lua, inline_fields.lua
- **Impact:** ~8x reduction per keystroke for 500-line files

### 4. Per-Buffer Debounce Timers
- **Document:** 56-highlight-viewport-rendering.md
- **Files:** All 5 highlight modules
- **Impact:** Prevents cross-buffer timer interference

### 5. Incremental Name Index in build_async()
- **Document:** 76-index-build-merge-precomputation.md
- **File:** vault_index_build.lua:84
- **Impact:** 5000 → 10 operations for warm-start builds

### 6. Generation-Cached all_tags() / all_frontmatter_keys()
- **Document:** 76-index-build-merge-precomputation.md
- **File:** vault_index.lua:563-595
- **Impact:** O(N) → O(1) per completion trigger

### 7. Cached file_count()
- **Document:** 76-index-build-merge-precomputation.md
- **File:** vault_index.lua:669-671
- **Impact:** O(N) → O(1) per call

### 8. Connection Scoring Top-K Heap
- **Document:** 60-graph-connections-performance.md
- **File:** connections.lua:464
- **Impact:** O(N log N) → O(N log K)

### 9. IDF Table Generation-Cached
- **Document:** 60-graph-connections-performance.md
- **File:** connections.lua:359-361
- **Impact:** Eliminates O(N) IDF rebuild per compute()

### 10. resolve_in_index Per-Traversal Memoization
- **Document:** 67-index-persistence-maintenance.md
- **Files:** graph_filter/traversal.lua, search_filter/graph_traversal.lua
- **Impact:** Memo eliminates redundant index lookups

---

## NOT Implemented — Medium Priority

| # | Optimization | Document |
|---|---|---|
| 11 | Pre-Computed rel_stem on Index Entries | 76 |
| 12 | Outlink Pre-Computed Stems (path_lower, stem_lower) | 58-parser |
| 13 | FilterContext Pre-Resolution | 55 |
| 14 | Task State Map (label_lower → mark) | 75 |
| 15 | Task Tag Pre-Lowering (tags_lower set) | 75 |
| 16 | Frontmatter cursor_in_frontmatter Caching | 77 |
| 17 | Field Accumulation Memoization in Completion | 57-completion |
| 18 | Highlight Navigation Position Caching | 78 |
| 19 | Outline Single-Pass with Bulk Line Fetch | 78 |
| 20 | ~~Preview Markdown Rendering Dedup~~ | ~~78~~ → consolidated into 61-calendar #3 |

---

## NOT Implemented — Low Priority

| # | Optimization | Document |
|---|---|---|
| 21 | vim.fn.fnamemodify → Pure Lua strip_extension | 79 |
| 22 | Sort Comparator Schwartzian Transform (pre-lowered keys) | 79 |
| 23 | vim.tbl_count → Counter Variables | 79 |
| 24 | Graph Render String Optimization | 58-graph |
| 25 | Watcher Cached skip_dirs | 77 |
| 26 | Config Re-Require Caching in Watcher | 77 |
| 27 | Startup Module Loading Tiering | 59-startup |
| 28 | Kanban Generation-Cached Task Collection | 70 |
| 29 | Task Hierarchy Generation Caching | 70 |
| 30 | Calendar days_in_month Lookup Table | 61-calendar |

---

## NOT Implemented — Deferred / High Effort

| # | Optimization | Document |
|---|---|---|
| 31 | Merged Triple Iteration in Index Build | 76 |
| 32 | Single-Pass Parser (prepare_lines + code mask) | 60-index |
| 33 | WAL-Based Incremental Persistence | 60-index |
| 34 | Embed Inverted Dependency Index | 68 |
| 35 | BFS Incremental Layer Caching | 60-graph |
| 36 | Parallel Ripgrep for AND/OR | 65 |
| 37 | Live Search Incremental Filtering | 57-search |

---

## Document Index

Each document is self-contained. Cross-references exist where complementary
optimizations touch related code paths, but each optimization has a single
canonical owner.

| Document | Optimizations Owned |
|---|---|
| 55-search-filter-precomputation | FilterContext pre-resolution |
| 56-highlight-viewport-rendering | Viewport rendering, code exclusion cache, per-buffer debounce, highlight coordinator |
| 57-completion-system-optimizations | Debounce alignment, adaptive batch sizing, field accumulation memo |
| 57-search-filter-performance | Pre-computed lowercase fields, cached date parsing, incremental live search, ripgrep output opt |
| 58-graph-connections-scoring | BFS queue opt, graph render strings, connection cache invalidation |
| 58-parser-single-pass-optimization | Pre-computed link resolution keys, resolution table reuse |
| 59-startup-lazy-loading | Phased module loading, async watcher init, async index load, lazy search |
| 59-completion-link-resolution | Path proximity scoring, direct link nav, cached heading slug |
| 60-graph-connections-performance | Top-K heap, IDF cache, incremental BFS, batched predicates |
| 60-index-persistence-memory | WAL persistence, reduced entry memory, single-pass parser |
| 61-startup-and-watcher-performance | Remove blocking fallback, skip preemptive dir scan |
| 61-calendar-task-ui-optimizations | Calendar scanning, task listing cache, preview float reuse, incremental re-render, timeline viewport |
| 63-engine-startup-performance | Watcher fs_stat fast-path, display width fast-path, code exclusion linear scan |
| 64-footnotes-wikilink-hl-pcall-batching | Cached footnote parsing, reduce per-extmark pcall |
| 65-search-pipeline-efficiency | AST classification cache, parallel ripgrep, tmpfile reuse, flattened outlinks |
| 66-completion-build-efficiency | Single-pass field accumulation, tag hierarchy pre-index |
| 67-index-persistence-maintenance | Change-aware persistence, batched watcher invalidation, memoized path resolution |
| 68-embed-sync-image-cache-performance | Inverted dependency index, selective image cache invalidation, timer reuse, single-pass descriptors |
| 69-link-navigation-diagnostic-caching | Batched backlinks, cached weekly review, link extraction gmatch, block ID from index |
| 70-task-ui-generation-caching-spatial-index | Kanban task cache, spatial index, task hierarchy cache, overdue detection cache |
| 71-callout-folds-frontmatter-editor-rendering | Callout boundary detection, merged frontmatter iteration, deferred fold existence check |
| 72-frecency-tags-export-rename-efficiency | Index-based frecency, index-based tags, export pipeline, pre-compiled rename patterns |
| 73-search-completion-graph-render-caching | Cached file names, pre-lowered headings |
| 74-inline-fields-link-scan-efficiency | Unified field-finding, bitset overlap check, cached buffer fields, interval position tracking |
| 75-match-field-task-lowercase-caching | Pre-lowered basename, task state map, filter timestamp, task tag pre-lowering, predicate short-circuit |
| 76-index-build-merge-precomputation | Incremental name index, merged triple iteration, cached aggregates, rel_stem, file_count |
| 77-watcher-logging-frontmatter-hot-path | Skip-dirs cache, pending counter, image ext cache, logger early-exit, cursor_in_frontmatter cache |
| 78-highlight-navigation-outline-dedup | Highlight nav caching, tag nav caching, outline single-pass (~~preview dedup~~ → consolidated into 61-calendar #3) |
| 79-graph-traversal-connections-refinement | Pre-lowered sort keys, cached tbl_count, tag sets, single-pass dedup, subgraph memo |
| 81-cross-module-caching-new-opportunities | heading_to_slug memo, date_utils memo |

---

## Recommended Implementation Order

**Phase 1 — Quick wins:**
1. Logger early-exit (#1) → doc 77
2. Cached file_count (#7) → doc 76
3. Incremental name index in build_async (#5) → doc 76
4. Generation-cached all_tags/all_frontmatter_keys (#6) → doc 76
5. Per-buffer debounce timers (#4) → doc 56-viewport

**Phase 2 — Medium effort, high impact:**
6. Changedtick-cached code exclusion (#2) → doc 56-viewport
7. Highlight viewport-scoped rendering (#3) → doc 56-viewport
8. IDF generation cache (#9) → doc 60-graph
9. resolve_in_index memoization (#10) → doc 67
10. FilterContext pre-resolution (#13) → doc 55

**Phase 3 — Scoring and matching:**
11. Connection top-K heap (#8) → doc 60-graph
12. Pre-computed rel_stem (#11) → doc 76
13. Outlink stems (#12) → doc 58-parser
14. Task state map (#14) → doc 75
15. Task tag pre-lowering (#15) → doc 75
