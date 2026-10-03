-- Perf regression spec: when autopairs has already inserted the closing "]]"
-- after the cursor, the wikilinks completion source must strip the trailing "]]"
-- from each item's insertText (to avoid producing "]]]]") WITHOUT cloning the
-- entire candidate set on every keystroke.
--
-- Before the fix, get_completions wrapped the callback and, on every keystroke
-- with "]]" after the cursor (the autopairs-common case), looped result.items
-- and cloned (vim.tbl_extend("force", {}, item)) every "]]"-suffixed item into a
-- fresh array — cloning a large fraction of the candidate set per keystroke for
-- big vaults.
--
-- The fix memoizes the stripped clone-array keyed on the SOURCE array's table
-- identity (note-name / heading / block arrays are stable across keystrokes of
-- an unchanged buffer/index), so the clone loop runs ONCE per source array and
-- subsequent keystrokes return the SAME stripped table reference. The shared,
-- cached source items are NEVER mutated (clone, not in-place edit).
--
-- This drives the REAL andrew.vault.completion source against a temp vault + a
-- real markdown buffer (no mocks, no source-introspection).
--
-- Discriminating power: reintroducing the per-keystroke clone makes each strip
-- call build a fresh array -> the second-call reference-identity assertion fails.
-- Reintroducing in-place mutation makes the "shared cache not corrupted" /
-- "non-]] call still has ]]" assertion fail. Verified by temporarily reverting.
--
-- Run with: nvim --headless -u NONE -l tests/completion_strip_close_bracket_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local completion_base = require("andrew.vault.completion_base")
local source = require("andrew.vault.completion") -- wikilinks source

print("\n=== Completion Strip Close-Bracket Perf Tests ===\n")

-- ---------------------------------------------------------------------------
-- Temp vault + buffer helpers
-- ---------------------------------------------------------------------------
local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

--- Drive the source's get_completions synchronously and return the result.
--- `line` is the full buffer line; `col` is the 0-indexed cursor column (chars
--- before the cursor count, chars at/after are the "after" segment). Defaults to
--- end-of-line (cursor after everything, nothing after).
local function complete(line, col)
  col = col or #line
  local result = nil
  local ctx = { line = line, cursor = { 1, col }, bufnr = vim.api.nvim_get_current_buf() }
  source:get_completions(ctx, function(r) result = r end)
  vim.wait(2000, function() return result ~= nil end, 5)
  return result or {}
end

-- ---------------------------------------------------------------------------
-- Setup: a temp vault with several notes (note-name candidates) + a buffer
-- with blocks and headings (block/heading candidates).
-- ---------------------------------------------------------------------------
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
write_file(dir, "Foo Note.md", { "# Foo Note", "", "Body." })
write_file(dir, "Foobar.md", { "# Foobar", "", "Body." })
write_file(dir, "Baz.md", { "# Baz", "", "Body." })
write_file(dir, "main.md", {
  "# Top Heading",
  "",
  "Some intro text.",
  "",
  "## Section A",
  "",
  "First paragraph. ^blk-aaaaaa",
  "",
  "## Section B",
  "",
  "Second paragraph. ^blk-bbbbbb",
})
engine.vault_path = dir
vault_index._instance = nil
local idx = vault_index.get(dir)
idx:build_sync()
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/main.md"))
completion_base.invalidate_all()

-- Warm the source cache so the note-name path returns the stable cached_items.
complete("[[")

local function any_insert_ends_double(items)
  for _, it in ipairs(items) do
    if it.insertText and it.insertText:sub(-2) == "]]" then return true end
  end
  return false
end

-- ===========================================================================
-- 1. Note-name: with "]]" after cursor, no item insertText ends in "]]".
-- ===========================================================================
test("note-name: '[[Foo]]' with cursor before ']]' strips trailing ']]'", function()
  -- line "[[Foo]]", cursor after "[[Foo" (col 5): before="[[Foo", after="]]".
  local stripped = complete("[[Foo]]", 5)
  assert_true(stripped.items and #stripped.items >= 1,
    "note-name items produced (got " .. tostring(stripped.items and #stripped.items) .. ")")
  for _, it in ipairs(stripped.items) do
    assert_true(it.insertText:sub(-2) ~= "]]",
      "stripped insertText must NOT end in ']]' (got: " .. it.insertText .. ")")
  end

  -- Without "]]" after the cursor, insertText DOES keep the "]]" suffix.
  local unstripped = complete("[[Foo") -- cursor at end, after = ""
  assert_true(any_insert_ends_double(unstripped.items),
    "without ']]' after cursor, insertText keeps its ']]' suffix")
end)

-- ===========================================================================
-- 2. Single closing bracket: stripped == base minus exactly the last two chars.
-- ===========================================================================
test("stripped insertText equals un-stripped minus the trailing ']]'", function()
  local unstripped = complete("[[Foobar").items
  local stripped = complete("[[Foobar]]", 8).items -- before="[[Foobar", after="]]"

  -- Build a label->insertText map from the un-stripped run.
  local base_by_label = {}
  for _, it in ipairs(unstripped) do base_by_label[it.label] = it.insertText end

  local checked = 0
  for _, it in ipairs(stripped) do
    local base_insert = base_by_label[it.label]
    if base_insert then
      assert_eq(base_insert:sub(-2), "]]", "un-stripped base ends in ']]'")
      assert_eq(it.insertText, base_insert:sub(1, -3),
        "stripped is base minus the last two chars (no doubled brackets)")
      checked = checked + 1
    end
  end
  assert_true(checked >= 1, "at least one item compared base-vs-stripped (got " .. checked .. ")")
end)

-- ===========================================================================
-- 3. CRITICAL: stripping must NOT mutate the shared cached source items.
-- ===========================================================================
test("stripping does not corrupt the shared cached note-name items", function()
  -- Strip call first.
  local stripped = complete("[[Foo]]", 5)
  assert_true(not any_insert_ends_double(stripped.items), "strip removed ']]'")

  -- Immediately a NON-']]' call on the SAME cached array: items must STILL
  -- carry their "]]" suffix (proves no in-place mutation of shared tables).
  local normal = complete("[[Foo")
  assert_true(any_insert_ends_double(normal.items),
    "non-']]' call still has ']]' suffix (shared cache not mutated)")
end)

-- ===========================================================================
-- 4. PERF / discriminating power: memoized stripped array is reused.
-- ===========================================================================
test("repeated strip on the stable cached array returns the SAME table", function()
  -- Two identical strip triggers on the unchanged buffer/index: the source
  -- note-name array is the stable cached_items, so the memo returns the SAME
  -- stripped array reference. The per-keystroke-clone bug fails this.
  local s1 = complete("[[Foo]]", 5).items
  local s2 = complete("[[Foo]]", 5).items
  assert_true(s1 == s2, "memoized stripped array is the SAME reference across triggers")

  -- The stripped array is a DIFFERENT reference from the un-stripped source,
  -- and "]]"-items are distinct clones (proves the memo isn't vacuous).
  local source_items = complete("[[Foo").items
  assert_true(s1 ~= source_items, "stripped array is a distinct reference from the source array")
  local distinct = false
  for i = 1, #s1 do
    if s1[i] ~= source_items[i] then distinct = true break end
  end
  assert_true(distinct, "at least one stripped item is a distinct clone from its source item")
end)

-- ===========================================================================
-- 5. Heading + block branches also strip; standalone '^' is unaffected.
-- ===========================================================================
test("same-file heading branch strips ']]' when ']]' follows the cursor", function()
  local stripped = complete("[[#]]", 3).items -- before="[[#", after="]]"
  assert_true(#stripped >= 1, "heading items produced")
  for _, it in ipairs(stripped) do
    assert_true(it.insertText:sub(-2) ~= "]]", "heading insertText stripped of ']]'")
  end
  -- Without ']]' after, headings keep the suffix.
  assert_true(any_insert_ends_double(complete("[[#").items), "heading keeps ']]' without trailing ']]'")
end)

test("same-file block branch strips ']]'; standalone '^' is never stripped", function()
  local stripped = complete("[[^]]", 3).items -- before="[[^", after="]]"
  assert_true(#stripped >= 1, "same-file block items produced")
  for _, it in ipairs(stripped) do
    assert_true(it.insertText:sub(-2) ~= "]]", "same-file block insertText stripped of ']]'")
  end

  -- Standalone '^blk' (not inside [[ ]]) never carries a ']]' suffix and is not
  -- routed through the strip logic regardless of what follows.
  local standalone = complete("^blk").items
  assert_true(#standalone >= 1, "standalone block items produced")
  for _, it in ipairs(standalone) do
    assert_true(it.insertText:sub(-2) ~= "]]", "standalone block insertText has no ']]'")
  end
end)

_H.finish({ style = "results", exit = "os" })
