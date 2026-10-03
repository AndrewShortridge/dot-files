-- Perf regression spec for render_diff carryover / idle-scroll early-out.
--
-- render.apply_diff runs on EVERY keystroke (transform_pipeline.run) AND on
-- every scroll-throttle tick (highlight_coordinator.on_win_scrolled). The old
-- implementation, on each call, allocated a fresh `next_prev = {}` and ran a
-- carryover loop over EVERY cached LINE (pairs(prev)), splicing unchanged lines
-- into the new table — O(total cached-spec lines) per call, even when nothing
-- changed (idle scroll passes apply_diff(buf, {}, {})).
--
-- The fix:
--   (1) Early-out at the top when #new_specs == 0 and changed_lines is empty —
--       kills the whole rebuild on idle scroll-throttle ticks.
--   (2) Mutate `prev` IN PLACE for dirty lines only (no full next_prev rebuild),
--       so the call is O(#dirty lines) and allocates no full-table copy.
--
-- This drives the REAL render_diff module against a real temp-vault buffer.
-- M._carryover_visits counts work that is O(#new specs) under the fix (it is
-- incremented per NEW spec staged) and would be O(total cached lines) under the
-- old whole-buffer carryover (incrementing per carried-over line). Reintroducing
-- the pairs(prev) carryover (with the counter there) makes test 1 jump to ~N and
-- removing the early-out makes test 2's counters non-zero — both fail.
--
-- Run with: nvim --headless -u NONE -l tests/render_diff_carryover_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local render = require("andrew.vault.render_diff")

print("\n=== render_diff carryover / early-out Perf Tests ===\n")

local NS = vim.api.nvim_create_namespace("render_diff_carryover_perf_spec")
local NS2 = vim.api.nvim_create_namespace("render_diff_carryover_perf_spec_2")

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

local function build_specs(n_lines)
  local specs = {}
  for line = 0, n_lines - 1 do
    specs[#specs + 1] = { ns = NS, line = line, col = 0, opts = { hl_group = "Comment", end_col = 4 } }
    specs[#specs + 1] = { ns = NS, line = line, col = 6, opts = { hl_group = "Identifier", end_col = 10 } }
    specs[#specs + 1] = { ns = NS2, line = line, col = 12, opts = { hl_group = "Special", end_col = 16 } }
  end
  return specs
end

local function all_lines(n_lines)
  local set = {}
  for line = 0, n_lines - 1 do
    set[line] = true
  end
  return set
end

-- ---------------------------------------------------------------------------
-- (1) PERF: editing one line stages only that line's new specs; the carryover
-- of unchanged lines is never iterated. _carryover_visits == #new_specs, NOT N.
-- ---------------------------------------------------------------------------
test("apply_diff stages only the changed line's specs on a single-line edit", function()
  local N = 200
  local buf = make_buf(N)

  -- Initial full render seeds _prev_specs for all N lines (3 specs each).
  render.apply_diff(buf, build_specs(N), all_lines(N))

  local one_line = {
    { ns = NS, line = 100, col = 0, opts = { hl_group = "Comment", end_col = 4 } },
    { ns = NS, line = 100, col = 6, opts = { hl_group = "Statement", end_col = 10 } }, -- changed
    { ns = NS2, line = 100, col = 12, opts = { hl_group = "Special", end_col = 16 } },
  }

  render._carryover_visits = 0
  render.apply_diff(buf, one_line, { [100] = true })
  local visits = render._carryover_visits

  -- Fix: O(#new specs). The old whole-buffer carryover loop visited every cached
  -- LINE (~N=200). Assert tightly so reintroducing pairs(prev) carryover trips.
  assert_eq(visits, #one_line, "apply_diff staged only the changed line's new specs")
  assert_true(visits < N, "apply_diff did not do O(total cached lines) carryover work")

  vim.api.nvim_buf_delete(buf, { force = true })
  render.invalidate(buf)
end)

-- ---------------------------------------------------------------------------
-- (2) IDLE EARLY-OUT: a scroll-throttle no-op call apply_diff(buf, {}, {}) does
-- NO carryover/diff work and leaves the extmark set untouched.
-- ---------------------------------------------------------------------------
local function capture(buf, ns)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local out = {}
  for _, m in ipairs(marks) do
    local d = m[4] or {}
    out[#out + 1] = string.format(
      "%d:%d:%s:%s", m[2], m[3], tostring(d.hl_group), tostring(d.end_col)
    )
  end
  table.sort(out)
  return table.concat(out, "\n")
end

local function capture_both(buf)
  return capture(buf, NS) .. "\n--\n" .. capture(buf, NS2)
end

test("idle scroll no-op apply_diff(buf, {}, {}) does zero carryover/diff work", function()
  local N = 200
  local buf = make_buf(N)
  render.apply_diff(buf, build_specs(N), all_lines(N))

  local before = capture_both(buf)

  render._carryover_visits = 0
  render._prev_visits = 0
  render.apply_diff(buf, {}, {})

  assert_eq(render._carryover_visits, 0, "early-out: no new specs staged on idle call")
  assert_eq(render._prev_visits, 0, "early-out: no prev specs scanned on idle call")

  local after = capture_both(buf)
  assert_eq(after, before, "idle no-op left the extmark set unchanged")

  vim.api.nvim_buf_delete(buf, { force = true })
  render.invalidate(buf)
end)

-- ---------------------------------------------------------------------------
-- (3) CORRECTNESS: the in-place commit yields a byte-identical extmark set to a
-- full fresh re-render of the same final spec set (isolates above to PERF).
-- ---------------------------------------------------------------------------
test("in-place commit produces identical extmarks to a fresh full render", function()
  local N = 60

  -- Path A: incremental — full render, then edit only line 30.
  local buf_a = make_buf(N)
  render.apply_diff(buf_a, build_specs(N), all_lines(N))
  local edited = {
    { ns = NS, line = 30, col = 0, opts = { hl_group = "Comment", end_col = 4 } },
    { ns = NS, line = 30, col = 6, opts = { hl_group = "Statement", end_col = 10 } },
    { ns = NS2, line = 30, col = 12, opts = { hl_group = "Special", end_col = 16 } },
  }
  render.apply_diff(buf_a, edited, { [30] = true })
  local got_a = capture_both(buf_a)

  -- Path B: reference — a single fresh render of the FINAL spec set.
  local final = build_specs(N)
  for _, s in ipairs(final) do
    if s.line == 30 and s.col == 6 then s.opts = { hl_group = "Statement", end_col = 10 } end
  end
  local buf_b = make_buf(N)
  render.invalidate(buf_b)
  render.apply_diff(buf_b, final, all_lines(N))
  local got_b = capture_both(buf_b)

  assert_eq(got_a, got_b, "incremental in-place commit matches a fresh full render")

  vim.api.nvim_buf_delete(buf_a, { force = true })
  vim.api.nvim_buf_delete(buf_b, { force = true })
  render.invalidate(buf_a)
  render.invalidate(buf_b)
end)

_H.finish({ style = "results", exit = "os" })
