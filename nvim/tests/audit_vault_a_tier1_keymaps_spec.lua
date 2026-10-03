-- Regression spec: the vault keymaps that must exist BEFORE the first markdown
-- buffer (Tier 1).
--
-- vault/init.lua is Tier 1; nearly everything else loads on the first
-- `FileType markdown` (Tier 2). Quick capture (<leader>vQ / <leader>vi) and the
-- command palette (<leader>v?) are global, "from anywhere" features, but their
-- lhs used to be registered only by capture.setup() / command_palette.setup(),
-- i.e. Tier 2 -- so from a Lua file or the startup screen they did not exist at
-- all. The vault-a audit added Tier-1 stubs in init.lua (same pattern as the
-- pre-existing <leader>uW stub). This spec pins all of them down.
--
-- Requiring andrew.vault runs init.lua's Tier-1 chunk only (the rest is behind
-- an autocmd), so no plugin manager or markdown buffer is involved.
--
-- Run with: nvim --headless -u NONE -l tests/audit_vault_a_tier1_keymaps_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. vim.fn.stdpath("config") .. "/lua/?/init.lua;" .. package.path

-- mapleader must be set before the maps are created: nvim resolves <leader> at
-- set time, so a later change would not move the lhs.
vim.g.mapleader = " "

local tmp_vault = vim.fn.tempname() .. "-vault"
vim.fn.mkdir(tmp_vault, "p")
vim.g.vault_path = tmp_vault

require("andrew.vault") -- Tier 1 only

local function get_map(lhs)
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    if m.lhs == lhs then return m end
  end
end

test("global 'from anywhere' vault maps exist at Tier 1", function()
  for lhs, want_desc in pairs({
    [" vQ"] = "quick capture",
    [" vi"] = "capture to inbox",
    [" v?"] = "command palette",
    [" uW"] = "readable width",
  }) do
    local m = get_map(lhs)
    assert_true(m ~= nil, "Tier 1 must register <leader>" .. lhs:sub(2))
    assert_true(type(m.callback) == "function", lhs .. " must have a Lua callback")
    assert_true(
      (m.desc or ""):lower():find(want_desc, 1, true) ~= nil,
      lhs .. " desc should mention '" .. want_desc .. "', got: " .. tostring(m.desc)
    )
  end
end)

test("all template maps exist at Tier 1", function()
  for _, suffix in ipairs({ "n", "d", "w", "s", "a", "k", "m", "f", "l", "p", "j", "c", "M", "Q", "Y" }) do
    local lhs = " vt" .. suffix
    local m = get_map(lhs)
    assert_true(m ~= nil, "Tier 1 must register <leader>vt" .. suffix)
    assert_true(type(m.callback) == "function", lhs .. " must have a Lua callback")
  end
end)

test("VaultNew / VaultDaily commands exist at Tier 1", function()
  local cmds = vim.api.nvim_get_commands({})
  assert_true(cmds["VaultNew"] ~= nil, ":VaultNew must exist at Tier 1")
  assert_true(cmds["VaultDaily"] ~= nil, ":VaultDaily must exist at Tier 1")
end)

test("<leader>v? replays the queued palette registrations and shows entries", function()
  -- init.lua queues register_command/register_keymap through a lazy proxy and
  -- replays them on the first non-register access. Reaching the palette through
  -- that proxy (not a direct require) is what makes the Tier-1 palette complete,
  -- so the registry must still be empty until the map actually fires.
  local palette = require("andrew.vault.command_palette")
  assert_eq(#palette._registry, 0, "registrations should still be queued before <leader>v? fires")

  local shown
  package.preload["fzf-lua"] = function()
    return { fzf_exec = function(lines) shown = lines end }
  end

  get_map(" v?").callback()

  assert_true(#palette._registry > 0, "firing <leader>v? must replay the queued registrations")
  assert_true(shown ~= nil and #shown > 0, "the palette must hand fzf a non-empty entry list")
end)

vim.fn.delete(tmp_vault, "rf")

_H.finish()
