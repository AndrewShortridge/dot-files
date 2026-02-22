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
      { "<leader>a", group = "Type Check" },
      { "<leader>c", group = "Code Actions" },
      { "<leader>d", group = "Debug" },
      { "<leader>e", group = "Explorer" },
      { "<leader>f", group = "Find/Files" },
      { "<leader>g", group = "Git" },
      { "<leader>h", group = "Git Hunks" },
      { "<leader>l", group = "Lint" },
      { "<leader>m", group = "Make/Build" },
      { "<leader>o", group = "OpenCode" },
      { "<leader>r", group = "Rust/Refactor" },
      { "<leader>s", group = "Split/Window" },
      { "<leader>t", group = "Tab/Terminal" },
      { "<leader>v", group = "Vault" },
      { "<leader>vt", group = "Templates" },
      { "<leader>vf", group = "Find" },
      { "<leader>vq", group = "Query" },
      { "<leader>ve", group = "Edit" },
      { "<leader>vx", group = "Tasks" },
      { "<leader>vc", group = "Check" },
      { "<leader>x", group = "Trouble/Diagnostics" },
    })
  end,
}
