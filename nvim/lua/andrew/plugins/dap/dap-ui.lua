-- =============================================================================
-- Debug Adapter Protocol UI (nvim-dap-ui)
-- =============================================================================
-- Configures nvim-dap-ui for a visual debugging interface.
-- Provides variable inspection, call stack, breakpoints list, and more.

return {
  -- Plugin: nvim-dap-ui - UI for nvim-dap
  -- Repository: https://github.com/rcarriga/nvim-dap-ui
  "rcarriga/nvim-dap-ui",

  -- Dependencies
  dependencies = {
    "mfussenegger/nvim-dap",
    "nvim-neotest/nvim-nio", -- Required async library
  },

  -- Load when nvim-dap loads
  lazy = true,

  -- =============================================================================
  -- Keybindings
  -- =============================================================================

  keys = {
    -- Toggle DAP UI
    {
      "<leader>du",
      function()
        require("dapui").toggle()
      end,
      desc = "Toggle DAP UI",
    },

    -- Evaluate expression under cursor
    {
      "<leader>de",
      function()
        require("dapui").eval()
      end,
      mode = { "n", "v" },
      desc = "Evaluate expression",
    },

    -- Float element (hover)
    {
      "<leader>df",
      function()
        require("dapui").float_element()
      end,
      desc = "Float element",
    },
  },

  -- =============================================================================
  -- Plugin Options
  -- =============================================================================
  opts = {
    -- Icon configuration
    icons = {
      expanded = "",
      collapsed = "",
      current_frame = "",
    },

    -- Control bar icons
    controls = {
      icons = {
        pause = "",
        play = "",
        step_into = "",
        step_over = "",
        step_out = "",
        step_back = "",
        run_last = "",
        terminate = "",
        disconnect = "",
      },
    },

    -- Floating window configuration
    floating = {
      max_height = 0.6,
      max_width = 0.6,
      border = "rounded",
      mappings = {
        close = { "q", "<Esc>" },
      },
    },

    -- Layout configuration
    layouts = {
      {
        -- Left sidebar: scopes, breakpoints, stacks, watches
        elements = {
          { id = "scopes", size = 0.25 },
          { id = "breakpoints", size = 0.25 },
          { id = "stacks", size = 0.25 },
          { id = "watches", size = 0.25 },
        },
        position = "left",
        size = 40,
      },
      {
        -- Bottom panel: REPL and console
        elements = {
          { id = "repl", size = 0.5 },
          { id = "console", size = 0.5 },
        },
        position = "bottom",
        size = 10,
      },
    },
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function(_, opts)
    local dapui = require("dapui")

    -- Initialize dap-ui with options
    dapui.setup(opts)

    -- Note: Auto-open/close listeners are configured in dap.lua
    -- to ensure they're registered when DAP loads
  end,
}
