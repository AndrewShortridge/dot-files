-- Regression spec (vault-b audit): :VaultLinkDiag must not recurse forever on
-- URLs that url_validate resolves synchronously.
--
-- Bug found by the vault-b audit: linkdiag's run_url_validation() queued EVERY
-- uncached URL into url_validate.validate_batch() and called M.validate(bufnr)
-- from both the per-result and the completion callback. url_validate.validate_url()
-- invokes its callback SYNCHRONOUSLY for an excluded URL (config.url_validation
-- .exclude_patterns -- localhost, 127.*, 192.168.*, ...) and never caches the
-- result, so the callback re-entered run_url_validation with the same still-
-- uncached URL. One `http://localhost:9/x` in a note was enough to hang Neovim:
--   linkdiag.validate -> run_url_validation -> validate_batch -> validate_url
--   -> callback -> linkdiag.validate -> ... -> "stack overflow"
-- Observed for real: `:VaultLinkDiag` on a note containing a localhost URL never
-- returned and nvim had to be SIGTERMed.
--
-- Run with: nvim --headless -u NONE -l tests/audit_vault_b_linkdiag_url_recursion_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local tmp_vault = vim.fn.tempname() .. "-vault"
vim.fn.mkdir(tmp_vault, "p")
vim.g.vault_path = tmp_vault

local url_validate = require("andrew.vault.url_validate")
local linkdiag = require("andrew.vault.linkdiag")

test("localhost / LAN URLs are reported as excluded", function()
  assert_true(url_validate.is_excluded("http://localhost:9/none"), "localhost must be excluded")
  assert_true(url_validate.is_excluded("https://127.0.0.1/x"), "127.* must be excluded")
  assert_true(url_validate.is_excluded("http://192.168.1.5/x"), "192.168.* must be excluded")
  assert_true(not url_validate.is_excluded("https://example.com/x"), "public URLs must not be excluded")
end)

test("an excluded URL resolves its callback synchronously and caches nothing", function()
  local calls = 0
  local result
  url_validate.validate_url("http://localhost:9/none", function(r) calls = calls + 1; result = r end)
  assert_eq(calls, 1, "callback must have fired synchronously")
  assert_eq(result.error, "excluded", "excluded URLs report error='excluded'")
  assert_true(url_validate.get_cached("http://localhost:9/none") == nil,
    "excluded URLs must not be cached (this is what made the retry loop unbounded)")
end)

test("validate() on a note with a localhost URL terminates", function()
  local note = tmp_vault .. "/urls.md"
  vim.fn.writefile({ "# URLs", "", "- http://localhost:9/none", "- http://127.0.0.1:9/also" }, note)
  vim.cmd("edit! " .. vim.fn.fnameescape(note))
  vim.bo.filetype = "markdown"
  local bufnr = vim.api.nvim_get_current_buf()

  -- Count re-entries: before the fix this grew until "stack overflow".
  local entries = 0
  local orig = linkdiag.validate
  local guard
  guard = function(b)
    entries = entries + 1
    if entries > 50 then error("run-away recursion: validate() re-entered " .. entries .. " times") end
    return orig(b)
  end
  linkdiag.validate = guard

  local ok, err = pcall(guard, bufnr)
  vim.wait(500)
  linkdiag.validate = orig

  assert_true(ok, "validate() must not error; got: " .. tostring(err))
  assert_true(entries <= 50, "validate() must not re-enter unboundedly (saw " .. entries .. ")")
end)

vim.fn.delete(tmp_vault, "rf")

_H.finish()
