-- Behavioral spec for the first-word inverted index in link_scan.scan_buffer_names.
--
-- Phase 1 of scan_buffer_names used to test EVERY multi-word vault name against
-- every scanned line (O(all_names x lines)). It now walks the words actually
-- present on each line and only tests names bucketed under each line word in a
-- first-word inverted index keyed on the name's first [%w_]+ run. A multi-word
-- name can only match a line if its first word occurs there, so the result is
-- behavior-identical to the old all-names loop.
--
-- This drives the REAL link_scan + REAL vault_index against a temp vault (no
-- mock) and asserts observable behavior only. Discriminating-power notes:
--   * Test 1 (parity): names whose first word appears match; names whose first
--     word does NOT appear are skipped — same as the old loop.
--   * Test 2 (TOKENIZATION trap): a name whose first %S token carries
--     punctuation ("foo+bar baz") must be keyed on its first [%w_]+ run ("foo"),
--     which the [%w_] word-walk produces — NOT on the whitespace-delimited
--     "foo+bar". Keying on %S+ (the bug variant) would bucket under "foo+bar",
--     a key the word-walk NEVER yields, so the match would be MISSED and this
--     test would fail. This is the bug-reintroduction proof.
--   * Test 3 (greedy/overlap parity): overlapping names sharing a first word are
--     bucketed together longest-first; the longest phrase wins on a column.
--   * Test 4 (generation invalidation): the inverted index lives in the same
--     partition cache entry, so a generation bump rebuilds it (new name matched).
--
-- Run with: nvim --headless -u NONE -l tests/link_scan_first_word_index_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_true = _H.test, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vi = require("andrew.vault.vault_index")
local link_scan = require("andrew.vault.link_scan")

print("\n=== link_scan first-word inverted index Tests ===\n")

local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

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

local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function matched_names(buf, opts)
  local set = {}
  for _, m in ipairs(link_scan.scan_buffer_names(buf, opts)) do
    set[m.note_name] = true
  end
  return set
end

-- ===========================================================================
-- 1. Parity: only names whose first word occurs on the line are matched.
-- ===========================================================================
test("multi-word names matched iff first word present (parity)", function()
  make_indexed_vault({
    ["alpha note.md"] = { "# Alpha Note" },
    ["beta gamma.md"] = { "# Beta Gamma" },
  })
  -- Line contains the full phrase "alpha note"; "beta gamma" absent entirely.
  local buf = make_buffer({ "I reference alpha note here, nothing else." })
  local names = matched_names(buf)
  assert_true(names["alpha note"], "'alpha note' matched (first word present + full phrase)")
  assert_true(not names["beta gamma"], "'beta gamma' not matched (absent)")
end)

-- ===========================================================================
-- 2. TOKENIZATION TRAP / bug-reintroduction proof: punctuated first token.
--    Name "foo+bar baz" must bucket under its first [%w_]+ run "foo", which the
--    line word-walk produces. Keying on the whitespace-delimited "foo+bar"
--    (the bug) would never be looked up -> miss. This test fails under that bug.
-- ===========================================================================
test("punctuated first token keyed on [%w_]+ run, not whitespace token", function()
  make_indexed_vault({
    ["foo+bar baz.md"] = { "# foo+bar baz" },
  })
  local buf = make_buffer({ "see foo+bar baz in the text" })
  local names = matched_names(buf)
  assert_true(names["foo+bar baz"], "'foo+bar baz' matched (keyed on [%w_]+ run 'foo')")
end)

-- ===========================================================================
-- 3. Greedy/overlap parity: overlapping names sharing a first word, the longest
--    phrase wins (bucket sorted longest-first preserves greedy order).
-- ===========================================================================
test("overlapping names sharing a first word -> longest wins", function()
  make_indexed_vault({
    ["alpha note.md"] = { "# Alpha Note" },
    ["alpha note extended.md"] = { "# Alpha Note Extended" },
  })
  local buf = make_buffer({ "the alpha note extended phrase appears here" })
  local names = matched_names(buf)
  assert_true(names["alpha note extended"], "longest phrase 'alpha note extended' matched")
  -- The shorter "alpha note" overlaps the same columns; occupied_cols blocks it.
  assert_true(not names["alpha note"], "shorter overlapping 'alpha note' suppressed by greedy match")
end)

-- ===========================================================================
-- 4. Generation invalidation: inverted index rebuilds with the partition cache.
-- ===========================================================================
test("name added after generation bump is matched (inverted index rebuilds)", function()
  local dir, idx = make_indexed_vault({
    ["alpha note.md"] = { "# Alpha Note" },
  })
  local buf = make_buffer({ "delta echo and alpha note." })

  local before = matched_names(buf)
  assert_true(before["alpha note"], "alpha note matched on original generation")
  assert_true(not before["delta echo"], "'delta echo' not yet a vault name")

  local gen0 = idx._generation
  write_file(dir, "delta echo.md", { "# Delta Echo" })
  idx:update_file(dir .. "/delta echo.md")
  assert_true(idx._generation > gen0, "generation bumped after update_file")

  local after = matched_names(buf)
  assert_true(after["delta echo"], "newly indexed 'delta echo' matched (inverted index rebuilt)")
  assert_true(after["alpha note"], "alpha note still matched after rebuild")
end)

-- ===========================================================================
-- 5. Same first word recurring on a line does not error (seen_fw guard) and
--    still matches the phrase.
-- ===========================================================================
test("first word recurring on a line is handled (seen-set guard)", function()
  make_indexed_vault({
    ["alpha note.md"] = { "# Alpha Note" },
  })
  local buf = make_buffer({ "alpha alpha alpha note alpha" })
  local names = matched_names(buf)
  assert_true(names["alpha note"], "'alpha note' matched despite repeated first word 'alpha'")
end)

-- ===========================================================================
-- 6. CROSS-BUCKET overlap: globally longest wins (NOT leftmost). Two overlapping
--    multi-word names with DIFFERENT first words ("advanced calculus" vs
--    "calculus and analytic geometry") on one line. The OLD Phase 1 iterated all
--    names in a single GLOBAL longest-first order, so the longest phrase won via
--    occupied_cols. A per-line-word walk that applies names in line order (the
--    prior buggy attempt) resolves leftmost-wins instead, matching the shorter
--    "advanced calculus". The fix collects cross-bucket candidates then sorts
--    them GLOBALLY longest-first before matching. Discriminating: leftmost-wins
--    yields advanced calculus=YES / longest=no -> this test FAILS on that bug.
-- ===========================================================================
test("cross-bucket overlap: globally longest wins (not leftmost)", function()
  make_indexed_vault({
    ["advanced calculus.md"] = { "# Advanced Calculus" },
    ["calculus and analytic geometry.md"] = { "# Calculus and Analytic Geometry" },
  })
  local buf = make_buffer({ "advanced calculus and analytic geometry today" })
  local names = matched_names(buf)
  assert_true(names["calculus and analytic geometry"],
    "globally longest phrase wins across first-word buckets")
  assert_true(not names["advanced calculus"],
    "shorter cross-bucket leftmost name suppressed (global longest-first, not leftmost-first)")
end)

_H.finish({ style = "results", exit = "os" })
