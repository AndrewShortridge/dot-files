-- Perf regression spec for incremental inlink recomputation.
--
-- THE BUG (now fixed): vault_index_inlinks.recompute_incremental Phase 1 used
--   for target_rel, inlink_list in pairs(inlinks) do ... end
-- which visits EVERY target in the vault's _inlinks map on every single-file
-- save (O(all edges in vault)) just to splice out the one changed source. The
-- fix maintains a reverse map (source_stem -> target_rel set) so Phase 1 visits
-- ONLY the targets the changed source contributed to (O(edges-from-changed-file)).
--
-- DISCRIMINATING POWER: the spec monkeypatches the GLOBAL `pairs` to count how
-- many entries are yielded when iterating the _inlinks map itself. With the fix,
-- Phase 1 indexes inlinks[target_rel] by key (never pairs() over the whole map),
-- so the visited count is O(1) and does NOT grow with vault size M. Reintroduce
-- the old `for ... in pairs(inlinks)` full sweep and `visited` jumps to ~M,
-- failing the `visited` threshold and the "does not grow with M" assertion.
-- (Runtime is LuaJIT 2.1 / Lua 5.1: __pairs is NOT honored, so patching the
-- global `pairs` reliably intercepts the module's direct `pairs` reference.)
--
-- It also cross-checks correctness: an unrelated save leaves every target's
-- inlinks unchanged, and dropping ONE source's link removes the inlink from
-- exactly that target while a sibling keeps its own — proving the reverse map
-- produces byte-identical inlink results.
--
-- Drives the REAL vault_index against a temp vault (no mocks, no introspection).
--
-- Run with: nvim --headless -u NONE -l tests/inlinks_incremental_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vault_index = require("andrew.vault.vault_index")

print("\n=== Inlinks Incremental Perf Tests ===\n")

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

local function pad(n)
  return string.format("%03d", n)
end

-- Build a vault of M targets, each with a dedicated source linking only to it
-- (so _inlinks has M target lists, each with one inlink), plus one unrelated
-- file that links to nothing and serves as a benign save target.
local function make_vault(M)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for i = 1, M do
    local t = "target_" .. pad(i)
    local s = "source_" .. pad(i)
    write_file(dir, t .. ".md", { "# " .. t, "", "Body." })
    write_file(dir, s .. ".md", { "Links to [[" .. t .. "]]." })
  end
  write_file(dir, "unrelated.md", { "Nothing here." })
  return dir
end

local function fresh_vi(dir)
  vault_index._instance = nil
  local idx = vault_index.get(dir)
  idx:build_sync()
  return idx
end

-- Run an unrelated save over a vault of size M and return how many entries were
-- yielded while iterating the _inlinks map itself during the save.
local function measure_visited(M)
  local dir = make_vault(M)
  local idx = fresh_vi(dir)

  -- Sanity: every target carries its source's inlink (M target lists present).
  assert_eq(#idx:get_inlinks("target_" .. pad(1) .. ".md"), 1, "target 1 has 1 inlink pre-save")
  assert_eq(#idx:get_inlinks("target_" .. pad(M) .. ".md"), 1, "target M has 1 inlink pre-save")

  local inlinks_tbl = idx._inlinks -- capture identity BEFORE the save
  local real_pairs = pairs
  local visited = 0
  _G.pairs = function(t)
    if t == inlinks_tbl then
      local it, s, k = real_pairs(t)
      return function(st, key)
        local nk, nv = it(st, key)
        if nk ~= nil then visited = visited + 1 end
        return nk, nv
      end, s, k
    end
    return real_pairs(t)
  end

  local ok, err = pcall(function()
    write_file(dir, "unrelated.md", { "Nothing here.", "", "An extra line." })
    idx:update_file(dir .. "/unrelated.md")
  end)

  _G.pairs = real_pairs -- restore no matter what
  if not ok then error(err) end

  -- _inlinks table identity must be preserved on the incremental path.
  assert_true(idx._inlinks == inlinks_tbl, "incremental save mutates _inlinks in place (identity stable)")

  return visited, idx, dir
end

-- ===========================================================================
-- 1. O(1) visited count, independent of vault size M.
-- ===========================================================================
test("Phase 1 does not sweep the whole _inlinks map (O(1) not O(M))", function()
  local v_small = measure_visited(50)
  local v_large = measure_visited(200)

  -- unrelated.md links to nothing, so its reverse set is empty; Phase 1 never
  -- iterates the _inlinks map. Allow a tiny constant slack for safety.
  assert_true(v_small <= 2, "small vault: visited <= 2 (got " .. v_small .. ")")
  assert_true(v_large <= 2, "large vault: visited <= 2 (got " .. v_large .. ")")

  -- The discriminator: the count must NOT grow with M. Under the old full
  -- sweep, v_small ~= 50 and v_large ~= 200.
  assert_true(v_large <= v_small + 1,
    "visited does not grow with M (small=" .. v_small .. ", large=" .. v_large .. ")")
end)

-- ===========================================================================
-- 2. Correctness: an unrelated save leaves all target inlinks intact.
-- ===========================================================================
test("unrelated save preserves every target's inlinks", function()
  local _, idx = measure_visited(50)
  for i = 1, 50 do
    local list = idx:get_inlinks("target_" .. pad(i) .. ".md")
    assert_eq(#list, 1, "target " .. i .. " keeps its single inlink")
    assert_eq(list[1].path, "source_" .. pad(i), "target " .. i .. " inlink is from its source")
  end
end)

-- ===========================================================================
-- 3. Correctness: dropping one source's link removes only that target's inlink.
-- ===========================================================================
test("editing one source updates only its target, reverse map stays correct", function()
  local dir = make_vault(20)
  local idx = fresh_vi(dir)

  assert_eq(#idx:get_inlinks("target_" .. pad(5) .. ".md"), 1, "target 5 starts with one inlink")
  assert_eq(#idx:get_inlinks("target_" .. pad(6) .. ".md"), 1, "target 6 starts with one inlink")

  -- source_005 stops linking to target_005.
  write_file(dir, "source_005.md", { "No links anymore." })
  idx:update_file(dir .. "/source_005.md")

  assert_eq(#idx:get_inlinks("target_" .. pad(5) .. ".md"), 0, "target 5 lost its inlink")
  assert_nil(idx._inlinks["target_005.md"], "empty inlink list removed for target 5")
  assert_eq(#idx:get_inlinks("target_" .. pad(6) .. ".md"), 1, "sibling target 6 keeps its inlink")

  -- Re-add the link: it must come back identically.
  write_file(dir, "source_005.md", { "Links to [[target_005]] again." })
  idx:update_file(dir .. "/source_005.md")
  local list = idx:get_inlinks("target_" .. pad(5) .. ".md")
  assert_eq(#list, 1, "target 5 inlink restored")
  assert_eq(list[1].path, "source_005", "restored inlink is from source_005")
end)

-- ===========================================================================
-- Summary
-- ===========================================================================
_H.finish({ style = "results", exit = "os" })
