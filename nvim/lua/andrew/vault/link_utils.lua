local M = {}

--- Parse the inner content of a wikilink [[inner]].
--- Handles: name, name#heading, name^block, name#heading^block, name|alias, and combinations.
--- Normalizes escaped pipes (\\|).
--- @param inner string  The text between [[ and ]]
--- @return { name: string, heading: string|nil, block_id: string|nil, alias: string|nil }
function M.parse_target(inner)
  -- Normalize escaped pipes
  inner = inner:gsub("\\|", "\1PIPE\1")

  -- Extract alias (after |)
  local target_part, alias = inner:match("^(.+)|(.+)$")
  if not target_part then
    target_part = inner
  end

  -- Restore pipes in alias
  if alias then alias = alias:gsub("\1PIPE\1", "|") end
  target_part = target_part:gsub("\1PIPE\1", "|")

  -- Parse name#heading^block_id
  local name, heading, block_id

  -- Handle same-file references: #heading, ^block, #heading^block
  if target_part:sub(1, 1) == "#" then
    local rest = target_part:sub(2)
    local h, b = rest:match("^([^%^]+)%^(.+)$")
    if h then
      heading, block_id = h, b
    else
      heading = rest
    end
    name = ""
  elseif target_part:sub(1, 1) == "^" then
    block_id = target_part:sub(2)
    name = ""
  else
    -- Try all combinations
    local n, h, b = target_part:match("^([^#%^]+)#([^%^]+)%^(.+)$")
    if n then
      name, heading, block_id = n, h, b
    else
      n, b = target_part:match("^([^#%^]+)%^(.+)$")
      if n then
        name, block_id = n, b
      else
        n, h = target_part:match("^([^#%^]+)#(.+)$")
        if n then
          name, heading = n, h
        else
          name = target_part
        end
      end
    end
  end

  return {
    name = vim.trim(name or ""),
    heading = heading and vim.trim(heading) or nil,
    block_id = block_id and vim.trim(block_id) or nil,
    alias = alias and vim.trim(alias) or nil,
  }
end

--- Extract just the note name from wikilink inner content.
--- Strips heading, block_id, and alias components.
--- @param inner string
--- @return string
function M.link_name(inner)
  return M.parse_target(inner).name
end

return M
