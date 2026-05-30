--- Shared text/string utilities for vault modules.

local M = {}

--- Fast display-width measurement.
--- Uses `#s` for pure-ASCII strings (no multibyte or tab characters),
--- falling back to `vim.fn.strdisplaywidth()` otherwise.
---@param s string
---@return number
function M.display_width(s)
  if not s:find("[\128-\255\t]") then
    return #s
  end
  return vim.fn.strdisplaywidth(s)
end

--- Compute the maximum display width across a list of strings.
---@param lines string[]
---@return number
function M.max_display_width(lines)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, M.display_width(l))
  end
  return width
end

--- Pad a string with trailing spaces to reach the given display width.
--- Returns the string unchanged if it is already at least `width` columns.
---@param s string
---@param width number
---@return string
function M.pad(s, width)
  local current = M.display_width(s)
  if current >= width then
    return s
  end
  return s .. string.rep(" ", width - current)
end

--- Normalize CRLF and bare CR line endings to LF.
---@param content string
---@return string
function M.normalize_line_endings(content)
  return content:gsub("\r\n", "\n"):gsub("\r", "\n")
end

--- Split content string into lines, normalizing CRLF/CR line endings.
---@param content string
---@return string[]
function M.split_lines(content)
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = {}
  for line in (content .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  if #lines > 0 and lines[#lines] == "" and not content:match("\n$") then
    lines[#lines] = nil
  end
  return lines
end

return M
