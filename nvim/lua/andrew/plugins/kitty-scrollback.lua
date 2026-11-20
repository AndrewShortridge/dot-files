-- =============================================================================
-- Kitty Scrollback (kitty-scrollback.nvim)
-- =============================================================================
-- Opens Kitty's scrollback buffer in Neovim: the copy-mode of this setup.
-- Kitty starts a second nvim in an overlay window and the plugin fills it with
-- the scrollback, so every motion, search and yank works on terminal output.
--
-- The Kitty side lives in ~/.config/kitty/kitty.conf:
--   action_alias kitty_scrollback_nvim kitten <this plugin>/python/kitty_scrollback_nvim.py
--   ctrl+shift+f1            whole scrollback
--   ctrl+shift+f2            output of the last command
--   ctrl+shift+right-click   output of the clicked command
-- That alias hard-codes the lazy.nvim install path, so do not rename the plugin.

return {
  -- Plugin: kitty-scrollback.nvim - browse Kitty's scrollback in Neovim
  -- Repository: https://github.com/mikesmithgh/kitty-scrollback.nvim
  "mikesmithgh/kitty-scrollback.nvim",

  -- Each major version raises the minimum Kitty or Neovim version, so stay on
  -- the 9.x line until a bump is made on purpose.
  version = "^9",

  -- Never loaded by an ordinary nvim. The kitten launches nvim with a --cmd
  -- that fires `User KittyScrollbackLaunch`; the commands are setup helpers.
  lazy = true,
  cmd = {
    "KittyScrollbackGenerateKittens",
    "KittyScrollbackCheckHealth",
    "KittyScrollbackGenerateCommandLineEditing",
  },
  event = { "User KittyScrollbackLaunch" },

  opts = {},
}
