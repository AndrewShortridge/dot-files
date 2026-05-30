local config = require("andrew.vault.config")

local M = {}

local CYCLE_FIELDS = {
  status = config.status_values,
  priority = config.priority_values,
  maturity = config.maturity_values,
  type = config.note_types,
}

M.CYCLE_FIELDS = CYCLE_FIELDS

local yaml_special = '[:%#%[%{\'"]'

---@alias FieldType "string"|"number"|"boolean"|"date"|"list"|"cycle"

---@param key string
---@param value any
---@return FieldType
function M.detect_field_type(key, value)
  if CYCLE_FIELDS[key] then return "cycle" end
  if type(value) == "boolean" then return "boolean" end
  if type(value) == "number" then return "number" end
  if type(value) == "table" then return "list" end
  if type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%d") then
    return "date"
  end
  return "string"
end

M.TYPE_HIGHLIGHTS = {
  string  = "VaultFmEditorString",
  number  = "VaultFmEditorNumber",
  boolean = "VaultFmEditorBoolean",
  date    = "VaultFmEditorDate",
  list    = "VaultFmEditorList",
  cycle   = "VaultFmEditorString",
}

function M.format_display_value(value, field_type)
  if field_type == "list" and type(value) == "table" then
    return table.concat(vim.tbl_map(tostring, value), ", ")
  end
  if field_type == "boolean" then
    return value and "true" or "false"
  end
  return tostring(value)
end

--- Compute the maximum key width from a list of keys or key-bearing objects.
---@param items string[]|table[]  Array of key strings or tables with a `.key` field
---@return number
function M.max_key_width(items)
  local max_kw = 0
  for _, item in ipairs(items) do
    local len = type(item) == "string" and #item or #item.key
    if len > max_kw then max_kw = len end
  end
  return max_kw
end

function M.format_yaml_value(val)
  if type(val) == "boolean" then
    return val and "true" or "false"
  end
  if type(val) == "number" then
    return tostring(val)
  end
  local s = tostring(val)
  if s:match(yaml_special) then
    return '"' .. s:gsub('"', '\\"') .. '"'
  end
  return s
end

return M
