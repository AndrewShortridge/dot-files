-- =============================================================================
-- md-render: heading colours by level
-- =============================================================================
-- Levels 1 to 3 have a colour each; levels 4 to 6 share one.
--
-- md-render colours a heading with `MdRenderH1` .. `MdRenderH6`, which it
-- copies from the colourscheme's `@markup.heading.<level>.markdown`: six
-- colours under both schemes of this config. Here the same copy is made, with
-- levels 5 and 6 reading level 4's group, so the palette is still the
-- colourscheme's and follows the <leader>ub light/dark toggle.
--
-- Under onedark, the dark scheme, levels 2 and 3 take another colour of its
-- palette instead of the heading colours it gives them (orange and yellow).
-- Which two is DEFAULT_ONEDARK_COLOR_OF_LEVEL below, and for the running
-- session, to try combinations with a preview open:
--
--   :MdRenderHeadingColors blue purple    (level 2, level 3; <Tab> completes)
--   :MdRenderHeadingColors                (says which are in use)
--
-- The light scheme is not touched by that.
--
-- These groups are set WITHOUT `default`, so they stand whichever of the two
-- sets them first: md-render sets its own before every render with
-- `default = true`, which yields to a group already defined and is replaced
-- by one defined after it.
--
-- They are also set again on ColorScheme. md-render does not do that: a
-- colourscheme change clears its groups, and until the next render every
-- heading was drawn without a colour.
--
-- Only md-render's rendered views change. The markdown source and
-- render-markdown.nvim still take six colours from the colourscheme.
--
-- Pinned by tests/md_render_heading_colors_spec.lua.

local M = {}

--- Heading level -> the level whose colour it is drawn in.
local COLOR_LEVEL_OF_HEADING_LEVEL = { 1, 2, 3, 4, 4, 4 }

--- The colourscheme the palette names below belong to.
local ONEDARK_COLORSCHEME = "onedark"

--- The colours of onedarkpro's palette a heading can be given.
local ONEDARK_COLOR_NAMES =
  { "red", "orange", "yellow", "green", "cyan", "blue", "purple", "white" }

--- Under onedark: heading level -> the palette colour it takes. A level not
--- listed keeps the colourscheme's heading colour (1 red, 4 green).
local DEFAULT_ONEDARK_COLOR_OF_LEVEL = { [2] = "blue", [3] = "purple" }

---@type table<integer, string>
local onedark_color_of_level = vim.deepcopy(DEFAULT_ONEDARK_COLOR_OF_LEVEL)

--- onedarkpro's palette, when onedark is the colourscheme in use.
---@return table<string, string>? palette colour name -> "#rrggbb"
local function onedark_palette()
  if vim.g.colors_name ~= ONEDARK_COLORSCHEME then
    return nil
  end
  local is_available, helpers = pcall(require, "onedarkpro.helpers")
  return is_available and helpers.get_colors(ONEDARK_COLORSCHEME) or nil
end

local function define_heading_groups()
  local palette = onedark_palette()
  for heading_level, color_level in ipairs(COLOR_LEVEL_OF_HEADING_LEVEL) do
    local group_name = "MdRenderH" .. heading_level
    local attributes = vim.api.nvim_get_hl(0, {
      name = "@markup.heading." .. color_level .. ".markdown",
      link = false,
    })
    local palette_color = palette and palette[onedark_color_of_level[color_level]]
    if palette_color then
      attributes.fg = palette_color
    end
    -- As md-render does it: every attribute carried over, bold forced, and
    -- Title for a colourscheme without per-level heading groups.
    if attributes.fg or attributes.bg then
      attributes.bold = true
      vim.api.nvim_set_hl(0, group_name, attributes)
    else
      vim.api.nvim_set_hl(0, group_name, { link = "Title" })
    end
  end
end

---@return string
local function describe_choice()
  local description = ("heading colours under %s: level 2 %s, level 3 %s"):format(
    ONEDARK_COLORSCHEME,
    onedark_color_of_level[2],
    onedark_color_of_level[3]
  )
  if vim.g.colors_name ~= ONEDARK_COLORSCHEME then
    description = description
      .. (" (not in use: the colourscheme is %s)"):format(tostring(vim.g.colors_name))
  end
  return description
end

--- Choose the colours of heading levels 2 and 3 under onedark, for this session.
---@param level_2_color string a name from ONEDARK_COLOR_NAMES
---@param level_3_color string
function M.use(level_2_color, level_3_color)
  for _, color_name in ipairs({ level_2_color, level_3_color }) do
    if not vim.tbl_contains(ONEDARK_COLOR_NAMES, color_name) then
      vim.notify(
        ("heading colours: unknown colour %q (expected one of: %s)"):format(
          color_name,
          table.concat(ONEDARK_COLOR_NAMES, ", ")
        ),
        vim.log.levels.ERROR
      )
      return
    end
  end
  onedark_color_of_level[2], onedark_color_of_level[3] = level_2_color, level_3_color
  define_heading_groups()
  -- The scaled headings on screen are drawn from copies of these groups.
  require("andrew.utils.md_render_heading_background").refresh()
end

function M.setup()
  define_heading_groups()
  -- Not scheduled: the colourscheme has set its groups by the time this fires,
  -- and md_render_heading_background.lua, which copies from these, is.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("md-render-heading-colors", { clear = true }),
    callback = define_heading_groups,
  })

  vim.api.nvim_create_user_command("MdRenderHeadingColors", function(command)
    if #command.fargs == 0 then
      vim.notify(describe_choice())
    elseif #command.fargs == 2 then
      M.use(command.fargs[1], command.fargs[2])
    else
      vim.notify("heading colours: give two colours, for level 2 and level 3", vim.log.levels.ERROR)
    end
  end, {
    nargs = "*",
    complete = function(argument_lead)
      return vim.tbl_filter(function(color_name)
        return vim.startswith(color_name, argument_lead)
      end, ONEDARK_COLOR_NAMES)
    end,
    desc = "Markdown: colours of heading levels 2 and 3 in md-render's views (onedark)",
  })
end

return M
