-- Spec for the flash.nvim / substitute.nvim / nvim-surround key partition.
--
-- flash took LazyVim's s and S. substitute.nvim, which used to own s/ss/S,
-- moved to gs/gss/gS. Three keys stayed put and must NOT drift:
--
--   * visual `S` belongs to nvim-surround (wrap the selection). LazyVim binds
--     flash treesitter in { "n", "o", "x" }; this config binds { "n", "o" }
--     precisely so visual S survives. gS -- where surround's visual-line
--     variant lives -- is normal-mode substitute now, so surround's visual S
--     has nowhere else to go, whereas flash treesitter in visual mode is
--     duplicated by nvim-treesitter's <C-space> incremental selection.
--   * <C-space>/<BS> stay with nvim-treesitter's incremental selection.
--     LazyVim binds flash there only because nvim-treesitter's `main` rewrite
--     deleted that feature; this config is pinned to `master`, which has it.
--   * normal-mode `r` and `R` stay native -- flash is operator-pending (+
--     visual for R) only.
--
-- Also load-bearing: flash keeps `event = "VeryLazy"` ALONGSIDE `keys`. Char
-- mode's f/F/t/T/;/, maps are installed from inside setup(), and no key in the
-- `keys` table would ever trigger that load. Dropping the event silently breaks
-- f/t cycling until the first `s` press -- a regression with no error message.
--
-- Drives the REAL plugin spec tables (dofile). substitute's keymaps are made by
-- its `config` function, so that is called with a stubbed substitute module and
-- an intercepted vim.keymap.set. No source introspection.
--
-- Discriminating power:
--   * Dropping flash's `event` -> fails the VeryLazy assertion (char mode dies).
--   * Copying LazyVim's S mode list verbatim -> "x" present, failing the
--     visual-S guard that protects nvim-surround.
--   * Adding LazyVim's <C-space> treesitter key -> fails the <C-space> guard.
--   * Binding r or R in normal mode -> fails the native-key guards.
--   * Leaving substitute on s/ss/S -> fails the relocation assertions AND the
--     cross-plugin collision check.
--   * Moving substitute to visual gS -> collides with surround, caught by the
--     explicit gS-is-normal-only assertion.
--
-- Run with: nvim --headless -u NONE -l tests/flash_keys_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local cfg = vim.fn.stdpath("config")
local flash = dofile(cfg .. "/lua/andrew/plugins/flash.lua")

-- Index flash's keys by lhs, normalising `mode` (string or table) to a set.
local fkeys = {}
for _, k in ipairs(flash.keys or {}) do
  local modes = k.mode or "n"
  if type(modes) == "string" then
    modes = { modes }
  end
  local set = {}
  for _, m in ipairs(modes) do
    set[m] = true
  end
  fkeys[k[1]] = { modes = set, desc = k.desc, n_modes = #modes }
end

test("flash spec keeps VeryLazy alongside keys", function()
  assert_eq(flash[1], "folke/flash.nvim", "spec must point at folke/flash.nvim")
  -- `keys` alone would never load the plugin for char mode's f/F/t/T maps,
  -- which setup() installs. This is the silent-breakage guard.
  assert_eq(flash.event, "VeryLazy", "event must stay VeryLazy or char mode (f/F/t/T) never installs")
  assert_true(type(flash.keys) == "table", "keys table must exist")
end)

test("flash jump on s in normal, visual and operator-pending", function()
  local k = fkeys["s"]
  assert_true(k ~= nil, "s must be bound")
  for _, m in ipairs({ "n", "x", "o" }) do
    assert_true(k.modes[m], "s must be bound in mode " .. m)
  end
end)

test("flash treesitter on S in normal and operator-pending ONLY", function()
  local k = fkeys["S"]
  assert_true(k ~= nil, "S must be bound")
  assert_true(k.modes["n"], "S must be bound in normal mode")
  assert_true(k.modes["o"], "S must be bound in operator-pending mode")
  -- THE GUARD: LazyVim uses { "n", "o", "x" }. Visual S is nvim-surround's
  -- "wrap this selection", documented in KEYMAPS.md, and it has no fallback
  -- key left. Flash treesitter in visual mode is redundant with <C-space>.
  assert_nil(k.modes["x"], "S must NOT be bound in visual mode -- that is nvim-surround's")
end)

test("remote flash is operator-pending only", function()
  local k = fkeys["r"]
  assert_true(k ~= nil, "r must be bound")
  assert_true(k.modes["o"], "r must be operator-pending")
  -- Normal-mode r is replace-character; shadowing it would be a real loss.
  assert_nil(k.modes["n"], "r must NOT be bound in normal mode (native replace-char)")
  assert_eq(k.n_modes, 1, "r must be bound in exactly one mode")
end)

test("treesitter search on R avoids normal mode", function()
  local k = fkeys["R"]
  assert_true(k ~= nil, "R must be bound")
  assert_true(k.modes["o"], "R must be operator-pending")
  assert_true(k.modes["x"], "R must be visual")
  -- Normal-mode R is Replace mode.
  assert_nil(k.modes["n"], "R must NOT be bound in normal mode (native Replace mode)")
end)

test("flash search toggle is cmdline-only", function()
  local k = fkeys["<c-s>"]
  assert_true(k ~= nil, "<c-s> must be bound")
  assert_true(k.modes["c"], "<c-s> must be cmdline mode")
  assert_eq(k.n_modes, 1, "<c-s> must be cmdline mode only")
end)

test("flash does not claim <C-space> from nvim-treesitter", function()
  -- nvim-treesitter (master branch) still ships incremental selection on
  -- <C-space>/<BS>; LazyVim's flash <C-space> key exists only to replace what
  -- the `main` rewrite removed.
  for lhs in pairs(fkeys) do
    local l = lhs:lower()
    assert_true(
      l ~= "<c-space>" and l ~= "<c-  space>",
      "flash must not bind <C-space> (nvim-treesitter incremental selection owns it)"
    )
  end
end)

test("flash leaves / and ? vanilla by default", function()
  assert_eq(flash.opts.modes.search.enabled, false, "modes.search must stay disabled; <c-s> opts in per-search")
end)

-- ---------------------------------------------------------------------------
-- substitute.nvim relocation
-- ---------------------------------------------------------------------------

local sub_maps = {}
do
  package.loaded["substitute"] = {
    setup = function() end,
    operator = function() end,
    line = function() end,
    eol = function() end,
    visual = function() end,
  }
  local plug = dofile(cfg .. "/lua/andrew/plugins/substitute.lua")
  local real_set = vim.keymap.set
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.keymap.set = function(mode, lhs, rhs, opts)
    local modes = type(mode) == "string" and { mode } or mode
    for _, m in ipairs(modes) do
      sub_maps[m .. ":" .. lhs] = (opts or {}).desc or true
    end
  end
  local ok, err = pcall(plug.config, nil, plug.opts or {})
  vim.keymap.set = real_set
  test("substitute config runs", function()
    assert_true(ok, "substitute config must run: " .. tostring(err))
  end)
end

test("substitute moved to the gs prefix", function()
  assert_true(sub_maps["n:gs"] ~= nil, "gs (normal) must be the substitute operator")
  assert_true(sub_maps["n:gss"] ~= nil, "gss must substitute the line")
  assert_true(sub_maps["n:gS"] ~= nil, "gS (normal) must substitute to end of line")
  assert_true(sub_maps["x:gs"] ~= nil, "gs (visual) must substitute the selection")
end)

test("substitute no longer claims flash's keys", function()
  assert_nil(sub_maps["n:s"], "substitute must not bind normal s (flash owns it)")
  assert_nil(sub_maps["n:S"], "substitute must not bind normal S (flash owns it)")
  assert_nil(sub_maps["n:ss"], "substitute must not bind ss")
  assert_nil(sub_maps["x:s"], "substitute must not bind visual s (flash owns it)")
end)

test("substitute does not take visual gS from nvim-surround", function()
  -- nvim-surround's visual_line surround is gS in VISUAL mode. substitute's gS
  -- is normal-mode only, so the two coexist. Binding x:gS would break surround
  -- silently, since surround's maps come from plugin defaults and appear in no
  -- keymap.set in this repo.
  assert_nil(sub_maps["x:gS"], "substitute must not bind visual gS (nvim-surround's visual_line)")
end)

test("flash and substitute do not overlap", function()
  -- Cross-plugin collision check: no lhs+mode is claimed by both.
  for lhs, k in pairs(fkeys) do
    for m in pairs(k.modes) do
      assert_nil(sub_maps[m .. ":" .. lhs], "flash and substitute both bind " .. m .. ":" .. lhs)
    end
  end
end)

_H.finish({ style = "results", exit = "os" })
