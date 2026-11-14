-- Spec for the <leader>ub light/dark switch (lua/andrew/themes/toggle.lua).
--
-- THE BUG THIS EXISTS FOR
--
-- Assigning vim.o.background resets vim.g.colors_name to nil. The conventional
-- colorscheme idiom
--
--     if vim.g.colors_name then vim.cmd("hi clear") end
--
-- is therefore already disarmed by the time it runs, if you set 'background'
-- first. onedarkpro's own generated output carries exactly that guard
-- (onedarkpro/lib/compile.lua:112), so returning to dark cleared NOTHING and
-- 248 highlight groups kept their soft-paper values.
--
-- It showed up as a light gutter. gitsigns rebuilds its ~49 groups on
-- ColorScheme but skips any that is "already defined"
-- (gitsigns/highlight.lua:302), so the stale light ones were never re-derived --
-- every GitSignsStaged* in particular. GitSignsAdd/Change/Delete looked fine
-- because soft-paper redefines those four by hand, which is exactly why the
-- fault was easy to miss.
--
-- Drives the REAL module with vim.cmd and vim.o stubbed, and asserts the
-- ORDER of operations. No source introspection.
--
-- Discriminating power (verified by reintroducing the bug):
--   * Re-adding the `if vim.g.colors_name then` guard around the clear -> the
--     clear stops being issued once background has been set, failing test 2.
--   * Dropping the clear entirely -> fails tests 1 and 2.
--   * Clearing BEFORE setting background -> fails the ordering assertion.
--   * Applying soft-paper via load() instead of :colorscheme -> fails test 4,
--     which is what keeps the ColorScheme event (and vault/colors.lua) alive.
--
-- Run with: nvim --headless -u NONE -l tests/theme_switch_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

local cfg = vim.fn.stdpath("config")

print("\n=== Theme Switch (<leader>ub) Tests ===\n")

--- Drive the real module, recording every vim.cmd call and background write.
---@param fn fun(T: table)
---@param colors_name string|nil value of vim.g.colors_name when the switch starts
---@return string[] trace
local function trace(fn, colors_name)
  local log = {}

  local real_cmd, real_g, real_o = vim.cmd, vim.g, vim.o
  local bg = "dark"

  local cmd = setmetatable({
    colorscheme = function(name)
      log[#log + 1] = "colorscheme " .. name
      -- the real :colorscheme sets this; mirror it so the module sees reality
      rawset(_G, "__colors_name", name)
    end,
  }, {
    __call = function(_, c) log[#log + 1] = tostring(c) end,
    __index = function(_, k)
      return function(...) log[#log + 1] = k .. " " .. tostring((...)) end
    end,
  })

  rawset(_G, "__colors_name", colors_name)
  local g_proxy = setmetatable({}, {
    __index = function(_, k)
      if k == "colors_name" then return rawget(_G, "__colors_name") end
      return real_g[k]
    end,
    __newindex = function(_, k, v) real_g[k] = v end,
  })
  local o_proxy = setmetatable({}, {
    __index = function(_, k)
      if k == "background" then return bg end
      return real_o[k]
    end,
    __newindex = function(_, k, v)
      if k == "background" then
        bg = v
        log[#log + 1] = "background=" .. tostring(v)
        -- THE TRAP: Neovim clears colors_name when 'background' is assigned.
        rawset(_G, "__colors_name", nil)
      else
        real_o[k] = v
      end
    end,
  })

  -- :colorscheme is stubbed, so soft-paper's load() never populates
  -- active_palette; stand it in so activate_soft_paper can reach its lualine call.
  local real_sp = package.loaded["andrew.themes.soft-paper"]
  package.loaded["andrew.themes.soft-paper"] = {
    active_palette = {},
    lualine_theme = function() return {} end,
  }

  vim.cmd, vim.g, vim.o = cmd, g_proxy, o_proxy
  package.loaded["andrew.themes.toggle"] = nil
  local T = dofile(cfg .. "/lua/andrew/themes/toggle.lua")
  local ok, err = pcall(fn, T)
  vim.cmd, vim.g, vim.o = real_cmd, real_g, real_o
  package.loaded["andrew.themes.soft-paper"] = real_sp
  package.loaded["andrew.themes.toggle"] = nil
  assert(ok, "driving the module failed: " .. tostring(err))
  return log
end

local function index_of(log, pattern)
  for i, line in ipairs(log) do
    if line:match(pattern) then return i end
  end
  return nil
end

-- ---------------------------------------------------------------------------
test("switching to dark clears highlights before applying the colorscheme", function()
  local log = trace(function(T) T.activate_onedark() end, "soft-paper-light")
  local clear = index_of(log, "^highlight clear$")
  local scheme = index_of(log, "^colorscheme onedark$")
  assert_true(clear ~= nil, "no `highlight clear` was issued: " .. vim.inspect(log))
  assert_true(scheme ~= nil, "onedark was never applied: " .. vim.inspect(log))
  assert_true(clear < scheme, "the clear must precede the colorscheme: " .. vim.inspect(log))
end)

test("the clear survives background having nulled colors_name", function()
  -- This is the whole bug: vim.o.background = "dark" sets colors_name to nil,
  -- so a `if vim.g.colors_name then` guard around the clear never fires.
  local log = trace(function(T) T.activate_onedark() end, "soft-paper-light")
  local bgi = index_of(log, "^background=dark$")
  local clear = index_of(log, "^highlight clear$")
  assert_true(bgi ~= nil, "background was never set: " .. vim.inspect(log))
  assert_true(clear ~= nil,
    "no clear after background nulled colors_name -- the guard is back: " .. vim.inspect(log))
  assert_true(bgi < clear, "background is set first, so the clear must be unguarded")
end)

test("a nil colors_name at entry still clears", function()
  -- Same assertion from the other direction: entering with no colorscheme at
  -- all must not skip the clear either.
  local log = trace(function(T) T.activate_onedark() end, nil)
  assert_true(index_of(log, "^highlight clear$") ~= nil,
    "clear skipped when colors_name started nil: " .. vim.inspect(log))
end)

test("soft-paper is applied via :colorscheme, not load()", function()
  -- Only the real command fires ColorScheme, which vault/colors.lua needs to
  -- re-derive ~120 Vault* groups, and render-markdown.lua hangs off too.
  local log = trace(function(T) T.activate_soft_paper("light") end, "onedark")
  assert_true(index_of(log, "^colorscheme soft%-paper%-light$") ~= nil,
    "soft-paper must go through :colorscheme: " .. vim.inspect(log))
end)

test("the light scheme keeps the name vault/colors.lua matches on", function()
  -- vault/colors.lua selects its palette by matching "^soft%-paper%-light$".
  -- Renaming the scheme sends every Vault highlight to the dark OneDark
  -- palette on a paper background.
  local log = trace(function(T) T.set_dark(false) end, "onedark")
  assert_true(index_of(log, "^colorscheme soft%-paper%-light$") ~= nil,
    "set_dark(false) must select exactly soft-paper-light: " .. vim.inspect(log))
end)

test("set_dark(true) routes to onedark", function()
  local log = trace(function(T) T.set_dark(true) end, "soft-paper-light")
  assert_true(index_of(log, "^colorscheme onedark$") ~= nil, vim.inspect(log))
end)

test("fortran keyword highlights survive a hi clear", function()
  -- Plain `link =` groups: a colorscheme's `hi clear` removes them outright, so
  -- one theme switch used to drop Fortran keyword colouring for the session.
  pcall(vim.api.nvim_del_augroup_by_name, "FortranHighlights")
  package.loaded["andrew.fortran.highlight"] = nil
  package.loaded["andrew.fortran.docs"] = { keywords = {} }

  local H = dofile(cfg .. "/lua/andrew/fortran/highlight.lua")
  H.setup_highlights()
  assert_eq(vim.api.nvim_get_hl(0, { name = "FortranMPIKeyword" }).link, "Constant",
    "setup_highlights did not define the group:")

  -- what a colorscheme does on the way in
  vim.cmd("highlight clear")
  assert_true(vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = "FortranMPIKeyword" })),
    "precondition: hi clear should have wiped the group")

  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert_eq(vim.api.nvim_get_hl(0, { name = "FortranMPIKeyword" }).link, "Constant",
    "the ColorScheme hook did not restore the group:")

  pcall(vim.api.nvim_del_augroup_by_name, "FortranHighlights")
  package.loaded["andrew.fortran.docs"] = nil
end)

_H.finish()
