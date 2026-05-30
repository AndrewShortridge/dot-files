-- =============================================================================
-- Sticky Context Headers (nvim-treesitter-context)
-- =============================================================================
-- Pins parent scope (headings, functions, classes) at the top of the screen
-- so you always know where you are in long files.

return {
  "nvim-treesitter/nvim-treesitter-context",

  dependencies = { "nvim-treesitter/nvim-treesitter" },

  event = { "BufReadPre", "BufNewFile" },

  opts = {
    enable = true,
    max_lines = 6,           -- up to 6 levels (h1-h6 in markdown)
    min_window_height = 20,  -- disable in short windows
    multiline_threshold = 1, -- show only the heading line, not its body
    trim_scope = "inner",    -- trim innermost first so top-level heading stays
    mode = "cursor",         -- show context based on cursor position
    separator = "─",         -- separator between context and buffer
  },

  keys = {
    {
      "[c",
      function()
        require("treesitter-context").go_to_context(vim.v.count1)
      end,
      desc = "Jump to context (parent scope)",
      silent = true,
    },
  },
}
