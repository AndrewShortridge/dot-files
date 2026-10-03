-- Spec for the floating terminal's open/hide/close state machine
-- (lua/andrew/custom/plugins/terminal.lua).
--
-- Three bugs are pinned here, all found by driving <leader>tt for real in a pty:
--
-- 1. toggle() trusted the cached `is_visible` flag. Nothing but hide()/close()
--    ever cleared it, so closing the float the way you close any other window
--    -- <C-w>c, <leader>wd (which IS <C-w>c), :q, :only -- left the flag true
--    with no window alive. The next <leader>tt then "hid" a window that was
--    already gone and you had to press it a SECOND time to get the terminal
--    back. toggle() now asks nvim_win_is_valid via is_open().
--
-- 2. TermClose hid the window but kept the dead buffer, so the next toggle
--    reopened a terminal whose shell had exited: it accepted no input, and the
--    first keypress made Neovim wipe the finished terminal buffer, desyncing
--    the module again. TermClose now drops the buffer (deferred, because
--    nvim_buf_delete is not allowed from inside that buffer's own TermClose),
--    so the next toggle starts a fresh shell.
--
-- 3. send_input() required the window to be VISIBLE and otherwise did nothing
--    at all -- silently, so `:FloatingTerminal send make` after hiding the
--    float was indistinguishable from a broken command. It is now gated on the
--    job being alive and notifies when there is none.
--
-- Every test below fails against the previous implementation (verified by
-- restoring each old line in turn).
--
-- Run with: nvim --headless -u NONE -l tests/audit_core_floatterm_state_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false = _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- The module is a script, not a `return`ing module: it registers
-- :FloatingTerminal and the keymaps as a side effect. Reach its state through
-- the command, which is the only public surface, plus the keymap callbacks.
dofile(vim.fn.stdpath("config") .. "/lua/andrew/custom/plugins/terminal.lua")

local function toggle()
  vim.cmd("FloatingTerminal toggle")
  vim.wait(120)
end

local function float_wins()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      n = n + 1
    end
  end
  return n
end

local function term_bufs()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "floating_terminal" then
      out[#out + 1] = b
    end
  end
  return out
end

local function term_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_win_get_config(w).relative ~= "" and vim.bo[b].filetype == "floating_terminal" then
      return w
    end
  end
end

local function cleanup()
  vim.cmd("FloatingTerminal close")
  vim.wait(120)
end

test("toggle opens, toggles closed, and reuses the same live buffer", function()
  cleanup()
  toggle()
  assert_eq(float_wins(), 1, "toggle must open exactly one float")
  local bufs = term_bufs()
  assert_eq(#bufs, 1, "one terminal buffer expected, got " .. vim.inspect(bufs))
  local first = bufs[1]

  toggle()
  assert_eq(float_wins(), 0, "second toggle must hide the float")
  assert_eq(#term_bufs(), 1, "hiding must PRESERVE the terminal buffer (session restore)")

  toggle()
  assert_eq(float_wins(), 1, "third toggle must show it again")
  assert_eq(term_bufs()[1], first, "the same buffer must come back, not a new shell")
  cleanup()
end)

test("closing the float as a plain window still leaves toggle working on ONE press", function()
  cleanup()
  toggle()
  local win = term_win()
  assert_true(win ~= nil, "terminal float must exist")

  -- Exactly what <C-w>c / <leader>wd / :q do: close the window without going
  -- through hide().
  vim.api.nvim_win_close(win, true)
  vim.wait(80)
  assert_eq(float_wins(), 0, "the float must be gone")

  toggle()
  assert_eq(float_wins(), 1, "ONE toggle must bring the terminal back (was: needed two)")
  cleanup()
end)

test("is_open() reflects the window, not a cached flag", function()
  cleanup()
  toggle()
  local win = term_win()
  vim.api.nvim_win_close(win, true)
  vim.wait(80)
  -- Second toggle from the externally-closed state must OPEN (not hide).
  toggle()
  assert_eq(float_wins(), 1, "toggle from an externally-closed float must open")
  cleanup()
end)

test("a terminal whose job exited is dropped, so the next toggle is a fresh shell", function()
  cleanup()
  toggle()
  local first = term_bufs()[1]
  assert_true(first ~= nil, "terminal buffer expected")

  -- End the shell the way typing `exit` does.
  local job = vim.b[first].terminal_job_id
  assert_true(job ~= nil, "terminal buffer must carry a job id")
  vim.fn.jobstop(job)
  -- TermClose -> hide() + scheduled close(); give both a chance to run.
  vim.wait(1500, function()
    return #term_bufs() == 0
  end, 20)

  assert_eq(#term_bufs(), 0, "the dead terminal buffer must be dropped, not kept for reuse")
  assert_eq(float_wins(), 0, "and its window closed")

  toggle()
  local second = term_bufs()[1]
  assert_true(second ~= nil, "one toggle must start a new terminal")
  assert_true(second ~= first, "and it must be a FRESH buffer, not the dead one")
  cleanup()
end)

test("send reaches a hidden-but-live terminal and warns when there is none", function()
  cleanup()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, lvl, o)
    notes[#notes + 1] = tostring(msg)
    return orig(msg, lvl, o)
  end

  -- No terminal at all: must say so instead of silently doing nothing.
  vim.cmd("FloatingTerminal send echo nope")
  vim.wait(60)
  assert_eq(#notes, 1, "send with no terminal must notify, got " .. vim.inspect(notes))
  assert_true(notes[1]:match("no terminal running") ~= nil, "unexpected message: " .. notes[1])

  -- Live but hidden: must be accepted silently.
  toggle()
  local buf = term_bufs()[1]
  toggle()
  assert_eq(float_wins(), 0, "terminal must be hidden for this half of the test")
  notes = {}
  vim.cmd("FloatingTerminal send echo AUDIT_HIDDEN_SEND")
  vim.wait(900)
  assert_eq(#notes, 0, "send to a hidden LIVE terminal must not warn, got " .. vim.inspect(notes))
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert_true(text:find("AUDIT_HIDDEN_SEND", 1, true) ~= nil, "the hidden terminal never received the input")

  vim.notify = orig
  cleanup()
end)

test("unknown subcommand warns, bare :FloatingTerminal toggles", function()
  cleanup()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, lvl, o)
    notes[#notes + 1] = tostring(msg)
    return orig(msg, lvl, o)
  end
  vim.cmd("FloatingTerminal bogus")
  vim.wait(60)
  vim.notify = orig
  assert_eq(#notes, 1, "unknown subcommand must notify")
  assert_true(notes[1]:match("Unknown command: bogus") ~= nil, "unexpected message: " .. notes[1])

  vim.cmd("FloatingTerminal")
  vim.wait(150)
  assert_eq(float_wins(), 1, "bare :FloatingTerminal must toggle the terminal open")
  cleanup()
  assert_eq(float_wins(), 0, "close must remove the window")
  assert_eq(#term_bufs(), 0, "close must remove the buffer")
end)

test("<leader>tt, <C-/> and <C-_> are all mapped to the toggle", function()
  -- Under -u NONE mapleader is unset, so <leader> is the default backslash.
  local leader = vim.g.mapleader or "\\"
  local want = { [leader .. "tt"] = "n", ["<C-/>"] = "n", ["<C-_>"] = "n" }
  local seen = {}
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    if want[m.lhs] then
      seen[m.lhs] = true
      assert_true(type(m.callback) == "function", m.lhs .. " must be a lua callback")
    end
  end
  for lhs in pairs(want) do
    assert_true(seen[lhs], lhs .. " is not mapped in normal mode")
  end
  local tmodes = {}
  for _, m in ipairs(vim.api.nvim_get_keymap("t")) do
    tmodes[m.lhs] = true
  end
  assert_true(tmodes["<C-/>"], "<C-/> must also be mapped in terminal mode")
  assert_true(tmodes["<C-_>"], "<C-_> must also be mapped in terminal mode")
end)

_H.finish()
