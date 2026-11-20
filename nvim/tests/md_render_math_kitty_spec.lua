-- Spec for andrew.utils.md_render_math_kitty: a coverage mask and a colour
-- become rows of Kitty Unicode-placeholder cells plus the highlight that
-- names the image, and the terminal is given (and later relieved of) the
-- picture.
--
-- WHAT THIS IS GUARDING
--
-- 1. The first use of a picture sends the terminal the PNG's BYTES (`t=d`,
--    base64) and then a VIRTUAL placement of its cells -- in that order: a
--    placement of an image Kitty does not hold yet is refused. Base64 over
--    4096 bytes goes in chunks of at most 4096 (`m=1` ... `m=0`).
-- 2. The PNG is the mask in the foreground: IHDR colour type 3, a PLTE of 256
--    times the colour, a tRNS whose alpha for value v is 255 - v (the mask's
--    coverage), the mask's IDAT byte for byte, valid CRCs, nothing after
--    IEND (the tex module's record there is not for the terminal). Decoded
--    here pixel by pixel.
-- 3. Nothing is sent again for the same picture: the cells are text, so
--    every rebuild of the view would otherwise re-send every equation. A box
--    or a colour of its own is an image of its own (Neovim sends no
--    underline colour for cells that are not underlined, so a second
--    placement of ONE image could not be chosen by the cells).
-- 4. `cells` never raises: `nil, "box"` for a box Kitty cannot address,
--    `nil, "missing"` for a file that cannot be read or is not an 8-bit
--    greyscale PNG -- without spending an id or a highlight group.
-- 5. Each cell is U+10EEEE + row + column + id-byte diacritic, one display
--    column wide, every one of them explicit: md-render may wrap or cut the
--    run and the rest must still show the right part of the picture. The
--    rows are shared, not copied per call.
-- 6. The highlight: fg = low 24 bits of the image id (the high byte is the
--    third diacritic), sp = the placement id, nocombine.
-- 7. Release: `mark` says what a buffer shows; 300 ms later (not before: a
--    delete must not overtake Neovim's redraw) unshown images beyond the 256
--    most recently used are deleted (`a=d,d=I`), oldest first, sparing any
--    handed out since the collection before and, for a grace, any never
--    marked; a wiped or unloaded buffer shows nothing. Released ids and
--    their highlight groups are used again (Neovim stops at ~19 600 groups).
--    VimLeavePre deletes everything still held.
-- 8. A resumed or newly attached UI gets the shown pictures, and those handed
--    out but not yet marked, again at once, the others when next used;
--    `:colorscheme` keeps the highlights.
-- 9. The terminal: Kitty or Ghostty, also over ssh; through tmux only when
--    the pane's allow-passthrough is on, read once and asynchronously (the
--    user's options untouched), every escape then wrapped and `User
--    MdRenderMathTerminal` fired; never a `:terminal` of another Neovim or a
--    multiplexer it cannot ask; only with 'termguicolors'. Why not: a reason.
--
-- That Kitty draws what these bytes and cells describe (colour within 3/255
-- of the pictures mutool drew in colour, chunked transmissions, no delete
-- while its cells are on screen, nothing left after exit, a recycled id
-- showing the new picture) was checked against Kitty 0.49.2's own parser
-- and graphics manager, outside this spec.
--
-- `nvim_ui_send` is replaced by a recorder; no terminal is needed.
--
-- Run with: nvim --headless -u NONE -l tests/md_render_math_kitty_spec.lua

local spec_directory = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]")
---@type SpecHelper
local _H = dofile(spec_directory .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

local bit = require("bit")

-- The module next to this spec, so that a copy of the tree tests its own copy
-- (Neovim's loader looks in 'runtimepath' before `package.path`).
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(spec_directory, ":p:h:h"))
local MODULE_NAME = "andrew.utils.md_render_math_kitty"

local sent_to_terminal = {} ---@type string[]
---@param data string
---@diagnostic disable-next-line: duplicate-set-field
vim.api.nvim_ui_send = function(data)
  sent_to_terminal[#sent_to_terminal + 1] = data
end

---@return string
local function take_sent()
  local sent = table.concat(sent_to_terminal)
  sent_to_terminal = {}
  return sent
end

--- Kitty's row/column diacritics for 0..131, from kitty
--- gen/rowcolumn-diacritics.txt -- written out here rather than taken from
--- the module, so that a wrong table there shows.
-- stylua: ignore
local DIACRITIC_CODEPOINTS = {
  0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A, 0x034B, 0x034C,
  0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
  0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592,
  0x0593, 0x0594, 0x0595, 0x0597, 0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
  0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615,
  0x0616, 0x0617, 0x0657, 0x0658, 0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
  0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2, 0x06E4, 0x06E7, 0x06E8, 0x06EB,
  0x06EC, 0x0730, 0x0732, 0x0733, 0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
  0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE, 0x07EF, 0x07F0, 0x07F1, 0x07F3,
  0x0816, 0x0817, 0x0818, 0x0819, 0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
  0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C, 0x082D, 0x0951, 0x0953, 0x0954,
}
local NUMBER_OF_DIACRITIC = {} ---@type table<integer, integer>
for index, codepoint in ipairs(DIACRITIC_CODEPOINTS) do
  NUMBER_OF_DIACRITIC[codepoint] = index - 1
end

local PLACEHOLDER_CODEPOINT = 0x10EEEE
local TWO_TO_THE_24 = 0x1000000

---@class KittySpecCell
---@field text string
---@field row integer?
---@field column integer?
---@field id_byte integer?
---@field codepoint_count integer

---@class KittySpecCodepoints
---@field codepoints integer[] the placeholder, then its diacritics

--- Split a row of placeholder cells into its cells and decode each.
---@param row_text string
---@return KittySpecCell[]
local function decode_cells(row_text)
  local cells = {} ---@type (KittySpecCodepoints|KittySpecCell)[]
  -- vim.fn.str2list is annotated as returning any; it returns codepoints.
  for _, codepoint in ipairs(vim.fn.str2list(row_text) --[[@as integer[] ]]) do
    if codepoint == PLACEHOLDER_CODEPOINT then
      cells[#cells + 1] = { codepoints = { codepoint } }
    else
      assert(#cells > 0, "the row does not start with U+10EEEE")
      table.insert(cells[#cells].codepoints, codepoint)
    end
  end
  for index, cell in ipairs(cells) do
    local codepoints = cell.codepoints
    cells[index] = {
      text = vim.fn.list2str(codepoints),
      row = NUMBER_OF_DIACRITIC[codepoints[2]],
      column = NUMBER_OF_DIACRITIC[codepoints[3]],
      id_byte = NUMBER_OF_DIACRITIC[codepoints[4]],
      codepoint_count = #codepoints,
    }
  end
  -- The loop above replaced every entry by its decoded cell.
  return cells --[[@as KittySpecCell[] ]]
end

---@class KittySpecCommand
---@field keys table<string, string>
---@field payload string?

--- The Kitty graphics commands in what was sent, in order. Fails on any
--- byte that is not part of a graphics command.
---@param sent string
---@return KittySpecCommand[]
local function graphics_commands(sent)
  local commands = {} ---@type KittySpecCommand[]
  local covered = 0
  -- string.gmatch is annotated with one capture; these patterns have two.
  for whole, body in sent:gmatch("(\27_G([^\27]*)\27\\)") --[[@as fun(): string, string]] do
    covered = covered + #whole
    local control, payload = body:match("^([^;]*);?(.*)$")
    local keys = {} ---@type table<string, string>
    for key, value in control:gmatch("(%w)=([^,]*)") --[[@as fun(): string, string]] do
      keys[key] = value
    end
    commands[#commands + 1] = { keys = keys, payload = payload ~= "" and payload or nil }
  end
  assert(covered == #sent, "bytes sent outside graphics commands")
  return commands
end

--- The ids deleted (`a=d,d=I`) in `commands`, as a set, and their number.
---@param commands KittySpecCommand[]
---@return table<string, true>, integer
local function deleted_ids(commands)
  ---@type table<string, true>, integer
  local ids, count = {}, 0
  for _, command in ipairs(commands) do
    assert(command.keys.a == "d", "a command other than a delete: a=" .. tostring(command.keys.a))
    assert(command.keys.d == "I", "delete of the image data too: d=" .. tostring(command.keys.d))
    assert(command.keys.q == "2", "a quiet delete: q=" .. tostring(command.keys.q))
    ids[command.keys.i] = true
    count = count + 1
  end
  return ids, count
end

---@return integer
local function count_highlight_groups()
  return vim.tbl_count(vim.api.nvim_get_hl(0, {}))
end

-- -----------------------------------------------------------------------------
-- PNG: written and read here, with a CRC of its own (bitwise, not the
-- module's table) and stored (uncompressed) deflate, so pixels can be read.
-- -----------------------------------------------------------------------------

---@param number integer
---@return string four bytes, big-endian
local function big_endian_32(number)
  return string.char(
    math.floor(number / 16777216) % 256,
    math.floor(number / 65536) % 256,
    math.floor(number / 256) % 256,
    number % 256
  )
end

---@param bytes string
---@param position integer
---@return integer the four bytes from `position`, big-endian
local function uint32_at(bytes, position)
  local first, second, third, fourth = bytes:byte(position, position + 3)
  return ((first * 256 + second) * 256 + third) * 256 + fourth
end

---@param bytes string
---@return string four bytes, big-endian
local function crc32(bytes)
  local crc = 0xFFFFFFFF
  for index = 1, #bytes do
    crc = bit.bxor(crc, bytes:byte(index))
    for _ = 1, 8 do
      crc = bit.bxor(bit.rshift(crc, 1), bit.band(0xEDB88320, -bit.band(crc, 1)))
    end
  end
  return big_endian_32(bit.bnot(crc))
end

---@param kind string
---@param data string
---@return string
local function chunk(kind, data)
  return big_endian_32(#data) .. kind .. data .. crc32(kind .. data)
end

--- zlib stream of `data` in stored blocks.
---@param data string
---@return string
local function stored_zlib(data)
  local parts = { "\120\1" }
  local offset = 1
  repeat
    local block = data:sub(offset, offset + 65534)
    offset = offset + #block
    local is_last = offset > #data
    local length = #block
    parts[#parts + 1] = string.char(
      is_last and 1 or 0,
      length % 256,
      math.floor(length / 256),
      255 - length % 256,
      255 - math.floor(length / 256)
    ) .. block
  until is_last
  local a, b = 1, 0
  for index = 1, #data do
    a = (a + data:byte(index)) % 65521
    b = (b + a) % 65521
  end
  parts[#parts + 1] = big_endian_32(b * 65536 + a)
  return table.concat(parts)
end

local PNG_SIGNATURE = "\137PNG\r\n\26\n"

--- A PNG of `width` x `height`, colour type `colour_type`, `bit_depth`, with
--- `value(x, y)` (0-based) as every sample of a pixel, and `after` behind IEND.
---@param options { width: integer, height: integer, value: (fun(x: integer, y: integer): integer), colour_type?: integer, bit_depth?: integer, after?: string, ancillary?: string }
---@return string
local function png_bytes(options)
  local colour_type, bit_depth = options.colour_type or 0, options.bit_depth or 8
  local samples = ({ [0] = 1, [2] = 3, [6] = 4 })[colour_type] * bit_depth / 8
  local rows = {} ---@type string[]
  for y = 0, options.height - 1 do
    local row = { "\0" }
    for x = 0, options.width - 1 do
      row[#row + 1] = string.char(options.value(x, y)):rep(samples)
    end
    rows[#rows + 1] = table.concat(row)
  end
  local header = big_endian_32(options.width)
    .. big_endian_32(options.height)
    .. string.char(bit_depth, colour_type, 0, 0, 0)
  return PNG_SIGNATURE
    .. chunk("IHDR", header)
    .. (options.ancillary or "")
    .. chunk("IDAT", stored_zlib(table.concat(rows)))
    .. chunk("IEND", "")
    .. (options.after or "")
end

---@param path string
---@param bytes string
local function write_file(path, bytes)
  local file = assert(io.open(path, "wb"))
  file:write(bytes)
  file:close()
end

---@param path string
---@return string
local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local bytes = file:read("*a")
  file:close()
  return bytes
end

---@class KittySpecPng
---@field width integer
---@field height integer
---@field kinds string[] chunk types in order
---@field data_of table<string, string> data of each chunk type (IDATs joined)

--- Parse a PNG; fails on a bad signature, CRC or anything after IEND.
---@param bytes string
---@return KittySpecPng
local function parse_png(bytes)
  assert(bytes:sub(1, 8) == PNG_SIGNATURE, "PNG signature")
  local png = { kinds = {} --[[@as string[] ]], data_of = {} --[[@as table<string, string>]] }
  local position = 9
  while true do
    local length = uint32_at(bytes, position)
    local kind = bytes:sub(position + 4, position + 7)
    local data = bytes:sub(position + 8, position + 7 + length)
    assert(
      bytes:sub(position + 8 + length, position + 11 + length) == crc32(kind .. data),
      "CRC of " .. kind
    )
    png.kinds[#png.kinds + 1] = kind
    png.data_of[kind] = (png.data_of[kind] or "") .. data
    position = position + 12 + length
    if kind == "IEND" then
      break
    end
  end
  assert(position == #bytes + 1, "bytes after IEND: " .. (#bytes + 1 - position))
  png.width, png.height = uint32_at(png.data_of.IHDR, 1), uint32_at(png.data_of.IHDR, 5)
  return png
end

--- The filtered scanlines of a zlib stream of stored blocks.
---@param zlib string
---@return string
local function inflate_stored(zlib)
  local parts = {} ---@type string[]
  local position = 3
  while true do
    local final, low, high = zlib:byte(position, position + 2)
    assert(bit.band(final, 6) == 0, "a stored block")
    local length = low + high * 256
    parts[#parts + 1] = zlib:sub(position + 5, position + 4 + length)
    position = position + 5 + length
    if bit.band(final, 1) == 1 then
      break
    end
  end
  return table.concat(parts)
end

--- RGBA of the pixel (x, y) (0-based) of a palette PNG with stored IDAT.
---@param png KittySpecPng
---@param x integer
---@param y integer
---@return integer red, integer green, integer blue, integer alpha
local function palette_pixel(png, x, y)
  local scanlines = inflate_stored(png.data_of.IDAT)
  local stride = png.width + 1
  assert(scanlines:byte(y * stride + 1) == 0, "filter type None")
  local index = scanlines:byte(y * stride + 2 + x)
  local palette, transparency = png.data_of.PLTE, png.data_of.tRNS
  local red, green, blue = palette:byte(index * 3 + 1, index * 3 + 3)
  return red, green, blue, transparency:byte(index + 1)
end

--- The PNG a transmission carries.
---@param commands KittySpecCommand[]
---@param first integer index of its `a=t` command
---@return KittySpecPng
local function transmitted_png(commands, first)
  return parse_png(vim.base64.decode(commands[first].payload))
end

-- -----------------------------------------------------------------------------
-- Masks
-- -----------------------------------------------------------------------------

local scratch_directory = vim.fn.tempname()
vim.fn.mkdir(scratch_directory, "p")

--- Value of the mask pixel (x, y): full ink at the left, none at the right,
--- 64 in row 1, so that every value maps to a known alpha.
---@param x integer
---@param y integer
---@return integer
local function gradient(x, y)
  if y == 1 then
    return 64
  end
  return math.min(255, x * 9)
end

---@param name string
---@param width integer
---@param height integer
---@return string path
local function write_mask(name, width, height)
  local path = scratch_directory .. "/" .. name
  local record = string.format("\nmdmath %d %d 1\n", width, height)
  write_file(
    path,
    png_bytes({
      width = width,
      height = height,
      value = gradient,
      after = record,
      -- A grey-only ancillary chunk: invalid in a palette PNG, must go.
      ancillary = chunk("bKGD", "\0\255"),
    })
  )
  return path
end

-- Stored, not compressed: kept small so that they go in one chunk.
local WIDE_PATH = write_mask("wide.png", 60, 12)
local TALL_PATH = write_mask("tall.png", 44, 30)
-- 200 x 60 px stored: ~12 kB of PNG, ~16 kB of base64, four chunks.
local LARGE_PATH = write_mask("large.png", 200, 60)
write_mask("relative.png", 17, 23)

---@param path string
---@param columns integer
---@param rows? integer default 1
---@return MdRenderMathPicture
local function picture_of(path, columns, rows)
  return { path = path, columns = columns, rows = rows or 1, scale = 1 }
end

local WIDE = picture_of(WIDE_PATH, 12)
local TALL = picture_of(TALL_PATH, 22, 3)

local FOREGROUND = "ABB2BF"

--- What this spec calls of the module (which declares no class of its
--- own); signatures as in lua/andrew/utils/md_render_math_kitty.lua.
---@class KittySpecModule
---@field MAX_CELLS integer
---@field is_supported fun(): boolean, string?
---@field cell_size fun(): integer?, integer?
---@field cells fun(picture: MdRenderMathPicture, box?: { columns: integer, rows: integer }, foreground: string): string[]?, string
---@field mark fun(owner: integer, groups: table<string, true>)
---@field setup fun(options?: { collection_delay_milliseconds?: integer, unmarked_grace_milliseconds?: integer, keep_unshown?: integer })

local kitty = require(MODULE_NAME) ---@type KittySpecModule
kitty.setup()

-- -----------------------------------------------------------------------------
-- Sending
-- -----------------------------------------------------------------------------

---@type string[], string, integer?
local wide_rows, wide_group, wide_image_id

test("the first use sends the PNG's bytes, then a virtual placement of its cells", function()
  take_sent()
  wide_rows, wide_group = assert(kitty.cells(WIDE, nil, FOREGROUND))
  local commands = graphics_commands(take_sent())
  assert_eq(#commands, 2, "graphics commands sent:")
  local transmit, place = commands[1], commands[2]
  assert_eq(transmit.keys.a, "t", "first command, action:")
  assert_eq(transmit.keys.t, "d", "transmitted directly, as bytes:")
  assert_eq(transmit.keys.f, "100", "format PNG:")
  assert_eq(transmit.keys.q, "2", "no answers asked for:")
  assert_eq(transmit.keys.m, nil, "one chunk, no `m`:")
  assert_true(#transmit.payload <= 4096, "payload within one chunk:")
  assert_eq(place.keys.a, "p", "second command, action:")
  assert_eq(place.keys.U, "1", "virtual (Unicode placeholder) placement:")
  assert_eq(place.keys.i, transmit.keys.i, "placement of the image just sent:")
  assert_eq(place.keys.p, "1", "placement id:")
  assert_eq(place.keys.c, "12", "placement columns:")
  assert_eq(place.keys.r, "1", "placement rows:")
  assert_eq(place.keys.q, "2", "no answers asked for:")
  assert_eq(place.payload, nil, "placement payload:")
  wide_image_id = tonumber(transmit.keys.i)
end)

test("the PNG sent is the mask in the foreground, alpha = coverage", function()
  kitty.cells(WIDE, { columns = 5, rows = 1 }, "FF8000")
  local commands = graphics_commands(take_sent())
  local png = transmitted_png(commands, 1)
  assert_eq(table.concat(png.kinds, " "), "IHDR PLTE tRNS IDAT IEND", "chunks:")
  local header = png.data_of.IHDR
  assert_eq(png.width, 60, "width:")
  assert_eq(png.height, 12, "height:")
  assert_eq(header:byte(9), 8, "bit depth:")
  assert_eq(header:byte(10), 3, "colour type palette:")
  assert_eq(png.data_of.PLTE, ("\255\128\0"):rep(256), "palette, 256 x the foreground:")
  local mask = parse_png((read_file(WIDE_PATH):gsub("\nmdmath[^\n]*\n$", "")))
  assert_eq(png.data_of.IDAT == mask.data_of.IDAT, true, "the mask's IDAT, byte for byte:")
  local red, green, blue, alpha = palette_pixel(png, 0, 0)
  assert_eq(string.format("%02X%02X%02X", red, green, blue), "FF8000", "colour of full ink:")
  assert_eq(alpha, 255, "alpha of value 0 (full ink):")
  assert_eq(select(4, palette_pixel(png, 59, 0)), 0, "alpha of value 255 (no ink):")
  assert_eq(select(4, palette_pixel(png, 3, 1)), 191, "alpha of value 64:")
  assert_eq(select(4, palette_pixel(png, 10, 0)), 255 - 90, "alpha of value 90:")
end)

test("image ids are above 2^24, where snacks' and md-render's never are", function()
  assert_true(wide_image_id >= TWO_TO_THE_24, "image id " .. tostring(wide_image_id) .. " >= 2^24:")
  assert_true(wide_image_id < 2 ^ 31, "image id below 2^31:")
end)

test("a second use of the same picture sends nothing", function()
  for _ = 1, 5 do
    local rows, group = assert(kitty.cells(WIDE, nil, FOREGROUND))
    assert_eq(rows[1], wide_rows[1], "same cells:")
    assert_eq(group, wide_group, "same highlight group:")
  end
  assert_eq(take_sent(), "", "sent for five more uses:")
end)

test("a scaled box is a second image of the same PNG with a placement of the box's size", function()
  local rows, group = assert(kitty.cells(WIDE, { columns = 6, rows = 1 }, FOREGROUND))
  local commands = graphics_commands(take_sent())
  assert_eq(#commands, 2, "graphics commands sent:")
  assert_eq(commands[1].keys.a, "t", "the PNG sent again under a new id:")
  assert_true(tonumber(commands[1].keys.i) ~= wide_image_id, "a different image id:")
  assert_eq(commands[2].keys.c, "6", "placement columns:")
  assert_eq(commands[2].keys.r, "1", "placement rows:")
  assert_true(group ~= wide_group, "a highlight group of its own:")
  assert_eq(#decode_cells(rows[1]), 6, "cells in the row:")
  kitty.cells(WIDE, { columns = 6, rows = 1 }, FOREGROUND)
  kitty.cells(WIDE, { columns = 12, rows = 1 }, FOREGROUND)
  assert_eq(take_sent(), "", "sent again for either box:")
end)

test("another foreground is another image, in that colour; its case does not matter", function()
  local _, group = kitty.cells(WIDE, nil, "00FF00")
  local commands = graphics_commands(take_sent())
  assert_eq(#commands, 2, "graphics commands sent:")
  assert_true(group ~= wide_group, "a highlight group of its own:")
  local png = transmitted_png(commands, 1)
  assert_eq(png.data_of.PLTE, ("\0\255\0"):rep(256), "palette:")
  local _, lower_group = kitty.cells(WIDE, nil, "00ff00")
  assert_eq(lower_group, group, "the same image in lower case:")
  assert_eq(take_sent(), "", "sent for it:")
  for _, foreground in ipairs({ "0x12AB", " 12345", "12345 ", "+12345", "12345", "GG0000", 1193046 }) do
    local is_accepted = pcall(kitty.cells, WIDE, nil, foreground)
    assert_eq(is_accepted, false, "foreground " .. vim.inspect(foreground) .. " accepted:")
  end
  assert_eq(take_sent(), "", "sent for wrong foregrounds:")
end)

test("a large picture goes in chunks of at most 4096 base64 bytes, the last m=0", function()
  local rows = kitty.cells(picture_of(LARGE_PATH, 20, 3), nil, FOREGROUND)
  assert_eq(#rows, 3, "rows:")
  local commands = graphics_commands(take_sent())
  assert_true(#commands >= 4, "at least three chunks and a placement: " .. #commands)
  local first, last = commands[1], commands[#commands - 1]
  assert_eq(first.keys.a, "t", "first chunk, action:")
  assert_eq(first.keys.t, "d", "first chunk, direct:")
  assert_eq(first.keys.f, "100", "first chunk, PNG:")
  assert_eq(first.keys.m, "1", "first chunk, more follow:")
  assert_eq(first.keys.q, "2", "first chunk, quiet:")
  local payloads = {} ---@type string[]
  for index = 1, #commands - 1 do
    local keys = commands[index].keys
    local payload = commands[index].payload
    payloads[index] = payload
    assert_true(#payload <= 4096, "chunk " .. index .. " within 4096 bytes:")
    if index < #commands - 1 then
      assert_eq(keys.m, "1", "chunk " .. index .. ", more follow:")
      assert_eq(#payload % 4, 0, "chunk " .. index .. ", a multiple of 4:")
    end
    if index > 1 then
      assert_eq(keys.a, nil, "chunk " .. index .. " repeats no action:")
      assert_eq(keys.i, nil, "chunk " .. index .. " repeats no id:")
      assert_eq(keys.q, "2", "chunk " .. index .. ", quiet:")
    end
  end
  assert_eq(last.keys.m, "0", "last chunk:")
  local png = parse_png(vim.base64.decode(table.concat(payloads)))
  assert_eq(png.width, 200, "the chunks join to the PNG, width:")
  assert_eq(select(4, palette_pixel(png, 3, 1)), 191, "the chunks join to the PNG, a pixel:")
  local place = commands[#commands]
  assert_eq(place.keys.a, "p", "then the placement:")
  assert_eq(place.keys.i, first.keys.i, "of the image sent in chunks:")
end)

--- Sample of the PNGs that are no masks: any value will do.
---@param x integer
---@return integer
local function ramp(x)
  return x
end

--- `cells` says "missing" for the file at `path` (written with `bytes` first,
--- when given).
---@param path string
---@param what string
---@param bytes? string
local function assert_missing(path, what, bytes)
  if bytes then
    write_file(path, bytes)
  end
  local rows, reason = kitty.cells(picture_of(path, 4), nil, FOREGROUND)
  assert_eq(rows, nil, what .. ", rows:")
  assert_eq(reason, "missing", what .. ", reason:")
end

test("what cannot be shown is told, not raised, and spends no id or group", function()
  local groups_before = count_highlight_groups()
  assert_missing(scratch_directory .. "/no-such.png", "no file")
  assert_missing(scratch_directory, "a directory")
  assert_missing(scratch_directory .. "/text.png", "not a PNG", "not a picture\n")
  assert_missing(
    scratch_directory .. "/coloured.png",
    "an RGBA PNG (the old cache's)",
    png_bytes({ width = 4, height = 2, value = ramp, colour_type = 6 })
  )
  assert_missing(
    scratch_directory .. "/deep.png",
    "16-bit grey",
    png_bytes({ width = 4, height = 2, value = ramp, bit_depth = 16 })
  )
  local whole = read_file(WIDE_PATH)
  local cut_path = scratch_directory .. "/cut.png"
  assert_missing(cut_path, "cut short in IDAT", whole:sub(1, 80))
  assert_missing(cut_path, "cut before IEND", whole:sub(1, #whole - #"\nmdmath 60 12 1\n" - 12))
  for _, box in ipairs({
    { columns = 0, rows = 1 },
    { columns = 2, rows = 0 },
    { columns = 1.5, rows = 1 },
    { columns = kitty.MAX_CELLS + 1, rows = 1 },
  }) do
    local rows, reason = kitty.cells(picture_of(WIDE_PATH, 4), box, FOREGROUND)
    local what = string.format("box %s x %s", box.columns, box.rows)
    assert_eq(rows, nil, what .. ", rows:")
    assert_eq(reason, "box", what .. ", reason:")
  end
  assert_eq(kitty.MAX_CELLS, 297, "cells Kitty has diacritics for:")
  assert_eq(take_sent(), "", "sent for what cannot be shown:")
  assert_eq(count_highlight_groups(), groups_before, "highlight groups:")
  local _, group = kitty.cells(picture_of(WIDE_PATH, 4), nil, FOREGROUND)
  local next_id = tonumber(graphics_commands(take_sent())[1].keys.i)
  assert_eq(next_id % TWO_TO_THE_24, (wide_image_id % TWO_TO_THE_24) + 5, "next id, none skipped:")
  assert_eq(group, "MdRenderMathPicture" .. next_id, "its group:")
end)

test("a known picture whose mask went is missing until the mask is back", function()
  local path = write_mask("comes-and-goes.png", 20, 23)
  local picture = picture_of(path, 2)
  local _, group = kitty.cells(picture, nil, FOREGROUND)
  take_sent()
  os.remove(path)
  -- The terminal may have lost it; the mask cannot be read to send it again.
  vim.api.nvim_exec_autocmds("VimResume", {})
  take_sent()
  local rows, reason = kitty.cells(picture, nil, FOREGROUND)
  assert_eq(rows, nil, "rows while the mask is gone:")
  assert_eq(reason, "missing", "reason:")
  write_mask("comes-and-goes.png", 20, 23)
  local _, group_again = kitty.cells(picture, nil, FOREGROUND)
  assert_eq(group_again, group, "the same image again:")
  assert_eq(graphics_commands(take_sent())[1].keys.a, "t", "sent when the mask is back:")
end)

test("base64 of exactly 4096 bytes is one command, of exactly 8192 two, the last m=0", function()
  -- What the module sends is 1116 bytes + the stored scanlines, height x
  -- (width + 1): 3072 bytes (4096 in base64) at 162 x 12, 6144 at 418 x 12.
  for _, case in ipairs({ { width = 162, chunks = 1 }, { width = 418, chunks = 2 } }) do
    local path = write_mask("exact" .. case.width .. ".png", case.width, 12)
    kitty.cells(picture_of(path, 4), nil, FOREGROUND)
    local commands = graphics_commands(take_sent())
    local what = case.chunks * 4096 .. " bytes"
    assert_eq(#commands, case.chunks + 1, what .. ", commands:")
    for index = 1, case.chunks do
      assert_eq(#commands[index].payload, 4096, what .. ", chunk " .. index .. ":")
    end
    if case.chunks == 1 then
      assert_true(
        commands[1].keys.m == nil or commands[1].keys.m == "0",
        what .. ", no more to come:"
      )
    else
      assert_eq(commands[1].keys.m, "1", what .. ", first chunk:")
      assert_eq(commands[2].keys.m, "0", what .. ", last chunk:")
    end
    assert_eq(commands[#commands].keys.a, "p", what .. ", then the placement:")
  end
end)

test("more colours than are cached still come out in their colour", function()
  local first_colour ---@type string?
  for index = 1, 20 do
    local colour = string.format("%02X%02X%02X", index, 255 - index, 7 * index % 256)
    first_colour = first_colour or colour
    kitty.cells(WIDE, { columns = 3, rows = 1 }, colour)
    take_sent()
  end
  kitty.cells(WIDE, { columns = 2, rows = 1 }, first_colour)
  local png = transmitted_png(graphics_commands(take_sent()), 1)
  assert_eq(png.data_of.PLTE, vim.text.hexdecode(first_colour):rep(256), "palette:")
end)

test("a file too big, or a header no decoder takes, is missing", function()
  local whole = read_file(WIDE_PATH)
  local bad_path = scratch_directory .. "/bad.png"
  local start = vim.uv.hrtime()
  assert_missing(bad_path, "over 16 MB", whole .. ("\0"):rep(16 * 1024 * 1024))
  assert_true((vim.uv.hrtime() - start) / 1e6 < 500, "refused without reading it:")
  ---@param position integer
  ---@param value integer
  ---@return string
  local function with_byte(position, value)
    return whole:sub(1, position - 1) .. string.char(value) .. whole:sub(position + 1)
  end
  assert_missing(bad_path, "compression method 1", with_byte(27, 1))
  assert_missing(bad_path, "filter method 1", with_byte(28, 1))
  assert_missing(bad_path, "interlace method 2", with_byte(29, 2))
  assert_missing(bad_path, "zero width", png_bytes({ width = 0, height = 2, value = ramp }))
  assert_missing(bad_path, "zero height", png_bytes({ width = 2, height = 0, value = ramp }))
  assert_eq(take_sent(), "", "sent:")
end)

test("a relative path is read again from where it was, after a :cd", function()
  local current_directory = vim.fn.getcwd()
  vim.cmd.cd(vim.fn.fnameescape(scratch_directory))
  kitty.cells(picture_of("relative.png", 2), nil, FOREGROUND)
  vim.cmd.cd(vim.fn.fnameescape(current_directory))
  take_sent()
  -- Handed out, never marked: sent again.
  vim.api.nvim_exec_autocmds("VimResume", {})
  local commands = graphics_commands(take_sent())
  local widths = {} ---@type table<integer, true>
  for index, command in ipairs(commands) do
    if command.keys.a == "t" and command.keys.m == nil then
      widths[transmitted_png(commands, index).width] = true
    end
  end
  assert_true(widths[17], "the 17 px wide relative.png sent again:")
end)

test("the same relative path in another directory is another picture", function()
  local first, second = scratch_directory .. "/first", scratch_directory .. "/second"
  vim.fn.mkdir(first, "p")
  vim.fn.mkdir(second, "p")
  write_mask("first/same.png", 13, 23)
  write_mask("second/same.png", 19, 23)
  local current_directory = vim.fn.getcwd()
  vim.cmd.cd(vim.fn.fnameescape(first))
  local _, first_group = kitty.cells(picture_of("same.png", 2), nil, FOREGROUND)
  local first_commands = graphics_commands(take_sent())
  vim.cmd.cd(vim.fn.fnameescape(second))
  local _, second_group = kitty.cells(picture_of("same.png", 2), nil, FOREGROUND)
  local second_commands = graphics_commands(take_sent())
  vim.cmd.cd(vim.fn.fnameescape(current_directory))
  assert_true(second_group ~= first_group, "a group of its own:")
  assert_eq(transmitted_png(first_commands, 1).width, 13, "the first directory's mask:")
  assert_eq(#second_commands, 2, "sent for the second directory's:")
  assert_eq(transmitted_png(second_commands, 1).width, 19, "the second directory's mask:")
  local _, absolute_group = kitty.cells(picture_of(second .. "/same.png", 2), nil, FOREGROUND)
  assert_eq(absolute_group, second_group, "the same file by its absolute path:")
  assert_eq(take_sent(), "", "sent for it:")
end)

-- -----------------------------------------------------------------------------
-- Cells
-- -----------------------------------------------------------------------------

---@param rows string[]
---@param image_id integer
---@param columns integer
local function assert_cells(rows, image_id, columns)
  for row_index, row_text in ipairs(rows) do
    local cells = decode_cells(row_text)
    assert_eq(#cells, columns, "cells in row " .. row_index .. ":")
    assert_eq(vim.api.nvim_strwidth(row_text), columns, "display width of row " .. row_index .. ":")
    for column_index, cell in ipairs(cells) do
      local where = string.format("row %d cell %d", row_index, column_index)
      assert_eq(vim.api.nvim_strwidth(cell.text), 1, where .. ", display width:")
      assert_eq(cell.codepoint_count, 4, where .. ", placeholder + three diacritics:")
      assert_eq(cell.row, row_index - 1, where .. ", row diacritic:")
      assert_eq(cell.column, column_index - 1, where .. ", column diacritic:")
      assert_eq(cell.id_byte, math.floor(image_id / TWO_TO_THE_24), where .. ", id byte diacritic:")
    end
  end
end

test("a 12x1 picture is one row of 12 cells, each naming its own column", function()
  assert_eq(#wide_rows, 1, "rows:")
  -- Set by the first test, whose transmission carried it.
  ---@cast wide_image_id integer
  assert_cells(wide_rows, wide_image_id, 12)
end)

test("a 22x3 picture is three rows of 22 cells, each naming its own row and column", function()
  local rows = assert(kitty.cells(TALL, nil, FOREGROUND))
  local image_id = assert(tonumber(graphics_commands(take_sent())[1].keys.i))
  assert_eq(#rows, 3, "rows:")
  assert_cells(rows, image_id, 22)
end)

test("the rows are shared, not copied per call", function()
  assert_eq(kitty.cells(WIDE, nil, FOREGROUND), wide_rows, "the same table:")
end)

-- -----------------------------------------------------------------------------
-- Highlight
-- -----------------------------------------------------------------------------

test("the highlight names the image in fg and the placement in sp, with nocombine", function()
  local highlight = vim.api.nvim_get_hl(0, { name = wide_group })
  assert_eq(highlight.fg, wide_image_id % TWO_TO_THE_24, "fg:")
  assert_eq(highlight.sp, 1, "sp:")
  assert_eq(highlight.nocombine, true, "nocombine:")
  assert_eq(highlight.link, nil, "link:")
end)

test("the number of highlight groups grows with images, not with calls", function()
  local groups_before = count_highlight_groups()
  for _ = 1, 50 do
    kitty.cells(WIDE, nil, FOREGROUND)
    kitty.cells(TALL, nil, FOREGROUND)
    kitty.cells(WIDE, { columns = 6, rows = 1 }, FOREGROUND)
  end
  assert_eq(count_highlight_groups(), groups_before, "groups after 150 calls for known images:")
  kitty.cells(WIDE, { columns = 7, rows = 1 }, FOREGROUND)
  assert_eq(count_highlight_groups(), groups_before + 1, "groups after one new box:")
  take_sent()
end)

test("a colour scheme keeps the highlights", function()
  vim.o.termguicolors = true
  vim.cmd.colorscheme("default")
  local highlight = vim.api.nvim_get_hl(0, { name = wide_group })
  assert_eq(highlight.fg, wide_image_id % TWO_TO_THE_24, "fg after :colorscheme:")
  assert_eq(highlight.sp, 1, "sp after :colorscheme:")
  assert_eq(highlight.nocombine, true, "nocombine after :colorscheme:")
end)

test("setup can run twice without doubling its autocmds", function()
  kitty.setup()
  kitty.setup()
  for _, event in ipairs({ "ColorScheme", "VimResume", "UIEnter", "BufWipeout", "VimLeavePre" }) do
    local autocmds =
      vim.api.nvim_get_autocmds({ group = "andrew_md_render_math_kitty", event = event })
    assert_eq(#autocmds, 1, event .. " autocmds:")
  end
end)

-- -----------------------------------------------------------------------------
-- Release, sending again, exit -- on fresh modules, so that their counters and
-- what the terminal holds are known exactly, and with the collection timer
-- replaced: `run_collection()` runs what it would have run, so nothing here
-- waits for real time.
-- -----------------------------------------------------------------------------

local real_new_timer = vim.uv.new_timer
local timers = {} ---@type KittySpecFakeTimer[]
---@return uv.uv_timer_t
---@diagnostic disable-next-line: duplicate-set-field
vim.uv.new_timer = function()
  ---@class KittySpecFakeTimer
  ---@field starts integer[] the timeout of every `start`
  ---@field callback fun()? what the timer would run next
  local timer = { starts = {} }
  ---@param timeout integer
  ---@param repeat_timeout integer
  ---@param callback fun()
  ---@return 0
  function timer:start(timeout, repeat_timeout, callback)
    assert(repeat_timeout == 0, "a one-shot timer")
    self.starts[#self.starts + 1] = timeout
    self.callback = callback
    return 0
  end
  ---@return 0
  function timer:stop()
    self.callback = nil
    return 0
  end
  function timer:close() end
  timers[#timers + 1] = timer
  -- A partial uv_timer_t: start, stop and close only.
  return timer --[[@as uv.uv_timer_t]]
end

---@return boolean
local function is_collection_queued()
  local timer = timers[#timers]
  return timer ~= nil and timer.callback ~= nil
end

--- Run the queued collection as the timer would, and wait until it ran.
local function run_collection()
  local timer = assert(timers[#timers], "no timer")
  local callback = assert(timer.callback, "no collection queued")
  timer.callback = nil
  callback()
  local is_done = false
  vim.schedule(function()
    is_done = true
  end)
  vim.wait(1000, function()
    return is_done
  end, 1)
end

--- Run collections while one is queued (re-queued for spared pictures too).
---@param limit integer
local function run_collections(limit)
  for _ = 1, limit do
    if not is_collection_queued() then
      return
    end
    run_collection()
  end
end

--- `#sent_to_terminal` at each `:redraw` the module asks for; while
--- `is_redraw_refused`, the redraw fails as it does under a text lock.
local redraw_positions = {} ---@type integer[]
local is_redraw_refused = false
local real_cmd = vim.cmd
vim.cmd = setmetatable({}, {
  ---@param _ table
  ---@param name string
  ---@return function
  __index = function(_, name)
    if name == "redraw" then
      ---@param ... any the arguments of `:redraw`, passed on untouched
      return function(...)
        if is_redraw_refused then
          error("E565: Not allowed to change text or change window")
        end
        redraw_positions[#redraw_positions + 1] = #sent_to_terminal
        return real_cmd.redraw(...)
      end
    end
    return real_cmd[name]
  end,
  ---@param _ table
  ---@param ... string|vim.api.keyset.cmd
  ---@return string
  __call = function(_, ...)
    return real_cmd(...)
  end,
})

--- What the terminal holds, from everything sent by the fresh module.
---@type table<string, true>
local held_ids = {}

---@return KittySpecCommand[]
local function take_commands()
  local commands = graphics_commands(take_sent())
  for _, command in ipairs(commands) do
    if command.keys.a == "t" then
      held_ids[command.keys.i] = true
    elseif command.keys.a == "d" then
      held_ids[command.keys.i] = nil
    end
  end
  return commands
end

take_sent()
---@type KittySpecModule?
package.loaded[MODULE_NAME] = nil
---@type KittySpecModule
kitty = require(MODULE_NAME)
kitty.setup()

local SMALL_PATH = write_mask("small.png", 10, 23)
local view = vim.api.nvim_create_buf(false, true)

---@param columns integer
---@param foreground string
---@return string group
---@return string id
local function new_picture(columns, foreground)
  local _, group = kitty.cells(picture_of(SMALL_PATH, columns), nil, foreground)
  local commands = take_commands()
  assert(#commands == 2 and commands[1].keys.a == "t", "a new image")
  return group, commands[1].keys.i
end

---@class KittySpecPicture
---@field group string
---@field id string
---@field columns integer?
---@field foreground string?

local early = {} ---@type KittySpecPicture[]
local late = {} ---@type KittySpecPicture[]
---@param pictures { group: string }[]
---@param set? table<string, true>
---@return table<string, true>
local function groups_of(pictures, set)
  set = set or {}
  for _, picture in ipairs(pictures) do
    set[picture.group] = true
  end
  return set
end

test("pictures a view shows are never released; the collection waits 300 ms", function()
  for columns = 1, 40 do
    local group, id = new_picture(columns, "AAAAAA")
    early[columns] = { group = group, id = id }
  end
  assert_eq(is_collection_queued(), false, "queued before any mark:")
  kitty.mark(view, groups_of(early))
  assert_eq(is_collection_queued(), true, "queued by a mark:")
  assert_eq(timers[1].starts[1], 300, "the delay:")
  run_collection()
  for columns = 1, 130 do
    for _, foreground in ipairs({ "BBBBBB", "CCCCCC" }) do
      local group, id = new_picture(columns, foreground)
      late[#late + 1] = { group = group, id = id, columns = columns, foreground = foreground }
    end
  end
  kitty.mark(view, groups_of(late, groups_of(early)))
  run_collection()
  assert_eq(#take_commands(), 0, "commands sent for 300 shown pictures:")
  assert_eq(vim.tbl_count(held_ids), 300, "images the terminal holds:")
end)

test("the delay counts from the first request, not restarted; one timer for all", function()
  local starts_before = #timers[1].starts
  local shown = groups_of(late, groups_of(early))
  for _ = 1, 50 do
    kitty.mark(view, shown)
  end
  local other = vim.api.nvim_create_buf(false, true)
  kitty.mark(other, { [early[1].group] = true })
  vim.api.nvim_buf_delete(other, { force = true })
  assert_eq(#timers[1].starts, starts_before + 1, "timer starts for 51 marks and a wipe:")
  assert_eq(#timers, 1, "timers made:")
  run_collection()
  assert_eq(take_sent(), "", "sent:")
end)

local released = {} ---@type table<string, true>

test("unshown pictures beyond 256 go at the collection, oldest first, after a redraw", function()
  kitty.mark(view, groups_of({ late[1], late[2], late[3], late[4] }))
  -- Handed out again (content being built), though no view shows it yet.
  kitty.cells(picture_of(SMALL_PATH, 1), nil, "AAAAAA")
  assert_eq(take_sent(), "", "sent before the collection:")
  redraw_positions = {}
  run_collection()
  assert_eq(redraw_positions[1], 0, "a redraw, before anything was sent:")
  local ids, count = deleted_ids(take_commands())
  -- 296 unshown: 40 early (older) and 256 late; 40 - 1 spared go.
  assert_eq(count, 39, "deletes:")
  for index = 2, 40 do
    assert_true(ids[early[index].id], "early picture " .. index .. " deleted:")
  end
  assert_eq(ids[early[1].id], nil, "the one just handed out, deleted:")
  released = ids
end)

local recycled ---@type KittySpecPicture

test("a released id is used again, the longest-freed first, its group too", function()
  local groups_before = count_highlight_groups()
  local recycled_path = write_mask("recycled.png", 30, 23)
  -- A recycled id's group is defined already: no `nvim_set_hl` at all.
  local definitions = 0
  local original_set_hl = vim.api.nvim_set_hl
  ---@type fun(ns_id: integer, name: string, val: vim.api.keyset.highlight)
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.api.nvim_set_hl = function(...)
    definitions = definitions + 1
    return original_set_hl(...)
  end
  local _, group = kitty.cells(picture_of(recycled_path, 3), nil, "DDDDDD")
  vim.api.nvim_set_hl = original_set_hl
  local commands = take_commands()
  local id = commands[1].keys.i
  assert_eq(id, early[2].id, "the new image's id, the first one freed:")
  assert_eq(group, "MdRenderMathPicture" .. id, "its group:")
  assert_eq(definitions, 0, "highlight groups defined:")
  assert_eq(count_highlight_groups(), groups_before, "highlight groups:")
  assert_eq(vim.api.nvim_get_hl(0, { name = group }).fg, tonumber(id) % TWO_TO_THE_24, "fg:")
  local png = transmitted_png(commands, 1)
  assert_eq(png.width, 30, "the new picture is sent under the old id:")
  assert_eq(png.data_of.PLTE:sub(1, 3), "\221\221\221", "in its colour:")
  recycled = { group = group, id = id }
end)

test(
  "a resumed or new UI gets the shown and the not yet shown at once, the rest when used",
  function()
    run_collections(5)
    take_commands()
    for _, event in ipairs({ "VimResume", "UIEnter" }) do
      vim.api.nvim_exec_autocmds(event, {})
      local commands = take_commands()
      ---@type table<string, KittySpecPng>, table<string, table<string, string>>
      local png_of_id, place_of_id = {}, {}
      for index = 1, #commands, 2 do
        assert_eq(commands[index].keys.a, "t", event .. ", command " .. index .. ":")
        assert_eq(commands[index + 1].keys.a, "p", event .. ", command " .. index + 1 .. ":")
        assert_eq(
          commands[index + 1].keys.i,
          commands[index].keys.i,
          event .. ", placed what was sent:"
        )
        png_of_id[commands[index].keys.i] = transmitted_png(commands, index)
        place_of_id[commands[index].keys.i] = commands[index + 1].keys
      end
      -- 4 shown, and the recycled one: handed out, never marked.
      assert_eq(#commands, 10, event .. ", commands:")
      for index = 1, 4 do
        local picture = late[index]
        local png = png_of_id[picture.id]
        assert_true(png ~= nil, event .. ", shown picture " .. index .. " sent:")
        assert_eq(
          png and png.data_of.PLTE:sub(1, 3),
          vim.text.hexdecode(picture.foreground),
          event .. ", shown picture " .. index .. ", its colour:"
        )
        assert_eq(place_of_id[picture.id].c, tostring(picture.columns), event .. ", its columns:")
        assert_eq(place_of_id[picture.id].r, "1", event .. ", its rows:")
      end
      assert_true(png_of_id[recycled.id] ~= nil, event .. ", the one not yet marked sent:")
      kitty.cells(picture_of(SMALL_PATH, 1), nil, "BBBBBB")
      assert_eq(take_sent(), "", event .. ", sent for a shown picture's next use:")
    end
    -- The last made: not shown, and still known (released go lowest counter
    -- first among the equally old).
    kitty.cells(picture_of(SMALL_PATH, 130), nil, "CCCCCC")
    local commands = take_commands()
    assert_eq(
      commands[1] and commands[1].keys.i,
      late[#late].id,
      "an unshown one, sent on its next use:"
    )
  end
)

test("a colour scheme defines the known groups again, a recycled one when used", function()
  vim.cmd.colorscheme("default")
  local highlight = vim.api.nvim_get_hl(0, { name = late[1].group })
  assert_eq(highlight.fg, tonumber(late[1].id) % TWO_TO_THE_24, "a shown picture's fg:")
  assert_eq(highlight.nocombine, true, "nocombine:")
  local _, group = kitty.cells(picture_of(write_mask("after-scheme.png", 10, 23), 1), nil, "EEEEEE")
  local id = take_commands()[1].keys.i
  assert_true(released[id], "a released id, " .. id .. ":")
  assert_eq(vim.api.nvim_get_hl(0, { name = group }).fg, tonumber(id) % TWO_TO_THE_24, "its fg:")
end)

test("a wiped view's pictures are released without a mark", function()
  -- Settle: no grace for the never-marked ones, so that nothing stays queued;
  -- 256 unshown kept, none handed out since the last collection.
  kitty.setup({ unmarked_grace_milliseconds = 0 })
  kitty.mark(view, groups_of({ late[1], late[2], late[3], late[4] }))
  run_collections(10)
  take_commands()
  assert_eq(is_collection_queued(), false, "queued before the wipe:")
  vim.api.nvim_buf_delete(view, { force = true })
  assert_eq(is_collection_queued(), true, "queued by the wipe:")
  run_collection()
  local _, count = deleted_ids(take_commands())
  assert_eq(count, 4, "deletes after the wipe (its 4 shown pictures unshown):")
end)

test("VimLeavePre leaves nothing in the terminal", function()
  take_commands()
  assert_true(vim.tbl_count(held_ids) > 0, "images held before:")
  vim.api.nvim_exec_autocmds("VimLeavePre", {})
  deleted_ids(take_commands())
  assert_eq(vim.tbl_count(held_ids), 0, "images held after:")
  vim.api.nvim_exec_autocmds("VimLeavePre", {})
  assert_eq(take_sent(), "", "a second VimLeavePre:")
end)

-- Another fresh module that keeps no unshown picture, so that each rule shows
-- on a few pictures.
take_sent()
---@type KittySpecModule?
package.loaded[MODULE_NAME] = nil
---@type KittySpecModule
kitty = require(MODULE_NAME)
kitty.setup({
  keep_unshown = 0,
  collection_delay_milliseconds = 40,
  unmarked_grace_milliseconds = 10000,
})
held_ids = {}
local owner = vim.api.nvim_create_buf(false, true)

test("the delay is a setup option", function()
  local _, group = new_picture(1, "111111")
  kitty.mark(owner, { [group] = true })
  assert_eq(timers[#timers].starts[1], 40, "the delay given:")
  run_collection()
  assert_eq(take_sent(), "", "sent for a shown picture:")
end)

test(
  "a picture handed out and not yet marked is sent again on VimResume, collections later",
  function()
    local _, id = new_picture(2, "111111")
    kitty.mark(owner, {})
    run_collection()
    kitty.mark(vim.api.nvim_create_buf(false, true), { x = true })
    run_collection()
    deleted_ids(take_commands())
    vim.api.nvim_exec_autocmds("VimResume", {})
    local sent_ids = {} ---@type table<string, string>
    for _, command in ipairs(take_commands()) do
      sent_ids[command.keys.i] = command.keys.a
    end
    assert_eq(sent_ids[id], "p", "sent again:")
  end
)

test("mark(owner, {}) unshows; an owner that showed nothing queues nothing", function()
  -- No grace from here on: nothing stays queued for a never-marked picture.
  kitty.setup({ unmarked_grace_milliseconds = 0 })
  run_collections(5)
  take_commands()
  assert_eq(is_collection_queued(), false, "queued before:")
  kitty.mark(vim.api.nvim_create_buf(false, true), {})
  assert_eq(is_collection_queued(), false, "queued by an empty mark of nothing:")
  local group, id = new_picture(3, "111111")
  local kept_group, kept_id = new_picture(4, "111111")
  kitty.mark(owner, { [group] = true, [kept_group] = true })
  run_collection()
  assert_eq(take_sent(), "", "sent while both are shown:")
  kitty.mark(owner, { [kept_group] = true })
  run_collection()
  local ids = deleted_ids(take_commands())
  assert_true(ids[id], "the one no longer marked, deleted:")
  assert_eq(ids[kept_id], nil, "the one still marked, deleted:")
  kitty.mark(owner, {})
  assert_eq(is_collection_queued(), true, "queued by an empty mark:")
  run_collections(5)
  assert_true(deleted_ids(take_commands())[kept_id], "the one unshown by the empty mark, deleted:")
end)

test("a view closed with :bdelete (unloaded) shows nothing", function()
  local listed = vim.api.nvim_create_buf(true, false)
  local group, id = new_picture(5, "111111")
  kitty.mark(listed, { [group] = true })
  run_collection()
  vim.cmd("bdelete! " .. listed)
  assert_eq(vim.api.nvim_buf_is_valid(listed), true, "still a buffer:")
  assert_eq(vim.api.nvim_buf_is_loaded(listed), false, "unloaded:")
  kitty.mark(owner, { other = true })
  run_collections(5)
  assert_true(deleted_ids(take_commands())[id], "its picture deleted:")
end)

test("a picture sent again by cells is spared like a hand-out", function()
  local picture = picture_of(SMALL_PATH, 6)
  local _, group = kitty.cells(picture, nil, "111111")
  local id = take_commands()[1].keys.i
  kitty.mark(owner, { [group] = true })
  run_collection()
  kitty.mark(owner, { [group] = true })
  run_collection()
  kitty.mark(owner, {})
  vim.api.nvim_exec_autocmds("VimResume", {})
  assert_eq(take_sent(), "", "sent on VimResume (not shown, not recent):")
  kitty.cells(picture, nil, "111111")
  assert_eq(take_commands()[1].keys.i, id, "sent again by cells:")
  run_collection()
  assert_eq(take_sent(), "", "deleted by the collection right after:")
  run_collection()
  assert_true(deleted_ids(take_commands())[id], "deleted by the next one:")
end)

test("a picture never marked is kept for the grace, then released", function()
  kitty.setup({ unmarked_grace_milliseconds = 60 })
  run_collections(5)
  take_commands()
  local _, id = new_picture(7, "111111")
  kitty.mark(owner, { other = true })
  run_collections(3)
  assert_eq(take_sent(), "", "deleted within the grace:")
  vim.wait(120, function()
    return false
  end, 10)
  run_collections(3)
  assert_true(deleted_ids(take_commands())[id], "deleted after the grace:")
  assert_eq(is_collection_queued(), false, "collections queued once nothing is spared:")
end)

test("a collection put off by a text lock takes no sparing away", function()
  kitty.setup({ unmarked_grace_milliseconds = 0 })
  run_collections(5)
  take_commands()
  local gone_group, gone_id = new_picture(8, "111111")
  kitty.mark(owner, { [gone_group] = true })
  run_collection()
  kitty.mark(owner, {})
  -- Handed out since the last collection that ran: spared by the next one.
  local _, spared_id = new_picture(9, "111111")
  is_redraw_refused = true
  run_collection()
  is_redraw_refused = false
  assert_eq(take_sent(), "", "deleted while the redraw was refused:")
  assert_eq(is_collection_queued(), true, "queued again:")
  run_collection()
  local ids = deleted_ids(take_commands())
  assert_true(ids[gone_id], "the unshown one, deleted once it can redraw:")
  assert_eq(ids[spared_id], nil, "the one handed out before the refused one, deleted:")
end)

vim.uv.new_timer = real_new_timer
vim.cmd = real_cmd
kitty.setup()

-- -----------------------------------------------------------------------------
-- The terminal
-- -----------------------------------------------------------------------------

local ENVIRONMENT_NAMES = {
  "TMUX",
  "TMUX_PANE",
  "ZELLIJ",
  "NVIM",
  "SSH_CONNECTION",
  "SSH_CLIENT",
  "SSH_TTY",
  "KITTY_WINDOW_ID",
  "KITTY_PID",
  "TERM",
  "TERM_PROGRAM",
  "GHOSTTY_RESOURCES_DIR",
}
local saved_environment = {} ---@type table<string, string>
for _, name in ipairs(ENVIRONMENT_NAMES) do
  saved_environment[name] = vim.env[name]
end

--- The module as freshly loaded, and first asked, in an environment of just
--- `variables`.
---@param variables table<string, string>
---@return KittySpecModule
local function module_in_environment(variables)
  for _, name in ipairs(ENVIRONMENT_NAMES) do
    vim.env[name] = variables[name]
  end
  ---@type KittySpecModule?
  package.loaded[MODULE_NAME] = nil
  local fresh_module = require(MODULE_NAME) ---@type KittySpecModule
  fresh_module.is_supported()
  for _, name in ipairs(ENVIRONMENT_NAMES) do
    vim.env[name] = saved_environment[name]
  end
  return fresh_module
end

local KITTY = { TERM = "xterm-kitty", KITTY_WINDOW_ID = "3", KITTY_PID = "1234" }

---@param kitty_module KittySpecModule
---@param expected boolean
---@param what string
local function assert_supported(kitty_module, expected, what)
  local is_supported, reason = kitty_module.is_supported()
  assert_eq(is_supported, expected, what .. ":")
  if expected then
    assert_eq(reason, nil, what .. ", reason:")
  else
    assert_true(type(reason) == "string" and reason ~= "", what .. ", a reason:")
  end
end

test("Kitty and Ghostty draw the pictures, also over ssh", function()
  vim.o.termguicolors = true
  assert_supported(module_in_environment(KITTY), true, "Kitty")
  assert_supported(module_in_environment({ KITTY_WINDOW_ID = "3" }), true, "Kitty, TERM changed")
  assert_supported(module_in_environment({ TERM_PROGRAM = "ghostty" }), true, "Ghostty")
  local over_ssh = vim.tbl_extend("force", KITTY, { SSH_CONNECTION = "10.0.0.1 22 10.0.0.2 22" })
  assert_supported(module_in_environment(over_ssh), true, "ssh from Kitty")
  assert_supported(
    module_in_environment({ TERM = "xterm-kitty", SSH_TTY = "/dev/pts/3" }),
    true,
    "ssh, only TERM forwarded"
  )
end)

test(
  "a :terminal of another Neovim, multiplexers it cannot ask and other terminals do not",
  function()
    vim.o.termguicolors = true
    local tmux_terminal = vim.tbl_extend("force", KITTY, { TERM = "tmux-256color" })
    assert_supported(module_in_environment(tmux_terminal), false, "TERM of tmux, no TMUX")
    local screen = vim.tbl_extend("force", KITTY, { TERM = "screen-256color" })
    assert_supported(module_in_environment(screen), false, "GNU screen")
    local zellij = vim.tbl_extend("force", KITTY, { ZELLIJ = "0" })
    assert_supported(module_in_environment(zellij), false, "zellij")
    local in_terminal = vim.tbl_extend("force", KITTY, { NVIM = "/run/user/1000/nvim.1.0" })
    assert_supported(module_in_environment(in_terminal), false, ":terminal in Kitty")
    assert_supported(module_in_environment({ TERM = "xterm-256color" }), false, "xterm")
  end
)

test("no pictures without 'termguicolors': the image id is a 24-bit colour", function()
  local kitty_module = module_in_environment(KITTY)
  vim.o.termguicolors = false
  local is_supported, reason = kitty_module.is_supported()
  vim.o.termguicolors = true
  assert_eq(is_supported, false, "Kitty, 'notermguicolors':")
  -- is_supported gives a reason with every false.
  ---@cast reason string
  assert_true(reason:find("termguicolors", 1, true) ~= nil, "the reason names it:")
  assert_eq(kitty_module.is_supported(), true, "Kitty, 'termguicolors' again:")
end)

test("the environment is read once", function()
  local kitty_module = module_in_environment(KITTY)
  assert_eq(kitty_module.is_supported(), true, "first answer:")
  vim.env.NVIM = "/run/user/1000/nvim.1.0"
  local later_answer = kitty_module.is_supported()
  vim.env.NVIM = saved_environment.NVIM
  assert_eq(later_answer, true, "answer after NVIM appeared:")
end)

-- tmux: `vim.system` is replaced, so no tmux is needed and its answer is ours.

---@class KittySpecSystemCall
---@field command string[]
---@field options vim.SystemOpts?
---@field on_exit fun(out: vim.SystemCompleted)?
---@field kills (integer|string)[] the signal of every `kill`

---@class KittySpecFakeSystemObj
---@field kill fun(self: KittySpecFakeSystemObj, signal: integer|string)

local system_calls = {} ---@type KittySpecSystemCall[]
local system_error ---@type string? what the replaced `vim.system` raises
local original_system = vim.system
---@param command string[]
---@param options vim.SystemOpts?
---@param on_exit? fun(out: vim.SystemCompleted)
---@return vim.SystemObj
local function fake_system(command, options, on_exit)
  if system_error then
    error(system_error)
  end
  ---@type KittySpecSystemCall
  local call = { command = command, options = options, on_exit = on_exit, kills = {} }
  system_calls[#system_calls + 1] = call
  -- A partial vim.SystemObj: `kill` is all the module calls.
  return ({
    ---@param _ KittySpecFakeSystemObj
    ---@param signal integer|string
    kill = function(_, signal)
      call.kills[#call.kills + 1] = signal
    end,
  } --[[@as KittySpecFakeSystemObj]]) --[[@as vim.SystemObj]]
end
vim.system = fake_system

local terminal_events = 0
vim.api.nvim_create_autocmd("User", {
  pattern = "MdRenderMathTerminal",
  callback = function()
    terminal_events = terminal_events + 1
  end,
})

local TMUX_IN_KITTY = vim.tbl_extend(
  "force",
  KITTY,
  { TMUX = "/tmp/tmux-1000/default,1,0", TMUX_PANE = "%3", TERM = "tmux-256color" }
)

---@param answer string|vim.SystemCompleted what tmux answers (stdout of exit code 0, or all)
---@return KittySpecModule kitty_module
local function module_in_tmux(answer)
  system_calls, terminal_events = {}, 0
  local kitty_module = module_in_environment(TMUX_IN_KITTY)
  kitty_module.setup()
  assert_supported(kitty_module, false, "before tmux answered")
  assert_eq(#system_calls, 1, "tmux asked:")
  local result = type(answer) == "table" and answer
    or { code = 0, signal = 0, stdout = answer .. "\n", stderr = "" }
  system_calls[1].on_exit(result)
  vim.wait(500, function()
    return kitty_module.is_supported() or terminal_events > 0
  end, 5)
  vim.wait(20, function()
    return false
  end)
  return kitty_module
end

test("in tmux: allow-passthrough is read once, asynchronously, and only read", function()
  local kitty_module = module_in_tmux("on")
  assert_eq(
    table.concat(system_calls[1].command, " "),
    "tmux show-options -Apv -t %3 allow-passthrough",
    "the one command run:"
  )
  for _ = 1, 3 do
    kitty_module.is_supported()
  end
  kitty_module.setup()
  assert_eq(#system_calls, 1, "commands run after more questions and setups:")
  local timeout = system_calls[1].options and system_calls[1].options.timeout
  assert_true(type(timeout) == "number" and timeout <= 5000, "a timeout of at most 5 s:")
end)

test("in tmux with passthrough on: pictures, every escape wrapped, the event once", function()
  for _, value in ipairs({ "on", "all" }) do
    local kitty_module = module_in_tmux(value)
    assert_supported(kitty_module, true, "allow-passthrough " .. value)
    assert_eq(terminal_events, 1, "User MdRenderMathTerminal fired:")
  end
  local kitty_module = module_in_tmux("on")
  take_sent()
  kitty_module.cells(picture_of(LARGE_PATH, 20, 3), nil, FOREGROUND)
  local sent = take_sent()
  ---@type string[], integer
  local unwrapped, covered = {}, 0
  -- string.gmatch is annotated with one capture; this pattern has two.
  for whole, body in sent:gmatch("(\27Ptmux;\27\27_G([^\27]*)\27\27\\\27\\)") --[[@as fun(): string, string]] do
    covered = covered + #whole
    unwrapped[#unwrapped + 1] = "\27_G" .. body .. "\27\\"
  end
  assert_eq(covered, #sent, "bytes sent outside a passthrough:")
  local commands = graphics_commands(table.concat(unwrapped))
  assert_true(#commands >= 4, "chunks and a placement, each wrapped: " .. #commands)
  assert_eq(commands[#commands].keys.a, "p", "the placement:")
  vim.api.nvim_exec_autocmds("VimLeavePre", {})
  assert_true(take_sent():find("^\27Ptmux;\27\27_Ga=d,d=I,") ~= nil, "the delete at exit, wrapped:")
  kitty.setup() -- the spec's own module's autocmds back
end)

test("in tmux with passthrough off, or none to ask: no pictures, a reason, no event", function()
  local kitty_module = module_in_tmux("off")
  local is_supported, reason = kitty_module.is_supported()
  assert_eq(is_supported, false, "allow-passthrough off:")
  -- is_supported gives a reason with every false.
  ---@cast reason string
  assert_true(reason:find("allow-passthrough is off", 1, true) ~= nil, "the reason: " .. reason)
  assert_eq(terminal_events, 0, "User MdRenderMathTerminal fired:")
  system_calls = {}
  local not_kitty = { TMUX = "/tmp/tmux-1000/default,1,0", TERM = "tmux-256color" }
  assert_supported(module_in_environment(not_kitty), false, "tmux not started in Kitty")
  assert_eq(#system_calls, 0, "tmux asked:")
  kitty.setup()
end)

test("in tmux that fails, prints garbage or cannot be run: no pictures, a short reason", function()
  local failing = module_in_tmux({
    code = 1,
    signal = 0,
    stdout = "on\n",
    stderr = "invalid option: allow-passthrough\n",
  })
  local is_supported, reason = failing.is_supported()
  assert_eq(is_supported, false, "tmux < 3.3 (exit 1):")
  -- is_supported gives a reason with every false.
  ---@cast reason string
  assert_true(
    reason:find("invalid option", 1, true) ~= nil,
    "its message in the reason: " .. reason
  )
  local noisy = module_in_tmux({
    code = 0,
    signal = 0,
    stdout = ("\0\255on"):rep(100000),
    stderr = ("\1x"):rep(100000),
  })
  is_supported, reason = noisy.is_supported()
  assert_eq(is_supported, false, "garbage:")
  ---@cast reason string
  assert_true(#reason <= 200, "a short reason: " .. #reason .. " bytes")
  assert_eq(terminal_events, 0, "User MdRenderMathTerminal fired:")
  system_error = "ENOENT: no such file or directory"
  local missing = module_in_environment(TMUX_IN_KITTY)
  system_error = nil
  is_supported, reason = missing.is_supported()
  assert_eq(is_supported, false, "no tmux to run:")
  assert_true(type(reason) == "string" and reason ~= "", "a reason:")
  kitty.setup()
end)

test("in tmux, a check still running at VimLeavePre is killed", function()
  system_calls = {}
  local kitty_module = module_in_environment(TMUX_IN_KITTY)
  kitty_module.setup()
  vim.api.nvim_exec_autocmds("VimLeavePre", {})
  assert_eq(#system_calls[1].kills, 1, "kills:")
  kitty.setup()
end)

vim.system = original_system

-- -----------------------------------------------------------------------------
-- Cell size
-- -----------------------------------------------------------------------------

local md_render_directory = vim.fn.stdpath("data") .. "/lazy/md-render.nvim"
if vim.fn.isdirectory(md_render_directory) == 1 then
  vim.opt.runtimepath:append(md_render_directory)
  local md_render_image = require("md-render.image")

  test("the cell size is md-render's, rounded to whole pixels", function()
    md_render_image._test_cell_size = { cell_w = 10, cell_h = 23 }
    local cell_width, cell_height = kitty.cell_size()
    assert_eq(cell_width, 10, "cell width:")
    assert_eq(cell_height, 23, "cell height:")
    md_render_image._test_cell_size = { cell_w = 9.6, cell_h = 20.4 }
    cell_width, cell_height = kitty.cell_size()
    assert_eq(cell_width, 10, "cell width of 9.6:")
    assert_eq(cell_height, 20, "cell height of 20.4:")
  end)

  test("no cell size when md-render reports none that can be used", function()
    md_render_image._test_cell_size = { cell_w = 0 / 0, cell_h = 23 }
    assert_eq(kitty.cell_size(), nil, "NaN width:")
    md_render_image._test_cell_size = { cell_w = math.huge, cell_h = 23 }
    assert_eq(kitty.cell_size(), nil, "infinite width:")
    md_render_image._test_cell_size = { cell_w = 0, cell_h = 0 }
    assert_eq(kitty.cell_size(), nil, "zero:")
    md_render_image._test_cell_size = nil
    local original_get_cell_size = md_render_image.get_cell_size
    ---@return { cell_w: number, cell_h: number }?
    local function no_cell_size()
      return nil
    end
    md_render_image.get_cell_size = no_cell_size
    local cell_width = kitty.cell_size()
    md_render_image.get_cell_size = original_get_cell_size
    assert_eq(cell_width, nil, "no size at all:")
  end)
else
  print("  SKIP: md-render.nvim not installed at " .. md_render_directory .. " (cell size)")
end

vim.fn.delete(scratch_directory, "rf")
_H.finish()
