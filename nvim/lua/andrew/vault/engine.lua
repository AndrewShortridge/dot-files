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

--- Create a JSON-backed persistent store scoped to the current vault.
--- @param filename string  The filename (e.g. ".vault-frecency.json")
--- @param defaults? table  Default value when file missing/corrupt
--- @return { load: fun(): table, save: fun(data: table), path: fun(): string }
function M.json_store(filename, defaults)
  defaults = defaults or {}

  local function path()
    return M.vault_path .. "/" .. filename
  end

  local function load()
    local file = io.open(path(), "r")
    if not file then return vim.deepcopy(defaults) end
    local raw = file:read("*a")
    file:close()
    if raw == "" then return vim.deepcopy(defaults) end
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then return vim.deepcopy(defaults) end
    return decoded
  end

  local function save(data)
    local file = io.open(path(), "w")
    if not file then
      vim.notify("Vault: failed to write " .. path(), vim.log.levels.WARN)
      return
    end
    file:write(vim.json.encode(data))
    file:close()
  end

  return { load = load, save = save, path = path }
end

--- Read entire file as a string. Returns nil on failure.
--- @param path string
--- @return string|nil
function M.read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

--- Read file as an array of lines. Returns empty table on failure.
--- @param path string
--- @param max_lines? number  Optional limit on lines read
--- @return string[]
function M.read_file_lines(path, max_lines)
  local f = io.open(path, "r")
  if not f then return {} end
  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
    if max_lines and #lines >= max_lines then break end
  end
  f:close()
  return lines
end

--- Write content to file, creating parent dirs. Returns success boolean.
--- @param path string
--- @param content string
--- @return boolean
function M.write_file(path, content)
  local dir = vim.fn.fnamemodify(path, ":h")
  M.ensure_dir(dir)
  local file, err = io.open(path, "w")
  if not file then
    vim.notify("Vault: failed to write " .. path .. ": " .. (err or "unknown"), vim.log.levels.WARN)
    return false
  end
  file:write(content)
  file:close()
  return true
end

--- Append content to file. Returns success boolean.
--- @param path string
--- @param content string
--- @return boolean
function M.append_file(path, content)
  local file, err = io.open(path, "a")
  if not file then
    vim.notify("Vault: failed to append to " .. path .. ": " .. (err or "unknown"), vim.log.levels.WARN)
    return false
  end
  file:write(content)
  file:close()
  return true
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

--- Check if an absolute path is inside the current vault.
--- @param path string
--- @return boolean
function M.is_vault_path(path)
  return path ~= "" and vim.startswith(path, M.vault_path)
end

--- Convert an absolute path to a vault-relative path.
--- Returns nil if path is not inside the vault.
--- @param path string
--- @return string|nil
function M.vault_relative(path)
  if not M.is_vault_path(path) then return nil end
  return path:sub(#M.vault_path + 2)
end

--- Get the basename (without extension) of the current buffer.
--- Returns nil if buffer has no name.
--- @return string|nil
function M.current_note_name()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then return nil end
  return vim.fn.fnamemodify(bufname, ":t:r")
end

--- Base ripgrep options for vault-wide searches.
--- @param glob? string  File glob pattern (default: "*.md")
--- @return string
function M.rg_base_opts(glob)
  glob = glob or "*.md"
  return '--column --line-number --no-heading --color=always --smart-case --glob "' .. glob .. '"'
end

--- Common fzf-lua options for vault pickers.
--- @param prompt string  The prompt text (without trailing "> ")
--- @param extra? table   Additional options to merge
--- @return table
function M.vault_fzf_opts(prompt, extra)
  local opts = {
    cwd = M.vault_path,
    prompt = prompt .. "> ",
    file_icons = true,
    git_icons = false,
  }
  if extra then
    for k, v in pairs(extra) do
      opts[k] = v
    end
  end
  return opts
end

--- Standard fzf-lua actions for file open/split/vsplit/tab.
--- @return table
function M.vault_fzf_actions()
  local fzf = require("fzf-lua")
  return {
    ["default"] = fzf.actions.file_edit,
    ["ctrl-s"] = fzf.actions.file_split,
    ["ctrl-v"] = fzf.actions.file_vsplit,
    ["ctrl-t"] = fzf.actions.file_tabedit,
  }
end

return M
