-- Perf regression spec for DQL SORT decorate-sort-undecorate (Schwartzian).
-- Run with: nvim --headless -u NONE -l tests/dql_sort_decorate_perf_spec.lua
--
-- THE BUG (now fixed): query/executor.lua's apply_sort called table.sort over
-- the resolved page set with a comparator that re-evaluated eval_expr TWICE per
-- comparison per sort key. table.sort does ~N*log2(N) comparisons, so for K
-- sort keys it performed up to ~2*K*N*log2(N) eval_expr invocations. The fix
-- precomputes each page's sort key(s) ONCE into a parallel decorated array
-- (O(N) eval_expr calls) and sorts that, reading only the precomputed keys in
-- the comparator. Output (including unstable tie ordering) is unchanged.
--
-- DISCRIMINATING POWER: a SORT key of `lower(name)` forces eval_expr to invoke
-- the `lower` builtin exactly once per key evaluation. We wrap the REAL
-- executor_builtins `lower` with a counting wrapper BEFORE the executor module
-- captures the builtins table, then count invocations across a SORT query of N
-- pages. With the decorate fix the count is exactly N per key (one pass). With
-- the in-comparator eval bug it grows to ~N*log2(N), blowing past the 2*N
-- ceiling and FAILING the assertion. (Verified manually: reverting apply_sort to
-- evaluate inside the comparator pushes the count to the hundreds for N=64.)
--
-- Behavioral specs below pin the EXACT sort order (multi-key tie-break, DESC,
-- case-insensitive strings, mixed-type nil-first/by-typename) so the rewrite is
-- output-identical to the old code. Drives the REAL executor against a fake
-- index (no source introspection).

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- Stub the logger so requiring real modules doesn't pull full vault infra.
package.loaded["andrew.vault.vault_log"] = {
  scope = function()
    return setmetatable({}, { __index = function() return function() end end })
  end,
}

-- Install a counting wrapper on the REAL `lower` builtin BEFORE executor
-- requires executor_builtins and captures the table at module load.
local builtins = require("andrew.vault.query.executor_builtins")
local lower_count = 0
local real_make_fns = builtins.make_fns
builtins.make_fns = function(deps)
  local fns = real_make_fns(deps)
  local real_lower = fns.lower
  fns.lower = function(...)
    lower_count = lower_count + 1
    return real_lower(...)
  end
  return fns
end

local executor = require("andrew.vault.query.executor")

print("\n=== DQL SORT Decorate Perf Tests ===\n")

-- Fake index exposing exactly what executor.execute needs.
local function fake_index(pages)
  return {
    all_pages = function() return pages end,
    resolve_source = function(_, _) return pages end,
    current_page = function(_, _) return nil end,
  }
end

local function page(link, fields)
  fields.file = { link = link }
  return fields
end

-- TABLE with a File column so row[1] reveals the resolved sort order.
local function table_ast(sort)
  return {
    type = "TABLE",
    without_id = false,
    fields = {},
    sort = sort,
  }
end

local function field(name)
  return { type = "field", path = { name } }
end

local function call(name, args)
  return { type = "call", name = name, args = args }
end

-- Run a query, return ordered list of file links (the sort order).
local function order_of(sort, pages)
  local results = executor.execute(table_ast(sort), fake_index(pages), "/x.md")
  local out = {}
  for _, row in ipairs(results[1].rows) do
    out[#out + 1] = row[1]
  end
  return out
end

-- ===========================================================================
-- 1. Perf: single SORT key evaluates lower() exactly once per page (O(N)).
--    Discriminating: in-comparator eval would push this to ~N*log2(N).
-- ===========================================================================
test("single-key SORT evaluates the sort expr ~N times (decorate), not N*logN", function()
  local N = 64
  local pages = {}
  for i = 1, N do
    -- distinct, mostly-unique names so the sort actually compares (no all-ties).
    pages[i] = page("P" .. i, { name = string.format("name-%03d", (i * 7) % 100) })
  end
  local sort = { { expr = call("lower", { field("name") }), dir = "ASC" } }

  lower_count = 0
  order_of(sort, pages)

  -- Decorate ceiling: one eval per page per key. (Bug => ~N*log2(N) >> 2N.)
  assert_eq(lower_count, N, "lower() called exactly once per page (single decorate pass)")
  assert_true(lower_count <= 2 * N, "lower() count within decorate ceiling")
end)

-- ===========================================================================
-- 2. Perf: multi-key SORT evaluates each key once per page (2*N total).
-- ===========================================================================
test("multi-key SORT evaluates each of K keys once per page (K*N)", function()
  local N = 48
  local pages = {}
  for i = 1, N do
    pages[i] = page("P" .. i, {
      name = string.format("g%d", i % 4),       -- many ties on key1 -> key2 used
      name2 = string.format("n-%03d", (i * 13) % 100),
    })
  end
  local sort = {
    { expr = call("lower", { field("name") }), dir = "ASC" },
    { expr = call("lower", { field("name2") }), dir = "ASC" },
  }

  lower_count = 0
  order_of(sort, pages)

  assert_eq(lower_count, 2 * N, "lower() called once per page per key (2 keys => 2N)")
  assert_true(lower_count <= 2 * (2 * N), "within multi-key decorate ceiling")
end)

-- ===========================================================================
-- 3. Behavioral: multi-key tie-break (equal key1, differ on key2), incl DESC.
-- ===========================================================================
test("multi-key tie-break orders by second key (ASC)", function()
  local pages = {
    page("A", { k1 = "x", k2 = 3 }),
    page("B", { k1 = "x", k2 = 1 }),
    page("C", { k1 = "x", k2 = 2 }),
  }
  local sort = {
    { expr = field("k1"), dir = "ASC" },
    { expr = field("k2"), dir = "ASC" },
  }
  assert_eq(table.concat(order_of(sort, pages), ","), "B,C,A", "tie on k1, ordered by k2 ASC")
end)

test("multi-key tie-break with DESC second key", function()
  local pages = {
    page("A", { k1 = "x", k2 = 3 }),
    page("B", { k1 = "x", k2 = 1 }),
    page("C", { k1 = "x", k2 = 2 }),
  }
  local sort = {
    { expr = field("k1"), dir = "ASC" },
    { expr = field("k2"), dir = "DESC" },
  }
  assert_eq(table.concat(order_of(sort, pages), ","), "A,C,B", "tie on k1, ordered by k2 DESC")
end)

-- ===========================================================================
-- 4. Behavioral: case-insensitive string order + DESC.
-- ===========================================================================
test("string SORT is case-insensitive (apple < Banana) ASC", function()
  local pages = {
    page("Ban", { s = "Banana" }),
    page("App", { s = "apple" }),
  }
  local sort = { { expr = field("s"), dir = "ASC" } }
  assert_eq(table.concat(order_of(sort, pages), ","), "App,Ban", "apple before Banana, case-insensitive")
end)

test("DESC reverses the order", function()
  local pages = {
    page("App", { s = "apple" }),
    page("Ban", { s = "Banana" }),
  }
  local sort = { { expr = field("s"), dir = "DESC" } }
  assert_eq(table.concat(order_of(sort, pages), ","), "Ban,App", "DESC: Banana before apple")
end)

-- ===========================================================================
-- 5. Behavioral: mixed-type SORT (nil-first then by typename) matches compare.
--    types.compare: nil < non-nil; different typenames ordered by typename
--    string ("number" < "string"). Numbers and strings here are distinct
--    typenames so ordering is number-block then string-block.
-- ===========================================================================
test("mixed-type SORT: nil first, then numbers, then strings (by typename)", function()
  local pages = {
    page("Str", { v = "zebra" }),
    page("Nil", {}),            -- v is nil
    page("Num", { v = 5 }),
  }
  local sort = { { expr = field("v"), dir = "ASC" } }
  -- nil < (number "5") < (string "zebra")  because "number" < "string" by typename.
  assert_eq(table.concat(order_of(sort, pages), ","), "Nil,Num,Str", "nil-first then by typename")
end)

_H.finish({ style = "results", exit = "os" })
