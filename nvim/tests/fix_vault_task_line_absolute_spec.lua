-- Regression spec (audit2 fix pass, vault-c §4a):
-- vault_index_parser.parse_content() numbered task lines relative to the BODY
-- while every other field it stores (headings, block_ids) -- and the task lines
-- parse_chunk() produces for large/chunked files -- are file-absolute. One
-- index carried two conventions, so in any note WITH frontmatter every task
-- jump landed `#frontmatter` lines too early: the task pickers/previews,
-- :VaultOverdue, task-tree <CR> and its [n/m %] virtual text, timeline <CR>,
-- calendar's due-task jump, and kanban <CR>/m/M (set_task_status re-checks the
-- checkbox pattern on the line it was given and silently did nothing, or would
-- flip a DIFFERENT task if the offset happened to land on one).
--
-- Also pins the schema-version bump that discards indexes persisted with the
-- old numbers, so users get one automatic rebuild instead of needing
-- :VaultIndexRebuild by hand.
--
-- Run with: nvim --headless -u NONE -l tests/fix_vault_task_line_absolute_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;"
  .. vim.fn.stdpath("config") .. "/lua/?/init.lua;" .. package.path

local parser = require("andrew.vault.vault_index_parser")

local stat = { mtime = { sec = 0 }, size = 0 }

--- Parse `lines` and assert every returned task.line indexes the checkbox line
--- it was extracted from.
---@param lines string[]
---@return table[] tasks
local function tasks_of(lines)
  local entry = parser.parse_content(table.concat(lines, "\n"), "t.md", stat)
  for _, t in ipairs(entry.tasks) do
    local at = lines[t.line]
    assert_true(at ~= nil, "task.line " .. t.line .. " is past the end of the file")
    assert_true(at:match("^%s*[-*]%s*%[.%]") ~= nil,
      "task.line " .. t.line .. " must point at a checkbox, got: " .. tostring(at))
    assert_true(at:find(t.text:sub(1, 10), 1, true) ~= nil,
      "task.line " .. t.line .. " must point at THIS task, got: " .. tostring(at))
  end
  return entry.tasks
end

test("tasks in a note WITH frontmatter get file-absolute line numbers", function()
  local lines = {
    "---",             -- 1
    "title: Alpha",    -- 2
    "tags: [project]", -- 3
    "status: active",  -- 4
    "---",             -- 5
    "",                -- 6
    "# Alpha",         -- 7
    "",                -- 8
    "## Tasks",        -- 9
    "",                -- 10
    "- [ ] first",     -- 11
    "  - [x] nested",  -- 12
    "- [/] second",    -- 13
  }
  local tasks = tasks_of(lines)
  assert_eq(#tasks, 3)
  assert_eq(tasks[1].line, 11)
  assert_eq(tasks[2].line, 12)
  assert_eq(tasks[3].line, 13)
end)

test("tasks in a note WITHOUT frontmatter are unchanged", function()
  local lines = { "# Plain", "", "- [ ] only task" }
  local tasks = tasks_of(lines)
  assert_eq(#tasks, 1)
  assert_eq(tasks[1].line, 3)
end)

test("parse_content and parse_chunk agree on the same body", function()
  local lines = {
    "---",         -- 1
    "title: T",    -- 2
    "---",         -- 3
    "",            -- 4
    "- [ ] alpha", -- 5
    "- [x] beta",  -- 6
  }
  local from_content = parser.parse_content(table.concat(lines, "\n"), "t.md", stat).tasks
  -- parse_chunk is handed the body only, told where it starts in the file, and
  -- has always returned file-absolute lines.
  local body = { lines[4], lines[5], lines[6] }
  local from_chunk = parser.parse_chunk(body, 4, nil).tasks
  assert_eq(#from_content, #from_chunk)
  for i = 1, #from_content do
    assert_eq(from_content[i].line, from_chunk[i].line,
      "parse_content and parse_chunk must use the same convention for task " .. i)
  end
end)

test("headings and block_ids stay file-absolute (not shifted by the fix)", function()
  local content = table.concat({
    "---",          -- 1
    "title: T",     -- 2
    "---",          -- 3
    "",             -- 4
    "# Head",       -- 5
    "",             -- 6
    "body ^blk1",   -- 7
    "- [ ] a task", -- 8
  }, "\n")
  local entry = parser.parse_content(content, "t.md", stat)
  assert_eq(entry.headings[1].line, 5)
  assert_eq(entry.block_ids[1].line, 7)
  assert_eq(entry.tasks[1].line, 8)
end)

test("the index schema version was bumped past the body-relative format", function()
  -- A persisted <vault>/.vault-index/index.json written before the fix holds the
  -- old body-relative task lines; vault_index.load() must reject it on version
  -- mismatch and rebuild instead of trusting those numbers.
  local src = vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/andrew/vault/vault_index.lua")
  local version
  for _, l in ipairs(src) do
    version = version or l:match("^local SCHEMA_VERSION = (%d+)")
  end
  assert_true(version ~= nil, "SCHEMA_VERSION must stay a plain literal so it can be audited")
  assert_true(tonumber(version) >= 11,
    "SCHEMA_VERSION must be >= 11 to invalidate indexes with body-relative task lines, got " .. tostring(version))
end)

_H.finish()
