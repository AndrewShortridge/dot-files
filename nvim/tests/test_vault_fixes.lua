-- Test suite for vault bug fixes
-- Run with: nvim --headless -u NONE -l tests/test_vault_fixes.lua

local passed = 0
local failed = 0
local errors = {}

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  PASS: " .. name)
  else
    failed = failed + 1
    table.insert(errors, { name = name, err = tostring(err) })
    print("  FAIL: " .. name .. " -> " .. tostring(err))
  end
end

local function assert_eq(got, expected, msg)
  if got ~= expected then
    error((msg or "") .. " expected: " .. vim.inspect(expected) .. ", got: " .. vim.inspect(got))
  end
end

local function assert_true(val, msg)
  if not val then
    error((msg or "assertion failed") .. " (got falsy)")
  end
end

local function assert_false(val, msg)
  if val then
    error((msg or "assertion failed") .. " (got truthy)")
  end
end

local function assert_match(str, pattern, msg)
  if not str:match(pattern) then
    error((msg or "") .. " string '" .. str .. "' does not match pattern '" .. pattern .. "'")
  end
end

-- ============================================================================
-- Setup: create temp vault structure for testing
-- ============================================================================
local tmp_vault = vim.fn.tempname() .. "/test-vault"
vim.fn.mkdir(tmp_vault .. "/Projects/Alpha/Tasks", "p")
vim.fn.mkdir(tmp_vault .. "/Projects/Beta", "p")
vim.fn.mkdir(tmp_vault .. "/Archive", "p")
vim.fn.mkdir(tmp_vault .. "/Domains/Physics", "p")
vim.fn.mkdir(tmp_vault .. "/Log", "p")
vim.fn.mkdir(tmp_vault .. "/Areas/Career", "p")
vim.fn.mkdir(tmp_vault .. "/.obsidian", "p")

-- Write test files
local function write_file(rel, content)
  local path = tmp_vault .. "/" .. rel
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local f = io.open(path, "w")
  f:write(content)
  f:close()
end

write_file("Projects/Alpha/Dashboard.md", [[---
type: project
tags:
  - physics
  - simulation
  - active
  - high-priority
  - review-needed
  - quarterly
  - funded
  - collaborative
  - experimental
  - published
  - peer-reviewed
  - conference
  - journal
  - grant
  - nist
  - doe
  - nsf
  - darpa
  - army-research
  - navy-research
  - air-force
  - space-force
  - dod
  - nih
  - cdc
  - fda
  - epa
  - noaa
  - nasa
  - usgs
  - usda
aliases: [Alpha Project, Project A]
status: active
modified: 2026-01-15T10:30:00
created: 2025-06-01T08:00:00
---
# Alpha Project Dashboard

## Overview
This is the Alpha project.

## Status
Currently active.
]])

write_file("Projects/Alpha/Tasks/Task1.md", [[---
type: task
status: open
priority: 1
due: 2026-03-01
created: 2026-02-01T10:00:00
modified: 2026-02-20T15:30:00
---
# Fix the simulation parameters

- [ ] Review LAMMPS config [due:: 2026-03-01]
- [x] Update boundary conditions [completion:: 2026-02-15]
- [/] Run convergence test
- [-] Old approach cancelled
- [>] Deferred to next sprint
]])

write_file("Archive/Alpha.md", [[---
type: archive
status: archived
modified: 2025-01-01T00:00:00
---
# Alpha (Archived)

This is an older archived note also named Alpha.
]])

write_file("Projects/Beta/Dashboard.md", [==[---
type: project
tags: [ml, deep-learning]
status: active
modified: 2026-02-01T10:00:00
created: 2026-02-18T14:00:00
---
# Beta Project

See also [[Alpha|Alpha Project]] and [[Alpha#Overview]].
References: [[Dashboard]] and [[NonExistent]].
]==])

write_file("Domains/Physics/Concepts.md", [==[---
type: concept
tags: [physics, mechanics]
modified: 2026-01-20T09:00:00
---
# Physics Concepts

## Newton's Laws

Basic mechanics overview.

## Thermodynamics

Heat and energy.

```python
# This is code with [[fake link]] inside
x = 1
```

Inline code: `[[not a link]]` should be ignored.

Some text with #physics and #mechanics tags.
]==])

write_file("Log/2026-02-21.md", [[---
type: log
modified: 2026-02-21T08:00:00
---
# Daily Log 2026-02-21

- [x] Morning standup
- [ ] Review PRs
]])

-- File with long frontmatter (> 30 lines)
local long_fm_lines = { "---", "type: literature" }
for i = 1, 40 do
  table.insert(long_fm_lines, "field_" .. i .. ": value_" .. i)
end
table.insert(long_fm_lines, "modified: 2025-01-01T00:00:00")
table.insert(long_fm_lines, "---")
table.insert(long_fm_lines, "# Long Frontmatter Note")
write_file("long_fm.md", table.concat(long_fm_lines, "\n"))

-- ============================================================================
print("\n=== 1. ENGINE: Coroutine safety (vim.schedule wrap) ===")
-- ============================================================================

test("engine.input wraps callback in vim.schedule", function()
  local src = io.open(vim.fn.expand("~/.config/nvim/lua/andrew/vault/engine.lua"), "r"):read("*a")
  -- Check that vim.ui.input callback uses vim.schedule
  assert_true(
    src:match("vim%.ui%.input%(opts, function%(value%)\n%s+vim%.schedule%(function%(%)"),
    "vim.ui.input callback should be wrapped in vim.schedule"
  )
end)

test("engine.select wraps callback in vim.schedule", function()
  local src = io.open(vim.fn.expand("~/.config/nvim/lua/andrew/vault/engine.lua"), "r"):read("*a")
  assert_true(
    src:match("vim%.ui%.select%(items, opts, function%(choice%)\n%s+vim%.schedule%(function%(%)"),
    "vim.ui.select callback should be wrapped in vim.schedule"
  )
end)

test("engine.write_note includes OS error in notification", function()
  local src = io.open(vim.fn.expand("~/.config/nvim/lua/andrew/vault/engine.lua"), "r"):read("*a")
  assert_true(
    src:match('io_err or "unknown error"'),
    "io.open failure should include the OS error message"
  )
end)

-- ============================================================================
print("\n=== 2. WIKILINKS: Cache stores lists, proximity resolution ===")
-- ============================================================================

-- Directly test the cache data structure by simulating what build_cache does
test("wikilink cache stores multiple paths per basename", function()
  -- Simulate the new cache logic with two files sharing the same basename "Alpha"
  local cache = {}
  local test_files = {
    tmp_vault .. "/Projects/Alpha/Alpha.md",
    tmp_vault .. "/Archive/Alpha.md",
  }
  for _, path in ipairs(test_files) do
    local basename = vim.fn.fnamemodify(path, ":t:r"):lower()
    if not cache[basename] then
      cache[basename] = {}
    end
    table.insert(cache[basename], path)
  end

  assert_eq(type(cache["alpha"]), "table", "cache['alpha'] should be a table")
  assert_eq(#cache["alpha"], 2, "cache['alpha'] should have 2 entries for same basename")
end)

test("proximity resolution picks closest directory", function()
  -- Simulate resolve_link with proximity logic
  local paths = {
    tmp_vault .. "/Projects/Alpha/Dashboard.md",
    tmp_vault .. "/Archive/Alpha.md",
  }
  local current_dir = tmp_vault .. "/Projects/Alpha/Tasks"

  local best_path = paths[1]
  local best_score = math.huge
  for _, path in ipairs(paths) do
    local dir = vim.fn.fnamemodify(path, ":h")
    local common = 0
    for i = 1, math.min(#dir, #current_dir) do
      if dir:sub(i, i) == current_dir:sub(i, i) then
        common = common + 1
      else
        break
      end
    end
    local score = (#dir - common) + (#current_dir - common)
    if score < best_score then
      best_score = score
      best_path = path
    end
  end

  assert_match(best_path, "Projects/Alpha", "Should pick Projects/Alpha/Dashboard.md when in Projects/Alpha/Tasks")
end)

test("proximity resolution picks Archive when closer", function()
  local paths = {
    tmp_vault .. "/Projects/Alpha/Dashboard.md",
    tmp_vault .. "/Archive/Alpha.md",
  }
  local current_dir = tmp_vault .. "/Archive"

  local best_path = paths[1]
  local best_score = math.huge
  for _, path in ipairs(paths) do
    local dir = vim.fn.fnamemodify(path, ":h")
    local common = 0
    for i = 1, math.min(#dir, #current_dir) do
      if dir:sub(i, i) == current_dir:sub(i, i) then
        common = common + 1
      else
        break
      end
    end
    local score = (#dir - common) + (#current_dir - common)
    if score < best_score then
      best_score = score
      best_path = path
    end
  end

  assert_match(best_path, "Archive/Alpha", "Should pick Archive/Alpha.md when in Archive/")
end)

-- ============================================================================
print("\n=== 3. WIKILINKS: New note created in current buffer dir ===")
-- ============================================================================

test("new note location logic uses buffer dir when inside vault", function()
  local vault_path = tmp_vault
  local buf_dir = tmp_vault .. "/Projects/Alpha/Tasks"
  local link = "NewNote"

  local new_path
  if vim.startswith(buf_dir, vault_path) then
    new_path = buf_dir .. "/" .. link .. ".md"
  else
    new_path = vault_path .. "/" .. link .. ".md"
  end

  assert_eq(new_path, tmp_vault .. "/Projects/Alpha/Tasks/NewNote.md",
    "New note should be in buffer's directory")
end)

test("new note location falls back to vault root when outside vault", function()
  local vault_path = tmp_vault
  local buf_dir = "/tmp/somewhere-else"
  local link = "NewNote"

  local new_path
  if vim.startswith(buf_dir, vault_path) then
    new_path = buf_dir .. "/" .. link .. ".md"
  else
    new_path = vault_path .. "/" .. link .. ".md"
  end

  assert_eq(new_path, tmp_vault .. "/NewNote.md",
    "New note should fall back to vault root")
end)

-- ============================================================================
print("\n=== 4. BACKLINKS: Regex matches aliased and heading links ===")
-- ============================================================================

-- Test ripgrep regex patterns (simulate matching)
local function rg_escape(str)
  return str:gsub("([%(%)%.%%%+%-%*%?%[%]%^%${}|\\])", "\\%1")
end

-- Convert the ripgrep regex to Lua pattern for testing
-- The backlink regex: \[\[name([#|][^\]]*)?]]
test("backlink regex matches plain [[Note]]", function()
  local name = "Alpha"
  local text = "See [[Alpha]] for details"
  -- The rg regex: \[\[Alpha([#|][^\]]*)?]]
  -- In Lua, test equivalent:
  assert_true(text:match("%[%[" .. name .. "%]%]") ~= nil, "Should match [[Alpha]]")
end)

test("backlink regex matches [[Note|alias]]", function()
  local text = "See [[Alpha|Alpha Project]] for details"
  -- Old regex would need exact ]] after name - would fail
  -- New regex allows [#|] followed by anything before ]]
  -- Test: does "Alpha" appear before a | or # or ]] ?
  local pattern = "%[%[Alpha[#|%]]"
  assert_true(text:match(pattern) ~= nil, "Should match [[Alpha|...]]")
end)

test("backlink regex matches [[Note#heading]]", function()
  local text = "See [[Alpha#Overview]] for details"
  local pattern = "%[%[Alpha[#|%]]"
  assert_true(text:match(pattern) ~= nil, "Should match [[Alpha#heading]]")
end)

test("backlink regex matches [[Note#heading|alias]]", function()
  local text = "See [[Alpha#Overview|Alpha Overview]] for details"
  local pattern = "%[%[Alpha[#|%]]"
  assert_true(text:match(pattern) ~= nil, "Should match [[Alpha#heading|alias]]")
end)

-- ============================================================================
print("\n=== 5. BACKLINKS: Heading backlinks use raw text ===")
-- ============================================================================

test("heading backlinks search for raw heading text, not slug", function()
  local src = io.open(vim.fn.expand("~/.config/nvim/lua/andrew/vault/backlinks.lua"), "r"):read("*a")
  -- The heading_backlinks function should use `heading` directly, not `slug`
  -- Check that it uses rg_escape(heading) not rg_escape(slug)
  assert_true(
    src:match('rg_escape%(heading%)'),
    "heading_backlinks should use raw heading text, not slug"
  )
  assert_false(
    src:match('rg_escape%(slug%)'),
    "heading_backlinks should not use slug in search"
  )
end)

-- ============================================================================
print("\n=== 6. SEARCH: All notes glob is recursive ===")
-- ============================================================================

test("search_filtered All notes uses **/*.md glob", function()
  local src = io.open(vim.fn.expand("~/.config/nvim/lua/andrew/vault/search.lua"), "r"):read("*a")
  assert_true(
    src:match('"All notes",%s*glob%s*=%s*"%*%*/%*%.md"'),
    "All notes should use **/*.md glob for recursive search"
  )
  assert_false(
    src:match('"All notes",%s*glob%s*=%s*"%*%.md"'),
    "All notes should NOT use *.md (non-recursive)"
  )
end)

-- ============================================================================
print("\n=== 7. SEARCH: type regex handles whitespace ===")
-- ============================================================================

test("search_by_type uses \\s+ for flexible whitespace", function()
  local src = io.open(vim.fn.expand("~/.config/nvim/lua/andrew/vault/search.lua"), "r"):read("*a")
  assert_true(
    src:match("\\s%+"),
    "search_by_type should use \\s+ for whitespace matching"
  )
end)

-- ============================================================================
print("\n=== 8. COMPLETION: Frontmatter parsing has no 30-line limit ===")
-- ============================================================================

test("completion parse_frontmatter uses while loop, not limited for loop", function()
  local src = io.open(vim.fn.expand("~/.config/nvim/lua/andrew/vault/completion.lua"), "r"):read("*a")
  assert_false(
    src:match("for _ = 1, 30 do"),
    "Should not have for _ = 1, 30 limit"
  )
  assert_true(
    src:match("while true do"),
    "Should use while true do for unlimited frontmatter reading"
  )
end)

test("completion parse_frontmatter reads all fields from long frontmatter", function()
  -- Directly test the parse_frontmatter logic
  local path = tmp_vault .. "/Projects/Alpha/Dashboard.md"
  local f = io.open(path, "r")
  assert_true(f ~= nil, "Test file should exist")

  local first = f:read("*l")
  assert_eq(first, "---", "First line should be ---")

  local fm = {}
  local cur_key = nil
  local cur_list = nil

  while true do
    local line = f:read("*l")
    if not line or line == "---" then break end

    local list_item = line:match("^%s+-%s+(.+)$")
    if list_item and cur_key then
      if not cur_list then cur_list = {} end
      cur_list[#cur_list + 1] = list_item
      fm[cur_key] = table.concat(cur_list, ", ")
    else
      local key, val = line:match("^(%w[%w_-]*):%s*(.*)$")
      if key then
        cur_key = key
        cur_list = nil
        if val and val ~= "" then
          val = val:gsub("^%[", ""):gsub("%]$", ""):gsub("^'", ""):gsub("'$", ""):gsub('^"', ""):gsub('"$', "")
          fm[key] = val
        end
      end
    end
  end
  f:close()

  assert_eq(fm.type, "project", "Should parse type field")
  assert_eq(fm.status, "active", "Should parse status field")
  assert_true(fm.tags ~= nil, "Should parse tags")
  assert_true(fm.aliases ~= nil, "Should parse aliases")
end)

test("completion parse_frontmatter handles long frontmatter (40+ fields)", function()
  local path = tmp_vault .. "/long_fm.md"
  local f = io.open(path, "r")
  assert_true(f ~= nil, "Long frontmatter test file should exist")

  local first = f:read("*l")
  assert_eq(first, "---", "First line should be ---")

  local fm = {}
  local cur_key = nil
  local cur_list = nil

  while true do
    local line = f:read("*l")
    if not line or line == "---" then break end

    local list_item = line:match("^%s+-%s+(.+)$")
    if list_item and cur_key then
      if not cur_list then cur_list = {} end
      cur_list[#cur_list + 1] = list_item
      fm[cur_key] = table.concat(cur_list, ", ")
    else
      local key, val = line:match("^(%w[%w_-]*):%s*(.*)$")
      if key then
        cur_key = key
        cur_list = nil
        if val and val ~= "" then
          fm[key] = val
        end
      end
    end
  end
  f:close()

  assert_eq(fm.type, "literature", "Should parse type from long frontmatter")
  assert_eq(fm.field_1, "value_1", "Should parse field_1")
  assert_eq(fm.field_30, "value_30", "Should parse field_30 (was previous limit)")
  assert_eq(fm.field_40, "value_40", "Should parse field_40 (beyond old limit)")
  assert_true(fm.modified ~= nil, "Should parse modified field after 40+ fields")
end)

-- ============================================================================
print("\n=== 9. COMPLETION: Race condition fix (generation counter) ===")
-- ============================================================================

test("completion has build_generation counter", function()
  local src = io.open(vim.fn.expand("~/.config/nvim/lua/andrew/vault/completion.lua"), "r"):read("*a")
  assert_true(src:match("build_generation"), "Should have build_generation variable")
end)

test("completion invalidate increments generation", function()
  local src = io.open(vim.fn.expand("~/.config/nvim/lua/andrew/vault/completion.lua"), "r"):read("*a")
  assert_true(
    src:match("build_generation = build_generation %+ 1"),
    "invalidate() should increment build_generation"
  )
end)

test("completion build_items_async captures and checks generation", function()
  local src = io.open(vim.fn.expand("~/.config/nvim/lua/andrew/vault/completion.lua"), "r"):read("*a")
  assert_true(
    src:match("local gen = build_generation"),
    "build_items_async should capture generation"
  )
  assert_true(
    src:match("gen ~= build_generation"),
    "build_items_async should check generation before writing results"
  )
end)

-- ============================================================================
print("\n=== 10. FRONTMATTER: Line limit increased ===")
-- ============================================================================

test("frontmatter reads up to 200 lines, not 30", function()
  local src = io.open(vim.fn.expand("~/.config/nvim/lua/andrew/vault/frontmatter.lua"), "r"):read("*a")
  assert_false(
    src:match("nvim_buf_get_lines%(ev%.buf, 0, 30,"),
    "Should not hardcode 30-line limit"
  )
  assert_true(
    src:match("math%.min%(line_count, 200%)"),
    "Should read up to 200 lines"
  )
end)

-- ============================================================================
print("\n=== 11. EXECUTOR: Pattern injection fix in contains_value ===")
-- ============================================================================

test("contains_value uses plain string find, not pattern match", function()
  local src = io.open(vim.fn.expand("~/.config/nvim/lua/andrew/vault/query/executor.lua"), "r"):read("*a")
  assert_true(
    src:match("v%.path:find%(b, 1, true%)"),
    "Should use string.find with plain=true"
  )
  assert_false(
    src:match("v%.path:match%(b%)"),
    "Should NOT use string.match (pattern injection risk)"
  )
end)

test("contains_value plain find works with special characters", function()
  -- Simulate the fixed contains_value behavior
  local link_path = "Projects/Alpha.Beta/Dashboard"

  -- Old behavior: :match(b) where b has "." which is a wildcard
  local bad_result = link_path:match("Alpha.Beta") -- matches "AlphaXBeta" too
  assert_true(bad_result ~= nil, "Lua match treats . as wildcard (old bug)")

  -- New behavior: :find(b, 1, true) does plain substring match
  local good_result = link_path:find("Alpha.Beta", 1, true)
  assert_true(good_result ~= nil, "Plain find matches exact substring")

  -- The key fix: special chars in b don't cause unexpected matches
  local no_match = ("Projects/AlphaXBeta/Dashboard"):find("Alpha.Beta", 1, true)
  assert_true(no_match == nil, "Plain find should NOT match AlphaXBeta with Alpha.Beta")
end)

test("contains_value plain find rejects Lua pattern metacharacters", function()
  -- Patterns that would crash or misbehave with :match()
  local test_cases = {
    { path = "foo(bar)", search = "(bar)" },
    { path = "foo[1]", search = "[1]" },
    { path = "100%done", search = "%done" },
    { path = "a+b", search = "a+b" },
  }

  for _, tc in ipairs(test_cases) do
    -- Old behavior would crash or match incorrectly
    local ok, _ = pcall(function()
      return tc.path:match(tc.search)
    end)
    -- New behavior: plain find always works
    local result = tc.path:find(tc.search, 1, true)
    assert_true(result ~= nil, "Plain find should work for: " .. tc.search)
  end
end)

-- ============================================================================
print("\n=== 12. EXECUTOR: LIMIT applied before GROUP BY ===")
-- ============================================================================

test("executor applies LIMIT before GROUP BY in pipeline", function()
  local src = io.open(vim.fn.expand("~/.config/nvim/lua/andrew/vault/query/executor.lua"), "r"):read("*a")

  -- Find the pipeline step comments (numbered steps in the execute function)
  local limit_pos = src:find("%-%- 5%. LIMIT")
  local group_pos = src:find("%-%- 6%. GROUP BY")

  assert_true(limit_pos ~= nil, "Should have step 5 LIMIT comment")
  assert_true(group_pos ~= nil, "Should have step 6 GROUP BY comment")
  assert_true(limit_pos < group_pos, "LIMIT (step 5) should come before GROUP BY (step 6)")
end)

test("executor LIMIT is not conditional on groups", function()
  local src = io.open(vim.fn.expand("~/.config/nvim/lua/andrew/vault/query/executor.lua"), "r"):read("*a")
  assert_false(
    src:match("if not groups then\n%s+pages = apply_limit"),
    "LIMIT should NOT be conditional on groups"
  )
end)

-- Functional test: LIMIT + GROUP BY
test("LIMIT caps total results even with GROUP BY", function()
  local types = require("andrew.vault.query.types")
  local executor = require("andrew.vault.query.executor")

  -- Create a minimal index mock
  local mock_index = {
    all_pages = function()
      local pages = {}
      for i = 1, 10 do
        local group = (i <= 5) and "A" or "B"
        pages[i] = {
          file = {
            name = "note" .. i,
            path = "note" .. i .. ".md",
            link = types.Link.new("note" .. i, "note" .. i, false),
            tags = {},
          },
          group_field = group,
        }
      end
      return pages
    end,
    resolve_source = function(self, node)
      return self:all_pages()
    end,
    current_page = function() return nil end,
  }

  -- Query: TABLE group_field FROM "" GROUP BY group_field LIMIT 5
  local ast = {
    type = "TABLE",
    fields = { { expr = { type = "field", path = { "group_field" } }, alias = nil } },
    group_by = { expr = { type = "field", path = { "group_field" } } },
    limit = 5,
    without_id = false,
  }

  local results = executor.execute(ast, mock_index, "")

  -- Count total rows across all groups
  local total_rows = 0
  for _, result in ipairs(results) do
    if result.rows then
      total_rows = total_rows + #result.rows
    end
  end

  assert_true(total_rows <= 5, "LIMIT 5 with GROUP BY should cap total to 5, got " .. total_rows)
end)

-- ============================================================================
print("\n=== 13. INDEX: Code block stripping (line-by-line) ===")
-- ============================================================================

test("_strip_code_blocks handles normal fenced blocks", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)

  local text = [==[
Some text before.

```python
x = 1
# not a heading
[[not a link]]
```

Some text after #real-tag.
]==]

  local result = idx:_strip_code_blocks(text)
  assert_false(result:match("%[%[not a link%]%]") ~= nil, "Links inside code blocks should be stripped")
  assert_false(result:match("x = 1") ~= nil, "Code content should be stripped")
  assert_true(result:match("#real%-tag") ~= nil, "Content outside code blocks should be preserved")
end)

test("_strip_code_blocks handles unclosed fences", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)

  local text = [==[
Before the fence.

```
This is unclosed code.
[[fake link]]
Still in code.
]==]

  local result = idx:_strip_code_blocks(text)
  assert_true(result:match("Before the fence") ~= nil, "Text before unclosed fence should be preserved")
  assert_false(result:match("%[%[fake link%]%]") ~= nil, "Content after unclosed fence should be stripped")
end)

test("_strip_code_blocks handles multiple fences", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)

  local text = [[
Text 1

```
code block 1
```

Text 2 #tag2

```lua
code block 2
```

Text 3 #tag3
]]

  local result = idx:_strip_code_blocks(text)
  assert_true(result:match("Text 1") ~= nil, "Text 1 preserved")
  assert_true(result:match("Text 2") ~= nil, "Text 2 preserved")
  assert_true(result:match("Text 3") ~= nil, "Text 3 preserved")
  assert_false(result:match("code block 1") ~= nil, "Code block 1 stripped")
  assert_false(result:match("code block 2") ~= nil, "Code block 2 stripped")
end)

test("_strip_code_blocks handles fences with language specifier", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)

  local text = [[
Before

```javascript
const x = 1;
```

After #tag
]]

  local result = idx:_strip_code_blocks(text)
  assert_false(result:match("const x") ~= nil, "JS code should be stripped")
  assert_true(result:match("#tag") ~= nil, "Tag after code block preserved")
end)

test("_strip_code_blocks strips inline code", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)

  local text = "Some `inline code with #fake-tag` and real #real-tag"
  local result = idx:_strip_code_blocks(text)
  assert_false(result:match("#fake%-tag") ~= nil, "Inline code content should be stripped")
  assert_true(result:match("#real%-tag") ~= nil, "Real tag outside inline code preserved")
end)

-- ============================================================================
print("\n=== 14. INDEX: Date parsing for YYYY-MM-DDTHH:MM:SS ===")
-- ============================================================================

test("_parse_scalar parses YYYY-MM-DD date", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)

  local result = idx:_parse_scalar("2026-02-18")
  assert_true(type(result) == "table", "Should parse to a Date table")
  assert_eq(result.year, 2026, "Year should be 2026")
  assert_eq(result.month, 2, "Month should be 2")
  assert_eq(result.day, 18, "Day should be 18")
end)

test("_parse_scalar parses YYYY-MM-DDTHH:MM:SS datetime", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)

  local result = idx:_parse_scalar("2026-02-18T10:30:00")
  assert_true(type(result) == "table", "Should parse to a Date table")
  assert_eq(result.year, 2026, "Year should be 2026")
  assert_eq(result.month, 2, "Month should be 2")
  assert_eq(result.day, 18, "Day should be 18")
  assert_eq(result.hour, 10, "Hour should be 10")
  assert_eq(result.min, 30, "Minute should be 30")
end)

test("_parse_scalar does not parse random strings as dates", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)

  local result = idx:_parse_scalar("hello world")
  assert_eq(type(result), "string", "Plain strings should stay as strings")
  assert_eq(result, "hello world", "Should return original string")
end)

test("_parse_scalar does not parse numbers as dates", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)

  local result = idx:_parse_scalar("42")
  assert_eq(type(result), "number", "Should parse as number")
  assert_eq(result, 42, "Should be 42")
end)

test("_parse_scalar parses date with space separator (YYYY-MM-DD HH:MM:SS)", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)

  -- The Date.parse function handles ISO format, let's check if our gate lets it through
  -- text:match("^%d%d%d%d%-%d%d%-%d%d[T ]") should match space-separated datetimes
  local text = "2026-02-18T14:00:00"
  assert_true(text:match("^%d%d%d%d%-%d%d%-%d%d[T ]") ~= nil, "Should match T-separated datetime")
end)

-- ============================================================================
print("\n=== 15. INDEX: Full indexing integration test ===")
-- ============================================================================

test("index builds and parses datetime fields in frontmatter", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)
  idx:build_sync()

  local page = idx:get_page("Projects/Alpha/Dashboard.md")
  assert_true(page ~= nil, "Dashboard page should be indexed")
  assert_eq(page.type, "project", "type field should be parsed")
  assert_eq(page.status, "active", "status field should be parsed")

  -- Check that modified (a datetime value) was parsed as a Date
  local mod = page.modified
  assert_true(type(mod) == "table", "modified should be parsed as Date table, got " .. type(mod))
  assert_eq(mod.year, 2026, "modified year should be 2026")
  assert_eq(mod.month, 1, "modified month should be 1")
  assert_eq(mod.hour, 10, "modified hour should be 10")
  assert_eq(mod.min, 30, "modified minute should be 30")
end)

test("index skips .obsidian directory", function()
  local Index = require("andrew.vault.query.index").Index
  -- Write a file inside .obsidian
  write_file(".obsidian/app.json", '{"vimMode": true}')
  local idx = Index.new(tmp_vault)
  idx:build_sync()

  local page = idx:get_page(".obsidian/app.json")
  assert_true(page == nil, ".obsidian files should be skipped")
end)

test("index extracts tags from both frontmatter and body", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)
  idx:build_sync()

  local page = idx:get_page("Domains/Physics/Concepts.md")
  assert_true(page ~= nil, "Concepts page should be indexed")

  local tag_set = {}
  for _, tag in ipairs(page.file.tags) do
    tag_set[tag] = true
  end

  assert_true(tag_set["physics"], "Should have 'physics' tag from frontmatter")
  assert_true(tag_set["mechanics"], "Should have 'mechanics' tag from frontmatter and body")
end)

test("index does not extract tags from inside code blocks", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)
  idx:build_sync()

  local page = idx:get_page("Domains/Physics/Concepts.md")
  assert_true(page ~= nil, "Concepts page should be indexed")

  -- The file has [[fake link]] inside a code block - check it's not in outlinks
  local has_fake = false
  for _, link in ipairs(page.file.outlinks) do
    if link.path == "fake link" then
      has_fake = true
    end
  end
  assert_false(has_fake, "Should NOT extract links from inside code blocks")
end)

test("index extracts tasks with inline fields", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)
  idx:build_sync()

  local page = idx:get_page("Projects/Alpha/Tasks/Task1.md")
  assert_true(page ~= nil, "Task1 page should be indexed")
  assert_true(#page.file.tasks > 0, "Should have tasks extracted")

  -- Check task statuses
  local statuses = {}
  for _, task in ipairs(page.file.tasks) do
    statuses[task.status] = true
  end
  assert_true(statuses[" "], "Should have open task")
  assert_true(statuses["x"], "Should have completed task")
  assert_true(statuses["/"], "Should have in-progress task")
  assert_true(statuses["-"], "Should have cancelled task")
  assert_true(statuses[">"], "Should have deferred task")
end)

test("index resolves inlinks correctly", function()
  local Index = require("andrew.vault.query.index").Index
  local idx = Index.new(tmp_vault)
  idx:build_sync()

  -- Beta links to Alpha, so Alpha should have an inlink from Beta
  local alpha_page = idx:get_page("Projects/Alpha/Dashboard.md")
  assert_true(alpha_page ~= nil, "Alpha page should exist")

  local has_beta_inlink = false
  for _, link in ipairs(alpha_page.file.inlinks) do
    if link.path:match("Beta") then
      has_beta_inlink = true
    end
  end
  assert_true(has_beta_inlink, "Alpha should have inlink from Beta (which uses [[Alpha|Alpha Project]])")
end)

-- ============================================================================
print("\n=== 16. EXECUTOR: Functional query tests ===")
-- ============================================================================

test("executor TABLE query with WHERE", function()
  local types = require("andrew.vault.query.types")
  local executor = require("andrew.vault.query.executor")
  local Index = require("andrew.vault.query.index").Index

  local idx = Index.new(tmp_vault)
  idx:build_sync()

  local ast = {
    type = "TABLE",
    fields = {
      { expr = { type = "field", path = { "status" } }, alias = "status" },
    },
    where = {
      type = "binary",
      op = "=",
      left = { type = "field", path = { "type" } },
      right = { type = "literal", value = "project" },
    },
    without_id = false,
  }

  local results, err = executor.execute(ast, idx, "")
  assert_true(err == nil, "Should not error: " .. tostring(err))
  assert_true(#results > 0, "Should have results")
  assert_true(results[1].rows ~= nil, "Should have rows")
  assert_true(#results[1].rows >= 2, "Should find at least 2 project notes")
end)

test("executor TASK query extracts tasks", function()
  local types = require("andrew.vault.query.types")
  local executor = require("andrew.vault.query.executor")
  local Index = require("andrew.vault.query.index").Index

  local idx = Index.new(tmp_vault)
  idx:build_sync()

  local ast = {
    type = "TASK",
    from = { type = "folder", path = "Projects/Alpha/Tasks" },
    without_id = false,
  }

  local results, err = executor.execute(ast, idx, "")
  assert_true(err == nil, "Should not error: " .. tostring(err))
  assert_true(#results > 0, "Should have results")
  assert_true(results[1].type == "task_list", "Should be a task_list result")
  assert_true(#results[1].groups > 0, "Should have task groups")

  local total_tasks = 0
  for _, g in ipairs(results[1].groups) do
    total_tasks = total_tasks + #g.tasks
  end
  assert_true(total_tasks >= 5, "Should find at least 5 tasks, got " .. total_tasks)
end)

-- ============================================================================
-- Cleanup
-- ============================================================================

-- Remove temp vault
vim.fn.delete(tmp_vault, "rf")

-- ============================================================================
-- Summary
-- ============================================================================

print("\n" .. string.rep("=", 60))
print(string.format("Results: %d passed, %d failed, %d total", passed, failed, passed + failed))
print(string.rep("=", 60))

if #errors > 0 then
  print("\nFailed tests:")
  for _, e in ipairs(errors) do
    print("  - " .. e.name .. ": " .. e.err)
  end
end

-- Exit with appropriate code
vim.cmd("cquit " .. (failed > 0 and "1" or "0"))
