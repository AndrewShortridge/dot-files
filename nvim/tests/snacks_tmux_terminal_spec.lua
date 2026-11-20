-- Spec for andrew.utils.snacks_tmux_terminal.
--
-- WHAT THIS IS GUARDING
--
-- Inside tmux, snacks.image asks the OUTER terminal who it is (XTVERSION
-- through tmux passthrough). tmux reads the answer as key input: `ESC \`, the
-- end of it, is M-\ -- bound to `split-window -h` in ~/.config/tmux/tmux.conf
-- -- and `>|kitty(0.49.2)` is typed into Neovim. The module makes snacks take
-- the name from tmux instead, so the query is never sent.
--
-- 1. No terminal query leaves Neovim inside tmux, and the terminal is still
--    identified (inline images depend on "kitty" being found in the name).
-- 2. Graphics commands are still wrapped in tmux passthrough afterwards:
--    upstream sets that up in the code path that is now skipped.
-- 3. Outside tmux nothing is touched.
-- 4. Upstream still sends the query. When this one fails, snacks has fixed it
--    and the module can be deleted.
--
-- Runs against the installed snacks.nvim, with tmux and the terminal stubbed.
--
-- Run with: nvim --headless -u NONE -l tests/snacks_tmux_terminal_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")

local XTVERSION_QUERY = "\27[>q"

--- Everything the code under test sent to the terminal.
local sent_to_terminal = {} ---@type string[]
---@param data string
vim.api.nvim_ui_send = function(data)
  sent_to_terminal[#sent_to_terminal + 1] = data
end

--- snacks' own tmux calls (`set -p allow-passthrough all`, `show -g extended-keys`).
local snacks_tmux_calls = {} ---@type string[]
--- Stand-in for vim.fn.system; snacks always passes the command as a list.
---@param command string|string[]
---@return string
local function fake_system(command)
  snacks_tmux_calls[#snacks_tmux_calls + 1] = table.concat(command --[[@as string[] ]], " ")
  return "extended-keys off\n"
end
vim.fn.system = fake_system

--- What `tmux display-message -p` prints; nil makes the call fail.
local tmux_answer ---@type string?
-- Returns vim.system's real type, not a fake class: lua_ls merges what a stub
-- assigned to `vim.system` returns into `vim.system` for the WHOLE workspace,
-- so a fake return type leaks into the config's own calls.
---@return vim.SystemObj
vim.system = function()
  -- Only `:wait()`, the one method the module under test uses.
  local fake_system_obj = {
    ---@return { code: integer, stdout: string }
    wait = function()
      return tmux_answer and { code = 0, stdout = tmux_answer .. "\n" } or { code = 1, stdout = "" }
    end,
  }
  return fake_system_obj --[[@as vim.SystemObj]]
end

---@class SnacksTmuxSpecTerminalOptions
---@field is_inside_tmux boolean
---@field is_adapted? boolean  run andrew.utils.snacks_tmux_terminal.setup()
---@field tmux_answer? string

--- A fresh snacks terminal module, as a new session has it.
---@param options SnacksTmuxSpecTerminalOptions
---@return snacks.image.terminal
local function fresh_terminal(options)
  vim.env.TMUX = options.is_inside_tmux and "/tmp/tmux-1000/default,1,0" or nil
  tmux_answer = options.tmux_answer
  sent_to_terminal, snacks_tmux_calls = {}, {}
  ---@type table?
  package.loaded["snacks.image.terminal"] = nil
  ---@type table?
  package.loaded["andrew.utils.snacks_tmux_terminal"] = nil
  local terminal = require("snacks.image.terminal")
  if options.is_adapted then
    require("andrew.utils.snacks_tmux_terminal").setup()
  end
  return terminal
end

---@return boolean
local function was_query_sent()
  for _, data in ipairs(sent_to_terminal) do
    if data:find(XTVERSION_QUERY, 1, true) then
      return true
    end
  end
  return false
end

test(
  "upstream still sends the query through tmux passthrough (delete the module when this fails)",
  function()
    local terminal = fresh_terminal({ is_inside_tmux = true })
    terminal.detect(function() end)
    assert_true(was_query_sent(), "snacks no longer queries the terminal inside tmux")
    assert_true(
      sent_to_terminal[1]:find("^\27Ptmux;") ~= nil,
      "the query is no longer wrapped in passthrough"
    )
  end
)

test("inside tmux no query is sent and the terminal comes from tmux", function()
  local terminal =
    fresh_terminal({ is_inside_tmux = true, is_adapted = true, tmux_answer = "kitty(0.49.2)" })
  local detected ---@type snacks.image.Terminal?
  ---@param result snacks.image.Terminal
  terminal.detect(function(result)
    detected = result
  end)
  assert_eq(#sent_to_terminal, 0, "bytes sent to the terminal:")
  assert_true(detected ~= nil, "the callback did not run")
  ---@cast detected -nil
  assert_eq(detected.terminal, "kitty(0.49.2)", "terminal:")
  assert_true(terminal.env().placeholders, "kitty was not recognised from the name")
end)

test("the blocking detect() returns at once", function()
  local terminal =
    fresh_terminal({ is_inside_tmux = true, is_adapted = true, tmux_answer = "kitty(0.49.2)" })
  local started = vim.uv.hrtime()
  terminal.detect()
  assert_true((vim.uv.hrtime() - started) / 1e6 < 200, "detect() waited for an answer")
  assert_eq(#sent_to_terminal, 0, "bytes sent to the terminal:")
end)

test("a terminal that never answered tmux is named after its $TERM", function()
  local terminal =
    fresh_terminal({ is_inside_tmux = true, is_adapted = true, tmux_answer = "xterm-ghostty" })
  terminal.detect(function() end)
  assert_eq(terminal._terminal.terminal, "ghostty", "terminal:")
end)

test("a failing tmux call leaves the terminal unknown, still without a query", function()
  local terminal = fresh_terminal({ is_inside_tmux = true, is_adapted = true })
  terminal.detect(function() end)
  assert_eq(terminal._terminal.terminal, "unknown", "terminal:")
  assert_eq(#sent_to_terminal, 0, "bytes sent to the terminal:")
end)

test("graphics commands are wrapped in passthrough and the pane allows it", function()
  local terminal =
    fresh_terminal({ is_inside_tmux = true, is_adapted = true, tmux_answer = "kitty(0.49.2)" })
  terminal.detect(function() end)
  terminal.write("\27_Ga=d\27\\")
  assert_eq(sent_to_terminal[1], "\27Ptmux;\27\27_Ga=d\27\27\\\27\\", "written:")
  assert_true(
    vim.tbl_contains(snacks_tmux_calls, "tmux set -p allow-passthrough all"),
    "allow-passthrough was not switched on for the pane"
  )
end)

test("outside tmux snacks' detection is left alone", function()
  local terminal = fresh_terminal({ is_inside_tmux = false })
  local upstream_detect = terminal._detect
  require("andrew.utils.snacks_tmux_terminal").setup()
  assert_eq(terminal._detect, upstream_detect, "_detect:")
end)

_H.finish()
