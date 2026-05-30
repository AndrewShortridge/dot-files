# 22 - Fix Graph BFS Cycle Detection and Silent Truncation

**Severity:** Medium (correctness + performance)

## Summary

The BFS traversal logic used by the graph system has two related issues:

1. **Predicate-gated visited set in `graph_filter.lua`** -- nodes that fail the
   filter predicate are never added to the `visited` set, so they are
   re-discovered (and re-evaluated) from every neighbor in a cyclic or
   densely-connected graph.  This causes redundant `resolve_in_index()` and
   predicate calls but cannot produce infinite loops because failed nodes are
   never enqueued.

2. **O(n) loop condition in `search_filter.lua`** -- the BFS loop uses
   `vim.tbl_count(reachable)` (a full table iteration) on every cycle instead
   of maintaining a counter, turning the overall traversal from O(V+E) to
   O(V*(V+E)).

3. **Silent truncation at `max_nodes`** -- both `collect_at_depth()` and
   `collect_reachable()` stop collecting when a `max_nodes` cap is reached.
   The user receives no indication that results were truncated, which can be
   confusing when nodes they expect to see are missing.

---

## Root Cause Analysis

### Location 1: `graph_filter.lua` -- `collect_at_depth()` (line 254)

**File:** `lua/andrew/vault/graph_filter.lua`, lines 254-361

The visited set is only populated when a node passes the predicate:

```lua
-- line 288-293
if target_rel and not visited[target_rel] then
    local target_entry = idx:get_entry(target_rel)
    if target_entry then
        local abs = target_entry.abs_path
        if predicate(abs) then
            visited[target_rel] = true   -- <-- only added here
```

If `predicate(abs)` returns false, `target_rel` is never added to `visited`.
The same node will be re-discovered from every neighbor that links to it,
causing:

- Repeated `resolve_in_index()` lookups (each one does a linear scan of
  `idx.files` in the worst case)
- Repeated `predicate()` evaluations (which may involve tag/date/path checks)
- Repeated `idx:get_entry()` calls

In a densely-connected vault with strict filters (many nodes fail the
predicate), this can multiply the work significantly.  The same pattern appears
for the inlinks loop at lines 330-351.

### Location 2: `search_filter.lua` -- `collect_reachable()` (line 1146)

**File:** `lua/andrew/vault/search_filter.lua`, lines 1146-1197

The BFS loop condition is:

```lua
-- line 1160
while #queue > 0 and vim.tbl_count(reachable) < max_nodes do
```

`vim.tbl_count()` iterates the entire `reachable` hash table on every loop
iteration.  With `max_nodes = 50` (the default), this is barely noticeable.
But when the user configures a larger `max_nodes` or the search `graph:`
operator is used with high depths, the quadratic cost becomes measurable.

This function does NOT have the predicate-gating issue (there is no predicate
parameter), so its visited-set logic is correct.  The only issue is the O(n)
size check.

### Location 3: Silent truncation (both files)

Both functions stop adding nodes once `max_nodes` is reached:

- `graph_filter.lua` line 278: `while #queue > 0 and #all_nodes < max_nodes do`
- `search_filter.lua` line 1160: `while #queue > 0 and vim.tbl_count(reachable) < max_nodes do`

Neither function signals to the caller that truncation occurred.  The user sees
an incomplete graph or an incomplete search result set with no explanation.

---

## The Fix

### Fix 1: Unconditional visited-set insertion in `graph_filter.lua`

Add discovered nodes to the `visited` set regardless of whether they pass the
predicate.  A node that fails the predicate should still be remembered so it is
not re-evaluated.

**File:** `lua/andrew/vault/graph_filter.lua`

**Before (lines 286-324):**

```lua
    -- Outlinks
    for _, link in ipairs(entry.outlinks) do
      local target_rel = resolve_in_index(idx, link.path or "")
      if target_rel and not visited[target_rel] then
        local target_entry = idx:get_entry(target_rel)
        if target_entry then
          local abs = target_entry.abs_path
          if predicate(abs) then
            visited[target_rel] = true
            local name = target_entry.basename
            local node = { name = name, path = abs }
            all_nodes[#all_nodes + 1] = node
            -- Determine direction: from center = forward, otherwise inherit
            local dir = (current.rel == center_rel) and "forward" or (current.direction or "forward")
            if dir == "forward" then
              forward_like[#forward_like + 1] = node
            else
              backlink_like[#backlink_like + 1] = node
            end
            table.insert(queue, { rel = target_rel, d = current.d + 1, direction = dir })
            if #all_nodes >= max_nodes then break end
          end
        end
      elseif not target_rel and current.rel == center_rel then
        ...
      end
    end
```

**After:**

```lua
    -- Outlinks
    for _, link in ipairs(entry.outlinks) do
      local target_rel = resolve_in_index(idx, link.path or "")
      if target_rel and not visited[target_rel] then
        visited[target_rel] = true  -- mark visited unconditionally
        local target_entry = idx:get_entry(target_rel)
        if target_entry then
          local abs = target_entry.abs_path
          if predicate(abs) then
            local name = target_entry.basename
            local node = { name = name, path = abs }
            all_nodes[#all_nodes + 1] = node
            local dir = (current.rel == center_rel) and "forward" or (current.direction or "forward")
            if dir == "forward" then
              forward_like[#forward_like + 1] = node
            else
              backlink_like[#backlink_like + 1] = node
            end
            table.insert(queue, { rel = target_rel, d = current.d + 1, direction = dir })
            if #all_nodes >= max_nodes then break end
          end
        end
      elseif not target_rel and current.rel == center_rel then
        ...
      end
    end
```

Apply the same change to the inlinks loop (lines 330-351):

**Before (lines 330-351):**

```lua
    -- Inlinks
    local inlinks = idx:get_inlinks(current.rel)
    for _, link in ipairs(inlinks) do
      local source_rel = link.path .. ".md"
      if not visited[source_rel] then
        local source_entry = idx:get_entry(source_rel)
        if source_entry then
          local abs = source_entry.abs_path
          if predicate(abs) then
            visited[source_rel] = true
            ...
          end
        end
      end
    end
```

**After:**

```lua
    -- Inlinks
    local inlinks = idx:get_inlinks(current.rel)
    for _, link in ipairs(inlinks) do
      local source_rel = link.path .. ".md"
      if not visited[source_rel] then
        visited[source_rel] = true  -- mark visited unconditionally
        local source_entry = idx:get_entry(source_rel)
        if source_entry then
          local abs = source_entry.abs_path
          if predicate(abs) then
            ...
          end
        end
      end
    end
```

**Important behavioral note:** This change means nodes that fail the predicate
will no longer be enqueued for further expansion.  In the original code, they
were never enqueued anyway (because the `table.insert(queue, ...)` was inside
the `predicate(abs)` branch).  However, the original code allowed them to be
"re-discovered" from different neighbors.  The fixed code blocks that
re-discovery.  Since the predicate result is deterministic for a given path,
re-discovery never produces a different outcome -- so blocking it is strictly
an optimization with no behavioral change.

**Edge case:** Should predicate-failing nodes still be traversed (their
outlinks/inlinks explored) even though they are excluded from results?  The
current code does NOT traverse through predicate-failing nodes, and the fix
preserves this.  If "traverse through filtered-out nodes" is desired in the
future, the fix would need to enqueue such nodes but not add them to the
result lists.  This is left as a separate enhancement.

### Fix 2: Replace `vim.tbl_count()` with a counter in `search_filter.lua`

**File:** `lua/andrew/vault/search_filter.lua`

**Before (lines 1157-1160):**

```lua
  local reachable = { [center_rel] = true }
  local queue = { { rel = center_rel, d = 0 } }

  while #queue > 0 and vim.tbl_count(reachable) < max_nodes do
```

**After:**

```lua
  local reachable = { [center_rel] = true }
  local reachable_count = 1
  local queue = { { rel = center_rel, d = 0 } }

  while #queue > 0 and reachable_count < max_nodes do
```

And update each insertion site:

**Before (line 1171-1173):**

```lua
        if target_rel and not reachable[target_rel] then
          reachable[target_rel] = true
          table.insert(queue, { rel = target_rel, d = current.d + 1 })
```

**After:**

```lua
        if target_rel and not reachable[target_rel] then
          reachable[target_rel] = true
          reachable_count = reachable_count + 1
          table.insert(queue, { rel = target_rel, d = current.d + 1 })
```

**Before (lines 1183-1187):**

```lua
        if not reachable[source_rel] then
          local source_entry = index:get_entry(source_rel)
          if source_entry then
            reachable[source_rel] = true
            table.insert(queue, { rel = source_rel, d = current.d + 1 })
```

**After:**

```lua
        if not reachable[source_rel] then
          local source_entry = index:get_entry(source_rel)
          if source_entry then
            reachable[source_rel] = true
            reachable_count = reachable_count + 1
            table.insert(queue, { rel = source_rel, d = current.d + 1 })
```

### Fix 3: Return truncation flag and notify user

**File:** `lua/andrew/vault/graph_filter.lua`

Change `collect_at_depth()` return signature to include a truncated flag:

**Before (line 253):**

```lua
---@return {name: string, path: string}[] forward_like
---@return {name: string, path: string}[] backlink_like
```

**After:**

```lua
---@return {name: string, path: string}[] forward_like
---@return {name: string, path: string}[] backlink_like
---@return boolean truncated true if max_nodes cap was hit
```

Add a `truncated` variable, set it when breaking on `max_nodes`, and return it:

```lua
  local truncated = false

  while #queue > 0 and #all_nodes < max_nodes do
    ...
  end

  -- Set truncated if we stopped early due to max_nodes
  if #queue > 0 and #all_nodes >= max_nodes then
    truncated = true
  end

  ...
  return forward_like, backlink_like, truncated
```

**File:** `lua/andrew/vault/graph.lua`

In `local_graph()`, consume the truncated flag (line 611):

**Before:**

```lua
    forward_links, backlinks = graph_filter.collect_at_depth(buf_path, state.depth, predicate)
```

**After:**

```lua
    local truncated
    forward_links, backlinks, truncated = graph_filter.collect_at_depth(buf_path, state.depth, predicate)
    if truncated then
      vim.notify(
        string.format("Graph: results truncated at %d nodes (max_nodes cap)", config.graph.max_nodes),
        vim.log.levels.INFO
      )
    end
```

**File:** `lua/andrew/vault/search_filter.lua`

Change `collect_reachable()` to also return a truncated flag:

```lua
  local truncated = #queue > 0 and reachable_count >= max_nodes
  return reachable, truncated
```

Update `precompute_graph_sets()` to log truncation:

```lua
  local reachable, truncated = collect_reachable(index, center_abs, node.depth, node.direction)
  sets[graph_id] = reachable
  if truncated then
    vim.notify(
      string.format("Search graph: '%s' truncated at %d nodes", graph_id, max_nodes),
      vim.log.levels.INFO
    )
  end
```

---

## Performance Implications

### Fix 1 (unconditional visited)

- **Reduces** work in densely-connected graphs with strict predicates.  Each
  node's `resolve_in_index()` + `predicate()` are called at most once instead
  of once per incoming edge.
- Worst-case improvement: from O(E * cost_of_predicate) to O(V *
  cost_of_predicate) where E >> V in dense graphs.
- No regression for sparse/tree-like vaults (no duplicate discoveries occur).

### Fix 2 (counter replaces `vim.tbl_count`)

- Eliminates O(n) per-iteration overhead, reducing overall BFS from O(n*(n+E))
  to O(n+E).
- At the default `max_nodes = 50`, the difference is negligible (~2500 hash
  iterations vs 50).  Becomes meaningful when users increase `max_nodes` or
  use `graph:depth=5` on large vaults.

### Fix 3 (truncation notification)

- Adds one `vim.notify` call when truncation occurs.  Zero cost when
  `max_nodes` is not reached.

---

## Test Cases

### 1. Cyclic graph -- visited set correctness

Create a cycle: A -> B -> C -> A.

- Open A, run `:VaultGraph` at depth 2.
- **Expected:** B and C appear exactly once each.  No duplicate entries.
- **Verify:** With the predicate-gating fix, if a tag filter excludes B, then B
  is visited once, fails the predicate, and is never re-evaluated.

### 2. Dense fan-out with strict filter

Create: Hub -> {N1, N2, ..., N20}, and N1 -> N2, N2 -> N3, ..., N19 -> N20.

- Apply a tag filter that excludes all N* notes.
- Open Hub, run `:VaultGraph` at depth 3.
- **Before fix:** each N* node is re-evaluated from every neighbor (up to 20
  times each for N-nodes near the middle of the chain).
- **After fix:** each N* node is evaluated exactly once.

### 3. `collect_reachable` counter accuracy

Use a search query: `graph:depth=3 tag:project`.

- **Before fix:** `vim.tbl_count(reachable)` called on every BFS iteration.
- **After fix:** `reachable_count` integer compared on every iteration; result
  set is identical.

### 4. Truncation notification

Set `config.graph.max_nodes = 5`.  Open a note with >5 connections at depth 2.

- **Expected:** Graph renders 5 nodes and a notification appears:
  "Graph: results truncated at 5 nodes (max_nodes cap)".
- For search: use `graph:depth=3` on a well-connected note.
  **Expected:** search results include a notification if truncated.

### 5. Predicate-failing nodes are NOT traversed through

Create: A -> B -> C where B has tag `#draft` and a tag filter excludes `#draft`.

- Open A, run `:VaultGraph` at depth 2 with `#draft` excluded.
- **Expected:** Neither B nor C appear.  C is unreachable because traversal
  does not pass through predicate-failing B.
- This preserves existing behavior (not a regression).

### 6. Empty / single-node graph

Open a note with no links and no backlinks.  Run `:VaultGraph`.

- **Expected:** "(no connections)" message.  No errors, no truncation warning.

---

## Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/graph_filter.lua` | Move `visited[target_rel] = true` before predicate check in both outlinks and inlinks loops of `collect_at_depth()`.  Add `truncated` return value. |
| `lua/andrew/vault/search_filter.lua` | Add `reachable_count` integer, replace `vim.tbl_count(reachable)` in loop condition.  Increment counter at each insertion.  Return `truncated` flag from `collect_reachable()`. |
| `lua/andrew/vault/graph.lua` | Consume `truncated` flag from `collect_at_depth()` and notify user in `local_graph()`. |
