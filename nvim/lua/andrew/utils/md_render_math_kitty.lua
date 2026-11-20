-- =============================================================================
-- md-render math: pictures as Kitty Unicode-placeholder cells
-- =============================================================================
-- Part of the rendered math of md_render_math.lua. md-render has no math
-- pictures at all (it colours raw TeX); its own images are absolute
-- placements that it re-places on every scroll, redraw and tab change. A
-- typeset equation here is TEXT instead: a run of cells, each `U+10EEEE` with
-- a row, a column and an image-id diacritic, in a highlight whose foreground
-- colour names the image (Kitty graphics protocol, "Unicode placeholders",
-- https://sw.kovidgoyal.net/kitty/graphics-protocol/#unicode-placeholders).
-- The terminal draws the picture wherever Neovim draws those cells, so
-- nothing is placed again on scroll, in floats or on other tab pages.
--
-- A picture file is a colour-free coverage mask (md_render_math_tex.lua): an
-- 8-bit greyscale PNG, value v = ink coverage (255 - v) / 255, followed after
-- IEND by a text record this module ignores. An image here is (mask, box,
-- foreground). The first time one is wanted, `cells` reads the mask, makes it
-- a palette PNG of that colour in memory and sends the BYTES:
--
--   ESC _G a=t,f=100,t=d,i=<image>,q=2,m=1 ; <base64, 4096 bytes> ESC \
--   ESC _G m=1,q=2 ; <next 4096> ESC \  ...  ESC _G m=0,q=2 ; <rest> ESC \
--   ESC _G a=p,U=1,i=<image>,p=1,c=<columns>,r=<rows>,C=1,q=2 ESC \
--
-- (one `a=t,...` command without `m` when the base64 fits in 4096 bytes, the
-- protocol's chunk limit), then a VIRTUAL placement of `columns` x `rows`
-- cells that the placeholder cells point into. snacks.nvim does the same for
-- math in the source buffer (snacks.nvim/lua/snacks/image/image.lua:141-151,
-- placement.lua:551-560).
--
-- Decisions, each checked against Kitty 0.49.2's own parser and graphics
-- manager driven headlessly (kitty_tests helpers, `update_layers`):
--
--   * Tinting: grey-8 and palette-8 rows are the same bytes with the same
--     filters, so the mask's IDAT is sent unchanged behind a new IHDR (colour
--     type 3), a `PLTE` of 256 times the foreground and a `tRNS` of alphas
--     255..0; no zlib. The two colour chunks are made once per colour. Kitty
--     decodes it to the foreground with alpha = coverage, within 3/255 of
--     the RGBA pictures mutool drew in colour before. Ancillary chunks of the
--     mask are dropped: a grey `sBIT`/`bKGD` is invalid in a palette PNG.
--   * Bytes (`t=d`), not a path (`t=f`): no tinted file on disk, one path for
--     local, ssh and containers (the terminal need not see our disk), and
--     Kitty loads them a little faster (no path policy calls: 36.8 vs 41.7 ms
--     median per 150 pictures on a loaded machine, RevKitty `tf_time.py`).
--     Costs ~2.6 kB through the tty per picture instead of ~110 B, and on the
--     main thread ~9 us per first use (read 4.3, tint 1.3, base64 and escapes
--     3) on top of the group definition. The bytes are not kept: a re-send
--     reads the mask again.
--   * One image per (mask, box, foreground), each with its one placement
--     `p=1`. A second placement of one image would be told apart only by the
--     placement id in the cells' UNDERLINE colour, and Neovim sends an
--     underline colour only for cells that are underlined; without it Kitty
--     takes "the first" virtual placement of the image, which is either one.
--   * Image ids `high byte << 24 | counter` with a non-zero high byte taken
--     from the pid, written as a third diacritic on every cell: snacks' ids
--     (`pid hash << 14 | counter`) and md-render's (from 101) are below 2^24,
--     so none is ever the same, and md-render's `a=d,d=i,i=N` never hits one.
--   * Release, mark and sweep: the adapter tells `mark` which picture groups
--     each view buffer shows. 300 ms after the first `mark` (or BufWipeout)
--     since the last collection -- not restarted by later ones, so a stream
--     of rebuilds still releases -- images no loaded owner shows are
--     candidates, except one handed out since the collection before, and one
--     no view was ever seen to show, for 30 s after its last hand-out (built
--     now, applied later). All but the 256 most recently used (they make a
--     colour scheme switched back, an undo or a revisited preview free) are
--     deleted (`a=d,d=I`: placement and data), right after a redraw
--     (`collect` says why), and their counters queued for reuse, the
--     longest-freed first.
--   * Counters are reused, and with them the image ids and highlight groups:
--     a group's definition depends on the id alone, so a recycled one is not
--     defined again (each new group costs Neovim a redraw of every window,
--     ~8 ms in the full config, Memory `e10b_full.lua`), and the groups stay
--     at the high-water mark of images known at once -- far from Neovim's
--     19,999 (E849, after which every plugin's new group fails).
--     Transmitting a recycled id replaces the old picture's data.
--   * The highlight sets `sp` to the placement id: an underline from a
--     highlight UNDER this one (a link) then carries `p=1` rather than
--     Neovim's default underline colour, which Kitty would read as some other
--     placement and draw nothing. `nocombine` drops the underline and reverse
--     of lower highlights altogether (reverse would swap away the image id)
--     and keeps their backgrounds, CursorLine's and Visual's: the picture
--     has a transparent background and they show behind it.
--   * Every cell has explicit row and column diacritics, so a run md-render
--     wraps or cuts still shows the right part of the picture.
--   * tmux: every graphics escape goes through tmux passthrough
--     (`ESC P tmux; ESC ESC _G ... ESC ESC \ ESC \`, as snacks.nvim does,
--     snacks/image/terminal.lua:30-33); the cells are plain text and 24-bit
--     colour to tmux. Only with the pane's `allow-passthrough` on/all: read
--     ONCE, asynchronously, from `setup` or the first `is_supported` (one
--     `tmux show-options`, never on the build path, the user's options
--     untouched). Until the answer is in `is_supported` says no; when it says
--     yes, `User MdRenderMathTerminal` fires once so the adapter rebuilds its
--     views with pictures. The outer terminal is known from the environment
--     tmux was started in (Kitty's and Ghostty's variables).
--
-- What makes the terminal forget a picture, and what is done about it:
--
--   * This module's own deletes: on release (above) and on VimLeavePre,
--     which deletes every image it has sent, so nothing is left in the
--     terminal after Neovim. Kitty itself keeps them through everything else
--     (`CSI 2J`/`3J`, leaving the alt screen, RIS -- measured in 0.49.2).
--   * md-render's deletes (`a=d,d=A` on its first image and on view
--     teardown, `a=d,d=a,i=N`): nothing. In Kitty `d=a/A` skip virtual
--     placements and free only images whose placements they removed
--     (kitty/graphics.c `clear_filter_func_noncell`, `filter_refs`), so
--     they never touch these.
--   * Another program on the same screen using the same image ids while
--     Neovim is suspended, or a UI that attaches anew (`:detach`, remote
--     UIs): the shown pictures and those handed out but not yet shown are
--     sent again on VimResume and UIEnter, the rest when they are next used.
--   * `:colorscheme` clears every highlight group: ColorScheme defines the
--     known images' groups again, or the cells would lose the image id.
--   * NOT handled: Kitty evicting images past its storage quota (320 MB per
--     screen by default, oldest first, even one on screen) -- it tells
--     Neovim nothing; a tmux client attached from another terminal, which
--     holds none of the images (a re-send on FocusGained would be the
--     trigger; untested, left out); nested tmux (one wrap only); another
--     Neovim in the same window with the same high byte (1 in 127) deleting
--     these ids at its exit; a Neovim killed (`kill -9`) leaves up to the
--     shown + 256 images in the terminal, as no VimLeavePre runs.
--
-- How the cells have to be applied (md_render_math.lua does it): as ONE
-- highlight over exactly the returned cells, in an extmark of priority above
-- every other highlight there (md-render's go up to 4200), with `spell =
-- false` -- spell checking takes the cells for a word and its undercurl
-- colour beats any highlight. Needs 'termguicolors': the image id is a 24-bit
-- colour.
--
-- Pinned by tests/md_render_math_kitty_spec.lua, which reads what is sent to
-- the terminal, decodes the PNGs and the cells. Drop this file when
-- md-render draws math pictures itself.

local bit = require("bit")

local M = {}

--- U+10EEEE, the character Kitty draws a piece of an image in place of.
local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)

--- Kitty's row/column/byte diacritics: the n-th (from 0) stands for n
--- (kitty gen/rowcolumn-diacritics.txt). A picture can therefore be at most
--- this many cells wide and high.
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
  0x0F82, 0x0F83, 0x0F86, 0x0F87, 0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
  0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D, 0x1B6E, 0x1B6F, 0x1B70, 0x1B71,
  0x1B72, 0x1B73, 0x1CD0, 0x1CD1, 0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
  0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1, 0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5,
  0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9, 0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
  0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1, 0x20D4, 0x20D5, 0x20D6, 0x20D7,
  0x20DB, 0x20DC, 0x20E1, 0x20E7, 0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
  0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA, 0x2DEB, 0x2DEC, 0x2DED, 0x2DEE,
  0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2, 0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
  0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D, 0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1,
  0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5, 0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9, 0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED,
  0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2, 0xAAB3, 0xAAB7, 0xAAB8, 0xAABE, 0xAABF, 0xAAC1,
  0xFE20, 0xFE21, 0xFE22, 0xFE23, 0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187,
  0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243, 0x1D244,
}

--- The most cells a picture can span in either direction.
M.MAX_CELLS = #DIACRITIC_CODEPOINTS

--- Diacritic for the number n is DIACRITIC_OF_NUMBER[n + 1].
---@type string[]
local DIACRITIC_OF_NUMBER = {}
for index, codepoint in ipairs(DIACRITIC_CODEPOINTS) do
  DIACRITIC_OF_NUMBER[index] = vim.fn.nr2char(codepoint)
end

local TWO_TO_THE_24 = 0x1000000

--- Most significant byte of every image id here: non-zero, so no id is one of
--- snacks' or md-render's (both below 2^24), and differing between Neovim
--- processes so that one started while another is suspended in the same
--- window rarely reuses an id. Below 128 so that ids stay below 2^31.
local IMAGE_ID_HIGH_BYTE = 1 + vim.uv.os_getpid() % 127

--- The third diacritic of every cell: that byte.
local ID_BYTE_DIACRITIC = DIACRITIC_OF_NUMBER[IMAGE_ID_HIGH_BYTE + 1]

--- Every image has exactly one placement, always this one.
local PLACEMENT_ID = 1

local HIGHLIGHT_GROUP_PREFIX = "MdRenderMathPicture"

local AUGROUP_NAME = "andrew_md_render_math_kitty"

--- Kitty takes at most 4096 bytes of base64 per escape code (graphics
--- protocol, "Remote client"); a multiple of 4, as every chunk but the last
--- has to be.
local CHUNK_BYTES = 4096

--- Setup option (for tests), as the next two: unshown pictures are released
--- this long after the first `mark` that unshowed them, so a burst of
--- rebuilds costs one collection.
local collection_delay_milliseconds = 300

--- How long a picture `cells` handed out, that no view was ever seen to
--- show, is kept after its last hand-out -- the caller may build now and
--- apply (and `mark`) later.
local unmarked_grace_milliseconds = 30000

--- Pictures kept in the terminal although no view shows them, the most
--- recently used: 256 keep a colour scheme toggled back, an undo or a
--- revisited preview free (Memory review: 2-3 MB in Kitty in practice).
local keep_unshown = 256

--- Masks are a few kB (the largest of the corpus 2.7 kB, 3000 x 920 px about
--- 0.3 MB); anything bigger at a mask's path is not read.
local MAX_MASK_BYTES = 16 * 1024 * 1024

--- Colours whose `PLTE`/`tRNS` chunks are kept (~1 kB each); past this the
--- cache starts again (a miss costs one CRC over 772 bytes, ~6 us).
local MAX_CACHED_COLOURS = 16

--- A `tmux show-options` that does not answer in this long is killed.
local TMUX_TIMEOUT_MILLISECONDS = 2000

---@class MdRenderMathKittyImage
---@field id integer Kitty image id
---@field counter integer low 24 bits of the id; reused once the image is released
---@field key string its key in `image_of_key`
---@field path string absolute path of the mask
---@field foreground string "RRGGBB", upper case
---@field columns integer
---@field rows integer
---@field highlight_group string
---@field row_texts string[] one string of `columns` placeholder cells per row
---@field is_sent boolean whether the terminal is believed to hold it now
---@field has_been_sent boolean whether the terminal may hold it: delete it on release
---@field last_used integer the collection generation `cells` last returned it in
---@field was_shown boolean whether a collection ever saw a view show it
---@field handed_out_at integer `vim.uv.now()` of its last hand-out while never shown

--- (mask path, box, foreground) -> its image: those some view shows, those
--- handed out recently and up to `keep_unshown` others.
---@type table<string, MdRenderMathKittyImage>
local image_of_key = {}

--- Counters of released images, to be used again, a queue: the first freed
--- is `free_counters[free_first]`, the last `free_counters[free_last]`.
---@type table<integer, integer>
local free_counters = {}
local free_first, free_last = 1, 0
local highest_counter = 0

--- Counters whose highlight group is defined (since the last `:colorscheme`).
---@type table<integer, true>
local is_group_defined = {}

--- Who shows which pictures: owner (a buffer) -> set of highlight groups.
---@type table<integer, table<string, true>>
local groups_of_owner = {}

--- Bumped by every collection that ran (not one put off by a text lock).
--- An unshown image is a candidate for release once `cells` did not hand it
--- out since the collection before (Zed keeps what the previous frame used:
--- gpui LineLayoutCache, `finish_frame`).
local generation = 0
local is_collection_queued = false
---@type uv.uv_timer_t?
local collection_timer

---@type boolean?
local is_terminal_supported
---@type string? why not, while `is_terminal_supported` is false
local unsupported_reason
---@type vim.SystemObj? the `tmux show-options` still running
local tmux_check

--- Every graphics command is `graphics_start .. control[;payload] ..
--- graphics_end`; inside tmux, its passthrough around it (ESC doubled).
local graphics_start, graphics_end = "\27_G", "\27\\"

-- -----------------------------------------------------------------------------
-- Terminal
-- -----------------------------------------------------------------------------

---@param result vim.SystemCompleted
local function settle_tmux_passthrough(result)
  local value = result.code == 0 and (result.stdout or ""):match("^%s*([%w%-]+)%s*$")
  if value == "on" or value == "all" then
    is_terminal_supported = true
    unsupported_reason = nil
    vim.api.nvim_exec_autocmds("User", { pattern = "MdRenderMathTerminal", modeline = false })
  elseif value then
    unsupported_reason = "tmux: allow-passthrough is "
      .. value:sub(1, 16)
      .. " (pictures need `set -g allow-passthrough on`)"
  else
    -- At most the first line, printable, short: what a broken tmux prints
    -- must not become a 300 kB reason.
    local error_text =
      vim.trim(result.stderr or ""):match("[^\n]*"):gsub("[%c\128-\255]", "?"):sub(1, 120)
    unsupported_reason = "tmux: cannot read allow-passthrough: "
      .. (error_text ~= "" and error_text or ("exit " .. tostring(result.code)))
  end
end

--- The pane's `allow-passthrough`, its own or inherited (`-A`), read once
--- and asynchronously: a process start blocks the main thread 2.3-4.7 ms in
--- the full config (measured for pdftex/mutool spawns). Read only
--- (`show-options`): the user's tmux options are theirs. Killed after
--- TMUX_TIMEOUT_MILLISECONDS, or at VimLeavePre.
local function check_tmux_passthrough()
  local command = { "tmux", "show-options", "-Apv" }
  if vim.env.TMUX_PANE then
    vim.list_extend(command, { "-t", vim.env.TMUX_PANE })
  end
  command[#command + 1] = "allow-passthrough"
  local is_started, process = pcall(
    vim.system,
    command,
    { text = true, timeout = TMUX_TIMEOUT_MILLISECONDS },
    function(result)
      vim.schedule(function()
        tmux_check = nil
        settle_tmux_passthrough(result)
      end)
    end
  )
  if is_started then
    tmux_check = process
  else
    unsupported_reason = "tmux: cannot run `tmux show-options`"
  end
end

--- Read the environment, once: Kitty or Ghostty directly, or through tmux.
local function detect_terminal()
  local environment = vim.env
  local term = environment.TERM or ""
  local term_program = environment.TERM_PROGRAM or ""
  is_terminal_supported = false
  if environment.ZELLIJ then
    unsupported_reason = "zellij passes no Kitty graphics through"
    return
  end
  -- In a `:terminal` of another Neovim the terminal is libvterm, which has
  -- no graphics; the Kitty variables are inherited all the same.
  if environment.NVIM then
    unsupported_reason = "inside a :terminal of another Neovim"
    return
  end
  -- Under tmux TERM is tmux's; Kitty's and Ghostty's own variables are
  -- inherited from the terminal tmux was started in.
  local is_kitty_or_ghostty_outside = environment.KITTY_WINDOW_ID ~= nil
    or environment.KITTY_PID ~= nil
    or environment.GHOSTTY_RESOURCES_DIR ~= nil
  if environment.TMUX then
    if not is_kitty_or_ghostty_outside then
      unsupported_reason = "tmux, not started in Kitty or Ghostty"
      return
    end
    graphics_start, graphics_end = "\27Ptmux;\27\27_G", "\27\27\\\27\\"
    unsupported_reason = "tmux: allow-passthrough not read yet"
    check_tmux_passthrough()
    return
  end
  -- A multiplexer this Neovim cannot ask (screen, or tmux on the other side
  -- of ssh): it would eat the graphics.
  if term:find("^tmux") or term:find("^screen") then
    unsupported_reason = "a terminal multiplexer (TERM=" .. term .. ")"
    return
  end
  is_terminal_supported = is_kitty_or_ghostty_outside
    or term == "xterm-kitty"
    or term_program == "kitty"
    or term == "xterm-ghostty"
    or term_program == "ghostty"
  if not is_terminal_supported then
    unsupported_reason = "not Kitty or Ghostty (TERM=" .. term .. ")"
  end
end

--- Whether the terminal draws Unicode-placeholder images, and if not why.
--- The environment is read once; 'termguicolors' every time, since the
--- image id is a 24-bit colour.
---@return boolean
---@return string? reason
function M.is_supported()
  if is_terminal_supported == nil then
    detect_terminal()
  end
  if not is_terminal_supported then
    return false, unsupported_reason
  end
  if not vim.o.termguicolors then
    return false, "'notermguicolors': the image id is a 24-bit colour"
  end
  return true
end

--- The terminal's cell size in pixels, as md-render reads it (TIOCGWINSZ),
--- rounded. When the terminal reports no pixel size md-render guesses 8x16,
--- which cannot be told apart from a real 8x16.
---@return integer? cell_width
---@return integer? cell_height
function M.cell_size()
  local is_loaded, image = pcall(require, "md-render.image")
  if not is_loaded then
    return nil
  end
  local is_read, size = pcall(image.get_cell_size)
  if not is_read or type(size) ~= "table" then
    return nil
  end
  local cell_width, cell_height = tonumber(size.cell_w), tonumber(size.cell_h)
  -- NaN fails both comparisons; a zero column count gives infinity.
  if not (cell_width and cell_height and cell_width >= 0.5 and cell_height >= 0.5) then
    return nil
  end
  if cell_width == math.huge or cell_height == math.huge then
    return nil
  end
  return math.floor(cell_width + 0.5), math.floor(cell_height + 0.5)
end

-- -----------------------------------------------------------------------------
-- Masks to tinted PNGs
-- -----------------------------------------------------------------------------

local PNG_SIGNATURE = "\137PNG\r\n\26\n"
--- Signature, IHDR's length (13) and type: how every PNG starts.
local PNG_START = PNG_SIGNATURE .. "\0\0\0\13IHDR"
local IEND_CHUNK = "\0\0\0\0IEND\174\66\96\130"

---@type integer[] CRC-32 (ISO 3309, as PNG uses it) of each byte value
local CRC_OF_BYTE = {}
for byte = 0, 255 do
  local crc = byte
  for _ = 1, 8 do
    if bit.band(crc, 1) == 1 then
      crc = bit.bxor(0xEDB88320, bit.rshift(crc, 1))
    else
      crc = bit.rshift(crc, 1)
    end
  end
  CRC_OF_BYTE[byte] = crc
end

---@param number integer
---@return string four bytes, big-endian
local function big_endian_32(number)
  return string.char(
    bit.band(bit.rshift(number, 24), 0xFF),
    bit.band(bit.rshift(number, 16), 0xFF),
    bit.band(bit.rshift(number, 8), 0xFF),
    bit.band(number, 0xFF)
  )
end

---@param kind string four letters
---@param data string
---@return string
local function png_chunk(kind, data)
  local typed = kind .. data
  local crc = 0xFFFFFFFF
  for index = 1, #typed do
    crc =
      bit.bxor(CRC_OF_BYTE[bit.band(bit.bxor(crc, typed:byte(index)), 0xFF)], bit.rshift(crc, 8))
  end
  return big_endian_32(#data) .. typed .. big_endian_32(bit.bxor(crc, 0xFFFFFFFF))
end

local alpha_of_index = {}
for index = 0, 255 do
  alpha_of_index[index + 1] = string.char(255 - index)
end
--- Palette index v (the mask's value) is ink coverage (255 - v) / 255.
local TRANSPARENCY_CHUNK = png_chunk("tRNS", table.concat(alpha_of_index))

--- Foreground as given -> "RRGGBB" in upper case, so that `abb2bf` and
--- `ABB2BF` are one image; at most MAX_CACHED_COLOURS, then started again.
---@type table<string, string>
local canonical_of_foreground = {}
local canonical_count = 0

---@param foreground string
---@return string
local function canonical_foreground(foreground)
  if type(foreground) ~= "string" or not foreground:find("^%x%x%x%x%x%x$") then
    error("md_render_math_kitty: foreground " .. vim.inspect(foreground) .. ", not RRGGBB", 3)
  end
  if canonical_count >= MAX_CACHED_COLOURS then
    canonical_of_foreground, canonical_count = {}, 0
  end
  local canonical = foreground:upper()
  canonical_of_foreground[foreground] = canonical
  canonical_count = canonical_count + 1
  return canonical
end

--- "RRGGBB" -> its `PLTE` and `tRNS` chunks, ~1 kB per colour, at most
--- MAX_CACHED_COLOURS, then started again.
---@type table<string, string>
local colour_chunks_of_foreground = {}
local colour_chunks_count = 0

---@param foreground string "RRGGBB", canonical
---@return string
local function colour_chunks(foreground)
  local chunks = colour_chunks_of_foreground[foreground]
  if chunks then
    return chunks
  end
  if colour_chunks_count >= MAX_CACHED_COLOURS then
    colour_chunks_of_foreground, colour_chunks_count = {}, 0
  end
  local rgb = tonumber(foreground, 16)
  local colour =
    string.char(bit.rshift(rgb, 16), bit.band(bit.rshift(rgb, 8), 0xFF), bit.band(rgb, 0xFF))
  chunks = png_chunk("PLTE", colour:rep(256)) .. TRANSPARENCY_CHUNK
  colour_chunks_of_foreground[foreground] = chunks
  colour_chunks_count = colour_chunks_count + 1
  return chunks
end

---@param bytes string
---@param position integer
---@return integer
local function big_endian_32_at(bytes, position)
  local first, second, third, fourth = bytes:byte(position, position + 3)
  return ((first * 256 + second) * 256 + third) * 256 + fourth
end

--- The mask at `path` as a PNG in `foreground`, or nil when the file cannot
--- be read or is not a whole 8-bit greyscale PNG. The IDAT's CRC and data
--- are not checked: the tex module writes masks by atomic rename, and the
--- check would cost as much as all the rest (6.6 us per mask).
---@param path string
---@param foreground string
---@return string?
local function tinted_png(path, foreground)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local file_size = file:seek("end")
  if not file_size or file_size > MAX_MASK_BYTES then
    file:close()
    return nil
  end
  file:seek("set")
  local mask = file:read("*a")
  file:close()
  -- IHDR is first: signature 8 + length 4 + type 4 + data 13 + CRC 4; the
  -- data are width, height (4 bytes each), depth, colour type, compression,
  -- filter and interlace method (file bytes 25 to 29).
  if not mask or #mask < 45 or mask:sub(1, 16) ~= PNG_START then
    return nil
  end
  local depth, colour_type, compression, filter, interlace = mask:byte(25, 29)
  if depth ~= 8 or colour_type ~= 0 or compression ~= 0 or filter ~= 0 or interlace > 1 then
    return nil
  end
  if big_endian_32_at(mask, 17) == 0 or big_endian_32_at(mask, 21) == 0 then
    return nil
  end
  -- Walk the chunks to IEND (whatever follows it is the tex module's
  -- record): the IDAT run is all that is kept, and a file cut short is no
  -- picture.
  local size = #mask
  local position = 34
  local idat_start, idat_end
  while true do
    if position + 11 > size then
      return nil
    end
    local next_position = position + 12 + big_endian_32_at(mask, position)
    if next_position - 1 > size then
      return nil
    end
    local kind = mask:sub(position + 4, position + 7)
    if kind == "IDAT" then
      if idat_end and idat_end ~= position - 1 then
        return nil -- IDATs must be consecutive (PNG 11.2.4)
      end
      idat_start = idat_start or position
      idat_end = next_position - 1
    elseif kind == "IEND" then
      break
    end
    position = next_position
  end
  if not idat_start then
    return nil
  end
  -- Width, height, depth 8, colour type 3 (palette), then compression,
  -- filter and interlace as they were.
  local header = mask:sub(17, 24) .. "\8\3" .. mask:sub(27, 29)
  return PNG_SIGNATURE
    .. png_chunk("IHDR", header)
    .. colour_chunks(foreground)
    .. mask:sub(idat_start, idat_end)
    .. IEND_CHUNK
end

-- -----------------------------------------------------------------------------
-- Sending
-- -----------------------------------------------------------------------------

--- The escapes that give the terminal `image`: its PNG, then its virtual
--- placement.
---@param image MdRenderMathKittyImage
---@param png string
---@return string
local function transmission(image, png)
  local payload = vim.base64.encode(png)
  local placement = string.format(
    "%sa=p,U=1,i=%d,p=%d,c=%d,r=%d,C=1,q=2%s",
    graphics_start,
    image.id,
    PLACEMENT_ID,
    image.columns,
    image.rows,
    graphics_end
  )
  local size = #payload
  local is_chunked = size > CHUNK_BYTES
  -- One format, the `m` key an argument: joined from two strings the single
  -- command costs 95 ns more (9 %, DedupDedupKitty `micro2.lua`).
  local first = string.format(
    "%sa=t,f=100,t=d,i=%d,q=2%s;",
    graphics_start,
    image.id,
    is_chunked and ",m=1" or ""
  )
  if not is_chunked then
    return first .. payload .. graphics_end .. placement
  end
  local parts = { first }
  for offset = 1, size, CHUNK_BYTES do
    if offset > 1 then
      parts[#parts + 1] = graphics_start
        .. (offset + CHUNK_BYTES > size and "m=0,q=2;" or "m=1,q=2;")
    end
    parts[#parts + 1] = payload:sub(offset, offset + CHUNK_BYTES - 1)
    parts[#parts + 1] = graphics_end
  end
  parts[#parts + 1] = placement
  return table.concat(parts)
end

---@param image MdRenderMathKittyImage
---@return string
local function deletion(image)
  -- `d=I`: the placement and the image data (kitty/graphics.c id_filter_func).
  return string.format("%sa=d,d=I,i=%d,q=2%s", graphics_start, image.id, graphics_end)
end

--- One write to the terminal for all of `sequences`, none for none.
---@param sequences string[]
local function send(sequences)
  if #sequences > 0 then
    vim.api.nvim_ui_send(table.concat(sequences))
  end
end

-- -----------------------------------------------------------------------------
-- Release
-- -----------------------------------------------------------------------------

--- A view closed with `:bdelete` is valid but unloaded and shows nothing.
---@return table<string, true> groups some loaded owner shows
local function shown_groups()
  local is_shown = {}
  for owner, groups in pairs(groups_of_owner) do
    if vim.api.nvim_buf_is_loaded(owner) then
      for group in pairs(groups) do
        is_shown[group] = true
      end
    else
      groups_of_owner[owner] = nil
    end
  end
  return is_shown
end

---@param first MdRenderMathKittyImage
---@param second MdRenderMathKittyImage
---@return boolean
local function is_used_earlier(first, second)
  if first.last_used ~= second.last_used then
    return first.last_used < second.last_used
  end
  return first.counter < second.counter
end

local queue_collection

--- Release the images no view shows beyond the `keep_unshown` most recently
--- used; the header says which are spared and why.
local function collect()
  is_collection_queued = false
  local now = vim.uv.now()
  local is_shown = shown_groups()
  local unshown = {}
  local is_one_spared = false
  for _, image in pairs(image_of_key) do
    if is_shown[image.highlight_group] then
      image.was_shown = true
    elseif
      -- Handed out since the collection before: `generation` is bumped only
      -- once a collection has run.
      image.last_used >= generation
      or (not image.was_shown and now - image.handed_out_at < unmarked_grace_milliseconds)
    then
      is_one_spared = true
    else
      unshown[#unshown + 1] = image
    end
  end
  if #unshown > keep_unshown then
    -- Neovim redraws only once its event queue is empty, and this can run
    -- before that (callbacks queued behind a long one, a `vim.wait`): a
    -- delete ahead of the redraw blanks cells still on the screen, and a
    -- recycled id then draws another picture in them (RevKitty `tui/`: 20
    -- of 20 in six scenarios, 0 with this). The redraw was owed anyway; with
    -- nothing to draw it costs 2.8 us (median, TUI on a pty, 20 pictures
    -- shown; `:redraw!` 156 us). Where it is not allowed (a text lock),
    -- nothing is released now.
    if not pcall(vim.cmd.redraw) then
      -- Not run: `generation` stays, so nothing loses its sparing.
      queue_collection()
      return
    end
    table.sort(unshown, is_used_earlier)
    local deletions = {}
    for index = 1, #unshown - keep_unshown do
      local image = unshown[index]
      if image.has_been_sent then
        deletions[#deletions + 1] = deletion(image)
      end
      image_of_key[image.key] = nil
      free_last = free_last + 1
      free_counters[free_last] = image.counter
    end
    send(deletions)
  end
  generation = generation + 1
  if is_one_spared then
    queue_collection()
  end
end

local collect_on_main_loop = vim.schedule_wrap(collect)

--- A collection `collection_delay_milliseconds` from now, unless one is
--- queued already. Never in the same turn of the event loop: a picture that
--- just left a view is on the terminal's screen until Neovim has redrawn.
queue_collection = function()
  if is_collection_queued then
    return
  end
  is_collection_queued = true
  collection_timer = collection_timer or assert(vim.uv.new_timer())
  collection_timer:start(collection_delay_milliseconds, 0, collect_on_main_loop)
end

--- Tell which pictures `owner` (a buffer) shows now: the highlight groups
--- `cells` returned for what was just put into it. Replaces what it showed
--- before; some time later the pictures no owner shows are released.
---@param owner integer buffer
---@param groups table<string, true>
function M.mark(owner, groups)
  if next(groups) == nil then
    if groups_of_owner[owner] == nil then
      return
    end
    groups_of_owner[owner] = nil
  else
    groups_of_owner[owner] = groups
  end
  queue_collection()
end

--- The terminal may have lost every image: send the shown ones and those
--- handed out but not yet shown again now, the others when `cells` next
--- hands them out.
local function send_shown_again()
  local is_shown = shown_groups()
  local sequences = {}
  for _, image in pairs(image_of_key) do
    image.is_sent = false
    if
      is_shown[image.highlight_group]
      or image.last_used >= generation - 1
      or not image.was_shown
    then
      -- A mask gone since: blank until the next build, whose `cells` says
      -- "missing" and has it made again.
      local png = tinted_png(image.path, image.foreground)
      if png then
        sequences[#sequences + 1] = transmission(image, png)
        image.is_sent = true
      end
    end
  end
  send(sequences)
end

--- Leave nothing behind in the terminal, and no tmux behind Neovim.
local function delete_all()
  if tmux_check then
    pcall(tmux_check.kill, tmux_check, "sigkill")
    tmux_check = nil
  end
  local deletions = {}
  for _, image in pairs(image_of_key) do
    if image.has_been_sent then
      deletions[#deletions + 1] = deletion(image)
      image.is_sent = false
      image.has_been_sent = false
    end
  end
  send(deletions)
end

-- -----------------------------------------------------------------------------
-- Images and their cells
-- -----------------------------------------------------------------------------

---@param image MdRenderMathKittyImage
local function define_highlight(image)
  vim.api.nvim_set_hl(0, image.highlight_group, {
    fg = image.counter,
    sp = PLACEMENT_ID,
    nocombine = true,
  })
  is_group_defined[image.counter] = true
end

---@param columns integer
---@param rows integer
---@return string[]
local function placeholder_rows(columns, rows)
  local row_texts = {}
  for row = 1, rows do
    local row_diacritic = DIACRITIC_OF_NUMBER[row]
    local cells = {}
    for column = 1, columns do
      cells[column] = PLACEHOLDER
        .. row_diacritic
        .. DIACRITIC_OF_NUMBER[column]
        .. ID_BYTE_DIACRITIC
    end
    row_texts[row] = table.concat(cells)
  end
  return row_texts
end

--- A new image under the counter freed longest ago (a just deleted id is the
--- last one to hand out again, should a stale cell of it be left anywhere),
--- else under a new one.
---@param key string
---@param path string absolute
---@param foreground string
---@param columns integer
---@param rows integer
---@return MdRenderMathKittyImage
local function new_image(key, path, foreground, columns, rows)
  local counter
  if free_first <= free_last then
    counter = free_counters[free_first]
    free_counters[free_first] = nil
    free_first = free_first + 1
    if free_first > free_last then
      free_first, free_last = 1, 0
    end
  else
    highest_counter = highest_counter + 1
    counter = highest_counter
  end
  local image_id = IMAGE_ID_HIGH_BYTE * TWO_TO_THE_24 + counter
  local image = {
    id = image_id,
    counter = counter,
    key = key,
    path = path,
    foreground = foreground,
    columns = columns,
    rows = rows,
    highlight_group = HIGHLIGHT_GROUP_PREFIX .. image_id,
    row_texts = placeholder_rows(columns, rows),
    is_sent = false,
    has_been_sent = false,
    last_used = generation,
    was_shown = false,
    handed_out_at = vim.uv.now(),
  }
  if not is_group_defined[counter] then
    -- A recycled id keeps its group: nothing to define, nothing to redraw.
    define_highlight(image)
  end
  image_of_key[key] = image
  return image
end

---@param value any
---@return boolean
local function is_cell_count(value)
  return type(value) == "number" and value >= 1 and value <= M.MAX_CELLS and value % 1 == 0
end

--- The cells that show `picture` in `foreground`, scaled into `box` (default:
--- its own size; Kitty fits the picture into the box keeping its aspect
--- ratio, centred). The first time an image is wanted it is sent to the
--- terminal.
---@param picture MdRenderMathPicture
---@param box? { columns: integer, rows: integer }
---@param foreground string "RRGGBB" in either case (anything else is a
---   caller's bug: raises)
---@return string[]? rows each exactly `columns` cells of display width 1;
---   shared, the caller must not change them
---@return string highlight_group to cover exactly those cells, or why there
---   are none: "box" (Kitty cannot address it), "missing" (the mask file
---   cannot be read or is not a mask)
function M.cells(picture, box, foreground)
  local columns = box and box.columns or picture.columns
  local rows = box and box.rows or picture.rows
  if not (is_cell_count(columns) and is_cell_count(rows)) then
    return nil, "box"
  end
  local colour = canonical_of_foreground[foreground] or canonical_foreground(foreground)
  -- The key names the file, not the text: `m.png` after a `:cd` is another
  -- picture. The tex module gives absolute paths, which cost nothing here.
  local path = picture.path
  if path:byte(1) ~= 47 then -- "/"
    path = vim.fs.abspath(path)
  end
  local key = path .. "\n" .. columns .. "x" .. rows .. "\n" .. colour
  local image = image_of_key[key]
  if not (image and image.is_sent) then
    local png = tinted_png(path, colour)
    if not png then
      -- A known image keeps its id until no view shows it; the caller has the
      -- mask made again. A new one gets no id and no group.
      return nil, "missing"
    end
    image = image or new_image(key, path, colour, columns, rows)
    vim.api.nvim_ui_send(transmission(image, png))
    image.is_sent, image.has_been_sent = true, true
  end
  image.last_used = generation
  if not image.was_shown then
    image.handed_out_at = vim.uv.now()
  end
  return image.row_texts, image.highlight_group
end

--- The autocmds that keep the pictures across what makes them go (the header
--- lists it) and release them. The options are for tests; what is not given
--- stays as it was.
---@param options? { collection_delay_milliseconds?: integer, unmarked_grace_milliseconds?: integer, keep_unshown?: integer }
function M.setup(options)
  options = options or {}
  collection_delay_milliseconds = options.collection_delay_milliseconds
    or collection_delay_milliseconds
  unmarked_grace_milliseconds = options.unmarked_grace_milliseconds or unmarked_grace_milliseconds
  keep_unshown = options.keep_unshown or keep_unshown
  if is_terminal_supported == nil then
    detect_terminal()
  end
  local augroup = vim.api.nvim_create_augroup(AUGROUP_NAME, { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    desc = "md-render math: define the picture highlights again",
    callback = function()
      -- Every group was cleared; the known images' are needed now, a
      -- recycled one when its counter is used again.
      is_group_defined = {}
      for _, image in pairs(image_of_key) do
        define_highlight(image)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResume", "UIEnter" }, {
    group = augroup,
    desc = "md-render math: send the shown pictures to the terminal again",
    callback = send_shown_again,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    desc = "md-render math: a wiped view shows no pictures",
    callback = function()
      -- Not `args.buf`: md-render wipes a view with events off, from its own
      -- handler for the note's wipe. Whatever is invalid by the time the
      -- collection runs is dropped there.
      if next(groups_of_owner) ~= nil then
        queue_collection()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    desc = "md-render math: leave no pictures behind in the terminal",
    callback = delete_all,
  })
end

return M
