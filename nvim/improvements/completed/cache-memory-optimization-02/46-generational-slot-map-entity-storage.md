# 46. Generational Slot Map Entity Storage

**Priority:** LOW
**Phase:** 3 (Advanced Infrastructure)
**Dependencies:** None (standalone utility module)
**Inspired by:** Zed's `crates/gpui/src/app/entity_map.rs` (SlotMap with generational IDs, ref counting, leak detection)

---

## Problem

The vault plugin uses Lua hash tables with string or number keys for all entity storage. While hash table lookups are O(1) amortized, the approach has several structural weaknesses that become relevant as vault size and session length grow.

### 1. String key hashing on every access

`vault_index.lua` stores entries in `self.files`, a hash table keyed by relative path strings (line 183). Every `self.files[rel_path]` lookup hashes the full path string. For a vault with 10K files, a full iteration (`for rel_path, entry in pairs(self.files)`) is fine, but repeated point lookups during search filtering, connection scoring, or completion building hash the same strings thousands of times per operation.

### 2. No ABA protection on path-keyed storage

When a file is deleted and a new file is created at the same path (rename via external tool, git checkout, etc.), the vault index silently replaces the old entry:

```lua
-- vault_index.lua, _apply_staged() (line 648), assignment at line 654
self.files[rel_path] = entry
```

Entries are never mutated in-place -- new entries completely replace old ones. The index tracks a runtime `_generation` counter (line 189, incremented at line 537 in `_notify_update()`) that downstream modules use for staleness detection. However, any module holding a stale reference to the old `rel_path` string will resolve to the new, unrelated entry. There is no per-entity mechanism to detect that the entity at a given key is a different entity than the one originally referenced. This is the classic ABA problem.

### 3. Buffer-keyed caches accumulate stale entries

`embed_state.lua` maintains six per-buffer dicts (lines 17-23):

```lua
M.embeds_visible = {}        -- bufnr -> boolean|"pending"
M.image_placements = {}      -- bufnr -> list of snacks placements (each tagged with _vault_lnum)
M._embed_deps = {}           -- bufnr -> { [abs_path] = true }
M._image_retry_fired = {}    -- bufnr -> boolean
M._embed_descriptors = {}    -- bufnr -> { generation, list, async_timer }
M._scroll_timers = {}        -- bufnr -> uv_timer_t
```

Additionally, `M._subscription` (line 21) is a module-level subscription handle (not bufnr-keyed), managed by embed_sync (set at embed_sync.lua line 159, checked/used at lines 169, 174-175).

These dicts are registered in a `_state_dicts` registry (line 27) with per-dict cleanup functions (lines 45-66). Cleanup is centralized through `M.clear_buffer_state(bufnr, opts)` (lines 79-98) and a GC mechanism `M.gc_stale_buffers()` (lines 101-116) that iterates all `_state_dicts`, checks `nvim_buf_is_valid()`, and calls cleanup functions for invalid buffers.

`highlight_coordinator.lua` maintains two additional per-buffer dicts:
- `_channels[bufnr]` (line 210): watch channel objects `{ send, handle }` for coalesced updates
- `_buf_caches[bufnr]` (line 215): `FrameCache` objects for dual-frame render caching

Its BufDelete cleanup (lines 488-500) also cleans up pipeline, viewport, and region_tracker state. Cache invalidation events also clear `_buf_caches[bufnr]` (line 476).

Despite these cleanup mechanisms, the fundamental risk remains: when a buffer is deleted and its `bufnr` is eventually reused by Neovim, if cleanup is incomplete (error in cleanup path, missed autocmd), the new buffer inherits stale state from the old one. There is no generational guard to detect this.

### 4. No leak detection

With hash-table storage, there is no way to determine which entities were allocated but never cleaned up. A leaked embed placement, a dangling timer reference, or an orphaned cache entry is invisible unless it causes a visible bug. Long editing sessions accumulate these silently.

Note: `embed_state.lua` does provide `M.all_tracked_buffers()` (lines 121-129) which collects all bufnr keys across all state dicts, enabling audit of tracked buffers. It also has a memoization cache `_has_embeds` (lines 214-222) with `M.has_embeds(bufnr)` (lines 229-231) for cached embed presence checks using changedtick, and a memory profiler counter registration (lines 193-207). However, these cannot identify *which* entities were allocated but never cleaned up, or provide allocation-site backtraces.

### 5. Cache locality

Lua hash tables use chained hashing internally. Iterating `pairs(t)` traverses a linked structure with poor spatial locality. For operations that scan all entities (index rebuild, connection scoring), this means cache misses on every hop between hash buckets.

---

## Zed Inspiration

### entity_map.rs: SlotMap with generational IDs

Zed's GPUI framework (`crates/gpui/src/app/entity_map.rs`) stores all application entities (views, models, subscriptions) using the `slotmap` crate (v1.0.6) rather than a `HashMap`:

```rust
// crates/gpui/src/app/entity_map.rs (lines 57-61)
pub(crate) struct EntityMap {
    entities: SecondaryMap<EntityId, Box<dyn Any>>,
    pub accessed_entities: RefCell<FxHashSet<EntityId>>,
    ref_counts: Arc<RwLock<EntityRefCounts>>,
}
```

```rust
// lines 63-68
struct EntityRefCounts {
    counts: SlotMap<EntityId, AtomicUsize>,
    dropped_entity_ids: Vec<EntityId>,
    #[cfg(any(test, feature = "leak-detection"))]
    leak_detector: LeakDetector,
}
```

`EntityId` is defined via `slotmap::new_key_type!` (lines 28-31), delegating generational ID management entirely to the slotmap crate's `KeyData` implementation.

Key design elements:

1. **Generational IDs**: Each `EntityId` encapsulates slotmap's `KeyData` which contains a slot index and a generation counter. When an entity is removed, the slot's generation is incremented. A stale ID (old generation) attempting to access the slot gets `None` instead of the wrong entity. This prevents ABA. Conversion helpers (`as_u64()`, `From<u64>`) use slotmap's FFI methods (lines 33-49).

2. **Dense array storage**: The underlying `SlotMap` stores values in a contiguous array indexed by slot number. Access is `O(1)` via direct array index -- no hashing, no probing, no string comparison.

3. **Free list reuse**: Removed slots are pushed onto a free list. New insertions pop from the free list before extending the array. This keeps the array dense and avoids fragmentation.

4. **Atomic reference counting with batch cleanup**: `ref_counts.counts` maps EntityId → AtomicUsize. Increments use `fetch_add(1, SeqCst)` (line 286, in `AnyEntity::clone`). Decrements use `fetch_sub(1, SeqCst)` (line 314, in `AnyEntity::drop`) with an `RwLockUpgradableReadGuard` pattern -- only upgrading to a write lock when the count reaches zero to push the EntityId to `dropped_entity_ids` (line 318). `take_dropped()` (lines 158-178) batch-collects entities with zero ref count for deferred cleanup, avoiding per-entity teardown overhead. The caller (`release_dropped_entities()` in `app.rs`) loops until no more drops remain, also cleaning up observers, event listeners, and release callbacks.

5. **Accessed entity tracking**: `accessed_entities: RefCell<FxHashSet<EntityId>>` tracks which entities were accessed during a frame, enabling frame-scoped invalidation. Insertions happen on `insert()` (line 99), `lease()` (line 111), and `read()` (line 133). Batch operations via `extend_accessed()` (lines 148-152) and `clear_accessed()` (lines 154-156).

6. **Entity type hierarchy**: The codebase defines multiple handle types:
   - `Entity<T>` (lines 376-381) -- strong typed reference with ref counting, uses `#[derive(Deref, DerefMut)]` to forward to `AnyEntity`
   - `AnyEntity` (lines 221-227) -- type-erased strong reference, holds `Weak<RwLock<EntityRefCounts>>` and conditional `handle_id: HandleId`
   - `WeakEntity<T>` (lines 655-660) -- weak typed reference that doesn't prevent dropping
   - `AnyWeakEntity` (lines 516-520) -- type-erased weak reference
   - `Slot<T>` (lines 217-218) -- wrapper for reserved entity slots (two-phase init)
   - `Lease<T>` (lines 189-193) -- temporary exclusive access, panics on drop if not returned via `end_lease()`

7. **Weak entity upgrades**: `atomic_incr_if_not_zero()` (defined in `crates/gpui/src/util.rs` lines 86-99, imported at entity_map.rs line 24, used at entity_map.rs line 544 in `AnyWeakEntity::upgrade()`) safely upgrades weak references by atomically trying to increment without going through zero via compare-and-swap loop. Returns `None` if the entity is already in `dropped_entity_ids`.

8. **Reserve/insert pattern**: Entity creation uses two-phase initialization -- `reserve()` (lines 88-91) allocates a slot with initial ref count of 1, then `insert()` (lines 94-104) stores the actual entity. This allows circular references during construction.

9. **LeakDetector**: Feature-gated with `#[cfg(any(test, feature = "leak-detection"))]`. Tracks per-entity handle allocations with optional backtraces (enabled via `LEAK_BACKTRACE` env var). `HandleId` (lines 793-795) is a simple `u64` wrapper:

```rust
// crates/gpui/src/app/entity_map.rs (lines 798-801, HandleId at lines 793-795)
pub(crate) struct LeakDetector {
    next_handle_id: u64,
    entity_handles: HashMap<EntityId, HashMap<HandleId, Option<backtrace::Backtrace>>>,
}
```

The detector tracks individual handle IDs per entity (not just entity-level), enabling precise identification of which clone of a handle leaked. `handle_created()` (lines 806-815) records new handles, `handle_released()` (lines 817-820) removes them, and `assert_released()` (lines 822-836) panics if handles still exist, printing backtraces when available.

---

## Proposed Design for Lua

### Core: slot_map.lua

A generational slot map implemented as a Lua module. Uses dense Lua arrays (integer-indexed tables) for storage, with a LIFO free list for slot reuse.

### Handle structure

```lua
-- A handle is a plain table with two integer fields.
-- Handles are compared by value (slot + generation), not by identity.
-- { slot = 3, generation = 7 }
```

Handles are lightweight (two numbers, one table allocation). For hot paths, handles can be encoded as a single integer (`slot * MAX_GENERATION + generation`) to avoid the table allocation entirely.

### Core Implementation

```lua
-- lua/andrew/vault/slot_map.lua

local M = {}
M.__index = M

--- Create a new generational slot map.
---@param opts? { leak_detect: boolean, name: string }
---@return table SlotMap instance
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    _slots = {},        -- array of { value, generation }
    _free_list = {},    -- LIFO stack of available slot indices
    _count = 0,         -- number of live entities
    _next_slot = 1,     -- next unallocated slot index
    _name = opts.name or "unnamed",

    -- Leak detection (debug mode only)
    _leak_detect = opts.leak_detect or false,
    _alloc_info = {},   -- slot -> { traceback, insert_time } (only when leak_detect=true)
  }, M)
end
```

### insert(value) -> handle

Allocates a slot, stores the value, returns a handle. Reuses freed slots via the free list.

```lua
--- Insert a value into the slot map.
---@param value any The value to store (must not be nil)
---@return table handle { slot = N, generation = N }
function M:insert(value)
  assert(value ~= nil, "slot_map: cannot insert nil")

  local slot
  local free_n = #self._free_list
  if free_n > 0 then
    slot = self._free_list[free_n]
    self._free_list[free_n] = nil
  else
    slot = self._next_slot
    self._next_slot = slot + 1
  end

  -- Increment generation (starts at 1 for new slots, bumps on reuse)
  local prev = self._slots[slot]
  local gen = prev and (prev.generation + 1) or 1

  self._slots[slot] = { value = value, generation = gen }
  self._count = self._count + 1

  if self._leak_detect then
    self._alloc_info[slot] = {
      traceback = debug.traceback("", 2),
      insert_time = vim.uv.hrtime(),
    }
  end

  return { slot = slot, generation = gen }
end
```

### get(handle) -> value or nil

O(1) array access. Returns `nil` if the handle's generation does not match the slot's current generation (stale handle / ABA detection).

```lua
--- Retrieve a value by handle.
--- Returns nil if the handle is stale (entity was removed and slot reused).
---@param handle table { slot, generation }
---@return any|nil value
function M:get(handle)
  local entry = self._slots[handle.slot]
  if entry and entry.generation == handle.generation then
    return entry.value
  end
  return nil
end
```

### contains(handle) -> boolean

```lua
--- Check if a handle refers to a live entity.
---@param handle table { slot, generation }
---@return boolean
function M:contains(handle)
  local entry = self._slots[handle.slot]
  return entry ~= nil and entry.generation == handle.generation
end
```

### remove(handle) -> value or nil

Frees the slot, pushes it onto the free list. The generation stays at its current value -- it will be incremented on the next `insert` into this slot.

```lua
--- Remove an entity by handle.
--- Returns the removed value, or nil if the handle was stale.
---@param handle table { slot, generation }
---@return any|nil removed_value
function M:remove(handle)
  local entry = self._slots[handle.slot]
  if not entry or entry.generation ~= handle.generation then
    return nil  -- Stale handle, entity already removed
  end

  local value = entry.value
  entry.value = nil  -- Clear value but keep generation for staleness detection

  self._free_list[#self._free_list + 1] = handle.slot
  self._count = self._count - 1

  if self._leak_detect then
    self._alloc_info[handle.slot] = nil
  end

  return value
end
```

### Iteration

```lua
--- Iterate over all live entities.
--- Yields (handle, value) pairs.
---@return function iterator
function M:iter()
  local slots = self._slots
  local i = 0
  local max = self._next_slot - 1
  return function()
    while i < max do
      i = i + 1
      local entry = slots[i]
      if entry and entry.value ~= nil then
        return { slot = i, generation = entry.generation }, entry.value
      end
    end
    return nil
  end
end

--- Return the number of live entities.
---@return integer
function M:len()
  return self._count
end
```

### Packed integer handles (optional optimization)

For hot paths where handle table allocation is a concern, encode the handle as a single Lua number. With LuaJIT's 64-bit integers or Lua 5.1's doubles (53-bit mantissa), this supports 2^20 slots and 2^33 generations -- more than sufficient.

```lua
local SLOT_BITS = 20  -- Up to ~1M slots
local GEN_MASK = 2^SLOT_BITS

--- Encode a handle as a single integer.
---@param handle table { slot, generation }
---@return integer packed
function M.pack(handle)
  return handle.generation * GEN_MASK + handle.slot
end

--- Decode a packed integer handle.
---@param packed integer
---@return table handle { slot, generation }
function M.unpack(packed)
  local slot = packed % GEN_MASK
  local generation = math.floor(packed / GEN_MASK)
  return { slot = slot, generation = generation }
end

--- Get value by packed handle (avoids table creation for lookup).
---@param packed integer
---@return any|nil value
function M:get_packed(packed)
  local slot = packed % GEN_MASK
  local generation = math.floor(packed / GEN_MASK)
  local entry = self._slots[slot]
  if entry and entry.generation == generation then
    return entry.value
  end
  return nil
end
```

### Leak Detection

On shutdown (or via debug command), report any entities that were inserted but never removed:

```lua
--- Report leaked entities (only meaningful when leak_detect=true).
---@return table[] leaks Array of { slot, generation, traceback, age_ms }
function M:detect_leaks()
  if not self._leak_detect then return {} end

  local leaks = {}
  local now = vim.uv.hrtime()
  for slot, info in pairs(self._alloc_info) do
    local entry = self._slots[slot]
    if entry and entry.value ~= nil then
      leaks[#leaks + 1] = {
        slot = slot,
        generation = entry.generation,
        traceback = info.traceback,
        age_ms = (now - info.insert_time) / 1e6,
      }
    end
  end
  return leaks
end

--- Clear all slots and report leaks if detection is enabled.
function M:destroy()
  if self._leak_detect then
    local leaks = self:detect_leaks()
    if #leaks > 0 then
      vim.schedule(function()
        for _, leak in ipairs(leaks) do
          vim.notify(
            string.format("SlotMap(%s): leaked entity at slot %d (age %.1fs)\n%s",
              self._name, leak.slot, leak.age_ms / 1000, leak.traceback),
            vim.log.levels.WARN
          )
        end
      end)
    end
  end
  self._slots = {}
  self._free_list = {}
  self._alloc_info = {}
  self._count = 0
end
```

---

## Use Cases in Vault

### 1. Per-buffer embed state management

Currently, `embed_state.lua` (lines 17-23) uses six separate `bufnr`-keyed dicts registered in a `_state_dicts` registry (line 27) with per-dict cleanup functions (lines 45-66). All access is via direct table indexing (e.g., `state._embed_descriptors[bufnr]`, `state.embeds_visible[bufnr] = true`). Cleanup is centralized through `clear_buffer_state()` (lines 79-98) and `gc_stale_buffers()` (lines 101-116).

A slot map would unify these into a single entity per buffer with generational safety, replacing the registry pattern:

```lua
-- embed_state.lua (with slot map)
local SlotMap = require("andrew.vault.slot_map")

local buf_entities = SlotMap.new({ name = "embed_buf", leak_detect = true })
local buf_handles = {}  -- bufnr -> packed handle (for quick lookup)

--- Register a buffer for embed tracking.
--- Replaces current pattern of lazily initializing each dict:
---   state.image_placements[bufnr] = state.image_placements[bufnr] or {}
---   state.embeds_visible[bufnr] = true
---@param bufnr integer
---@return table handle
function M.register_buffer(bufnr)
  -- Remove old entity if bufnr is being reused
  local old_handle = buf_handles[bufnr]
  if old_handle then
    buf_entities:remove(old_handle)
  end

  local handle = buf_entities:insert({
    bufnr = bufnr,
    visible = false,        -- was: M.embeds_visible[bufnr]
    placements = {},         -- was: M.image_placements[bufnr]
    deps = {},               -- was: M._embed_deps[bufnr]
    image_retry_fired = false, -- was: M._image_retry_fired[bufnr]
    descriptors = nil,       -- was: M._embed_descriptors[bufnr]
    scroll_timer = nil,      -- was: M._scroll_timers[bufnr]
  })
  buf_handles[bufnr] = handle
  return handle
end

--- Get embed state for a buffer. Returns nil if bufnr was never registered
--- or if the entity was removed (stale handle from bufnr reuse).
--- Replaces current direct access: state._embed_descriptors[bufnr]
---@param bufnr integer
---@return table|nil state
function M.get_buf_state(bufnr)
  local handle = buf_handles[bufnr]
  if not handle then return nil end
  return buf_entities:get(handle)
end
```

The generation check means that if buffer 42 is deleted and a new buffer 42 is created, any code holding the old handle gets `nil` instead of the new buffer's state. This replaces the current `gc_stale_buffers()` (lines 101-116) approach which relies on `nvim_buf_is_valid()` checks after the fact.

**Migration scope**: embed.lua has 27 direct state dict accesses across six dicts:
- `state._embed_deps[bufnr]`: lines 36, 664, 796, 1063, 1127 (5 sites)
- `state._embed_descriptors[bufnr]`: lines 404, 417, 538, 563, 581, 641, 894, 935, 1023 (9 sites)
- `state.image_placements[bufnr]`: lines 414, 758, 947 (3 sites)
- `state.embeds_visible[bufnr]`: lines 456, 594, 680, 786, 895, 1022, 1125 (7 sites)
- `state._image_retry_fired[bufnr]`: line 596 (1 site)
- `state._scroll_timers[bufnr]`: line 1052 (2 accesses on 1 line: read + write via `cleanup.debounce()`)

Plus 3 `state.clear_buffer_state()` calls (lines 674, 1074, 1136), 1 `state.has_embeds()` call (line 456), 3 `state.is_embed_active()` calls (lines 580, 640, 1053), 1 `state.gc_stale_buffers()` call (line 1095), and 1 `state.embeds_visible` pairs iteration (line 1099). Additionally, `state.all_tracked_buffers()` is iterated at line 1135. All would need to change from `state.foo[bufnr]` to `state.get_buf_state(bufnr).foo`. embed_sync.lua iterates `state._embed_deps` (line 30) and `state.embeds_visible` (line 109) which would become `buf_entities:iter()` calls.

### 2. Image placement lifecycle

`embed_images.lua` currently stores placements in `state.image_placements[bufnr]` as a flat list (embed_state.lua line 18). Each placement is a snacks placement object tagged with `_vault_lnum` (1-indexed line number) for viewport-aware GC (embed_images.lua line 276). Placement creation is at `M.create_placement()` (lines 262-282), cleanup at `M.clear_image_placements()` (lines 305-314) and `M.clear_image_placements_in_range()` (lines 321-341).

The module also maintains its own LRU image path cache with generation tracking (`_image_cache` at line 45, `_image_cache_generation` at line 48, plus hit/miss/eviction counters at lines 42-44) and a locality heuristic (`_last_hit_idx` at line 52). Additionally, embed_images.lua accesses other embed_state dicts: `state._image_retry_fired[bufnr]` (lines 237, 241) and `state.embeds_visible[bufnr]` (lines 238, 244, 294) for conditional rendering guards.

With a slot map, each placement gets its own handle, enabling precise stale detection:

```lua
local placement_map = SlotMap.new({ name = "img_placement" })

local function create_placement(bufnr, opts)
  local placement = Snacks.image.placement.new(buf, opts)
  placement._vault_lnum = opts.pos[1]  -- preserve existing lnum tagging
  local handle = placement_map:insert({
    placement = placement,
    bufnr = bufnr,
    created_at = vim.uv.hrtime(),
  })
  return handle
end

-- Later, when checking if a placement is still valid:
local function is_placement_alive(handle)
  local entry = placement_map:get(handle)
  if not entry then return false end  -- Stale: placement was removed
  if not vim.api.nvim_buf_is_valid(entry.bufnr) then
    placement_map:remove(handle)  -- Buffer gone, clean up
    return false
  end
  return true
end
```

### 3. Highlight coordinator per-buffer state

`highlight_coordinator.lua` manages two per-buffer dicts: `_channels[bufnr]` (line 210, watch channel objects with `{ send, handle }`) and `_buf_caches[bufnr]` (line 215, `FrameCache` objects). Accessor functions `get_channel(bufnr)` (line 245) and `get_cache(bufnr)` (line 217) provide the lookup layer.

Cleanup is handled via `cleanup.on_buf_delete()` (lines 488-500) which clears channels, caches, pipeline, viewport, and region_tracker state. VimLeavePre teardown (lines 514-521) closes all channel handles and clears both state tables.

A slot map would unify these into a single entity with generational safety against bufnr reuse:

```lua
local hl_entities = SlotMap.new({ name = "highlight" })

function M.register_buffer(bufnr)
  return hl_entities:insert({
    bufnr = bufnr,
    channel = nil,       -- was: _channels[bufnr]
    cache = nil,         -- was: _buf_caches[bufnr]
  })
end
```

### 4. Debug-mode leak detection for long sessions

Enable leak detection during development to catch cleanup bugs. The teardown path currently lives in `event_dispatch.lua` (called from `engine.lua` `M.teardown()` at lines 700-707). engine.lua already has a cache registry system (`M._cache_registry` at line 32, `M.register_cache()` at lines 52-56, with `CacheSpec` type at lines 34-39 and `CacheStats` at lines 41-48) that slot maps could integrate with. The teardown performs `profiler.shutdown()`, `url_validate.persist_now()`, and `vault_log.close()`. The teardown path currently lives at `M.teardown()` (lines 700-707), performing `profiler.shutdown()`, `url_validate.persist_now()`, and `vault_log.close()`.

```lua
-- engine.lua M.teardown() (currently at lines 700-707)
-- Add slot map cleanup alongside existing profiler.shutdown()/url_validate.persist_now()/vault_log.close() teardown:
function M.teardown()
  profiler.shutdown()
  -- ... existing cleanup ...

  -- Slot map cleanup with leak reporting
  if config.slot_map.leak_detect then
    local embed_leaks = buf_entities:detect_leaks()
    local placement_leaks = placement_map:detect_leaks()
    -- Log leak count and tracebacks via vault_log
  end
  buf_entities:destroy()
  placement_map:destroy()
end
```

---

## What NOT to Use Slot Maps For

### Path-keyed lookups (vault_index.files)

`vault_index.files` (line 183) is a hash table keyed by `rel_path`. This is the right data structure for its use case: callers have a path string and need the entry. The index already has its own change-tracking via `_generation` (line 189, incremented in `_notify_update()` at lines 536-537) and derived indexes (`_name_index`, `_alias_index`, `_inlinks` at lines 185-187, lazy caches `_name_cache`/`_sorted_names` at lines 202-203, `_summary_tree` at line 205, precomputed sets `_files_with_tags`/`_files_with_tasks`/`_files_by_type` at lines 209-211, bloom filters `_tag_blooms` at line 212, collision tracking `_collisions` at line 196, and invalidation stats `_inv_stats` at line 207). Converting to a slot map would require a separate `path -> handle` index, adding indirection with no benefit.

Slot maps are best for **entity-style** storage where items have a lifecycle (create, use, destroy) and where stale references are a concern. `vault_index.files` is a **registry** where the key is the natural identifier and entries are replaced atomically in `_apply_staged()` (line 648, staged assignments at line 654, deletions at line 661). After applying, it updates `_summary_tree` (lines 666-686) and incrementally rebuilds derived indexes (lines 689-703). Keep it as a hash table.

### Small, short-lived caches

Caches with fewer than ~20 entries (e.g., per-function memoization) do not benefit from slot map overhead. The generation check and free list management cost more than they save at small scale.

### Static configuration data

`config.lua` values are set once and read many times. No lifecycle management needed.

---

## Configuration

`config.lua` already has analogous infrastructure sections: `M.cache` (lines 815-835, count-based limits and memory-weighted byte budgets), `M.pools` (lines 857-863, table object pool capacities), `M.arena` (lines 868-872, per-render bulk table recycling), `M.intern` (lines 846-852, string intern pool limits), `M.sharing` (lines 957-960, structural sharing with debug_immutability flag), `M.profiler` (lines 964-971, memory profiling infrastructure), `M.memoize` (lines 981-983, memoized state checks), and `M.render_cache` (lines 987-999, per-buffer render cache limits).

The slot_map config should follow the same pattern:

```lua
-- config.lua additions (alongside existing M.pools, M.arena, M.sharing)
M.slot_map = {
  leak_detect = false,  -- Enable allocation tracking with backtraces (debug only)
}
```

`leak_detect` defaults to `false` because `debug.traceback()` on every insertion is expensive. Enable it during development or when investigating resource leaks. This mirrors the `M.arena.debug_validation` and `M.sharing.debug_immutability` patterns for dev-only diagnostics.

---

## Monitoring

### :VaultSlotMapDebug command

```lua
vim.api.nvim_create_user_command("VaultSlotMapDebug", function()
  local lines = { "SlotMap Status", "" }
  local maps = {
    { name = "embed_buf", map = require("andrew.vault.embed_state")._buf_entities },
    { name = "img_placement", map = require("andrew.vault.embed_images")._placement_map },
    { name = "highlight", map = require("andrew.vault.highlight_coordinator")._hl_entities },
  }
  for _, m in ipairs(maps) do
    if m.map then
      table.insert(lines, string.format(
        "%s: live=%d, slots_allocated=%d, free_list=%d",
        m.name, m.map:len(), m.map._next_slot - 1, #m.map._free_list
      ))
    end
  end

  -- Show leaks if detection is enabled
  for _, m in ipairs(maps) do
    if m.map and m.map._leak_detect then
      local leaks = m.map:detect_leaks()
      if #leaks > 0 then
        table.insert(lines, "")
        table.insert(lines, string.format("LEAKS in %s: %d entities", m.name, #leaks))
        for _, leak in ipairs(leaks) do
          table.insert(lines, string.format(
            "  slot=%d gen=%d age=%.1fs",
            leak.slot, leak.generation, leak.age_ms / 1000
          ))
        end
      end
    end
  end

  -- Display in scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.cmd.split()
  vim.api.nvim_win_set_buf(0, buf)
end, {})
```

Example output:

```
SlotMap Status

embed_buf: live=3, slots_allocated=5, free_list=2
img_placement: live=7, slots_allocated=12, free_list=5
highlight: live=3, slots_allocated=3, free_list=0

LEAKS in img_placement: 1 entities
  slot=4 gen=2 age=847.3s
```

---

## Implementation Steps

### Step 1: Create slot_map.lua module

Implement the core `SlotMap` with `new`, `insert`, `get`, `contains`, `remove`, `iter`, `len`, `destroy`. Include leak detection behind the `leak_detect` flag. No external dependencies (pure Lua utility). Place at `lua/andrew/vault/slot_map.lua`.

### Step 2: Add configuration

Add `config.slot_map.leak_detect` to `config.lua` (alongside existing `M.pools`, `M.arena`, `M.sharing` sections).

### Step 3: Migrate embed_state.lua per-buffer dicts

Replace the six separate `bufnr`-keyed dicts (lines 17-23) and the `_state_dicts` registry (line 27) with a single `SlotMap` holding a unified per-buffer state record. Maintain a thin `bufnr -> handle` index for lookup. The existing `register_state()` (lines 29-31) / `clear_buffer_state()` / `gc_stale_buffers()` cleanup infrastructure (lines 29-116) would be replaced by slot map `remove()` calls.

Update callers that use direct table access:
- `embed.lua` (27 direct dict accesses + 10 function/method calls across lines 36, 404, 414, 417, 456, 538, 563, 580, 581, 594, 596, 640, 641, 664, 674, 680, 758, 786, 796, 894-895, 935, 947, 1022, 1023, 1052, 1053, 1063, 1074, 1095, 1099, 1125, 1127, 1135, 1136) → use `M.get_buf_state(bufnr).field`
- `embed_sync.lua` (pairs iteration at lines 30, 109) → use `buf_entities:iter()`
- `embed_images.lua` (placement list access at `state.image_placements[bufnr]`, 7 access sites at lines 277-278, 306, 308, 322, 337, 339; plus cross-module accesses to `state._image_retry_fired[bufnr]` at lines 237, 241 and `state.embeds_visible[bufnr]` at lines 238, 244, 294) → access via unified state record
- `embed.lua` also calls `state.is_embed_active()` (lines 580, 640, 1053), `state.gc_stale_buffers()` (line 1095), and iterates `state.embeds_visible` via `pairs()` (line 1099)

### Step 4: Migrate image placement tracking

Move `state.image_placements[bufnr]` (embed_state.lua line 18) to a dedicated `SlotMap` where each placement is an individual entity with its own handle. Update `embed_images.lua` cleanup paths: `clear_image_placements()` (lines 305-314) and `clear_image_placements_in_range()` (lines 321-341). Preserve `_vault_lnum` tagging for viewport GC. The existing LRU image path cache (`_image_cache` at line 45) is orthogonal and unaffected.

### Step 5: Migrate highlight coordinator

Replace `_channels[bufnr]` (line 210) and `_buf_caches[bufnr]` (line 215) with a single `SlotMap`. Update accessor functions `get_channel()` (line 245) and `get_cache()` (line 217). Ensure the BufDelete handler (lines 488-500) calls `slot_map:remove()` and continues to propagate cleanup to pipeline, viewport, and region_tracker.

### Step 6: Integrate with existing cleanup infrastructure

The embed system already has `cleanup.on_buf_delete()` autocmds. Ensure these call `slot_map:remove()` for the departing buffer's handle. The highlight coordinator's BufDelete handler (lines 488-500) and VimLeavePre teardown (lines 514-521) should similarly use slot map removal. Leak detection catches any cleanup path misses.

### Step 7: Register with engine.lua cache registry

Register slot maps with `engine.register_cache()` (lines 52-56, with `CacheSpec` type at lines 34-39) so they appear in `:VaultCacheDebug` alongside existing caches. Add a `:VaultSlotMapDebug` command to report live entity counts, slot utilization, free list depth, and any detected leaks.

### Step 8: Add VimLeavePre leak report

Integrate with `engine.teardown()` (lines 700-707, called by event_dispatch.lua on VimLeavePre). Call `destroy()` on all slot maps alongside existing `profiler.shutdown()`, `url_validate.persist_now()`, and `vault_log.close()` teardown. In leak-detect mode, report any entities that survived to shutdown via vault_log.

---

## Trade-offs

| Aspect | Hash Table (current) | Slot Map (proposed) |
|--------|---------------------|---------------------|
| Lookup cost | String hash + probe | Array index + generation compare |
| ABA safety | None | Generation mismatch returns nil |
| Memory layout | Sparse hash buckets | Dense array (better locality) |
| Key type | Natural (path, bufnr) | Opaque handle (requires index) |
| Leak detection | Not possible | Built-in (debug mode) |
| Iteration order | Undefined (pairs) | Slot order (deterministic) |
| API ergonomics | `t[key]` (direct) | `map:get(handle)` (method call) |
| Overhead per entity | Hash node (~40 bytes) | Array slot (~24 bytes) + handle |

The key trade-off is **ergonomics vs safety**. Direct table access (`state.embeds_visible[bufnr]`) is simpler to write than `map:get(handle)`. The slot map adds a level of indirection. This cost is justified for entity-style storage where stale references cause bugs, but not for simple key-value lookups.

---

## Performance

| Operation | Hash Table | Slot Map |
|-----------|-----------|----------|
| Insert | O(1) amortized (may resize) | O(1) (free list pop or array extend) |
| Get | O(1) amortized (hash + probe) | O(1) (array index + integer compare) |
| Remove | O(1) amortized | O(1) (free list push) |
| Iterate all | O(capacity) via pairs | O(capacity) via sequential scan |
| GC pressure | String keys allocate | Integer handles (or packed) |

The slot map's advantage is not in asymptotic complexity (both are O(1)) but in **constant factors**: array indexing is faster than hash probing, integer comparison is faster than string comparison, and dense arrays have better cache locality for iteration.

For the vault's scale (~10K files, ~50 buffers, ~100 placements), the performance difference per operation is negligible. The real wins are:

1. **Correctness**: Generational IDs catch stale reference bugs that hash tables silently mask.
2. **Debuggability**: Leak detection surfaces resource management issues during development.
3. **Unified cleanup**: One `remove(handle)` call cleans up the entity vs clearing seven separate dicts.

---

## Risks

1. **Migration complexity**: Changing from `state.foo[bufnr]` to `state.get_buf_state(bufnr).foo` touches 27 direct dict access sites in embed.lua (plus 10 function/method calls: 3 `clear_buffer_state()`, 1 `has_embeds()`, 3 `is_embed_active()`, 1 `gc_stale_buffers()`, 1 `embeds_visible` pairs iteration, and 1 `all_tracked_buffers()` iteration), plus embed_sync.lua (pairs iterations at lines 30, 109), embed_images.lua (7 placement list access sites + 5 cross-module state accesses at lines 237-238, 241, 244, 294), and highlight_coordinator.lua (two per-buffer dicts + cache invalidation at line 476). The existing `_state_dicts` registry pattern (embed_state.lua line 27) with its cleanup functions (lines 45-66) would need to be fully replaced. Each site must be updated and tested.

2. **Handle management burden**: Callers must store and pass handles rather than natural keys. Losing a handle means the entity is leaked (unless leak detection catches it). This is a new category of bug that does not exist with hash tables. The current codebase uses pure direct table access throughout with no getter/setter abstraction -- the slot map imposes a fundamentally different access pattern.

3. **Double indirection for bufnr lookups**: Bufnr-keyed access becomes `bufnr -> handle -> slot -> value` instead of `bufnr -> value`. The extra hop is cheap but adds conceptual complexity. The current `is_embed_active(bufnr)` helper (embed_state.lua lines 71-73) would need to go through this indirection.

4. **Packed handle overflow**: With 20 slot bits, the maximum slot count is ~1M. This is far beyond the vault's needs but would silently corrupt handles if exceeded. The guard is an assertion in `insert()`.

5. **Not idiomatic Lua**: Lua code conventionally uses tables as hash maps. A slot map is an unusual pattern that requires explanation for contributors unfamiliar with the concept. The current codebase is fully idiomatic with direct `state.foo[bufnr]` access.

6. **Replacing existing cleanup infrastructure**: The current `_state_dicts` registry with per-dict cleanup functions is a working, tested system. Replacing it with slot map semantics means re-implementing cleanup logic that already handles edge cases (e.g., embed_sync watch channel teardown via `get_embed_channel()` at lines 53-71 and `close_channel()` at lines 83-89, async timer cleanup at lines 63, timer close via cleanup module at lines 64-66).

---

## Expected Impact

- **Eliminate stale bufnr reference bugs**: Generation checks guarantee that code holding an old handle for buffer N cannot accidentally read or write state belonging to a new buffer that was assigned the same bufnr. This upgrades the current approach of `nvim_buf_is_valid()` checks in `gc_stale_buffers()` (embed_state.lua lines 101-116) from reactive cleanup to proactive detection.
- **Surface resource leaks during development**: Leak detection with backtraces makes it trivial to find cleanup bugs that currently go unnoticed until they cause memory growth or visual artifacts in long sessions. Complements the existing `all_tracked_buffers()` audit (embed_state.lua lines 121-129) with allocation-site traceability.
- **Simplify per-buffer cleanup**: One `remove(handle)` call replaces clearing entries from six separate dicts and their registered cleanup functions (embed_state.lua lines 45-66), reducing the chance of incomplete cleanup. Similarly for highlight_coordinator's two dicts and multi-module cleanup calls (lines 488-500: channels, caches, pipeline, viewport, region_tracker), plus its cache invalidation path (line 476).
- **Unified debug observability**: A `:VaultSlotMapDebug` command would complement existing debug commands (`:VaultEmbedDebug`, `:VaultCompletionDebug`, `:VaultIndexStatus`) and integrate with `engine.register_cache()` for `:VaultCacheDebug` visibility.
- **Marginal performance improvement**: Dense array access and integer comparison are faster than hash probing and string comparison, though the difference is unlikely to be noticeable at current scale.
