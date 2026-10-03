-- Unit tests for lua/andrew/vault/link_utils.lua (pure functions only)
-- Run with: nvim --headless -u NONE -l tests/link_utils_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

-- ============================================================================
-- Load module under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local link_utils = require("andrew.vault.link_utils")

-- ============================================================================
-- Tests
-- ============================================================================

print("\n=== link_utils Tests ===\n")

-- ---------------------------------------------------------------------------
-- 1. heading_to_slug — lowercase, strip specials, spaces->hyphens
-- ---------------------------------------------------------------------------
test("heading_to_slug lowercases", function()
  assert_eq(link_utils.heading_to_slug("Hello"), "hello")
end)

test("heading_to_slug spaces become hyphens", function()
  assert_eq(link_utils.heading_to_slug("Hello World"), "hello-world")
end)

test("heading_to_slug strips special characters", function()
  assert_eq(link_utils.heading_to_slug("Foo: Bar!"), "foo-bar")
end)

test("heading_to_slug collapses repeated spaces into single hyphen", function()
  assert_eq(link_utils.heading_to_slug("a   b"), "a-b")
end)

test("heading_to_slug trims leading/trailing whitespace", function()
  assert_eq(link_utils.heading_to_slug("  Trim me  "), "trim-me")
end)

test("heading_to_slug is case-insensitive (same slug for differing case)", function()
  assert_eq(link_utils.heading_to_slug("My Heading"), link_utils.heading_to_slug("MY HEADING"))
end)

test("heading_to_slug keeps digits and existing hyphens", function()
  assert_eq(link_utils.heading_to_slug("Chapter 12"), "chapter-12")
end)

-- ---------------------------------------------------------------------------
-- 2. parse_target — wikilink inner parsing
-- ---------------------------------------------------------------------------
test("parse_target plain name", function()
  local t = link_utils.parse_target("My Note")
  assert_eq(t.name, "My Note")
  assert_nil(t.heading)
  assert_nil(t.block_id)
  assert_nil(t.alias)
end)

test("parse_target name#heading", function()
  local t = link_utils.parse_target("Note#Section")
  assert_eq(t.name, "Note")
  assert_eq(t.heading, "Section")
  assert_nil(t.block_id)
end)

test("parse_target name^block", function()
  local t = link_utils.parse_target("Note^abc123")
  assert_eq(t.name, "Note")
  assert_eq(t.block_id, "abc123")
  assert_nil(t.heading)
end)

test("parse_target name#heading^block", function()
  local t = link_utils.parse_target("Note#Section^abc")
  assert_eq(t.name, "Note")
  assert_eq(t.heading, "Section")
  assert_eq(t.block_id, "abc")
end)

test("parse_target alias via pipe", function()
  local t = link_utils.parse_target("Note|Display Name")
  assert_eq(t.name, "Note")
  assert_eq(t.alias, "Display Name")
end)

test("parse_target self-reference #heading (empty name)", function()
  local t = link_utils.parse_target("#Heading")
  assert_eq(t.name, "")
  assert_eq(t.heading, "Heading")
end)

test("parse_target self-reference ^block (empty name)", function()
  local t = link_utils.parse_target("^blk")
  assert_eq(t.name, "")
  assert_eq(t.block_id, "blk")
end)

test("parse_target normalizes escaped pipe", function()
  local t = link_utils.parse_target("Note\\|Alias")
  assert_eq(t.name, "Note")
  assert_eq(t.alias, "Alias")
end)

-- ---------------------------------------------------------------------------
-- 3. Pure path helpers
-- ---------------------------------------------------------------------------
test("get_basename strips dir and extension", function()
  assert_eq(link_utils.get_basename("notes/sub/My Note.md"), "My Note")
end)

test("get_tail keeps extension, drops directory", function()
  assert_eq(link_utils.get_tail("notes/sub/My Note.md"), "My Note.md")
end)

test("rel_to_stem strips .md", function()
  assert_eq(link_utils.rel_to_stem("notes/foo.md"), "notes/foo")
end)

test("rel_to_stem leaves non-md paths unchanged", function()
  assert_eq(link_utils.rel_to_stem("notes/foo.txt"), "notes/foo.txt")
end)

-- ---------------------------------------------------------------------------
-- 4. is_fence_delimiter
-- ---------------------------------------------------------------------------
test("is_fence_delimiter detects backtick fence", function()
  assert_true(link_utils.is_fence_delimiter("```"))
end)

test("is_fence_delimiter detects tilde fence", function()
  assert_true(link_utils.is_fence_delimiter("~~~"))
end)

test("is_fence_delimiter rejects plain text", function()
  assert_true(not link_utils.is_fence_delimiter("just text"))
end)

-- ---------------------------------------------------------------------------
-- 5. find_heading_line (pure with a lines array)
-- ---------------------------------------------------------------------------
test("find_heading_line returns 1-based line of matching heading", function()
  local lines = { "intro text", "## Goals", "body", "## Other" }
  assert_eq(link_utils.find_heading_line(lines, "Goals"), 2)
end)

test("find_heading_line is slug/case-insensitive", function()
  local lines = { "# My Big Heading", "content" }
  assert_eq(link_utils.find_heading_line(lines, "my big heading"), 1)
end)

test("find_heading_line returns nil when not found", function()
  local lines = { "# A", "# B" }
  assert_nil(link_utils.find_heading_line(lines, "C"))
end)

-- ---------------------------------------------------------------------------
-- 6. extract_line_links
-- ---------------------------------------------------------------------------
test("extract_line_links parses a regular wikilink", function()
  local links = link_utils.extract_line_links("see [[Note#Sec]] here")
  assert_eq(#links, 1)
  assert_eq(links[1].name, "Note")
  assert_eq(links[1].heading, "Sec")
  assert_eq(links[1].embed, false)
end)

test("extract_line_links marks embeds with embed=true", function()
  local links = link_utils.extract_line_links("![[Picture]]")
  assert_eq(#links, 1)
  assert_eq(links[1].name, "Picture")
  assert_eq(links[1].embed, true)
end)

test("extract_line_links returns empty for no links", function()
  local links = link_utils.extract_line_links("plain line, no links")
  assert_eq(#links, 0)
end)

-- ---------------------------------------------------------------------------
-- 7. wikilink_display_name
-- ---------------------------------------------------------------------------
test("wikilink_display_name returns alias when present", function()
  assert_eq(link_utils.wikilink_display_name("[[Note|Friendly]]"), "Friendly")
end)

test("wikilink_display_name returns tail for path-qualified link", function()
  assert_eq(link_utils.wikilink_display_name("[[Sub/Note]]"), "Note")
end)

-- ---------------------------------------------------------------------------
-- 8. replace_link_note / replace_link_heading
-- ---------------------------------------------------------------------------
test("replace_link_note swaps name, preserves heading suffix", function()
  assert_eq(link_utils.replace_link_note("[[Old#Sec]]", "New"), "[[New#Sec]]")
end)

test("replace_link_note returns nil for malformed link", function()
  assert_nil(link_utils.replace_link_note("not a link", "New"))
end)

test("replace_link_heading swaps heading, preserves name", function()
  assert_eq(link_utils.replace_link_heading("[[Note#Old]]", "New"), "[[Note#New]]")
end)

-- ---------------------------------------------------------------------------
-- 9. lua_dirname
-- ---------------------------------------------------------------------------
test("lua_dirname returns parent directory", function()
  assert_eq(link_utils.lua_dirname("/a/b/c.md"), "/a/b")
end)

-- ============================================================================
-- Summary
-- ============================================================================
_H.finish({ style = "results", exit = "os" })
