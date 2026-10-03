-- Behavioral spec for multi-value inline-field query parity.
-- Run with: nvim --headless -u NONE -l tests/inline_fields_query_spec.lua
--
-- Covers the seams added for inline-field query parity:
--   * vault_index_parser.extract_inline_fields  -> scalar-or-list shape
--   * search_filter.match_field / match_helpers -> list any-element matching,
--                                                  special-field inline fallback
--   * query.index:_parse_scalar_from_vi         -> per-element typing of lists
-- Assertions are behavioral (exercise real module output), not source-introspection.

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- Stub the logger so requiring real modules doesn't pull full vault infra.
package.loaded["andrew.vault.vault_log"] = {
  scope = function()
    return setmetatable({}, { __index = function() return function() end end })
  end,
}

local P = require("andrew.vault.vault_index_parser")
local match_field = require("andrew.vault.search_filter.match_field")
local match_helpers = require("andrew.vault.search_filter.match_helpers")
local QI = require("andrew.vault.query.index")

-- Parse a markdown body into a vault-index entry.
local function parse(body)
  return P.parse_content(body, "Note.md", {
    mtime = { sec = 1 },
    size = #body,
    birthtime = { sec = 1 },
  })
end

local SAMPLE = table.concat({
  "---",
  "title: Sample",
  "---",
  "",
  "Prose mentioning [genre:: rock] and also [genre:: jazz] inline.",
  "A paren field (rating:: 5) mid sentence.",
  "status:: active",
  "type:: project",
  "",
  "- [ ] a task [due:: 2026-01-01]",
}, "\n")

-- ── Parsing: scalar-or-list shape ──────────────────────────────────────────

test("repeated bracket key collapses to an ordered list", function()
  local e = parse(SAMPLE)
  assert_eq(type(e.inline_fields.genre), "table")
  assert_eq(e.inline_fields.genre[1], "rock")
  assert_eq(e.inline_fields.genre[2], "jazz")
  assert_eq(#e.inline_fields.genre, 2)
end)

test("single occurrence stays a scalar string (no list)", function()
  local e = parse(SAMPLE)
  assert_eq(e.inline_fields.rating, "5")
  assert_eq(e.inline_fields.status, "active")
end)

test("standalone field is anchored — prose with brackets is not swallowed", function()
  local e = parse(SAMPLE)
  -- The genre list must contain ONLY the two bracket values, not a polluted
  -- whole-line capture from the unanchored standalone pattern.
  for _, v in ipairs(e.inline_fields.genre) do
    assert_true(v == "rock" or v == "jazz", "unexpected genre value: " .. tostring(v))
  end
end)

test("task-line fields do not leak into page-level inline_fields", function()
  local e = parse(SAMPLE)
  assert_nil(e.inline_fields.due)
end)

-- ── Search matching: list any-element + scalar coercion ────────────────────

local function field_node(name, op, value)
  return { name = name, op = op, value = value }
end

test("list field matches when ANY element satisfies =", function()
  local e = parse(SAMPLE)
  assert_eq(match_field.match_field(field_node("genre", "=", "jazz"), e, nil), true)
  assert_eq(match_field.match_field(field_node("genre", "=", "rock"), e, nil), true)
  assert_eq(match_field.match_field(field_node("genre", "=", "blues"), e, nil), false)
end)

test("scalar inline field supports numeric coercion (rating > 3)", function()
  local e = parse(SAMPLE)
  assert_eq(match_field.match_field(field_node("rating", ">", "3"), e, nil), true)
  assert_eq(match_field.match_field(field_node("rating", ">", "9"), e, nil), false)
end)

test("get_generic_field returns the list for a repeated key", function()
  local e = parse(SAMPLE)
  local v = match_helpers.get_generic_field(e, "genre")
  assert_eq(type(v), "table")
  assert_eq(#v, 2)
end)

test("special field 'type' falls back to inline value", function()
  -- No frontmatter.type; only an inline `type:: project`.
  local e = parse(SAMPLE)
  assert_nil(e.frontmatter.type)
  assert_eq(match_field.match_field(field_node("type", "=", "project"), e, nil), true)
end)

-- ── DQL: per-element typing of list values ─────────────────────────────────

test("_parse_scalar_from_vi types scalar and list values consistently", function()
  local Index = QI.Index or (QI.new and getmetatable(QI.new()).__index)
  local inst = setmetatable({}, { __index = Index })
  assert_eq(inst:_parse_scalar_from_vi("5"), 5)
  local list = inst:_parse_scalar_from_vi({ "3", "7" })
  assert_eq(type(list), "table")
  assert_eq(list[1], 3)
  assert_eq(list[2], 7)
end)

_H.finish({ style = "results", exit = "os" })
