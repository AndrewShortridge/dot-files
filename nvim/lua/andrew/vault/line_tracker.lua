--- Layer 0: Per-buffer dirty line tracking via on_bytes.
---
--- Tracks which lines changed since the last pipeline consume, enabling
--- incremental re-parsing in Layer 1. On a line-count change (insertion/
--- deletion) it records a bounded dirty region plus a row-shift op so the
--- line-number-keyed caches can be renumbered by the +/-N delta instead of
--- triggering a whole-buffer reparse. The full-reparse fallback is retained
--- as a safety hatch (unsafe math) and via the `bounded_dirty` config flag.

local M = {}

--- A pending row-shift op produced by an insert/delete edit.
---@class LineShift
---@field start_row number 0-indexed post-edit row where the shift begins
---@field delta number net rows inserted (>0) or deleted (<0)
---@field old_end_row number rows spanned by the OLD (replaced) text, relative
---  to start_row. The span [start_row, start_row+old_end_row] was directly
---  replaced; extmarks on those rows are NOT auto-tracked by `delta` and must
---  be recreated rather than renumbered (see render_diff.shift_lines).

--- Per-buffer dirty line tracking.
---@type table<number, { tick: number, dirty: table<number, true>, full: boolean, shifts: LineShift[] }>
local _buffers = {}

--- Attach on_bytes callback to a buffer for fine-grained change tracking.
---@param bufnr number
function M.attach(bufnr)
  if _buffers[bufnr] then return end
  _buffers[bufnr] = { tick = 0, dirty = {}, full = true, shifts = {} }

  local config = require("andrew.vault.config")

  vim.api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(_, buf, tick, start_row, _, _, old_end_row, _, _, new_end_row, _, _)
      local state = _buffers[buf]
      if not state then return true end -- detach

      state.tick = tick

      -- on_bytes semantics: old_end_row/new_end_row are DELTAS relative to
      -- start_row (rows spanned by the change), not absolute line numbers.
      if old_end_row ~= new_end_row then
        -- Line count changed.
        local bounded = config.pipeline.bounded_dirty
        if bounded == nil then bounded = true end
        if not bounded or start_row < 0 then
          -- Kill-switch / unsafe math: fall back to full reparse.
          state.full = true
        else
          -- Record a bounded dirty region (post-edit rows that now exist in
          -- the edited span) plus a row-shift op so downstream caches can be
          -- renumbered by the delta instead of fully reparsed.
          local delta = new_end_row - old_end_row
          state.shifts[#state.shifts + 1] =
            { start_row = start_row, delta = delta, old_end_row = old_end_row }

          -- Renumber already-pending dirty rows by this delta so the accumulated
          -- dirty set stays in final (post-edit) coordinates, matching the caches
          -- that transform_pipeline.run renumbers via the same shift ops. Rows in
          -- the vacated range (delta<0) are dropped. Mirrors the predicate used in
          -- line_parse_cache.shift_lines / render_diff.shift_lines so dirty and
          -- caches stay in lockstep across multiple edits in one consume window.
          local shifted = {}
          for row in pairs(state.dirty) do
            if row >= start_row then
              local nr = row + delta
              if nr >= start_row then shifted[nr] = true end
              -- else: row fell into the deleted/vacated region — drop it
            else
              shifted[row] = true
            end
          end
          state.dirty = shifted

          for row = start_row, start_row + new_end_row do
            state.dirty[row] = true
          end
        end
      else
        -- In-place edit: only mark affected lines
        for row = start_row, start_row + math.max(old_end_row, new_end_row) do
          state.dirty[row] = true
        end
      end
    end,

    on_detach = function(_, buf)
      _buffers[buf] = nil
    end,
  })
end

--- Get dirty lines and pending row-shifts since last consume, then clear them.
--- Returns nil for dirty_lines if a full reparse is needed (safety hatch or
--- `bounded_dirty=false`); in that case shifts is also cleared/nil. Otherwise
--- returns the sorted dirty list plus the ordered shift ops (apply in order to
--- renumber the line-keyed caches before re-parsing the dirty region).
---@param bufnr number
---@return number[]|nil dirty_lines nil means full reparse needed
---@return LineShift[]|nil shifts ordered row-shift ops, or nil on full reparse
function M.consume(bufnr)
  local state = _buffers[bufnr]
  if not state then return nil, nil end

  if state.full then
    state.full = false
    state.dirty = {}
    state.shifts = {}
    return nil, nil -- caller must do full parse
  end

  local lines = vim.tbl_keys(state.dirty)
  table.sort(lines)
  state.dirty = {}

  local shifts = state.shifts
  state.shifts = {}
  if #shifts == 0 then shifts = nil end
  return lines, shifts
end

--- Detach tracking from a buffer.
---@param bufnr number
function M.detach(bufnr)
  _buffers[bufnr] = nil
end

return M
