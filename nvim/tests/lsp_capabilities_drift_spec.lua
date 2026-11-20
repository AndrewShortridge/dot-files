-- Spec: andrew.lsp_capabilities.COMPLETION must equal what the installed
-- blink.cmp advertises.
--
-- lspconfig.lua sends a static COPY of blink.cmp's completion capabilities so
-- that opening a file does not have to load blink.cmp (and LuaSnip with it)
-- just to read a constant table. The price of a copy is drift: after a blink
-- update that, say, adds a resolveSupport property, every server would keep
-- being told the old set, with no error anywhere. This compares the two.
--
-- Discriminating power: fails if any key or value in the copy differs from
-- blink's table, in either direction.
--
-- Run with: nvim --headless -u NONE -l tests/lsp_capabilities_drift_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_true, assert_deep_eq = _H.test, _H.assert_true, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy/blink.cmp")

test("the static copy matches blink.cmp's get_lsp_capabilities()", function()
  local ok, blink = pcall(require, "blink.cmp")
  assert_true(ok, "blink.cmp must be installed to compare against: " .. tostring(blink))
  assert_deep_eq(
    require("andrew.lsp_capabilities").COMPLETION,
    blink.get_lsp_capabilities(),
    "lua/andrew/lsp_capabilities.lua is out of date with blink.cmp -- re-copy it"
  )
end)

_H.finish({ style = "results", exit = "os" })
