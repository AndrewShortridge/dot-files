-- =============================================================================
-- Keybinding Hints (which-key.nvim)
-- =============================================================================
-- Displays available keybindings when the leader key is pressed.
-- Shows a popup with all key mappings starting with the pressed prefix.

return {
  -- Plugin: which-key.nvim - Keybinding hints popup
  -- Repository: https://github.com/folke/which-key.nvim
  "folke/which-key.nvim",

  -- Load lazily
  event = "VeryLazy",

  -- Initialize before config
  init = function()
    -- Enable keybinding timeout
    vim.o.timeout = true

    -- Timeout length in milliseconds (500ms)
    vim.o.timeoutlen = 500
  end,

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    local wk = require("which-key")

    wk.setup({})

    -- =============================================================================
    -- Register Key Groups
    -- =============================================================================
    -- Pre-register groups so which-key shows them even for lazy-loaded plugins

    wk.add({
      { "<leader>d", group = "Debug" },
      { "<leader>r", group = "Rust/Refactor" },
      { "<leader>c", group = "Code Actions" },
      { "<leader>f", group = "Find/Files" },
      { "<leader>x", group = "Trouble/Diagnostics" },
      { "<leader>s", group = "Split/Window" },
      { "<leader>g", group = "Git" },
    })
  end,
}
