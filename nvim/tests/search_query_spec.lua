-- Unit tests for the advanced search pipeline:
--   search_query (tokenizer + parser), date_utils, filter_utils,
--   search_filter.{classify, ast_split, match_helpers, match_field,
--   match_has, match_task} and search_filter.match_entry integration.
-- Run with: nvim --headless -u NONE -l tests/search_query_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_deep_eq, assert_true, assert_false, assert_nil, assert_match =
  _H.test, _H.assert_eq, _H.assert_deep_eq, _H.assert_true, _H.assert_false, _H.assert_nil, _H.assert_match

-- ============================================================================
-- Load modules under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local sq = require("andrew.vault.search_query")
local date_utils = require("andrew.vault.date_utils")
local filter_utils = require("andrew.vault.filter_utils")
local classify_mod = require("andrew.vault.search_filter.classify")
local ast_split = require("andrew.vault.search_filter.ast_split")
local match_helpers = require("andrew.vault.search_filter.match_helpers")
local match_field_mod = require("andrew.vault.search_filter.match_field")
local match_has_mod = require("andrew.vault.search_filter.match_has")
local match_task_mod = require("andrew.vault.search_filter.match_task")
local search_filter = require("andrew.vault.search_filter")
local config = require("andrew.vault.config")

-- ============================================================================
-- Fixtures (fixed, deterministic dates)
-- ============================================================================

local function ts(y, m, d, h, mi, s)
  return os.time({ year = y, month = m, day = d, hour = h or 0, min = mi or 0, sec = s or 0 })
end

--- Build a fresh VaultIndexEntry-shaped fixture for matcher tests.
local function make_entry()
  return {
    rel_path = "Projects/Alpha Note.md",
    rel_stem = "Projects/Alpha Note",
    rel_stem_lower = "projects/alpha note",
    basename = "Alpha Note",
    basename_lower = "alpha note",
    folder = "Projects",
    day = "2026-06-09",
    day_ts = ts(2026, 6, 9),
    created_ts = ts(2026, 3, 15, 10, 30),
    modified_ts = ts(2026, 6, 1, 8),
    tags = { "project", "work/alpha" },
    aliases = { "alpha", "the alpha project" },
    frontmatter = { type = "Note", status = "Active", priority = 2, area = "engineering" },
    inline_fields = { rating = "8" },
    outlinks = { { path = "Other Note", _name_lower = "other note" } },
    tasks = {
      {
        text = "Wash the car",
        text_lower = "wash the car",
        status = " ",
        completed = false,
        priority = 2,
        due = "2026-06-15",
        tags_lower = { urgent = true, ["home/chores"] = true },
      },
      {
        text = "Ship release",
        text_lower = "ship release",
        status = "x",
        completed = true,
        priority = 1,
        completion = "2026-05-20",
        repeat_rule = "every week",
        repeat_rule_lower = "every week",
        tags_lower = {},
      },
      {
        text = "Design review",
        text_lower = "design review",
        status = "/",
        completed = false,
        scheduled = "2026-06-10",
        tags_lower = {},
      },
    },
  }
end

--- Parse a query and return its AST, asserting success.
local function parse_ok(q)
  local ast, err = sq.parse_query(q)
  assert_nil(err, "parse_query('" .. q .. "') unexpected error")
  assert_true(ast ~= nil, "parse_query('" .. q .. "') returned nil ast")
  return ast
end

print("\n=== Search Query / Filter Pipeline Tests ===\n")

-- ============================================================================
-- 1. search_query.parse_query — tokenizer + parser AST shapes
-- ============================================================================

test("parse: plain text term", function()
  assert_deep_eq(parse_ok("hello"), { type = "text", value = "hello", quoted = false })
end)

test("parse: quoted phrase", function()
  assert_deep_eq(parse_ok('"exact phrase"'), { type = "text", value = "exact phrase", quoted = true })
end)

test("parse: regex with flags", function()
  assert_deep_eq(parse_ok("/reg.x/i"), { type = "regex", pattern = "reg.x", flags = "i" })
end)

test("parse: regex without flags has no flags field", function()
  local ast = parse_ok("/abc/")
  assert_deep_eq(ast, { type = "regex", pattern = "abc" })
  assert_nil(ast.flags, "flags should be nil")
end)

test("parse: field key:value with default = op", function()
  local ast = parse_ok("status:active")
  assert_deep_eq(ast, { type = "field", name = "status", op = "=", value = "active" })
  assert_nil(ast.value2, "value2 should be nil")
end)

test("parse: field with >= operator", function()
  assert_deep_eq(parse_ok("priority:>=3"), { type = "field", name = "priority", op = ">=", value = "3" })
end)

test("parse: field with < operator", function()
  assert_deep_eq(parse_ok("modified:<7d"), { type = "field", name = "modified", op = "<", value = "7d" })
end)

test("parse: field range .. operator", function()
  assert_deep_eq(parse_ok("created:2026-01-01..2026-02-01"), {
    type = "field", name = "created", op = "..", value = "2026-01-01", value2 = "2026-02-01",
  })
end)

test("parse: field quoted value strips quotes", function()
  assert_deep_eq(parse_ok('status:"in progress"'), { type = "field", name = "status", op = "=", value = "in progress" })
end)

test("parse: empty field value means exists", function()
  assert_deep_eq(parse_ok("type:"), { type = "field", name = "type", op = "=", value = "" })
end)

test("parse: explicit OR", function()
  assert_deep_eq(parse_ok("a OR b"), {
    type = "or",
    left = { type = "text", value = "a", quoted = false },
    right = { type = "text", value = "b", quoted = false },
  })
end)

test("parse: lowercase 'or' keyword is case-insensitive", function()
  assert_deep_eq(parse_ok("a or b"), {
    type = "or",
    left = { type = "text", value = "a", quoted = false },
    right = { type = "text", value = "b", quoted = false },
  })
end)

test("parse: implicit AND between adjacent terms", function()
  assert_deep_eq(parse_ok("a b"), {
    type = "and",
    left = { type = "text", value = "a", quoted = false },
    right = { type = "text", value = "b", quoted = false },
  })
end)

test("parse: MINUS prefix becomes NOT inside implicit AND", function()
  assert_deep_eq(parse_ok("foo -bar"), {
    type = "and",
    left = { type = "text", value = "foo", quoted = false },
    right = { type = "not", operand = { type = "text", value = "bar", quoted = false } },
  })
end)

test("parse: NOT keyword", function()
  assert_deep_eq(parse_ok("NOT done"), {
    type = "not",
    operand = { type = "text", value = "done", quoted = false },
  })
end)

test("parse: parentheses override precedence", function()
  assert_deep_eq(parse_ok("(a OR b) c"), {
    type = "and",
    left = {
      type = "or",
      left = { type = "text", value = "a", quoted = false },
      right = { type = "text", value = "b", quoted = false },
    },
    right = { type = "text", value = "c", quoted = false },
  })
end)

test("parse: has: operator", function()
  assert_deep_eq(parse_ok("has:tasks"), { type = "has", target = "tasks" })
end)

test("parse: task-* meta operator with comparison op", function()
  assert_deep_eq(parse_ok("task-due:<7d"), {
    type = "task", variant = "meta", meta_field = "due", op = "<", value = "7d",
  })
end)

test("parse: legacy task: variant any", function()
  assert_deep_eq(parse_ok("task:wash"), { type = "task", variant = "any", pattern = "wash" })
end)

test("parse: task-todo and task-done variants", function()
  assert_deep_eq(parse_ok("task-todo:foo"), { type = "task", variant = "todo", pattern = "foo" })
  assert_deep_eq(parse_ok("task-done:bar"), { type = "task", variant = "done", pattern = "bar" })
end)

test("parse: graph: params", function()
  assert_deep_eq(parse_ok("graph:depth=2,dir=forward"), {
    type = "graph", depth = 2, direction = "forward", center = "current",
  })
end)

test("parse: graph:neighbors and graph:extended shorthands", function()
  assert_deep_eq(parse_ok("graph:neighbors"), { type = "graph", depth = 1, direction = "both", center = "current" })
  assert_deep_eq(parse_ok("graph:extended"), { type = "graph", depth = 2, direction = "both", center = "current" })
end)

test("parse: graph center param", function()
  assert_deep_eq(parse_ok("graph:depth=3,center=Dashboard"), {
    type = "graph", depth = 3, direction = "both", center = "Dashboard",
  })
end)

test("parse: group: directive extracted as 3rd return and removed from AST", function()
  local ast, err, group = sq.parse_query("group:folder type:note")
  assert_nil(err)
  assert_deep_eq(ast, { type = "field", name = "type", op = "=", value = "note" })
  assert_eq(group, "folder")
end)

test("parse: group-only query yields match_all AST plus group mode", function()
  local ast, err, group = sq.parse_query("group:folder")
  assert_nil(err)
  assert_deep_eq(ast, { type = "match_all" })
  assert_eq(group, "folder")
end)

test("parse: url not parsed as field (// guard)", function()
  assert_deep_eq(parse_ok("http://x.com"), { type = "text", value = "http://x.com", quoted = false })
end)

test("parse: empty / whitespace / non-string queries error 'empty query'", function()
  local ast, err = sq.parse_query("")
  assert_nil(ast)
  assert_eq(err, "empty query")
  ast, err = sq.parse_query("   ")
  assert_nil(ast)
  assert_eq(err, "empty query")
  ast, err = sq.parse_query(nil)
  assert_nil(ast)
  assert_eq(err, "empty query")
  ast, err = sq.parse_query(42)
  assert_nil(ast)
  assert_eq(err, "empty query")
end)

test("parse: unterminated quote errors", function()
  local ast, err = sq.parse_query('"unterminated')
  assert_nil(ast)
  assert_match(err, "unterminated quoted string")
end)

test("parse: unterminated regex errors", function()
  local ast, err = sq.parse_query("/unterminated")
  assert_nil(ast)
  assert_match(err, "unterminated regex")
end)

test("parse: missing closing paren errors with 'expected RPAREN'", function()
  local ast, err = sq.parse_query("(a OR b")
  assert_nil(ast)
  assert_match(err, "expected RPAREN at position %d+")
end)

test("parse: unknown task- prefix falls back to text", function()
  assert_deep_eq(parse_ok("task-bogus:x"), { type = "text", value = "task-bogus:x", quoted = false })
end)

-- ============================================================================
-- 2. search_query.edit_distance / suggest_field
-- ============================================================================

test("edit_distance: kitten/sitting = 3", function()
  assert_eq(sq.edit_distance("kitten", "sitting"), 3)
end)

test("edit_distance: identical strings = 0", function()
  assert_eq(sq.edit_distance("status", "status"), 0)
end)

test("edit_distance: empty argument = length of other", function()
  assert_eq(sq.edit_distance("", "abc"), 3)
  assert_eq(sq.edit_distance("abc", ""), 3)
end)

test("suggest_field: 'staus' suggests 'status' at distance 1", function()
  local field, dist = sq.suggest_field("staus", { "status", "priority", "tag" })
  assert_eq(field, "status")
  assert_eq(dist, 1)
end)

test("suggest_field: names shorter than 3 chars yield nil", function()
  local field, dist = sq.suggest_field("st", { "status" })
  assert_nil(field)
  assert_nil(dist)
end)

test("suggest_field: no match within max_distance yields nil", function()
  local field, dist = sq.suggest_field("zzzzzz", { "status", "priority" })
  assert_nil(field)
  assert_nil(dist)
end)

test("suggest_field: custom max_distance widens acceptance", function()
  local field, dist = sq.suggest_field("statusss", { "status" }, 3)
  assert_eq(field, "status")
  assert_eq(dist, 2)
end)

-- ============================================================================
-- 3. classify
-- ============================================================================

test("classify: field/has/task/graph leaves are metadata", function()
  assert_eq(classify_mod.classify(parse_ok("status:active")), "metadata")
  assert_eq(classify_mod.classify(parse_ok("has:tasks")), "metadata")
  assert_eq(classify_mod.classify(parse_ok("task:wash")), "metadata")
  assert_eq(classify_mod.classify(parse_ok("graph:depth=2")), "metadata")
end)

test("classify: text/regex leaves are text", function()
  assert_eq(classify_mod.classify(parse_ok("hello")), "text")
  assert_eq(classify_mod.classify(parse_ok("/re.x/")), "text")
end)

test("classify: AND/OR of same class keeps the class", function()
  assert_eq(classify_mod.classify(parse_ok("status:active has:tasks")), "metadata")
  assert_eq(classify_mod.classify(parse_ok("hello world")), "text")
  assert_eq(classify_mod.classify(parse_ok("hello OR world")), "text")
end)

test("classify: AND/OR of different classes is mixed", function()
  assert_eq(classify_mod.classify(parse_ok("status:active hello")), "mixed")
  assert_eq(classify_mod.classify(parse_ok("status:active OR hello")), "mixed")
end)

test("classify: not takes the class of its operand", function()
  assert_eq(classify_mod.classify(parse_ok("NOT status:active")), "metadata")
  assert_eq(classify_mod.classify(parse_ok("NOT hello")), "text")
end)

test("classify: nil node is metadata", function()
  assert_eq(classify_mod.classify(nil), "metadata")
end)

test("classify: memoizes into provided cache", function()
  local ast = parse_ok("status:active hello")
  local cache = {}
  assert_eq(classify_mod.classify(ast, cache), "mixed")
  assert_eq(cache[ast], "mixed")
  -- second call served from cache, same answer
  assert_eq(classify_mod.classify(ast, cache), "mixed")
end)

-- ============================================================================
-- 4. ast_split.split_ast
-- ============================================================================

test("split_ast: metadata-only query", function()
  local ast = parse_ok("status:active")
  local split = ast_split.split_ast(ast)
  assert_eq(split.mode, "metadata_only")
  assert_deep_eq(split.metadata_ast, { type = "field", name = "status", op = "=", value = "active" })
  assert_nil(split.text_ast)
end)

test("split_ast: text-only query", function()
  local split = ast_split.split_ast(parse_ok("hello"))
  assert_eq(split.mode, "text_only")
  assert_nil(split.metadata_ast)
  assert_deep_eq(split.text_ast, { type = "text", value = "hello", quoted = false })
end)

test("split_ast: mixed AND splits into metadata_then_text", function()
  local split = ast_split.split_ast(parse_ok("status:active hello"))
  assert_eq(split.mode, "metadata_then_text")
  assert_deep_eq(split.metadata_ast, { type = "field", name = "status", op = "=", value = "active" })
  assert_deep_eq(split.text_ast, { type = "text", value = "hello", quoted = false })
end)

test("split_ast: mixed OR yields mixed_or mode (no sound partial trees)", function()
  local split = ast_split.split_ast(parse_ok("status:active OR hello"))
  assert_eq(split.mode, "mixed_or")
  assert_nil(split.metadata_ast)
  assert_nil(split.text_ast)
end)

test("split_ast: match_all AST yields metadata_only + match_all flag", function()
  local ast = select(1, sq.parse_query("group:folder"))
  local split = ast_split.split_ast(ast)
  assert_eq(split.mode, "metadata_only")
  assert_eq(split.match_all, true)
  assert_nil(split.metadata_ast)
  assert_nil(split.text_ast)
end)

test("split_ast: nil AST is text_only", function()
  local split = ast_split.split_ast(nil)
  assert_eq(split.mode, "text_only")
  assert_nil(split.metadata_ast)
  assert_nil(split.text_ast)
end)

-- ============================================================================
-- 5. match_helpers
-- ============================================================================

test("compare_num: comparison operators", function()
  assert_true(match_helpers.compare_num(2, ">", 1))
  assert_false(match_helpers.compare_num(1, ">", 2))
  assert_true(match_helpers.compare_num(2, ">=", 2))
  assert_true(match_helpers.compare_num(1, "<", 2))
  assert_true(match_helpers.compare_num(2, "<=", 2))
  assert_false(match_helpers.compare_num(3, "<=", 2))
  assert_true(match_helpers.compare_num(2, "=", 2))
end)

test("compare_num: unknown operator returns false", function()
  assert_false(match_helpers.compare_num(1, "!=", 2))
end)

test("in_num_range: inclusive and auto-swapping", function()
  assert_true(match_helpers.in_num_range(2, 1, 3))
  assert_true(match_helpers.in_num_range(1, 1, 3), "lo inclusive")
  assert_true(match_helpers.in_num_range(3, 1, 3), "hi inclusive")
  assert_false(match_helpers.in_num_range(4, 1, 3))
  assert_true(match_helpers.in_num_range(2, 3, 1), "reversed bounds auto-swap")
end)

test("compare_date: Nd filter value auto-inverts operator", function()
  -- '<7d' means "less than 7 days ago" => entry_ts > threshold
  assert_true(match_helpers.compare_date(100, "<", 50, "7d"))
  assert_false(match_helpers.compare_date(40, "<", 50, "7d"))
end)

test("compare_date: absolute date value does not invert", function()
  assert_true(match_helpers.compare_date(40, "<", 50, "2026-01-01"))
  assert_false(match_helpers.compare_date(100, "<", 50, "2026-01-01"))
end)

test("compare_date: explicit invert param overrides auto-detect", function()
  -- invert=false on an Nd value: standard comparison applies
  assert_false(match_helpers.compare_date(100, "<", 50, "7d", false))
  -- invert=true on an absolute value: inversion forced
  assert_true(match_helpers.compare_date(100, "<", 50, "2026-01-01", true))
end)

test("field_exists: special-cased and generic fields", function()
  local entry = make_entry()
  assert_true(match_helpers.field_exists("type", entry))
  assert_true(match_helpers.field_exists("tag", entry))
  assert_true(match_helpers.field_exists("status", entry))
  assert_true(match_helpers.field_exists("priority", entry))
  assert_true(match_helpers.field_exists("day", entry))
  assert_true(match_helpers.field_exists("alias", entry))
  assert_true(match_helpers.field_exists("path", entry), "path always exists")
  assert_true(match_helpers.field_exists("created", entry), "created always exists")
  assert_true(match_helpers.field_exists("rating", entry), "generic inline field")
  assert_false(match_helpers.field_exists("nonexistent", entry))

  local bare = { rel_path = "x.md" }
  assert_false(match_helpers.field_exists("type", bare))
  assert_false(match_helpers.field_exists("tag", bare))
  assert_false(match_helpers.field_exists("day", bare))
  assert_false(match_helpers.field_exists("alias", bare))
end)

test("get_generic_field: frontmatter wins over inline_fields", function()
  local entry = { frontmatter = { x = "fm" }, inline_fields = { x = "inline", y = "only-inline" } }
  assert_eq(match_helpers.get_generic_field(entry, "x"), "fm")
  assert_eq(match_helpers.get_generic_field(entry, "y"), "only-inline")
  assert_nil(match_helpers.get_generic_field(entry, "zzz"))
end)

test("get_generic_field: config field_aliases path resolution", function()
  local saved = config.search.field_aliases
  config.search.field_aliases = { area2 = "frontmatter.area" }
  local ok, err = pcall(function()
    local entry = make_entry()
    assert_eq(match_helpers.get_generic_field(entry, "area2"), "engineering")
  end)
  config.search.field_aliases = saved
  if not ok then error(err) end
end)

-- ============================================================================
-- 6. match_field (index = nil; pure paths only)
-- ============================================================================

local match_field = match_field_mod.match_field

test("match_field: type is case-insensitive equality", function()
  local entry = make_entry()
  assert_true(match_field(parse_ok("type:note"), entry, nil, nil))
  assert_true(match_field(parse_ok("type:NOTE"), entry, nil, nil))
  assert_false(match_field(parse_ok("type:task"), entry, nil, nil))
end)

test("match_field: tag is hierarchical with include/exclude", function()
  local entry = make_entry()
  assert_true(match_field(parse_ok("tag:project"), entry, nil, nil))
  assert_true(match_field(parse_ok("tag:work"), entry, nil, nil), "hierarchical prefix work/")
  assert_false(match_field(parse_ok("tag:archived"), entry, nil, nil))
  assert_true(match_field(parse_ok("tag:project,-archived"), entry, nil, nil))
  local archived = make_entry()
  archived.tags = { "project", "archived" }
  assert_false(match_field(parse_ok("tag:project,-archived"), archived, nil, nil), "exclude wins")
end)

test("match_field: path is case-sensitive prefix match", function()
  local entry = make_entry()
  assert_true(match_field(parse_ok("path:Projects/"), entry, nil, nil))
  assert_false(match_field(parse_ok("path:projects/"), entry, nil, nil), "case-sensitive")
  assert_false(match_field(parse_ok("path:Archive/"), entry, nil, nil))
end)

test("match_field: file is case-insensitive substring match", function()
  local entry = make_entry()
  assert_true(match_field(parse_ok("file:alpha"), entry, nil, nil))
  assert_true(match_field(parse_ok("file:ALPHA"), entry, nil, nil))
  assert_false(match_field(parse_ok("file:zeta"), entry, nil, nil))
end)

test("match_field: folder is exact or slash-terminated prefix", function()
  local entry = make_entry()
  assert_true(match_field(parse_ok("folder:Projects"), entry, nil, nil), "exact")
  assert_false(match_field(parse_ok("folder:Proj"), entry, nil, nil), "no bare prefix")
  local sub = make_entry()
  sub.folder = "Projects/Sub"
  assert_true(match_field(parse_ok("folder:Projects"), sub, nil, nil), "slash prefix")
end)

test("match_field: alias matches case-insensitively", function()
  local entry = make_entry()
  assert_true(match_field(parse_ok("alias:Alpha"), entry, nil, nil))
  assert_true(match_field(parse_ok('alias:"the alpha project"'), entry, nil, nil))
  assert_false(match_field(parse_ok("alias:beta"), entry, nil, nil))
end)

test("match_field: status is case-insensitive equality", function()
  local entry = make_entry()
  assert_true(match_field(parse_ok("status:active"), entry, nil, nil))
  assert_false(match_field(parse_ok("status:done"), entry, nil, nil))
end)

test("match_field: priority numeric comparisons and range", function()
  local entry = make_entry() -- frontmatter priority = 2
  assert_true(match_field(parse_ok("priority:2"), entry, nil, nil))
  assert_true(match_field(parse_ok("priority:>=2"), entry, nil, nil))
  assert_false(match_field(parse_ok("priority:>2"), entry, nil, nil))
  assert_true(match_field(parse_ok("priority:1..3"), entry, nil, nil))
  assert_false(match_field(parse_ok("priority:3..5"), entry, nil, nil))
end)

test("match_field: created equality is same-day, comparisons date-aware", function()
  local entry = make_entry() -- created 2026-03-15 10:30
  assert_true(match_field(parse_ok("created:2026-03-15"), entry, nil, nil))
  assert_false(match_field(parse_ok("created:2026-03-16"), entry, nil, nil))
  assert_true(match_field(parse_ok("created:>2026-01-01"), entry, nil, nil))
  assert_false(match_field(parse_ok("created:>2026-04-01"), entry, nil, nil))
  assert_true(match_field(parse_ok("created:2026-03-01..2026-03-31"), entry, nil, nil))
  assert_false(match_field(parse_ok("created:2026-04-01..2026-04-30"), entry, nil, nil))
end)

test("match_field: day exact-string and comparison matching", function()
  local entry = make_entry() -- day 2026-06-09
  assert_true(match_field(parse_ok("day:2026-06-09"), entry, nil, nil))
  assert_false(match_field(parse_ok("day:2026-06-08"), entry, nil, nil))
  assert_true(match_field(parse_ok("day:>2026-06-01"), entry, nil, nil))
  assert_false(match_field(parse_ok("day:<2026-06-01"), entry, nil, nil))
end)

test("match_field: generic fields numeric, string-eq, and string range", function()
  local entry = make_entry() -- rating="8" (inline), area="engineering" (frontmatter)
  assert_true(match_field(parse_ok("rating:>5"), entry, nil, nil))
  assert_false(match_field(parse_ok("rating:>9"), entry, nil, nil))
  assert_true(match_field(parse_ok("rating:8"), entry, nil, nil))
  assert_true(match_field(parse_ok("area:engineering"), entry, nil, nil))
  assert_true(match_field(parse_ok("area:ENGINEERING"), entry, nil, nil), "case-insensitive eq")
  assert_false(match_field(parse_ok("area:marketing"), entry, nil, nil))
  assert_true(match_field(parse_ok("area:a..f"), entry, nil, nil), "lexicographic range")
  assert_false(match_field(parse_ok("area:f..z"), entry, nil, nil))
end)

test("match_field: empty value with = means field exists", function()
  local entry = make_entry()
  assert_true(match_field(parse_ok("status:"), entry, nil, nil))
  assert_true(match_field(parse_ok("rating:"), entry, nil, nil))
  assert_false(match_field(parse_ok("nonexistent:"), entry, nil, nil))
end)

test("match_field: links-to / linked-from require an index", function()
  local entry = make_entry()
  assert_false(match_field(parse_ok("links-to:Other"), entry, nil, nil))
  assert_false(match_field(parse_ok("linked-from:Other"), entry, nil, nil))
end)

-- ============================================================================
-- 7. match_has (index = nil)
-- ============================================================================

local match_has = match_has_mod.match_has

test("match_has: tags/aliases/tasks/outlinks/frontmatter present", function()
  local entry = make_entry()
  assert_true(match_has({ type = "has", target = "tags" }, entry, nil))
  assert_true(match_has({ type = "has", target = "aliases" }, entry, nil))
  assert_true(match_has({ type = "has", target = "tasks" }, entry, nil))
  assert_true(match_has({ type = "has", target = "outlinks" }, entry, nil))
  assert_true(match_has({ type = "has", target = "frontmatter" }, entry, nil))
end)

test("match_has: absent collections do not match", function()
  local bare = { rel_path = "x.md" }
  assert_false(match_has({ type = "has", target = "tags" }, bare, nil))
  assert_false(match_has({ type = "has", target = "aliases" }, bare, nil))
  assert_false(match_has({ type = "has", target = "tasks" }, bare, nil))
  assert_false(match_has({ type = "has", target = "outlinks" }, bare, nil))
  assert_false(match_has({ type = "has", target = "frontmatter" }, bare, nil))
  local empty_fm = { rel_path = "y.md", frontmatter = {} }
  assert_false(match_has({ type = "has", target = "frontmatter" }, empty_fm, nil))
end)

test("match_has: inlinks without index is false", function()
  assert_false(match_has({ type = "has", target = "inlinks" }, make_entry(), nil))
end)

test("match_has: unknown target falls back to field presence", function()
  local entry = make_entry()
  assert_true(match_has({ type = "has", target = "rating" }, entry, nil), "inline field presence")
  assert_true(match_has({ type = "has", target = "area" }, entry, nil), "frontmatter presence")
  assert_false(match_has({ type = "has", target = "zzz" }, entry, nil))
end)

-- ============================================================================
-- 8. match_task (no index needed)
-- ============================================================================

local match_task = match_task_mod.match_task

test("match_task: variant any matches by existence and substring", function()
  local entry = make_entry()
  assert_true(match_task(parse_ok("task:"), entry, nil), "empty pattern: any tasks exist")
  assert_true(match_task(parse_ok("task:wash"), entry, nil))
  assert_false(match_task(parse_ok("task:nonexistenttext"), entry, nil))
end)

test("match_task: variant todo matches only open tasks", function()
  local entry = make_entry()
  assert_true(match_task(parse_ok("task-todo:wash"), entry, nil))
  assert_false(match_task(parse_ok("task-todo:ship"), entry, nil), "ship is done, not todo")
end)

test("match_task: variant done matches only completed tasks", function()
  local entry = make_entry()
  assert_true(match_task(parse_ok("task-done:ship"), entry, nil))
  assert_false(match_task(parse_ok("task-done:wash"), entry, nil))
end)

test("match_task: no tasks means no match", function()
  local empty = { rel_path = "x.md", tasks = {} }
  assert_false(match_task(parse_ok("task:"), empty, nil))
end)

test("match_task: meta due equality is same-day (fixed dates)", function()
  local entry = make_entry() -- due 2026-06-15
  assert_true(match_task(parse_ok("task-due:2026-06-15"), entry, nil))
  assert_false(match_task(parse_ok("task-due:2026-06-16"), entry, nil))
end)

test("match_task: meta due comparison with absolute dates", function()
  local entry = make_entry()
  assert_true(match_task(parse_ok("task-due:<2026-07-01"), entry, nil))
  assert_false(match_task(parse_ok("task-due:<2026-06-10"), entry, nil))
end)

test("match_task: meta due range", function()
  local entry = make_entry()
  assert_true(match_task(parse_ok("task-due:2026-06-01..2026-06-30"), entry, nil))
  assert_false(match_task(parse_ok("task-due:2026-07-01..2026-07-31"), entry, nil))
end)

test("match_task: meta scheduled and completion dates", function()
  local entry = make_entry() -- scheduled 2026-06-10, completion 2026-05-20
  assert_true(match_task(parse_ok("task-scheduled:2026-06-10"), entry, nil))
  assert_true(match_task(parse_ok("task-completion:2026-05-20"), entry, nil))
  assert_false(match_task(parse_ok("task-completion:2026-05-21"), entry, nil))
end)

test("match_task: meta priority comparisons and range", function()
  local entry = make_entry() -- priorities 2 and 1
  assert_true(match_task(parse_ok("task-priority:<=2"), entry, nil))
  assert_false(match_task(parse_ok("task-priority:>2"), entry, nil))
  assert_true(match_task(parse_ok("task-priority:1..1"), entry, nil))
end)

test("match_task: meta tag is hierarchical on task tags", function()
  local entry = make_entry()
  assert_true(match_task(parse_ok("task-tag:urgent"), entry, nil))
  assert_true(match_task(parse_ok("task-tag:home"), entry, nil), "home/chores prefix")
  assert_false(match_task(parse_ok("task-tag:office"), entry, nil))
end)

test("match_task: meta repeat exists and substring", function()
  local entry = make_entry()
  assert_true(match_task(parse_ok("task-repeat:"), entry, nil), "empty value: rule exists")
  assert_true(match_task(parse_ok("task-repeat:week"), entry, nil))
  assert_false(match_task(parse_ok("task-repeat:month"), entry, nil))
end)

test("match_task: meta state resolves labels and single-char marks", function()
  local entry = make_entry()
  assert_true(match_task(parse_ok("task-state:in-progress"), entry, nil), "label -> '/' mark")
  assert_true(match_task(parse_ok("task-state:x"), entry, nil), "single-char mark passthrough")
  assert_true(match_task(parse_ok("task-state:open"), entry, nil), "label -> ' ' mark")
  assert_false(match_task(parse_ok("task-state:deferred"), entry, nil))
end)

test("match_task: meta empty value means field exists on any task", function()
  local entry = make_entry()
  assert_true(match_task(parse_ok("task-due:"), entry, nil))
  assert_true(match_task(parse_ok("task-scheduled:"), entry, nil))
  local no_meta = { rel_path = "x.md", tasks = { { text_lower = "plain", status = " " } } }
  assert_false(match_task(parse_ok("task-due:"), no_meta, nil))
end)

-- ============================================================================
-- 9. date_utils
-- ============================================================================

test("date_utils: is_leap_year", function()
  assert_true(date_utils.is_leap_year(2024))
  assert_false(date_utils.is_leap_year(2026))
  assert_true(date_utils.is_leap_year(2000))
  assert_false(date_utils.is_leap_year(1900))
end)

test("date_utils: days_in_month", function()
  assert_eq(date_utils.days_in_month(2024, 2), 29)
  assert_eq(date_utils.days_in_month(2026, 2), 28)
  assert_eq(date_utils.days_in_month(2026, 4), 30)
  assert_eq(date_utils.days_in_month(2026, 1), 31)
end)

test("date_utils: format_date zero-pads", function()
  assert_eq(date_utils.format_date(2026, 6, 9), "2026-06-09")
end)

test("date_utils: days_since_monday (ISO week convention)", function()
  assert_eq(date_utils.days_since_monday(2), 0, "Monday")
  assert_eq(date_utils.days_since_monday(1), 6, "Sunday")
  assert_eq(date_utils.days_since_monday(7), 5, "Saturday")
end)

test("date_utils: parse_iso_datetime date-only and full forms", function()
  assert_eq(date_utils.parse_iso_datetime("2026-06-09"), ts(2026, 6, 9))
  assert_eq(date_utils.parse_iso_datetime("2026-06-09T14:30:15"), ts(2026, 6, 9, 14, 30, 15))
  assert_eq(date_utils.parse_iso_datetime("2026-06-09", 12), ts(2026, 6, 9, 12), "default_hour")
  assert_nil(date_utils.parse_iso_datetime("nope"))
  assert_nil(date_utils.parse_iso_datetime(nil))
end)

test("date_utils: is_iso_date", function()
  assert_true(date_utils.is_iso_date("2026-06-09"))
  assert_false(date_utils.is_iso_date("nope"))
  assert_false(date_utils.is_iso_date(nil))
end)

test("date_utils: same_day compares local calendar day", function()
  assert_true(date_utils.same_day(ts(2026, 6, 9, 1), ts(2026, 6, 9, 23)))
  assert_false(date_utils.same_day(ts(2026, 6, 9, 23), ts(2026, 6, 10, 0)))
end)

test("date_utils: in_date_range includes the hi calendar day, exclusive after", function()
  local lo = ts(2026, 6, 1)
  local hi = ts(2026, 6, 5)
  assert_true(date_utils.in_date_range(ts(2026, 6, 1), lo, hi), "lo inclusive")
  assert_true(date_utils.in_date_range(ts(2026, 6, 5, 12), lo, hi), "hi day included")
  assert_false(date_utils.in_date_range(ts(2026, 6, 6), lo, hi), "exclusive at hi+1d")
  assert_false(date_utils.in_date_range(ts(2026, 5, 31, 23), lo, hi))
  assert_true(date_utils.in_date_range(ts(2026, 6, 3), hi, lo), "reversed bounds auto-swap")
end)

test("date_utils: is_relative_duration", function()
  assert_true(date_utils.is_relative_duration("7d"))
  assert_true(date_utils.is_relative_duration("7D"))
  assert_false(date_utils.is_relative_duration("7"))
  assert_false(date_utils.is_relative_duration("2026-01-01"))
  assert_false(date_utils.is_relative_duration(nil))
end)

test("date_utils: in_keyword_range returns nil for non-keyword values", function()
  assert_nil(date_utils.in_keyword_range(ts(2026, 6, 9), "2026-01-01"))
  assert_nil(date_utils.in_keyword_range(ts(2026, 6, 9), "7d"))
end)

test("date_utils: days_between", function()
  assert_eq(date_utils.days_between("2026-01-01", "2026-01-11"), 10)
  assert_eq(date_utils.days_between("2026-01-11", "2026-01-01"), -10)
  assert_eq(date_utils.days_between("2026-01-01", "2026-01-01"), 0)
end)

test("date_utils: date_add crosses month boundaries", function()
  assert_eq(date_utils.date_add("2026-01-30", 5), "2026-02-04")
  assert_eq(date_utils.date_add("2026-01-01", -1), "2025-12-31")
end)

test("date_utils: format_date_short", function()
  assert_eq(date_utils.format_date_short("2026-03-01"), "Mar 01")
end)

test("date_utils: truncate with ellipsis", function()
  assert_eq(date_utils.truncate("abcdef", 4), "abc…")
  assert_eq(date_utils.truncate("abc", 4), "abc")
  assert_eq(date_utils.truncate(nil, 4), "")
end)

-- ============================================================================
-- 10. filter_utils
-- ============================================================================

test("filter_utils: parse_tag_filter include/exclude lists", function()
  local inc, exc = filter_utils.parse_tag_filter("project,-archived,-template")
  assert_deep_eq(inc, { "project" })
  assert_deep_eq(exc, { "archived", "template" })

  inc, exc = filter_utils.parse_tag_filter("project")
  assert_deep_eq(inc, { "project" })
  assert_deep_eq(exc, {})

  inc, exc = filter_utils.parse_tag_filter("-archived")
  assert_deep_eq(inc, {})
  assert_deep_eq(exc, { "archived" })
end)

test("filter_utils: matches_include_exclude semantics", function()
  local function eq(target)
    return function(item) return item == target end
  end
  assert_true(filter_utils.matches_include_exclude({ "a" }, { "b" }, eq("a")), "include matches")
  assert_false(filter_utils.matches_include_exclude({ "a" }, { "b" }, eq("b")), "exclude wins")
  assert_true(filter_utils.matches_include_exclude(nil, nil, eq("x")), "no constraints -> true")
  assert_true(filter_utils.matches_include_exclude({}, {}, eq("x")), "empty lists -> true")
  assert_false(filter_utils.matches_include_exclude({ "a" }, {}, eq("z")), "no include matches -> false")
end)

test("filter_utils: normalize_link_name strips fragments, trims, lowercases", function()
  assert_eq(filter_utils.normalize_link_name("Note Name#Heading^block"), "note name")
  assert_eq(filter_utils.normalize_link_name("  Spaced  "), "spaced")
  assert_eq(filter_utils.normalize_link_name("Plain"), "plain")
  assert_nil(filter_utils.normalize_link_name(""))
  assert_nil(filter_utils.normalize_link_name("   "))
end)

test("filter_utils: get_entry_timestamp fast paths and fallbacks", function()
  local entry = make_entry()
  assert_eq(filter_utils.get_entry_timestamp(entry, "created"), entry.created_ts)
  assert_eq(filter_utils.get_entry_timestamp(entry, "modified"), entry.modified_ts)
  assert_eq(filter_utils.get_entry_timestamp(entry, "day"), entry.day_ts)

  -- day string fallback (no day_ts)
  local day_only = { day = "2026-06-09" }
  assert_eq(filter_utils.get_entry_timestamp(day_only, "day"), ts(2026, 6, 9))

  -- frontmatter fallback
  local fm = { frontmatter = { created = "2026-02-01" } }
  assert_eq(filter_utils.get_entry_timestamp(fm, "created"), ts(2026, 2, 1))

  -- filesystem fallbacks
  local fs = { mtime = 12345, ctime = 11111 }
  assert_eq(filter_utils.get_entry_timestamp(fs, "modified"), 12345)
  assert_eq(filter_utils.get_entry_timestamp(fs, "created"), 11111)
  local fs2 = { mtime = 12345 }
  assert_eq(filter_utils.get_entry_timestamp(fs2, "created"), 12345, "ctime falls back to mtime")

  assert_nil(filter_utils.get_entry_timestamp(nil, "created"))
  assert_nil(filter_utils.get_entry_timestamp({}, "day"))
end)

test("filter_utils: filter_cache_key sorts keys deterministically", function()
  assert_eq(filter_utils.filter_cache_key({ b = 2, a = 1 }), "a=1|b=2")
  assert_eq(filter_utils.filter_cache_key({}), "")
  assert_eq(filter_utils.filter_cache_key(nil), "")
end)

test("filter_utils: is_cache_gen_valid", function()
  assert_true(filter_utils.is_cache_gen_valid({ gen = 5 }, 5))
  assert_false(filter_utils.is_cache_gen_valid({ gen = 4 }, 5))
  assert_false(filter_utils.is_cache_gen_valid(nil, 5))
  assert_false(filter_utils.is_cache_gen_valid({ gen = 0 }, 0), "gen 0 never valid")
  assert_true(filter_utils.is_cache_gen_valid({ index_gen = 7 }, 7, "index_gen"), "custom gen field")
end)

test("filter_utils: build_row_index keys entries by row", function()
  local a, b = { row = 0 }, { row = 3 }
  local idx = filter_utils.build_row_index({ a, b })
  assert_eq(idx[0], a)
  assert_eq(idx[3], b)
  assert_nil(idx[1])
end)

test("filter_utils: passes_task_filter predicates", function()
  assert_false(filter_utils.passes_task_filter({ priority = "5" }, { priority_max = 3 }))
  assert_true(filter_utils.passes_task_filter({ priority = "2" }, { priority_max = 3 }))
  assert_true(filter_utils.passes_task_filter({ priority = "5" }, nil), "nil opts passes")
  assert_true(filter_utils.passes_task_filter(
    { text_lower = "wash the car" }, { text_pattern = "CAR" }), "case-insensitive text")
  assert_false(filter_utils.passes_task_filter(
    { text_lower = "wash the car" }, { text_pattern = "boat" }))
  assert_false(filter_utils.passes_task_filter(
    { due = "2026-06-15" }, { due_before = "2026-06-10" }))
  assert_true(filter_utils.passes_task_filter(
    { due = "2026-06-15" }, { due_before = "2026-06-20" }))
  assert_false(filter_utils.passes_task_filter({}, { due_before = "2026-06-10" }), "no due fails due_before")
end)

-- ============================================================================
-- 11. search_filter.match_entry (metadata-only integration) + ast_contains_graph
-- ============================================================================

test("match_entry: single field node", function()
  local entry = make_entry()
  assert_true(search_filter.match_entry(parse_ok("type:note"), entry, nil))
  assert_false(search_filter.match_entry(parse_ok("type:task"), entry, nil))
end)

test("match_entry: implicit AND of metadata nodes", function()
  local entry = make_entry()
  assert_true(search_filter.match_entry(parse_ok("tag:project status:active"), entry, nil))
  assert_false(search_filter.match_entry(parse_ok("tag:project status:done"), entry, nil))
end)

test("match_entry: NOT", function()
  local entry = make_entry()
  assert_true(search_filter.match_entry(parse_ok("NOT type:task"), entry, nil))
  assert_false(search_filter.match_entry(parse_ok("NOT type:note"), entry, nil))
end)

test("match_entry: OR", function()
  local entry = make_entry()
  assert_true(search_filter.match_entry(parse_ok("type:task OR tag:project"), entry, nil))
  assert_false(search_filter.match_entry(parse_ok("type:task OR tag:archived"), entry, nil))
end)

test("match_entry: has and task nodes", function()
  local entry = make_entry()
  assert_true(search_filter.match_entry(parse_ok("has:tasks"), entry, nil))
  assert_true(search_filter.match_entry(parse_ok("has:tags task-tag:urgent"), entry, nil))
end)

test("match_entry: nil AST matches, nil entry does not", function()
  assert_true(search_filter.match_entry(nil, make_entry(), nil))
  assert_false(search_filter.match_entry(parse_ok("type:note"), nil, nil))
end)

test("ast_contains_graph detects graph nodes anywhere in the tree", function()
  assert_false(search_filter.ast_contains_graph(parse_ok("type:note")))
  assert_true(search_filter.ast_contains_graph(parse_ok("graph:depth=2")))
  assert_true(search_filter.ast_contains_graph(parse_ok("type:note graph:depth=1")))
  assert_true(search_filter.ast_contains_graph(parse_ok("NOT (a OR graph:neighbors)")))
end)

-- ============================================================================
-- Summary
-- ============================================================================
_H.finish({ style = "results_assertions", exit = "os" })
