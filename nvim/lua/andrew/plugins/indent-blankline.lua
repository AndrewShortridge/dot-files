-- =============================================================================
-- Indent Guides (indent-blankline.nvim)
-- =============================================================================
-- Displays visual indentation guides for each indentation level.
-- Helps visualize code structure and nesting depth.

return {
  -- Plugin: indent-blankline.nvim - Indent guides for Neovim
  -- Repository: https://github.com/lukas-reineke/indent-blankline.nvim
  "lukas-reineke/indent-blankline.nvim",

  -- Load only for code filetypes (shared list). Markdown/text never load ibl,
  -- so its per-keystroke/scroll refresh autocmds never attach there.
  ft = require("andrew.lsp_filetypes"),

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

    -- Skip markdown: render-markdown already supplies list/indent visuals, so
    -- ibl is redundant there. Excluding it stops ibl's per-keystroke/scroll
    -- refresh (CursorMoved/TextChanged/WinScrolled) from running on .md
    -- buffers. ibl APPENDS these to its default excludes (utils.tbl_join).
    exclude = {
      filetypes = { "markdown" },
    },
  },
}
