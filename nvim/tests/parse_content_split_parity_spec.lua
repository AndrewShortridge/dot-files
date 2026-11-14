-- Behavioral spec pinning parse_content() output across the split refactor.
--
-- parse_content() now splits content once (shared by heading/block_id
-- extraction) and body once (for task extraction), instead of each extractor
-- splitting internally. The load-bearing invariant: heading/block_id
-- extraction reads the CONTENT array while task extraction reads the BODY array.
-- Swapping the two arrays would silently corrupt line numbers — these
-- assertions catch that.
--
-- Note: extract_tasks() still numbers relative to the body, but parse_content()
-- now normalises task.line to file-absolute before returning (audit2, vault-c
-- §4a) so the entry does not carry two conventions at once — parse_chunk() has
-- always produced file-absolute task lines, and every consumer treats task.line
-- as a file line. The offset these assertions pin is therefore between the
-- extractor's input arrays, not in the returned entry.
--
-- Drives the REAL parser (no mock). Run with:
--   nvim --headless -u NONE -l tests/parse_content_split_parity_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local P = require("andrew.vault.vault_index_parser")

print("\n=== parse_content Split Parity Tests ===\n")

local function parse(content)
  return P.parse_content(content, "Note.md", {
    mtime = { sec = 1 }, size = #content, birthtime = { sec = 1 },
  })
end

-- ---------------------------------------------------------------------------
-- 1. Single-line frontmatter: heading/block content-relative, task body-relative
-- ---------------------------------------------------------------------------
test("frontmatter note: content-relative headings/blocks, body-relative tasks", function()
  local content = table.concat({
    "---",                                   -- 1
    "title: Sample",                         -- 2
    "tags: [a, b]",                          -- 3
    "---",                                   -- 4
    "",                                      -- 5
    "# Heading One",                         -- 6
    "Some prose with [genre:: rock].",       -- 7
    "status:: active",                       -- 8
    "",                                      -- 9
    "- [ ] task alpha [due:: 2026-01-01]",   -- 10
    "- [x] task beta #work",                 -- 11
    "",                                      -- 12
    "Block paragraph. ^block-id-1",          -- 13
  }, "\n")
  local e = parse(content)

  -- Heading: full-content line 6.
  assert_eq(e.headings[1].text, "Heading One", "heading text")
  assert_eq(e.headings[1].line, 6, "heading line is content-relative (6)")

  -- Block id: full-content line 13.
  assert_eq(e.block_ids[1].id, "block-id-1", "block id")
  assert_eq(e.block_ids[1].line, 13, "block id line is content-relative (13)")

  -- Tasks: file-absolute, like headings and block ids. extract_tasks() scans the
  -- body (task alpha is body line 6, beta body line 7) and parse_content() adds
  -- the 4-line frontmatter offset back on.
  assert_eq(e.tasks[1].line, 10, "task alpha line is file-absolute (10)")
  assert_eq(e.tasks[2].line, 11, "task beta line is file-absolute (11)")
  assert_eq(e.tasks[1].due, "2026-01-01", "task alpha due field")
  assert_true(e.tasks[2].completed, "task beta completed")
  local beta_has_work = false
  for _, t in ipairs(e.tasks[2].tags or {}) do if t == "work" then beta_has_work = true end end
  assert_true(beta_has_work, "task beta carries #work tag")

  -- Inline fields parsed from body.
  assert_eq(e.inline_fields.genre, "rock", "inline field genre")
  assert_eq(e.inline_fields.status, "active", "inline field status")
end)

-- ---------------------------------------------------------------------------
-- 2. No frontmatter: body == content, numbering coincides.
-- ---------------------------------------------------------------------------
test("no-frontmatter note: heading and task numbering coincide with content", function()
  local content = table.concat({
    "# Top",                 -- 1
    "",                      -- 2
    "- [ ] only task",       -- 3
    "",                      -- 4
    "tail. ^b2",             -- 5
  }, "\n")
  local e = parse(content)

  assert_eq(e.headings[1].line, 1, "heading at content line 1")
  assert_eq(e.tasks[1].line, 3, "task at line 3 (body == content)")
  assert_eq(e.block_ids[1].id, "b2", "block id b2")
  assert_eq(e.block_ids[1].line, 5, "block id at content line 5")
end)

-- ---------------------------------------------------------------------------
-- 3. Multi-line frontmatter: maximizes content-vs-body offset divergence.
--    Every returned line -- heading, block id and task alike -- must be larger
--    than its body-relative position by exactly the frontmatter line count.
-- ---------------------------------------------------------------------------
test("multi-line frontmatter: heading/block lines offset from task lines by FM size", function()
  local fm = { "---", "title: Big", "tags:", "  - x", "  - y", "date: 2026-01-01", "---" } -- 7 lines
  local body = {
    "",                          -- body 1
    "# Section",                 -- body 2
    "",                          -- body 3
    "- [ ] a body task",         -- body 4
    "",                          -- body 5
    "end ^bk",                   -- body 6
  }
  local content = table.concat(fm, "\n") .. "\n" .. table.concat(body, "\n")
  local e = parse(content)

  local fm_offset = #fm -- 7
  -- Heading "# Section": body line 2 -> content line 2 + 7 = 9.
  assert_eq(e.headings[1].line, fm_offset + 2, "heading line includes FM offset")
  -- Block "^bk": body line 6 -> content line 6 + 7 = 13.
  assert_eq(e.block_ids[1].line, fm_offset + 6, "block line includes FM offset")
  -- Task: file-absolute too -- body line 4 -> content line 4 + 7 = 11.
  assert_eq(e.tasks[1].line, fm_offset + 4, "task line includes FM offset")
  -- The divergence between a body line and the returned line equals the
  -- frontmatter size — the exact thing a swapped split array would break.
  assert_eq(e.headings[1].line - 2, fm_offset, "heading offset == FM size")
  assert_eq(e.tasks[1].line - 4, fm_offset, "task offset == FM size")
end)

-- ---------------------------------------------------------------------------
-- 4. Fenced code block in the BODY of an FM note: the body's stripped lines are
--    derived as a slice of the stripped CONTENT lines. A #tag inside a ``` fence
--    must NOT be captured — this proves the slice carries correct fence state
--    past the frontmatter offset (a wrong offset or aliasing the FM case would
--    let the fenced #fakeTag leak into tags).
-- ---------------------------------------------------------------------------
test("fenced body of FM note: tag inside ``` fence is not captured (slice keeps fence state)", function()
  local content = table.concat({
    "---",                 -- 1
    "title: Fenced",       -- 2
    "---",                 -- 3
    "",                    -- 4
    "Real prose #realtag", -- 5
    "",                    -- 6
    "```",                 -- 7
    "code #fakeTag here",  -- 8
    "```",                 -- 9
    "",                    -- 10
    "After #aftertag",     -- 11
  }, "\n")
  local e = parse(content)

  local has = {}
  for _, t in ipairs(e.tags or {}) do has[t] = true end
  assert_true(has["realtag"], "real tag captured")
  assert_true(has["aftertag"], "tag after fence captured")
  assert_true(not has["fakeTag"], "fenced #fakeTag NOT captured (fence state preserved across FM offset)")
end)

_H.finish({ style = "results", exit = "os" })
