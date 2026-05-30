# Optimization Implementation Order

> Generated from analysis of all optimization documents (55-82).
> Doc 80 is a status tracker, not an implementation target.
> Doc 75 is fully implemented. Docs 68, 69, 72, 76, 79, and 61-calendar are partially implemented.

---

## Dependency Graph

```
Phase 1 (foundations) ---+--> Phase 2 (highlights)
                        +--> Phase 3 (parser/index precomputation)
                        |        \--> Phase 4 (search/filter)
                        |                \--> Phase 5 (graph/connections)
                        +--> Phase 6 (completion/UI)
                        +--> Phase 7 (startup)
                        +--> Phase 8 (task/calendar polish)
                        \--> Phase 9 (miscellaneous)
                                 Phase 10 (deferred high-effort)

Notable cross-phase deps:
  Doc 58-parser (Phase 3) --> Doc 55 (Phase 4)
  Doc 67 (Phase 3) --> Doc 60-graph (Phase 5)
  Doc 82 (Phase 1) --> Doc 58-parser (Phase 3)
  Doc 73 (Phase 6) --> Doc 75 (implemented)
```

---

## Phase 1: Foundation Quick Wins

*Low effort, zero dependencies, immediate impact across hot paths.*

| Priority | Document | Focus | Complexity | Impact |
|----------|----------|-------|------------|--------|
| 1 | Doc 77 | Watcher, logging, and frontmatter hot path optimizations | Low | High |
| 2 | Doc 76 | Index build incremental updates and cached aggregates (remaining items) | Low | High |
| 3 | Doc 81 | Cross-module heading slug and date parse memoization | Low | Medium |
| 4 | Doc 82 | Residual lowercase allocations and graph tag hierarchy fix | Low | Medium |

**Rationale:** All items are isolated, small changes. Doc 77's logger early-exit eliminates thousands of wasted string.format allocations per session. Doc 82 includes a bug fix (graph tag filters ignore hierarchical tags).

---

## Phase 2: Highlight System Overhaul

*Highest-frequency hot path (fires on every keystroke).*

| Priority | Document | Focus | Complexity | Impact |
|----------|----------|-------|------------|--------|
| 1 | Doc 56 | Viewport-aware rendering, code exclusion caching, per-buffer debounce | Low-High | High |
| 2 | Doc 64 | Footnote parse caching and extmark pcall batching | Low | Medium |
| 3 | Doc 78 | Highlight navigation cache and outline single-pass dedup | Low | Medium |

**Rationale:** The highlight pipeline fires on every keystroke. Doc 56's code exclusion caching eliminates 2 redundant treesitter parses per keystroke. Viewport rendering reduces line processing by ~85% on large files.

---

## Phase 3: Parser and Index Precomputation

*Prepare data at index-build time to eliminate per-query/per-entry work. Foundation for Phase 4.*

| Priority | Document | Focus | Complexity | Impact |
|----------|----------|-------|------------|--------|
| 1 | Doc 58-parser | Single-pass parser precomputation (lowered fields, resolution keys) | Low-Med | High |
| 2 | Doc 67 | Change-aware persistence and batched watcher invalidation | Medium | High |
| 3 | Doc 76 | Merged triple iteration for cold-start index build (remaining items) | High | High |

**Rationale:** Search filter optimizations in Phase 4 rely on pre-computed lowercase fields and resolution keys created during index parsing. Doc 67's change-aware persistence prevents unnecessary JSON serialization.

---

## Phase 4: Search and Filter Optimization

*Builds on Phase 3 parser precomputation and Phase 1 caching.*

| Priority | Document | Focus | Complexity | Impact |
|----------|----------|-------|------------|--------|
| 1 | Doc 55 | FilterContext precomputation (dates, tags, links per query) | Medium | High |
| 2 | Doc 75 | Pre-lowered basename matching and task state lookup table | Low | High |
| 3 | Doc 65 | Search pipeline efficiency (AST caching, tmpfile reuse, section accumulation) | Low-High | Medium-High |
| 4 | Doc 57-search | Optimized ripgrep output and incremental live search filtering | Low-High | Medium-High |

**Rationale:** Doc 55's FilterContext on top of Phase 3's pre-lowered fields produces the best combined improvement. Doc 57-search's incremental live search provides ~4x speedup for restrictive queries.

---

## Phase 5: Graph and Connections

*Depends on Phase 4 memoized resolver and Phase 3 parser precomputation.*

| Priority | Document | Focus | Complexity | Impact |
|----------|----------|-------|------------|--------|
| 1 | Doc 60-graph | IDF caching, top-K heap scoring, batched predicate lookups | Low-Med | High |
| 2 | Doc 58-graph | Render string optimization and connection cache invalidation | Low-Med | Medium |
| 3 | Doc 79 | Pre-lowered sort keys, cached tbl_count, single-pass dedup (remaining items) | Low | Medium |

**Rationale:** Doc 60-graph's top-K heap provides the largest single improvement (9x operation reduction). Graph traversal benefits from memoized path resolution and pre-computed fields from earlier phases.

---

## Phase 6: Completion and UI

*Builds on Phase 1 cached aggregates and Phase 3 parser work.*

| Priority | Document | Focus | Complexity | Impact |
|----------|----------|-------|------------|--------|
| 1 | Doc 57-completion | Debounce alignment, adaptive batch sizing, memoized field accumulation | Low | High |
| 2 | Doc 73 | Cached file name list and pre-lowered heading text for completion | Low | High |
| 3 | Doc 66 | Single-pass field accumulation and tag hierarchy pre-index | Medium | Medium |
| 4 | Doc 74 | Cached buffer fields, unified field-finding pass, interval position tracking | Low-Med | Medium-High |

**Rationale:** Completion sources fire on every keystroke during link/tag insertion. Doc 57-completion's debounce alignment eliminates 90% of wasted work during index builds.

---

## Phase 7: Startup and Initialization

*Most impactful for first-launch experience. Best attempted after core systems are stable.*

| Priority | Document | Focus | Complexity | Impact |
|----------|----------|-------|------------|--------|
| 1 | Doc 61-startup | Remove blocking fallback and deferred directory scan | Low | High |
| 2 | Doc 63 | Watcher filesystem fast-path and display width ASCII fast path | Low | Low-Med |
| 3 | Doc 59-startup | Async index loading, lazy search submodules, phased module loading | Low-High | High |

**Rationale:** Startup optimization is high-impact for first-launch but affects only initial load. Editor responsiveness (Phases 1-6) matters more for sustained usage.

---

## Phase 8: Task, Calendar, and UI Polish

*Lower-frequency user interactions. Nice-to-have optimizations.*

| Priority | Document | Focus | Complexity | Impact |
|----------|----------|-------|------------|--------|
| 1 | Doc 70 | Task kanban/hierarchy/overdue generation caching and spatial index | Low-Med | High |
| 2 | Doc 61-calendar | Task collection caching, preview float reuse, timeline viewport (remaining items) | Low-Med | Medium-High |
| 3 | Doc 71 | Callout fold boundary caching and frontmatter editor merge | Low-Med | Medium-High |
| 4 | Doc 69 | Weekly review navigation cache and block ID from index (remaining items) | Low | Medium |

**Rationale:** These modules are invoked less frequently than highlights or search. Generation-based caching (Doc 70) provides the biggest wins for task UI.

---

## Phase 9: Miscellaneous and Link-Level

| Priority | Document | Focus | Complexity | Impact |
|----------|----------|-------|------------|--------|
| 1 | Doc 72 | Index-based frecency and pre-compiled rename patterns (remaining items) | Low | High |
| 2 | Doc 59-completion | Efficient path proximity scoring and direct link navigation | Low-Med | Medium-High |
| 3 | Doc 68 | Embed inverted dependency index and selective image cache invalidation (remaining items) | Low-Med | Medium-High |

**Rationale:** Doc 72's index-based frecency replaces slow filesystem globpath with fast index iteration (100x improvement). Doc 68's inverted dependency index converts O(B*D) buffer scanning to O(changed_paths).

---

## Phase 10: Deferred High-Effort Optimizations

*High complexity or speculative benefit. Attempt only after profiling confirms need.*

| Priority | Document | Focus | Complexity | Impact |
|----------|----------|-------|------------|--------|
| 1 | Doc 60-index | WAL-based incremental persistence and reduced entry memory footprint | Med-High | Medium |
| 2 | Doc 60-graph | BFS incremental layer caching | High | High |
| 3 | Doc 65 | Parallel ripgrep execution for AND/OR branches | High | High |
| 4 | Doc 57-search | Cached date parsing pre-computed at index time | Low | High |

**Rationale:** WAL persistence, memory footprint reduction, and parallel ripgrep are high-effort with uncertain payoff until profiling confirms bottlenecks in earlier phases.

---

## Document Cross-Reference

| Doc | Covered In | Status |
|-----|------------|--------|
| 55 | Phase 4 | Not implemented |
| 56 | Phase 2 | Not implemented |
| 57-completion | Phase 6 | Partially implemented |
| 57-search | Phase 4, 10 | Not implemented |
| 58-parser | Phase 3 | Not implemented |
| 58-graph | Phase 5 | Not implemented |
| 59-startup | Phase 7 | Not implemented |
| 59-completion | Phase 9 | Not implemented |
| 60-graph | Phase 5, 10 | Not implemented |
| 60-index | Phase 10 | Not implemented |
| 61-startup | Phase 7 | Not implemented |
| 61-calendar | Phase 8 | Partially implemented |
| 63 | Phase 7 | Not implemented |
| 64 | Phase 2 | Not implemented |
| 65 | Phase 4, 10 | Not implemented |
| 66 | Phase 6 | Not implemented |
| 67 | Phase 3 | Not implemented |
| 68 | Phase 9 | Partially implemented |
| 69 | Phase 8 | Partially implemented |
| 70 | Phase 8 | Not implemented |
| 71 | Phase 8 | Not implemented |
| 72 | Phase 9 | Partially implemented |
| 73 | Phase 6 | Not implemented |
| 74 | Phase 6 | Not implemented |
| 75 | Phase 4 | Fully implemented |
| 76 | Phase 1, 3 | Partially implemented |
| 77 | Phase 1 | Not implemented |
| 78 | Phase 2 | Not implemented |
| 79 | Phase 5 | Partially implemented |
| 80 | N/A | Status tracker (not an implementation target) |
| 81 | Phase 1 | Not implemented |
| 82 | Phase 1 | Not implemented |
