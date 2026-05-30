# 02 — Bounded Caches & Eviction Policies

## Priority: HIGH
## Estimated Effort: Small (touches 2 modules)

## Problem

Several caches grow without bounds during a session:

| Cache | Module | Growth Pattern | Cleanup Trigger | Current Status |
|-------|--------|---------------|-----------------|----------------|
| `_image_cache` | embed_images.lua | Per unique image name+dir | Generation change clears all | **Unbounded** |
| `_section_cache` | search_filter/match_field.lua | Per file searched | Generation change + LRU eviction | **Already bounded (LRU)** |
| `_domain_last_request` | url_validate.lua | Per unique domain | Never | **Unbounded** |
| `_code_exclusion_cache` | link_scan.lua | Per buffer opened | Tick-based + BufDelete/BufWipeout | **Already cleaned** |
| `_frontmatter_cache` | link_scan.lua | Per buffer opened | Tick-based + BufDelete/BufWipeout | **Already cleaned** |
| `_fn_cache` | footnotes.lua | Per buffer with footnotes | Tick-based + BufDelete/BufWipeout | **Already cleaned** |

**Already resolved**: `link_scan.lua` has `BufDelete`/`BufWipeout` autocmds (via `M.clear_cache(bufnr)`
at lines 165-168) that remove both `_code_exclusion_cache[bufnr]` (line 10) and
`_frontmatter_cache[bufnr]` (line 11) — autocmd at lines 170-172. Similarly,
`footnotes.lua` has `BufDelete`/`BufWipeout` autocmds (lines 640-646, inside `M.setup()`,
augroup `"VaultFootnotes"`) that clear both `_fn_cache[bufnr]`
(line 20) and `footnotes_visible[bufnr]` (line 19). Both modules also use changedtick-based validation for cache freshness.

**Already resolved**: `_section_cache` in `match_field.lua` (line 49) now uses
`lru.new(config.cache.section_cache_max)` with generation-based invalidation preserved
via `M.maybe_invalidate_section_cache(index)` (lines 54-60). Max size configured at
`config.cache.section_cache_max = 200` (config.lua line 776).

**Remaining work**: Two caches still lack bounds — `_image_cache` and
`_domain_last_request`. In a long session touching many files/URLs, these accumulate entries
that are never evicted.

## Zed Inspiration

Zed enforces bounds on every cache using a variety of strategies:

- **Manual LRU**: `SimpleLruCache` in `crates/gpui/examples/image_gallery.rs` (lines 166-189) — tracks access order in a `usages` Vec, evicts oldest entry when `max_items` exceeded; wrapped by `SimpleLruCacheProvider` (lines 140-164); `ImageCache` trait with `load()` method implements LRU eviction (lines 217-226)
- **Dual-bounded queue**: `SummaryBacklog` in `crates/semantic_index/src/summary_backlog.rs` (lines 1-50) — drains when either `MAX_FILES_BEFORE_RESUMMARIZE: 4` (line 5) or `MAX_BYTES_BEFORE_RESUMMARIZE: 1_000_000` (line 6, 1MB) exceeded; struct at lines 8-14 with `needs_drain()` at lines 29-34; uses cached `total_bytes` field to avoid full map traversal
- **Result limits**: `MAX_SEARCH_RESULT_FILES: 5_000` and `MAX_SEARCH_RESULT_RANGES: 10_000` in `crates/project/src/project.rs` (lines 146-147) — stops collecting when either limit hit; used in search boundary checks (lines 3848-3850)
- **VecDeque with capacity**: `MAX_STORED_LOG_ENTRIES: 2000` in `crates/language_tools/src/lsp_log.rs` (line 28) — while-loop pops front entries when full; `VecDeque::with_capacity` at lines 394-395, 535; `pop_front()` bounds at lines 479-480, 681-682, 698-699. Same pattern in DAP logs (`RpcMessages::MESSAGE_QUEUE_LIMIT: 255` in `crates/debugger_tools/src/dap_log.rs` line 101, `VecDeque::with_capacity` at line 107; uses `drain(..excess)` for bulk removal at lines 341-346)
- **Viewport-bounded search**: `MAX_SEARCH_LINES: 100` in `crates/terminal/src/terminal_hyperlinks.rs` (line 187, local to `visible_regex_match_iter()`) — restricts regex search to viewport ± 100 lines (lines 189-194)
- **Bounded channels**: `channel::bounded(128..2048)` throughout `crates/semantic_index/` — capacities: 128 (deleted entries in `embedding_index.rs:104,189`), 512 (updated entries in `embedding_index.rs:103,188`, embedded files in `embedding_index.rs:283`, summarized entries in `summary_index.rs:256,290,366,492,655`), 1024 (chunks/summaries in `project_index.rs:234,413`), 2048 (chunked files in `embedding_index.rs:234`, digest in `summary_index.rs:424`); producer-consumer backpressure prevents memory bloat
- **Batch flush**: Telemetry queue in `crates/client/src/telemetry.rs` (lines 56-66) — `MAX_QUEUE_LEN: 5` (debug, line 57) / `50` (release, line 60) via `#[cfg(debug_assertions)]`, with `FLUSH_INTERVAL: 1s` (debug, line 63) / `5min` (release, line 66)
- **Ring buffer**: Terminal scroll history — `MAX_SCROLL_HISTORY_LINES: 100_000` (public const) and `DEFAULT_SCROLL_HISTORY_LINES: 10_000` in `crates/terminal/src/terminal.rs` (lines 335-336); applied to terminal builder at lines 432-441 (tasks get `MAX_SCROLL_HISTORY_LINES`, regular terminals default to `DEFAULT_SCROLL_HISTORY_LINES` capped at max)

The principle: **every cache has a maximum size, and every cache has a cleanup path**.

## Current Infrastructure

### Existing bounded cache patterns

Several modules already implement bounded caches with different strategies:

| Module | Pattern | Max Size | Eviction |
|--------|---------|----------|----------|
| `slug.lua` | LRU cache | `config.cache.slug_max = 2000` | LRU eviction via `lru.new()` (line 9) |
| `date_utils.lua` | LRU cache | `config.cache.date_parse_max = 5000` | LRU eviction via `lru.new()` (line 89); simple memoization of ISO datetime parsing |
| `connections.lua` | LRU cache + generation + TTL + deps | `config.cache.connections_max = 500` | LRU eviction (line 31) + generation check + TTL (`config.connections.cache_ttl = 60s`) + selective invalidation via dependency tracking using `entries()` iteration (lines 869-883) |
| `search_filter/match_field.lua` | LRU cache + generation | `config.cache.section_cache_max = 200` | LRU eviction + full clear on generation change (line 49) |
| `search_history.lua` | Frecency pruning | Configurable `max_entries` | Prunes bottom 10% by frecency score; `MAX_TIMESTAMPS = 10` per query |
| `preview/history.lua` | FIFO stack | `config.preview.history_max` | `table.remove(entries, 1)` on overflow (line 26) |
| `completion_base.lua` | Generation-aware | N/A (rebuilds on generation change) | Full rebuild when `vault_index._generation` advances (line 133); coroutine-based chunked build with `batch_size` yielding |

`slug.lua`, `date_utils.lua`, `connections.lua`, and `match_field.lua` use the shared
`lru_cache` module (`lru_cache.lua` — API: `new`, `get`, `put`, `clear`, `size`, `remove`,
`entries`). The others implement bounding inline.

### Existing cache visibility

`:VaultCacheStatus` (in `init.lua`, lines 716-746) reports cache health for all modules
registered via `engine.register_cache()` (defined at `engine.lua` lines 49-53, spec at
lines 28-45): entry counts, ages, TTLs, and vault path info. Cache stats collected via
`engine.cache_stats()` (lines 114-124).

`:VaultCacheInvalidate [module]` (in `init.lua`, lines 692-714) invalidates all or specific
module caches via `engine.invalidate_caches()` (lines 57-110), which also propagates to
vault index and fires a `User:VaultCacheInvalidate` autocmd.

`:VaultURLCacheStats` (in `linkdiag.lua`) reports URL validation cache statistics: total/valid/expired
entries and breakdown by status class. Backed by `M.cache_stats()` in `url_validate.lua` (lines 494-508).

### Existing config structure

Cache-related config has a dedicated `M.cache` section (config.lua lines 772-778) plus
per-module settings:
- `M.cache.slug_max` — 2000 (LRU max for slug cache)
- `M.cache.date_parse_max` — 5000 (LRU max for date parsing cache)
- `M.cache.connections_max` — 500 (LRU max for connections cache)
- `M.cache.section_cache_max` — 200 (LRU max for section outlinks cache)
- `M.cache.note_data_max` — 1000 (LRU max for note data cache)
- `M.connections.cache_ttl` — 60s TTL for related notes
- `M.url_validation.domain_rate_limit_ms` — 1000ms per-domain rate limit
- `M.url_validation.cache_ttl` — per-status-code TTLs (success: 7d, redirect: 3d, errors: 1d, network: 4h)
- `M.url_validation.cache_persist_debounce_ms` — 5000ms debounce for disk persist
- `M.completion.debounce_ms` — 250ms, `M.completion.batch_size` — 50, `M.completion.index_build_timeout_secs` — 30
- `M.index.batch_size` — 20, `M.index.persist_debounce_ms` — 5000ms

## Implementation

### 1. Image Path Cache — Add Size Limit

**File**: `lua/andrew/vault/embed_images.lua`

Current state (lines 42-49): `_image_cache = {}` (line 42, `table<string, string|false>`), keyed by
`image_name .. "\0" .. buf_dir`, values are absolute paths or `false` (negative cache for
not-found). Three generation variables manage invalidation: `_image_cache_generation` (line 45),
`_last_cache_generation` (line 46), and `_last_hit_idx` (line 49, locality heuristic for search
directory ordering).

`M.invalidate_image_cache(changed_path)` (lines 56-77) supports two modes:
- **Full invalidation** (no path): increments `_image_cache_generation`, deferred clear on next lookup
- **Selective invalidation** (with path): extracts filename via `changed_path:match("[^/]+$")`, removes only entries whose cache key filename matches
Called from `engine_watcher.lua` (lines 107-116, guarded by `get_image_exts()` check at lines 110-114) on image file changes.

`M.resolve_image(image_name, bufpath)` (lines 150-187):
1. Generation staleness check — clears cache + `_last_hit_idx` when `_last_cache_generation ~= _image_cache_generation` (lines 150-154)
2. Cache key: `image_name .. "\0" .. buf_dir` (line 157)
3. Cache hit: returns path or nil (converts `false` → nil) (lines 159-161)
4. Locality heuristic: tries `_last_hit_idx` first (lines 164-170)
5. Full search via `M.get_image_search_paths()` (lines 173-179)
6. Stores result or `false` (not-found) in cache (line 180)

```lua
-- Current: unbounded table
local _image_cache = {}

-- Proposed: LRU with generation invalidation (max 500 images)
local lru = require("andrew.vault.lru_cache")
local _image_cache = lru.new(config.cache.image_path_max)
local _image_cache_generation = 0

function M.resolve_image(image_name, bufpath)
  -- Generation check (existing pattern, preserved)
  if _image_cache_generation ~= _last_cache_generation then
    _image_cache:clear()
    _image_cache_generation = _last_cache_generation
  end

  local key = image_name .. "\0" .. buf_dir
  local cached = _image_cache:get(key)
  if cached ~= nil then
    return cached ~= false and cached or nil
  end

  -- ... resolve logic ...
  _image_cache:put(key, result or false)
  return result
end
```

**Note**: The `_last_hit_idx` locality heuristic is orthogonal to LRU bounding and should be
preserved. Selective invalidation (`invalidate_image_cache(path)`) needs adaptation for LRU API
— iterate via `_image_cache:entries()` (the `lru_cache` module supports iteration via its
`entries()` method, already used by `connections.lua` at line 876 for dependency-based
selective invalidation) and call `_image_cache:remove(key)` for matching entries.

### ~~2. Section Cache — Bound with LRU (covered in doc 01)~~

**Status: DONE** — Already implemented.

**File**: `lua/andrew/vault/search_filter/match_field.lua`

The section cache (line 49) now uses `lru.new(config.cache.section_cache_max)` with
generation-based invalidation preserved via `M.maybe_invalidate_section_cache(index)` (lines
54-60). Lazily populated by `get_section_outlinks()` (lines 189-195) which delegates to
`build_file_section_map(abs_path)` (lines 88-174, single-pass heading parser with upward
propagation of outlinks through heading hierarchy).

### 2. URL Domain Rate-Limit Cache — Add Periodic Pruning

**File**: `lua/andrew/vault/url_validate.lua`

Current state (line 13): `_domain_last_request = {}` (plain table), keyed by domain string,
values are millisecond timestamps from `vim.uv.now()`. Used by `check_rate_limit(domain)`
(lines 156-164) and `record_request(domain)` (lines 168-170). The existing
`domain_rate_limit_ms` config (1000ms, line 649) controls the per-domain minimum interval.

Separate from the URL result cache (`_cache`, lines 15-19) which already has per-status-code
TTLs and disk persistence at `{vault_path}/.vault-index/url-cache.json`. The `M._persist()`
function (lines 250-268) prunes expired entries via `cache_valid()` (lines 179-196) before
writing — this is the only cleanup path for `_cache`. Persistence is debounced (5000ms via
`M._schedule_persist()` at lines 242-248) and also runs on `VimLeavePre` (via `engine.lua`
lines 462-469).

```lua
local DOMAIN_CACHE_MAX = config.url_validation.domain_rate_limit_max or 200
local DOMAIN_ENTRY_TTL_MS = (config.url_validation.domain_rate_limit_ttl or 3600) * 1000

local function prune_domain_cache()
  local now = vim.uv.now()  -- matches existing timestamp format (ms)
  local count = 0
  for domain, last_req in pairs(_domain_last_request) do
    if now - last_req > DOMAIN_ENTRY_TTL_MS then
      _domain_last_request[domain] = nil
    else
      count = count + 1
    end
  end
  -- Hard cap fallback
  if count > DOMAIN_CACHE_MAX then
    _domain_last_request = {}
  end
end
```

Call `prune_domain_cache()` at the start of each batch validation run.

**Note**: Uses `vim.uv.now()` (milliseconds) to match the existing `record_request()` timestamps,
not `os.time()` (seconds) as previously proposed.

## Config Additions

```lua
-- config.lua — add to existing M.cache section (lines 772-778) and M.url_validation section (lines 638-676)
M.cache.image_path_max = 500

M.url_validation.domain_rate_limit_max = 200
M.url_validation.domain_rate_limit_ttl = 3600  -- seconds
```

**Note**: `domain_rate_limit_max` and `domain_rate_limit_ttl` are placed under `M.url_validation`
alongside the existing `domain_rate_limit_ms` (line 649) for consistency. `image_path_max` goes
in the existing `M.cache` section (which already contains `slug_max`, `date_parse_max`,
`connections_max`, `section_cache_max`, and `note_data_max` at lines 773-777).

## Validation

Extend the existing `:VaultCacheStatus` command (or add a separate `:VaultCacheStats`) to
report sizes of all bounded caches:

```lua
-- Output example:
-- Cache Stats:
--   slug_cache:      847/2000 entries (LRU)
--   image_cache:     42/500 entries (LRU)
--   section_cache:   12/200 entries (LRU)
--   domain_rate:     15/200 domains (TTL-pruned)
--   link_scan bufs:  3 buffers (BufDelete cleanup active)
--   footnotes bufs:  2 buffers (BufDelete cleanup active)
```

This provides visibility into cache utilization and helps tune max sizes.

## Testing

- Run `:VaultEmbedRender` on 100+ images, verify image cache stays ≤500
- Validate URLs for 300+ unique domains, verify pruning keeps count ≤200
- Open 50+ files in a session, close them all, verify buffer-keyed caches
  are empty via `:VaultCacheStats` (confirms existing BufDelete cleanup works)
