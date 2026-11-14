-- Spec for the <leader>gB / <leader>gY gitbrowse guard in plugins/git.lua.
--
-- THE BUG. snacks.nvim's gitbrowse aborts every failure path with
-- `error("__ignore__")` (snacks/gitbrowse.lua:125) after showing a friendly
-- Snacks.notify.error. Lua prefixes the source position, so the
-- `err ~= "__ignore__"` filter in snacks' own M.open (gitbrowse.lua:143-148)
-- never matches and the sentinel is RE-RAISED. Pressing <leader>gB on a file
-- outside a git repo therefore dumped a raw
--   E5108: Lua: .../snacks/gitbrowse.lua:125: __ignore__
-- traceback plus a hit-enter prompt on top of the friendly notification.
-- <leader>gY is worse: it passes `notify = false`, so the traceback was the
-- ONLY feedback.
--
-- THE FIX. Both keys now go through a local `gitbrowse_guarded` that pcalls
-- Snacks.gitbrowse and swallows ONLY an error containing "__ignore__";
-- anything else is re-raised with error(err, 0) so real bugs stay visible.
--
-- Discriminating power:
--   * Dropping the pcall on either key            -> "swallows" test fails.
--   * Swallowing every error (bare `pcall(...)`)  -> "re-raises" test fails.
--   * Losing the copy-to-register opts on gY      -> "opts" test fails.
--
-- Drives the REAL spec (dofile + a stubbed _G.Snacks); no source introspection.
--
-- Run with: nvim --headless -u NONE -l tests/fix_plugins_git_gitbrowse_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_match = _H.test, _H.assert_eq, _H.assert_true, _H.assert_match

local cfg = vim.fn.stdpath("config")
local git = dofile(cfg .. "/lua/andrew/plugins/git.lua")

--- Find the callback of a `keys = {}` entry by its lhs.
local function fn_for(lhs)
  for _, k in ipairs(git.keys or {}) do
    if k[1] == lhs then
      return k[2]
    end
  end
end

local gB, gY = fn_for("<leader>gB"), fn_for("<leader>gY")

test("both gitbrowse keys exist and carry a Lua callback", function()
  assert_eq(type(gB), "function", "<leader>gB")
  assert_eq(type(gY), "function", "<leader>gY")
end)

-- The exact string snacks re-raises: error("__ignore__") inside gitbrowse.lua,
-- which Lua turns into "<file>:<line>: __ignore__", then M.open error()s it on.
local SENTINEL = "/home/x/.local/share/nvim/lazy/snacks.nvim/lua/snacks/gitbrowse.lua:125: __ignore__"

for _, case in ipairs({ { "<leader>gB", gB }, { "<leader>gY", gY } }) do
  local name, fn = case[1], case[2]

  test(name .. " swallows the snacks __ignore__ sentinel", function()
    _G.Snacks = { gitbrowse = function() error(SENTINEL) end }
    local ok, err = pcall(fn)
    assert_true(ok, name .. " raised instead of swallowing: " .. tostring(err))
  end)

  test(name .. " still re-raises a real error", function()
    _G.Snacks = { gitbrowse = function() error("kaboom: something actually broke") end }
    local ok, err = pcall(fn)
    assert_true(not ok, name .. " swallowed a real error")
    assert_match(tostring(err), "kaboom", name .. " lost the real message")
  end)
end

test("<leader>gY still copies the url instead of opening it", function()
  local got
  _G.Snacks = { gitbrowse = function(opts) got = opts end }
  gY()
  assert_true(type(got) == "table", "gY passed no opts")
  assert_eq(got.notify, false, "gY should silence the snacks notify")
  assert_eq(type(got.open), "function", "gY should override `open`")

  -- The override must put the url on the + register. Intercept setreg rather
  -- than reading it back: headless has no clipboard provider, so "+" is inert.
  local reg, val
  local real_setreg = vim.fn.setreg
  vim.fn.setreg = function(r, v) reg, val = r, v end
  local ok, err = pcall(got.open, "https://example.test/blob/main/x.lua")
  vim.fn.setreg = real_setreg
  assert_true(ok, "open override raised: " .. tostring(err))
  assert_eq(reg, "+", "url should go to the system clipboard register")
  assert_eq(val, "https://example.test/blob/main/x.lua")
end)

test("<leader>gB opens (no opts table, no open override)", function()
  local called, got = false, "unset"
  _G.Snacks = { gitbrowse = function(opts) called = true got = opts end }
  gB()
  assert_true(called, "gB did not call Snacks.gitbrowse")
  assert_eq(got, nil, "gB should call gitbrowse with no options")
end)

_H.finish({ style = "results" })
