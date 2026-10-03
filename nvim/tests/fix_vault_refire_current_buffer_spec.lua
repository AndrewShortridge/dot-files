-- Regression spec: vault/init.lua's Phase-B autocmd re-fire must run with the
-- first markdown buffer CURRENT, not merely named.
--
-- The re-fire (`nvim_exec_autocmds("FileType", { buffer = ev.buf })`, plus
-- BufReadPost and BufEnter) only sets <abuf>. Everything it triggers reads the
-- CURRENT buffer and window: ftplugin/markdown.lua sets `vim.wo.wrap`,
-- `vim.wo.spell`, `vim.wo.conceallevel = 2` and ~140 buffer-local maps that
-- way. The first markdown buffer of a session is frequently not current --
-- every LSP hover float is a markdown buffer, and one tick later the cursor is
-- still in the code window -- so the first `K` in a fresh session turned wrap,
-- spell and concealing on in the FORTRAN window and bound `j`/`k` there.
-- Found live while checking the fortran-extras hover (float wrap trace).
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "the code window keeps its own options" fails if the nvim_buf_call
--     wrapper is removed: wrap flips to true, conceallevel to 2.
--   * "no markdown maps leak into the code buffer" fails likewise: `j`
--     acquires a buffer-local expr mapping in the Fortran buffer.
--   * "the float itself is still set up" fails if the re-fire is skipped
--     instead of scoped -- the ftplugin must still reach the real target.
--
-- Run with: nvim --headless -u NONE -l tests/fix_vault_refire_current_buffer_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local config = vim.fn.stdpath("config")
package.path = config .. "/lua/?.lua;" .. config .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:prepend(config)
vim.opt.runtimepath:append(config .. "/after")
vim.cmd("filetype plugin on")

vim.g.mapleader = " "
local tmp_vault = vim.fn.tempname() .. "-vault"
vim.fn.mkdir(tmp_vault, "p")
vim.g.vault_path = tmp_vault
vim.o.wrap = false

require("andrew.vault") -- installs the once-only markdown FileType autocmd

-- A code buffer in the only real window, exactly like a Fortran file under K.
local code = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(code, 0, -1, false, { "      PROGRAM MAIN", "      END" })
vim.bo[code].filetype = "fortran"
local code_win = vim.api.nvim_get_current_win()

-- An unfocused float showing a markdown buffer: the shape of an LSP hover.
local fbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "```fortran90", "SUBROUTINE HEAT(T)", "```" })
local fwin = vim.api.nvim_open_win(fbuf, false, { relative = "cursor", row = 1, col = 0, width = 30, height = 3 })
vim.bo[fbuf].filetype = "markdown" -- fires the once-only autocmd; Phase B is scheduled

-- Let the scheduled Phase B (and its re-fire) run.
vim.wait(2000, function()
  return false
end, 50)

test("the code window keeps its own options", function()
  assert_eq(vim.api.nvim_get_current_win(), code_win, "the cursor never left the code window:")
  assert_eq(vim.wo[code_win].wrap, false, "wrap stayed off in the code window:")
  assert_eq(vim.wo[code_win].spell, false, "spell stayed off in the code window:")
  assert_eq(vim.wo[code_win].conceallevel, 0, "nothing is concealed in the code window:")
  assert_eq(vim.bo[code].filetype, "fortran", "the code buffer is still Fortran:")
end)

test("no markdown maps leak into the code buffer", function()
  for _, lhs in ipairs({ "j", "k", "o" }) do
    local m = vim.fn.maparg(lhs, "n", false, true)
    assert_true(m.buffer == nil or m.buffer == 0, lhs .. " has no buffer-local map in the Fortran buffer:")
  end
  assert_nil(vim.b[code].__md_ftplugin_done, "the markdown ftplugin never ran against the code buffer:")
end)

test("the float itself is still set up", function()
  assert_true(vim.api.nvim_win_is_valid(fwin), "the float is still open:")
  assert_eq(vim.wo[fwin].wrap, true, "the markdown ftplugin reached the float window:")
  assert_eq(vim.b[fbuf].__md_ftplugin_done, true, "the ftplugin ran once against the float buffer:")
end)

_H.finish()
