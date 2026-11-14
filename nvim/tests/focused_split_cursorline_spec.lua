-- Spec for the "cursorline in the focused split only" autocommands in
-- core/keymaps.lua (augroup focused-split-cursorline).
--
-- WHAT THIS IS GUARDING
--
-- Moving the cursorline on WinEnter / WinLeave is enough for `<C-w>w` and not
-- for the cases around it. The tests below pin those cases:
--
-- 1. `:buffer N` in the focused split. Window options are remembered per
--    buffer, so a buffer last shown in an unfocused split arrives carrying that
--    split's "off" and the focused window loses its cursorline with no window
--    event fired at all.
-- 2. nvim_win_set_buf() on an unfocused split. BufWinEnter runs with that split
--    temporarily current; code that trusts the current window there moves the
--    cursorline to a window the cursor is not in, and nothing moves it back.
-- 3. Focus in a float. Pickers and the floating terminal take focus without
--    the user having left the split, so the split stays marked.
-- 4. Plugin panels (Trouble, quickfix, the vault sidebar: buftype nofile or
--    quickfix) use the cursorline as their selection marker. Turning it off
--    when focus leaves hides which entry is selected.
-- 5. `:set nocursorline` has to stick. A recipe that turns the option on at
--    every WinEnter silently undoes it on the next window switch.
--
-- Drives the REAL file (dofile), with real windows.
--
-- Run with: nvim --headless -u NONE -l tests/focused_split_cursorline_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq = _H.test, _H.assert_eq

local config_dir = vim.fn.stdpath("config")
package.path = config_dir .. "/lua/?.lua;" .. package.path

vim.o.cursorline = true -- core/options.lua does this in the real config
dofile(config_dir .. "/lua/andrew/core/keymaps.lua")

local scratch_dir = vim.fn.tempname()
vim.fn.mkdir(scratch_dir, "p")

local function scratch_file(name)
  local path = scratch_dir .. "/" .. name
  vim.fn.writefile({ "first", "second", "third" }, path)
  return path
end

local ONE, TWO, THREE = scratch_file("one.txt"), scratch_file("two.txt"), scratch_file("three.txt")

-- One window on ONE with the cursorline wanted, as after startup.
local function reset_to_single_window()
  vim.cmd("silent! tabonly | silent! only")
  vim.cmd("silent! %bwipeout!")
  vim.cmd.edit(ONE)
  vim.cmd("set cursorline")
  return vim.api.nvim_get_current_win()
end

-- Open `path` in a split. Returns the window that was focused and the new
-- split, which now has focus.
local function split_with(path)
  local original = vim.api.nvim_get_current_win()
  vim.cmd.vsplit(path)
  return original, vim.api.nvim_get_current_win()
end

local focus = vim.api.nvim_set_current_win

local function shows_cursorline(window)
  return vim.wo[window].cursorline
end

test("only the focused split shows the cursorline, and it follows focus", function()
  reset_to_single_window()
  local original, split = split_with(TWO)
  assert_eq(shows_cursorline(split), true, "the new, focused split:")
  assert_eq(shows_cursorline(original), false, "the split focus left:")

  focus(original)
  assert_eq(shows_cursorline(original), true, "after moving focus back, the original split:")
  assert_eq(shows_cursorline(split), false, "after moving focus back, the new split:")
end)

test("switching the focused split to a buffer shown in an unfocused one keeps the cursorline", function()
  reset_to_single_window()
  local original, split = split_with(TWO)
  focus(original)
  assert_eq(shows_cursorline(split), false, "precondition, the unfocused split on two.txt:")

  vim.cmd.buffer(vim.fn.bufnr(TWO))
  assert_eq(shows_cursorline(original), true, "the focused split after :buffer two.txt:")
  assert_eq(shows_cursorline(split), false, "the unfocused split, still on two.txt:")
end)

test("giving an unfocused split a buffer through the API does not move the cursorline", function()
  reset_to_single_window()
  local original, split = split_with(TWO)
  local third = vim.fn.bufadd(THREE)
  vim.fn.bufload(third)

  vim.api.nvim_win_set_buf(original, third)
  assert_eq(shows_cursorline(original), false, "the unfocused split that received the buffer:")
  assert_eq(shows_cursorline(split), true, "the focused split:")

  -- The reverse leak: two.txt was last shown with the cursorline on.
  vim.cmd.edit(ONE)
  vim.api.nvim_win_set_buf(original, vim.fn.bufnr(TWO))
  assert_eq(shows_cursorline(original), false, "the unfocused split given a buffer last shown focused:")
  assert_eq(shows_cursorline(split), true, "the focused split afterwards:")
end)

test("a split opened without entering it does not show the cursorline", function()
  local focused = reset_to_single_window()
  local unentered = vim.api.nvim_open_win(vim.fn.bufadd(TWO), false, { split = "right" })
  assert_eq(shows_cursorline(unentered), false, "the split that was never entered:")
  assert_eq(shows_cursorline(focused), true, "the focused split:")
end)

test("focus in a floating window leaves the split underneath marked", function()
  reset_to_single_window()
  local original, split = split_with(TWO)
  local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 20,
    height = 3,
  })
  assert_eq(vim.api.nvim_get_current_win(), float, "precondition, focus is in the float:")
  assert_eq(shows_cursorline(split), true, "the split the float was opened from:")
  assert_eq(shows_cursorline(original), false, "the other split:")

  vim.api.nvim_win_close(float, true)
  assert_eq(shows_cursorline(split), true, "the same split once the float is closed:")
end)

test("a plugin panel keeps its own cursorline when focus leaves it", function()
  reset_to_single_window()
  local text_window = vim.api.nvim_get_current_win()
  vim.cmd("botright new")
  local panel = vim.api.nvim_get_current_win()
  vim.bo.buftype = "nofile"
  vim.wo[panel].cursorline = true
  assert_eq(shows_cursorline(text_window), false, "the text split while focus is in the panel:")

  focus(text_window)
  assert_eq(shows_cursorline(panel), true, "the panel after focus left it:")
  assert_eq(shows_cursorline(text_window), true, "the text split, focused again:")
end)

test(":set nocursorline in a split survives leaving it and coming back", function()
  reset_to_single_window()
  local original, split = split_with(TWO)
  vim.cmd("set nocursorline")
  focus(original)
  assert_eq(shows_cursorline(original), true, "the other split still gets its cursorline:")

  focus(split)
  assert_eq(shows_cursorline(split), false, "the split where it was switched off:")
end)

test("each tab page keeps the cursorline in its own last-focused split", function()
  reset_to_single_window()
  local original, split = split_with(TWO)
  vim.cmd.tabnew(THREE)
  local tab_window = vim.api.nvim_get_current_win()
  assert_eq(shows_cursorline(tab_window), true, "the window of the new tab page:")
  assert_eq(shows_cursorline(split), true, "the last-focused split of the tab page left behind:")
  assert_eq(shows_cursorline(original), false, "its other split:")
end)

vim.fn.delete(scratch_dir, "rf")
_H.finish()
