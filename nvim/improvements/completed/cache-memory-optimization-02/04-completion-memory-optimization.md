# 04 — Completion Memory Optimization

## Priority: MEDIUM
## Estimated Effort: Medium

## Problem

The completion system maintains 5 independent caches (one per source), each
storing the full completion item array. For large vaults:

- **Wikilinks**: N notes x ~500 bytes = 5 MB at 10K notes (includes aliases).
  Each item: `{ label, insertText, filterText, kind=18, sortText, labelDetails={description}, data={rel_path, abs_path} }`.
  Aliases duplicate this with `label=alias`, `filterText=alias.." "..name`,
  `description="(alias) "..desc`. Block refs (`kind=22`, `data.completion_kind="block"`)
  and heading refs (`kind=22`, `data.completion_kind="heading"`) are built
  on-demand in `get_completions`, not cached.
- **Tags**: ~100 KB (aggregated counts via `build_kv_single_pass`, lines 397-526 in completion_base.lua)
- **Frontmatter**: ~100 KB (field counts + values via `kv_get_completions`, line 551-566)
- **Inline fields**: ~50 KB (same `kv_get_completions` factory as frontmatter, via `build_kv_fields`, line 533-542)
- **Spell**: No cache (standalone, max 10 suggestions via `spellsuggest`)

Total: ~5.5 MB for a 10K-note vault, with no deduplication between sources
and no per-item size cap.

Each wikilink completion item carries `data = { rel_path, abs_path }` — two
full path strings per item, even though `abs_path` can be derived from
`engine.vault_path .. "/" .. rel_path`. This applies to primary items (line 244),
alias items (line 225), block references (line 328), and heading references
(line 365) in `completion.lua`.

### Current Architecture

The completion system is built on `completion_base.lua`'s `create_source(opts)`
factory, which provides:

- **Coroutine-based async builds** (`build_iter` path) with adaptive batch sizing
  via `effective_batch_size()` — caps coroutine yields at 3
- **Legacy sync builds** (`build` callback path) used by tags, frontmatter,
  inline fields
- **Generation tracking**: `cached_index_gen` vs `vault_index._generation` for
  staleness detection
- **Cancellation**: `active_state.cancelled` flag checked at each yield; cancel
  function returned to blink.cmp
- **Debounce**: `vim.uv.new_timer()` with `config.completion.debounce_ms` (250ms)
- **Pre-warm**: `source.new()` calls `build_items_async()` fire-and-forget (line 297)
- **Debug stats**: per-source tracking via `all_source_stats` registry, exposed
  through `M.debug_info()` and `:VaultCompletionDebug`

Blink.cmp configuration (`lua/andrew/plugins/blink-cmp.lua`):
- Wikilinks: `async = true`, `timeout_ms = 3000`, score_offset 15 (line 96-114)
- Tags: score_offset 12, trigger `#`, `/` (line 115-121)
- Frontmatter: score_offset 14 (line 122-128)
- Inline fields: score_offset 11, trigger `:` (line 129-135)
- Spell: score_offset -5, min_keyword_length 3 (line 136-142)
- Markdown filetype sources (line 86): wikilinks, vault_tags, vault_frontmatter,
  vault_inline_fields, lsp, snippets, path, buffer, spell

## Zed Inspiration

Zed's completion system uses several memory optimization techniques:

### 1. CharBag: Ultra-Compact Character Presence Filtering

**File**: `crates/fuzzy/src/char_bag.rs`

A `CharBag` is a newtype `struct CharBag(u64)` (line 4) — 2 bits per
lowercase letter (52 bits, lines 13-19), 1 bit per digit (10 bits,
lines 20-22), 1 bit for hyphen at bit 62 (lines 23-25). Enables O(1)
superset checking via `self.0 & other.0 == other.0` (lines 7-9), discarding
~95% of non-matching candidates before expensive scoring. Zero allocations,
fits in a register. Implements `From<&str>`, `From<&[char]>`, and
`FromIterator<char>`.

### 2. Fuzzy Matcher: Pre-Allocated Buffer Reuse

**File**: `crates/fuzzy/src/matcher.rs`

The `Matcher` struct (lines 15-26) owns reusable buffers: `match_positions`
(Vec<usize>), `last_positions` (Vec<usize>), `score_matrix` (Vec<Option<f64>>),
`best_position_matrix` (Vec<usize>). In `match_candidates()` (lines 57-121),
`score_matrix` and `best_position_matrix` are `.clear()`ed and `.resize()`d
per candidate (lines 100-103). Local candidate char vectors (`candidate_chars`,
`lowercase_candidate_chars`) are also `.clear()`ed and refilled each iteration
(lines 83-85). Scoring uses 1D matrix indexing: `query_idx * path_len +
path_idx` with memoization in `recursive_score_match()` (lines 194-345).

### 3. Parallel Fuzzy Matching with Per-CPU Segmentation

**File**: `crates/fuzzy/src/strings.rs`

`match_strings()` (line 116) splits candidates into `num_cpus` segments
(line 151-152), each with a per-thread `Matcher` (line 164) and pre-allocated
result vectors (`Vec::with_capacity`, line 154). Results are concatenated
(line 196) and truncated via `truncate_to_bottom_n_sorted_by()` (defined in
`crates/util/src/util.rs:196`) which uses quickselect
(`select_nth_unstable_by`) + truncate + sort. An `AtomicBool` cancel flag
is checked after all segments complete (line 192) and returns empty on
cancellation.

### 4. Bounded Markdown Documentation Cache

**File**: `crates/editor/src/code_context_menus.rs`

A `VecDeque<(MarkdownCacheKey, Entity<Markdown>)>` ring buffer (line 213)
capped at `MARKDOWN_CACHE_MAX_SIZE = 16` (line 53). On cache hit during
render, the entry is rotated to front via `rotate_right(1)` + `swap`
(lines 651-656). On miss with full cache, the oldest entry is overwritten
via `rotate_right(1)` and content reset (lines 691-700). New entries are
`push_front`ed when cache has space (line 686). Cache keys use a
`MarkdownCacheKey` enum (lines 220-228) with variants `ForCandidate {
candidate_id }` and `ForCompletionMatch { new_text, markdown_source }`
for heuristic reuse during typing.

### 5. Windowed Lazy Resolution

**Files**: `crates/editor/src/code_context_menus.rs`, `crates/project/src/lsp_store.rs`

Only resolves completions near the visible selection:
- `RESOLVE_BEFORE_ITEMS = 4`, `RESOLVE_AFTER_ITEMS = 4` (lines 58-59)
- `MARKDOWN_CACHE_BEFORE_ITEMS = 2`, `MARKDOWN_CACHE_AFTER_ITEMS = 2` (lines 54-55)
- `APPROXIMATE_VISIBLE_COUNT = 12` used when `last_rendered_range` unavailable
- Items with existing `documentation` are skipped (no duplicate LSP calls)
- Selected item is always resolved first, then neighbors via
  `expanded_and_wrapped_usize_range()` (line 516)
- Two-stage pipeline: `resolve_visible_completions()` (line 468) dispatches
  LSP resolve → on completion triggers `start_markdown_parse_for_nearby_entries()`
  (line 568) which uses `wrapped_usize_outward_from()` to enumerate items
  spiraling outward from selection

### 6. Lightweight Completion Struct with Lazy Docs

**File**: `crates/project/src/project.rs`

The `Completion` struct (lines 423-443) stores
`documentation: Option<CompletionDocumentation>` which is `None` until resolved.
`CompletionDocumentation` (defined in `lsp_store.rs:12093`) is an enum with
variants: `Undocumented`, `SingleLine(SharedString)`,
`MultiLinePlainText(SharedString)`, `MultiLineMarkdown(SharedString)`,
`SingleLineAndMultiLinePlainText { single_line, plain_text: Option<SharedString> }` — classified by
display strategy. `SharedString` provides string interning. A `resolved: bool`
flag on `CompletionSource::Lsp` (line 457) prevents duplicate resolution.

### 7. Fixed-Size Arrays and Bounded Word Lookup

**File**: `crates/editor/src/editor.rs`

After merging LSP completions and buffer words, the final array is converted
from `Vec<Completion>` to `Box<[Completion]>` via `.into()` (line 5603) —
fixed-size, no growth. Stored as `Rc<RefCell<Box<[Completion]>>>` in
`CompletionsMenu` (line 203 of `code_context_menus.rs`). Word lookup is bounded
to `WORD_LOOKUP_ROWS = 5_000` rows (line 5484). Deduplication removes buffer
words that match existing LSP completion `new_text` before menu creation.

### Key Zed Insight: Separate Display Data from Resolution Data

Zed keeps completion items lightweight for display and only loads heavy data
(documentation, resolved edits) when the user selects an item or scrolls near it.

## Implementation

### 1. Eliminate Redundant abs_path in Completion Items

**File**: `completion.lua` (build_iter function, lines 167-248)

Currently each wikilink item stores both `rel_path` and `abs_path` in
`item.data`. Since `abs_path = engine.vault_path .. "/" .. rel_path`, we can
derive it on resolve.

```lua
-- Before (current code, lines 242-244):
data = {
  rel_path = rel,
  abs_path = entry.abs_path,
}

-- After:
data = {
  rel_path = rel,
}

-- In resolve_item (completion.lua resolve function, starts at line 380):
-- engine.vault_path is already available as a module-level reference
local abs_path = engine.vault_path .. "/" .. item.data.rel_path
```

This change affects 4 locations in `completion.lua`:
- Primary items (line 244): `abs_path = entry.abs_path`
- Alias items (line 225): `abs_path = entry.abs_path`
- Block references (line 328): `abs_path = entry.abs_path`
- Heading references (line 365): `abs_path = target_path`

Note: The resolve function dispatches on `item.data.completion_kind`:
block resolution (lines 382-407), heading resolution (lines 410-452),
and note-level resolution (lines 454-517). All three paths use
`item.data.abs_path` and would need updating to derive it.

**Savings**: ~80 bytes per item (avg abs_path length). At 10K items with
aliases: ~800 KB–1.2 MB.

### 2. Cap Maximum Completion Items

**File**: `completion_base.lua`

Currently no cap exists. Add a configurable maximum to prevent unbounded growth.
The cap should be applied in the coroutine build path (after all items are
collected) and the legacy build path:

```lua
-- In build_items_async, after build completes:
local max_items = config.completion.max_items or 10000

if #items > max_items then
  -- Items are already sorted by mtime (sortText = format("%010d", 9999999999 - mtime))
  -- so truncating keeps the most recent items
  table.sort(items, function(a, b)
    return a.sortText < b.sortText
  end)
  for i = max_items + 1, #items do
    items[i] = nil
  end
end

update_cache(items)
```

Note: The current `effective_batch_size()` function (lines 61-64) already adapts
batch sizes based on estimated item count (caps yields at 3), so this cap
integrates cleanly with the existing async build pipeline. The cap should be
applied in `update_cache()` (lines 169-180) before storing items.

### 3. Deduplicate Description Strings

**File**: `completion.lua`

The `build_description(fm, rel)` function (lines 133-145, called at line 202)
constructs description strings per item in the format
`type | tag1, tag2 — relative/path.md` (or just `rel` if no frontmatter).
Many items share identical descriptions (same frontmatter type, same tags).
Lua's string interning only works for identical string references, not freshly
constructed identical strings. Use a bounded string pool:

```lua
local _desc_pool = {}
local _desc_pool_size = 0
local DESC_POOL_MAX = 500

local function intern_desc(desc)
  if _desc_pool[desc] then return _desc_pool[desc] end
  if _desc_pool_size >= DESC_POOL_MAX then
    _desc_pool = {}
    _desc_pool_size = 0
  end
  _desc_pool[desc] = desc
  _desc_pool_size = _desc_pool_size + 1
  return desc
end

-- Usage in build_iter (line 202, within primary item construction):
local desc = intern_desc(build_description(fm, rel))

-- And for aliases (line 221, alias labelDetails.description):
description = intern_desc("(alias) " .. desc),
```

**Savings**: Depends on description uniqueness. With common frontmatter
patterns (type: "note", tags: "project"), ~30-50% string memory reduction.

### 4. Lazy Sort Text Generation

**File**: `completion.lua`

Currently `sortText` is eagerly computed for every item at line 203:
```lua
local sort = string.format("%010d", 9999999999 - mtime)
```

This creates a unique 10-char string per item. Since blink.cmp uses
`filterText` for initial filtering, consider deferring `sortText` or using
a numeric sort key instead:

```lua
-- Option A: Store mtime in data, generate sortText lazily in get_completions
data = {
  rel_path = entry.rel_path,
  mtime = entry.mtime or 0,
}

-- Option B: Share sortText strings for items with identical mtime
-- (less impactful since mtime values tend to be unique)
```

Note: This optimization has lower impact than abs_path elimination since
sortText is only 10 bytes per item. Investigate whether blink.cmp actually
calls `sortText` before implementing.

### 5. Pre-warm Guard

**File**: `completion_base.lua` (lines 294-299)

The current pre-warm fires on `source.new()`, which blink.cmp calls when
setting up providers. The `source:enabled()` method (line 301-303) already
guards against non-markdown buffers:

```lua
function source:enabled()
  return vim.bo.filetype == "markdown"
end
```

However, `source.new()` still triggers `build_items_async()` regardless of
filetype. Consider guarding the pre-warm:

```lua
function source.new()
  local self = setmetatable({}, { __index = source })
  -- Only pre-warm if we're already in a markdown buffer
  if vim.bo.filetype == "markdown" then
    build_items_async()
  end
  return self
end
```

This is a minor optimization — the build is debounced and async, so the cost
of a wasted build is low.

## Config Additions

```lua
-- config.lua (current completion section at lines 399-415):
M.completion = {
  debounce_ms = 250,              -- Already exists (line 405)
  batch_size = 50,                -- Already exists (line 410)
  index_build_timeout_secs = 30,  -- Already exists (line 414)
  -- New:
  max_items = 10000,              -- Cap completion item count
  intern_descriptions = true,     -- Enable description string pooling
}
```

## Monitoring

Extend `:VaultCompletionDebug` (currently at `completion_base.lua:570-610`,
with per-source stats function at lines 103-122) to show memory estimates
alongside existing stats:

```
Completion Debug
================================
  Registered sources: 4
  Config: debounce_ms=250, batch_size=50
  Index generation: 42 (8500 files)

  [wikilinks]
    Cache: 8492 items (~4.2 MB estimated)
    Data fields: rel_path only (abs_path derived)
    Description pool: 142 unique / 8492 total (98% dedup)
    State: idle
    Mode: coroutine (build_iter)
    Generation: cache=42, invalidation=3
    Last build: 45.2ms (12s ago)

  [vault_tags]
    Cache: 340 items (~34 KB estimated)
    State: idle
    Mode: legacy (build)
    ...
```

The current debug output already includes per-source item count, state,
mode, generation tracking, and build timing. The additions are:
- Estimated memory size per source (item_count × avg_item_bytes)
- Data field composition (whether abs_path is stored)
- Description pool hit rate (if intern_descriptions enabled)

## Testing

- Build completion with 10K+ notes, verify item count ≤ max_items
- Verify `resolve_item` still works without pre-cached abs_path
  - Test note resolution, block reference resolution, heading resolution
- Compare memory usage before/after with `:lua print(collectgarbage("count"))`
- Verify description interning: check `_desc_pool_size` after build
- Verify pre-warm guard: open a non-markdown file, confirm no build triggered
- Existing `:VaultCompletionDebug` should show updated stats
