-- Perf regression spec for the merged WinScrolled dispatcher.
--
-- There used to be TWO independent global WinScrolled autocmds (no pattern):
-- one in highlight_coordinator (Phase 1 visible throttle + Phase 2 prefetch)
-- and one in embed (lazy scroll render). Each one re-derived the current
-- buffer / filetype and ran its own bookkeeping every scroll tick; the
-- coordinator additionally called engine.is_vault_buf. That meant per tick:
-- two callbacks, two C-boundary current-buf reads, and an implicit
-- cross-handler ordering dependency (embed.newly_visible() reads viewport
-- _ranges/_prev_ranges that the coordinator refreshes on the same tick).
--
-- The fix mirrors the existing TextChanged consolidation: event_dispatch.lua
-- registers ONE WinScrolled autocmd that computes bufnr/filetype/is_vault ONCE
-- and dispatches coordinator-first then embed, both via new public
-- M.on_win_scrolled(ctx) methods. Behavior is byte-identical (same debounce
-- timers, same scope, same ordering); only the per-tick redundancy is removed.
--
-- This drives the REAL event_dispatch.setup() against a temp vault buffer and
-- asserts at module seams (NOT source introspection) that a single WinScrolled
-- tick:
--   * calls engine.is_vault_buf exactly ONCE,
--   * invokes highlight_coordinator.on_win_scrolled exactly ONCE,
--   * invokes embed.on_win_scrolled exactly ONCE,
--   * dispatches the coordinator BEFORE embed (the load-bearing ordering).
-- A non-vault buffer gets ZERO method dispatches (proves the shared gate gates).
--
-- Discriminating power: reintroducing the two separate handlers (each module
-- registering its own anonymous WinScrolled callback, the coordinator's one
-- calling is_vault_buf inline) makes is_vault_buf fire on EACH handler that
-- checks it, and the two on_win_scrolled methods would no longer be the
-- dispatch seam — the "exactly once via the merged dispatcher" assertions fail.
-- The single highest-signal discriminator here: with the merged dispatcher the
-- two M.on_win_scrolled methods are each invoked exactly once per tick by the
-- ONE event_dispatch autocmd; inlining the logic back into per-module
-- anonymous autocmds drops those method invocations to zero.
--
-- Run with: nvim --headless -u NONE -l tests/winscrolled_merge_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local engine = require("andrew.vault.engine")
local highlight_coordinator = require("andrew.vault.highlight_coordinator")
local embed = require("andrew.vault.embed")
local event_dispatch = require("andrew.vault.event_dispatch")

print("\n=== WinScrolled Merge Perf Tests ===\n")

-- Register the REAL consolidated dispatch path. event_dispatch.setup() requires
-- many vault modules at call time; they are all loadable headless via package.path.
local ok_setup, err_setup = pcall(event_dispatch.setup)
assert(ok_setup, "event_dispatch.setup() must load headless: " .. tostring(err_setup))

-- Create a markdown buffer inside a temp "vault" so engine.is_vault_buf is true.
local function make_vault_buf()
  local vault = vim.fn.tempname()
  vim.fn.mkdir(vault, "p")
  engine.vault_path = vault

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, vault .. "/note.md")
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_set_current_buf(buf)
  local lines = {}
  for i = 1, 200 do lines[i] = "line " .. i end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- Fire a single WinScrolled tick deterministically while counting the seams.
-- Headless WinScrolled does not reliably fire on programmatic scroll, so we use
-- nvim_exec_autocmds for a deterministic dispatch through the real autocmd.
local function fire_and_count()
  local is_vault_calls = 0
  local coord_calls = 0
  local embed_calls = 0
  local order = {}

  local orig_is_vault = engine.is_vault_buf
  local orig_coord = highlight_coordinator.on_win_scrolled
  local orig_embed = embed.on_win_scrolled

  engine.is_vault_buf = function(b)
    is_vault_calls = is_vault_calls + 1
    return orig_is_vault(b)
  end
  highlight_coordinator.on_win_scrolled = function(ctx)
    coord_calls = coord_calls + 1
    order[#order + 1] = "coord"
    return orig_coord(ctx)
  end
  embed.on_win_scrolled = function(ctx)
    embed_calls = embed_calls + 1
    order[#order + 1] = "embed"
    return orig_embed(ctx)
  end

  local ok, err = pcall(vim.api.nvim_exec_autocmds, "WinScrolled", {})

  engine.is_vault_buf = orig_is_vault
  highlight_coordinator.on_win_scrolled = orig_coord
  embed.on_win_scrolled = orig_embed

  if not ok then error(err) end
  return {
    is_vault = is_vault_calls,
    coord = coord_calls,
    embed = embed_calls,
    order = order,
  }
end

-- ---------------------------------------------------------------------------
-- A single WinScrolled tick on a vault markdown buffer dispatches ONCE each,
-- with a single shared is_vault check, coordinator before embed.
-- ---------------------------------------------------------------------------
test("single WinScrolled tick = one is_vault check, one coord + one embed dispatch", function()
  make_vault_buf()
  local c = fire_and_count()

  assert_eq(c.is_vault, 1, "merged dispatcher must check engine.is_vault_buf exactly once per tick")
  assert_eq(c.coord, 1, "highlight_coordinator.on_win_scrolled must be dispatched exactly once per tick")
  assert_eq(c.embed, 1, "embed.on_win_scrolled must be dispatched exactly once per tick")
end)

test("coordinator dispatched BEFORE embed (newly_visible ordering invariant)", function()
  make_vault_buf()
  local c = fire_and_count()
  assert_eq(c.order[1], "coord", "coordinator must run first so it refreshes viewport ranges")
  assert_eq(c.order[2], "embed", "embed must run after coordinator (reads refreshed _ranges)")
end)

-- ---------------------------------------------------------------------------
-- Non-vault buffer: the shared gate short-circuits — neither method dispatches.
-- Proves the gate is the sole vault filter and that a regression that bypasses
-- the dispatcher (inline per-module handlers) would not produce these counts.
-- ---------------------------------------------------------------------------
test("non-vault buffer dispatches neither method", function()
  -- A scratch buffer NOT inside the vault path.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/outside.md")
  vim.bo[buf].filetype = "markdown"
  -- Point vault_path elsewhere so this buffer is non-vault.
  engine.vault_path = vim.fn.tempname() .. "_vault"
  vim.api.nvim_set_current_buf(buf)

  local c = fire_and_count()
  assert_eq(c.coord, 0, "non-vault buffer must not dispatch coordinator scroll")
  assert_eq(c.embed, 0, "non-vault buffer must not dispatch embed scroll")
end)

_H.finish({ style = "results", exit = "os" })
