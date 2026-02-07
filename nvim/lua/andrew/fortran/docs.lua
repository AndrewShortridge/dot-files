-- Fortran custom documentation module
-- Provides hover documentation for Fortran keywords from custom snippets
local M = {}

-- Cache for loaded documentation
M.docs = nil

-- Load documentation from JSON file
function M.load()
  if M.docs then
    return M.docs
  end

  local path = vim.fn.expand("~/.config/nvim/snippets/fortran-docs.json")
  local file = io.open(path, "r")
  if not file then
    vim.notify("Fortran docs not found: " .. path, vim.log.levels.WARN)
    M.docs = {}
    return M.docs
  end

  local content = file:read("*a")
  file:close()

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or not decoded then
    vim.notify("Failed to parse Fortran docs JSON", vim.log.levels.WARN)
    M.docs = {}
    return M.docs
  end

  M.docs = decoded
  return M.docs
end

-- Lookup documentation for a keyword (case-insensitive)
function M.get(keyword)
  local docs = M.load()
  if not keyword or keyword == "" then
    return nil
  end

  -- Try exact match first, then lowercase, then uppercase
  return docs[keyword] or docs[keyword:lower()] or docs[keyword:upper()]
end

-- Reload documentation (useful after updating fortran-docs.json)
function M.reload()
  M.docs = nil
  return M.load()
end

-- Get list of all documented keywords
function M.keywords()
  local docs = M.load()
  local keys = {}
  for k, _ in pairs(docs) do
    table.insert(keys, k)
  end
  return keys
end

return M
