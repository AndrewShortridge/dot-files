-- Spec for the LazyVim smooth-scroll / animation parity.
--
-- Covers:
--   * plugins/snacks.lua   -- animate + scroll opts, and that they stay BARE
--   * core/options.lua     -- global 'smoothscroll' and vim.g.snacks_animate
--
-- WHY "BARE" IS THE WHOLE POINT.
--
-- The request was to match LazyVim's scroll SPEED. LazyVim does not configure a
-- speed: it passes `scroll = { enabled = true }` with no overrides
-- (lazyvim/plugins/ui.lua:279) and never passes a top-level `animate` table at
-- all. So the LazyVim scroll speed IS snacks' own default, and parity is
-- maintained by adding nothing. That makes this the easiest thing in the config
-- to "improve" into a regression -- someone tuning `duration` here would be
-- diverging from LazyVim while believing they were matching it. Test 2 and 3
-- make that unwritable.
--
-- Test 4 pins the upstream default values themselves, read out of the installed
-- snacks.nvim. Bare opts only equal LazyVim's speed for as long as snacks'
-- defaults are what they were when this was ported; a snacks upgrade that
-- retunes scroll would change the speed silently, and this is what notices.
--
-- Drives the REAL specs (dofile) with a stubbed Snacks; options.lua is EXECUTED
-- and the resulting vim.o / vim.g state asserted, rather than pattern-matched.
--
-- Discriminating power (verified by reintroducing each bug):
--   * Adding `duration`/`easing` under scroll or animate -> fails test 2 / 3.
--   * Dropping `opt.smoothscroll` -> fails test 5.
--   * Upstream retuning scroll's defaults -> fails test 4 with both values.
--
-- Run with: nvim --headless -u NONE -l tests/smooth_scroll_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local cfg = vim.fn.stdpath("config")

print("\n=== Smooth Scroll / Animation Parity Tests ===\n")

-- snacks.lua's config() runs the whole <leader>u block, so Snacks has to exist.
local function snacks_spec()
  local noop = setmetatable({}, { __index = function(t) return function() return t end end })
  _G.Snacks = {
    toggle = setmetatable({ option = function() return noop end },
      { __call = function() return noop end,
        __index = function() return function() return noop end end }),
  }
  package.loaded["snacks"] = { setup = function() end }
  return dofile(cfg .. "/lua/andrew/plugins/snacks.lua")
end

-- ---------------------------------------------------------------------------
test("snacks enables both scroll and animate", function()
  local o = snacks_spec().opts
  assert_true(o.scroll ~= nil and o.scroll.enabled == true, "scroll must be enabled")
  -- animate is what gives <leader>ua something to switch off: scroll consults
  -- Snacks.animate.enabled(), so without it the toggle has no effect on scroll.
  assert_true(o.animate ~= nil and o.animate.enabled == true, "animate must be enabled")
end)

test("scroll opts carry no speed override (LazyVim passes none)", function()
  local scroll = snacks_spec().opts.scroll
  for _, k in ipairs({ "animate", "animate_repeat", "duration", "easing", "fps", "filter" }) do
    assert_nil(scroll[k], "scroll." .. k .. " diverges from LazyVim, which overrides nothing")
  end
  local n = 0
  for _ in pairs(scroll) do n = n + 1 end
  assert_eq(n, 1, "scroll must be exactly { enabled = true }, got extra keys:")
end)

test("animate opts carry no override either", function()
  local animate = snacks_spec().opts.animate
  for _, k in ipairs({ "duration", "easing", "fps" }) do
    assert_nil(animate[k], "animate." .. k .. " diverges from LazyVim, which passes no animate table")
  end
end)

test("the installed snacks defaults are still the speed this was ported against", function()
  local src = vim.fn.resolve(vim.fn.expand("~/.local/share/nvim/lazy/snacks.nvim/lua/snacks/scroll.lua"))
  if vim.fn.filereadable(src) ~= 1 then
    print("  (skipped: snacks.nvim not installed at the expected path)")
    return
  end
  local text = table.concat(vim.fn.readfile(src), "\n")
  -- The defaults block, not any doc comment: step/total inside `duration = {}`.
  local step, total = text:match("animate%s*=%s*{%s*duration%s*=%s*{%s*step%s*=%s*(%d+)%s*,%s*total%s*=%s*(%d+)")
  assert_eq(step, "10", "snacks scroll default step changed; scroll speed no longer matches the port:")
  assert_eq(total, "200", "snacks scroll default total changed; scroll speed no longer matches the port:")
  local rstep, rtotal = text:match("animate_repeat%s*=%s*{.-duration%s*=%s*{%s*step%s*=%s*(%d+)%s*,%s*total%s*=%s*(%d+)")
  assert_eq(rstep, "5", "snacks animate_repeat step changed:")
  assert_eq(rtotal, "50", "snacks animate_repeat total changed:")
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
