local M = {}

--- Record the last search in saved_searches for the quick-save feature.
---@param query string
---@param scope string
---@param search_type? string
---@param advanced? boolean
function M.track(query, scope, search_type, advanced)
  -- Lazy-require to avoid circular dependency at load time
  require("andrew.vault.saved_searches").set_last_search(query, scope, search_type, advanced)
  -- Record in search history (non-empty queries only)
  local q = query and vim.trim(query) or ""
  if q ~= "" then
    require("andrew.vault.search_history").record(q, advanced and "advanced" or search_type)
  end
end

return M
