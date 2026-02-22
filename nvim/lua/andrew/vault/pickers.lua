local M = {}

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

  return engine.select(projects, { prompt = "Select project" })
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
  table.insert(projects, 1, "None (General Meeting)")

  local choice = engine.select(projects, { prompt = "Select project" })
  if choice == nil then return nil end
  if choice == "None (General Meeting)" then return false end
  return choice
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

return M
