local M = {}

local config = require("andrew.vault.config")
local pat = require("andrew.vault.patterns")
local file_cache = require("andrew.vault.file_cache")


--- Parse a scalar YAML value string into a typed Lua value.
--- Handles: booleans, numbers, quoted strings, wikilinks, bare strings.
--- @param raw string
--- @return any
function M.parse_value(raw)
  if raw == nil or raw == "" then return "" end
  raw = vim.trim(raw)
  -- Booleans
  if raw == "true" then return true end
  if raw == "false" then return false end
  -- Numbers
  local num = tonumber(raw)
  if num then return num end
  -- Quoted strings (double or single, with escape handling)
  local dq = raw:match('^"(.*)"$')
  if dq then return dq:gsub('\\"', '"') end
  local sq = raw:match("^'(.*)'$")
  if sq then return sq:gsub("''", "'") end
  -- Wikilink
  local wl = raw:match(pat.WIKILINK_EXACT)
  if wl then return wl end
  -- Bare string
  return raw
end

--- Parse frontmatter from an array of lines.
--- Expects lines[1] == "---". Parses until closing "---".
--- @param lines string[]  Array of file/buffer lines
--- @param max_lines? number  Max lines to scan
--- @return { start_line: number, end_line: number, fields: table<string, any> }|nil
function M.parse_lines(lines, max_lines)
  max_lines = max_lines or config.frontmatter.max_scan_lines
  if #lines == 0 or lines[1] ~= "---" then return nil end

  local fields = {}
  local current_key = nil
  local current_list = nil

  for i = 2, math.min(#lines, max_lines) do
    local line = lines[i]

    -- Closing delimiter
    if line == "---" or line == "..." then
      -- Flush any pending list
      if current_key and current_list then
        fields[current_key] = current_list
      end
      return { start_line = 1, end_line = i, fields = fields }
    end

    -- List item (indented "- value")
    local list_item = line:match("^%s+-%s+(.+)$")
    if list_item and current_key then
      if not current_list then current_list = {} end
      current_list[#current_list + 1] = M.parse_value(list_item)
      goto continue
    end

    -- Top-level key: value
    local key, val = line:match(pat.FM_KEY_VALUE)
    if key then
      -- Flush previous list
      if current_key and current_list then
        fields[current_key] = current_list
      end
      current_key = key
      current_list = nil

      val = vim.trim(val)
      if val == "" then
        -- Key with no inline value — expect block list below
        current_list = {}
      else
        -- Check for inline array [a, b, c]
        local inner = val:match("^%[(.*)%]$")
        if inner then
          local items = {}
          for item in inner:gmatch(pat.CSV_ITEM) do
            items[#items + 1] = M.parse_value(vim.trim(item))
          end
          fields[key] = items
          current_key = nil
        else
          fields[key] = M.parse_value(val)
          current_key = nil
        end
      end
    end

    ::continue::
  end

  -- Unclosed frontmatter
  return nil
end

--- Parse frontmatter from a buffer.
--- @param bufnr number  Buffer number
--- @param max_lines? number
--- @return { start_line: number, end_line: number, fields: table<string, any> }|nil
function M.parse_buffer(bufnr, max_lines)
  max_lines = max_lines or config.frontmatter.max_scan_lines
  local n = math.min(vim.api.nvim_buf_line_count(bufnr), max_lines)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)
  return M.parse_lines(lines, max_lines)
end

--- Get a single field value from buffer frontmatter.
--- @param bufnr number
--- @param field string
--- @return any|nil
function M.buf_field(bufnr, field)
  local fm = M.parse_buffer_cached(bufnr)
  if not fm then return nil end
  return fm.fields[field]
end

--- Get a single field value from a file's frontmatter.
--- @param filepath string
--- @param field string
--- @return any|nil
function M.file_field(filepath, field)
  local max_lines = config.frontmatter.max_scan_lines
  local lines = file_cache.read(filepath, max_lines)
  if not lines or #lines == 0 then return nil end
  local fm = M.parse_lines(lines, max_lines)
  if not fm then return nil end
  return fm.fields[field]
end

-- Memoized frontmatter parse — cached per changedtick
local memo = require("andrew.vault.memoize")
local _cached_parse = memo.new(memo.changedtick, function(bufnr)
  return M.parse_buffer(bufnr)
end, "frontmatter_parse")
memo.register_buf_cleanup(_cached_parse)

--- Cached frontmatter parse — returns parsed frontmatter or nil.
---@param bufnr number
---@return { start_line: number, end_line: number, fields: table<string, any> }|nil
function M.parse_buffer_cached(bufnr)
  return _cached_parse:get(bufnr)
end

--- Memoized frontmatter boundary — derives from _cached_parse to avoid redundant
--- scanning. Returns: false (no FM), nil (unclosed FM), or number (1-indexed
--- closing line index).
local _cached_boundary = memo.new(memo.changedtick, function(bufnr)
  local fm = _cached_parse:get(bufnr)
  if fm then return fm.end_line end -- closed FM: 1-indexed closing line
  -- fm is nil — either no FM or unclosed FM. Check first line to distinguish.
  local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
  if not first or first ~= "---" then return false end -- no FM at all
  return nil -- unclosed FM (user still typing)
end, "frontmatter_boundary")
memo.register_buf_cleanup(_cached_boundary)

--- Check if a 0-indexed buffer row is inside frontmatter.
--- Returns true for rows between (exclusive of) opening --- and up to closing ---.
--- Also returns true when frontmatter is unclosed (user still typing).
--- @param bufnr number
--- @param row number  0-indexed row
--- @return boolean
function M.cursor_in_frontmatter(bufnr, row)
  local end_line = _cached_boundary:get(bufnr)
  -- end_line == false means no frontmatter at all
  if end_line == false then return false end
  if row <= 0 then return false end
  -- end_line == nil means unclosed frontmatter (still typing)
  if end_line == nil then return true end
  return row < end_line
end

return M
