# 13 — Early Exit Pre-Filtering for Completion & Search

## Priority: MEDIUM
## Inspired By: Zed's `CharBag` in `crates/fuzzy/`, early exit patterns in search

## Problem

The vault's completion and search systems evaluate every candidate against the full
matching pipeline. For completion with 10K items or search over 10K index entries,
this means expensive operations (string matching, field extraction, scoring) run on
candidates that could be eliminated cheaply.

### Current Flow (Completion)

```
User types: "proj"
  → build_iter() yields up to 10,000 completion items (cached via completion_base.lua)
  → Items built via make_note_item() wrapper → base.make_item(label, insertText, filterText, kind, opts)
  → Each item has: label, insertText, filterText, sortText (mtime-derived), description (interned)
  → blink.cmp filters all 10,000 with fuzzy match against filterText
  → Result: ~50 matches displayed
  → Wasted: 9,950 items fully constructed and passed to blink.cmp but not shown
```

**Key files:**
- `completion.lua` — wikilink source, uses `build_iter` (coroutine path)
  - `make_note_item()` (lines 201-212) — wrapper that calls `base.make_item()` with interned description
  - `build_iter()` (lines 221-280) — stateless generator yielding primary notes + queued alias items
  - `get_completions()` (lines 282-392) — routes to block/heading/note completion modes
- `completion_base.lua` — `create_source` factory with debounce (`config.completion.debounce_ms`, default 250),
  cancellation (`active_state.cancelled` flag), coroutine chunking (`config.completion.batch_size`, default 50),
  adaptive batching (`effective_batch_size()` — caps yields at 3), and `max_items` cap (default 10,000)
  - `make_item()` (lines 58-74) — returns `{ label, insertText, filterText, kind, labelDetails, sortText, data }`
  - `update_cache()` (lines 241-272) — post-build: sorts by mtime, generates sortText, caps at max_items
- Description interning via `intern_desc()` (bounded pool, max 500) already reduces allocation

### Current Flow (Search Metadata)

```
Query: "type:note tag:project"
  → search_filter.evaluate(ast, index, graph_sets, restrict_to) iterates index.files
  → build_filter_context(ast, index) pre-resolves dates/tags/numerics once (amortized)
  → match_entry(ast, entry, index, graph_sets, ctx) called per entry
  → Short-circuit AND/OR/NOT already implemented (left fails → skip right)
  → Each entry: extract frontmatter["type"], compare "note"
  → Then: extract tags array, iterate for "project"
  → Result: ~200 matches
  → Wasted: 9,800 entries fully evaluated despite lacking required fields
```

**Existing optimizations already in search_filter.lua:**
- `build_filter_context()` (lines 145-217) — pre-resolves all constant filter values once per evaluate() call
  (caches resolved dates, parsed tags, numeric values, memoized link resolver via `filter_utils.create_memoized_resolver()`)
- `match_entry()` (lines 235-275) uses modular dispatch: `match_field_mod.match_field()`,
  `match_has_mod.match_has()`, `match_task_mod.match_task()` — each in `search_filter/` submodules
- Short-circuit evaluation in `match_entry()`: AND returns false immediately if left fails,
  OR returns true immediately if left succeeds
- `is_ast_superset(old_ast, new_ast)` (lines 104-133) — incremental live-search optimization for query prefixes
  (conservative: only handles pure AND-trees, rejects OR/NOT)
- `evaluate()` (lines 292-313) calls `match_field_mod.maybe_invalidate_section_cache(index)` before iteration
- `precompute_graph_sets()` — BFS traversal happens once, not per entry
- `restrict_to` parameter — limits iteration to specific file subset
- Generation-based cache invalidation via `vault_index._generation`

**What's missing:** cheap pre-checks that reject entries *before* entering `match_entry()` recursion.

### Zed's Multi-Layer Filtering Funnel

Zed uses a cascade of increasingly expensive filters. Each layer eliminates candidates
before more costly operations run:

1. **CharBag superset check** — O(1) bitwise AND, eliminates ~80% of candidates
2. **find_last_positions()** — O(n) reverse linear scan, verifies all query chars exist
3. **Min-score pruning** — During DP scoring, prunes branches below threshold
4. **Perfect score break** — Exits inner loop when score reaches 1.0
5. **Cancel flag polling** — Relaxed atomic check in main loop for responsive cancellation
6. **Quickselect truncation** — O(n) partition for top-N results (not O(n log n) sort)
7. **Parallel segmentation** — Divides candidates across CPU cores

### Zed's CharBag Implementation (Actual)

Zed's CharBag uses a 64-bit integer with **2-bit counting** for letters (tracks up to 3
occurrences), 1-bit presence for digits and hyphen:

```rust
// From crates/fuzzy/src/char_bag.rs (lines 3-26, verified current)
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct CharBag(u64);

impl CharBag {
    pub fn is_superset(self, other: CharBag) -> bool {  // lines 7-9
        self.0 & other.0 == other.0
    }

    fn insert(&mut self, c: char) {  // lines 11-26
        let c = c.to_ascii_lowercase();
        if c.is_ascii_lowercase() {
            // 2 bits per letter: bits [0..51] for a-z (indices 0-25, 2 bits each)
            // Saturating count: 00→01→10→11 (max 3)
            let mut count = self.0;
            let idx = c as u8 - b'a';
            count >>= idx * 2;
            count = ((count << 1) | 1) & 3;  // Saturating increment
            count <<= idx * 2;
            self.0 |= count;
        } else if c.is_ascii_digit() {
            // 1 bit per digit: bits [52..61]
            let idx = c as u8 - b'0';
            self.0 |= 1 << (idx + 52);
        } else if c == '-' {
            // 1 bit for hyphen: bit 62
            self.0 |= 1 << 62;
        }
        // Bit 63 unused
    }
}
```

**Bit layout:** a-z use bits 0-51 (2 bits each), 0-9 use bits 52-61, `-` uses bit 62.

Usage in `matcher.rs`:
```rust
// Line 75: First filter in the matching loop (match_candidates function, lines 57-121)
for candidate in candidates {
    if !candidate.borrow().has_chars(self.query_char_bag) {  // line 75
        continue;  // O(1) elimination before any scoring
    }

    // Line 79-81: Cancel flag check (relaxed atomic ordering)
    if cancel_flag.load(atomic::Ordering::Relaxed) {
        break;
    }

    // Line 95-97: find_last_positions check
    if !self.find_last_positions(lowercase_prefix, &lowercase_candidate_chars) {
        continue;
    }
    // ... expensive DP scoring only if both pass ...
}
```

**Note:** Cancel flag is checked *between* CharBag and find_last_positions (not at end of loop).

All match candidates implement `has_chars()` via CharBag superset:
```rust
// strings.rs (lines 31-39): StringMatchCandidate (struct at lines 14-29) stores CharBag at construction time
impl<'a> MatchCandidate for &'a StringMatchCandidate {
    fn has_chars(&self, bag: CharBag) -> bool {
        self.char_bag.is_superset(bag)
    }
}

// paths.rs (lines 48-56): PathMatchCandidate (struct at lines 17-22) follows same pattern
impl MatchCandidate for PathMatchCandidate<'_> {
    fn has_chars(&self, bag: CharBag) -> bool {
        self.char_bag.is_superset(bag)
    }
}
```

## Proposed Solution

### 1. CharBag Module for Lua

Create `lua/andrew/vault/char_bag.lua`:

```lua
--- Character presence bitset for fast pre-filtering.
--- Inspired by Zed's CharBag in crates/fuzzy/src/char_bag.rs.
---
--- Simplified for Lua: 1 bit per character (no occurrence counting).
--- Maps a-z to bits 0-25, 0-9 to bits 26-35, common punctuation to 36-41.
--- Total: 42 bits, fits in a Lua number (52-bit mantissa in LuaJIT doubles).
---
--- Zed uses 2-bit counting per letter (64-bit u64), but Lua's double precision
--- limits us to 52 safe integer bits. 1-bit presence is sufficient for
--- pre-filtering: we only need to know IF a character exists, not how many times.

local M = {}

-- Neovim uses LuaJIT which provides the `bit` library (not `bit32`)
local band = bit.band
local bor = bit.bor

-- Precompute character -> bit mappings
local _char_bit = {}
for i = 0, 25 do
  _char_bit[string.byte("a") + i] = 2 ^ i
  _char_bit[string.byte("A") + i] = 2 ^ i  -- Case insensitive
end
for i = 0, 9 do
  _char_bit[string.byte("0") + i] = 2 ^ (26 + i)
end
_char_bit[string.byte("-")] = 2 ^ 36
_char_bit[string.byte("_")] = 2 ^ 37
_char_bit[string.byte(".")] = 2 ^ 38
_char_bit[string.byte("/")] = 2 ^ 39
_char_bit[string.byte("#")] = 2 ^ 40
_char_bit[string.byte("@")] = 2 ^ 41

--- Compute CharBag for a string.
--- @param s string
--- @return number bag 42-bit character presence bitset
function M.from_string(s)
  local bag = 0
  for i = 1, #s do
    local b = _char_bit[s:byte(i)]
    if b then
      bag = bor(bag, b)
    end
  end
  return bag
end

--- Check if candidate's bag is a superset of query's bag.
--- If false, candidate cannot possibly match the query.
--- @param candidate_bag number
--- @param query_bag number
--- @return boolean
function M.is_superset(candidate_bag, query_bag)
  return band(candidate_bag, query_bag) == query_bag
end

return M
```

**Key differences from Zed:**
- 1-bit per character (not 2-bit counting) — sufficient for pre-filtering
- Uses LuaJIT `bit` library (`bit.band`, `bit.bor`) — Neovim always bundles LuaJIT
- Includes `_`, `.`, `/`, `#`, `@` (common in wiki-link paths) that Zed omits
- 42 bits total, well within LuaJIT's 52-bit safe integer range

### 2. Pre-Filter Completion Candidates

In `completion.lua`, pre-compute CharBag during `build_iter()` item construction.

The current item construction uses `make_note_item()` (lines 201-212), which wraps
`base.make_item(label, insertText, filterText, kind, opts)`. CharBag should be computed
from `filterText` (the field blink.cmp matches against):

```lua
local char_bag = require("andrew.vault.char_bag")

-- In make_note_item() or build_iter(), after constructing each item:
-- Note items (via make_note_item, line ~201-212):
local item = make_note_item(label, basename, filter, desc, mtime, rel)
item._char_bag = char_bag.from_string(filter)  -- Precomputed once at build time

-- Alias items follow same pattern (queued in build_iter's alias_queue):
local alias_item = make_note_item(alias_label, alias_basename, alias_filter, ...)
alias_item._char_bag = char_bag.from_string(alias_filter)
```

**Integration with blink.cmp:** blink.cmp has its own fuzzy matcher, but we can add a
`transform_items` hook in `completion_base.lua`'s `get_completions()` to pre-filter
before returning items to blink.cmp:

```lua
-- In completion_base.lua, within the get_completions callback:
local function get_completions(self, params, callback)
  -- ... existing debounce/cache logic ...
  local items = cached_items
  local query = params.query or ""

  -- CharBag pre-filter: eliminate impossible matches before blink.cmp scoring
  if conf("char_bag_enabled", true) and #query >= conf("min_query_length", 2) then
    local query_bag = char_bag.from_string(query:lower())
    local filtered = {}
    for i = 1, #items do
      local item = items[i]
      if not item._char_bag or char_bag.is_superset(item._char_bag, query_bag) then
        filtered[#filtered + 1] = item
      end
    end
    items = filtered
  end

  callback({ items = items, isIncomplete = false })
end
```

### 3. Pre-Filter Search Metadata

In `search_filter.lua`, add cheap field-existence pre-checks in the `evaluate()` loop,
*before* calling `match_entry()`. This complements existing optimizations (build_filter_context,
short-circuit AND/OR/NOT) by rejecting entries at the iteration level.

The current `evaluate()` function (lines 292-313) iterates `index.files` (or `restrict_to`)
via `pairs()`, calling `M.match_entry(ast, entry, index, graph_sets, ctx)` for each entry.
Line 293 calls `match_field_mod.maybe_invalidate_section_cache(index)` before the loop.
Add pre-checks between context building (line 299) and the main loop (line 302):

```lua
--- Extract cheap pre-check predicates from the AST.
--- Returns a list of functions that can reject entries in O(1).
--- @param ast table Metadata AST node
--- @return function[]|nil pre_checks Array of (entry, rel_path) -> bool functions
local function extract_pre_checks(ast)
  local checks = {}

  -- Collect leaf-level pre-checks from AND-tree
  -- AST field names: field nodes use `node.name`, has nodes use `node.target`
  local function collect(node)
    if not node then return end
    if node.type == "and" then
      collect(node.left)
      collect(node.right)
    elseif node.type == "field" and node.name == "type" then
      -- Entry must have frontmatter.type to match type: queries
      checks[#checks + 1] = function(entry)
        return entry.frontmatter ~= nil and entry.frontmatter.type ~= nil
      end
    elseif node.type == "has" and node.target == "tags" then
      -- Entry must have at least one tag
      checks[#checks + 1] = function(entry)
        return entry.tags ~= nil and #entry.tags > 0
      end
    elseif node.type == "has" and node.target == "tasks" then
      -- Entry must have at least one task
      checks[#checks + 1] = function(entry)
        return entry.tasks ~= nil and #entry.tasks > 0
      end
    elseif node.type == "has" and node.target == "aliases" then
      -- Entry must have at least one alias
      checks[#checks + 1] = function(entry)
        return entry.aliases ~= nil and #entry.aliases > 0
      end
    elseif node.type == "task" then
      -- Any task-* query requires the entry to have tasks
      checks[#checks + 1] = function(entry)
        return entry.tasks ~= nil and #entry.tasks > 0
      end
    end
  end

  collect(ast)
  return #checks > 0 and checks or nil
end

-- In evaluate() (line 299, after build_filter_context):
local pre_checks = extract_pre_checks(ast)

-- Replace the simple loop at lines 302-310 with:
local files = restrict_to or index.files
for rel_path, entry in pairs(files) do
  -- O(1) pre-checks before expensive match_entry
  -- Note: graph_sets is keyed by _graph_id (not rel_path), so graph filtering
  -- stays inside match_entry() where ast._graph_id is accessible
  if pre_checks then
    local skip = false
    for _, check in ipairs(pre_checks) do
      if not check(entry) then
        skip = true
        break
      end
    end
    if skip then goto continue end
  end

  -- Full evaluation (expensive) — dispatches to match_field_mod, match_has_mod, match_task_mod
  if M.match_entry(ast, entry, index, graph_sets, ctx) then
    matches[rel_path] = entry
    count = count + 1
    if max_files and count >= max_files then
      return matches, true
    end
  end

  ::continue::
end
```

**Note:** `extract_pre_checks()` only collects from pure AND-trees (same conservative
approach as `is_ast_superset()`). OR/NOT branches require full evaluation.

### 4. Bloom Filter for Tag Membership (Optional, Advanced)

For large tag sets, a bloom filter provides O(1) membership testing:

```lua
--- Simple bloom filter for set membership pre-checks.
--- False positives allowed (fall through to exact check).
--- False negatives never happen (safe for pre-filtering).

-- Use FNV-1a hash (fast, no external deps, suitable for bloom filter)
local bxor = bit.bxor

local function fnv1a(s)
  local hash = 2166136261
  for i = 1, #s do
    hash = bxor(hash, s:byte(i))
    hash = hash * 16777619
    hash = hash % 4294967296  -- Keep 32-bit
  end
  return hash
end

local function fnv1a_seeded(s, seed)
  local hash = bxor(2166136261, seed)
  for i = 1, #s do
    hash = bxor(hash, s:byte(i))
    hash = hash * 16777619
    hash = hash % 4294967296
  end
  return hash
end

local function bloom_add(bloom, item)
  local b1 = fnv1a(item) % 256
  local b2 = fnv1a_seeded(item, 0x9E3779B9) % 256
  bloom[b1] = true
  bloom[b2] = true
end

local function bloom_maybe_contains(bloom, item)
  local b1 = fnv1a(item) % 256
  local b2 = fnv1a_seeded(item, 0x9E3779B9) % 256
  return bloom[b1] and bloom[b2]
end
```

### 5. Index-Level Pre-Computed Sets

Pre-compute frequently-queried sets in vault_index for O(1) checks.

The vault index currently stores entries in `self.files` (rel_path → VaultIndexEntry) with
derived fields computed lazily via `__index` metatable (lines 30-80): `abs_path`, `basename`,
`basename_lower`, `folder`, `tag_set`, `heading_slugs`, `block_id_set`. Pre-computed fields
set during `load()` (lines 291-340): `rel_stem`, `rel_stem_lower`, link name caches, task
`tags_lower`, date timestamps (`day_ts`, `created_ts`, `modified_ts`). Aggregate caches
(`_cached_name_cache`, `_cached_tags`, `_cached_tag_counts`, `_cached_fm_keys`, `_cached_aliases`,
`_cached_sorted_names`) are rebuilt lazily on generation change via `_ensure_aggregates()`
(lines 892-964).

Add precomputed sets that are maintained incrementally (like `_name_index` and `_inlinks`).

Current `VaultIndex.new()` (lines 134-164) initializes: `files`, `_file_count`, `_name_index`,
`_alias_index`, `_inlinks`, `_persist_timer`, `_generation`, `_last_persisted_generation`,
`_persist_in_flight`, `_last_persist_time`, `_subscribers`, `_ready`, `_building`,
`_collisions`, `_collision_notified`, `_wal_count`, `_index_dir`, `_aggregates_gen`,
and all `_cached_*` fields (`_cached_name_cache`, `_cached_tags`, `_cached_fm_keys`,
`_cached_tag_counts`, `_cached_aliases`, `_cached_sorted_names`). Add alongside these:

```lua
-- In vault_index.lua, initialize in VaultIndex.new() (after line ~142):
self._files_with_tags = {}    -- Set of rel_paths that have ≥1 tag
self._files_with_tasks = {}   -- Set of rel_paths that have ≥1 task
self._files_by_type = {}      -- type_value → Set of rel_paths

-- Updated incrementally during _process_entry() or after batch updates:
function VaultIndex:_update_precomputed_sets(rel_path, entry)
  -- Tags
  if entry.tags and #entry.tags > 0 then
    self._files_with_tags[rel_path] = true
  else
    self._files_with_tags[rel_path] = nil
  end

  -- Tasks
  if entry.tasks and #entry.tasks > 0 then
    self._files_with_tasks[rel_path] = true
  else
    self._files_with_tasks[rel_path] = nil
  end

  -- Frontmatter type (must clean up old type if changed)
  -- Note: on entry update, caller should remove old rel_path from previous type set
  local ftype = entry.frontmatter and entry.frontmatter.type
  if ftype then
    self._files_by_type[ftype] = self._files_by_type[ftype] or {}
    self._files_by_type[ftype][rel_path] = true
  end
end

-- Also rebuild from scratch after load() (alongside _rebuild_name_index at line 344
-- and _recompute_inlinks at line 345):
function VaultIndex:_rebuild_precomputed_sets()
  self._files_with_tags = {}
  self._files_with_tasks = {}
  self._files_by_type = {}
  for rel_path, entry in pairs(self.files) do
    self:_update_precomputed_sets(rel_path, entry)
  end
end
```

Then in `search_filter.lua`, pre-checks can use these sets for complete O(1) resolution
(not just existence checks — full answer for simple queries):

```lua
-- O(1) complete answer: "has:tags" → check _files_with_tags
-- Note: has nodes use `ast.target` (not `ast.field`) per search_query.lua line 458
if ast.type == "has" and ast.target == "tags" then
  return index._files_with_tags[rel_path] or false
end

-- O(1) complete answer: "type:note" with equality → check _files_by_type
-- Note: field nodes use `ast.name` (not `ast.field`) per search_query.lua line 439
if ast.type == "field" and ast.name == "type" and ast.op == "=" then
  local type_set = index._files_by_type[ast.value]
  return type_set and type_set[rel_path] or false
end

-- O(1) complete answer: "has:tasks" → check _files_with_tasks
if ast.type == "has" and ast.target == "tasks" then
  return index._files_with_tasks[rel_path] or false
end
```

**Note:** These are NOT persisted to `index.json` — they are rebuilt from entries on
`load()` (same approach as `_name_index`, `_alias_index`, `_inlinks`).

## Configuration

Add to `config.lua` alongside existing `M.completion` and `M.search` sections:

```lua
M.prefilter = {
  enabled = true,
  completion_char_bag = true,     -- CharBag pre-filtering for completion
  search_fast_path = true,        -- Early exit checks in search_filter
  precomputed_sets = true,        -- Index-level precomputed sets
  min_query_length = 2,           -- CharBag only useful for queries ≥2 chars
}
```

## Zed Reference

### CharBag (`crates/fuzzy/src/char_bag.rs`, lines 3-63)

Full 64-bit layout with 2-bit letter counting (verified current):

```rust
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq, Hash)]  // lines 3-4
pub struct CharBag(u64);

impl CharBag {
    pub fn is_superset(self, other: CharBag) -> bool {  // lines 7-9
        self.0 & other.0 == other.0
    }

    fn insert(&mut self, c: char) {  // lines 11-26
        let c = c.to_ascii_lowercase();
        if c.is_ascii_lowercase() {
            // 2 bits per letter at positions [idx*2, idx*2+1]
            // Saturating count: 00→01→10→11 (max 3)
            let mut count = self.0;
            let idx = c as u8 - b'a';
            count >>= idx * 2;
            count = ((count << 1) | 1) & 3;
            count <<= idx * 2;
            self.0 |= count;
        } else if c.is_ascii_digit() {
            let idx = c as u8 - b'0';
            self.0 |= 1 << (idx + 52);
        } else if c == '-' {
            self.0 |= 1 << 62;
        }
    }
}

// Additional trait impls for CharBag construction:
impl Extend<char> for CharBag { ... }           // lines 29-35
impl FromIterator<char> for CharBag { ... }     // lines 37-43

impl From<&str> for CharBag {                   // lines 45-52
    fn from(s: &str) -> Self {
        let mut bag = Self(0);
        for c in s.chars() { bag.insert(c); }
        bag
    }
}

impl From<&[char]> for CharBag { ... }          // lines 55-62
```

### Matcher Early Exit Cascade (`crates/fuzzy/src/matcher.rs`, lines 57-121)

```rust
// match_candidates() function (lines 57-121)
// Matcher struct (lines 15-26) holds: query, lowercase_query, query_char_bag, smart_case,
//   penalize_length, min_score, match_positions, last_positions, score_matrix, best_position_matrix

for candidate in candidates {
    // Layer 1: CharBag superset (O(1) bitwise AND) — line 75
    if !candidate.borrow().has_chars(self.query_char_bag) {
        continue;
    }

    // Layer 2: Cancel flag (relaxed atomic, checked per candidate) — lines 79-81
    if cancel_flag.load(atomic::Ordering::Relaxed) {
        break;
    }

    // Layer 3: find_last_positions (O(n) reverse scan) — lines 95-97
    // Iterates query chars in reverse via enumerate().rev(), uses rposition() — lines 123-140
    if !self.find_last_positions(lowercase_prefix, &lowercase_candidate_chars) {
        continue;
    }

    // Layer 4: DP scoring with min-score pruning (recursive_score_match, lines 194-345)
    // Pruning: next_score = cur_score * multiplier; if < self.min_score → continue (lines 305-315)
    let score = self.recursive_score_match(...);

    // Layer 5: Perfect score break (exits inner loop at score == 1.0) — lines 331-335
}

// Post-matching: quickselect truncation for top-N (O(n) partition)
// Uses Vec::select_nth_unstable_by() for O(n) expected performance
truncate_to_bottom_n_sorted_by(&mut results, max_results, &compare);
```

### Parallel Segmentation (`crates/fuzzy/src/paths.rs`, lines 142-217)

```rust
// Lines 142-143: Segment calculation
let num_cpus = executor.num_cpus().min(path_count);
let segment_size = path_count.div_ceil(num_cpus);

// Lines 148-209: Each segment runs independently with its own Matcher instance
executor.scoped(|scope| {
    for (segment_idx, results) in segment_results.iter_mut().enumerate() {
        scope.spawn(async move {
            // Cancel flag checked per candidate_set (line 160, relaxed ordering)
            if cancel_flag.load(atomic::Ordering::Relaxed) { break; }
            matcher.match_candidates(&prefix, &lowercase_prefix, candidates, results, cancel_flag);
        })
    }
})

// strings.rs (lines 151-197) follows identical parallel pattern:
// segment_size = candidates.len().div_ceil(num_cpus) (lines 151-152)
// scoped spawning with per-segment Matcher (lines 157-189)
// truncation at line 197
```

## Expected Impact

| Optimization | Candidates Eliminated | CPU Savings |
|-------------|----------------------|-------------|
| CharBag (completion) | ~80% for 3+ char queries | ~4x faster filtering |
| Field existence pre-check | ~30-50% for typed queries | ~2x faster |
| Precomputed type sets | ~90% for `type:X` queries | ~10x faster |
| has:tags/tasks pre-check | ~40-60% (files without) | ~2x faster |
| Task existence gate | ~70-80% (most files lack tasks) | ~3x faster for task-* queries |

**Aggregate:** 2-10x speedup for search/completion filtering on large vaults.

**Note:** Completion CharBag savings are *in addition to* existing blink.cmp fuzzy
matching — the pre-filter reduces the number of items blink.cmp needs to score.
Search savings are *in addition to* existing `build_filter_context()` amortization and
`is_ast_superset()` incremental narrowing in live mode.

## Testing Strategy

1. **CharBag correctness:** Verify `is_superset(from_string("project"), from_string("proj"))` = true,
   `is_superset(from_string("file"), from_string("proj"))` = false
2. **Bit library:** Verify `bit.band` and `bit.bor` work correctly (LuaJIT always present in Neovim)
3. **Completion pre-filter:** Compare filtered results with/without CharBag (must be identical)
4. **Search fast path:** Run same query with/without pre-checks (must return same results)
5. **Precomputed sets:** Verify sets stay consistent after incremental index updates
   (add file, remove file, change file type)
6. **Benchmark:** Time `evaluate()` on 10K entries with/without fast paths
7. **Edge cases:** Empty query, single char, unicode characters, entry with nil frontmatter
8. **Live search interaction:** Verify `is_ast_superset()` + pre-checks compose correctly
   (pre-checks should not interfere with restrict_to narrowing)

## AST Node Field Reference

Critical for correct pre-check implementation — AST nodes use these field names
(from `search_query.lua` parser — field at lines 435-443, graph at lines 446-453,
has at lines 456-458, task meta at lines 464-472, task other at line 474):

| AST Type | Key Fields | Example Query |
|----------|-----------|---------------|
| `"field"` | `name`, `op`, `value`, `value2` | `type:note` → `{type="field", name="type", op="=", value="note"}` |
| `"has"` | `target` | `has:tags` → `{type="has", target="tags"}` |
| `"task"` | `variant`, `meta_field`, `op`, `value`, `value2` (meta) or `pattern` (any/todo/done) | `task-due:<7d` → `{type="task", variant="meta", meta_field="due", op="<", value="7d"}` |
| `"graph"` | `depth`, `direction`, `center`, `_graph_id` (set by precompute) | `graph:depth=2` → `{type="graph", depth=2, direction="both", center="current"}` |
| `"and"` | `left`, `right` | implicit AND between terms |
| `"or"` | `left`, `right` | explicit `OR` keyword |
| `"not"` | `operand` | `NOT` prefix or `-` prefix |
| `"text"` | `value`, `quoted` | `foo` or `"foo bar"` |
| `"regex"` | `pattern`, `flags` | `/regex/i` |
| `"match_all"` | (none) | standalone `group:` directive |

**Token types** (line 14-30): TEXT, QUOTED, REGEX, FIELD, AND, OR, NOT, MINUS, LPAREN, RPAREN, HAS, TASK, GRAPH, GROUP, EOF.

## Dependencies

- Independent module (no dependencies beyond LuaJIT `bit` library)
- Integrates with doc 04 (Completion Memory) and doc 08 (Progressive Search Filtering)
- CharBag data (1 number per item) adds negligible memory to completion cache
- Precomputed sets add ~3 tables to VaultIndex (rebuilt on load, not persisted)
- Must coordinate with `_rebuild_name_index()` / `_recompute_inlinks()` lifecycle
  in vault_index.lua (call `_rebuild_precomputed_sets()` at same points — currently
  `_rebuild_name_index()` (lines 685-698) is called at `load()` line 344,
  `_recompute_inlinks()` (lines 827-829) at line 345, and both after batch updates
  via `update_files_batch()` (lines 871-873))
- `match_entry()` (lines 235-275) dispatches to modular matchers in `search_filter/` subdirectory:
  `match_field.lua` (M.match_field at lines 234-536), `match_has.lua` (M.match_has at lines 10-45),
  `match_task.lua` (M.match_task at lines 280-329) — pre-checks must be consistent
  with these matchers' field access patterns
- `match_has.lua` checks: tags (line 13-14), aliases (17-18), tasks (21-22), outlinks (25-26),
  inlinks (29-31), frontmatter (34-36) — pre-checks for has: nodes must mirror these
- `build_async()` (lines 858-860) delegates to `vault_index_build.build_async()` (external module);
  `parse_task_fields()` (line 83) re-exported from `vault_index_parser.lua`
- Current SCHEMA_VERSION = 5 (line 17 of vault_index.lua)
