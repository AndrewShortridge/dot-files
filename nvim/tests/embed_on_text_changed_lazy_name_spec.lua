-- Regression spec for lazy nvim_buf_get_name() in embed.on_text_changed.
-- Run with: nvim --headless -u NONE -l tests/embed_on_text_changed_lazy_name_spec.lua
--
-- Bug: event_dispatch.lua computed vim.api.nvim_buf_get_name(bufnr) eagerly on
-- EVERY TextChanged/InsertLeave and passed it to embed.on_text_changed, which
-- discards it for the common case (no visible transclusion). The fix moves the
-- C call+alloc inside on_text_changed, AFTER the sync+visibility guards.
--
-- Discriminating power: the common-path test asserts nvim_buf_get_name is NOT
-- called for a buffer with no embed state. Reintroducing the bug (eager call at
-- the site, or computing the name before the guards) makes the counter >= 1.

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true =
  _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local embed = require("andrew.vault.embed")
local state = require("andrew.vault.embed_state")
local sync = require("andrew.vault.embed_sync")
local config = require("andrew.vault.config")

-- Ensure the first guard (sync enabled) passes so the visibility guard is what
-- gates the common path.
config.embed.sync = config.embed.sync or {}
config.embed.sync.enabled = true

-- Wrap nvim_buf_get_name with a call counter.
local orig_get_name = vim.api.nvim_buf_get_name
local name_calls = 0
vim.api.nvim_buf_get_name = function(b)
  name_calls = name_calls + 1
  return orig_get_name(b)
end

print("\n=== embed.on_text_changed lazy name Tests ===\n")

-- ---------------------------------------------------------------------------
-- 1. Common path: buffer with NO embed state => name must NOT be computed.
-- ---------------------------------------------------------------------------
test("on_text_changed does not compute buf name for untracked buffer", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  -- No state.get_buf_state call => try_get_buf_state returns nil => early return.
  name_calls = 0
  embed.on_text_changed(bufnr)
  assert_eq(name_calls, 0, "nvim_buf_get_name should not run for untracked buffer")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

-- ---------------------------------------------------------------------------
-- 2. Active path: visible embed whose deps include self => rerender fires,
--    and name IS computed exactly once.
-- ---------------------------------------------------------------------------
test("on_text_changed reruns for visible self-referential embed", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local name = orig_get_name(bufnr)
  local bst = state.get_buf_state(bufnr)
  bst.visible = true
  bst.deps = { [name] = true }

  local orig_schedule = sync.schedule_rerender
  local rerendered = false
  sync.schedule_rerender = function(_)
    rerendered = true
  end

  name_calls = 0
  embed.on_text_changed(bufnr)

  assert_eq(name_calls, 1, "name computed exactly once on the active path")
  assert_true(rerendered, "schedule_rerender should fire for self-referential dep")

  sync.schedule_rerender = orig_schedule
  state.clear_buffer_state(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

-- Restore the wrapped API.
vim.api.nvim_buf_get_name = orig_get_name

_H.finish({ style = "results", exit = "os" })
