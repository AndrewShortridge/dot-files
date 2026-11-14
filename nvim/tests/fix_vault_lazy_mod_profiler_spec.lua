-- Regression specs (audit2 fix pass):
--
-- 1. vault-b §4.3 -- vault/init.lua's lazy_mod() set its `loaded` latch BEFORE
--    the require, so a module that failed to load poisoned the memo: `mod`
--    stayed nil and every later call through that stub raised
--    "attempt to index a nil value" at init.lua's own call site instead of the
--    real error. Reproduced during the audit while fzf-lua was unavailable:
--    the first :VaultUnlinked showed the real require error, then
--    :VaultUnlinkedAll / :VaultAutoLink / :VaultAutoLinkAll all reported the
--    useless nil-index message and the cause was gone.
--
-- 2. vault-c §4c -- :VaultMemorySnapshot and :VaultMemoryReset reported success
--    ("Memory snapshot saved" / "Profiler timing windows reset") even though
--    both are no-ops while the profiler is disabled, unlike
--    :VaultMemoryProfile / :VaultMemoryDiff which correctly say so.
--
-- Requiring andrew.vault runs init.lua's Tier-1 chunk only (no plugin manager,
-- no markdown buffer), which is where both live.
--
-- Run with: nvim --headless -u NONE -l tests/fix_vault_lazy_mod_profiler_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;"
  .. vim.fn.stdpath("config") .. "/lua/?/init.lua;" .. package.path

vim.g.mapleader = " "
local tmp_vault = vim.fn.tempname() .. "-vault"
vim.fn.mkdir(tmp_vault, "p")
vim.g.vault_path = tmp_vault

-- Make one lazy_mod() target fail to load, BEFORE init.lua's chunk runs (the
-- stub only requires it on first use, so the order does not actually matter --
-- but this keeps the spec honest about never having loaded the real module).
local BOOM = "BOOM-simulated-load-failure"
package.loaded["andrew.vault.stats"] = nil
package.preload["andrew.vault.stats"] = function() error(BOOM, 0) end

require("andrew.vault") -- Tier 1

test("a lazy_mod stub never turns a failed require into a nil-index error", function()
  local errs = {}
  for i = 1, 3 do
    local ok, err = pcall(vim.cmd, "VaultStats")
    assert_true(not ok, "call " .. i .. " should have failed")
    errs[i] = tostring(err)
  end
  -- First call: the module's own error, verbatim.
  assert_true(errs[1]:find(BOOM, 1, true) ~= nil,
    "the first call must surface the module's own error, got: " .. errs[1])
  -- Later calls: Lua's own "previous error loading module <name>" (require does
  -- not retry a module that already blew up). Either way the message still
  -- names the module that failed -- the point of the fix is that it is never the
  -- opaque nil-index error from init.lua's call site, which is what the stub
  -- produced when it latched `loaded` before the require.
  for i, err in ipairs(errs) do
    assert_true(err:find("attempt to index a nil value", 1, true) == nil,
      "call " .. i .. " must not degrade into a nil-index error, got: " .. err)
  end
  for i = 2, 3 do
    assert_true(errs[i]:find("andrew.vault.stats", 1, true) ~= nil,
      "call " .. i .. " must still name the module that failed, got: " .. errs[i])
  end
end)

test("a lazy_mod stub still memoizes a module that loads", function()
  local loads = 0
  package.loaded["andrew.vault.pins"] = nil
  package.preload["andrew.vault.pins"] = function()
    loads = loads + 1
    return { setup = function() end, list = function() end }
  end
  -- :VaultPins goes through the same stub; three calls, one require.
  for _ = 1, 3 do pcall(vim.cmd, "VaultPins") end
  assert_eq(loads, 1, "the module must be required exactly once")
end)

test("memory_profiler exposes whether it is actually collecting", function()
  local profiler = require("andrew.vault.memory_profiler")
  assert_eq(type(profiler.is_enabled), "function", "is_enabled() must exist")
  -- setup() was never called in this spec, so nothing is being collected and the
  -- snapshot/reset calls below are no-ops.
  assert_eq(profiler.is_enabled(), false)
end)

test(":VaultMemorySnapshot / :VaultMemoryReset say 'disabled' instead of 'saved'", function()
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m, lvl) msgs[#msgs + 1] = { tostring(m), lvl } end

  local ok1 = pcall(vim.cmd, "VaultMemorySnapshot")
  local ok2 = pcall(vim.cmd, "VaultMemoryReset")

  vim.notify = orig
  assert_true(ok1 and ok2, "neither command may throw")
  assert_eq(#msgs, 2, "each command must notify exactly once, got " .. vim.inspect(msgs))
  for _, m in ipairs(msgs) do
    assert_true(m[1]:lower():find("disabled", 1, true) ~= nil,
      "must report the profiler is disabled, got: " .. m[1])
    assert_eq(m[2], vim.log.levels.WARN, "and at WARN level, not INFO")
  end
end)

vim.fn.delete(tmp_vault, "rf")

_H.finish()
