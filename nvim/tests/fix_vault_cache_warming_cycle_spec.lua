-- Regression spec (audit2 fix pass, vault-a "changes needed outside my files" #1):
-- engine.lua required cache_warming.lua from its own top-level chunk, while
-- cache_warming.lua requires engine back. That closes a require CYCLE: under
-- some load orders Lua raised "loop or previous error loading module
-- 'andrew.vault.engine'", engine's pcall swallowed it, and the entire idle cache
-- warming feature silently never existed -- setup() never ran, no warming
-- autocmd was created and :VaultWarmDebug was absent (observed once during the
-- audit with `andrew.core.options` required before vault/init.lua).
--
-- The fix defers engine's side of the cycle to vim.schedule, so engine is fully
-- loaded before cache_warming asks for it -- in every load order.
--
-- Run with: nvim --headless -u NONE -l tests/fix_vault_cache_warming_cycle_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;"
  .. vim.fn.stdpath("config") .. "/lua/?/init.lua;" .. package.path

local tmp_vault = vim.fn.tempname() .. "-vault"
vim.fn.mkdir(tmp_vault, "p")
vim.g.vault_path = tmp_vault

test("engine does not require cache_warming from its own top-level chunk", function()
  local src = table.concat(
    vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/andrew/vault/engine.lua"), "\n")
  local at = src:find('require, "andrew.vault.cache_warming"', 1, true)
  assert_true(at ~= nil, "engine must still load cache_warming somehow")
  -- The require must sit inside a vim.schedule callback, not at chunk level.
  local before = src:sub(1, at)
  local sched = before:match(".*()vim%.schedule%(function%(%)")
  assert_true(sched ~= nil,
    "the cache_warming require must be wrapped in vim.schedule, or the require cycle comes back")
end)

test("requiring engine loads and sets up cache_warming on the next tick", function()
  assert_eq(package.loaded["andrew.vault.cache_warming"], nil,
    "cache_warming must not be loaded before engine is required")

  require("andrew.vault.engine")
  -- Not yet: the whole point is that it happens after engine finished loading.
  assert_eq(package.loaded["andrew.vault.cache_warming"], nil,
    "cache_warming must not be required from engine's own chunk")

  vim.wait(500, function() return package.loaded["andrew.vault.cache_warming"] ~= nil end)
  assert_true(package.loaded["andrew.vault.cache_warming"] ~= nil,
    "cache_warming must be loaded once the scheduled callback runs")
end)

test(":VaultWarmDebug exists and warming is in the cache registry", function()
  -- cache_warming registers itself with engine from its own vim.schedule, so
  -- drain one more tick.
  local engine = require("andrew.vault.engine")
  vim.wait(500, function() return engine._cache_registry.warming ~= nil end)
  assert_true(engine._cache_registry.warming ~= nil,
    "cache_warming must register itself with engine's cache registry")

  local cmds = vim.api.nvim_get_commands({})
  assert_true(cmds.VaultWarmDebug ~= nil, ":VaultWarmDebug must exist")
end)

vim.fn.delete(tmp_vault, "rf")

_H.finish()
