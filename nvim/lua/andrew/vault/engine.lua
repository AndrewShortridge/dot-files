local M = {}

-- Configurable vault root path
M.vault_path = vim.fn.expand("~/Documents/Personal-Vault-Copy-02")

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
    local ok, err = coroutine.resume(co, value)
    if not ok then
      vim.notify("Vault: " .. tostring(err), vim.log.levels.ERROR)
    end
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
    local ok, err = coroutine.resume(co, choice)
    if not ok then
      vim.notify("Vault: " .. tostring(err), vim.log.levels.ERROR)
    end
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

--- Returns YYYY-MM-DD offset by `days` from today (can be negative)
function M.date_offset(days)
  return os.date("%Y-%m-%d", os.time() + days * 86400)
end

--- Create directory and all parents if they don't exist
---@param abs_path string
function M.ensure_dir(abs_path)
  vim.fn.mkdir(abs_path, "p")
end

--- Write a note to the vault and open it in the current buffer.
--- Creates parent directories as needed.
---@param rel_path string path relative to vault root, WITHOUT .md extension
---@param content string full file content including frontmatter
function M.write_note(rel_path, content)
  local full_path = M.vault_path .. "/" .. rel_path .. ".md"
  local dir = vim.fn.fnamemodify(full_path, ":h")
  M.ensure_dir(dir)

  -- Write file
  local file = io.open(full_path, "w")
  if not file then
    vim.notify("Vault: failed to write " .. full_path, vim.log.levels.ERROR)
    return
  end
  file:write(content)
  file:close()

  -- Open in editor
  vim.cmd("edit " .. vim.fn.fnameescape(full_path))
  vim.notify("Created: " .. rel_path .. ".md", vim.log.levels.INFO)
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
