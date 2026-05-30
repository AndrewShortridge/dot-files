local config = require("andrew.vault.config")
local hl_coord = require("andrew.vault.highlight_coordinator")

local M = {}

M.enabled = config.wikilink_highlights.enabled
M.ns = vim.api.nvim_create_namespace("vault_wikilink_hl")

-- ---------------------------------------------------------------------------
-- Toggle
-- ---------------------------------------------------------------------------

M.toggle = hl_coord.make_toggle(M, "wikilink highlights")

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  local palette = require("andrew.vault.command_palette")
  local group = vim.api.nvim_create_augroup("VaultWikilinkHL", { clear = true })

  hl_coord.setup_buf_cleanup(group, M.ns, {})

  -- Commands
  vim.api.nvim_create_user_command("VaultWikilinkHLToggle", function()
    M.toggle()
  end, { desc = "Toggle wikilink resolution highlighting" })

  hl_coord.make_refresh_command("VaultWikilinkHLRefresh", "Refresh wikilink highlights in current buffer")

  -- FileType autocmd removed: now dispatched via event_dispatch.lua

  -- Palette registrations
  palette.register_command("VaultWikilinkHLToggle", "Toggle wikilink resolution highlighting", "Debug", function()
    M.toggle()
  end, "<leader>vch")
  palette.register_command("VaultWikilinkHLRefresh", "Refresh wikilink highlights in current buffer", "Debug", function()
    vim.cmd("VaultWikilinkHLRefresh")
  end)

end

--- Called by event_dispatch.lua on FileType markdown.
--- @param ev table autocmd event args
function M.on_ft_markdown(ev)
  vim.keymap.set("n", "<leader>vch", function()
    M.toggle()
  end, {
    buffer = ev.buf,
    desc = "Check: wikilink highlights toggle",
    silent = true,
  })
end

return M
