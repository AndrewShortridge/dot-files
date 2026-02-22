local M = {}

-- Available vaults (name -> path)
M.vaults = {
  ["Main"] = vim.fn.expand("~/Documents/Obsidian-Vault/Obsidian-Vault"),
  ["Personal"] = vim.fn.expand("~/Desktop/Personal Vault"),
}

-- Active vault (default to Main)
M.vault_path = M.vaults["Main"]

--- Switch to a different vault by name.
---@param name string vault name from M.vaults
function M.switch_vault(name)
  local path = M.vaults[name]
  if not path then
    vim.notify("Vault: unknown vault '" .. name .. "'", vim.log.levels.ERROR)
    return
  end
  M.vault_path = path
  vim.notify("Vault: switched to " .. name .. " (" .. path .. ")", vim.log.levels.INFO)
end

--- Show a picker to select and switch vaults.
function M.pick_vault()
  local names = {}
  for name, _ in pairs(M.vaults) do
    names[#names + 1] = name
  end
  table.sort(names)

  M.run(function()
    local choice = M.select(names, { prompt = "Switch vault" })
    if choice then
      M.switch_vault(choice)
    end
  end)
end

--- Run a template function inside a coroutine.
--- The function can call M.input() and M.select() which yield/resume automatically.
---@param fn function
function M.run(fn)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co)
  if not ok then
    vim.notify("Vault: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Coroutine-wrapped vim.ui.input. Must be called from within M.run().
---@param opts table {prompt: string}
---@return string|nil value, nil if cancelled
function M.input(opts)
  local co = coroutine.running()
  assert(co, "engine.input() must be called within engine.run()")
  vim.ui.input(opts, function(value)
    vim.schedule(function()
      local ok, err = coroutine.resume(co, value)
      if not ok then
        vim.notify("Vault: " .. tostring(err), vim.log.levels.ERROR)
      end
    end)
  end)
  return coroutine.yield()
end

--- Coroutine-wrapped vim.ui.select. Must be called from within M.run().
---@param items string[]
---@param opts table {prompt: string, format_item?: function}
---@return string|nil chosen item, nil if cancelled
function M.select(items, opts)
  local co = coroutine.running()
  assert(co, "engine.select() must be called within engine.run()")
  vim.ui.select(items, opts, function(choice)
    vim.schedule(function()
      local ok, err = coroutine.resume(co, choice)
      if not ok then
        vim.notify("Vault: " .. tostring(err), vim.log.levels.ERROR)
      end
    end)
  end)
  return coroutine.yield()
end

--- Returns today's date in YYYY-MM-DD format
function M.today()
  return os.date("%Y-%m-%d")
end

--- Returns date like "February 18, 2026"
function M.today_long()
  local day = tonumber(os.date("%d"))
  return os.date("%B ") .. day .. os.date(", %Y")
end

--- Returns date like "Tuesday, February 18, 2026"
function M.today_weekday()
  local day = tonumber(os.date("%d"))
  return os.date("%A, %B ") .. day .. os.date(", %Y")
end

--- Returns ISO week number as zero-padded string (e.g., "07")
function M.week_number()
  return os.date("%V")
end

--- Returns YYYY-MM-DD offset by `days` from today (can be negative).
--- Uses os.time table normalization to handle DST correctly.
function M.date_offset(days)
  local t = os.date("*t")
  t.day = t.day + days
  return os.date("%Y-%m-%d", os.time(t))
end

--- Create directory and all parents if they don't exist
---@param abs_path string
function M.ensure_dir(abs_path)
  vim.fn.mkdir(abs_path, "p")
end

--- Write a note to the vault and open it in the current buffer.
--- Creates parent directories as needed.
--- If the file already exists, prompts for confirmation before overwriting.
--- Must be called from within M.run() if overwrite confirmation is needed.
---@param rel_path string path relative to vault root, WITHOUT .md extension
---@param content string full file content including frontmatter
---@return boolean success
function M.write_note(rel_path, content)
  local full_path = M.vault_path .. "/" .. rel_path .. ".md"
  local dir = vim.fn.fnamemodify(full_path, ":h")
  M.ensure_dir(dir)

  -- Guard against overwriting existing files
  if vim.fn.filereadable(full_path) == 1 then
    local choice = M.select(
      { "Open existing", "Overwrite", "Cancel" },
      { prompt = rel_path .. ".md already exists" }
    )
    if choice == "Open existing" then
      vim.cmd("edit " .. vim.fn.fnameescape(full_path))
      return false
    elseif choice ~= "Overwrite" then
      return false
    end
  end

  -- Write file
  local file, io_err = io.open(full_path, "w")
  if not file then
    vim.notify("Vault: failed to write " .. full_path .. ": " .. (io_err or "unknown error"), vim.log.levels.ERROR)
    return false
  end
  file:write(content)
  file:close()

  -- Open in editor
  vim.cmd("edit " .. vim.fn.fnameescape(full_path))
  vim.notify("Created: " .. rel_path .. ".md", vim.log.levels.INFO)
  return true
end

--- Simple template variable substitution.
--- Replaces ${var_name} with values from the vars table.
---@param template string
---@param vars table<string, string>
---@return string
function M.render(template, vars)
  return (template:gsub("%${([%w_]+)}", function(key)
    return vars[key] or ("${" .. key .. "}")
  end))
end

return M
