-- =============================================================================
-- Color Scheme Plugin
-- =============================================================================
-- Configures the OneDarkPro color scheme with custom highlights.
-- This plugin is loaded with high priority (1000) to ensure colors load early.

return {
  -- Plugin: OneDarkPro - A dark color scheme for Neovim
  -- Repository: https://github.com/olimorris/onedarkpro.nvim
  "olimorris/onedarkpro.nvim",

  -- Priority: Load this plugin first among those with priority
  -- This ensures the color scheme is applied before other plugins that might override it
  priority = 1000,

  -- Configuration function called when plugin loads
  config = function()
    -- Setup OneDarkPro with custom options
    require("onedarkpro").setup({
      -- =============================================================================
      -- Plugin Options
      -- =============================================================================
      options = {
        transparency = false,           -- Use opaque background (not transparent)
        terminal_colors = true,         -- Apply theme colors to terminal buffers
        cursorline = true,              -- Highlight the cursor line
        highlight_inactive_windows = false,  -- Don't highlight inactive windows
      },

      -- =============================================================================
      -- Custom Highlight Groups
      -- =============================================================================
      -- Override specific highlight groups to match our preferences

      highlights = {
        -- Normal buffer background: dark gray-blue
        Normal = { bg = "#1E222A" },

        -- Floating window background: slightly darker
        NormalFloat = { bg = "#17191d" },

        -- Floating window border: gray foreground with dark background
        FloatBorder = { fg = "#E06C75", bg = "#1E222A" },
      },

      -- =============================================================================
      -- Style Options
      -- =============================================================================
      -- Apply text styles to specific syntax elements

      styles = {
        comments = "italic",    -- Render comments in italic font
        keywords = "bold",      -- Render keywords in bold font
      },
    })

    -- Apply the onedark color scheme
    vim.cmd("colorscheme onedark")
  end,
}
