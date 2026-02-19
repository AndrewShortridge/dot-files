-- =============================================================================
-- Table Editing (vim-table-mode)
-- =============================================================================
-- Auto-formats markdown tables as you type. Provides tab navigation
-- between cells, column alignment, and table creation shortcuts.
-- Similar to Obsidian's Advanced Tables plugin.
--
-- Usage:
--   <leader>tm  Toggle table mode on/off
--   |           Auto-creates table structure when table mode is on
--   Tab         Move to next cell (in table mode)
--   ||          Creates a horizontal separator row
--
-- Table mode auto-activates when entering a line starting with |

return {
  "dhruvasagar/vim-table-mode",

  ft = { "markdown" },

  init = function()
    -- Use markdown-compatible table corners
    vim.g.table_mode_corner = "|"

    -- Auto-align columns as you type
    vim.g.table_mode_auto_align = 1

    -- Map toggle to <leader>tm (table mode)
    vim.g.table_mode_map_prefix = "<leader>T"
    vim.g.table_mode_toggle_map = "m"
  end,
}
