-- Spec for the flash.nvim char-mode "repeat with no state" crash guard
-- installed by lua/andrew/plugins/flash.lua's `config`.
--
-- =============================================================================
-- The upstream bug (flash.nvim @ 5f0f270, lua/flash/plugins/char.lua:118-126)
-- =============================================================================
-- flash.repeat sets `Repeat.is_repeat = true` from a `vim.on_key` hook the
-- moment a literal `.` is consumed in normal mode, and clears it only on the
-- NEXT `vim.schedule`. Char mode's f/F/t/T/;/, mapping takes the repeat branch
-- on that flag and then dereferences `M.state` with no nil check:
--
--     if Repeat.is_repeat then
--       M.jump_labels = false
--       M.state:jump({ count = vim.v.count1 })   -- char.lua:123
--       M.state:show()
--
-- `M.state` stays nil until the first successful char jump of the session, so a
-- `.` immediately followed by f/F/t/T/;/, in the SAME input batch (a quick `.`
-- after "nothing to repeat", a paste, a macro, a --remote-send burst) raises
--
--     E5108: .../flash/plugins/char.lua:123: attempt to index field 'state'
--
-- and wedges the session on a hit-enter prompt. Upstream's one-liner is
-- `if Repeat.is_repeat and M.state then`.
--
-- =============================================================================
-- What the config does instead (fix under test)
-- =============================================================================
-- The plugin checkout must stay pristine (`:Lazy` reports local changes
-- otherwise), so `config` re-wraps flash's OWN f/F/t/T/;/, mappings after
-- `require("flash").setup(opts)` and clears the stale flag when `M.state` is
-- nil, letting the keypress fall through to the ordinary non-repeat jump.
--
-- Assertions here:
--   1. the spec still returns folke/flash.nvim and now carries a `config`;
--   2. after `config` runs, every f/F/t/T/;/, mapping is OUR wrapper, not
--      char.lua's callback (and `;`/`,` are only taken over if flash owned
--      them -- flash itself declines to steal a pre-existing `;`/`,` map);
--   3. the exact crash condition -- `Repeat.is_repeat == true` with
--      `Char.state == nil` -- no longer errors, clears the flag and performs a
--      normal jump (cursor lands on the target char);
--   4. the guard is inert once a jump has happened: a genuine repeat with a
--      live `M.state` still reaches char.lua's repeat branch;
--   5. `config` is tolerant -- it never throws, even when the plugin's internal
--      modules are missing or have been renamed.
--
-- Discriminating power: dropping the `Repeat.is_repeat = false` line from
-- flash.lua's wrapper makes test 3 fail with the E5108 above; dropping the
-- whole wrapper makes test 2 fail as well.
--
-- Run with: nvim --headless -u NONE -l tests/fix_plugins_flash_repeat_spec.lua

local _H =
  dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

local cfgdir = vim.fn.stdpath("config")
local spec = dofile(cfgdir .. "/lua/andrew/plugins/flash.lua")

test("flash spec still points at folke/flash.nvim and defines a config hook", function()
  assert_eq(spec[1], "folke/flash.nvim", "spec must point at folke/flash.nvim")
  assert_eq(type(spec.config), "function", "spec must carry the guard in `config`")
  assert_eq(spec.opts.modes.char.multi_line, false, "char mode must stay line-local")
end)

-- ---------------------------------------------------------------------------
-- Load the real plugin. Without the checkout there is nothing to guard, so the
-- behavioural tests are skipped rather than failed (keeps the suite green on a
-- machine that has not run :Lazy install).
-- ---------------------------------------------------------------------------
local flash_root = vim.fn.stdpath("data") .. "/lazy/flash.nvim"
local have_flash = vim.fn.isdirectory(flash_root) == 1

if not have_flash then
  print("SKIP: flash.nvim not installed at " .. flash_root)
  _H.finish({ style = "results", exit = "os" })
  return
end

vim.opt.runtimepath:prepend(flash_root)
vim.opt.termguicolors = true

-- `config(plugin, opts)` is lazy.nvim's signature.
local ok_config, config_err = pcall(spec.config, spec, spec.opts)
test("config() runs without throwing", function()
  assert_true(ok_config, "config must not error: " .. tostring(config_err))
end)

local Char = require("flash.plugins.char")
local Repeat = require("flash.repeat")

local function callback_source(key, mode)
  local map = vim.fn.maparg(key, mode or "n", false, true)
  if type(map) ~= "table" or type(map.callback) ~= "function" then
    return nil
  end
  local info = debug.getinfo(map.callback, "S")
  return type(info) == "table" and info.source or nil
end

test("every char-mode key is wrapped by the config, not by char.lua", function()
  for _, key in ipairs({ "f", "F", "t", "T", ";", "," }) do
    for _, mode in ipairs({ "n", "x", "o" }) do
      local src = callback_source(key, mode)
      assert_true(src ~= nil, ("%s (%s) must still be mapped to a Lua callback"):format(key, mode))
      assert_true(
        src:find("andrew/plugins/flash%.lua") ~= nil,
        ("%s (%s) must be the config's wrapper, got %s"):format(key, mode, src)
      )
    end
  end
end)

-- ---------------------------------------------------------------------------
-- The crash itself.
-- ---------------------------------------------------------------------------
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "alpha bravo gamma delta gamma",
  "one two three four five",
})
vim.api.nvim_win_set_buf(0, buf)

--- Send keys through the real mapping, exactly as a typed batch would.
--- @return boolean ok, string? err
local function type_keys(keys)
  return pcall(
    vim.api.nvim_feedkeys,
    vim.api.nvim_replace_termcodes(keys, true, false, true),
    "x",
    false
  )
end

test("`f<char>` with is_repeat set and state nil jumps instead of erroring", function()
  -- Exactly the state a `.` immediately followed by `fg` leaves behind.
  Char.state = nil
  Repeat.is_repeat = true
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.v.errmsg = ""

  local ok, err = type_keys("fg")
  assert_true(ok, "the f mapping must not raise: " .. tostring(err))
  assert_false(
    tostring(vim.v.errmsg):find("char%.lua") ~= nil,
    "no char.lua error may be reported, got: " .. tostring(vim.v.errmsg)
  )
  assert_eq(
    vim.api.nvim_win_get_cursor(0)[2],
    12,
    "`fg` must land on the g of `gamma` (0-based col 12)"
  )
  assert_false(Repeat.is_repeat, "the stale repeat flag must have been cleared")
  assert_true(Char.state ~= nil, "a normal jump must have created the char state")
end)

test("a stale repeat flag makes every char key behave exactly as a plain press", function()
  -- The guard must be indistinguishable from "the `.` never happened": for each
  -- key, run it from a clean state WITHOUT the stale flag (the reference), then
  -- again WITH it, and require the same landing column.
  local cases = {
    { keys = "Fb", from = { 1, 12 }, what = "`Fb` from col 12" },
    { keys = "tg", from = { 1, 0 }, what = "`tg` from col 0" },
    { keys = "Ta", from = { 1, 12 }, what = "`Ta` from col 12" },
    { keys = ";", from = { 1, 0 }, what = "`;` with no prior jump" },
    { keys = ",", from = { 1, 0 }, what = "`,` with no prior jump" },
  }
  --- Run `keys` from a pristine char-mode state; returns the landing column.
  local function run(keys, from, stale)
    Char.state = nil
    Char.motion = "f"
    Char.jump_labels = false
    Repeat.is_repeat = stale and true or false
    vim.api.nvim_win_set_cursor(0, from)
    vim.v.errmsg = ""
    local ok, err = type_keys(keys)
    vim.wait(20)
    return vim.api.nvim_win_get_cursor(0)[2], ok, err
  end

  for _, case in ipairs(cases) do
    local want = run(case.keys, case.from, false)
    local got, ok, err = run(case.keys, case.from, true)
    assert_true(ok, case.what .. " must not raise with a stale flag: " .. tostring(err))
    assert_false(
      tostring(vim.v.errmsg):find("char%.lua") ~= nil,
      case.what .. " must not report a char.lua error, got: " .. tostring(vim.v.errmsg)
    )
    assert_eq(got, want, case.what .. " must land where a plain press lands")
  end
end)

test("a genuine repeat with a live state still takes char.lua's repeat branch", function()
  -- Establish a real state first, the way a normal `fg` does.
  Char.state = nil
  Repeat.is_repeat = false
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert_true(select(1, type_keys("fg")), "the priming jump must succeed")
  assert_true(Char.state ~= nil, "priming jump must leave a state behind")
  assert_eq(vim.api.nvim_win_get_cursor(0)[2], 12, "priming jump lands on col 12")

  -- Now the flag is legitimate: the wrapper must leave it alone and flash must
  -- repeat the jump off the live state.
  Repeat.is_repeat = true
  vim.v.errmsg = ""
  local ok, err = type_keys("f")
  assert_true(ok, "repeat branch must not raise: " .. tostring(err))
  assert_true(Repeat.is_repeat, "a legitimate repeat flag must NOT be cleared by the guard")
  assert_eq(vim.api.nvim_win_get_cursor(0)[2], 24, "the repeat must advance to the second gamma")
  Repeat.is_repeat = false
end)

test("config() is idempotent and never double-wraps into a loop", function()
  local ok, err = pcall(spec.config, spec, spec.opts)
  assert_true(ok, "a second config() must not error: " .. tostring(err))
  local src = callback_source("f", "n")
  assert_true(
    src ~= nil and src:find("andrew/plugins/flash%.lua") ~= nil,
    "f must still be the config's wrapper after a re-run, got " .. tostring(src)
  )
  Char.state = nil
  Repeat.is_repeat = true
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert_true(select(1, type_keys("fg")), "`fg` must still work after a re-run")
  assert_eq(vim.api.nvim_win_get_cursor(0)[2], 12, "`fg` still lands on col 12 after a re-run")
end)

test("config() tolerates flash internals being renamed or missing", function()
  -- Stub `flash.setup` out so only the guard half of `config` is exercised,
  -- then simulate a future flash where char.lua/repeat.lua no longer exist,
  -- where the modules are not tables at all, or where `is_repeat` is gone
  -- because the bug was finally fixed upstream. None of it may throw.
  local saved = {
    flash = package.loaded["flash"],
    char = package.loaded["flash.plugins.char"],
    rep = package.loaded["flash.repeat"],
    is_repeat = Repeat.is_repeat,
  }
  package.loaded["flash"] = { setup = function() end }

  local variants = {
    ["`is_repeat` removed upstream"] = function()
      package.loaded["flash.repeat"] = { setup = function() end }
    end,
    ["char module is not a table"] = function()
      package.loaded["flash.plugins.char"] = "renamed"
    end,
    ["repeat module is not a table"] = function()
      package.loaded["flash.repeat"] = 42
    end,
  }

  local results = {}
  for name, prepare in pairs(variants) do
    package.loaded["flash.plugins.char"] = saved.char
    package.loaded["flash.repeat"] = saved.rep
    prepare()
    local ok, err = pcall(spec.config, spec, spec.opts)
    results[name] = { ok = ok, err = err }
  end

  package.loaded["flash"] = saved.flash
  package.loaded["flash.plugins.char"] = saved.char
  package.loaded["flash.repeat"] = saved.rep
  Repeat.is_repeat = saved.is_repeat

  for name, r in pairs(results) do
    assert_true(r.ok, name .. " must be tolerated, got: " .. tostring(r.err))
  end
end)

_H.finish({ style = "results", exit = "os" })
