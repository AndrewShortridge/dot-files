-- Spec for andrew.utils.md_render_heading_colors, run against the real
-- md-render.nvim: heading levels 1 to 3 have a colour each, levels 4 to 6
-- share level 4's.
--
-- WHAT THIS IS GUARDING
--
-- The rule is six lines. What can undo it is md-render, which defines the same
-- six groups itself:
--
-- 1. The rule itself, read from the colourscheme's heading groups -- also when
--    md-render defined its six colours first.
-- 2. md-render sets `MdRenderH1..6` before every render. If its definitions
--    won, levels 5 and 6 would be back to their own colours after the first
--    render -- which is every time the rule would be looked at.
-- 3. A colourscheme change clears the groups. md-render does not set them
--    again until the next render, and then from the new scheme's six colours.
-- 4. Under onedark levels 2 and 3 take colours of onedarkpro's palette, chosen
--    with `:MdRenderHeadingColors`. They must not leak: not into the other
--    levels, and not into the light scheme, whose palette they are not from.
--
-- onedark is not loaded here -- `:colorscheme onedark` would compile and cache
-- it with default options. Its name and its palette are all the module reads.
--
-- Run with: nvim --headless -u NONE -l tests/md_render_heading_colors_spec.lua

local _H =
  dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq = _H.test, _H.assert_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/md-render.nvim")
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/onedarkpro.nvim")

---@param colors string[] one per heading level
local function set_colorscheme_heading_colors(colors)
  for level, color in ipairs(colors) do
    vim.api.nvim_set_hl(0, "@markup.heading." .. level .. ".markdown", { fg = color })
  end
end

---@return string colors of MdRenderH1..6, e.g. "#aa0000 #bb0000 ..."
local function md_render_heading_colors()
  local colors = {}
  for level = 1, 6 do
    local foreground = vim.api.nvim_get_hl(0, { name = "MdRenderH" .. level, link = false }).fg
    colors[level] = foreground and ("#%06x"):format(foreground) or "none"
  end
  return table.concat(colors, " ")
end

set_colorscheme_heading_colors({ "#aa0000", "#bb0000", "#cc0000", "#dd0000", "#ee0000", "#ff0000" })
-- md-render got there first.
require("md-render").setup_highlights()
require("andrew.utils.md_render_heading_colors").setup()

local EXPECTED_COLORS = "#aa0000 #bb0000 #cc0000 #dd0000 #dd0000 #dd0000"

test("levels 1 to 3 take their own colour, levels 4 to 6 take level 4's", function()
  assert_eq(md_render_heading_colors(), EXPECTED_COLORS, "MdRenderH1..6:")
end)

test("md-render setting its own heading groups does not undo it", function()
  require("md-render").setup_highlights()
  assert_eq(md_render_heading_colors(), EXPECTED_COLORS, "MdRenderH1..6 after md-render's setup:")
end)

test("a colourscheme change is followed, without waiting for a render", function()
  -- What `:colorscheme` does: clear everything, set the new groups, fire the event.
  vim.cmd("highlight clear")
  set_colorscheme_heading_colors({
    "#0000aa",
    "#0000bb",
    "#0000cc",
    "#0000dd",
    "#0000ee",
    "#0000ff",
  })
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert_eq(
    md_render_heading_colors(),
    "#0000aa #0000bb #0000cc #0000dd #0000dd #0000dd",
    "MdRenderH1..6 under the new colourscheme:"
  )
end)

local onedark_palette = require("onedarkpro.helpers").get_colors("onedark")

---@param level_2_color string
---@param level_3_color string
---@return string
local function scheme_colors_with(level_2_color, level_3_color)
  return ("#0000aa %s %s #0000dd #0000dd #0000dd"):format(level_2_color, level_3_color):lower()
end

test("under onedark levels 2 and 3 take colours of its palette, the rest stay", function()
  vim.g.colors_name = "onedark"
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert_eq(
    md_render_heading_colors(),
    scheme_colors_with(onedark_palette.blue, onedark_palette.purple),
    "MdRenderH1..6 with the default choice, blue and purple:"
  )
end)

test(":MdRenderHeadingColors changes the two for the session", function()
  vim.cmd("MdRenderHeadingColors cyan green")
  assert_eq(
    md_render_heading_colors(),
    scheme_colors_with(onedark_palette.cyan, onedark_palette.green),
    "MdRenderH1..6 after `cyan green`:"
  )

  -- Refused with an error message, which `vim.cmd` raises in a headless run.
  pcall(vim.cmd, "MdRenderHeadingColors red nosuchcolour")
  assert_eq(
    md_render_heading_colors(),
    scheme_colors_with(onedark_palette.cyan, onedark_palette.green),
    "MdRenderH1..6 after a colour that does not exist:"
  )
end)

test("another colourscheme keeps its own colours for levels 2 and 3", function()
  vim.g.colors_name = "soft-paper-light"
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert_eq(
    md_render_heading_colors(),
    scheme_colors_with("#0000bb", "#0000cc"),
    "MdRenderH1..6 under the light scheme:"
  )
end)

_H.finish()
