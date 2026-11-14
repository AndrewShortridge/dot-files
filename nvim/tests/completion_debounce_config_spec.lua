-- Perf regression spec: completion debounce interval is config-driven and
-- responsive (not the legacy 250ms inline fallback).
--
-- config.completion previously had NO debounce_ms key, so completion_base's
-- conf("debounce_ms", 250) fell back to 250ms — a long stall before the
-- completion menu first populates after a vault-index invalidation. The fix
-- adds config.completion.debounce_ms (~100ms), keeping the value config-driven.
--
-- This drives the REAL andrew.vault.config / completion_base modules (no mocks,
-- no source-introspection). It proves end-to-end wiring by setting a distinctive
-- sentinel value and verifying completion_base reports it via debug_info().
--
-- Discriminating power:
--   * Deleting the debounce_ms key from config.lua (reintroducing the bug)
--     makes assertion 1 fail (key is nil / not <= 120).
--   * Hardcoding 250 (or breaking the conf read) in completion_base makes the
--     sentinel assertion fail (debug_info reports 250, not the sentinel).
--
-- Run with: nvim --headless -u NONE -l tests/completion_debounce_config_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local config = require("andrew.vault.config")

print("\n=== Completion Debounce Config Tests ===\n")

-- ---------------------------------------------------------------------------
-- 1) The config key exists, is a number, and is responsive (not 250 fallback).
-- ---------------------------------------------------------------------------
test("config.completion.debounce_ms is a responsive number", function()
  local v = config.completion.debounce_ms
  assert_true(type(v) == "number", "debounce_ms must be a number, got " .. type(v))
  assert_true(v <= 120, "debounce_ms must be <= 120 (responsive), got " .. tostring(v))
  assert_true(v >= 0, "debounce_ms must be >= 0, got " .. tostring(v))
end)

-- ---------------------------------------------------------------------------
-- 2) completion_base consumes the config key end-to-end (wiring proof).
--    Set a sentinel value, re-require completion_base so the conf read picks
--    it up, then assert debug_info() reports the sentinel (not 250).
-- ---------------------------------------------------------------------------
test("completion_base reads config.completion.debounce_ms", function()
  local saved = config.completion.debounce_ms
  local SENTINEL = 7
  config.completion.debounce_ms = SENTINEL

  package.loaded["andrew.vault.completion_base"] = nil
  local ok, err = pcall(function()
    local completion_base = require("andrew.vault.completion_base")
    -- Create a real source via the build path (no index build required).
    completion_base.create_source({
      name = "debounce_test",
      build = function(_, cb)
        cb({})
      end,
    })
    local lines = completion_base.debug_info()
    local joined = table.concat(lines, "\n")
    assert_true(
      joined:find("debounce_ms=" .. SENTINEL, 1, true) ~= nil,
      "debug_info should report debounce_ms=" .. SENTINEL .. ", got:\n" .. joined
    )
  end)

  -- finally: restore config + reload completion_base with real value so the
  -- shared aggregate-run state is clean for later specs.
  config.completion.debounce_ms = saved
  package.loaded["andrew.vault.completion_base"] = nil
  require("andrew.vault.completion_base")

  assert_true(ok, "sentinel wiring body errored: " .. tostring(err))
end)

_H.finish({ style = "results", exit = "os" })
