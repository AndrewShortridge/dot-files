local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local M = {}
M.auto_file = false

M.type_map = {
  ["log"] = "Log",                     ["journal"] = "Log/journal",
  ["task"] = "Log/tasks",              ["literature"] = "Library",
  ["methodology"] = "Methods",         ["person"] = "People",
  ["meeting"] = "Log",                 ["simulation"] = "Log",
  ["analysis"] = "Log",                ["finding"] = "Log",
  ["concept"] = "Domains",             ["domain-moc"] = "Domains",
  ["project-dashboard"] = "Projects",  ["area-dashboard"] = "Areas",
}

local function strip(val)
  val = vim.trim(val)
  val = val:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
  return val:gsub("^%[%[(.-)%]%]$", "%1")
end

local function parse_frontmatter(bufnr)
  local count = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(count, config.frontmatter.max_scan_lines), false)
  local fields = {}
  if #lines == 0 or lines[1] ~= "---" then return fields end
  for i = 2, #lines do
    if lines[i] == "---" then break end
    local key, val = lines[i]:match("^([%w%-]+):%s+(.+)")
    if key then fields[key] = strip(val) end
  end
  return fields
end

local project_types = { task = true, meeting = true, simulation = true, analysis = true, finding = true, ["project-dashboard"] = true }

function M.get_expected_dir(note_type, fm)
  local base = M.type_map[note_type]
  if not base then return nil end

  local project = fm["parent-project"]
  if project and project ~= "" and project_types[note_type] then
    if note_type == "task" then
      return config.dirs.projects .. "/" .. project .. "/tasks"
    end
    return config.dirs.projects .. "/" .. project
  end

  local domain = fm["domain"]
  if domain and domain ~= "" and (note_type == "concept" or note_type == "domain-moc") then
    return config.dirs.domains .. "/" .. domain
  end

  local area = fm["area"]
  if area and area ~= "" and note_type == "area-dashboard" then
    return config.dirs.areas .. "/" .. area
  end

  return base
end

local function already_correct(filepath, expected_dir)
  local expected_abs = engine.vault_path .. "/" .. expected_dir
  return vim.startswith(vim.fn.fnamemodify(filepath, ":h"), expected_abs)
end

local function in_vault(filepath)
  return filepath ~= "" and vim.startswith(filepath, engine.vault_path)
end

function M.move(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if not in_vault(filepath) then return end

  local fm = parse_frontmatter(bufnr)
  local expected = fm["type"] and M.get_expected_dir(fm["type"], fm)
  if not expected then return end
  if already_correct(filepath, expected) then
    vim.notify("Already in correct directory", vim.log.levels.INFO)
    return
  end

  local dest_dir = engine.vault_path .. "/" .. expected
  local dest = dest_dir .. "/" .. vim.fn.fnamemodify(filepath, ":t")

  if vim.fn.filereadable(dest) == 1 then
    vim.notify("Destination already exists: " .. dest, vim.log.levels.ERROR)
    return
  end

  engine.ensure_dir(dest_dir)
  if vim.fn.rename(filepath, dest) ~= 0 then
    vim.notify("Failed to move file", vim.log.levels.ERROR)
    return
  end

  vim.cmd("edit " .. vim.fn.fnameescape(dest))
  local old_buf = vim.fn.bufnr(filepath)
  if old_buf ~= -1 and old_buf ~= vim.api.nvim_get_current_buf() then
    vim.api.nvim_buf_delete(old_buf, { force = true })
  end
  vim.notify("Moved: " .. filepath .. " -> " .. dest, vim.log.levels.INFO)
end

function M.suggest(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if not in_vault(filepath) then return end

  local fm = parse_frontmatter(bufnr)
  local expected = fm["type"] and M.get_expected_dir(fm["type"], fm)
  if not expected then return end
  if already_correct(filepath, expected) then return end

  local dest = expected .. "/" .. vim.fn.fnamemodify(filepath, ":t")
  engine.run(function()
    local answer = engine.input({ prompt = "Move to " .. dest .. "? (y/n): " })
    if answer and answer:lower() == "y" then M.move(bufnr) end
  end)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("VaultAutoFile", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if not in_vault(vim.api.nvim_buf_get_name(ev.buf)) then return end
      M.suggest(ev.buf)
    end,
  })

  vim.api.nvim_create_user_command("VaultAutoFile", function()
    M.suggest()
  end, { desc = "Suggest moving current note to its expected directory" })

  vim.api.nvim_create_user_command("VaultAutoFileMove", function()
    M.move()
  end, { desc = "Force-move current note to its expected directory" })

  vim.keymap.set("n", "<leader>vmv", function()
    M.suggest()
  end, { desc = "Vault: auto-file suggestion", silent = true })
end

return M
