local engine = require("andrew.vault.engine")
local pickers = require("andrew.vault.pickers")

local M = {}

--- Convert a title to a filename-safe slug.
---@param title string
---@return string
local function slugify(title)
  return title
    :lower()
    :gsub("%s+", "-")
    :gsub("[^%w%-]", "")
    :gsub("%-%-+", "-")
    :gsub("^%-+", "")
    :gsub("%-+$", "")
end

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
    "status: Not Started",
    "priority: 3",
    "created: " .. date,
  }

  if project then
    lines[#lines + 1] = 'parent-project: "[[Projects/' .. project .. "/Dashboard|" .. project .. ']]"'
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
  local ui = vim.api.nvim_list_uis()[1]
  local width = 60
  local col = math.floor((ui.width - width) / 2)
  local row = math.floor((ui.height - 1) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = " Quick Task ",
    title_pos = "center",
  })

  vim.cmd("startinsert")

  local closed = false
  local function close(submit)
    if closed then return end
    closed = true
    vim.cmd("stopinsert")

    if submit then
      local title = vim.trim(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
      if title ~= "" then
        vim.schedule(function() M._create_task(title) end)
      else
        vim.notify("Vault: empty title, task not created", vim.log.levels.WARN)
      end
    end

    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- Keymaps
  local kopts = { buffer = buf, silent = true }
  vim.keymap.set({ "n", "i" }, "<CR>", function() close(true) end, kopts)
  vim.keymap.set("n", "<Esc>", function() close(false) end, kopts)
  vim.keymap.set("n", "q", function() close(false) end, kopts)

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function() close(false) end,
  })
end

--- Write the task note to disk.
---@param title string
function M._create_task(title)
  local slug = slugify(title)
  local project = pickers.get_sticky()

  local rel_path
  if project then
    rel_path = "Projects/" .. project .. "/tasks/" .. slug
  else
    rel_path = "Log/tasks/" .. slug
  end

  local content = build_note(title, project)

  engine.run(function()
    engine.write_note(rel_path, content)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("VaultQuickTask", function()
    M.quick_task()
  end, { desc = "Create a quick task note" })

  vim.keymap.set("n", "<leader>vxq", function()
    M.quick_task()
  end, { desc = "Vault: quick task", silent = true })
end

return M
