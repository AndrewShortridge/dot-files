-- Behavioral spec for the footnote parse cache.
--
-- parse_all_footnotes_cached() used to key on the buffer changedtick, which
-- increments on EVERY edit — so any note containing footnotes rebuilt its whole
-- fn_map on every keystroke, even when the edit touched plain prose that cannot
-- affect any footnote. The cache now keys on a lightweight signature of the
-- footnote-relevant lines (definition markers, reference-bearing lines, indented
-- continuation lines, and blank lines). Editing unrelated prose leaves the
-- signature byte-identical (cache hit, no rebuild); editing a footnote line, or
-- inserting/deleting lines that shift footnote lnums, changes the signature.
--
-- This drives the REAL footnotes module against a scratch buffer (no mock) and
-- asserts only observable behavior: the orphan report produced by M.orphans()
-- (captured via vim.notify). No source introspection.
--
-- Run with: nvim --headless -u NONE -l tests/footnote_cache_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq = _H.test, _H.assert_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local footnotes = require("andrew.vault.footnotes")

print("\n=== Footnote Cache Tests ===\n")

-- Run M.orphans() against a fresh scratch buffer seeded with `lines` and return
-- the captured notification text (the orphan report, or the "no footnotes" /
-- "all linked" message). vim.notify is stubbed only for the duration of the call.
local function orphans_for(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function capture_orphans()
  local captured = {}
  local orig = vim.notify
  vim.notify = function(msg) captured[#captured + 1] = msg end
  local ok, err = pcall(footnotes.orphans)
  vim.notify = orig
  if not ok then error(err) end
  return table.concat(captured, "\n")
end

-- ---------------------------------------------------------------------------
-- Editing unrelated prose must not change the footnote report (cache hit).
-- ---------------------------------------------------------------------------
test("editing non-footnote prose leaves orphan report unchanged", function()
  local buf = orphans_for({
    "Some prose here[^a].",
    "More prose, no footnotes.",
    "",
    "[^a]: definition for a",
    "[^b]: orphan def with no ref",
  })
  local before = capture_orphans()

  -- Mutate a plain prose line that contains no ref/def/continuation.
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Completely different prose." })
  local after = capture_orphans()

  assert_eq(after, before, "orphan report changed after an unrelated prose edit")
  -- Sanity: the report actually reported the orphan def, not an empty result.
  assert_eq(before:match("%[%^b%]") ~= nil, true, "expected [^b] orphan in report")
end)

-- ---------------------------------------------------------------------------
-- Editing a footnote line must change the report (signature invalidation).
-- ---------------------------------------------------------------------------
test("editing a footnote ref updates the orphan report", function()
  local buf = orphans_for({
    "Prose with a ref[^a].",
    "[^a]: definition for a",
  })
  local before = capture_orphans()
  -- No orphans: [^a] is referenced and defined.
  assert_eq(before:match("Orphans") == nil, true, "expected no orphans initially")

  -- Introduce an orphan reference to [^missing] with no definition.
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "Prose with a ref[^a] and[^missing]." })
  local after = capture_orphans()

  assert_eq(after:match("%[%^missing%]") ~= nil, true, "expected [^missing] to appear as an orphan ref")
end)

-- ---------------------------------------------------------------------------
-- Inserting a plain prose line above a definition shifts its lnum; the report's
-- line numbers must update (the signature encodes lnum, so it invalidates).
-- ---------------------------------------------------------------------------
test("inserting a line shifts reported definition lnum", function()
  local buf = orphans_for({
    "[^b]: orphan def",
  })
  local before = capture_orphans()
  assert_eq(before:match("at line 1") ~= nil, true, "expected def at line 1 initially")

  -- Insert a prose line at the top, shifting the def down to line 2.
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "New first line." })
  local after = capture_orphans()
  assert_eq(after:match("at line 2") ~= nil, true, "expected def to shift to line 2")
end)

-- ---------------------------------------------------------------------------
-- Editing a continuation line (indented) must be reflected; here we verify a
-- multi-line definition is still recognized as a defined (non-orphan) footnote
-- before and after editing its continuation text.
-- ---------------------------------------------------------------------------
test("continuation-line edits keep definition recognized", function()
  local buf = orphans_for({
    "Text with ref[^c].",
    "[^c]: first line of def",
    "    continued line",
  })
  local before = capture_orphans()
  assert_eq(before:match("Orphans") == nil, true, "expected no orphans (c is ref'd + defined)")

  -- Edit the continuation line (starts with whitespace -> in the signature).
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "    edited continuation" })
  local after = capture_orphans()
  assert_eq(after:match("Orphans") == nil, true, "expected still no orphans after continuation edit")
end)

_H.finish({ style = "results", exit = "os" })
