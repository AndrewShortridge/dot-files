local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local notify = require("andrew.vault.notify")
local pat = require("andrew.vault.patterns")

local M = {}

--- Maximum access timestamps stored per file.
local MAX_TIMESTAMPS = 10

--- Recency weight buckets: {max_age_hours, weight}.
local BUCKETS = {
  { 1, 100 },   -- last hour
  { 24, 80 },   -- last day
  { 72, 60 },   -- last 3 days
  { 168, 40 },  -- last week
  { 336, 20 },  -- last 2 weeks
  { 720, 10 },  -- last month
}
local FLOOR_WEIGHT = 5

local store = engine.json_store(".vault-frecency.json")

---@return table<string, {timestamps: number[]}>
local function load_db()
  return store.cached_load()
end

---@param db table
local function save_db(db)
  store.cached_save(db)
end

--- Compute recency weight for a single timestamp.
---@param ts number epoch seconds
---@param now number epoch seconds
---@return number
local function recency_weight(ts, now)
  local age_hours = (now - ts) / 3600
  for _, bucket in ipairs(BUCKETS) do
    if age_hours < bucket[1] then
      return bucket[2]
    end
  end
  return FLOOR_WEIGHT
end

--- Compute the frecency score for a database entry.
--- Score = sum of recency_weight for each stored timestamp.
--- A file accessed 10 times in the last hour scores 1000.
--- A file accessed once a month ago scores 10.
---@param entry {timestamps: number[]}
---@param now? number
---@return number
function M.score(entry, now)
  now = now or os.time()
  local total = 0
  for _, ts in ipairs(entry.timestamps or {}) do
    total = total + recency_weight(ts, now)
  end
  return total
end

local function scored_entries()
  local db = load_db()
  local vault = engine.vault_path
  local now = os.time()
  local scored = {}
  for rel, entry in pairs(db) do
    local abs = vault .. "/" .. rel
    if vim.fn.filereadable(abs) == 1 then
      scored[#scored + 1] = { path = rel, score = M.score(entry, now) }
    end
  end
  table.sort(scored, function(a, b) return a.score > b.score end)
  return scored
end

--- Record an access for a vault file.
---@param abs_path string absolute file path
function M.record(abs_path)
  if not engine.is_vault_path(abs_path) then return end
  local rel = engine.vault_relative(abs_path)
  if not rel:match(pat.MD_EXTENSION) then return end

  local db = load_db()
  local entry = db[rel] or { timestamps = {} }
  local ts = entry.timestamps or {}

  -- Debounce: skip if last access was < 5 seconds ago
  if #ts > 0 and (os.time() - ts[1]) < 5 then return end

  table.insert(ts, 1, os.time())
  while #ts > MAX_TIMESTAMPS do
    table.remove(ts)
  end
  entry.timestamps = ts
  db[rel] = entry
  save_db(db)
end

--- Get all vault markdown files sorted by frecency score.
--- Tracked files appear first (highest score first), then untracked files alphabetically.
---@return string[] relative paths
function M.ranked_files()
  local scored = scored_entries()

  local result = {}
  local seen = {}
  for _, item in ipairs(scored) do
    result[#result + 1] = item.path
    seen[item.path] = true
  end

  -- Append remaining vault files alphabetically, skipping hidden dirs
  -- Prefer vault index (in-memory) over filesystem glob
  local idx = vault_index.current()
  local all_rels
  if idx and idx:is_ready() then
    all_rels = {}
    for rel_path in pairs(idx:snapshot_files()) do
      all_rels[#all_rels + 1] = rel_path
    end
  else
    -- Fallback: filesystem glob when index not ready
    local all_files = vim.fn.globpath(engine.vault_path, "**/*.md", false, true)
    all_rels = {}
    for _, f in ipairs(all_files) do
      all_rels[#all_rels + 1] = engine.vault_relative(f)
    end
  end
  table.sort(all_rels)
  for _, rel in ipairs(all_rels) do
    if not rel:match("^%.") and not rel:match("/%.") and not seen[rel] then
      result[#result + 1] = rel
    end
  end

  return result
end

--- Get only tracked files sorted by frecency score.
---@return string[] relative paths
function M.frequent_files()
  local scored = scored_entries()

  local result = {}
  for _, item in ipairs(scored) do
    result[#result + 1] = item.path
  end
  return result
end

--- Open fzf-lua with all vault files sorted by frecency.
function M.files()
  local ranked = M.ranked_files()
  if #ranked == 0 then
    notify.info("no files found")
    return
  end
  local fzf = require("fzf-lua")
  fzf.fzf_exec(ranked, engine.vault_fzf_opts("Vault files", {
    previewer = "builtin",
    actions = engine.vault_fzf_actions(),
  }))
end

--- Open fzf-lua with only tracked files, sorted by frecency.
function M.frequent()
  local files = M.frequent_files()
  if #files == 0 then
    notify.info("no recent notes in frecency database")
    return
  end
  local fzf = require("fzf-lua")
  fzf.fzf_exec(files, engine.vault_fzf_opts("Recent vault notes", {
    previewer = "builtin",
    actions = engine.vault_fzf_actions(),
  }))
end

function M.setup()
  -- BufEnter autocmd removed: now dispatched via event_dispatch.lua

  vim.api.nvim_create_user_command("VaultFiles", function()
    M.files()
  end, { desc = "Find vault files ranked by frecency" })

  -- Palette registrations
  local palette = require("andrew.vault.command_palette")

  palette.register_command("VaultFiles", "Find vault files ranked by frecency", "Navigate", M.files)
end

--- Called by event_dispatch.lua on BufEnter for vault markdown buffers.
--- Defers the frecency write to IDLE priority (no user-visible effect).
--- @param ctx { bufnr: number, file: string, is_vault_md: boolean }
function M.on_buf_enter(ctx)
  if ctx.file ~= "" then
    local scheduler = require("andrew.vault.work_scheduler")
    scheduler.schedule(scheduler.IDLE, function()
      M.record(ctx.file)
    end, { domain = "frecency", label = "record" })
  end
end

return M
