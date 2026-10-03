-- =============================================================================
-- Plugin Manager Setup (lazy.nvim)
-- =============================================================================
-- This module initializes and configures lazy.nvim as the plugin manager.
-- Lazy.nvim handles plugin installation, loading, and updates.

-- =============================================================================
-- Lazy.nvim Bootstrap
-- =============================================================================
-- First-time installation: Clone lazy.nvim repository if not already present
-- The plugin manager is stored in Neovim's data directory

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

-- Check if lazy.nvim is already installed
if not vim.uv.fs_stat(lazypath) then
  -- Clone the repository using Git with blobless clone for faster downloads
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    lazypath,
  })
end

-- Add lazy.nvim to the runtime path so it can be loaded
vim.opt.rtp:prepend(lazypath)

-- =============================================================================
-- Plugin Specification and Configuration
-- =============================================================================
-- Configure lazy.nvim with plugin specifications and behavior settings

-- Containerised runs (container/nvim.def) export NVIM_CONTAINER=1. There the
-- plugin tree is baked into a read-only .sif, usually on an air-gapped compute
-- node, so the update checker can do nothing but spend startup on `git fetch`
-- calls that cannot resolve -- and would have nowhere to write if they could.
-- Unset on a normal workstation run, where both settings keep their old values.
local containerised = vim.env.NVIM_CONTAINER == "1"

require("lazy").setup({
  -- Import all plugin specifications from the plugins directory
  -- This loads all plugins defined in lua/andrew/plugins/*.lua
  { import = "andrew.plugins" },

  -- Import LSP-related plugins from a subdirectory
  -- LSP plugins are organized separately for better code organization
  { import = "andrew.plugins.lsp" },
}, {
  -- =============================================================================
  -- Lazy.nvim Behavior Options
  -- =============================================================================

  -- No plugin in this config declares a luarocks dependency (lazy's own health
  -- check says so), so hererocks only ever produced one ERROR and two WARNINGs
  -- in :checkhealth lazy. Turn it off.
  rocks = { enabled = false },

  -- Checker: Automatically check for plugin updates
  checker = {
    enabled = not containerised,  -- Automatic update checking (off in a container)
    notify = false,        -- Don't notify on every check (silent background check)
  },

  -- Change Detection: Watch config files for changes
  change_detection = {
    enabled = not containerised,  -- Nothing can change under a read-only image
    notify = false,        -- Don't notify when config files change
  },
})
