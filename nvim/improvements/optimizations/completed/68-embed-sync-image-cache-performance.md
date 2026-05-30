# 68 --- Embed Sync & Image Cache Performance

> This document is a self-contained implementation guide. Each optimization below is unique to this document.

Targeted improvements for the embed synchronization pipeline and image
resolution cache, addressing O(N*M) buffer/dependency iteration on vault
index changes, overly broad image cache invalidation, and redundant
descriptor list traversals.

> **Modules affected:** `embed_sync.lua`, `embed_images.lua`, `embed.lua`,
> `embed_state.lua`

---

## 1. Inverted Dependency Index in Embed Sync — Status: DONE

### Problem Analysis

**File:** `lua/andrew/vault/embed_sync.lua` (lines 53-62)

`M.on_index_update()` fires on every vault index change and iterates ALL
tracked embed buffers and ALL their dependencies:

```lua
for bufnr, deps in pairs(state._embed_deps) do    -- O(B) buffers
  for dep_path, _ in pairs(deps) do                 -- O(D) deps per buffer
    if changed_set[dep_path] then
      schedule_rerender(bufnr)
      break
    end
  end
end
```

For 20 open vault buffers averaging 10 embed dependencies each, every vault
index update performs 200 hash lookups. During a bulk index rebuild (touching
50+ files), this fires repeatedly.

**Complexity:** O(B * D) per index update where B = tracked buffers, D = avg
deps per buffer.

### Proposed Solution

Build an inverted index: `dep_path -> { bufnr1, bufnr2, ... }`. On index
update, iterate only the changed paths and look up affected buffers directly.

### Code Changes

**File: `lua/andrew/vault/embed_sync.lua`**

```lua
-- Module-level inverted index
local _dep_to_bufs = {}  -- dep_path -> { [bufnr] = true }

--- Rebuild inverted index from state._embed_deps.
--- Called when embed deps change (on render).
function M.rebuild_dep_index()
  _dep_to_bufs = {}
  for bufnr, deps in pairs(state._embed_deps or {}) do
    for dep_path in pairs(deps) do
      if not _dep_to_bufs[dep_path] then
        _dep_to_bufs[dep_path] = {}
      end
      _dep_to_bufs[dep_path][bufnr] = true
    end
  end
end

--- Optimized index update handler.
function M.on_index_update(changed_paths)
  local to_rerender = {}
  for _, path in ipairs(changed_paths) do
    local bufs = _dep_to_bufs[path]
    if bufs then
      for bufnr in pairs(bufs) do
        to_rerender[bufnr] = true
      end
    end
  end

  for bufnr in pairs(to_rerender) do
    schedule_rerender(bufnr)
  end
end
```

### Expected Performance Improvement

- **Before:** O(B * D) per index update (20 buffers * 10 deps = 200 lookups)
- **After:** O(changed_paths) lookups + O(affected_bufs) schedules

For a single-file save (1 changed path): 200 lookups -> 1 lookup.

### Risk Assessment

- **Inverted index staleness:** Must call `rebuild_dep_index()` whenever
  `state._embed_deps` changes (after each embed render). Add the call at
  the end of `render_embeds()`.
- **Memory:** One set per unique dep_path. For 100 unique dep paths with
  avg 2 buffers each: ~200 entries. Negligible.

---

## 2. Selective Image Cache Invalidation — Status: DONE

### Problem Analysis

**File:** `lua/andrew/vault/embed_images.lua` (lines 106-110)

On any filesystem event, the entire `_image_cache` is cleared:

```lua
function M.invalidate_cache()
  _image_cache = {}
end
```

This is called from the watcher on any file change. For a vault with 200
cached image paths, a single `.md` file save clears all 200 entries, forcing
re-resolution on the next embed render.

### Proposed Solution

Accept an optional path parameter for selective invalidation. Only clear
image cache entries matching the changed path or its directory.

### Code Changes

**File: `lua/andrew/vault/embed_images.lua`**

```lua
function M.invalidate_cache(changed_path)
  if not changed_path then
    -- Full clear (backward compatible)
    _image_cache = {}
    return
  end

  -- Only clear entries that could be affected by the change
  local dir = changed_path:match("^(.+)/[^/]*$")
  if not dir then
    _image_cache = {}
    return
  end

  for key in pairs(_image_cache) do
    -- Clear entries whose resolved path is in the same directory
    -- or entries that match the changed filename
    if key == changed_path or (_image_cache[key] and
       _image_cache[key]:find(dir, 1, true)) then
      _image_cache[key] = nil
    end
  end
end
```

### Expected Performance Improvement

- **Before:** Every file save clears all 200 cached image paths
- **After:** Only clears entries related to the changed file's directory

For typical editing (saving `.md` files), image cache entries for unrelated
directories are preserved.

### Risk Assessment

- **False negatives:** An image moved from one directory to another would
  keep a stale cache entry until the source directory is invalidated.
  Acceptable — the entry resolves to a valid path on next access.
- **Backward compatibility:** `invalidate_cache()` with no args still
  performs full clear.

---

## 3. Timer Reuse in Embed Sync Schedule — Status: DONE

### Problem Analysis

**File:** `lua/andrew/vault/embed_sync.lua` (line 14)

`schedule_rerender()` allocates a new `vim.uv.new_timer()` on every call:

```lua
function M.schedule_rerender(bufnr)
  local timer = vim.uv.new_timer()
  timer:start(delay, 0, vim.schedule_wrap(function()
    -- ...
  end))
end
```

During rapid file changes (e.g., git checkout), multiple timers are created
and discarded for the same buffer.

### Proposed Solution

Use a per-buffer timer dictionary, reusing existing timers.

### Code Changes

```lua
local _rerender_timers = {}  -- bufnr -> uv_timer_t

function M.schedule_rerender(bufnr)
  if _rerender_timers[bufnr] then
    _rerender_timers[bufnr]:stop()
  else
    _rerender_timers[bufnr] = vim.uv.new_timer()
  end

  _rerender_timers[bufnr]:start(delay, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      -- ... existing rerender logic ...
    end
  end))
end

-- Cleanup on BufDelete
vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  callback = function(ev)
    if _rerender_timers[ev.buf] then
      _rerender_timers[ev.buf]:stop()
      _rerender_timers[ev.buf]:close()
      _rerender_timers[ev.buf] = nil
    end
  end,
})
```

### Expected Performance Improvement

- **Before:** N timer allocations for N rapid changes to same buffer
- **After:** 1 timer allocation per buffer, reused across changes

Eliminates timer object churn during bulk operations.

---

## 4. Single-Pass Descriptor Processing in render_embeds — Status: DONE

### Problem Analysis

**File:** `lua/andrew/vault/embed.lua` (lines 350-368)

In lazy mode, descriptors are iterated 2-3 times:

1. **Lines 350-354:** First pass — render visible embeds
2. **Lines 357-359:** Second pass — check if any unrendered embeds remain
3. **Line 361:** Third pass — schedule async render for remaining

### Proposed Solution

Track unrendered count during the first pass using a counter, eliminating
the second scan.

### Code Changes

```lua
-- In render_embeds(), lazy mode path:
local unrendered_count = 0

for _, desc in ipairs(descriptors) do
  if is_visible(desc, top, bot) then
    render_single_embed(desc, bufnr)
  else
    unrendered_count = unrendered_count + 1
  end
end

-- Replace scan with counter check
if unrendered_count > 0 then
  schedule_async_render(remaining_descriptors, bufnr)
end
```

### Expected Performance Improvement

- **Before:** 2-3 full descriptor list iterations
- **After:** 1 iteration with counter tracking

For a buffer with 50 embeds: 100-150 iterations -> 50 iterations.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Inverted dependency index (#1) | Medium | High | Low |
| 2 | Timer reuse (#3) | Low | Medium | Low |
| 3 | Single-pass descriptors (#4) | Low | Medium | Low |
| 4 | Selective image cache (#2) | Low | Low-Medium | Low |

---

## Testing Strategy

### Inverted Dependency Index (#1)
1. Open 5 vault buffers with cross-file embeds. Edit an embedded file.
   Verify only the buffer(s) embedding that file re-render.
2. Verify no missed re-renders when an embed target is modified.
3. Close a buffer. Verify its entries are removed from the inverted index.

### Selective Image Cache (#2)
1. Open a note with 10 image embeds. Save an unrelated `.md` file.
   Verify image cache is preserved (not cleared).
2. Save an image file in `attachments/`. Verify affected cache entries clear.

### Timer Reuse (#3)
1. Trigger 10 rapid file changes. Verify only 1 timer per buffer exists.
2. Close buffer. Verify timer is cleaned up.

### Single-Pass Descriptors (#4)
1. Open a buffer with 50 embeds, 10 visible. Verify all render correctly.
2. Verify async render fires for off-screen embeds.

---

## Related Documents

- Standalone — no overlapping optimizations in other documents.
