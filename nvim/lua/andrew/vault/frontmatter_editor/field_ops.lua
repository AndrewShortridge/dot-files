local config = require("andrew.vault.config")
local fm_parser = require("andrew.vault.frontmatter_parser")
local metaedit = require("andrew.vault.metaedit")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("fm_editor")
local type_utils = require("andrew.vault.frontmatter_editor.type_utils")

local M = {}

--- Read frontmatter-relevant lines from a source buffer.
---@param source_buf number
---@return string[]
function M.read_frontmatter_lines(source_buf)
  local max = config.frontmatter.max_scan_lines
  local line_count = vim.api.nvim_buf_line_count(source_buf)
  local limit = math.min(line_count, max)
  return vim.api.nvim_buf_get_lines(source_buf, 0, limit, false)
end

--- Find the start and end line indices of a frontmatter field (1-based).
--- Returns nil, nil if the field is not found.
---@param lines string[]
---@param fm table  parsed frontmatter with start_line, end_line
---@param key string
---@return number|nil field_start
---@return number|nil field_end
local function find_field_extent(lines, fm, key)
  local field_start = nil
  local field_end = nil
  local pat = "^" .. vim.pesc(key) .. ":%s*(.*)"

  for i = fm.start_line + 1, fm.end_line - 1 do
    if not field_start then
      local raw = lines[i]:match(pat)
      if raw then
        field_start = i
        field_end = i
        for j = i + 1, fm.end_line - 1 do
          if lines[j]:match("^%s+%-") then
            field_end = j
          else
            break
          end
        end
      end
    end
  end

  return field_start, field_end
end

--- Write a field to the source buffer using metaedit.set_field.
---@param source_buf number
---@param key string
---@param value any
function M.write_field_to_source(source_buf, key, value)
  vim.api.nvim_buf_call(source_buf, function()
    metaedit.set_field(key, value)
  end)
end

--- Write a YAML list field to the source buffer.
---@param source_buf number
---@param key string
---@param items any[]
function M.set_list_field(source_buf, key, items)
  vim.api.nvim_buf_call(source_buf, function()
    local lines = M.read_frontmatter_lines(source_buf)

    local max = config.frontmatter.max_scan_lines
    local fm = fm_parser.parse_lines(lines, max)
    if not fm then
      local new_lines = { "---", key .. ":" }
      for _, item in ipairs(items) do
        new_lines[#new_lines + 1] = "  - " .. type_utils.format_yaml_value(item)
      end
      new_lines[#new_lines + 1] = "---"
      local ok, err = pcall(vim.cmd, "undojoin")
      if not ok then log.debug("undojoin before list insert: %s", err) end
      vim.api.nvim_buf_set_lines(source_buf, 0, 0, false, new_lines)
      return
    end

    local field_start, field_end = find_field_extent(lines, fm, key)

    local new_lines = { key .. ":" }
    for _, item in ipairs(items) do
      new_lines[#new_lines + 1] = "  - " .. type_utils.format_yaml_value(item)
    end

    local ok, err = pcall(vim.cmd, "undojoin")
    if not ok then log.debug("undojoin before list field write: %s", err) end
    if field_start then
      vim.api.nvim_buf_set_lines(source_buf, field_start - 1, field_end, false, new_lines)
    else
      vim.api.nvim_buf_set_lines(source_buf, fm.end_line - 1, fm.end_line - 1, false, new_lines)
    end
  end)

  notify.info(key .. " = [" .. #items .. " items]")
end

--- Remove a frontmatter field from the source buffer.
---@param source_buf number
---@param key string
function M.delete_field(source_buf, key)
  vim.api.nvim_buf_call(source_buf, function()
    local lines = M.read_frontmatter_lines(source_buf)

    local max = config.frontmatter.max_scan_lines
    local fm = fm_parser.parse_lines(lines, max)
    if not fm then return end

    local field_start, field_end = find_field_extent(lines, fm, key)

    if not field_start then
      notify.warn("field '" .. key .. "' not found")
      return
    end

    local ok, err = pcall(vim.cmd, "undojoin")
    if not ok then log.debug("undojoin before field delete: %s", err) end
    vim.api.nvim_buf_set_lines(source_buf, field_start - 1, field_end, false, {})
    notify.info("deleted " .. key)
  end)
end

return M
