--- Centralized state management for the embed system.
--- Holds all per-buffer state in a generational slot map with ABA protection.
--- Shared parsing utilities for embed syntax.
local pat = require("andrew.vault.patterns")
local SlotMap = require("andrew.vault.slot_map")
local config = require("andrew.vault.config")

local M = {}

M.ns = vim.api.nvim_create_namespace("VaultEmbed")

-- Lua pattern matching ![[...]] embed syntax.
-- NOTE: Canonical embed tokenization lives in line_parse_cache.tokenize_line().
-- This pattern is kept for find_embed_spans/iterate_embeds used by embed.lua
-- and embed_resolver.lua outside the pipeline path.
local EMBED_PAT = pat.EMBED_DETECT

-- Generational slot map for per-buffer embed state.
-- Each buffer gets a single entity with all embed-related fields.
local _buf_entities = SlotMap.new({
  name = "embed_buf",
  leak_detect = config.slot_map.leak_detect,
})

-- bufnr -> handle mapping for slot map lookups
local _buf_handles = {}

-- Subscription handle (not per-buffer, managed by embed_sync)
M._subscription = nil

--- Notify embed_sync that the dependency index needs rebuilding.
--- Uses package.loaded to avoid circular require (embed_state cannot
--- require embed_sync directly). embed.lua calls sync.mark_dep_index_dirty()
--- directly since it already imports embed_sync.
local function notify_dep_index_dirty()
  local sync_mod = package.loaded["andrew.vault.embed_sync"]
  if sync_mod and sync_mod.mark_dep_index_dirty then
    sync_mod.mark_dep_index_dirty()
  end
end

--- Create a new per-buffer state record with default values.
---@return table
local function new_buf_record(bufnr)
  return {
    bufnr = bufnr,
    visible = false,
    placements = {},
    deps = {},
    image_retry_fired = false,
    descriptors = nil,
    scroll_timer = nil,
    channel = nil, -- embed_sync watch channel { send, handle }
  }
end

--- Get or register a buffer's embed state.
--- Lazily creates the slot map entity on first access.
---@param bufnr number
---@return table state record
function M.get_buf_state(bufnr)
  return _buf_entities:get_or_insert(bufnr, _buf_handles, new_buf_record)
end

--- Get buffer state if it exists, without auto-creating.
---@param bufnr number
---@return table|nil state record
function M.try_get_buf_state(bufnr)
  return _buf_entities:try_get(bufnr, _buf_handles)
end

--- Check if a buffer has embeds visible and is still valid.
---@param bufnr number
---@return boolean
function M.is_embed_active(bufnr)
  local st = M.try_get_buf_state(bufnr)
  return st ~= nil and st.visible ~= false and vim.api.nvim_buf_is_valid(bufnr)
end

--- Perform cleanup for a buffer's resources before removal.
---@param bufnr number
---@param st table buffer state record
local function cleanup_buf_resources(bufnr, st)
  -- Close image placements
  if st.placements and #st.placements > 0 then
    local images_mod = package.loaded["andrew.vault.embed_images"]
    if images_mod and images_mod.clear_image_placements then
      images_mod.clear_image_placements(bufnr)
    end
  end

  -- Close embed_sync watch channel (stored in unified state record)
  if st.channel then
    st.channel.handle.close()
    st.channel = nil
  end

  -- Close scroll timer
  if st.scroll_timer then
    pcall(function() st.scroll_timer:close() end)
    st.scroll_timer = nil
  end
end

--- Clear all per-buffer state for a given buffer.
--- Used by clear_embeds() and BufDelete/BufWipeout to avoid duplication.
---@param bufnr number
---@param opts? { clear_namespace?: boolean }
function M.clear_buffer_state(bufnr, opts)
  opts = opts or {}

  if opts.clear_namespace then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end

  local st = _buf_entities:remove_by_key(bufnr, _buf_handles)
  if st then
    cleanup_buf_resources(bufnr, st)
  end

  notify_dep_index_dirty()
end

--- Garbage-collect stale entries for buffers that are no longer valid.
function M.gc_stale_buffers()
  local deps_changed = false
  local stale = {}
  for bufnr, handle in pairs(_buf_handles) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      local st = _buf_entities:get(handle)
      if st then
        if st.deps and next(st.deps) then deps_changed = true end
        cleanup_buf_resources(bufnr, st)
      end
      _buf_entities:remove(handle)
      stale[#stale + 1] = bufnr
    end
  end
  for _, bufnr in ipairs(stale) do
    _buf_handles[bufnr] = nil
  end
  if deps_changed then notify_dep_index_dirty() end
end

--- Collect all buffer numbers tracked in the slot map.
--- Used by VimLeavePre and teardown to enumerate tracked buffers.
---@return table<number, true>
function M.all_tracked_buffers()
  local bufs = {}
  for bufnr in pairs(_buf_handles) do
    bufs[bufnr] = true
  end
  return bufs
end

--- Iterate all live buffer state entities.
--- Yields (bufnr, state_record) pairs.
---@return function iterator
function M.iter_buffers()
  local iter = _buf_entities:iter()
  return function()
    while true do
      local handle, st = iter()
      if not handle then return nil end
      return st.bufnr, st
    end
  end
end

--- Expose the slot map for debug/monitoring commands.
---@return SlotMap
function M._get_slot_map()
  return _buf_entities
end

--- Extract the inner text from an embed match span.
---@param line string
---@param s number start position of the match
---@param e number end position of the match
---@return string
function M.extract_embed_inner(line, s, e)
  return vim.trim(line:sub(s + 3, e - 2))
end

--- Find all ![[...]] embed spans in a line.
--- Returns a flat array {s1, e1, s2, e2, ...} of start/end positions, or nil if none found.
---@param line string
---@return number[]|nil
function M.find_embed_spans(line)
  local spans
  local pos = 1
  while true do
    local s, e = line:find(EMBED_PAT, pos)
    if not s then break end
    if not spans then spans = {} end
    spans[#spans + 1] = s
    spans[#spans + 1] = e
    pos = e + 1
  end
  return spans
end

--- Check whether a line contains only ![[...]] embeds (no other non-whitespace).
---@param line string
---@param spans number[] flat {s1, e1, s2, e2, ...} from find_embed_spans
---@return boolean
function M.is_purely_embeds(line, spans)
  local check_from = 1
  for k = 1, #spans, 2 do
    local s, e = spans[k], spans[k + 1]
    if s > check_from then
      local gap = line:sub(check_from, s - 1)
      if gap:find("%S") then return false end
    end
    check_from = e + 1
  end
  if check_from <= #line then
    if line:sub(check_from):find("%S") then return false end
  end
  return true
end

--- Iterate all ![[...]] embed spans in a set of buffer lines.
---@param lines string[] buffer lines
---@param callback fun(i: number, inner: string, s: number, e: number)
function M.iterate_embeds(lines, callback)
  for i, line in ipairs(lines) do
    local spans = M.find_embed_spans(line)
    if spans then for k = 1, #spans, 2 do
      local s, e = spans[k], spans[k + 1]
      local inner = M.extract_embed_inner(line, s, e)
      callback(i, inner, s, e)
    end end
  end
end

-- Deferred profiler registration (safe: profiler may not be loaded yet)
do
  local ok, profiler = pcall(require, "andrew.vault.memory_profiler")
  if ok then
    profiler.register_counter_deferred({
      name = "embed_tracked_buffers",
      get_count = function()
        local bufs = M.all_tracked_buffers()
        local n = 0
        for _ in pairs(bufs) do n = n + 1 end
        return n
      end,
      description = "buffers with active embed state",
    })
  end
end

-- Register with engine cache registry for :VaultCacheDebug visibility
_buf_entities:register_with_engine({
  name = "embed_buf_slotmap",
  module = "andrew.vault.embed_state",
  invalidate = function()
    -- Slot map entries are lifecycle-managed, not cache entries.
    -- Full invalidation = GC stale buffers.
    M.gc_stale_buffers()
  end,
})

-- ============================================================================
-- Memoized embed presence check
-- ============================================================================

local memo = require("andrew.vault.memoize")
local _has_embeds = memo.new(memo.changedtick, function(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, line in ipairs(lines) do
    if line:find(pat.HAS_EMBED) then
      return true
    end
  end
  return false
end, "has_embeds")
memo.register_buf_cleanup(_has_embeds)

--- Quick memoized check: does buffer contain any embed syntax?
--- Cached per changedtick — only rescans on buffer edits.
---@param bufnr number
---@return boolean
function M.has_embeds(bufnr)
  return _has_embeds:get(bufnr)
end

return M
