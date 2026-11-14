-- Unit tests for lua/andrew/vault/people.lua
--   listing, path derivation, existence checks and headless stub creation
-- Run with: nvim --headless -u NONE -l tests/people_spec.lua
--
-- Every test redirects engine.vault_path at a throwaway temp directory, so the
-- real vault is never read from or written to.

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local function assert_contains(haystack, needle, msg)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error((msg or "missing substring") .. ": " .. vim.inspect(needle))
  end
end

local function assert_not_contains(haystack, needle, msg)
  if type(haystack) == "string" and haystack:find(needle, 1, true) then
    error((msg or "unexpected substring present") .. ": " .. vim.inspect(needle))
  end
end

local function assert_deep_eq(got, expected, msg)
  local function deep_eq(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
      if not deep_eq(v, b[k]) then return false end
    end
    for k, _ in pairs(b) do
      if a[k] == nil then return false end
    end
    return true
  end
  if not deep_eq(got, expected) then
    error((msg or "") .. " expected: " .. vim.inspect(expected) .. ", got: " .. vim.inspect(got))
  end
end

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local engine = require("andrew.vault.engine")
local people = require("andrew.vault.people")

--- Point the engine at an empty temp vault, run fn, then restore.
---@param fn fun(root: string)
local function in_temp_vault(fn)
  local real_path = engine.vault_path
  local root = vim.fn.tempname() .. "-people-spec"
  vim.fn.mkdir(root .. "/People", "p")
  engine.vault_path = root
  local ok, err = pcall(fn, root)
  engine.vault_path = real_path
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

local function read(path)
  local fd = io.open(path, "r")
  if not fd then return nil end
  local content = fd:read("*a")
  fd:close()
  return content
end

-- ---------------------------------------------------------------------------
-- list_names
-- ---------------------------------------------------------------------------
test("list_names returns sorted basenames and ignores non-markdown", function()
  in_temp_vault(function(root)
    vim.fn.writefile({ "x" }, root .. "/People/Zoe Last.md")
    vim.fn.writefile({ "x" }, root .. "/People/Adam First.md")
    vim.fn.writefile({ "x" }, root .. "/People/notes.txt")
    vim.fn.mkdir(root .. "/People/Subfolder", "p")
    assert_deep_eq(people.list_names(), { "Adam First", "Zoe Last" })
  end)
end)

test("list_names returns an empty table when People/ is missing", function()
  in_temp_vault(function(root)
    vim.fn.delete(root .. "/People", "rf")
    assert_deep_eq(people.list_names(), {})
  end)
end)

-- ---------------------------------------------------------------------------
-- rel_path / exists
-- ---------------------------------------------------------------------------
test("rel_path prefixes People/ and sanitizes filename-hostile characters", function()
  assert_eq(people.rel_path("Rongbo Wang"), "People/Rongbo Wang")
  assert_eq(people.rel_path("A/B: C*D?E|F"), "People/A-B - CDEF")
end)

test("exists is false for a missing note and for a blank name", function()
  in_temp_vault(function(root)
    assert_true(not people.exists("Nobody Here"))
    assert_true(not people.exists(""))
    vim.fn.writefile({ "x" }, root .. "/People/Somebody.md")
    assert_true(people.exists("Somebody"))
  end)
end)

-- ---------------------------------------------------------------------------
-- create_stub
-- ---------------------------------------------------------------------------
test("create_stub writes person frontmatter and reports created", function()
  in_temp_vault(function(root)
    assert_eq(people.create_stub("Rongbo Wang"), "created")
    local c = read(root .. "/People/Rongbo Wang.md")
    assert_true(c ~= nil, "stub file written")
    assert_contains(c, "type: person")
    assert_contains(c, "name: Rongbo Wang")
    assert_contains(c, "role: ")
    assert_contains(c, "institution: ")
    assert_contains(c, "email: ")
    assert_contains(c, "tags:\n  - person")
    assert_contains(c, "# Rongbo Wang")
    assert_contains(c, "## Notes")
  end)
end)

test("create_stub never opens a buffer", function()
  in_temp_vault(function()
    local before = #vim.api.nvim_list_bufs()
    people.create_stub("Silent Author")
    assert_eq(#vim.api.nvim_list_bufs(), before, "buffer count unchanged")
  end)
end)

test("create_stub is idempotent and reports exists", function()
  in_temp_vault(function(root)
    assert_eq(people.create_stub("Rongbo Wang"), "created")
    vim.fn.writefile({ "SENTINEL" }, root .. "/People/Rongbo Wang.md")
    assert_eq(people.create_stub("Rongbo Wang"), "exists")
    assert_contains(read(root .. "/People/Rongbo Wang.md"), "SENTINEL", "existing note untouched")
  end)
end)

test("create_stub rejects blank and non-string names", function()
  in_temp_vault(function()
    assert_eq(people.create_stub("   "), "error")
    assert_eq(people.create_stub(nil), "error")
    assert_eq(people.create_stub(42), "error")
  end)
end)

test("create_stub emits aliases as an indented YAML block list", function()
  in_temp_vault(function(root)
    people.create_stub("F. J. Cherne", { aliases = { "Frank Cherne", "Cherne, F.J." } })
    local c = read(root .. "/People/F. J. Cherne.md")
    -- Two-space indent is required by the index parser (patterns.lua).
    assert_contains(c, 'aliases:\n  - "Frank Cherne"\n  - "Cherne, F.J."\n')
    -- aliases must sit directly after name:, before role:
    assert_true(c:find("name: F. J. Cherne\naliases:", 1, true) ~= nil, "aliases follow name")
  end)
end)

-- ---------------------------------------------------------------------------
-- yaml_quote
-- ---------------------------------------------------------------------------
test("yaml_quote double-quotes ordinary values", function()
  -- Matches the Library corpus and the Obsidian Templater template.
  assert_eq(people.yaml_quote("[[Rongbo Wang]]"), '"[[Rongbo Wang]]"')
end)

test("yaml_quote keeps an apostrophe unescaped inside double quotes", function()
  -- '' doubling is valid YAML but the index's strip_quotes never un-doubles it,
  -- so a single-quoted O''Malley would be indexed as a link to "O''Malley".
  assert_eq(people.yaml_quote("[[Sean O'Malley]]"), '"[[Sean O\'Malley]]"')
  assert_not_contains(people.yaml_quote("[[Sean O'Malley]]"), "''")
end)

test("yaml_quote falls back to single quotes when a double quote appears", function()
  local out = people.yaml_quote("a'b\"c")
  assert_eq(out:sub(1, 1), "'")
  assert_contains(out, "a''b")
end)

-- ---------------------------------------------------------------------------
-- Round trip: emitted YAML must parse back into a resolvable outlink
-- ---------------------------------------------------------------------------
test("emitted author YAML parses into frontmatter values and outlinks", function()
  local parser = require("andrew.vault.vault_index_parser")
  local names = { "Rongbo Wang", "Sean O'Malley" }
  local lines = { "---", "type: literature", "authors:" }
  for _, n in ipairs(names) do
    lines[#lines + 1] = "  - " .. people.yaml_quote("[[" .. n .. "]]")
  end
  lines[#lines + 1] = "---"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Body."
  local text = table.concat(lines, "\n")

  local entry = parser.parse_content(text, "Library/x.md", { mtime = { sec = 0 }, size = #text })
  assert_deep_eq(entry.frontmatter.authors, { "[[Rongbo Wang]]", "[[Sean O'Malley]]" })

  local targets = {}
  for _, l in ipairs(entry.outlinks or {}) do
    targets[#targets + 1] = l.path
  end
  assert_deep_eq(targets, names, "each author becomes an outlink to the bare person name")
end)

-- ============================================================================
-- Summary
-- ============================================================================
_H.finish({ style = "results", exit = "os" })
