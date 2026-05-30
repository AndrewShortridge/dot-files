# 57 --- Completion System Optimizations

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

Targeted improvements for the blink.cmp completion sources, addressing
debounce misalignment with the vault index, coroutine over-yielding for
small vaults, and redundant field accumulation across sources.

---

## 1. Debounce Alignment with Index Updates — IMPLEMENTED

> **Status:** IMPLEMENTED. `debounce_ms` increased to 250ms. Index-building
> guard added to both legacy and coroutine paths with 30s timeout fallback
> using module-level `_building_first_seen` tracker.

### Problem Analysis

**File:** `lua/andrew/vault/config.lua` (lines 397-407)

The completion debounce is set to 100ms while the index watch debounce is
500ms:

```lua
M.completion = {
  debounce_ms = 100,
  batch_size = 50,
}

M.index = {
  watch_debounce_ms = 500,
  persist_debounce_ms = 5000,
}
```

During an async index build, the vault index generation increments on each
batch. The completion system detects generation changes every 100ms, causing
multiple cache invalidations and rebuilds during a single index build cycle.

For a 1000-file vault with batch_size=50, the index build takes ~20 batches.
Each batch increment triggers completion cache invalidation → rebuild cycle
at 100ms intervals, producing 10+ wasted rebuild attempts while the index
is still building.

### Proposed Solution

Increase `completion.debounce_ms` to 250ms and add an "index building" guard
that suppresses completion rebuilds while `vault_index.is_building()` is true.

### Code Changes

**File: `lua/andrew/vault/config.lua`**

```lua
M.completion = {
  debounce_ms = 250,  -- Was 100; aligned closer to index update cadence
  batch_size = 50,
}
```

**File: `lua/andrew/vault/completion_base.lua`** (in the debounce callback)

```lua
-- Before starting a rebuild, check if index is still building
local function should_rebuild(vault_path)
  local idx = vault_index.current()
  if idx and idx._building then
    -- Index is mid-build; defer rebuild until build completes
    return false
  end
  return true
end
```

### Expected Performance Improvement

During a 20-batch index build:

- **Before:** ~10 completion cache rebuilds (100ms debounce vs 500ms build)
- **After:** 0-1 rebuilds during build, 1 final rebuild when build completes
- Eliminates ~90% of wasted completion work during index initialization

### Risk Assessment

- **Increased latency:** 250ms vs 100ms adds 150ms to first completion
  after a file edit. This is generally imperceptible during typing.
- **Index building guard:** If `_building` is never cleared (bug), completions
  would never rebuild. Add a timeout fallback: if `_building` has been
  true for >30s, ignore the guard.

---

## 2. Adaptive Coroutine Batch Sizing — IMPLEMENTED

> **Status:** IMPLEMENTED. `effective_batch_size()` computes adaptive batch
> size capping yields at 3. Applied in coroutine path before creating the
> coroutine, using `vim.tbl_count(idx.files)` as the estimate.

### Problem Analysis

**File:** `lua/andrew/vault/completion_base.lua` (lines 196-236)

The coroutine-based build yields every `batch_size` (default 50) items:

```lua
local co = coroutine.create(function()
  local count = 0
  for item in iter do
    items[#items + 1] = item
    count = count + 1
    if count % batch_size == 0 then
      coroutine.yield()
    end
  end
end)
```

Each yield schedules a `vim.schedule()` callback, which costs an event loop
tick (~1-2ms overhead). For a 500-file vault with batch_size=50, this
produces 10 yields = 10-20ms of scheduling overhead. The overhead may exceed
the actual computation time.

### Proposed Solution

Use adaptive batch sizing: for small vaults, increase the batch to minimize
yields. Cap at 3 yields maximum for any vault size.

### Code Changes

**File: `lua/andrew/vault/completion_base.lua`**

```lua
-- Before:
local batch_size = config.completion.batch_size or 50

-- After: adaptive sizing
local function effective_batch_size(estimated_items)
  local configured = config.completion.batch_size or 50
  if estimated_items <= 0 then return configured end
  -- Target max 3 yields per build
  return math.max(configured, math.ceil(estimated_items / 3))
end

-- In the timer callback, before starting coroutine:
local idx = vault_index.current()
local est_count = idx and vim.tbl_count(idx.files) or 0
local batch_size = effective_batch_size(est_count)
```

For synchronous sources (tags, frontmatter, inline_fields), skip the
coroutine entirely if the item count is small:

```lua
-- In create_source(), for non-iter (callback) sources:
-- These already run synchronously. No change needed.
-- The coroutine path is only for build_iter sources (wikilinks).
```

### Expected Performance Improvement

- **500-file vault:** batch_size increases to 167 → 3 yields instead of 10
  (saves ~14ms scheduling overhead)
- **100-file vault:** batch_size increases to 100 → 1-2 yields instead of 2
- **2000-file vault:** batch_size stays at 667 → 3 yields (manageable UI
  blocking per yield)

### Risk Assessment

- **Larger batches = longer UI blocks:** Each yield lets the event loop
  process. With 667-item batches, each coroutine step may take 5-10ms.
  This is still under the 16ms frame budget.
- **vim.tbl_count overhead:** Called once per build to estimate count.
  For 2000 files, this is ~0.1ms — negligible.

---

## 3. Memoized Field Accumulation — IMPLEMENTED

> **Status:** IMPLEMENTED. `_field_cache` memoizes by `(vault_path, field_name,
> generation)`. Cache cleared in `invalidate_all()`. Eliminates redundant
> vault scans across keystroke cycles within the same generation.

### Problem Analysis

**File:** `lua/andrew/vault/completion_base.lua` (lines 324-351)

`accumulate_fields()` iterates through ALL vault index entries to collect
field names and values. It's called by:

- `completion_frontmatter.lua` with `field_name = "frontmatter"`
- `completion_inline_fields.lua` with `field_name = "inline_fields"`

Both sources invalidate on the same index generation change, causing two
independent full-vault scans when both need rebuilding simultaneously.

```lua
function M.accumulate_fields(idx, field_name)
  local field_counts = {}
  local field_values = {}
  for _, entry in pairs(idx.files) do       -- Full vault iteration
    local fields = entry[field_name]
    if fields then
      for key, val in pairs(fields) do       -- All fields per entry
        field_counts[key] = (field_counts[key] or 0) + 1
        -- ... value collection ...
      end
    end
  end
  return field_counts, field_values
end
```

### Proposed Solution

Memoize `accumulate_fields()` results by `(vault_path, field_name, index_generation)`.

### Code Changes

**File: `lua/andrew/vault/completion_base.lua`**

```lua
local _field_cache = {}  -- "vault_path\0field_name" -> { gen, counts, values }

function M.accumulate_fields(idx, field_name)
  local vault_path = idx._vault_path or ""
  local cache_key = vault_path .. "\0" .. field_name
  local gen = idx._generation or 0

  local cached = _field_cache[cache_key]
  if cached and cached.gen == gen then
    return cached.counts, cached.values
  end

  -- ... existing accumulation logic ...

  _field_cache[cache_key] = { gen = gen, counts = field_counts, values = field_values }
  return field_counts, field_values
end
```

### Expected Performance Improvement

When both frontmatter and inline_fields sources invalidate together (common
case — any file edit bumps generation):

- **Before:** 2 full vault scans (one per field_name)
- **After:** Each field_name scanned once per generation; if both invalidate
  in the same cycle, only 2 scans total (unchanged), but subsequent calls
  within the same generation are free

The main benefit is across **multiple completion trigger cycles** within the
same index generation (user typing multiple characters before next file save).

- **Before:** Each keystroke that triggers rebuild → full vault scan
- **After:** First keystroke → scan; subsequent keystrokes → cache hit

For a 2000-file vault, this saves ~4ms per cache hit.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Debounce Alignment (#1) | Low | High | Low |
| 2 | Adaptive Batch Sizing (#2) | Low | Medium | Low |
| 3 | Memoized Field Accumulation (#3) | Low | Medium | Low |

All three are low effort and can be implemented independently.

---

## Testing Strategy

### Debounce Alignment (#1)
1. Edit a file during initial index build. Verify completion doesn't
   thrash (monitor with `:VaultCompletionDebug`).
2. After build completes, verify completion items appear within 300ms.

### Adaptive Batch Sizing (#2)
1. On a 100-file vault, verify 1-2 coroutine yields (log yield count).
2. On a 2000-file vault, verify 3 yields.
3. Check that UI remains responsive during builds (no frame drops).

### Memoized Field Accumulation (#3)
1. Trigger frontmatter completion twice without editing. Verify second
   call uses cache (log cache hit/miss).
2. Edit a file. Verify next completion triggers fresh accumulation.

---

## Related Documents

- Doc 66-completion-build-efficiency covers completion build pipeline optimizations (complementary).
- Doc 76-index-build-merge-precomputation #3 covers generation-cached aggregate queries (`all_tags()`, `all_frontmatter_keys()`) at the vault index level. That optimization is complementary to #3 here: Doc 76 caches vault-level aggregates, while #3 here caches the completion-specific `accumulate_fields()` results that build on those aggregates.
