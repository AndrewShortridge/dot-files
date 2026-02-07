-- =============================================================================
-- Indent Guides (indent-blankline.nvim)
-- =============================================================================
-- Displays visual indentation guides for each indentation level.
-- Helps visualize code structure and nesting depth.

return {
  -- Plugin: indent-blankline.nvim - Indent guides for Neovim
  -- Repository: https://github.com/lukas-reineke/indent-blankline.nvim
  "lukas-reineke/indent-blankline.nvim",

  -- Load when reading files
  event = { "BufReadPre", "BufNewFile" },

  -- Use 'ibl' as the main module name (new API)
  main = "ibl",

  -- =============================================================================
  -- Plugin Options
  -- =============================================================================
  opts = {
    -- Indentation character configuration
    indent = {
      -- Character to use for indent guides (Unicode box drawing character)
      char = "┊",
    },
  },
}
