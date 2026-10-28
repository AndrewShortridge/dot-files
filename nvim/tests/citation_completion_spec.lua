-- Spec for andrew.vault.completion_citations (pandoc `@citekey` completion).
--
-- Covers the two decisions a user would notice going wrong:
--   * where the menu opens: after `[@`, `; @`, `[-@`, a bare in-text `@`, but
--     never inside an e-mail address;
--   * which keys it offers and how they are labelled: the note's own
--     `bibliography:` first, vault databases after (flagged "not in
--     bibliography" when the note declares one), and the Library note matched
--     by DOI or by normalised title.
--
-- Run with: nvim --headless -u NONE -l tests/citation_completion_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local cite = require("andrew.vault.completion_citations")

print("\n=== citation completion Tests ===\n")

local function start(line)
  return cite.cite_start(line, #line)
end

test("cite_start opens on pandoc citation positions", function()
  assert_eq(start("@"), 1)
  assert_eq(start("see [@prud"), 6)
  assert_eq(start("[@a; @kar"), 6)
  assert_eq(start("[-@wu"), 3)
  assert_eq(start("as (@wu"), 5)
  assert_eq(start("in-text @ab:c.d"), 9, "internal punctuation stays in the key")
end)

test("cite_start stays closed for e-mail addresses and mid-word @", function()
  assert_nil(start("dongare@uconn.edu"))
  assert_nil(start("a.b@x"))
  assert_nil(start("see [@a b"), "cursor past the key")
end)

-- Scratch vault: .obsidian marker, a draft with its own bibliography, a
-- vault-wide database, and two Library notes (one DOI match, one title match).
local root = vim.fn.tempname()
local function write(rel, text)
  local path = root .. "/" .. rel
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(io.open(path, "w"))
  fd:write(text)
  fd:close()
  return path
end

vim.fn.mkdir(root .. "/.obsidian", "p")
write("Drafts/refs.json", vim.json.encode({
  { id = "prudhomme2020velocity", title = "Velocity and mass density", DOI = "10.1063/5.0022940",
    author = { { family = "Prudhomme", given = "G" }, { family = "Roland", given = "C" } },
    issued = { ["date-parts"] = { { 2020 } } } },
  { id = "buttler2012unstable", title = "Unstable Richtmyer–Meshkov growth of solid and liquid metals in vacuum",
    author = { { family = "Buttler", given = "W T" } }, issued = { ["date-parts"] = { { 2012 } } } },
}))
write("temporary/lib.json", vim.json.encode({
  { id = "buttler2012unstable", title = "duplicate key, must not win" },
  { id = "mishin2001structural", title = "Structural stability", author = { { family = "Mishin" } },
    issued = { ["date-parts"] = { { 2001 } } } },
}))
write("Library/Vel/Vel.md", '---\ntype: literature\ntitle: Something else\ndoi: 10.1063/5.0022940\n---\n')
write("Library/RM/RM.md", '---\ntype: literature\ntitle: "Unstable Richtmyer-Meshkov growth of solid and liquid metals in vacuum"\n---\n')
local draft = write("Drafts/Draft.md", "---\ntype: draft\nbibliography: refs.json\n---\n\nText [@\n")

vim.cmd.edit(vim.fn.fnameescape(draft))
local buf = vim.api.nvim_get_current_buf()

local function by_key(items)
  local m = {}
  for _, it in ipairs(items) do
    m[it.label] = it
  end
  return m
end

test("keys: note bibliography first, vault database deduplicated after it", function()
  local items = cite.build(buf, { "temporary/*.json" })
  assert_eq(#items, 3)
  local m = by_key(items)
  assert_true(not m.buttler2012unstable.documentation.value:find("must not win", 1, true), "bibliography entry wins the duplicate key")
  assert_true(m.mishin2001structural.labelDetails.description:find("not in bibliography", 1, true) ~= nil)
  assert_true(m.mishin2001structural.sortText > m.prudhomme2020velocity.sortText, "foreign keys sort last")
  assert_nil(m.prudhomme2020velocity.labelDetails.description:find("not in bibliography", 1, true))
end)

test("keys: Library note matched by DOI and by normalised title", function()
  local m = by_key(cite.build(buf, { "temporary/*.json" }))
  assert_eq(m.prudhomme2020velocity.labelDetails.description, "Prudhomme et al. 2020 · Library")
  assert_true(m.prudhomme2020velocity.documentation.value:find("Library/Vel/Vel.md", 1, true) ~= nil)
  assert_true(m.buttler2012unstable.documentation.value:find("Library/RM/RM.md", 1, true) ~= nil, "en dash vs hyphen title")
  assert_nil(m.mishin2001structural.labelDetails.description:find("Library", 1, true))
end)

test("get_completions replaces the typed key and is silent in frontmatter", function()
  local src = cite.new({ databases = { "temporary/*.json" } })
  local got
  src:get_completions({ bufnr = buf, line = "Text [@pru", cursor = { 6, 10 } }, function(r) got = r end)
  local item = by_key(got.items).prudhomme2020velocity
  assert_eq(item.textEdit.newText, "prudhomme2020velocity")
  assert_eq(item.textEdit.range.start.character, 7)
  assert_eq(item.textEdit.range["end"].character, 10)
  src:get_completions({ bufnr = buf, line = "bibliography: @x", cursor = { 3, 16 } }, function(r) got = r end)
  assert_eq(#got.items, 0)
end)

vim.fn.delete(root, "rf")
_H.finish()
