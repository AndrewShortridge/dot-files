local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local link_utils = require("andrew.vault.link_utils")
local utils = require("andrew.vault.unlinked.utils")

local M = {}

--- Get the current note's searchable names (basename + aliases).
--- Returns nil if the buffer is not a vault file.
---@return { names: string[], path: string }|nil
function M.current_note_names()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" or not engine.is_vault_buf(0) then
    return nil
  end

  local basename = link_utils.get_basename(bufname)
  local names = { basename }

  local idx = vault_index.current()
  local entry = idx and idx:get_entry_by_abs(bufname)
  local aliases = entry and entry.aliases
  if aliases then
    for _, alias in ipairs(aliases) do
      if #alias > 0 and alias ~= entry.basename_lower then
        names[#names + 1] = alias
      end
    end
  end

  return { names = names, path = bufname }
end

--- Collect all note names and aliases from the vault index.
--- Returns a deduplicated list of { name, path } entries.
---@return { name: string, path: string }[]
function M.all_note_names()
  local idx = vault_index.current()
  if not idx then return {} end

  local entries = {}
  local seen = {}

  for _, entry in pairs(idx:snapshot_files()) do
    local name = entry.basename
    local key = entry.basename_lower
    if not seen[key] then
      seen[key] = true
      entries[#entries + 1] = { name = name, name_lower = key, path = entry.abs_path }
    end
    if entry.aliases then
      for _, alias in ipairs(entry.aliases) do
        local alias_key = alias
        if not seen[alias_key] then
          seen[alias_key] = true
          entries[#entries + 1] = { name = alias, name_lower = alias, path = entry.abs_path }
        end
      end
    end
  end

  return utils.filter_by_min_length(entries, function(e) return e.name end)
end

return M
