-- Behavioral spec for type-safe DQL ordered WHERE comparisons.
-- Run with: nvim --headless -u NONE -l tests/dql_type_safe_compare_spec.lua
--
-- Covers the seam in query/executor.lua: the ordered operators (<, >, <=, >=)
-- must not let a non-numeric string (e.g. "/5", "abc") satisfy a numeric
-- comparison via types.compare's typename-string fallback. Numeric strings
-- ("5") must still coerce and compare. String-vs-string ordered compares and
-- equality (=, !=) must be unaffected.
--
-- Assertions are behavioral: they exercise real executor.execute output against
-- a tiny fake index, never source-introspection.

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- Stub the logger so requiring real modules doesn't pull full vault infra.
package.loaded["andrew.vault.vault_log"] = {
  scope = function()
    return setmetatable({}, { __index = function() return function() end end })
  end,
}

local executor = require("andrew.vault.query.executor")

-- Build a fake index exposing the interface executor.execute needs.
local function fake_index(pages)
  return {
    all_pages = function() return pages end,
    resolve_source = function(_, _) return pages end,
    current_page = function(_, _) return nil end,
  }
end

-- TABLE <field> WHERE <field> <op> <literal>  (File column present so each row's
-- row[1] is the page's file link → easy to assert which pages matched).
local function table_ast(field_name, op, literal)
  return {
    type = "TABLE",
    without_id = false,
    fields = { { expr = { type = "field", path = { field_name } } } },
    where = {
      type = "binary",
      op = op,
      left = { type = "field", path = { field_name } },
      right = { type = "literal", value = literal },
    },
  }
end

-- Run a query and return a set { [file_link] = true } of matched rows.
local function matched(field_name, op, literal, pages)
  local results = executor.execute(table_ast(field_name, op, literal), fake_index(pages), "/x.md")
  local set = {}
  for _, row in ipairs(results[1].rows) do
    set[row[1]] = true
  end
  return set
end

local function page(link, fields)
  fields.file = { link = link }
  return fields
end

-- ── number > number satisfied / rejected as expected ───────────────────────

test("numeric WHERE: 5 > 3 matches, 2 > 3 does not", function()
  local pages = { page("Five", { rating = 5 }), page("Two", { rating = 2 }) }
  local set = matched("rating", ">", 3, pages)
  assert_true(set["Five"])
  assert_false(set["Two"] or false)
end)

-- ── THE BUG: non-numeric string must NOT satisfy a numeric comparison ───────

test("non-numeric string '/5' does not satisfy rating > 3", function()
  local pages = { page("Good", { rating = 5 }), page("Bad", { rating = "/5" }) }
  local set = matched("rating", ">", 3, pages)
  assert_true(set["Good"])
  assert_false(set["Bad"] or false)
end)

test("non-numeric string '/5' rejected by <, <=, >= too", function()
  for _, op in ipairs({ "<", "<=", ">=", ">" }) do
    local pages = { page("Bad", { rating = "/5" }) }
    local set = matched("rating", op, 3, pages)
    assert_false(set["Bad"] or false)
  end
end)

test("non-numeric string 'abc' matches none of >,>=,<,<= against 3", function()
  for _, op in ipairs({ ">", ">=", "<", "<=" }) do
    local pages = { page("Word", { rating = "abc" }) }
    local set = matched("rating", op, 3, pages)
    assert_false(set["Word"] or false)
  end
end)

-- ── numeric-string coercion preserved ──────────────────────────────────────

test("numeric string '5' still coerces: matches > 3 and >= 5, not > 9", function()
  local pages = { page("StrFive", { rating = "5" }) }
  assert_true(matched("rating", ">", 3, pages)["StrFive"])
  assert_true(matched("rating", ">=", 5, pages)["StrFive"])
  assert_false(matched("rating", ">", 9, pages)["StrFive"] or false)
end)

-- ── string-vs-string ordered compare still lexical ─────────────────────────

test("string > string still orders lexically (guard fires only for num/str)", function()
  local pages = { page("Rock", { genre = "rock" }), page("Aaa", { genre = "aaa" }) }
  -- "rock" > "abc" is true lexically; "aaa" > "abc" is false.
  local set = matched("genre", ">", "abc", pages)
  assert_true(set["Rock"])
  assert_false(set["Aaa"] or false)
end)

-- ── equality unaffected (= / != not routed through ordered_compare) ─────────

test("equality: rating = 5 matches number 5 and string '5' via compare_eq", function()
  local pages = { page("Num", { rating = 5 }), page("Str", { rating = "5" }) }
  local set = matched("rating", "=", 5, pages)
  assert_true(set["Num"])
  assert_true(set["Str"])
end)

test("equality: rating = '/5' matches the literal-string page", function()
  local pages = { page("Slash", { rating = "/5" }), page("Five", { rating = 5 }) }
  local set = matched("rating", "=", "/5", pages)
  assert_true(set["Slash"])
  assert_false(set["Five"] or false)
end)

_H.finish({ style = "results", exit = "os" })
