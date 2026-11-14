-- Regression spec (vault-b audit): the sidebar Meta panel's `a` (add field) key
-- must act on the NOTE, not on the sidebar's own scratch buffer.
--
-- Bug found by the vault-b audit: sidebar_meta's `a` called
-- frontmatter_editor.open() directly. That function reads
-- nvim_get_current_buf() and guards with engine.is_vault_buf(); pressed from the
-- focused sidebar the current buffer is the sidebar scratch buffer (no name), so
-- the editor answered "Vault: not a vault file" and never opened. The panel's
-- <CR> handler already redirected to the source buffer/window, `a` did not.
-- Observed for real: <leader>vSm, <leader>vSf, then `a` -> "not a vault file".
--
-- Run with: nvim --headless -u NONE -l tests/audit_vault_b_sidebar_meta_add_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local tmp_vault = vim.fn.tempname() .. "-vault"
vim.fn.mkdir(tmp_vault, "p")
vim.g.vault_path = tmp_vault

local note = tmp_vault .. "/note.md"
vim.fn.writefile({ "---", "title: Note", "---", "", "# Note" }, note)

local engine = require("andrew.vault.engine")
local sidebar_meta = require("andrew.vault.sidebar_meta")

test("`a` hands focus back to the source window before opening the editor", function()
  vim.cmd("edit! " .. vim.fn.fnameescape(note))
  vim.bo.filetype = "markdown"
  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_get_current_buf()
  assert_true(engine.is_vault_buf(source_buf), "precondition: note must be a vault buffer")

  -- Stand in for the sidebar: a scratch split that is NOT a vault buffer.
  vim.cmd("vsplit")
  local side_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), side_buf)
  assert_true(not engine.is_vault_buf(side_buf), "sidebar scratch buffer must not be a vault buffer")

  sidebar_meta.setup_keymaps(side_buf, source_win)

  local cb
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(side_buf, "n")) do
    if m.lhs == "a" then cb = m.callback end
  end
  assert_true(cb ~= nil, "the Meta panel must map `a`")

  -- Stub frontmatter_editor so the assertion is about the buffer it would see.
  local seen_buf
  package.loaded["andrew.vault.frontmatter_editor"] = {
    open = function() seen_buf = vim.api.nvim_get_current_buf() end,
  }

  cb()

  assert_eq(seen_buf, source_buf,
    "frontmatter_editor.open() must run with the note as the current buffer")
  assert_true(engine.is_vault_buf(seen_buf), "and that buffer must pass the is_vault_buf guard")
end)

vim.fn.delete(tmp_vault, "rf")

_H.finish()
