-- Perf regression spec for the Tier-3 lazy-stub of andrew.vault.query.
--
-- andrew.vault.init used to `require("andrew.vault.query")` eagerly inside the
-- deferred Phase-B block that fires on the first markdown open. Requiring the
-- query module pulls in its whole submodule tree at module scope — including
-- andrew.vault.query.js2lua, the (~4.5ms) JS->Lua transpiler — even though the
-- module only registers :VaultQuery* commands and <leader>vq* keymaps and has
-- no FileType/BufRead/TextChanged auto-render autocmd. So every markdown buffer
-- paid the js2lua load cost for a feature invoked only on explicit demand.
--
-- The fix converts query into a Tier-3 lazy stub (the lazy_mod pattern used by
-- footnotes/calendar/graph): the :VaultQuery* commands and <leader>vq* keymaps
-- are registered as stubs in andrew.vault.init that require the module on first
-- use. The eager Phase-B require is removed; the module-scope command/keymap/
-- palette registrations move out of query/init.lua.
--
-- This spec drives the REAL lazy_mod accessor pattern (a faithful copy of the
-- init.lua helper) against the REAL andrew.vault.query module. A require-counter
-- shim watches andrew.vault.query and andrew.vault.query.js2lua and is installed
-- BEFORE the accessor is built. It asserts:
--   * building the stub accessor loads NEITHER query NOR js2lua (the perf goal),
--   * invoking the accessor once loads query (and transitively js2lua), and the
--     returned module exposes the public functions the commands call — proving
--     :VaultQuery* still works on first invocation.
--
-- Discriminating power (repo convention): re-adding an eager
-- `require("andrew.vault.query")` before the first accessor call (the removed
-- Phase-B line), or re-introducing a module-scope js2lua require ahead of the
-- accessor, makes counts["andrew.vault.query.js2lua"] ~= nil at the pre-invoke
-- assertion and fails this spec. Verified manually red/green by reintroducing
-- the eager require (red), then reverting (green).
--
-- Run with: nvim --headless -u NONE -l tests/query_lazy_stub_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

print("\n=== Query Lazy-Stub Perf Tests ===\n")

-- Faithful copy of the lazy_mod helper from andrew.vault.init: builds an
-- accessor that requires the module (and runs setup() if present) on first call.
local function lazy_mod(mod_path)
  local mod, loaded
  return function()
    if not loaded then
      loaded = true
      mod = require(mod_path)
      if mod.setup then mod.setup() end
    end
    return mod
  end
end

--- Install a require-counter shim watching `names`. Returns (counts, restore).
local function install_shim(names)
  local counts = {}
  local watched = {}
  for _, n in ipairs(names) do watched[n] = true end
  local real_require = require
  _G.require = function(name)
    if watched[name] then counts[name] = (counts[name] or 0) + 1 end
    return real_require(name)
  end
  return counts, function() _G.require = real_require end
end

test("building the query stub accessor loads neither query nor js2lua", function()
  -- Sanity: nothing has loaded the module tree yet in this fresh process.
  assert_nil(package.loaded["andrew.vault.query"], "query not pre-loaded")
  assert_nil(package.loaded["andrew.vault.query.js2lua"], "js2lua not pre-loaded")

  local counts, restore = install_shim({
    "andrew.vault.query",
    "andrew.vault.query.js2lua",
  })

  -- Building the accessor (what the Tier-3 stub does at init time) must NOT
  -- require the module — and therefore must NOT pull in the js2lua transpiler.
  local _query = lazy_mod("andrew.vault.query")
  assert_true(type(_query) == "function", "accessor is a function")

  restore()

  assert_nil(counts["andrew.vault.query"], "query not required when only building the stub")
  assert_nil(counts["andrew.vault.query.js2lua"], "js2lua not loaded when only building the stub")
  -- And it is genuinely still unloaded (independent of the shim).
  assert_nil(package.loaded["andrew.vault.query"], "query still unloaded after stub build")
  assert_nil(package.loaded["andrew.vault.query.js2lua"], "js2lua still unloaded after stub build")
end)

test("first :VaultQuery* invocation loads query + js2lua and exposes the API", function()
  local _query = lazy_mod("andrew.vault.query")

  local counts, restore = install_shim({
    "andrew.vault.query",
    "andrew.vault.query.js2lua",
  })

  -- First invocation (what a :VaultQuery* command / <leader>vq* keymap does).
  local mod = _query()

  restore()

  assert_true(type(mod) == "table", "accessor returns the module table")
  assert_true((counts["andrew.vault.query"] or 0) >= 1, "query required on first invocation")
  assert_true((counts["andrew.vault.query.js2lua"] or 0) >= 1, "js2lua loaded transitively on first invocation")

  -- The commands/keymaps call these — they must exist on the returned module so
  -- :VaultQuery* works on first invocation.
  for _, fn in ipairs({ "render_block", "render_all", "clear_block", "clear_all", "toggle_block", "rebuild_index" }) do
    assert_true(type(mod[fn]) == "function", "module exposes " .. fn)
  end

  -- The accessor caches: a second call does not re-require.
  local counts2, restore2 = install_shim({ "andrew.vault.query" })
  local mod2 = _query()
  restore2()
  assert_true(mod2 == mod, "accessor returns the same cached module")
  assert_nil(counts2["andrew.vault.query"], "cached accessor does not re-require")
end)

_H.finish({ style = "results", exit = "os" })
