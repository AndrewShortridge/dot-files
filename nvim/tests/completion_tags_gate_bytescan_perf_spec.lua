-- Perf regression spec: tag completion's early-exit GATE short-circuits on a
-- cheap plain-byte '#' scan before running its backtracking Lua patterns.
--
-- The vault_tags source has min_keyword_length=2, so blink.cmp invokes
-- get_completions whenever a 2+ char keyword precedes the cursor — i.e. on
-- essentially every prose word typed. The original early-exit was:
--   if not before:match(pat.TAG_TRIGGER) and not before:match("^#[%w_/-]*$")
-- where TAG_TRIGGER == "[%s^]#[%w_/-]*$" is UNANCHORED at the start, so Lua's
-- pattern engine attempts it at every byte position of `before` (~3us on a
-- 176-char prose line). A tag completion is impossible unless `before` contains
-- a literal '#' at all, so a plain-byte `before:find("#", 1, true)` (~0.07us)
-- short-circuits the entire no-'#' prose case before the two backtracking
-- matches. Both downstream patterns require a literal '#', so the pre-gate
-- changes no observable semantics.
--
-- This drives the REAL andrew.vault.completion_tags source against a temp vault
-- buffer (no mocks, no source-introspection).
--
-- Discriminating power (proven empirically):
--   * On a NO-'#' prose line, the FIXED gate runs find("#",1,true) (>=1 find,
--     saw_hash_find==true) and 0 string.match on this path. The BUGGY gate
--     (pre-gate removed) runs match(TAG_TRIGGER) then match("^#[%w_/-]*$") = 2
--     matches and 0 '#'-finds. So:
--       - match_count == 0   (bug -> 2, assertion FAILS)
--       - saw_hash_find      (bug -> false, assertion FAILS)
--   * BEHAVIORAL guards: '#topic' still returns tag items (gate passes); plain
--     prose returns empty_response; a heading-like '# Heading ' returns empty
--     (the line-114 heading exclusion still fires after the gate).
--
-- Run with:
--   nvim --headless -u NONE -l tests/completion_tags_gate_bytescan_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local tags_source = require("andrew.vault.completion_tags")

print("\n=== Tag Completion Gate Byte-Scan Perf Tests ===\n")

-- ---------------------------------------------------------------------------
-- Temp vault: several notes with frontmatter tags so tags_with_counts() yields
-- a non-trivial candidate set.
-- ---------------------------------------------------------------------------
local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
for i = 1, 8 do
  write_file(dir, string.format("note_%03d.md", i), {
    "---",
    "tags: [topic" .. i .. "]",
    "---",
    "# Note " .. i,
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

vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/note_001.md"))
local bufnr = vim.api.nvim_get_current_buf()

local function get_items(line)
  local result = nil
  local ctx = { line = line, cursor = { 1, #line }, bufnr = bufnr }
  tags_source:get_completions(ctx, function(r) result = r end)
  vim.wait(2000, function() return result ~= nil end, 10)
  return (result or {}).items or {}
end

-- A long prose line with NO '#' trigger — the overwhelmingly common keystroke.
local PROSE = string.rep("word ", 35) -- ~175 chars, no '#'

-- ---------------------------------------------------------------------------
-- PERF — on a no-'#' prose line, the GATE must be a plain-byte find, not a
-- backtracking match. Spy string.match AND string.find for the dynamic extent
-- of ONE get_completions call, then always restore (pcall + finally). Record
-- whether the gate's plain-byte '#' find ran.
-- ---------------------------------------------------------------------------
test("no-'#' prose line: gate uses string.find not string.match", function()
  -- Prime the item cache so the spied call hits the synchronous path (a cache
  -- miss could defer work; priming with a '#'-bearing line warms the index gen).
  get_items("#topic")

  local orig_match = string.match
  local orig_find = string.find
  local match_count = 0
  local find_count = 0
  local saw_hash_find = false
  local result = nil
  local ok, err = pcall(function()
    string.match = function(...)
      match_count = match_count + 1
      return orig_match(...)
    end
    string.find = function(s, patt, init, plain)
      find_count = find_count + 1
      if patt == "#" and plain == true then saw_hash_find = true end
      return orig_find(s, patt, init, plain)
    end
    local ctx = { line = PROSE, cursor = { 1, #PROSE }, bufnr = bufnr }
    tags_source:get_completions(ctx, function(r) result = r end)
  end)
  string.match = orig_match -- finally: always restore
  string.find = orig_find

  assert_true(ok, "get_completions did not error under the spies: " .. tostring(err))
  -- Fixed gate: find("#",1,true) bails before any match runs on this path.
  -- Buggy gate (pre-gate removed): 2 matches (TAG_TRIGGER + "^#[%w_/-]*$").
  assert_eq(match_count, 0, "no string.match on the no-'#' prose path")
  assert_true(find_count >= 1, "at least one string.find on the prose path, got " .. find_count)
  assert_true(saw_hash_find, "the gate ran a plain-byte find('#', 1, true)")
end)

-- ---------------------------------------------------------------------------
-- BEHAVIORAL equivalence — the gate change preserves all trigger paths.
-- ---------------------------------------------------------------------------
test("plain no-'#' prose line returns empty_response (gate correctly fails)", function()
  local items = get_items(PROSE)
  assert_eq(#items, 0, "no completion items on a no-'#' prose line")
end)

test("#topic still passes the gate and returns tag items", function()
  local items = get_items("#topic")
  assert_true(#items >= 1, "tag trigger still produces tag items")
end)

test("heading-like '# Heading ' still returns empty (heading exclusion fires)", function()
  -- This line contains a '#', so it passes the new pre-gate; the existing
  -- heading-exclusion check (line ~114) must still suppress completion.
  local items = get_items("# Heading ")
  assert_eq(#items, 0, "markdown heading is not a tag trigger")
end)

_H.finish({ style = "results", exit = "os" })
