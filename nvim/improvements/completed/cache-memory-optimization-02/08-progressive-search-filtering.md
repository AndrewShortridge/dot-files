# 08 — Progressive Search Filtering

## Status: IMPLEMENTED
## Priority: LOW (originally)
## Estimated Effort: ~~Large~~ — Completed

## Problem

Live search (`lua/andrew/vault/search/live.lua`) re-evaluates the full metadata
AST against all vault files on every keystroke (after debounce). For a 10K-note vault:

- Each keystroke: O(10K) metadata evaluations
- If query includes `graph:` operator: BFS pre-computation on each keystroke
- Typing "type:note tag:project" triggers 6+ full evaluations during typing

The debounce (`config.search.live_debounce_ms`, default 150ms) helps, but the
underlying per-keystroke cost is still O(N).

## Zed Inspiration (Corrected)

> Last verified against Zed source: 2026-03-13. All line numbers confirmed current.

Investigation of the Zed codebase (`~/Software/zed-main`) reveals the original
doc overstated Zed's progressive filtering. Here's what Zed actually does:

### What Zed DOES implement

1. **Streaming with `ready_chunks`**: Project search (`crates/project/src/project.rs:3814`)
   batches results via `ready_chunks(64)`. The consumer in `project_search.rs:312`
   uses `ready_chunks(1024)` to incrementally update the UI as results arrive.

2. **Cancellation via task replacement** (project search): In `project_search.rs`,
   `pending_search: Option<Task<Option<()>>>` (struct field at line 183).
   At line 311, starting a new search assigns `self.pending_search = Some(cx.spawn(...))`.
   The old task is dropped via Rust's assignment semantics, causing automatic
   cancellation. No `AtomicBool` needed.

3. **Cancellation via `AtomicBool`** (file finder only): In
   `file_finder.rs:892-894`, a shared `Arc<AtomicBool>` (struct field at
   line 408) is passed to parallel fuzzy matchers. On new query:
   ```rust
   self.cancel_flag.store(true, atomic::Ordering::Relaxed);  // line 892: stop old search
   self.cancel_flag = Arc::new(AtomicBool::new(false));      // line 893: new flag
   let cancel_flag = self.cancel_flag.clone();               // line 894: clone for task
   ```
   The fuzzy matcher (`crates/fuzzy/src/matcher.rs:79`) checks this flag per-candidate.

4. **Viewport-only rendering**: The picker (`crates/picker/src/picker.rs:772-779`)
   uses GPUI's `uniform_list` which passes only the `visible_range: Range<usize>`
   (line 775) to a `cx.processor()` render callback — offscreen items are never
   constructed.

5. **CharBag pre-filtering**: `crates/fuzzy/src/char_bag.rs` uses a `u64` bitmap
   for O(1) character set superset checks (`is_superset`: `self.0 & other.0 == other.0`).
   Layout: bits 0-51 = 26 letters (2 bits each for count), bits 52-61 = digits
   (1 bit each), bit 62 = hyphen. Candidates missing any query character are
   skipped before expensive fuzzy scoring.

6. **Extend-old-matches** (file finder): `file_finder.rs` `set_search_matches()`
   (lines 919-948) has at line 934:
   ```rust
   let extend_old_matches = self.latest_search_did_cancel && !query_changed;
   ```
   When a search was cancelled (timed out) and the query hasn't changed, new
   results are merged with old partial results via `matches.push_new_matches()`
   (lines 942-948) rather than replacing them. This is **not** progressive
   refinement — it's partial result preservation.

### What Zed does NOT implement

- **Progressive refinement**: Zed does NOT filter within previous results when
  characters are appended. Each keystroke triggers a full search from scratch
  (project search) or a full fuzzy match across all candidates (file finder).
- **Monotonic query narrowing**: Not used anywhere in Zed's search pipeline.

### Key Insight: Monotonic Query Refinement

The insight remains valid even though Zed doesn't use it: when a user appends
characters to an AND-based query, the result set can only shrink. Searching
within the previous result set is always correct and often much faster.

## Current Implementation

Progressive filtering is **fully implemented** across three components:

### 1. Incremental Cache in Live Search

**File**: `lua/andrew/vault/search/live.lua` (lines 37, 60-84)

The `_prev_cache` local tracks previous query state within each fzf session:

```lua
local _prev_cache = { query = nil, ast = nil, file_set = nil, gen = nil }
```

On each keystroke, two conditions are checked before using incremental filtering:

1. **String prefix heuristic** (necessary but not sufficient):
   ```lua
   local is_prefix = #query_string > #_prev_cache.query
     and query_string:sub(1, #_prev_cache.query) == _prev_cache.query
   ```

2. **AST superset analysis** (sufficient for safety):
   ```lua
   if search_filter.is_ast_superset(_prev_cache.ast, ast) then
     restrict_to = _prev_cache.file_set
   end
   ```

When both pass, `restrict_to` is set to the previous result set, and
`evaluate_advanced_ast()` only iterates those entries instead of the full index.

### 2. AST Superset Check

**File**: `lua/andrew/vault/search_filter.lua` (section lines 44-132)

The `search_filter` module has been refactored into submodules under
`lua/andrew/vault/search_filter/` (`ripgrep.lua`, `ast_split.lua`,
`graph_traversal.lua`, `match_field.lua`, `match_has.lua`, `match_task.lua`,
`classify.lua`, `match_helpers.lua`). The main `search_filter.lua` re-exports
the public API (e.g., `M.ripgrep_in_files = ripgrep_mod.ripgrep_in_files` at
line 30). The superset check and evaluate functions remain in the main file.

The superset section spans lines 44-132:
- Line 44: section comment header
- `collect_and_leaves()` helper at lines 52-62
- `leaf_key()` fingerprint helper at lines 68-92
- `M.is_ast_superset()` function at lines 103-132

`M.is_ast_superset(old_ast, new_ast)` performs a conservative structural analysis:

- Flattens both ASTs into leaf sets via `collect_and_leaves()`
- Only handles **pure AND-trees** (returns `false` for OR/NOT — safe fallback)
- Each leaf is fingerprinted via `leaf_key()` (type + name + op + value)
- Returns `true` only if every old leaf appears in the new leaf set

Supported leaf types for fingerprinting:
- `text:value`, `regex:pattern:flags`
- `field:name:op:value:value2`
- `has:target`
- `task:pattern`, `task-meta:field:op:value:value2`, `task-state:pattern`
- `graph:_graph_id`

### 3. Restricted Evaluation

**File**: `lua/andrew/vault/search_filter.lua` (lines 290-305)

`M.evaluate()` (line 290) accepts an optional `restrict_to` parameter.
`M.match_entry()` (line 234) dispatches to submodule matchers:
`match_field.lua`, `match_has.lua`, `match_task.lua` for their respective node
types, plus inline graph set lookup for `"graph"` nodes.

```lua
function M.evaluate(ast, index, graph_sets, restrict_to)
  match_field_mod.maybe_invalidate_section_cache(index)
  local ctx = M.build_filter_context(ast, index)
  local files = restrict_to or index.files
  for rel_path, entry in pairs(files) do
    if M.match_entry(ast, entry, index, graph_sets, ctx) then
      matches[rel_path] = entry
    end
  end
  return matches
end
```

When `restrict_to` is provided, iteration is bounded by the previous result set
size rather than the full index — the core performance win.

### 4. Cache Update

After evaluation, the cache is always updated (lines 81-84):

```lua
_prev_cache.query = query_string
_prev_cache.ast = ast
_prev_cache.file_set = metadata_matches
_prev_cache.gen = cur_gen
```

This means progressive filtering chains: typing "t" → "ta" → "tag" → "tag:"
→ "tag:p" will progressively narrow the result set at each step (assuming pure
AND queries).

## Invalidation Rules (Implemented)

The progressive cache is automatically invalidated when:

1. **Query is not a prefix** — user deleted characters, jumped to middle, etc.
   The string prefix check fails and `restrict_to` stays `nil`.

2. **AST structure changed incompatibly** — OR/NOT nodes present, or old leaves
   not found in new AST. `is_ast_superset()` returns `false`.

3. **Vault index generation changed** — `filter_utils.is_cache_gen_valid()`
   compares `_prev_cache.gen` against `idx._generation`. Any file modification
   invalidates the cache.

4. **fzf session ends** — `_prev_cache` is local to the `search_advanced_live()`
   closure, so it's garbage-collected when fzf closes. No explicit cleanup needed.

5. **Graph queries** — graph: nodes get unique `_graph_id` values, and
   `is_ast_superset()` fingerprints them. Since graph sets depend on center/depth,
   changing graph parameters naturally fails the superset check.

## Ripgrep Progressive Filtering

The existing pipeline naturally benefits from progressive metadata filtering.

**File**: `lua/andrew/vault/search/advanced.lua`

- `resolve_query()` (lines 48-164) orchestrates the three evaluation modes
  (metadata_only, metadata_then_text, mixed_or), threading `restrict_to`
  through to `search_filter.evaluate()` at lines 52, 84, and 127.
- `M.evaluate_advanced_ast()` (line 182) is the public entry point called by
  `live.lua`, passing `restrict_to` to `resolve_query()` at line 203 (async
  path with callback) and lines 210-211 (sync path).

**File**: `lua/andrew/vault/search_filter/ripgrep.lua`

`ripgrep_in_files()` (re-exported as `search_filter.ripgrep_in_files`) handles
boolean text ASTs via recursive dispatch: AND → parallel spawn + intersect,
OR → union, NOT → complement. Supports both sync and async (callback) modes.

```lua
-- In search/advanced.lua resolve_query(), mode "metadata_then_text":
-- 1. evaluate(metadata_ast, idx, graph_sets, restrict_to)  ← progressive
-- 2. ripgrep_in_files(text_ast, candidate_paths)            ← fewer files
```

When metadata evaluation uses `restrict_to`, the candidate file list passed to
ripgrep is smaller, so ripgrep runs faster. No additional ripgrep-specific
progressive logic was needed.

## Limitations (As Implemented)

- **OR queries**: `is_ast_superset()` returns `false` for any tree containing OR
  nodes — falls back to full evaluation. This is correct (OR can expand results).
- **NOT queries**: Same — `collect_and_leaves()` returns `false` for NOT nodes.
- **Graph queries**: Superset check works at the fingerprint level but graph sets
  are recomputed each time (BFS cost not avoided). Progressive filtering reduces
  the metadata evaluation cost but not the graph pre-computation cost.
- **Text-only queries**: No progressive filtering applied — ripgrep always
  searches the full candidate set. The `is_ast_superset()` check requires
  metadata nodes to be meaningful.

## Config

No dedicated config flag was needed. Progressive filtering is always active with
safe fallback behavior — `is_ast_superset()` returns `false` for any uncertain
case. The existing `config.search.live_debounce_ms` controls keystroke debounce.

## Observed Impact

| Scenario | Without Progressive | With Progressive |
|----------|-------------------|------------------|
| Type "tag:project" (10 chars) | 10 x O(N) evaluations | 1 x O(N) + 9 x O(results) |
| 10K vault, 500 matches | ~100K evaluations total | ~14.5K evaluations total |
| OR query "tag:a OR tag:b" | Same | Same (fallback to full) |
| Graph query "graph:depth=2 tag:x" | Same | Metadata progressive, BFS still full |

## Risk Assessment

- **Correctness**: The dual-check design (string prefix + AST superset) is
  conservative — false negatives fall back to full evaluation, false positives
  are structurally prevented by the pure AND-tree requirement. No correctness
  issues reported.
- **Complexity**: Minimal state added — one `_prev_cache` table local to the
  fzf closure. No module-level state pollution. Cache is naturally scoped to
  the fzf session lifetime.

## Future Improvements

1. **OR-safe progressive filtering**: For queries like `tag:a tag:b` (AND of
   two fields) where a user appends to one field value, progressive filtering
   works. But `tag:a OR tag:b` falls back. A more sophisticated AST diff could
   handle some OR cases where both branches are refined.

2. **Graph BFS caching**: Cache graph reachable sets by `(center, depth, direction)`
   tuple across keystrokes. If only the metadata portion of the query changes,
   reuse the graph sets.

3. **Text-query progressive filtering**: For metadata-then-text queries, track
   which files matched the text portion. When metadata narrows but text is
   unchanged, skip ripgrep entirely and intersect cached text matches with new
   metadata matches.

## Testing

- Type "tag:" then "tag:p" then "tag:pr" — verify results monotonically decrease
  and `restrict_to` is used (check via `:VaultLog` or timing stats line)
- Delete a character ("tag:p" → "tag:") — verify full re-evaluation triggers
- Edit a file during live search — verify generation mismatch clears cache
- Type "tag:a OR tag:b" — verify fallback to full evaluation
- Type "graph:depth=2 tag:project" — verify metadata is progressive, graph recomputes
- Compare results of progressive vs full evaluation for 100 random queries

---

> Last verified: 2026-03-13 — All nvim and Zed line numbers confirmed current.
> search_filter.lua refactored into submodules (ripgrep, ast_split,
> graph_traversal, match_field, match_has, match_task, classify, match_helpers);
> public API re-exported from main file.
