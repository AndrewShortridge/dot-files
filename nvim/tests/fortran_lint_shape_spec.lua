-- Spec for the Fortran linter registration in lua/andrew/plugins/linting.lua.
--
-- Two real bugs lived here, both invisible because they masked each other:
--
--   1. The linter was registered as a TABLE whose `args` was a function.
--      nvim-lint treats `args` as a list and maps its evaluator over the
--      elements (lint.lua:381, `vim.tbl_map(eval, linter.args)`), so elements
--      may be functions but the field may not. Every lint attempt threw
--      "t: expected table, got function" out of vim.tbl_map, swallowed by
--      try_lint's pcall -- Fortran linting had simply never run.
--
--   2. `cwd` was a function too. nvim-lint types cwd as a string and hands it
--      straight to uv.spawn. Unreachable while (1) threw first.
--
-- The fix registers a FUNCTION returning the linter table (nvim-lint resolves
-- function linters in lookup_linter, lint.lua:83), which keeps the per-run
-- freshness the `args` function was reaching for.
--
-- Drives the REAL plugin spec via dofile with a fake `lint` module injected
-- into package.loaded, the same technique as which_key_icons_spec.
--
-- NOT covered here, deliberately: the infinite-loop guard in
-- get_fortran_project_root. Its regression mode is a HANG, not a failed
-- assertion, so a spec for it would wedge the whole suite instead of reporting.
-- It is verified by opening a Fortran buffer with no root marker above it and
-- checking nvim still exits. Test 3 below pins the underlying fact that makes
-- the guard necessary.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * Test 1 fails if the linter goes back to being a plain table.
--   * Test 2 fails if `args` or `cwd` is a function again.
--   * Test 3 fails if lua_dirname stops being a fixed point -- at which point
--     the guard could be dropped, and this spec says so.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_lint_shape_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- Fake nvim-lint. try_lint/linters_by_ft are written to by the real config.
local fake_lint = { linters = {}, linters_by_ft = {}, try_lint = function() end }
package.loaded["lint"] = fake_lint

-- gfortran must look installed for the Fortran linter to register.
local real_executable = vim.fn.executable

-- linting.lua returns ONE lazy spec, whose [1] is the repo string -- not a list
-- of specs. Guard that, because `spec[1] or spec` silently yields the string and
-- every assertion below then skips instead of failing.
local plug = dofile(vim.fn.stdpath("config") .. "/lua/andrew/plugins/linting.lua")
assert_true(type(plug) == "table", "linting.lua must return a table")
assert_true(type(plug[1]) == "string", "spec[1] must be the repo name")
assert_true(type(plug.config) == "function", "spec must have a config function")

local cfg_ok, cfg_err = pcall(plug.config)
assert_true(cfg_ok, "config() must not error: " .. tostring(cfg_err))

local function fortran_linter_name()
  local by_ft = fake_lint.linters_by_ft.fortran
  return by_ft and by_ft[1] or nil
end

-- If this ever goes nil the tests below would pass vacuously, which is exactly
-- how the first draft of this spec failed to catch either mutation. gfortran is
-- present on this machine; if it is not, that is a fact worth failing on rather
-- than skipping silently.
test("the Fortran linter actually registered (guards against vacuous passes)", function()
  assert_true(
    fortran_linter_name() ~= nil,
    "no Fortran linter registered -- is a compiler installed? Every assertion "
      .. "below is meaningless without one"
  )
end)

test("the Fortran linter is registered as a FUNCTION, not a table", function()
  local name = assert(fortran_linter_name())
  assert_eq(
    type(fake_lint.linters[name]),
    "function",
    "nvim-lint resolves function linters in lookup_linter; a table here means `args` "
      .. "must be a literal list, which the dynamic include paths cannot be"
  )
end)

test("the resolved linter has a LIST args and a STRING cwd", function()
  local name = assert(fortran_linter_name())
  local ok, linter = pcall(fake_lint.linters[name])
  assert_true(ok, "resolving the linter must not error: " .. tostring(linter))
  assert_eq(type(linter.args), "table", "args must be a list -- nvim-lint tbl_maps over it")
  assert_eq(type(linter.cmd), "string", "cmd must be a string")
  assert_eq(type(linter.cwd), "string", "cwd must be a string -- it goes straight to uv.spawn")
  for i, a in ipairs(linter.args) do
    assert_eq(type(a), "string", "arg " .. i .. " must be a string after resolution")
  end
end)

test("lua_dirname has a fixed point, so root walks MUST guard against it", function()
  local lua_dirname = require("andrew.vault.link_utils").lua_dirname

  -- It returns its argument unchanged when no parent matches, and it does so
  -- one level below root. Any `while path ~= "/"` walk over it spins forever.
  assert_eq(lua_dirname("/tmp/a/b"), "/tmp/a", "normal case still walks up")
  assert_eq(lua_dirname("/tmp"), "/tmp", "FIXED POINT: one level below root returns itself")

  -- Demonstrate the guard's shape, bounded so this spec can never hang.
  local path, steps, hit_fixed_point = "/tmp/a/b/c", 0, false
  while path ~= "/" and path ~= "" and steps < 50 do
    steps = steps + 1
    local parent = lua_dirname(path)
    if parent == path then
      hit_fixed_point = true
      break
    end
    path = parent
  end
  assert_true(hit_fixed_point, "the walk must terminate via the fixed-point guard, not via \"/\"")
  assert_true(steps < 50, "and it must do so quickly")
end)

vim.fn.executable = real_executable
_H.finish({ style = "results", exit = "os" })
