# 05 — Search Result Streaming & Limits

## Priority: MEDIUM
## Estimated Effort: Medium

## Problem

The search system has no hard limits on result set sizes:

1. **`search_filter.evaluate(ast, index, graph_sets, restrict_to)`** iterates all files in `index.files` (or `restrict_to` subset) and returns ALL matching entries in an unbounded `matches` table — no cap on metadata results
2. **`ripgrep.ripgrep_in_files(text_ast, file_paths, vault_path, on_done)`** collects ALL matching lines into memory via `process_rg_output()` before returning — no line limit
3. **AND operator** (`and_combine()` in `search_filter/ripgrep.lua`) runs both sides fully (parallel spawn for leaf nodes via `sync_binary()`), then intersects file sets — both result arrays held in memory simultaneously
4. **Live search** (`search/live.lua`) re-evaluates full AST on every keystroke (150ms debounce + incremental cache via `is_ast_superset()` help, but broad queries still unbounded)

For a vault with 10K+ notes, a broad query like `type:note` can return thousands
of entries, each with file path and metadata references.

### Current Architecture

The search pipeline has a three-stage flow:

1. **AST Splitting** (`search_filter/ast_split.lua`): `split_ast()` classifies nodes as metadata-only (`field`, `has`, `task`, `graph`) or text (`text`, `regex`), producing four modes: `metadata_only`, `text_only`, `metadata_then_text`, `mixed_or`
2. **Metadata Evaluation** (`search_filter.lua`): `evaluate()` uses pre-computed `build_filter_context()` (cached date resolution, parsed tags, numeric values, memoized link resolver) and iterates `index.files` — fast in-process, but unbounded output
3. **Text Search** (`search_filter/ripgrep.lua`): `ripgrep_in_files()` with recursive sync/async dispatch, parallel leaf spawning, `--files-from` tmpfile restriction (when `#file_paths <= config.search.max_files_from` which is 500), post-filtering fallback for larger sets

**Result flow** passes through an intermediary before display:
- `search/advanced.lua:evaluate_advanced_ast()` (line 182) splits AST, pre-computes graph sets, then delegates to `resolve_query()` (line 48) which calls `search_filter.evaluate()` for metadata modes (lines 52, 84, 127) and `ripgrep_in_files()` for text modes
- `search/advanced.lua:execute_advanced_query()` (line 219) calls `evaluate_advanced_ast()` async (line 255), passes `result.entries` to `fzf.fzf_exec()` (line 341) — no pagination or truncation
- `search/live.lua:search_advanced_live()` (line 16) calls `evaluate_advanced_ast()` sync (line 77), returns `result.entries` from `fzf_live()` provider — no limit. Uses incremental cache with `restrict_to` from previous query's file set (lines 64-78)

**Existing config** (`config.lua` `M.search` section, lines 420-497) has `max_files_from = 500` (controls `--files-from` threshold), `live_debounce_ms = 150`, `show_stats = true`, `history`, `field_correction`, `field_enums`, `grouping`, but **no** `max_result_files`, `max_result_lines`, or `max_matches_per_file` settings.

## Zed Inspiration

Zed enforces strict result limits and uses progressive streaming throughout its
search architecture. Notably, Zed does **not** use ripgrep — it performs in-memory
search on loaded buffers using `AhoCorasick` (text) and `fancy_regex` (regex),
but the limit and streaming patterns translate well to our ripgrep-based pipeline.

### Result Limits
```rust
// crates/project/src/project.rs:146-147
const MAX_SEARCH_RESULT_FILES: usize = 5_000;
const MAX_SEARCH_RESULT_RANGES: usize = 10_000;
```

Limits are checked after each buffer chunk in `Project::search()`. When either
`buffer_count > MAX_SEARCH_RESULT_FILES` or `range_count > MAX_SEARCH_RESULT_RANGES`,
the search sends a `SearchResult::LimitReached` enum variant and breaks the outer
processing loop:

```rust
// crates/project/src/project.rs:3843-3860
range_count += ranges.len();
buffer_count += 1;
result_tx.send(SearchResult::Buffer { buffer, ranges }).await?;
if buffer_count > MAX_SEARCH_RESULT_FILES
    || range_count > MAX_SEARCH_RESULT_RANGES
{
    limit_reached = true;
    break 'outer;
}
// ...after the 'outer loop:
if limit_reached {
    result_tx.send(SearchResult::LimitReached).await?;
}
```

`SearchResult` is defined in `crates/project/src/search.rs:18-25`:
```rust
#[derive(Debug)]
pub enum SearchResult {
    Buffer {
        buffer: Entity<Buffer>,
        ranges: Vec<Range<Anchor>>,
    },
    LimitReached,
}
```

### Multi-Stage Streaming with Bounded Chunks

Zed uses two levels of chunked streaming:

```rust
// UI layer: crates/search/src/project_search.rs:312
let mut matches = pin!(search.ready_chunks(1024));
while let Some(results) = matches.next().await {
    // Process up to 1024 search results at a time for UI updates
}

// Search core: crates/project/src/project.rs:3814
let chunks = matching_buffers_rx.ready_chunks(64);
// Process 64 buffer candidates at a time, spawning parallel search tasks
```

### Multi-Stage Early Termination

Three levels of progressive elimination:

1. **File discovery** (`worktree_store.rs:881-913`): `filter_paths()` opens each file, checks UTF-8 validity on first buffer-fill (`fill_buf()` + `from_utf8()`), then calls `query.detect()` (`search.rs:280-318`) — for text queries uses `stream_find_iter()` (stops at first match); for regex uses per-line `regex.find()` (or full-file for multiline). Most files rejected without full read.
2. **Range accumulation** (`project.rs:3843-3860`): Hard limits (5K files / 10K ranges) with `break 'outer` and `LimitReached` signal.
3. **Per-buffer yielding** (`search.rs:359`): `yield_now()` every 20,000 matches (`YIELD_INTERVAL = 20_000`) to prevent blocking the async executor during large-file scans.

### Concurrency Limits

Zed caps concurrent operations with bounded channels:

| Stage | Limit | Source | Purpose |
|-------|-------|--------|---------|
| File scanning workers | 64 | `worktree_store.rs:698` (`MAX_CONCURRENT_FILE_SCANS`) | Parallel file readers via `executor.scoped` |
| Buffer open concurrency | 64 | `buffer_store.rs:1075` (`MAX_CONCURRENT_BUFFER_OPENS`) | I/O throttling via `.chunks()` |
| Search core batching | 64 | `project.rs:3814` (`ready_chunks(64)`) | Backpressure on buffer candidates |
| UI result batching | 1024 | `project_search.rs:312` (`ready_chunks(1024)`) | Efficient UI update coalescing |

## Implementation

### 1. Add Result Limits to Metadata Evaluation

**File**: `search_filter.lua`

Current signature (line 290): `M.evaluate(ast, index, graph_sets, restrict_to)` returns
a single `matches` table (`table<rel_path, VaultIndexEntry>`). The function calls
`match_field_mod.maybe_invalidate_section_cache(index)` (line 291), guards against nil
index (line 293), builds filter context via `M.build_filter_context(ast, index)`
(line 295), then iterates all files with `M.match_entry()` (lines 298-302).

Add a `max_files` limit with early termination and a second return value:

```lua
function M.evaluate(ast, index, graph_sets, restrict_to)
  local max_files = config.search.max_result_files
  match_field_mod.maybe_invalidate_section_cache(index)
  local matches = {}
  if not index or not index.files then return matches, false end
  local count = 0
  local ctx = M.build_filter_context(ast, index)
  local files = restrict_to or index.files

  for rel_path, entry in pairs(files) do
    if M.match_entry(ast, entry, index, graph_sets, ctx) then
      matches[rel_path] = entry
      count = count + 1
      if max_files and count >= max_files then
        return matches, true  -- true = limit reached
      end
    end
  end

  return matches, false
end
```

The caller is `resolve_query()` in `search/advanced.lua` (line 48) which
calls `search_filter.evaluate()` at lines 52, 84, and 127 for metadata_only,
metadata_then_text, and mixed_or modes respectively. `resolve_query()` must handle the second return value and propagate
`limit_reached` through the `result` table to both `execute_advanced_query()` and
`search_advanced_live()`.

### 2. Add Result Limits to Ripgrep Output

**File**: `search_filter/ripgrep.lua`

Current signature: `M.ripgrep_in_files(text_ast, file_paths, vault_path, on_done)`.

Add line-count tracking in `process_rg_output()` (line 115, the shared output handler
used by both sync and async paths).

Current signature: `process_rg_output(stdout, use_file_restriction, file_paths)` where
`stdout` is the raw ripgrep output string, `use_file_restriction` is a boolean
(whether `--files-from` was used), and `file_paths` is the original path array
(used for post-filtering when full-vault fallback was used).

```lua
local function process_rg_output(stdout, use_file_restriction, file_paths)
  local max_lines = config.search.max_result_lines
  local lines = {}
  local count = 0

  for line in (stdout or ""):gmatch("[^\n]+") do
    count = count + 1
    if max_lines and count > max_lines then
      lines[#lines + 1] = "__limit_reached__:0:0:... results truncated at "
        .. max_lines .. " matches"
      break
    end
    lines[#lines + 1] = line
  end

  -- When full-vault fallback was used, post-filter results to only include
  -- files from the original file_paths set (otherwise metadata filtering is bypassed)
  if not use_file_restriction and #file_paths > 0 then
    local allowed = {}
    for _, path in ipairs(file_paths) do
      allowed[path] = true
    end
    local filtered = {}
    for _, line in ipairs(lines) do
      if allowed[M.extract_rg_file(line)] then
        filtered[#filtered + 1] = line
      end
    end
    return filtered
  end

  return lines
end
```

### 3. Optimize AND Operator Memory

**File**: `search_filter/ripgrep.lua`

`sync_binary()` (line 254) has two paths:
- **Parallel leaf case** (lines 258-264): Both children are leaf nodes → spawns both
  `vim.system()` calls simultaneously via `prepare_rg_call()`, waits on both. Good for
  I/O overlap, but both full result arrays are held in memory.
- **Sequential non-leaf case** (lines 266-267): Calls `ripgrep_recursive_sync()` for
  left, then right — both with the **same** `file_paths` parameter. No restriction of
  right-side files based on left results.

In both cases, `and_combine()` (line 194) post-intersects file sets using
`collect_file_set()` on both sides, keeping only lines from common files.

**Optimization**: For the sequential (non-leaf) case, restrict the right side to
left's matched files before recursing:

```lua
-- In sync_binary() for AND, replace sequential (non-leaf) case (lines 266-267):
local left = ripgrep_recursive_sync(text_ast.left, file_paths, vault_path, tmpfile)
local left_files = collect_file_set(left)  -- already exists (line 195 in and_combine)

-- Only search right side in files that matched left
local right_file_paths = {}
for _, fp in ipairs(file_paths) do
  if left_files[fp] then
    right_file_paths[#right_file_paths + 1] = fp
  end
end

local right = ripgrep_recursive_sync(text_ast.right, right_file_paths, vault_path, tmpfile)
return and_combine(left, right)
```

This reduces peak memory from `|left| + |right|` to `|left| + |intersection|`.

For the parallel leaf case, the optimization is less applicable since both
processes are spawned simultaneously — but result limits (step 2) still cap
total output.

### 4. Add Limit-Reached Notification in UI

**Files**: `search/advanced.lua` and `search/live.lua`

In `resolve_query()` (line 48), propagate `limit_reached` through the result table:

```lua
-- In resolve_query(), after each search_filter.evaluate() call (lines 52, 84, 127):
local matches, limit_reached = search_filter.evaluate(split.metadata_ast, idx, graph_sets, restrict_to)
-- ... existing result processing ...
result.limit_reached = limit_reached
```

In `execute_advanced_query()` (line 219), after receiving the async result (line 256):

```lua
if result.limit_reached then
  notify.warn(string.format(
    "Search results limited to %d files. Try narrowing your query.",
    config.search.max_result_files
  ))
end
```

In `search_advanced_live()` (line 16), propagate via fzf header or prepend to
`result.entries` stats line (line 87-98) to avoid spamming notifications on each
keystroke — the live mode calls `evaluate_advanced_ast()` synchronously on every
query change (line 77).

### 5. Ripgrep Process Limits

Pass `--max-count` to ripgrep in `build_rg_args()` (line 12) to limit matches per file.
The function currently builds args with base flags (`--column`, `--line-number`,
`--no-heading`, `--color=never`), then adds mode-specific flags (`--fixed-strings` for
quoted text, `--smart-case` for unquoted, `--case-insensitive`/`--multiline-dotall`/
`--multiline` for regex), then appends `--files-from` or vault_path.

Add `--max-count` before the file restriction flags:

```lua
-- In build_rg_args() (line 12), after base flags and before files-from (line 44):
local max_per_file = config.search.max_matches_per_file
if max_per_file then
  args[#args + 1] = "--max-count"
  args[#args + 1] = tostring(max_per_file)
end
```

This prevents a single large file from consuming the entire result budget.

## Config Additions

```lua
-- config.lua, within existing M.search table (lines 420-497)
-- Add after max_files_from = 500 (line 430):
M.search.max_result_files = 5000       -- metadata evaluation cap
M.search.max_result_lines = 10000      -- ripgrep output line cap
M.search.max_matches_per_file = 100    -- rg --max-count per file
```

These join the existing `M.search` settings: `live_debounce_ms` (150), `max_files_from`
(500), `builtin_fields`, `field_aliases`, `has_targets`, `graph_operator` (true),
`graph_max_depth` (5), `prompt_width` (72), `help_width` (55), `history` (enabled,
max_entries=200), `show_stats` (true), `field_correction` (enabled, max_distance=2),
`field_enums`, `grouping` (default_mode="none").

## Performance Impact

For a 10K-note vault with broad queries:
- **Before**: All 10K entries evaluated and stored → ~5MB result table
- **After**: Evaluation stops at 5K, rg stops at 10K lines → ~2.5MB max
- **AND optimization**: Reduced peak memory for sequential AND (right side restricted to left's file set)
- **Per-file cap**: `--max-count=100` prevents single large files from dominating results

## Testing

- Query `type:note` on large vault, verify limit notification appears and `evaluate()` returns `true` as second value
- Query `word1 word2` (AND), verify sequential path restricts right-side file set to left matches
- Verify `:VaultSearch` live mode respects limits without UI hang (check fzf header for limit indicator)
- Verify `--max-count` flag doesn't break existing ripgrep result parsing in `process_rg_output()`
- Verify `__limit_reached__` truncation marker is handled gracefully by fzf display and result selection
- Test with `max_result_files = nil` to confirm backward-compatible unbounded behavior
