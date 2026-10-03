-- Perf regression spec: large (>=5 file) incremental batches must NOT run the
-- O(N) collision scan synchronously on the foreground. The scan is deferred to
-- IDLE via the work scheduler (exactly like the full-rebuild path), coalesced
-- under the "collisions" domain. This drives the REAL vault_index + scheduler
-- against a temp vault and counts real _detect_collisions invocations.
--
-- Discriminating power: with the fix, a >=5-file batch reports calls==0 before
-- draining IDLE and calls==1 after. Reintroducing the synchronous call flips
-- the "before drain == 0" assertion to 1 (FAIL).
--
-- Run with: nvim --headless -u NONE -l tests/collision_idle_defer_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq = _H.test, _H.assert_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vi = require("andrew.vault.vault_index")
local sched = require("andrew.vault.work_scheduler")

print("\n=== Collision IDLE Defer Tests ===\n")

local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
  return abs
end

-- Build a temp vault and return the index with a clean scheduler queue and a
-- counter wrapping the live instance's _detect_collisions method. The build
-- itself defers a collisions scan to IDLE, so we cancel that domain BEFORE
-- installing the counter, so only the batch under test is measured.
local function new_vault_with_counter()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir, "seed.md", { "# Seed" })

  local idx = vi.VaultIndex.new(dir)
  idx:build_sync()
  sched.cancel_domain("collisions") -- discard the build's deferred scan

  local calls = 0
  local orig = idx._detect_collisions
  idx._detect_collisions = function(self, n, a)
    calls = calls + 1
    return orig(self, n, a)
  end

  return dir, idx, function() return calls end
end

-- ---------------------------------------------------------------------------
-- 1. A >=5-file batch defers the scan: no synchronous detect, exactly one
--    detect after draining IDLE.
-- ---------------------------------------------------------------------------
test(">=5-file batch defers collision detect to IDLE", function()
  local dir, idx, count = new_vault_with_counter()

  local paths = {}
  for i = 1, 5 do
    paths[i] = write_file(dir, "f" .. i .. ".md", { "# F" .. i })
  end
  idx:update_files_batch(paths)

  assert_eq(count(), 0, "no synchronous detect after a >=5-file batch")

  sched.drain_idle(100)
  assert_eq(count(), 1, "exactly one detect ran after draining IDLE")
end)

-- ---------------------------------------------------------------------------
-- 2. A <5-file batch schedules nothing and runs nothing (small-batch skip).
-- ---------------------------------------------------------------------------
test("<5-file batch never schedules or runs collision detect", function()
  local dir, idx, count = new_vault_with_counter()

  local abs = write_file(dir, "solo.md", { "# Solo" })
  idx:update_file(abs)

  assert_eq(count(), 0, "no synchronous detect for a single-file update")

  sched.drain_idle(100)
  assert_eq(count(), 0, "nothing queued -> still no detect after draining IDLE")
end)

-- ---------------------------------------------------------------------------
-- 3. Two back-to-back >=5-file batches coalesce to a single deferred scan
--    (cancel_domain("collisions") collapses the pending item).
-- ---------------------------------------------------------------------------
test("back-to-back >=5-file batches coalesce to one deferred scan", function()
  local dir, idx, count = new_vault_with_counter()

  local first = {}
  for i = 1, 5 do
    first[i] = write_file(dir, "a" .. i .. ".md", { "# A" .. i })
  end
  idx:update_files_batch(first)

  local second = {}
  for i = 1, 5 do
    second[i] = write_file(dir, "b" .. i .. ".md", { "# B" .. i })
  end
  idx:update_files_batch(second)

  assert_eq(count(), 0, "no synchronous detect across both batches")

  sched.drain_idle(100)
  assert_eq(count(), 1, "coalesced to exactly one deferred scan")
end)

_H.finish({ style = "results", exit = "os" })
