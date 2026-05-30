# 36. Hierarchical Summary Index

## Problem

`_ensure_aggregates()` in `vault_index.lua` (lines 1787-1872) lazily rebuilds 7 aggregate caches by iterating ALL files in `self.files` when a generation mismatch (`_aggregates_gen != _generation`) is detected. The caches built are: `_cached_name_cache`, `_cached_tags`, `_cached_tag_counts`, `_cached_fm_keys`, `_cached_fm_key_counts`, `_cached_aliases`, and `_cached_sorted_names`. An incremental path exists (`_update_aggregates_incremental()`, lines 1316-1619) using count tracking (increment/decrement of `_cached_tag_counts` and `_cached_fm_key_counts` dictionaries, binary insert/remove for sorted arrays), but it only handles small-batch updates — large changes or cold starts still trigger full O(N) iteration. The incremental path is gated behind `config.invalidation.enable_tiered` and a batch size threshold (`config.invalidation.partial_file_threshold`, default 50).

Separately, `stats.lua:compute(idx)` performs its own independent O(N) pass over `idx:snapshot_files()` to compute vault-wide statistics (file counts, tag distributions, task breakdowns, orphans, broken links, folder/month distributions, connectivity). This iteration is completely separate from `_ensure_aggregates()` and always pays the full O(N) cost.

`connections.lua` maintains its own IDF cache (`_idf_cache`, `_idf_gen`, `_idf_total`, `_idf_file_tags`) with `build_tag_idf(files)` and `update_tag_idf_incremental(files)`, iterating all files to compute document frequency for each tag. This is a third independent O(N) iteration path.

For a 5,000-file vault, these three separate O(N) passes are expensive even when only a single file changed. Because there is no shared intermediate caching layer, each consumer pays its own full iteration cost.

**Note**: Some aggregate queries are already O(1): `vault_index:file_count()` (lines 1975-1977) returns a cached `_file_count` counter (incremented/decremented during `_apply_staged()`). The BFS-based graph traversal in `bfs.lua` counts nodes during traversal with a `max_nodes` cap from `config.graph.max_nodes` (default 50), not via aggregate iteration — BFS uses a running `node_count` with three hard-stop checks (lines 66, 73, 92) and a main loop guard (line 145). Note: `graph.lua` does NOT call `idx:file_count()` directly — it delegates file count awareness to BFS truncation detection.

## Inspiration

Zed's `crates/sum_tree/src/` crate (3 files: `sum_tree.rs`, `cursor.rs`, `tree_map.rs`) implements a generic balanced B+ tree where each interior node caches a `Summary` of its entire subtree. Dependencies: `arrayvec 0.7.1` (fixed-capacity vectors), `rayon` (parallel construction), `log`.

**Core traits:**
- `Item` trait (line 19): `pub trait Item: Clone` with `type Summary: Summary` and `fn summary(&self, cx: &<Self::Summary as Summary>::Context) -> Self::Summary` — computes a summary from a single item, using the Summary's associated Context type
- `Summary` trait (line 36): `pub trait Summary: Clone` with `type Context`, `fn zero(cx: &Self::Context) -> Self` and `fn add_summary(&mut self, summary: &Self, cx: &Self::Context)` — monoid operations for combining summaries. Also implemented for `&'static ()` as a catch-all placeholder
- `Dimension<'a, S>` trait (line 63): Lifetime-parameterized, separate from Summary, enables measuring specific attributes within a Summary for cursor navigation. Has blanket impl for any `T: Summary` (a Summary is automatically its own Dimension). Supports tuple composition for tracking multiple dimensions simultaneously (lines 103-136)
- `SeekTarget<'a, S, D>` trait (line 85): `fn cmp(&self, cursor_location: &D, cx: &S::Context) -> Ordering` — defines how to compare a target position against cursor position during tree seeking. Blanket impl for any `D: Dimension + Ord`
- `KeyedItem` trait (line 26): Extends `Item` with `type Key: for<'a> Dimension<'a, Self::Summary> + Ord` and `fn key() -> Key` for ordered lookup, enabling `edit()`, `insert_or_replace()`, and `remove()` operations

**Node structure (line 792):**
```rust
#[derive(Clone)]
pub enum Node<T: Item> {
    Internal {
        height: u8,
        summary: T::Summary,                           // Cached total of all descendants
        child_summaries: ArrayVec<T::Summary, { 2 * TREE_BASE }>,  // Per-child summaries
        child_trees: ArrayVec<SumTree<T>, { 2 * TREE_BASE }>,
    },
    Leaf {
        summary: T::Summary,                           // Aggregated summary of items
        items: ArrayVec<T, { 2 * TREE_BASE }>,
        item_summaries: ArrayVec<T::Summary, { 2 * TREE_BASE }>,
    },
}
```

`SumTree<T>` (line 183) is a newtype wrapper around `Arc<Node<T>>`, providing copy-on-write semantics via `Arc::make_mut()` — clones only when multiple owners exist. Interior nodes cache both the full node summary AND individual child summaries for efficient cursor traversal. TREE_BASE is 6 in production (2 in tests), giving max 12 items/children per node.

**Cursor** (cursor.rs, line 22): `Cursor<'a, T: Item, D>` with stack-based traversal (`ArrayVec<StackEntry<'a, T, D>, 16>` max depth), `position: D` for dimension tracking, `did_seek`/`at_end` state flags, and a context reference. A `Bias` enum (Left/Right, line 159) disambiguates cursor positions at boundaries. A `SeekAggregate` trait (cursor.rs, line 697) enables three operations from one traversal codepath: pure seeking (`()`), subtree extraction (`SliceSeekAggregate`), and summary accumulation (`SummarySeekAggregate`). Also provides `FilterCursor` (cursor.rs, line 628) with predicate-based filtering and `Iterator` impl.

**Batch operations**: `edit(edits: Vec<Edit<T>>)` (line 712) sorts edits by key and processes them in O(k log n) using cursor slicing. `Edit<T>` is an enum with `Insert(T)` and `Remove(T::Key)` variants (line 890). `from_iter()` (line 219) builds balanced trees bottom-up in O(n) by creating leaf nodes of `2*TREE_BASE` items then layering internal nodes. `from_par_iter()` (line 285) uses rayon's `.chunks()` for parallel O(n/p) construction, requiring `T: Send + Sync`. Trees use `Arc<Node<T>>` for copy-on-write semantics via `Arc::make_mut()`.

**TreeMap/TreeSet** (tree_map.rs): `TreeMap<K, V>` wraps `SumTree<MapEntry<K,V>>` providing ordered map operations (`insert`, `get`, `remove`, `closest`, `iter_from`, `remove_range`, `retain`). `TreeSet<K>` wraps TreeMap with unit values. `MapSeekTarget<K>` trait (line 220) enables custom seek behavior.

The key insight is that summaries compose: the summary of a parent is the sum of its children's summaries, so updates only need to recompute along the path from the changed leaf to the root.

## Design

Rather than implementing a full balanced B-tree (which would be over-engineered for our use case), we use the natural directory hierarchy of the vault as the tree structure. Every directory becomes an interior node, and every file becomes a leaf node. Each node caches an aggregate summary of its subtree.

### SummaryNode Structure

```lua
-- Each node in the tree
SummaryNode = {
  path = "daily/",              -- relative directory path (or file path for leaves)
  is_leaf = false,              -- true for file entries
  file_count = 365,             -- number of files in subtree
  tag_counts = {                -- tag -> count across all files in subtree
    journal = 365,
    review = 12,
  },
  tag_file_counts = {           -- tag -> number of files containing that tag (for IDF)
    journal = 365,
    review = 12,
  },
  fm_key_counts = {             -- frontmatter key -> count across subtree
    type = 300,
    date = 365,
  },
  task_count = 1200,            -- total tasks in subtree
  task_status_counts = {        -- task status char -> count (matches task.status field)
    [" "] = 800,
    ["x"] = 350,
    ["/"] = 50,
  },
  link_count = 2000,            -- total outlinks in subtree
  heading_count = 4500,         -- total headings in subtree
  alias_count = 50,             -- total aliases in subtree
  block_id_count = 200,         -- total block IDs in subtree
  children = {                  -- name -> SummaryNode (nil for leaves)
    ["2024-01-01.md"] = SummaryNode,
    ["2024-01-02.md"] = SummaryNode,
  },
}
```

### Tree Layout

```
root (vault/)
  daily/
    2024-01-01.md  (leaf)
    2024-01-02.md  (leaf)
    ...
  projects/
    alpha/
      notes.md     (leaf)
      tasks.md     (leaf)
    beta/
      overview.md  (leaf)
  zettelkasten/
    202401011200.md (leaf)
    ...
```

### Summary Composition

A directory node's summary is the element-wise sum of its children's summaries:

```lua
local function compose_summaries(children)
  local summary = {
    file_count = 0,
    tag_counts = {},
    tag_file_counts = {},
    fm_key_counts = {},
    task_count = 0,
    task_status_counts = {},
    link_count = 0,
    heading_count = 0,
    alias_count = 0,
    block_id_count = 0,
  }
  for _, child in pairs(children) do
    summary.file_count = summary.file_count + child.file_count
    summary.task_count = summary.task_count + child.task_count
    summary.link_count = summary.link_count + child.link_count
    summary.heading_count = summary.heading_count + child.heading_count
    summary.alias_count = summary.alias_count + child.alias_count
    summary.block_id_count = summary.block_id_count + child.block_id_count
    for tag, count in pairs(child.tag_counts) do
      summary.tag_counts[tag] = (summary.tag_counts[tag] or 0) + count
    end
    for tag, count in pairs(child.tag_file_counts) do
      summary.tag_file_counts[tag] = (summary.tag_file_counts[tag] or 0) + count
    end
    for key, count in pairs(child.fm_key_counts) do
      summary.fm_key_counts[key] = (summary.fm_key_counts[key] or 0) + count
    end
    for mark, count in pairs(child.task_status_counts) do
      summary.task_status_counts[mark] = (summary.task_status_counts[mark] or 0) + count
    end
  end
  return summary
end
```

### Leaf Summary Extraction

A leaf node's summary is derived directly from the vault index entry for that file (SCHEMA_VERSION 5). Entry structure uses `self.files[rel_path]` (not `_entries`) and has persisted fields: `rel_path`, `rel_stem`, `rel_stem_lower`, `mtime`, `size`, `ctime`, `frontmatter` (table), `aliases` (string[]), `tags` (string[]), `headings` (table[]), `block_ids` (table[]), `outlinks` (table[]), `tasks` (table[]), `inline_fields` (table), `day` (date string|nil), `created_ts`, `modified_ts`, `day_ts`. Each task has fields: `text`, `text_lower`, `status` (the checkbox character, e.g. " ", "x", "/"), `completed` (boolean), `line`, `indent_level`, `tags`, plus parsed inline fields (`due`, `priority`, `repeat_rule`, `completion`, `scheduled`, `fields`). Derived fields like `tag_set`, `heading_slugs`, `block_id_set`, `abs_path`, `basename`, `basename_lower`, `folder` are lazily computed via metatable `__index` (vault_index.lua lines 37-84, within `make_entry_mt()` at lines 35-86).

```lua
local function entry_to_summary(entry)
  -- Tag counts (total references) and tag file counts (document frequency for IDF)
  local tag_counts = {}
  local tag_file_counts = {}
  for _, tag in ipairs(entry.tags or {}) do
    tag_counts[tag] = (tag_counts[tag] or 0) + 1
    tag_file_counts[tag] = 1  -- each file counts once per tag for IDF
  end

  -- Frontmatter key counts
  local fm_key_counts = {}
  if entry.frontmatter then
    for key, _ in pairs(entry.frontmatter) do
      fm_key_counts[key] = 1
    end
  end

  -- Task status breakdown
  local task_status_counts = {}
  for _, task in ipairs(entry.tasks or {}) do
    local mark = task.status or " "
    task_status_counts[mark] = (task_status_counts[mark] or 0) + 1
  end

  return {
    file_count = 1,
    tag_counts = tag_counts,
    tag_file_counts = tag_file_counts,
    fm_key_counts = fm_key_counts,
    task_count = #(entry.tasks or {}),
    task_status_counts = task_status_counts,
    link_count = #(entry.outlinks or {}),
    heading_count = #(entry.headings or {}),
    alias_count = #(entry.aliases or {}),
    block_id_count = #(entry.block_ids or {}),
  }
end
```

## Target Modules

- **vault_index.lua** — Replace `_ensure_aggregates()` (lines 1787-1872) and `_update_aggregates_incremental()` (lines 1316-1619) with tree-based lookups. The summary tree becomes the backing store for `tags_with_counts()` (line 1910), `all_tags()` (line 1889), `all_frontmatter_keys()` (line 1903), `all_aliases()` (line 1896), `sorted_names()` (line 1883), and `get_name_cache()` (line 1876). The existing `_file_count` counter can remain as-is (already O(1), line 1975) or be replaced by `tree:query("").file_count`. The `_name_index`, `_alias_index`, and `_inlinks` are lookup tables (not aggregates) and remain separately maintained via `_rebuild_name_index()` (line 1099) / `_update_name_index_incremental()` (line 1123) and `_recompute_inlinks()` (line 1281) / `_recompute_inlinks_incremental()` (line 1725). Entry index keys are computed via `entry_index_keys()` (line 1058) returning `(basename_lower, rel_stem_lower, aliases)`.
- **stats.lua** — `M.compute(idx)` (lines 41-230) is a stateless, uncached function that iterates `idx:snapshot_files()` (line 42, returns live or copy per `config.index.use_snapshots`) and `idx._inlinks` (line 43, direct field access) in a single pass to compute 20 fields: `total_notes`, `total_outlinks`, `total_inlinks`, `broken_link_count`, `broken_link_notes`, tag distributions (`tag_file_counts` using per-file `seen_tags` deduplication), `total_tags` (unique tag count via `vim.tbl_count`), `avg_tags` (tag refs / notes), task breakdowns by `task.status` field (`task_counts`, `task_total`), `total_aliases`, `total_headings`, `total_block_ids`, `avg_outlinks`, `type_counts` (from `entry.frontmatter.type` or `"(untyped)"`), `folder_counts` (extracts top-level dir via `entry.folder:match("^([^/]+)")`, root files → `"(root)"`), `month_counts` (from `entry.day:sub(1,7)` or `os.date("%Y-%m", entry.ctime)` fallback), `orphan_count`/`orphan_pct` (zero inlinks), and `top_connected` (sorted by `degree = in_count + out_count`). Broken link detection uses `idx:resolve_name()` with basename-first then full-name fallback (lines 106-109). Many of these (file/tag/task/link/heading/alias/block_id counts, folder_counts) can be served directly from `tree:query("")` or scoped `tree:query("daily/")`. Broken link detection, orphan detection, connectivity scoring, type_counts, and month_counts still require per-entry access to `_inlinks`, link resolution, frontmatter, or date fields — these remain iterative but can be narrowed to only files that changed since last stats computation using generation tracking.
- **connections.lua** — Maintains its own IDF cache (`_idf_cache` line 47, `_idf_gen` line 49, `_idf_total` line 48, `_idf_file_tags` line 50) via `build_tag_idf(files)` (lines 147-161) and `update_tag_idf_incremental(files)` (lines 165-221). The `ensure_idf(files, gen)` function (lines 721-735) manages cache lifecycle: returns cached values when `_idf_gen == gen`, calls `update_tag_idf_incremental` when `_idf_gen != gen` (incremental), or calls `build_tag_idf` on first build. Design note (lines 43-46): IDF uses manual generation tracking (not `gen_cache`) because `ensure_idf()` performs incremental updates. A similar note (lines 53-55) explains `_note_data_cache` uses manual tracking for subscriber-based per-entry LRU eviction. The IDF denominator (document frequency per tag) can be replaced with `tree:query("").tag_file_counts[tag]`, and total document count with `tree:query("").file_count`. This eliminates the need for `_idf_cache`, `_idf_file_tags`, and their incremental update logic. The scoring functions (`score_tags` line 231, `score_frontmatter` line 285 with FM_FIELDS weights {type=1.0, project=1.5, domain=1.0, status=0.3} (lines 252-257), `score_colinks` line 310, `score_link_proximity` line 338, `score_temporal` line 392) and the multi-signal weighting (tags=3.0, fm=2.0, colinks=2.5, link_1hop=5.0, link_2hop=2.0, temporal=1.0, max_2hop_bridges=5, from `get_weights()` line 500, overridable via `config.connections.weights`) remain unchanged. Subscriber-based tiered invalidation (`on_index_update` line 1048) handles full/additive/partial tiers with interest declarations for `{ "tags", "outlinks", "frontmatter", "aliases" }` (lines 1085-1090).
- **graph.lua** — Does not directly call `idx:file_count()`. BFS node counting in `bfs.lua` uses a running `node_count` (line 133, initialized from `opts.initial_count or 0`) with three hard-stop checks at lines 66, 73, 92 and a main loop guard at line 145 (`while head <= tail and node_count < max_nodes`). Truncation is recorded at line 162. `graph.lua` checks truncation status at lines 315-318 from `config.graph.max_nodes` (default 50). No changes needed for graph — the existing patterns are already efficient. The summary tree would only add value here for scoped file counts in filtered graph views (e.g., `tree:query("projects/").file_count`).

## Implementation Steps

### Step 1: Create `lua/andrew/vault/summary_tree.lua`

```lua
local M = {}
local log = require("andrew.vault.vault_log").scope("summary_tree")

--- @class SummaryNode
--- @field path string
--- @field is_leaf boolean
--- @field file_count number
--- @field tag_counts table<string, number>
--- @field tag_file_counts table<string, number>
--- @field fm_key_counts table<string, number>
--- @field task_count number
--- @field task_status_counts table<string, number>
--- @field link_count number
--- @field heading_count number
--- @field alias_count number
--- @field block_id_count number
--- @field children table<string, SummaryNode>|nil

local SummaryTree = {}
SummaryTree.__index = SummaryTree

function M.new()
  local self = setmetatable({}, SummaryTree)
  self.root = M._make_dir_node("")
  return self
end

function M._make_dir_node(path)
  return {
    path = path,
    is_leaf = false,
    file_count = 0,
    tag_counts = {},
    tag_file_counts = {},
    fm_key_counts = {},
    task_count = 0,
    task_status_counts = {},
    link_count = 0,
    heading_count = 0,
    alias_count = 0,
    block_id_count = 0,
    children = {},
  }
end
```

### Step 2: Implement path splitting and node traversal

```lua
--- Split a relative path into directory segments and filename.
--- "daily/2024-01-01.md" -> {"daily"}, "2024-01-01.md"
--- "projects/alpha/notes.md" -> {"projects", "alpha"}, "notes.md"
local function split_path(rel_path)
  local segments = {}
  for seg in rel_path:gmatch("([^/]+)") do
    segments[#segments + 1] = seg
  end
  local filename = table.remove(segments)
  return segments, filename
end

--- Ensure all directory nodes along the path exist, return the parent dir node.
function SummaryTree:_ensure_dirs(segments)
  local node = self.root
  for _, seg in ipairs(segments) do
    if not node.children[seg] then
      local dir_path = node.path == "" and seg .. "/" or node.path .. seg .. "/"
      node.children[seg] = M._make_dir_node(dir_path)
    end
    node = node.children[seg]
  end
  return node
end
```

### Step 3: Implement update_file

```lua
--- Update or insert a file's summary in the tree.
--- @param rel_path string  Relative file path (e.g. "daily/2024-01-01.md")
--- @param entry table  Vault index entry for this file (from self.files[rel_path])
function SummaryTree:update(rel_path, entry)
  local segments, filename = split_path(rel_path)
  if not filename then
    log.warn("update called with directory path: " .. rel_path)
    return
  end

  local parent = self:_ensure_dirs(segments)
  local summary = entry_to_summary(entry)
  summary.path = rel_path
  summary.is_leaf = true
  summary.children = nil
  parent.children[filename] = summary

  -- Propagate summaries up to root
  self:_recompute_ancestors(segments)
end
```

### Step 4: Implement remove

```lua
--- Remove a file from the tree.
--- @param rel_path string
function SummaryTree:remove(rel_path)
  local segments, filename = split_path(rel_path)
  if not filename then return end

  local parent = self:_ensure_dirs(segments)
  if not parent.children[filename] then return end

  parent.children[filename] = nil
  self:_recompute_ancestors(segments)

  -- Prune empty directory nodes upward
  self:_prune_empty(segments)
end
```

### Step 5: Implement ancestor recomputation

```lua
--- Recompute summaries for all ancestor directory nodes of a path.
--- Walks from deepest directory up to root.
function SummaryTree:_recompute_ancestors(segments)
  -- Build list of nodes from root to deepest dir
  local path_nodes = { self.root }
  local node = self.root
  for _, seg in ipairs(segments) do
    node = node.children[seg]
    if not node then return end
    path_nodes[#path_nodes + 1] = node
  end

  -- Recompute bottom-up
  for i = #path_nodes, 1, -1 do
    local dir_node = path_nodes[i]
    local composed = compose_summaries(dir_node.children)
    dir_node.file_count = composed.file_count
    dir_node.tag_counts = composed.tag_counts
    dir_node.tag_file_counts = composed.tag_file_counts
    dir_node.fm_key_counts = composed.fm_key_counts
    dir_node.task_count = composed.task_count
    dir_node.task_status_counts = composed.task_status_counts
    dir_node.link_count = composed.link_count
    dir_node.heading_count = composed.heading_count
    dir_node.alias_count = composed.alias_count
    dir_node.block_id_count = composed.block_id_count
  end
end
```

### Step 6: Implement query

```lua
--- Query aggregate summary for a directory prefix.
--- @param dir_prefix string  e.g. "daily/", "projects/alpha/", or "" for whole vault
--- @return SummaryNode|nil
function SummaryTree:query(dir_prefix)
  if dir_prefix == "" then
    return self:_snapshot(self.root)
  end

  -- Navigate to the target directory node
  local segments = {}
  for seg in dir_prefix:gmatch("([^/]+)") do
    segments[#segments + 1] = seg
  end

  local node = self.root
  for _, seg in ipairs(segments) do
    node = node.children and node.children[seg]
    if not node then return nil end
  end

  return self:_snapshot(node)
end

--- Return a shallow copy of a node's summary fields (no children reference).
function SummaryTree:_snapshot(node)
  return {
    path = node.path,
    file_count = node.file_count,
    tag_counts = vim.deepcopy(node.tag_counts),
    tag_file_counts = vim.deepcopy(node.tag_file_counts),
    fm_key_counts = vim.deepcopy(node.fm_key_counts),
    task_count = node.task_count,
    task_status_counts = vim.deepcopy(node.task_status_counts),
    link_count = node.link_count,
    heading_count = node.heading_count,
    alias_count = node.alias_count,
    block_id_count = node.block_id_count,
  }
end
```

### Step 7: Integrate into vault_index.lua

The current mutation path is `_apply_staged(staged, deleted, old_entries, changed_rel_paths, is_cold_start)` (lines 523-618), which atomically applies entries from `staged` (lines 525-529) and removes entries in `deleted` (lines 533-537). After mutations, it rebuilds/updates derived indexes (ordering differs by path):
- **Cold start** (lines 541-544): `_rebuild_name_index()` → `_recompute_inlinks()` → `_rebuild_precomputed_sets()`
- **Non-cold** (lines 546-555): `_update_name_index_incremental()` → `_update_precomputed_sets_incremental()` (guarded by `#changed_rel_paths > 0 or #deleted > 0`) → `_recompute_inlinks_incremental()` (with fallback to full `_recompute_inlinks()` when `_inlinks` is nil/empty, line 550)

Then:
1. Set `_ready = true`, `_building = false` (lines 557-558)
2. Persist scheduling (lines 559-562)
3. Tiered invalidation context building (lines 565-601) — computes `change_types` by diffing old vs new entries
4. Incremental aggregate update, gated: `config.invalidation.enable_tiered` AND batch ≤ `config.invalidation.partial_file_threshold` (default 50) (lines 604-609)
5. `_notify_update()` which increments `_generation` (lines 611-617)

The summary tree should be updated within this function after entries are written to `self.files`, replacing step 4:

```lua
-- In vault_index.lua, within _apply_staged():
-- After: self.files[rel_path] = entry (for staged entries, line 529)
self._summary_tree:update(rel_path, entry)

-- After: self.files[rel_path] = nil (for deleted entries, line 536)
self._summary_tree:remove(rel_path)

-- Replace _ensure_aggregates() callers with tree queries:
function M.VaultIndex:tags_with_counts()  -- was line 1910
  return self._summary_tree:query("").tag_counts
end

function M.VaultIndex:all_tags()  -- was line 1889
  local counts = self._summary_tree:query("").tag_counts
  local tags = vim.tbl_keys(counts)
  table.sort(tags)
  return tags
end

function M.VaultIndex:all_frontmatter_keys()  -- was line 1903
  local counts = self._summary_tree:query("").fm_key_counts
  local keys = vim.tbl_keys(counts)
  table.sort(keys)
  return keys
end

-- file_count() can remain as-is (already O(1) via _file_count counter, line 1975)
-- or optionally: return self._summary_tree:query("").file_count

-- _name_index, _alias_index, _inlinks remain separately maintained
-- (they are lookup tables, not aggregates — the tree doesn't help here)
```

**What gets removed**: `_ensure_aggregates()` (lines 1787-1872), `_update_aggregates_incremental()` (lines 1316-1619), and the cache fields `_aggregates_gen` (line 194), `_cached_tag_counts`, `_cached_tags`, `_cached_fm_keys`, `_cached_fm_key_counts`, `_cached_aliases`, `_cached_sorted_names`, `_cached_name_cache` (lines 195-201). Also the conditional guard at lines 604-609 in `_apply_staged()`.

**What remains unchanged**: `_rebuild_name_index()` (line 1099), `_update_name_index_incremental()` (line 1123), `_recompute_inlinks()` (line 1281), `_recompute_inlinks_incremental()` (line 1725), `_rebuild_precomputed_sets()` (line 1635), `_update_precomputed_sets_incremental()` (line 1669), `_file_count` (line 177), `_files_with_tags`, `_files_with_tasks`, `_files_by_type`, `_tag_blooms` (rebuilt in precomputed sets). Also unchanged: tiered invalidation context building (lines 565-601), subscriber notification via `_notify_update()` (lines 611-617), and the `config.invalidation` gating.

### Step 8: Add pruning for empty directory nodes

```lua
--- Remove empty directory nodes upward from the deepest segment.
function SummaryTree:_prune_empty(segments)
  local path_nodes = { self.root }
  local node = self.root
  for _, seg in ipairs(segments) do
    node = node.children and node.children[seg]
    if not node then break end
    path_nodes[#path_nodes + 1] = node
  end

  for i = #path_nodes, 2, -1 do
    local dir_node = path_nodes[i]
    if dir_node.file_count == 0 and not dir_node.is_leaf then
      local parent = path_nodes[i - 1]
      local seg = segments[i - 1]
      parent.children[seg] = nil
    else
      break  -- Stop pruning if a node still has content
    end
  end
end
```

### Step 9: Integrate into stats.lua

`M.compute(idx)` (lines 41-230) is currently stateless and uncached — it recomputes all 20 fields from scratch on every call. It can be split into tree-served aggregates and iterative-only computations:

```lua
function M.compute(idx)
  local tree = idx._summary_tree
  local root = tree:query("")

  -- These come directly from the tree (O(1)):
  local total_notes = root.file_count
  local total_outlinks = root.link_count
  local total_headings = root.heading_count
  local total_aliases = root.alias_count
  local total_block_ids = root.block_id_count
  local task_total = root.task_count
  local task_counts = root.task_status_counts  -- keyed by task.status char
  local tag_file_counts = root.tag_file_counts
  local fm_key_counts = root.fm_key_counts

  -- Scoped queries — folder_counts from tree root children (O(C_root)):
  -- stats.lua currently extracts top-level dir via entry.folder:match("^([^/]+)")
  -- Tree root children map directly to top-level dirs
  local folder_counts = {}
  for name, child in pairs(tree.root.children) do
    if not child.is_leaf then
      folder_counts[name] = child.file_count
    else
      -- Root-level files go to "(root)" bucket
      folder_counts["(root)"] = (folder_counts["(root)"] or 0) + 1
    end
  end

  -- These still require per-entry iteration:
  -- - broken_link_count/broken_link_notes: requires idx:resolve_name() per outlink (lines 98-119)
  -- - orphan_count/orphan_pct: requires _inlinks[rel_path] check per file (lines 92-95)
  -- - top_connected: requires degree = in_count + out_count per file (lines 87-90, 187-197)
  -- - total_inlinks: requires sum across inlinks table (lines 203-206)
  -- - type_counts: requires entry.frontmatter.type per file (lines 141-147)
  -- - month_counts: requires entry.day or entry.ctime per file (lines 159-169)
  -- - avg_tags: uses total_tags_refs (sum of tag references, not unique) / total_notes
  local files = idx:snapshot_files()
  local inlinks = idx._inlinks
  -- ... (iterate for link resolution, inlink checks, month_counts, type_counts)
end
```

### Step 10: Integrate into connections.lua

Replace the `_idf_cache` / `_idf_file_tags` / `build_tag_idf()` / `update_tag_idf_incremental()` infrastructure:

```lua
-- Replace ensure_idf(files, gen) (lines 721-735) with:
function ensure_idf(idx)
  local root = idx._summary_tree:query("")
  return root.tag_file_counts, root.file_count
end

-- In score_tags() (line 231), the IDF lookup becomes:
-- local df = tag_file_counts[tag] or 0
-- local tag_idf = math.log(total / math.max(df, 0.1))
-- (clamped to min 0.1 at line 239 to avoid log(1)=0 for unique tags)
```

This eliminates `_idf_cache` (line 47), `_idf_gen` (line 49), `_idf_total` (line 48), `_idf_file_tags` (line 50), `build_tag_idf()` (lines 147-161), and `update_tag_idf_incremental()` (lines 165-221) from connections.lua. The `_pending_changed` (line 64) / `_pending_full_clear` (line 65) subscriber-based tiered invalidation (full/additive/partial tiers via `on_index_update` line 1048) and `_note_data_cache` (weighted LRU lines 56-60, max bytes from `config.cache.note_data_bytes`, max items from `config.cache.note_data_max`, with `weighers.note_data`) remain unchanged — those handle per-note scoring data (`ConnectionNoteData`: rel_path, tags, outlink_targets, inlink_sources, neighbors, fm_fields, ctime, mtime), not aggregate frequencies. The subscriber's additive tier (line 1061) currently resets `_idf_gen = 0` to trigger incremental IDF — with the tree, this logic simplifies to a no-op since tree is always current.

## API

```lua
local summary_tree = require("andrew.vault.summary_tree")

local tree = summary_tree.new()

-- Update from vault index entries (entry from self.files[rel_path])
tree:update("daily/2024-01-01.md", { tags = { "journal" }, tasks = { { status = " " }, { status = "x" }, { status = " " } }, outlinks = { {}, {}, {}, {}, {} }, headings = { {} }, aliases = {}, block_ids = {}, frontmatter = { type = "daily", date = "2024-01-01" } })
tree:update("daily/2024-01-02.md", { tags = { "journal", "review" }, tasks = { { status = " " } }, outlinks = { {}, {} }, headings = { {}, {} }, aliases = { "jan-2" }, block_ids = { { id = "blk-abc123" } }, frontmatter = { type = "daily" } })

-- Remove a deleted file
tree:remove("daily/old-note.md")

-- Query a directory scope
local daily_summary = tree:query("daily/")
-- { file_count = 2, tag_counts = { journal = 2, review = 1 }, tag_file_counts = { journal = 2, review = 1 },
--   fm_key_counts = { type = 2, date = 1 }, task_count = 4, task_status_counts = { [" "] = 3, ["x"] = 1 },
--   link_count = 7, heading_count = 3, alias_count = 1, block_id_count = 1 }

-- Query whole vault
local total = tree:query("")

-- Query non-existent directory
local missing = tree:query("nonexistent/")  -- nil
```

## Incremental Update

When a single file changes, the update cost is O(D) where D is the directory depth of that file (typically 1-3 levels). The process:

1. **Leaf update**: Recompute the leaf's summary from the new vault index entry. This is O(T + L + K) where T = tags, L = links, K = frontmatter keys in that one file.
2. **Ancestor propagation**: Walk up from the leaf's parent directory to the root, recomposing each directory's summary from its children. Each directory recomposition is O(C) where C = number of direct children.
3. **Total cost**: O(D * C_avg) per file change, where C_avg is the average number of siblings per directory level. For typical vault structures this is effectively O(1) compared to the previous O(N) full iteration.

Contrast with the current approach: `_ensure_aggregates()` iterates all N entries in `self.files` regardless of how many changed. The incremental path (`_update_aggregates_incremental()`) exists but uses reference counting that still touches all changed entries' old and new tag/key sets, and falls back to full rebuild for large batches. The summary tree's ancestor propagation is strictly cheaper because it only recomputes along the tree path, not across all entries.

### Batch Update Path

During initial index build (or rebuild via `_apply_staged` with `is_cold_start = true`), files are processed in batches via coroutine (batch size from `config.index.batch_size`, default 20). The summary tree can defer ancestor recomputation until the batch completes:

```lua
function SummaryTree:batch_begin()
  self._batch_dirty = {}
end

function SummaryTree:batch_update(rel_path, entry)
  -- Update leaf but track dirty ancestors instead of immediate recompute
  local segments, filename = split_path(rel_path)
  local parent = self:_ensure_dirs(segments)
  local summary = entry_to_summary(entry)
  summary.path = rel_path
  summary.is_leaf = true
  summary.children = nil
  parent.children[filename] = summary
  -- Mark ancestor chain as dirty
  for i = 1, #segments do
    self._batch_dirty[table.concat(segments, "/", 1, i)] = true
  end
  self._batch_dirty[""] = true  -- root always dirty
end

function SummaryTree:batch_end()
  -- Recompute all dirty nodes (deepest first)
  local sorted = vim.tbl_keys(self._batch_dirty)
  table.sort(sorted, function(a, b) return #a > #b end)
  for _, path in ipairs(sorted) do
    self:_recompute_node(path)
  end
  self._batch_dirty = nil
end
```

This integrates with `_apply_staged()` (lines 523-618): when `is_cold_start` is true (line 541) or the staged batch is large, use `batch_begin/batch_update/batch_end` instead of individual `update()` calls. The batch size aligns with `config.index.batch_size` (default 20) used by the coroutine-based async build. During cold start, `_apply_staged` calls `_rebuild_name_index()`, `_recompute_inlinks()`, and `_rebuild_precomputed_sets()` (lines 541-544) — the summary tree batch build would occur alongside these.

## Configuration

```lua
-- In config.lua (currently no M.summary_tree section exists).
-- Add alongside existing M.index (lines 340-384) and M.cache (lines 794-814) sections:
M.summary_tree = {
  enabled = true,  -- Set to false to fall back to _ensure_aggregates() (for debugging)
}
```

When `enabled = false`, `vault_index.lua` falls back to the existing `_ensure_aggregates()` and `_update_aggregates_incremental()` implementations (gated behind `config.invalidation.enable_tiered`). This allows A/B comparison and safe rollback. The existing `config.cache` section budgets 15 MB total across all caches (file_content=5MB, section_cache=2MB, section_outlinks=2MB, connections=3MB, note_data=2MB, bfs_traversal=1MB) — the summary tree's memory overhead (~1.7 MB estimate) fits within this budget philosophy.

## Expected Impact

| Operation | Before | After |
|---|---|---|
| Whole-vault tag counts (`tags_with_counts()`) | O(N) lazy rebuild via `_ensure_aggregates()` | O(1) cached tree root lookup |
| Scoped file count (e.g. `tree:query("daily/")`) | Not available (would require O(N) + filter) | O(D) tree traversal |
| Single file update aggregation | O(N) rebuild or O(changed) incremental | O(D * C_avg) propagation |
| Stats display refresh (`stats.compute()`) | O(N) full iteration | O(1) for counts + O(N_links) for broken/orphan detection |
| Connection scoring IDF (`ensure_idf()`) | O(N) `build_tag_idf()` or O(changed) incremental | O(1) tree root lookup |
| Folder-level counts | O(N) iteration + filter | O(1) per folder from tree children |
| `all_tags()` sorted | O(N) rebuild + sort | O(T) sort from tree root tag_counts keys |
| `all_frontmatter_keys()` sorted | O(N) rebuild + sort | O(K) sort from tree root fm_key_counts keys |

For a 5,000-file vault with average directory depth of 2 and 20 children per directory, single-file update goes from ~5,000 iterations to ~40 operations (2 levels * 20 children recomposition).

**Already O(1) (no change needed)**: `vault_index:file_count()` (cached `_file_count` counter), graph BFS node counting (running counter with early termination).

## Trade-offs

- **Memory overhead**: Each directory node stores `tag_counts`, `tag_file_counts`, `fm_key_counts`, and `task_status_counts` tables that duplicate information derivable from children. For a vault with 500 unique tags, 50 frontmatter keys, 5 task states, and 100 directories, this adds roughly 100 * (500 + 500 + 50 + 5) * 16 bytes = ~1.7 MB. Acceptable given `config.cache` already budgets 15 MB across all caches.
- **Complexity of path splitting**: Every update must split the relative path into segments and walk the tree. This is simple string processing but adds a constant factor to every file update.
- **Tag count accuracy**: Tag counts are maintained as integers. If a file changes from having tag "foo" twice to once, the tree must correctly compute the delta. Using `entry_to_summary()` (which counts from scratch) and full recomposition at each ancestor level ensures correctness without delta tracking.
- **tag_counts vs tag_file_counts**: `tag_counts` sums total tag references (a file with `#journal` twice counts 2). `tag_file_counts` counts files containing each tag (same file counts 1). Both are needed: `tag_counts` for `tags_with_counts()`, `tag_file_counts` for IDF computation in connections.lua.
- **No persistence**: The summary tree is rebuilt from `self.files` (loaded from `{vault_path}/.vault-index/index.json` + WAL replay) on startup during `load()`. Since it derives entirely from `self.files`, persisting it separately would be redundant. The rebuild cost during `load()` is O(N) once, same as current `_ensure_aggregates()`.
- **Non-aggregate queries remain iterative**: Broken link detection (requires `idx:resolve_name()` with basename-first then full-name fallback), orphan detection (requires `_inlinks` lookup per file), connectivity scoring (requires per-file `degree = in_count + out_count`), type distribution (requires `entry.frontmatter.type`), and month-based activity (requires `entry.day` or `entry.ctime` fallback) cannot be served by the summary tree and remain O(N) in `stats.compute()`.
- **sorted_names and name_cache**: `get_name_cache()` (line 1876) and `sorted_names()` (line 1883) return sorted lists of filenames/paths — these are lookup-table derivatives built from `_name_index`, not aggregate sums. They continue to use the existing `_name_index` infrastructure rather than the summary tree. `all_aliases()` (line 1896) similarly returns a sorted list maintained via binary insert/remove in `_update_aggregates_incremental`.
- **Directory rename**: Moving files between directories requires remove + update for each file. Bulk moves should use the batch API to avoid redundant recomputation.
- **Precomputed sets independence**: `_rebuild_precomputed_sets()` (line 1635) / `_update_precomputed_sets_incremental()` (line 1669) build `_files_with_tags`, `_files_with_tasks`, `_files_by_type`, and `_tag_blooms` — these are per-file membership sets, not aggregates, and remain independent of the summary tree. They are updated in `_apply_staged()` at lines 544/548.
- **Snapshot consistency**: `stats.compute()` uses `idx:snapshot_files()` which returns a live reference or shallow copy depending on `config.index.use_snapshots`. The summary tree is always current (updated inline in `_apply_staged()`), so tree queries and iterative passes over `snapshot_files()` may observe slightly different states if snapshots are disabled and a concurrent update occurs. This is acceptable since both paths converge after `_notify_update()`.
