-- Behavioral spec for the get_link_ranges short-circuit in
-- link_scan.scan_buffer_names.
--
-- scan_buffer_names runs per-line on every autolink scroll/edit. For lines that
-- contain neither a literal '[' nor the substring "http", no wikilink / markdown
-- link / URL can exist, so the (multi-pass) get_link_ranges scan is skipped and a
-- shared EMPTY_RANGES table is reused. The byte-gate MUST be exact: lines that DO
-- contain '[' or "http" must still compute real link_ranges so that
-- overlaps_range suppresses bare-name occurrences sitting inside link/URL syntax.
--
-- This drives the REAL link_scan + REAL vault_index against a temp vault (no
-- mock) and asserts observable match output only:
--   1. Link-free prose line: the bare name IS matched (short-circuit path).
--   2. A name inside a wikilink (line has '[') is suppressed, while a bare
--      mention on the SAME line is matched (ranges computed for '['-lines).
--   3. A name inside a URL (line has "http", no '[') is suppressed, while a bare
--      mention on the same line is matched (ranges computed for "http"-lines).
--
-- Discriminating power: if the gate is broken so '['/"http" lines also get
-- EMPTY_RANGES, assertions 2 and 3 fail (the bracketed / URL occurrences wrongly
-- become matches).
--
-- Run with: nvim --headless -u NONE -l tests/link_scan_link_range_skip_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_true = _H.test, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vi = require("andrew.vault.vault_index")
local link_scan = require("andrew.vault.link_scan")

print("\n=== link_scan get_link_ranges short-circuit Tests ===\n")

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

-- Collect matches as a list of { name, start_col } on a given row.
local function matches_on(buf, opts)
  local out = {}
  for _, m in ipairs(link_scan.scan_buffer_names(buf, opts)) do
    out[#out + 1] = { name = m.note_name, start_col = m.start_col, row = m.row }
  end
  return out
end

-- Count how many times `name` matched on `row`.
local function count_on_row(ms, name, row)
  local n = 0
  for _, m in ipairs(ms) do
    if m.name == name and m.row == row then n = n + 1 end
  end
  return n
end

-- ===========================================================================
-- 1. Link-free prose line: short-circuit path returns EMPTY_RANGES, the bare
--    name is still matched.
-- ===========================================================================
test("link-free prose line still matches the bare name", function()
  make_indexed_vault({
    ["alpha note.md"] = { "# Alpha Note" },
  })
  -- No '[' and no "http" anywhere on the line -> short-circuit branch.
  local buf = make_buffer({ "I mention alpha note here." })
  local ms = matches_on(buf)
  assert_true(count_on_row(ms, "alpha note", 0) == 1, "alpha note matched once on link-free line")
end)

-- ===========================================================================
-- 2. Wikilink line (contains '['): the bracketed occurrence is suppressed by
--    real link_ranges; a bare mention on the same line is matched.
-- ===========================================================================
test("name inside a wikilink is suppressed; bare mention on same line matches", function()
  make_indexed_vault({
    ["alpha note.md"] = { "# Alpha Note" },
  })
  -- Bare mention first, then the same name inside a wikilink ('[' present).
  local buf = make_buffer({ "see alpha note then [[alpha note]] again" })
  local ms = matches_on(buf)
  -- Exactly one match: the bare mention. The bracketed one overlaps a link range.
  assert_true(count_on_row(ms, "alpha note", 0) == 1,
    "exactly one alpha note match (bare yes, bracketed suppressed)")
end)

-- ===========================================================================
-- 3. URL line (contains "http", no '['): a name overlapping URL bytes is
--    suppressed; a name outside the URL on the same line is matched.
-- ===========================================================================
test("name inside a URL is suppressed; bare mention on same line matches", function()
  make_indexed_vault({
    ["alpha.md"] = { "# Alpha" },
  })
  -- "alpha" appears inside the URL host AND as a bare word. No '[' on the line,
  -- so this exercises the "http"-without-'[' branch (real ranges still built).
  local buf = make_buffer({ "alpha see https://alpha.example.com end" })
  local ms = matches_on(buf)
  -- The first bare "alpha" matches; the one inside the URL is suppressed.
  assert_true(count_on_row(ms, "alpha", 0) == 1,
    "exactly one alpha match (bare yes, in-URL suppressed)")
  -- And the matched one is the bare leading occurrence (col 0), not the URL one.
  local bare = false
  for _, m in ipairs(ms) do
    if m.name == "alpha" and m.start_col == 0 then bare = true end
  end
  assert_true(bare, "the matched alpha is the bare leading occurrence")
end)

_H.finish({ style = "results", exit = "os" })
