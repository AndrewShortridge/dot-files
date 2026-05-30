--- Simple bloom filter for set membership pre-checks.
--- False positives allowed (fall through to exact check).
--- False negatives never happen (safe for pre-filtering).
---
--- Uses FNV-1a hash (fast, no external deps). Two hash functions
--- with 256 buckets (Lua table with boolean values).

local M = {}

local bxor = bit.bxor

--- FNV-1a hash (32-bit), with optional seed for independent hash functions.
---@param s string
---@param seed? number
---@return number
local function fnv1a(s, seed)
  local hash = seed and bxor(2166136261, seed) or 2166136261
  for i = 1, #s do
    hash = bxor(hash, s:byte(i))
    hash = hash * 16777619
    hash = hash % 4294967296
  end
  return hash
end

local SEED2 = 0x9E3779B9

--- Create a new empty bloom filter.
---@return table bloom
function M.new()
  return {}
end

--- Add an item to the bloom filter.
---@param bloom table
---@param item string
function M.add(bloom, item)
  bloom[fnv1a(item) % 256] = true
  bloom[fnv1a(item, SEED2) % 256] = true
end

--- Check if an item might be in the bloom filter.
--- Returns true if possibly present (may be false positive).
--- Returns false if definitely not present (never false negative).
---@param bloom table
---@param item string
---@return boolean
function M.maybe_contains(bloom, item)
  return bloom[fnv1a(item) % 256] == true
    and bloom[fnv1a(item, SEED2) % 256] == true
end

return M
