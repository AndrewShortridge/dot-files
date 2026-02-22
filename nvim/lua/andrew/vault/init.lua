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

-- Template group: <leader>vt
keymap("n", "<leader>vtn", function()
  M.new_note()
end, opts("Template: picker"))
keymap("n", "<leader>vtd", function()
  M.run_template("Daily Log")
end, opts("Template: daily log"))
keymap("n", "<leader>vtw", function()
  M.run_template("Weekly Review")
end, opts("Template: weekly review"))
keymap("n", "<leader>vts", function()
  M.run_template("Simulation Note")
end, opts("Template: simulation"))
keymap("n", "<leader>vta", function()
  M.run_template("Analysis Note")
end, opts("Template: analysis"))
keymap("n", "<leader>vtk", function()
  M.run_template("Task Note")
end, opts("Template: task"))
keymap("n", "<leader>vtm", function()
  M.run_template("Meeting Note")
end, opts("Template: meeting"))
keymap("n", "<leader>vtf", function()
  M.run_template("Finding Note")
end, opts("Template: finding"))
keymap("n", "<leader>vtl", function()
  M.run_template("Literature Note")
end, opts("Template: literature"))
keymap("n", "<leader>vtp", function()
  M.run_template("Project Dashboard")
end, opts("Template: project"))
keymap("n", "<leader>vtj", function()
  M.run_template("Journal Entry")
end, opts("Template: journal"))
keymap("n", "<leader>vtc", function()
  M.run_template("Concept Note")
end, opts("Template: concept"))
keymap("n", "<leader>vtM", function()
  M.run_template("Monthly Review")
end, opts("Template: monthly review"))
keymap("n", "<leader>vtQ", function()
  M.run_template("Quarterly Review")
end, opts("Template: quarterly review"))
keymap("n", "<leader>vtY", function()
  M.run_template("Yearly Review")
end, opts("Template: yearly review"))

-- Load query module
M.query = require("andrew.vault.query")

-- Load wikilink navigation
require("andrew.vault.wikilinks").setup()

-- Load backlinks / forward links
require("andrew.vault.backlinks").setup()

-- Load daily log navigation
require("andrew.vault.navigate").setup()

-- Load vault-wide search
require("andrew.vault.search").setup()

-- Load heading outline picker
require("andrew.vault.outline").setup()

-- Load tag search
require("andrew.vault.tags").setup()

-- Load frontmatter auto-update
require("andrew.vault.frontmatter").setup()

-- Load link health check
require("andrew.vault.linkcheck").setup()

-- Load footnote navigation
require("andrew.vault.footnotes").setup()

-- Load extract-to-note
require("andrew.vault.extract").setup()

-- Load rename operations
require("andrew.vault.rename").setup()

-- Load frecency tracking
require("andrew.vault.frecency").setup()

-- Load recent vault notes picker (frecency-backed)
require("andrew.vault.recent").setup()

-- Load project picker
pickers.setup()

-- Load pandoc export
require("andrew.vault.export").setup()

-- Load task aggregation
require("andrew.vault.tasks").setup()

-- Load quick capture
require("andrew.vault.capture").setup()

-- Load link hover preview
require("andrew.vault.preview").setup()

-- Load image paste
require("andrew.vault.images").setup()

-- Load pinned/starred notes
require("andrew.vault.pins").setup()

-- Load embed transclusion rendering
require("andrew.vault.embed").setup()

-- Load local graph view
require("andrew.vault.graph").setup()

-- Load template fragment insertion
require("andrew.vault.fragments").setup()

-- Load MetaEdit frontmatter toggling
require("andrew.vault.metaedit").setup()

-- Load quick task capture
require("andrew.vault.quicktask").setup()

-- Load breadcrumb winbar
require("andrew.vault.breadcrumbs").setup()

-- Load auto-file by type
require("andrew.vault.autofile").setup()

-- Load real-time link diagnostics
require("andrew.vault.linkdiag").setup()

-- Load block ID generation
require("andrew.vault.blockid").setup()

-- Load saved/pinned searches
require("andrew.vault.saved_searches").setup()

-- Vault switcher
vim.api.nvim_create_user_command("VaultSwitch", function()
  engine.pick_vault()
end, { desc = "Switch active vault" })

keymap("n", "<leader>vV", function()
  engine.pick_vault()
end, opts("Vault: switch vault"))

return M
