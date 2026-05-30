--- Layer 3: Render Instruction Diffing — minimizes extmark API calls.
---
--- Generates extmark specifications from resolved tokens, then diffs against
--- the previous set to only set/delete extmarks that actually changed.
--- All operations are batched via nvim_call_atomic to minimize Lua→C crossings.

local M = {}

---@class ExtmarkSpec
---@field ns number namespace id
---@field line number 0-indexed
---@field col number 0-indexed start column
---@field opts table extmark options (hl_group, end_col, priority, hl_mode, etc.)
---@field key string unique identity for diffing
---@field _id? number extmark id (set after nvim_buf_set_extmark)

---@type table<number, table<string, ExtmarkSpec>> -- bufnr -> key -> spec
local _prev_specs = {}

--- Compute a unique key for an extmark spec (for diffing).
---@param spec ExtmarkSpec
---@return string
local function spec_key(spec)
  local type_tag = spec.opts.hl_group
    or (spec.opts.virt_text and "vt")
    or (spec.opts.virt_lines and "vl")
    or "other"
  return string.format("%d:%d:%d:%s:%s",
    spec.ns, spec.line, spec.col, type_tag,
    spec.opts.end_col or "-")
end

--- Compare two extmark option tables for equality.
---@param a table
---@param b table
---@return boolean
local function opts_equal(a, b)
  -- Fast path: identical hl_group and end_col covers most highlight extmarks
  if a.hl_group ~= b.hl_group then return false end
  if a.end_col ~= b.end_col then return false end
  if a.end_row ~= b.end_row then return false end
  if a.priority ~= b.priority then return false end
  return true
end

--- Pipeline stats: tracks batched vs individual API call counts.
---@type { batched_calls: number, individual_calls: number, atomic_failures: number }
M._stats = { batched_calls = 0, individual_calls = 0, atomic_failures = 0 }

--- Apply extmark operations individually (legacy path, no batching).
---@param del_ops table[] { bufnr, ns, id } tuples to delete
---@param set_ops table[] { bufnr, ns, line, col, opts, key, spec } tuples to set
local function apply_individual(del_ops, set_ops)
  for _, op in ipairs(del_ops) do
    pcall(vim.api.nvim_buf_del_extmark, op[1], op[2], op[3])
  end
  for _, op in ipairs(set_ops) do
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, op[1], op[2], op[3], op[4], op[5])
    if ok then op[7]._id = id end
  end
  M._stats.individual_calls = M._stats.individual_calls + #del_ops + #set_ops
end

--- Apply only the delta between old and new extmark specs for given lines.
--- Uses nvim_call_atomic to batch all set/del operations into one Lua→C call
--- when config.pipeline.batch_extmarks is true (default).
---@param bufnr number
---@param new_specs ExtmarkSpec[] new specifications for changed lines
---@param changed_lines table<number, true> set of lines that changed
function M.apply_diff(bufnr, new_specs, changed_lines)
  local prev = _prev_specs[bufnr] or {}
  local next_prev = {}

  -- Index new specs by key
  local new_by_key = {}
  for _, spec in ipairs(new_specs) do
    local key = spec_key(spec)
    new_by_key[key] = spec
    next_prev[key] = spec
  end

  -- Collect delete and set operations
  local del_ops = {}
  local set_ops = {}

  -- Remove old extmarks on changed lines that are no longer present
  for key, old_spec in pairs(prev) do
    if changed_lines[old_spec.line] then
      if not new_by_key[key] then
        if old_spec._id then
          del_ops[#del_ops + 1] = { bufnr, old_spec.ns, old_spec._id }
        end
      end
    else
      next_prev[key] = old_spec
    end
  end

  -- Set new/updated extmarks on changed lines
  for key, spec in pairs(new_by_key) do
    local old = prev[key]
    if not old or not opts_equal(old.opts, spec.opts) then
      set_ops[#set_ops + 1] = { bufnr, spec.ns, spec.line, spec.col, spec.opts, key, spec }
    else
      spec._id = old._id -- reuse existing extmark id
    end
  end

  if #del_ops == 0 and #set_ops == 0 then
    _prev_specs[bufnr] = next_prev
    return
  end

  local cfg = require("andrew.vault.config")
  local batch = cfg.pipeline and cfg.pipeline.batch_extmarks
  if batch == nil then batch = true end

  if batch then
    -- Build atomic call batch
    local calls = {}
    local set_map = {} -- call_index -> set_ops entry for ID extraction

    for _, op in ipairs(del_ops) do
      calls[#calls + 1] = { "nvim_buf_del_extmark", { op[1], op[2], op[3] } }
    end
    for _, op in ipairs(set_ops) do
      calls[#calls + 1] = { "nvim_buf_set_extmark", { op[1], op[2], op[3], op[4], op[5] } }
      set_map[#calls] = op
    end

    -- Execute all operations in one Lua→C boundary crossing
    local ok, result = pcall(vim.api.nvim_call_atomic, calls)
    if ok and result then
      local results = result[1] -- array of return values
      if results then
        for idx, op in pairs(set_map) do
          local ret = results[idx]
          if ret then
            op[7]._id = ret -- spec._id
          end
        end
      end
      M._stats.batched_calls = M._stats.batched_calls + 1  -- one nvim_call_atomic = one Lua→C crossing
    else
      -- Fallback: if nvim_call_atomic itself fails, try individual calls
      M._stats.atomic_failures = M._stats.atomic_failures + 1
      apply_individual(del_ops, set_ops)
    end
  else
    -- Individual pcall-wrapped calls (legacy path)
    apply_individual(del_ops, set_ops)
  end

  _prev_specs[bufnr] = next_prev
end

--- Invalidate all cached specs for a buffer.
---@param bufnr number
function M.invalidate(bufnr)
  _prev_specs[bufnr] = nil
end

return M
