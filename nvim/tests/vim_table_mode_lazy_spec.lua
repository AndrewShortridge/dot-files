-- Perf regression spec for vim-table-mode lazy gating.
--
-- The plugin spec used to declare `ft = { "markdown" }`. Because lazy.nvim
-- re-fires `FileType markdown` when a ft-gated plugin loads, every .md open
-- re-attached the treesitter highlighter (TS parse ~13ms + highlight attach
-- ~17ms per replay). Table editing is on-demand, so the fix gates the plugin on
-- its toggle mapping (<leader>Tm) and table commands via `keys`/`cmd` instead of
-- `ft`, eliminating the FileType replay on every markdown open. `init` (which
-- sets the table_mode g: vars at startup, before the plugin's plugin/ file
-- defines its mappings) is kept unchanged.
--
-- This drives the REAL plugin spec table (dofile). No source introspection /
-- string scanning.
--
-- Discriminating power:
--   * Re-adding `ft = { "markdown" }` fails Test 2 (plug.ft must be nil).
--   * Dropping the toggle mapping from `keys` fails Test 3.
--   * Dropping the table commands from `cmd` fails Test 4.
--   * Drifting table_mode_map_prefix / table_mode_toggle_map without updating the
--     `keys` lhs fails Test 5 (the resolved mapping = prefix .. toggle_map must
--     stay consistent with the `keys` entry).
--
-- Run with: nvim --headless -u NONE -l tests/vim_table_mode_lazy_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local plug = dofile(vim.fn.stdpath("config") .. "/lua/andrew/plugins/vim-table-mode.lua")

local function contains(list, val)
  for _, v in ipairs(list or {}) do
    if v == val then return true end
  end
  return false
end

test("plugin spec returns a table for dhruvasagar/vim-table-mode", function()
  assert_true(type(plug) == "table", "spec must return a table")
  assert_eq(plug[1], "dhruvasagar/vim-table-mode", "spec must point at vim-table-mode")
end)

test("ft gate removed (no FileType replay on every .md open)", function()
  assert_nil(plug.ft, "ft must not be set (ft=markdown re-fires FileType, re-attaching TS)")
end)

test("lazy-gated on the toggle mapping via keys", function()
  assert_true(type(plug.keys) == "table", "keys gate must exist")
  local found = false
  for _, k in ipairs(plug.keys) do
    -- entries may be a string lhs or a { lhs, ... } table
    local lhs = type(k) == "table" and k[1] or k
    if lhs == "<leader>Tm" then found = true end
  end
  assert_true(found, "keys must include the <leader>Tm toggle mapping")
end)

test("lazy-gated on table commands via cmd", function()
  assert_true(type(plug.cmd) == "table", "cmd gate must exist")
  assert_true(contains(plug.cmd, "TableModeToggle"), "cmd must include TableModeToggle")
  assert_true(contains(plug.cmd, "Tableize"), "cmd must include Tableize")
end)

test("init sets table_mode g: vars consistent with the keys lhs", function()
  assert_true(type(plug.init) == "function", "init must set the table_mode g: vars at startup")
  vim.g.table_mode_corner = nil
  vim.g.table_mode_auto_align = nil
  vim.g.table_mode_map_prefix = nil
  vim.g.table_mode_toggle_map = nil
  plug.init()
  assert_eq(vim.g.table_mode_corner, "|", "table_mode_corner must be markdown-compatible")
  assert_eq(vim.g.table_mode_auto_align, 1, "table_mode_auto_align must be on")
  assert_eq(vim.g.table_mode_map_prefix, "<leader>T", "table_mode_map_prefix preserved")
  assert_eq(vim.g.table_mode_toggle_map, "m", "table_mode_toggle_map preserved")
  -- The plugin builds the toggle mapping as prefix .. toggle_map. The `keys`
  -- lazy stub MUST match that resolved lhs, or the plugin never loads.
  local resolved = vim.g.table_mode_map_prefix .. vim.g.table_mode_toggle_map
  assert_eq(resolved, "<leader>Tm", "resolved toggle mapping must equal the keys lhs <leader>Tm")
end)

_H.finish({ style = "results", exit = "os" })
