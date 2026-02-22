local M = {}

--- Session-only sticky project: remembers the last-selected project name.
M._sticky_project = nil

--- Pick a project from Projects/ that contains a Dashboard.md.
--- Scans the vault's Projects/ directory for subdirectories containing Dashboard.md.
---@param engine table the engine module
---@return string|nil project name, nil if cancelled
function M.project(engine)
  local projects_dir = engine.vault_path .. "/Projects"
  local entries = vim.fn.readdir(projects_dir)

  local projects = vim.tbl_filter(function(name)
    return vim.fn.isdirectory(projects_dir .. "/" .. name) == 1
      and vim.fn.filereadable(projects_dir .. "/" .. name .. "/Dashboard.md") == 1
  end, entries)

  table.sort(projects)

  if #projects == 0 then
    vim.notify("Vault: no projects found in Projects/", vim.log.levels.WARN)
    return nil
  end

  -- Promote sticky project to index 1 if it still exists
  if M._sticky_project then
    for i, name in ipairs(projects) do
      if name == M._sticky_project then
        table.remove(projects, i)
        table.insert(projects, 1, M._sticky_project .. " (recent)")
        break
      end
    end
  end

  local choice = engine.select(projects, { prompt = "Select project" })
  if choice == nil then return nil end

  -- Strip the " (recent)" marker if present
  local clean = choice:gsub(" %(recent%)$", "")
  M._sticky_project = clean
  return clean
end

--- Pick a project or "None (General)".
--- Returns the project name, or false if "None" was selected, or nil if cancelled.
---@param engine table
---@return string|false|nil
function M.project_or_none(engine)
  local projects_dir = engine.vault_path .. "/Projects"
  local entries = vim.fn.readdir(projects_dir)

  local projects = vim.tbl_filter(function(name)
    return vim.fn.isdirectory(projects_dir .. "/" .. name) == 1
      and vim.fn.filereadable(projects_dir .. "/" .. name .. "/Dashboard.md") == 1
  end, entries)

  table.sort(projects)

  -- Promote sticky project to index 1 if it still exists
  if M._sticky_project then
    for i, name in ipairs(projects) do
      if name == M._sticky_project then
        table.remove(projects, i)
        table.insert(projects, 1, M._sticky_project .. " (recent)")
        break
      end
    end
  end

  table.insert(projects, 1, "None (General Meeting)")

  local choice = engine.select(projects, { prompt = "Select project" })
  if choice == nil then return nil end
  if choice == "None (General Meeting)" then return false end

  -- Strip the " (recent)" marker if present
  local clean = choice:gsub(" %(recent%)$", "")
  M._sticky_project = clean
  return clean
end

--- Pick an area from Areas/.
---@param engine table
---@return string|nil area name
function M.area(engine)
  local areas_dir = engine.vault_path .. "/Areas"
  local entries = vim.fn.readdir(areas_dir)

  local areas = vim.tbl_filter(function(name)
    return vim.fn.isdirectory(areas_dir .. "/" .. name) == 1
  end, entries)

  table.sort(areas)

  if #areas == 0 then
    vim.notify("Vault: no areas found in Areas/", vim.log.levels.WARN)
    return nil
  end

  return engine.select(areas, { prompt = "Select area" })
end

--- Pick a domain from Domains/.
---@param engine table
---@return string|nil domain name
function M.domain(engine)
  local domains_dir = engine.vault_path .. "/Domains"
  local entries = vim.fn.readdir(domains_dir)

  local domains = vim.tbl_filter(function(name)
    return vim.fn.isdirectory(domains_dir .. "/" .. name) == 1
  end, entries)

  table.sort(domains)

  if #domains == 0 then
    vim.notify("Vault: no domains found in Domains/", vim.log.levels.WARN)
    return nil
  end

  return engine.select(domains, { prompt = "Select domain" })
end

--- Manually set the sticky project.
---@param name string project name
function M.set_sticky(name)
  M._sticky_project = name
end

--- Clear the sticky project.
function M.clear_sticky()
  M._sticky_project = nil
end

--- Read the current sticky project.
---@return string|nil
function M.get_sticky()
  return M._sticky_project
end

--- Show an fzf picker of projects and open the selected project's Dashboard.md.
function M.pick_project()
  local vault_path = require("andrew.vault.engine").vault_path
  local projects_dir = vault_path .. "/Projects"
  local entries = vim.fn.readdir(projects_dir)

  local projects = vim.tbl_filter(function(name)
    return vim.fn.isdirectory(projects_dir .. "/" .. name) == 1
      and vim.fn.filereadable(projects_dir .. "/" .. name .. "/Dashboard.md") == 1
  end, entries)

  table.sort(projects)

  if #projects == 0 then
    vim.notify("Vault: no projects found in Projects/", vim.log.levels.WARN)
    return
  end

  -- Build relative paths so the builtin previewer can render them
  local dashboard_paths = {}
  for _, name in ipairs(projects) do
    dashboard_paths[#dashboard_paths + 1] = name .. "/Dashboard.md"
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(dashboard_paths, {
    prompt = "Projects> ",
    cwd = projects_dir,
    file_icons = true,
    git_icons = false,
    previewer = "builtin",
    actions = {
      ["default"] = fzf.actions.file_edit,
      ["ctrl-s"] = fzf.actions.file_split,
      ["ctrl-v"] = fzf.actions.file_vsplit,
    },
  })
end

function M.setup()
  vim.api.nvim_create_user_command("VaultProjects", function()
    M.pick_project()
  end, { desc = "Pick a vault project and open its dashboard" })

  vim.keymap.set("n", "<leader>vfp", function()
    M.pick_project()
  end, { desc = "Find: project dashboard", silent = true })

  -- Auto-detect sticky project from buffer path on BufEnter
  local vault_path = require("andrew.vault.engine").vault_path
  local projects_prefix = vault_path .. "/Projects/"
  vim.api.nvim_create_autocmd("BufEnter", {
    group = vim.api.nvim_create_augroup("VaultStickyProject", { clear = true }),
    pattern = "*.md",
    callback = function(ev)
      local bufpath = ev.match
      if bufpath:sub(1, #projects_prefix) == projects_prefix then
        local rest = bufpath:sub(#projects_prefix + 1)
        local project_name = rest:match("^([^/]+)")
        if project_name and vim.fn.isdirectory(projects_prefix .. project_name) == 1 then
          M._sticky_project = project_name
        end
      end
    end,
  })

  -- VaultStickyProject: show current or pick one
  vim.api.nvim_create_user_command("VaultStickyProject", function()
    if M._sticky_project then
      vim.notify("Sticky project: " .. M._sticky_project, vim.log.levels.INFO)
    else
      vim.notify("No sticky project set", vim.log.levels.INFO)
    end
    vim.ui.select({ "Keep", "Pick new", "Clear" }, { prompt = "Sticky project" }, function(choice)
      if choice == "Pick new" then
        local engine = require("andrew.vault.engine")
        engine.run(function()
          local name = M.project(engine)
          if name then
            M._sticky_project = name
            vim.notify("Sticky project set: " .. name, vim.log.levels.INFO)
          end
        end)
      elseif choice == "Clear" then
        M.clear_sticky()
        vim.notify("Sticky project cleared", vim.log.levels.INFO)
      end
    end)
  end, { desc = "Show/set sticky project" })

  -- VaultStickyClear: clear the sticky project
  vim.api.nvim_create_user_command("VaultStickyClear", function()
    M.clear_sticky()
    vim.notify("Sticky project cleared", vim.log.levels.INFO)
  end, { desc = "Clear sticky project" })

  -- <leader>vP: show/set sticky project
  vim.keymap.set("n", "<leader>vP", function()
    vim.cmd("VaultStickyProject")
  end, { desc = "Sticky project: show/set", silent = true })
end

return M
