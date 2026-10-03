-- Spec for andrew.fortran.completion_sort: in Fortran buffers an exact match
-- comes first, then the LSP group, then the snippet group (and every other
-- source); everywhere else blink's default order holds.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_completion_sort_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local cfg = vim.fn.stdpath("config")
package.path = cfg .. "/lua/?.lua;" .. vim.fn.stdpath("data") .. "/lazy/blink.cmp/lua/?.lua;"
  .. vim.fn.stdpath("data") .. "/lazy/blink.cmp/lua/?/init.lua;" .. package.path

local S = require("andrew.fortran.completion_sort")
local blink = dofile(cfg .. "/lua/andrew/plugins/blink-cmp.lua")

local function item(source_id, label, score, exact)
  return { source_id = source_id, label = label, score = score or 0, sortText = label, exact = exact }
end

test("lsp ranks first, every other source shares one rank", function()
  assert_eq(S.rank(item("lsp", "x")), 1, "lsp:")
  assert_eq(S.rank(item("snippets", "x")), 2, "snippets:")
  assert_eq(S.rank(item("path", "x")), 2, "path:")
  assert_eq(S.rank(item("buffer", "x")), 2, "buffer:")
  assert_eq(S.rank({ label = "x" }), 2, "an item with no source_id must not error:")
end)

test("is_fortran recognises every Fortran filetype and dotted compounds", function()
  for _, ft in ipairs({ "fortran", "fortran_fixed", "fortran_free", "f90", "f95", "fortran.openmp" }) do
    assert_true(S.is_fortran(ft), ft .. " must count as Fortran:")
  end
  for _, ft in ipairs({ "lua", "markdown", "", "c", "fortranx" }) do
    assert_true(not S.is_fortran(ft), ("%q must not count as Fortran:"):format(ft))
  end
  assert_true(not S.is_fortran(nil) or vim.bo.filetype ~= "", "nil reads the current buffer (empty here):")
end)

test("in Fortran, an lsp item beats a snippet item regardless of score", function()
  local lsp = item("lsp", "MPI_Comm_rank", 10)
  local snip = item("snippets", "mpi_comm_rank", 99)
  assert_eq(S.compare(lsp, snip, "fortran"), true, "lsp above snippets:")
  assert_eq(S.compare(snip, lsp, "fortran"), false, "...and the reverse pair agrees:")
end)

test("an exact match beats the LSP group; two exact matches fall back to the group", function()
  -- The `ompdo` case: a weak fuzzy LSP hit must not outrank the exact snippet.
  local weak_lsp = item("lsp", "command_argument_count", 41)
  local exact_snip = item("snippets", "ompdo", 98, true)
  assert_eq(S.compare(exact_snip, weak_lsp, "fortran"), true, "exact snippet above non-exact lsp:")
  assert_eq(S.compare(weak_lsp, exact_snip, "fortran"), false, "...and the reverse pair agrees:")
  -- `mpi_init`: both exact -> lsp still leads the group.
  local exact_lsp = item("lsp", "MPI_Init", 90, true)
  local exact_snip2 = item("snippets", "mpi_init", 98, true)
  assert_eq(S.compare(exact_lsp, exact_snip2, "fortran"), true, "both exact: lsp first:")
  -- Two exact items from one source fall through to score.
  assert_nil(S.compare(item("lsp", "a", 1, true), item("lsp", "b", 2, true), "fortran"), "exact lsp vs exact lsp:")
  -- Outside Fortran exactness is not this comparator's business either.
  assert_nil(S.compare(exact_snip, weak_lsp, "lua"), "exact outside Fortran must defer:")
end)

test("pairs within one source, or among non-lsp sources, fall through", function()
  assert_nil(S.compare(item("lsp", "a", 1), item("lsp", "b", 2), "fortran"), "lsp vs lsp:")
  assert_nil(S.compare(item("snippets", "a"), item("snippets", "b"), "fortran"), "snippets vs snippets:")
  assert_nil(S.compare(item("snippets", "a"), item("path", "b"), "fortran"), "snippets vs path:")
  assert_nil(S.compare(item("buffer", "a"), item("snippets", "b"), "fortran"), "buffer vs snippets:")
end)

test("outside Fortran the comparator never decides", function()
  local lsp, snip = item("lsp", "a", 1), item("snippets", "b", 2)
  for _, ft in ipairs({ "lua", "markdown", "python", "" }) do
    assert_nil(S.compare(lsp, snip, ft), ft .. " must keep blink's default order:")
    assert_nil(S.compare(snip, lsp, ft), ft .. " (reversed):")
  end
end)

test("the comparator is a strict weak ordering table.sort accepts", function()
  -- 300 items across four sources with random scores; table.sort raises
  -- "invalid order function" on an inconsistent comparator.
  local sources = { "lsp", "snippets", "path", "buffer" }
  local list = {}
  math.randomseed(42)
  for i = 1, 300 do
    list[i] = item(sources[(i % 4) + 1], ("n%03d"):format(i), math.random(0, 20), math.random() < 0.1)
  end
  local sort = require("blink.cmp.fuzzy.sort")
  local ok, err = pcall(sort.sort, list, {
    function(a, b)
      return S.compare(a, b, "fortran")
    end,
    "score",
    "sort_text",
  })
  assert_true(ok, "table.sort rejected the comparator: " .. tostring(err))
  -- Tiers: exact lsp, exact other, non-exact lsp, the rest.
  local function tier(it)
    local lsp = it.source_id == "lsp"
    if it.exact then return lsp and 1 or 2 end
    return lsp and 3 or 4
  end
  local prev_tier, prev_score = 0, nil
  for _, it in ipairs(list) do
    local t = tier(it)
    assert_true(t >= prev_tier, "tier order broken at " .. it.label .. ":")
    if t == prev_tier then
      assert_true(prev_score >= it.score, "score order broken inside a tier at " .. it.label .. ":")
    end
    prev_tier, prev_score = t, it.score
  end
  assert_true(prev_tier == 4, "the random list must have exercised every tier:")
end)

test("the blink spec wires the comparator first and keeps blink's defaults after it", function()
  local sorts = blink.opts.fuzzy.sorts
  assert_true(type(sorts) == "table", "fuzzy.sorts must be a table:")
  assert_true(type(sorts[1]) == "function", "the first sort must be the Fortran comparator:")
  assert_eq(sorts[2], "score", "blink's default `score` must follow:")
  assert_eq(sorts[3], "sort_text", "...then `sort_text`:")
  assert_eq(#sorts, 3, "nothing else in the chain:")
  -- The wrapper routes to the module: an lsp/snippet pair in Fortran decides,
  -- and in a non-Fortran buffer it defers.
  vim.bo.filetype = "fortran"
  assert_eq(sorts[1](item("lsp", "a", 1), item("snippets", "b", 9)), true, "wired comparator (fortran):")
  vim.bo.filetype = "lua"
  assert_nil(sorts[1](item("lsp", "a", 1), item("snippets", "b", 9)), "wired comparator (lua):")
  vim.bo.filetype = ""
end)

_H.finish()
