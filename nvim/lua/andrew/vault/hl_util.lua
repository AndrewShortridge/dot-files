-- hl_util.lua
-- Shared helper for applying highlight extmarks across vault UI modules.
--
-- Every call site builds the SAME opts table via build_opts() so the resulting
-- extmark options are byte-identical to the inline tables they replaced.
--
-- Two shapes are supported, selected by col_end:
--   RANGE      (col_end ~= -1): { end_row = row,     end_col = col_end, hl_group = group }
--   WHOLE-LINE (col_end == -1): { end_row = row + 1, end_col = 0,       hl_group = group }
--
-- Each caller passes its OWN namespace (ns) — namespaces are never merged.

local M = {}

--- Build the extmark opts table, reproducing the inline conditional used at
--- every original call site exactly.
---@param group string highlight group
---@param row integer 0-indexed start row
---@param col_end integer end column, or -1 for a whole-line highlight
---@param extra table|nil optional extra opts merged in (forward-compat; unused today)
---@return table
local function build_opts(group, row, col_end, extra)
  local opts
  if col_end == -1 then
    opts = { end_row = row + 1, end_col = 0, hl_group = group }
  else
    opts = { end_row = row, end_col = col_end, hl_group = group }
  end
  if extra ~= nil then
    for k, v in pairs(extra) do
      opts[k] = v
    end
  end
  return opts
end

--- Apply a highlight extmark (raw; errors propagate as with a direct call).
---@param buf integer buffer handle
---@param ns integer namespace id
---@param group string highlight group
---@param row integer 0-indexed start row
---@param col_start integer 0-indexed start column
---@param col_end integer end column, or -1 for a whole-line highlight
---@param extra table|nil optional extra opts
---@return integer extmark_id
function M.add(buf, ns, group, row, col_start, col_end, extra)
  return vim.api.nvim_buf_set_extmark(buf, ns, row, col_start, build_opts(group, row, col_end, extra))
end

--- Apply a highlight extmark, pcall-wrapped (matches sites that guarded the
--- call). Returns the pcall results so callers can keep their own error logging.
---@param buf integer buffer handle
---@param ns integer namespace id
---@param group string highlight group
---@param row integer 0-indexed start row
---@param col_start integer 0-indexed start column
---@param col_end integer end column, or -1 for a whole-line highlight
---@param extra table|nil optional extra opts
---@return boolean ok
---@return any result extmark_id on success, error message on failure
function M.add_safe(buf, ns, group, row, col_start, col_end, extra)
  return pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col_start, build_opts(group, row, col_end, extra))
end

return M
