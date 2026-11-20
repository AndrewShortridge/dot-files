-- Spec for the LazyVim <leader>u UI/Toggle port.
--
-- Covers the files that have to agree with each other:
--   * plugins/snacks.lua      -- the <leader>u toggle block + scroll/animate opts
--   * plugins/gitsigns.lua    -- <leader>uG, registered from opts()
--   * core/options.lua        -- pins showtabline = 2
--   * themes/toggle.lua       -- light/dark backing the <leader>ub toggle
--
-- FOUR THINGS THIS PROTECTS.
--
-- 1. The LazyVim letter alignment. ud/uD are diagnostics/dimming, which is the
--    REVERSE of what this config used before; ui -> ug and ur -> uL moved too.
--    A regression here is silent -- the key still works, it just does the other
--    thing -- so the mapping is asserted by name, not merely by presence.
--
-- 2. <leader>ug must NOT be `<cmd>IBLToggle<CR>`. The ibl spec declares only
--    `ft`, no `cmd`, so lazy.nvim creates no command stub and that form threw
--    E492 in any buffer where ibl had not loaded. It also must not require ibl
--    from `get`, or which-key drawing the popup would defeat ibl's ft gate.
--
-- 3. <leader>uG comes from gitsigns' opts(), not from snacks.lua. Registering it
--    eagerly would make which-key's `get` pull gitsigns in ahead of BufReadPre.
--
-- 4. The removals stay removed: the <leader>ut cycler, the duplicate <leader>ub
--    colourscheme picker, and :ThemeCycle.
--
-- Drives the REAL plugin specs (dofile) against a stubbed Snacks that records
-- every toggle and :map() call. No source introspection.
--
-- Discriminating power (verified by reintroducing each bug):
--   * Swapping ud/uD back -> fails the letter table.
--   * Restoring `<cmd>IBLToggle<CR>` -> fails the ug-is-a-toggle assertion.
--   * Making ug's `get` call require("ibl.config") -> fails the lazy-get test.
--   * Moving uG into snacks.lua -> fails both the gitsigns and the
--     not-in-snacks assertions.
--   * Re-adding <leader>ut or the ub picker -> fails the removals test.
--   * Dropping scroll/animate from opts -> fails the smooth-scroll test.
--
-- Run with: nvim --headless -u NONE -l tests/ui_toggles_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local cfg = vim.fn.stdpath("config")

print("\n=== UI Toggle (<leader>u) Tests ===\n")

-- ---------------------------------------------------------------------------
-- Stub Snacks and capture everything the specs register
-- ---------------------------------------------------------------------------

--- Opts a stubbed toggle constructor receives: full `snacks.toggle.Opts` from
--- `Snacks.toggle(...)`, a `snacks.toggle.Config` from the builtin toggles.
--- @alias UiTogglesSpecToggleOpts snacks.toggle.Opts|snacks.toggle.Config

--- @class UiTogglesSpecCaptured
--- @field toggles table<string, string>  key -> toggle name
--- @field plain table<string, string>  key -> keymap desc
--- @field defs table<string, UiTogglesSpecToggleOpts>  toggle name -> opts

--- The lazy.nvim spec of snacks.lua / gitsigns.lua. Narrowed from
--- `LazyPluginSpec`: `config` is called here with a nil `self` (and is never
--- `true`), and `opts` is a table (snacks.lua) or a no-argument function (gitsigns.lua).
--- @class UiTogglesSpecPluginSpec: LazyPluginSpec
--- @field config? fun(self: LazyPlugin?, opts: table)
--- @field opts? snacks.Config|fun(): table

--- @param path string  plugin spec file to dofile
--- @param how fun(spec: UiTogglesSpecPluginSpec)  drives the loaded spec
--- @return UiTogglesSpecCaptured captured  { toggles = {key -> name}, plain = {key -> desc}, defs = {name -> opts} }
--- @return UiTogglesSpecPluginSpec spec
local function drive(path, how)
  local captured = { toggles = {}, plain = {}, defs = {} } ---@type UiTogglesSpecCaptured

  --- @param name string
  --- @param opts? UiTogglesSpecToggleOpts
  --- @return UiTogglesSpecFakeToggle
  local function make_toggle(name, opts)
    --- Stand-in for `snacks.toggle.Class`: records its name and opts, and
    --- `:map()` records the key instead of creating a mapping.
    --- @class UiTogglesSpecFakeToggle
    --- @field name string
    --- @field opts UiTogglesSpecToggleOpts
    local t = { name = name, opts = opts or {} }
    --- @param self UiTogglesSpecFakeToggle
    --- @param keys string
    --- @return UiTogglesSpecFakeToggle
    t.map = function(self, keys)
      captured.toggles[keys] = self.name
      captured.defs[self.name] = self.opts
      return self
    end
    return t
  end

  local toggle = setmetatable({
    --- @param o string
    --- @param opts? snacks.toggle.Config|{ name?: string }
    --- @return UiTogglesSpecFakeToggle
    option = function(o, opts) return make_toggle((opts or {}).name or o, opts) end,
    --- @return UiTogglesSpecFakeToggle
    line_number = function() return make_toggle("Line Numbers") end,
    --- @return UiTogglesSpecFakeToggle
    diagnostics = function() return make_toggle("Diagnostics") end,
    --- @return UiTogglesSpecFakeToggle
    treesitter = function() return make_toggle("Treesitter Highlight") end,
    --- @return UiTogglesSpecFakeToggle
    inlay_hints = function() return make_toggle("Inlay Hints") end,
    --- @return UiTogglesSpecFakeToggle
    dim = function() return make_toggle("Dimming") end,
    --- @return UiTogglesSpecFakeToggle
    animate = function() return make_toggle("Animations") end,
    --- @return UiTogglesSpecFakeToggle
    scroll = function() return make_toggle("Smooth Scroll") end,
  }, {
    --- @param _ table  the toggle table itself
    --- @param opts snacks.toggle.Opts
    --- @return UiTogglesSpecFakeToggle
    __call = function(_, opts) return make_toggle(opts.name, opts) end,
  })

  local prev_snacks, prev_loaded = _G.Snacks, package.loaded["snacks"]
  -- Partial Snacks on purpose: the driven specs only reach `toggle` and `zen`.
  ---@class UiTogglesSpecFakeSnacks
  local fake_snacks = { toggle = toggle, zen = function() end }
  _G.Snacks = fake_snacks --[[@as Snacks]]
  package.loaded["snacks"] = { setup = function() end }

  local real_set = vim.keymap.set
  --- Same signature as `vim.keymap.set`; records the desc instead of mapping.
  ---@type fun(mode: string|string[], lhs: string, rhs: string|function, opts?: vim.keymap.set.Opts)
  vim.keymap.set = function(_, lhs, _, opts)
    captured.plain[lhs] = (opts or {}).desc or ""
  end

  local spec = dofile(path) ---@type UiTogglesSpecPluginSpec
  local ok, err = pcall(how, spec)

  vim.keymap.set = real_set
  _G.Snacks, package.loaded["snacks"] = prev_snacks, prev_loaded
  assert(ok, "driving " .. path .. " failed: " .. tostring(err))
  return captured, spec
end

local snacks = drive(cfg .. "/lua/andrew/plugins/snacks.lua",
  --- @param spec UiTogglesSpecPluginSpec
  function(spec)
  -- snacks.lua's opts is a table.
  spec.config(nil, spec.opts --[[@as snacks.Config?]] or {})
end)

local gits = drive(cfg .. "/lua/andrew/plugins/gitsigns.lua",
  --- @param spec UiTogglesSpecPluginSpec
  function(spec)
  assert(type(spec.opts) == "function", "gitsigns opts must be a function so uG registers on load")
  spec.opts()
end)

-- ---------------------------------------------------------------------------
test("every requested toggle exists on its LazyVim letter", function()
  local expected = {
    ["<leader>us"] = "Spelling",
    ["<leader>uw"] = "Wrap",
    ["<leader>uL"] = "Relative Number",
    ["<leader>ul"] = "Line Numbers",
    ["<leader>ud"] = "Diagnostics",
    ["<leader>uc"] = "Conceal Level",
    ["<leader>uT"] = "Treesitter Highlight",
    ["<leader>uh"] = "Inlay Hints",
    ["<leader>uD"] = "Dimming",
    ["<leader>ua"] = "Animations",
    ["<leader>uS"] = "Smooth Scroll",
    ["<leader>uA"] = "Tabline",
    ["<leader>ub"] = "Dark Background",
    ["<leader>ug"] = "Indention Guides",
  }
  local wrong = {} ---@type string[]
  for key, name in pairs(expected) do
    if snacks.toggles[key] ~= name then
      wrong[#wrong + 1] = string.format("%s: want %q got %q", key, name, tostring(snacks.toggles[key]))
    end
  end
  table.sort(wrong)
  assert_eq(table.concat(wrong, " | "), "", "toggles on the wrong letter")
end)

test("dimming and diagnostics are NOT swapped back", function()
  -- The single most likely regression: this config used the opposite pair.
  assert_eq(snacks.toggles["<leader>ud"], "Diagnostics", "<leader>ud must be diagnostics:")
  assert_eq(snacks.toggles["<leader>uD"], "Dimming", "<leader>uD must be dimming:")
end)

test("indent guides is a toggle, not the broken IBLToggle command", function()
  assert_eq(snacks.toggles["<leader>ug"], "Indention Guides")
  assert_nil(snacks.plain["<leader>ui"], "the old <leader>ui IBLToggle mapping must be gone")
  for lhs, desc in pairs(snacks.plain) do
    assert_true(not tostring(desc):match("indent"), "indent guides must not be a plain keymap: " .. lhs)
  end
end)

test("indent guides `get` does not force-load ibl", function()
  -- which-key calls get() just to draw the popup icon; requiring ibl there
  -- would load it in every filetype and defeat its `ft` gate.
  local def = snacks.defs["Indention Guides"]
  assert_true(def ~= nil and type(def.get) == "function", "no get function captured")
  ---@type table?
  package.loaded["ibl.config"] = nil
  local ok, res = pcall(def.get)
  assert_true(ok, "get() errored when ibl was not loaded: " .. tostring(res))
  assert_eq(res, false, "get() must report disabled when ibl is not loaded:")
  assert_nil(package.loaded["ibl.config"], "get() must not have loaded ibl")
end)

test("git signs is registered from the gitsigns spec, not snacks", function()
  assert_eq(gits.toggles["<leader>uG"], "Git Signs")
  assert_nil(snacks.toggles["<leader>uG"], "uG must not be registered eagerly from snacks.lua")
end)

test("smooth scrolling is enabled in snacks opts", function()
  local _, spec = drive(cfg .. "/lua/andrew/plugins/snacks.lua",
    --- @param s UiTogglesSpecPluginSpec
    function(s)
    -- snacks.lua's opts is a table.
    s.config(nil, s.opts --[[@as snacks.Config?]] or {})
  end)
  -- snacks.lua's opts is a table.
  ---@cast spec { opts: snacks.Config }
  -- snacks.plugins.Config's per-plugin configs (snacks.scroll.Config, snacks.animate.Config)
  -- do not declare `enabled`, which snacks/init.lua's setup() reads on every one of them.
  ---@diagnostic disable-next-line: undefined-field
  assert_true(spec.opts.scroll ~= nil and spec.opts.scroll.enabled == true, "scroll must be enabled")
  -- Same upstream gap as above (snacks.animate.Config has no `enabled`).
  ---@diagnostic disable-next-line: undefined-field
  assert_true(spec.opts.animate ~= nil and spec.opts.animate.enabled == true, "animate must be enabled")
end)

test("the removed mappings stay removed", function()
  assert_nil(snacks.toggles["<leader>ut"], "theme cycler must be gone")
  assert_nil(snacks.plain["<leader>ut"], "theme cycler must be gone")
  assert_nil(snacks.toggles["<leader>ur"], "old relativenumber letter must be gone")
  -- <leader>ub is now the background toggle, never the colourscheme picker
  assert_eq(snacks.toggles["<leader>ub"], "Dark Background")
  assert_nil(snacks.plain["<leader>ub"], "the duplicate colourscheme picker must be gone")
  assert_eq(snacks.plain["<leader>uC"], "Colorschemes", "the surviving picker keeps <leader>uC:")
end)

test("the theme module exposes light/dark and has dropped the cycler", function()
  package.loaded["andrew.themes.toggle"] = nil
  local T = dofile(cfg .. "/lua/andrew/themes/toggle.lua") ---@type table<string, function>
  assert_true(type(T.set_dark) == "function", "set_dark missing")
  assert_true(type(T.is_dark) == "function", "is_dark missing")
  assert_true(type(T.activate_soft_paper) == "function", "activate_soft_paper missing")
  assert_nil(rawget(T, "cycle"), "M.cycle must be gone")
end)

test("showtabline is pinned so the tabline is visible by default", function()
  local src = table.concat(vim.fn.readfile(cfg .. "/lua/andrew/core/options.lua"), "\n")
  assert_true(src:match("opt%.showtabline%s*=%s*2") ~= nil,
    "core/options.lua must set showtabline = 2: nothing else turns the tabline on")
end)

_H.finish()
