--- Viewport tracking for rendering optimization.
--- Per-window caching, change detection, and three-zone prefetch
--- (visible immediate + above/below delayed) for scroll pop-in reduction.

local M = {}
local config = require("andrew.vault.config")
local cleanup = require("andrew.vault.resource_cleanup")

--- @class ViewportRange
--- @field first number 1-indexed first visible line
--- @field last number 1-indexed last visible line
--- @field pad_first number first - padding (clamped to 1)
--- @field pad_last number last + padding (clamped to line_count)
--- @field height number viewport height in lines

--- @type table<number, ViewportRange> per-window cache
local _ranges = {}

--- @type table<number, ViewportRange> previous range (for diff detection)
local _prev_ranges = {}

--- Get the current viewport range for a window.
--- @param winid? number window ID (default: current)
--- @return ViewportRange
function M.get_range(winid)
  winid = winid or vim.api.nvim_get_current_win()
  local cached = _ranges[winid]
  if cached then return cached end
  return M.refresh(winid)
end

--- Refresh viewport range for a window.
--- @param winid? number
--- @return ViewportRange
function M.refresh(winid)
  winid = winid or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local padding = config.viewport.padding_lines

  local first = vim.fn.line("w0", winid)
  local last = vim.fn.line("w$", winid)

  -- Only update _prev_ranges when the viewport actually moved.
  -- Multiple callers (coordinator + embed WinScrolled) may call refresh()
  -- on the same event tick; without this guard the second call overwrites
  -- _prev_ranges with the already-updated _ranges, making newly_visible()
  -- return nil and silently dropping the scroll transition.
  local old = _ranges[winid]
  if old and (old.first ~= first or old.last ~= last) then
    _prev_ranges[winid] = old
  end

  local range = {
    first = first,
    last = last,
    pad_first = math.max(1, first - padding),
    pad_last = math.min(line_count, last + padding),
    height = last - first + 1,
  }

  _ranges[winid] = range
  return range
end

--- Check if a line is far enough off-screen to warrant cleanup.
--- Returns true if the line is beyond cleanup_threshold * viewport_height
--- from the nearest viewport edge.
--- @param lnum number 1-indexed line number
--- @param winid? number
--- @return boolean
function M.should_cleanup(lnum, winid)
  local r = M.get_range(winid)
  local threshold = r.height * config.viewport.cleanup_threshold
  return lnum < (r.first - threshold) or lnum > (r.last + threshold)
end

--- Get lines that became newly visible since last refresh.
--- Returns nil if no previous range exists (first render).
--- @param winid? number
--- @return { first: number, last: number }[]|nil new_ranges
function M.newly_visible(winid)
  winid = winid or vim.api.nvim_get_current_win()
  local cur = _ranges[winid]
  local prev = _prev_ranges[winid]
  if not cur or not prev then return nil end

  local ranges = {}

  -- New lines above previous viewport
  if cur.pad_first < prev.pad_first then
    ranges[#ranges + 1] = { first = cur.pad_first, last = math.min(prev.pad_first - 1, cur.pad_last) }
  end

  -- New lines below previous viewport
  if cur.pad_last > prev.pad_last then
    ranges[#ranges + 1] = { first = math.max(prev.pad_last + 1, cur.pad_first), last = cur.pad_last }
  end

  return #ranges > 0 and ranges or nil
end

-- ---------------------------------------------------------------------------
-- Three-zone prefetch
-- ---------------------------------------------------------------------------

--- @class ViewportZones
--- @field above { start_line: number, end_line: number }
--- @field visible { start_line: number, end_line: number }
--- @field below { start_line: number, end_line: number }
--- @field viewport_height number
--- @field prefetch_size number

--- Compute three zones around the current viewport.
--- Extends the existing get_range() with proportional prefetch zones.
--- @param winid? number
--- @return ViewportZones
function M.get_zones(winid)
  local range = M.refresh(winid)
  winid = winid or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local buf_line_count = vim.api.nvim_buf_line_count(bufnr)
  local multiplier = config.viewport.prefetch_multiplier
  local prefetch_size = math.floor(range.height * multiplier)

  return {
    above = {
      start_line = math.max(1, range.first - prefetch_size),
      end_line = math.max(0, range.first - 1),
    },
    visible = {
      start_line = range.first,
      end_line = range.last,
    },
    below = {
      start_line = math.min(buf_line_count + 1, range.last + 1),
      end_line = math.min(buf_line_count, range.last + prefetch_size),
    },
    viewport_height = range.height,
    prefetch_size = prefetch_size,
  }
end

--- Get viewport range with render margin (0-indexed start, exclusive end).
--- Shared helper for lightweight viewport-restricted modules (autolink, footnotes).
--- @param bufnr number
--- @param winid? number
--- @return number start_line 0-indexed
--- @return number end_line exclusive end
function M.get_margin_range(bufnr, winid)
  winid = winid or vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(winid) ~= bufnr then
    return 0, vim.api.nvim_buf_line_count(bufnr)
  end
  local vp = M.get_range(winid)
  local margin = config.viewport.render_margin
  local start_line = math.max(0, vp.first - 1 - margin)
  local end_line = math.min(vim.api.nvim_buf_line_count(bufnr), vp.last + margin)
  return start_line, end_line
end

-- ---------------------------------------------------------------------------
-- Prefetch scheduling
-- ---------------------------------------------------------------------------

--- @type table<string, uv.uv_timer_t> "bufnr:winid:zone" → timer
local _prefetch_timers = {}

--- Schedule a prefetch callback with debounce.
--- Uses cleanup.debounce() for consistent timer management.
--- @param bufnr number
--- @param winid number
--- @param zone_name "above"|"below"
--- @param callback fun()
function M.schedule_prefetch(bufnr, winid, zone_name, callback)
  local key = bufnr .. ":" .. winid .. ":" .. zone_name
  local debounce_ms = config.viewport.prefetch_debounce_ms

  _prefetch_timers[key] = cleanup.debounce(_prefetch_timers[key], debounce_ms, function()
    _prefetch_timers[key] = nil
    if vim.api.nvim_buf_is_valid(bufnr)
      and vim.api.nvim_win_is_valid(winid) then
      callback()
    end
  end)
end

--- Cancel all prefetch timers for a buffer (or buffer+window).
--- @param bufnr number
--- @param winid? number
function M.cancel_prefetch(bufnr, winid)
  local prefix = tostring(bufnr) .. ":"
  if winid then prefix = prefix .. winid .. ":" end
  for key, timer in pairs(_prefetch_timers) do
    if key:sub(1, #prefix) == prefix then
      cleanup.close_timer(timer)
      _prefetch_timers[key] = nil
    end
  end
end

-- ---------------------------------------------------------------------------
-- Zone stability (range deduplication)
-- ---------------------------------------------------------------------------

--- @type table<string, ViewportZones> "bufnr:winid" → last prefetched zones
local _prefetched_zones = {}

--- Check which prefetch zones have changed since last prefetch.
--- Returns flags indicating whether each zone needs re-rendering.
--- @param bufnr number
--- @param winid number
--- @param new_zones ViewportZones
--- @return boolean above_changed, boolean below_changed
function M.prefetch_zones_changed(bufnr, winid, new_zones)
  local key = bufnr .. ":" .. winid
  local old = _prefetched_zones[key]
  _prefetched_zones[key] = new_zones

  if not old then return true, true end
  local above_changed = old.above.start_line ~= new_zones.above.start_line
    or old.above.end_line ~= new_zones.above.end_line
  local below_changed = old.below.start_line ~= new_zones.below.start_line
    or old.below.end_line ~= new_zones.below.end_line
  return above_changed, below_changed
end

-- ---------------------------------------------------------------------------
-- State cleanup
-- ---------------------------------------------------------------------------

--- Clear all prefetch and viewport state for a buffer (or buffer+window).
--- @param bufnr number
--- @param winid? number
function M.clear_state(bufnr, winid)
  M.cancel_prefetch(bufnr, winid)
  if winid then
    local key = bufnr .. ":" .. winid
    _prefetched_zones[key] = nil
    _ranges[winid] = nil
    _prev_ranges[winid] = nil
  else
    for k, _ in pairs(_prefetched_zones) do
      if k:match("^" .. bufnr .. ":") then
        _prefetched_zones[k] = nil
      end
    end
  end
end

return M
