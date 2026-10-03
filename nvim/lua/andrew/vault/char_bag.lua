--- Character presence bitset for fast pre-filtering.
--- Inspired by Zed's CharBag in crates/fuzzy/src/char_bag.rs.
---
--- Simplified for Lua: 1 bit per character (no occurrence counting).
--- Maps a-z to buckets 0-25, 0-9 to buckets 26-35, common punctuation to 36-41.
--- LuaJIT's bit.* ops operate on 32-bit integers, so a single 42-bit mask would
--- silently overflow (bit positions >=32 wrap and alias onto low bits). To avoid
--- that, the 42 buckets are split across two 31-bit bitmaps: `lo` holds buckets
--- 0-30 and `hi` holds buckets 31-41. is_superset ANDs both halves.

local M = {}

-- Neovim uses LuaJIT which provides the `bit` library
local band = bit.band
local bor = bit.bor

-- Precompute character -> {bucket, lo_bit, hi_bit} mappings.
-- Buckets 0-30 set a bit in `lo`; buckets 31-41 set a bit in `hi` (bit n-31).
local _char_bit = {}
local function set_char(byte, bucket)
  if bucket <= 30 then
    _char_bit[byte] = { lo = 2 ^ bucket, hi = 0 }
  else
    _char_bit[byte] = { lo = 0, hi = 2 ^ (bucket - 31) }
  end
end
for i = 0, 25 do
  set_char(string.byte("a") + i, i)
  set_char(string.byte("A") + i, i) -- Case insensitive
end
for i = 0, 9 do
  set_char(string.byte("0") + i, 26 + i)
end
set_char(string.byte("-"), 36)
set_char(string.byte("_"), 37)
set_char(string.byte("."), 38)
set_char(string.byte("/"), 39)
set_char(string.byte("#"), 40)
set_char(string.byte("@"), 41)

--- Compute CharBag for a string.
--- @param s string
--- @return table bag {lo, hi} character presence bitset (two 31-bit halves)
function M.from_string(s)
  local lo, hi = 0, 0
  for i = 1, #s do
    local b = _char_bit[s:byte(i)]
    if b then
      lo = bor(lo, b.lo)
      hi = bor(hi, b.hi)
    end
  end
  return { lo = lo, hi = hi }
end

--- Check if candidate's bag is a superset of query's bag.
--- If false, candidate cannot possibly match the query.
--- @param candidate_bag table
--- @param query_bag table
--- @return boolean
function M.is_superset(candidate_bag, query_bag)
  return band(candidate_bag.lo, query_bag.lo) == query_bag.lo
    and band(candidate_bag.hi, query_bag.hi) == query_bag.hi
end

return M
