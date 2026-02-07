-- =============================================================================
-- TODO Comments Highlighting (todo-comments.nvim)
-- =============================================================================
-- Highlights and provides navigation for TODO, FIXME, HACK, WARNING, etc. comments.
-- Enables quick discovery of task markers throughout the codebase.

return {
  -- Plugin: todo-comments.nvim - Highlight and search TODO comments
  -- Repository: https://github.com/folke/todo-comments.nvim
  "folke/todo-comments.nvim",

  -- Load when reading files
  event = { "BufReadPre", "BufNewFile" },

  -- Dependencies
  dependencies = { "nvim-lua/plenary.nvim" },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Load modules
    local todo_comments = require("todo-comments")
    local keymap = vim.keymap

    -- =============================================================================
    -- Navigation Keybindings
    -- =============================================================================

    -- Jump to next TODO comment
    keymap.set("n", "]t", function()
      todo_comments.jump_next()
    end, { desc = "Jump to next TODO/FIXME comment" })

    -- Jump to previous TODO comment
    keymap.set("n", "[t", function()
      todo_comments.jump_prev()
    end, { desc = "Jump to previous TODO/FIXME comment" })

    -- Setup the plugin with default options
    todo_comments.setup()
  end,
}
