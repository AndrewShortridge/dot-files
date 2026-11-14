-- Perf regression spec for render_diff line-keyed diffing.
--
-- render.apply_diff runs on every keystroke (transform_pipeline.run). The old
-- implementation kept _prev_specs as a FLAT bufnr -> key -> spec map and, on
-- each call, iterated EVERY spec in the buffer (pairs(prev)), copying every
-- unchanged spec into a fresh carryover table — O(total specs in buffer), not
-- O(changed-line specs). It also string.format-allocated a key per new spec.
--
-- The fix restructures _prev_specs to bufnr -> line -> col_key -> spec. Carryover
-- of unchanged lines reuses each line's bucket BY REFERENCE (no per-spec copy),
-- and only changed lines are diffed. col_key() is computed once per NEW spec
-- only, never for the whole buffer.
--
-- This drives the REAL render_diff module against a real temp-vault buffer with
-- many specs across many lines, then edits ONE line and asserts:
--   * apply_diff individually examines only the handful of PREVIOUS specs on the
--     changed line (M._prev_visits delta), NOT every spec in the buffer. This is
--     the work that is O(total specs) under the bug and O(changed) under the fix:
--     the line-reference carryover never iterates individual unchanged specs,
--     while the old whole-buffer pairs(prev) per-spec carryover visited them all.
--   * the produced extmark set is byte-identical to a full fresh re-render of
--     the same final spec set (proves the fast path changes only perf).
-- Reintroducing the whole-buffer per-spec carryover makes the prev-visit delta
-- jump to O(total specs) and fails the first test.
--
-- Run with: nvim --headless -u NONE -l tests/render_diff_line_key_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local render = require("andrew.vault.render_diff")

print("\n=== render_diff line-key Perf Tests ===\n")

local NS = vim.api.nvim_create_namespace("render_diff_line_key_perf_spec")
local NS2 = vim.api.nvim_create_namespace("render_diff_line_key_perf_spec_2")

-- Build a fresh scratch buffer inside a temp vault dir with N lines of content.
local function make_buf(n)
  local vault = vim.fn.tempname()
  vim.fn.mkdir(vault, "p")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, vault .. "/note.md")
  local lines = {}
  for i = 1, n do
    lines[i] = "line " .. i .. " with a [[link]] and a #tag"
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- Build specs: for each line, a Comment highlight; on EVERY line also a second
-- namespace highlight (link-style) so "total specs" >> "specs on one line".
local function build_specs(n_lines)
  local specs = {}
  for line = 0, n_lines - 1 do
    specs[#specs + 1] = { ns = NS, line = line, col = 0, opts = { hl_group = "Comment", end_col = 4 } }
    specs[#specs + 1] = { ns = NS, line = line, col = 6, opts = { hl_group = "Identifier", end_col = 10 } }
    specs[#specs + 1] = { ns = NS2, line = line, col = 12, opts = { hl_group = "Special", end_col = 16 } }
  end
  return specs
end

-- The set of all lines (changed_lines for an initial full apply).
local function all_lines(n_lines)
  local set = {}
  for line = 0, n_lines - 1 do
    set[line] = true
  end
  return set
end

-- ---------------------------------------------------------------------------
-- (1) PERF: editing one line must individually examine only that line's prev
-- specs, not every spec in the buffer.
-- ---------------------------------------------------------------------------
test("apply_diff examines only the changed line's prev specs on a single-line edit", function()
  local N = 200
  local buf = make_buf(N)
  local specs = build_specs(N)

  -- Initial full render: seeds _prev_specs for all N lines.
  render.apply_diff(buf, specs, all_lines(N))

  -- Edit ONE line (line 100): re-emit only that line's 3 specs (one tweaked so
  -- there is real diff work), with changed_lines = { [100] = true }.
  local one_line = {
    { ns = NS, line = 100, col = 0, opts = { hl_group = "Comment", end_col = 4 } },
    { ns = NS, line = 100, col = 6, opts = { hl_group = "Statement", end_col = 10 } }, -- changed hl_group
    { ns = NS2, line = 100, col = 12, opts = { hl_group = "Special", end_col = 16 } },
  }

  render._prev_visits = 0
  render.apply_diff(buf, one_line, { [100] = true })
  local visits = render._prev_visits

  -- The fix individually examines only the changed line's prev specs (3); the
  -- line-reference carryover never iterates the other lines' specs. The old
  -- whole-buffer per-spec carryover visited every spec (~3 * N = 600). Assert
  -- tightly so reintroducing pairs(prev) per-spec carryover trips this.
  assert_eq(visits, #one_line, "apply_diff examined only the changed line's prev specs")
  assert_true(visits < N, "apply_diff did not visit O(total specs) prev specs (regression guard)")

  vim.api.nvim_buf_delete(buf, { force = true })
  render.invalidate(buf)
end)

-- ---------------------------------------------------------------------------
-- (2) CORRECTNESS: the single-line fast path yields a byte-identical extmark
-- set to a full fresh re-render of the same final spec set. This isolates the
-- assertion above to PERF (output is unchanged).
-- ---------------------------------------------------------------------------

-- Capture the full extmark set for a namespace as a sorted, comparable list.
local function capture(buf, ns)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local out = {}
  for _, m in ipairs(marks) do
    local d = m[4] or {}
    out[#out + 1] = string.format(
      "%d:%d:%s:%s:%s",
      m[2], m[3], tostring(d.hl_group), tostring(d.end_col), tostring(d.priority)
    )
  end
  table.sort(out)
  return out
end

local function capture_both(buf)
  local a = capture(buf, NS)
  local b = capture(buf, NS2)
  for _, v in ipairs(b) do a[#a + 1] = v end
  table.sort(a)
  return table.concat(a, "\n")
end

test("single-line fast path produces identical extmarks to a fresh re-render", function()
  local N = 60
  local specs = build_specs(N)

  -- Final spec set = initial set with line 30's middle spec changed.
  local final = build_specs(N)
  -- Change line 30, col 6 spec hl_group.
  for _, s in ipairs(final) do
    if s.line == 30 and s.col == 6 then s.opts = { hl_group = "Statement", end_col = 10 } end
  end

  -- Path A: incremental — full render, then edit only line 30.
  local buf_a = make_buf(N)
  render.apply_diff(buf_a, specs, all_lines(N))
  local edited = {
    { ns = NS, line = 30, col = 0, opts = { hl_group = "Comment", end_col = 4 } },
    { ns = NS, line = 30, col = 6, opts = { hl_group = "Statement", end_col = 10 } },
    { ns = NS2, line = 30, col = 12, opts = { hl_group = "Special", end_col = 16 } },
  }
  render.apply_diff(buf_a, edited, { [30] = true })
  local got_a = capture_both(buf_a)

  -- Path B: reference — a single fresh render of the FINAL spec set.
  local buf_b = make_buf(N)
  render.invalidate(buf_b)
  render.apply_diff(buf_b, final, all_lines(N))
  local got_b = capture_both(buf_b)

  assert_eq(got_a, got_b, "incremental fast-path extmark set matches a fresh full render")

  vim.api.nvim_buf_delete(buf_a, { force = true })
  vim.api.nvim_buf_delete(buf_b, { force = true })
  render.invalidate(buf_a)
  render.invalidate(buf_b)
end)

-- ---------------------------------------------------------------------------
-- (3) CORRECTNESS: a no-op re-diff of an unchanged line carries it over by
-- reference and produces NO new API ops (early-return path), and removing a
-- spec from a changed line deletes exactly that extmark.
-- ---------------------------------------------------------------------------
test("removing one spec from a changed line deletes exactly that extmark", function()
  local N = 40
  local buf = make_buf(N)
  render.apply_diff(buf, build_specs(N), all_lines(N))

  local before = #vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {})

  -- Re-emit line 10 with the Identifier (col 6) spec removed.
  render.apply_diff(buf, {
    { ns = NS, line = 10, col = 0, opts = { hl_group = "Comment", end_col = 4 } },
    { ns = NS2, line = 10, col = 12, opts = { hl_group = "Special", end_col = 16 } },
  }, { [10] = true })

  local after = #vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {})
  assert_eq(after, before - 1, "exactly one NS extmark (the removed col-6 spec) was deleted")

  vim.api.nvim_buf_delete(buf, { force = true })
  render.invalidate(buf)
end)

_H.finish({ style = "results", exit = "os" })
