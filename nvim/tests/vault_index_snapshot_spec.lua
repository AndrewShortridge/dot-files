-- Unit tests for vault_index snapshot, generation_guard, and _apply_staged logic
-- Run with: nvim --headless -u NONE -l tests/vault_index_snapshot_spec.lua

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

-- ============================================================================
-- Minimal mock of VaultIndex snapshot/generation logic
-- Replicates the core algorithms from vault_index.lua so we can test them
-- without loading the full module (which requires neovim plugin state).
-- ============================================================================

local VaultIndex = {}
VaultIndex.__index = VaultIndex

--- Create a minimal mock VaultIndex for testing.
function VaultIndex.new()
  local self = setmetatable({}, VaultIndex)
  self.files = {}
  self._name_index = {}
  self._alias_index = {}
  self._inlinks = {}
  self._files_with_tags = {}
  self._files_with_tasks = {}
  self._files_by_type = {}
  self._tag_blooms = {}
  self._file_count = 0
  self._generation = 0
  self._subscribers = {}
  self._ready = false
  self._building = false
  return self
end

--- Snapshot: shallow-copy files table, share derived indexes by reference.
--- Matches the real vault_index.lua implementation exactly.
function VaultIndex:snapshot()
  local files_snap = {}
  for k, v in pairs(self.files) do
    files_snap[k] = v
  end

  return {
    files = files_snap,
    _name_index = self._name_index,
    _alias_index = self._alias_index,
    _inlinks = self._inlinks,
    _files_with_tags = self._files_with_tags,
    _files_with_tasks = self._files_with_tasks,
    _files_by_type = self._files_by_type,
    _tag_blooms = self._tag_blooms,
    _generation = self._generation,
    _file_count = self._file_count,
  }
end

--- Generation guard: captures a generation and provides is_valid().
function VaultIndex:generation_guard()
  local captured_gen = self._generation
  local idx = self
  return {
    generation = captured_gen,
    is_valid = function()
      return idx._generation == captured_gen
    end,
  }
end

--- Notify subscribers and bump generation.
function VaultIndex:_notify_update(context)
  self._generation = self._generation + 1
  for _, fn in ipairs(self._subscribers) do
    local ok, err = pcall(fn, self._generation, context)
    if not ok then
      -- swallow in tests
    end
  end
end

--- Apply staged mutations atomically (simplified for testing).
--- Matches the core logic of the real _apply_staged without derived index rebuilds.
function VaultIndex:_apply_staged(staged, deleted, changed_rel_paths)
  -- Apply staged entries
  for rel_path, entry in pairs(staged) do
    if self.files[rel_path] == nil then
      self._file_count = self._file_count + 1
    end
    self.files[rel_path] = entry
  end

  -- Remove deleted entries
  for _, rel_path in ipairs(deleted) do
    if self.files[rel_path] ~= nil then
      self._file_count = self._file_count - 1
      self.files[rel_path] = nil
    end
  end

  self._ready = true
  self._building = false
  self:_notify_update({ changed_paths = changed_rel_paths, deleted_paths = deleted })
end

-- ============================================================================
-- Tests
-- ============================================================================

print("\n=== Vault Index Snapshot Tests ===\n")

-- ---------------------------------------------------------------------------
-- 1. Snapshot isolation
-- ---------------------------------------------------------------------------
test("snapshot isolation: mutating original files does not affect snapshot", function()
  local idx = VaultIndex.new()
  idx.files["a.md"] = { title = "A" }
  idx.files["b.md"] = { title = "B" }
  idx._file_count = 2

  local snap = idx:snapshot()

  -- Mutate the original: add a new file, remove an existing one
  idx.files["c.md"] = { title = "C" }
  idx.files["a.md"] = nil

  -- Snapshot should be unaffected
  assert_true(snap.files["a.md"] ~= nil, "snapshot should still have a.md")
  assert_eq(snap.files["a.md"].title, "A", "snapshot a.md title")
  assert_true(snap.files["b.md"] ~= nil, "snapshot should still have b.md")
  assert_nil(snap.files["c.md"], "snapshot should not have c.md")
end)

test("snapshot isolation: mutating snapshot files does not affect original", function()
  local idx = VaultIndex.new()
  idx.files["x.md"] = { title = "X" }
  idx._file_count = 1

  local snap = idx:snapshot()

  -- Mutate the snapshot
  snap.files["x.md"] = nil
  snap.files["y.md"] = { title = "Y" }

  -- Original should be unaffected
  assert_true(idx.files["x.md"] ~= nil, "original should still have x.md")
  assert_eq(idx.files["x.md"].title, "X", "original x.md title unchanged")
  assert_nil(idx.files["y.md"], "original should not have y.md")
end)

-- ---------------------------------------------------------------------------
-- 2. Snapshot shares entry references (not deep copies)
-- ---------------------------------------------------------------------------
test("snapshot entries are same table references as original", function()
  local idx = VaultIndex.new()
  local entry_a = { title = "A", tags = { "foo" } }
  local entry_b = { title = "B", tags = { "bar" } }
  idx.files["a.md"] = entry_a
  idx.files["b.md"] = entry_b
  idx._file_count = 2

  local snap = idx:snapshot()

  -- Same reference (rawequal)
  assert_true(snap.files["a.md"] == entry_a, "a.md should be same reference")
  assert_true(snap.files["b.md"] == entry_b, "b.md should be same reference")
  assert_true(rawequal(snap.files["a.md"], idx.files["a.md"]), "rawequal check for a.md")
end)

-- ---------------------------------------------------------------------------
-- 3. Snapshot derived index sharing (same references)
-- ---------------------------------------------------------------------------
test("snapshot derived indexes are same references as original", function()
  local idx = VaultIndex.new()
  idx._name_index = { note = "a.md" }
  idx._alias_index = { alias1 = "b.md" }
  idx._inlinks = { ["a.md"] = { "b.md" } }
  idx._files_with_tags = { ["a.md"] = true }
  idx._files_with_tasks = { ["b.md"] = true }
  idx._files_by_type = { markdown = { ["a.md"] = true } }
  idx._tag_blooms = { foo = { [1] = true } }

  local snap = idx:snapshot()

  assert_true(snap._name_index == idx._name_index, "_name_index same reference")
  assert_true(snap._alias_index == idx._alias_index, "_alias_index same reference")
  assert_true(snap._inlinks == idx._inlinks, "_inlinks same reference")
  assert_true(snap._files_with_tags == idx._files_with_tags, "_files_with_tags same reference")
  assert_true(snap._files_with_tasks == idx._files_with_tasks, "_files_with_tasks same reference")
  assert_true(snap._files_by_type == idx._files_by_type, "_files_by_type same reference")
  assert_true(snap._tag_blooms == idx._tag_blooms, "_tag_blooms same reference")
end)

-- ---------------------------------------------------------------------------
-- 4. Generation guard creation and invalidation
-- ---------------------------------------------------------------------------
test("generation guard captures current generation and invalidates on bump", function()
  local idx = VaultIndex.new()
  assert_eq(idx._generation, 0, "initial generation is 0")

  local guard = idx:generation_guard()
  assert_eq(guard.generation, 0, "guard captures generation 0")
  assert_true(guard.is_valid(), "guard should be valid initially")

  -- Bump generation
  idx._generation = idx._generation + 1
  assert_true(not guard.is_valid(), "guard should be invalid after generation bump")
end)

test("generation guard invalid after _notify_update", function()
  local idx = VaultIndex.new()
  local guard = idx:generation_guard()

  idx:_notify_update({ changed_paths = { "a.md" } })

  assert_true(not guard.is_valid(), "guard invalid after _notify_update")
  assert_eq(guard.generation, 0, "guard still holds captured generation")
  assert_eq(idx._generation, 1, "index generation bumped to 1")
end)

-- ---------------------------------------------------------------------------
-- 5. Generation guard remains valid when generation unchanged
-- ---------------------------------------------------------------------------
test("generation guard stays valid when generation unchanged", function()
  local idx = VaultIndex.new()
  idx._generation = 5 -- start at arbitrary generation

  local guard = idx:generation_guard()
  assert_eq(guard.generation, 5, "guard captures generation 5")
  assert_true(guard.is_valid(), "guard valid immediately")

  -- Do various things that DON'T bump generation
  idx.files["a.md"] = { title = "A" }
  idx._file_count = 1
  idx._name_index = { note = "a.md" }

  assert_true(guard.is_valid(), "guard still valid after non-generation mutations")
end)

test("multiple guards track independently", function()
  local idx = VaultIndex.new()

  local guard1 = idx:generation_guard()
  idx:_notify_update()
  local guard2 = idx:generation_guard()
  idx:_notify_update()

  assert_true(not guard1.is_valid(), "guard1 invalid (gen 0, current 2)")
  assert_true(not guard2.is_valid(), "guard2 invalid (gen 1, current 2)")
  assert_eq(guard1.generation, 0)
  assert_eq(guard2.generation, 1)
  assert_eq(idx._generation, 2)
end)

-- ---------------------------------------------------------------------------
-- 6. Staged apply atomicity
-- ---------------------------------------------------------------------------
test("_apply_staged adds new entries and increments file count", function()
  local idx = VaultIndex.new()
  idx.files["existing.md"] = { title = "Existing" }
  idx._file_count = 1

  local staged = {
    ["new1.md"] = { title = "New1" },
    ["new2.md"] = { title = "New2" },
  }

  idx:_apply_staged(staged, {}, { "new1.md", "new2.md" })

  assert_eq(idx._file_count, 3, "file count after adding 2")
  assert_eq(idx.files["new1.md"].title, "New1")
  assert_eq(idx.files["new2.md"].title, "New2")
  assert_eq(idx.files["existing.md"].title, "Existing")
end)

test("_apply_staged removes deleted entries and decrements file count", function()
  local idx = VaultIndex.new()
  idx.files["a.md"] = { title = "A" }
  idx.files["b.md"] = { title = "B" }
  idx.files["c.md"] = { title = "C" }
  idx._file_count = 3

  idx:_apply_staged({}, { "a.md", "c.md" }, {})

  assert_eq(idx._file_count, 1, "file count after deleting 2")
  assert_nil(idx.files["a.md"], "a.md removed")
  assert_nil(idx.files["c.md"], "c.md removed")
  assert_eq(idx.files["b.md"].title, "B", "b.md still present")
end)

test("_apply_staged handles combined adds and deletes atomically", function()
  local idx = VaultIndex.new()
  idx.files["old.md"] = { title = "Old" }
  idx._file_count = 1

  local staged = { ["new.md"] = { title = "New" } }
  local deleted = { "old.md" }

  idx:_apply_staged(staged, deleted, { "new.md" })

  assert_eq(idx._file_count, 1, "file count: +1 -1 = still 1")
  assert_nil(idx.files["old.md"], "old.md removed")
  assert_eq(idx.files["new.md"].title, "New", "new.md added")
end)

test("_apply_staged updates existing entry without changing file count", function()
  local idx = VaultIndex.new()
  idx.files["a.md"] = { title = "Old Title" }
  idx._file_count = 1

  local staged = { ["a.md"] = { title = "New Title" } }
  idx:_apply_staged(staged, {}, { "a.md" })

  assert_eq(idx._file_count, 1, "file count unchanged on update")
  assert_eq(idx.files["a.md"].title, "New Title", "entry updated")
end)

test("_apply_staged calls _notify_update", function()
  local idx = VaultIndex.new()
  local notified = false
  local notified_gen = nil
  table.insert(idx._subscribers, function(gen, _ctx)
    notified = true
    notified_gen = gen
  end)

  idx:_apply_staged({ ["a.md"] = { title = "A" } }, {}, { "a.md" })

  assert_true(notified, "_notify_update should have been called")
  assert_eq(notified_gen, 1, "generation should be 1 after first notify")
end)

test("_apply_staged sets _ready and clears _building", function()
  local idx = VaultIndex.new()
  idx._ready = false
  idx._building = true

  idx:_apply_staged({}, {}, {})

  assert_true(idx._ready, "_ready should be true after apply")
  assert_true(not idx._building, "_building should be false after apply")
end)

test("_apply_staged ignores deletion of non-existent files", function()
  local idx = VaultIndex.new()
  idx.files["a.md"] = { title = "A" }
  idx._file_count = 1

  idx:_apply_staged({}, { "nonexistent.md" }, {})

  assert_eq(idx._file_count, 1, "file count unchanged when deleting non-existent")
  assert_eq(idx.files["a.md"].title, "A", "existing file unchanged")
end)

-- ---------------------------------------------------------------------------
-- 7. Snapshot file count
-- ---------------------------------------------------------------------------
test("snapshot _file_count matches number of entries", function()
  local idx = VaultIndex.new()
  idx.files["a.md"] = { title = "A" }
  idx.files["b.md"] = { title = "B" }
  idx.files["c.md"] = { title = "C" }
  idx._file_count = 3

  local snap = idx:snapshot()

  assert_eq(snap._file_count, 3, "snapshot _file_count")

  -- Verify it actually matches the table count
  local count = 0
  for _ in pairs(snap.files) do count = count + 1 end
  assert_eq(count, 3, "actual number of files in snapshot")
  assert_eq(snap._file_count, count, "_file_count matches actual count")
end)

test("snapshot _file_count reflects state at time of snapshot", function()
  local idx = VaultIndex.new()
  idx.files["a.md"] = { title = "A" }
  idx._file_count = 1

  local snap = idx:snapshot()

  -- Add more files to original after snapshot
  idx.files["b.md"] = { title = "B" }
  idx._file_count = 2

  assert_eq(snap._file_count, 1, "snapshot _file_count unchanged after original mutation")
  assert_eq(idx._file_count, 2, "original _file_count updated")
end)

test("snapshot of empty index has _file_count = 0", function()
  local idx = VaultIndex.new()
  local snap = idx:snapshot()

  assert_eq(snap._file_count, 0, "empty snapshot _file_count")
  local count = 0
  for _ in pairs(snap.files) do count = count + 1 end
  assert_eq(count, 0, "empty snapshot has no files")
end)

test("snapshot _generation matches index generation at time of snapshot", function()
  local idx = VaultIndex.new()
  idx:_notify_update() -- gen -> 1
  idx:_notify_update() -- gen -> 2

  local snap = idx:snapshot()
  assert_eq(snap._generation, 2, "snapshot captures generation 2")

  idx:_notify_update() -- gen -> 3
  assert_eq(snap._generation, 2, "snapshot generation unchanged after further bumps")
  assert_eq(idx._generation, 3, "original generation advanced")
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

-- Exit with non-zero if any test failed
if failed > 0 then
  os.exit(1)
end
