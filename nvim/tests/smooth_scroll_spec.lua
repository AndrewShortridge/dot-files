-- Spec for the smooth-scroll / animation setup.
--
-- Covers:
--   * plugins/snacks.lua   -- animate + scroll opts
--   * core/options.lua     -- global 'smoothscroll' and vim.g.snacks_animate
--
-- Animated scrolling (snacks.scroll) is OFF by default; <leader>uS turns it on
-- for a session. Test 1 pins the default.
--
-- The scroll speed is set explicitly under `scroll` in plugins/snacks.lua and
-- is meant to be tuned there, so it is not pinned here. The top-level `animate`
-- table is still expected to carry no override (test 2): LazyVim passes none.
--
-- Drives the REAL specs (dofile) with a stubbed Snacks; options.lua is EXECUTED
-- and the resulting vim.o / vim.g state asserted, rather than pattern-matched.
--
-- Run with: nvim --headless -u NONE -l tests/smooth_scroll_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local cfg = vim.fn.stdpath("config")

print("\n=== Smooth Scroll / Animation Parity Tests ===\n")

---@class SmoothScrollSpecSnacksOpts
---@field scroll { enabled?: boolean }
---@field animate table<string, any>  test 2 reads it by key name

---@class SmoothScrollSpecSnacksPluginSpec
---@field opts SmoothScrollSpecSnacksOpts

-- Partial Snacks: only `toggle`, the one module snacks.lua's config() touches.
---@class SmoothScrollSpecFakeSnacks
---@field toggle table  callable and indexable; every lookup/call yields `noop`

-- snacks.lua's config() runs the whole <leader>u block, so Snacks has to exist.
---@return SmoothScrollSpecSnacksPluginSpec
local function snacks_spec()
  local noop = setmetatable({}, {
    ---@param t table
    ---@return fun(): table
    __index = function(t) return function() return t end end,
  })
  ---@type SmoothScrollSpecFakeSnacks
  local fake_snacks = {
    toggle = setmetatable({
      ---@return table
      option = function() return noop end,
    }, {
      ---@return table
      __call = function() return noop end,
      ---@return fun(): table
      __index = function() return function() return noop end end,
    }),
  }
  -- The fake implements only `toggle`; cast where it replaces the real global.
  _G.Snacks = fake_snacks --[[@as Snacks]]
  package.loaded["snacks"] = { setup = function() end }
  return dofile(cfg .. "/lua/andrew/plugins/snacks.lua")
end

-- ---------------------------------------------------------------------------
test("snacks keeps animate on but scroll off by default", function()
  local o = snacks_spec().opts
  assert_true(o.scroll ~= nil and o.scroll.enabled == false, "scroll must be disabled by default")
  -- animate stays on for dim, and for scroll when <leader>uS turns it on:
  -- scroll consults Snacks.animate.enabled().
  assert_true(o.animate ~= nil and o.animate.enabled == true, "animate must be enabled")
end)

test("top-level animate opts carry no override", function()
  local animate = snacks_spec().opts.animate
  for _, k in ipairs({ "duration", "easing", "fps" }) do
    assert_nil(animate[k], "animate." .. k .. " diverges from LazyVim, which passes no animate table")
  end
end)

test("options.lua sets smoothscroll globally and declares the animate switch", function()
  local had = vim.o.smoothscroll
  vim.o.smoothscroll = false
  vim.g.snacks_animate = nil
  dofile(cfg .. "/lua/andrew/core/options.lua")
  -- 'smoothscroll' only bites where 'wrap' is on. markdown sets it per-window
  -- already, so the global exists for every OTHER wrapped buffer -- notably any
  -- buffer where <leader>uw turns wrap on, which would otherwise scroll in
  -- whole-logical-line jumps.
  assert_eq(vim.o.smoothscroll, true, "core/options.lua must set smoothscroll globally:")
  assert_true(vim.g.snacks_animate ~= false, "vim.g.snacks_animate must not be off by default")
  vim.o.smoothscroll = had
end)

test("markdown keeps its own window-local smoothscroll", function()
  -- Deliberately redundant with the global: markdown wants screen-row scrolling
  -- regardless of what the global is later set to, and the ftplugin is the only
  -- thing that survives a user clearing the global.
  local src = table.concat(vim.fn.readfile(cfg .. "/ftplugin/markdown.lua"), "\n")
  assert_true(src:match("smoothscroll%s*=%s*true") ~= nil,
    "ftplugin/markdown.lua must keep setting smoothscroll window-locally")
end)

_H.finish()
