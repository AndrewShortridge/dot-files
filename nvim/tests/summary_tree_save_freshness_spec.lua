-- Freshness + parity + perf-discrimination spec for Issue 6: keep the summary
-- tree fresh on every save.
--
-- THE BUG: update_files_batch() (run on BufWritePost / fs-watcher flush) updated
--   _name_index / _inlinks / _precomputed_sets incrementally but NEVER touched
--   _summary_tree. So all_tags() / tags_with_counts() / all_frontmatter_keys() /
--   all_inline_field_keys() (all served by _summary_tree:query("")) returned STALE
--   results after a save that added/removed a tag, frontmatter key, or inline-field
--   key — until the next full build_async().
--
-- THE FIX: SummaryTree:apply_delta(rel_path, old_entry, new_entry) applies a
--   per-field +new -old delta along the ancestor chain (with empty-bucket pruning),
--   wired into update_files_batch for each changed/deleted path. It is
--   O(depth * fields-changed) — NOT the O(N-vault) sibling sweep of
--   _recompute_ancestors / compose_summaries.
--
-- FRESHNESS (correctness): after an incremental save, the summary-tree-backed
--   accessors must immediately reflect added/removed tags, frontmatter keys, and
--   inline-field keys — with no rebuild.
--
-- DISCRIMINATING POWER:
--   * Reverting the apply_delta wiring leaves the tree stale, so the "new tag
--     appears immediately" assertion fails. (Verified by temporarily removing the
--     wiring before finalizing.)
--   * PERF: a single-file save must NOT invoke _recompute_ancestors (the O(N)
--     sibling-sweep path) even with many root-level siblings present. We count
--     _recompute_ancestors invocations during a save and assert 0.
--
-- PARITY (incremental == full): after each incremental save, the accessors must
--   equal a fresh build_sync() of the same on-disk state.
--
-- Runtime is LuaJIT 2.1 / Lua 5.1. Drives the REAL vault_index against a temp
-- vault (no mocks, no source introspection).
--
-- Run with: nvim --headless -u NONE -l tests/summary_tree_save_freshness_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vault_index = require("andrew.vault.vault_index")

print("\n=== Summary Tree Save-Freshness Tests ===\n")

-- ---------------------------------------------------------------------------
-- Temp vault helpers.
-- ---------------------------------------------------------------------------
local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

local function rm_file(dir, rel)
  os.remove(dir .. "/" .. rel)
end

local function make_vault()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir, "A.md", { "---", "status: open", "---", "# A", "", "#alpha note." })
  write_file(dir, "B.md", { "# B", "", "#beta and [stage:: draft] here." })
  write_file(dir, "C.md", { "# C", "", "Leaf note." })
  return dir
end

local function fresh_vi(dir)
  vault_index._instance = nil
  local idx = vault_index.VaultIndex.new(dir)
  idx:build_sync()
  return idx
end

local function has(list, val)
  for _, v in ipairs(list) do
    if v == val then return true end
  end
  return false
end

-- ===========================================================================
-- 1. FRESHNESS: tags / fm keys / inline keys are fresh immediately after save.
-- ===========================================================================
test("freshness: adding a tag appears in all_tags()/tags_with_counts() immediately", function()
  local dir = make_vault()
  local idx = fresh_vi(dir)
  assert_false(has(idx:all_tags(), "gamma"), "gamma absent before save")

  -- C gains a new tag.
  write_file(dir, "C.md", { "# C", "", "Now tagged #gamma." })
  idx:update_file(dir .. "/C.md")

  assert_true(has(idx:all_tags(), "gamma"),
    "gamma in all_tags() immediately after save (stale tree fails here)")
  assert_eq(idx:tags_with_counts()["gamma"], 1,
    "tags_with_counts()[gamma] == 1 immediately after save")
end)

test("freshness: removing a tag drops it (empty-bucket pruning)", function()
  local dir = make_vault()
  local idx = fresh_vi(dir)
  assert_true(has(idx:all_tags(), "alpha"), "alpha present before save")

  -- A drops its only tag.
  write_file(dir, "A.md", { "---", "status: open", "---", "# A", "", "no tag now." })
  idx:update_file(dir .. "/A.md")

  assert_false(has(idx:all_tags(), "alpha"),
    "alpha gone from all_tags() after removal (no empty-bucket pruning fails here)")
  assert_eq(idx:tags_with_counts()["alpha"], nil,
    "tags_with_counts()[alpha] pruned to nil after removal")
end)

test("freshness: adding a frontmatter key appears in all_frontmatter_keys()", function()
  local dir = make_vault()
  local idx = fresh_vi(dir)
  assert_false(has(idx:all_frontmatter_keys(), "priority"), "priority key absent before save")

  write_file(dir, "A.md", { "---", "status: open", "priority: 1", "---", "# A", "", "#alpha note." })
  idx:update_file(dir .. "/A.md")

  assert_true(has(idx:all_frontmatter_keys(), "priority"),
    "priority in all_frontmatter_keys() immediately after save")
end)

test("freshness: adding an inline-field key appears in all_inline_field_keys()", function()
  local dir = make_vault()
  local idx = fresh_vi(dir)
  assert_false(has(idx:all_inline_field_keys(), "owner"), "owner key absent before save")

  write_file(dir, "C.md", { "# C", "", "Leaf note. [owner:: andrew]" })
  idx:update_file(dir .. "/C.md")

  assert_true(has(idx:all_inline_field_keys(), "owner"),
    "owner in all_inline_field_keys() immediately after save")
end)

test("freshness: deleting a file removes its tag contribution", function()
  local dir = make_vault()
  local idx = fresh_vi(dir)
  assert_true(has(idx:all_tags(), "beta"), "beta present before delete")

  rm_file(dir, "B.md")
  idx:update_file(dir .. "/B.md")

  assert_false(has(idx:all_tags(), "beta"),
    "beta gone after file delete (delete path must apply_delta too)")
end)

-- ===========================================================================
-- 2. PARITY: incremental accessors == a fresh full rebuild.
-- ===========================================================================
local function canon_counts(idx)
  return {
    tags = idx:all_tags(),
    fm = idx:all_frontmatter_keys(),
    inline = idx:all_inline_field_keys(),
    counts = idx:tags_with_counts(),
  }
end

local function assert_parity(dir, idx, label)
  local full = fresh_vi(dir)
  local a, b = canon_counts(idx), canon_counts(full)
  assert_true(_H.deep_equal(a.tags, b.tags), label .. ": all_tags() == full rebuild")
  assert_true(_H.deep_equal(a.fm, b.fm), label .. ": all_frontmatter_keys() == full rebuild")
  assert_true(_H.deep_equal(a.inline, b.inline), label .. ": all_inline_field_keys() == full rebuild")
  assert_true(_H.deep_equal(a.counts, b.counts), label .. ": tags_with_counts() == full rebuild")
end

test("parity: add tag + fm key + inline key in one save", function()
  local dir = make_vault()
  local idx = fresh_vi(dir)
  write_file(dir, "C.md", { "---", "kind: log", "---", "# C", "", "#gamma [owner:: a]" })
  idx:update_file(dir .. "/C.md")
  assert_parity(dir, idx, "multi-field add")
end)

test("parity: remove tag then delete", function()
  local dir = make_vault()
  local idx = fresh_vi(dir)
  write_file(dir, "B.md", { "# B", "", "tag gone now." })
  idx:update_file(dir .. "/B.md")
  rm_file(dir, "A.md")
  idx:update_file(dir .. "/A.md")
  assert_parity(dir, idx, "remove + delete")
end)

-- ===========================================================================
-- 3. DISCRIMINATING POWER (perf): a single save must NOT invoke the O(N)
--    _recompute_ancestors sibling-sweep path, even with many siblings.
-- ===========================================================================
test("perf: single save invokes _recompute_ancestors 0 times (no O(N) sweep)", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  -- Many root-level siblings: a sweep would re-merge all of them.
  for i = 1, 50 do
    write_file(dir, "n" .. i .. ".md", { "# n" .. i, "", "#t" .. i })
  end
  local idx = fresh_vi(dir)

  -- Count _recompute_ancestors invocations on the live tree instance.
  local tree = idx._summary_tree
  local real = tree._recompute_ancestors
  local sweeps = 0
  tree._recompute_ancestors = function(self, ...)
    sweeps = sweeps + 1
    return real(self, ...)
  end

  write_file(dir, "n1.md", { "# n1", "", "#t1 #brandnew" })
  idx:update_file(dir .. "/n1.md")

  tree._recompute_ancestors = real -- restore

  assert_eq(sweeps, 0,
    "incremental save uses apply_delta, not the O(N) _recompute_ancestors sweep " ..
    "(a naive full-recompute fix makes this > 0)")
  -- And the result is still correct.
  assert_true(has(idx:all_tags(), "brandnew"), "brandnew tag present after delta save")
end)

-- ===========================================================================
-- Summary
-- ===========================================================================
_H.finish({ style = "results", exit = "os" })
