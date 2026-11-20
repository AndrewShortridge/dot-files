-- Spec for andrew.utils.tabline, the port of craftzdog's slanted tabline.
--
-- WHAT THIS IS GUARDING
--
-- The parts of the port that are NOT in his version, plus the two things a
-- 'tabline' expression gets wrong quietly:
--
-- 1. Focus in a floating window. A tab page is named after its focused window;
--    taken literally, every picker and the floating terminal rename the tab for
--    as long as they are open. The split underneath has to keep naming it.
-- 2. `%` in a file name. 'tabline' is a statusline-format string, so an
--    unescaped `%` starts an item and the name is drawn wrong or not at all.
-- 3. Truncation by characters, not bytes. Cutting a multi-byte name at a byte
--    offset leaves half a character in the tabline.
-- 4. Colours following the colourscheme. They are derived from its groups, so
--    they must be re-derived on ColorScheme or the light/dark toggle leaves the
--    tabs on the old palette.
--
-- The rendered string is checked through nvim_eval_statusline(), i.e. as the
-- text and highlight spans Neovim would actually draw.
--
-- Run with: nvim --headless -u NONE -l tests/tabline_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local tabline = require("andrew.utils.tabline")

-- `-u NONE` has no colourscheme: give the three source groups colours so the
-- tabline's own groups exist and show up as spans.
vim.api.nvim_set_hl(0, "Normal", { fg = "#aaaaaa", bg = "#101010" })
vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = "#00cc00" })
vim.api.nvim_set_hl(0, "CursorLine", { bg = "#303030" })
tabline.apply_colours()

local scratch_dir = vim.fn.tempname()
vim.fn.mkdir(scratch_dir, "p")

---@param name string
---@return string
local function scratch_file(name)
  local path = scratch_dir .. "/" .. name
  vim.fn.writefile({ "first", "second" }, path)
  return path
end

---@param path string
local function reset_to(path)
  vim.cmd("silent! tabonly | silent! only")
  vim.cmd("silent! %bwipeout!")
  vim.cmd.edit(vim.fn.fnameescape(path))
end

--- What Neovim would draw: the text, and the highlight group in force at the
--- start of `needle`.
---@return string text
---@return fun(needle: string): string? group_at
local function drawn()
  local evaluated = vim.api.nvim_eval_statusline(tabline.render(), { use_tabline = true, highlights = true })
  ---@param needle string
  ---@return string?
  local function group_at(needle)
    local start = assert(evaluated.str:find(needle, 1, true), "not drawn: " .. needle) - 1
    local group ---@type string?
    for _, span in ipairs(evaluated.highlights) do
      if span.start <= start then
        group = span.group
      end
    end
    return group
  end
  return evaluated.str, group_at
end

test("each tab page is named after its file and the current one is marked", function()
  reset_to(scratch_file("one.txt"))
  vim.cmd.tabedit(scratch_file("two.txt"))

  local text, group_at = drawn()
  assert_true(text:find("one.txt", 1, true) < text:find("two.txt", 1, true), "tabs out of order: " .. text)
  assert_eq(group_at("two.txt"), "TabLineActive", "the current tab page:")
  assert_eq(group_at("one.txt"), "TabLineInactive", "the other tab page:")

  vim.cmd.tabfirst()
  local _, group_after_switch = drawn()
  assert_eq(group_after_switch("one.txt"), "TabLineActive", "after :tabfirst, the first tab page:")
end)

test("a modified file is marked on its tab", function()
  reset_to(scratch_file("one.txt"))
  assert_true(not drawn():find("[+]", 1, true), "unmodified file must not be marked")

  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "changed" })
  assert_true(drawn():find("[+] one.txt", 1, true) ~= nil, "modified file not marked: " .. drawn())
  vim.cmd("silent! edit!")
end)

test("a tab page whose focus is in a float keeps the name of the split underneath", function()
  reset_to(scratch_file("one.txt"))
  local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 20,
    height = 3,
  })
  assert_eq(vim.api.nvim_get_current_win(), float, "precondition, focus is in the float:")
  assert_true(drawn():find("one.txt", 1, true) ~= nil, "tab renamed by the float: " .. drawn())
  vim.api.nvim_win_close(float, true)
end)

test("a percent sign in a file name is drawn literally", function()
  reset_to(scratch_file("100%done.txt"))
  assert_true(drawn():find("100%done.txt", 1, true) ~= nil, "name mangled: " .. drawn())
end)

test("a long name is cut to 17 characters, counted as characters", function()
  reset_to(scratch_file(("é"):rep(30) .. ".txt"))
  local text = drawn()
  assert_true(text:find(("é"):rep(17) .. "…", 1, true) ~= nil, "not cut at 17 characters: " .. text)
  assert_true(not text:find(("é"):rep(18), 1, true), "more than 17 characters kept: " .. text)
end)

test("a buffer without a file is labelled [No Name]", function()
  vim.cmd("silent! tabonly | silent! only")
  vim.cmd("silent! %bwipeout!")
  assert_true(drawn():find("[No Name]", 1, true) ~= nil, "unnamed buffer: " .. drawn())
end)

test("the colours follow a colourscheme change", function()
  tabline.setup()
  vim.api.nvim_set_hl(0, "Normal", { fg = "#111111", bg = "#222222" })
  vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = "#333333" })
  vim.api.nvim_set_hl(0, "CursorLine", { bg = "#444444" })
  vim.api.nvim_exec_autocmds("ColorScheme", {})

  local active = vim.api.nvim_get_hl(0, { name = "TabLineActive" })
  local inactive = vim.api.nvim_get_hl(0, { name = "TabLineInactive" })
  assert_eq(active.bg, 0x333333, "current tab background (the scheme's green, DiagnosticOk):")
  assert_eq(active.fg, 0x222222, "current tab text (the editor background):")
  assert_eq(inactive.bg, 0x444444, "other tabs' background (the cursorline surface):")
  assert_eq(inactive.fg, 0x111111, "other tabs' text:")
end)

vim.fn.delete(scratch_dir, "rf")
_H.finish()
