local M = {}

local vi = require("andrew.vault.vault_index")

--- Collect all distinct values for a given frontmatter field across the vault.
---@param field_name string
---@return string[]
function M.vault_field_values(field_name)
  local idx = vi.current()
  if not idx or not idx:is_ready() then return {} end

  local seen = {}
  local values = {}
  for _, entry in pairs(idx:snapshot_files()) do
    local fm = entry.frontmatter
    if fm and fm[field_name] ~= nil then
      local v = fm[field_name]
      if type(v) == "table" then
        for _, item in ipairs(v) do
          local s = tostring(item)
          if not seen[s] then
            seen[s] = true
            values[#values + 1] = s
          end
        end
      else
        local s = tostring(v)
        if not seen[s] then
          seen[s] = true
          values[#values + 1] = s
        end
      end
    end
  end
  table.sort(values)
  return values
end

--- Collect all distinct frontmatter field names across the vault.
--- Delegates to the generation-cached vault index method.
---@return string[]
function M.vault_field_names()
  local idx = vi.current()
  if not idx or not idx:is_ready() then return {} end
  return idx:all_frontmatter_keys()
end

return M
