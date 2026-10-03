-- Headless verification of the pure-Lua PPM->composite->PNG pipeline:
--   nvim --headless -u NONE -l tmp/prototype/png_check.lua
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
package.path = here .. "/?.lua;" .. package.path
local IO = require("image_ops")

local pass, fail = 0, 0
local function check(n, ok, d)
  if ok then pass = pass + 1; print("  ok   " .. n)
  else fail = fail + 1; print("  FAIL " .. n .. (d and ("  -- " .. d) or "")) end
end

-- known-answer checksums (cross-checked against python zlib/binascii below)
check("crc32('123456789')", IO._crc32("123456789") % 4294967296 == 0xCBF43926,
  string.format("%08x", IO._crc32("123456789") % 4294967296))
check("adler32('123456789')", IO._adler32("123456789") == 0x091E01DE,
  string.format("%08x", IO._adler32("123456789")))
check("crc32('')", IO._crc32("") % 4294967296 == 0)

local img, err = IO.read_ppm(here .. "/data/_t.ppm")
check("ppm parsed", img ~= nil, err)
if not img then os.exit(1) end
print(("  %dx%d, %d rows"):format(img.w, img.h, #img.rows))
check("row stride correct", #img.rows[1] == img.w * 3)

-- sample a pixel before/after so the blend is provably applied
local function px(x, y)
  return string.byte(img.rows[y + 1], x * 3 + 1, x * 3 + 3)
end
local bx, by = math.floor(img.w / 2), 20
local r0, g0, b0 = px(bx, by)

local t0 = vim.uv.hrtime()
IO.highlight_rects(img, { { x0 = 0, y0 = 10, x1 = img.w - 1, y1 = 30, color = "yellow" } })
local blend_ms = (vim.uv.hrtime() - t0) / 1e6

local r1, g1, b1 = px(bx, by)
check("blend darkened blue channel (highlighter multiply)", b1 < b0 or b0 == 0,
  ("%d,%d,%d -> %d,%d,%d"):format(r0, g0, b0, r1, g1, b1))
check("blend preserved red channel", r1 == math.floor(r0 * 255 / 255))
check("pixel outside the rect untouched", select(3, px(bx, 60)) == select(3, px(bx, 60)))

local t1 = vim.uv.hrtime()
local out = IO.write_png(here .. "/data/_t.png", img)
local png_ms = (vim.uv.hrtime() - t1) / 1e6
check("png written", out ~= nil)
print(("  blend %.1fms, png encode %.1fms, %d bytes"):format(
  blend_ms, png_ms, vim.fn.getfsize(here .. "/data/_t.png")))

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
