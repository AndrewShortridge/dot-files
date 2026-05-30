# 58 --- Graph & Connections Performance Optimizations

This document is a self-contained implementation guide. Each optimization
below is unique to this document.

Targeted improvements for BFS queue management in graph traversal, string
operations in graph rendering, and connection cache invalidation strategy.

> **Modules affected:** `graph_filter/traversal.lua`,
> `search_filter/graph_traversal.lua`, `graph/render.lua`, `connections.lua`

---

## 1. BFS Queue Optimization — IMPLEMENTED

### Problem Analysis

**Files:**
- `lua/andrew/vault/graph_filter/traversal.lua` (lines 19-125)
- `lua/andrew/vault/search_filter/graph_traversal.lua` (lines 33-93)

Both files implement BFS with array-based queues using `table.insert()`:

```lua
local queue = { { rel = center_rel, d = 0 } }
local head = 1

while head <= #queue do
  local current = queue[head]
  head = head + 1
  -- ...
  table.insert(queue, { rel = target_rel, d = current.d + 1 })
end
```

`table.insert()` at the end of an array is O(1) amortized, but the queue
grows unbounded, leaving consumed entries in memory. For deep traversals
with max_nodes=200, the queue can hold 200+ spent entries.

Additionally, two separate BFS implementations exist with nearly identical
logic — duplicated maintenance burden.

### Proposed Solution

**Optimization 1: Use head/tail index pattern (no table.insert).**

```lua
local queue = {}
local head, tail = 1, 0

local function enqueue(item)
  tail = tail + 1
  queue[tail] = item
end

local function dequeue()
  if head > tail then return nil end
  local item = queue[head]
  queue[head] = nil  -- Allow GC of consumed entry
  head = head + 1
  return item
end
```

**Optimization 2: Consolidate into shared BFS module.**

```lua
-- lua/andrew/vault/bfs.lua (new shared module)
local M = {}

---@param opts table
---  center_rel: string - starting node
---  max_depth: number
---  max_nodes: number
---  direction: "forward"|"backward"|"both"
---  get_outlinks: function(rel_path) -> {rel_path, ...}
---  get_inlinks: function(rel_path) -> {rel_path, ...}
---  predicate: function(rel_path) -> boolean (optional)
---@return table<string, true> reachable  set of reachable rel_paths
---@return table[] nodes  array of {rel, depth, direction}
function M.traverse(opts)
  local queue = {}
  local head, tail = 1, 0
  local visited = {}
  local nodes = {}

  local function enqueue(rel, depth, dir)
    if visited[rel] then return end
    if #nodes >= opts.max_nodes then return end
    if depth > opts.max_depth then return end
    if opts.predicate and not opts.predicate(rel) then return end
    visited[rel] = true
    nodes[#nodes + 1] = { rel = rel, depth = depth, direction = dir }
    tail = tail + 1
    queue[tail] = { rel = rel, d = depth, direction = dir }
  end

  enqueue(opts.center_rel, 0, nil)

  while head <= tail and #nodes < opts.max_nodes do
    local current = queue[head]
    queue[head] = nil
    head = head + 1

    if current.d >= opts.max_depth then goto continue end

    -- Forward links
    if opts.direction ~= "backward" then
      local outlinks = opts.get_outlinks(current.rel)
      if outlinks then
        for _, target in ipairs(outlinks) do
          enqueue(target, current.d + 1, "forward")
        end
      end
    end

    -- Backward links
    if opts.direction ~= "forward" then
      local inlinks = opts.get_inlinks(current.rel)
      if inlinks then
        for _, source in ipairs(inlinks) do
          enqueue(source, current.d + 1, "backward")
        end
      end
    end

    ::continue::
  end

  return visited, nodes
end

return M
```

### Expected Performance Improvement

- **Queue memory:** Consumed entries are GC'd immediately (set to nil)
  instead of persisting in the array.
- **Code deduplication:** Single BFS implementation maintained in one place.
- **Minor speedup:** Avoids `table.insert()` overhead (realloc checks).

For typical graph traversals (depth 2-3, max_nodes 50-200), the improvement
is modest but the code quality benefit is significant.

### Risk Assessment

- **Behavioral parity:** The shared module must support both use cases:
  - `graph_filter/traversal.lua`: returns node list with directions
  - `search_filter/graph_traversal.lua`: returns reachable set only
  Both are covered by the proposed API (returns both `reachable` set and
  `nodes` array).

---

## 2. Graph Render String Optimization — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/graph/render.lua` (lines 56-230)

The render function builds display lines with multiple string concatenation
operations and repeated `vim.fn.strdisplaywidth()` calls:

```lua
left_part = string.rep(" ", pad) .. bl_display .. connector_in   -- 3 concats
right_part = connector_out .. fl_display                          -- 1 concat
line_str = left_part .. right_part                                -- 1 concat
```

`M.display_width()` wraps `vim.fn.strdisplaywidth()`, crossing the VimL
boundary. Called ~6 times per render for connector strings that never change.

Highlight positions are found via linear string search (`line:find(needle, ...)`),
redundantly searching strings that were just constructed.

### Proposed Solution

**Optimization 1: Cache display widths for static strings.**

```lua
-- Module-level cache for strings that don't change per render
local _dw_cache = {}
local function cached_display_width(s)
  if not _dw_cache[s] then
    _dw_cache[s] = vim.fn.strdisplaywidth(s)
  end
  return _dw_cache[s]
end
```

**Optimization 2: Cache `string.rep()` results.**

```lua
local _pad_cache = setmetatable({}, {
  __index = function(t, n)
    t[n] = string.rep(" ", n)
    return t[n]
  end
})

-- Usage:
left_part = _pad_cache[pad] .. bl_display .. connector_in
```

**Optimization 3: Track highlight positions during string construction.**

Instead of building the string then searching it for highlight positions:

```lua
-- Track column position as we build the line
local col = 0
local parts = {}

parts[#parts + 1] = _pad_cache[pad]
col = col + pad

local bl_start = col
parts[#parts + 1] = bl_display
col = col + cached_display_width(bl_display)
local bl_end = col

parts[#parts + 1] = connector_in
col = col + connector_in_dw

-- ... continue building ...

local line_str = table.concat(parts)

-- Highlights use pre-computed positions (no string search needed)
add_hl(row, bl_start, bl_end, "VaultGraphBacklink")
```

### Expected Performance Improvement

For a graph render with 50 links:

- **Before:** ~300 string concatenations, ~100 `strdisplaywidth()` calls,
  ~150 `string.find()` searches
- **After:** ~50 `table.concat()` calls, ~50 `strdisplaywidth()` calls
  (cached for repeated strings), 0 `string.find()` searches
- **Estimated:** ~40-50% reduction in render time

---

## 3. Connection Cache Invalidation — IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/connections.lua` (lines 645-658)

When any file changes, `_index_gen` resets to 0, invalidating ALL cached
connection results:

```lua
invalidate_file = function(abs_path)
  local rel = engine.vault_relative(abs_path)
  if rel then
    _cache[rel] = nil          -- Clears one entry
    _index_gen = 0             -- But invalidates ALL entries
  end
end
```

For a 10-file editing session, every save invalidates the entire connection
cache, causing full recomputation on next access.

### Proposed Solution

Track which files link to the cached source. Only invalidate a cache entry
if the changed file is in its dependency set.

```lua
invalidate_file = function(abs_path)
  local rel = engine.vault_relative(abs_path)
  if rel then
    -- Remove the changed file's own cache entry
    _cache[rel] = nil

    -- Only invalidate entries that depend on the changed file
    for cached_rel, entry in pairs(_cache) do
      if entry.deps and entry.deps[rel] then
        _cache[cached_rel] = nil
      end
    end
    -- Do NOT reset _index_gen globally
  end
end
```

In `M.compute()`, record dependencies:

```lua
-- After computing connections for source_rel:
local deps = {}
-- Dependencies are: direct neighbors + files with shared tags
for _, result in ipairs(top_results) do
  deps[result.rel_path] = true
end
_cache[source_rel] = {
  results = top_results,
  deps = deps,
  index_gen = index_gen,
  timestamp = now,
}
```

### Expected Performance Improvement

- **Before:** Every file save -> all connection caches cleared
- **After:** File save -> only affected connection caches cleared
- For typical editing (5-10 files touched), this preserves ~90% of cached
  connections across the session.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Graph Render Strings (#2) | Low | Medium | Low |
| 2 | Connection Cache Invalidation (#3) | Medium | Medium | Medium |
| 3 | BFS Queue Consolidation (#1) | Medium | Low | Low |

#2 is a quick win that affects every graph render. #3 improves multi-file
editing workflows. #1 is primarily a code quality improvement.

---

## Testing Strategy

### BFS Queue (#1)
1. Run graph traversal with depth=3, max_nodes=100. Compare reachable
   sets before/after refactor.
2. Verify no memory leak (queue entries GC'd after consumption).

### Graph Render (#2)
1. Render a graph with 50 links. Verify visual output is identical.
2. Verify highlight positions match expected columns.

### Connection Cache (#3)
1. Open connection view for Note A. Edit unrelated Note B. Verify
   Note A's connections are still cached (not recomputed).
2. Edit a note that links to Note A. Verify Note A's connections
   are recomputed.

---

## Related Documents

- Doc 60-graph-connections-performance covers BFS layer caching and top-K heap (complementary).
- Doc 79-graph-traversal-connections-refinement covers graph traversal refinements.
