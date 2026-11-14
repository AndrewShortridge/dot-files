-- Perf regression spec: wikilink completion captures the tail ONCE.
--
-- blink.cmp calls the wikilinks provider's get_completions on EVERY keystroke
-- while the menu is open. The common note-name path (`[[foo`, no `#`/`^`) used
-- to run several anchored-to-end, backtracking Lua patterns over the full line
-- prefix just to prove the ABSENCE of a block (`%^[^%]]*$`) and heading
-- (`#[^%]]*$`) trigger before falling through to the note-name branch. Each of
-- those is a lazy `.-` anchored `$` match that scans the whole prefix.
--
-- The fix captures the wikilink tail once (`before:match("!?%[%[(.-)$")`) and
-- dispatches on it using cheap linear byte scans (string.find(..., plain=true))
-- for "]", "^" and "#" — no extra backtracking full-prefix matches. The "after
-- the last `]`" invariant of the old patterns is preserved (the caret/hash must
-- lie strictly after the last "]" in the tail), so behaviour is identical.
--
-- This drives the REAL andrew.vault.completion source against a temp vault
-- buffer (no mocks, no source-introspection).
--
-- Discriminating power:
--   * PERF: a counting wrapper around string.match proves the common `[[foo`
--     path runs a BOUNDED, small number of matches. Reintroducing the two
--     anchored full-prefix matches (the bug) pushes the count past the bound,
--     so the assertion fails.
--   * BEHAVIORAL edge cases guard the "after last ]" invariant: a literal
--     find-from-start (the naive proposal) would falsely trigger block on
--     `[[Note^blk]more` and falsely trigger heading on `[[A]]more#x`; both must
--     resolve as note-name / non-trigger paths, NOT block/heading items.
--
-- Run with: nvim --headless -u NONE -l tests/completion_wikilink_tail_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local completion = require("andrew.vault.completion")

print("\n=== Wikilink Completion Tail-Capture Perf Tests ===\n")

-- ---------------------------------------------------------------------------
-- Temp vault: one note with a heading and a block id, plus enough sibling notes
-- that the note-name candidate list is non-trivial.
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

local note_lines = {
  "# Alpha Heading",
  "",
  "Some body text. ^blk-abc123",
  "",
  "## Beta Heading",
  "",
  "More text.",
}
write_file(dir, "note.md", note_lines)
for i = 1, 40 do
  write_file(dir, string.format("foo_%03d.md", i), { "# foo " .. i, "", "body" })
end

engine.vault_path = dir
vault_index._instance = nil
local idx = vault_index.get(dir)
idx:build_sync()

vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/note.md"))
local bufnr = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, note_lines)

local function get_items(line)
  local result = nil
  local ctx = { line = line, cursor = { 1, #line } }
  completion:get_completions(ctx, function(r) result = r end)
  vim.wait(2000, function() return result ~= nil end, 10)
  return result
end

-- ---------------------------------------------------------------------------
-- Test PERF — common note-name path runs a bounded, small number of
-- string.match calls. Spy on string.match for the dynamic extent of ONE
-- get_completions call, then always restore (pcall + finally).
-- ---------------------------------------------------------------------------
test("note-name path runs a bounded number of string.match calls", function()
  -- Prime the item cache first so the spied call hits the cache-hit synchronous
  -- path (the work scheduler that builds items is not part of the hot per-
  -- keystroke string.match accounting we are guarding).
  get_items("[[foo")

  local orig_match = string.match
  local count = 0
  local result = nil
  local ok, err = pcall(function()
    string.match = function(...)
      count = count + 1
      return orig_match(...)
    end
    local ctx = { line = "[[foo", cursor = { 1, #("[[foo") } }
    completion:get_completions(ctx, function(r) result = r end)
  end)
  string.match = orig_match -- finally: always restore

  assert_true(ok, "get_completions did not error under the spy: " .. tostring(err))
  -- L380 gate + L395 after-check + single tail capture == 3 matches on the
  -- common note path. The bug (two extra anchored full-prefix matches) makes
  -- this >= 5.
  assert_true(count <= 3, "string.match called <=3 times on note path, got " .. count)
  -- Prove the spy was actually wired (a stubbed-out spy that never increments
  -- could pass <=3 vacuously).
  assert_true(count >= 1, "string.match spy observed at least one call, got " .. count)
  assert_true(result ~= nil, "get_completions returned a result under the spy")
end)

-- ---------------------------------------------------------------------------
-- BEHAVIORAL equivalence across the three trigger branches.
-- ---------------------------------------------------------------------------
test("heading trigger ([[#) still returns heading items", function()
  local items = (get_items("[[#") or {}).items or {}
  local n = 0
  for _, item in ipairs(items) do
    if item.data and item.data.completion_kind == "heading" then n = n + 1 end
  end
  assert_true(n >= 1, "same-file heading branch produced heading items")
end)

test("block trigger ([[^) still returns block items", function()
  local items = (get_items("[[^") or {}).items or {}
  local n = 0
  for _, item in ipairs(items) do
    if item.data and item.data.completion_kind == "block" then n = n + 1 end
  end
  assert_true(n >= 1, "same-file block branch produced block items")
end)

test("note-name trigger ([[foo) returns note items with no completion_kind", function()
  local items = (get_items("[[foo") or {}).items or {}
  assert_true(#items >= 1, "note-name branch produced note items")
  for _, item in ipairs(items) do
    assert_true(not (item.data and item.data.completion_kind),
      "note item has no completion_kind")
  end
end)

test("cross-file heading ([[note#) returns heading items from index", function()
  local items = (get_items("[[note#") or {}).items or {}
  local n = 0
  for _, item in ipairs(items) do
    if item.data and item.data.completion_kind == "heading" then n = n + 1 end
  end
  assert_true(n >= 1, "cross-file heading branch produced heading items")
end)

test("cross-file block ([[note^) returns block items from index", function()
  local items = (get_items("[[note^") or {}).items or {}
  local n = 0
  for _, item in ipairs(items) do
    if item.data and item.data.completion_kind == "block" then n = n + 1 end
  end
  assert_true(n >= 1, "cross-file block branch produced block items")
end)

-- ---------------------------------------------------------------------------
-- EDGE CASES — the "after last ]" invariant. A literal find-from-start (naive
-- proposal) would falsely trigger block/heading here; the correct dispatch
-- treats them as note-name / non-block paths.
-- ---------------------------------------------------------------------------
test("[[Note^blk]more does NOT trigger block (caret before last ])", function()
  -- Old pattern `%^[^%]]*$` fails (a "]" follows the "^"), so this is the
  -- note-name path: no block items.
  local items = (get_items("[[Note^blk]more") or {}).items or {}
  local block = 0
  for _, item in ipairs(items) do
    if item.data and item.data.completion_kind == "block" then block = block + 1 end
  end
  assert_eq(block, 0, "no block items for caret preceding a later ]")
end)

test("[[A]]more#x heading capture is 'A]]more' -> no index entry -> empty", function()
  -- Old pattern `#[^%]]*$` captures note_name "A]]more" (the "#" is after the
  -- last "]"), which resolves to no index entry -> empty_response. So: no
  -- heading items for a heading-less / unknown note.
  local items = (get_items("[[A]]more#x") or {}).items or {}
  local heading = 0
  for _, item in ipairs(items) do
    if item.data and item.data.completion_kind == "heading" then heading = heading + 1 end
  end
  assert_eq(heading, 0, "no heading items for an unresolvable note name")
end)

_H.finish({ style = "results", exit = "os" })
