-- Spec for andrew.utils.md_render_heading_background, run against the real
-- md-render.nvim: a scaled heading is drawn on the background of the window it
-- is in.
--
-- WHAT THIS IS GUARDING
--
-- md-render writes a scaled heading to the terminal with a background colour
-- of its own choosing, and for a heading group without one it chooses
-- NormalFloat's in every window. In a normal window that is a box of the
-- wrong colour around each heading. What is asserted is the colour in the
-- bytes sent to the terminal:
--
-- 1. Focused view: Normal's background.
-- 2. View in a window that lost the focus: NormalNC's, and Normal's again
--    when the focus comes back. This is the split with the cursor in the
--    source.
-- 3. The `:MdRender` float: still NormalFloat's, which is right there.
-- 4. After a colourscheme change: the new Normal.
-- 5. A heading group that has a background keeps it.
--
-- The adapter renames the highlight group in md-render's placements, so an
-- md-render update that stops reading the group from there turns this red.
--
-- There is no terminal in a `-l` run, so `nvim_ui_send` is replaced by a
-- recorder and md-render is told the terminal can scale text.
--
-- Run with: nvim --headless -u NONE -l tests/md_render_heading_background_spec.lua

local _H =
  dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/md-render.nvim")
vim.cmd("filetype on")
vim.cmd("runtime plugin/md-render.lua")

-- Everything md-render sends to the terminal goes through this one function.
local sent_to_terminal = {}
---@diagnostic disable-next-line: duplicate-set-field
vim.api.nvim_ui_send = function(data)
  sent_to_terminal[#sent_to_terminal + 1] = data
end

-- md-render probes the terminal once and caches the answer, which with no UI
-- attached is "no". There is no switch for it.
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

-- onedark's three, which is what made the box visible.
local NORMAL_BACKGROUND = "#1e222a"
local UNFOCUSED_BACKGROUND = "#282c34"
local FLOAT_BACKGROUND = "#17191d"
vim.api.nvim_set_hl(0, "Normal", { fg = "#abb2bf", bg = NORMAL_BACKGROUND })
vim.api.nvim_set_hl(0, "NormalNC", { bg = UNFOCUSED_BACKGROUND })
vim.api.nvim_set_hl(0, "NormalFloat", { bg = FLOAT_BACKGROUND })

require("andrew.utils.md_render_heading_background").setup()

--- Let timers and scheduled callbacks run.
---@param milliseconds integer
local function let_run(milliseconds)
  vim.wait(milliseconds, function()
    return false
  end, 20)
end

--- The background colours of the scaled runs md-render sends from now on: it
--- writes them again at least every 500 ms.
---@return string colours distinct ones, sorted, e.g. "#1e222a"
local function heading_backgrounds()
  -- Whatever was queued before the change under test.
  let_run(150)
  sent_to_terminal = {}
  let_run(800)

  local colours = {}
  -- The background is the last attribute set before a scaled run.
  for red, green, blue in
    table.concat(sent_to_terminal):gmatch("\27%[48;2;(%d+);(%d+);(%d+)m\27%]66;")
  do
    colours[("#%02x%02x%02x"):format(red, green, blue)] = true
  end
  local distinct = vim.tbl_keys(colours)
  table.sort(distinct)
  return #distinct > 0 and table.concat(distinct, " ") or "no scaled run was sent"
end

local note = vim.fn.tempname() .. ".md"
vim.fn.writefile({
  "# Title",
  "",
  -- Long, so that the float, which is sized to its content, has room for the
  -- heading at twice its width. Without room md-render does not scale it.
  "Some text that is long enough to make the float wider than the heading.",
}, note)
vim.cmd.edit(vim.fn.fnameescape(note))
local preview = require("md-render").preview
preview.toggle()

test("a heading in the focused view is drawn on Normal's background", function()
  assert_true(vim.b.md_render, "the window shows the rendered view:")
  assert_eq(heading_backgrounds(), NORMAL_BACKGROUND, "background of the scaled heading:")
end)

test("it follows the focus: NormalNC's when another window has it", function()
  vim.cmd.vnew()
  assert_eq(heading_backgrounds(), UNFOCUSED_BACKGROUND, "with the focus in another window:")
  vim.cmd.close()
  assert_eq(heading_backgrounds(), NORMAL_BACKGROUND, "with the focus back in the view:")
end)

test("the float keeps NormalFloat's background", function()
  -- Back to the source: the float is opened from there.
  preview.toggle()
  assert_eq(vim.b.md_render, nil, "the window shows the source:")
  vim.cmd("MdRender")
  assert_eq(heading_backgrounds(), FLOAT_BACKGROUND, "background of the heading in the float:")
  vim.cmd("MdRender")
  preview.toggle()
  assert_true(vim.b.md_render, "the window shows the rendered view again:")
end)

test("it follows a colourscheme change", function()
  vim.api.nvim_set_hl(0, "Normal", { fg = "#abb2bf", bg = "#102030" })
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert_eq(heading_backgrounds(), "#102030", "background after Normal changed:")
end)

test("a heading group with a background of its own keeps it", function()
  vim.api.nvim_set_hl(0, "MdRenderH1", { fg = "#e06c75", bg = "#3a323b", bold = true })
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert_eq(heading_backgrounds(), "#3a323b", "background of the scaled heading:")
end)

vim.fn.delete(note)
_H.finish()
