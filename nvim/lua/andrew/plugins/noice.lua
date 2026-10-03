-- =============================================================================
-- Command Line UI (noice.nvim)
-- =============================================================================
-- Replaces the bottom-row command line with a floating popup for `:` and gives
-- `/` and `?` an icon plus regex syntax highlighting.
--
-- Scoped deliberately to the cmdline ONLY. noice can also take over vim.notify,
-- :messages and the LSP hover/signature windows, but this config already has
-- owners for those:
--   - vault/notify.lua and vault/vault_log.lua call vim.notify directly
--   - snacks `input` / `picker.ui_select` own vim.ui.input / vim.ui.select
-- Enabling those noice modules would make the ownership a three-way race, so
-- they stay off. Everything below the cmdline behaves exactly as before.

return {
  -- Plugin: noice.nvim - replaces the UI for the cmdline, messages, popupmenu
  -- Repository: https://github.com/folke/noice.nvim
  "folke/noice.nvim",

  -- Load after startup; nothing here is needed to draw the first frame
  event = "VeryLazy",

  -- Plugin dependencies
  dependencies = {
    "MunifTanjim/nui.nvim",  -- Float/popup primitives noice renders into
  },

  opts = {
    -- The one module we actually want
    cmdline = {
      enabled = true,
      view = "cmdline_popup",
    },

    -- Leave messages, notifications and the wildmenu alone (see header note)
    messages = { enabled = false },
    notify = { enabled = false },
    popupmenu = { enabled = false },

    -- Leave every LSP window rendered by nvim/lspconfig as-is
    lsp = {
      hover = { enabled = false },
      signature = { enabled = false },
      message = { enabled = false },
      progress = { enabled = false },
      override = {
        ["vim.lsp.util.convert_input_to_markdown_lines"] = false,
        ["vim.lsp.util.stylize_markdown"] = false,
        ["cmp.entry.get_documentation"] = false,
      },
    },

    presets = {
      -- `:` popup sits near the top of the screen rather than dead centre
      command_palette = true,

      -- `/` and `?` render as a styled full-width bottom line, matching
      -- LazyVim. Set to false to float them in the same popup as `:`.
      bottom_search = true,

      -- Message routes; both irrelevant with messages disabled
      long_message_to_split = false,
      inc_rename = false,
    },
  },
}
