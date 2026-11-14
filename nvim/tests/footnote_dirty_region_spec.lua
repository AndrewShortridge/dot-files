-- Perf + correctness spec for footnote-map invalidation (issue T2).
--
-- parse_all_footnotes_cached() rebuilds its invalidation signature on every
-- changedtick miss. The OLD signature source was footnote_signature(), which
-- read the ENTIRE buffer (nvim_buf_get_lines(bufnr, 0, -1)) and ran up to four
-- regexes per line — on every keystroke in a footnote-bearing note. The fix
-- derives the signature from the WARM pipeline parse cache (line_parse_cache),
-- which is already kept in sync incrementally, falling back to the whole-buffer
-- read only when the cache is cold or incomplete (eviction).
--
-- PERF: when the parse cache is warm and an edit touches a NON-footnote line,
-- a footnote query (M.orphans) must NOT perform any whole-buffer (0,-1) read.
-- Reintroducing the whole-buffer footnote_signature makes this read >= 1 -> fails.
--
-- CORRECTNESS: editing a footnote line must still invalidate the map and update
-- the reported orphans. The existing cold-cache footnote_cache_spec covers the
-- fallback path; this spec covers the warm-cache path.
--
-- Drives the REAL footnotes + line_parse_cache modules against a scratch buffer.
-- No source introspection.
--
-- Run with: nvim --headless -u NONE -l tests/footnote_dirty_region_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local footnotes = require("andrew.vault.footnotes")
local line_parse = require("andrew.vault.line_parse_cache")

print("\n=== Footnote Dirty-Region Tests ===\n")

-- No code-block exclusion in these scratch buffers.
local function code_excl() return false end

-- Seed a fresh scratch buffer and warm the line parse cache over the whole
-- buffer, mirroring what transform_pipeline.run() does (line_parse.update)
-- before footnotes' coordinated_update reads the map.
local function fresh_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  line_parse.update(buf, nil, code_excl) -- full warm
  return buf
end

-- Apply an in-place single-line edit and re-warm ONLY that dirty line through
-- the parse cache (the pipeline's incremental path), then return.
local function edit_line(buf, lnum0, text)
  vim.api.nvim_buf_set_lines(buf, lnum0, lnum0 + 1, false, { text })
  line_parse.update(buf, { lnum0 }, code_excl)
end

-- Run M.orphans() while counting whole-buffer nvim_buf_get_lines(0, -1) reads.
-- Returns (report_text, whole_buffer_read_count).
local function orphans_counting_reads()
  local whole_reads = 0
  local orig_lines = vim.api.nvim_buf_get_lines
  vim.api.nvim_buf_get_lines = function(b, s, e, strict)
    if s == 0 and e == -1 then whole_reads = whole_reads + 1 end
    return orig_lines(b, s, e, strict)
  end
  local captured = {}
  local orig_notify = vim.notify
  vim.notify = function(msg) captured[#captured + 1] = msg end
  local ok, err = pcall(footnotes.orphans)
  vim.notify = orig_notify
  vim.api.nvim_buf_get_lines = orig_lines
  if not ok then error(err) end
  return table.concat(captured, "\n"), whole_reads
end

-- ---------------------------------------------------------------------------
-- PERF: a non-footnote edit on a warm cache triggers no whole-buffer read.
-- ---------------------------------------------------------------------------
test("warm cache: non-footnote edit triggers no whole-buffer signature read", function()
  local buf = fresh_buf({
    "Some prose here[^a].",
    "More prose, no footnotes.",
    "",
    "[^a]: definition for a",
    "[^b]: orphan def with no ref",
  })

  -- Prime the footnote cache (this first call legitimately parses the buffer).
  local before, _ = orphans_counting_reads()
  assert_true(before:match("%[%^b%]") ~= nil, "expected [^b] orphan in initial report")

  -- Edit a plain prose line that contains no ref/def/continuation, then re-warm
  -- just that dirty line — exactly what happens per keystroke via the pipeline.
  edit_line(buf, 1, "Completely different prose, still no footnotes.")

  local after, whole_reads = orphans_counting_reads()

  -- The signature is unchanged (the edited line is not footnote-relevant), so
  -- the map is reused without re-parsing AND without a whole-buffer read.
  assert_eq(whole_reads, 0, "non-footnote edit must not read the whole buffer")
  assert_eq(after, before, "orphan report changed after an unrelated prose edit")
end)

-- ---------------------------------------------------------------------------
-- CORRECTNESS: editing a footnote line on a warm cache still updates the map.
-- ---------------------------------------------------------------------------
test("warm cache: editing a footnote ref still updates the orphan report", function()
  local buf = fresh_buf({
    "Prose with a ref[^a].",
    "[^a]: definition for a",
  })

  local before, _ = orphans_counting_reads()
  assert_eq(before:match("Orphans") == nil, true, "expected no orphans initially")

  -- Introduce an orphan reference [^missing] on a footnote-relevant line.
  edit_line(buf, 0, "Prose with a ref[^a] and[^missing].")

  local after, _ = orphans_counting_reads()
  assert_true(after:match("%[%^missing%]") ~= nil, "expected [^missing] orphan after footnote edit")
end)

-- ---------------------------------------------------------------------------
-- CORRECTNESS: a line insert (lnum shift) on a warm cache updates reported lnum.
-- ---------------------------------------------------------------------------
test("warm cache: inserting a line shifts reported definition lnum", function()
  local buf = fresh_buf({
    "[^b]: orphan def",
  })
  local before, _ = orphans_counting_reads()
  assert_true(before:match("at line 1") ~= nil, "expected def at line 1 initially")

  -- Insert a prose line at the top; re-warm the whole buffer (mirrors a shift +
  -- reparse). The def shifts to line 2 and the signature (lnum-prefixed) changes.
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "New first line." })
  line_parse.update(buf, nil, code_excl)

  local after, _ = orphans_counting_reads()
  assert_true(after:match("at line 2") ~= nil, "expected def to shift to line 2")
end)

_H.finish({ style = "results", exit = "os" })
