-- Unit tests for lua/andrew/vault/summary_tree.lua
-- Run with: nvim --headless -u NONE -l tests/summary_tree_spec.lua

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

local function assert_nil(val, msg)
  if val ~= nil then
    error((msg or "expected nil") .. ", got: " .. vim.inspect(val))
  end
end

local function assert_table_eq(got, expected, msg)
  local g = vim.inspect(got)
  local e = vim.inspect(expected)
  if g ~= e then
    error((msg or "") .. " expected: " .. e .. ", got: " .. g)
  end
end

-- ============================================================================
-- Load module under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- Stub vault_log to avoid loading full vault infrastructure
package.loaded["andrew.vault.vault_log"] = {
  scope = function()
    return {
      debug = function() end,
      info = function() end,
      warn = function() end,
      error = function() end,
    }
  end,
}

local summary_tree = require("andrew.vault.summary_tree")

-- ============================================================================
-- Test helpers
-- ============================================================================

--- Create a minimal vault index entry for testing.
local function make_entry(opts)
  opts = opts or {}
  return {
    tags = opts.tags or {},
    frontmatter = opts.frontmatter or {},
    tasks = opts.tasks or {},
    outlinks = opts.outlinks or {},
    headings = opts.headings or {},
    aliases = opts.aliases or {},
    block_ids = opts.block_ids or {},
  }
end

-- ============================================================================
-- Tests
-- ============================================================================

print("\n=== Summary Tree Tests ===\n")

-- ---------------------------------------------------------------------------
-- 1. Empty tree
-- ---------------------------------------------------------------------------
test("new tree has zero file_count", function()
  local tree = summary_tree.new()
  local root = tree:query("")
  assert_eq(root.file_count, 0)
  assert_eq(root.task_count, 0)
  assert_eq(root.link_count, 0)
  assert_eq(root.heading_count, 0)
  assert_eq(root.alias_count, 0)
  assert_eq(root.block_id_count, 0)
end)

test("query on empty tree returns empty tables", function()
  local tree = summary_tree.new()
  local root = tree:query("")
  assert_table_eq(root.tag_counts, {})
  assert_table_eq(root.tag_file_counts, {})
  assert_table_eq(root.fm_key_counts, {})
  assert_table_eq(root.task_status_counts, {})
end)

test("query non-existent directory returns nil", function()
  local tree = summary_tree.new()
  assert_nil(tree:query("nonexistent/"))
end)

-- ---------------------------------------------------------------------------
-- 2. Single file at root
-- ---------------------------------------------------------------------------
test("update root-level file increments file_count", function()
  local tree = summary_tree.new()
  tree:update("notes.md", make_entry())
  local root = tree:query("")
  assert_eq(root.file_count, 1)
end)

test("update root-level file with tags", function()
  local tree = summary_tree.new()
  tree:update("notes.md", make_entry({ tags = { "foo", "bar", "foo" } }))
  local root = tree:query("")
  assert_eq(root.tag_counts["foo"], 2, "foo should appear twice")
  assert_eq(root.tag_counts["bar"], 1)
  assert_eq(root.tag_file_counts["foo"], 1, "IDF: file counts once per tag")
  assert_eq(root.tag_file_counts["bar"], 1)
end)

test("update root-level file with tasks", function()
  local tree = summary_tree.new()
  tree:update("notes.md", make_entry({
    tasks = {
      { status = " " },
      { status = "x" },
      { status = " " },
    },
  }))
  local root = tree:query("")
  assert_eq(root.task_count, 3)
  assert_eq(root.task_status_counts[" "], 2)
  assert_eq(root.task_status_counts["x"], 1)
end)

test("update root-level file with frontmatter", function()
  local tree = summary_tree.new()
  tree:update("notes.md", make_entry({
    frontmatter = { type = "daily", date = "2024-01-01" },
  }))
  local root = tree:query("")
  assert_eq(root.fm_key_counts["type"], 1)
  assert_eq(root.fm_key_counts["date"], 1)
end)

test("update root-level file counts links/headings/aliases/block_ids", function()
  local tree = summary_tree.new()
  tree:update("notes.md", make_entry({
    outlinks = { {}, {}, {} },
    headings = { {}, {} },
    aliases = { "alias1" },
    block_ids = { { id = "blk-1" }, { id = "blk-2" } },
  }))
  local root = tree:query("")
  assert_eq(root.link_count, 3)
  assert_eq(root.heading_count, 2)
  assert_eq(root.alias_count, 1)
  assert_eq(root.block_id_count, 2)
end)

-- ---------------------------------------------------------------------------
-- 3. Nested files and directory queries
-- ---------------------------------------------------------------------------
test("update nested file creates directory hierarchy", function()
  local tree = summary_tree.new()
  tree:update("daily/2024-01-01.md", make_entry({ tags = { "journal" } }))
  tree:update("daily/2024-01-02.md", make_entry({ tags = { "journal", "review" } }))

  local root = tree:query("")
  assert_eq(root.file_count, 2)
  assert_eq(root.tag_counts["journal"], 2)
  assert_eq(root.tag_counts["review"], 1)

  local daily = tree:query("daily/")
  assert_true(daily ~= nil, "daily/ directory should exist")
  assert_eq(daily.file_count, 2)
  assert_eq(daily.tag_counts["journal"], 2)
end)

test("deeply nested files propagate to root", function()
  local tree = summary_tree.new()
  tree:update("projects/alpha/tasks.md", make_entry({
    tasks = { { status = " " }, { status = " " } },
  }))
  local root = tree:query("")
  assert_eq(root.file_count, 1)
  assert_eq(root.task_count, 2)

  local projects = tree:query("projects/")
  assert_eq(projects.file_count, 1)

  local alpha = tree:query("projects/alpha/")
  assert_eq(alpha.file_count, 1)
  assert_eq(alpha.task_count, 2)
end)

test("multiple directories aggregate correctly at root", function()
  local tree = summary_tree.new()
  tree:update("daily/note1.md", make_entry({ tags = { "a" } }))
  tree:update("projects/note2.md", make_entry({ tags = { "b" } }))
  tree:update("root.md", make_entry({ tags = { "c" } }))

  local root = tree:query("")
  assert_eq(root.file_count, 3)
  assert_eq(root.tag_counts["a"], 1)
  assert_eq(root.tag_counts["b"], 1)
  assert_eq(root.tag_counts["c"], 1)
  assert_eq(root.tag_file_counts["a"], 1)
  assert_eq(root.tag_file_counts["b"], 1)
  assert_eq(root.tag_file_counts["c"], 1)
end)

-- ---------------------------------------------------------------------------
-- 4. File update (re-update existing file)
-- ---------------------------------------------------------------------------
test("updating existing file replaces its summary", function()
  local tree = summary_tree.new()
  tree:update("notes.md", make_entry({ tags = { "old" } }))
  assert_eq(tree:query("").tag_counts["old"], 1)

  tree:update("notes.md", make_entry({ tags = { "new" } }))
  local root = tree:query("")
  assert_eq(root.file_count, 1, "file_count should still be 1")
  assert_nil(root.tag_counts["old"], "old tag should be gone")
  assert_eq(root.tag_counts["new"], 1)
end)

test("updating file in subdirectory updates ancestors", function()
  local tree = summary_tree.new()
  tree:update("daily/note.md", make_entry({ tasks = { { status = " " } } }))
  assert_eq(tree:query("").task_count, 1)

  tree:update("daily/note.md", make_entry({ tasks = { { status = "x" }, { status = "x" } } }))
  local root = tree:query("")
  assert_eq(root.task_count, 2)
  assert_nil(root.task_status_counts[" "], "old status gone")
  assert_eq(root.task_status_counts["x"], 2)
end)

-- ---------------------------------------------------------------------------
-- 5. File removal
-- ---------------------------------------------------------------------------
test("remove file decrements counts", function()
  local tree = summary_tree.new()
  tree:update("a.md", make_entry({ tags = { "x" } }))
  tree:update("b.md", make_entry({ tags = { "y" } }))
  assert_eq(tree:query("").file_count, 2)

  tree:remove("a.md")
  local root = tree:query("")
  assert_eq(root.file_count, 1)
  assert_nil(root.tag_counts["x"])
  assert_eq(root.tag_counts["y"], 1)
end)

test("remove non-existent file is a no-op", function()
  local tree = summary_tree.new()
  tree:update("a.md", make_entry())
  tree:remove("nonexistent.md")
  assert_eq(tree:query("").file_count, 1)
end)

test("remove last file from directory prunes empty dirs", function()
  local tree = summary_tree.new()
  tree:update("deep/nested/dir/file.md", make_entry())
  assert_eq(tree:query("").file_count, 1)

  tree:remove("deep/nested/dir/file.md")
  assert_eq(tree:query("").file_count, 0)
  assert_nil(tree:query("deep/"), "empty deep/ should be pruned")
  assert_nil(tree:query("deep/nested/"), "empty nested/ should be pruned")
end)

test("remove does not prune dirs with other children", function()
  local tree = summary_tree.new()
  tree:update("dir/a.md", make_entry())
  tree:update("dir/b.md", make_entry())
  tree:remove("dir/a.md")

  local dir = tree:query("dir/")
  assert_true(dir ~= nil, "dir/ should not be pruned")
  assert_eq(dir.file_count, 1)
end)

-- ---------------------------------------------------------------------------
-- 6. Batch operations
-- ---------------------------------------------------------------------------
test("batch_begin/batch_update/batch_end produces correct tree", function()
  local tree = summary_tree.new()
  tree:batch_begin()
  tree:batch_update("daily/a.md", make_entry({ tags = { "journal" } }))
  tree:batch_update("daily/b.md", make_entry({ tags = { "journal", "review" } }))
  tree:batch_update("projects/p.md", make_entry({ outlinks = { {}, {} } }))
  tree:batch_end()

  local root = tree:query("")
  assert_eq(root.file_count, 3)
  assert_eq(root.tag_counts["journal"], 2)
  assert_eq(root.tag_counts["review"], 1)
  assert_eq(root.link_count, 2)

  local daily = tree:query("daily/")
  assert_eq(daily.file_count, 2)
end)

test("batch_remove removes files and prunes", function()
  local tree = summary_tree.new()
  tree:update("dir/a.md", make_entry({ tags = { "x" } }))
  tree:update("dir/b.md", make_entry({ tags = { "y" } }))

  tree:batch_begin()
  tree:batch_remove("dir/a.md")
  tree:batch_remove("dir/b.md")
  tree:batch_end()

  assert_eq(tree:query("").file_count, 0)
  assert_nil(tree:query("dir/"), "empty dir should be pruned")
end)

test("mixed batch update and remove", function()
  local tree = summary_tree.new()
  tree:update("a.md", make_entry({ tags = { "old" } }))

  tree:batch_begin()
  tree:batch_remove("a.md")
  tree:batch_update("b.md", make_entry({ tags = { "new" } }))
  tree:batch_end()

  local root = tree:query("")
  assert_eq(root.file_count, 1)
  assert_nil(root.tag_counts["old"])
  assert_eq(root.tag_counts["new"], 1)
end)

-- ---------------------------------------------------------------------------
-- 7. build_from_files
-- ---------------------------------------------------------------------------
test("build_from_files creates tree from files table", function()
  local tree = summary_tree.new()
  local files = {
    ["daily/a.md"] = make_entry({ tags = { "journal" }, tasks = { { status = " " } } }),
    ["daily/b.md"] = make_entry({ tags = { "journal" } }),
    ["root.md"] = make_entry({ aliases = { "home" } }),
  }
  tree:build_from_files(files)

  local root = tree:query("")
  assert_eq(root.file_count, 3)
  assert_eq(root.tag_counts["journal"], 2)
  assert_eq(root.task_count, 1)
  assert_eq(root.alias_count, 1)
end)

test("build_from_files resets tree state", function()
  local tree = summary_tree.new()
  tree:update("old.md", make_entry({ tags = { "stale" } }))
  assert_eq(tree:query("").file_count, 1)

  tree:build_from_files({
    ["new.md"] = make_entry({ tags = { "fresh" } }),
  })
  local root = tree:query("")
  assert_eq(root.file_count, 1, "should have only the new file")
  assert_nil(root.tag_counts["stale"], "old tag should be gone")
  assert_eq(root.tag_counts["fresh"], 1)
end)

-- ---------------------------------------------------------------------------
-- 8. Tag counts vs tag file counts (IDF distinction)
-- ---------------------------------------------------------------------------
test("tag_counts sums references, tag_file_counts counts files", function()
  local tree = summary_tree.new()
  -- File with duplicate tags
  tree:update("a.md", make_entry({ tags = { "foo", "foo", "bar" } }))
  tree:update("b.md", make_entry({ tags = { "foo" } }))

  local root = tree:query("")
  -- tag_counts: total references
  assert_eq(root.tag_counts["foo"], 3, "foo: 2 refs in a.md + 1 in b.md")
  assert_eq(root.tag_counts["bar"], 1)
  -- tag_file_counts: document frequency (each file counts once)
  assert_eq(root.tag_file_counts["foo"], 2, "foo appears in 2 files")
  assert_eq(root.tag_file_counts["bar"], 1)
end)

-- ---------------------------------------------------------------------------
-- 9. Frontmatter key aggregation
-- ---------------------------------------------------------------------------
test("fm_key_counts aggregates across files", function()
  local tree = summary_tree.new()
  tree:update("a.md", make_entry({ frontmatter = { type = "daily", date = "2024" } }))
  tree:update("b.md", make_entry({ frontmatter = { type = "note" } }))

  local root = tree:query("")
  assert_eq(root.fm_key_counts["type"], 2)
  assert_eq(root.fm_key_counts["date"], 1)
end)

-- ---------------------------------------------------------------------------
-- 10. Edge cases
-- ---------------------------------------------------------------------------
test("empty entry produces zero summary", function()
  local tree = summary_tree.new()
  tree:update("empty.md", make_entry())
  local root = tree:query("")
  assert_eq(root.file_count, 1)
  assert_eq(root.task_count, 0)
  assert_eq(root.link_count, 0)
  assert_eq(root.heading_count, 0)
  assert_eq(root.alias_count, 0)
  assert_eq(root.block_id_count, 0)
  assert_table_eq(root.tag_counts, {})
end)

test("entry with nil fields handled gracefully", function()
  local tree = summary_tree.new()
  tree:update("sparse.md", {
    -- All fields nil except what entry_to_summary checks with "or {}"
  })
  local root = tree:query("")
  assert_eq(root.file_count, 1)
  assert_eq(root.task_count, 0)
  assert_eq(root.link_count, 0)
end)

test("task with nil status defaults to space", function()
  local tree = summary_tree.new()
  tree:update("t.md", make_entry({
    tasks = { { text = "do something" } }, -- no status field
  }))
  local root = tree:query("")
  assert_eq(root.task_count, 1)
  assert_eq(root.task_status_counts[" "], 1, "nil status defaults to space")
end)

test("build_from_files with empty table produces empty tree", function()
  local tree = summary_tree.new()
  tree:build_from_files({})
  local root = tree:query("")
  assert_eq(root.file_count, 0)
end)

test("batch_end with no batch_begin is a no-op", function()
  local tree = summary_tree.new()
  tree:update("a.md", make_entry())
  tree:batch_end() -- should not error
  assert_eq(tree:query("").file_count, 1)
end)

-- ---------------------------------------------------------------------------
-- 11. Scoped queries
-- ---------------------------------------------------------------------------
test("scoped query returns only subtree data", function()
  local tree = summary_tree.new()
  tree:update("daily/a.md", make_entry({ tags = { "journal" } }))
  tree:update("projects/b.md", make_entry({ tags = { "work" } }))

  local daily = tree:query("daily/")
  assert_eq(daily.file_count, 1)
  assert_eq(daily.tag_counts["journal"], 1)
  assert_nil(daily.tag_counts["work"], "work tag not in daily/")

  local projects = tree:query("projects/")
  assert_eq(projects.file_count, 1)
  assert_eq(projects.tag_counts["work"], 1)
  assert_nil(projects.tag_counts["journal"])
end)

-- ---------------------------------------------------------------------------
-- 12. Snapshot isolation (read-only contract)
-- ---------------------------------------------------------------------------
test("snapshot returns correct path field", function()
  local tree = summary_tree.new()
  tree:update("daily/a.md", make_entry())
  local daily = tree:query("daily/")
  assert_eq(daily.path, "daily/")
  local root = tree:query("")
  assert_eq(root.path, "")
end)

-- ============================================================================
-- Summary
-- ============================================================================
print("\n=== Results ===")
print(string.format("  %d passed, %d failed", passed, failed))
if #errors > 0 then
  print("\nFailures:")
  for _, e in ipairs(errors) do
    print("  " .. e.name .. ": " .. e.err)
  end
end

if failed > 0 then
  os.exit(1)
end
