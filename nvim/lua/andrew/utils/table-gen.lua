--- Markdown table generation utility.
--- Pure function: returns a list of strings, no side effects.

local M = {}

--- Map a single alignment character to a separator cell.
--- @param char string  "l", "c", "r", or "-"
--- @param width number  Minimum content width (not counting outer pipes/spaces)
--- @return string  The separator cell content (e.g., ":---:", "----", "---:")
local function align_separator(char, width)
  local min_dashes = math.max(width, 3)
  if char == "c" then
    return ":" .. string.rep("-", min_dashes - 2) .. ":"
  elseif char == "r" then
    return string.rep("-", min_dashes - 1) .. ":"
  else
    -- "l" or default: plain dashes (no colon = left-aligned by convention)
    return string.rep("-", min_dashes)
  end
end

--- Generate a markdown table as a list of strings.
--- @param cols number  Number of columns (>= 1)
--- @param rows number  Number of data rows (>= 0; 0 = header + separator only)
--- @param headers? string[]  Optional header names (defaults to "Header 1", etc.)
--- @param alignments? string  Optional pipe-delimited alignment string (e.g., "l|c|r")
--- @return string[]  Lines of the generated table
function M.generate(cols, rows, headers, alignments)
  cols = math.max(1, math.floor(cols))
  rows = math.max(0, math.floor(rows))

  -- Build header names
  local hdrs = {}
  for c = 1, cols do
    hdrs[c] = (headers and headers[c] and headers[c] ~= "")
      and headers[c]
      or ("Header " .. c)
  end

  -- Parse alignment specifiers
  local aligns = {}
  if alignments and alignments ~= "" then
    for spec in alignments:gmatch("[^|]+") do
      aligns[#aligns + 1] = spec:match("^%s*(.-)%s*$"):sub(1, 1):lower()
    end
  end

  -- Compute column widths: max of header text and minimum separator width (3)
  local widths = {}
  for c = 1, cols do
    widths[c] = math.max(#hdrs[c], 3)
  end

  -- Build header row
  local header_cells = {}
  for c = 1, cols do
    header_cells[c] = " " .. hdrs[c] .. string.rep(" ", widths[c] - #hdrs[c]) .. " "
  end
  local header_line = "|" .. table.concat(header_cells, "|") .. "|"

  -- Build separator row
  local sep_cells = {}
  for c = 1, cols do
    local a = aligns[c] or "-"
    sep_cells[c] = " " .. align_separator(a, widths[c]) .. " "
  end
  local sep_line = "|" .. table.concat(sep_cells, "|") .. "|"

  -- Build data rows
  local empty_cells = {}
  for c = 1, cols do
    empty_cells[c] = " " .. string.rep(" ", widths[c]) .. " "
  end
  local empty_line = "|" .. table.concat(empty_cells, "|") .. "|"

  -- Assemble lines
  local lines = { header_line, sep_line }
  for _ = 1, rows do
    lines[#lines + 1] = empty_line
  end

  return lines
end

--- Parse a dimension string like "3x4" into cols, rows.
--- @param dim string  Dimension string (e.g., "3x4", "5X2")
--- @return number? cols, number? rows  Parsed values, or nil if invalid
function M.parse_dimensions(dim)
  local c, r = dim:match("^(%d+)[xX](%d+)$")
  if c and r then
    return tonumber(c), tonumber(r)
  end
  return nil, nil
end

--- Parse a pipe-delimited header string into a list of names.
--- @param header_str string  e.g., "Name|Age|City"
--- @return string[]
function M.parse_headers(header_str)
  local headers = {}
  for name in header_str:gmatch("[^|]+") do
    headers[#headers + 1] = name:match("^%s*(.-)%s*$") -- trim whitespace
  end
  return headers
end

return M
