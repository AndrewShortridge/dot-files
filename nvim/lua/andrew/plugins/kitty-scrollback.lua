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

  -- Visual `y` / `<CR>` copy the selection to the clipboard and close the
  -- overlay, as in Kitty's or tmux's copy mode; Visual `Y` does it by lines.
  -- They replace the plugin's Visual `<leader>y` (which waited out
  -- 'timeoutlen' behind <leader>yf / <leader>yp) and `<leader>Y` (bound to
  -- `<Plug>(KsbVisualYankLine)`, which upstream never defines, so it did
  -- nothing; it is defined here). The plugin skips a default whose <Plug> is
  -- already mapped, and maps its own after this runs. Closing is the
  -- plugin's: a yank into "+ ends the session (`close_after_yank`). Plain `y`
  -- no longer feeds the paste window; `<S-CR>` still sends a selection there.
  config = function(_, opts)
    require("kitty-scrollback").setup(opts)

    -- The setup commands (:KittyScrollbackCheckHealth, ...) load the plugin in
    -- an ordinary nvim too; only the overlay's nvim gets this variable.
    if vim.env.KITTY_SCROLLBACK_NVIM ~= "true" then
      return
    end
    local keymap = vim.keymap
    local copy_and_close =
      { silent = true, desc = "Scrollback: copy selection to clipboard and close" }
    keymap.set("x", "y", "<Plug>(KsbVisualYank)", copy_and_close)
    keymap.set("x", "<CR>", "<Plug>(KsbVisualYank)", copy_and_close)
    keymap.set("x", "<Plug>(KsbVisualYankLine)", '"+Y')
    keymap.set("x", "Y", "<Plug>(KsbVisualYankLine)", {
      silent = true,
      desc = "Scrollback: copy selected lines to clipboard and close",
    })
  end,
}
