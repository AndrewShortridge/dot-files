-- Unit tests for vault task logic:
--   andrew.vault.recurrence      (parse_rule, next_date)
--   andrew.vault.vault_index     (parse_task_fields)
--   andrew.vault.task_utils      (checkbox, comparators, format_task_line)
--   andrew.vault.task_hierarchy  (build_tree, completion_stats)
-- Run with: nvim --headless -u NONE -l tests/task_logic_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil, assert_deep_eq =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil, _H.assert_deep_eq

-- ============================================================================
-- Load modules under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local rec = require("andrew.vault.recurrence")
local vi = require("andrew.vault.vault_index")
local tu = require("andrew.vault.task_utils")
local th = require("andrew.vault.task_hierarchy")

print("\n=== Task Logic Tests ===\n")

-- ---------------------------------------------------------------------------
-- 1. recurrence.parse_rule
-- ---------------------------------------------------------------------------

test("parse_rule: every day", function()
  assert_deep_eq(rec.parse_rule("every day"), { type = "days", n = 1 })
end)

test("parse_rule: every weekday", function()
  assert_deep_eq(rec.parse_rule("every weekday"), { type = "weekday", n = 1 })
end)

test("parse_rule: every week == 7 days", function()
  assert_deep_eq(rec.parse_rule("every week"), { type = "days", n = 7 })
end)

test("parse_rule: every N weeks multiplies by 7", function()
  assert_deep_eq(rec.parse_rule("every 2 weeks"), { type = "days", n = 14 })
end)

test("parse_rule: every month on the Nth", function()
  assert_deep_eq(rec.parse_rule("every month on the 15th"), { type = "monthly_on", n = 1, day = 15 })
end)

test("parse_rule: every month on the 1st", function()
  assert_deep_eq(rec.parse_rule("every month on the 1st"), { type = "monthly_on", n = 1, day = 1 })
end)

test("parse_rule: every month", function()
  assert_deep_eq(rec.parse_rule("every month"), { type = "months", n = 1 })
end)

test("parse_rule: every quarter == 3 months", function()
  assert_deep_eq(rec.parse_rule("every quarter"), { type = "months", n = 3 })
end)

test("parse_rule: every year", function()
  assert_deep_eq(rec.parse_rule("every year"), { type = "years", n = 1 })
end)

test("parse_rule: every N days", function()
  assert_deep_eq(rec.parse_rule("every 5 days"), { type = "days", n = 5 })
end)

test("parse_rule: case-insensitive and trimmed", function()
  assert_deep_eq(rec.parse_rule("  EVERY DAY  "), { type = "days", n = 1 })
end)

test("parse_rule: unknown string returns nil", function()
  assert_nil(rec.parse_rule("nonsense"))
end)

test("parse_rule: nil input returns nil", function()
  assert_nil(rec.parse_rule(nil))
end)

test("parse_rule: 'every 3 week' (no s) still matches via weeks?", function()
  assert_deep_eq(rec.parse_rule("every 3 week"), { type = "days", n = 21 })
end)

test("parse_rule: 'every 0 days' yields n=0 (no validation)", function()
  assert_deep_eq(rec.parse_rule("every 0 days"), { type = "days", n = 0 })
end)

-- ---------------------------------------------------------------------------
-- 2. recurrence.next_date
-- ---------------------------------------------------------------------------

test("next_date: daily +1", function()
  assert_eq(rec.next_date("2026-06-09", { type = "days", n = 1 }), "2026-06-10")
end)

test("next_date: weekly via days n=7", function()
  assert_eq(rec.next_date("2026-06-09", { type = "days", n = 7 }), "2026-06-16")
end)

test("next_date: month rollover overflow (Jan31 +1mo -> Feb overflow -> Mar 3 in 2026)", function()
  assert_eq(rec.next_date("2026-01-31", { type = "months", n = 1 }), "2026-03-03")
end)

test("next_date: year rollover (Dec +1mo -> Jan next year)", function()
  assert_eq(rec.next_date("2026-12-15", { type = "months", n = 1 }), "2027-01-15")
end)

test("next_date: day31 +1mo into 30-day month (Mar31 -> May1)", function()
  assert_eq(rec.next_date("2026-03-31", { type = "months", n = 1 }), "2026-05-01")
end)

test("next_date: years preserves month/day", function()
  assert_eq(rec.next_date("2026-02-28", { type = "years", n = 1 }), "2027-02-28")
end)

test("next_date: leap-day +1yr normalizes (Feb29 2024 -> Mar1 2025)", function()
  assert_eq(rec.next_date("2024-02-29", { type = "years", n = 1 }), "2025-03-01")
end)

test("next_date: monthly_on jumps to fixed day of next month", function()
  assert_eq(rec.next_date("2026-06-09", { type = "monthly_on", n = 1, day = 15 }), "2026-07-15")
end)

test("next_date: monthly_on from end of month uses next-month fixed day", function()
  assert_eq(rec.next_date("2026-01-31", { type = "monthly_on", n = 1, day = 15 }), "2026-02-15")
end)

test("next_date: monthly_on day31 overflow (Aug31 -> Sep has 30 -> Oct 1)", function()
  assert_eq(rec.next_date("2026-08-31", { type = "monthly_on", n = 1, day = 31 }), "2026-10-01")
end)

test("next_date: weekday from Friday skips weekend to Monday", function()
  -- 2026-06-12 is a Friday
  assert_eq(rec.next_date("2026-06-12", { type = "weekday", n = 1 }), "2026-06-15")
end)

test("next_date: weekday from Saturday -> Monday", function()
  assert_eq(rec.next_date("2026-06-13", { type = "weekday", n = 1 }), "2026-06-15")
end)

test("next_date: weekday from Sunday -> Monday", function()
  assert_eq(rec.next_date("2026-06-14", { type = "weekday", n = 1 }), "2026-06-15")
end)

test("next_date: weekday from Monday -> next day Tuesday (no skip)", function()
  -- 2026-06-08 is a Monday
  assert_eq(rec.next_date("2026-06-08", { type = "weekday", n = 1 }), "2026-06-09")
end)

test("next_date: unknown rule type returns input unchanged", function()
  assert_eq(rec.next_date("2026-06-09", { type = "frobnicate", n = 1 }), "2026-06-09")
end)

test("next_date: day arithmetic crosses year boundary deterministically", function()
  assert_eq(rec.next_date("2026-12-31", { type = "days", n = 1 }), "2027-01-01")
end)

test("next_date: malformed input falls back to today's date (format only)", function()
  -- IMPURE FALLBACK: returns engine.today(); assert only the shape, not the value.
  local got = rec.next_date("not-a-date", { type = "days", n = 1 })
  assert_true(type(got) == "string" and got:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil,
    "fallback should be an ISO date string, got: " .. vim.inspect(got))
  assert_true(got ~= "not-a-date", "fallback should not echo malformed input")
end)

-- ---------------------------------------------------------------------------
-- 3. vault_index.parse_task_fields
-- ---------------------------------------------------------------------------

test("parse_task_fields: bracket due + priority", function()
  local r = vi.parse_task_fields("Buy milk [due:: 2026-06-15] [priority:: 1]")
  assert_deep_eq(r, { due = "2026-06-15", priority = 1 })
end)

test("parse_task_fields: paren form", function()
  local r = vi.parse_task_fields("Task (due:: 2026-07-01) (priority:: 2)")
  assert_deep_eq(r, { due = "2026-07-01", priority = 2 })
end)

test("parse_task_fields: repeat key renamed to repeat_rule", function()
  local r = vi.parse_task_fields("Pay rent [repeat:: every month] [due:: 2026-06-01]")
  assert_deep_eq(r, { due = "2026-06-01", repeat_rule = "every month" })
end)

test("parse_task_fields: completion + scheduled", function()
  local r = vi.parse_task_fields("Done [completion:: 2026-05-01] [scheduled:: 2026-04-28]")
  assert_deep_eq(r, { completion = "2026-05-01", scheduled = "2026-04-28" })
end)

test("parse_task_fields: rejects non-iso due and non-numeric priority", function()
  local r = vi.parse_task_fields("Bad [due:: not-a-date] [priority:: high]")
  assert_nil(r.due)
  assert_nil(r.priority)
  assert_nil(next(r), "result should be an empty table")
end)

test("parse_task_fields: unknown keys go into .fields", function()
  local r = vi.parse_task_fields("Mixed [project:: alpha] [context:: home]")
  assert_true(r.fields ~= nil, "expected .fields subtable")
  assert_eq(r.fields.project, "alpha")
  assert_eq(r.fields.context, "home")
  assert_nil(r.due)
end)

test("parse_task_fields: ignores fields inside inline code backticks", function()
  local r = vi.parse_task_fields("Code `[due:: 2026-01-01]` ignored")
  assert_nil(r.due)
end)

test("parse_task_fields: rejects empty repeat value", function()
  local r = vi.parse_task_fields("Empty [repeat:: ]")
  assert_nil(r.repeat_rule)
  assert_nil(next(r), "result should be an empty table")
end)

test("parse_task_fields: bracket precedence over paren for same key", function()
  local r = vi.parse_task_fields("x [due:: 2026-01-01] (due:: 2026-02-02)")
  assert_deep_eq(r, { due = "2026-01-01" })
end)

test("parse_task_fields: no fields yields empty table", function()
  local r = vi.parse_task_fields("Plain task no fields")
  assert_nil(next(r))
end)

test("parse_task_fields: priority accepts float", function()
  local r = vi.parse_task_fields("P [priority:: 2.5]")
  assert_deep_eq(r, { priority = 2.5 })
end)

test("parse_task_fields: space after :: is optional", function()
  local r = vi.parse_task_fields("[due::2026-06-15]")
  assert_deep_eq(r, { due = "2026-06-15" })
end)

test("parse_task_fields: trims surrounding whitespace in value", function()
  local r = vi.parse_task_fields("[priority::   3   ]")
  assert_deep_eq(r, { priority = 3 })
end)

test("parse_task_fields: is_iso_date is structural only (accepts impossible date)", function()
  -- Documents structural-only validation: ^dddd-dd-dd$ with no semantic check.
  local r = vi.parse_task_fields("[due:: 2026-13-45]")
  assert_deep_eq(r, { due = "2026-13-45" })
end)

test("parse_task_fields: rejects unpadded date", function()
  local r = vi.parse_task_fields("[due:: 2026-1-1]")
  assert_nil(r.due)
  assert_nil(next(r), "result should be an empty table")
end)

test("parse_task_fields: keys are lowercased", function()
  local r = vi.parse_task_fields("x [DUE:: 2026-06-15] [Project:: alpha]")
  assert_eq(r.due, "2026-06-15")
  assert_eq(r.fields.project, "alpha")
end)

-- ---------------------------------------------------------------------------
-- 4. task_utils.checkbox
-- ---------------------------------------------------------------------------

test("checkbox: done lowercase", function()
  assert_eq(tu.checkbox("x"), "[x]")
end)

test("checkbox: done uppercase normalizes to lowercase", function()
  assert_eq(tu.checkbox("X"), "[x]")
end)

test("checkbox: in-progress", function()
  assert_eq(tu.checkbox("/"), "[/]")
end)

test("checkbox: cancelled", function()
  assert_eq(tu.checkbox("-"), "[-]")
end)

test("checkbox: forwarded", function()
  assert_eq(tu.checkbox(">"), "[>]")
end)

test("checkbox: space (todo)", function()
  assert_eq(tu.checkbox(" "), "[ ]")
end)

test("checkbox: empty string falls back to todo", function()
  assert_eq(tu.checkbox(""), "[ ]")
end)

test("checkbox: unknown char falls back to todo", function()
  assert_eq(tu.checkbox("z"), "[ ]")
end)

test("checkbox: nil falls back to todo", function()
  assert_eq(tu.checkbox(nil), "[ ]")
end)

-- ---------------------------------------------------------------------------
-- 5. task_utils.compare_priority_due
-- ---------------------------------------------------------------------------

test("compare_priority_due: lower priority sorts first", function()
  assert_true(tu.compare_priority_due({ priority = 1 }, { priority = 2 }))
  assert_true(not tu.compare_priority_due({ priority = 2 }, { priority = 1 }))
end)

test("compare_priority_due: nil priority sorts last (treated as 999)", function()
  assert_true(tu.compare_priority_due({ priority = 5 }, {}))
  assert_true(not tu.compare_priority_due({}, { priority = 5 }))
end)

test("compare_priority_due: equal priority tie-breaks by due ascending", function()
  local a = { priority = 1, due = "2026-06-01" }
  local b = { priority = 1, due = "2026-06-15" }
  assert_true(tu.compare_priority_due(a, b))
  assert_true(not tu.compare_priority_due(b, a))
end)

test("compare_priority_due: nil due sorts last on priority tie", function()
  local a = { priority = 1, due = "2026-06-01" }
  local b = { priority = 1 }
  assert_true(tu.compare_priority_due(a, b))
  assert_true(not tu.compare_priority_due(b, a))
end)

test("compare_priority_due: fully equal tasks compare false both ways (strict order)", function()
  local a = { priority = 1, due = "2026-06-01" }
  local b = { priority = 1, due = "2026-06-01" }
  assert_true(not tu.compare_priority_due(a, b))
  assert_true(not tu.compare_priority_due(b, a))
end)

test("compare_priority_due: sorts a list into priority-then-due order", function()
  local items = {
    { text = "c", priority = 2, due = "2026-01-01" },
    { text = "a", priority = 1, due = "2026-02-01" },
    { text = "d" },
    { text = "b", priority = 1, due = "2026-01-15" },
  }
  table.sort(items, tu.compare_priority_due)
  assert_eq(items[1].text, "b")
  assert_eq(items[2].text, "a")
  assert_eq(items[3].text, "c")
  assert_eq(items[4].text, "d")
end)

-- ---------------------------------------------------------------------------
-- 6. task_utils.compare_priority_text
-- ---------------------------------------------------------------------------

test("compare_priority_text: lower priority sorts first", function()
  assert_true(tu.compare_priority_text({ priority = 1, text = "zzz" }, { priority = 2, text = "aaa" }))
end)

test("compare_priority_text: nil priority sorts last", function()
  assert_true(tu.compare_priority_text({ priority = 998, text = "z" }, { text = "a" }))
  assert_true(not tu.compare_priority_text({ text = "a" }, { priority = 998, text = "z" }))
end)

test("compare_priority_text: equal priority tie-breaks by text", function()
  assert_true(tu.compare_priority_text({ priority = 1, text = "alpha" }, { priority = 1, text = "beta" }))
  assert_true(not tu.compare_priority_text({ priority = 1, text = "beta" }, { priority = 1, text = "alpha" }))
end)

test("compare_priority_text: nil text treated as empty string", function()
  assert_true(tu.compare_priority_text({ priority = 1 }, { priority = 1, text = "a" }))
  assert_true(not tu.compare_priority_text({ priority = 1, text = "a" }, { priority = 1 }))
end)

-- ---------------------------------------------------------------------------
-- 7. task_utils.format_task_line
-- ---------------------------------------------------------------------------

test("format_task_line: defaults (indent + checkbox + text, priority shown)", function()
  local line = tu.format_task_line({ status = " ", text = "Buy milk" })
  assert_eq(line, "    [ ] Buy milk")
end)

test("format_task_line: priority suffix appended by default", function()
  local line = tu.format_task_line({ status = "x", text = "Ship it", priority = 1 })
  assert_eq(line, "    [x] Ship it  (P1)")
end)

test("format_task_line: show_priority=false omits priority", function()
  local line = tu.format_task_line({ status = "x", text = "Ship it", priority = 1 }, { show_priority = false })
  assert_eq(line, "    [x] Ship it")
end)

test("format_task_line: due hidden by default, shown with show_due=true", function()
  local task = { status = "/", text = "Review", priority = 2, due = "2026-06-15" }
  assert_eq(tu.format_task_line(task), "    [/] Review  (P2)")
  assert_eq(tu.format_task_line(task, { show_due = true }), "    [/] Review  (P2)  2026-06-15")
end)

test("format_task_line: custom indent", function()
  local line = tu.format_task_line({ status = " ", text = "Task" }, { indent = "" })
  assert_eq(line, "[ ] Task")
end)

test("format_task_line: truncates long text with ellipsis to fit width", function()
  local text = string.rep("a", 40)
  local line = tu.format_task_line({ status = " ", text = text }, { width = 30, indent = "" })
  -- prefix "[ ] " = 4 chars, no suffixes -> text_max = 26 -> 25 a's + "…"
  assert_eq(line, "[ ] " .. string.rep("a", 25) .. "…")
end)

test("format_task_line: minimum text width of 10 enforced", function()
  -- width=10 with default indent gives text_max = 10-8 = 2 -> clamped to 10.
  local line = tu.format_task_line({ status = " ", text = "short" }, { width = 10 })
  assert_eq(line, "    [ ] short", "text of length <= 10 must not be truncated")
  local long = tu.format_task_line({ status = " ", text = "twelve chars" }, { width = 10 })
  assert_eq(long, "    [ ] twelve ch…", "text longer than clamped 10 truncates to 9 + ellipsis")
end)

test("format_task_line: reserved space shrinks text budget", function()
  local text = string.rep("b", 30)
  -- width=30, indent="" -> text_max = 30-4-10 = 16 -> 15 b's + "…"
  local line = tu.format_task_line({ status = " ", text = text }, { width = 30, indent = "", reserved = 10 })
  assert_eq(line, "[ ] " .. string.rep("b", 15) .. "…")
end)

test("format_task_line: nil text renders as empty", function()
  local line = tu.format_task_line({ status = "x" })
  assert_eq(line, "    [x] ")
end)

-- ---------------------------------------------------------------------------
-- 8. task_hierarchy.build_tree
-- ---------------------------------------------------------------------------

local function mk(line, indent, text, completed)
  return { line = line, indent_level = indent, text = text, completed = completed or false }
end

test("build_tree: flat list (all indent 0) -> all roots, no children", function()
  local tasks = { mk(1, 0, "a"), mk(2, 0, "b"), mk(3, 0, "c") }
  local roots = th.build_tree(tasks)
  assert_eq(#roots, 3)
  for i, r in ipairs(roots) do
    assert_eq(#r.children, 0, "root " .. i .. " should have no children")
    assert_nil(r.parent_line, "root " .. i .. " should have nil parent_line")
  end
  assert_eq(roots[1].text, "a")
  assert_eq(roots[3].text, "c")
end)

test("build_tree: simple parent-child nesting", function()
  local tasks = { mk(1, 0, "parent"), mk(2, 1, "child") }
  local roots = th.build_tree(tasks)
  assert_eq(#roots, 1)
  assert_eq(roots[1].text, "parent")
  assert_eq(#roots[1].children, 1)
  assert_eq(roots[1].children[1].text, "child")
  assert_eq(roots[1].children[1].parent_line, 1)
end)

test("build_tree: grandchild nesting", function()
  local tasks = { mk(1, 0, "root"), mk(2, 1, "child"), mk(3, 2, "grandchild") }
  local roots = th.build_tree(tasks)
  assert_eq(#roots, 1)
  local child = roots[1].children[1]
  assert_eq(#child.children, 1)
  assert_eq(child.children[1].text, "grandchild")
  assert_eq(child.children[1].parent_line, 2)
end)

test("build_tree: siblings at same indent attach to same parent", function()
  local tasks = { mk(1, 0, "p"), mk(2, 1, "c1"), mk(3, 1, "c2") }
  local roots = th.build_tree(tasks)
  assert_eq(#roots, 1)
  assert_eq(#roots[1].children, 2)
  assert_eq(roots[1].children[1].text, "c1")
  assert_eq(roots[1].children[2].text, "c2")
  assert_eq(roots[1].children[2].parent_line, 1)
end)

test("build_tree: dedent returns to root level", function()
  local tasks = { mk(1, 0, "p1"), mk(2, 1, "c1"), mk(3, 2, "g1"), mk(4, 0, "p2"), mk(5, 1, "c2") }
  local roots = th.build_tree(tasks)
  assert_eq(#roots, 2)
  assert_eq(roots[2].text, "p2")
  assert_nil(roots[2].parent_line)
  assert_eq(#roots[2].children, 1)
  assert_eq(roots[2].children[1].text, "c2")
  assert_eq(roots[2].children[1].parent_line, 4)
end)

test("build_tree: dedent by one level attaches to grandparent", function()
  -- g1 at indent 2, then sibling-of-child at indent 1 must pop back to root.
  local tasks = { mk(1, 0, "root"), mk(2, 1, "c1"), mk(3, 2, "g1"), mk(4, 1, "c2") }
  local roots = th.build_tree(tasks)
  assert_eq(#roots, 1)
  assert_eq(#roots[1].children, 2)
  assert_eq(roots[1].children[2].text, "c2")
  assert_eq(roots[1].children[2].parent_line, 1)
end)

test("build_tree: does not mutate input tasks (shallow copies)", function()
  local tasks = { mk(1, 0, "p"), mk(2, 1, "c") }
  local roots = th.build_tree(tasks)
  assert_nil(tasks[1].children, "input task must not gain .children")
  assert_nil(tasks[2].parent_line, "input task must not gain .parent_line")
  assert_true(roots[1] ~= tasks[1], "node must be a copy, not the input table")
  -- Copy carries the original fields.
  assert_eq(roots[1].text, "p")
  assert_eq(roots[1].line, 1)
  assert_eq(roots[1].indent_level, 0)
end)

test("build_tree: empty input yields empty roots", function()
  local roots = th.build_tree({})
  assert_eq(#roots, 0)
end)

-- ---------------------------------------------------------------------------
-- 9. task_hierarchy.completion_stats
-- ---------------------------------------------------------------------------

test("completion_stats: incomplete leaf -> 0/1", function()
  local roots = th.build_tree({ mk(1, 0, "leaf", false) })
  local done, total = th.completion_stats(roots[1])
  assert_eq(done, 0)
  assert_eq(total, 1)
end)

test("completion_stats: completed leaf -> 1/1", function()
  local roots = th.build_tree({ mk(1, 0, "leaf", true) })
  local done, total = th.completion_stats(roots[1])
  assert_eq(done, 1)
  assert_eq(total, 1)
end)

test("completion_stats: branch aggregates children (mixed)", function()
  local roots = th.build_tree({
    mk(1, 0, "p", false),
    mk(2, 1, "c1", true),
    mk(3, 1, "c2", false),
    mk(4, 1, "c3", true),
  })
  local done, total = th.completion_stats(roots[1])
  assert_eq(done, 2)
  assert_eq(total, 3)
end)

test("completion_stats: branch ignores its own completed flag", function()
  local roots = th.build_tree({
    mk(1, 0, "p", true), -- parent marked complete...
    mk(2, 1, "c1", false), -- ...but its only child is incomplete
  })
  local done, total = th.completion_stats(roots[1])
  assert_eq(done, 0, "parent's own .completed must not count")
  assert_eq(total, 1)
end)

test("completion_stats: nested tree counts all leaves", function()
  local roots = th.build_tree({
    mk(1, 0, "root", false),
    mk(2, 1, "c1", true),
    mk(3, 2, "g1", true),
    mk(4, 2, "g2", false),
    mk(5, 1, "c2", true),
  })
  -- c1 is a branch (g1, g2): contributes 1/2. c2 is a leaf: 1/1. Total 2/3.
  local done, total = th.completion_stats(roots[1])
  assert_eq(done, 2)
  assert_eq(total, 3)
end)

test("completion_stats: all children complete -> done == total", function()
  local roots = th.build_tree({
    mk(1, 0, "p", false),
    mk(2, 1, "c1", true),
    mk(3, 1, "c2", true),
  })
  local done, total = th.completion_stats(roots[1])
  assert_eq(done, 2)
  assert_eq(total, 2)
end)

-- ============================================================================
-- Summary
-- ============================================================================
_H.finish({ style = "results", exit = "os" })
