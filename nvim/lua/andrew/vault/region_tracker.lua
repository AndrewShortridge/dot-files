local M = {}

local config = require("andrew.vault.config")
local log = require("andrew.vault.vault_log").scope("region_tracker")

---@class ValidRegion
---@field start_line number  0-indexed, inclusive
---@field end_line number    0-indexed, exclusive
---@field version number     changedtick when validated

---@class RegionTracker
---@field _bufnr number
---@field _regions ValidRegion[]
local RegionTracker = {}
RegionTracker.__index = RegionTracker

--- Create a new region tracker scope (no buffer attachment — edits
--- are propagated from the BufferTracker that owns this scope).
---@param bufnr number
---@return RegionTracker
function RegionTracker._new_scope(bufnr)
  return setmetatable({
    _bufnr = bufnr,
    _regions = {},
  }, RegionTracker)
end

--- Process an edit notification (called by BufferTracker for each scope).
---@param first_line number  First changed line (0-indexed)
---@param last_line number   Old end of changed range (0-indexed, exclusive)
---@param new_last_line number  New end of changed range (0-indexed, exclusive)
function RegionTracker:_on_lines(first_line, last_line, new_last_line)
  local delta = new_last_line - last_line
  local new_regions = {}

  for _, region in ipairs(self._regions) do
    if region.end_line <= first_line then
      -- Region is entirely before the edit: keep unchanged
      new_regions[#new_regions + 1] = region
    elseif region.start_line >= last_line then
      -- Region is entirely after the edit: shift by delta
      new_regions[#new_regions + 1] = {
        start_line = region.start_line + delta,
        end_line = region.end_line + delta,
        version = region.version,
      }
    elseif region.start_line < first_line and region.end_line > last_line then
      -- Edit is contained within region: split into two
      new_regions[#new_regions + 1] = {
        start_line = region.start_line,
        end_line = first_line,
        version = region.version,
      }
      -- Right fragment (after edit, shifted)
      local shifted_end = region.end_line + delta
      if shifted_end > new_last_line then
        new_regions[#new_regions + 1] = {
          start_line = new_last_line,
          end_line = shifted_end,
          version = region.version,
        }
      end
    elseif region.start_line < first_line then
      -- Region overlaps edit start: truncate to before edit
      new_regions[#new_regions + 1] = {
        start_line = region.start_line,
        end_line = first_line,
        version = region.version,
      }
    elseif region.end_line > last_line then
      -- Region overlaps edit end: truncate to after edit, shifted
      local shifted_end = region.end_line + delta
      if shifted_end > new_last_line then
        new_regions[#new_regions + 1] = {
          start_line = new_last_line,
          end_line = shifted_end,
          version = region.version,
        }
      end
    end
    -- else: region is fully contained in the edit range, discard it
  end

  self._regions = new_regions
  self:_enforce_limit()
end

--- Get all invalid ranges within the buffer's line count.
--- Returns ranges that are NOT covered by any valid region.
---@return {start_line: number, end_line: number}[]
function RegionTracker:get_invalid_ranges()
  if not vim.api.nvim_buf_is_valid(self._bufnr) then return {} end
  local line_count = vim.api.nvim_buf_line_count(self._bufnr)
  local invalid = {}
  local cursor = 0

  for _, region in ipairs(self._regions) do
    if cursor < region.start_line then
      invalid[#invalid + 1] = {
        start_line = cursor,
        end_line = region.start_line,
      }
    end
    cursor = math.max(cursor, region.end_line)
  end

  if cursor < line_count then
    invalid[#invalid + 1] = {
      start_line = cursor,
      end_line = line_count,
    }
  end

  return invalid
end

--- Check if a line range overlaps any invalid region.
---@param start_line number 0-indexed, inclusive
---@param end_line number 0-indexed, exclusive
---@return boolean
function RegionTracker:has_invalid_in_range(start_line, end_line)
  local invalid = self:get_invalid_ranges()
  for _, r in ipairs(invalid) do
    if r.start_line < end_line and r.end_line > start_line then
      return true
    end
  end
  return false
end

--- Mark a line range as valid (after successful rendering).
---@param start_line number  0-indexed, inclusive
---@param end_line number    0-indexed, exclusive
function RegionTracker:mark_valid(start_line, end_line)
  if start_line >= end_line then return end
  if not vim.api.nvim_buf_is_valid(self._bufnr) then return end

  local version = vim.api.nvim_buf_get_changedtick(self._bufnr)
  local new_region = {
    start_line = start_line,
    end_line = end_line,
    version = version,
  }

  -- Insert in sorted position
  local inserted = false
  for i, region in ipairs(self._regions) do
    if start_line <= region.start_line then
      table.insert(self._regions, i, new_region)
      inserted = true
      break
    end
  end
  if not inserted then
    self._regions[#self._regions + 1] = new_region
  end

  self:_coalesce()
  self:_enforce_limit()
end

--- Explicitly invalidate a line range, removing validity.
---@param start_line number  0-indexed, inclusive
---@param end_line number    0-indexed, exclusive
function RegionTracker:invalidate_range(start_line, end_line)
  local new_regions = {}

  for _, region in ipairs(self._regions) do
    if region.end_line <= start_line or region.start_line >= end_line then
      new_regions[#new_regions + 1] = region
    else
      if region.start_line < start_line then
        new_regions[#new_regions + 1] = {
          start_line = region.start_line,
          end_line = start_line,
          version = region.version,
        }
      end
      if region.end_line > end_line then
        new_regions[#new_regions + 1] = {
          start_line = end_line,
          end_line = region.end_line,
          version = region.version,
        }
      end
    end
  end

  self._regions = new_regions
end

--- Invalidate all regions (full reset).
function RegionTracker:invalidate_all()
  self._regions = {}
end

--- Merge overlapping or adjacent valid regions.
function RegionTracker:_coalesce()
  if #self._regions <= 1 then return end

  local merged = { self._regions[1] }

  for i = 2, #self._regions do
    local prev = merged[#merged]
    local curr = self._regions[i]

    if curr.start_line <= prev.end_line then
      prev.end_line = math.max(prev.end_line, curr.end_line)
      prev.version = math.max(prev.version, curr.version)
    else
      merged[#merged + 1] = curr
    end
  end

  self._regions = merged
end

--- Enforce max regions per buffer to bound memory and lookup time.
--- When over the limit, first tries to merge nearby regions (within
--- coalesce_threshold lines) to reduce count without losing coverage.
--- Falls back to evicting the smallest region if still over limit.
function RegionTracker:_enforce_limit()
  local max = config.region_tracker and config.region_tracker.max_per_buffer or 50
  if #self._regions <= max then return end

  -- First pass: merge nearby regions separated by small gaps.
  -- This is safe here because we only sacrifice gap precision under
  -- memory pressure, not on every mark_valid() call.
  local threshold = config.region_tracker and config.region_tracker.coalesce_threshold or 5
  if threshold > 0 then
    local merged = { self._regions[1] }
    for i = 2, #self._regions do
      local prev = merged[#merged]
      local curr = self._regions[i]
      if curr.start_line <= prev.end_line + threshold then
        prev.end_line = math.max(prev.end_line, curr.end_line)
        prev.version = math.max(prev.version, curr.version)
      else
        merged[#merged + 1] = curr
      end
    end
    self._regions = merged
  end

  -- Second pass: evict smallest regions if still over limit
  while #self._regions > max do
    local min_size = math.huge
    local min_idx = 1
    for i, region in ipairs(self._regions) do
      local size = region.end_line - region.start_line
      if size < min_size then
        min_size = size
        min_idx = i
      end
    end
    table.remove(self._regions, min_idx)
  end
end

-- ---------------------------------------------------------------------------
-- BufferTracker: per-buffer container that holds multiple scoped RegionTrackers
-- and a single nvim_buf_attach subscription shared across all scopes.
-- ---------------------------------------------------------------------------

---@class BufferTracker
---@field _bufnr number
---@field _scopes table<string, RegionTracker>
---@field _attached boolean
local BufferTracker = {}
BufferTracker.__index = BufferTracker

function BufferTracker.new(bufnr)
  local self = setmetatable({
    _bufnr = bufnr,
    _scopes = {},
    _attached = false,
  }, BufferTracker)
  self:_attach()
  return self
end

function BufferTracker:_attach()
  if self._attached then return end

  local ok = vim.api.nvim_buf_attach(self._bufnr, false, {
    on_lines = function(_event, _buf, _tick, first_line, last_line, new_last_line)
      -- Propagate edit to ALL scopes
      for _, scope in pairs(self._scopes) do
        scope:_on_lines(first_line, last_line, new_last_line)
      end
    end,
    on_detach = function()
      self._attached = false
      for _, scope in pairs(self._scopes) do
        scope._regions = {}
      end
    end,
  })

  if ok then
    self._attached = true
  else
    log.warn("Failed to attach to buffer %d", self._bufnr)
  end
end

--- Get or create a scoped RegionTracker within this buffer.
---@param scope string
---@return RegionTracker
function BufferTracker:get_scope(scope)
  if not self._scopes[scope] then
    self._scopes[scope] = RegionTracker._new_scope(self._bufnr)
  end
  return self._scopes[scope]
end

--- Invalidate all scopes (e.g., on VaultCacheInvalidate).
function BufferTracker:invalidate_all_scopes()
  for _, scope in pairs(self._scopes) do
    scope:invalidate_all()
  end
end

-- ---------------------------------------------------------------------------
-- Module-level registry
-- ---------------------------------------------------------------------------

local _buffers = {} ---@type table<number, BufferTracker>

--- Get or create a scoped RegionTracker for a buffer.
--- Each (bufnr, scope) pair gets its own independent validity tracking,
--- but they all share the same on_lines edit propagation.
---@param bufnr number
---@param scope? string  Consumer name (default: "default")
---@return RegionTracker
function M.get(bufnr, scope)
  scope = scope or "default"
  if not _buffers[bufnr] then
    _buffers[bufnr] = BufferTracker.new(bufnr)
  end
  return _buffers[bufnr]:get_scope(scope)
end

--- Get the BufferTracker for a buffer (for invalidate_all_scopes).
---@param bufnr number
---@return BufferTracker|nil
function M.get_buffer(bufnr)
  return _buffers[bufnr]
end

--- Remove all trackers for a buffer (called on BufDelete/BufWipeout).
---@param bufnr number
function M.remove(bufnr)
  _buffers[bufnr] = nil
end

--- Clear extmarks within invalid ranges only (shared helper for consumers).
--- Returns the invalid ranges used, or nil if no work needed.
---@param bufnr number
---@param ns number  Namespace ID
---@param scope? string  Consumer scope name
---@param opts? { force?: boolean }
---@return {start_line: number, end_line: number}[]|nil
function M.clear_extmarks_in_invalid_ranges(bufnr, ns, scope, opts)
  local tracker = M.get(bufnr, scope)
  local force = opts and opts.force

  if force then
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    tracker:invalidate_range(0, line_count)
  end

  local invalid_ranges = tracker:get_invalid_ranges()
  if #invalid_ranges == 0 then return nil end

  for _, range in ipairs(invalid_ranges) do
    local existing = vim.api.nvim_buf_get_extmarks(
      bufnr,
      ns,
      { range.start_line, 0 },
      { range.end_line, 0 },
      {}
    )
    for _, mark in ipairs(existing) do
      vim.api.nvim_buf_del_extmark(bufnr, ns, mark[1])
    end
  end

  return invalid_ranges
end

--- Mark ranges as valid after rendering (shared helper).
---@param bufnr number
---@param ranges {start_line: number, end_line: number}[]
---@param scope? string
function M.mark_ranges_valid(bufnr, ranges, scope)
  local tracker = M.get(bufnr, scope)
  for _, range in ipairs(ranges) do
    tracker:mark_valid(range.start_line, range.end_line)
  end
end

--- Check if a 0-indexed line falls within any of the given ranges.
---@param line_0 number  0-indexed line number
---@param ranges {start_line: number, end_line: number}[]
---@return boolean
function M.is_line_in_ranges(line_0, ranges)
  for _, range in ipairs(ranges) do
    if line_0 >= range.start_line and line_0 < range.end_line then
      return true
    end
  end
  return false
end

return M
