-- Regression spec for the vault-c audit fix in transform_pipeline.
-- Run with: nvim --headless -u NONE -l tests/audit_vaultc_pipeline_spec.lua
--
-- Bug: a highlight toggle (hl_coord.make_toggle -> :VaultFieldHLToggle,
-- :VaultTagHLToggle, :VaultWikilinkHLToggle) clears its namespace DIRECTLY and
-- then asks the coordinator for a `full` re-render. render_diff still held those
-- extmarks in its shadow copy, so the diff decided "nothing changed" and painted
-- nothing: toggling any highlight group back on left the buffer unhighlighted for
-- good (:Vault*HLRefresh could not recover it either).
--
-- Part 1 pins the render_diff invariant the bug rests on.
-- Part 2 drives the real pipeline over a real buffer and asserts a `full` run
-- repaints after an out-of-band namespace clear.

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

package.loaded["andrew.vault.vault_log"] = setmetatable({
  scope = function()
    return setmetatable({}, { __index = function() return function() end end })
  end,
}, { __index = function() return function() end end })

local render_diff = require("andrew.vault.render_diff")

local NS = vim.api.nvim_create_namespace("audit_vaultc_pipeline_ns")

local function fresh_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function marks(buf, ns)
  return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
end

-- ── Part 1: the render_diff shadow-state invariant ────────────────────────

test("apply_diff re-applies nothing after an out-of-band namespace clear", function()
  local buf = fresh_buf({ "alpha", "beta" })
  local specs = {
    { ns = NS, line = 0, col = 0, opts = { end_col = 5, hl_group = "Comment" } },
  }
  render_diff.apply_diff(buf, specs, { [0] = true, [1] = true })
  assert_eq(marks(buf, NS), 1, "first apply paints the spec")

  -- Simulate hl_coord.make_toggle's direct namespace wipe.
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  assert_eq(marks(buf, NS), 0)

  render_diff.apply_diff(buf, specs, { [0] = true, [1] = true })
  assert_eq(marks(buf, NS), 0,
    "the shadow copy suppresses the repaint -- this is why `full` must invalidate")
  render_diff.invalidate(buf)
end)

test("render_diff.invalidate lets the identical spec set be re-applied", function()
  local buf = fresh_buf({ "alpha", "beta" })
  local specs = {
    { ns = NS, line = 0, col = 0, opts = { end_col = 5, hl_group = "Comment" } },
  }
  render_diff.apply_diff(buf, specs, { [0] = true, [1] = true })
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  render_diff.invalidate(buf)
  render_diff.apply_diff(buf, specs, { [0] = true, [1] = true })
  assert_eq(marks(buf, NS), 1, "after invalidate the spec is painted again")
  render_diff.invalidate(buf)
end)

-- ── Part 2: the real pipeline repaints on a `full` run ────────────────────

test("a `full` pipeline run repaints inline-field highlights after a ns wipe", function()
  local pipeline = require("andrew.vault.transform_pipeline")
  local inline_fields = require("andrew.vault.inline_fields")
  local link_scan = require("andrew.vault.link_scan")

  local buf = fresh_buf({
    "# Note",
    "",
    "author:: Andrew",
    "year:: 2026",
  })
  vim.api.nvim_set_current_buf(buf)
  inline_fields.enabled = true

  pipeline.attach(buf)
  local code_excl = link_scan.build_code_exclusion(buf)
  pipeline.run(buf, code_excl, { full = true })
  local first = marks(buf, inline_fields.ns)
  assert_true(first > 0, "the first full run paints inline-field highlights")

  -- Exactly what hl_coord.make_toggle does when switching the feature off.
  vim.api.nvim_buf_clear_namespace(buf, inline_fields.ns, 0, -1)
  assert_eq(marks(buf, inline_fields.ns), 0)

  -- ...and what it does when switching it back on.
  pipeline.run(buf, link_scan.build_code_exclusion(buf), { full = true })
  assert_eq(marks(buf, inline_fields.ns), first,
    "a full run restores every highlight it painted before")

  pipeline.detach(buf)
end)

test("a `full` run does not duplicate extmarks when nothing was cleared", function()
  local pipeline = require("andrew.vault.transform_pipeline")
  local inline_fields = require("andrew.vault.inline_fields")
  local link_scan = require("andrew.vault.link_scan")

  local buf = fresh_buf({ "# Note", "", "author:: Andrew" })
  vim.api.nvim_set_current_buf(buf)
  inline_fields.enabled = true

  pipeline.attach(buf)
  pipeline.run(buf, link_scan.build_code_exclusion(buf), { full = true })
  local n1 = marks(buf, inline_fields.ns)
  pipeline.run(buf, link_scan.build_code_exclusion(buf), { full = true })
  local n2 = marks(buf, inline_fields.ns)
  assert_eq(n2, n1, "repeated full runs are idempotent")
  pipeline.detach(buf)
end)

-- ── cache_warming must not close a require cycle with engine ───────────────
--
-- engine.lua does `pcall(require, "andrew.vault.cache_warming")` from its own
-- top-level chunk. A top-level `require("andrew.vault.engine")` inside
-- cache_warming therefore raised "loop or previous error loading module",
-- engine swallowed it, and the module never finished loading: no warming
-- autocmds, no :VaultWarmDebug, no "warming" cache registration.

test("cache_warming loads standalone (no top-level engine require cycle)", function()
  package.loaded["andrew.vault.cache_warming"] = nil
  local ok, mod = pcall(require, "andrew.vault.cache_warming")
  assert_true(ok, "require must succeed: " .. tostring(mod))
  assert_eq(type(mod), "table", "module returns its table")
  assert_eq(type(mod.setup), "function", "setup() is reachable")
  assert_eq(type(mod.stats), "function", "stats() is reachable")
end)

test("cache_warming.setup() installs its autocmd group", function()
  local mod = require("andrew.vault.cache_warming")
  mod.setup()
  local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "VaultCacheWarming" })
  assert_true(ok, "the VaultCacheWarming augroup exists")
  assert_true(#autocmds > 0, "setup() registered autocmds")
end)

_H.finish({ style = "results", exit = "os" })
