-- Spec for :FloatingTerminal's subcommand completion
-- (lua/andrew/custom/plugins/terminal.lua).
--
-- Background: the command declares `complete = function(_, line) ... end`, i.e.
-- it took Neovim's SECOND completion argument (CmdLine -- the entire
-- ":FloatingTerminal o" line) and searched for that string INSIDE each
-- subcommand name:
--
--     if cmd:find(line, 1, true) then      -- ("open"):find("FloatingTerminal o")
--
-- which can never match, so the function returned {} for every input and
-- `:FloatingTerminal <Tab>` offered nothing -- not even the bare list. The fix
-- takes the FIRST argument (ArgLead, the word being completed) and anchors the
-- match at position 1, which is what a subcommand completer must do.
--
-- Discriminating power: every test below fails against the old
-- `function(_, line)` + unanchored `find` implementation (verified by
-- reinstating it). Test 3 additionally fails if the match stops being anchored
-- (then "ose" would complete to "close").
--
-- Run with: nvim --headless -u NONE -l tests/audit_core_floatterm_complete_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- Load the module for real; it registers :FloatingTerminal and two keymaps.
dofile(vim.fn.stdpath("config") .. "/lua/andrew/custom/plugins/terminal.lua")

local ALL = { "open", "close", "hide", "toggle", "restart", "send" }


local function complete(arg_lead)
  -- Go through the real completion machinery, exactly as <Tab> would.
  return vim.fn.getcompletion("FloatingTerminal " .. arg_lead, "cmdline")
end

test("bare <Tab> lists every subcommand", function()
  local got = complete("")
  assert_eq(#got, #ALL, "expected all " .. #ALL .. " subcommands, got " .. vim.inspect(got))
  for _, want in ipairs(ALL) do
    assert_true(vim.tbl_contains(got, want), want .. " missing from " .. vim.inspect(got))
  end
end)

test("a prefix narrows to the matching subcommands", function()
  assert_eq(vim.inspect(complete("o")), vim.inspect({ "open" }), "'o' must complete to open")
  assert_eq(vim.inspect(complete("cl")), vim.inspect({ "close" }), "'cl' must complete to close")
  assert_eq(vim.inspect(complete("re")), vim.inspect({ "restart" }), "'re' must complete to restart")
  local h = complete("h")
  assert_eq(#h, 1, "'h' must match only hide, got " .. vim.inspect(h))
  assert_eq(h[1], "hide")
end)

test("the match is anchored: an inner substring completes nothing", function()
  assert_eq(#complete("ose"), 0, "'ose' must NOT complete to close")
  assert_eq(#complete("art"), 0, "'art' must NOT complete to restart")
end)

test("an unknown prefix completes nothing", function()
  assert_eq(#complete("zzz"), 0, "'zzz' must complete to nothing")
end)

test("the completion function reads ArgLead, not CmdLine", function()
  local cmd = vim.api.nvim_get_commands({})["FloatingTerminal"]
  assert_true(cmd ~= nil, ":FloatingTerminal must exist")
  -- The whole-cmdline bug is observable through getcompletion above; this pins
  -- that nargs stays "*" so `send <words...>` keeps working.
  assert_eq(cmd.nargs, "*", "nargs must stay '*' so :FloatingTerminal send <cmd> works")
end)

_H.finish()
