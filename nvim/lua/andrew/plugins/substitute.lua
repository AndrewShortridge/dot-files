-- =============================================================================
-- Substitute Plugin (substitute.nvim)
-- =============================================================================
-- Provides a motion-based substitute (replace) operation.
-- More intuitive than vim's built-in substitute command.

return {
  -- Plugin: substitute.nvim - Modern substitute plugin for Neovim
  -- Repository: https://github.com/gbprod/substitute.nvim
  "gbprod/substitute.nvim",

  -- Load when reading files
  event = { "BufReadPre", "BufNewFile" },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Load substitute module
    local substitute = require("substitute")

    -- Initialize with default options
    substitute.setup()

    -- =============================================================================
    -- Keybindings
    -- =============================================================================
    local keymap = vim.keymap

    -- Operator: substitute with motion (e.g., s i w to substitute inner word)
    keymap.set("n", "s", substitute.operator, { desc = "Substitute with motion" })

    -- Line: substitute entire current line
    keymap.set("n", "ss", substitute.line, { desc = "Substitute entire line" })

    -- End of line: substitute from cursor to end of line
    keymap.set("n", "S", substitute.eol, { desc = "Substitute to end of line" })

    -- Visual mode: substitute selection
    keymap.set("x", "s", substitute.visual, { desc = "Substitute selection in visual mode" })
  end,
}
