-- =============================================================================
-- Table Editing (vim-table-mode)
-- =============================================================================
-- Auto-formats markdown tables as you type. Provides tab navigation
-- between cells, column alignment, and table creation shortcuts.
-- Similar to Obsidian's Advanced Tables plugin.
--
-- Usage:
--   <leader>Tm  Toggle table mode on/off (prefix is <leader>T -- see init below)
--   |           Auto-creates table structure when table mode is on
--   ]| / [|     Move to the next / previous cell
--   }| / {|     Move to the cell below / above
--   a| / i|     Around / inside a cell (text objects)
--   ||          Creates a horizontal separator row
--
-- NOTE: the plugin maps no <Tab>. Insert-mode <Tab> belongs to blink.cmp.
--
-- Loaded on-demand: the plugin is lazy-gated on its toggle mapping (<leader>Tm)
-- and table commands rather than `ft = markdown`, so opening a .md file no longer
-- re-fires `FileType markdown` (which would re-attach the treesitter highlighter).
-- Auto-activation on a line starting with | only kicks in after the first explicit
-- <leader>Tm / :TableModeToggle / :Tableize loads the plugin's markdown ftplugin.

return {
  "dhruvasagar/vim-table-mode",

  keys = {
    { "<leader>Tm", desc = "Toggle table mode" },
  },
  cmd = {
    "TableModeToggle",
    "TableModeEnable",
    "TableModeDisable",
    "Tableize",
    "TableSort",
    "TableModeRealign",
    "TableAddFormula",
  },

  init = function()
    -- Use markdown-compatible table corners
    vim.g.table_mode_corner = "|"

    -- Auto-align columns as you type
    vim.g.table_mode_auto_align = 1

    -- Toggle lives at <leader>Tm (prefix <leader>T + toggle map "m").
    vim.g.table_mode_map_prefix = "<leader>T"
    vim.g.table_mode_toggle_map = "m"
  end,
}
