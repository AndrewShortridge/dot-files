-- Behavioral spec for the incremental (partial) query-index update.
--
-- The query index used to rebuild EVERY page on the first :VaultQuery after any
-- save: build_from_vault_index() clears self.pages and re-runs _entry_to_page
-- for all entries (re-parsing all frontmatter/inline scalars, re-converting all
-- outlinks) plus a full inlink repopulation. apply_partial() now re-converts
-- only the changed/added/deleted pages, then refreshes inlinks for every page
-- from the vault index (the single source of truth, maintained incrementally).
--
-- The non-obvious correctness requirement this spec guards: when file A changes
-- a wikilink, the LINK TARGET page (B or C) — which is itself untouched and not
-- in changed_paths — gains/loses an inlink in the vault index. A partial update
-- that refreshed inlinks only for the changed file would leave the target's
-- query page stale. apply_partial therefore re-reads inlinks for ALL pages, so
-- its result is identical to a fresh full build_from_vault_index().
--
-- Drives the REAL vault_index + real query/index against a temp vault (no mock),
-- per repo conventions.
--
-- Run with: nvim --headless -u NONE -l tests/query_index_partial_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vault_index = require("andrew.vault.vault_index")
local QI = require("andrew.vault.query.index")

print("\n=== Query Index Partial Update Tests ===\n")

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

-- A links to B (only). C is unlinked. Plus a frontmatter/inline field on A so we
-- can confirm the touched page's scalars are re-parsed correctly after partial.
local function make_vault()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir, "A.md", {
    "---",
    "title: Alpha",
    "priority: 1",
    "---",
    "",
    "Links to [[B]].",
    "",
    "status:: draft",
  })
  write_file(dir, "B.md", { "---", "title: Bravo", "---", "", "Plain B." })
  write_file(dir, "C.md", { "---", "title: Charlie", "---", "", "Plain C." })
  return dir
end

-- Build a fresh vault index over `dir`, set it as the current instance (so
-- query/index's vault_index.current() resolves to it), and return it.
local function fresh_vi(dir)
  vault_index._instance = nil
  local idx = vault_index.get(dir)
  idx:build_sync()
  return idx
end

-- Collect the set of inlink source stems on a query page.
local function inlink_stems(page)
  local out = {}
  for _, l in ipairs(page.file.inlinks) do
    out[l.path] = true
  end
  return out
end

-- Build a full query index and a partially-updated one over the same post-change
-- vault index, then assert their inlink sets match for each page.
local function assert_inlinks_match_full(vi, partial_idx, rel_paths)
  local full = QI.Index.new(vi.vault_path)
  full:build_from_vault_index()
  for _, rp in ipairs(rel_paths) do
    local fp, pp = full.pages[rp], partial_idx.pages[rp]
    if fp == nil and pp == nil then
      -- both absent: consistent
    else
      assert_true(fp ~= nil, "full build missing page " .. rp)
      assert_true(pp ~= nil, "partial build missing page " .. rp)
      local fset, pset = inlink_stems(fp), inlink_stems(pp)
      for k in pairs(fset) do
        assert_true(pset[k], "partial page " .. rp .. " missing inlink from " .. k)
      end
      for k in pairs(pset) do
        assert_true(fset[k], "partial page " .. rp .. " has extra inlink from " .. k)
      end
    end
  end
end

-- ===========================================================================
-- 1. Editing A to also link C gives C an inlink (its page was NOT changed).
-- ===========================================================================
test("partial update: new link target gains an inlink, identical to full build", function()
  local dir = make_vault()
  local vi = fresh_vi(dir)

  -- Full initial query index.
  local q = QI.Index.new(dir)
  q:build_from_vault_index()

  -- Baseline: C has no inlinks, B has one (from A).
  assert_nil(next(inlink_stems(q.pages["C.md"])), "C starts with no inlinks")
  assert_true(inlink_stems(q.pages["B.md"])["A"], "B starts with inlink from A")

  -- Edit A so it now links to BOTH B and C, and changes a scalar field.
  write_file(dir, "A.md", {
    "---",
    "title: Alpha",
    "priority: 2",
    "---",
    "",
    "Links to [[B]] and [[C]].",
    "",
    "status:: final",
  })
  vi:update_file(dir .. "/A.md")

  -- The vault index must have produced a non-full partial context.
  local ctx = vi._last_inv_ctx
  assert_true(ctx ~= nil, "update produced an invalidation context")
  assert_true(ctx.tier ~= "full", "single-file edit is a non-full tier (was: " .. tostring(ctx.tier) .. ")")

  q:update_incremental(vi, ctx)

  -- C — an untouched link TARGET — must now carry an inlink from A.
  assert_true(inlink_stems(q.pages["C.md"])["A"], "C gains inlink from A after partial update")
  assert_true(inlink_stems(q.pages["B.md"])["A"], "B keeps its inlink from A")

  -- The touched page's re-parsed scalar fields round-trip.
  assert_eq(q.pages["A.md"].priority, 2, "A.priority re-parsed to new value")
  assert_eq(q.pages["A.md"].status, "final", "A inline status re-parsed to new value")

  -- And the partial result is identical to a fresh full rebuild.
  assert_inlinks_match_full(vi, q, { "A.md", "B.md", "C.md" })
end)

-- ===========================================================================
-- 2. Deleting A removes the inlink from B (and C, once it linked there too).
-- ===========================================================================
test("partial update: deleting a source removes inlinks from its targets", function()
  local dir = make_vault()
  -- Start from the "A links B and C" state so both targets have an A inlink.
  write_file(dir, "A.md", {
    "---", "title: Alpha", "---", "",
    "Links to [[B]] and [[C]].",
  })
  local vi = fresh_vi(dir)

  local q = QI.Index.new(dir)
  q:build_from_vault_index()
  assert_true(inlink_stems(q.pages["B.md"])["A"], "B has inlink from A before delete")
  assert_true(inlink_stems(q.pages["C.md"])["A"], "C has inlink from A before delete")

  -- Delete A from disk and from the index.
  os.remove(dir .. "/A.md")
  vi:update_file(dir .. "/A.md")

  local ctx = vi._last_inv_ctx
  assert_true(ctx ~= nil and ctx.tier ~= "full", "delete is a non-full tier")

  q:update_incremental(vi, ctx)

  assert_nil(q.pages["A.md"], "A page removed after delete")
  assert_nil(inlink_stems(q.pages["B.md"])["A"], "B no longer has inlink from A")
  assert_nil(inlink_stems(q.pages["C.md"])["A"], "C no longer has inlink from A")

  assert_inlinks_match_full(vi, q, { "A.md", "B.md", "C.md" })
end)

-- ===========================================================================
-- 3. Discriminating power: a partial that refreshes inlinks ONLY for changed
--    files (skipping untouched targets) MUST produce a stale, wrong result.
--    This proves the all-pages inlink refresh in apply_partial is load-bearing.
-- ===========================================================================
test("a target-skipping partial would leave a stale inlink (proves the guard)", function()
  local dir = make_vault()
  local vi = fresh_vi(dir)

  local q = QI.Index.new(dir)
  q:build_from_vault_index()

  -- Edit A to ALSO link C.
  write_file(dir, "A.md", {
    "---", "title: Alpha", "---", "",
    "Links to [[B]] and [[C]].",
  })
  vi:update_file(dir .. "/A.md")
  local ctx = vi._last_inv_ctx

  -- Simulate the WRONG (naive) partial: re-convert only touched pages and
  -- refresh inlinks ONLY for those same touched paths, never the targets.
  local files = vi:snapshot_files()
  for _, rp in ipairs(ctx.changed_paths or {}) do
    if files[rp] then q.pages[rp] = q:_entry_to_page(files[rp]) end
    q:_populate_inlinks_for(vi, rp)
  end

  -- C's page was NOT touched, so the naive partial leaves it stale: no inlink.
  assert_nil(inlink_stems(q.pages["C.md"])["A"],
    "naive (target-skipping) partial leaves C's inlink stale — this is the bug")

  -- The correct apply_partial fixes it.
  q:apply_partial(vi, ctx)
  assert_true(inlink_stems(q.pages["C.md"])["A"],
    "apply_partial repairs C's inlink (all-pages refresh)")
end)

-- ===========================================================================
-- Summary
-- ===========================================================================
_H.finish({ style = "results", exit = "os" })
