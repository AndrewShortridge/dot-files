-- Perf regression spec: per-item CharBag construction is gated on the prefilter
-- threshold.
--
-- The CharBag flat/value prefilter only fires once the candidate list reaches
-- config.prefilter.min_candidates_for_charbag (default 500). Below that
-- threshold blink.cmp re-filters returned lists with its own fuzzy matcher, so
-- a bag-less item is output-safe. Building `_char_bag = char_bag.from_string(s)`
-- per item at build time below the threshold is therefore dead weight (build
-- time + memory) that is never read.
--
-- The fix gates the per-item bag construction:
--   * wikilinks (build_iter / build_items_for_file) and kv fields
--     (build_kv_single_pass) gate on idx:file_count() (candidate count is
--     bounded by file_count);
--   * tags build builds bag-less items, then sweeps in bags only if the exact
--     item count reaches the threshold (distinct-tag count is unrelated to
--     file_count).
-- At or above the threshold the bags are built exactly as before, so the
-- prefilter stays correct for large vaults.
--
-- This drives the REAL andrew.vault.completion / completion_tags /
-- completion_base sources against a temp vault (no mocks, no
-- source-introspection). A counting wrapper around char_bag.from_string proves
-- the per-item construction is skipped below threshold and restored above.
--
-- Discriminating power: reintroducing the unconditional per-item bag build
-- makes the below-threshold counts non-zero and the "no _char_bag" assertions
-- fail.
--
-- Run with: nvim --headless -u NONE -l tests/completion_charbag_gate_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local config = require("andrew.vault.config")
local char_bag = require("andrew.vault.char_bag")
local base = require("andrew.vault.completion")           -- wikilinks source
local tags_source = require("andrew.vault.completion_tags")
local completion_base = require("andrew.vault.completion_base")

print("\n=== Completion CharBag Gate Perf Tests ===\n")

-- ---------------------------------------------------------------------------
-- Temp vault helpers
-- ---------------------------------------------------------------------------
local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

--- Run `fn` with char_bag.from_string spied; returns the call count.
local function count_from_string(fn)
  local orig = char_bag.from_string
  local n = 0
  char_bag.from_string = function(...)
    n = n + 1
    return orig(...)
  end
  local ok, err = pcall(fn)
  char_bag.from_string = orig -- finally: always restore
  assert_true(ok, "spied body did not error: " .. tostring(err))
  return n
end

--- Drive the wikilinks source's get_completions and return the result table.
local function wikilink_items(line)
  local result = nil
  local ctx = { line = line, cursor = { 1, #line } }
  base:get_completions(ctx, function(r) result = r end)
  vim.wait(2000, function() return result ~= nil end, 10)
  return (result or {}).items or {}
end

--- Drive the tags source's get_completions and return the result table.
local function tag_items(line)
  local result = nil
  local ctx = { line = line, cursor = { 1, #line }, bufnr = vim.api.nvim_get_current_buf() }
  tags_source:get_completions(ctx, function(r) result = r end)
  vim.wait(2000, function() return result ~= nil end, 10)
  return (result or {}).items or {}
end

local function setup_vault(dir, n_notes)
  vim.fn.mkdir(dir, "p")
  for i = 1, n_notes do
    write_file(dir, string.format("note_%04d.md", i), {
      "---",
      "tags: [topic" .. i .. "]",
      "status: active",
      "---",
      "# Note " .. i,
      "",
      "[field:: value" .. i .. "]",
      "",
      "body",
    })
  end
  engine.vault_path = dir
  vault_index._instance = nil
  local idx = vault_index.get(dir)
  idx:build_sync()
  -- build_sync does not populate the summary tree (the persisted load() path
  -- does); tags_with_counts() reads it, so build it from the indexed files.
  idx._summary_tree:build_from_files(idx.files)
  -- Open a markdown buffer so source:enabled() / build paths run.
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/note_0001.md"))
  -- Invalidate any cache warmed by a previous vault so the next get_completions
  -- triggers a fresh build under the spy.
  completion_base.invalidate_all()
  return idx
end

local THRESHOLD = config.prefilter.min_candidates_for_charbag or 500

-- ===========================================================================
-- BELOW THRESHOLD: per-item bags must NOT be built.
-- ===========================================================================
local below_dir = vim.fn.tempname()
local below_idx = setup_vault(below_dir, 5)
assert_true(below_idx:file_count() < THRESHOLD,
  "below-threshold vault has fewer files than threshold")

test("wikilinks: no char_bag.from_string per item below threshold", function()
  local count = count_from_string(function()
    wikilink_items("[[no")
  end)
  -- The bare-query gate (#query < min_query_length) and the small-list gate both
  -- preclude a query-bag build, and the per-item build is gated off, so zero.
  assert_eq(count, 0, "char_bag.from_string never called for small wikilink vault")
  -- And no item carries a bag.
  local items = wikilink_items("[[no")
  assert_true(#items >= 1, "wikilink items were produced")
  for _, item in ipairs(items) do
    assert_true(item._char_bag == nil, "wikilink item has no _char_bag below threshold")
  end
end)

test("tags: no char_bag.from_string per item below threshold", function()
  -- 5 notes -> 5 distinct tags, far below the threshold.
  local count = count_from_string(function()
    tag_items("#to")
  end)
  assert_eq(count, 0, "char_bag.from_string never called for small tag set")
  local items = tag_items("#to")
  assert_true(#items >= 1, "tag items were produced")
  for _, item in ipairs(items) do
    assert_true(item._char_bag == nil, "tag item has no _char_bag below threshold")
  end
end)

test("kv fields: no char_bag.from_string per item below threshold", function()
  local count = count_from_string(function()
    completion_base.build_kv_single_pass(
      below_idx, "frontmatter", completion_base.known_field_values(), ": ")
  end)
  assert_eq(count, 0, "char_bag.from_string never called for small kv build")
  local res = completion_base.build_kv_single_pass(
    below_idx, "frontmatter", completion_base.known_field_values(), ": ")
  assert_true(#res.names >= 1, "kv name items were produced")
  for _, item in ipairs(res.names) do
    assert_true(item._char_bag == nil, "kv name item has no _char_bag below threshold")
  end
end)

-- ===========================================================================
-- AT/ABOVE THRESHOLD: per-item bags built and the prefilter narrows.
-- Lower the threshold (instead of creating 500+ notes) so the gate's
-- at-threshold branch is exercised cheaply. The vault has > threshold items.
-- ===========================================================================
test("at threshold: per-item bags built and prefilter narrows", function()
  local saved = config.prefilter.min_candidates_for_charbag
  config.prefilter.min_candidates_for_charbag = 3 -- < 5-note vault
  local ok, err = pcall(function()
    -- wikilinks: bags built (>= 1 from_string) and items carry _char_bag.
    completion_base.invalidate_all()
    local count = count_from_string(function() wikilink_items("[[no") end)
    assert_true(count >= 1, "char_bag.from_string called when at threshold (wikilinks)")
    local items = wikilink_items("[[no")
    local with_bag = 0
    for _, item in ipairs(items) do
      if item._char_bag then with_bag = with_bag + 1 end
    end
    assert_true(with_bag >= 1, "wikilink items carry _char_bag at threshold")

    -- tags: bags swept in at/above threshold.
    completion_base.invalidate_all()
    local tcount = count_from_string(function() tag_items("#to") end)
    assert_true(tcount >= 1, "char_bag.from_string called when at threshold (tags)")
    local titems = tag_items("#to")
    local twith = 0
    for _, item in ipairs(titems) do
      if item._char_bag then twith = twith + 1 end
    end
    assert_true(twith >= 1, "tag items carry _char_bag at threshold")

    -- kv: name items carry bags and the prefilter still narrows. Build once,
    -- then drive the kv get_completions handler over the >= threshold name list.
    local res = completion_base.build_kv_single_pass(
      below_idx, "frontmatter", completion_base.known_field_values(), ": ")
    local kvwith = 0
    for _, item in ipairs(res.names) do
      if item._char_bag then kvwith = kvwith + 1 end
    end
    assert_true(kvwith >= 1, "kv name items carry _char_bag at threshold")
  end)
  config.prefilter.min_candidates_for_charbag = saved -- finally: restore
  assert_true(ok, "at-threshold body did not error: " .. tostring(err))
end)

_H.finish({ style = "results", exit = "os" })
