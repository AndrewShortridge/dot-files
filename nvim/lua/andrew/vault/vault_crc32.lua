-- vault_crc32.lua — Table-driven CRC32 (8 hex chars), shared hashing helper.
-- Used for file-level content hashing and per-chunk digests. A digest collision
-- or mismatch only triggers a re-parse (never corruption), so CRC32 is sufficient
-- and far cheaper than SHA-256.

local bit = require("bit")

local M = {}

local crc32_table
local function ensure_crc32_table()
  if crc32_table then return end
  crc32_table = {}
  for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
      if bit.band(crc, 1) == 1 then
        crc = bit.bxor(bit.rshift(crc, 1), 0xEDB88320)
      else
        crc = bit.rshift(crc, 1)
      end
    end
    crc32_table[i] = crc
  end
end

--- Compute CRC32 of a string.
---@param data string
---@return string hex 8-char hex-encoded CRC32
function M.crc32(data)
  ensure_crc32_table()
  local crc = 0xFFFFFFFF
  for i = 1, #data do
    local byte = data:byte(i)
    local idx = bit.band(bit.bxor(crc, byte), 0xFF)
    crc = bit.bxor(bit.rshift(crc, 8), crc32_table[idx])
  end
  return string.format("%08x", bit.bxor(crc, 0xFFFFFFFF))
end

return M
