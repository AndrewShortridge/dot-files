local link_utils = require("andrew.vault.link_utils")

local T = {}
local _engine -- set by T.setup()

-- =============================================================================
-- Obsidian-Compatible Template Variable Substitution
-- =============================================================================

--- Map of Obsidian/Moment.js format tokens to Lua os.date() strftime codes.
--- Ordered longest-first within each letter group to ensure greedy matching.
--- @type { pattern: string, replacement: string }[]
local OBSIDIAN_FORMAT_MAP = {
  -- Year
  { pattern = "YYYY", replacement = "%%Y" },
  { pattern = "YY",   replacement = "%%y" },
  -- Month (name)
  { pattern = "MMMM", replacement = "%%B" },
  { pattern = "MMM",  replacement = "%%b" },
  -- Month (number) — must come after MMMM/MMM
  { pattern = "MM",   replacement = "%%m" },
  -- Day of year
  { pattern = "DDDD", replacement = "%%j" },
  -- Day of month (padded)
  { pattern = "DD",   replacement = "%%d" },
  -- Weekday names — must come before single-char matches
  { pattern = "dddd", replacement = "%%A" },
  { pattern = "ddd",  replacement = "%%a" },
  { pattern = "dd",   replacement = "%%a" },
  -- Hour 24h (padded)
  { pattern = "HH",   replacement = "%%H" },
  -- Hour 12h (padded)
  { pattern = "hh",   replacement = "%%I" },
  -- Minutes (padded)
  { pattern = "mm",   replacement = "%%M" },
  -- Seconds (padded)
  { pattern = "ss",   replacement = "%%S" },
  -- AM/PM
  { pattern = "A",    replacement = "%%p" },
}

--- Unpadded token handlers — evaluated at runtime, not via strftime.
--- Keyed by Obsidian token.
--- @type table<string, fun(): string>
local OBSIDIAN_UNPADDED = {
  M = function() return tostring(tonumber(os.date("%m"))) end,   -- month
  D = function() return tostring(tonumber(os.date("%d"))) end,   -- day
  H = function() return tostring(tonumber(os.date("%H"))) end,   -- 24h hour
  h = function() return tostring(tonumber(os.date("%I"))) end,   -- 12h hour
  m = function() return tostring(tonumber(os.date("%M"))) end,   -- minutes
  s = function() return tostring(tonumber(os.date("%S"))) end,   -- seconds
  a = function() return os.date("%p"):lower() end,               -- am/pm
}

--- Convert an Obsidian/Moment.js format string to a Lua os.date()-compatible
--- string. Tokens that require runtime computation (unpadded values) are
--- resolved immediately and spliced into the format string as literals.
---@param fmt string  Obsidian format (e.g., "YYYY-MM-DD", "MMMM D, YYYY")
---@return string strftime_fmt
function T.obsidian_to_strftime(fmt)
  local parts = {}
  local i = 1
  local len = #fmt

  while i <= len do
    local matched = false

    -- Try multi-char padded tokens (longest match first)
    for _, entry in ipairs(OBSIDIAN_FORMAT_MAP) do
      local pat = entry.pattern
      if fmt:sub(i, i + #pat - 1) == pat then
        parts[#parts + 1] = entry.replacement
        i = i + #pat
        matched = true
        break
      end
    end

    -- Try single-char unpadded tokens (only if no multi-char matched)
    if not matched then
      local ch = fmt:sub(i, i)
      local fn = OBSIDIAN_UNPADDED[ch]
      if fn then
        -- Splice the computed value directly as a literal
        parts[#parts + 1] = fn()
        i = i + 1
        matched = true
      end
    end

    if not matched then
      -- Literal character
      local ch = fmt:sub(i, i)
      if ch == "%" then
        parts[#parts + 1] = "%%%%"  -- escape for os.date
      else
        parts[#parts + 1] = ch
      end
      i = i + 1
    end
  end

  return table.concat(parts)
end

--- Format the current date/time using an Obsidian-style format string.
---@param obsidian_fmt string  e.g., "YYYY-MM-DD", "HH:mm", "MMMM D, YYYY"
---@return string
function T.format_obsidian(obsidian_fmt)
  local strftime_fmt = T.obsidian_to_strftime(obsidian_fmt)
  return os.date(strftime_fmt)
end

-- ---------------------------------------------------------------------------
-- Variable registry
-- ---------------------------------------------------------------------------

--- Registry of user-defined custom template variables.
--- @type table<string, fun(vars: table): string>
T._custom_vars = {}

--- Register a custom template variable.
--- The resolver receives the vars table and must return a string.
---@param name string  Variable name (used as {{name}} in templates)
---@param resolver fun(vars: table): string
function T.register_var(name, resolver)
  T._custom_vars[name] = resolver
end

--- Built-in variable resolvers.
--- Note: resolvers referencing _engine are safe because they only execute
--- at substitution time, after T.setup() has been called.
--- @type table<string, fun(vars: table): string>
local BUILTIN_VARS = {
  date = function(_vars)
    local cfg = require("andrew.vault.config")
    return T.format_obsidian(cfg.template_vars.date_format)
  end,
  time = function(_vars)
    local cfg = require("andrew.vault.config")
    return T.format_obsidian(cfg.template_vars.time_format)
  end,
  title = function(vars)
    if vars.title then return vars.title end
    local bufname = vim.api.nvim_buf_get_name(0)
    if bufname ~= "" then return link_utils.get_basename(bufname) end
    return "Untitled"
  end,
  vault = function(_vars)
    for name, path in pairs(_engine.vaults) do
      if path == _engine.vault_path then return name end
    end
    return link_utils.get_tail(_engine.vault_path)
  end,
  vault_path = function(_vars)
    return _engine.vault_path
  end,
  folder = function(vars)
    if vars.folder then return vars.folder end
    if vars._dest_path then
      local dir = link_utils.lua_dirname(vars._dest_path)
      return dir ~= "." and dir or ""
    end
    return ""
  end,
  date_long = function(_vars) return _engine.today_long() end,
  date_weekday = function(_vars) return _engine.today_weekday() end,
  week = function(_vars) return _engine.week_number() end,
  year = function(_vars) return os.date("%Y") end,
  month = function(_vars) return os.date("%m") end,
  day = function(_vars) return os.date("%d") end,
  yesterday = function(_vars) return _engine.date_offset(-1) end,
  tomorrow = function(_vars) return _engine.date_offset(1) end,
  timestamp = function(_vars) return os.date("%Y-%m-%dT%H:%M:%S") end,
}

--- Perform Obsidian-compatible template variable substitution.
---
--- Supports three syntaxes in order:
---   1. {{date:FORMAT}} / {{time:FORMAT}} — Obsidian format strings
---   2. {{variable}} — built-in, custom-registered, or vars-table lookup
---   3. ${variable} — legacy syntax (backward compat with existing templates)
---
---@param template string   The template string with {{var}} or ${var} placeholders
---@param vars? table       Variable overrides (key -> string value)
---@return string
function T.substitute(template, vars)
  vars = vars or {}

  -- Pass 1: {{date:FORMAT}} and {{time:FORMAT}}
  local result = template:gsub("{{date:([^}]+)}}", function(fmt)
    return T.format_obsidian(fmt)
  end)
  result = result:gsub("{{time:([^}]+)}}", function(fmt)
    return T.format_obsidian(fmt)
  end)

  -- Pass 2: {{variable}}
  result = result:gsub("{{([%w_]+)}}", function(key)
    -- Explicit vars override everything
    if vars[key] ~= nil then return tostring(vars[key]) end
    -- Built-in resolvers
    if BUILTIN_VARS[key] then return BUILTIN_VARS[key](vars) end
    -- Custom registered resolvers
    if T._custom_vars[key] then return T._custom_vars[key](vars) end
    -- Unresolved: leave as-is
    return "{{" .. key .. "}}"
  end)

  -- Pass 3: ${variable} (legacy backward compat)
  result = result:gsub("%${([%w_]+)}", function(key)
    return vars[key] or ("${" .. key .. "}")
  end)

  return result
end

--- Initialize the template system with a reference to the engine module.
--- Must be called before any template substitution that uses built-in variables.
---@param engine table  The engine module table
function T.setup(engine)
  _engine = engine
end

return T
