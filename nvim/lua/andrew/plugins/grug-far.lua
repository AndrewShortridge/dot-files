-- =============================================================================
-- Find and Replace (grug-far.nvim)
-- =============================================================================
-- Project-wide search and replace in a dedicated buffer, powered by ripgrep.
-- Ported from LazyVim (lua/lazyvim/plugins/editor.lua), keeping its <leader>sr
-- keymap and its cmd/keys lazy gate verbatim. LazyVim's one option override,
-- `headerMaxWidth = 80`, is NOT carried over: that option no longer exists in
-- grug-far and was silently ignored, so the plugin runs on its own defaults.

return {
  -- Plugin: grug-far.nvim - Find And Replace, using the full power of rg
  -- Repository: https://github.com/MagicDuck/grug-far.nvim
  "MagicDuck/grug-far.nvim",

  -- Load only when the keymap or one of the commands is used. GrugFarWithin is
  -- listed alongside GrugFar because the plugin ships both user commands and
  -- neither exists until the plugin loads.
  cmd = { "GrugFar", "GrugFarWithin" },

  -- No option overrides: `headerMaxWidth` (LazyVim's only one) no longer exists
  -- in the installed grug-far and was dropped on the floor without a warning.
  opts = {},

  -- =============================================================================
  -- Keybindings
  -- =============================================================================
  keys = {
    {
      "<leader>sr",
      function()
        local grug = require("grug-far")
        -- Prefill the files filter with the current file's extension, so a
        -- replace started from a .lua file defaults to searching *.lua only.
        -- Guarded on buftype == "" so this never fires from a scratch/terminal
        -- buffer, where expand("%:e") would be meaningless.
        local ext = vim.bo.buftype == "" and vim.fn.expand("%:e")
        grug.open({
          transient = true,
          prefills = {
            filesFilter = ext and ext ~= "" and "*." .. ext or nil,
          },
        })
      end,
      mode = { "n", "x" },
      desc = "Search and Replace (project-wide, via ripgrep)",
    },
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function(_, opts)
    require("grug-far").setup(opts)

    -- LazyVim closes grug-far buffers with `q` via its central close_with_q
    -- autocmd (lazyvim/config/autocmds.lua). This config has no such central
    -- list -- `q`-to-close is done per-buffer at creation time -- so register
    -- the equivalent here, scoped to the grug-far buffer only. Inside that
    -- buffer `q` shadows macro recording, which is the same tradeoff LazyVim
    -- makes; the plugin's own <localleader>c close keymap still works too.
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("grug_far_close_with_q", { clear = true }),
      pattern = "grug-far",
      callback = function(event)
        vim.bo[event.buf].buflisted = false
        vim.keymap.set("n", "q", function()
          vim.cmd("close")
          pcall(vim.api.nvim_buf_delete, event.buf, { force = true })
        end, { buffer = event.buf, silent = true, desc = "Quit buffer" })
      end,
    })
  end,
}
