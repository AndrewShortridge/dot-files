-- Spec for <leader>yf / <leader>yp (core/keymaps.lua) and
-- andrew.utils.path_reference: copying a file's path for an agent prompt, and
-- `path#L10-L24` from Visual mode.
--
-- WHAT THIS IS GUARDING
--
-- 1. Line numbers appear ONLY for a Visual selection. Normal mode copies the
--    bare path, wherever the cursor is and whatever was selected earlier.
-- 2. The range comes from the LIVE selection. `'<` and `'>` are only set when
--    Visual mode ends, so code that reads them from inside the mapping gets the
--    PREVIOUS selection's lines -- right the first time, wrong ever after.
-- 3. The range is ordered whichever way the selection was made. Selecting
--    upward puts the cursor on the first line; `#L24-L10` is not a range.
-- 4. A selection on one line is `#L10`, not `#L10-L10`.
-- 5. Visual mode is left afterwards, as after a yank.
-- 6. A buffer that is not a file copies NOTHING and leaves the clipboard as it
--    was.
--
-- Drives the REAL mappings by feeding keys; the clipboard is a fake provider
-- (the `+` register has none under --headless).
--
-- Run with: nvim --headless -u NONE -l tests/path_reference_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq = _H.test, _H.assert_eq

local config_dir = vim.fn.stdpath("config")
package.path = config_dir .. "/lua/?.lua;" .. package.path

--- What the fake `+` provider last received (see `:h clipboard-provider`).
---@class PathReferenceSpecClipboard
---@field lines string[]
---@field regtype string  "v", "V" or a blockwise "\22{width}"

---@class PathReferenceSpecNotification
---@field message string
---@field level? integer

---@type PathReferenceSpecClipboard
local clipboard = { lines = {}, regtype = "v" }
vim.g.clipboard = {
  name = "path-reference-spec",
  copy = {
    ---@param lines string[]
    ---@param regtype string
    ["+"] = function(lines, regtype)
      clipboard.lines, clipboard.regtype = lines, regtype
    end,
    ["*"] = function() end,
  },
  paste = {
    ---@return [string[], string]
    ["+"] = function()
      return { clipboard.lines, clipboard.regtype }
    end,
    ---@return [string[], string]
    ["*"] = function()
      return { {}, "v" }
    end,
  },
}

dofile(config_dir .. "/lua/andrew/core/keymaps.lua")

local notifications = {} ---@type PathReferenceSpecNotification[]
--- Fake of vim.notify(msg: string, level?: integer, opts?: table); opts is not recorded.
---@param message string
---@param level? integer
vim.notify = function(message, level)
  notifications[#notifications + 1] = { message = message, level = level }
end

-- Resolved, because every path Neovim reports for a buffer is.
local sandbox = vim.uv.fs_realpath(vim.fn.fnamemodify(vim.fn.tempname(), ":h")) .. "/path_reference_spec"
vim.fn.delete(sandbox, "rf")
vim.fn.mkdir(sandbox .. "/project/src", "p")
vim.fn.mkdir(sandbox .. "/elsewhere", "p")

local source_lines = {} ---@type string[]
for line_number = 1, 30 do
  source_lines[line_number] = "line " .. line_number
end
vim.fn.writefile(source_lines, sandbox .. "/project/src/solver.f90")

---@param working_directory string  directory under the sandbox to :cd into
local function open_source_file(working_directory)
  vim.cmd("silent! %bwipeout!")
  vim.cmd.cd(vim.fn.fnameescape(sandbox .. "/" .. working_directory))
  vim.cmd.edit(vim.fn.fnameescape(sandbox .. "/project/src/solver.f90"))
  clipboard.lines = { "untouched" }
  notifications = {}
end

--- Type `keys` as the user would, mappings included.
---@param keys string
local function type_keys(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

---@return string
local function copied()
  return table.concat(clipboard.lines, "\n")
end

test("Normal mode copies the relative path with no line number", function()
  open_source_file("project")
  type_keys("12G<leader>yf")
  assert_eq(copied(), "src/solver.f90", "clipboard:")
  assert_eq(notifications[1] and notifications[1].message, "Yanked: src/solver.f90", "notification:")
end)

test("<leader>yp copies the absolute path with no line number", function()
  open_source_file("project")
  type_keys("12G<leader>yp")
  assert_eq(copied(), sandbox .. "/project/src/solver.f90", "clipboard:")
end)

test("a Visual selection is copied as a line range", function()
  open_source_file("project")
  type_keys("10GV14j<leader>yf")
  assert_eq(copied(), "src/solver.f90#L10-L24", "line-wise selection:")

  type_keys("3Gvjj<leader>yf")
  assert_eq(copied(), "src/solver.f90#L3-L5", "character-wise selection:")

  type_keys("7G<C-v>jl<leader>yp")
  assert_eq(copied(), sandbox .. "/project/src/solver.f90#L7-L8", "block selection, absolute:")
end)

test("the range is ordered when the selection was made upward", function()
  open_source_file("project")
  type_keys("24GV14k<leader>yf")
  assert_eq(copied(), "src/solver.f90#L10-L24", "clipboard:")
end)

test("the range is the live selection, not the previous one", function()
  open_source_file("project")
  type_keys("2GVj<Esc>") -- leaves '< and '> on lines 2-3
  type_keys("20GVjj<leader>yf")
  assert_eq(copied(), "src/solver.f90#L20-L22", "clipboard:")
end)

test("a selection within one line is that line, not a range", function()
  open_source_file("project")
  type_keys("9Gvl<leader>yf")
  assert_eq(copied(), "src/solver.f90#L9", "clipboard:")
end)

test("Visual mode is left, and Normal mode then copies the bare path again", function()
  open_source_file("project")
  type_keys("10GVjj<leader>yf")
  assert_eq(vim.fn.mode(), "n", "mode after copying from Visual mode:")

  type_keys("18G<leader>yf")
  assert_eq(copied(), "src/solver.f90", "Normal mode after an earlier selection:")
end)

test("a file outside the working directory keeps its absolute path", function()
  open_source_file("elsewhere")
  type_keys("4G<leader>yf")
  assert_eq(copied(), sandbox .. "/project/src/solver.f90", "Normal mode:")

  type_keys("4GVj<leader>yf")
  assert_eq(copied(), sandbox .. "/project/src/solver.f90#L4-L5", "Visual mode:")
end)

test("a buffer that is not a file copies nothing and warns", function()
  open_source_file("project")
  vim.cmd.enew()
  type_keys("<leader>yf")
  assert_eq(copied(), "untouched", "clipboard after an unnamed buffer:")
  assert_eq(notifications[1] and notifications[1].level, vim.log.levels.WARN, "notification level:")

  vim.cmd.file("scratch-panel")
  vim.bo.buftype = "nofile"
  type_keys("V<leader>yp")
  assert_eq(copied(), "untouched", "clipboard after a named scratch buffer:")
  assert_eq(vim.fn.mode(), "n", "mode after the refused copy:")
end)

vim.cmd("silent! %bwipeout!")
vim.cmd.cd(vim.fn.fnameescape(config_dir))
vim.fn.delete(sandbox, "rf")
_H.finish()
