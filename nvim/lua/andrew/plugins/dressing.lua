-- =============================================================================
-- UI Improvements (dressing.nvim)
-- =============================================================================
-- Improves Neovim's built-in UI components:
-- - vim.ui.input: Better input prompts with completion
-- - vim.ui.select: Better file/item picker UI

return {
  -- Plugin: dressing.nvim - Improved UI for Neovim
  -- Repository: https://github.com/stevearc/dressing.nvim
  "stevearc/dressing.nvim",

  -- Load lazily (no specific trigger needed)
  event = "VeryLazy",
}
