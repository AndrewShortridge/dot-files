-- Regression spec for the #tag LEFT BOUNDARY fix.
--
-- patterns.M.TAG used to be "#([%w_%-][%w_%-/]*)" — a bare '#' with no left
-- boundary. Every '#' followed by a word char therefore registered as a tag,
-- so a wikilink heading anchor ([[Alpha Project#Goals]]), an embed heading
-- anchor (![[Beta#Details]]) and a URL fragment (https://x.com#install) all
-- produced PHANTOM tags. Those leaked into :VaultTags, the tag tree, the tag
-- sidebar and tag completion — and dangerously into the :VaultTagRemove /
-- :VaultTagRename pick lists, where acting on a phantom rewrites real text.
--
-- The fix captures the '#' position (M.TAG = "()#([%w_%-][%w_%-/]*)") and every
-- consumer rejects a match whose preceding byte is a word char, ']', '-', '.'
-- or '/' (patterns.tag_boundary_ok). patterns.gmatch_tags applies the check
-- (plus the pre-existing purely-numeric exclusion) so callers stay unchanged.
--
-- Coverage is at both levels: the shared iterator/predicate in patterns.lua and
-- the real body-tag + task-tag scans in vault_index_parser.parse_content.
--
-- Run with: nvim --headless -u NONE -l tests/tag_pattern_boundary_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false = _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local pat = require("andrew.vault.patterns")
local parser = require("andrew.vault.vault_index_parser")

print("\n=== tag pattern left-boundary Tests ===\n")

-- Collect the tags patterns.gmatch_tags yields for one line, in order.
local function tags_of(line)
  local out = {}
  for tag in pat.gmatch_tags(line) do
    out[#out + 1] = tag
  end
  return out
end

local function set_of(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

-- parse_content reads stat.mtime/stat.size for the entry; a minimal stub keeps
-- the spec filesystem-free.
local STAT = { mtime = { sec = 0 }, size = 0 }

-- Parse a note body through the real index parser and return its tag set.
local function parsed_tags(body_lines)
  local entry = parser.parse_content(table.concat(body_lines, "\n"), "Note.md", STAT)
  return set_of(entry.tags or {})
end

-- ===========================================================================
-- 1. Real tags are still collected (including nested a/b form).
-- ===========================================================================
test("plain tags are collected, nested tags keep their slash", function()
  assert_eq(table.concat(tags_of("#home #project/alpha"), ","), "home,project/alpha",
    "both tags yielded in order")
end)

-- ===========================================================================
-- 2. Wikilink heading anchors are NOT tags.
-- ===========================================================================
test("wikilink heading anchor yields no tag", function()
  assert_eq(#tags_of("see [[Alpha Project#Goals]] for details"), 0, "no phantom tag")
end)

-- ===========================================================================
-- 3. Embed heading anchors are NOT tags.
-- ===========================================================================
test("embed heading anchor yields no tag", function()
  assert_eq(#tags_of("![[Beta#Details]]"), 0, "no phantom tag")
end)

-- ===========================================================================
-- 4. URL fragments are NOT tags.
-- ===========================================================================
test("URL fragment yields no tag", function()
  assert_eq(#tags_of("docs at https://x.com#install today"), 0, "no phantom tag")
end)

-- ===========================================================================
-- 5. Markdown headings are NOT tags ('#' followed by '#' or by a space).
-- ===========================================================================
test("markdown heading yields no tag", function()
  assert_eq(#tags_of("## Heading"), 0, "no phantom tag from heading markers")
end)

-- ===========================================================================
-- 6. A '#' glued to the end of a word is NOT a tag.
-- ===========================================================================
test("word#notatag yields no tag", function()
  assert_eq(#tags_of("word#notatag"), 0, "word-char left neighbour rejected")
end)

-- ===========================================================================
-- 7. Punctuation that is NOT in the reject set still opens a tag.
-- ===========================================================================
test("tag after an opening paren is still a tag", function()
  assert_eq(table.concat(tags_of("(#paren)"), ","), "paren", "'(' is a valid left boundary")
end)

-- ===========================================================================
-- 8. Purely numeric "#123" is excluded (pre-existing rule, preserved).
-- ===========================================================================
test("numeric-only #123 yields no tag", function()
  assert_eq(#tags_of("issue #123 filed"), 0, "numeric-only tag excluded")
end)

-- ===========================================================================
-- 9. tag_boundary_ok predicate directly: start-of-line and each reject byte.
-- ===========================================================================
test("tag_boundary_ok accepts start-of-line/space and rejects word/]/-/./ bytes", function()
  assert_true(pat.tag_boundary_ok("#home", 1), "start of line accepted")
  assert_true(pat.tag_boundary_ok("a #home", 3), "space accepted")
  assert_false(pat.tag_boundary_ok("x#home", 2), "word char rejected")
  assert_false(pat.tag_boundary_ok("]#home", 2), "']' rejected")
  assert_false(pat.tag_boundary_ok("-#home", 2), "'-' rejected")
  assert_false(pat.tag_boundary_ok(".#home", 2), "'.' rejected")
  assert_false(pat.tag_boundary_ok("/#home", 2), "'/' rejected")
end)

-- ===========================================================================
-- 10. END-TO-END body-tag scan: vault_index_parser.parse_content sees the real
--     tags and none of the phantoms, with frontmatter tags merged in.
-- ===========================================================================
test("parse_content body scan collects real tags only", function()
  local tags = parsed_tags({
    "---",
    "tags: [fm-one, fm/two]",
    "---",
    "## Heading",
    "Real tags: #home #project/alpha",
    "Links: [[Alpha Project#Goals]] and ![[Beta#Details]]",
    "URL: https://x.com#install",
    "Glued: word#notatag and issue #123",
    "Parens: (#paren)",
  })

  assert_true(tags["home"], "#home collected")
  assert_true(tags["project/alpha"], "#project/alpha collected")
  assert_true(tags["project"], "parent of a nested tag collected")
  assert_true(tags["paren"], "(#paren) collected")
  assert_true(tags["fm-one"], "frontmatter tag collected")

  assert_false(tags["Goals"], "wikilink heading anchor is not a tag")
  assert_false(tags["Details"], "embed heading anchor is not a tag")
  assert_false(tags["install"], "URL fragment is not a tag")
  assert_false(tags["notatag"], "word#notatag is not a tag")
  assert_false(tags["Heading"], "markdown heading is not a tag")
  assert_false(tags["123"], "numeric-only is not a tag")
end)

-- ===========================================================================
-- 11. END-TO-END task-tag scan: the per-task tag list obeys the same boundary.
-- ===========================================================================
test("parse_content task scan collects real task tags only", function()
  local content = table.concat({
    "- [ ] task one #urgent see [[Alpha Project#Goals]] at https://x.com#install",
    "- [x] task two ![[Beta#Details]] #done/late",
  }, "\n")
  local entry = parser.parse_content(content, "Note.md", STAT)
  local tasks = entry.tasks or {}
  assert_eq(#tasks, 2, "both tasks parsed")

  local t1 = set_of(tasks[1].tags or {})
  assert_true(t1["urgent"], "#urgent collected on task 1")
  assert_false(t1["Goals"], "wikilink heading anchor not a task tag")
  assert_false(t1["install"], "URL fragment not a task tag")

  local t2 = set_of(tasks[2].tags or {})
  assert_true(t2["done/late"], "#done/late collected on task 2")
  assert_false(t2["Details"], "embed heading anchor not a task tag")
end)

_H.finish({ style = "results", exit = "os" })
