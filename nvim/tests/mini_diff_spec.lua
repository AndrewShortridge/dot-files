-- Spec for the mini.diff / gitsigns COEXISTENCE and the unattached-buffer guard.
--
-- LazyVim's `editor.mini-diff` extra installs mini.diff by disabling gitsigns
-- outright (`{ "lewis6991/gitsigns.nvim", enabled = false }`). This config runs
-- both, so the two have to be kept off each other's keys:
--
--   gitsigns   -- sign column, <leader>gh staging, blame, and ALL hunk
--                 navigation (]g/[g, ]h/[h, ]H/[H).
--   mini.diff  -- the reference-text overlay, gh/gH operators, gh textobject.
--
-- TWO BUGS THIS EXISTS TO CATCH.
--
-- 1. THE COLLISION. mini.diff's upstream defaults are goto_first/prev/next/last
--    = [H / [h / ]h / ]H -- all four already belong to gitsigns here, and in
--    markdown ]h/[h belong twice over to headings (ftplugin/markdown.lua) and
--    ==highlights== (vault/highlights.lua). Upstream binds them GLOBALLY while
--    gitsigns binds buffer-locally, so a regression would not error; the
--    buffer-local map would just quietly win in attached buffers and
--    mini.diff's would take over everywhere else. Silent either way.
--
-- 2. THE HARD ERROR (reported by the user). mini.diff auto-attaches only to
--    normal listed text buffers (`buftype == ''`), so a picker preview, a diff
--    scratch buffer, a terminal or a help window never has a diff. Upstream's
--    `toggle_overlay()`, `textobject()` and `do_hunks()` each call `H.error()`
--    in that case, surfacing as:
--
--      E5108: Lua: (mini.diff) Buffer 16 is not enabled.
--
--    reachable just by pressing the key after closing a `<leader>gd` diff. So
--    EVERY upstream mapping is disabled and re-bound here behind a guard.
--    Because the operators are `expr = true`, their guard must return `''` --
--    returning nil from an expr mapping is itself an error.
--
-- Also guarded: view.style must stay "number". Both plugins mark the SAME
-- hunks, so with style="sign" they would draw duplicate marks in one sign
-- column. Upstream computes this default as `vim.go.number and 'number' or
-- 'sign'`, evaluated once when the module table is built, so it must be pinned.
--
-- Drives the REAL plugin spec (dofile) and calls its REAL config with a stubbed
-- mini.diff module, capturing the mappings and commands actually created, then
-- invokes those mappings against an unattached buffer. No source introspection.
--
-- Discriminating power:
--   * Restoring any upstream goto_* default -> fails the disabled-mappings
--     assertion AND the cross-plugin collision check against gitsigns.
--   * Restoring upstream apply/reset/textobject (i.e. dropping the guard) ->
--     fails the disabled-mappings assertion.
--   * Calling toggle_overlay/textobject/operator without the guard -> fails the
--     no-error assertions with the reported E5108.
--   * Returning nil instead of '' from the expr guard -> fails the expr-return
--     assertion (a real "expected String" error at runtime).
--   * Flipping view.style to "sign" -> fails the sign-column assertion.
--   * Adding a gitsigns `enabled = false` fragment -> fails coexistence.
--   * Dropping any user command or the <leader>go key -> fails those assertions.
--
-- Run with: nvim --headless -u NONE -l tests/mini_diff_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local cfg = vim.fn.stdpath("config")
local md = dofile(cfg .. "/lua/andrew/plugins/mini-diff.lua")

test("spec points at mini.diff and pins no version", function()
  assert_eq(md[1], "echasnovski/mini.diff", "spec must point at echasnovski/mini.diff")
  -- mini.* modules tag per-module releases; `false` tracks main, as upstream advises.
  assert_eq(md.version, false, "version must be false to follow main")
  assert_true(type(md.opts) == "table", "opts table must exist")
end)

test("mini.diff does not disable gitsigns", function()
  -- THE COEXISTENCE GUARD. LazyVim's extra ships exactly this fragment:
  --   { "lewis6991/gitsigns.nvim", enabled = false }
  -- Adopting it would silently delete the whole <leader>gh group, ]g/[g/]H/[H
  -- and the ih textobject.
  local function scan(t, depth)
    if type(t) ~= "table" or depth > 4 then
      return
    end
    if t[1] == "lewis6991/gitsigns.nvim" then
      error("mini-diff.lua must not carry a gitsigns spec fragment")
    end
    for _, v in pairs(t) do
      scan(v, depth + 1)
    end
  end
  scan(md, 0)
  assert_eq(md.enabled, nil, "mini.diff must not be conditionally disabled itself")
end)

test("hunk marks go in the number column, not the sign column", function()
  -- gitsigns owns the sign column. Both plugins mark the same hunks, so
  -- style="sign" would render every hunk twice.
  assert_eq(md.opts.view.style, "number", "view.style must be 'number' so gitsigns keeps the sign column")
end)

test("every upstream mapping is disabled", function()
  -- Navigation because gitsigns owns those keys; apply/reset/textobject because
  -- upstream's versions hard-error on unattached buffers. All are re-bound in
  -- `config` behind the guard.
  local mp = md.opts.mappings
  for _, name in ipairs({ "apply", "reset", "textobject", "goto_first", "goto_prev", "goto_next", "goto_last" }) do
    assert_eq(mp[name], "", name .. " must be disabled with an empty string")
  end
end)

-- ---------------------------------------------------------------------------
-- Run the REAL config against a stubbed mini.diff, on an UNATTACHED buffer
-- ---------------------------------------------------------------------------

local maps, commands, notifies = {}, {}, {}
local autocmds, toggles = {}, {}
local stub_attached, stub_overlay = false, false

do
  package.loaded["mini.diff"] = {
    setup = function() end,
    -- The whole point: an unattached buffer returns nil here.
    get_buf_data = function()
      return stub_attached and { hunks = {}, overlay = stub_overlay } or nil
    end,
    enable = function() end,
    toggle = function() end,
    toggle_overlay = function(b)
      toggles[#toggles + 1] = b
      stub_overlay = not stub_overlay
    end,
    export = function() return {} end,
    operator = function() return "g@" end,
    textobject = function() end,
  }

  local real_set, real_cmd, real_notify = vim.keymap.set, vim.api.nvim_create_user_command, vim.notify
  local real_au = vim.api.nvim_create_autocmd
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.api.nvim_create_autocmd = function(event, opts)
    autocmds[#autocmds + 1] = { event = event, opts = opts or {} }
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.keymap.set = function(mode, lhs, rhs, opts)
    local modes = type(mode) == "string" and { mode } or mode
    for _, m in ipairs(modes) do
      maps[m .. ":" .. lhs] = { rhs = rhs, opts = opts or {} }
    end
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.api.nvim_create_user_command = function(name, fn, opts)
    commands[name] = { fn = fn, desc = (opts or {}).desc }
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg)
    notifies[#notifies + 1] = tostring(msg)
  end

  local ok, err = pcall(md.config, nil, md.opts)

  vim.keymap.set, vim.api.nvim_create_user_command, vim.notify = real_set, real_cmd, real_notify
  vim.api.nvim_create_autocmd = real_au
  package.loaded["mini.diff"] = nil

  test("mini.diff config runs", function()
    assert_true(ok, "config must run: " .. tostring(err))
  end)
end

test("config re-binds the operators, textobject and overlay key", function()
  -- Upstream binds apply/reset in { n, x } as expr, and -- because the
  -- textobject shares `gh` with apply -- the textobject in `o` only.
  for _, key in ipairs({ "n:gh", "x:gh", "n:gH", "x:gH" }) do
    assert_true(maps[key] ~= nil, key .. " must be bound")
    assert_true(maps[key].opts.expr == true, key .. " must be an expr mapping (dot-repeat via g@)")
  end
  assert_true(maps["o:gh"] ~= nil, "gh must be the operator-pending hunk textobject")
  assert_true(maps["n:<leader>go"] ~= nil, "<leader>go must toggle the overlay")
  assert_eq(maps["n:<leader>go"].opts.desc, "Toggle Diff Overlay", "desc must say what it does")
end)

test("config registers the MiniDiff user commands", function()
  -- Upstream creates no commands at all, so these are the only discoverable
  -- entry points besides the mappings.
  for _, name in ipairs({ "MiniDiffOverlay", "MiniDiffToggle", "MiniDiffQuickfix" }) do
    assert_true(commands[name] ~= nil, ":" .. name .. " must be created")
  end
end)

--- Run `fn` with vim.notify intercepted into `notifies`.
--- Required because the guard resolves vim.notify at CALL time, so stubbing it
--- only while `config` ran would miss every message.
local function with_notify(fn)
  local real = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg)
    notifies[#notifies + 1] = tostring(msg)
  end
  local ok, res = pcall(fn)
  vim.notify = real
  return ok, res
end

-- The reported bug, reproduced against a real nofile buffer.
local scratch = vim.api.nvim_create_buf(false, true)
vim.bo[scratch].buftype = "nofile"
local prev_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_set_current_buf(scratch)
stub_attached = false

test("an unattached buffer never raises from the operators", function()
  -- Upstream's do_hunks() calls H.error() here -> E5108.
  for _, key in ipairs({ "n:gh", "x:gh", "n:gH", "x:gH" }) do
    notifies = {}
    local ok, res = with_notify(function() return maps[key].rhs() end)
    assert_true(ok, key .. " must not raise on an unattached buffer: " .. tostring(res))
    -- An expr mapping MUST return a string; nil is itself a runtime error.
    assert_eq(res, "", key .. " must return an empty string so nothing happens")
    assert_true(#notifies > 0, key .. " must explain why nothing happened")
  end
end)

test("an unattached buffer never raises from the textobject or overlay", function()
  -- Upstream's textobject() and toggle_overlay() both call H.error() here.
  for _, key in ipairs({ "o:gh", "n:<leader>go" }) do
    notifies = {}
    local ok, err = with_notify(function() return maps[key].rhs() end)
    assert_true(ok, key .. " must not raise on an unattached buffer: " .. tostring(err))
    assert_true(#notifies > 0, key .. " must explain why nothing happened")
  end
end)

test(":MiniDiffOverlay is guarded too, not just the keymap", function()
  -- The user's traceback came through the keymap, but the command reaches the
  -- identical upstream call.
  notifies = {}
  local ok, err = with_notify(function() return commands["MiniDiffOverlay"].fn() end)
  assert_true(ok, ":MiniDiffOverlay must not raise on an unattached buffer: " .. tostring(err))
  assert_true(#notifies > 0, ":MiniDiffOverlay must explain why nothing happened")
end)

test("an ATTACHED buffer still performs the action", function()
  -- Guard against over-correcting into "never do anything".
  stub_attached = true
  notifies = {}
  local ok, res = with_notify(function() return maps["n:gh"].rhs() end)
  assert_true(ok, "gh must run on an attached buffer")
  assert_eq(res, "g@", "gh must return g@ so the operator is dot-repeatable")
  assert_eq(#notifies, 0, "an attached buffer must not warn")

  local ok2 = with_notify(function() return maps["n:<leader>go"].rhs() end)
  assert_true(ok2, "<leader>go must run on an attached buffer")
  assert_eq(#notifies, 0, "an attached buffer must not warn")
  stub_attached = false
end)

vim.api.nvim_set_current_buf(prev_buf)
vim.api.nvim_buf_delete(scratch, { force = true })

-- ---------------------------------------------------------------------------
-- The overlay must survive a buffer reload
-- ---------------------------------------------------------------------------
--
-- THE BUG (reported): with the overlay on, leaving a `<leader>ghd` diff turned
-- it back off. `overlay` lives in mini.diff's per-buffer cache; `disable()`
-- deletes that cache and re-attaching re-initialises it to false. `enable()`
-- registers `on_detach -> disable`, and nvim fires on_detach on ANY reload --
-- upstream's comment says "including `:edit`". So the choice was silently lost.

local restore_au
test("config registers a MiniDiffUpdated restore hook", function()
  for _, a in ipairs(autocmds) do
    if a.event == "User" and a.opts.pattern == "MiniDiffUpdated" then
      restore_au = a
    end
  end
  assert_true(restore_au ~= nil, "a User MiniDiffUpdated autocmd must be created to restore the overlay")
  assert_true(type(restore_au.opts.callback) == "function", "the hook must have a callback")
end)

local named = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(named, "/tmp/andrew-minidiff-spec-target.txt")
local prev2 = vim.api.nvim_get_current_buf()
vim.api.nvim_set_current_buf(named)

test("the overlay choice is re-applied after a reload", function()
  stub_attached, stub_overlay = true, false

  -- 1. the user turns the overlay on
  with_notify(function() return maps["n:<leader>go"].rhs() end)
  assert_true(stub_overlay, "the keymap must have turned the overlay on")

  -- 2. a reload: mini.diff detaches, re-attaches, overlay back to false
  stub_overlay = false
  toggles = {}

  -- 3. mini.diff finishes its first diff update after re-attaching
  restore_au.opts.callback({ buf = named })
  assert_true(#toggles > 0, "the hook must re-apply the overlay after a reload")
  assert_true(stub_overlay, "the overlay must be back on")
end)

test("the hook does not loop once the overlay is restored", function()
  -- toggle_overlay schedules another update, which fires the hook again.
  toggles = {}
  restore_au.opts.callback({ buf = named })
  assert_eq(#toggles, 0, "the hook must be a no-op when the overlay is already on")
end)

test("turning the overlay off is remembered too", function()
  -- Guard against over-correcting into "always force the overlay on".
  stub_attached, stub_overlay = true, true
  with_notify(function() return maps["n:<leader>go"].rhs() end)
  assert_true(not stub_overlay, "the keymap must have turned the overlay off")

  toggles = {}
  restore_au.opts.callback({ buf = named })
  assert_eq(#toggles, 0, "a buffer the user turned OFF must not be re-enabled")
end)

test("a buffer the user never touched is left alone", function()
  local other = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(other, "/tmp/andrew-minidiff-spec-other.txt")
  stub_attached, stub_overlay = true, false
  toggles = {}
  restore_au.opts.callback({ buf = other })
  assert_eq(#toggles, 0, "the hook must not enable the overlay on buffers the user never enabled")
  vim.api.nvim_buf_delete(other, { force = true })
end)

vim.api.nvim_set_current_buf(prev2)
vim.api.nvim_buf_delete(named, { force = true })
stub_attached, stub_overlay = false, false

-- ---------------------------------------------------------------------------
-- Cross-plugin collision check against gitsigns' REAL map set
-- ---------------------------------------------------------------------------

--- gitsigns' `opts` is a function: it registers the <leader>uG "Git Signs"
--- Snacks.toggle and then returns the options table. Resolve it behind a
--- stubbed Snacks so these specs keep reaching on_attach.
local function gitsigns_opts(spec)
  if type(spec.opts) ~= "function" then
    return spec.opts
  end
  local prev = _G.Snacks
  local noop_toggle = {}
  noop_toggle.map = function(self) return self end
  -- the spec calls Snacks.toggle({...}):map(...), so `toggle` is the callable
  _G.Snacks = { toggle = setmetatable({}, { __call = function() return noop_toggle end }) }
  local ok, res = pcall(spec.opts)
  _G.Snacks = prev
  assert(ok, "gitsigns opts() failed: " .. tostring(res))
  return res
end

local gitsigns_maps = {}
do
  local gs_spec = dofile(cfg .. "/lua/andrew/plugins/gitsigns.lua")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "lua"
  local noop = function() end
  package.loaded.gitsigns = setmetatable({}, { __index = function() return noop end })
  local real_set = vim.keymap.set
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.keymap.set = function(mode, lhs, _, opts)
    local modes = type(mode) == "string" and { mode } or mode
    for _, m in ipairs(modes) do
      gitsigns_maps[m .. ":" .. lhs] = (opts or {}).desc or true
    end
  end
  pcall(gitsigns_opts(gs_spec).on_attach, buf)
  vim.keymap.set = real_set
  package.loaded.gitsigns = nil
  vim.api.nvim_buf_delete(buf, { force = true })
end

test("no mini.diff mapping collides with a gitsigns mapping", function()
  assert_true(next(gitsigns_maps) ~= nil, "gitsigns map set must be non-empty for this check to mean anything")
  for key in pairs(maps) do
    assert_nil(gitsigns_maps[key], "mini.diff and gitsigns both bind " .. key)
  end
end)

test("gitsigns still owns every hunk motion", function()
  -- The other half of the collision check: prove the keys mini.diff gave up
  -- are actually still served by gitsigns, so nothing was simply lost.
  for _, k in ipairs({ "]g", "[g", "]h", "[h", "]H", "[H" }) do
    assert_true(gitsigns_maps["n:" .. k] ~= nil, k .. " must still be a gitsigns hunk motion")
  end
end)

_H.finish({ style = "results", exit = "os" })
