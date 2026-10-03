-- Spec for andrew.fortran.docs.render -- normalization of the structured
-- entries in snippets/fortran-docs.json.
--
-- WHAT IT PINS
--
-- Five entries in that file -- `size`, `shape`, `lbound`, `ubound` and
-- `allocated` -- are stored as JSON OBJECTS while every other entry is a
-- markdown STRING. Every consumer assumed a string. The hover handler passes
-- the value straight to `vim.split`, so pressing K on `size` raised
--
--     s: expected string, got table
--
-- and put an error on screen instead of documentation. `size(a)` is one of
-- the most common expressions in Fortran, so this was not a corner: it was
-- five of the most-reached-for intrinsics in the language, all broken. The
-- blink completion source had the same bug by a different route -- it reads
-- `docs.load()` directly and never goes through `get`, so a per-call type
-- check at the hover site would have fixed only half of it.
--
-- Normalizing inside `load` means the cache holds only strings and no
-- consumer has to know that two shapes ever existed.
--
-- The option ORDER is the subtle part. JSON objects decode to Lua tables,
-- which are unordered, so rendering `pairs(options)` directly produces an
-- argument list in arbitrary order -- and `shape(source, kind)` sorts
-- alphabetically to `kind, source`, which documents the signature backwards.
-- The order is recovered from the synopsis text.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "options follow the synopsis order" fails if `ordered_keys` is replaced
--     by a plain sort, which is the obvious implementation and is wrong for
--     any routine whose arguments are not alphabetical.
--   * "a substring argument name is not matched early" fails if the
--     whole-word guard around the synopsis search is dropped -- `dim` would
--     then match inside `dimension` and sort by the wrong position.
--   * "a plain string passes through untouched" fails if render unconditionally
--     rebuilds, which would destroy the 380-odd entries that are already
--     markdown.
--   * "an entry with no known sections yields nil" fails if render returns an
--     empty string instead, since the hover handler treats any non-nil value
--     as a doc and would pop up an empty float.
--   * "junk input yields nil" fails if the type guard is dropped.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_docs_render_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local docs = require("andrew.fortran.docs")

test("a plain string passes through untouched", function()
  local s = "## trim\n\n### **Name**\n\nalready markdown"
  assert_eq(docs.render(s), s, "identity:")
end)

test("a structured entry renders every section", function()
  local out = docs.render({
    name = "**size** - Return the number of elements",
    synopsis = { usage = "```fortran\nresult = size(array, dim)\n```", interface = "```fortran\ninterface\n```" },
    characteristics = { "first point", "second point" },
    description = "**size** returns the total number of elements.",
    options = { array = "The array.", dim = "The dimension." },
    result = "A scalar integer.",
    examples = { code = "print *, size(a)", results = "```text\n5\n```" },
    standard = "Fortran 90",
    see_also = { "[**shape**](#shape)", "[**lbound**](#lbound)" },
  })
  for _, section in ipairs({ "Name", "Synopsis", "Characteristics", "Description",
                            "Options", "Result", "Examples", "Standard", "See Also" }) do
    assert_true(out:find("### %*%*" .. section:gsub(" ", " ") .. "%*%*") ~= nil,
      section .. " section present:")
  end
  assert_true(out:find("first point", 1, true) ~= nil, "characteristics rendered:")
  assert_true(out:find("```fortran\nprint %*, size%(a%)") ~= nil, "example fenced:")
end)

test("options follow the synopsis order", function()
  -- shape(source, kind): alphabetical order would document them backwards.
  local out = docs.render({
    synopsis = { usage = "result = shape(source, kind)" },
    options = { kind = "The kind.", source = "The source." },
  })
  local isource = out:find("%*%*source%*%*")
  local ikind = out:find("%*%*kind%*%*")
  assert_true(isource ~= nil and ikind ~= nil, "both options rendered:")
  assert_true(isource < ikind, "source before kind:")
end)

test("a substring argument name is not matched early", function()
  -- `dim` occurs inside `dimension` well before its own mention; a
  -- non-whole-word search would order it first.
  local out = docs.render({
    synopsis = { usage = "result = f(dimension_arg, dim)" },
    options = { dim = "The dimension index.", dimension_arg = "The array." },
  })
  local iarg = out:find("%*%*dimension_arg%*%*")
  local idim = out:find("%*%*dim%*%*")
  assert_true(iarg < idim, "dimension_arg before dim:")
end)

test("missing sections are omitted, not emitted empty", function()
  local out = docs.render({ name = "**x** - a thing", description = "Some prose." })
  assert_true(out:find("### %*%*Name%*%*") ~= nil, "name kept:")
  assert_true(out:find("### %*%*Options%*%*") == nil, "no empty Options:")
  assert_true(out:find("### %*%*Examples%*%*") == nil, "no empty Examples:")
end)

test("an entry with no known sections yields nil", function()
  -- The hover handler treats any non-nil value as a doc, so an empty string
  -- would open a blank float.
  assert_nil(docs.render({}), "empty table:")
  assert_nil(docs.render({ unknown_field = "x" }), "unknown fields only:")
end)

test("junk input yields nil", function()
  assert_nil(docs.render(nil), "nil:")
  assert_nil(docs.render(42), "number:")
end)

test("every entry in the real file resolves to a string", function()
  -- The regression itself: five entries were tables, and every consumer
  -- assumed a string.
  local all = docs.load()
  local bad = {}
  for k, v in pairs(all) do
    if type(v) ~= "string" then
      bad[#bad + 1] = k
    end
  end
  assert_eq(#bad, 0, "non-string entries (" .. table.concat(bad, ", ") .. "):")
end)

test("the five formerly-structured intrinsics survive a hover round trip", function()
  -- Exactly what the K handler does with the value.
  for _, w in ipairs({ "size", "shape", "lbound", "ubound", "allocated" }) do
    local d = docs.get(w)
    assert_true(type(d) == "string", w .. " is a string:")
    local ok = pcall(vim.split, d, "\n")
    assert_true(ok, w .. " survives vim.split:")
    assert_true(d:find("### %*%*Name%*%*") ~= nil, w .. " has a Name section:")
  end
end)

_H.finish()
