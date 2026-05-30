local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local fm_parser = require("andrew.vault.frontmatter_parser")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("metaedit")

local M = {}

-- ---------------------------------------------------------------------------
-- YAML special characters that require quoting
-- ---------------------------------------------------------------------------
local yaml_special = '[:%#%[%{\'"]'

--- Format a value for YAML output.
--- Booleans -> true/false, numbers -> bare, strings -> quote only if needed.
---@param val any
---@return string
local function format_value(val)
  if type(val) == "boolean" then
    return val and "true" or "false"
  end
  if type(val) == "number" then
    return tostring(val)
  end
  local s = tostring(val)
  if s:match(yaml_special) then
    -- Use double quotes, escaping internal double quotes
    return '"' .. s:gsub('"', '\\"') .. '"'
  end
  return s
end

--- Parse a raw string value and set the corresponding frontmatter field.
--- Delegates type coercion to parse_value.
--- @param field string  frontmatter field name
--- @param raw_value string  raw string typed by the user
local function coerce_and_set(field, raw_value)
  M.set_field(field, fm_parser.parse_value(raw_value))
end

-- ---------------------------------------------------------------------------
-- Frontmatter scanning
-- ---------------------------------------------------------------------------

--- Find frontmatter boundaries and a specific field in the current buffer.
--- Scans lines 1..max_scan_lines.
---@param buf number buffer handle
---@param field_name string field to look for
---@return table|nil info { opening: int, closing: int, field_line: int|nil, field_value: any|nil }
local function find_frontmatter(buf, field_name)
  local max = config.frontmatter.max_scan_lines
  local line_count = vim.api.nvim_buf_line_count(buf)
  local limit = math.min(line_count, max)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, limit, false)

  local fm = fm_parser.parse_lines(lines, max)
  if not fm then return nil end

  local field_line = nil
  local field_value = nil
  local pat = "^" .. vim.pesc(field_name) .. ":%s*(.*)"

  for i = fm.start_line + 1, fm.end_line - 1 do
    local raw = lines[i]:match(pat)
    if raw then
      field_line = i
      field_value = fm_parser.parse_value(raw)
    end
  end

  return {
    opening = fm.start_line,
    closing = fm.end_line,
    field_line = field_line,
    field_value = field_value,
  }
end

-- ---------------------------------------------------------------------------
-- Buffer modification helpers
-- ---------------------------------------------------------------------------

--- Replace a single line in the buffer (1-based line number).
---@param buf number
---@param lnum number 1-based
---@param text string
local function replace_line(buf, lnum, text)
  local ok, err = pcall(vim.cmd, "undojoin")
  if not ok then log.debug("undojoin before replace_line: %s", err) end
  vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { text })
end

--- Insert a line before a given 1-based line number.
---@param buf number
---@param before number 1-based line to insert before
---@param text string
local function insert_before(buf, before, text)
  local ok, err = pcall(vim.cmd, "undojoin")
  if not ok then log.debug("undojoin before insert_before: %s", err) end
  vim.api.nvim_buf_set_lines(buf, before - 1, before - 1, false, { text })
end

--- Create frontmatter with a single field at the top of the buffer.
---@param buf number
---@param field_name string
---@param val any
local function create_frontmatter(buf, field_name, val)
  local ok, err = pcall(vim.cmd, "undojoin")
  if not ok then log.debug("undojoin before create_frontmatter: %s", err) end
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, {
    "---",
    field_name .. ": " .. format_value(val),
    "---",
  })
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Set a frontmatter field to a specific value.
--- If the field is missing, add it. If no frontmatter exists, create it.
---@param field_name string
---@param value any
function M.set_field(field_name, value)
  local buf = vim.api.nvim_get_current_buf()
  local info = find_frontmatter(buf, field_name)

  if not info then
    -- No frontmatter at all
    create_frontmatter(buf, field_name, value)
    notify.info(field_name .. " = " .. format_value(value))
    return
  end

  local new_line = field_name .. ": " .. format_value(value)

  if info.field_line then
    replace_line(buf, info.field_line, new_line)
  else
    -- Field not present; insert before closing ---
    insert_before(buf, info.closing, new_line)
  end

  notify.info(field_name .. " = " .. format_value(value))
end

--- Cycle a frontmatter field through a list of values.
--- If the field is missing, set to the first value.
--- If at the last value, wrap to the first.
---@param field_name string
---@param values any[] list of values to cycle through
function M.cycle_field(field_name, values)
  if not values or #values == 0 then
    notify.warn("no values to cycle")
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local info = find_frontmatter(buf, field_name)

  -- Determine current index
  local cur_idx = nil
  if info and info.field_value ~= nil then
    local cur = info.field_value
    for i, v in ipairs(values) do
      -- Compare as strings to handle mixed types (number 1 vs string "1")
      if tostring(v) == tostring(cur) then
        cur_idx = i
        break
      end
    end
  end

  local next_idx = cur_idx and (cur_idx % #values) + 1 or 1
  local next_val = values[next_idx]

  if not info then
    create_frontmatter(buf, field_name, next_val)
  elseif info.field_line then
    replace_line(buf, info.field_line, field_name .. ": " .. format_value(next_val))
  else
    insert_before(buf, info.closing, field_name .. ": " .. format_value(next_val))
  end

  notify.info(field_name .. " -> " .. format_value(next_val))
end

--- Toggle a boolean frontmatter field.
--- If missing, add as true. If true, set false. If false, set true.
---@param field_name string
function M.toggle_field(field_name)
  local buf = vim.api.nvim_get_current_buf()
  local info = find_frontmatter(buf, field_name)

  local new_val
  if info and info.field_value ~= nil then
    new_val = not info.field_value
  else
    new_val = true
  end

  if not info then
    create_frontmatter(buf, field_name, new_val)
  elseif info.field_line then
    replace_line(buf, info.field_line, field_name .. ": " .. format_value(new_val))
  else
    insert_before(buf, info.closing, field_name .. ": " .. format_value(new_val))
  end

  notify.info(field_name .. " = " .. format_value(new_val))
end

-- ---------------------------------------------------------------------------
return M
