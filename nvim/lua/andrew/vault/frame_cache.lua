local M = {}
M.__index = M

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    previous = {},
    current = {},
    current_count = 0,
    previous_count = 0,
    max_entries = opts.max_entries,
    stats = { hits = 0, misses = 0, promotions = 0, evictions = 0 },
  }, M)
end

function M:get(key)
  local val = self.current[key]
  if val ~= nil then
    self.stats.hits = self.stats.hits + 1
    return val
  end

  val = self.previous[key]
  if val ~= nil then
    -- Promote from previous to current
    self.previous[key] = nil
    self.previous_count = self.previous_count - 1
    self.current[key] = val
    self.current_count = self.current_count + 1
    self.stats.promotions = self.stats.promotions + 1
    return val
  end

  self.stats.misses = self.stats.misses + 1
  return nil
end

function M:set(key, value)
  if self.max_entries and self.current_count >= self.max_entries then
    if self.current[key] == nil then
      self.stats.evictions = self.stats.evictions + 1
      return false
    end
  end
  if self.current[key] == nil then
    self.current_count = self.current_count + 1
  end
  self.current[key] = value
  return true
end

function M:finish_frame()
  self.previous = self.current
  self.previous_count = self.current_count
  self.current = {}
  self.current_count = 0
end

function M:clear()
  self.previous = {}
  self.current = {}
  self.previous_count = 0
  self.current_count = 0
end

function M:size()
  return self.current_count + self.previous_count
end

function M:get_stats()
  return {
    hits = self.stats.hits,
    misses = self.stats.misses,
    promotions = self.stats.promotions,
    evictions = self.stats.evictions,
    current_entries = self.current_count,
    previous_entries = self.previous_count,
    total_entries = self.current_count + self.previous_count,
  }
end

function M:reset_stats()
  self.stats = { hits = 0, misses = 0, promotions = 0, evictions = 0 }
end

--- Per-buffer cache registry shared by modules with independent render cycles.
--- Each module passes its own `registry` table (e.g. `_frame_caches = {}`).
---@param registry table<number, table> module-owned bufnr → FrameCache map
---@param bufnr number
---@return table|nil cache instance, or nil when render_cache is disabled
function M.buf_get(registry, bufnr)
  local config = require("andrew.vault.config")
  if not config.render_cache.enabled then return nil end
  if not registry[bufnr] then
    registry[bufnr] = M.new({
      max_entries = config.render_cache.max_entries_per_frame,
    })
  end
  return registry[bufnr]
end

--- Deep-copy a virt_lines table so cached values survive arena recycling.
--- Each element is `{ {text, hl}, ... }`.
---@param virt_lines table[]
---@return table[]
function M.copy_virt_lines(virt_lines)
  local copy = {}
  for i, line in ipairs(virt_lines) do
    local lc = {}
    for j, seg in ipairs(line) do lc[j] = { seg[1], seg[2] } end
    copy[i] = lc
  end
  return copy
end

return M
