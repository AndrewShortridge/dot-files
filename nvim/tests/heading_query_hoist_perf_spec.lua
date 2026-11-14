-- Perf regression spec for the markdown ftplugin heading navigation.
--
-- The heading treesitter query used to be a file-local in ftplugin/markdown.lua,
-- so it was re-parsed (recompiled) on EVERY markdown buffer open (every
-- FileType markdown / :e / split). It is now compiled ONCE per session, cached
-- on _G.__md_heading_query. Additionally get_headings() used to re-parse the
-- tree and do one nvim_buf_get_lines per heading on every ]#/[#/]1..]6 press;
-- it is now memoized per (buffer, changedtick) on _G.__md_headings_cache.
--
-- This drives the REAL ftplugin (ftplugin/markdown.lua) against markdown
-- buffers in a temp vault, with counting wrappers around
-- vim.treesitter.query.parse and vim.api.nvim_buf_get_lines. No source
-- introspection.
--
-- Discriminating power:
--   Test 1: reintroducing the per-source `local heading_query =
--           vim.treesitter.query.parse(...)` makes the atx_heading parse count
--           jump from 1 to N, failing the assertion.
--   Test 2: reverting the changedtick memo makes get_headings recompute (extra
--           per-heading buffer reads) on the second press with no edit, failing
--           the cache-hit assertion.
--   Test 3: heading motions (]#/[#, ]1..]6) still land on the right rows.
-- Heading nav lives on ]# / [#, not ]h / [h: vault/highlights.lua binds ]h / [h
-- buffer-locally (==highlight== nav) after the ftplugin runs and always wins.
--
-- Run with: nvim --headless -u NONE -l tests/heading_query_hoist_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

local config_dir = vim.fn.stdpath("config")
local ftplugin_path = config_dir .. "/ftplugin/markdown.lua"

print("\n=== Heading Query Hoist Perf Tests ===\n")

-- Stub which-key so the ftplugin's wk.add doesn't error / pollute (we only care
-- about the heading machinery here).
package.loaded["which-key"] = { setup = function() end, add = function() end }

-- Clear session caches so the test starts clean.
_G.__md_heading_query = nil
_G.__md_headings_cache = nil
vim.g.__md_wk_registered = nil

-- ---------------------------------------------------------------------------
-- Counting wrapper around treesitter query.parse, installed BEFORE dofile.
-- We only count parses whose query string targets atx_heading so unrelated
-- parses (from other modules the ftplugin requires) don't pollute the count.
-- ---------------------------------------------------------------------------
local real_parse = vim.treesitter.query.parse
local atx_parse_calls = 0
vim.treesitter.query.parse = function(lang, q)
  if type(q) == "string" and q:find("atx_heading", 1, true) then
    atx_parse_calls = atx_parse_calls + 1
  end
  return real_parse(lang, q)
end

local vault = vim.fn.tempname()
vim.fn.mkdir(vault, "p")
local N = 8
local bufs = {}
local SEED = { "# H1", "prose", "## H2", "### H3" }

for i = 1, N do
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, vault .. "/note_" .. i .. ".md")
  bufs[i] = buf
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, SEED)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  dofile(ftplugin_path)
end

-- ---------------------------------------------------------------------------
-- Test 1 (discriminating — query hoist): the atx_heading query is compiled
-- exactly once across N ftplugin sourcings.
-- ---------------------------------------------------------------------------
test("heading query compiled exactly once across N buffer opens", function()
  assert_eq(atx_parse_calls, 1, "heading query must be parsed once per session, not per-buffer")
  assert_true(_G.__md_heading_query ~= nil, "cached query object must be present after sourcing")
end)

-- ---------------------------------------------------------------------------
-- Test 2 (discriminating — changedtick memo): get_headings is memoized per
-- (buffer, changedtick). We count per-heading buffer reads done by
-- get_headings; two heading-nav presses with NO intervening edit must do the
-- per-heading reads at most once (cache hit on the second). After an edit
-- (changedtick bump), it recomputes.
--
-- We isolate get_headings' reads by wrapping nvim_buf_get_lines and only
-- counting single-row reads of the current buffer (the shape get_headings uses:
-- nvim_buf_get_lines(0, row, row+1, false)).
-- ---------------------------------------------------------------------------

-- Use a fresh buffer with known headings.
local nav_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(nav_buf, vault .. "/nav.md")
local NAV = {
  "# Title",  -- row 1, level 1
  "intro",    -- 2
  "## Sub A", -- 3, level 2
  "body",     -- 4
  "## Sub B", -- 5, level 2
  "more",     -- 6
  "### Deep", -- 7, level 3
}
vim.api.nvim_buf_set_lines(nav_buf, 0, -1, false, NAV)
vim.api.nvim_set_current_buf(nav_buf)
vim.bo[nav_buf].filetype = "markdown"
dofile(ftplugin_path)

-- Wrap nvim_buf_get_lines to count get_headings-shaped per-heading reads
-- (single-row reads, end == start + 1) of the current buffer.
local real_get_lines = vim.api.nvim_buf_get_lines
local heading_reads = 0
vim.api.nvim_buf_get_lines = function(b, s, e, strict)
  if (b == 0 or b == nav_buf) and e == s + 1 then
    heading_reads = heading_reads + 1
  end
  return real_get_lines(b, s, e, strict)
end

-- Open a window so the heading motions (which use win_set_cursor) work.
vim.cmd("buffer " .. nav_buf)
vim.api.nvim_win_set_cursor(0, { 1, 0 })

local function press(keys)
  local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcodes, "x", false)
end

test("get_headings is changedtick-memoized (no recompute without an edit)", function()
  heading_reads = 0
  -- First nav press: computes headings (reads each heading line once).
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press("]#")
  local after_first = heading_reads
  assert_true(after_first > 0, "first nav must read heading lines (compute path)")

  -- Second nav press WITHOUT editing: must hit the cache => no new reads.
  press("]#")
  assert_eq(heading_reads, after_first, "second nav with no edit must hit changedtick cache (no extra reads)")

  -- Now mutate the buffer (bumps changedtick) and nav again: must recompute.
  vim.api.nvim_buf_set_lines(nav_buf, 1, 1, false, { "inserted line" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press("]#")
  assert_true(heading_reads > after_first, "after an edit (changedtick bump) headings must recompute")
end)

-- ---------------------------------------------------------------------------
-- Test 3 (behavior preserved): heading motions still land on the right rows.
-- ---------------------------------------------------------------------------
test("]# / [# / ]2 navigation still lands on the correct headings", function()
  -- Reset to the original NAV content (Test 2 inserted a line).
  vim.api.nvim_buf_set_lines(nav_buf, 0, -1, false, NAV)

  -- ]# from top -> first heading after row 1 is row 3 (## Sub A).
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press("]#")
  assert_eq(vim.api.nvim_win_get_cursor(0)[1], 3, "]# from row 1 should land on row 3")

  -- ]2 from row 1 -> next level-2 heading is row 3 (## Sub A).
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press("]2")
  assert_eq(vim.api.nvim_win_get_cursor(0)[1], 3, "]2 from row 1 should land on row 3 (first h2)")

  -- ]2 from row 3 -> next level-2 heading is row 5 (## Sub B).
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  press("]2")
  assert_eq(vim.api.nvim_win_get_cursor(0)[1], 5, "]2 from row 3 should land on row 5 (second h2)")

  -- [# from bottom (row 7) -> previous heading is row 5 (## Sub B).
  vim.api.nvim_win_set_cursor(0, { 7, 0 })
  press("[#")
  assert_eq(vim.api.nvim_win_get_cursor(0)[1], 5, "[# from row 7 should land on row 5")
end)

-- Cleanup: restore patched fns, delete buffers, clear caches.
vim.api.nvim_buf_get_lines = real_get_lines
vim.treesitter.query.parse = real_parse
for _, buf in ipairs(bufs) do
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end
pcall(vim.api.nvim_buf_delete, nav_buf, { force = true })
_G.__md_heading_query = nil
_G.__md_headings_cache = nil
vim.g.__md_wk_registered = nil
package.loaded["which-key"] = nil
pcall(vim.fn.delete, vault, "rf")

_H.finish({ style = "results", exit = "os" })
