-- =============================================================================
-- md-render: a heading's level is its size, not an icon
-- =============================================================================
-- md-render starts every rendered heading with a level icon (the
-- nf-md-format_header_1..6 glyphs, which are also render-markdown.nvim's) and,
-- in a terminal that can scale text, draws the heading's text larger as well:
-- 2x for `#` down to 1.17x for `######` (`:help md-render-text-size`). The
-- icon has no option.
--
-- Here the size replaces the icon: a heading md-render is going to scale is
-- rendered as its text alone. Where it cannot scale -- inside tmux, a terminal
-- other than Kitty >= 0.40, after `:MdRender textsize off` -- the icon stays,
-- as the one thing left that tells the levels apart.
--
-- How: `render` of md-render.markdown turns one source line into rendered text
-- plus the byte ranges of its highlights and links, icon included. It is
-- wrapped, and the icon comes off what it returns. Nothing after it has to
-- know: a heading line without an icon is a case md-render already handles,
-- being every line but the first of a heading that wraps.
--
-- Pinned by tests/md_render_headings_spec.lua. Drop this file when md-render
-- grows an option for the icon.

local M = {}

local HEADING_LEVEL_COUNT = 6

--- Take the level icon off a rendered heading. The text is returned; the
--- highlights and links, which are byte ranges into it, are moved in place.
---@param rendered_text string
---@param highlights { col: integer, end_col: integer }[]
---@param links { col_start: integer, col_end: integer }[]
---@return string rendered_text unchanged when the heading will not be scaled
local function without_level_icon(rendered_text, highlights, links)
  local markdown = require("md-render.markdown")
  for level = 1, HEADING_LEVEL_COUNT do
    local icon_prefix = markdown.heading_icon_prefix(level)
    if vim.startswith(rendered_text, icon_prefix) then
      -- md-render's own answer to "is this level drawn larger here": the
      -- terminal can do it and the feature is on.
      if not require("md-render.text_size").spec_for(level) then
        return rendered_text
      end
      local icon_length = #icon_prefix
      -- The heading's own highlight starts at 0 and stays there; everything
      -- inside the text was moved right by the icon and moves back.
      for _, highlight in ipairs(highlights) do
        highlight.col = math.max(0, highlight.col - icon_length)
        highlight.end_col = math.max(0, highlight.end_col - icon_length)
      end
      for _, link in ipairs(links) do
        link.col_start = math.max(0, link.col_start - icon_length)
        link.col_end = math.max(0, link.col_end - icon_length)
      end
      return rendered_text:sub(icon_length + 1)
    end
  end
  return rendered_text
end

--- Wrap md-render's line renderer. Call once md-render has loaded.
function M.setup()
  local markdown = require("md-render.markdown")
  local upstream_render = markdown.render

  -- Returns: rendered text, highlights, links, the kind of line, then more
  -- that depend on the kind. Passed on by count, not by name, so that a value
  -- upstream adds later is not dropped here.
  markdown.render = function(...)
    local results = vim.F.pack_len(upstream_render(...))
    if results[4] == "heading" then
      results[1] = without_level_icon(results[1], results[2], results[3])
    end
    return vim.F.unpack_len(results)
  end
end

return M
