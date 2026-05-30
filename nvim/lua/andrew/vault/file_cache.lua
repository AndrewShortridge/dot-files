--- File content cache with mtime-based invalidation.
--- Caches recently-read file contents to avoid redundant disk I/O
--- for preview, embed, and export operations.
--- Requires only lru_cache + config (no engine) to avoid circular deps.

local lru = require("andrew.vault.lru_cache")
local config = require("andrew.vault.config")
local weighers = require("andrew.vault.cache_weighers")

local M = {}

local _cache = nil
local _section_cache = nil
local _hits = 0
local _misses = 0
local _evictions = 0

--- Initialize caches (lazy, on first use).
local function ensure_init()
  if _cache then return end
  _cache = lru.new_weighted({
    max_bytes = config.cache.file_content_bytes,
    max_items = config.cache.file_content_max,
    weigher = weighers.file_content,
    on_evict = function() _evictions = _evictions + 1 end,
  })
  _section_cache = lru.new_weighted({
    max_bytes = config.cache.section_cache_bytes,
    max_items = config.cache.section_cache_max,
    weigher = weighers.section_lines,
  })
end

--- Read file content, returning cached version if mtime unchanged.
--- Uses io.open + file:lines() for raw file reads.
--- @param path string Absolute file path
--- @param max_lines number|nil Optional line limit
--- @return string[]|nil lines, number|nil mtime
function M.read(path, max_lines)
  ensure_init()
  local stat = vim.uv.fs_stat(path)
  if not stat then return nil, nil end

  local mtime = stat.mtime.sec

  -- Check cache (only use cached result if no max_lines or cached without limit)
  local cached = _cache:get(path)
  if cached and cached.mtime == mtime and not max_lines then
    _hits = _hits + 1
    return cached.lines, mtime
  end

  -- Cache miss — read from disk
  _misses = _misses + 1
  local file = io.open(path, "r")
  if not file then return nil, nil end

  local lines = {}
  for line in file:lines() do
    lines[#lines + 1] = line
    if max_lines and #lines >= max_lines then break end
  end
  file:close()

  -- Only cache unlimited reads (partial reads would produce incomplete entries)
  if not max_lines then
    _cache:put(path, { lines = lines, mtime = mtime })
  end

  return lines, mtime
end

--- Get cached section, or extract and cache.
--- @param path string Absolute file path
--- @param fragment string Heading name or ^blockid
--- @param extract_fn function(lines, fragment) → string[]
--- @return string[]|nil section_lines
function M.get_section(path, fragment, extract_fn)
  ensure_init()
  local stat = vim.uv.fs_stat(path)
  if not stat then return nil end

  local mtime = stat.mtime.sec
  local key = path .. "\0" .. fragment

  local cached = _section_cache:get(key)
  if cached and cached.mtime == mtime then
    return cached.lines
  end

  -- Read file (uses file cache above)
  local lines = M.read(path)
  if not lines then return nil end

  -- Extract section
  local section = extract_fn(lines, fragment)
  if not section then return nil end

  -- Cache
  _section_cache:put(key, { lines = section, mtime = mtime })

  return section
end

--- Invalidate a specific file (e.g., after writing).
--- Also invalidates any cached sections from that file.
--- @param path string
function M.invalidate(path)
  if not _cache then return end
  _cache:remove(path)
  -- Invalidate sections from this file (scan section cache keys)
  local prefix = path .. "\0"
  local to_remove = {}
  for key, _ in _section_cache:entries() do
    if type(key) == "string" and key:sub(1, #prefix) == prefix then
      to_remove[#to_remove + 1] = key
    end
  end
  for _, key in ipairs(to_remove) do
    _section_cache:remove(key)
  end
end

--- Invalidate all cached content.
function M.clear()
  if not _cache then return end
  _cache:clear()
  _section_cache:clear()
  _hits = 0
  _misses = 0
end

--- Get cache statistics.
--- @return table { file_size, file_max, section_size, section_max, hits, misses, hit_rate }
function M.stats()
  ensure_init()
  local total = _hits + _misses
  local file_stats = _cache.stats and _cache:stats() or {}
  local section_stats = _section_cache.stats and _section_cache:stats() or {}
  return {
    file_size = _cache:size(),
    file_max = config.cache.file_content_max,
    section_size = _section_cache:size(),
    section_max = config.cache.section_cache_max,
    hits = _hits,
    misses = _misses,
    hit_rate = total > 0 and (_hits / total * 100) or 0,
    -- Weighted cache byte stats
    total_bytes = (file_stats.total_bytes or 0) + (section_stats.total_bytes or 0),
    max_bytes = (file_stats.max_bytes or 0) + (section_stats.max_bytes or 0),
    file_bytes = file_stats.total_bytes,
    file_max_bytes = file_stats.max_bytes,
    section_bytes = section_stats.total_bytes,
    section_max_bytes = section_stats.max_bytes,
  }
end

do
  local profiler = require("andrew.vault.memory_profiler")
  profiler.register_cache({
    name = "file_content",
    get_size = function() return _cache and _cache:size() or 0 end,
    get_capacity = function() return config.cache.file_content_max end,
    get_hits = function() return _hits end,
    get_misses = function() return _misses end,
    get_evictions = function() return _evictions end,
    get_bytes = function()
      local s = _cache and _cache.stats and _cache:stats() or {}
      return s.total_bytes or 0
    end,
    get_max_bytes = function() return config.cache.file_content_bytes end,
  })
end

return M
