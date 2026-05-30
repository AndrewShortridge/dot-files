local config = require("andrew.vault.config")

--- Preview navigation history (browser-style back/forward).
local M = {}

---@class PreviewHistory
---@field entries PreviewTarget[]
---@field cursor number
---@field max_size number

M.entries = {}
M.cursor = 0
M.max_size = config.preview.history_max

--- Push a target onto the history stack.
--- If the cursor is mid-stack, truncate forward entries (browser-style).
---@param target PreviewTarget
function M.push(target)
  if M.cursor < #M.entries then
    for i = #M.entries, M.cursor + 1, -1 do
      M.entries[i] = nil
    end
  end

  if #M.entries >= M.max_size then
    table.remove(M.entries, 1)
  end

  M.entries[#M.entries + 1] = target
  M.cursor = #M.entries
end

--- Navigate backward in history. Returns the target to display, or nil.
---@return PreviewTarget|nil
function M.pop_back()
  if M.cursor <= 1 then
    return nil
  end
  M.cursor = M.cursor - 1
  return M.entries[M.cursor]
end

--- Navigate forward in history. Returns the target to display, or nil.
---@return PreviewTarget|nil
function M.pop_forward()
  if M.cursor >= #M.entries then
    return nil
  end
  M.cursor = M.cursor + 1
  return M.entries[M.cursor]
end

--- Clear all history entries.
function M.clear()
  M.entries = {}
  M.cursor = 0
end

--- Return the current history entry.
---@return PreviewTarget|nil
function M.current()
  return M.entries[M.cursor]
end

--- Return a human-readable position string, e.g., "[3/7]".
--- Empty string if only one entry.
---@return string
function M.position()
  if #M.entries <= 1 then
    return ""
  end
  return "[" .. M.cursor .. "/" .. #M.entries .. "]"
end

return M
