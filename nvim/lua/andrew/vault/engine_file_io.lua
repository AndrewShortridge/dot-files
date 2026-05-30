local notify = require("andrew.vault.notify")
local link_utils = require("andrew.vault.link_utils")

local F = {}
local _engine -- set by F.setup()

--- Open a file, returning handle or nil + error string.
---@param path string
---@param mode string
---@return file*|nil, string|nil
local function open_file(path, mode)
  local file, err = io.open(path, mode)
  if not file then return nil, err end
  return file, nil
end

--- Create directory and all parents if they don't exist.
---@param abs_path string
function F.ensure_dir(abs_path)
  vim.fn.mkdir(abs_path, "p")
end

--- Create a JSON-backed persistent store scoped to the current vault.
--- @param filename string  The filename (e.g. ".vault-frecency.json")
--- @param defaults? table  Default value when file missing/corrupt
--- @return { load: fun(): table, save: fun(data: table), path: fun(): string }
function F.json_store(filename, defaults)
  defaults = defaults or {}

  local function path()
    return _engine.vault_path .. "/" .. filename
  end

  local function load()
    local file = open_file(path(), "r")
    if not file then return vim.deepcopy(defaults) end
    local raw = file:read("*a")
    file:close()
    if raw == "" then return vim.deepcopy(defaults) end
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then return vim.deepcopy(defaults) end
    return decoded
  end

  local function save(data)
    local file = open_file(path(), "w")
    if not file then
      notify.failed_write(path())
      return
    end
    file:write(vim.json.encode(data))
    file:close()
  end

  -- In-memory cache with vault-path invalidation.
  -- Eliminates the need for per-module _db/_db_vault boilerplate.
  local _cached = nil
  local _cached_vault = nil

  --- Load data, returning the cached copy if vault path hasn't changed.
  ---@return table
  local function cached_load()
    if _cached and _cached_vault == _engine.vault_path then
      return _cached
    end
    _cached_vault = _engine.vault_path
    _cached = load()
    return _cached
  end

  --- Save data and update the in-memory cache.
  ---@param data table
  local function cached_save(data)
    _cached = data
    _cached_vault = _engine.vault_path
    save(data)
  end

  --- Invalidate the in-memory cache (e.g. on vault switch).
  local function cached_invalidate()
    _cached = nil
    _cached_vault = nil
  end

  --- Return the cached data without loading from disk, or nil if not cached.
  ---@return table|nil
  local function cached_get()
    if _cached and _cached_vault == _engine.vault_path then
      return _cached
    end
    return nil
  end

  return {
    load = load,
    save = save,
    path = path,
    cached_load = cached_load,
    cached_save = cached_save,
    cached_invalidate = cached_invalidate,
    cached_get = cached_get,
  }
end

--- Read entire file as a string.
--- @param path string
--- @return string|nil content
--- @return string|nil err  Error reason on failure
function F.read_file(path)
  local file, err = open_file(path, "r")
  if not file then
    return nil, "cannot open " .. path .. ": " .. (err or "unknown")
  end
  local content = file:read("*a")
  file:close()
  if not content then
    return nil, "read returned nil for " .. path
  end
  return content, nil
end

--- Read file as an array of lines. Returns empty table on failure.
--- @param path string
--- Write content to file, creating parent dirs. Returns success boolean.
--- @param path string
--- @param content string
--- @return boolean
function F.write_file(path, content)
  local dir = link_utils.lua_dirname(path)
  F.ensure_dir(dir)
  local file, err = open_file(path, "w")
  if not file then
    notify.failed_write(path, err or "unknown")
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
function F.append_file(path, content)
  local file, err = open_file(path, "a")
  if not file then
    notify.failed_append(path, err or "unknown")
    return false
  end
  file:write(content)
  file:close()
  return true
end

--- Write a note to the vault and open it in the current buffer.
--- Creates parent directories as needed.
--- If the file already exists, prompts for confirmation before overwriting.
--- Must be called from within engine.run() if overwrite confirmation is needed.
---@param rel_path string path relative to vault root, WITHOUT .md extension
---@param content string full file content including frontmatter
---@return boolean success
function F.write_note(rel_path, content)
  local full_path = _engine.vault_path .. "/" .. rel_path .. ".md"
  local dir = link_utils.lua_dirname(full_path)
  F.ensure_dir(dir)

  -- Guard against overwriting existing files
  if vim.fn.filereadable(full_path) == 1 then
    local choice = _engine.select(
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
  local file, io_err = open_file(full_path, "w")
  if not file then
    notify.failed_write(full_path, io_err or "unknown error")
    return false
  end
  file:write(content)
  file:close()

  -- Open in editor
  vim.cmd("edit " .. vim.fn.fnameescape(full_path))
  notify.note_created(rel_path)
  return true
end

--- Initialize the file I/O system with a reference to the engine module.
---@param engine table  The engine module table
function F.setup(engine)
  _engine = engine
end

return F
