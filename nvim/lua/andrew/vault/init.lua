local engine = require("andrew.vault.engine")
local pickers = require("andrew.vault.pickers")
local templates = require("andrew.vault.templates")

local M = {}

--- Open the template picker and run the selected template
function M.new_note()
  engine.run(function()
    local names = {}
    for _, t in ipairs(templates) do
      table.insert(names, t.name)
    end

    local choice = engine.select(names, { prompt = "New vault note" })
    if not choice then
      return
    end

    for _, t in ipairs(templates) do
      if t.name == choice then
        t.run(engine, pickers)
        return
      end
    end
  end)
end

--- Run a specific template by its name (for direct keybindings)
---@param name string template display name
function M.run_template(name)
  for _, t in ipairs(templates) do
    if t.name == name then
      engine.run(function()
        t.run(engine, pickers)
      end)
      return
    end
  end
  vim.notify("Vault: unknown template '" .. name .. "'", vim.log.levels.ERROR)
end

-- =============================================================================
-- Commands
-- =============================================================================

vim.api.nvim_create_user_command("VaultNew", function()
  M.new_note()
end, { desc = "Create a new vault note from template" })

vim.api.nvim_create_user_command("VaultDaily", function()
  M.run_template("Daily Log")
end, { desc = "Create today's daily log" })

-- =============================================================================
-- Keybindings
-- =============================================================================

local keymap = vim.keymap.set
local opts = function(desc)
  return { desc = desc, silent = true }
end

-- Main picker
keymap("n", "<leader>vn", function()
  M.new_note()
end, opts("Vault: new note"))

-- Quick-access templates
keymap("n", "<leader>vd", function()
  M.run_template("Daily Log")
end, opts("Vault: daily log"))
keymap("n", "<leader>vw", function()
  M.run_template("Weekly Review")
end, opts("Vault: weekly review"))
keymap("n", "<leader>vs", function()
  M.run_template("Simulation Note")
end, opts("Vault: simulation"))
keymap("n", "<leader>va", function()
  M.run_template("Analysis Note")
end, opts("Vault: analysis"))
keymap("n", "<leader>vt", function()
  M.run_template("Task Note")
end, opts("Vault: task"))
keymap("n", "<leader>vm", function()
  M.run_template("Meeting Note")
end, opts("Vault: meeting"))
keymap("n", "<leader>vf", function()
  M.run_template("Finding Note")
end, opts("Vault: finding"))
keymap("n", "<leader>vl", function()
  M.run_template("Literature Note")
end, opts("Vault: literature"))
keymap("n", "<leader>vp", function()
  M.run_template("Project Dashboard")
end, opts("Vault: project"))
keymap("n", "<leader>vj", function()
  M.run_template("Journal Entry")
end, opts("Vault: journal"))
keymap("n", "<leader>vc", function()
  M.run_template("Concept Note")
end, opts("Vault: concept"))

-- Load query module
M.query = require("andrew.vault.query")

return M
