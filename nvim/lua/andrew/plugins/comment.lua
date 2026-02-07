-- =============================================================================
-- Commenting Plugin (Comment.nvim)
-- =============================================================================
-- Provides easy commenting and uncommenting for all supported file types.
-- Integrates with tree-sitter for accurate comment detection.

return {
  -- Plugin: Comment.nvim - Smart commenting plugin for Neovim
  -- Repository: https://github.com/numToStr/Comment.nvim
  "numToStr/Comment.nvim",

  -- Load when reading or creating files
  event = { "BufReadPre", "BufNewFile" },

  -- Dependencies
  dependencies = {
    -- Tree-sitter integration for accurate comment detection
    "JoosepAlviste/nvim-ts-context-commentstring",
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Load modules
    local comment = require("Comment")
    local ts_context_commentstring = require("ts_context_commentstring.integrations.comment_nvim")

    -- Setup with tree-sitter integration
    comment.setup({
      -- Pre-hook for tree-sitter comment string detection
      -- Enables accurate commenting in: Vue, JSX, Svelte, HTML, etc.
      pre_hook = ts_context_commentstring.create_pre_hook()
    })
  end,
}
