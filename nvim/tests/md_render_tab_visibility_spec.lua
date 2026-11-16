-- Spec for andrew.utils.md_render_tab_visibility, run against the real
-- md-render.nvim: a rendered view draws nothing to the terminal while its
-- window is on another tab page.
--
-- WHAT THIS IS GUARDING
--
-- md-render writes images (Kitty graphics) and scaled headings (OSC 66)
-- straight to the terminal, at the screen cells of the view's window, and
-- keeps re-writing them from timers and redraw hooks. None of those ask
-- whether the window is on screen, only whether it exists, so after `:tabnew`
-- the pictures and headings of the tab left behind were painted over the new
-- one.
--
-- The adapter leans on md-render's internals for the headings (it swaps
-- `state.win`), so an md-render update is the likeliest thing to turn this
-- red. What is asserted is the bytes sent to the terminal, not the mechanism:
--
-- 1. With the view on screen, both kinds of drawing happen at all -- otherwise
--    the "nothing was drawn" below would pass for the wrong reason.
-- 2. On another tab, nothing is drawn, however md-render is prodded: its
--    keepalive timer, a redraw, a cursor move, its own "screen was repainted"
--    event.
-- 3. Back on the view's tab, both are drawn again.
--
-- There is no terminal in a `-l` run, so `nvim_ui_send` is replaced by a
-- recorder and md-render is told the terminal can do both protocols.
--
-- Run with: nvim --headless -u NONE -l tests/md_render_tab_visibility_spec.lua

local _H =
  dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/md-render.nvim")
vim.cmd("filetype on")

-- Everything md-render sends to the terminal goes through this one function.
local sent_to_terminal = {}
---@diagnostic disable-next-line: duplicate-set-field
vim.api.nvim_ui_send = function(data)
  sent_to_terminal[#sent_to_terminal + 1] = data
end

local IMAGE_PLACEMENT = "\27_Ga=p"
local SCALED_TEXT = "\27]66;"

---@param escape_sequence string
---@return integer
local function count_sent(escape_sequence)
  local _, count = table.concat(sent_to_terminal):gsub(vim.pesc(escape_sequence), "")
  return count
end

local function forget_what_was_sent()
  sent_to_terminal = {}
end

-- The terminal can show images...
require("md-render.image")._set_kitty_supported(true)
-- ...and scale text. That module has no such switch: it probes the terminal
-- and caches the answer, which with no UI attached is "no".
local text_size = require("md-render.text_size")
for upvalue_index = 1, math.huge do
  local upvalue_name = debug.getupvalue(text_size.supports, upvalue_index)
  if upvalue_name == nil then
    error("md-render.text_size.supports no longer caches its answer in `_supported`")
  end
  if upvalue_name == "_supported" then
    debug.setupvalue(text_size.supports, upvalue_index, true)
    break
  end
end

require("andrew.utils.md_render_tab_visibility").setup()

local scratch_dir = vim.fn.tempname()
vim.fn.mkdir(scratch_dir, "p")

-- A 1x1 PNG.
local png_file = assert(io.open(scratch_dir .. "/still.png", "wb"))
png_file:write(
  vim.base64.decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
  )
)
png_file:close()

local note = scratch_dir .. "/note.md"
vim.fn.writefile(
  { "# A heading", "", "Some text.", "", "![still](still.png)", "", "More text." },
  note
)

--- Let timers and scheduled callbacks run until `condition` holds.
local function settle(condition)
  return vim.wait(3000, condition, 20)
end

--- Let them run when the point is that nothing should come of it.
---@param milliseconds integer
local function let_run(milliseconds)
  vim.wait(milliseconds, function()
    return false
  end, 20)
end

local function is_view_drawn()
  return count_sent(IMAGE_PLACEMENT) > 0 and count_sent(SCALED_TEXT) > 0
end

vim.cmd.edit(vim.fn.fnameescape(note))
require("md-render").preview.toggle()

test("a view on screen has its image placed and its heading scaled", function()
  assert_true(vim.b.md_render, "the window shows the rendered view:")
  assert_true(settle(is_view_drawn), "image placement and scaled heading were sent:")
end)

test("a view on another tab page draws nothing", function()
  vim.cmd.tabnew()
  -- The switch itself: placements removed, screen repainted.
  let_run(100)
  forget_what_was_sent()

  -- md-render's keepalive timer for headings is 500 ms.
  let_run(700)
  vim.cmd.redraw()
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  vim.api.nvim_exec_autocmds("User", { pattern = "MdRenderRepaint", data = { source = "spec" } })
  let_run(300)

  assert_eq(count_sent(IMAGE_PLACEMENT), 0, "image placements sent while on the other tab:")
  assert_eq(count_sent(SCALED_TEXT), 0, "scaled heading runs sent while on the other tab:")
end)

test("back on its tab page the view is drawn again", function()
  forget_what_was_sent()
  vim.cmd.tabprevious()
  assert_true(settle(is_view_drawn), "image placement and scaled heading were sent again:")
end)

vim.fn.delete(scratch_dir, "rf")
_H.finish()
