-- Spec for the start screen's actions (the `dashboard` block of
-- lua/andrew/plugins/snacks.lua).
--
-- WHAT THIS IS GUARDING
--
-- Most rows of the dashboard do not call a picker themselves: their action is
-- a key sequence ("<leader>ff"), which snacks feeds as if typed, so the row
-- does whatever that key does. The price is that nothing ties the two
-- together. Rename or drop the mapping and the row still renders, still takes
-- its key, and does nothing at all -- no error, because typing an unmapped
-- sequence is not one.
--
-- So: every action given as keys must be a Normal-mode mapping this config
-- defines, either in core/keymaps.lua or in the `keys` of a plugin spec.
--
-- Run with: nvim --headless -u NONE -l tests/dashboard_keys_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_true = _H.test, _H.assert_true

local config_directory = vim.fn.stdpath("config")
package.path = config_directory
  .. "/lua/?.lua;"
  .. config_directory
  .. "/lua/?/init.lua;"
  .. package.path

print("\n=== Dashboard Action Tests ===\n")

---@param mode string|string[]|nil
---@return boolean
local function includes_normal_mode(mode)
  if mode == nil then
    return true -- lazy.nvim's default for a `keys` entry
  end
  return vim.tbl_contains(type(mode) == "table" and mode or { mode }, "n")
end

---@type table<string, boolean>
local normal_mode_mappings = {}

-- core/keymaps.lua, with vim.keymap.set recording instead of mapping.
local real_keymap_set = vim.keymap.set
---@param mode string|string[]
---@param lhs string
vim.keymap.set = function(mode, lhs)
  if includes_normal_mode(mode) then
    normal_mode_mappings[lhs] = true
  end
end
local did_load_core_keymaps, core_keymaps_error =
  pcall(dofile, config_directory .. "/lua/andrew/core/keymaps.lua")
vim.keymap.set = real_keymap_set

-- The `keys` of every plugin spec. A file may return one spec or a list of
-- them; one that cannot be evaluated without its plugin installed is skipped,
-- and its keys are then simply not known here.
---@param spec any
local function record_spec_keys(spec)
  if type(spec) ~= "table" then
    return
  end
  if type(spec.keys) == "table" then
    local keys = spec.keys ---@type (string|LazyKeysSpec)[]
    for _, key in ipairs(keys) do
      local lhs = type(key) == "table" and key[1] or key
      local mode = type(key) == "table" and key.mode or nil
      if type(lhs) == "string" and includes_normal_mode(mode) then
        normal_mode_mappings[lhs] = true
      end
    end
  end
  local nested_specs = spec ---@type any[]
  for _, nested_spec in ipairs(nested_specs) do
    record_spec_keys(nested_spec)
  end
end

for _, spec_file in
  ipairs(vim.fn.glob(config_directory .. "/lua/andrew/plugins/**/*.lua", true, true) --[[@as string[] ]])
do
  local did_load, spec = pcall(dofile, spec_file)
  if did_load then
    record_spec_keys(spec)
  end
end

-- Loads snacks.nvim's types for this file (lazydev).
---@module "snacks"

---@class DashboardKeysSnacksSpec  the part of plugins/snacks.lua's lazy spec this test reads
---@field opts { dashboard: { preset: { keys: snacks.dashboard.Item[] } } }

local snacks_spec = dofile(config_directory .. "/lua/andrew/plugins/snacks.lua") ---@type DashboardKeysSnacksSpec
local dashboard_items = snacks_spec.opts.dashboard.preset.keys

test("core/keymaps.lua loads", function()
  assert_true(
    did_load_core_keymaps,
    "core/keymaps.lua failed to load: " .. tostring(core_keymaps_error)
  )
end)

test("every dashboard action given as keys is a mapping this config defines", function()
  local key_actions = 0
  for _, item in ipairs(dashboard_items) do
    local action = item.action
    if type(action) == "string" and action:sub(1, 1) ~= ":" then
      key_actions = key_actions + 1
      assert_true(
        normal_mode_mappings[action],
        ("dashboard key %q (%s) feeds %s, which nothing maps in Normal mode"):format(
          item.key,
          item.desc,
          action
        )
      )
    end
  end
  assert_true(key_actions > 0, "no key-sequence actions found: the dashboard items were not read")
end)

_H.finish()
