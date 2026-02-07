-- =============================================================================
-- Auto-Pairs Configuration (nvim-autopairs)
-- =============================================================================
-- Automatically inserts and manages matching pairs: (), [], {}, "", '', etc.
-- Integrates with completion plugins for intelligent pair handling.

return {
  -- Plugin: nvim-autopairs - Auto-close brackets and quotes
  -- Repository: https://github.com/windwp/nvim-autopairs
  "windwp/nvim-autopairs",

  -- Load when entering insert mode
  event = { "InsertEnter" },

  -- Dependencies
  dependencies = {
    -- nvim-cmp is required for completion integration
    "hrsh7th/nvim-cmp",
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Load autopairs module
    local autopairs = require("nvim-autopairs")

    -- Configure autopairs behavior
    autopairs.setup({
      -- Enable tree-sitter integration for smart pair detection
      check_ts = true,

      -- Tree-sitter configuration for ignored nodes
      ts_config = {
        lua = { "string" },             -- Don't auto-pair in Lua strings
        javascript = { "template_string" },  -- Don't auto-pair in JS template strings
        java = false,                   -- Disable tree-sitter for Java
      },
    })

    -- =============================================================================
    -- Completion Integration
    -- =============================================================================
    -- Configure autopairs to work with nvim-cmp completion

    local cmp_autopairs = require("nvim-autopairs.completion.cmp")
    local cmp = require("cmp")

    -- Trigger autopairs on completion confirm
    cmp.event:on("confirm_done", cmp_autopairs.on_confirm_done())
  end,
}
