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
-- The picker's name has since moved to the box title (utils/fzf_look.lua), but
-- cwd_prompt must stay off or the shared icon prompt is overwritten the same way.
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

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_match =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_match

-- lazydev loads fzf-lua's annotations into lua_ls from this line.
---@module "fzf-lua"

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local NBSP = "\xc2\xa0"

-- ---------------------------------------------------------------------------
-- Fakes
-- ---------------------------------------------------------------------------
-- What fortran-build.lua hands fzf.files(), as far as these tests read it: a
-- plain action function, a plain winopts table.
---@class AuditLspMakePickerFilesOpts
---@field actions table<string, fun(selected: string[])>
---@field cwd_prompt boolean
---@field winopts { title: string }

---@class AuditLspMakePickerKey  one entry of the spec's `keys`
---@field [1] string lhs
---@field [2] fun() rhs
---@field desc string

---@class AuditLspMakePickerPluginSpec  the lazy.nvim fragment fortran-build.lua returns
---@field keys AuditLspMakePickerKey[]

local captured_opts ---@type AuditLspMakePickerFilesOpts?
package.loaded["fzf-lua"] = {
  ---@param opts fzf-lua.config.Files|{ }?
  files = function(opts)
    -- Narrowed to the shape fortran-build.lua builds; the tests assert it.
    captured_opts = opts --[[@as AuditLspMakePickerFilesOpts]]
  end,
}
-- Stand-in for the real fzf-lua.path: strips everything up to the last NBSP,
-- which is what entry_to_file does to the icon prefix.
package.loaded["fzf-lua.path"] = {
  ---@param entry string
  ---@return fzf-lua.path.Entry
  entry_to_file = function(entry)
    local stripped = entry:match(".*" .. NBSP .. "(.*)$") or entry
    return { path = stripped }
  end,
}
package.loaded["andrew.vault.link_utils"] = {
  ---@param p string
  ---@return string
  lua_dirname = function(p)
    return p:match("^(.*)/[^/]*$") or p
  end,
}

---@type AuditLspMakePickerPluginSpec
local spec = dofile(vim.fn.stdpath("config") .. "/lua/andrew/plugins/fortran-build.lua")
assert_true(type(spec) == "table", "fortran-build.lua must return a table")
assert_true(type(spec.keys) == "table", "spec must carry `keys`")

---@param lhs string
---@return AuditLspMakePickerKey?
local function key_for(lhs)
  for _, k in ipairs(spec.keys) do
    if k[1] == lhs then
      return k
    end
  end
end

-- Record what run_make_in_split would hand the shell.
local last_cmd ---@type string?
local real_cmd = vim.cmd
---@param fn fun()
local function with_stubs(fn)
  ---@param c string|table
  local function fake_cmd(c)
    if type(c) == "string" and c:find("terminal", 1, true) then
      last_cmd = c
    end
  end
  vim.cmd = fake_cmd
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
    ---@cast k -nil
    captured_opts, last_cmd = nil, nil
    k[2]()
    assert_true(type(captured_opts) == "table", lhs .. " must open the fzf picker")
    ---@cast captured_opts AuditLspMakePickerFilesOpts
    local action = captured_opts.actions and captured_opts.actions["default"]
    assert_true(type(action) == "function", lhs .. " must install a default action")
    with_stubs(function()
      action({ "\u{f0673}" .. NBSP .. "./code/Makefile" })
    end)
    assert_true(type(last_cmd) == "string", lhs .. " must open a terminal")
    ---@cast last_cmd string
    -- The decoration must NOT survive into the shell command.
    assert_true(not last_cmd:find(NBSP, 1, true), lhs .. ": NBSP leaked into: " .. tostring(last_cmd))
    assert_match(last_cmd, "cd '%./code'", lhs .. ": wrong cd target")
    assert_match(last_cmd, "make %-f 'Makefile'", lhs .. ": wrong make invocation")
  end
end)

test("1b. <leader>ml re-runs the stripped path, not the decorated entry", function()
  local mb, ml = key_for("<leader>mb"), key_for("<leader>ml")
  assert_true(mb ~= nil and ml ~= nil, "<leader>mb and <leader>ml must be defined")
  ---@cast mb -nil
  ---@cast ml -nil
  captured_opts, last_cmd = nil, nil
  mb[2]()
  with_stubs(function()
    -- `.actions` would raise on a missing picker call anyway; assert names the cause.
    assert(captured_opts).actions["default"]({ "\u{f0673}" .. NBSP .. "./code/Makefile" })
  end)
  last_cmd = nil
  with_stubs(function()
    ml[2]()
  end)
  assert_true(type(last_cmd) == "string", "<leader>ml must re-run the last Makefile")
  ---@cast last_cmd string
  assert_true(not last_cmd:find(NBSP, 1, true), "<leader>ml: NBSP leaked into: " .. tostring(last_cmd))
  assert_match(last_cmd, "cd '%./code'", "<leader>ml: wrong cd target")
end)

test("2. the Makefile picker disables cwd_prompt and carries its name as the title", function()
  captured_opts = nil
  -- `[2]` would raise on a missing key anyway; assert names the cause.
  assert(key_for("<leader>mb"))[2]()
  -- Set by the fzf-lua stub above; a missing picker call fails on the next line.
  ---@cast captured_opts AuditLspMakePickerFilesOpts
  assert_eq(captured_opts.cwd_prompt, false, "cwd_prompt must be false")
  assert_eq(captured_opts.winopts.title, " Select Makefile ", "the picker must be named")
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
