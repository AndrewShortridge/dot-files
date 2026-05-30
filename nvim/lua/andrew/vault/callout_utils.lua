local M = {}

--- Parse a callout header line into its components.
---@param line string
---@return string|nil type   e.g. "NOTE" (uppercased)
---@return string|nil suffix e.g. "-" or "+"
---@return string title      text after the suffix (may be empty)
function M.parse_header(line)
  local ctype, suffix, title = line:match("^>%s*%[!([%w_]+)%]([%-+])%s*(.*)")
  if not ctype then
    ctype, title = line:match("^>%s*%[!([%w_]+)%]%s*(.*)")
    if ctype then
      return ctype:upper(), nil, vim.trim(title or "")
    end
    return nil, nil, ""
  end
  return ctype:upper(), suffix, vim.trim(title or "")
end

--- Scan lines for callout block boundaries.
--- Pure function — operates on string arrays, no buffer or vim API needed.
---@param lines string[]
---@return table[] blocks  { { start_line: number, end_line: number, ctype: string, suffix: string|nil, title: string, content_lines: string[] }, ... }
function M.scan_blocks(lines)
  local blocks = {}
  local i = 1
  while i <= #lines do
    local ctype, suffix, title = M.parse_header(lines[i])
    if ctype then
      local start = i
      local content = {}
      i = i + 1
      while i <= #lines and lines[i]:match("^>") do
        content[#content + 1] = lines[i]
        i = i + 1
      end
      blocks[#blocks + 1] = {
        start_line = start,
        end_line = i - 1,
        ctype = ctype,
        suffix = suffix,
        title = title,
        content_lines = content,
      }
    else
      i = i + 1
    end
  end
  return blocks
end

return M
