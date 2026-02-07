-- =============================================================================
-- Core Module Initialization
-- =============================================================================
-- This is the main entry point for the core configuration layer.
-- Core modules contain fundamental editor settings that all other layers depend on.
-- These modules must be loaded first before any plugins.

-- Load core editor options (vim.opt settings)
require("andrew.core.options")

-- Load global keybindings (vim.keymap settings)
require("andrew.core.keymaps")
