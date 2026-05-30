# 65 --- Search Pipeline Efficiency

> This document is a self-contained implementation guide. Each optimization below is unique to this document.

Four targeted optimizations for the search pipeline, addressing redundant AST
classification, sequential ripgrep execution, per-call tmpfile allocation, and
quadratic section-outlink accumulation.

> **Modules affected:** `search_filter/ast_split.lua`, `search_filter/ripgrep.lua`,
> `search_filter/match_field.lua`, `search/advanced.lua`

---

## 1. Cached AST Classification in split_ast() — Status: IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/search_filter/ast_split.lua` (lines 89-144)

The `split_ast()` function classifies the root AST node at line 99 via
`classify(ast)`, which recursively categorizes every node in the tree as
`"text"`, `"metadata"`, or `"mixed"`. When the result is `"mixed"` (the most
common case for real queries), it calls `extract_metadata_ast(ast)` at line 113,
which internally calls `classify(node)` again at line 55 for each child node.

```lua
-- ast_split.lua:89-144 (simplified)
function M.split_ast(ast)
  local cat = classify(ast)          -- Line 99: recursive classify of entire tree
  if cat == "text" then ... end
  if cat == "metadata" then ... end

  -- Mixed case (line 112):
  if ast.type == "and" then
    local meta = extract_metadata_ast(ast)  -- Line 113: re-classifies children
    local text = extract_text_ast(ast)      -- Line 114: checks types directly
    ...
  end
end
```

`extract_metadata_ast()` (line 48) calls `classify(node)` at line 55 for each
operand. Since `classify()` is recursive, a deeply nested AST with K nodes
triggers O(K) work in the initial `classify()` call, then O(K) again inside
`extract_metadata_ast()` — effectively **2x classification work**.

Note: `extract_text_ast()` (line 17) does NOT call `classify()` — it uses
direct `TEXT_TYPES[t]` / `METADATA_TYPES[t]` checks, which is efficient.

**Complexity:** O(2K) recursive traversals for mixed ASTs where K = node count.

### Proposed Solution

Memoize classification results during the initial `classify()` pass. Use a
local table keyed by node identity (Lua table reference) to store each node's
category. Pass this cache to `extract_metadata_ast()` so it can look up
classifications in O(1) instead of re-traversing.

### Code Changes

**File: `lua/andrew/vault/search_filter/ast_split.lua`**

**Before (lines 73-99):**

```lua
local function classify(node)
  local t = node.type
  if TEXT_TYPES[t] then return "text" end
  if METADATA_TYPES[t] then return "metadata" end
  if t == "and" or t == "or" then
    local lc = classify(node.left)
    local rc = classify(node.right)
    if lc == rc then return lc end
    return "mixed"
  end
  if t == "not" then return classify(node.operand) end
  return "text"
end

function M.split_ast(ast)
  local cat = classify(ast)
  ...
end
```

**After:**

```lua
--- Classify all nodes in the AST, caching results by node reference.
---@param node table  AST node
---@param cache table  node -> "text"|"metadata"|"mixed"
---@return string
local function classify(node, cache)
  local cached = cache[node]
  if cached then return cached end

  local t = node.type
  local result
  if TEXT_TYPES[t] then
    result = "text"
  elseif METADATA_TYPES[t] then
    result = "metadata"
  elseif t == "and" or t == "or" then
    local lc = classify(node.left, cache)
    local rc = classify(node.right, cache)
    result = (lc == rc) and lc or "mixed"
  elseif t == "not" then
    result = classify(node.operand, cache)
  else
    result = "text"
  end

  cache[node] = result
  return result
end

function M.split_ast(ast)
  local cache = {}
  local cat = classify(ast, cache)
  -- Pass cache to extract_metadata_ast so it can reuse classifications
  ...
end
```

Then modify `extract_metadata_ast()` to accept and use the cache:

```lua
local function extract_metadata_ast(node, cache)
  local cat = cache[node] or classify(node, cache)
  if cat == "metadata" then return node end
  if cat == "text" then return nil end
  -- ... handle mixed children using cached classifications
end
```

### Expected Performance Improvement

For a typical mixed query AST with 10 nodes:

- **Before:** ~20 recursive node visits (classify + extract_metadata re-classify)
- **After:** ~10 recursive node visits (classify once, O(1) lookups in extract)

The absolute time saved is small (microseconds), but this runs on every
keystroke in live search mode. Eliminates redundant tree traversal.

### Risk Assessment

- **Correctness:** Cache is keyed by Lua table identity (reference), which is
  unique per AST node. No risk of key collision.
- **Lifetime:** Cache is local to `split_ast()` — created and discarded per
  call. No stale data across queries.
- **Memory:** One entry per AST node. Typical queries have < 20 nodes.

---

## 2. Parallel Ripgrep Execution for AND/OR Branches — Status: IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/search_filter/ripgrep.lua` (lines 110, 163-165, 190-191)

For compound text queries like `(word1 AND word2 AND word3)`, the
`ripgrep_in_files()` function processes AND/OR branches recursively. Each leaf
node calls `run_rg_single()` (line 110) which invokes
`vim.system(cmd):wait()` — a **blocking** call.

```lua
-- ripgrep.lua:110 (simplified)
local function run_rg_single(pattern, file_paths, opts)
  -- ... build command ...
  local result = vim.system(cmd):wait()  -- BLOCKS until rg completes
  -- ... process output ...
end

-- ripgrep.lua:163-165 (AND branch)
local function ripgrep_in_files(ast, file_paths, opts)
  if ast.type == "and" then
    local left = ripgrep_in_files(ast.left, file_paths, opts)   -- blocks
    local right = ripgrep_in_files(ast.right, file_paths, opts) -- blocks after left
    -- ... intersect results ...
  end
end
```

For `(A AND B AND C)`, three sequential ripgrep processes run one after
another. Since they search the same file set independently, they could run
in parallel.

**Complexity:** O(depth * rg_latency) wall-clock time, where depth = number
of AND/OR leaves. A 3-term AND query takes ~3x the latency of a single search.

### Proposed Solution

Launch independent ripgrep branches in parallel using `vim.system()` without
`:wait()`, then collect results. For AND nodes, launch both branches
concurrently and intersect when both complete. For OR nodes, launch both and
union.

### Code Changes

**File: `lua/andrew/vault/search_filter/ripgrep.lua`**

**New helper — non-blocking ripgrep launch:**

```lua
--- Launch ripgrep asynchronously, returning the SystemObj handle.
---@param pattern string
---@param file_paths string[]
---@param opts table
---@return vim.SystemObj
local function launch_rg(pattern, file_paths, opts)
  local tmpfile = write_paths_tmpfile(file_paths)
  local cmd = build_rg_cmd(pattern, tmpfile, opts)
  local handle = vim.system(cmd)
  -- Store tmpfile path on handle for cleanup
  handle._tmpfile = tmpfile
  return handle
end

--- Wait for a launched ripgrep and return parsed results.
---@param handle vim.SystemObj
---@return string[]
local function collect_rg(handle)
  local result = handle:wait()
  if handle._tmpfile then
    os.remove(handle._tmpfile)
  end
  return parse_rg_output(result)
end
```

**Modified AND/OR handling:**

```lua
local function ripgrep_in_files(ast, file_paths, opts)
  if ast.type == "and" then
    -- Check if both branches are independent (no shared state)
    -- Launch both in parallel
    local left_handle = launch_rg_tree(ast.left, file_paths, opts)
    local right_handle = launch_rg_tree(ast.right, file_paths, opts)
    local left = collect_rg_tree(left_handle)
    local right = collect_rg_tree(right_handle)
    return intersect_results(left, right)
  elseif ast.type == "or" then
    local left_handle = launch_rg_tree(ast.left, file_paths, opts)
    local right_handle = launch_rg_tree(ast.right, file_paths, opts)
    local left = collect_rg_tree(left_handle)
    local right = collect_rg_tree(right_handle)
    return union_results(left, right)
  else
    -- Leaf: run single rg synchronously (already fast)
    return run_rg_single(ast, file_paths, opts)
  end
end
```

**Note:** `launch_rg_tree` / `collect_rg_tree` are recursive wrappers that
handle the tree structure, launching leaf nodes in parallel where possible.

### Expected Performance Improvement

For a 3-term AND query on a 2000-file vault:

- **Before:** 3 sequential ripgrep calls, ~150ms total (50ms each)
- **After:** 3 parallel ripgrep calls, ~60ms total (50ms + OS scheduling)

~2-3x speedup for multi-term text queries. More impactful in live search
where this runs on every keystroke (after debounce).

### Risk Assessment

- **Process limits:** Launching 3-5 ripgrep processes simultaneously is
  well within normal limits. Deep ASTs (10+ terms) could spawn many processes;
  add a `max_parallel` cap (default 4).
- **Tmpfile contention:** Each branch uses its own tmpfile — no contention.
- **Result ordering:** AND intersection and OR union are order-independent.
  The parallel execution produces identical results.
- **Fallback:** If `vim.system()` without `:wait()` is unavailable (older
  Neovim), fall back to sequential execution.

---

## 3. Tmpfile Reuse Across Ripgrep Calls — Status: IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/search_filter/ripgrep.lua` (lines 58-67, 98, 113)

Each `run_rg_single()` call creates a temporary file via
`write_paths_tmpfile()` (lines 58-67), writes all file paths to it, passes it
to ripgrep via `--files-from`, then deletes it at line 113.

```lua
-- ripgrep.lua:58-67
local function write_paths_tmpfile(file_paths)
  local tmpfile = os.tmpname()
  local f = io.open(tmpfile, "w")
  for _, p in ipairs(file_paths) do
    f:write(p .. "\n")
  end
  f:close()
  return tmpfile
end
```

For an AND query with 3 terms searching the same file set, this creates 3
identical tmpfiles containing the same paths, writes 3x the same data, and
deletes 3 files.

**Complexity:** O(branches * file_count) I/O operations for the same data.

### Proposed Solution

Create the tmpfile once at the top of `ripgrep_in_files()` and pass it down
to all recursive calls. Delete it after the top-level call completes.

### Code Changes

**File: `lua/andrew/vault/search_filter/ripgrep.lua`**

```lua
--- Top-level entry point: creates tmpfile once, delegates to recursive impl.
function M.ripgrep_in_files(ast, file_paths, opts)
  if not ast then return {} end

  local tmpfile = write_paths_tmpfile(file_paths)
  local ok, result = pcall(ripgrep_in_files_impl, ast, tmpfile, opts)
  os.remove(tmpfile)

  if not ok then error(result) end
  return result
end

--- Recursive implementation using shared tmpfile.
local function ripgrep_in_files_impl(ast, tmpfile, opts)
  if ast.type == "and" then
    local left = ripgrep_in_files_impl(ast.left, tmpfile, opts)
    local right = ripgrep_in_files_impl(ast.right, tmpfile, opts)
    return intersect_results(left, right)
  elseif ast.type == "or" then
    -- ... similar ...
  else
    return run_rg_with_tmpfile(ast, tmpfile, opts)  -- reuses existing tmpfile
  end
end
```

### Expected Performance Improvement

For a 3-term AND on 2000 files:

- **Before:** 3 tmpfile creates + 3 writes of 2000 paths + 3 deletes = 9 I/O ops
- **After:** 1 tmpfile create + 1 write + 1 delete = 3 I/O ops

Saves ~6 filesystem operations per compound query. Modest but free improvement.

### Risk Assessment

- **Correctness:** All branches search the same file set (the intersection/
  union logic operates on results, not file lists). Reusing the tmpfile is safe.
- **Cleanup:** `pcall` wrapper ensures tmpfile is deleted even on error.
- **Parallel compatibility:** If combined with optimization #2 (parallel
  ripgrep), each parallel branch reads the same tmpfile simultaneously.
  This is safe — tmpfiles are opened read-only by ripgrep.

---

## 4. Flattened Section-Outlink Accumulation — Status: IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/search_filter/match_field.lua` (lines 74-115)

The `build_file_section_map()` function reads a file from disk (line 66),
scans every line for headings and outlinks, and assigns each outlink to all
ancestor headings in the heading stack:

```lua
-- match_field.lua:106-114 (inside build_file_section_map)
for _, lnk in ipairs(line_links) do
  for _, ancestor in ipairs(heading_stack) do   -- O(heading_depth)
    local sec = sections[ancestor.slug]
    sec[#sec + 1] = lnk
  end
end
```

For a file with heading depth D and L links per line and N lines, this is
O(N * L * D) insertions. A deeply nested file (D=6) with 10 links per section
duplicates each link into 6 ancestor sections.

**Complexity:** O(N * L * D) where D = max heading nesting depth.

### Proposed Solution

Accumulate outlinks only under the immediate (deepest) heading. After the line
scan completes, propagate outlinks upward through the heading hierarchy in a
single post-processing pass. This reduces the inner loop from O(D) to O(1)
per link.

### Code Changes

**File: `lua/andrew/vault/search_filter/match_field.lua`**

**Before (lines 106-114):**

```lua
for _, lnk in ipairs(line_links) do
  for _, ancestor in ipairs(heading_stack) do
    local sec = sections[ancestor.slug]
    sec[#sec + 1] = lnk
  end
end
```

**After:**

```lua
-- Phase 1: accumulate links under immediate heading only
for _, lnk in ipairs(line_links) do
  local current = heading_stack[#heading_stack]
  if current then
    local sec = sections[current.slug]
    sec[#sec + 1] = lnk
  end
end

-- ... after the line loop completes ...

-- Phase 2: propagate outlinks upward through heading hierarchy
-- Build parent map from heading_stack tracking
for slug, links in pairs(sections) do
  local parent_slug = parent_map[slug]
  while parent_slug do
    local parent_sec = sections[parent_slug]
    for _, lnk in ipairs(links) do
      parent_sec[#parent_sec + 1] = lnk
    end
    parent_slug = parent_map[parent_slug]
  end
end
```

The `parent_map` is built during the heading scan by recording each heading's
parent (the previous entry in the heading_stack before the new heading was
pushed).

### Expected Performance Improvement

For a file with 6-level nesting, 100 links total:

- **Before:** 100 * 6 = 600 table insertions during the line scan
- **After:** 100 insertions during line scan + ~100 propagation insertions = ~200

~3x reduction in table insertions for deeply nested files.

### Risk Assessment

- **Correctness:** The post-processing propagation produces identical section
  contents — each ancestor section contains the union of all descendant
  outlinks. The result is the same set of links per section slug.
- **parent_map construction:** Straightforward to build during heading_stack
  push/pop operations (track parent slug when pushing a new heading).
- **Section cache:** Results are cached per `(rel_path, generation)` in
  `_section_cache` (line 23), so the optimization benefits both first access
  and cache-miss rebuilds.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Tmpfile Reuse (#3) | Low | Low | Low |
| 2 | AST Classification Cache (#1) | Low | Low | Low |
| 3 | Flattened Section Accumulation (#4) | Medium | Medium | Low |
| 4 | Parallel Ripgrep (#2) | High | High | Medium |

---

## Testing Strategy

### AST Classification Cache (#1)

1. Compare `split_ast()` output before/after for a corpus of query ASTs.
2. Verify mixed, text-only, and metadata-only queries produce identical splits.

### Parallel Ripgrep (#2)

1. Run the same compound query (3-term AND) with sequential and parallel modes.
   Verify identical result sets.
2. Measure wall-clock time reduction for 3-5 term queries.
3. Test max_parallel cap with a 10-term OR query.

### Tmpfile Reuse (#3)

1. Verify compound queries produce identical results with shared vs per-call
   tmpfiles.
2. Verify tmpfile cleanup on error (force an error mid-query).

### Section Accumulation (#4)

1. For a file with known heading structure, verify `get_section_outlinks()`
   returns identical results before/after.
2. Test with deeply nested headings (6+ levels).
3. Test with flat structure (single H1).

---

## Related Documents

- Doc 57-search-filter-performance covers ripgrep output processing optimization (complementary to #2-#3 here).
