local M = {}

--- Show recently accessed vault notes ranked by frecency score.
--- Delegates to the frecency module which tracks access patterns
--- (frequency + recency) rather than relying on vim.v.oldfiles.
function M.recent()
  require("andrew.vault.frecency").frequent()
end

function M.setup()
  vim.api.nvim_create_user_command("VaultRecent", function()
    M.recent()
  end, { desc = "Show recently edited vault notes" })

  vim.keymap.set("n", "<leader>vfr", function()
    M.recent()
  end, { desc = "Find: recent notes (frecency)", silent = true })
end

return M
