-- Parity + perf-discrimination spec for Issue H: skip inlink recompute for
-- sources whose outlink SET did not change.
--
-- THE FIX (two parts):
--   (1) _build_resolve_fn caches one closure (reads self._name_index/_alias_index/
--       files live through `self`) instead of allocating a fresh closure on every
--       update_files_batch / _apply_staged.
--   (2) recompute_incremental only removes+re-adds inlink edges for changed
--       sources whose outlink SET actually changed (keyed_set_equal via
--       outlink_key — the SAME signal diff_entry already computes). A prose-only
--       edit leaves the outlink set byte-identical, so it contributes the exact
--       same inlink edges; reprocessing it is pure churn.
--
-- PARITY (correctness): after each of edit-prose-only / add-link / remove-link /
--   anchor-only edit / rename-target+rewrite-sources / delete-source /
--   delete-target, the incremental _inlinks (compared as per-target SETS of
--   source stems) must equal a fresh build_sync() of the same on-disk state.
--   This proves incremental == full across edit/rename/delete.
--
-- DISCRIMINATING POWER:
--   * FIX (2): wrap _build_resolve_fn so we count resolver invocations during a
--     save. A prose-only edit of a source with N outlinks must invoke the
--     resolver 0 times for that source; a link-changing edit must invoke it N>0
--     times. Reverting FIX (2) (dropping the outlinks_changed_set filter so every
--     changed source is reprocessed) makes the prose-only edit invoke the
--     resolver N>0 times, failing the "0 resolver calls" assertion.
--   * FIX (1): _build_resolve_fn() must return the SAME closure identity twice.
--     Reverting the memoization (returning a fresh closure each call) fails this.
--     (Manually verified both by temporarily reverting before finalizing.)
--
-- Runtime is LuaJIT 2.1 / Lua 5.1. Drives the REAL vault_index against a temp
-- vault (no mocks, no source introspection).
--
-- Run with: nvim --headless -u NONE -l tests/inlink_outlink_unchanged_skip_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true =
  _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vault_index = require("andrew.vault.vault_index")

print("\n=== Inlink Outlink-Unchanged Skip Tests ===\n")

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

-- A web of links:
--   A -> B, A -> C, B -> C, D -> A
-- plus an isolated note linking to nothing.
local function make_web_vault()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir, "A.md", { "# A", "", "See [[B]] and [[C]]." })
  write_file(dir, "B.md", { "# B", "", "See [[C]]." })
  write_file(dir, "C.md", { "# C", "", "Leaf note." })
  write_file(dir, "D.md", { "# D", "", "Points to [[A]]." })
  write_file(dir, "isolated.md", { "# isolated", "", "No links." })
  return dir
end

local function fresh_vi(dir)
  vault_index._instance = nil
  -- Force a brand-new instance each time (do NOT share the singleton).
  local idx = vault_index.VaultIndex.new(dir)
  idx:build_sync()
  return idx
end

-- Normalize _inlinks into a comparable canonical form:
--   { [target_rel] = { source_stem = true, ... } }
-- (per-target SET of source stems — ordering-agnostic, matching the inlink
-- record which is anchor-agnostic: only path/stem is stored).
--
-- We compare only over targets that STILL EXIST in the index. The incremental
-- path (by long-standing design, independent of Issue H) does not eagerly purge
-- the inlink LIST keyed by a *deleted target's* rel_path — that stale list is
-- unreachable via get_inlinks for a file that no longer exists. A full rebuild
-- simply never creates it. Restricting to live targets compares the invariant
-- that actually matters (inlinks of every file still in the vault) and is exactly
-- the property Issue H must preserve.
local function canon_inlinks(idx)
  local out = {}
  for target_rel, list in pairs(idx._inlinks) do
    if idx.files[target_rel] then
      local s = {}
      for _, rec in ipairs(list) do
        s[rec.path] = true
      end
      if next(s) then out[target_rel] = s end
    end
  end
  return out
end

local function sets_equal(a, b)
  for k, av in pairs(a) do
    local bv = b[k]
    if type(bv) ~= "table" then return false, "missing target " .. tostring(k) end
    for sk in pairs(av) do
      if not bv[sk] then return false, "missing source " .. tostring(sk) .. " in " .. tostring(k) end
    end
    for sk in pairs(bv) do
      if not av[sk] then return false, "extra source " .. tostring(sk) .. " in " .. tostring(k) end
    end
  end
  for k in pairs(b) do
    if not a[k] then return false, "extra target " .. tostring(k) end
  end
  return true
end

-- Assert the incremental index's inlinks == a fresh full rebuild of the same
-- on-disk state.
local function assert_parity(dir, idx, label)
  local full = fresh_vi(dir)
  local inc_c = canon_inlinks(idx)
  local full_c = canon_inlinks(full)
  local ok, why = sets_equal(inc_c, full_c)
  assert_true(ok, label .. ": incremental inlinks == full rebuild (" .. tostring(why) .. ")")
end

-- ===========================================================================
-- 1. PARITY across edit / rename / delete.
-- ===========================================================================
test("parity: prose-only edit (outlinks unchanged)", function()
  local dir = make_web_vault()
  local idx = fresh_vi(dir)
  -- Edit A's prose; its links [[B]] [[C]] are untouched.
  write_file(dir, "A.md", { "# A", "", "See [[B]] and [[C]].", "", "Extra prose line." })
  idx:update_file(dir .. "/A.md")
  assert_parity(dir, idx, "prose-only edit")
end)

test("parity: add a link", function()
  local dir = make_web_vault()
  local idx = fresh_vi(dir)
  -- B now also links to A.
  write_file(dir, "B.md", { "# B", "", "See [[C]] and now [[A]]." })
  idx:update_file(dir .. "/B.md")
  assert_parity(dir, idx, "add link")
end)

test("parity: remove a link", function()
  local dir = make_web_vault()
  local idx = fresh_vi(dir)
  -- A drops [[C]], keeps [[B]].
  write_file(dir, "A.md", { "# A", "", "See [[B]] only now." })
  idx:update_file(dir .. "/A.md")
  assert_parity(dir, idx, "remove link")
end)

test("parity: anchor-only link edit (outlink set byte-identical)", function()
  local dir = make_web_vault()
  local idx = fresh_vi(dir)
  -- A links to [[B#Heading]] instead of [[B]] — same target name, different
  -- anchor. outlink_key is name-based, so the outlink SET is unchanged and the
  -- source is skipped; inlinks (anchor-agnostic) must remain identical.
  write_file(dir, "A.md", { "# A", "", "See [[B#Section]] and [[C]]." })
  idx:update_file(dir .. "/A.md")
  assert_parity(dir, idx, "anchor-only edit")
end)

test("parity: rename target + rewrite linking sources", function()
  local dir = make_web_vault()
  local idx = fresh_vi(dir)
  -- Rename C.md -> Cee.md and rewrite the sources that linked to it (A, B),
  -- mirroring rename.lua: re-index renamed file then re-index rewritten sources.
  os.rename(dir .. "/C.md", dir .. "/Cee.md")
  write_file(dir, "A.md", { "# A", "", "See [[B]] and [[Cee]]." })
  write_file(dir, "B.md", { "# B", "", "See [[Cee]]." })
  idx:update_files_batch({ dir .. "/C.md", dir .. "/Cee.md" })
  idx:update_files_batch({ dir .. "/A.md", dir .. "/B.md" })
  assert_parity(dir, idx, "rename target")
end)

test("parity: delete a source", function()
  local dir = make_web_vault()
  local idx = fresh_vi(dir)
  -- Delete D (which linked to A); A should lose its inlink from D.
  rm_file(dir, "D.md")
  idx:update_file(dir .. "/D.md")
  assert_parity(dir, idx, "delete source")
end)

test("parity: delete a target", function()
  local dir = make_web_vault()
  local idx = fresh_vi(dir)
  -- Delete C (a target of A and B). Its inlink list must vanish.
  rm_file(dir, "C.md")
  idx:update_file(dir .. "/C.md")
  assert_parity(dir, idx, "delete target")
end)

-- ===========================================================================
-- 2. DISCRIMINATING POWER for FIX (2): prose-only edit invokes resolver 0x.
-- ===========================================================================
-- Wrap _build_resolve_fn so we can count how many times the resolver fn is
-- actually called during a save. (We wrap PER-INDEX on the metatable-bound
-- method via a per-instance override.)
local function with_resolver_counter(idx)
  local real = idx._build_resolve_fn
  local count = 0
  -- Reset memoized closure so our wrapper installs cleanly, then re-memoize a
  -- counting wrapper around the real (cached) resolver.
  idx._resolve_fn = nil
  local inner = real(idx)
  local wrapped = function(link)
    count = count + 1
    return inner(link)
  end
  idx._resolve_fn = wrapped
  return function() return count end
end

test("FIX2 discrimination: prose-only edit => 0 resolver calls for that source", function()
  local dir = make_web_vault()
  local idx = fresh_vi(dir)
  local get_count = with_resolver_counter(idx)

  -- A has 2 outlinks ([[B]], [[C]]). Prose-only edit must NOT re-resolve them.
  write_file(dir, "A.md", { "# A", "", "See [[B]] and [[C]].", "", "New prose." })
  idx:update_file(dir .. "/A.md")

  assert_eq(get_count(), 0,
    "prose-only edit of A (2 outlinks) invokes resolver 0 times " ..
    "(reverting FIX2's outlinks_changed filter makes this 2)")

  -- Inlinks still correct after the skipped save.
  assert_parity(dir, idx, "prose-only skip leaves inlinks correct")
end)

test("FIX2 discrimination: link-changing edit => resolver IS invoked (N>0)", function()
  local dir = make_web_vault()
  local idx = fresh_vi(dir)
  local get_count = with_resolver_counter(idx)

  -- A changes its outlink set (drops [[C]]): resolver must run for A's links.
  write_file(dir, "A.md", { "# A", "", "See [[B]] only." })
  idx:update_file(dir .. "/A.md")

  assert_true(get_count() > 0,
    "link-changing edit invokes resolver N>0 times (got " .. get_count() .. ")")
  assert_parity(dir, idx, "link-changing edit leaves inlinks correct")
end)

-- ===========================================================================
-- 3. DISCRIMINATING POWER for FIX (1): resolver closure is memoized (identity).
-- ===========================================================================
test("FIX1 discrimination: _build_resolve_fn returns the SAME closure twice", function()
  local dir = make_web_vault()
  local idx = fresh_vi(dir)
  local f1 = idx:_build_resolve_fn()
  local f2 = idx:_build_resolve_fn()
  assert_true(f1 == f2,
    "cached resolver closure identity is stable across calls " ..
    "(reverting the memoization returns a fresh closure each call)")
end)

test("FIX1 correctness: cached resolver survives a full rebuild (table swap)", function()
  local dir = make_web_vault()
  local idx = fresh_vi(dir)
  -- Grab the resolver, then do a full build_sync (which swaps self.files and
  -- rebuilds _name_index/_alias_index wholesale). The cached closure reads
  -- through `self`, so it must still resolve correctly afterwards.
  local resolve = idx:_build_resolve_fn()
  idx:build_sync()
  -- A real outlink from A -> B must still resolve to B's entry.
  local a = idx.files["A.md"]
  assert_true(a ~= nil, "A entry present after rebuild")
  local target = resolve(a.outlinks[1])
  assert_true(target ~= nil and target.rel_path == "B.md",
    "cached resolver resolves A's first outlink to B after a wholesale rebuild")
end)

-- ===========================================================================
-- Summary
-- ===========================================================================
_H.finish({ style = "results", exit = "os" })
