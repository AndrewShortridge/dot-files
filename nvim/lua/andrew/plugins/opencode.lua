-- =============================================================================
-- OpenCode AI Integration (opencode.nvim)
-- =============================================================================
-- AI-powered coding assistant integration.
-- Provides commands for asking questions about code and generating responses.

return {
  -- Plugin: opencode.nvim - AI coding assistant for Neovim
  -- Repository: https://github.com/NickvanDyke/opencode.nvim
  "NickvanDyke/opencode.nvim",

  -- Dependencies
  dependencies = {
    -- Snacks for UI components (configured in plugins/snacks.lua)
    "folke/snacks.nvim",
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Empty options (use defaults)
    vim.g.opencode_opts = {}

    -- Enable auto-reload for file changes
    vim.opt.autoread = true

    -- =============================================================================
    -- Keybindings
    -- =============================================================================
    local keymap = vim.keymap

    -- Toggle the OpenCode panel
    keymap.set("n", "<leader>ot", function()
      require("opencode").toggle()
    end, { desc = "Toggle OpenCode panel" })

    -- Ask about code at cursor
    keymap.set("n", "<leader>oa", function()
      require("opencode").ask("@cursor: ")
    end, { desc = "Ask OpenCode about code at cursor" })

    -- Ask about selected code
    keymap.set("v", "<leader>oa", function()
      require("opencode").ask("@selection: ")
    end, { desc = "Ask OpenCode about selected code" })

    -- Add buffer to prompt
    keymap.set("n", "<leader>o+", function()
      require("opencode").prompt("@buffer", { append = true })
    end, { desc = "Add current buffer to OpenCode prompt" })

    -- Add selection to prompt
    keymap.set("v", "<leader>o+", function()
      require("opencode").prompt("@selection", { append = true })
    end, { desc = "Add selection to OpenCode prompt" })

    -- Explain code at cursor
    keymap.set("n", "<leader>oe", function()
      require("opencode").prompt("Explain @cursor and its context")
    end, { desc = "Explain code at cursor" })

    -- New session
    keymap.set("n", "<leader>on", function()
      require("opencode").command("session_new")
    end, { desc = "Create new OpenCode session" })

    -- Message navigation
    keymap.set("n", "<S-C-u>", function()
      require("opencode").command("messages_half_page_up")
    end, { desc = "Scroll OpenCode messages up" })

    keymap.set("n", "<S-C-d>", function()
      require("opencode").command("messages_half_page_down")
    end, { desc = "Scroll OpenCode messages down" })

    -- Select prompt
    keymap.set({ "n", "v" }, "<leader>os", function()
      require("opencode").select()
    end, { desc = "Select OpenCode prompt" })
  end,
}
