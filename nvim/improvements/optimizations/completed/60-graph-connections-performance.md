# 60 --- Graph & Connections Performance

This document is a self-contained implementation guide. Each optimization
below is unique to this document.

Four targeted optimizations for the connection scoring and graph traversal
systems, addressing quadratic scoring overhead, redundant IDF computation,
full BFS rebuilds on depth change, and batched predicate index lookups.

> **Modules affected:** `connections.lua`, `graph_filter/traversal.lua`,
> `graph_filter.lua`, `filter_utils.lua`

---

## 1. Connection Scoring Top-K Heap — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/connections.lua` (lines 360-483)

`M.compute()` scores **every page** in the vault against a source note.
For each candidate, it computes 5 signal scores (tags, links, frontmatter,
shared neighbors, text similarity). This is O(N) per source note, but the
constant factor is high: each candidate requires IDF lookups, neighbor set
comparisons, and frontmatter intersection.

```lua
-- connections.lua:360-483 (simplified)
local all_pages = index:all_pages()
local idf, total_pages = build_tag_idf(all_pages)  -- O(N * T)

for _, page in ipairs(all_pages) do                 -- O(N)
    if page.file.path == source_rel_path then goto continue end
    local candidate = build_note_data(page)         -- table alloc per candidate
    local total_score = 0

    -- 5 scoring functions called per candidate
    local tag_score = score_tags(...)               -- O(T) per candidate
    local link_score = score_link_proximity(...)    -- O(neighbors) per candidate
    local fm_score = score_frontmatter(...)         -- O(F) per candidate
    -- ...

    results[#results + 1] = { ... }                 -- table alloc per candidate
    ::continue::
end

table.sort(results, ...)  -- O(N log N)
-- Return top 20
```

With a 2000-file vault, each `compute()` call:
- Allocates 2000 `build_note_data()` tables
- Allocates 2000 result entry tables
- Sorts all 2000 results
- Returns only the top 20

**Complexity:** O(N * (T + neighbors + F)) + O(N log N) sort

### Proposed Solution

Use a min-heap (priority queue) of size K (default 20) to track the top-K
candidates. This eliminates the full sort and allows early pruning: once
the heap is full, candidates with scores below the heap minimum can be
skipped after the cheapest signal (tag overlap check).

### Code Changes

**Simple top-K tracker (no external dependency):**

```lua
--- Maintain a fixed-size min-heap of top-K scored items.
local function create_top_k(k)
    local heap = {}
    local size = 0

    return {
        --- Try to insert a scored item. Returns true if inserted.
        insert = function(score, item)
            if size < k then
                size = size + 1
                heap[size] = { score = score, item = item }
                -- Bubble up (min-heap by score)
                local i = size
                while i > 1 do
                    local parent = math.floor(i / 2)
                    if heap[i].score < heap[parent].score then
                        heap[i], heap[parent] = heap[parent], heap[i]
                        i = parent
                    else break end
                end
                return true
            elseif score > heap[1].score then
                -- Replace minimum
                heap[1] = { score = score, item = item }
                -- Sift down
                local i = 1
                while true do
                    local smallest = i
                    local l, r = 2*i, 2*i+1
                    if l <= size and heap[l].score < heap[smallest].score then smallest = l end
                    if r <= size and heap[r].score < heap[smallest].score then smallest = r end
                    if smallest == i then break end
                    heap[i], heap[smallest] = heap[smallest], heap[i]
                    i = smallest
                end
                return true
            end
            return false
        end,

        --- Get minimum score in heap (threshold for pruning).
        min_score = function()
            return size >= k and heap[1].score or 0
        end,

        --- Extract sorted results (descending by score).
        results = function()
            table.sort(heap, function(a, b) return a.score > b.score end)
            local out = {}
            for i = 1, size do out[i] = heap[i].item end
            return out
        end,
    }
end
```

**Modified scoring loop with early pruning:**

```lua
local top = create_top_k(max_results or 20)

for _, page in ipairs(all_pages) do
    if page.file.path == source_rel_path then goto continue end

    -- Cheap signal first: tag overlap (fast, O(min(T1, T2)))
    local candidate_tags = page.file.tags or {}
    local tag_score = score_tags(source_data.tags, candidate_tags, idf, total_pages)

    -- Early pruning: if tag_score alone can't beat the current minimum,
    -- and we already have K results, skip expensive signals
    local max_possible = tag_score + weights.link_max + weights.fm_max + weights.neighbor_max + weights.text_max
    if top.min_score() > 0 and max_possible < top.min_score() then
        goto continue
    end

    -- Compute remaining signals (only if candidate has a chance)
    local candidate = build_note_data(page)
    local link_score = score_link_proximity(...)
    local fm_score = score_frontmatter(...)
    -- ...
    local total_score = tag_score + link_score + fm_score + ...

    if total_score > 0 then
        top.insert(total_score, {
            page = page,
            score = total_score,
            reasons = reasons,
            breakdown = breakdown,
        })
    end

    ::continue::
end

return top.results()
```

### Expected Performance Improvement

For a 2000-file vault returning top 20 connections:

- **Before:** 2000 full scoring operations + O(2000 log 2000) sort = ~22,000 ops
- **After:** 2000 tag checks + ~200 full scoring operations (after pruning) +
  O(20) heap operations = ~2400 ops (~9x reduction)

The pruning is most effective when the source note has distinctive tags, which
is the common case. For notes with no tags, all candidates pass the first
filter and the improvement is smaller (~2x from eliminating the sort).

### Risk Assessment

- **Correctness:** The top-K heap is an exact algorithm (not approximate).
  All candidates are considered; only expensive signals are skipped for
  candidates that can't possibly reach the top K.
- **Weight constants:** The early pruning requires knowing the maximum possible
  score for each signal (`weights.*_max`). These can be derived from the weight
  configuration. If weights change, the max values must update.
- **Result stability:** The heap-based approach may return results in a different
  order for equal-scoring items. This is acceptable since connections are
  displayed sorted by score.

---

## 2. Generation-Cached IDF Table — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/connections.lua` (lines 56-70, 361)

`build_tag_idf()` iterates all pages and all their tags to compute document
frequency counts. It is called at the top of `compute()` -- which runs on
every `compute()` invocation, even though IDF only changes when the vault
index changes.

```lua
-- connections.lua:56-70
local function build_tag_idf(pages)
    local doc_count = {}
    local total = 0
    for _, page in ipairs(pages) do
        total = total + 1
        local seen = {}
        for _, tag in ipairs(page.file.tags) do  -- O(T) per page
            if not seen[tag] then
                seen[tag] = true
                doc_count[tag] = (doc_count[tag] or 0) + 1
            end
        end
    end
    return doc_count, total
end
```

**Complexity:** O(N * T) per `compute()` call where N = pages, T = avg tags

### Proposed Solution

Cache the IDF table at module level with vault index generation tracking.

### Code Changes

```lua
-- Module-level IDF cache
local _idf_cache = nil       -- { doc_count, total }
local _idf_cache_gen = -1    -- vault index generation when IDF was built

local function get_tag_idf(all_pages, index_gen)
    if _idf_cache and _idf_cache_gen == index_gen then
        return _idf_cache.doc_count, _idf_cache.total
    end

    local doc_count, total = build_tag_idf(all_pages)
    _idf_cache = { doc_count = doc_count, total = total }
    _idf_cache_gen = index_gen
    return doc_count, total
end

-- In compute():
local idf, total_pages = get_tag_idf(all_pages, index._generation)
```

### Expected Performance Improvement

- **Before:** O(N * T) on every `compute()` call
- **After:** O(N * T) once per index generation, O(1) on cache hit

For repeated `compute()` calls within the same generation (e.g., user viewing
connections for multiple notes): eliminates redundant IDF computation entirely.

### Risk Assessment

- **Staleness:** Generation tracking ensures IDF is recomputed when the index
  changes (new files, modified tags). No stale data possible.
- **Memory:** One doc_count table (key: tag string, value: number). For 500
  unique tags: ~20KB. Negligible.

---

## 3. Incremental BFS Layer Caching — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/graph_filter/traversal.lua` (lines 19-125)

`collect_at_depth()` runs a full BFS from the center node every time the graph
is displayed. When users interactively increase depth (pressing `+` to go from
depth 1 -> 2 -> 3), each depth change triggers a complete BFS re-traversal from
scratch.

**User interaction pattern:**
1. Open graph at depth=1: BFS visits ~10 nodes
2. Press `+` for depth=2: BFS revisits those 10 nodes + ~30 new ones
3. Press `+` for depth=3: BFS revisits all 40 nodes + ~60 new ones

The depth=1 and depth=2 results are discarded and recomputed.

**Complexity:** O(E_d) per depth change, where E_d = edges reachable at depth D.
Total work for depth 1->2->3: O(E_1 + E_2 + E_3) instead of O(E_3).

### Proposed Solution

Cache BFS results per (center, direction, depth) tuple. When depth increases,
reuse the previous depth's frontier as the starting point.

### Code Changes

```lua
-- Module-level BFS cache
local _bfs_cache = {}  -- key: "center_rel|direction" -> { depth_results, frontier }

local function cache_key(center_rel, direction)
    return center_rel .. "|" .. (direction or "both")
end

--- Collect nodes at depth, reusing previous depth's results when possible.
function M.collect_at_depth(idx, center_rel, depth, direction, max_nodes, predicate)
    local key = cache_key(center_rel, direction)
    local cached = _bfs_cache[key]

    -- Check if we can extend from cached result
    if cached and cached.gen == idx._generation and cached.depth < depth then
        -- Extend: BFS from cached frontier only
        local nodes = vim.deepcopy(cached.nodes)
        local visited = {}
        for _, n in ipairs(nodes) do visited[n.rel] = true end

        local frontier = cached.frontier
        for d = cached.depth + 1, depth do
            local new_frontier = {}
            for _, node in ipairs(frontier) do
                -- Expand node's neighbors
                local entry = idx.files[node.rel]
                if not entry then goto skip end
                for _, link in ipairs(entry.outlinks) do
                    local target = resolve(idx, link)
                    if target and not visited[target] and #nodes < max_nodes then
                        if not predicate or predicate(target) then
                            visited[target] = true
                            local new_node = { rel = target, d = d }
                            nodes[#nodes + 1] = new_node
                            new_frontier[#new_frontier + 1] = new_node
                        end
                    end
                end
                -- ... inlinks too, if direction allows ...
                ::skip::
            end
            frontier = new_frontier
        end

        _bfs_cache[key] = { gen = idx._generation, depth = depth, nodes = nodes, frontier = frontier }
        return nodes
    end

    -- Full BFS (cache miss or depth decreased)
    local nodes, frontier = full_bfs(idx, center_rel, depth, direction, max_nodes, predicate)
    _bfs_cache[key] = { gen = idx._generation, depth = depth, nodes = nodes, frontier = frontier }
    return nodes
end

--- Invalidate cache (called on center change or filter change).
function M.invalidate_bfs_cache()
    _bfs_cache = {}
end
```

### Expected Performance Improvement

For interactive depth exploration (depth 1->2->3) on a well-connected vault:

- **Before:** 3 full BFS traversals = O(E_1 + E_2 + E_3) ~ O(3 * E_3)
- **After:** 1 full BFS (depth=1) + 2 frontier-only expansions = O(E_1 + (E_2 - E_1) + (E_3 - E_2)) = O(E_3)

~3x reduction in total BFS work for the common 3-level exploration.

### Risk Assessment

- **Generation tracking:** Cache invalidates when vault index changes. No stale
  graph data.
- **Filter changes:** Predicate changes must also invalidate the cache. Call
  `invalidate_bfs_cache()` when graph filters are toggled.
- **Center changes:** Different center nodes have different BFS results. The
  cache key includes center_rel, so switching center automatically misses cache.
- **Depth decrease:** Going from depth=3 to depth=2 can't reuse the depth=3
  cache (we'd need to remove nodes). Fall back to full BFS. Depth decrease is
  rare in practice.
- **Memory:** One cached BFS result per (center, direction) pair. Typical:
  1-2 entries, ~50KB each. Negligible.

---

## 4. Batched Predicate Index Lookups — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/graph_filter.lua` (lines 168-200)

`M.build_predicate()` returns a function that checks multiple conditions
sequentially. Each predicate independently looks up the entry in the vault
index via `filter_utils`:

```lua
-- graph_filter.lua:168-200
return function(path)
    for _, pred in ipairs(predicates) do
        if not pred(path) then return false end  -- each pred does index lookup
    end
    return true
end
```

Each predicate calls `filter_utils.get_tags(path)`, `filter_utils.get_timestamp(path, field)`,
etc. -- each of which resolves `path` to an index entry independently.

For 3 active filters on a 100-node graph: 300 index lookups instead of 100.

### Proposed Solution

Change predicates to accept `(entry, idx)` instead of `(path)`.
Look up the entry once and pass it through all predicates.

### Code Changes

```lua
-- Modified build_predicate: predicates accept entry instead of path
function M.build_predicate(state, idx)
    local predicates = {}
    -- ... build predicates that accept (entry) instead of (path) ...

    return function(path)
        if not path then return not state.existing_only end
        -- Single index lookup
        local entry = idx.files[path] or idx.files[resolve_path(idx, path)]
        if not entry then return not state.existing_only end
        -- Pass entry to all predicates
        for _, pred in ipairs(predicates) do
            if not pred(entry) then return false end
        end
        return true
    end
end
```

> Per-traversal `resolve_in_index` memoization → consolidated into doc
> `67-index-persistence-maintenance.md` #3

### Expected Performance Improvement

- For 3 filters on 100-node graph: 300 index lookups -> 100 (3x reduction)

### Risk Assessment

- **API change:** Predicates now receive entry objects instead of paths. All
  predicate builders in `graph_filter.lua` must be updated. No external API change.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Generation-cached IDF (#2) | Low | Medium | Low |
| 2 | Batched predicates (#4) | Medium | Medium | Low |
| 3 | Connection scoring top-K (#1) | Medium | High | Low |
| 4 | BFS layer caching (#3) | High | High | Medium |

#2 is a 10-line change with immediate benefit. #1 and #3 are the
highest-impact changes but require more careful implementation.

---

## Testing Strategy

### Connection Scoring (#1)
1. Compare top-20 results before/after for a specific source note. Verify
   identical results (order may differ for equal scores).
2. Profile `compute()` with 2000 files. Verify reduced scoring operations.

### IDF Cache (#2)
1. Call `compute()` twice for different source notes. Verify IDF is computed
   only once (same generation).
2. Modify a file (triggers index rebuild). Verify IDF is recomputed.

### BFS Layer Caching (#3)
1. Open graph at depth=1. Press `+` twice. Verify correct nodes at each depth.
2. Toggle a filter. Verify cache invalidation (nodes recalculated).
3. Switch center node. Verify new BFS (different cache key).

### Batched Predicates (#4)
1. Enable 3 graph filters. Verify correct filtering behavior.
2. Profile: verify single index lookup per node per predicate evaluation.

---

## Related Documents

- **Doc `67-index-persistence-maintenance.md` #3** consolidates
  `resolve_in_index` memoization.
- **Doc `58-graph-connections-scoring.md`** covers related graph performance
  optimizations.
- **Doc `79-graph-traversal-connections-refinement.md`** covers graph traversal
  refinements.
