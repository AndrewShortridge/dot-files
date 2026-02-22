local engine = require("andrew.vault.engine")

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

-- In-memory cache (invalidated on vault switch)
local _db = nil
local _db_vault = nil

---@return string
local function db_path()
  return engine.vault_path .. "/.vault-frecency.json"
end

---@return table<string, {timestamps: number[]}>
local function load_db()
  if _db and _db_vault == engine.vault_path then
    return _db
  end
  _db_vault = engine.vault_path
  local file = io.open(db_path(), "r")
  if not file then
    _db = {}
    return _db
  end
  local raw = file:read("*a")
  file:close()
  if raw == "" then
    _db = {}
    return _db
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    _db = {}
    return _db
  end
  _db = decoded
  return _db
end

---@param db table
local function save_db(db)
  _db = db
  _db_vault = engine.vault_path
  local file = io.open(db_path(), "w")
  if not file then return end
  file:write(vim.json.encode(db))
  file:close()
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

--- Record an access for a vault file.
---@param abs_path string absolute file path
function M.record(abs_path)
  local vault = engine.vault_path
  if abs_path:sub(1, #vault) ~= vault then return end
  local rel = abs_path:sub(#vault + 2)
  if not rel:match("%.md$") then return end

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
  local db = load_db()
  local vault = engine.vault_path
  local now = os.time()

  -- Score tracked files
  local scored = {}
  for rel, entry in pairs(db) do
    local abs = vault .. "/" .. rel
    if vim.fn.filereadable(abs) == 1 then
      scored[#scored + 1] = { path = rel, score = M.score(entry, now) }
    end
  end
  table.sort(scored, function(a, b) return a.score > b.score end)

  local result = {}
  local seen = {}
  for _, item in ipairs(scored) do
    result[#result + 1] = item.path
    seen[item.path] = true
  end

  -- Append remaining vault files alphabetically, skipping hidden dirs
  local all_files = vim.fn.globpath(vault, "**/*.md", false, true)
  table.sort(all_files)
  for _, f in ipairs(all_files) do
    local rel = f:sub(#vault + 2)
    if not rel:match("^%.") and not rel:match("/%.") and not seen[rel] then
      result[#result + 1] = rel
    end
  end

  return result
end

--- Get only tracked files sorted by frecency score.
---@return string[] relative paths
function M.frequent_files()
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
    vim.notify("Vault: no files found", vim.log.levels.INFO)
    return
  end
  local fzf = require("fzf-lua")
  fzf.fzf_exec(ranked, {
    prompt = "Vault files> ",
    cwd = engine.vault_path,
    file_icons = true,
    git_icons = false,
    previewer = "builtin",
    actions = {
      ["default"] = fzf.actions.file_edit,
      ["ctrl-s"] = fzf.actions.file_split,
      ["ctrl-v"] = fzf.actions.file_vsplit,
      ["ctrl-t"] = fzf.actions.file_tabedit,
    },
  })
end

--- Open fzf-lua with only tracked files, sorted by frecency.
function M.frequent()
  local files = M.frequent_files()
  if #files == 0 then
    vim.notify("Vault: no recent notes in frecency database", vim.log.levels.INFO)
    return
  end
  local fzf = require("fzf-lua")
  fzf.fzf_exec(files, {
    prompt = "Recent vault notes> ",
    cwd = engine.vault_path,
    file_icons = true,
    git_icons = false,
    previewer = "builtin",
    actions = {
      ["default"] = fzf.actions.file_edit,
      ["ctrl-s"] = fzf.actions.file_split,
      ["ctrl-v"] = fzf.actions.file_vsplit,
      ["ctrl-t"] = fzf.actions.file_tabedit,
    },
  })
end

function M.setup()
  local group = vim.api.nvim_create_augroup("VaultFrecency", { clear = true })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      if name ~= "" then
        M.record(name)
      end
    end,
  })

  vim.api.nvim_create_user_command("VaultFiles", function()
    M.files()
  end, { desc = "Find vault files ranked by frecency" })
end

return M
