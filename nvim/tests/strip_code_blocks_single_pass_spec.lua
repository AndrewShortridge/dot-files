-- Behavioral parity spec for the single-pass strip_code_blocks refactor.
--
-- strip_code_blocks used to run MULTIPLE times per parse over the same content
-- (extract_tags re-stripped the body, extract_links re-stripped the full
-- content, extract_tasks re-stripped per line). The refactor computes the
-- code-stripped, line-split representation ONCE (strip_code_blocks_lines) for
-- content and once for body, then shares the arrays with the FENCE-AWARE
-- line-based extractors. Output MUST stay byte-identical.
--
-- The load-bearing invariant: stripped CONTENT lines feed links; stripped BODY
-- lines feed tags/task-tags. They must never be swapped, and the fence/inline-
-- code stripping must still happen.
--
-- CRITICAL: extract_inline_fields is NOT fence-aware (it strips only inline-
-- code spans per line). A `key:: value` inside a fenced block IS captured, and
-- must NOT be fed the fence-aware stripped_body_lines. Assertion 1 guards this.
--
-- Discriminating power (verified): swapping the two stripped arrays in
-- parse_content, or making strip_code_blocks_lines skip fence handling, makes
-- the tag/link assertions fail; feeding stripped_body_lines to
-- extract_inline_fields makes the in-fence inline-field assertion fail;
-- feeding stripped_body_lines to extract_links breaks the boundary spec.
--
-- Drives the REAL parser (no mock). Run with:
--   nvim --headless -u NONE -l tests/strip_code_blocks_single_pass_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local P = require("andrew.vault.vault_index_parser")

print("\n=== strip_code_blocks Single-Pass Parity Tests ===\n")

local function parse(content)
  return P.parse_content(content, "Note.md", {
    mtime = { sec = 1 }, size = #content, birthtime = { sec = 1 },
  })
end

local function has(list, val)
  for _, v in ipairs(list or {}) do if v == val then return true end end
  return false
end

local function has_link(links, name)
  for _, l in ipairs(links or {}) do
    if l.path == name or l.display == name then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- 1. Fenced code block: tags AND links inside the fence are ignored (those
--    extractors are fence-aware via the shared stripped CONTENT/BODY arrays);
--    real content outside the fence is captured.
--
--    Inline fields are DELIBERATELY NOT fence-aware: historically (and still)
--    extract_inline_fields strips only inline-code spans per line, so a
--    `key:: value` written inside a fenced block IS captured. The single-pass
--    refactor must NOT change this — a prior cleanup that fed the fence-aware
--    stripped_body_lines into extract_inline_fields silently dropped these and
--    is exactly what this assertion guards against.
-- ---------------------------------------------------------------------------
test("fenced code block stripped from tags / links but NOT inline fields", function()
  local content = table.concat({
    "# Title",
    "",
    "Outside #realTag and [[RealLink]] and [real:: outval]",
    "",
    "```",
    "#fakeTag and [[FakeLink]] and [fence:: fenceval]",
    "```",
    "",
    "more #realTag2",
  }, "\n")
  local e = parse(content)

  assert_true(has(e.tags, "realTag"), "#realTag captured")
  assert_true(has(e.tags, "realTag2"), "#realTag2 captured")
  assert_true(not has(e.tags, "fakeTag"), "#fakeTag inside fence ignored")

  assert_true(has_link(e.outlinks, "RealLink"), "RealLink captured")
  assert_true(not has_link(e.outlinks, "FakeLink"), "FakeLink inside fence ignored")

  assert_eq(e.inline_fields.real, "outval", "real inline field captured")
  -- Inline fields are not fence-aware: this MUST still be captured.
  assert_eq(e.inline_fields.fence, "fenceval", "inline field inside fence captured")
end)

-- ---------------------------------------------------------------------------
-- 2. Inline-code spans on a single line are stripped before tag/link/field
--    extraction, but text outside the backticks is still scanned.
-- ---------------------------------------------------------------------------
test("inline-code span stripped on a single line", function()
  local content = table.concat({
    "prose `#nocode [[NoLink]] [no:: x]` realtext #yescode and [[YesLink]]",
    "[yes:: v]",
  }, "\n")
  local e = parse(content)

  assert_true(has(e.tags, "yescode"), "#yescode (outside backticks) captured")
  assert_true(not has(e.tags, "nocode"), "#nocode (in backticks) ignored")

  assert_true(has_link(e.outlinks, "YesLink"), "YesLink captured")
  assert_true(not has_link(e.outlinks, "NoLink"), "NoLink in backticks ignored")

  assert_eq(e.inline_fields.yes, "v", "yes inline field captured")
  assert_nil(e.inline_fields.no, "no inline field in backticks ignored")
end)

-- ---------------------------------------------------------------------------
-- 3. Task tag sub-scan respects inline-code: a tag inside backticks within a
--    task line is NOT counted; a real tag on the same line is.
-- ---------------------------------------------------------------------------
test("task tag sub-scan respects inline code", function()
  local content = "- [ ] do #task with `#incode` here"
  local e = parse(content)

  assert_eq(#e.tasks, 1, "one task parsed")
  assert_true(has(e.tasks[1].tags, "task"), "#task captured on task")
  assert_true(not has(e.tasks[1].tags, "incode"), "#incode (in backticks) ignored")
end)

-- ---------------------------------------------------------------------------
-- 4. Tasks inside a fenced code block are NOT parsed as tasks.
-- ---------------------------------------------------------------------------
test("tasks inside a fence are not parsed", function()
  local content = table.concat({
    "- [ ] real task #r",
    "```",
    "- [ ] fenced task #f",
    "```",
    "- [x] real done #d",
  }, "\n")
  local e = parse(content)

  assert_eq(#e.tasks, 2, "only the two real tasks parsed")
  assert_true(has(e.tasks[1].tags, "r"), "first real task tag")
  assert_true(has(e.tasks[2].tags, "d"), "second real task tag")
end)

-- ---------------------------------------------------------------------------
-- 5. Boundary preservation: with frontmatter, links/tags use stripped CONTENT
--    while tasks/inline-fields use stripped BODY. Line numbers and field
--    sources must not shift after the single-pass refactor.
-- ---------------------------------------------------------------------------
test("content-vs-body boundary preserved after single-pass refactor", function()
  local content = table.concat({
    "---",                                  -- 1
    "title: Sample",                        -- 2
    "tags: [fm1]",                          -- 3
    "---",                                  -- 4
    "",                                     -- 5
    "# Heading",                            -- 6
    "body #bodytag [[BodyLink]] [bf:: bv]", -- 7
    "",                                     -- 8
    "- [ ] task #t [due:: 2026-02-02]",     -- 9
    "",                                     -- 10
    "tail ^bk1",                            -- 11
  }, "\n")
  local e = parse(content)

  -- Frontmatter + body tags.
  assert_true(has(e.tags, "fm1"), "frontmatter tag")
  assert_true(has(e.tags, "bodytag"), "body tag")

  -- Link from body, found via stripped CONTENT lines.
  assert_true(has_link(e.outlinks, "BodyLink"), "BodyLink captured")

  -- Heading/block are content-relative.
  assert_eq(e.headings[1].line, 6, "heading content-relative line 6")
  assert_eq(e.block_ids[1].line, 11, "block content-relative line 11")

  -- Task lines are file-absolute too: extract_tasks() scans the BODY array
  -- (content line 9 is body line 5) and parse_content() adds the frontmatter
  -- offset back on, so the entry carries one convention (audit2, vault-c §4a).
  assert_eq(e.tasks[1].line, 9, "task file-absolute line 9")
  assert_eq(e.tasks[1].due, "2026-02-02", "task due field")
  assert_true(has(e.tasks[1].tags, "t"), "task tag")

  -- Inline field from body.
  assert_eq(e.inline_fields.bf, "bv", "inline field bf")
end)

_H.finish({ style = "results", exit = "os" })
