-- Perf-discrimination + correctness spec for Issue 13 (orig #15):
-- connections.compute cache validity is GENERATION-based only; the legacy
-- config.connections.cache_ttl wall-clock term is no longer consulted.
--
-- THE FIX: in connections.lua M.compute, the cache-hit branch dropped the
--   `and (now - cached.timestamp) < ttl` term, relying solely on
--   filter_utils.is_cache_gen_valid (cached.index_gen == current generation).
--   On an unchanged vault (index _generation unchanged) the cached result is
--   reused indefinitely instead of being discarded after cache_ttl seconds and
--   forcing a redundant full-vault recompute that yields an identical result.
--
-- OBSERVABLE DISCRIMINATOR (no mocks, no source introspection): a cache HIT
--   returns the SAME results table identity (cached.results); a MISS builds a
--   fresh results table (NEW identity). So compute('A.md') == compute('A.md')
--   is true on a hit, false on a miss.
--
-- DISCRIMINATING POWER (verified by reverting): with cache_ttl = 0, the FIXED
--   code ignores ttl => the second compute is a HIT (same identity). Reintroducing
--   the `and (now - cached.timestamp) < ttl` term makes the condition always
--   false at ttl=0 => MISS => NEW identity => Test 1 FAILS.
--
-- CORRECTNESS PRESERVED: when the index generation DOES change (a file edited
--   via update_file bumps _generation), the cache must MISS and recompute.
--
-- Runtime is LuaJIT 2.1 / Lua 5.1. Drives the REAL connections + vault_index
-- modules against a temp vault (vim.fn.tempname()).
--
-- Run with: nvim --headless -u NONE -l tests/connections_cache_gen_only_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true =
  _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vault_index = require("andrew.vault.vault_index")
local connections = require("andrew.vault.connections")
local config = require("andrew.vault.config")

print("\n=== Connections Cache Generation-Only Tests ===\n")

local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

-- A web of links so connection scoring yields a non-empty result for A.md:
--   A -> B, A -> C, B -> C (A and B share an outlink to C; A links B).
local function make_vault()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir, "A.md", { "# A", "", "See [[B]] and [[C]]." })
  write_file(dir, "B.md", { "# B", "", "See [[C]]." })
  write_file(dir, "C.md", { "# C", "", "Leaf note." })
  return dir
end

-- Build the SINGLETON index that connections.compute reads via
-- vault_index.current().
local function build_singleton(dir)
  vault_index._instance = nil
  local idx = vault_index.get(dir)
  idx:build_sync()
  return idx
end

-- ---------------------------------------------------------------------------
-- 1. THE FIX: generation-valid cache HIT regardless of ttl.
-- ---------------------------------------------------------------------------
test("gen-valid hit: ttl=0 still hits cache (ttl term ignored)", function()
  local orig_ttl = config.connections.cache_ttl
  local dir = make_vault()
  build_singleton(dir)
  -- Set ttl=0 so that ANY surviving wall-clock term would force a miss.
  config.connections.cache_ttl = 0

  local r1 = connections.compute("A.md")
  local r2 = connections.compute("A.md")

  config.connections.cache_ttl = orig_ttl

  assert_true(type(r1) == "table" and #r1 > 0, "first compute yields non-empty results")
  assert_true(r1 == r2,
    "second compute returns the SAME results table (cache hit) with ttl=0 " ..
    "(reintroducing `and (now-cached.timestamp)<ttl` makes ttl=0 always miss => different table)")
end)

-- ---------------------------------------------------------------------------
-- 2. CORRECTNESS: generation change forces a MISS / recompute.
-- ---------------------------------------------------------------------------
test("gen-invalid miss: index mutation bumps _generation => recompute", function()
  local dir = make_vault()
  local idx = build_singleton(dir)
  config.connections.cache_ttl = 60

  local r1 = connections.compute("A.md")
  local gen_before = idx._generation

  -- Edit B and re-index it: this bumps _generation, invalidating the cache.
  write_file(dir, "B.md", { "# B", "", "See [[C]] and now [[A]]." })
  idx:update_file(dir .. "/B.md")
  assert_true(idx._generation ~= gen_before,
    "update_file bumped _generation (" .. tostring(gen_before) .. " -> " .. tostring(idx._generation) .. ")")

  local r2 = connections.compute("A.md")
  assert_true(r1 ~= r2,
    "after an index mutation the cache MISSES and recomputes (new results table)")
end)

-- ---------------------------------------------------------------------------
-- 3. Sanity: gen-valid hit returns content-stable results.
-- ---------------------------------------------------------------------------
test("gen-valid hit returns content-stable, non-empty results", function()
  local dir = make_vault()
  build_singleton(dir)
  config.connections.cache_ttl = 60

  local r1 = connections.compute("A.md")
  local r2 = connections.compute("A.md")
  assert_true(#r1 > 0, "results are non-empty")
  assert_eq(#r1, #r2, "result count stable across a gen-valid hit")
  assert_eq(r1[1].rel_path, r2[1].rel_path, "top result identical across a gen-valid hit")
end)

_H.finish({ style = "results", exit = "os" })
