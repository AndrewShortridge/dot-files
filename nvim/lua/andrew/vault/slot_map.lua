--- Generational slot map for entity-style storage.
--- Provides O(1) array-indexed access with ABA protection via generation counters.
--- Inspired by Zed's entity_map.rs (SlotMap with generational IDs).
---@class SlotMap
local M = {}
M.__index = M

local SLOT_BITS = 20
local GEN_MASK = 2 ^ SLOT_BITS

--- Create a new generational slot map.
---@param opts? { leak_detect: boolean, name: string }
---@return SlotMap
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    _slots = {},      -- array of { value, generation }
    _free_list = {},  -- LIFO stack of available slot indices
    _count = 0,       -- number of live entities
    _next_slot = 1,   -- next unallocated slot index
    _name = opts.name or "unnamed",

    -- Leak detection (debug mode only)
    _leak_detect = opts.leak_detect or false,
    _alloc_info = {}, -- slot -> { traceback, insert_time } (only when leak_detect=true)
  }, M)
end

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
    assert(slot < GEN_MASK, "slot_map: slot count exceeds maximum")
  end

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

--- Check if a handle refers to a live entity.
---@param handle table { slot, generation }
---@return boolean
function M:contains(handle)
  local entry = self._slots[handle.slot]
  return entry ~= nil and entry.generation == handle.generation
end

--- Remove an entity by handle.
--- Returns the removed value, or nil if the handle was stale.
---@param handle table { slot, generation }
---@return any|nil removed_value
function M:remove(handle)
  local entry = self._slots[handle.slot]
  if not entry or entry.generation ~= handle.generation then
    return nil
  end

  local value = entry.value
  entry.value = nil

  self._free_list[#self._free_list + 1] = handle.slot
  self._count = self._count - 1

  if self._leak_detect then
    self._alloc_info[handle.slot] = nil
  end

  return value
end

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

--- Key-map helpers: deduplicate the common pattern of maintaining a
--- separate key→handle mapping (e.g. bufnr→handle) alongside the slot map.

--- Get or auto-create an entity by external key.
--- If the key has no handle, or the handle is stale, calls create_fn(key) to
--- build a new record, inserts it, and updates key_map.
---@param key any External key (e.g. bufnr)
---@param key_map table Mutable key→handle mapping (e.g. _buf_handles)
---@param create_fn fun(key: any): any Factory for new records
---@return any value The live entity value
function M:get_or_insert(key, key_map, create_fn)
  local handle = key_map[key]
  if handle then
    local st = self:get(handle)
    if st then return st end
    key_map[key] = nil -- stale handle
  end
  local record = create_fn(key)
  key_map[key] = self:insert(record)
  return record
end

--- Look up an entity by external key without auto-creating.
--- Cleans up stale handles automatically.
---@param key any External key
---@param key_map table key→handle mapping
---@return any|nil value
function M:try_get(key, key_map)
  local handle = key_map[key]
  if not handle then return nil end
  local st = self:get(handle)
  if not st then
    key_map[key] = nil
    return nil
  end
  return st
end

--- Remove an entity by external key.
--- Returns the removed value (or nil if not found).
---@param key any External key
---@param key_map table key→handle mapping
---@return any|nil removed_value
function M:remove_by_key(key, key_map)
  local handle = key_map[key]
  if not handle then return nil end
  key_map[key] = nil
  return self:remove(handle)
end

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

--- Return stats for engine cache registry integration.
---@return { entries: integer, max: integer, free: integer }
function M:get_stats()
  return {
    entries = self._count,
    max = self._next_slot - 1,
    free = #self._free_list,
  }
end

--- Register this slot map with the engine cache registry.
--- Eliminates per-module boilerplate for :VaultCacheDebug visibility.
---@param opts { name: string, module: string, invalidate: fun() }
function M:register_with_engine(opts)
  local engine = require("andrew.vault.engine")
  local sm = self
  engine.register_cache({
    name = opts.name,
    module = opts.module,
    invalidate = opts.invalidate,
    stats = function()
      local s = sm:get_stats()
      s.vault = engine.vault_path
      return s
    end,
  })
end

--- Clear all slots and report leaks if detection is enabled.
function M:destroy()
  if self._leak_detect then
    local leaks = self:detect_leaks()
    if #leaks > 0 then
      vim.schedule(function()
        for _, leak in ipairs(leaks) do
          vim.notify(
            string.format(
              "SlotMap(%s): leaked entity at slot %d (age %.1fs)\n%s",
              self._name, leak.slot, leak.age_ms / 1000, leak.traceback
            ),
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

return M
