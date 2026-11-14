-- Spec for the format-on-save gate (lua/andrew/utils/autoformat.lua) and the
-- two conform.nvim save paths that must both consult it.
--
-- Background: formatting on save was unconditional -- `format_on_save` was a
-- static table and there was no toggle of any kind, so the only way to save
-- without formatting was :noautocmd w. LazyVim gates format-on-save on
-- vim.b.autoformat / vim.g.autoformat (util/format.lua:84-96) and exposes
-- <leader>uf (global) and <leader>uF (buffer). This ports the gate.
--
-- conform.lua USED to have two BufWritePre paths -- the one conform installs
-- from `format_on_save`, plus a hand-rolled autocmd in augroup ConformFormat
-- whose pattern list was a strict subset of conform's "*". It added no coverage
-- and formatted every matched buffer a second time, after the write. It has
-- been removed, and test 4 pins that: a second path is both wasted work and a
-- place for a future toggle to be half-applied.
--
-- Drives the REAL modules: the gate directly, and the REAL conform plugin spec
-- via dofile with a fake `conform` injected into package.loaded (same technique
-- as which_key_icons_spec), so both save paths are exercised as written.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * Test 1 fails if buffer/global precedence is inverted or if an unset
--     value stops defaulting to enabled.
--   * Test 3 fails if format_on_save reverts to a static table (it then
--     formats even with autoformat off).
--   * Test 4 fails if a second BufWritePre save path is reintroduced (verified
--     by restoring the old ConformFormat autocmd).
--   * Test 5 fails if <leader>cf / <leader>cF are dropped or lose visual mode.
--   * Test 6 fails if <leader>cf starts honouring the gate; it is the FORCE
--     path and must format even when autoformat is off.
--
-- Run with: nvim --headless -u NONE -l tests/autoformat_toggle_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_false, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local AF = require("andrew.utils.autoformat")

local function reset()
  vim.g.autoformat = nil
  vim.b.autoformat = nil
end

test("enabled(): defaults on, buffer overrides global", function()
  reset()
  assert_true(AF.enabled(0), "unset must default to enabled")

  vim.g.autoformat = false
  assert_false(AF.enabled(0), "global off must disable")

  vim.b.autoformat = true
  assert_true(AF.enabled(0), "buffer ON must override global off")

  vim.g.autoformat = true
  vim.b.autoformat = false
  assert_false(AF.enabled(0), "buffer OFF must override global on")

  reset()
end)

test("enabled() reads the buffer it is asked about, not just the current one", function()
  reset()
  local other = vim.api.nvim_create_buf(false, true)
  vim.b[other].autoformat = false

  assert_true(AF.enabled(0), "current buffer unaffected")
  assert_false(AF.enabled(other), "must honour the buffer argument")

  vim.api.nvim_buf_delete(other, { force = true })
  reset()
end)

-- ---------------------------------------------------------------------------
-- Drive the real conform spec with a fake conform module.
-- ---------------------------------------------------------------------------
local captured = { setup_opts = nil, formats = {} }
package.loaded["conform"] = {
  setup = function(o)
    captured.setup_opts = o
  end,
  format = function(o)
    captured.formats[#captured.formats + 1] = o
  end,
}

local spec = dofile(vim.fn.stdpath("config") .. "/lua/andrew/plugins/formatting/conform.lua")
spec.config()

test("format_on_save is a gate function, not an unconditional table", function()
  local fos = captured.setup_opts and captured.setup_opts.format_on_save
  assert_true(type(fos) == "function", "format_on_save must be a function so it can consult the toggle")

  reset()
  local on = fos(vim.api.nvim_get_current_buf())
  assert_true(type(on) == "table", "must return opts when autoformat is enabled")
  assert_eq(on.timeout_ms, 1000, "must keep the original 1s timeout")

  vim.g.autoformat = false
  assert_nil(fos(vim.api.nvim_get_current_buf()), "must return nil when autoformat is disabled")
  reset()
end)

test("there is exactly ONE format-on-save path (the duplicate is gone)", function()
  -- The spec used to register a second BufWritePre autocmd in augroup
  -- ConformFormat whose pattern list was a strict subset of the "*" conform
  -- installs from format_on_save. It formatted every matched buffer a second
  -- time, after the write had already happened. Assert it stays gone.
  local ok, aus = pcall(vim.api.nvim_get_autocmds, { group = "ConformFormat" })
  assert_true(
    not ok or #aus == 0,
    "augroup ConformFormat must not exist -- the duplicate save path was removed"
  )

  -- More generally: config() must not install a BufWritePre handler of its own.
  -- conform's is registered inside conform.setup(), which is faked here, so any
  -- BufWritePre autocmd carrying this file's callback would be a second path.
  local own = 0
  for _, au in ipairs(vim.api.nvim_get_autocmds({ event = "BufWritePre" })) do
    if au.group_name and au.group_name:find("Conform") then
      own = own + 1
    end
  end
  assert_eq(own, 0, "conform.lua must not create its own BufWritePre autocmd")
end)

test("spec declares <leader>cf and <leader>cF in normal AND visual mode", function()
  local seen = {}
  for _, k in ipairs(spec.keys or {}) do
    local modes = k.mode or "n"
    if type(modes) == "string" then
      modes = { modes }
    end
    for _, m in ipairs(modes) do
      seen[k[1] .. "|" .. m] = k[2]
    end
  end

  for _, want in ipairs({ "<leader>cf|n", "<leader>cf|x", "<leader>cF|n", "<leader>cF|x" }) do
    assert_true(type(seen[want]) == "function", "missing format keymap: " .. want)
  end
end)

test("<leader>cf is the FORCE path and ignores the toggle", function()
  local rhs
  for _, k in ipairs(spec.keys or {}) do
    if k[1] == "<leader>cf" then
      rhs = k[2]
    end
  end

  vim.g.autoformat = false
  captured.formats = {}
  local ok, err = pcall(rhs)
  reset()

  assert_true(ok, "rhs must not error: " .. tostring(err))
  assert_eq(#captured.formats, 1, "<leader>cf must format even with autoformat off")
end)

_H.finish({ style = "results", exit = "os" })
