-- Regression spec: a linter whose binary is not installed must be skipped
-- silently, not raise an error out of the BufReadPost autocmd.
--
-- THE BUG. linters_by_ft maps javascript/typescript/vue -> eslint and c/cpp ->
-- cppcheck, but neither binary is installed on this machine. nvim-lint spawns
-- unconditionally (lua/lint.lua: `handle, pid_or_err = uv.spawn(cmd, ...)`),
-- and on failure calls `vim.notify(..., ERROR)`. Raised from inside the
-- AndrewLinting autocmd, that ABORTS the autocmd chain, so merely opening a
-- .js file failed with:
--
--   Error in BufReadPost Autocommands for "*": ...filetype.lua:28:
--   BufReadPost Autocommands for "*"..FileType Autocommands for "javascript"..
--   BufReadPost Autocommands for "*": Vim(append):Error running eslint:
--   ENOENT: no such file or directory
--
-- The file still opened, but every open threw. Same for cppcheck on .c files.
--
-- THE FIX. Every try_lint call routes through a local try_lint_available which
-- passes nvim-lint's supported `filter` hook. `filter` runs AFTER the linter
-- table is resolved (lua/lint.lua: `local linter = lookup_linter(name); if
-- use_linter(linter) then`), so linter.cmd is populated -- and may itself be a
-- function, as the Fortran linter's is.
--
-- This drives the REAL plugin spec (dofile) and calls its REAL config with a
-- stubbed `lint` module, then fires the real autocmd to capture the filter that
-- was actually passed. No source introspection.
--
-- Discriminating power:
--   * Reverting any autocmd call site to a bare `try_lint()` -> no opts.filter
--     is passed, failing the "filter supplied" assertion.
--   * A filter that returns true unconditionally -> fails the missing-binary
--     case (this is the shipped bug).
--   * A filter that returns false unconditionally -> fails the present-binary
--     case, i.e. it would silently disable working linters like ruff.
--   * Dropping the function-cmd branch -> fails the function-cmd case with an
--     attempt-to-compare / executable(nil) error.
--
-- Run with: nvim --headless -u NONE -l tests/lint_missing_binary_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false = _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- Puts nvim-lint's annotations (lint.Linter, lint.try_lint.Opts) in scope:
-- the spec stubs the module instead of requiring it.
---@module "lint"

-- A binary that certainly exists, and one that certainly does not.
local PRESENT = vim.fn.executable("sh") == 1 and "sh" or "nvim"
local ABSENT = "definitely-not-a-real-linter-binary-xyzzy"

-- Stub nvim-lint. Records the (names, opts) of each try_lint call.
---@class LintMissingBinaryTryLintCall
---@field names? string|string[]
---@field opts? lint.try_lint.Opts

-- What the tests hand to the captured filter: a stand-in for lint.Linter
-- carrying only `cmd`, deliberately including malformed values (nil, "", 42).
---@class LintMissingBinaryLinterProbe
---@field cmd? string|integer|fun(): string

-- linting.lua's spec: its `config` is a function taking nothing (LazyPluginSpec
-- also allows `true`, which pcall below could not call).
---@class LintMissingBinaryPluginSpec: LazyPluginSpec
---@field config fun()

local calls = {} ---@type LintMissingBinaryTryLintCall[]
local lint_stub = {
  ---@type table<string, lint.Linter|fun(): lint.Linter>
  linters = {},
  ---@type table<string, string[]>
  linters_by_ft = {},
  ---@param names? string|string[]
  ---@param opts? lint.try_lint.Opts
  try_lint = function(names, opts)
    calls[#calls + 1] = { names = names, opts = opts }
  end,
}
package.loaded["lint"] = lint_stub

local plug = dofile(vim.fn.stdpath("config") .. "/lua/andrew/plugins/linting.lua") ---@type LintMissingBinaryPluginSpec

test("plugin spec returns a table for mfussenegger/nvim-lint", function()
  assert_true(type(plug) == "table", "spec must return a table")
  assert_eq(plug[1], "mfussenegger/nvim-lint", "spec must point at mfussenegger/nvim-lint")
end)

test("config runs against the stubbed lint module", function()
  local ok, err = pcall(plug.config, nil, plug.opts or {})
  assert_true(ok, "config must run: " .. tostring(err))
end)

-- Fire the real autocmd the bug reproduced through. That was BufReadPost at
-- the time; opens are linted from FileType now (see the trigger test below).
-- Cast: the tests below call it with LintMissingBinaryLinterProbe tables
-- (partial, sometimes malformed linters) on purpose; the assertion after the
-- assignment checks that it really is a function.
local filter ---@type fun(linter: LintMissingBinaryLinterProbe): boolean
test("the on-open lint autocmd supplies a filter", function()
  calls = {}
  vim.api.nvim_exec_autocmds("FileType", { group = "AndrewLinting" })
  assert_true(#calls > 0, "FileType must reach try_lint")

  local opts = calls[#calls].opts
  assert_true(type(opts) == "table", "try_lint must be called with an opts table")
  ---@cast opts -nil
  filter = opts.filter --[[@as fun(linter: LintMissingBinaryLinterProbe): boolean]]
  -- A bare try_lint() -- the shipped bug -- passes no filter at all.
  assert_true(type(filter) == "function", "try_lint must receive an opts.filter function")
end)

test("filter rejects a linter whose binary is missing", function()
  -- The actual reported failure: eslint / cppcheck configured but not installed.
  assert_false(filter({ cmd = ABSENT }), "a missing binary must be filtered out")
end)

test("filter keeps a linter whose binary is present", function()
  -- Guard against over-correcting into "never lint anything".
  assert_true(filter({ cmd = PRESENT }), "an installed binary must still run")
end)

test("filter resolves a function cmd", function()
  -- The Fortran linter sets cmd from fortran_config.compiler_path; nvim-lint
  -- itself evals cmd, so a function is legal here and must not crash the filter.
  ---@return string
  assert_true(filter({ cmd = function() return PRESENT end }), "function cmd resolving to a real binary must run")
  ---@return string
  assert_false(filter({ cmd = function() return ABSENT end }), "function cmd resolving to a missing binary must be filtered")
  assert_false(filter({ cmd = function() error("boom") end }), "a throwing cmd function must be filtered, not propagated")
end)

test("filter rejects malformed cmd values", function()
  assert_false(filter({ cmd = nil }), "nil cmd must be filtered")
  assert_false(filter({ cmd = "" }), "empty cmd must be filtered")
  assert_false(filter({ cmd = 42 }), "non-string cmd must be filtered")
end)

test("every configured filetype linter is guarded, not just javascript", function()
  -- cppcheck (c/cpp) hit the identical crash; the guard must be global rather
  -- than an eslint special-case.
  local by_ft = lint_stub.linters_by_ft
  for _, ft in ipairs({ "javascript", "typescript", "vue", "c", "cpp", "python" }) do
    assert_true(type(by_ft[ft]) == "table", "linters_by_ft must define " .. ft)
  end
  -- The autocmd is filetype-agnostic, so proving the single filter handles an
  -- arbitrary missing binary covers all of them.
  assert_false(filter({ cmd = ABSENT }), "the shared filter must reject any missing binary")
end)

-- Each trigger must lint exactly once. Two regressions this pins, both of which
-- only ever showed up as wasted compiler runs:
--   * Fortran on InsertLeave: its linter compiles the file ON DISK, so the run
--     re-checks the last save while blocking every <Esc> on the spawn.
--   * A second autocmd (or BufReadPost beside FileType) matching the same
--     buffer: every open or save then lints twice.
test("each trigger lints once, and Fortran skips InsertLeave", function()
  ---@param event string
  ---@param filetype string
  ---@return integer
  local function lint_runs(event, filetype)
    vim.bo.filetype = filetype
    calls = {}
    vim.api.nvim_exec_autocmds(event, {})
    return #calls
  end
  assert_eq(lint_runs("FileType", "fortran"), 1, "opening a Fortran buffer lints once")
  assert_eq(lint_runs("BufReadPost", "fortran"), 0, "BufReadPost must not lint again on top of FileType")
  assert_eq(lint_runs("BufWritePost", "fortran"), 1, "saving a Fortran buffer lints once")
  for _, filetype in ipairs({ "fortran", "fortran_free", "fortran_fixed" }) do
    assert_eq(lint_runs("InsertLeave", filetype), 0, filetype .. " must not lint on InsertLeave")
  end
  assert_eq(lint_runs("InsertLeave", "python"), 1, "other filetypes still lint on InsertLeave")
end)

_H.finish({ style = "results", exit = "os" })
