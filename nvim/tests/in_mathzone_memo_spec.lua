-- Perf + correctness regression spec for andrew.utils.tex M.in_mathzone.
--
-- blink.cmp's luasnip source filters the WHOLE cached snippet list by each
-- snippet's show_condition on EVERY completion query (vim.tbl_filter over the
-- items). All ~387 markdown math snippets carry
-- `show_condition = M.in_mathzone`, so in a markdown buffer with the menu open
-- in_mathzone was invoked ~387 times PER keystroke, each doing a fresh
-- vim.treesitter.get_parser(buf) + language_for_range walk (a TS reparse).
-- Every call within one query shares the same buffer/changedtick/cursor and
-- therefore the same result.
--
-- The fix memoizes in_mathzone on (buf, changedtick, cursor_row, cursor_col)
-- with a 1-slot cache, collapsing the ~387 identical-input calls into a single
-- TS parse while the menu is open.
--
-- This spec drives the REAL module against a real buffer (no mocks):
--   Test 1: correctness preserved (math zone vs prose, regex fallback).
--   Test 2: discriminating power -- count vim.treesitter.get_parser calls
--           across N repeated in_mathzone() calls at a fixed cursor; with the
--           memo the parser is fetched once. Reintroducing the bug (removing
--           the memo) makes this == N and fails.
--   Test 3: invalidation -- editing the buffer (bumps changedtick) or moving
--           the cursor busts the cache, so the parser is fetched again.

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

-- Require the real module headless.
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local tex = require("andrew.utils.tex")

-- Make a fresh buffer with the given filetype + lines, make it current, place
-- the cursor at (row 1-indexed, col 0-indexed).
local function make_buf(ft, lines, row, col)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { row, col })
  return buf
end

-- ---------------------------------------------------------------------------
-- Test 1: correctness preserved (memo refactor must not change semantics).
-- Uses the regex $-counting fallback path, which is deterministic regardless
-- of whether the markdown latex injection parser is installed -- so this test
-- runs everywhere and still exercises in_mathzone end to end.
-- ---------------------------------------------------------------------------
test("in_mathzone: true inside inline $...$, false in prose (regex fallback)", function()
  -- Cursor inside the math: "$x +| y$" -> odd number of $ before cursor.
  make_buf("markdown", { "text $x + y$ more" }, 1, 8)
  assert_true(tex.in_mathzone(), "cursor inside $...$ must be a math zone")

  -- Cursor in plain prose before any $.
  make_buf("markdown", { "text $x + y$ more" }, 1, 2)
  assert_eq(tex.in_mathzone(), false, "cursor in prose before math must not be a math zone")

  -- Cursor after the closing $ -> even count -> prose.
  make_buf("markdown", { "text $x + y$ more" }, 1, 14)
  assert_eq(tex.in_mathzone(), false, "cursor after closing $ must not be a math zone")

  -- not_mathzone must mirror in_mathzone.
  make_buf("markdown", { "text $x + y$ more" }, 1, 8)
  assert_eq(tex.not_mathzone(), false, "not_mathzone must be the inverse inside math")
end)

-- ---------------------------------------------------------------------------
-- Test 2: discriminating power -- the memo collapses N calls into 1 parse.
-- Mirrors blink's per-snippet show_condition fan-out within a single query:
-- N calls, same cursor, no edits. Counts vim.treesitter.get_parser invocations.
-- ---------------------------------------------------------------------------
test("in_mathzone: N repeated calls at fixed cursor -> 1 treesitter parse", function()
  make_buf("markdown", { "text $x + y$ more" }, 1, 8)

  -- Warm once so any module-level lazy init in get_parser path settles, then
  -- the count below reflects steady-state per-call parser fetches.
  tex.in_mathzone()

  local calls = 0
  local orig = vim.treesitter.get_parser
  vim.treesitter.get_parser = function(...)
    calls = calls + 1
    return orig(...)
  end

  local ok, err = pcall(function()
    local N = 50
    for _ = 1, N do
      tex.in_mathzone()
    end
  end)

  vim.treesitter.get_parser = orig
  if not ok then
    error(err)
  end

  -- With the memo, all N calls hit the 1-slot cache (same buf/changedtick/
  -- cursor as the warm call) -> zero fresh parser fetches. Without the memo
  -- each call fetches the parser -> calls == 50, failing this assertion.
  assert_eq(calls, 0, "memo must collapse repeated same-key calls (got " .. calls .. " parser fetches)")
end)

-- ---------------------------------------------------------------------------
-- Test 3: invalidation -- changedtick (edit) and cursor move bust the cache.
-- ---------------------------------------------------------------------------
test("in_mathzone: edit (changedtick) and cursor move bust the memo", function()
  local buf = make_buf("markdown", { "text $x + y$ more" }, 1, 8)
  tex.in_mathzone() -- prime the cache for this key

  -- (a) Edit the buffer: bumps changedtick -> next call must re-parse.
  local calls = 0
  local orig = vim.treesitter.get_parser
  vim.treesitter.get_parser = function(...)
    calls = calls + 1
    return orig(...)
  end

  local ok, err = pcall(function()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "text $x + z$ more" })
    -- keep the cursor in-bounds at the same spot
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    tex.in_mathzone()
    assert_eq(calls, 1, "edit must invalidate memo (changedtick changed)")

    -- (b) Move the cursor: same changedtick, different cursor -> re-parse.
    calls = 0
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    tex.in_mathzone()
    assert_eq(calls, 1, "cursor move must invalidate memo")
  end)

  vim.treesitter.get_parser = orig
  if not ok then
    error(err)
  end
end)

_H.finish({ style = "results", exit = "os" })
