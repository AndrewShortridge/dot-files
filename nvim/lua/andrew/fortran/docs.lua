-- Fortran custom documentation module
-- Provides hover documentation for Fortran keywords from custom snippets
local M = {}

-- Cache for loaded documentation
M.docs = nil

-- ---------------------------------------------------------------------------
-- Structured-entry rendering
-- ---------------------------------------------------------------------------

--- Order the keys of an options table by where each first appears in `hint`.
---
--- JSON objects decode to Lua tables, which have no order, so the argument
--- order of a rendered Options section would otherwise be whatever `pairs`
--- happened to yield -- different between runs, and wrong for any routine
--- whose arguments are not in alphabetical order (`shape(source, kind)` sorts
--- to `kind, source`). Reading the order out of the synopsis restores it.
---@param opts table<string, string>
---@param hint string text to take the ordering from
---@return string[]
local function ordered_keys(opts, hint)
  local keys = {}
  for k in pairs(opts) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local pos = {}
  for i, k in ipairs(keys) do
    -- Whole-word search, so `dim` does not match inside `dimension`.
    local at = hint and hint:find("[^%w_]" .. k .. "[^%w_]")
    pos[k] = at or (1e9 + i) -- unfound keys keep their alphabetical order, last
  end
  table.sort(keys, function(a, b)
    if pos[a] ~= pos[b] then
      return pos[a] < pos[b]
    end
    return a < b
  end)
  return keys
end

--- Render a structured documentation entry to the markdown every other entry
--- in the file already uses.
---
--- Five entries -- `size`, `shape`, `lbound`, `ubound`, `allocated` -- are
--- stored as JSON OBJECTS rather than markdown strings. Every consumer here
--- assumed a string: the hover handler passes the value straight to
--- `vim.split`, which raised `s: expected string, got table` and put an error
--- on screen instead of a doc. Hovering `size` is not an edge case -- it is
--- one of the most used intrinsics in Fortran, and it threw.
---
--- Normalizing here rather than at the hover site fixes every consumer at
--- once, including the blink completion source, which reads `docs.load()`
--- directly and never goes through `get`.
---@param entry string|table
---@return string|nil
function M.render(entry)
  if type(entry) == "string" then
    return entry
  end
  if type(entry) ~= "table" then
    return nil
  end

  local out = {}
  local function section(title, body)
    if body and body ~= "" then
      out[#out + 1] = "### **" .. title .. "**\n\n" .. body
    end
  end

  if entry.name then
    out[#out + 1] = "### **Name**\n\n" .. entry.name
  end

  local syn = entry.synopsis
  local syn_text
  if type(syn) == "table" then
    local parts = {}
    for _, k in ipairs({ "usage", "interface" }) do
      if syn[k] and syn[k] ~= "" then
        parts[#parts + 1] = syn[k]
      end
    end
    syn_text = table.concat(parts, "\n\n")
  elseif type(syn) == "string" then
    syn_text = syn
  end
  section("Synopsis", syn_text)

  if type(entry.characteristics) == "table" then
    local lines = {}
    for _, c in ipairs(entry.characteristics) do
      lines[#lines + 1] = " - " .. c
    end
    section("Characteristics", table.concat(lines, "\n"))
  end

  section("Description", entry.description)

  if type(entry.options) == "table" then
    local lines = {}
    for _, k in ipairs(ordered_keys(entry.options, syn_text or "")) do
      lines[#lines + 1] = "- **" .. k .. "**\n  : " .. tostring(entry.options[k])
    end
    section("Options", table.concat(lines, "\n\n"))
  end

  section("Result", entry.result)

  if type(entry.examples) == "table" then
    local parts = {}
    if entry.examples.code and entry.examples.code ~= "" then
      parts[#parts + 1] = "```fortran\n" .. entry.examples.code .. "\n```"
    end
    if entry.examples.results and entry.examples.results ~= "" then
      parts[#parts + 1] = entry.examples.results
    end
    section("Examples", table.concat(parts, "\n\n"))
  elseif type(entry.examples) == "string" then
    section("Examples", entry.examples)
  end

  section("Standard", entry.standard)

  if type(entry.see_also) == "table" then
    section("See Also", table.concat(entry.see_also, "\n\n"))
  elseif type(entry.see_also) == "string" then
    section("See Also", entry.see_also)
  end

  if #out == 0 then
    return nil
  end
  return table.concat(out, "\n\n") .. "\n"
end

-- Load documentation from JSON file
function M.load()
  if M.docs then
    return M.docs
  end

  -- stdpath("config"), not a hardcoded ~/.config/nvim: the two are only the
  -- same while $XDG_CONFIG_HOME and $NVIM_APPNAME are both unset. Under a
  -- test harness, a second nvim profile, or anyone who moves their config,
  -- the literal path silently misses and every Fortran hover falls back to
  -- "Fortran docs not found" plus an empty table.
  local path = vim.fn.stdpath("config") .. "/snippets/fortran-docs.json"
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

  -- Normalize structured entries once, so the cache holds only strings and no
  -- consumer has to type-check what it got.
  for k, v in pairs(decoded) do
    if type(v) ~= "string" then
      decoded[k] = M.render(v)
    end
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
