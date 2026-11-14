-- Regression spec: `ac` / `ic` inside a code block whose opening fence has NO
-- info string (a bare ``` or ~~~).
--
-- find_code_block() used to scan UPWARDS from the cursor and, on hitting a bare
-- fence above it, assume "that must be the CLOSER of an earlier block" and try
-- to skip past it. Two problems: the assumption is wrong for the very common
-- ```-with-no-language block, and the skip itself was a no-op (it assigned the
-- enclosing `for r = row, 0, -1` loop variable, which Lua ignores). Result:
-- `vac` / `vic` / `dac` / `dic` silently did nothing inside every code block
-- written without a language tag, while the same keys worked in ```lua blocks.
--
-- The fix replaces the upward guess with one top-down scan shared with the
-- ]b/[b motions (collect_code_block_ranges), where an opener is unambiguous.
-- Run with: nvim --headless -u NONE -l tests/audit_markdown_codeblock_textobj_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_deep_eq = _H.test, _H.assert_eq, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local mto = require("andrew.utils.md-textobjects")

--- Put `lines` in a real window, move to (row, col) 1/0-indexed, run the text
--- object, then yank the resulting visual selection and return it.
local function select_text(lines, row, col, fn)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_win_set_cursor(0, { row, col })
  fn()
  local got = ""
  if vim.fn.mode():find("^[vV\22]") then
    vim.cmd('silent! normal! "zy')
    got = vim.fn.getreg("z")
  end
  if vim.fn.mode() ~= "n" then
    vim.cmd("silent! normal! \27")
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  return got
end

local BARE = { "before", "```", "bare body", "```", "after" }
local TAGGED = { "before", "```lua", "local x = 1", "```", "after" }

test("ac selects a bare-fence block from inside it", function()
  assert_eq(select_text(BARE, 3, 0, mto.around_codeblock), "```\nbare body\n```")
end)

test("ic selects the contents of a bare-fence block", function()
  assert_eq(select_text(BARE, 3, 0, mto.inside_codeblock), "bare body")
end)

test("ac works from the opening and closing fence lines of a bare block", function()
  assert_eq(select_text(BARE, 2, 0, mto.around_codeblock), "```\nbare body\n```")
  assert_eq(select_text(BARE, 4, 0, mto.around_codeblock), "```\nbare body\n```")
end)

test("ac still selects an info-string block (no regression)", function()
  assert_eq(select_text(TAGGED, 3, 0, mto.around_codeblock), "```lua\nlocal x = 1\n```")
end)

test("ac picks the right block when a bare block follows a tagged one", function()
  local mixed = { "```lua", "a", "```", "", "```", "b", "```" }
  assert_eq(select_text(mixed, 2, 0, mto.around_codeblock), "```lua\na\n```")
  assert_eq(select_text(mixed, 6, 0, mto.around_codeblock), "```\nb\n```")
end)

test("ac picks the right block among two bare blocks", function()
  local two = { "```", "one", "```", "x", "```", "two", "```" }
  assert_eq(select_text(two, 2, 0, mto.around_codeblock), "```\none\n```")
  assert_eq(select_text(two, 6, 0, mto.around_codeblock), "```\ntwo\n```")
end)

test("ac is a no-op between two blocks", function()
  local two = { "```", "one", "```", "x", "```", "two", "```" }
  -- No selection started: the helper returns "" when mode stayed normal.
  assert_eq(select_text(two, 4, 0, mto.around_codeblock), "")
end)

test("ac handles ~~~ fences with and without an info string", function()
  assert_eq(select_text({ "~~~", "t", "~~~" }, 2, 0, mto.around_codeblock), "~~~\nt\n~~~")
  assert_eq(select_text({ "~~~py", "t", "~~~" }, 2, 0, mto.around_codeblock), "~~~py\nt\n~~~")
end)

test("an orphan fence with no closer selects nothing", function()
  assert_eq(select_text({ "text", "```", "unterminated" }, 3, 0, mto.around_codeblock), "")
end)

test("]b / [b still enumerate bare and tagged blocks alike", function()
  local mixed = { "```", "a", "```", "x", "```lua", "b", "```", "y" }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, mixed)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  mto.next_codeblock()
  assert_eq(vim.api.nvim_win_get_cursor(0)[1], 5, "]b from line 1 lands on the 2nd opener")
  vim.api.nvim_win_set_cursor(0, { 8, 0 })
  mto.prev_codeblock()
  assert_eq(vim.api.nvim_win_get_cursor(0)[1], 5, "[b from line 8 lands on the 2nd opener")
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  mto.prev_codeblock()
  assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1, "[b from line 4 lands on the 1st opener")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("dic on an empty bare block leaves the buffer alone", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "```", "```" })
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  mto.inside_codeblock()
  if vim.fn.mode() ~= "n" then
    vim.cmd("silent! normal! \27")
  end
  assert_deep_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "```", "```" })
  vim.api.nvim_buf_delete(buf, { force = true })
end)

_H.finish()
