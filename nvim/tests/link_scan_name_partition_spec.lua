-- Behavioral spec for the memoized name partition in link_scan.scan_buffer_names.
--
-- scan_buffer_names runs on every autolink TextChanged. It partitions the entire
-- vault name+alias map into (multi_words sorted longest-first, single_set) before
-- the bounded line scan. That partition only changes when the vault index
-- generation changes or the autolink params (min_name_length / exclude_names)
-- change, so it is now memoized on (idx._generation, min_name_length,
-- exclude_names identity).
--
-- The correctness trap: the memo MUST invalidate when the index generation bumps,
-- else newly added notes never get autolinked (stale partition). This drives the
-- REAL link_scan + REAL vault_index against a temp vault (no mock) and asserts
-- observable behavior only:
--   1. names in the vault are scanned/matched (partition built correctly)
--   2. adding a note + reindex (generation bump) makes the new name match
--      (memo invalidates on generation change -> no stale partition)
--   3. a changed min_name_length yields a different match set on the same
--      generation (param-key invalidation)
--
-- Run with: nvim --headless -u NONE -l tests/link_scan_name_partition_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_true, assert_eq = _H.test, _H.assert_true, _H.assert_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vi = require("andrew.vault.vault_index")
local link_scan = require("andrew.vault.link_scan")

print("\n=== link_scan name partition memo Tests ===\n")

local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

-- Build a vault, build its index synchronously, and register it as the singleton
-- so scan_buffer_names (which reads vault_index.current()) sees it.
local function make_indexed_vault(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for rel, lines in pairs(files) do
    write_file(dir, rel, lines)
  end
  local idx = vi.VaultIndex.new(dir)
  idx:build_sync()
  vi._instance = idx
  return dir, idx
end

-- Load lines into a scratch buffer and return its bufnr.
local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- Collect the set of lowercased note_names matched in a buffer.
local function matched_names(buf, opts)
  local set = {}
  for _, m in ipairs(link_scan.scan_buffer_names(buf, opts)) do
    set[m.note_name] = true
  end
  return set
end

-- ===========================================================================
-- 1. Partition is built correctly: known vault names get matched.
-- ===========================================================================
test("scan matches existing vault note names", function()
  local _, _idx = make_indexed_vault({
    ["alpha note.md"] = { "# Alpha Note" },
    ["beta.md"] = { "# Beta" },
  })
  local buf = make_buffer({ "I reference alpha note and beta here." })
  local names = matched_names(buf)
  assert_true(names["alpha note"], "multi-word name 'alpha note' matched")
  assert_true(names["beta"], "single-word name 'beta' matched")
end)

-- ===========================================================================
-- 2. CORRECTNESS TRAP: a note added + reindexed (generation bump) is matched.
--    With a stale (non-invalidated) memo, the new name would never appear.
-- ===========================================================================
test("name added after a generation bump is matched (memo invalidates)", function()
  local dir, idx = make_indexed_vault({
    ["alpha note.md"] = { "# Alpha Note" },
  })
  local buf = make_buffer({ "mentions gamma and alpha note." })

  -- Prime the memo on the original generation: gamma not in vault yet.
  local before = matched_names(buf)
  assert_true(before["alpha note"], "alpha note matched on original generation")
  assert_true(not before["gamma"], "gamma not yet a vault name")

  -- Add a note and reindex it -> _generation bumps, name cache invalidates.
  local gen0 = idx._generation
  write_file(dir, "gamma.md", { "# Gamma" })
  idx:update_file(dir .. "/gamma.md")
  assert_true(idx._generation > gen0, "generation bumped after update_file")

  local after = matched_names(buf)
  assert_true(after["gamma"], "newly indexed 'gamma' is now matched (memo not stale)")
  assert_true(after["alpha note"], "alpha note still matched after rebuild")
end)

-- ===========================================================================
-- 3. Param-key invalidation: changing min_name_length on the same generation
--    produces a different match set (short names drop out).
-- ===========================================================================
test("min_name_length change re-partitions on same generation", function()
  make_indexed_vault({
    ["ab.md"] = { "# ab" },
    ["alpha.md"] = { "# alpha" },
  })
  local buf = make_buffer({ "ab and alpha here." })

  -- Default min 3: short name "ab" excluded, "alpha" included.
  local def = matched_names(buf)
  assert_true(not def["ab"], "ab excluded at default min_name_length (3)")
  assert_true(def["alpha"], "alpha included at default min_name_length")

  -- min 2 on the SAME generation: "ab" now passes the length gate.
  local lowered = matched_names(buf, { min_name_length = 2 })
  assert_true(lowered["ab"], "ab matched when min_name_length lowered to 2")
  assert_true(lowered["alpha"], "alpha still matched at min 2")
end)

-- ===========================================================================
-- 4. CORRECTNESS TRAP (cross-vault): a vault switch installs a FRESH VaultIndex
--    instance. The module-level memo MUST be keyed on the instance, not just on
--    a bare numeric generation: two vaults can sit at the same generation with
--    identical min_name_length / exclude_names identity, so without the instance
--    key the new vault would serve the previous vault's name partition.
-- ===========================================================================
test("vault switch (new instance) does not serve stale partition", function()
  -- Vault A, prime the memo against its names.
  local _, idxA = make_indexed_vault({ ["alpha note.md"] = { "# Alpha Note" } })
  local buf = make_buffer({ "alpha note and delta here." })
  local a = matched_names(buf)
  assert_true(a["alpha note"], "alpha note matched in vault A")
  assert_true(not a["delta"], "delta absent in vault A")
  local primed_gen = idxA._generation

  -- Switch to vault B: a fresh VaultIndex instance (replaces vi._instance), same
  -- global min_name_length / exclude_names identity. Force the generation to
  -- collide with vault A's primed generation so the INSTANCE key is the sole
  -- discriminator (proving the instance, not the gen, invalidates the memo).
  local _, idxB = make_indexed_vault({ ["delta.md"] = { "# Delta" } })
  idxB._generation = primed_gen
  local b = matched_names(buf)
  assert_true(b["delta"], "delta matched in vault B (memo keyed on instance)")
  assert_true(not b["alpha note"], "vault A's 'alpha note' no longer matched")
end)

_H.finish({ style = "results", exit = "os" })
