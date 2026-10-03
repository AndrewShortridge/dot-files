-- Regression spec: :VaultFoldClear from a NON-vault buffer must not touch the
-- vault's callout-fold sidecar.
--
-- Bug found by the vault-a audit: M.clear() called load_db() (the *cached*
-- store loader) BEFORE the is_vault_buf() guard. That primed the in-memory
-- store cache for whatever vault was active, and the VimLeavePre teardown()
-- then wrote that cache back out -- creating a `.vault-callout-folds.json`
-- in a vault where the user had never edited a note. Observed for real: a
-- `:VaultFoldClear` in a scratch buffer created the sidecar in the active
-- vault root on exit.
--
-- Run with: nvim --headless -u NONE -l tests/audit_vault_a_callout_clear_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- Point the plugin at a throwaway vault BEFORE engine.lua is first required.
local tmp_vault = vim.fn.tempname() .. "-vault"
vim.fn.mkdir(tmp_vault, "p")
vim.g.vault_path = tmp_vault

local engine = require("andrew.vault.engine")
local cf = require("andrew.vault.callout_folds")

local sidecar = tmp_vault .. "/.vault-callout-folds.json"

assert_eq(engine.vault_path, tmp_vault, "engine must honour vim.g.vault_path override")

test("clear() from a non-vault buffer writes nothing and creates no sidecar", function()
  vim.cmd("enew!") -- unnamed scratch buffer: never inside the vault
  assert_true(not engine.is_vault_buf(vim.api.nvim_get_current_buf()), "scratch buffer must not be a vault buffer")

  cf.clear()
  assert_eq(vim.fn.filereadable(sidecar), 0, "clear() must not create the sidecar from a non-vault buffer")

  -- The VimLeavePre path: teardown() must not flush a primed cache either.
  cf.teardown()
  assert_eq(vim.fn.filereadable(sidecar), 0, "teardown() after a non-vault clear() must not create the sidecar")
end)

test("clear(true) still rewrites the sidecar for the active vault", function()
  cf.clear(true)
  assert_eq(vim.fn.filereadable(sidecar), 1, "clear(all) must still write an empty db")
  local raw = table.concat(vim.fn.readfile(sidecar), "")
  local ok, decoded = pcall(vim.json.decode, raw)
  assert_true(ok, "sidecar must stay valid JSON, got: " .. tostring(raw))
  assert_eq(vim.tbl_count(decoded or {}), 0, "clear(all) must leave an empty db")
end)

test("record_toggle/debug/clear round-trip still works for a vault note", function()
  local note = tmp_vault .. "/spec-note.md"
  vim.fn.writefile({ "---", "type: note", "---", "> [!note]- Head", "> body one" }, note)
  vim.cmd("edit! " .. vim.fn.fnameescape(note))
  local bufnr = vim.api.nvim_get_current_buf()
  assert_true(engine.is_vault_buf(bufnr), "note inside the vault must be a vault buffer")

  cf.record_toggle(bufnr, 4, true) -- override the '-' (closed) default
  local raw = table.concat(vim.fn.readfile(sidecar), "")
  assert_true(raw:find("spec%-note%.md") ~= nil, "override must be persisted, got: " .. raw)

  cf.clear()
  local after = table.concat(vim.fn.readfile(sidecar), "")
  assert_true(after:find("spec%-note%.md") == nil, "clear() must drop this file's overrides, got: " .. after)
end)

vim.fn.delete(tmp_vault, "rf")

_H.finish()
