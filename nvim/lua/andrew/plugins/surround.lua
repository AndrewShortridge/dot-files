-- =============================================================================
-- Surround Plugin (nvim-surround)
-- =============================================================================
-- Provides mappings to easily add, change, and delete surrounding pairs.
-- Works with: parentheses, brackets, braces, quotes, tags, and more.

return {
  -- Plugin: nvim-surround - Surround plugin for Neovim
  -- Repository: https://github.com/kylechui/nvim-surround
  "kylechui/nvim-surround",

  -- Load when reading files
  event = { "BufReadPre", "BufNewFile" },

  -- Use latest stable version
  version = "*",

  -- Built-in configuration (default settings are sufficient)
  config = true,
}
