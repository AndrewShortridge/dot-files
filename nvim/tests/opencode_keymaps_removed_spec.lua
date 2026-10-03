-- Spec for opencode.nvim having NO keymaps (lua/andrew/plugins/opencode.lua).
--
-- History. The spec originally defined all 10 AI keymaps inside config() with
-- no lazy gate, so lazy.nvim loaded opencode (6 plugin/*.lua files) at every
-- startup. That was fixed by moving the keymaps into a `keys` table -- the mere
-- PRESENCE of `keys` implies lazy=true -- and the startup side effects into
-- init(), which runs without loading the plugin.
--
-- 2026-09-06: the keymaps were removed by request. The plugin, its snacks
-- dependency and its init() side effects all stay; only the bindings are gone,
-- so opencode has no interactive entry point.
--
-- That removal is exactly where the old fix becomes a trap. Deleting `keys`
-- also deletes the ONLY thing that made the plugin lazy, so a spec with the
-- keymaps stripped and nothing else changed reverts to lazy=false and resumes
-- sourcing opencode at startup -- the original perf bug, now with no keymaps to
-- justify it. `lazy = true` has to be set explicitly to replace the implication
-- `keys` used to carry. Test 2 is the guard for that.
--
-- This drives the REAL plugin spec table (dofile) and, for the which-key group,
-- the REAL which-key spec with a fake which-key injected into package.loaded --
-- the same technique as which_key_icons_spec. No source introspection.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * Test 2 fails if `keys` comes back, if `lazy = true` is dropped (the
--     silent eager-load regression), or if lazy/event/cmd/ft are set to
--     anything that would make the dormant plugin load again.
--   * Test 3 fails if any keymap definition is left anywhere in the spec under
--     any handler key, including a stray `keys = {}` that would re-imply
--     lazy=true and mask a missing `lazy = true`.
--   * Test 4 fails if init() is deleted along with the keymaps -- the request
--     was to remove the bindings, NOT the setup, so autoread and
--     vim.g.opencode_opts must survive.
--   * Test 5 fails if the <leader>o which-key group is left behind, which would
--     render an empty menu on a prefix that no longer resolves to anything.
--
-- Run with: nvim --headless -u NONE -l tests/opencode_keymaps_removed_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local config_dir = vim.fn.stdpath("config")
local plug = dofile(config_dir .. "/lua/andrew/plugins/opencode.lua")

test("plugin spec returns a table for NickvanDyke/opencode.nvim", function()
  assert_true(type(plug) == "table", "spec must return a table")
  assert_eq(plug[1], "NickvanDyke/opencode.nvim", "spec must point at opencode.nvim")
end)

test("still dormant at startup: lazy=true now carries what `keys` used to imply", function()
  -- With no keys/cmd/event/ft handler left, lazy.nvim falls back to lazy=false
  -- unless lazy is set explicitly. This is the whole point of the spec.
  assert_true(plug.lazy == true, "lazy must be explicitly true (no handler left to imply it)")
  assert_nil(plug.keys, "keys must be gone (the keymaps were removed)")
  assert_nil(plug.event, "event gate must not be present")
  assert_nil(plug.cmd, "cmd gate must not be present")
  assert_nil(plug.ft, "ft gate must not be present")
  assert_nil(plug.config, "config must stay dropped (side effects belong in init)")
  assert_true(type(plug.init) == "function", "init function must exist for startup side effects")
end)

test("no keymap definitions survive under any lazy.nvim handler key", function()
  -- lazy.nvim only ever reads keymaps out of `keys`, but assert the broader
  -- property so a keymap smuggled back under another field is caught too.
  for _, field in ipairs({ "keys", "config", "opts", "event", "cmd", "ft" }) do
    local v = plug[field]
    assert_true(
      v == nil or type(v) ~= "table" or #v == 0,
      "field '" .. field .. "' must not carry keymap entries"
    )
  end

  -- A stray `keys = {}` would re-imply lazy=true and hide a missing lazy flag.
  assert_true(rawget(plug, "keys") == nil, "keys must be absent, not an empty table")
end)

test("init() still applies startup side effects (setup was NOT removed)", function()
  local prev_opts = vim.g.opencode_opts
  local prev_autoread = vim.o.autoread
  vim.g.opencode_opts = nil
  vim.o.autoread = false

  local ok, err = pcall(plug.init)

  local got_opts = vim.g.opencode_opts
  local got_autoread = vim.o.autoread

  vim.g.opencode_opts = prev_opts
  vim.o.autoread = prev_autoread

  assert_true(ok, "init must not error: " .. tostring(err))
  assert_true(type(got_opts) == "table", "init must set vim.g.opencode_opts to a table")
  assert_true(got_autoread == true, "init must set autoread=true (opencode reload.lua expects it)")
end)

test("which-key no longer registers a <leader>o group", function()
  -- Drive the real which-key spec with a fake which-key, as which_key_icons_spec
  -- does, and assert the now-empty OpenCode prefix is gone.
  local captured = {}
  package.loaded["which-key"] = {
    setup = function() end,
    add = function(specs)
      for _, s in ipairs(specs) do captured[#captured + 1] = s end
    end,
  }
  local wk = dofile(config_dir .. "/lua/andrew/plugins/which-key.lua")
  wk.config()
  package.loaded["which-key"] = nil

  assert_true(#captured > 0, "which-key spec must register entries (fake capture failed)")
  for _, e in ipairs(captured) do
    assert_true(
      e[1] ~= "<leader>o",
      "<leader>o group must be removed (it would render an empty menu)"
    )
  end
end)

_H.finish({ style = "results", exit = "os" })
