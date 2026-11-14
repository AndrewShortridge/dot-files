-- Behavioral spec for the bounded-dirty / row-shift pipeline optimization.
-- Run with: nvim --headless -u NONE -l tests/line_tracker_shift_spec.lua
--
-- Drives the REAL line-keyed cache modules against temp buffers to assert:
--   * line_parse_cache.shift_lines renumbers .lines/.texts in lockstep on
--     insert (delta>0) and delete (delta<0), dropping the vacated range.
--   * semantic_resolution.shift_lines renumbers .resolved keys AND bumps each
--     ResolvedToken.line_nr stored inside the value.
--   * render_diff.shift_lines renumbers _prev_specs by recomputing spec_key
--     (which embeds spec.line) and bumps spec.line.
--   * line_tracker.consume returns (dirty_lines, shifts) on a line-count edit
--     instead of nil, and only the bounded edited region is marked dirty.
-- Assertions are behavioral (real module output via public API), not
-- source-introspection.

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- Stub the logger so requiring real modules doesn't pull full vault infra.
package.loaded["andrew.vault.vault_log"] = {
  scope = function()
    return setmetatable({}, { __index = function() return function() end end })
  end,
}

local line_parse = require("andrew.vault.line_parse_cache")
local semantic = require("andrew.vault.semantic_resolution")
local render = require("andrew.vault.render_diff")
local line_tracker = require("andrew.vault.line_tracker")

-- code_excl that never excludes (treat the whole buffer as prose).
local function no_code_excl() return false end

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- ---------------------------------------------------------------------------
-- line_parse_cache.shift_lines
-- ---------------------------------------------------------------------------

test("line_parse.shift_lines insert renumbers lines+texts above start_row", function()
  local buf = make_buf({ "#alpha", "plain", "#beta" })
  line_parse.update(buf, nil, no_code_excl) -- full parse, populate cache

  local cache = line_parse._get_cache()[buf]
  assert_true(cache ~= nil, "cache populated")
  -- baseline: line 0 has a tag, line 2 has a tag
  assert_eq(line_parse.get_line_tokens(buf, 0)[1].type, "tag")
  assert_eq(line_parse.get_line_tokens(buf, 2)[1].type, "tag")

  -- Simulate inserting 1 blank line at row 1 (delta = +1).
  line_parse.shift_lines(buf, 1, 1)

  -- Row 0 untouched (below start_row); rows 1,2 shifted to 2,3.
  assert_eq(line_parse.get_line_tokens(buf, 0)[1].type, "tag", "row 0 preserved")
  assert_eq(line_parse.get_line_tokens(buf, 1)[1], nil, "vacated row has no tokens")
  assert_eq(cache.texts[1], nil, "vacated text key cleared")
  assert_eq(cache.texts[3], "#beta", "beta text shifted to row 3")
  assert_eq(line_parse.get_line_tokens(buf, 3)[1].type, "tag", "beta tokens shifted to row 3")

  vim.api.nvim_buf_delete(buf, { force = true })
  line_parse.invalidate(buf)
end)

test("line_parse.shift_lines delete drops vacated range and renumbers", function()
  local buf = make_buf({ "#a", "#b", "#c", "#d" })
  line_parse.update(buf, nil, no_code_excl)
  local cache = line_parse._get_cache()[buf]

  -- Simulate deleting 1 line at row 1 (delta = -1): rows 2,3 -> 1,2.
  line_parse.shift_lines(buf, 1, -1)

  assert_eq(cache.texts[0], "#a", "row 0 preserved")
  assert_eq(cache.texts[1], "#c", "c shifted down to row 1")
  assert_eq(cache.texts[2], "#d", "d shifted down to row 2")
  assert_eq(cache.texts[3], nil, "old top row dropped")
  assert_eq(line_parse.get_line_tokens(buf, 1)[1].captures[1], "c", "c tokens at row 1")

  vim.api.nvim_buf_delete(buf, { force = true })
  line_parse.invalidate(buf)
end)

-- ---------------------------------------------------------------------------
-- semantic_resolution.shift_lines — bumps line_nr inside the value
-- ---------------------------------------------------------------------------

test("semantic.shift_lines renumbers keys and bumps ResolvedToken.line_nr", function()
  local buf = make_buf({ "#alpha", "plain", "#beta" })
  line_parse.update(buf, nil, no_code_excl)
  -- index=nil is tolerated by resolve (gen falls back to 0); tags resolve passthrough.
  semantic.resolve(buf, nil, line_parse, nil)

  -- baseline: row 2 resolved tag carries line_nr == 2
  local r2 = semantic.get_resolved(buf, 2)
  assert_true(#r2 >= 1, "row 2 has a resolved token")
  assert_eq(r2[1].line_nr, 2, "baseline line_nr")

  semantic.shift_lines(buf, 1, 1) -- insert one row at 1

  assert_eq(#semantic.get_resolved(buf, 2), 0, "vacated row cleared")
  local r3 = semantic.get_resolved(buf, 3)
  assert_true(#r3 >= 1, "tokens shifted to row 3")
  assert_eq(r3[1].line_nr, 3, "line_nr bumped to match new key")
  -- row 0 (below start_row) keeps its original line_nr
  assert_eq(semantic.get_resolved(buf, 0)[1].line_nr, 0, "row 0 line_nr preserved")

  vim.api.nvim_buf_delete(buf, { force = true })
  line_parse.invalidate(buf)
  semantic.invalidate(buf)
end)

-- ---------------------------------------------------------------------------
-- render_diff.shift_lines — recompute keys (embed spec.line) + bump spec.line
-- ---------------------------------------------------------------------------

test("render.shift_lines bumps spec.line and rekeys cached specs", function()
  local buf = make_buf({ "x", "x", "x", "x" })
  local ns = vim.api.nvim_create_namespace("line_tracker_shift_spec")
  -- Seed _prev_specs via apply_diff with specs on rows 0 and 2.
  local specs = {
    { ns = ns, line = 0, col = 0, opts = { hl_group = "Comment", end_col = 1 } },
    { ns = ns, line = 2, col = 0, opts = { hl_group = "Comment", end_col = 1 } },
  }
  render.apply_diff(buf, specs, { [0] = true, [2] = true })

  render.shift_lines(buf, 1, 1) -- insert one row at 1: row 2 -> 3

  -- Re-applying the same specs on the OLD lines should now treat the row-3
  -- spec as already present at its new key (no recreate), proving the rekey.
  -- We assert behaviorally: a second apply_diff with the shifted spec set is a
  -- no-op delta (the cached spec.line followed the shift).
  local shifted = {
    { ns = ns, line = 0, col = 0, opts = { hl_group = "Comment", end_col = 1 } },
    { ns = ns, line = 3, col = 0, opts = { hl_group = "Comment", end_col = 1 } },
  }
  -- changed_lines covers both rows; if the cache had NOT shifted, the row-3
  -- spec would be "new" and the stale row-2 spec would be deleted.
  local before = render._stats.individual_calls + render._stats.batched_calls
  render.apply_diff(buf, shifted, { [0] = true, [3] = true })
  -- No structural change expected -> the early-return (no del/set) path keeps
  -- stat counters unchanged.
  local after = render._stats.individual_calls + render._stats.batched_calls
  assert_eq(after, before, "shifted spec set produced a no-op diff")

  vim.api.nvim_buf_delete(buf, { force = true })
  render.invalidate(buf)
end)

-- ---------------------------------------------------------------------------
-- line_tracker.consume contract — bounded dirty + shifts on a line-count edit
-- ---------------------------------------------------------------------------

test("line_tracker.consume returns bounded dirty + shift on insert (not nil)", function()
  local buf = make_buf({ "one", "two", "three" })
  line_tracker.attach(buf)
  line_tracker.consume(buf) -- clear the initial full=true state

  -- Insert a newline at row 1: split "two" -> on_bytes fires a line-count edit.
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "tw", "o" })

  local dirty, shifts = line_tracker.consume(buf)
  assert_true(dirty ~= nil, "line-count edit no longer forces full reparse (dirty not nil)")
  assert_true(shifts ~= nil and #shifts >= 1, "a shift op was recorded")
  -- net delta across shifts must equal +1 (one line added).
  local net = 0
  for _, s in ipairs(shifts) do net = net + s.delta end
  assert_eq(net, 1, "net row delta == +1")

  line_tracker.detach(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("line_tracker.consume bounded_dirty=false falls back to full reparse", function()
  local config = require("andrew.vault.config")
  local prev = config.pipeline.bounded_dirty
  config.pipeline.bounded_dirty = false

  local buf = make_buf({ "a", "b", "c" })
  line_tracker.attach(buf)
  line_tracker.consume(buf) -- clear initial full state

  vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "inserted" }) -- line-count edit

  local dirty, shifts = line_tracker.consume(buf)
  assert_nil(dirty, "kill-switch forces full reparse (dirty nil)")
  assert_nil(shifts, "no shifts on full reparse")

  config.pipeline.bounded_dirty = prev
  line_tracker.detach(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ---------------------------------------------------------------------------
-- (3a) Multi-edit-then-single-consume: TWO line-count edits before one consume.
-- The accumulated dirty set must stay in FINAL post-edit coordinates so the
-- genuinely-changed inserted rows are covered, matching the caches that the
-- pipeline renumbers via the same shift ops. Drives the REAL line_parse cache
-- in the exact order transform_pipeline.run uses (apply shifts, then update).
-- ---------------------------------------------------------------------------

test("line_tracker multi-edit before single consume keeps dirty in final coords", function()
  local buf = make_buf({ "L0", "L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8" })
  line_parse.update(buf, nil, no_code_excl) -- seed the cache (full parse)
  line_tracker.attach(buf)
  line_tracker.consume(buf) -- clear the initial full=true state

  -- Edit A: split row 7 into two lines ( +1 @ row 7 ).
  vim.api.nvim_buf_set_lines(buf, 7, 8, false, { "L7a", "L7b" })
  -- Edit B: delete 2 rows at row 1 ( -2 @ row 1 ). No consume in between.
  vim.api.nvim_buf_set_lines(buf, 1, 3, false, {})

  local dirty, shifts = line_tracker.consume(buf)
  assert_true(dirty ~= nil, "multi-edit still incremental (dirty not nil)")
  assert_true(shifts ~= nil and #shifts == 2, "two shift ops recorded")

  -- The inserted content (L7a/L7b) ends up at FINAL rows 5,6 after the -2
  -- delete at row 1. Those rows MUST be in the dirty set.
  local dset = {}
  for _, ln in ipairs(dirty) do dset[ln] = true end
  assert_true(dset[5], "inserted row 5 is dirty (final coords)")
  assert_true(dset[6], "inserted row 6 is dirty (final coords)")

  -- Behavioral: drive the real line_parse cache exactly like the pipeline does,
  -- applying the shifts (in order) before the incremental update over `dirty`.
  for _, s in ipairs(shifts) do
    line_parse.shift_lines(buf, s.start_row, s.delta)
  end
  line_parse.update(buf, dirty, no_code_excl)

  -- After reparse the inserted rows must reflect the new line content. With the
  -- bug live, rows 5,6 are absent from dirty → not reparsed → stale text.
  local cache = line_parse._get_cache()[buf]
  assert_eq(cache.texts[5], "L7a", "row 5 text reparsed to inserted content")
  assert_eq(cache.texts[6], "L7b", "row 6 text reparsed to inserted content")

  line_tracker.detach(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  line_parse.invalidate(buf)
end)

-- ---------------------------------------------------------------------------
-- (3b) render_diff delete-leak: a spec dropped into the vacated region must
-- have its underlying extmark deleted, else it auto-tracks to a surviving row
-- and the next apply_diff duplicates it. Asserts real buffer extmark counts.
-- ---------------------------------------------------------------------------

test("render.shift_lines delete drops vacated spec extmark (no leak)", function()
  local buf = make_buf({ "x", "x", "x" })
  local ns = vim.api.nvim_create_namespace("line_tracker_shift_spec_del")

  -- Seed _prev_specs with one highlight extmark per row 0,1,2.
  local specs = {
    { ns = ns, line = 0, col = 0, opts = { hl_group = "Comment", end_col = 1 } },
    { ns = ns, line = 1, col = 0, opts = { hl_group = "Comment", end_col = 1 } },
    { ns = ns, line = 2, col = 0, opts = { hl_group = "Comment", end_col = 1 } },
  }
  render.apply_diff(buf, specs, { [0] = true, [1] = true, [2] = true })
  assert_eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 3, "3 extmarks seeded")

  -- Simulate dd of row 0: the row-0 spec falls into the vacated region.
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
  render.shift_lines(buf, 0, -1)

  -- Re-diff with the two surviving specs now on rows 0,1.
  local shifted = {
    { ns = ns, line = 0, col = 0, opts = { hl_group = "Comment", end_col = 1 } },
    { ns = ns, line = 1, col = 0, opts = { hl_group = "Comment", end_col = 1 } },
  }
  render.apply_diff(buf, shifted, { [0] = true, [1] = true })

  -- With the leak fixed, the orphaned row-0 extmark was deleted in shift_lines,
  -- so exactly 2 extmarks remain (no duplicate). With the bug live, 3 remain.
  assert_eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 2, "no leaked extmark after delete")

  vim.api.nvim_buf_delete(buf, { force = true })
  render.invalidate(buf)
end)

-- ---------------------------------------------------------------------------
-- (3c) render_diff replaced-span reuse: a multi-line edit that deletes-and-
-- reinserts the row carrying an extmark must NOT renumber that spec by `delta`.
-- nvim relocates the replaced-row extmark to the end of the inserted block, not
-- by the net delta, so renumbering would leave the cached spec.line out of sync
-- with the real extmark. If a later render produces an identical key at the
-- delta-shifted line, apply_diff would reuse the stale id and render on the
-- wrong physical row. The fix drops specs in the replaced span and recreates
-- them. Asserts the real extmark lands on the intended row.
-- ---------------------------------------------------------------------------

test("render.shift_lines replaced span recreates extmark on correct row", function()
  -- Buffer {a, b, HL, d}; highlight extmark on row 2 ("HL").
  local buf = make_buf({ "a", "b", "HL", "d" })
  local ns = vim.api.nvim_create_namespace("line_tracker_shift_spec_replace")
  render.apply_diff(buf, {
    { ns = ns, line = 2, col = 0, opts = { hl_group = "Comment", end_col = 1 } },
  }, { [2] = true })
  assert_eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 1, "1 extmark seeded on row 2")

  -- Multi-line paste replacing row 2 with {R1, R2, HL}: the old row 2 is the
  -- directly-replaced span (start_row=2, old_end_row=0, new_end_row=2,
  -- delta=+2). The HL content now lives at row 4.
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "R1", "R2", "HL" })
  render.shift_lines(buf, 2, 2, 0) -- old_end_row=0 → span [2,2] is replaced

  -- The next render re-emits HL at its true row 4. With the bug (delta bump of
  -- the replaced-span spec → cached line 4 but real extmark relocated to 5),
  -- apply_diff would match the key at line 4 and REUSE the stale id, leaving the
  -- highlight on the wrong row. With the fix the old spec was dropped+deleted,
  -- so apply_diff creates a fresh extmark at row 4.
  render.apply_diff(buf, {
    { ns = ns, line = 4, col = 0, opts = { hl_group = "Comment", end_col = 1 } },
  }, { [4] = true })

  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  assert_eq(#marks, 1, "exactly one extmark after replace+rerender (no leak)")
  -- marks[1] = { id, row, col, details }
  assert_eq(marks[1][2], 4, "highlight lands on the correct physical row (4)")

  vim.api.nvim_buf_delete(buf, { force = true })
  render.invalidate(buf)
end)

_H.finish({ style = "results", exit = "os" })
