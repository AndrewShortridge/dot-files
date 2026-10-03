--- Layer 3: Render Instruction Diffing — minimizes extmark API calls.
---
--- Generates extmark specifications from resolved tokens, then diffs against
--- the previous set to only set/delete extmarks that actually changed.
--- All operations are batched via nvim_call_atomic to minimize Lua→C crossings.

local config = require("andrew.vault.config")

local M = {}

---@class ExtmarkSpec
---@field ns number namespace id
---@field line number 0-indexed
---@field col number 0-indexed start column
---@field opts table extmark options (hl_group, end_col, priority, hl_mode, etc.)
---@field key string unique identity for diffing
---@field _id? number extmark id (set after nvim_buf_set_extmark)

---@type table<number, table<number, table<string, ExtmarkSpec>>> -- bufnr -> line -> col_key -> spec
local _prev_specs = {}

--- Test-only counter: number of PREVIOUS specs individually examined per
--- apply_diff (carryover/removal scan). The fix touches only changed-line specs
--- (O(changed)); the old whole-buffer pairs(prev) carryover touched every spec
--- (O(total)). Used by the render_diff line-key perf regression spec.
M._prev_visits = 0

--- Test-only counter: number of NEW specs staged into per-line buckets per
--- apply_diff. Under the fix this is O(#new specs) (only dirty lines touched).
--- The old whole-buffer carryover loop rebuilt next_prev by iterating every
--- cached LINE (O(total)); reintroducing that loop with a counter would push
--- this to ~N, so the carryover perf regression spec asserts it stays bounded
--- by #new_specs on a single-line edit.
M._carryover_visits = 0

--- Compute a per-line identity key for an extmark spec (for diffing). The spec's
--- line is the OUTER key in _prev_specs, so it is excluded here. ns stays in the
--- key: multiple consumers register distinct namespaces on the same line.
---@param spec ExtmarkSpec
---@return string
local function col_key(spec)
  local type_tag = spec.opts.hl_group
    or (spec.opts.virt_text and "vt")
    or (spec.opts.virt_lines and "vl")
    or "other"
  return spec.ns .. ":" .. spec.col .. ":" .. type_tag .. ":" .. (spec.opts.end_col or "-")
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

  -- Idle no-op fast path: scroll-throttle ticks call apply_diff(buf, {}, {})
  -- with nothing changed and no new specs, so there is nothing to diff. Skip the
  -- whole carryover/diff entirely, but keep the table identity stable so
  -- shift_lines / first-call callers see a registered (possibly empty) table.
  if #new_specs == 0 and next(changed_lines) == nil then
    _prev_specs[bufnr] = prev
    return
  end

  -- Stage new per-line buckets for DIRTY lines only. Do NOT touch `prev` yet —
  -- the diff loop below reads prev[line] as the OLD bucket. `new_buckets` starts
  -- empty, so a re-emitted line always gets a FRESH bucket (old specs replaced),
  -- and duplicate col_keys collapse last-wins. O(#new specs), no full-table copy.
  -- `dirty_lines` is the set of lines to diff: changed lines plus any line that
  -- actually carries a new spec (the latter normally a subset of changed_lines).
  local dirty_lines = {}
  for line in pairs(changed_lines) do
    dirty_lines[line] = true
  end
  local new_buckets = {}
  for _, spec in ipairs(new_specs) do
    M._carryover_visits = M._carryover_visits + 1 -- test-only counter (perf regression spec)
    local bucket = new_buckets[spec.line]
    if not bucket then
      bucket = {}
      new_buckets[spec.line] = bucket
    end
    bucket[col_key(spec)] = spec
    dirty_lines[spec.line] = true
  end

  -- Collect delete and set operations
  local del_ops = {}
  local set_ops = {}

  -- Diff only dirty lines: their old bucket (prev[line]) vs the staged new bucket.
  for line in pairs(dirty_lines) do
    local old_bucket = prev[line]
    local new_bucket = new_buckets[line]
    -- A changed line with new specs has a fresh bucket (~= old_bucket); a changed
    -- line with no new specs has no bucket at all (its old specs are all deleted).
    if old_bucket and old_bucket ~= new_bucket then
      -- Removed: old specs absent from the new bucket.
      for k, old_spec in pairs(old_bucket) do
        M._prev_visits = M._prev_visits + 1 -- test-only counter (perf regression spec)
        if (not new_bucket or new_bucket[k] == nil) and old_spec._id then
          del_ops[#del_ops + 1] = { bufnr, old_spec.ns, old_spec._id }
        end
      end
    end
    if new_bucket then
      -- Set new/updated; reuse the old extmark id when opts are unchanged.
      for k, spec in pairs(new_bucket) do
        local old = old_bucket and old_bucket[k]
        if not old or not opts_equal(old.opts, spec.opts) then
          set_ops[#set_ops + 1] = { bufnr, spec.ns, spec.line, spec.col, spec.opts, k, spec }
        else
          spec._id = old._id -- reuse existing extmark id
        end
      end
    end
  end

  -- Commit dirty lines into `prev` IN PLACE. Unchanged lines stay untouched (no
  -- full-table rebuild). A changed line with no new specs gets prev[line] = nil
  -- (new_buckets[line] is nil), clearing its old bucket.
  for line in pairs(dirty_lines) do
    prev[line] = new_buckets[line]
  end
  _prev_specs[bufnr] = prev

  if #del_ops == 0 and #set_ops == 0 then
    return
  end

  local batch = config.pipeline and config.pipeline.batch_extmarks
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
end

--- Renumber cached extmark specs after an insert/delete of `delta` rows at
--- `start_row`. The diff map is keyed by line, so shifting a row just reassigns
--- the line's spec bucket under its new line number.
---
--- Extmarks below the directly-replaced span auto-track row position in nvim by
--- exactly `delta`, so for those specs we can bump spec.line and recompute the
--- key. But extmarks ON the replaced span (old rows [start_row, replaced_end])
--- are NOT auto-tracked by `delta` — nvim relocates them to the end of the
--- inserted block, not by the net delta. Renumbering such a spec by `delta`
--- would leave its cached line out of sync with its real extmark, and a later
--- apply_diff that finds a matching key would reuse the stale id and render the
--- highlight on the wrong physical row. So specs in the replaced span are
--- DROPPED (and their extmarks deleted) — the bounded reparse re-emits them at
--- the correct rows via apply_diff. `old_end_row` is the rows spanned by the
--- replaced (old) text relative to start_row; it defaults to 0 so existing
--- callers (and the single-line/insert case) keep their prior behavior.
--- Specs whose shifted line would fall into a vacated region are also dropped.
---@param bufnr number
---@param start_row number 0-indexed row where the shift begins (post-edit)
---@param delta number net rows inserted (>0) or deleted (<0)
---@param old_end_row? number rows spanned by the replaced text (default 0)
function M.shift_lines(bufnr, start_row, delta, old_end_row)
  if delta == 0 then return end
  local prev = _prev_specs[bufnr]
  if not prev then return end

  local replaced_end = start_row + (old_end_row or 0)

  local rebuilt = {}
  for line, line_specs in pairs(prev) do
    if line < start_row then
      -- Above the edit: untouched (carry the whole line bucket by reference).
      rebuilt[line] = line_specs
    elseif line <= replaced_end then
      -- On the directly-replaced span: the extmarks are not auto-tracked by
      -- `delta`. Delete them and drop the bucket so apply_diff recreates fresh
      -- ones at the correct rows from the reparsed dirty region.
      for _, spec in pairs(line_specs) do
        if spec._id then
          pcall(vim.api.nvim_buf_del_extmark, bufnr, spec.ns, spec._id)
        end
      end
    else
      -- Strictly below the replaced span: auto-tracked by `delta`.
      local new_line = line + delta
      if new_line >= start_row then
        -- Reassign the bucket under its new line; bump each spec.line inside it.
        for _, spec in pairs(line_specs) do
          spec.line = new_line
        end
        rebuilt[new_line] = line_specs
      else
        -- Shifted into the vacated region (delete edits): remove the extmarks so
        -- they cannot auto-track onto a surviving row and duplicate on next diff.
        for _, spec in pairs(line_specs) do
          if spec._id then
            pcall(vim.api.nvim_buf_del_extmark, bufnr, spec.ns, spec._id)
          end
        end
      end
    end
  end
  _prev_specs[bufnr] = rebuilt
end

--- Invalidate all cached specs for a buffer.
---@param bufnr number
function M.invalidate(bufnr)
  _prev_specs[bufnr] = nil
end

return M
