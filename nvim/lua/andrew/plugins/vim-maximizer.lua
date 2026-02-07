-- =============================================================================
-- Window Maximizer (vim-maximizer)
-- =============================================================================
-- Maximizes and restores the current split window to fill the editor.
-- Useful for focusing on a single file or section of code.

return {
  -- Plugin: vim-maximizer - Maximize/restore Neovim splits
  -- Repository: https://github.com/szw/vim-maximizer
  "szw/vim-maximizer",

  -- =============================================================================
  -- Keybindings
  -- =============================================================================
  keys = {
    -- Toggle maximization of current split
    { "<leader>sm", "<cmd>MaximizerToggle<CR>", desc = "Maximize/minimize current split" },
  },
}
