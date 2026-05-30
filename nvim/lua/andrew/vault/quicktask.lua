local config = require("andrew.vault.config")
local engine = require("andrew.vault.engine")
local notify = require("andrew.vault.notify")
local pickers = require("andrew.vault.pickers")
local link_utils = require("andrew.vault.link_utils")
local ui = require("andrew.vault.ui")

local M = {}

local slugify = link_utils.heading_to_slug

--- Build the task note content.
---@param title string
---@param project string|nil
---@return string
local function build_note(title, project)
  local date = engine.today()
  local lines = {
    "---",
    "type: task",
    'title: "' .. title .. '"',
    "status: " .. config.status_default,
    "priority: " .. config.priority_default,
    "created: " .. date,
  }

  if project then
    lines[#lines + 1] = 'parent-project: "[[' .. config.dirs.projects .. '/' .. project .. "/Dashboard|" .. project .. ']]"'
  end

  vim.list_extend(lines, {
    "tags:",
    "  - task",
    "---",
    "",
    "# " .. title,
    "",
    "## Description",
    "",
    "",
    "## Acceptance Criteria",
    "",
    "- [ ] ",
    "",
    "## Notes",
    "",
  })

  return table.concat(lines, "\n") .. "\n"
end

--- Open a 60x1 floating window and create a task on <CR>.
function M.quick_task()
  ui.create_float_input({
    title = "Quick Task",
    width = config.ui.input_float_width,
    height = 1,
    submit_modes = { "n", "i" },
    on_submit = function(lines)
      local title = vim.trim(lines[1] or "")
      if title ~= "" then
        vim.schedule(function() M._create_task(title) end)
      else
        notify.warn("empty title, task not created")
      end
    end,
  })
end

--- Write the task note to disk.
---@param title string
function M._create_task(title)
  local slug = slugify(title)
  local project = pickers.get_sticky()

  local rel_path
  if project then
    rel_path = config.dirs.projects .. "/" .. project .. "/tasks/" .. slug
  else
    rel_path = config.dirs.log .. "/tasks/" .. slug
  end

  local content = build_note(title, project)

  engine.run(function()
    engine.write_note(rel_path, content)
  end)
end

function M.setup()
  local palette = require("andrew.vault.command_palette")

  vim.api.nvim_create_user_command("VaultQuickTask", function()
    M.quick_task()
  end, { desc = "Create a quick task note" })

  vim.keymap.set("n", "<leader>vxq", function()
    M.quick_task()
  end, { desc = "Vault: quick task", silent = true })

  -- Palette registrations
  palette.register_command("VaultQuickTask", "Create a quick task note", "Tasks", M.quick_task, "<leader>vxq")
end

return M
