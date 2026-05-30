# 17 — Snapshot-Based Index Reads

## Priority: LOW
## Inspired By: Zed's `Snapshot`, `BufferSnapshot` in `crates/worktree/`, `crates/language/`

## Problem

The vault index is mutated in-place during async builds. While the coroutine-based
`build_async()` (in `vault_index_build.lua`) yields between batches, each batch directly
modifies `index.files` and `index._file_count`. Derived indexes (`_name_index`,
`_alias_index`, `_inlinks`, `_files_with_tags`, `_files_with_tasks`, `_files_by_type`,
`_tag_blooms`) are only rebuilt **after all batches complete**. Code reading the index
during a build may see partially-updated state:

### Race Window

```
Time →
  T0: index.files has 10,000 entries (consistent with derived indexes)
  T1: build_async starts, processes batch 1 (config.index.batch_size files)
      → Deletes entries via index.files[rel_path] = nil  (line 62, build.lua)
      → Replaces entries via index.files[rel_path] = entry (line 80, build.lua)
      → _name_index, _alias_index, _inlinks UNCHANGED (stale)
  T2: coroutine.yield() → event loop runs  (line 101, build.lua)
      → User triggers search → search_filter.evaluate() iterates index.files
      → Sees updated files table but stale _name_index
      → wikilinks.resolve_link() via _name_index may fail for renamed files
      → search pre-filter checks (_files_with_tags, _tag_blooms) are stale
  T3: build_async resumes, processes batch 2
      → More files mutated in index.files
  T4: build complete → derived indexes rebuilt (incremental or full)
      → _notify_update() increments _generation (single bump)
      → All consistent again
```

### Current Mitigations (Actual Codebase State)

The vault has several existing consistency mechanisms, but they address **cache staleness**
rather than **mid-build inconsistency**:

#### 1. Generation Counter (`_generation`)
- Defined in `vault_index.lua` as a field on `VaultIndex` (initialized to 0)
- Incremented only in `_notify_update()` (line 224) — called **once per build** (without context
  in `build_async()` line 132) or per-batch in `update_files_batch()` (line 235, with context)
- Used by consumers for cache invalidation:
  - `completion_base.lua:215` — `if idx._generation ~= _cached_gen then return false`
  - `completion_base.lua:482` — generation-keyed memoization in `build_kv_single_pass()`
  - `search/live.lua:62` — `local cur_gen = idx._generation` for incremental cache
  - `connections.lua:68-72` — `get_vault_index()` returns `idx._generation or 0` for cache TTL validation
  - `connections.lua:715-724` — generation + timestamp TTL for result caching in `compute()`

#### 2. Key Snapshot in Completion (completion.lua:221-226)
```lua
-- Snapshot the files table keys so the iterator is safe against
-- concurrent index mutations.
local keys = {}
for rel_path in pairs(idx.files) do
  keys[#keys + 1] = rel_path
end
```
This is the **only explicit key snapshot** — it snapshots keys but still accesses
entries lazily from the live table (`idx.files[rel_path]` at line 244), with nil-check
for entry removal detection.

#### 3. Reference Snapshot in Connections (connections.lua:688)
```lua
local files = vi.files
```
`prepare_compute()` captures a reference to the files table at line 688, stored in the
state object (`s.files`), and iterated at line 735 in `compute()`. This provides iterator
stability but does **not** protect against entry mutation/removal during scoring.

#### 4. Subscriber Pattern (connections.lua)
Uses `cleanup.subscription_handle()` wrapping `on_index_update` (lines 956-958) for targeted
cache invalidation instead of polling. The subscriber (`on_index_update`, lines 935-953)
receives context with `changed_paths`/`deleted_paths` from `update_files_batch()` (line 235),
but receives **no context** from `build_async()` (line 132), triggering a full cache clear
(via `_pending_full_clear = true` at line 938-941).

#### 5. Old Entry Capture (vault_index_build.lua:45-54)
Before mutations begin, `build_async()` captures old entries:
```lua
local old_entries = {}
if not is_cold_start then
  for _, file in ipairs(changed) do
    old_entries[file.rel_path] = index.files[file.rel_path]
  end
  for _, rel_path in ipairs(deleted) do
    old_entries[rel_path] = index.files[rel_path]
  end
end
```
This enables incremental derived index rebuilding, but does **not** protect readers.

### Consumer Read Patterns (Current State)

| Module | Direct `index.files` Iteration | Snapshot | Generation Check |
|--------|-------------------------------|----------|-----------------|
| `search_filter.lua:401,422,457` | Yes (`for rel_path, entry in pairs(files)` at 422; async batched via `yield_iter.filter_yielding()` at 457) | No | Indirect (section cache invalidation via `match_field_mod` at 396) |
| `search_filter.lua:317-378` | Pre-checks: `_tag_blooms` (317/325), `_files_by_type` (334/336), `_files_with_tags` (346/348), `_files_with_tasks` (356/358, 370/372) | No | No |
| `search/live.lua:145` | Yes (`build_restrict_to()`) | No | Yes (line 62: `idx._generation` via `filter_utils.is_cache_gen_valid()`) |
| `search/advanced.lua:88-90` | Yes (`collect_abs_paths()`) | No | Local `_search_generation` only (line 16, race guard at 41) |
| `connections.lua:688,735` | Yes (in `compute()` via `s.files`) | **Yes (reference)** at line 688 | Yes (cache TTL at 715-724 + subscriber at 956-958) |
| `completion.lua:221-226` | Keys only | **Yes (keys)** | Yes (via completion_base) |
| `completion_base.lua:515` | Yes (`build_kv_single_pass()`) | No | Yes (line 482: gen-keyed memoization) |
| `filter_utils.lua:84` | Yes (`idx.files[lower..".md"]`) | No | No |
| `wikilinks.lua` | No (delegates to link_utils at 169) | N/A | Readiness check (lines 174-179) |

**Key observation:** `completion.lua` takes a key snapshot (lines 221-226) and `connections.lua`
captures a table reference (line 688), but neither protects against mid-build inconsistency
between `files` and derived indexes. All other modules iterate the live `index.files` table
directly. Additionally, `match_has.lua` (lines 17-18, 28-29) accesses `_files_with_tags`
and `_files_with_tasks` directly from the index during per-entry matching.

### Zed's Snapshot Approach

Zed creates immutable snapshots of data structures, replacing them wholesale rather than
mutating in-place:

#### WorktreeSnapshot (`crates/worktree/src/worktree.rs`)

```rust
// Lines 158-179: Snapshot struct with Arc-based SumTree fields
#[derive(Clone)]
pub struct Snapshot {
    id: WorktreeId,
    abs_path: SanitizedPath,
    root_name: String,
    root_char_bag: CharBag,
    entries_by_path: SumTree<Entry>,  // SumTree wraps Arc<Node<T>> — cheap clone
    entries_by_id: SumTree<PathEntry>,
    always_included_entries: Vec<Arc<Path>>,
    scan_id: usize,           // Increments on each scan start
    completed_scan_id: usize, // Only advances when scan completes
}

// Lines 720-725: Snapshot creation on Worktree enum — dispatches to local or remote
pub fn snapshot(&self) -> Snapshot {
    match self {
        Worktree::Local(worktree) => worktree.snapshot.snapshot.clone(),
        Worktree::Remote(worktree) => worktree.snapshot.clone(),
    }
}

// Lines 1316-1338: Wholesale replacement (never in-place mutation)
fn set_snapshot(
    &mut self,
    mut new_snapshot: LocalSnapshot,
    entry_changes: UpdatedEntriesSet,
    cx: &mut Context<Worktree>,
) {
    let repo_changes = self.changed_repos(&self.snapshot, &mut new_snapshot);
    self.snapshot = new_snapshot;  // Wholesale replacement
    // ... send to update_observer, emit UpdatedEntries/UpdatedGitRepositories events
}
```

**Key design:** Background scanner (`BackgroundScanner`, lines 3802-3815) maintains state in a
`Mutex<BackgroundScannerState>` (lines 370-382) which holds a `LocalSnapshot`. The scanner
calls `send_status_update()` (lines 4226-4250) to clone the snapshot and send it via
`status_updates_tx` as `ScanState::Updated`. The main actor receives this (lines 1296-1310)
and calls `set_snapshot()` to swap atomically. All existing snapshot clones remain valid
(they share old Arc nodes).

#### BufferSnapshot (`crates/language/src/buffer.rs`)

```rust
// Lines 145-153: Snapshot struct
pub struct BufferSnapshot {
    pub text: text::BufferSnapshot,     // Rope with Arc-shared chunks
    pub(crate) syntax: SyntaxSnapshot,  // SumTree layers + version vectors
    file: Option<Arc<dyn File>>,        // Arc — cheap clone
    diagnostics: SmallVec<[(LanguageServerId, DiagnosticSet); 2]>,
    remote_selections: TreeMap<ReplicaId, SelectionSet>,
    language: Option<Arc<Language>>,     // Arc — cheap clone
    non_text_state_update_count: usize,  // Version counter for non-text state
}

// Lines 1041-1056: Snapshot creation
pub fn snapshot(&self) -> BufferSnapshot {
    let text = self.text.snapshot();
    let mut syntax_map = self.syntax_map.lock();
    syntax_map.interpolate(&text);  // Sync syntax with text state
    let syntax = syntax_map.snapshot();
    BufferSnapshot { text, syntax, file: self.file.clone(), /* ... */ }
}
```

**Key insight:** Buffer mutates freely; snapshots capture immutable views at a point in time.
The `non_text_state_update_count` counter tracks non-text mutations (language, file, diagnostics).

**Two-level version tracking:** Zed uses `scan_id` (started) + `completed_scan_id` (finished)
for worktrees — `scan_id` increments on each filesystem scan start (line 3963), while
`completed_scan_id` only advances when a scan completes (lines 3869, 4121). The difference
signals "scan in progress" (`is_last_update: self.completed_scan_id == self.scan_id` at
lines 2390, 2725). For buffers, Zed uses `non_text_state_update_count` +
`clock::Global` version vectors.

## Proposed Solution

### 1. Index Snapshot Mechanism

Add snapshot capability to `vault_index.lua`. The snapshot must include **all fields
that consumers read**, including precomputed sets used by `search_filter.lua`:

```lua
--- @class IndexSnapshot
--- @field files table<string, VaultIndexEntry> Frozen copy of files
--- @field _name_index table<string, string[]> Frozen name index
--- @field _alias_index table<string, string[]> Frozen alias index
--- @field _inlinks table<string, table[]> Frozen inlinks
--- @field _files_with_tags table<string, boolean> Frozen tag presence set
--- @field _files_with_tasks table<string, boolean> Frozen task presence set
--- @field _files_by_type table<string, table<string, boolean>> Frozen type index
--- @field _tag_blooms table<string, table<integer, boolean>> Frozen bloom filters
--- @field _generation number Generation at snapshot time
--- @field _file_count number File count at snapshot time

--- Create an immutable snapshot of the current index state.
--- Snapshot shares entry *references* (not deep copies) — entries
--- themselves are replaced (not mutated) during index updates.
---
--- @return IndexSnapshot
function VaultIndex:snapshot()
  -- Shallow copy of files table — O(N) but entries are shared references
  local files_snap = {}
  for k, v in pairs(self.files) do
    files_snap[k] = v  -- Share entry reference (not deep copy)
  end

  return {
    files = files_snap,
    _name_index = self._name_index,         -- Share reference (rebuilt atomically)
    _alias_index = self._alias_index,       -- Share reference (rebuilt atomically)
    _inlinks = self._inlinks,               -- Share reference (rebuilt atomically)
    _files_with_tags = self._files_with_tags,     -- Share reference
    _files_with_tasks = self._files_with_tasks,   -- Share reference
    _files_by_type = self._files_by_type,         -- Share reference
    _tag_blooms = self._tag_blooms,               -- Share reference
    _generation = self._generation,
    _file_count = self._file_count,
  }
end
```

**Memory cost:** Only the files table shell is copied (~80 bytes per entry for key + pointer).
For 10K files: ~800 KB per snapshot. Entries and derived index tables are shared references.

**Why derived indexes can be shared by reference:** `_rebuild_name_index()` (vault_index.lua:715-728)
already builds new tables in locals (`name_idx`, `alias_idx` at lines 716-717) then assigns
atomically to `self._name_index`/`self._alias_index` (lines 723-724). Similarly,
`_rebuild_precomputed_sets()` (lines 888-916) builds four fresh local tables and assigns all
four at lines 912-915. The incremental methods (`_update_name_index_incremental` lines 739-793,
`_update_precomputed_sets_incremental` lines 922-973) do mutate existing tables in-place, but
these only run after all batches complete — the same point where `_generation` is bumped.

### 2. Atomic Entry Replacement (**Already Implemented**)

The current codebase **already** replaces entries rather than mutating them in-place.
In `vault_index_build.lua:80`:

```lua
index.files[file.rel_path] = entry  -- New entry from parser.parse_file()
```

And deletions at line 62:
```lua
index.files[rel_path] = nil
```

The `parser.parse_file()` always returns a fresh entry table. No code path mutates
existing entries in `index.files`. **This prerequisite is already satisfied.**

The key invariant to maintain: entry objects must never be mutated after insertion
into `index.files`. Currently this holds because:
- `parse_file()` creates fresh tables
- `_apply_entry_mt()` (vault_index.lua:187-189) sets a metatable for lazy derived fields
  via `rawset()` (first access only — doesn't mutate observable state)
- No other code path mutates entry fields after insertion

### 3. Snapshot-Based Search

Use snapshots in `search_filter.lua` for consistent reads during evaluation:

```lua
-- In search_filter.lua, modify prepare_evaluate() (line 395, local function):
local function prepare_evaluate(ast, index, graph_sets, restrict_to)
  match_field_mod.maybe_invalidate_section_cache(index)
  if not index or not index.files then return nil end

  -- Take snapshot at start of evaluation for consistent reads.
  -- If restrict_to is provided, it's already a separate table.
  local snap = restrict_to and index or index:snapshot()
  local files = restrict_to or snap.files

  local ctx = M.build_filter_context(ast, snap)
  local pre_checks = extract_pre_checks(ast, snap, ctx)
  -- ... pre-checks use snap._tag_blooms, snap._files_by_type, etc.
end
```

Note: `extract_pre_checks()` (lines 302-384) accesses `index._tag_blooms` (line 317/325),
`index._files_by_type` (line 334/336), `index._files_with_tags` (line 346/348), and
`index._files_with_tasks` (line 356/358). These must come from the snapshot to ensure
consistency with the files table.

### 4. Lightweight Snapshot (Generation-Gated)

For most use cases, a full snapshot is overkill. A "generation guard" is sufficient:

```lua
--- @class GenerationGuard
--- @field _index VaultIndex
--- @field _generation number Expected generation

--- Create a generation guard (lightweight consistency check).
--- @return GenerationGuard
function VaultIndex:generation_guard()
  return {
    _index = self,
    _generation = self._generation,
  }
end

--- Check if index has changed since guard was created.
--- @param guard GenerationGuard
--- @return boolean still_valid
function M.is_valid(guard)
  return guard._generation == guard._index._generation
end
```

**Note:** Since `_generation` only increments once per build (in `_notify_update()`),
generation guards cannot detect mid-build inconsistency. They are useful for detecting
whether a **complete** build has occurred since the guard was created. For mid-build
safety, a full snapshot is needed.

### 5. Build-Phase Isolation (Staged Apply)

Currently, `build_async()` mutates `index.files` **during** batch processing (lines 56-84
of `vault_index_build.lua`), then rebuilds derived indexes after all batches. This creates
a window where `files` and derived indexes are inconsistent.

**Proposed change:** Stage mutations in a local table, apply atomically after all batches:

```lua
-- In vault_index_build.lua, modify build_async():
function B.build_async(index, callback)
  if index._building then return end
  index._building = true
  parser.reset_intern_pool()

  local start_time = vim.uv.hrtime()
  local is_cold_start = not index._ready

  local yield_iter = require("andrew.vault.yield_iter")
  yield_iter.run_async(function()
    local changed, deleted = index:_detect_changes()

    -- Capture old entries before processing (existing pattern, line 45-54)
    local old_entries = {}
    if not is_cold_start then
      for _, file in ipairs(changed) do
        old_entries[file.rel_path] = index.files[file.rel_path]
      end
      for _, rel_path in ipairs(deleted) do
        old_entries[rel_path] = index.files[rel_path]
      end
    end

    -- Stage changes in local tables instead of mutating index.files directly
    local staged = {}        -- rel_path → new entry
    local staged_deleted = {} -- list of rel_paths to remove

    -- Process deletions into staging
    for _, rel_path in ipairs(deleted) do
      if index.files[rel_path] ~= nil then
        staged_deleted[#staged_deleted + 1] = rel_path
      end
    end

    -- Process changed files in batches (yield between batches)
    local processed = 0
    local batch_count = 0
    local changed_rel_paths = {}
    for i = 1, #changed, config.index.batch_size do
      local batch_end = math.min(i + config.index.batch_size - 1, #changed)
      for j = i, batch_end do
        local file = changed[j]
        local entry = parser.parse_file(file.abs_path, file.rel_path, file.stat)
        if entry then
          index:_apply_entry_mt(entry)
          staged[file.rel_path] = entry  -- Stage, don't apply
          changed_rel_paths[#changed_rel_paths + 1] = file.rel_path
        end
        processed = processed + 1
      end
      batch_count = batch_count + 1
      -- ... progress notification (unchanged) ...
      coroutine.yield()
    end

    -- Apply all changes atomically
    index:_apply_staged(staged, staged_deleted, old_entries,
                        changed_rel_paths, is_cold_start)

    -- ... completion notification, callback (unchanged) ...
  end, {
    on_error = function(err)
      index._building = false
      notify.error("index error: " .. err)
    end,
  })
end

function VaultIndex:_apply_staged(staged, deleted, old_entries, changed_rel_paths, is_cold_start)
  -- Apply staged entries
  for rel_path, entry in pairs(staged) do
    if self.files[rel_path] == nil then
      self._file_count = self._file_count + 1
    end
    self.files[rel_path] = entry
  end

  -- Remove deleted entries
  for _, rel_path in ipairs(deleted) do
    self._file_count = self._file_count - 1
    self.files[rel_path] = nil
  end

  -- Rebuild derived indexes (existing cold/warm logic)
  if is_cold_start then
    self:_rebuild_name_index()
    self:_recompute_inlinks()
    self:_rebuild_precomputed_sets()
  else
    if #changed_rel_paths > 0 or #deleted > 0 then
      self:_update_name_index_incremental(old_entries, changed_rel_paths, deleted)
      self:_update_precomputed_sets_incremental(old_entries, changed_rel_paths, deleted)
    end
    if not self._inlinks or not next(self._inlinks) then
      self:_recompute_inlinks()
    else
      self:_recompute_inlinks_incremental(changed_rel_paths, deleted)
    end
  end

  self._ready = true
  self._building = false
  self:_schedule_persist()
  -- NOTE: Current build_async (line 132) calls _notify_update() WITHOUT context.
  -- Only update_files_batch (line 235) passes context. The staged version should
  -- pass context so subscribers (connections.lua:935-953) can do targeted invalidation
  -- instead of falling back to full cache clear (via _pending_full_clear at line 938).
  self:_notify_update({ changed_paths = changed_rel_paths, deleted_paths = deleted })
end
```

**Key difference from current code:** During batch processing, `index.files` remains
unchanged. Readers see the previous consistent state. All mutations happen in the
`_apply_staged()` call, which runs synchronously (no yield) — making the update atomic
from the event loop's perspective. Additionally, passing context to `_notify_update()`
(which `build_async` currently omits at line 132) enables subscribers like
`connections.lua` to use targeted cache invalidation rather than full clears.

### 6. Derived Index Atomic Rebuild (**Partially Implemented**)

The full rebuild methods already follow the atomic pattern:

```lua
-- vault_index.lua:715-728 (_rebuild_name_index)
-- Builds name_idx and alias_idx in local variables (lines 716-717),
-- then assigns: self._name_index = name_idx (line 723)
-- This is already atomic — anyone holding the old reference sees consistent old state.

-- vault_index.lua:888-916 (_rebuild_precomputed_sets)
-- Builds four local tables (with_tags, with_tasks, by_type, tag_blooms),
-- then assigns all four atomically (lines 912-915).

-- vault_index.lua:856-859 (_recompute_inlinks)
-- Full rebuild: self._inlinks = inlinks_mod.recompute(...) — atomic assignment.
```

The **incremental** methods mutate existing tables in-place:
- `_update_name_index_incremental` (lines 739-793): Gets references to `self._name_index`
  and `self._alias_index`, removes old entries and adds new ones directly
- `_update_precomputed_sets_incremental` (lines 922-973): Directly mutates all four
  precomputed set tables via `self._files_with_tags[rel_path] = nil/true`, etc.
- `_recompute_inlinks_incremental` (lines 975-982): Delegates to `inlinks_mod.recompute_incremental()`
  which mutates the existing `self._inlinks` table

This is safe **only if** they run synchronously (no yield), which they do — they're
called after all batches complete (lines 104-127 of build.lua).

With staged builds (Section 5), incremental methods run inside `_apply_staged()` which
is also synchronous, preserving safety.

## Configuration

**Current state:** Neither `staged_builds` nor `use_snapshots` exist in `config.lua`.
The `M.index` section (lines 362-400) currently has: `skip_dirs`, `batch_size` (20),
`persist_debounce_ms` (5000), `persist_min_interval_ms` (10000), `watch` (true),
`watch_debounce_ms` (500), `warn_collisions`, `show_progress`, `progress_threshold`,
`collision_notify_ms`.

**Proposed additions:**
```lua
-- In config.lua, M.index section (after existing fields):
M.index.staged_builds = true,      -- Stage changes during build (Section 5)
M.index.use_snapshots = false,     -- Enable snapshot-based reads (Section 1/3)
```

Generation guards (Section 4) are zero-cost and can be always-on — no config needed.

## Zed Reference

### WorktreeSnapshot (`crates/worktree/src/worktree.rs`)

**Type definition (lines 158-179):**
```rust
#[derive(Clone)]
pub struct Snapshot {
    id: WorktreeId,
    abs_path: SanitizedPath,
    root_name: String,
    root_char_bag: CharBag,
    entries_by_path: SumTree<Entry>,   // SumTree(Arc<Node<T>>) — O(1) clone
    entries_by_id: SumTree<PathEntry>, // SumTree(Arc<Node<T>>) — O(1) clone
    always_included_entries: Vec<Arc<Path>>,
    scan_id: usize,                    // Increments on each scan start
    completed_scan_id: usize,          // Advances only when scan completes
}
```

**LocalSnapshot wrapper (lines 356-368):**
```rust
#[derive(Debug, Clone)]
pub struct LocalSnapshot {
    snapshot: Snapshot,
    ignores_by_parent_abs_path: HashMap<Arc<Path>, (Arc<Gitignore>, bool)>,
    git_repositories: TreeMap<ProjectEntryId, LocalRepositoryEntry>,
    root_file_handle: Option<Arc<dyn fs::FileHandle>>,
}
```
Implements `Deref` and `DerefMut` to the inner `Snapshot` (lines 436-448).

**Snapshot creation (lines 720-725 for Worktree enum):**
```rust
// Worktree enum (line 720) — dispatches to local or remote
pub fn snapshot(&self) -> Snapshot {
    match self {
        Worktree::Local(worktree) => worktree.snapshot.snapshot.clone(),
        Worktree::Remote(worktree) => worktree.snapshot.clone(),
    }
}
```

**SumTree internals (`sum_tree/src/sum_tree.rs:184`):**
`pub struct SumTree<T: Item>(Arc<Node<T>>)` — a single Arc wrapping the root node.
Internal `Node<T>` enum (lines 791-804) has `Internal` variant with
`child_trees: ArrayVec<SumTree<T>, { 2 * TREE_BASE }>` (recursive Arcs) and `Leaf` variant
with `items: ArrayVec<T, { 2 * TREE_BASE }>`. Cloning any SumTree only increments the Arc
reference count — O(1), not O(N).

**Wholesale replacement (lines 1316-1338):**
```rust
fn set_snapshot(&mut self, mut new_snapshot: LocalSnapshot, ...) {
    let repo_changes = self.changed_repos(&self.snapshot, &mut new_snapshot);
    self.snapshot = new_snapshot;  // Old snapshots remain valid via Arc sharing
    // ... send to update_observer, emit UpdatedEntries, UpdatedGitRepositories events
}
```

**Background scanner flow:**
1. `BackgroundScanner` (lines 3802-3815) holds `Mutex<BackgroundScannerState>` (lines 370-382)
2. State contains a `LocalSnapshot` that the scanner mutates during scanning
3. `send_status_update()` (lines 4226-4250) clones the snapshot, builds a diff via
   `build_diff()` against `prev_snapshot`, and sends `ScanState::Updated` through channel
4. Main actor receives (lines 1296-1310) and calls `set_snapshot()` to swap atomically
5. `scan_id` increments on scan start (line 3963); `completed_scan_id` catches up on
   completion (lines 3869, 4121)

**Key design pattern:** Background scanner builds entirely new snapshots. `set_snapshot()`
swaps atomically. All previously-cloned snapshots remain valid because SumTree nodes are
Arc-shared — old snapshot points to old Arc nodes, new snapshot has new nodes for changed
subtrees but shares unchanged nodes.

### BufferSnapshot (`crates/language/src/buffer.rs`)

**Type definition (lines 145-153):**
```rust
pub struct BufferSnapshot {
    pub text: text::BufferSnapshot,           // Rope with Arc-shared chunks
    pub(crate) syntax: SyntaxSnapshot,        // SumTree layers + version vectors
    file: Option<Arc<dyn File>>,              // Arc — cheap clone
    diagnostics: SmallVec<[(LanguageServerId, DiagnosticSet); 2]>,
    remote_selections: TreeMap<ReplicaId, SelectionSet>,
    language: Option<Arc<Language>>,           // Arc — cheap clone
    non_text_state_update_count: usize,        // Non-text state version counter
}
```

**Snapshot creation (lines 1041-1056):**
```rust
pub fn snapshot(&self) -> BufferSnapshot {
    let text = self.text.snapshot();
    let mut syntax_map = self.syntax_map.lock();
    syntax_map.interpolate(&text);  // Sync syntax with current text
    let syntax = syntax_map.snapshot();
    BufferSnapshot { text, syntax, file: self.file.clone(), /* ... */ }
}
```

**Consumer examples:**
1. **Outline extraction** (buffer.rs:3536-3539) — snapshot for syntax queries via `outline_items_containing()`
2. **Diff application** (buffer.rs:1847-1862) — snapshot as stable reference for background diff via `self.as_rope()`
3. **Autoindent tracking** (buffer.rs:2409) — `before_edit = self.snapshot()` stored for deferred computation
4. **Display map invalidation** (inlay_map.rs:543-544) — compares `non_text_state_update_count()`
   between old and new snapshots to detect non-text state changes and invalidate cached display maps

**`non_text_state_update_count` is incremented on:** `set_language()` (line 1231),
`update_file()` (line 1367), `did_finish_parsing()` (line 1549), `set_selections()`
(line 2184), `update_remote_selection()` (line 2217), and two `apply_operation()` paths
(lines 2590, 2635 — `Operation::UpdateSelections` and diagnostic update respectively).
Accessor at lines 4406-4408. This provides efficient change detection for non-text
mutations without comparing entire diagnostic sets or selection maps.

**Key insight:** Zed's snapshots are cheap because they share internal data via `Arc`.
In Lua, table references serve a similar purpose — a shallow copy of the files table
shares entry references, making snapshots O(N) in space but sharing the heavy per-entry data.
Derived indexes (name, alias, inlinks, precomputed sets) are shared by reference since
they're rebuilt atomically (not mutated in-place during builds).

## Expected Impact

| Issue | Before | After |
|-------|--------|-------|
| Mid-build `files` vs derived index inconsistency | Possible (files mutated per-batch, indexes rebuilt after) | Eliminated (staged apply in single synchronous pass) |
| Search during build | May see entries with stale `_name_index`, `_tag_blooms` | Consistent snapshot OR previous consistent state (staged) |
| Derived index inconsistency | Brief window during incremental rebuild (synchronous, low risk) | Same (incremental methods are already synchronous) |
| Generation bump granularity | Already per-build (single bump in `_notify_update()`) | Unchanged — already correct |
| Completion iterator safety | Key snapshot exists (`completion.lua:221-226`) | Formalized via `index:snapshot()` |

**Memory cost of snapshots:**
- Shallow copy of 10K files table: ~800 KB per snapshot
- Derived index references: ~0 bytes (shared references, not copies)
- Snapshots are short-lived (duration of search/query) → GC'd quickly
- At most 1-2 snapshots alive simultaneously

**Correctness improvement:** Eliminates a class of subtle bugs where search results
include entries from different "versions" of the index. The main practical risk today
is `search_filter.lua` iterating `index.files` while pre-filter checks use stale
precomputed sets during a build.

## Testing Strategy

1. Start `build_async()` on modified vault, run search mid-build — verify `search_filter.evaluate()`
   returns consistent results (no entries missing from derived indexes that exist in files)
2. Compare `evaluate(ast, index)` vs `evaluate(ast, index:snapshot())` — identical results
3. Rename a file during build — verify search doesn't show both old and new names
4. Profile snapshot creation: should be <1ms for 10K files
5. Monitor GC: snapshots should be collected after query completes
6. Verify staged build: add logging to confirm `index.files` unchanged during batch processing
7. Test existing key-snapshot in `completion.lua` still works with `index:snapshot()` API

## Dependencies

- Independent of other optimizations
- Complements doc 06 (Connections) — connections could use snapshots for consistent scoring
  (currently uses generation-based cache + subscriber pattern at `connections.lua:935-958`,
  plus a reference snapshot of `vi.files` at line 688)
- Complements doc 14 (Cooperative Yielding) — async evaluation benefits from consistent snapshots
- `completion.lua:221-226` already implements a partial snapshot (keys only) — would be
  replaced by `index:snapshot()` call

## Risk Assessment

- **Low risk:** Snapshot is read-only view, doesn't affect write path
- **Staged builds:** Medium risk — changes apply semantics shift from "progressive mutation"
  to "atomic swap". The `old_entries` capture (existing code, build.lua:45-54) already
  handles this correctly since it captures before any mutations
- **Generation guards:** Zero risk — purely informational check
- **Key constraint:** Entry objects must not be mutated in-place after insertion
  (replace with new object instead) — this invariant **already holds** in current code
  since `parser.parse_file()` always returns fresh tables
- **Migration path:**
  1. Start with staged builds (Section 5) — highest impact, eliminates mid-build inconsistency
  2. Add `snapshot()` API (Section 1) — enables consistent reads for search_filter, connections
  3. Adopt snapshots in consumers (Section 3) — search_filter, connections, completion
  4. Generation guards (Section 4) optional — useful for debugging, not strictly needed
