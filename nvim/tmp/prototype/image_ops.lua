-- image_ops.lua -- PPM read, highlighter compositing, PNG write. Pure Lua.
--
-- Exists so highlight burn-in works with nothing but poppler installed.
-- imagemagick is not required: we read pdftoppm's uncompressed PPM, blend the
-- highlight rects ourselves, and emit a PNG using zlib *stored* (uncompressed)
-- blocks, which needs no compression library -- only crc32 and adler32.
--
-- If `magick` is on PATH, callers should prefer it; this is the fallback that
-- always works.

local bit = require("bit")
local band, bxor, rshift = bit.band, bit.bxor, bit.rshift

local M = {}

----------------------------------------------------------------------
-- checksums
----------------------------------------------------------------------

local CRC = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if band(c, 1) ~= 0 then c = bxor(0xEDB88320, rshift(c, 1)) else c = rshift(c, 1) end
  end
  CRC[i] = c
end

local function crc32(s)
  local c = -1 -- 0xFFFFFFFF
  local n, i = #s, 1
  while i <= n do
    local j = math.min(i + 4095, n)
    local b = { string.byte(s, i, j) }
    for k = 1, #b do
      c = bxor(CRC[band(bxor(c, b[k]), 0xFF)], rshift(c, 8))
    end
    i = j + 1
  end
  return bxor(c, -1)
end

local function adler32(s)
  local a, b = 1, 0
  local n, i = #s, 1
  while i <= n do
    local j = math.min(i + 4095, n)
    local by = { string.byte(s, i, j) }
    for k = 1, #by do
      a = a + by[k]
      b = b + a
    end
    a = a % 65521
    b = b % 65521
    i = j + 1
  end
  return b * 65536 + a
end

local function be32(x)
  x = x % 4294967296
  return string.char(
    math.floor(x / 16777216) % 256,
    math.floor(x / 65536) % 256,
    math.floor(x / 256) % 256,
    x % 256
  )
end

local function le16(x)
  return string.char(x % 256, math.floor(x / 256) % 256)
end

----------------------------------------------------------------------
-- PPM (P6) in
----------------------------------------------------------------------

--- @return table|nil img { w, h, rows = { [1..h] = string of w*3 bytes } }
function M.read_ppm(path)
  local fd = io.open(path, "rb")
  if not fd then return nil, "cannot open " .. path end
  local body = fd:read("*a")
  fd:close()

  if body:sub(1, 2) ~= "P6" then return nil, "not a P6 ppm" end

  -- token scan across the header, skipping # comments
  local pos, toks = 3, {}
  while #toks < 3 do
    local c = body:sub(pos, pos)
    if c == "" then return nil, "truncated ppm header" end
    if c == "#" then
      pos = (body:find("\n", pos, true) or #body) + 1
    elseif c:match("%s") then
      pos = pos + 1
    else
      local e = body:find("[%s#]", pos) or (#body + 1)
      table.insert(toks, body:sub(pos, e - 1))
      pos = e
    end
  end
  pos = pos + 1 -- single whitespace byte after maxval

  local w, h, maxv = tonumber(toks[1]), tonumber(toks[2]), tonumber(toks[3])
  if not (w and h and maxv) then return nil, "bad ppm header" end
  if maxv ~= 255 then return nil, "only 8-bit ppm supported (maxval " .. maxv .. ")" end

  local stride = w * 3
  local want = stride * h
  local pixels = body:sub(pos, pos + want - 1)
  if #pixels < want then return nil, ("truncated ppm: %d of %d bytes"):format(#pixels, want) end

  local rows = {}
  for y = 1, h do
    rows[y] = pixels:sub((y - 1) * stride + 1, y * stride)
  end
  return { w = w, h = h, rows = rows }
end

----------------------------------------------------------------------
-- highlighter compositing
----------------------------------------------------------------------

M.colors = {
  yellow = { 255, 232, 66 },
  blue   = { 128, 200, 255 },
  red    = { 255, 138, 138 },
  purple = { 205, 160, 255 },
}

--- Multiply blend, like a real highlighter: white paper takes the colour,
--- black glyphs stay black and stay readable.
--- rects are pixel-space { x0, y0, x1, y1 } (0-indexed, inclusive)
function M.highlight_rects(img, rects)
  for _, r in ipairs(rects) do
    local c = M.colors[r.color] or M.colors.yellow
    local cr, cg, cb = c[1] / 255, c[2] / 255, c[3] / 255
    local y0 = math.max(1, math.floor(r.y0) + 1)
    local y1 = math.min(img.h, math.floor(r.y1) + 1)
    local x0 = math.max(0, math.floor(r.x0))
    local x1 = math.min(img.w - 1, math.floor(r.x1))
    if x1 >= x0 then
      for y = y0, y1 do
        local row = img.rows[y]
        local b0 = x0 * 3 + 1
        local b1 = (x1 + 1) * 3
        local mid = row:sub(b0, b1)
        local out, n = {}, 0
        local i = 1
        while i <= #mid do
          local pr, pg, pb = string.byte(mid, i, i + 2)
          n = n + 1
          out[n] = string.char(
            math.floor(pr * cr),
            math.floor(pg * cg),
            math.floor(pb * cb)
          )
          i = i + 3
        end
        img.rows[y] = row:sub(1, b0 - 1) .. table.concat(out) .. row:sub(b1 + 1)
      end
    end
  end
  return img
end

----------------------------------------------------------------------
-- PNG out (zlib stored blocks -- no compression library needed)
----------------------------------------------------------------------

local function chunk(typ, data)
  return be32(#data) .. typ .. data .. be32(crc32(typ .. data))
end

local function zlib_stored(raw)
  local parts = { "\x78\x01" }
  local n = #raw
  local pos = 1
  if n == 0 then
    parts[#parts + 1] = "\x01" .. le16(0) .. le16(0xFFFF)
  end
  while pos <= n do
    local len = math.min(65535, n - pos + 1)
    local final = (pos + len - 1 >= n) and 1 or 0
    parts[#parts + 1] = string.char(final) .. le16(len) .. le16(0xFFFF - len)
    parts[#parts + 1] = raw:sub(pos, pos + len - 1)
    pos = pos + len
  end
  parts[#parts + 1] = be32(adler32(raw))
  return table.concat(parts)
end

function M.write_png(path, img)
  local ihdr = be32(img.w) .. be32(img.h) .. string.char(8, 2, 0, 0, 0) -- 8-bit RGB
  local scan = {}
  for y = 1, img.h do
    scan[y] = "\0" .. img.rows[y] -- filter type 0
  end
  local png = table.concat({
    "\137PNG\r\n\26\n",
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib_stored(table.concat(scan))),
    chunk("IEND", ""),
  })
  local fd = io.open(path, "wb")
  if not fd then return nil, "cannot write " .. path end
  fd:write(png)
  fd:close()
  return path
end

--- Width/height straight from the IHDR chunk.
function M.png_dim(path)
  local fd = io.open(path, "rb")
  if not fd then return nil end
  local h = fd:read(24)
  fd:close()
  if not h or h:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end
  local function u32(o)
    return h:byte(o) * 16777216 + h:byte(o + 1) * 65536 + h:byte(o + 2) * 256 + h:byte(o + 3)
  end
  return u32(17), u32(21)
end

M._crc32, M._adler32 = crc32, adler32

return M
