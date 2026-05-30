# 15 — Preview & Render Caching

## Priority: LOW
## Inspired By: Zed's `CompletionsMenu.markdown_cache` in `code_context_menus.rs`

## Problem

The vault's preview system (`preview.lua`) re-reads and re-processes file content every
time a floating preview is opened, even for recently-viewed notes. Similarly, the embed
system re-reads cross-file content on every render cycle.

### Current Preview Flow

```
User presses K (preview):
  → link_utils.get_wikilink_under_cursor()
  → target.resolve(details, parent_buf)            [preview/target.lua:19]
    → wikilinks.resolve_link(name)                   (cached via vault index ✓)
    → link_utils.resolve_content(details, path)      [link_utils.lua:357]
      → read_heading_section(path, heading)           [link_utils.lua:250]
        → read_all_lines(source)                       [link_utils.lua:231]
          → io.open(path, "r") → f:lines()             (uncached disk I/O ✗)
      or read_block_content(path, block_id)          [link_utils.lua:290]
        → read_all_lines(source)                       [link_utils.lua:231]
          → io.open(path, "r") → f:lines()             (uncached disk I/O ✗)
      or (full file) engine.read_file_lines(path)    [link_utils.lua:400]
        → engine_file_io.read_file_lines(path)         [engine_file_io.lua:127-139]
          → io.open(path, "r") → file:lines()          (uncached disk I/O ✗)
  → compute_float_dims(lines)                        [preview.lua:69]
  → nvim_open_win(buf, false, config)                [preview.lua:397]
  → setup_markdown_rendering()                       [preview.lua:80]
  → User dismisses float (close_preview)             [preview.lua:290]

User presses K on same link 5 seconds later:
  → Same full pipeline repeats (io.open, extract, format)
  → File hasn't changed — all work is redundant
```

**Note:** Preview reuses a single persistent buffer (`state.buf`) across sessions and
preserves markdown rendering state (`_markdown_rendered` flag at preview.lua:30), but does
NOT cache file content or extracted sections.

**Note:** `read_all_lines()` (link_utils.lua:231) uses raw `io.open()` instead of
`engine.read_file_lines()` because engine.lua requires link_utils.lua — calling back
into engine would create a circular dependency (see link_utils.lua:226-228 comment).

### Current Embed Flow

```
M.render_embeds(opts)                               [embed.lua:347]
  → build_descriptors(buffer_lines)                  [embed.lua:134] (pattern match, no I/O)
  → render_in_range(descs, ctx, top, bot)            [embed.lua:285] (lazy: visible only)
    → render_single_embed(desc, ctx)                 [embed.lua:188]
      → resolver.resolve_embed(details.name, bufpath)  [embed_resolver.lua:16] → absolute path
      → resolver.resolve_embed_lines(details, source, ...)  [embed_resolver.lua:66]
        → get_embed_content()                          [embed_resolver.lua:29]
          → link_utils.resolve_content(details, source)  [link_utils.lua:357]
            → read_all_lines(source) → io.open()         (heading/block path, uncached ✗)
            or engine.read_file_lines(path)              (full-file path, uncached ✗)
  → render_remaining_async(bufnr, generation, ctx)    [embed.lua:312] (16ms timer batches)

On BufEnter (M.on_buf_enter):                       [embed.lua:759]
  → Ensures vault index subscription active           [embed.lua:760]
  → GC stale buffers                                  [embed.lua:761]
  → Guard: skips if embeds_visible[bufnr] is truthy   [embed.lua:762]
  → 50ms defer → render_embeds({ silent = true })     [embed.lua:763-767]
  → Full re-read of all cross-file embed targets
```

**Existing embed optimizations:**
- Lazy rendering: only visible embeds rendered synchronously, rest batched at 16ms (config.embed.lazy)
- Same-file embeds use `nvim_buf_get_lines()` (live buffer, no disk I/O) [embed.lua:236-237]
- Generation counter prevents stale async renders [embed.lua:367, checked at 301-306 and 321-325]
- embed_sync.lua watches vault_index changes for targeted re-renders [embed_sync.lua:51-92]
  - Uses inverted dependency index: O(changed_files) lookup instead of O(buffers)
- Image path resolution uses LRU cache (`embed_images.lua:42`, bounded by `config.cache.image_path_max`)
  - Registered with engine cache system [embed_images.lua:51-67] with selective invalidation [embed_images.lua:74-99]
- Cycle detection via visited_set in recursive embeds [embed_resolver.lua:84-86]
- Line budget system respects config.embed.max_total_lines [embed.lua:228-247, embed_resolver.lua:73-75]
- WinScrolled triggers debounced renders for newly-visible embeds [embed.lua:708-744]

### Impact

| Operation | Frequency | Cost Per Call | Cacheable? |
|-----------|-----------|---------------|------------|
| Preview file read | Every K press | 1-5ms (io.open + lines()) | Yes (mtime-gated) |
| Preview section extract | Every K press | 0.5-2ms (string ops) | Yes (mtime-gated) |
| Embed file read | Every BufEnter | 1-5ms per embed × N | Yes (mtime-gated) |
| Embed section extract | Every BufEnter | 0.5-2ms per embed × N | Yes (mtime-gated) |
| Preview formatting | Every K press | 0.1-0.5ms | Yes |

For a buffer with 10 embeds, each BufEnter costs 15-70ms in redundant I/O.

## Proposed Solution

### 1. File Content Cache with Mtime Validation

Create `lua/andrew/vault/file_cache.lua`:

```lua
--- File content cache with mtime-based invalidation.
--- Caches recently-read file contents to avoid redundant disk I/O.
--- Inspired by Zed's last_loaded_file deduplication in semantic_index.rs.

local lru = require("andrew.vault.lru_cache")
local config = require("andrew.vault.config")

local M = {}

--- @class FileCache
--- @field _cache table LRU cache instance
--- @field _hits number Cache hit count
--- @field _misses number Cache miss count

local _cache = nil
local _section_cache = nil
local _hits = 0
local _misses = 0

--- Initialize caches (lazy, on first use).
local function ensure_init()
  if _cache then return end
  _cache = lru.new(config.cache.file_content_max or 100)
  _section_cache = lru.new(config.cache.section_cache_max or 200)
end

--- Read file content, returning cached version if mtime unchanged.
--- Uses io.open + file:lines() to match engine_file_io.read_file_lines() behavior.
--- @param path string Absolute file path
--- @param max_lines number|nil Optional line limit
--- @return string[]|nil lines, number|nil mtime
function M.read(path, max_lines)
  ensure_init()
  local stat = vim.uv.fs_stat(path)
  if not stat then return nil, nil end

  local mtime = stat.mtime.sec

  -- Check cache (only use cached result if no max_lines or cached without limit)
  local cached = _cache:get(path)
  if cached and cached.mtime == mtime and not max_lines then
    _hits = _hits + 1
    return cached.lines, mtime
  end

  -- Cache miss — read from disk (same method as engine_file_io.read_file_lines)
  _misses = _misses + 1
  local file, err = io.open(path, "r")
  if not file then return nil, nil end

  local lines = {}
  for line in file:lines() do
    lines[#lines + 1] = line
    if max_lines and #lines >= max_lines then break end
  end
  file:close()

  -- Only cache unlimited reads (partial reads would produce incomplete entries)
  if not max_lines then
    _cache:put(path, { lines = lines, mtime = mtime })
  end

  return lines, mtime
end

--- Get cached section, or extract and cache.
--- @param path string Absolute file path
--- @param fragment string Heading name or ^blockid
--- @param extract_fn function(lines, fragment) → string[]
--- @return string[]|nil section_lines
function M.get_section(path, fragment, extract_fn)
  ensure_init()
  local stat = vim.uv.fs_stat(path)
  if not stat then return nil end

  local mtime = stat.mtime.sec
  local key = path .. "\0" .. fragment

  local cached = _section_cache:get(key)
  if cached and cached.mtime == mtime then
    return cached.lines
  end

  -- Read file (uses file cache above)
  local lines = M.read(path)
  if not lines then return nil end

  -- Extract section
  local section = extract_fn(lines, fragment)
  if not section then return nil end

  -- Cache
  _section_cache:put(key, { lines = section, mtime = mtime })

  return section
end

--- Invalidate a specific file (e.g., after writing).
--- Also invalidates any cached sections from that file.
--- @param path string
function M.invalidate(path)
  if not _cache then return end
  _cache:remove(path)
  -- Invalidate sections from this file (scan section cache keys)
  local prefix = path .. "\0"
  local to_remove = {}
  for key, _ in _section_cache:entries() do
    if type(key) == "string" and key:sub(1, #prefix) == prefix then
      to_remove[#to_remove + 1] = key
    end
  end
  for _, key in ipairs(to_remove) do
    _section_cache:remove(key)
  end
end

--- Invalidate all cached content.
function M.clear()
  if not _cache then return end
  _cache:clear()
  _section_cache:clear()
  _hits = 0
  _misses = 0
end

--- Get cache statistics.
--- @return table { file_size, file_max, section_size, section_max, hits, misses, hit_rate }
function M.stats()
  ensure_init()
  local total = _hits + _misses
  return {
    file_size = _cache:size(),
    file_max = config.cache.file_content_max or 100,
    section_size = _section_cache:size(),
    section_max = config.cache.section_cache_max or 200,
    hits = _hits,
    misses = _misses,
    hit_rate = total > 0 and (_hits / total * 100) or 0,
  }
end

return M
```

Key differences from previous design:
- **Direct `require`** of `lru_cache` (no lazy require / pcall fallback — `lru_cache.lua` already exists, lines 1-95)
- **Uses `io.open` + `file:lines()`** to match `engine_file_io.read_file_lines()` behavior
- **Respects `max_lines`** parameter but only caches unlimited reads
- **Section invalidation** scans for keys with matching path prefix via `lru:entries()`
- **Config-driven sizes** via `config.cache.file_content_max` and existing `config.cache.section_cache_max`
- **No circular deps**: file_cache requires only `lru_cache` and `config` — safe to require from `link_utils.lua`
  (unlike `engine.lua` which link_utils cannot require; see link_utils.lua:226-228)
- **Precedent**: `export.lua:13-20` already implements a simple `_export_file_cache` dict pattern
  for caching file reads during exports; this is the proper LRU-bounded, mtime-validated version

### 2. Registration with Engine Cache System

Register file_cache with the existing centralized cache registry in `engine.lua` (`register_cache()` at
engine.lua:49-53):

```lua
-- MUST be done from a module that can require both file_cache and engine without
-- circular deps — NOT from file_cache.lua itself, because link_utils requires
-- file_cache, and engine requires link_utils (circular dep).
-- Pattern: 16 existing caches register from their own modules (e.g., embed_images.lua:51,
-- connections.lua:962, calendar.lua:675) — file_cache is the exception due to the
-- engine → link_utils → file_cache chain.
local file_cache = require("andrew.vault.file_cache")
local engine = require("andrew.vault.engine")

engine.register_cache({
  name = "file_content",
  module = "file_cache",
  invalidate = function() file_cache.clear() end,
  invalidate_file = function(path) file_cache.invalidate(path) end,
  stats = function()
    local s = file_cache.stats()
    return { entries = s.file_size, max = s.file_max, hits = s.hits, misses = s.misses }
  end,
})
```

This integrates with:
- `engine.invalidate_caches({ scope = "files", paths = { path } })` (engine.lua:57-110) — per-file invalidation
- `engine.cache_stats()` (engine.lua:114-124) / `engine.cache_debug()` (engine.lua:140-254) — unified reporting
- `:VaultCacheStatus` / `:VaultCacheInvalidate` commands

### 3. Integration with preview.lua

The preview pipeline resolves content through `preview/target.lua` → `link_utils.resolve_content()`.
The full call chain for cross-file previews:

```
target.resolve(details, parent_buf)              [target.lua:19-47]
  → wikilinks.resolve_link(details.name)           [target.lua:37] (cached ✓)
  → link_utils.resolve_content(details, path)      [target.lua:40 → link_utils.lua:357]
    → read_heading_section → read_all_lines → io.open   (heading path)
    → read_block_content   → read_all_lines → io.open   (block path)
    → engine.read_file_lines                             (full-file path, link_utils.lua:400)
```

Same-file previews (`[[#heading]]`, `[[^block]]`) use `nvim_buf_get_lines()` [target.lua:33] — no disk I/O.
Nested preview navigation uses `target.resolve_in_preview()` [target.lua:55-72].

```lua
local file_cache = require("andrew.vault.file_cache")

-- AFTER — two integration options:

-- Option A: Cache at the link_utils.resolve_content() level (broader impact)
-- In link_utils.lua, modify resolve_content() to use file_cache.read() instead of
-- engine.read_file_lines(), and file_cache.get_section() for heading/block:
-- No circular dep: file_cache requires only lru_cache + config (not engine)
local lines = file_cache.read(source)  -- instead of engine.read_file_lines(source)
local section = file_cache.get_section(source, heading, extract_heading_fn)
-- Also replace read_all_lines() calls in read_heading_section/read_block_content

-- Option B: Cache at the target.lua level (preview-specific, safer)
-- In target.lua, cache the resolved PreviewTarget content by path+fragment+mtime
```

**Recommended:** Option A — caching inside `link_utils.resolve_content()` benefits both
preview and embed systems with a single change point. This is safe because `file_cache.lua`
requires only `lru_cache` and `config` (no circular dep with engine.lua).

### 4. Integration with embed.lua

The embed pipeline reads cross-file content through `embed_resolver.resolve_embed_lines()`
(embed_resolver.lua:66-177) → `get_embed_content()` (embed_resolver.lua:29-41) →
`link_utils.resolve_content()`:

```lua
-- In link_utils.resolve_content() [line 357]:
-- Three I/O paths to cache:

-- Path 1 (heading): read_heading_section [line 250] → read_all_lines [line 231] → io.open
-- BEFORE:  local lines = read_all_lines(source)
-- AFTER:   local lines = file_cache.read(source)

-- Path 2 (block):   read_block_content [line 290] → read_all_lines [line 231] → io.open
-- BEFORE:  local lines = read_all_lines(source)
-- AFTER:   local lines = file_cache.read(source)

-- Path 3 (full file): engine.read_file_lines(source, limit) [line 400]
-- BEFORE:  local lines = engine.read_file_lines(source, limit)
-- AFTER:   local lines = file_cache.read(source)

-- Or use file_cache.get_section() for paths 1 & 2 to cache extracted sections directly.
```

**No separate BufWritePost autocmd needed** — invalidation is already handled by the
consolidated autocmd in `init.lua` (lines 660-669, augroup "VaultCacheInvalidation" at
line 657) which calls `engine.invalidate_caches({ scope = "files", paths = { bufpath } })`
on BufWritePost, FileChangedShellPost, BufDelete, and BufWipeout for `*.md` files. The
file_cache just needs to be registered with `engine.register_cache()` (see section 2).

### 5. Cache Warming for Visible Embeds

```lua
--- Pre-read files referenced by embeds in current buffer.
--- Called before render_embeds() in render pipeline.
--- build_descriptors() [embed.lua:134] already extracts embed targets without I/O.
local function warm_embed_cache(descs, bufpath)
  local file_cache = require("andrew.vault.file_cache")
  local seen = {}
  for _, desc in ipairs(descs) do
    if not desc.is_image then
      local path = resolver.resolve_embed(desc.inner, bufpath)
      if path and path ~= bufpath and not seen[path] then
        seen[path] = true
        file_cache.read(path)  -- Populate cache for subsequent render
      end
    end
  end
end
```

**Note:** Same-file embeds (`path == bufpath`) already use `nvim_buf_get_lines()` and
skip disk I/O entirely (embed.lua:236-237), so warming is only needed for cross-file
targets. The resolver path resolution uses `wikilinks.resolve_link()` via
`resolver.resolve_embed()` (embed_resolver.lua:16-21).

## Configuration

Add to existing `config.cache` section (config.lua lines 815-823):

```lua
M.cache = {
  -- ... existing entries (8 keys) ...
  slug_max = 2000,
  date_parse_max = 5000,
  connections_max = 500,
  section_cache_max = 200,       -- Already exists, reuse for file_cache sections
  note_data_max = 1000,
  display_width_max = 2000,
  bfs_traversal_max = 100,
  image_path_max = 500,
  file_content_max = 100,        -- NEW: Max cached file contents
}
```

Also add to `LRU_CONFIG_KEYS` in engine.lua (lines 129-135) for debug reporting.
Current keys: connections, slug, date_parse, section_cache, note_data. Add:
```lua
{ ..., file_content = "file_content_max" }
```

## Zed Reference

From `crates/editor/src/code_context_menus.rs`:

```rust
// CompletionsMenu struct (lines 195-213):
pub struct CompletionsMenu {
    // ... 16 fields total ...
    markdown_cache: Rc<RefCell<VecDeque<(MarkdownCacheKey, Entity<Markdown>)>>>,  // line 213
    // ...
}

// MarkdownCacheKey enum (lines 220-227):
#[derive(Clone, Debug, PartialEq)]
enum MarkdownCacheKey {
    ForCandidate { candidate_id: usize },                              // lines 221-223
    ForCompletionMatch { new_text: String, markdown_source: SharedString },  // lines 224-227
}

// Constants (lines 53-55):
const MARKDOWN_CACHE_MAX_SIZE: usize = 16;
const MARKDOWN_CACHE_BEFORE_ITEMS: usize = 2;
const MARKDOWN_CACHE_AFTER_ITEMS: usize = 2;
```

Key patterns:
- **Ring buffer** (`VecDeque`, max 16 entries) — `rotate_right(1)` used at line 653 (rendering) and
  line 695 (capacity eviction); when not full, `push_front()` (line 686)
- **Multi-key lookup** (`get_or_create_markdown`, lines 606-701):
  Phase 1: search by `candidate_id` (ForCandidate, lines 616-623)
  Phase 2 fallback: search by `markdown_source` (lines 625-630), then heuristic by `new_text` (lines 631-640)
- **Cache preservation** (`preserve_markdown_cache`, lines 1153-1179): converts `ForCandidate` keys to
  `ForCompletionMatch` keys via `retain_mut()` when menu updates, enabling cross-menu reuse
- **Proactive preloading** (`start_markdown_parse_for_nearby_entries`, lines 568-584): uses
  `util::wrapped_usize_outward_from()` to parse documentation for 2 items before/after selection
  in an outward spiral pattern

From `crates/semantic_index/src/semantic_index.rs`:
```rust
// Single-file deduplication cache (line 109):
let mut last_loaded_file: Option<(Entity<Worktree>, Arc<Path>, PathBuf, String)> = None;

// Cache hit check (lines 114-120):
if let Some(last_loaded_file) =
    last_loaded_file
        .as_ref()
        .filter(|(last_worktree, last_path, _, _)| {
            last_worktree == &result.worktree && last_path == &result.path
        })
{
    // Cache hit — reuse content (lines 121-122)
    full_path = last_loaded_file.2.clone();
    file_content = &last_loaded_file.3;
} else {
    // Cache miss — load from disk, replace cache entry (lines 123-145)
    last_loaded_file = Some((worktree, path, full_path, content));
}
```

Key patterns:
- Results **pre-sorted** by score (desc) → worktree ID → path → range start (lines 98-107)
  to maximize consecutive cache hits from a single-entry buffer
- **Adjacent row range merging** (lines 177-185): if `prev_result.row_range.end() + 1 == start_row`
  and same file, extends range and appends content instead of creating new result
- **Max scores map** (lines 87-96) built first to track highest score per `(worktree, path)` tuple

## Expected Impact

| Operation | Before | After | Savings |
|-----------|--------|-------|---------|
| Preview same note (K, dismiss, K) | 2 io.open reads | 1 read + 1 cache hit | 50% I/O |
| 10 embeds on BufEnter (3 unique files) | 10 io.open reads | 3 reads + 7 hits | 70% I/O |
| Navigate between 2 notes repeatedly | N io.open reads | 2 reads total | ~90% I/O |
| Embed re-render on BufEnter (unchanged) | Full re-read | mtime check only | ~95% I/O |

**Total I/O reduction:** 50-90% for typical preview/embed workflows.
**Memory cost:** ~100 cached files × ~5 KB avg = ~500 KB (bounded by LRU).

**Note:** Embed lazy rendering already reduces synchronous I/O cost — only visible embeds
block the UI. The file cache primarily helps when navigating back to buffers with
previously-rendered embeds and when re-previewing the same notes.

## Testing Strategy

1. Open preview (K), dismiss, open same preview — verify second is faster (no disk read)
2. Edit target file, save, open preview — verify updated content shown (mtime invalidation)
3. Open buffer with 10 embeds, navigate away and back — verify faster re-render
4. Check `:VaultCacheStatus` — file_content cache should appear with hit/miss stats
5. Stress: open 200 different previews — verify cache stays bounded at `config.cache.file_content_max`
6. External edit: modify file outside Neovim, open preview — verify fresh content (mtime catches it)
7. Verify `engine.invalidate_caches({ scope = "files", paths = {p} })` clears file_cache entry

## Dependencies

- **Uses** `lru_cache.lua` (lines 1-96) — full API: new, get, put, clear, remove, entries, size
- **Registers with** `engine.register_cache()` (engine.lua:49-53) — from a non-circular module, NOT file_cache.lua
  (16 existing caches register from their own modules; file_cache is the exception due to circular dep chain)
- **Hooks into** existing BufWritePost invalidation in `init.lua` (lines 660-669, augroup at 657)
- **Config** extends existing `config.cache` section (config.lua:815-823, currently 8 keys)
- **Modifies** `link_utils.resolve_content()` (line 357) — single integration point for both preview and embed
  - Also affects `read_all_lines()` (line 231) used by heading/block extraction
- **No new autocmds** — leverages consolidated invalidation group in `init.lua`
- **No circular deps** — file_cache requires only lru_cache + config (safe for link_utils to require)
- **Also exists** `gen_cache.lua` — generation-based cache factory (alternative pattern, not used here)

## Risk Assessment

- **Low risk:** Mtime validation ensures stale content never displayed
- **Edge case:** File modified externally without BufWritePost — caught by mtime check on next read
- **Edge case:** FocusGained after external sync — handled by existing 200ms debounced invalidation in init.lua (lines 671-688)
- **Memory:** Bounded by LRU max (100 files × ~5 KB = 500 KB)
- **Concurrency:** Single-threaded Neovim, no race conditions
- **Embed lazy mode:** File cache complements (not conflicts with) lazy rendering — cached reads are still faster than uncached even in async batches
