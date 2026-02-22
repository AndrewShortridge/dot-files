local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

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

--- Parse a raw YAML value string into a typed Lua value.
---@param raw string
---@return any
local function parse_value(raw)
  local trimmed = vim.trim(raw)
  -- Booleans
  if trimmed == "true" then return true end
  if trimmed == "false" then return false end
  -- Numbers
  local num = tonumber(trimmed)
  if num then return num end
  -- Quoted strings: strip surrounding quotes
  local dq = trimmed:match('^"(.*)"$')
  if dq then return dq:gsub('\\"', '"') end
  local sq = trimmed:match("^'(.*)'$")
  if sq then return sq:gsub("''", "'") end
  -- Bare string
  return trimmed
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

  if #lines == 0 or lines[1] ~= "---" then
    return nil
  end

  local closing = nil
  local field_line = nil
  local field_value = nil

  -- Pattern: field_name at start of line, then colon
  local pat = "^" .. vim.pesc(field_name) .. ":%s*(.*)"

  for i = 2, #lines do
    if lines[i] == "---" then
      closing = i
      break
    end
    local raw = lines[i]:match(pat)
    if raw then
      field_line = i
      field_value = parse_value(raw)
    end
  end

  if not closing then
    return nil
  end

  return {
    opening = 1,
    closing = closing,     -- 1-based line number of closing ---
    field_line = field_line, -- 1-based, or nil if field not found
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
  pcall(vim.cmd, "undojoin")
  vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { text })
end

--- Insert a line before a given 1-based line number.
---@param buf number
---@param before number 1-based line to insert before
---@param text string
local function insert_before(buf, before, text)
  pcall(vim.cmd, "undojoin")
  vim.api.nvim_buf_set_lines(buf, before - 1, before - 1, false, { text })
end

--- Create frontmatter with a single field at the top of the buffer.
---@param buf number
---@param field_name string
---@param val any
local function create_frontmatter(buf, field_name, val)
  pcall(vim.cmd, "undojoin")
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
    vim.notify("metaedit: " .. field_name .. " = " .. format_value(value), vim.log.levels.INFO)
    return
  end

  local new_line = field_name .. ": " .. format_value(value)

  if info.field_line then
    replace_line(buf, info.field_line, new_line)
  else
    -- Field not present; insert before closing ---
    insert_before(buf, info.closing, new_line)
  end

  vim.notify("metaedit: " .. field_name .. " = " .. format_value(value), vim.log.levels.INFO)
end

--- Cycle a frontmatter field through a list of values.
--- If the field is missing, set to the first value.
--- If at the last value, wrap to the first.
---@param field_name string
---@param values any[] list of values to cycle through
function M.cycle_field(field_name, values)
  if not values or #values == 0 then
    vim.notify("metaedit: no values to cycle", vim.log.levels.WARN)
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

  vim.notify("metaedit: " .. field_name .. " -> " .. format_value(next_val), vim.log.levels.INFO)
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

  vim.notify("metaedit: " .. field_name .. " = " .. format_value(new_val), vim.log.levels.INFO)
end

--- Increment a numeric frontmatter field by step (default 1).
--- If missing, add with the step value.
---@param field_name string
---@param step number|nil defaults to 1
function M.increment_field(field_name, step)
  step = step or 1
  local buf = vim.api.nvim_get_current_buf()
  local info = find_frontmatter(buf, field_name)

  local cur = 0
  if info and info.field_value ~= nil then
    cur = tonumber(info.field_value) or 0
  end
  local new_val = cur + step

  if not info then
    create_frontmatter(buf, field_name, new_val)
  elseif info.field_line then
    replace_line(buf, info.field_line, field_name .. ": " .. format_value(new_val))
  else
    insert_before(buf, info.closing, field_name .. ": " .. format_value(new_val))
  end

  vim.notify("metaedit: " .. field_name .. " = " .. format_value(new_val), vim.log.levels.INFO)
end

--- Show a picker to choose a value, then set the field.
--- Uses engine.run/engine.select for coroutine-based UI.
---@param field_name string
---@param values any[] list of choices
function M.pick_and_set(field_name, values)
  engine.run(function()
    local items = {}
    for _, v in ipairs(values) do
      items[#items + 1] = tostring(v)
    end
    local choice = engine.select(items, { prompt = field_name })
    if not choice then return end
    -- Find the original typed value that matches the chosen string
    for _, v in ipairs(values) do
      if tostring(v) == choice then
        M.set_field(field_name, v)
        return
      end
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Setup: keymaps, commands, autocmds
-- ---------------------------------------------------------------------------

function M.setup()
  -- Cycle value lists
  local status_values = config.status_values
  local priority_values = config.priority_values
  local maturity_values = config.maturity_values

  -- -------------------------------------------------------------------
  -- Commands
  -- -------------------------------------------------------------------
  vim.api.nvim_create_user_command("VaultMetaEdit", function(opts)
    local args = vim.split(vim.trim(opts.args), "%s+", { trimempty = true })
    if #args < 2 then
      vim.notify("Usage: VaultMetaEdit [field] [value]", vim.log.levels.WARN)
      return
    end
    local field = args[1]
    local value = table.concat(vim.list_slice(args, 2), " ")
    -- Try to coerce to number or boolean
    if value == "true" then
      M.set_field(field, true)
    elseif value == "false" then
      M.set_field(field, false)
    elseif tonumber(value) then
      M.set_field(field, tonumber(value))
    else
      M.set_field(field, value)
    end
  end, {
    nargs = "+",
    desc = "Set a frontmatter field to a value",
  })

  vim.api.nvim_create_user_command("VaultMetaCycle", function(opts)
    local field = vim.trim(opts.args)
    if field == "" then
      vim.notify("Usage: VaultMetaCycle [field]", vim.log.levels.WARN)
      return
    end
    -- Look up known cycle lists
    local known = {
      status = status_values,
      priority = priority_values,
      maturity = maturity_values,
    }
    local values = known[field]
    if not values then
      vim.notify("metaedit: no known cycle values for '" .. field .. "'", vim.log.levels.WARN)
      return
    end
    M.cycle_field(field, values)
  end, {
    nargs = 1,
    desc = "Cycle a frontmatter field through its known values",
  })

  vim.api.nvim_create_user_command("VaultMetaToggle", function(opts)
    local field = vim.trim(opts.args)
    if field == "" then
      vim.notify("Usage: VaultMetaToggle [field]", vim.log.levels.WARN)
      return
    end
    M.toggle_field(field)
  end, {
    nargs = 1,
    desc = "Toggle a boolean frontmatter field",
  })

  -- -------------------------------------------------------------------
  -- Buffer-local keymaps for markdown files
  -- -------------------------------------------------------------------
  local group = vim.api.nvim_create_augroup("VaultMetaEdit", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      local bopts = { buffer = ev.buf, silent = true }

      -- <leader>vms — cycle status
      vim.keymap.set("n", "<leader>vms", function()
        M.cycle_field("status", status_values)
      end, vim.tbl_extend("force", bopts, { desc = "Meta: cycle status" }))

      -- <leader>vmp — cycle priority
      vim.keymap.set("n", "<leader>vmp", function()
        M.cycle_field("priority", priority_values)
      end, vim.tbl_extend("force", bopts, { desc = "Meta: cycle priority" }))

      -- <leader>vmm — cycle maturity
      vim.keymap.set("n", "<leader>vmm", function()
        M.cycle_field("maturity", maturity_values)
      end, vim.tbl_extend("force", bopts, { desc = "Meta: cycle maturity" }))

      -- <leader>vmt — toggle draft
      vim.keymap.set("n", "<leader>vmt", function()
        M.toggle_field("draft")
      end, vim.tbl_extend("force", bopts, { desc = "Meta: toggle draft" }))

      -- <leader>vmf — pick and set any field
      vim.keymap.set("n", "<leader>vmf", function()
        engine.run(function()
          local field = engine.input({ prompt = "Field name: " })
          if not field or field == "" then return end
          local value = engine.input({ prompt = field .. " = " })
          if not value then return end
          -- Coerce typed input
          if value == "true" then
            M.set_field(field, true)
          elseif value == "false" then
            M.set_field(field, false)
          elseif tonumber(value) then
            M.set_field(field, tonumber(value))
          else
            M.set_field(field, value)
          end
        end)
      end, vim.tbl_extend("force", bopts, { desc = "Meta: set any field" }))
    end,
  })
end

return M
