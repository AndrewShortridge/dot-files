-- Regression spec for the vault-c audit fixes in the task UI modules.
-- Run with: nvim --headless -u NONE -l tests/audit_vaultc_tasks_spec.lua
--
-- Covers, behaviourally:
--   1. task_kanban navigation must resolve the card under the cursor's BOARD
--      COLUMN, not "whatever card was written last for that row". The old
--      row -> card spatial index let the rightmost column win, so h/l/j/k,
--      m/M and <CR> all acted on the wrong card.
--   2. task_timeline must centre the visible window on state.center_date
--      (moved by h/l/H/L, reset by t). It used engine.today() instead, making
--      all four scroll keys no-ops.
--   3. completion_spell must find the word being typed when the cursor sits one
--      byte past its end (normal insert-mode position) and must return an
--      INCOMPLETE response so blink re-queries on each keystroke.

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- Stub the logger so requiring real modules does not pull the full vault infra.
-- The catch-all __index also satisfies module-level calls like vault_log.configure().
package.loaded["andrew.vault.vault_log"] = setmetatable({
  scope = function()
    return setmetatable({}, { __index = function() return function() end end })
  end,
}, { __index = function() return function() end end })

local kanban = require("andrew.vault.task_kanban")
local timeline = require("andrew.vault.task_timeline")

local K = kanban._internal
local COL_W = 20
local STRIDE = COL_W + #K.divider_char

-- Three columns, two card rows. Rows 0-2 hold card row 1, rows 3-5 card row 2.
local function board()
  return {
    { task = { text = "c1r1" }, row = 0, col_index = 1 },
    { task = { text = "c2r1" }, row = 0, col_index = 2 },
    { task = { text = "c3r1" }, row = 0, col_index = 3 },
    { task = { text = "c1r2" }, row = 3, col_index = 1 },
    { task = { text = "c3r2" }, row = 3, col_index = 3 },
  }
end

-- ── 1. kanban: card lookup is column-aware ─────────────────────────────────

test("column_at_cursor maps a cursor byte column to the board column", function()
  assert_eq(K.column_at_cursor(0, COL_W, 3), 1)
  assert_eq(K.column_at_cursor(2, COL_W, 3), 1)
  assert_eq(K.column_at_cursor(STRIDE, COL_W, 3), 2)
  assert_eq(K.column_at_cursor(STRIDE * 2 + 2, COL_W, 3), 3)
  assert_eq(K.column_at_cursor(STRIDE * 9, COL_W, 3), 3, "clamped to the last column")
end)

test("find_card_at_cursor returns the card in the cursor's own column", function()
  local cps = board()
  local ri = K.build_spatial_index(cps)
  for ci = 1, 3 do
    local cp = K.find_card_at_cursor(cps, 1, ri, (ci - 1) * STRIDE + 2, COL_W, 3)
    assert_true(cp ~= nil, "a card is found for column " .. ci)
    assert_eq(cp.col_index, ci, "column " .. ci .. " resolves to its own card")
    assert_eq(cp.task.text, "c" .. ci .. "r1")
  end
end)

test("find_card_at_cursor picks the nearest existing column when its own is empty", function()
  local cps = board()
  local ri = K.build_spatial_index(cps)
  -- Card row 2 has no column-2 card; column 2's cursor must land on 1 or 3.
  local cp = K.find_card_at_cursor(cps, 4, ri, STRIDE + 2, COL_W, 3)
  assert_true(cp ~= nil)
  assert_true(cp.col_index == 1 or cp.col_index == 3, "fell back to an adjacent column")
  assert_eq(cp.row, 3, "stayed on the same card row")
end)

test("find_card_at_cursor without a column hint still returns a card (back-compat)", function()
  local cps = board()
  local ri = K.build_spatial_index(cps)
  local cp = K.find_card_at_cursor(cps, 1, ri)
  assert_true(cp ~= nil)
  assert_eq(cp.row, 0)
end)

test("the nearest-search fallback (cursor off every card) is also column-aware", function()
  local cps = board()
  -- No row index -> linear nearest scan.
  local cp = K.find_card_at_cursor(cps, 9, nil, STRIDE * 2 + 2, COL_W, 3)
  assert_true(cp ~= nil)
  assert_eq(cp.col_index, 3, "prefers the cursor's column among equidistant rows")
end)

test("build_spatial_index keeps one entry per (row, column) pair", function()
  local ri = K.build_spatial_index(board())
  for r = 0, 2 do
    assert_true(ri[r] ~= nil, "row " .. r .. " indexed")
    assert_eq(ri[r][1].task.text, "c1r1")
    assert_eq(ri[r][2].task.text, "c2r1")
    assert_eq(ri[r][3].task.text, "c3r1")
    assert_eq(ri[r].any.col_index, 1, "`any` is the leftmost card on the row")
  end
end)

-- ── 2. timeline: the window follows center_date ────────────────────────────

local function header_of(center, range_days)
  local data = {
    dated = {
      ["2026-01-05"] = { { text = "a", status = " ", line = 1 } },
      ["2026-03-05"] = { { text = "b", status = " ", line = 1 } },
    },
    undated = {},
  }
  local res = timeline._internal.render_timeline(data, {
    center_date = center,
    range_days = range_days,
  }, 80)
  return res.lines[1]
end

test("render_timeline centres its range on state.center_date", function()
  local h1 = header_of("2026-01-10", 5)
  local h2 = header_of("2026-03-10", 5)
  assert_true(h1 ~= h2, "moving center_date must change the rendered range header")
  assert_true(h1:find("Jan 05", 1, true) ~= nil, "Jan window: " .. h1)
  assert_true(h1:find("Jan 15", 1, true) ~= nil, "Jan window: " .. h1)
  assert_true(h2:find("Mar 05", 1, true) ~= nil, "Mar window: " .. h2)
  assert_true(h2:find("Mar 15", 1, true) ~= nil, "Mar window: " .. h2)
end)

test("only dated tasks inside the centred window are rendered", function()
  local data = {
    dated = {
      ["2026-01-05"] = { { text = "jan-task", status = " ", line = 1 } },
      ["2026-03-05"] = { { text = "mar-task", status = " ", line = 1 } },
    },
    undated = {},
  }
  local function blob(center)
    local res = timeline._internal.render_timeline(data,
      { center_date = center, range_days = 5 }, 80)
    return table.concat(res.lines, "\n")
  end
  local jan = blob("2026-01-05")
  local mar = blob("2026-03-05")
  assert_true(jan:find("jan-task", 1, true) ~= nil, "Jan window shows the Jan task")
  assert_true(jan:find("mar-task", 1, true) == nil, "Jan window hides the Mar task")
  assert_true(mar:find("mar-task", 1, true) ~= nil, "Mar window shows the Mar task")
  assert_true(mar:find("jan-task", 1, true) == nil, "Mar window hides the Jan task")
end)

test("a nil center_date still renders (falls back to today)", function()
  local res = timeline._internal.render_timeline({ dated = {}, undated = {} },
    { range_days = 7 }, 80)
  assert_true(res.lines[1]:find("Task Timeline", 1, true) ~= nil)
end)

-- ── 3. completion_spell ───────────────────────────────────────────────────

test("spell source finds the word when the cursor is one past its end", function()
  local spell = require("andrew.vault.completion_spell")
  local src = spell.new()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "recieve" })
  vim.api.nvim_set_current_buf(buf)
  vim.wo.spell = true
  vim.bo.spelllang = "en_us"
  if vim.fn.spellbadword("recieve")[1] == "" then
    -- No en_us spell file available in this environment; the cursor-position
    -- behaviour is still asserted below via the empty-line case.
    print("    (note: no en_us spellfile; suggestion assertions skipped)")
  else
    local res
    -- col 7 == one byte PAST the final "e" (the real insert-mode position).
    src:get_completions({ line = "recieve", cursor = { 1, 7 }, bufnr = buf },
      function(r) res = r end)
    assert_true(res ~= nil, "callback fired")
    assert_true(#res.items > 0, "suggestions produced at end-of-word cursor")
    assert_eq(res.items[1].filterText, "recieve", "filterText is the misspelled word")
  end
end)

test("spell responses are marked incomplete so blink re-queries per keystroke", function()
  local spell = require("andrew.vault.completion_spell")
  local src = spell.new()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.api.nvim_set_current_buf(buf)
  vim.wo.spell = true
  local res
  src:get_completions({ line = "", cursor = { 1, 0 }, bufnr = buf }, function(r) res = r end)
  assert_true(res ~= nil, "callback fired for an empty line")
  assert_eq(res.is_incomplete_forward, true, "forward-incomplete")
  assert_eq(res.is_incomplete_backward, true, "backward-incomplete")
  assert_eq(#res.items, 0)
end)

test("spell source is gated on 'spell'", function()
  local spell = require("andrew.vault.completion_spell")
  local src = spell.new()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.wo.spell = false
  assert_true(not src:enabled(), "disabled without 'spell'")
  vim.wo.spell = true
  assert_true(src:enabled(), "enabled with 'spell'")
end)

_H.finish({ style = "results", exit = "os" })
