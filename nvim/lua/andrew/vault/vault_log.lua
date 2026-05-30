--- Structured logger for vault modules.
--- Provides level-filtered logging to vim.notify and optional file output.
--- Usage:
---   local log = require("andrew.vault.vault_log").scope("module_name")
---   log.debug("parsed %d files in %dms", count, elapsed)
---   log.warn("image not found: %s", name)

local M = {}

--- @alias LogLevel "DEBUG"|"INFO"|"WARN"|"ERROR"

local LEVELS = {
  DEBUG = 1,
  INFO  = 2,
  WARN  = 3,
  ERROR = 4,
}

local VIM_LEVELS = {
  DEBUG = vim.log.levels.DEBUG,
  INFO  = vim.log.levels.INFO,
  WARN  = vim.log.levels.WARN,
  ERROR = vim.log.levels.ERROR,
}

-- Default: show WARN and above in vim.notify, log everything to file
local _min_notify_level = LEVELS.WARN
local _min_file_level = LEVELS.DEBUG
local _log_file = nil          -- path, set by configure()
local _log_file_handle = nil   -- io file handle

--- Configure the logger. Called once from engine.lua after config is loaded.
---@param opts { notify_level?: LogLevel, file_level?: LogLevel, file?: string }
function M.configure(opts)
  if opts.notify_level and LEVELS[opts.notify_level] then
    _min_notify_level = LEVELS[opts.notify_level]
  end
  if opts.file_level and LEVELS[opts.file_level] then
    _min_file_level = LEVELS[opts.file_level]
  end
  if opts.file then
    _log_file = opts.file
  end
end

--- Format and emit a log message.
---@param level_name LogLevel
---@param prefix string
---@param fmt string
---@param ... any
local function emit(level_name, prefix, fmt, ...)
  local level_num = LEVELS[level_name]
  -- Early exit: skip formatting if neither output will use this message
  if level_num < _min_notify_level and (not _log_file or level_num < _min_file_level) then
    return
  end
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then
    msg = fmt -- fallback to raw format string if formatting fails
  end
  local full = prefix ~= "" and ("[vault:" .. prefix .. "] " .. msg) or ("[vault] " .. msg)

  -- vim.notify (user-visible)
  if level_num >= _min_notify_level then
    vim.schedule(function()
      vim.notify(full, VIM_LEVELS[level_name], {
        title = "Vault",
      })
    end)
  end

  -- File output
  if _log_file and level_num >= _min_file_level then
    if not _log_file_handle then
      _log_file_handle = io.open(_log_file, "a")
    end
    if _log_file_handle then
      local timestamp = os.date("%Y-%m-%d %H:%M:%S")
      _log_file_handle:write(
        string.format("[%s] [%s] %s\n", timestamp, level_name, full)
      )
      _log_file_handle:flush()
    end
  end
end

--- Close log file handle on exit.
function M.close()
  if _log_file_handle then
    _log_file_handle:close()
    _log_file_handle = nil
  end
end

--- Create a scoped logger that prepends a module name.
---@param module_name string
---@return table
function M.scope(module_name)
  return {
    debug = function(fmt, ...) emit("DEBUG", module_name, fmt, ...) end,
    info  = function(fmt, ...) emit("INFO",  module_name, fmt, ...) end,
    warn  = function(fmt, ...) emit("WARN",  module_name, fmt, ...) end,
    error = function(fmt, ...) emit("ERROR", module_name, fmt, ...) end,
  }
end

--- Get recent log entries (for :VaultLog integration).
--- Returns the tail of the log file, or instructions if file logging is off.
---@param n? number  Number of lines to return (default 50)
---@return string[]
function M.tail(n)
  n = n or 50
  if not _log_file then
    return { "File logging is disabled. Set config.log.file to enable." }
  end
  local f = io.open(_log_file, "r")
  if not f then
    return { "Log file does not exist yet: " .. _log_file }
  end
  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  -- Return last n lines
  if #lines <= n then return lines end
  local result = {}
  for i = #lines - n + 1, #lines do
    result[#result + 1] = lines[i]
  end
  return result
end

return M
