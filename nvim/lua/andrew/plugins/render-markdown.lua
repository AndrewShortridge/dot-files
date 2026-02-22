-- =============================================================================
-- Markdown Rendering (render-markdown.nvim)
-- =============================================================================
-- Renders markdown in-buffer with styled headings, tables with box-drawing
-- characters, checkboxes, code blocks, and concealed wiki-link syntax.
-- Uses treesitter for parsing. Rendering disappears when cursor enters
-- the element so you can edit normally.

return {
  "MeanderingProgrammer/render-markdown.nvim",

  ft = { "markdown" },

  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "nvim-tree/nvim-web-devicons",
  },

  ---@module 'render-markdown'
  ---@type render.md.UserConfig
  opts = {
    -- Use the obsidian preset (renders in all modes)
    preset = "obsidian",

    -- Heading: keep markdown-style icons, disable sign column clutter
    heading = {
      sign = false,
    },

    -- Code blocks: no sign column, full-width background
    code = {
      sign = false,
    },

    -- Table rendering with round box-drawing characters
    pipe_table = {
      preset = "round",
    },
  },
}
