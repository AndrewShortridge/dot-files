-- =============================================================================
-- Lualine OneDark Theme (shared)
-- =============================================================================
-- The statusline palette and theme table used when the OneDark colorscheme is
-- active.
--
-- This lives outside lua/andrew/plugins/lualine.lua so the light/dark toggle in
-- andrew.themes.toggle can RESTORE it. The previous theme cycler could not: it
-- fell back to `theme = "auto"` when returning to OneDark, which silently threw
-- away this hand-tuned palette and let lualine re-derive a generic one. Keeping
-- the table here means both the plugin spec and the toggle apply the same thing.

local M = {}

-- OneDark colour palette, matching the OneDarkPro colorscheme.
M.colors = {
  bg = "#282c34", -- Dark gray background
  fg = "#abb2bf", -- Light gray foreground
  red = "#e06c75", -- Red for errors
  green = "#98c379", -- Green for success/added
  yellow = "#e5c07b", -- Yellow for warnings/modified
  blue = "#61afef", -- Blue for info/links
  purple = "#c678dd", -- Purple for special
  cyan = "#56b6c2", -- Cyan for hints
  darkgray = "#2c313c", -- Darker gray for sections
  gray = "#3e4451", -- Medium gray
  lightgray = "#5c6370", -- Light gray for inactive
  inactive_bg = "#1f2329", -- Very dark for inactive windows
}

local c = M.colors

-- Status line colours for each Vim mode.
M.theme = {
  -- Normal mode (default)
  normal = {
    a = { bg = c.blue, fg = c.bg, gui = "bold" },
    b = { bg = c.darkgray, fg = c.fg },
    c = { bg = c.bg, fg = c.fg },
  },

  -- Insert mode (when typing)
  insert = {
    a = { bg = c.green, fg = c.bg, gui = "bold" },
    b = { bg = c.darkgray, fg = c.fg },
    c = { bg = c.bg, fg = c.fg },
  },

  -- Visual mode (when selecting)
  visual = {
    a = { bg = c.purple, fg = c.bg, gui = "bold" },
    b = { bg = c.darkgray, fg = c.fg },
    c = { bg = c.bg, fg = c.fg },
  },

  -- Command mode (when entering commands)
  command = {
    a = { bg = c.yellow, fg = c.bg, gui = "bold" },
    b = { bg = c.darkgray, fg = c.fg },
    c = { bg = c.bg, fg = c.fg },
  },

  -- Replace mode (overwrite typing)
  replace = {
    a = { bg = c.red, fg = c.bg, gui = "bold" },
    b = { bg = c.darkgray, fg = c.fg },
    c = { bg = c.bg, fg = c.fg },
  },

  -- Inactive windows (no focus)
  inactive = {
    a = { bg = c.inactive_bg, fg = c.lightgray, gui = "bold" },
    b = { bg = c.inactive_bg, fg = c.lightgray },
    c = { bg = c.inactive_bg, fg = c.lightgray },
  },
}

return M
