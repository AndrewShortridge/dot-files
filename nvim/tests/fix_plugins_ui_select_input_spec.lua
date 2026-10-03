-- Spec for the dressing.nvim -> snacks.nvim handover of `vim.ui.input` and
-- `vim.ui.select` (lua/andrew/plugins/snacks.lua).
--
-- THE BUG. dressing.nvim (archived upstream) owned both handlers. It calls the
-- REMOVED `vim.validate{ <table> }` form on every invocation -- a deprecation
-- on 0.12 and a hard error at nvim 1.0 -- and because its spec loaded on
-- `VeryLazy`, i.e. AFTER snacks' own `lazy = false, priority = 1000` setup, it
-- silently took `vim.ui.input` back from the already-enabled snacks `input`
-- module. `:checkhealth snacks` reported
--   ERROR `vim.ui.input` is not set to `Snacks.input`
-- and snacks' `input` config was dead weight.
--
-- THE FIX. plugins/dressing.lua is deleted (and its require() removed from
-- plugins/init.lua, its pin removed from lazy-lock.json); snacks.lua now
-- declares `picker = { enabled = true, ui_select = true }` next to
-- `input = { enabled = true }`, so snacks owns both. Two behaviour-preserving
-- overrides keep dressing's feel:
--   * `input.win.keys.i_esc` -> `cancel` (snacks' own style stops at
--     `stopinsert`, needing a SECOND <Esc>; every caller in this config treats
--     one <Esc> as "cancel, callback gets nil").
--   * `picker.sources.select.win.input.keys["<Esc>"]` -> cancel in BOTH modes
--     (dressing delegated select to fzf-lua, where one <Esc> aborts).
-- Plus a WinClosed guard that re-asserts snacks ownership after fzf-lua's
-- `lsp_code_actions` leaves its temporary `vim.ui.select` installed (it only
-- deregisters when an action is APPLIED, so an aborted <leader>ca used to make
-- the next :VaultSwitch / callout picker render in fzf).
--
-- Discriminating power:
--   * Re-adding the dressing spec, or dropping `picker.ui_select` -> the
--     ownership tests fail.
--   * Dropping the `i_esc` / `<Esc>` overrides -> the "one <Esc> cancels"
--     tests fail (the callback is never called with nil).
--   * Dropping the WinClosed guard -> the fzf-lua handover test fails.
--
-- Drives the REAL spec against the REAL snacks.nvim on the runtimepath.
--
-- Run with: nvim --headless -u NONE -l tests/fix_plugins_ui_select_input_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil
local assert_false, assert_match = _H.assert_false, _H.assert_match

local cfg = vim.fn.stdpath("config")
local lazy_root = vim.fn.stdpath("data") .. "/lazy"

if vim.fn.isdirectory(lazy_root .. "/snacks.nvim") == 0 then
  print("  SKIP: snacks.nvim not installed")
  _H.finish({ style = "results" })
  return
end

vim.opt.runtimepath:prepend(lazy_root .. "/snacks.nvim")
vim.opt.runtimepath:prepend(cfg)

-- ---------------------------------------------------------------------------
-- 1. dressing.nvim is really gone
-- ---------------------------------------------------------------------------

test("the dressing.nvim spec file no longer exists", function()
  assert_eq(vim.fn.filereadable(cfg .. "/lua/andrew/plugins/dressing.lua"), 0, "plugins/dressing.lua")
end)

test("plugins/init.lua no longer requires the dressing spec", function()
  local src = table.concat(vim.fn.readfile(cfg .. "/lua/andrew/plugins/init.lua"), "\n")
  assert_false(src:find("dressing", 1, true), "plugins/init.lua still mentions dressing")
end)

test("lazy-lock.json no longer pins dressing.nvim", function()
  local lock = table.concat(vim.fn.readfile(cfg .. "/lazy-lock.json"), "\n")
  assert_false(lock:find("dressing", 1, true), "lazy-lock.json still pins dressing.nvim")
  -- the file must still be valid JSON with the rest of the pins intact
  local ok, decoded = pcall(vim.json.decode, lock)
  assert_true(ok, "lazy-lock.json is not valid JSON")
  assert_true(decoded["snacks.nvim"] ~= nil, "snacks.nvim pin went missing")
end)

-- ---------------------------------------------------------------------------
-- 2. The snacks spec declares both backends
-- ---------------------------------------------------------------------------

local spec = dofile(cfg .. "/lua/andrew/plugins/snacks.lua")

test("snacks opts enable `input` and `picker.ui_select`", function()
  assert_eq(spec.opts.input.enabled, true, "input.enabled")
  assert_eq(spec.opts.picker.enabled, true, "picker.enabled")
  assert_eq(spec.opts.picker.ui_select, true, "picker.ui_select")
end)

test("snacks is eager so it cannot be out-raced by a VeryLazy plugin", function()
  assert_eq(spec.lazy, false, "spec.lazy")
  assert_eq(spec.priority, 1000, "spec.priority")
end)

if spec.init then
  spec.init()
end
spec.config(spec, spec.opts)

-- snacks defers `input` / `picker` setup to UIEnter, which `setup()` runs
-- inline when vim has already entered (the case here and in a real session).
-- VeryLazy is fired too: that is the event dressing used to load on, and the
-- point of the fix is that nothing steals ownership at that moment.
vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy" })
vim.wait(50)

local Input = require("snacks.input")
local Picker = require("snacks.picker")

-- ---------------------------------------------------------------------------
-- 3. Ownership
-- ---------------------------------------------------------------------------

test("vim.ui.input is Snacks.input after VeryLazy", function()
  assert_eq(vim.ui.input, Input.input, "vim.ui.input is not Snacks.input")
end)

test("vim.ui.select is the snacks picker after VeryLazy", function()
  assert_eq(vim.ui.select, Picker.select, "vim.ui.select is not Snacks.picker.select")
end)

test("no dressing module ever loads", function()
  assert_nil(package.loaded["dressing"], "dressing loaded")
  assert_nil(package.loaded["dressing.input"], "dressing.input loaded")
  assert_nil(package.loaded["dressing.select"], "dressing.select loaded")
end)

-- ---------------------------------------------------------------------------
-- 4. vim.ui.input round-trip
-- ---------------------------------------------------------------------------

test("vim.ui.input prefills `default`, opens a 1-line float and confirms", function()
  local got, called = nil, false
  local win = vim.ui.input({ prompt = "Pick a name: ", default = "alpha" }, function(v)
    got, called = v, true
  end)
  assert_eq(vim.bo[win.buf].filetype, "snacks_input", "input buffer filetype")
  assert_eq(vim.api.nvim_buf_get_lines(win.buf, 0, -1, false)[1], "alpha", "default not prefilled")
  assert_eq(vim.api.nvim_win_get_height(win.win), 1, "input float height")

  -- Type at the end of the prefilled text, exactly as <CR> would confirm it.
  vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, { "alpha-2" })
  win:execute("confirm")
  vim.wait(500, function() return called end)
  assert_true(called, "on_confirm was never called")
  assert_eq(got, "alpha-2", "confirmed value")
end)

test("insert-mode <Esc> cancels vim.ui.input and the callback gets nil", function()
  local got, called = "sentinel", false
  local win = vim.ui.input({ prompt = "Cancel me: " }, function(v)
    got, called = v, true
  end)

  -- The mapping itself must resolve to `cancel`, not snacks' default
  -- `stopinsert` (which would need a second <Esc>).
  local esc
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(win.buf, "i")) do
    if m.lhs == "<Esc>" then esc = m end
  end
  assert_true(esc ~= nil, "no insert-mode <Esc> mapping in the input float")
  assert_match(esc.desc or "", "cancel", "insert-mode <Esc> should cancel")

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
  vim.wait(500, function() return called end)
  assert_true(called, "on_confirm was never called on cancel")
  assert_nil(got, "cancelled input must yield nil")
end)

-- ---------------------------------------------------------------------------
-- 5. vim.ui.select round-trip
-- ---------------------------------------------------------------------------

local items = { "one", "two", "three" }

test("vim.ui.select renders format_item and confirms item + index", function()
  local got, idx, called = nil, nil, false
  local picker = vim.ui.select(items, {
    prompt = "Pick one:",
    format_item = function(it) return "<<" .. it .. ">>" end,
  }, function(item, i)
    got, idx, called = item, i, true
  end)

  assert_eq(picker.title, "Pick one", "picker title (prompt, stripped)")
  assert_true(vim.wait(3000, function() return picker:count() >= #items end), "items never loaded")
  assert_eq(vim.bo[picker.input.win.buf].filetype, "snacks_picker_input", "picker input filetype")

  local texts = {}
  for _, it in ipairs(picker:items()) do
    texts[#texts + 1] = it.text
  end
  assert_eq(texts[1], "1 <<one>>", "format_item not applied")
  assert_eq(texts[3], "3 <<three>>", "format_item not applied to the last item")

  picker:action("confirm")
  vim.wait(1000, function() return called end)
  assert_true(called, "on_choice was never called")
  assert_eq(got, "one", "chosen item")
  assert_eq(idx, 1, "chosen index")
end)

test("one <Esc> cancels vim.ui.select and the callback gets nil", function()
  local got, called = "sentinel", false
  local picker = vim.ui.select(items, { prompt = "Cancel me:" }, function(item)
    got, called = item, true
  end)
  assert_true(vim.wait(3000, function() return picker:count() >= #items end), "items never loaded")

  -- Insert mode is where the picker starts, so <Esc> must cancel there too.
  local esc
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(picker.input.win.buf, "i")) do
    if m.lhs == "<Esc>" then esc = m end
  end
  assert_true(esc ~= nil, "no insert-mode <Esc> mapping in the select picker")
  assert_match(esc.desc or "", "cancel", "insert-mode <Esc> should cancel")

  picker:action("cancel")
  vim.wait(1000, function() return called end)
  assert_true(called, "on_choice was never called on cancel")
  assert_nil(got, "cancelled select must yield nil")
end)

-- ---------------------------------------------------------------------------
-- 6. fzf-lua may not keep vim.ui.select after its window closes
-- ---------------------------------------------------------------------------
-- <leader>ca routes code actions through fzf-lua, which registers its OWN
-- vim.ui.select for the call and restores the previous handler only from
-- `post_action_cb` -- i.e. when an action is applied. Aborting the picker used
-- to leave fzf-lua registered for the rest of the session.

local fzf_ok, fzf_ui_select = false, nil
if vim.fn.isdirectory(lazy_root .. "/fzf-lua") == 1 then
  vim.opt.runtimepath:append(lazy_root .. "/fzf-lua")
  fzf_ok, fzf_ui_select = pcall(require, "fzf-lua.providers.ui_select")
end

--- Open a throwaway float whose buffer looks like an fzf-lua window, then close
--- it so the real WinClosed autocmd fires.
local function close_a_fake_fzf_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "fzf"
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor", row = 1, col = 1, width = 10, height = 3, style = "minimal",
  })
  vim.api.nvim_win_close(win, true)
end

if not fzf_ok then
  print("  SKIP: fzf-lua not installed (ui_select handover guard)")
else
  test("snacks reclaims vim.ui.select when an fzf-lua window closes", function()
    fzf_ui_select.register({}, true)
    assert_true(fzf_ui_select.is_registered(), "fzf-lua did not take vim.ui.select")

    close_a_fake_fzf_win()
    assert_true(
      vim.wait(1000, function() return vim.ui.select == Picker.select end),
      "vim.ui.select was not handed back to snacks"
    )
    assert_false(fzf_ui_select.is_registered(), "fzf-lua is still registered")
  end)

  test("vim.g.fzf_lua_owns_ui_select opts out of the handover", function()
    vim.g.fzf_lua_owns_ui_select = true
    fzf_ui_select.register({}, true)
    close_a_fake_fzf_win()
    vim.wait(300)
    assert_true(fzf_ui_select.is_registered(), "the opt-out did not keep fzf-lua registered")
    fzf_ui_select.deregister({}, true, true)
    vim.g.fzf_lua_owns_ui_select = nil
    assert_eq(vim.ui.select, Picker.select, "snacks should own vim.ui.select again")
  end)

  test("a non-fzf window closing does not touch vim.ui.select", function()
    local sentinel = function() end
    vim.ui.select = sentinel
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "markdown"
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor", row = 1, col = 1, width = 10, height = 3, style = "minimal",
    })
    vim.api.nvim_win_close(win, true)
    vim.wait(200)
    assert_eq(vim.ui.select, sentinel, "an unrelated WinClosed must not rewrite vim.ui.select")
    vim.ui.select = Picker.select
  end)
end

_H.finish({ style = "results" })
