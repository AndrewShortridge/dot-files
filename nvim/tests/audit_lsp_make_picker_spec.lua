-- Spec for the six <leader>m Make keys in lua/andrew/plugins/fortran-build.lua
-- and the fortls enable guard in lua/andrew/plugins/lsp/lspconfig.lua.
--
-- Bug 1 (fortran-build.lua): the fzf-lua `files` picker renders every entry as
--   <devicon><NBSP><path>
-- and the action handed `selected[1]` straight to the shell, producing
--   cd ' <icon>./code' && make -f 'Makefile'
-- -> "/bin/bash: line 1: cd: ./code: No such file or directory".
-- All six keys (<leader>mb/md/mc/mr/ma/ml) therefore ran nothing at all, the
-- second time these keys were silently dead. Observed in a real pty on
-- nvim 0.12.5, 2026-09-13. The fix routes the selection through fzf-lua's own
-- path.entry_to_file, which strips the decoration.
--
-- Bug 2 (fortran-build.lua): `prompt = "Select Makefile> "` never reached the
-- screen, because the `files` provider defaults to cwd_prompt = true and
-- OVERWRITES opts.prompt with the shortened cwd (fzf-lua core.lua:818-825).
--
-- Bug 3 (lspconfig.lua): fortls was passed to vim.lsp.enable() unconditionally
-- even though it has an explicit cmd, so a machine without fortls spawned a
-- client that died on the spot -- the exact invisible failure the enable_if
-- guard above it was written to remove.
--
-- Discriminating power (each verified by reverting the fix):
--   * Test 1 fails if the action stops stripping the icon prefix.
--   * Test 2 fails if cwd_prompt is not disabled.
--   * Test 3 fails if fortls goes back to an unguarded vim.lsp.enable().
--
-- Run with: nvim --headless -u NONE -l tests/audit_lsp_make_picker_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_match =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_match

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local NBSP = "\xc2\xa0"

-- ---------------------------------------------------------------------------
-- Fakes
-- ---------------------------------------------------------------------------
local captured_opts
package.loaded["fzf-lua"] = {
  files = function(opts)
    captured_opts = opts
  end,
}
-- Stand-in for the real fzf-lua.path: strips everything up to the last NBSP,
-- which is what entry_to_file does to the icon prefix.
package.loaded["fzf-lua.path"] = {
  entry_to_file = function(entry)
    local stripped = entry:match(".*" .. NBSP .. "(.*)$") or entry
    return { path = stripped }
  end,
}
package.loaded["andrew.vault.link_utils"] = {
  lua_dirname = function(p)
    return p:match("^(.*)/[^/]*$") or p
  end,
}

local spec = dofile(vim.fn.stdpath("config") .. "/lua/andrew/plugins/fortran-build.lua")
assert_true(type(spec) == "table", "fortran-build.lua must return a table")
assert_true(type(spec.keys) == "table", "spec must carry `keys`")

local function key_for(lhs)
  for _, k in ipairs(spec.keys) do
    if k[1] == lhs then
      return k
    end
  end
end

-- Record what run_make_in_split would hand the shell.
local last_cmd
local real_cmd = vim.cmd
local function with_stubs(fn)
  vim.cmd = function(c)
    if type(c) == "string" and c:find("terminal", 1, true) then
      last_cmd = c
    end
  end
  local ok, err = pcall(fn)
  vim.cmd = real_cmd
  if not ok then
    error(err)
  end
end

-- ---------------------------------------------------------------------------
test("1. picker selection is stripped of the fzf-lua icon prefix", function()
  for _, lhs in ipairs({ "<leader>mb", "<leader>md", "<leader>mc", "<leader>mr", "<leader>ma" }) do
    local k = key_for(lhs)
    assert_true(k ~= nil, lhs .. " must be defined")
    captured_opts, last_cmd = nil, nil
    k[2]()
    assert_true(type(captured_opts) == "table", lhs .. " must open the fzf picker")
    local action = captured_opts.actions and captured_opts.actions["default"]
    assert_true(type(action) == "function", lhs .. " must install a default action")
    with_stubs(function()
      action({ "\u{f0673}" .. NBSP .. "./code/Makefile" })
    end)
    assert_true(type(last_cmd) == "string", lhs .. " must open a terminal")
    -- The decoration must NOT survive into the shell command.
    assert_true(not last_cmd:find(NBSP, 1, true), lhs .. ": NBSP leaked into: " .. tostring(last_cmd))
    assert_match(last_cmd, "cd '%./code'", lhs .. ": wrong cd target")
    assert_match(last_cmd, "make %-f 'Makefile'", lhs .. ": wrong make invocation")
  end
end)

test("1b. <leader>ml re-runs the stripped path, not the decorated entry", function()
  local mb, ml = key_for("<leader>mb"), key_for("<leader>ml")
  assert_true(mb ~= nil and ml ~= nil, "<leader>mb and <leader>ml must be defined")
  captured_opts, last_cmd = nil, nil
  mb[2]()
  with_stubs(function()
    captured_opts.actions["default"]({ "\u{f0673}" .. NBSP .. "./code/Makefile" })
  end)
  last_cmd = nil
  with_stubs(function()
    ml[2]()
  end)
  assert_true(type(last_cmd) == "string", "<leader>ml must re-run the last Makefile")
  assert_true(not last_cmd:find(NBSP, 1, true), "<leader>ml: NBSP leaked into: " .. tostring(last_cmd))
  assert_match(last_cmd, "cd '%./code'", "<leader>ml: wrong cd target")
end)

test("2. the Makefile picker disables cwd_prompt so its prompt survives", function()
  captured_opts = nil
  key_for("<leader>mb")[2]()
  assert_eq(captured_opts.cwd_prompt, false, "cwd_prompt must be false")
  assert_eq(captured_opts.prompt, "Select Makefile> ", "prompt must be kept")
end)

test("3. fortls is enabled only when its binary resolved", function()
  local src = table.concat(
    vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/andrew/plugins/lsp/lspconfig.lua"),
    "\n"
  )
  assert_true(
    src:find('enable_if("fortls"', 1, true) ~= nil,
    "fortls must go through the enable_if guard"
  )
  assert_true(
    src:find('vim.lsp.enable("fortls")', 1, true) == nil,
    "fortls must NOT be enabled unconditionally"
  )
end)

_H.finish({ style = "results", exit = "os" })
