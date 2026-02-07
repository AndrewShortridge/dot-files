-- =============================================================================
-- Color Highlighter (nvim-colorizer.lua)
-- =============================================================================
-- Highlights color codes (hex, rgb, hsl, etc.) with their actual color.
-- Shows inline color preview for CSS, HTML, and other color-related code.

return {
  -- Plugin: nvim-colorizer.lua - Color highlighter for Neovim
  -- Repository: https://github.com/norcalli/nvim-colorizer.lua
  "norcalli/nvim-colorizer.lua",

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Setup colorizer for all file types
    require("colorizer").setup({ "*" })
  end,
}
