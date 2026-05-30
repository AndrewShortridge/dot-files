--- Search history with frecency ranking.
---
--- Persists query history to .vault-search-history.json with timestamps.
--- Reuses the frecency.lua scoring algorithm to rank queries by recency
--- and frequency of use.

local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local frecency = require("andrew.vault.frecency")
local notify = require("andrew.vault.notify")

local M = {}

--- Maximum timestamps stored per query entry.
local MAX_TIMESTAMPS = 10

local store = engine.json_store(".vault-search-history.json")

---@return table<string, {timestamps: number[], type?: string}>
local function load_db()
  return store.cached_load()
end

---@param db table
local function save_db(db)
  store.cached_save(db)
end

--- Compute frecency score for a history entry.
--- Delegates to frecency.lua (shared scoring algorithm).
---@param entry {timestamps: number[]}
---@param now? number
---@return number
function M.score(entry, now)
  return frecency.score(entry, now)
end

--- Record a query execution.
---@param query string the raw query text
---@param search_type? string "advanced"|"grep"|"type"
function M.record(query, search_type)
  if not query or query == "" then return end
  local hist = config.search.history
  if hist.enabled == false then return end

  local max_entries = hist.max_entries

  local db = load_db()
  local entry = db[query] or { timestamps = {} }
  local ts = entry.timestamps or {}

  -- Debounce: skip if same query was recorded < 5 seconds ago
  if #ts > 0 and (os.time() - ts[1]) < 5 then return end

  table.insert(ts, 1, os.time())
  while #ts > MAX_TIMESTAMPS do
    table.remove(ts)
  end
  entry.timestamps = ts
  if search_type then entry.type = search_type end
  db[query] = entry

  -- Prune oldest entries if exceeding max size
  local count = vim.tbl_count(db)
  if count > max_entries then
    local all = {}
    local now = os.time()
    for q, e in pairs(db) do
      all[#all + 1] = { query = q, score = M.score(e, now) }
    end
    table.sort(all, function(a, b) return a.score > b.score end)
    -- Remove bottom 10%
    local cutoff = math.floor(max_entries * 0.9)
    for i = cutoff + 1, #all do
      db[all[i].query] = nil
    end
  end

  save_db(db)
end

--- Get all history entries sorted by frecency score (highest first).
---@return {query: string, score: number, type?: string}[]
function M.ranked()
  local db = load_db()
  local now = os.time()
  local scored = {}
  for query, entry in pairs(db) do
    scored[#scored + 1] = {
      query = query,
      score = M.score(entry, now),
      type = entry.type,
    }
  end
  table.sort(scored, function(a, b) return a.score > b.score end)
  return scored
end

--- Open fzf picker with search history sorted by frecency.
--- Selecting an entry re-executes the query.
function M.pick()
  local ranked = M.ranked()
  if #ranked == 0 then
    notify.no_search_history()
    return
  end

  local entries = {}
  local lookup = {}
  for _, item in ipairs(ranked) do
    local prefix = item.type == "advanced" and "[ADV] " or ""
    local display = prefix .. item.query
    entries[#entries + 1] = display
    lookup[display] = item
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(entries, {
    prompt = "Search history> ",
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        local item = lookup[selected[1]]
        if not item then return end
        vim.schedule(function()
          if item.type == "advanced" then
            require("andrew.vault.search").execute_advanced_query(item.query)
          else
            -- Re-execute as live grep with the query pre-filled
            local fzf2 = require("fzf-lua")
            fzf2.live_grep(
              engine.vault_fzf_opts("Vault search", {
                search = item.query,
              })
            )
          end
        end)
      end,
      -- ctrl-d: delete selected history entry
      ["ctrl-d"] = function(selected)
        if not selected or #selected == 0 then return end
        local item = lookup[selected[1]]
        if item then
          M.delete(item.query)
          notify.info("deleted from history: " .. item.query)
        end
      end,
    },
    fzf_opts = {
      ["--no-sort"] = "",  -- preserve frecency order
    },
  })
end

--- Delete a query from history.
---@param query string
function M.delete(query)
  local db = load_db()
  db[query] = nil
  save_db(db)
end

--- Clear all search history.
function M.clear()
  save_db({})
  notify.info("search history cleared")
end

function M.setup()
  local palette = require("andrew.vault.command_palette")

  vim.api.nvim_create_user_command("VaultSearchHistory", function()
    M.pick()
  end, { desc = "Browse vault search history (frecency-ranked)" })

  vim.api.nvim_create_user_command("VaultSearchHistoryClear", function()
    M.clear()
  end, { desc = "Clear vault search history" })

  -- Palette registrations
  palette.register_command("VaultSearchHistory", "Browse vault search history (frecency-ranked)", "Search", M.pick, "<leader>vfH")
  palette.register_command("VaultSearchHistoryClear", "Clear vault search history", "Search", M.clear)
end

return M
