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
    -- These live on `gs` rather than the upstream `s`, because flash.nvim now
    -- owns s/S with LazyVim's meanings (see plugins/flash.lua). The gs/gss/gS
    -- shape deliberately mirrors nvim-surround's ys/yss/yS, and is the same
    -- prefix LazyVim itself moves mini.surround onto for the same reason.
    --
    -- `gs` shadows the built-in "sleep for N seconds" command, which is not a
    -- meaningful loss. It does NOT collide with nvim-surround: surround's `gS`
    -- is visual-mode only, while the `gS` below is normal-mode only.
    local keymap = vim.keymap

    -- Operator: substitute with motion (e.g., gs i w to substitute inner word)
    keymap.set("n", "gs", substitute.operator, { desc = "Substitute with motion" })

    -- Line: substitute entire current line
    keymap.set("n", "gss", substitute.line, { desc = "Substitute entire line" })

    -- End of line: substitute from cursor to end of line
    keymap.set("n", "gS", substitute.eol, { desc = "Substitute to end of line" })

    -- Visual mode: substitute selection
    keymap.set("x", "gs", substitute.visual, { desc = "Substitute selection in visual mode" })
  end,
}
