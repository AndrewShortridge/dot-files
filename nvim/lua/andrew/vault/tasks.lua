local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local M = {}

--- Collect all open tasks (- [ ]) across the vault and show in fzf-lua.
function M.tasks()
  local fzf = require("fzf-lua")
  fzf.grep({
    cwd = engine.vault_path,
    search = "- \\[ \\]",
    prompt = "Vault tasks> ",
    file_icons = true,
    git_icons = false,
    no_esc = true,
    rg_opts = '--column --line-number --no-heading --color=always --glob "*.md" -e',
  })
end

--- Collect tasks matching a specific checkbox state.
---@param mark string single char: " ", "/", "x", "-", ">"
function M.tasks_by_state(mark)
  local fzf = require("fzf-lua")
  local escaped = mark:gsub("[%-]", "\\%0")
  fzf.grep({
    cwd = engine.vault_path,
    search = "- \\[" .. escaped .. "\\]",
    prompt = "Vault tasks [" .. mark .. "]> ",
    file_icons = true,
    git_icons = false,
    no_esc = true,
    rg_opts = '--column --line-number --no-heading --color=always --glob "*.md" -e',
  })
end

--- Show all tasks regardless of state.
function M.tasks_all()
  local fzf = require("fzf-lua")
  fzf.grep({
    cwd = engine.vault_path,
    search = "- \\[.\\]",
    prompt = "Vault tasks (all)> ",
    file_icons = true,
    git_icons = false,
    no_esc = true,
    rg_opts = '--column --line-number --no-heading --color=always --glob "*.md" -e',
  })
end

function M.setup()
  vim.api.nvim_create_user_command("VaultTasks", function()
    M.tasks()
  end, { desc = "Show open tasks across vault" })

  vim.api.nvim_create_user_command("VaultTasksAll", function()
    M.tasks_all()
  end, { desc = "Show all tasks across vault (any state)" })

  vim.api.nvim_create_user_command("VaultTasksByState", function(args)
    local mark = args.args
    if mark == "" then
      mark = " "
    end
    M.tasks_by_state(mark)
  end, {
    nargs = "?",
    desc = "Show tasks with specific checkbox state",
  })

  -- Tasks group: <leader>vx
  vim.keymap.set("n", "<leader>vxo", function()
    M.tasks()
  end, { desc = "Tasks: open", silent = true })

  vim.keymap.set("n", "<leader>vxa", function()
    M.tasks_all()
  end, { desc = "Tasks: all", silent = true })

  vim.keymap.set("n", "<leader>vxs", function()
    engine.run(function()
      local states = {}
      for _, s in ipairs(config.task_states) do
        states[#states + 1] = s.mark .. " (" .. s.label .. ")"
      end
      local choice = engine.select(states, { prompt = "Task state" })
      if choice then
        M.tasks_by_state(choice:sub(1, 1))
      end
    end)
  end, { desc = "Tasks: by state", silent = true })
end

return M
