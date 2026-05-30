--- Layer 0: Per-buffer dirty line tracking via on_bytes.
---
--- Tracks which lines changed since the last pipeline consume, enabling
--- incremental re-parsing in Layer 1. When line count changes (insertions/
--- deletions), signals a full reparse since line-keyed caches become stale.

local M = {}

--- Per-buffer dirty line tracking.
---@type table<number, { tick: number, dirty: table<number, true>, full: boolean }>
local _buffers = {}

--- Attach on_bytes callback to a buffer for fine-grained change tracking.
---@param bufnr number
function M.attach(bufnr)
  if _buffers[bufnr] then return end
  _buffers[bufnr] = { tick = 0, dirty = {}, full = true }

  vim.api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(_, buf, tick, start_row, _, _, old_end_row, _, _, new_end_row, _, _)
      local state = _buffers[buf]
      if not state then return true end -- detach

      state.tick = tick

      if old_end_row ~= new_end_row then
        -- Line count changed: mark everything from start_row onward as dirty
        -- (line numbers shifted, cached tokens for later lines are stale)
        state.full = true
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

--- Get dirty lines since last consume, then clear dirty set.
--- Returns nil if a full reparse is needed (line count changed).
---@param bufnr number
---@return number[]|nil dirty_lines nil means full reparse needed
function M.consume(bufnr)
  local state = _buffers[bufnr]
  if not state then return nil end

  if state.full then
    state.full = false
    state.dirty = {}
    return nil -- caller must do full parse
  end

  local lines = vim.tbl_keys(state.dirty)
  table.sort(lines)
  state.dirty = {}
  return lines
end

--- Detach tracking from a buffer.
---@param bufnr number
function M.detach(bufnr)
  _buffers[bufnr] = nil
end

return M
