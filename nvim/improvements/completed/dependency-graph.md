# Improvement Dependency Graph (09-13)

## Overview

This document maps the dependencies, shared infrastructure, and recommended
implementation order for five proposed vault improvements:

| ID | Title                       | Scope                                          |
|----|-----------------------------|-------------------------------------------------|
| 09 | Graph Filtering             | Filter/depth UI for the local graph view        |
| 10 | Highlight Syntax            | `==text==` rendering + vault navigation module  |
| 11 | Footnote Snippets           | LuaSnip snippets + auto-numbering for footnotes |
| 12 | Unified Cache Invalidation  | Cache registry + centralized invalidation bus    |
| 13 | Incremental Indexing        | Persistent vault index replacing per-module caches |

---

## ASCII Dependency Diagram

Arrows point from **dependency** to **dependent** (must-come-before direction).
Dashed lines indicate "benefits from" (soft dependency, not a hard blocker).

```
                    +---------+
                    |   12    |
                    | Unified |
                    | Cache   |
                    | Inval.  |
                    +----+----+
                         |
              hard dep   |
                         v
                    +---------+
                    |   13    |
                    | Increm. |
                    | Indexing|
                    +----+----+
                         |
              soft dep   |  (graph filtering benefits from
                         |   fast index for multi-hop)
                         |
                    +----v----+
                    |   09    |
                    | Graph   |
                    |Filtering|
                    +---------+


    +---------+          +---------+
    |   10    |          |   11    |
    |Highlight|          |Footnote |
    | Syntax  |          |Snippets |
    +---------+          +---------+
     (independent)        (independent)
```

Expanded view with soft/hard relationships:

```
    12 ────hard────> 13 ···soft···> 09
    (cache registry    (persistent     (multi-hop graph uses
     + event bus)       index)          query index; benefits
                                        from unified cache)

    12 ···soft···> 09
    (graph_filter has its own _file_tag_cache;
     would be cleaner with registry)

    13 ···soft···> 09
    (depth>1 collection relies on query/index.lua;
     index-backed inlinks would be instant)

    10  (fully independent -- no cache, no index, no shared state)
    11  (fully independent -- edits footnotes.lua + luasnippets only)
```

---

## Dependency Matrix

Rows depend on columns. `H` = hard dependency, `S` = soft/benefits-from, `.` = none.

```
          |  09   10   11   12   13
    ------+---------------------------
      09  |   .    .    .    S    S
      10  |   .    .    .    .    .
      11  |   .    .    .    .    .
      12  |   .    .    .    .    .
      13  |   .    .    .    H    .
```

Reading: Row 09 has soft dependencies on 12 and 13. Row 13 has a hard dependency on 12.

---

## Detailed Dependency Analysis

### 12 -> 13 (Hard Dependency)

**Unified Cache Invalidation must be implemented before Incremental Indexing.**

Rationale:
- Improvement 13 replaces per-module caches with a single vault index. It needs
  a clean invalidation bus to notify downstream consumers when the index updates.
- Document 13 explicitly plans to use `engine.invalidate_all_caches()` and the
  filesystem watcher integration. Document 12 rewrites that function into a
  proper registry with `invalidate_caches({ scope, path })` and the
  `VaultCacheInvalidate` User autocmd event.
- Without 12, improvement 13 would need to re-implement the event notification
  system that 12 already provides, or leave the old brittle hard-coded
  enumeration in place.
- Document 13's migration Phase 2 says "Update `engine.invalidate_all_caches()`
  to trigger an incremental index update instead of blanket invalidation" -- this
  assumes the registry from 12 already exists.

Shared modules touched by both:
- `engine.lua` -- 12 adds `_cache_registry`, `register_cache()`,
  `invalidate_caches()`; 13 replaces `get_name_cache()`, `list_md_files_async()`,
  updates `invalidate_all_caches()`, modifies `start_fs_watcher()`.
- `init.lua` -- 12 consolidates autocmds; 13 adds index lifecycle.
- `wikilinks.lua` -- 12 adds `register_cache()`; 13 replaces `build_cache()`.
- `tags.lua` -- 12 adds `register_cache()`; 13 replaces `collect_tags()`.
- `connections.lua` -- 12 adds `register_cache()`; 13 replaces `get_index()`.
- `completion_base.lua` -- 12 adds `register_cache()`; 13 replaces `build()`.
- `linkdiag.lua` -- 12 adds `register_cache()`; 13 replaces heading cache.
- `autolink.lua` -- 12 adds `register_cache()`; 13 replaces name index.
- `query/init.lua` -- 12 adds `register_cache()`; 13 backs it with vault index.
- `config.lua` -- both add new configuration sections.

If implemented out of order (13 before 12): Each module would still have its own
BufWritePost autocmd (6 separate callbacks), the hard-coded cache enumeration in
`engine.invalidate_all_caches()` would need manual extension for the new vault
index, and there would be no `VaultCacheInvalidate` event for downstream modules
to subscribe to. The work would need to be redone when 12 is later implemented.

### 12 -> 09 (Soft Dependency)

**Graph Filtering benefits from Unified Cache Invalidation but does not require it.**

Rationale:
- `graph_filter.lua` introduces its own `_file_tag_cache` with a 30-second TTL
  for caching per-file tag data. Under 12's registry, this cache would
  self-register and be invalidated centrally instead of relying on its own TTL.
- The graph filter UI triggers a re-render cycle. With 12's
  `VaultCacheInvalidate` event, the graph could auto-refresh when underlying data
  changes (e.g., a tag is added to a note in another buffer).
- Without 12: graph filtering works fine, just with a standalone cache that may
  occasionally serve stale tag data for up to 30 seconds.

### 13 -> 09 (Soft Dependency)

**Graph Filtering benefits from Incremental Indexing for multi-hop performance.**

Rationale:
- Document 09's depth>1 collection (`collect_at_depth`) uses
  `query/index.lua`'s pre-computed outlinks and inlinks. Currently this requires
  `Index.new(vault_path):build_sync()` which performs a full vault walk.
- With 13's persistent index, the query index is backed by always-fresh in-memory
  data. Multi-hop graph collection becomes instant (no filesystem walk) and
  can reliably use the BFS algorithm without performance concerns.
- Without 13: depth>1 graph filtering works but triggers a synchronous index
  build (potentially 500ms+ on large vaults). The document already notes this as
  a performance concern and suggests "reuse cached index from connections.lua
  when available."

### 10 (Fully Independent)

**Highlight Syntax has zero dependencies on any other improvement.**

Rationale:
- Tier 1 (config-only changes) touches `colorscheme.lua` and
  `render-markdown.lua` -- plugin config files that no other improvement touches.
- Tier 2 (vault module) creates `highlights.lua` following the established
  pattern of `tag_highlights.lua`. It uses only `engine.is_vault_path()` and
  treesitter queries -- infrastructure that already exists and is not modified by
  any other improvement.
- No caching, no indexing, no shared state with any other proposed improvement.
- Does not touch `engine.lua`, `init.lua`, `wikilinks.lua`, `config.lua`, or
  any other file that 12 or 13 modify (except a trivial addition of a
  `highlight_marks` section to `config.lua` and a `require` line in `init.lua`).

### 11 (Fully Independent)

**Footnote Snippets has zero dependencies on any other improvement.**

Rationale:
- Edits only `footnotes.lua` (adding `M.next_id()`) and
  `luasnippets/markdown.lua` (adding snippet definitions).
- Neither file is touched by any other improvement.
- No caching, no indexing, no UI changes, no config changes.
- The `next_id()` function only reads buffer lines -- completely self-contained.

---

## Shared Module / File Overlap

Files touched by multiple improvements and the nature of each change:

| File | 09 | 10 | 11 | 12 | 13 |
|------|:--:|:--:|:--:|:--:|:--:|
| `engine.lua` | -- | -- | -- | Major rewrite (registry, invalidation API) | Major rewrite (index lifecycle, replace name cache) |
| `init.lua` | -- | `require` line | `--` | Consolidate autocmds, add commands | Index init, commands |
| `config.lua` | Add `graph` section | Add `highlight_marks` | -- | -- | Add `index` section |
| `graph.lua` | Major rewrite (filter integration) | -- | -- | -- | Optionally use index inlinks |
| `wikilinks.lua` | -- | -- | -- | Add `register_cache()` | Replace `build_cache()` |
| `tags.lua` | Used read-only by graph_filter | -- | -- | Add `register_cache()` | Replace `collect_tags()` |
| `connections.lua` | -- | -- | -- | Add `register_cache()` | Replace `get_index()` |
| `linkdiag.lua` | -- | -- | -- | Add `register_cache()` | Replace heading cache |
| `completion_base.lua` | -- | -- | -- | Add `register_cache()` | Replace `build()` |
| `autolink.lua` | -- | -- | -- | Add `register_cache()` | Replace name index |
| `query/init.lua` | Used by depth>1 collection | -- | -- | Add `register_cache()` | Back with vault index |
| `frontmatter_parser.lua` | Used read-only by predicates | -- | -- | -- | Parsing consolidated into vault_index |
| `footnotes.lua` | -- | -- | Add `next_id()` | -- | -- |
| `luasnippets/markdown.lua` | -- | -- | Add snippets | -- | -- |
| `colorscheme.lua` | -- | Add hl group | -- | -- | -- |
| `render-markdown.lua` | -- | Add inline_highlight config | -- | -- | -- |
| `ui.lua` | Used (not modified) | -- | -- | -- | -- |

**Conflict hotspots:**
- `engine.lua`: Both 12 and 13 make major changes. 12 must land first so 13 can
  build on the registry.
- `init.lua`: 12 and 13 both modify autocmd setup. Implementing 12 first gives
  13 a clean base.
- 7 vault modules (wikilinks, tags, connections, linkdiag, completion_base,
  autolink, query/init): 12 adds `register_cache()` to each; 13 later replaces
  internals. No conflict if done in order.

---

## Effort and Risk Assessment

| ID | Title | Effort | Risk | Rationale |
|----|-------|:------:|:----:|-----------|
| 09 | Graph Filtering | **L** | Medium | New module (`graph_filter.lua`), multi-hop BFS algorithm, filter UI with sub-pickers, preset persistence. Touches graph rendering pipeline. Risk: performance at depth>2 on large vaults; UI complexity. |
| 10 | Highlight Syntax (Tier 1) | **S** | Low | Two config file edits, zero new modules. Cannot break anything -- additive highlight group definition and plugin config. |
| 10 | Highlight Syntax (Tier 2) | **M** | Low | New module following established pattern (`tag_highlights.lua`). Well-understood architecture. Risk: priority conflicts with render-markdown extmarks (mitigated by design). |
| 11 | Footnote Snippets | **S** | Low | ~12 lines in `footnotes.lua`, ~55 lines in `luasnippets/markdown.lua`. Purely additive. Risk: trigger conflicts with existing snippets (mitigated: `fn*` prefix is unused). |
| 12 | Unified Cache Invalidation | **M** | Medium | Refactors 11 modules. Core change is small (registry API in engine.lua), but migration touches many files. Risk: double-invalidation bugs during migration; subtle ordering issues in autocmd removal. |
| 13 | Incremental Indexing | **L** | High | New core module (`vault_index.lua`), replaces internals of 12+ modules, persistence layer, background processing, change detection. Risk: data correctness (stale/missing index entries), performance regression during migration, subtle parsing differences vs. per-module parsers. |

Effort key: **S** = Small (< 1 hour), **M** = Medium (2-4 hours), **L** = Large (1-2 days)

---

## Recommended Implementation Order

### Phase 1: Quick Wins (Parallel)

**Implement 10 (Tier 1) and 11 simultaneously.**

These are fully independent of each other and of all other improvements. They
require no architectural changes, touch no shared infrastructure, and deliver
immediate user-facing value.

| Task | Files Changed | Time |
|------|---------------|------|
| 10 Tier 1: Highlight color + config | `colorscheme.lua`, `render-markdown.lua` | 15 min |
| 11: Footnote snippets | `footnotes.lua`, `luasnippets/markdown.lua` | 30 min |

**Deliverables:**
- Yellow highlighter-pen rendering for `==text==`
- Custom prefix highlights (`==!important==`, `==?question==`)
- 7 footnote snippets with auto-numbering

### Phase 2: Highlight Navigation (Optional, Parallel with Phase 3)

**Implement 10 (Tier 2).**

Can run in parallel with Phase 3 since it touches completely different files.
Adds `]h`/`[h` motions, toggle command, and vault-aware extmarks for highlights.

| Task | Files Changed | Time |
|------|---------------|------|
| 10 Tier 2: Vault highlight module | New: `highlights.lua`; Edit: `config.lua`, `init.lua` | 1-2 hrs |

### Phase 3: Cache Infrastructure

**Implement 12 (Unified Cache Invalidation).**

This is the foundation for Phase 4. It rationalizes the cache landscape, removes
6 redundant BufWritePost autocmds, and introduces the registry + event bus that
improvement 13 builds on.

| Task | Files Changed | Time |
|------|---------------|------|
| 12: Cache registry API in engine.lua | `engine.lua` | 30 min |
| 12: Migrate 11 modules to register_cache() | `wikilinks.lua`, `tags.lua`, `linkdiag.lua`, `connections.lua`, `completion_base.lua`, `calendar.lua`, `callout_folds.lua`, `autolink.lua`, `query/init.lua`, `frecency.lua` | 2 hrs |
| 12: Consolidate autocmds in init.lua | `init.lua` | 30 min |
| 12: Add VaultCacheStatus/Invalidate commands | `init.lua` | 30 min |
| 12: Add VaultCacheInvalidate subscribers | `wikilink_highlights.lua`, `linkdiag.lua`, `autolink.lua` | 30 min |

**Deliverables:**
- Self-registering cache system
- Single BufWritePost handler (replaces 6)
- `:VaultCacheStatus` diagnostic command
- `:VaultCacheInvalidate [module]` manual control
- `VaultCacheInvalidate` User autocmd event for downstream listeners

### Phase 4: Persistent Index

**Implement 13 (Incremental Indexing).**

Builds on Phase 3's registry. This is the highest-effort, highest-risk
improvement. Recommend implementing in the sub-phases described in document 13:

| Sub-phase | Description | Time |
|-----------|-------------|------|
| 13.1: Core vault_index.lua | New module with persistence, change detection, single-pass parser, background build | 4-6 hrs |
| 13.2: Engine integration | Replace `get_name_cache()`, update fs_watcher | 1-2 hrs |
| 13.3: Wikilinks integration | Replace `build_cache()` with index-backed resolution | 1-2 hrs |
| 13.4: Query index integration | Back `query/index.lua` with vault index | 2-3 hrs |
| 13.5: Remaining modules | tags, completion, linkdiag, autolink, linkcheck | 2-3 hrs |
| 13.6: Cleanup | Remove dead code, deprecated TTLs | 1 hr |

**Deliverables:**
- Persistent JSON index surviving across sessions
- Sub-second warm starts (vs. multi-hundred-ms cold scans)
- Single-pass file parsing (eliminates redundant reads)
- Real-time incremental updates on file save

### Phase 5: Graph Filtering

**Implement 09 (Graph Filtering).**

With the unified cache and persistent index in place, graph filtering can leverage
instant index lookups for multi-hop collection and benefit from the event bus for
cache coherence.

| Task | Description | Time |
|------|-------------|------|
| 09.1: graph_filter.lua | Predicate system, filter state, status formatting | 2-3 hrs |
| 09.2: graph.lua integration | Filter layer, keybindings, re-render cycle | 2-3 hrs |
| 09.3: Filter UI | Configuration popup, sub-pickers | 2-3 hrs |
| 09.4: Multi-hop collection | BFS with index-backed inlinks | 1-2 hrs |
| 09.5: Preset persistence | JSON store for saved filter configs | 30 min |

**Deliverables:**
- Tag, type, date, path, and toggle filters for graph view
- Multi-hop graph expansion (depth 1-5)
- Filter presets (save/load/delete)
- Interactive filter UI with status bar

---

## Parallelization Summary

```
Timeline:  ──────────────────────────────────────────────────>

Phase 1:   [10-T1]  [11]        (parallel, ~30 min each)
              |       |
Phase 2:   [10-T2]  |           (can overlap with Phase 3)
              |      |
Phase 3:      |   [===== 12 =====]
              |          |
Phase 4:      |       [========= 13 =========]
                                    |
Phase 5:                         [========= 09 =========]
```

Phases that CAN run in parallel:
- **10 Tier 1 and 11**: Fully independent. Zero file overlap.
- **10 Tier 2 and 12**: Fully independent. 10 touches `highlights.lua` (new),
  `config.lua` (different section), and `init.lua` (one require line). 12 touches
  `engine.lua` and migrates cache modules. No conflict. Can be developed on
  separate branches and merged independently.
- **10 Tier 2 and 13**: Same reasoning as above.

Phases that CANNOT be parallelized:
- **12 and 13**: 13 depends on 12's registry. Both make major changes to
  `engine.lua` and `init.lua`. Must be sequential.
- **13 and 09**: 09 can be implemented without 13 (it already works with the
  existing query index), but multi-hop performance improves significantly with 13.
  Recommend sequential for cleanest result; parallel is possible with performance
  caveats.

---

## Critical Path Analysis

The **critical path** is the longest chain of dependent work that determines the
minimum total implementation time:

```
12 (Unified Cache Invalidation)  ──>  13 (Incremental Indexing)  ──>  09 (Graph Filtering)
        ~4 hours                           ~12 hours                      ~10 hours
```

**Total critical path length: ~26 hours of focused work.**

This chain exists because:
1. **13 hard-depends on 12**: The persistent index needs the cache registry and
   event bus to notify downstream modules.
2. **09 soft-depends on 13**: Multi-hop graph collection is practical only with
   an index-backed query system.

**Improvements NOT on the critical path:**
- **10 (Highlight Syntax)**: Fully independent. Total: ~2.5 hours (both tiers).
  Can be completed at any time.
- **11 (Footnote Snippets)**: Fully independent. Total: ~30 minutes. Can be
  completed at any time.

**Optimal total project time** (with maximum parallelization):
- Start 10-T1 + 11 immediately (Phase 1): 30 min
- Start 10-T2 and 12 in parallel (Phases 2+3): 4 hours (12 is the bottleneck)
- Start 13 after 12 completes (Phase 4): 12 hours
- Start 09 after 13 completes (Phase 5): 10 hours
- **Total wall-clock: ~26.5 hours** (10+11 hide behind the critical path)

---

## Risk Mitigation Notes

### 12 (Unified Cache Invalidation) -- Medium Risk
- **Risk**: Removing per-module BufWritePost autocmds could break invalidation if
  a module forgets to call `register_cache()`.
- **Mitigation**: Keep `invalidate_all_caches()` as a backward-compatible wrapper.
  Add `:VaultCacheStatus` early so missing registrations are immediately visible.
  Migrate one module at a time, testing after each.

### 13 (Incremental Indexing) -- High Risk
- **Risk**: Parser differences between the new single-pass parser and per-module
  parsers could cause subtle data correctness issues (e.g., a tag not extracted,
  a heading slug computed differently).
- **Mitigation**: Run the old and new systems side by side during Phase 13.1.
  Build comparison tooling (`:VaultIndexDiff`) that checks the new index against
  the old cache outputs. Only switch downstream modules once parity is confirmed.

### 09 (Graph Filtering) -- Medium Risk
- **Risk**: Multi-hop BFS at depth>2 could cause performance problems or UI
  hangs on large vaults.
- **Mitigation**: Hard cap at `max_nodes = 50` with a configurable ceiling.
  Implement async collection with progress indicator for depth>1. Start with
  depth 1 filtering (no BFS needed) as an intermediate deliverable.

### 10 and 11 -- Low Risk
- Both are additive, isolated changes with no architectural impact. Standard
  testing (manual verification in a vault buffer) is sufficient.
