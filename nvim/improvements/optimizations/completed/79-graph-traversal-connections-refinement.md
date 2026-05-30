# 79 --- Graph Traversal & Connections Refinement

This document is a self-contained implementation guide. Each optimization
below is unique to this document.

Targeted improvements for graph traversal sorting, connections scoring
overhead, multi-pass deduplication in graph collection, and subgraph
memoization in search-graph integration.

> **Modules affected:** `graph_filter/traversal.lua`, `connections.lua`,
> `graph/collect.lua`, `search_filter/graph_traversal.lua`

---

## 1. Pre-Lowered Sort Keys in Graph Traversal — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/graph_filter/traversal.lua` (lines 121-122)

After BFS collection, results are sorted with a comparator that calls
`:lower()` on every comparison.

**Same pattern in `graph/collect.lua` (line 10).**

### Resolution

All sort functions now use pre-computed `_sort_key` fields (Schwartzian
transform): pre-compute `item._sort_key = item.name:lower()`, sort by
`_sort_key`, then strip the temporary field.

Applied in:
- `graph_filter/traversal.lua` — `sort_nodes()` function
- `graph/collect.lua` — `sort_by_name()` function
- `sidebar_backlinks.lua` — inline sort in `collect_backlinks()`
- `user_templates.lua` — inline sort in template loading

~15x reduction in string allocations during sort (200 nodes).

---

## 2. Cached vim.tbl_count in Connections Scoring — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/connections.lua`

`score_colinks()` originally called `vim.tbl_count()` twice per candidate.

### Resolution

`build_note_data()` now pre-computes `outlink_count` and `inlink_count`
as running tallies during iteration. `score_colinks()` accepts these
pre-computed counts as parameters, eliminating all `vim.tbl_count()` calls
in the scoring hot path. Only one diagnostic `vim.tbl_count` remains
(cache stats reporting).

---

## 3. Pre-Built Tag Sets in Connections — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/connections.lua` (lines 264-266)

`build_note_data()` rebuilds a tag set from the tag array for every
candidate. For 1000 candidates with 5 tags each: 5000 table insertions.

### Resolution

Tag sets are now pre-built at index time and cached in entries.
`build_note_data()` reuses `entry.tag_set` directly (O(1)).

---

## 4. Single-Pass Deduplication in Graph Collect — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/graph/collect.lua`

Graph collection had a separate pass to build `resolved_names` set
after collection, then a filter pass to drop unresolved duplicates.

### Resolution

`resolved_names` set is now built during the collection loop itself
(when a link resolves, its lowercase name is added to the set
immediately). This eliminates one full iteration over the links array.
The filter pass remains (unavoidable — needs the complete set before
filtering).

---

## 5. Memoized Subgraph Reach Sets — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/search_filter/graph_traversal.lua`
(lines 116-150)

`precompute_graph_sets()` walks the AST to find all `graph:` nodes and
computes a BFS reachable set for each. If the AST contains multiple
`graph:` nodes with identical parameters, the BFS would run multiple
times for the same reach set.

### Resolution

`precompute_graph_sets()` now memoizes by graph ID: if `graph_sets[graph_id]`
already exists, the BFS is skipped for that node. Duplicate graph
constraints in a query share a single BFS result.

---

## 6. BFS Visited-Table Dedup — IMPLEMENTED

This was previously listed as part of the graph traversal improvements.

### Resolution

BFS in `graph_filter/traversal.lua` now uses a visited table to prevent
re-enqueuing already-seen nodes, eliminating redundant expansion.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Status |
|----------|-------------|--------|--------|--------|
| 1 | Pre-lowered sort keys (#1) | Low | Medium | IMPLEMENTED |
| 2 | Cached tbl_count (#2) | Low | Medium | IMPLEMENTED |
| 3 | Single-pass dedup (#4) | Low | Low | IMPLEMENTED |
| 4 | Pre-built tag sets (#3) | Low | Medium | IMPLEMENTED |
| 5 | Subgraph memoization (#5) | Low | Low | IMPLEMENTED |
| 6 | BFS visited-table dedup (#6) | Low | Low | IMPLEMENTED |

---

## Testing Strategy

### Pre-Lowered Sort Keys (#1)
1. Open graph with 50 nodes. Verify alphabetical ordering.
2. Test with mixed-case names (e.g., "Alpha", "beta", "GAMMA").
   Verify case-insensitive sort order is preserved.

### Cached tbl_count (#2)
1. Run `:VaultConnections`. Verify results match before/after.
2. Test with a note that has 0 outlinks. Verify no division errors.

### Single-Pass Dedup (#4)
1. Open graph for a note with duplicate link targets. Verify
   disambiguation shows folder-qualified names.
2. Test with notes that have identical basenames in different folders.

---

## Related Documents

- Doc 58-graph-connections-scoring covers BFS queue optimization and graph render caching.
- Doc 60-graph-connections-performance covers BFS layer caching and top-K heap.
