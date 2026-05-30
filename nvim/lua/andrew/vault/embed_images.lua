--- Image integration for the embed system.
--- Isolates all Snacks/terminal dependency for image rendering.
local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local lru = require("andrew.vault.lru_cache")
local link_utils = require("andrew.vault.link_utils")
local SlotMap = require("andrew.vault.slot_map")
local state = require("andrew.vault.embed_state")
local log = require("andrew.vault.vault_log").scope("embed_images")

--- Cached reference to the image extensions set (never changes after init).
local _image_exts = config.embed.image_exts

local M = {}

-- Dedicated slot map for individual image placements.
-- Each placement is an entity with its own handle for precise lifecycle tracking.
local _placement_map = SlotMap.new({
  name = "img_placement",
  leak_detect = config.slot_map.leak_detect,
})

--- Safely call a function, logging any error via the module logger.
---@param context string caller context for debug logging
---@param fn function the function to call
---@param ... any arguments to pass
---@return boolean ok
---@return any result_or_err
local function safe_pcall(context, fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then
    log.debug("%s failed: %s", context, tostring(result))
  end
  return ok, result
end

--- Close a placement entry safely, logging any error.
---@param entry table { placement, bufnr, lnum }
local function close_placement_entry(entry)
  safe_pcall("placement close", function() entry.placement:close() end)
end

--- Safely call Snacks.image.terminal.env(), logging on failure.
---@param context string caller context for debug logging
---@return boolean ok, table|string|nil env_or_err
local function safe_terminal_env(context)
  return safe_pcall(context, function() return Snacks.image.terminal.env() end)
end
M.safe_terminal_env = safe_terminal_env

local IMAGE_SEARCH_DIRS = { "attachments", "assets", "images", "img", "media", "static", "public" }

--- Image resolution cache (LRU-bounded).
--- Key: image_name .. "\0" .. buf_dir (NUL separator avoids ambiguity)
--- Value: absolute path (string) or false (not found)
local _image_cache_hits = 0
local _image_cache_misses = 0
local _image_cache_evictions = 0
local _image_cache = lru.new(config.cache.image_path_max)

--- Generation counter: incremented on any fs event that might affect images.
local _image_cache_generation = 0
local _last_cache_generation = 0

--- Last successful search path index (locality heuristic).
local _last_hit_idx = nil

engine.register_cache({
  name = "image_paths",
  module = "andrew.vault.embed_images",
  invalidate = function()
    _image_cache_generation = _image_cache_generation + 1
  end,
  invalidate_file = function(abs_path)
    M.invalidate_image_cache(abs_path)
  end,
  stats = function()
    return {
      entries = _image_cache:size(),
      max = config.cache.image_path_max,
      vault = engine.vault_path,
    }
  end,
})

do
  local profiler = require("andrew.vault.memory_profiler")
  profiler.register_cache({
    name = "image_paths",
    get_size = function() return _image_cache:size() end,
    get_capacity = function() return config.cache.image_path_max end,
    get_hits = function() return _image_cache_hits end,
    get_misses = function() return _image_cache_misses end,
    get_evictions = function() return _image_cache_evictions end,
  })
end

--- Invalidate the image path cache. Called by the filesystem watcher when
--- events occur in image directories.
--- When called with a changed_path, only invalidates entries whose filename
--- matches the changed file (selective invalidation).
---@param changed_path? string optional absolute path of the changed image file
function M.invalidate_image_cache(changed_path)
  if not changed_path then
    -- Full invalidation (backward compatible)
    _image_cache_generation = _image_cache_generation + 1
    return
  end

  -- Selective: only clear entries for the same image filename
  local changed_name = changed_path:match("[^/]+$")
  if not changed_name then
    _image_cache_generation = _image_cache_generation + 1
    return
  end

  -- Collect matching keys first (avoid mutating during iteration)
  local to_remove = {}
  for key in _image_cache:entries() do
    local cached_name = key:match("^([^\0]+)")
    if cached_name == changed_name then
      to_remove[#to_remove + 1] = key
    end
  end
  for _, key in ipairs(to_remove) do
    _image_cache:remove(key)
  end
end

--- Invalidate the snacks terminal env cache if placeholders are not detected.
---@return boolean invalidated
local function invalidate_snacks_env()
  if not (Snacks and Snacks.image and Snacks.image.terminal) then
    return false
  end
  local term = Snacks.image.terminal
  if term._env and not term._env.placeholders then
    term._env = nil
  end
  return true
end

--- Safely initialize the snacks image system and return the placement module.
---@return table|nil placement module, or nil if unavailable
---@return table|nil doc config from Snacks.image.config.doc
function M.init_snacks_image()
  if not (Snacks and Snacks.image) then
    log.debug("snacks image unavailable: Snacks=%s, Snacks.image=%s", tostring(Snacks ~= nil), tostring(Snacks and Snacks.image ~= nil))
    return nil, nil
  end
  local ok, placement = safe_pcall("snacks placement access", function() return Snacks.image.placement end)
  if not ok or not placement or type(placement.new) ~= "function" then
    return nil, nil
  end
  local doc_cfg = Snacks.image.config and Snacks.image.config.doc or {}
  return placement, doc_cfg
end

--- Check if an embed inner text refers to an image file.
---@param inner string the text between ![[  and ]]
---@return boolean
function M.is_image_embed(inner)
  local first = inner:sub(1, 1)
  if first == "^" or first == "#" then
    return false
  end
  local name = inner:match("^([^|#^]+)") or inner
  local ext = name:match("%.(%w+)$")
  return ext and _image_exts[ext:lower()] or false
end

--- Extract the image filename from embed inner text, stripping any pipe alias.
---@param inner string e.g. "photo.png|400"
---@return string e.g. "photo.png"
function M.get_image_name(inner)
  return inner:match("^([^|]+)") or inner
end

--- Build the ordered list of candidate paths to search for an image.
---@param image_name string image filename (e.g. "photo.png")
---@param bufpath string buffer file path for relative resolution
---@param buf_dir? string pre-computed directory of bufpath (avoids redundant lua_dirname)
---@return string[]
function M.get_image_search_paths(image_name, bufpath, buf_dir)
  buf_dir = buf_dir or link_utils.lua_dirname(bufpath)
  local paths = {
    buf_dir .. "/" .. image_name,
    engine.vault_path .. "/" .. image_name,
  }
  for _, dir in ipairs(IMAGE_SEARCH_DIRS) do
    paths[#paths + 1] = engine.vault_path .. "/" .. dir .. "/" .. image_name
  end
  return paths
end

--- Resolve an image embed name to an absolute file path.
--- Results are cached; call invalidate_image_cache() on fs events.
---@param image_name string image filename (e.g. "photo.png")
---@param bufpath string buffer file path for relative resolution
---@return string|nil
function M.resolve_image(image_name, bufpath)
  -- Check if cache needs wholesale invalidation
  if _last_cache_generation ~= _image_cache_generation then
    _image_cache_evictions = _image_cache_evictions + _image_cache:size()
    _image_cache:clear()
    _last_cache_generation = _image_cache_generation
    _last_hit_idx = nil
  end

  local buf_dir = link_utils.lua_dirname(bufpath)
  local cache_key = image_name .. "\0" .. buf_dir

  local cached = _image_cache:get(cache_key)
  if cached ~= nil then
    _image_cache_hits = _image_cache_hits + 1
    return cached ~= false and cached or nil
  end
  _image_cache_misses = _image_cache_misses + 1

  -- Cache miss: try the last successful directory first (locality heuristic)
  local paths = M.get_image_search_paths(image_name, bufpath, buf_dir)
  if _last_hit_idx and _last_hit_idx <= #paths then
    local candidate = paths[_last_hit_idx]
    if vim.uv.fs_stat(candidate) then
      _image_cache:put(cache_key, candidate)
      return candidate
    end
  end

  -- Full search
  for idx, candidate in ipairs(paths) do
    if vim.uv.fs_stat(candidate) then
      _last_hit_idx = idx
      _image_cache:put(cache_key, candidate)
      return candidate
    end
  end

  _image_cache:put(cache_key, false)
  return nil, "image not found: " .. tostring(image_name)
end

--- Build an on_update callback for image placement retry logic.
--- When a placement updates but placeholders aren't detected yet (and SNACKS_KITTY=1),
--- invalidates the env cache and schedules a re-render.
---@param bufnr number buffer number
---@param render_fn fun(opts: table) function to call for re-render
---@return fun(p: table)
function M.make_on_update(bufnr, render_fn)
  return function(p)
    local st = state.try_get_buf_state(bufnr)
    if not st then return end
    if st.image_retry_fired then return end
    if not p.closed and st.visible then
      local ok_e, env = safe_terminal_env("on_update")
      if ok_e and env and not env.placeholders and vim.env.SNACKS_KITTY == "1" then
        st.image_retry_fired = true
        invalidate_snacks_env()
        vim.schedule(function()
          local st2 = state.try_get_buf_state(bufnr)
          if st2 and st2.visible then
            render_fn({ silent = true })
          end
        end)
      end
    end
  end
end

--- Create an image placement for a single embed.
---@param bufnr number buffer number
---@param src string resolved image path
---@param snacks_doc_cfg table doc config from init_snacks_image()
---@param merge_fn fun(...): table config merge function
---@param pos {[1]: number, [2]: number} 1-indexed row, 0-indexed col
---@param range {[1]: number, [2]: number, [3]: number, [4]: number}
---@param on_update? fun(p: table) optional on_update callback
---@return table|nil placement, string|nil error
function M.create_placement(bufnr, src, PlacementMod, snacks_doc_cfg, merge_fn, pos, range, on_update)
  if not PlacementMod then
    return nil, "snacks placement module unavailable"
  end
  local ok, placement = pcall(PlacementMod.new, bufnr, src, merge_fn({}, snacks_doc_cfg, {
    pos = pos,
    range = range,
    inline = true,
    conceal = false,
    type = "image",
    on_update = on_update,
  }))
  if ok and placement then
    -- Tag with 1-indexed line number for viewport GC (pos = {row, col})
    placement._vault_lnum = pos[1]
    local handle = _placement_map:insert({
      placement = placement,
      bufnr = bufnr,
      lnum = pos[1],
    })
    local st = state.get_buf_state(bufnr)
    table.insert(st.placements, handle)
    return placement, nil
  end
  return nil, tostring(placement)
end

--- Schedule a deferred image retry if placeholders are not yet detected.
---@param bufnr number buffer number
---@param render_fn fun(opts: table) function to call for re-render (e.g. M.render_embeds)
function M.schedule_retry(bufnr, render_fn)
  local ok_env, env = safe_terminal_env("image retry")
  if not ok_env then return end
  if not env or env.placeholders then return end

  vim.defer_fn(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local rst = state.try_get_buf_state(bufnr)
    if not rst or not rst.visible then return end
    invalidate_snacks_env()
    local ok2, env2 = safe_terminal_env("deferred image retry")
    if ok2 and env2 and env2.placeholders then
      render_fn({ silent = true })
    end
  end, config.embed.image_retry_delay_ms)
end

--- Clean up image placements for a buffer.
---@param bufnr number
function M.clear_image_placements(bufnr)
  local st = state.try_get_buf_state(bufnr)
  if not st then return end
  local handles = st.placements
  if not handles or #handles == 0 then return end
  st.placements = {}
  for _, handle in ipairs(handles) do
    local entry = _placement_map:remove(handle)
    if entry then
      close_placement_entry(entry)
    end
  end
end

--- Clean up image placements within a specific line range.
--- Preserves placements outside the range.
---@param bufnr number
---@param start_line number 0-indexed, inclusive
---@param end_line number 0-indexed, exclusive
function M.clear_image_placements_in_range(bufnr, start_line, end_line)
  local st = state.try_get_buf_state(bufnr)
  if not st then return end
  local handles = st.placements
  if not handles or #handles == 0 then return end

  local kept = {}
  for _, handle in ipairs(handles) do
    local entry = _placement_map:get(handle)
    if not entry then goto continue end
    -- lnum is 1-indexed; convert range to 1-indexed for comparison
    local lnum = entry.lnum
    if lnum and lnum >= start_line + 1 and lnum <= end_line then
      _placement_map:remove(handle)
      close_placement_entry(entry)
    else
      kept[#kept + 1] = handle
    end
    ::continue::
  end

  st.placements = kept
end

--- Resolve a placement handle to its entry.
--- Returns nil if the handle is stale (placement was removed).
---@param handle table { slot, generation }
---@return table|nil entry { placement, bufnr, lnum }
function M.get_placement(handle)
  return _placement_map:get(handle)
end

--- Remove a placement by handle and close it.
---@param handle table { slot, generation }
---@return boolean removed
function M.remove_placement(handle)
  local entry = _placement_map:remove(handle)
  if entry then
    close_placement_entry(entry)
    return true
  end
  return false
end

--- Get the count of live placements for a buffer.
---@param bufnr number
---@return number
function M.placement_count(bufnr)
  local st = state.try_get_buf_state(bufnr)
  if not st then return 0 end
  return #st.placements
end

--- Resolve all placement handles for a buffer to their entries.
--- Returns array of { handle, entry } pairs (skips stale handles).
---@param bufnr number
---@return table[] pairs Array of { handle, entry } where entry = { placement, bufnr, lnum }
function M.resolve_placements(bufnr)
  local st = state.try_get_buf_state(bufnr)
  if not st then return {} end
  local result = {}
  for _, handle in ipairs(st.placements) do
    local entry = _placement_map:get(handle)
    if entry then
      result[#result + 1] = { handle = handle, entry = entry }
    end
  end
  return result
end

--- Expose the slot map for debug/monitoring commands.
---@return SlotMap
function M._get_slot_map()
  return _placement_map
end

-- Register with engine cache registry for :VaultCacheDebug visibility
_placement_map:register_with_engine({
  name = "img_placement_slotmap",
  module = "andrew.vault.embed_images",
  invalidate = function()
    -- Placement lifecycle is managed by embed system, not cache invalidation.
    -- No-op: placements are cleaned up via clear_image_placements().
  end,
})

return M
