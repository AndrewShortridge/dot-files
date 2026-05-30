--- Character presence bitset for fast pre-filtering.
--- Inspired by Zed's CharBag in crates/fuzzy/src/char_bag.rs.
---
--- Simplified for Lua: 1 bit per character (no occurrence counting).
--- Maps a-z to bits 0-25, 0-9 to bits 26-35, common punctuation to 36-41.
--- Total: 42 bits, fits in a Lua number (52-bit mantissa in LuaJIT doubles).

local M = {}

-- Neovim uses LuaJIT which provides the `bit` library
local band = bit.band
local bor = bit.bor

-- Precompute character -> bit mappings
local _char_bit = {}
for i = 0, 25 do
  _char_bit[string.byte("a") + i] = 2 ^ i
  _char_bit[string.byte("A") + i] = 2 ^ i -- Case insensitive
end
for i = 0, 9 do
  _char_bit[string.byte("0") + i] = 2 ^ (26 + i)
end
_char_bit[string.byte("-")] = 2 ^ 36
_char_bit[string.byte("_")] = 2 ^ 37
_char_bit[string.byte(".")] = 2 ^ 38
_char_bit[string.byte("/")] = 2 ^ 39
_char_bit[string.byte("#")] = 2 ^ 40
_char_bit[string.byte("@")] = 2 ^ 41

--- Compute CharBag for a string.
--- @param s string
--- @return number bag 42-bit character presence bitset
function M.from_string(s)
  local bag = 0
  for i = 1, #s do
    local b = _char_bit[s:byte(i)]
    if b then
      bag = bor(bag, b)
    end
  end
  return bag
end

--- Check if candidate's bag is a superset of query's bag.
--- If false, candidate cannot possibly match the query.
--- @param candidate_bag number
--- @param query_bag number
--- @return boolean
function M.is_superset(candidate_bag, query_bag)
  return band(candidate_bag, query_bag) == query_bag
end

return M
