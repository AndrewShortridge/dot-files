-- =============================================================================
-- Tab/Buffer Line (bufferline.nvim)
-- =============================================================================
-- Displays tabs and buffers in a horizontal line at the top of the editor.
-- Provides visual management of open files and tabs.

return {
  -- Plugin: bufferline.nvim - A buffer line for Neovim
  -- Repository: https://github.com/akinsho/bufferline.nvim
  "akinsho/bufferline.nvim",

  -- Dependencies
  dependencies = { "nvim-tree/nvim-web-devicons" },

  -- Use latest stable version
  version = "*",

  -- =============================================================================
  -- Plugin Options
  -- =============================================================================
  opts = {
    -- Display mode: tabs (vs buffers)
    options = {
      mode = "tabs",
    },
  },
}
