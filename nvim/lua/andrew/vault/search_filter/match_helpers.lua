--- Shared helper functions for field/task matching in search filter.

local M = {}

local config = require("andrew.vault.config")
local date_utils = require("andrew.vault.date_utils")

--- Compare two numbers with an operator.
---@param lhs number
---@param op string
---@param rhs number
---@return boolean
function M.compare_num(lhs, op, rhs)
  if op == "=" then return lhs == rhs end
  if op == ">" then return lhs > rhs end
  if op == ">=" then return lhs >= rhs end
  if op == "<" then return lhs < rhs end
  if op == "<=" then return lhs <= rhs end
  return false
end

--- Invert a comparison operator.
--- For relative duration values (e.g. "7d"), operators are inverted so that
--- users think in terms of recency/age: "modified:<7d" = "less than 7 days ago"
--- = "within the last 7 days" (entry_ts > threshold).
---@param op string
---@return string
local function invert_op(op)
  if op == ">" then return "<" end
  if op == "<" then return ">" end
  if op == ">=" then return "<=" end
  if op == "<=" then return ">=" end
  return op
end

--- Check if a value falls within an inclusive numeric range.
--- Automatically swaps lo/hi if reversed.
---@param val number the value to test
---@param lo number range lower bound (inclusive)
---@param hi number range upper bound (inclusive)
---@return boolean
function M.in_num_range(val, lo, hi)
  if lo > hi then lo, hi = hi, lo end
  return lo <= val and val <= hi
end

--- Compare a timestamp against a filter with automatic operator inversion
--- for relative duration values (Nd patterns).
---@param ts number entry timestamp
---@param op string comparison operator
---@param filter_ts number resolved filter timestamp
---@param filter_val string raw filter value (to detect Nd patterns)
---@param invert boolean|nil override: true to force inversion, false to skip, nil for auto-detect
---@return boolean
function M.compare_date(ts, op, filter_ts, filter_val, invert)
  local effective_op = op
  if invert == nil then invert = date_utils.is_relative_duration(filter_val) end
  if invert then effective_op = invert_op(op) end
  return M.compare_num(ts, effective_op, filter_ts)
end

--- Resolve a field alias path (e.g. "frontmatter.area") into the entry.
--- Resolve a dot-separated alias path on an entry table.
---@param entry table VaultIndexEntry
---@param alias_path string dot-separated path
---@return any|nil
local function resolve_alias_path(entry, alias_path)
  local val = entry
  for part in alias_path:gmatch("[^%.]+") do
    if type(val) ~= "table" then return nil end
    val = val[part]
  end
  return val
end

--- Get a field value from the entry: field_aliases -> frontmatter -> inline_fields.
---@param entry table VaultIndexEntry
---@param name string field name
---@return any|nil
function M.get_generic_field(entry, name)
  -- Check field aliases from config
  local aliases = config.search.field_aliases
  local alias_path = aliases[name]
  if alias_path then
    return resolve_alias_path(entry, alias_path)
  end

  -- Frontmatter first, then inline_fields
  if entry.frontmatter and entry.frontmatter[name] ~= nil then
    return entry.frontmatter[name]
  end
  if entry.inline_fields and entry.inline_fields[name] ~= nil then
    return entry.inline_fields[name]
  end
  return nil
end

--- Convert a filter value to number, using FilterContext cache when available.
---@param val string|nil value to convert
---@param ctx table|nil FilterContext
---@return number|nil
function M.tonumber_cached(val, ctx)
  if not val then return nil end
  if ctx then
    local cached = ctx.numeric_values[val]
    if cached ~= nil then return cached or nil end
  end
  return tonumber(val)
end

--- Check if a named field has a non-nil, non-empty value in the entry.
---@param name string field name
---@param entry table VaultIndexEntry
---@return boolean
function M.field_exists(name, entry)
  if name == "type" then
    local v = entry.frontmatter and entry.frontmatter.type
    return v ~= nil and v ~= ""
  elseif name == "tag" then
    return entry.tags ~= nil and #entry.tags > 0
  elseif name == "path" or name == "file" or name == "folder" then
    return true
  elseif name == "status" then
    local v = (entry.frontmatter and entry.frontmatter.status)
      or (entry.inline_fields and entry.inline_fields.status)
    return v ~= nil and v ~= ""
  elseif name == "priority" then
    local v = (entry.frontmatter and entry.frontmatter.priority)
      or (entry.inline_fields and entry.inline_fields.priority)
    return v ~= nil
  elseif name == "created" or name == "modified" then
    return true
  elseif name == "day" then
    return entry.day ~= nil
  elseif name == "alias" then
    return entry.aliases ~= nil and #entry.aliases > 0
  else
    return M.get_generic_field(entry, name) ~= nil
  end
end

return M
