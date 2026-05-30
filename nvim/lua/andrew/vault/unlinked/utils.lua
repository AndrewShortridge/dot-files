local config = require("andrew.vault.config")
local engine = require("andrew.vault.engine")
local file_cache = require("andrew.vault.file_cache")

local M = {}

--- Filter items by minimum name length from config.autolink.min_name_length.
--- When `get_name` is nil each item is treated as a plain string;
--- otherwise `get_name(item)` should return the string to measure.
---@param list any[]
---@param get_name? fun(item: any): string
---@return any[]
function M.filter_by_min_length(list, get_name)
  local min_len = config.autolink.min_name_length
  local filtered = {}
  for _, item in ipairs(list) do
    local name = get_name and get_name(item) or item
    if #name >= min_len then
      filtered[#filtered + 1] = item
    end
  end
  return filtered
end

--- Group a list of result tables by their .file field.
---@param results table[] each element must have a .file field
---@param filter_fn? fun(r: table): boolean optional predicate to include an item
---@return table<string, table[]>
function M.group_by_file(results, filter_fn)
  local by_file = {}
  for _, r in ipairs(results) do
    if not filter_fn or filter_fn(r) then
      if not by_file[r.file] then by_file[r.file] = {} end
      by_file[r.file][#by_file[r.file] + 1] = r
    end
  end
  return by_file
end

--- Split a flat list into batches of at most `size` elements.
---@param list table[]
---@param size number
---@return table[][] batches
function M.batch_list(list, size)
  local batches = {}
  local current = {}
  for _, item in ipairs(list) do
    current[#current + 1] = item
    if #current >= size then
      batches[#batches + 1] = current
      current = {}
    end
  end
  if #current > 0 then
    batches[#batches + 1] = current
  end
  return batches
end

--- Find a case-insensitive name match in a line, returning match positions.
--- Searches for `name_lower` in `line_lower` and returns the first occurrence
--- whose range contains `col` (1-indexed). Returns nil if no match at col.
---@param line_lower string lowercased line text
---@param name_lower string lowercased name to find
---@param col number 1-indexed column to match against
---@return number|nil ms match start (1-indexed)
---@return number|nil me match end (1-indexed)
function M.find_name_at_col(line_lower, name_lower, col)
  local ms, me = line_lower:find(name_lower, 1, true)
  while ms do
    if ms <= col and col <= me then
      return ms, me
    end
    ms, me = line_lower:find(name_lower, ms + 1, true)
  end
  return nil, nil
end

--- Read lines from a buffer if loaded, otherwise from disk.
---@param file string absolute file path
---@return string[] lines
---@return number|nil bufnr loaded buffer number, or nil if read from disk
function M.read_lines_prefer_buffer(file)
  local bufnr = vim.fn.bufnr(file)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), bufnr
  end
  local lines = file_cache.read(file)
  return lines or {}, nil
end

return M
