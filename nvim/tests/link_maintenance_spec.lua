-- Unit tests for vault link-maintenance modules:
--   url_validate (extract_urls / classify_status / class_to_severity)
--   search_query.edit_distance, linkdiag.find_closest
--   link_utils.replace_link_note / replace_link_heading
--   rename._compute_rename_changes (offline, no-index path)
--   linkcheck.scan_broken_links (temp vault, real rg + vault_index)
-- Run with: nvim --headless -u NONE -l tests/link_maintenance_spec.lua

local _SRCDIR = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]")
local _H = dofile(_SRCDIR .. "/spec_helper.lua")
local _F = dofile(_SRCDIR .. "/fixtures.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

--- Substring containment helper (plain find, no patterns).
local function assert_contains(haystack, needle, msg)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error((msg or "expected substring") .. " " .. vim.inspect(needle) .. " in: " .. vim.inspect(haystack))
  end
end

-- ============================================================================
-- Load modules under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local url_validate = require("andrew.vault.url_validate")
local linkdiag = require("andrew.vault.linkdiag")
local search_query = require("andrew.vault.search_query")
local link_utils = require("andrew.vault.link_utils")
local rename = require("andrew.vault.rename")
local linkcheck = require("andrew.vault.linkcheck")
local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")

-- ============================================================================
-- Helpers for temp-vault tests
-- ============================================================================

-- Temp-vault primitives shared with other specs, sourced from tests/fixtures.lua.
local make_tmp_dir = _F.make_tmp_dir
local write_file = _F.write_file

print("\n=== Link Maintenance Tests ===\n")

-- ---------------------------------------------------------------------------
-- 1. url_validate.extract_urls (pure, offline — no network)
-- ---------------------------------------------------------------------------

test("extract_urls: markdown link captured with kind=markdown", function()
  local urls = url_validate.extract_urls({ "See [docs](https://example.com/path) here" })
  assert_eq(#urls, 1, "entry count")
  assert_eq(urls[1].url, "https://example.com/path", "url")
  assert_eq(urls[1].lnum, 1, "lnum")
  assert_eq(urls[1].kind, "markdown", "kind")
end)

test("extract_urls: bare URL captured with kind=bare", function()
  local urls = url_validate.extract_urls({ "bare https://foo.org/x end" })
  assert_eq(#urls, 1, "entry count")
  assert_eq(urls[1].url, "https://foo.org/x", "url")
  assert_eq(urls[1].lnum, 1, "lnum")
  assert_eq(urls[1].kind, "bare", "kind")
end)

test("extract_urls: URLs inside fenced code block are skipped", function()
  local urls = url_validate.extract_urls({ "```", "https://incode.example/skip", "```" })
  assert_eq(#urls, 0, "code-fenced URL should be skipped")
end)

test("extract_urls: non-URL plain text yields nothing", function()
  local urls = url_validate.extract_urls({ "just plain text, no link here" })
  assert_eq(#urls, 0, "plain text should yield no URLs")
end)

test("extract_urls: wikilink http target yields bare+wikilink pair (current behavior)", function()
  -- SUSPECTED BUG: a [[https://...|alias]] wikilink produces TWO entries for the
  -- same URL — the bare-URL pass captures it first (URL_PAT stops at '|'), and the
  -- wikilink pass adds a second entry. The dedup loop only suppresses overlap with
  -- markdown entries already collected, not the later wikilink pass. This test pins
  -- the exact CURRENT behavior; if dedup is ever fixed, update the count to 1.
  local urls = url_validate.extract_urls({ "[[https://wiki.link|alias]] tail" })
  assert_eq(#urls, 2, "current behavior: duplicate bare + wikilink entries")
  local kinds = {}
  for _, u in ipairs(urls) do
    assert_eq(u.url, "https://wiki.link", "both entries share the url")
    assert_eq(u.lnum, 1, "lnum")
    kinds[u.kind] = true
  end
  assert_true(kinds["wikilink"], "a wikilink-kind entry must exist")
  assert_true(kinds["bare"], "a bare-kind duplicate exists (suspected bug)")
end)

-- ---------------------------------------------------------------------------
-- 2. url_validate.classify_status / class_to_severity (pure)
-- ---------------------------------------------------------------------------

test("classify_status: full mapping table", function()
  assert_eq(url_validate.classify_status(-1), "excluded", "-1")
  assert_eq(url_validate.classify_status(-2), "pending", "-2")
  assert_eq(url_validate.classify_status(0), "error", "0")
  assert_eq(url_validate.classify_status(200), "ok", "200")
  assert_eq(url_validate.classify_status(204), "ok", "204")
  assert_eq(url_validate.classify_status(301), "redirect", "301")
  assert_eq(url_validate.classify_status(404), "dead", "404")
  assert_eq(url_validate.classify_status(500), "dead", "500")
end)

test("class_to_severity: dead maps to WARN, ok maps to nil", function()
  assert_eq(url_validate.class_to_severity("dead"), vim.diagnostic.severity.WARN, "dead")
  assert_eq(url_validate.class_to_severity("dead"), 2, "WARN numeric value")
  assert_eq(url_validate.class_to_severity("error"), vim.diagnostic.severity.WARN, "error")
  assert_nil(url_validate.class_to_severity("ok"), "ok")
  assert_nil(url_validate.class_to_severity("redirect"), "redirect")
end)

-- ---------------------------------------------------------------------------
-- 3. search_query.edit_distance (pure Levenshtein)
-- ---------------------------------------------------------------------------

test("edit_distance: classic Levenshtein values", function()
  assert_eq(search_query.edit_distance("kitten", "sitting"), 3, "kitten/sitting")
  assert_eq(search_query.edit_distance("project", "projekt"), 1, "project/projekt")
  assert_eq(search_query.edit_distance("", "abc"), 3, "empty/abc")
end)

-- ---------------------------------------------------------------------------
-- 4. linkdiag.find_closest (fuzzy candidate ranking used by link_repair)
--    threshold = max(floor(#query * 0.6), 5) with default config
-- ---------------------------------------------------------------------------

test("find_closest: resolves broken name to nearest candidates, sorted ascending", function()
  local results = linkdiag.find_closest(
    "project",
    { "project", "projekt", "prajects", "totally-different", "unrelated" },
    5
  )
  -- threshold = max(floor(7*0.6)=4, 5) = 5; the two far candidates are rejected
  assert_eq(#results, 3, "result count")
  assert_eq(results[1].name, "project", "exact match first")
  assert_eq(results[1].dist, 0, "exact match dist")
  assert_eq(results[2].name, "projekt", "second")
  assert_eq(results[2].dist, 1, "second dist")
  assert_eq(results[3].name, "prajects", "third")
  assert_eq(results[3].dist, 2, "third dist")
end)

test("find_closest: too-distant candidates are rejected", function()
  local results = linkdiag.find_closest("cat", { "hat", "dog", "xyzzy123456" }, 5)
  -- threshold = max(floor(3*0.6)=1, 5) = 5; xyzzy123456 (dist 8) rejected
  assert_eq(#results, 2, "result count")
  assert_eq(results[1].name, "hat", "closest first")
  assert_eq(results[1].dist, 1, "hat dist")
  assert_eq(results[2].name, "dog", "second")
  assert_eq(results[2].dist, 3, "dog dist")
end)

test("find_closest: n cap limits result count", function()
  local results = linkdiag.find_closest("cat", { "bat", "hat", "cap", "car" }, 2)
  assert_eq(#results, 2, "capped to n=2")
  for i, r in ipairs(results) do
    assert_eq(r.dist, 1, "result " .. i .. " dist")
  end
end)

test("find_closest: longer query raises threshold proportionally", function()
  -- threshold = max(floor(12*0.6)=7, 5) = 7
  local results = linkdiag.find_closest(
    "abcdefghijkl",
    { "abcdefXXXXXX", "totallyunrelatedstring999" },
    5
  )
  assert_eq(#results, 1, "result count")
  assert_eq(results[1].name, "abcdefXXXXXX", "kept candidate")
  assert_eq(results[1].dist, 6, "dist 6 <= threshold 7")
end)

-- ---------------------------------------------------------------------------
-- 5. link_utils.replace_link_note / replace_link_heading (pure)
-- ---------------------------------------------------------------------------

test("replace_link_note: preserves alias suffix", function()
  assert_eq(link_utils.replace_link_note("[[Old|alias]]", "New"), "[[New|alias]]")
end)

test("replace_link_note: preserves heading suffix", function()
  assert_eq(link_utils.replace_link_note("[[Old#Head]]", "New"), "[[New#Head]]")
end)

test("replace_link_note: plain link", function()
  assert_eq(link_utils.replace_link_note("[[Old]]", "New"), "[[New]]")
end)

test("replace_link_note: non-wikilink returns nil", function()
  assert_nil(link_utils.replace_link_note("Old", "New"))
end)

test("replace_link_heading: replaces anchor, keeps name+alias", function()
  assert_eq(link_utils.replace_link_heading("[[Note#OldH|a]]", "NewH"), "[[Note#NewH|a]]")
end)

-- ---------------------------------------------------------------------------
-- 6. rename._compute_rename_changes (offline path: NO vault index built,
--    build_old_name_set returns only { old_name:lower() })
--    NOTE: run BEFORE the linkcheck tests so no vault index singleton exists.
-- ---------------------------------------------------------------------------

test("compute_rename_changes: rewrites all OldNote forms, leaves Other untouched", function()
  local tmp = make_tmp_dir()
  engine.vault_path = tmp
  local doc = tmp .. "/doc.md"
  write_file(doc, "See [[OldNote]] and [[OldNote|alias]]\nAnd [[OldNote#Sec]] plus [[Other]]\n")

  local info = rename._compute_rename_changes({ doc }, "OldNote", "NewNote", tmp .. "/OldNote.md")
  assert_eq(info.link_count, 3, "link_count")
  assert_eq(info.file_count, 1, "file_count")
  assert_eq(#info.changes, 2, "two changed lines")

  local new_content = info.file_writes[doc]
  assert_true(new_content ~= nil, "file_writes entry exists for doc")
  assert_contains(new_content, "[[NewNote]]", "plain link rewritten")
  assert_contains(new_content, "[[NewNote|alias]]", "alias link rewritten")
  assert_contains(new_content, "[[NewNote#Sec]]", "heading link rewritten")
  assert_contains(new_content, "[[Other]]", "unrelated link preserved")
  assert_true(not new_content:find("OldNote", 1, true), "no OldNote remains")

  -- changes entries point at the right lines
  assert_eq(info.changes[1].lnum, 1, "first change line")
  assert_eq(info.changes[2].lnum, 2, "second change line")
  assert_eq(info.changes[1].filename, doc, "first change filename")
end)

test("compute_rename_changes: case-insensitive name match", function()
  local tmp = make_tmp_dir()
  engine.vault_path = tmp
  local doc2 = tmp .. "/doc2.md"
  write_file(doc2, "ref [[oldnote]] and [[OLDNOTE#x]]\n")

  local info = rename._compute_rename_changes({ doc2 }, "OldNote", "NewName", tmp .. "/OldNote.md")
  assert_eq(info.link_count, 2, "link_count")
  local new_content = info.file_writes[doc2]
  assert_true(new_content ~= nil, "file_writes entry exists")
  assert_contains(new_content, "[[NewName]]", "lowercase form rewritten")
  assert_contains(new_content, "[[NewName#x]]", "uppercase+heading form rewritten")
end)

test("compute_rename_changes: no matching links yields empty result", function()
  local tmp = make_tmp_dir()
  engine.vault_path = tmp
  local doc3 = tmp .. "/doc3.md"
  write_file(doc3, "only [[Unrelated]] here\n")

  local info = rename._compute_rename_changes({ doc3 }, "OldNote", "NewName", tmp .. "/OldNote.md")
  assert_eq(info.link_count, 0, "link_count")
  assert_eq(info.file_count, 0, "file_count")
  assert_eq(#info.changes, 0, "changes empty")
  assert_nil(next(info.file_writes), "file_writes empty")
end)

-- ---------------------------------------------------------------------------
-- 7. linkcheck.scan_broken_links (temp vault end-to-end: rg + vault_index)
-- ---------------------------------------------------------------------------

--- Set up a temp vault with the given files, build the index synchronously,
--- run scan_broken_links, and wait for the async callback.
---@param files table<string, string>  relative name -> content
---@return table[] broken, number total
local function scan_temp_vault(files)
  local tmp = _F.make_temp_vault(files)
  engine.vault_path = tmp
  local idx = vault_index.get(tmp)
  idx:build_sync()
  assert_true(idx:is_ready(), "index should be ready after build_sync")

  local done = false
  local got_broken, got_total
  linkcheck.scan_broken_links(function(broken_links, total)
    got_broken = broken_links
    got_total = total
    done = true
  end)
  vim.wait(5000, function() return done end)
  assert_true(done, "scan_broken_links callback should fire within 5s")
  return got_broken, got_total
end

test("scan_broken_links: detects broken note, leaves valid links", function()
  local broken, total = scan_temp_vault({
    ["Alpha.md"] = "# Alpha\nLink to [[Beta]] and [[Ghost]]\n",
    ["Beta.md"] = "# Beta\nback to [[Alpha]]\n",
  })
  assert_eq(total, 3, "total link count")
  assert_eq(#broken, 1, "exactly one broken link")
  local b = broken[1]
  assert_eq(b.target, "Ghost", "broken target")
  assert_eq(b.type, "broken_note", "broken type")
  assert_eq(vim.fn.fnamemodify(b.file, ":t"), "Alpha.md", "broken link source file")
  assert_eq(b.lnum, 2, "broken link line number")
end)

test("scan_broken_links: detects broken heading anchor, valid heading passes", function()
  local broken, total = scan_temp_vault({
    ["Note.md"] = "# Note\n## Real Heading\n",
    ["ref.md"] = "link [[Note#Missing Heading]] and [[Note#Real Heading]]\n",
  })
  assert_eq(total, 2, "total link count")
  assert_eq(#broken, 1, "exactly one broken link")
  local b = broken[1]
  assert_eq(b.target, "Note", "target note")
  assert_eq(b.heading, "Missing Heading", "broken heading anchor")
  assert_eq(b.type, "broken_heading", "broken type")
  assert_eq(vim.fn.fnamemodify(b.file, ":t"), "ref.md", "source file")
end)

test("scan_broken_links: clean vault reports zero broken", function()
  local broken, total = scan_temp_vault({
    ["A.md"] = "[[B]]\n",
    ["B.md"] = "[[A]]\n",
  })
  assert_eq(total, 2, "total link count")
  assert_eq(#broken, 0, "no broken links")
end)

-- ============================================================================
-- Summary
-- ============================================================================
_H.finish({ style = "results", exit = "os" })
