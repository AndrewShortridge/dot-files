-- Behavioral spec for Issue 9: skip the empty callout-fold path.
--
-- The deferred BufWinEnter/BufRead callback in render-markdown.lua short-circuits
-- on `cf.get_all_blocks(bufnr)` being empty (no callouts) BEFORE touching
-- foldmethod or running `normal! zE`. This spec drives the REAL callout_folds
-- module against temp scratch buffers and asserts:
--   1. get_all_blocks returns a length-0 array for no-callout buffers (the exact
--      predicate the short-circuit branches on).
--   2. get_all_blocks returns populated blocks (with suffix) for buffers that DO
--      have callouts.
--   3. Replicating apply_callout_folds's range-fold commands closes a `[!NOTE]-`
--      callout and leaves a `[!NOTE]+` callout open (folding still works).
--
-- The autocmd callback itself is inline in render-markdown.lua and not directly
-- requireable headless (needs lazy/plugin setup), so we assert the predicate and
-- the fold side-effects rather than the autocmd. No source-introspection.
-- Run with: nvim --headless -u NONE -l tests/callout_fold_skip_empty_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local cf = require("andrew.vault.callout_folds")

--- Create a scratch buffer with the given lines.
local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- ============================================================================
-- (1) Empty predicate: no callouts => length-0 array (the short-circuit signal)
-- ============================================================================
test("get_all_blocks returns empty array for a no-callout buffer", function()
  local buf = make_buf({ "# Heading", "just some prose", "- a list item", "more text" })
  local blocks = cf.get_all_blocks(buf)
  assert_eq(type(blocks), "table", "blocks should be a table")
  assert_eq(#blocks, 0, "no-callout buffer must yield zero blocks")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ============================================================================
-- (2) Populated predicate: callouts => non-empty array with suffix info
-- ============================================================================
test("get_all_blocks returns populated blocks for a callout buffer", function()
  local buf = make_buf({
    "> [!NOTE]- Collapsed",
    "> hidden body line one",
    "> hidden body line two",
    "",
    "ordinary text",
  })
  local blocks = cf.get_all_blocks(buf)
  assert_true(#blocks >= 1, "callout buffer must yield at least one block")
  assert_eq(blocks[1].suffix, "-", "first block carries the '-' suffix")
  assert_true(blocks[1].end_line > blocks[1].start_line, "block spans multiple lines")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ============================================================================
-- (3) Folding still works: '-' callout closes, '+' callout stays open.
--     Replicates apply_callout_folds's range-fold Ex commands in a real window.
-- ============================================================================
test("range-fold commands close '-' callouts and leave '+' callouts open", function()
  local buf = make_buf({
    "> [!NOTE]- Closed by default", -- 1
    "> closed body a", -- 2
    "> closed body b", -- 3
    "", -- 4
    "> [!TIP]+ Open by default", -- 5
    "> open body a", -- 6
    "> open body b", -- 7
  })
  -- Apply folds in a real window context (manual folds are window-local).
  vim.api.nvim_set_current_buf(buf)
  vim.wo.foldmethod = "manual"
  vim.cmd("normal! zE")

  local blocks = cf.get_all_blocks(buf)
  assert_eq(#blocks, 2, "expected exactly two callout blocks")

  -- Mirror apply_callout_folds: create the fold, open it unless suffix is '-'.
  for _, block in ipairs(blocks) do
    if block.end_line > block.start_line then
      local cs = block.start_line + 1
      local ce = block.end_line
      vim.cmd("silent! " .. cs .. "," .. ce .. "fold")
      if block.suffix ~= "-" then
        vim.cmd("silent! " .. cs .. "," .. ce .. "foldopen")
      end
    end
  end

  -- '-' callout: its content (line 2) must be inside a CLOSED fold.
  assert_true(vim.fn.foldclosed(2) ~= -1, "'-' callout content should be folded closed")
  -- '+' callout: its content (line 6) must NOT be folded closed.
  assert_eq(vim.fn.foldclosed(6), -1, "'+' callout content should be open")

  vim.api.nvim_buf_delete(buf, { force = true })
end)

_H.finish()
