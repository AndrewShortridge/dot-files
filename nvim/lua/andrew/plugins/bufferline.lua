-- =============================================================================
-- Tab/Buffer Line (bufferline.nvim)
-- =============================================================================
-- Displays tabs and buffers in a horizontal line at the top of the editor.
-- Provides visual management of open files and tabs.

return {
  -- Plugin: bufferline.nvim - A buffer line for Neovim
  -- Repository: https://github.com/akinsho/bufferline.nvim
  "akinsho/bufferline.nvim",

  -- Dependencies
  dependencies = { "nvim-tree/nvim-web-devicons" },

  -- Use latest stable version
  version = "*",

  -- Defer until after the UI paints (Tier 2 startup win)
  event = "VeryLazy",

  -- =============================================================================
  -- Plugin Options
  -- =============================================================================
  opts = {
    options = {
      -- Display mode: tabs (vs buffers)
      mode = "tabs",

      -- Stop bufferline managing 'showtabline' so <leader>uA can own it.
      -- bufferline re-asserts the option on every redraw (bufferline.lua:94,
      -- guarded by this flag), which would silently undo the toggle a moment
      -- after it fired. LazyVim instead sets always_show_bufferline = false,
      -- but that hides the tabline whenever only one tab is open -- a visible
      -- change from this config's current always-on tabline. Turning off the
      -- auto-management keeps the current look and makes the toggle stick;
      -- core/options.lua pins showtabline = 2 as the startup value.
      auto_toggle_bufferline = false,
    },
  },
}
