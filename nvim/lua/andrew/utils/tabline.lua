-- =============================================================================
-- Tabline: one slanted tab per tab page
-- =============================================================================
-- A port of the tabline in craftzdog's dotfiles
-- (lua/craftzdog/utils/tabline.lua): each tab page is a parallelogram holding
-- the icon and name of its focused file, "[+]" in front while that file has
-- unsaved changes, and the current tab page filled with the accent colour.
--
-- What differs from his:
--
-- * Colours. His come from the solarized-osaka palette. Here they are read
--   from the highlight groups of whichever colourscheme is active, and re-read
--   on ColorScheme, so the tabs are onedark's under onedark and follow the
--   light/dark toggle (andrew/themes/toggle.lua). The roles are his: the
--   current tab filled with an accent, the others on a surface one step above
--   the editor background, nothing painted between them. The accent is the
--   scheme's green (the DiagnosticOk colour); his is yellow.
-- * Text on the current tab is the editor background, not the light
--   foreground: onedark's accents are far paler than Solarized's and light
--   text on them cannot be read.
-- * A tab page whose focus is in a floating window keeps the name of the split
--   underneath. Otherwise every picker and the floating terminal rename the
--   tab to "[Terminal]" for as long as they are open.
-- * `%` in a file name is escaped; unescaped it is read as a tabline item.
-- * Icons come from nvim-web-devicons (he uses mini.icons).
--
-- 'showtabline' is not touched here: core/options.lua pins it at 2 and
-- <leader>uA toggles it. (His is 1, which hides the tabline until there is a
-- second tab page.)

local M = {}

local SLANT_BEFORE_TAB = "\u{e0ba}" -- nf-ple-lower_right_triangle
local SLANT_AFTER_TAB = "\u{e0b8}" -- nf-ple-lower_left_triangle
local MAX_NAME_WIDTH = 20
local TRUNCATED_NAME_WIDTH = 17

--- One colour of a group, links followed.
---@param group string
---@param attribute "fg"|"bg"
---@return integer?
local function colour_of(group, attribute)
  return vim.api.nvim_get_hl(0, { name = group, link = false })[attribute]
end

--- (Re)define the tabline's highlight groups from the active colourscheme.
function M.apply_colours()
  local set_hl = vim.api.nvim_set_hl
  local editor_background = colour_of("Normal", "bg")
  local accent = colour_of("DiagnosticOk", "fg")
  local raised_background = colour_of("CursorLine", "bg")

  set_hl(0, "TabLineActive", { fg = editor_background, bg = accent, bold = true })
  set_hl(0, "TabLineInactive", { fg = colour_of("Normal", "fg"), bg = raised_background })
  -- The slants are drawn in the tab's colour on the editor background.
  set_hl(0, "TabLineSepActive", { fg = accent, bg = editor_background })
  set_hl(0, "TabLineSepInactive", { fg = raised_background, bg = editor_background })
  set_hl(0, "TabLineFill", { bg = editor_background })
end

---@param window integer
---@return boolean
local function is_floating_window(window)
  return vim.api.nvim_win_get_config(window).relative ~= ""
end

--- The window a tab page is named after: its focused window, or, while focus
--- is in a float, the split focus came from.
---@param tab_number integer
---@return integer window
local function naming_window(tab_number)
  local focused = vim.fn.tabpagewinnr(tab_number)
  local previous = vim.fn.tabpagewinnr(tab_number, "#")
  for _, window_number in ipairs({ focused, previous }) do
    local window = vim.fn.win_getid(window_number, tab_number)
    if window_number > 0 and not is_floating_window(window) then
      return window
    end
  end
  -- Floats are numbered after the splits, so window 1 is never one.
  return vim.fn.win_getid(1, tab_number)
end

--- Icon and name for a buffer, as shown on its tab.
---@param buffer integer
---@return string
local function buffer_label(buffer)
  if vim.bo[buffer].buftype == "terminal" then
    return "[Terminal]"
  end
  local path = vim.api.nvim_buf_get_name(buffer)
  if path == "" then
    return "[No Name]"
  end

  local filename = vim.fn.fnamemodify(path, ":t")
  local has_devicons, devicons = pcall(require, "nvim-web-devicons")
  local icon = has_devicons and devicons.get_icon(filename, nil, { default = true }) or nil
  if vim.fn.strchars(filename) > MAX_NAME_WIDTH then
    filename = vim.fn.strcharpart(filename, 0, TRUNCATED_NAME_WIDTH) .. "…"
  end
  return icon and (icon .. " " .. filename) or filename
end

---@param tab_number integer
---@param is_active boolean
---@return string
local function render_tab(tab_number, is_active)
  local buffer = vim.api.nvim_win_get_buf(naming_window(tab_number))
  local modified_marker = vim.bo[buffer].modified and "[+] " or ""
  local title = ("   " .. modified_marker .. buffer_label(buffer) .. "   "):gsub("%%", "%%%%")

  local tab_highlight = is_active and "%#TabLineActive#" or "%#TabLineInactive#"
  local slant_highlight = is_active and "%#TabLineSepActive#" or "%#TabLineSepInactive#"

  -- %NT ... %T makes the tab clickable (:help 'tabline').
  return table.concat({
    "%" .. tab_number .. "T",
    slant_highlight,
    SLANT_BEFORE_TAB,
    tab_highlight,
    title,
    slant_highlight,
    SLANT_AFTER_TAB,
    "%T",
  })
end

--- The 'tabline' expression.
---@return string
function M.render()
  local tabs = {}
  local active_tab_number = vim.fn.tabpagenr()
  for tab_number = 1, vim.fn.tabpagenr("$") do
    tabs[#tabs + 1] = render_tab(tab_number, tab_number == active_tab_number)
  end
  return table.concat(tabs) .. "%#TabLineFill#"
end

function M.setup()
  M.apply_colours()
  vim.api.nvim_create_autocmd("ColorScheme", {
    desc = "Re-derive the tabline colours from the new colourscheme",
    group = vim.api.nvim_create_augroup("AndrewTabline", { clear = true }),
    callback = M.apply_colours,
  })
  vim.o.tabline = "%!v:lua.require('andrew.utils.tabline').render()"
end

return M
