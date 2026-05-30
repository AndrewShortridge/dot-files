--- Shared sort utilities for vault modules.
local M = {}

--- Sort a list of items by name (case-insensitive) using Schwartzian transform.
--- Items must have a `.name` field. Sorts in-place and returns the list.
---@param list table[]
---@return table[]
function M.sort_by_name(list)
  for _, item in ipairs(list) do item._sort_key = item.name:lower() end
  table.sort(list, function(a, b) return a._sort_key < b._sort_key end)
  for _, item in ipairs(list) do item._sort_key = nil end
  return list
end

return M
