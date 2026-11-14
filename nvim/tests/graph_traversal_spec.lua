-- Unit tests for vault graph traversal modules:
--   andrew.vault.bfs (core BFS over synthetic index stub)
--   andrew.vault.search_filter.graph_traversal (precompute_graph_sets, ast_contains_graph)
--   andrew.vault.graph_filter.traversal (collect_at_depth_async + BFS cache)
--   andrew.vault.connections (compute scoring breakdown)
--   andrew.vault.filter_utils (pure helpers)
--   andrew.vault.graph.collect (disambiguate_names)
-- Run with: nvim --headless -u NONE -l tests/graph_traversal_spec.lua

local _SRCDIR = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]")
local _H = dofile(_SRCDIR .. "/spec_helper.lua")
local _F = dofile(_SRCDIR .. "/fixtures.lua")
local test, assert_eq, assert_true, assert_false, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_false, _H.assert_nil

local function assert_close(got, expected, msg)
  if type(got) ~= "number" or math.abs(got - expected) > 1e-9 then
    error((msg or "") .. " expected ~" .. tostring(expected) .. ", got: " .. vim.inspect(got))
  end
end

--- Compare the sorted keys of a set against an expected sorted list.
local function assert_set_keys(set, expected, msg)
  local keys = {}
  for k in pairs(set) do keys[#keys + 1] = k end
  table.sort(keys)
  assert_eq(table.concat(keys, ","), table.concat(expected, ","), msg)
end

--- Extract .name fields from a node list, sorted.
local function sorted_names(nodes)
  local names = {}
  for _, n in ipairs(nodes) do names[#names + 1] = n.name end
  table.sort(names)
  return table.concat(names, ",")
end

-- ============================================================================
-- Load modules under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;"
  .. vim.fn.stdpath("config") .. "/lua/?/init.lua;" .. package.path

local bfs = require("andrew.vault.bfs")
local fu = require("andrew.vault.filter_utils")
local gt = require("andrew.vault.search_filter.graph_traversal")
local trav = require("andrew.vault.graph_filter.traversal")
local collect = require("andrew.vault.graph.collect")
local connections = require("andrew.vault.connections")
local vault_index = require("andrew.vault.vault_index")
local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

print("\n=== Graph Traversal Tests ===\n")

-- ============================================================================
-- 1. bfs.traverse over a synthetic index stub (pure, no filesystem)
--    Graph: A -> B -> C -> D, plus A -> E
-- ============================================================================

local stub_entries = {
  ["A.md"] = { outlinks = { { path = "B" }, { path = "E" } } },
  ["B.md"] = { outlinks = { { path = "C" } } },
  ["C.md"] = { outlinks = { { path = "D" } } },
  ["D.md"] = { outlinks = {} },
  ["E.md"] = { outlinks = {} },
}

local stub_inlinks = {
  ["B.md"] = { { path = "A" } },
  ["C.md"] = { { path = "B" } },
  ["D.md"] = { { path = "C" } },
  ["E.md"] = { { path = "A" } },
}

local stub_idx = {
  get_entry = function(_, rel) return stub_entries[rel] end,
  get_inlinks = function(_, rel) return stub_inlinks[rel] or {} end,
}

local function stub_resolve(link_path)
  if link_path ~= "" and stub_entries[link_path .. ".md"] then
    return link_path .. ".md"
  end
  return nil
end

test("bfs.traverse forward-only depth 2 reaches A,B,C,E (D at depth 3 excluded)", function()
  local visited = bfs.init_visited("A.md")
  local r = bfs.traverse(bfs.make_opts({
    index = stub_idx,
    frontier = bfs.init_frontier("A.md"),
    max_depth = 2,
    max_nodes = 50,
    resolve = stub_resolve,
    visited = visited,
    initial_count = 1,
    process_inlinks = false,
    on_discover = function() return true end,
  }))
  assert_set_keys(visited, { "A.md", "B.md", "C.md", "E.md" }, "visited set")
  assert_eq(r.node_count, 4, "node_count")
  assert_false(r.truncated, "truncated")
end)

test("bfs.traverse forward depth 1 limits to direct neighbors", function()
  local visited = bfs.init_visited("A.md")
  local r = bfs.traverse(bfs.make_opts({
    index = stub_idx,
    frontier = bfs.init_frontier("A.md"),
    max_depth = 1,
    max_nodes = 50,
    resolve = stub_resolve,
    visited = visited,
    initial_count = 1,
    process_inlinks = false,
    on_discover = function() return true end,
  }))
  assert_set_keys(visited, { "A.md", "B.md", "E.md" }, "visited set")
  assert_eq(r.node_count, 3, "node_count")
end)

test("bfs.traverse honors max_nodes cap (inclusive of initial_count) and truncates", function()
  local visited = bfs.init_visited("A.md")
  local r = bfs.traverse(bfs.make_opts({
    index = stub_idx,
    frontier = bfs.init_frontier("A.md"),
    max_depth = 5,
    max_nodes = 2,
    resolve = stub_resolve,
    visited = visited,
    initial_count = 1,
    process_inlinks = false,
    on_discover = function() return true end,
  }))
  assert_set_keys(visited, { "A.md", "B.md" }, "visited set (center + 1 discovery)")
  assert_eq(r.node_count, 2, "node_count")
  assert_true(r.truncated, "should report truncation")
end)

test("bfs.traverse backward (inlinks only) from leaf D reaches all ancestors", function()
  local visited = bfs.init_visited("D.md")
  local r = bfs.traverse(bfs.make_opts({
    index = stub_idx,
    frontier = bfs.init_frontier("D.md"),
    max_depth = 5,
    max_nodes = 50,
    resolve = stub_resolve,
    visited = visited,
    initial_count = 1,
    process_outlinks = false,
    process_inlinks = true,
    on_discover = function() return true end,
  }))
  assert_set_keys(visited, { "A.md", "B.md", "C.md", "D.md" }, "visited set")
  assert_eq(r.node_count, 4, "node_count")
end)

test("bfs.traverse on_discover rejection prunes a branch", function()
  local visited = bfs.init_visited("A.md")
  local r = bfs.traverse(bfs.make_opts({
    index = stub_idx,
    frontier = bfs.init_frontier("A.md"),
    max_depth = 2,
    max_nodes = 50,
    resolve = stub_resolve,
    visited = visited,
    initial_count = 1,
    process_inlinks = false,
    on_discover = function(rel)
      if rel == "B.md" then return nil end
      return true
    end,
  }))
  assert_set_keys(visited, { "A.md", "E.md" }, "B rejected so C never reached")
  assert_eq(r.node_count, 2, "node_count")
end)

-- ============================================================================
-- 2. precompute_graph_sets / ast_contains_graph over a REAL temp-vault index
--    Vault graph: A -> B, A -> E, B -> C, C -> D
-- ============================================================================

local tmp1 = _F.make_temp_vault({
  ["A.md"] = "# A\n\nlinks: [[B]] and [[E]]\n",
  ["B.md"] = "# B\n\nlinks: [[C]]\n",
  ["C.md"] = "# C\n\nlinks: [[D]]\n",
  ["D.md"] = "# D\n\nno links\n",
  ["E.md"] = "# E\n\nno links\n",
}, { suffix = "_graphvault" })

engine.vault_path = tmp1
local idx1 = vault_index.get(tmp1)
idx1:build_sync()

test("temp vault index built and ready (5 files)", function()
  assert_true(idx1:is_ready(), "index ready")
  assert_eq(idx1:file_count(), 5, "file count")
  assert_true((idx1._generation or 0) > 0, "generation > 0")
end)

test("precompute_graph_sets forward depth 2 from current (A)", function()
  local sets = gt.precompute_graph_sets(
    { type = "graph", center = "current", depth = 2, direction = "forward" },
    idx1, tmp1 .. "/A.md")
  local set = sets["graph_current_2_forward"]
  assert_true(set ~= nil, "set keyed graph_current_2_forward")
  assert_set_keys(set, { "A.md", "B.md", "C.md", "E.md" }, "reachable set")
end)

test("precompute_graph_sets backward depth 2 from leaf D", function()
  local sets = gt.precompute_graph_sets(
    { type = "graph", center = "current", depth = 2, direction = "backward" },
    idx1, tmp1 .. "/D.md")
  local set = sets["graph_current_2_backward"]
  assert_true(set ~= nil, "set keyed graph_current_2_backward")
  assert_set_keys(set, { "B.md", "C.md", "D.md" }, "ancestors within 2 hops (A at depth 3 excluded)")
end)

test("precompute_graph_sets direction=both depth 1 from middle node C", function()
  local sets = gt.precompute_graph_sets(
    { type = "graph", center = "current", depth = 1, direction = "both" },
    idx1, tmp1 .. "/C.md")
  local set = sets["graph_current_1_both"]
  assert_true(set ~= nil, "set keyed graph_current_1_both")
  assert_set_keys(set, { "B.md", "C.md", "D.md" }, "B via inlink, D via outlink")
end)

test("precompute_graph_sets resolves center by note NAME (not current_path)", function()
  local sets = gt.precompute_graph_sets(
    { type = "graph", center = "B", depth = 1, direction = "forward" },
    idx1, nil)
  local set = sets["graph_B_1_forward"]
  assert_true(set ~= nil, "set keyed graph_B_1_forward")
  assert_set_keys(set, { "B.md", "C.md" }, "B's forward 1-hop set")
end)

test("precompute_graph_sets caps at config.graph.max_nodes and truncates", function()
  local save = config.graph.max_nodes
  config.graph.max_nodes = 2
  local ok, err = pcall(function()
    local sets = gt.precompute_graph_sets(
      { type = "graph", center = "current", depth = 5, direction = "forward" },
      idx1, tmp1 .. "/A.md")
    local set = sets["graph_current_5_forward"]
    assert_true(set ~= nil, "set keyed graph_current_5_forward")
    assert_set_keys(set, { "A.md", "B.md" }, "capped at 2 nodes (center + 1)")
  end)
  config.graph.max_nodes = save
  if not ok then error(err) end
end)

test("ast_contains_graph detects graph nodes including nested", function()
  assert_true(gt.ast_contains_graph(
    { type = "graph", center = "current", depth = 1, direction = "both" }),
    "bare graph node")
  assert_false(gt.ast_contains_graph({ type = "text", value = "foo" }),
    "plain text node")
  assert_true(gt.ast_contains_graph({
    type = "and",
    left = { type = "text", value = "x" },
    right = { type = "graph", center = "current", depth = 1, direction = "both" },
  }), "graph node nested under and")
end)

-- ============================================================================
-- 3. graph_filter.traversal.collect_at_depth_async (async BFS + layer cache)
-- ============================================================================

test("collect_at_depth_async returns forward nodes at depth 2 (async)", function()
  vault_index._instance = idx1
  engine.vault_path = tmp1
  trav.invalidate_bfs_cache()
  local done = false
  local FWD, BK, TR
  trav.collect_at_depth_async(tmp1 .. "/A.md", 2, function() return true end, "st1",
    function(fwd, bk, trunc)
      FWD, BK, TR = fwd, bk, trunc
      done = true
    end)
  vim.wait(3000, function() return done end)
  assert_true(done, "async callback fired")
  assert_eq(sorted_names(FWD), "B,C,E", "forward names (center A excluded)")
  assert_eq(#BK, 0, "no backlinks for A")
  assert_false(TR, "not truncated")
end)

test("collect_at_depth_async BFS cache: miss then exact hit", function()
  trav.invalidate_bfs_cache()
  local h0, m0 = trav.bfs_cache_counters()

  local done1, fwd1 = false, nil
  trav.collect_at_depth_async(tmp1 .. "/A.md", 2, function() return true end, "s1",
    function(fwd) fwd1 = fwd; done1 = true end)
  vim.wait(3000, function() return done1 end)
  assert_true(done1, "first call completed")
  assert_true(trav.bfs_cache_size() >= 1, "cache populated after first call")

  local done2, fwd2 = false, nil
  trav.collect_at_depth_async(tmp1 .. "/A.md", 2, function() return true end, "s1",
    function(fwd) fwd2 = fwd; done2 = true end)
  vim.wait(3000, function() return done2 end)
  assert_true(done2, "second call completed")

  local h1, m1 = trav.bfs_cache_counters()
  assert_eq(m1, m0 + 1, "exactly one miss (the first call)")
  assert_true(h1 > h0, "second identical call hits the cache")
  assert_eq(sorted_names(fwd1), "B,C,E", "first forward set")
  assert_eq(sorted_names(fwd2), "B,C,E", "cached forward set identical")
end)

-- ============================================================================
-- 4. connections.compute over a second temp vault
--    Vault: A -> B, A -> C, B -> C; Iso has no links.
-- ============================================================================

local tmp2 = _F.make_temp_vault({
  ["A.md"] = "# A\n\n[[B]] and [[C]]\n",
  ["B.md"] = "# B\n\n[[C]]\n",
  ["C.md"] = "# C\n\nno links\n",
  ["Iso.md"] = "# Iso\n\nisolated note\n",
}, { suffix = "_connvault" })

engine.vault_path = tmp2
local idx2 = vault_index.get(tmp2)
idx2:build_sync()

local conn_results

test("connections.compute deterministic breakdown, ordering, and self-exclusion", function()
  conn_results = connections.compute("A.md", 30)
  assert_true(conn_results ~= nil, "results returned")
  assert_eq(#conn_results, 3, "three candidates (B, C, Iso)")

  local by_name = {}
  for _, r in ipairs(conn_results) do
    assert_true(r.rel_path ~= "A.md", "source excluded from its own results")
    by_name[r.name] = r
  end

  local b = by_name["B"]
  assert_true(b ~= nil, "B present")
  assert_close(b.breakdown.link, 5.0, "B 1-hop link score")
  assert_close(b.breakdown.colink, 2.5, "B colink score (1 shared / min(2,1))")
  assert_close(b.breakdown.tags, 0, "B tags score")
  assert_close(b.breakdown.fm, 0, "B fm score")
  assert_close(b.score, b.breakdown.link + b.breakdown.colink + b.breakdown.temporal,
    "B total = link + colink + temporal")
  assert_close(b.breakdown.temporal, 1.0, "B temporal (same-day temp files)")
  assert_close(b.score, 8.5, "B total score")

  local c = by_name["C"]
  assert_true(c ~= nil, "C present")
  assert_close(c.breakdown.link, 5.0, "C 1-hop link score")
  assert_close(c.breakdown.colink, 0, "C colink score (C has no outlinks)")
  assert_close(c.score, 6.0, "C total score")

  local iso = by_name["Iso"]
  assert_true(iso ~= nil, "Iso present")
  assert_close(iso.breakdown.link, 0, "Iso link score")
  assert_close(iso.breakdown.colink, 0, "Iso colink score")
  assert_close(iso.score, 1.0, "Iso total (same-day temporal only)")

  -- Ordering by score descending: B, C, Iso
  assert_eq(conn_results[1].name, "B", "rank 1")
  assert_eq(conn_results[2].name, "C", "rank 2")
  assert_eq(conn_results[3].name, "Iso", "rank 3")
end)

test("connections.compute reasons include human-readable link/colink labels", function()
  assert_true(conn_results ~= nil, "previous compute results available")
  local by_name = {}
  for _, r in ipairs(conn_results) do by_name[r.name] = r end

  local function has_reason(r, needle)
    for _, reason in ipairs(r.reasons) do
      if reason:find(needle, 1, true) then return true end
    end
    return false
  end

  local b = by_name["B"]
  assert_true(has_reason(b, "1-hop link"), "B has '1-hop link' reason")
  assert_true(has_reason(b, "colink: 1 shared"), "B has 'colink: 1 shared' reason")

  local c = by_name["C"]
  assert_true(has_reason(c, "1-hop link"), "C has '1-hop link' reason")
  assert_false(has_reason(c, "colink"), "C has no colink reason")
end)

-- ============================================================================
-- 5. filter_utils pure helpers
-- ============================================================================

test("filter_utils.is_cache_gen_valid", function()
  assert_false(fu.is_cache_gen_valid(nil, 5), "nil cached")
  assert_true(fu.is_cache_gen_valid({ gen = 5 }, 5), "matching gen")
  assert_false(fu.is_cache_gen_valid({ gen = 4 }, 5), "stale gen")
  assert_false(fu.is_cache_gen_valid({ gen = 0 }, 0), "gen <= 0 always invalid")
  assert_true(fu.is_cache_gen_valid({ index_gen = 7 }, 7, "index_gen"), "custom gen field")
end)

test("filter_utils.normalize_link_name strips fragments and lowercases", function()
  assert_eq(fu.normalize_link_name("Note Name#Head^blk"), "note name")
  assert_nil(fu.normalize_link_name("   "), "whitespace-only is nil")
end)

test("filter_utils.parse_tag_filter splits includes/excludes", function()
  local inc, exc = fu.parse_tag_filter("project,-archived,-template")
  assert_eq(#inc, 1, "one include")
  assert_eq(inc[1], "project")
  assert_eq(#exc, 2, "two excludes")
  assert_eq(exc[1], "archived")
  assert_eq(exc[2], "template")
end)

test("filter_utils.matches_include_exclude logic", function()
  assert_true(fu.matches_include_exclude({ "a" }, { "b" }, function(x) return x == "a" end),
    "include matches, exclude does not")
  assert_false(fu.matches_include_exclude({ "a" }, { "b" }, function(x) return x == "b" end),
    "exclude match rejects")
  assert_true(fu.matches_include_exclude(nil, nil, function() return false end),
    "no constraints passes")
  assert_false(fu.matches_include_exclude({ "a" }, {}, function() return false end),
    "include present but none match")
end)

-- Stub VaultIndex for resolve_in_index: only files / vault_path / resolve_name used.
local function make_resolver_stub()
  local stub = {
    resolve_calls = 0,
    files = { ["notes/beta.md"] = { rel_path = "notes/beta.md" } },
    vault_path = "/v",
  }
  stub.resolve_name = function(self, lower)
    self.resolve_calls = self.resolve_calls + 1
    if lower == "gamma" then return { "/v/g/Gamma.md" } end
    if lower == "ext" then return { "/other/X.md" } end
    return nil
  end
  return stub
end

test("filter_utils.resolve_in_index: direct rel_path, name lookup, outside-vault, miss", function()
  local stub = make_resolver_stub()
  -- Direct rel_path match (lowercased), no resolve_name call
  assert_eq(fu.resolve_in_index(stub, "Notes/Beta"), "notes/beta.md", "direct rel_path match")
  assert_eq(stub.resolve_calls, 0, "direct match skips resolve_name")
  -- Name-based lookup strips fragment and converts abs -> rel
  assert_eq(fu.resolve_in_index(stub, "Gamma#Heading"), "g/Gamma.md", "resolve_name abs->rel")
  -- resolve_name result outside vault prefix is rejected
  assert_nil(fu.resolve_in_index(stub, "ext"), "abs path outside vault rejected")
  -- Unknown name misses
  assert_nil(fu.resolve_in_index(stub, "Missing"), "unknown name")
end)

test("filter_utils.create_memoized_resolver caches hits AND nil-results", function()
  local stub = make_resolver_stub()
  local resolve = fu.create_memoized_resolver(stub)
  -- Two repeated misses -> only one resolve_name call
  assert_nil(resolve("Missing"))
  assert_nil(resolve("Missing"))
  assert_eq(stub.resolve_calls, 1, "nil result memoized")
  -- Two repeated hits -> only one more resolve_name call
  assert_eq(resolve("Gamma"), "g/Gamma.md")
  assert_eq(resolve("Gamma"), "g/Gamma.md")
  assert_eq(stub.resolve_calls, 2, "hit memoized")
end)

-- ============================================================================
-- 6. graph.collect.disambiguate_names
-- ============================================================================

test("disambiguate_names renames duplicate display names to vault-relative stems", function()
  engine.vault_path = tmp1
  local entries = {
    { name = "Note", path = tmp1 .. "/a/Note.md" },
    { name = "note", path = tmp1 .. "/b/Note.md" }, -- same group, case-insensitive
    { name = "Unique", path = tmp1 .. "/Unique.md" },
  }
  local out = collect.disambiguate_names(entries)
  assert_eq(out, entries, "mutates and returns same table")
  assert_eq(entries[1].name, "a/Note", "dup 1 renamed to rel stem")
  assert_eq(entries[2].name, "b/Note", "dup 2 renamed to rel stem")
  assert_eq(entries[3].name, "Unique", "unique entry untouched")
end)

test("disambiguate_names leaves nil-path entries untouched even in dup groups", function()
  engine.vault_path = tmp1
  local entries = {
    { name = "X", path = tmp1 .. "/sub/X.md" },
    { name = "X", path = nil },
  }
  collect.disambiguate_names(entries)
  assert_eq(entries[1].name, "sub/X", "path-bearing dup renamed")
  assert_eq(entries[2].name, "X", "nil-path dup keeps original name")
end)

-- ============================================================================
-- Cleanup
-- ============================================================================
vim.fn.delete(tmp1, "rf")
vim.fn.delete(tmp2, "rf")

-- ============================================================================
-- Summary
-- ============================================================================
_H.finish({ style = "results", exit = "os" })
