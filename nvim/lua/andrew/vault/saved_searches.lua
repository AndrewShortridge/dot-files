local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")

local M = {}

local function notify_no_recent_search()
  notify.warn("no recent search to save")
end

--- Last executed search, tracked for quick-save.
---@type { query: string, scope: string, type: string, advanced?: boolean }|nil
local last_search = nil

--- Built-in default searches seeded when the JSON file does not yet exist.
local defaults = {
  {
    name = "Overdue tasks",
    query = 'task-todo:"" task-due:<today',
    scope = "all",
    type = "advanced",
    advanced = true,
  },
  {
    name = "Due this week",
    query = 'task-todo:"" task-due:this-week',
    scope = "all",
    type = "advanced",
    advanced = true,
  },
  {
    name = "High priority open",
    query = 'task-todo:"" task-priority:<=2',
    scope = "all",
    type = "advanced",
    advanced = true,
  },
  {
    name = "Recent literature",
    query = "",
    scope = "library",
    type = "grep",
  },
  {
    name = "Open tasks",
    query = "- \\[ \\]",
    scope = "all",
    type = "grep",
  },
}

-- ---------------------------------------------------------------------------
-- Scope helpers
-- ---------------------------------------------------------------------------

--- Map a scope name to a glob pattern for rg.
---@param scope string
---@return string glob
local function scope_to_glob(scope)
  return config.scope_glob(scope) or "**/*.md"
end

--- Human-readable label for a scope.
---@param scope string
---@return string
local function scope_label(scope)
  return config.scope_label(scope) or scope
end

local store = engine.json_store(".vault-searches.json", defaults)

-- ---------------------------------------------------------------------------
-- Execute a saved search
-- ---------------------------------------------------------------------------

--- Run a saved search entry via fzf-lua.
---@param entry table { name, query, scope, type, advanced? }
local function execute_search(entry)
  local fzf = require("fzf-lua")
  local glob = scope_to_glob(entry.scope)
  local label = scope_label(entry.scope)

  -- Track for save_last
  last_search = { query = entry.query, scope = entry.scope, type = entry.type, advanced = entry.advanced }

  -- Advanced search dispatch
  if entry.advanced then
    require("andrew.vault.search").execute_advanced_query(entry.query)
    return
  end

  if entry.type == "type" then
    -- Search by frontmatter note type (same pattern as search.search_by_type)
    fzf.grep(engine.vault_fzf_opts("Saved [" .. entry.name .. "]", {
      search = "^type:\\s+" .. entry.query,
      no_esc = true,
      rg_opts = engine.rg_base_opts(glob),
    }))
  elseif entry.query == "" then
    -- Empty query -> live grep so the user can type interactively
    fzf.live_grep(engine.vault_fzf_opts("Saved [" .. entry.name .. " | " .. label .. "]", {
      rg_opts = engine.rg_base_opts(glob),
    }))
  else
    -- Fixed query grep
    fzf.grep(engine.vault_fzf_opts("Saved [" .. entry.name .. "]", {
      search = entry.query,
      no_esc = true,
      rg_opts = engine.rg_base_opts(glob),
    }))
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Save a search with the given properties.
---@param name string display name
---@param query string ripgrep pattern or advanced query string
---@param scope string one of "all", "projects", "areas", "log", "domains", "library"
---@param search_type? string "grep" (default), "type", or "advanced"
---@param advanced? boolean true for advanced search queries
function M.save(name, query, scope, search_type, advanced)
  if not name or name == "" then
    notify.warn("search name cannot be empty")
    return
  end
  local entry = {
    name = name,
    query = query or "",
    scope = scope or "all",
    type = search_type or "grep",
  }
  -- Only include advanced flag when true (omit from JSON when false)
  if advanced then
    entry.advanced = true
  end
  local searches = store.load()
  -- Replace if a search with the same name exists
  local replaced = false
  for i, s in ipairs(searches) do
    if s.name == name then
      searches[i] = entry
      replaced = true
      break
    end
  end
  if not replaced then
    searches[#searches + 1] = entry
  end
  -- Defer persistence to IDLE (no user-visible urgency)
  local scheduler = require("andrew.vault.work_scheduler")
  scheduler.schedule(scheduler.IDLE, function()
    store.save(searches)
  end, { domain = "saved-searches", label = "save" })
  notify.info("saved search '" .. name .. "'")
end

--- List saved searches in an fzf-lua picker; selecting one executes it.
function M.list()
  local searches = store.load()
  if #searches == 0 then
    notify.info("no saved searches")
    return
  end

  -- Build display strings and a lookup table
  local entries = {}
  local lookup = {}
  for _, s in ipairs(searches) do
    local prefix = s.advanced and "[ADV] " or ""
    local display = prefix .. s.name
      .. "  ["
      .. scope_label(s.scope)
      .. "]"
      .. (s.query ~= "" and ("  " .. s.query) or "")
    entries[#entries + 1] = display
    lookup[display] = s
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(entries, {
    prompt = "Saved searches> ",
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then
          return
        end
        local entry = lookup[selected[1]]
        if entry then
          execute_search(entry)
        end
      end,
    },
  })
end

--- Delete a saved search by name.
---@param name string
function M.delete(name)
  local searches = store.load()
  local new = {}
  local found = false
  for _, s in ipairs(searches) do
    if s.name == name then
      found = true
    else
      new[#new + 1] = s
    end
  end
  if not found then
    notify.warn("no saved search named '" .. name .. "'")
    return
  end
  -- Defer persistence to IDLE (no user-visible urgency)
  local scheduler = require("andrew.vault.work_scheduler")
  scheduler.schedule(scheduler.IDLE, function()
    store.save(new)
  end, { domain = "saved-searches", label = "delete" })
  notify.info("deleted saved search '" .. name .. "'")
end

--- Interactive delete via fzf-lua picker.
function M.pick_delete()
  local searches = store.load()
  if #searches == 0 then
    notify.info("no saved searches to delete")
    return
  end

  local names = {}
  for _, s in ipairs(searches) do
    names[#names + 1] = s.name
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(names, {
    prompt = "Delete saved search> ",
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then
          return
        end
        M.delete(selected[1])
      end,
    },
  })
end

--- Save the most recently executed search, prompting for a name.
function M.save_last()
  if not last_search then
    notify_no_recent_search()
    return
  end
  engine.run(function()
    local name = engine.input({ prompt = "Save search as: " })
    if not name or name == "" then
      return
    end
    M.save(name, last_search.query, last_search.scope, last_search.type, last_search.advanced)
  end)
end

--- Allow external modules (e.g. search.lua) to record the last search.
---@param query string
---@param scope string
---@param search_type? string
---@param advanced? boolean
function M.set_last_search(query, scope, search_type, advanced)
  last_search = {
    query = query or "",
    scope = scope or "all",
    type = search_type or "grep",
    advanced = advanced or nil,
  }
end

-- ---------------------------------------------------------------------------
return M
