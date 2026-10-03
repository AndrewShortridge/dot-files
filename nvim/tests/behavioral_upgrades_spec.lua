-- Behavioral unit tests for pure vault modules:
--   andrew.vault.query.types          (Duration, Date, Link, typename, truthy, compare)
--   andrew.vault.query.executor_values (compare_eq, add_values, sub_values, contains_value)
--   andrew.vault.query.executor        (execute pipeline: WHERE/SORT/LIMIT, error paths)
--   andrew.vault.inline_fields         (parse_line, classify_value, value_highlight)
--   andrew.vault.callout_utils         (parse_header, scan_blocks)
--   andrew.vault.block_patterns        (match_id, extract_*, id_set_*)
-- Run with: nvim --headless -u NONE -l tests/behavioral_upgrades_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_false, _H.assert_nil

--- Deep structural equality for plain tables / scalars (spec-local variant).
local function deep_equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then return false end
  end
  for k, _ in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function assert_deep_eq(got, expected, msg)
  if not deep_equal(got, expected) then
    error((msg or "") .. " expected: " .. vim.inspect(expected) .. ", got: " .. vim.inspect(got))
  end
end

-- ============================================================================
-- Load modules under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local types = require("andrew.vault.query.types")
local vals = require("andrew.vault.query.executor_values")
local executor = require("andrew.vault.query.executor")
local inf = require("andrew.vault.inline_fields")
local callout = require("andrew.vault.callout_utils")
local bp = require("andrew.vault.block_patterns")

print("\n=== Behavioral Upgrade Tests ===\n")

-- ============================================================================
-- 1. types.Duration
-- ============================================================================
print("--- types.Duration ---")

test("Duration.parse simple '7 days'", function()
  local d = types.Duration.parse("7 days")
  assert_true(d ~= nil, "should parse")
  assert_eq(d.days, 7)
  assert_eq(d.weeks, 0)
  assert_eq(d.years, 0)
  assert_eq(d.hours, 0)
end)

test("Duration.parse multi-unit '1 year, 3 months'", function()
  local d = types.Duration.parse("1 year, 3 months")
  assert_true(d ~= nil, "should parse")
  assert_eq(d.years, 1)
  assert_eq(d.months, 3)
  assert_eq(d.days, 0)
end)

test("Duration.parse abbreviations '2 wks' and '30 mins'", function()
  local w = types.Duration.parse("2 wks")
  assert_eq(w.weeks, 2)
  local m = types.Duration.parse("30 mins")
  assert_eq(m.minutes, 30)
end)

test("Duration.parse garbage returns nil", function()
  assert_nil(types.Duration.parse("xyz"))
  assert_nil(types.Duration.parse("5 fortnights"), "unknown unit should fail")
end)

test("Duration.parse empty returns nil", function()
  assert_nil(types.Duration.parse(""))
  assert_nil(types.Duration.parse("   "))
end)

test("Duration to_seconds for deterministic units", function()
  assert_eq(types.Duration.new({ days = 2 }):to_seconds(), 172800)
  assert_eq(types.Duration.new({ hours = 1, minutes = 30 }):to_seconds(), 5400)
  assert_eq(types.Duration.new({ weeks = 1 }):to_seconds(), 604800)
  assert_eq(types.Duration.new({ seconds = 42 }):to_seconds(), 42)
end)

test("Duration tostring multi-field", function()
  assert_eq(tostring(types.Duration.new({ days = 2, hours = 3 })), "2 days, 3 hours")
end)

test("Duration tostring singular when value is 1", function()
  assert_eq(tostring(types.Duration.new({ days = 1 })), "1 day")
end)

test("Duration tostring empty -> '0 seconds'", function()
  assert_eq(tostring(types.Duration.new()), "0 seconds")
end)

test("Duration __add sums fields", function()
  local d = types.Duration.new({ days = 1 }) + types.Duration.new({ hours = 2, days = 1 })
  assert_eq(d.days, 2)
  assert_eq(d.hours, 2)
end)

test("Duration __eq / __lt via approximate seconds", function()
  assert_true(types.Duration.new({ days = 1 }) == types.Duration.new({ hours = 24 }))
  assert_true(types.Duration.new({ hours = 1 }) < types.Duration.new({ days = 1 }))
  assert_false(types.Duration.new({ days = 1 }) < types.Duration.new({ hours = 1 }))
end)

-- ============================================================================
-- 2. types.Date (absolute forms only, for determinism)
-- ============================================================================
print("\n--- types.Date ---")

test("Date.parse ISO date", function()
  local d = types.Date.parse("2026-02-18")
  assert_true(d ~= nil, "should parse")
  assert_eq(tostring(d), "2026-02-18")
end)

test("Date.parse ISO datetime keeps time components", function()
  local d = types.Date.parse("2026-02-18T10:30:00")
  assert_true(d ~= nil, "should parse")
  assert_eq(d.hour, 10)
  assert_eq(d.min, 30)
  assert_eq(d.sec, 0)
  assert_eq(tostring(d), "2026-02-18")
end)

test("Date.parse long form 'February 18, 2026'", function()
  local d = types.Date.parse("February 18, 2026")
  assert_true(d ~= nil, "should parse")
  assert_eq(tostring(d), "2026-02-18")
end)

test("Date.parse garbage returns nil", function()
  assert_nil(types.Date.parse("not a date"))
  assert_nil(types.Date.parse("Nonmonth 18, 2026"), "unknown month name should fail")
end)

test("Date plus 1 month clamps Jan 31 to Feb 28", function()
  local d = types.Date.new(2026, 1, 31):plus(types.Duration.new({ months = 1 }))
  assert_eq(tostring(d), "2026-02-28")
end)

test("Date plus accepts plain {days=7} table", function()
  local d = types.Date.new(2026, 1, 1):plus({ days = 7 })
  assert_eq(tostring(d), "2026-01-08")
end)

test("Date plus months normalizes year rollover", function()
  local d = types.Date.new(2026, 11, 15):plus(types.Duration.new({ months = 3 }))
  assert_eq(tostring(d), "2027-02-15")
end)

test("Date minus Duration returns earlier Date", function()
  local d = types.Date.new(2026, 3, 1):minus({ days = 1 })
  assert_eq(tostring(d), "2026-02-28")
end)

test("Date minus Date returns Duration of 604800 seconds for one week", function()
  local dur = types.Date.new(2026, 1, 8):minus(types.Date.new(2026, 1, 1))
  assert_eq(dur:to_seconds(), 604800)
end)

test("Date __lt comparison", function()
  assert_true(types.Date.new(2026, 1, 1) < types.Date.new(2026, 1, 2))
  assert_false(types.Date.new(2026, 1, 2) < types.Date.new(2026, 1, 1))
end)

test("Date __le and __eq via timestamps", function()
  assert_true(types.Date.new(2026, 1, 1) <= types.Date.new(2026, 1, 1))
  assert_true(types.Date.new(2026, 1, 1) == types.Date.new(2026, 1, 1))
  assert_false(types.Date.new(2026, 1, 1) == types.Date.new(2026, 1, 2))
end)

-- ============================================================================
-- 3. types.Link / typename / truthy / compare
-- ============================================================================
print("\n--- types utilities ---")

test("Link tostring plain, with display, embed", function()
  assert_eq(tostring(types.Link.new("p")), "[[p]]")
  assert_eq(tostring(types.Link.new("p", "d")), "[[p|d]]")
  assert_eq(tostring(types.Link.new("p", nil, true)), "![[p]]")
end)

test("typename basic variants", function()
  assert_eq(types.typename(nil), "null")
  assert_eq(types.typename(5), "number")
  assert_eq(types.typename("s"), "string")
  assert_eq(types.typename(true), "boolean")
  assert_eq(types.typename({}), "array")
  assert_eq(types.typename({ 1, 2 }), "array")
  assert_eq(types.typename({ a = 1 }), "object")
end)

test("typename custom types", function()
  assert_eq(types.typename(types.Date.new(2026, 1, 1)), "date")
  assert_eq(types.typename(types.Duration.new()), "duration")
  assert_eq(types.typename(types.Link.new("p")), "link")
end)

test("truthy: nil/false falsy; 0 and '' truthy", function()
  assert_false(types.truthy(nil))
  assert_false(types.truthy(false))
  assert_true(types.truthy(0))
  assert_true(types.truthy(""))
  assert_true(types.truthy({}))
end)

test("compare numbers and nil ordering", function()
  assert_eq(types.compare(1, 2), -1)
  assert_eq(types.compare(2, 1), 1)
  assert_eq(types.compare(2, 2), 0)
  assert_eq(types.compare(nil, nil), 0)
  assert_eq(types.compare(nil, 1), -1, "nil < non-nil")
  assert_eq(types.compare(1, nil), 1)
end)

test("compare strings is case-insensitive", function()
  assert_eq(types.compare("a", "B"), -1)
  assert_eq(types.compare("B", "a"), 1)
  assert_eq(types.compare("Hello", "hello"), 0)
end)

test("compare booleans: false < true", function()
  assert_eq(types.compare(false, true), -1)
  assert_eq(types.compare(true, false), 1)
  assert_eq(types.compare(true, true), 0)
end)

test("compare dates and durations", function()
  assert_eq(types.compare(types.Date.new(2026, 1, 1), types.Date.new(2026, 1, 2)), -1)
  assert_eq(types.compare(types.Duration.new({ days = 2 }), types.Duration.new({ days = 1 })), 1)
end)

test("compare cross-type orders by typename string (number < string)", function()
  assert_eq(types.compare(1, "a"), -1)
  assert_eq(types.compare("a", 1), 1)
end)

-- ============================================================================
-- 4. executor_values
-- ============================================================================
print("\n--- executor_values ---")

test("compare_eq nil handling and tostring fallback", function()
  assert_true(vals.compare_eq(nil, nil))
  assert_false(vals.compare_eq(nil, 1))
  assert_false(vals.compare_eq(1, nil))
  assert_true(vals.compare_eq(1, "1"), "number/string coexistence via tostring")
  assert_true(vals.compare_eq("x", "x"))
  assert_false(vals.compare_eq("x", "y"))
end)

test("compare_eq Links by path", function()
  assert_true(vals.compare_eq(types.Link.new("a"), types.Link.new("a")))
  assert_false(vals.compare_eq(types.Link.new("a"), types.Link.new("b")))
end)

test("compare_eq Dates by timestamp", function()
  assert_true(vals.compare_eq(types.Date.new(2026, 1, 1), types.Date.new(2026, 1, 1)))
  assert_false(vals.compare_eq(types.Date.new(2026, 1, 1), types.Date.new(2026, 1, 2)))
end)

test("add_values numeric, concat, and string coercion", function()
  assert_eq(vals.add_values(2, 3), 5)
  assert_eq(vals.add_values("a", "b"), "ab")
  assert_eq(vals.add_values("x", 5), "x5")
end)

test("add_values Date + Duration returns next day", function()
  local d = vals.add_values(types.Date.new(2026, 1, 1), types.Duration.new({ days = 1 }))
  assert_eq(tostring(d), "2026-01-02")
end)

test("sub_values numeric and Date - Date", function()
  assert_eq(vals.sub_values(5, 3), 2)
  local dur = vals.sub_values(types.Date.new(2026, 1, 2), types.Date.new(2026, 1, 1))
  assert_eq(dur:to_seconds(), 86400)
end)

test("contains_value array membership", function()
  assert_true(vals.contains_value({ 1, 2, 3 }, 2))
  assert_false(vals.contains_value({ 1, 2, 3 }, 9))
end)

test("contains_value string substring", function()
  assert_true(vals.contains_value("hello world", "world"))
  assert_false(vals.contains_value("hello", "zzz"))
end)

test("contains_value Link path substring match", function()
  assert_true(vals.contains_value({ types.Link.new("foo/bar") }, "bar"))
  assert_false(vals.contains_value({ types.Link.new("foo/bar") }, "qux"))
end)

test("contains_value non-container returns false", function()
  assert_false(vals.contains_value(5, 5))
  assert_false(vals.contains_value(nil, 1))
end)

-- ============================================================================
-- 5. executor.execute (against a fake in-memory index, no fs)
-- ============================================================================
print("\n--- executor.execute ---")

--- Build a mock index with fixed pages (per test_vault_fixes.lua pattern).
local function make_mock_index()
  local function build_pages()
    local specs = {
      { name = "alpha", priority = 3, tags = { "project", "urgent" } },
      { name = "beta", priority = 1, tags = { "journal" } },
      { name = "gamma", priority = 2, tags = { "project" } },
      { name = "delta", priority = 4, tags = {} },
    }
    local pages = {}
    for i, s in ipairs(specs) do
      pages[i] = {
        file = {
          name = s.name,
          path = s.name .. ".md",
          link = types.Link.new(s.name, s.name, false),
          tags = s.tags,
        },
        priority = s.priority,
        tags = s.tags,
      }
    end
    return pages
  end
  return {
    all_pages = function()
      return build_pages()
    end,
    resolve_source = function(self, _node)
      return self:all_pages()
    end,
    current_page = function()
      return nil
    end,
  }
end

local function field(...)
  return { type = "field", path = { ... } }
end

local function lit(v)
  return { type = "literal", value = v }
end

local function binop(op, l, r)
  return { type = "binary", op = op, left = l, right = r }
end

test("execute nil ast returns ({}, 'Invalid query AST: missing type')", function()
  local results, err = executor.execute(nil, make_mock_index(), "")
  assert_eq(#results, 0)
  assert_eq(err, "Invalid query AST: missing type")
end)

test("execute ast without type returns same error", function()
  local results, err = executor.execute({}, make_mock_index(), "")
  assert_eq(#results, 0)
  assert_eq(err, "Invalid query AST: missing type")
end)

test("execute nil index returns ({}, 'No index provided')", function()
  local results, err = executor.execute({ type = "LIST" }, nil, "")
  assert_eq(#results, 0)
  assert_eq(err, "No index provided")
end)

test("LIST with no clauses returns all pages in order", function()
  local ast = {
    type = "LIST",
    list_expr = field("file", "name"),
    without_id = true,
  }
  local results, err = executor.execute(ast, make_mock_index(), "")
  assert_nil(err)
  assert_eq(#results, 1)
  assert_eq(results[1].type, "list")
  assert_deep_eq(results[1].items, { "alpha", "beta", "gamma", "delta" })
end)

test("WHERE priority > 2 filters pages", function()
  local ast = {
    type = "LIST",
    list_expr = field("file", "name"),
    without_id = true,
    where = binop(">", field("priority"), lit(2)),
  }
  local results, err = executor.execute(ast, make_mock_index(), "")
  assert_nil(err)
  assert_deep_eq(results[1].items, { "alpha", "delta" })
end)

test("WHERE with OR of equalities", function()
  local ast = {
    type = "LIST",
    list_expr = field("file", "name"),
    without_id = true,
    where = binop("OR",
      binop("=", field("priority"), lit(1)),
      binop("=", field("priority"), lit(3))),
  }
  local results, err = executor.execute(ast, make_mock_index(), "")
  assert_nil(err)
  assert_deep_eq(results[1].items, { "alpha", "beta" })
end)

test("WHERE tags CONTAINS 'project'", function()
  local ast = {
    type = "LIST",
    list_expr = field("file", "name"),
    without_id = true,
    where = binop("CONTAINS", field("tags"), lit("project")),
  }
  local results, err = executor.execute(ast, make_mock_index(), "")
  assert_nil(err)
  assert_deep_eq(results[1].items, { "alpha", "gamma" })
end)

test("SORT priority ASC orders pages", function()
  local ast = {
    type = "LIST",
    list_expr = field("file", "name"),
    without_id = true,
    sort = { { expr = field("priority"), dir = "ASC" } },
  }
  local results, err = executor.execute(ast, make_mock_index(), "")
  assert_nil(err)
  assert_deep_eq(results[1].items, { "beta", "gamma", "alpha", "delta" })
end)

test("SORT priority DESC with LIMIT 2 returns top two", function()
  local ast = {
    type = "LIST",
    list_expr = field("file", "name"),
    without_id = true,
    sort = { { expr = field("priority"), dir = "DESC" } },
    limit = 2,
  }
  local results, err = executor.execute(ast, make_mock_index(), "")
  assert_nil(err)
  assert_deep_eq(results[1].items, { "delta", "alpha" })
end)

test("TABLE query builds headers and rows", function()
  local ast = {
    type = "TABLE",
    fields = { { expr = field("priority"), alias = "prio" } },
    without_id = true,
    sort = { { expr = field("priority"), dir = "ASC" } },
  }
  local results, err = executor.execute(ast, make_mock_index(), "")
  assert_nil(err)
  assert_eq(#results, 1)
  assert_eq(results[1].type, "table")
  assert_deep_eq(results[1].headers, { "prio" })
  assert_deep_eq(results[1].rows, { { 1 }, { 2 }, { 3 }, { 4 } })
end)

test("Unknown query type yields an error result item without err", function()
  local results, err = executor.execute({ type = "BOGUS" }, make_mock_index(), "")
  assert_nil(err)
  assert_eq(#results, 1)
  assert_eq(results[1].type, "error")
  assert_eq(results[1].message, "Unknown query type: BOGUS")
end)

-- ============================================================================
-- 6. inline_fields.parse_line
-- ============================================================================
print("\n--- inline_fields.parse_line ---")

test("bracket field positions in '[key:: value]'", function()
  local fields = inf.parse_line("here is [key:: value] text", 0)
  assert_eq(#fields, 1)
  local f = fields[1]
  assert_eq(f.key, "key")
  assert_eq(f.value, "value")
  assert_eq(f.syntax, "bracket")
  assert_eq(f.row, 0)
  assert_eq(f.col_start, 8)
  assert_eq(f.col_end, 21)
  assert_eq(f.col_key_start, 9)
  assert_eq(f.col_key_end, 12)
  assert_eq(f.col_val_start, 15)
  assert_eq(f.col_val_end, 20)
end)

test("paren field positions in '(status:: done)'", function()
  local fields = inf.parse_line("paren (status:: done) here", 0)
  assert_eq(#fields, 1)
  local f = fields[1]
  assert_eq(f.key, "status")
  assert_eq(f.value, "done")
  assert_eq(f.syntax, "paren")
  assert_eq(f.col_start, 6)
  assert_eq(f.col_end, 21)
  assert_eq(f.col_key_start, 7)
  assert_eq(f.col_key_end, 13)
  assert_eq(f.col_val_start, 16)
  assert_eq(f.col_val_end, 20)
end)

test("standalone field on bare line", function()
  local fields = inf.parse_line("priority:: high", 0)
  assert_eq(#fields, 1)
  local f = fields[1]
  assert_eq(f.key, "priority")
  assert_eq(f.value, "high")
  assert_eq(f.syntax, "standalone")
  assert_eq(f.col_start, 0)
  assert_eq(f.col_end, 15)
  assert_eq(f.col_key_start, 0)
  assert_eq(f.col_key_end, 8)
  assert_eq(f.col_val_start, 11)
  assert_eq(f.col_val_end, 15)
end)

test("standalone field after list marker", function()
  local fields = inf.parse_line("- author:: Jane Doe", 0)
  assert_eq(#fields, 1)
  local f = fields[1]
  assert_eq(f.key, "author")
  assert_eq(f.value, "Jane Doe")
  assert_eq(f.syntax, "standalone")
  assert_eq(f.col_start, 2)
  assert_eq(f.col_key_start, 2)
  assert_eq(f.col_key_end, 8)
  assert_eq(f.col_val_start, 11)
  assert_eq(f.col_val_end, 19)
  assert_eq(f.col_end, 19)
end)

test("skips wikilinks but finds following bracket field", function()
  local fields = inf.parse_line("a [[wikilink]] and [k:: v]", 0)
  assert_eq(#fields, 1)
  assert_eq(fields[1].key, "k")
  assert_eq(fields[1].value, "v")
  assert_eq(fields[1].syntax, "bracket")
  assert_eq(fields[1].col_start, 19)
end)

test("two bracket fields on one line", function()
  local fields = inf.parse_line("[x:: 1] [y:: 2]", 0)
  assert_eq(#fields, 2)
  assert_eq(fields[1].key, "x")
  assert_eq(fields[1].col_start, 0)
  assert_eq(fields[2].key, "y")
  assert_eq(fields[2].col_start, 8)
end)

test("skips markdown link, finds later field", function()
  local fields = inf.parse_line("see [text](http://url) and [a:: b]", 0)
  assert_eq(#fields, 1)
  assert_eq(fields[1].key, "a")
  assert_eq(fields[1].value, "b")
  assert_eq(fields[1].col_start, 27)
end)

test("skips footnote references", function()
  local fields = inf.parse_line("claim [^1] and [note:: ok]", 0)
  assert_eq(#fields, 1)
  assert_eq(fields[1].key, "note")
end)

test("no fields on plain line", function()
  assert_eq(#inf.parse_line("no fields here", 0), 0)
end)

test("https scheme is not a standalone field", function()
  assert_eq(#inf.parse_line("https:: not a field because scheme", 0), 0)
end)

test("https scheme is not a bracket field", function()
  assert_eq(#inf.parse_line("see [https:: //example.com] there", 0), 0)
end)

-- ============================================================================
-- 7. inline_fields.classify_value / value_highlight
-- ============================================================================
print("\n--- inline_fields classification ---")

test("classify_value all types", function()
  assert_eq(inf.classify_value(""), "empty")
  assert_eq(inf.classify_value("   "), "empty")
  assert_eq(inf.classify_value("true"), "boolean")
  assert_eq(inf.classify_value("false"), "boolean")
  assert_eq(inf.classify_value("2026-02-18"), "date")
  assert_eq(inf.classify_value("2026-02-18T10:30"), "date", "ISO prefix counts as date")
  assert_eq(inf.classify_value("42"), "number")
  assert_eq(inf.classify_value("3.14"), "number")
  assert_eq(inf.classify_value("[[Some Note]]"), "link")
  assert_eq(inf.classify_value("plain words"), "text")
end)

test("value_highlight maps types to groups", function()
  assert_eq(inf.value_highlight("number"), "VaultFieldValueNumber")
  assert_eq(inf.value_highlight("boolean"), "VaultFieldValueBool")
  assert_eq(inf.value_highlight("date"), "VaultFieldValueDate")
  assert_eq(inf.value_highlight("link"), "VaultFieldValueLink")
  assert_eq(inf.value_highlight("text"), "VaultFieldValue")
  assert_eq(inf.value_highlight("empty"), "VaultFieldValue")
  assert_eq(inf.value_highlight("bogus"), "VaultFieldValue", "unknown type falls back")
end)

-- ============================================================================
-- 8. callout_utils
-- ============================================================================
print("\n--- callout_utils ---")

test("parse_header with suffix and title", function()
  local ctype, suffix, title = callout.parse_header("> [!NOTE]- Title")
  assert_eq(ctype, "NOTE")
  assert_eq(suffix, "-")
  assert_eq(title, "Title")
end)

test("parse_header uppercases type, no suffix", function()
  local ctype, suffix, title = callout.parse_header("> [!info] x")
  assert_eq(ctype, "INFO")
  assert_nil(suffix)
  assert_eq(title, "x")
end)

test("parse_header '+' suffix with empty title", function()
  local ctype, suffix, title = callout.parse_header("> [!warning]+")
  assert_eq(ctype, "WARNING")
  assert_eq(suffix, "+")
  assert_eq(title, "")
end)

test("parse_header non-callout returns nil,nil,''", function()
  local ctype, suffix, title = callout.parse_header("plain text")
  assert_nil(ctype)
  assert_nil(suffix)
  assert_eq(title, "")
  local c2 = callout.parse_header("> regular quote")
  assert_nil(c2)
end)

test("scan_blocks finds two blocks with boundaries and content", function()
  local lines = {
    "intro",
    "> [!NOTE]- My Title",
    "> content one",
    "> content two",
    "after",
    "> [!TIP] Second",
    "> body",
  }
  local blocks = callout.scan_blocks(lines)
  assert_eq(#blocks, 2)

  local b1 = blocks[1]
  assert_eq(b1.start_line, 2)
  assert_eq(b1.end_line, 4)
  assert_eq(b1.ctype, "NOTE")
  assert_eq(b1.suffix, "-")
  assert_eq(b1.title, "My Title")
  assert_deep_eq(b1.content_lines, { "> content one", "> content two" })

  local b2 = blocks[2]
  assert_eq(b2.start_line, 6)
  assert_eq(b2.end_line, 7)
  assert_eq(b2.ctype, "TIP")
  assert_nil(b2.suffix)
  assert_eq(b2.title, "Second")
  assert_deep_eq(b2.content_lines, { "> body" })
end)

test("scan_blocks header with no body has end_line == start_line", function()
  local blocks = callout.scan_blocks({ "> [!NOTE] solo", "not quoted" })
  assert_eq(#blocks, 1)
  assert_eq(blocks[1].start_line, 1)
  assert_eq(blocks[1].end_line, 1)
  assert_deep_eq(blocks[1].content_lines, {})
end)

test("scan_blocks empty input returns empty list", function()
  assert_eq(#callout.scan_blocks({}), 0)
end)

-- ============================================================================
-- 9. block_patterns
-- ============================================================================
print("\n--- block_patterns ---")

test("match_id extracts id without caret", function()
  assert_eq(bp.match_id("some text ^blk-abc123"), "blk-abc123")
  assert_eq(bp.match_id("trailing space ^blk-x1  "), "blk-x1")
end)

test("match_id returns nil when no id", function()
  assert_nil(bp.match_id("no id here"))
  assert_nil(bp.match_id("caret ^ alone"))
end)

test("extract_from_lines: no dedup, 1-indexed lines, stripped text", function()
  local blocks = bp.extract_from_lines({ "a ^id1", "plain", "b ^id2", "c ^id1" })
  assert_eq(#blocks, 3, "duplicates are kept")
  assert_deep_eq(blocks[1], { id = "id1", text = "a", line = 1 })
  assert_deep_eq(blocks[2], { id = "id2", text = "b", line = 3 })
  assert_deep_eq(blocks[3], { id = "id1", text = "c", line = 4 })
end)

test("extract_from_content dedups by id (first wins)", function()
  local blocks = bp.extract_from_content("a ^id1\nb ^id2\nc ^id1")
  assert_eq(#blocks, 2)
  assert_deep_eq(blocks[1], { id = "id1", text = "a", line = 1 })
  assert_deep_eq(blocks[2], { id = "id2", text = "b", line = 2 })
end)

test("extract_from_content accepts pre-split lines", function()
  local blocks = bp.extract_from_content("ignored", { "x ^only-one" })
  assert_eq(#blocks, 1)
  assert_eq(blocks[1].id, "only-one")
  assert_eq(blocks[1].text, "x")
end)

test("id_set_from_lines builds existence set", function()
  local ids = bp.id_set_from_lines({ "a ^id1", "plain", "b ^id2", "c ^id1" })
  assert_deep_eq(ids, { id1 = true, id2 = true })
end)

test("id_set_from_content handles \\r\\n and \\r line endings", function()
  local crlf = bp.id_set_from_content("a ^id1\r\nb ^id2")
  assert_deep_eq(crlf, { id1 = true, id2 = true })
  local cr = bp.id_set_from_content("a ^id3\rb ^id4")
  assert_deep_eq(cr, { id3 = true, id4 = true })
end)

-- ============================================================================
-- Summary
-- ============================================================================
_H.finish({ style = "results", exit = "os" })
