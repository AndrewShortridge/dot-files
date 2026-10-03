-- =============================================================================
-- Sticky Context Headers (nvim-treesitter-context)
-- =============================================================================
-- Pins parent scope (headings, functions, classes) at the top of the screen
-- so you always know where you are in long files.

return {
  "nvim-treesitter/nvim-treesitter-context",

  dependencies = { "nvim-treesitter/nvim-treesitter" },

  ft = { "lua", "python", "fortran", "c", "cpp", "rust", "javascript", "typescript", "tsx", "vue", "html", "css", "bash", "latex", "vim", "json", "yaml", "query", "vimdoc" },

  opts = {
    enable = true,
    max_lines = 6,           -- up to 6 levels (h1-h6 in markdown)
    min_window_height = 20,  -- disable in short windows
    multiline_threshold = 1, -- show only the heading line, not its body
    trim_scope = "inner",    -- trim innermost first so top-level heading stays
    mode = "cursor",         -- show context based on cursor position
    separator = "─",         -- separator between context and buffer

    -- In cursor mode the plugin re-walks the TS tree on every CursorMoved
    -- (the hottest nav event); in markdown that means re-walking the heading
    -- tree per move. The plugin has no per-filetype `mode`, and a global
    -- `topline` switch would degrade code-file context. So we gate markdown
    -- off via `on_attach`: update_win() short-circuits in cannot_open() for
    -- unattached buffers and never calls context.get() for md. Code files
    -- keep cursor-mode context unchanged. `[c` (go_to_context) still works in
    -- markdown — it calls context.get() on demand, independent of attach.
    on_attach = function(bufnr)
      if vim.bo[bufnr].filetype == "markdown" then
        return false
      end
      return true
    end,
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
