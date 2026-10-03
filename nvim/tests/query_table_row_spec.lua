-- Behavioral spec for DQL TABLE row construction (nil-cell column alignment).
-- Run with: nvim --headless -u NONE -l tests/query_table_row_spec.lua
--
-- Covers the seam in query/executor_results.lua build_table_row:
--   * A nil cell in a non-final column must NOT shift later columns left.
--   * Each row must carry exactly one cell per header (using explicit indices).
--   * Both the flat and GROUP BY code paths share the same builder.
-- Assertions are behavioral (exercise real ER.build_table_results output),
-- not source-introspection. A counted loop / explicit indices are used instead
-- of `#row` because a trailing-nil column makes Lua `#` unreliable.

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

local ER = require("andrew.vault.query.executor_results")

-- Fake evaluator: read the field value straight off the page table so the spec
-- controls exactly which cells resolve to nil.
local function eval_expr(expr, page)
  return page[expr.path[1]]
end

local function field(name)
  return { expr = { type = "field", path = { name } } }
end

-- ── Nil in a non-final, non-File column must not shift later cells ──────────

test("nil interior column leaves a hole, rating stays under its header", function()
  local ast = { without_id = true, fields = { field("genre"), field("rating") } }
  local pages = { { file = { link = "NoteA" }, genre = nil, rating = "5" } }
  local result = ER.build_table_results(ast, pages, nil, nil, eval_expr)[1]
  local row = result.rows[1]

  assert_eq(#result.headers, 2)
  assert_eq(result.headers[1], "genre")
  assert_eq(result.headers[2], "rating")
  -- genre (nil) stays at index 1; rating ("5") stays at index 2.
  assert_nil(row[1])
  assert_eq(row[2], "5")
  -- Explicit cell count == header count (counted, robust to nil holes).
  assert_eq(#row, 2)
end)

-- ── File column preserved with an interior nil ─────────────────────────────

test("File column preserved when an interior field is nil", function()
  local ast = { without_id = false, fields = { field("genre"), field("rating") } }
  local pages = { { file = { link = "NoteA" }, genre = nil, rating = "5" } }
  local result = ER.build_table_results(ast, pages, nil, nil, eval_expr)[1]
  local row = result.rows[1]

  assert_eq(#result.headers, 3)
  assert_eq(result.headers[1], "File")
  assert_eq(result.headers[2], "genre")
  assert_eq(result.headers[3], "rating")
  assert_eq(row[1], "NoteA") -- page_link
  assert_nil(row[2])          -- genre hole
  assert_eq(row[3], "5")      -- rating correctly placed
end)

-- ── Trailing nil column: first column still correct ────────────────────────

test("trailing nil column does not corrupt the first column", function()
  local ast = { without_id = true, fields = { field("rating"), field("genre") } }
  local pages = { { rating = "5", genre = nil } }
  local result = ER.build_table_results(ast, pages, nil, nil, eval_expr)[1]
  local row = result.rows[1]

  assert_eq(row[1], "5")
  assert_nil(row[2])
end)

-- ── Happy-path regression guard: all cells present ─────────────────────────

test("all-present row keeps values aligned (no regression)", function()
  local ast = { without_id = true, fields = { field("genre"), field("rating") } }
  local pages = { { genre = "rock", rating = "5" } }
  local result = ER.build_table_results(ast, pages, nil, nil, eval_expr)[1]
  local row = result.rows[1]

  assert_eq(row[1], "rock")
  assert_eq(row[2], "5")
  assert_eq(#row, 2)
end)

-- ── GROUP BY path shares the same builder ──────────────────────────────────

test("GROUP BY path also keeps nil holes aligned", function()
  local ast = { without_id = true, fields = { field("genre"), field("rating") } }
  local groups = { { key = "k", pages = { { genre = nil, rating = "5" } } } }
  local results = ER.build_table_results(ast, {}, groups, nil, eval_expr)
  local row = results[1].rows[1]

  assert_eq(results[1].group, "k")
  assert_nil(row[1])
  assert_eq(row[2], "5")
  assert_eq(#row, 2)
end)

_H.finish({ style = "results", exit = "os" })
