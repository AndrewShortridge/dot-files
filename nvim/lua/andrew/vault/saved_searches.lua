local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local M = {}

--- Last executed search, tracked for quick-save.
---@type { query: string, scope: string, type: string }|nil
local last_search = nil

--- Built-in default searches seeded when the JSON file does not yet exist.
local defaults = {
  {
    name = "Overdue tasks",
    query = "\\[due:: .*\\].*\\[ \\]",
    scope = "all",
    type = "grep",
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
  local map = {
    all = "**/*.md",
    projects = config.dirs.projects .. "/**/*.md",
    areas = config.dirs.areas .. "/**/*.md",
    log = config.dirs.log .. "/**/*.md",
    domains = config.dirs.domains .. "/**/*.md",
    library = config.dirs.library .. "/**/*.md",
  }
  return map[scope] or "**/*.md"
end

--- Human-readable label for a scope.
---@param scope string
---@return string
local function scope_label(scope)
  local map = {
    all = "All notes",
    projects = "Projects",
    areas = "Areas",
    log = "Log",
    domains = "Domains",
    library = "Library",
  }
  return map[scope] or scope
end

-- ---------------------------------------------------------------------------
-- JSON persistence (mirrors pins.lua)
-- ---------------------------------------------------------------------------

--- Return the absolute path to the saved-searches JSON file.
---@return string
local function storage_path()
  return engine.vault_path .. "/.vault-searches.json"
end

--- Load saved searches from the JSON file.
--- Returns the built-in defaults (and writes them) when the file does not exist.
---@return table[]
local function load_searches()
  local file = io.open(storage_path(), "r")
  if not file then
    -- Seed with defaults on first use
    local f = io.open(storage_path(), "w")
    if f then
      f:write(vim.json.encode(defaults))
      f:close()
    end
    -- Return a deep copy so callers can mutate freely
    return vim.deepcopy(defaults)
  end
  local raw = file:read("*a")
  file:close()
  if raw == "" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

--- Write the searches list to the JSON file.
---@param searches table[]
local function save_searches(searches)
  local file = io.open(storage_path(), "w")
  if not file then
    vim.notify("Vault: failed to write saved-searches file", vim.log.levels.ERROR)
    return
  end
  file:write(vim.json.encode(searches))
  file:close()
end

-- ---------------------------------------------------------------------------
-- Execute a saved search
-- ---------------------------------------------------------------------------

--- Run a saved search entry via fzf-lua.
---@param entry table { name, query, scope, type }
local function execute_search(entry)
  local fzf = require("fzf-lua")
  local glob = scope_to_glob(entry.scope)
  local label = scope_label(entry.scope)

  -- Track for save_last
  last_search = { query = entry.query, scope = entry.scope, type = entry.type }

  if entry.type == "type" then
    -- Search by frontmatter note type (same pattern as search.search_by_type)
    fzf.grep({
      cwd = engine.vault_path,
      prompt = "Saved [" .. entry.name .. "]> ",
      file_icons = true,
      git_icons = false,
      search = "^type:\\s+" .. entry.query,
      no_esc = true,
      rg_opts = '--column --line-number --no-heading --color=always --smart-case --glob "' .. glob .. '"',
    })
  elseif entry.query == "" then
    -- Empty query -> live grep so the user can type interactively
    fzf.live_grep({
      cwd = engine.vault_path,
      prompt = "Saved [" .. entry.name .. " | " .. label .. "]> ",
      file_icons = true,
      git_icons = false,
      rg_opts = '--column --line-number --no-heading --color=always --smart-case --glob "' .. glob .. '"',
    })
  else
    -- Fixed query grep
    fzf.grep({
      cwd = engine.vault_path,
      prompt = "Saved [" .. entry.name .. "]> ",
      file_icons = true,
      git_icons = false,
      search = entry.query,
      no_esc = true,
      rg_opts = '--column --line-number --no-heading --color=always --smart-case --glob "' .. glob .. '"',
    })
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Save a search with the given properties.
---@param name string display name
---@param query string ripgrep pattern
---@param scope string one of "all", "projects", "areas", "log", "domains", "library"
---@param search_type? string "grep" (default) or "type"
function M.save(name, query, scope, search_type)
  if not name or name == "" then
    vim.notify("Vault: search name cannot be empty", vim.log.levels.WARN)
    return
  end
  local entry = {
    name = name,
    query = query or "",
    scope = scope or "all",
    type = search_type or "grep",
  }
  local searches = load_searches()
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
  save_searches(searches)
  vim.notify("Vault: saved search '" .. name .. "'", vim.log.levels.INFO)
end

--- List saved searches in an fzf-lua picker; selecting one executes it.
function M.list()
  local searches = load_searches()
  if #searches == 0 then
    vim.notify("Vault: no saved searches", vim.log.levels.INFO)
    return
  end

  -- Build display strings and a lookup table
  local entries = {}
  local lookup = {}
  for _, s in ipairs(searches) do
    local display = s.name
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
  local searches = load_searches()
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
    vim.notify("Vault: no saved search named '" .. name .. "'", vim.log.levels.WARN)
    return
  end
  save_searches(new)
  vim.notify("Vault: deleted saved search '" .. name .. "'", vim.log.levels.INFO)
end

--- Interactive delete via fzf-lua picker.
function M.pick_delete()
  local searches = load_searches()
  if #searches == 0 then
    vim.notify("Vault: no saved searches to delete", vim.log.levels.INFO)
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
    vim.notify("Vault: no recent search to save", vim.log.levels.WARN)
    return
  end
  engine.run(function()
    local name = engine.input({ prompt = "Save search as: " })
    if not name or name == "" then
      return
    end
    M.save(name, last_search.query, last_search.scope, last_search.type)
  end)
end

--- Allow external modules (e.g. search.lua) to record the last search.
---@param query string
---@param scope string
---@param search_type? string
function M.set_last_search(query, scope, search_type)
  last_search = { query = query or "", scope = scope or "all", type = search_type or "grep" }
end

--- Save a new search interactively (prompt for name, query, scope).
function M.save_interactive()
  engine.run(function()
    local name = engine.input({ prompt = "Search name: " })
    if not name or name == "" then
      return
    end

    local query = engine.input({ prompt = "Query pattern: " })
    if not query then
      return
    end

    local scopes = { "all", "projects", "areas", "log", "domains", "library" }
    local scope = engine.select(scopes, { prompt = "Search scope" })
    if not scope then
      return
    end

    local types = { "grep", "type" }
    local search_type = engine.select(types, { prompt = "Search type" })
    if not search_type then
      return
    end

    M.save(name, query, scope, search_type)
  end)
end

-- ---------------------------------------------------------------------------
-- Setup: commands and keymaps
-- ---------------------------------------------------------------------------

function M.setup()
  vim.api.nvim_create_user_command("VaultSearchSave", function(cmd_opts)
    local name = cmd_opts.args ~= "" and cmd_opts.args or nil
    if name then
      if not last_search then
        vim.notify("Vault: no recent search to save", vim.log.levels.WARN)
        return
      end
      M.save(name, last_search.query, last_search.scope, last_search.type)
    else
      M.save_last()
    end
  end, { nargs = "?", desc = "Save last vault search (optionally provide a name)" })

  vim.api.nvim_create_user_command("VaultSearchList", function()
    M.list()
  end, { desc = "Pick and execute a saved vault search" })

  vim.api.nvim_create_user_command("VaultSearchDelete", function()
    M.pick_delete()
  end, { desc = "Pick and delete a saved vault search" })

  -- Find group: <leader>vf
  vim.keymap.set("n", "<leader>vfS", function()
    M.list()
  end, { desc = "Find: saved searches", silent = true })
end

return M
