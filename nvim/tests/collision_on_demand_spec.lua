-- End-to-end spec for on-demand collision detection.
--
-- Collision detection is now deferred off the full-rebuild critical path (to
-- IDLE), and the incremental update path already skips it for small (<5 file)
-- batches. To guarantee :VaultIndexCollisions never shows stale data,
-- show_collisions() recomputes synchronously on demand. This spec drives the
-- REAL module against a temp vault and asserts that on-demand recompute reflects
-- the current name/alias state, even when the deferred/skipped scan hasn't run.
--
-- Run with: nvim --headless -u NONE -l tests/collision_on_demand_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vi = require("andrew.vault.vault_index")

print("\n=== Collision On-Demand Tests ===\n")

local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

local function find_collision(list, ctype, key)
  for _, c in ipairs(list or {}) do
    if c.type == ctype and c.key == key then return c end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- 1. Basename collision is reported by on-demand recompute, even though the
--    full-build scan was deferred (IDLE never drains in headless).
-- ---------------------------------------------------------------------------
test("show_collisions recomputes and reports a basename collision", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir, "one/dup.md", { "# One" })
  write_file(dir, "two/dup.md", { "# Two" })

  local idx = vi.VaultIndex.new(dir)
  idx:build_sync() -- collision detection deferred to IDLE (not drained here)

  -- On-demand path: show_collisions() recomputes into idx._collisions first.
  -- (C.show opens a float; wrap so any headless-UI quirk can't fail the test —
  -- the recompute that populates _collisions runs before the render.)
  pcall(function() idx:show_collisions() end)

  local hit = find_collision(idx._collisions, "basename", "dup")
  assert_true(hit ~= nil, "basename collision on 'dup' reported on demand")
  assert_eq(#hit.files, 2, "two files share the 'dup' basename")
end)

-- ---------------------------------------------------------------------------
-- 2. Alias-alias collision likewise surfaces via on-demand recompute.
-- ---------------------------------------------------------------------------
test("show_collisions reports an alias-alias collision on demand", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir, "x.md", { "---", "aliases: [shared]", "---", "x" })
  write_file(dir, "y.md", { "---", "aliases: [shared]", "---", "y" })

  local idx = vi.VaultIndex.new(dir)
  idx:build_sync()
  pcall(function() idx:show_collisions() end)

  local hit = find_collision(idx._collisions, "alias-alias", "shared")
  assert_true(hit ~= nil, "alias-alias collision on 'shared' reported on demand")
  assert_eq(#hit.files, 2, "two files define alias 'shared'")
end)

-- ---------------------------------------------------------------------------
-- 3. Freshness after a small incremental update: a collision introduced by a
--    <5-file update (whose inline detection is skipped) is still surfaced by
--    the on-demand recompute. This is the staleness gap the fix closes.
-- ---------------------------------------------------------------------------
test("on-demand recompute reflects collision added by a small incremental update", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir, "a/note.md", { "# A" })

  local idx = vi.VaultIndex.new(dir)
  idx:build_sync()
  -- No collision yet.
  pcall(function() idx:show_collisions() end)
  assert_true(find_collision(idx._collisions, "basename", "note") == nil,
    "no 'note' basename collision initially")

  -- Introduce a colliding file via a single-file incremental update (<5 files,
  -- so the incremental path skips inline collision detection).
  write_file(dir, "b/note.md", { "# B" })
  idx:update_file(dir .. "/b/note.md")

  -- On-demand recompute must now reflect the new collision.
  pcall(function() idx:show_collisions() end)
  local hit = find_collision(idx._collisions, "basename", "note")
  assert_true(hit ~= nil, "new 'note' basename collision surfaced on demand")
  assert_eq(#hit.files, 2, "both note.md files reported")
end)

_H.finish({ style = "results", exit = "os" })
