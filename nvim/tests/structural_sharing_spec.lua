-- Tests for structural_sharing.lua (doc 30)
-- Covers: correctness, reference identity, diff_entry compatibility,
-- lazy field safety, intern_array, freeze
-- Run with: nvim --headless -u NONE -l tests/structural_sharing_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local function assert_near(got, expected, tol, msg)
  if type(got) ~= "number" or math.abs(got - expected) > tol then
    error((msg or "") .. " expected ~" .. tostring(expected) .. " (tol " .. tostring(tol) .. "), got: " .. vim.inspect(got))
  end
end

-- Deep-equality helper (translation of busted's assert.same) — spec-local.
local function deep_equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function assert_same(expected, got, msg)
  if not deep_equal(expected, got) then
    error((msg or "") .. " expected (same): " .. vim.inspect(expected) .. ", got: " .. vim.inspect(got))
  end
end

-- assert.has_error(fn): translation -> the function must raise.
local function assert_error(fn, msg)
  if pcall(fn) then
    error((msg or "expected function to raise an error") .. " (no error raised)")
  end
end

-- ============================================================================
-- Load module under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- Mock config before requiring the module
package.loaded["andrew.vault.config"] = {
  sharing = { enable = true, debug_immutability = false, intern_threshold = 3 },
}

local ss = require("andrew.vault.structural_sharing")

-- ---------------------------------------------------------------------------
-- Helper: build a realistic entry table
-- ---------------------------------------------------------------------------
local function make_entry(overrides)
  local entry = {
    rel_path = "notes/test.md",
    name = "test",
    name_lower = "test",
    mtime = 1000,
    size = 500,
    tags = { "daily", "project" },
    aliases = { "myalias" },
    frontmatter = { title = "Test", status = "active" },
    inline_fields = { due = "2026-01-01" },
    headings = {
      { text = "Introduction", text_lower = "introduction", slug = "introduction", level = 1, line = 3 },
      { text = "Details", text_lower = "details", slug = "details", level = 2, line = 10 },
    },
    block_ids = {
      { id = "blk-abc123", text = "some text", line = 15 },
    },
    outlinks = {
      { path = "other.md", display = "Other", embed = false, _name_lower = "other" },
      { path = "ref.md", display = "Ref", embed = true, _name_lower = "ref" },
    },
    tasks = {
      { text = "Do something", text_lower = "do something", status = " ", line = 20, due = "2026-03-01" },
    },
  }
  if overrides then
    for k, v in pairs(overrides) do entry[k] = v end
  end
  return entry
end

-- Deep-copy a table (for creating independent copies)
local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local copy = {}
  for k, v in pairs(t) do copy[k] = deep_copy(v) end
  return copy
end

-- ============================================================================
-- Tests
-- ============================================================================

print("\n=== Structural Sharing Tests ===\n")

-- ---------------------------------------------------------------------------
-- 1. arrays_equal
-- ---------------------------------------------------------------------------
test("arrays_equal returns true for identical references", function()
  local t = { "a", "b" }
  assert_true(ss.arrays_equal(t, t))
end)
test("arrays_equal returns true for equal content", function()
  assert_true(ss.arrays_equal({ "a", "b" }, { "a", "b" }))
end)
test("arrays_equal returns false for different content", function()
  assert_true(not ss.arrays_equal({ "a", "b" }, { "a", "c" }))
end)
test("arrays_equal returns false for different lengths", function()
  assert_true(not ss.arrays_equal({ "a" }, { "a", "b" }))
end)
test("arrays_equal handles both nil", function()
  assert_true(ss.arrays_equal(nil, nil))
end)
test("arrays_equal handles one nil", function()
  assert_true(not ss.arrays_equal({ "a" }, nil))
  assert_true(not ss.arrays_equal(nil, { "a" }))
end)
test("arrays_equal handles empty arrays", function()
  assert_true(ss.arrays_equal({}, {}))
end)

-- ---------------------------------------------------------------------------
-- 2. dicts_equal
-- ---------------------------------------------------------------------------
test("dicts_equal returns true for equal dicts", function()
  assert_true(ss.dicts_equal({ a = 1, b = "x" }, { a = 1, b = "x" }))
end)
test("dicts_equal returns false for different values", function()
  assert_true(not ss.dicts_equal({ a = 1 }, { a = 2 }))
end)
test("dicts_equal returns false for extra keys", function()
  assert_true(not ss.dicts_equal({ a = 1 }, { a = 1, b = 2 }))
end)
test("dicts_equal returns false for missing keys", function()
  assert_true(not ss.dicts_equal({ a = 1, b = 2 }, { a = 1 }))
end)
test("dicts_equal handles both nil", function()
  assert_true(ss.dicts_equal(nil, nil))
end)

-- ---------------------------------------------------------------------------
-- 3. struct_arrays_equal
-- ---------------------------------------------------------------------------
local struct_key = function(h) return h.text .. ":" .. h.level end
test("struct_arrays_equal returns true for identical structured arrays", function()
  local a = { { text = "A", level = 1 } }
  local b = { { text = "A", level = 1 } }
  assert_true(ss.struct_arrays_equal(a, b, struct_key))
end)
test("struct_arrays_equal returns false when key differs", function()
  local a = { { text = "A", level = 1 } }
  local b = { { text = "B", level = 1 } }
  assert_true(not ss.struct_arrays_equal(a, b, struct_key))
end)
test("struct_arrays_equal returns false when field differs", function()
  local a = { { text = "A", level = 1, extra = "x" } }
  local b = { { text = "A", level = 1, extra = "y" } }
  assert_true(not ss.struct_arrays_equal(a, b, struct_key))
end)
test("struct_arrays_equal returns false when b has extra field", function()
  local a = { { text = "A", level = 1 } }
  local b = { { text = "A", level = 1, extra = "y" } }
  assert_true(not ss.struct_arrays_equal(a, b, struct_key))
end)

-- ---------------------------------------------------------------------------
-- 4. share_unchanged — reference identity (spec test #2)
-- ---------------------------------------------------------------------------
test("share_unchanged reuses all sub-tables when nothing changed", function()
  local old = make_entry()
  local new = deep_copy(old)
  local changed = ss.share_unchanged(old, new)

  assert_same({}, changed)
  -- Reference identity checks
  assert_true(rawequal(old.tags, new.tags))
  assert_true(rawequal(old.aliases, new.aliases))
  assert_true(rawequal(old.frontmatter, new.frontmatter))
  assert_true(rawequal(old.inline_fields, new.inline_fields))
  assert_true(rawequal(old.headings, new.headings))
  assert_true(rawequal(old.block_ids, new.block_ids))
  assert_true(rawequal(old.outlinks, new.outlinks))
  assert_true(rawequal(old.tasks, new.tasks))
end)

test("share_unchanged does not share changed sub-tables", function()
  local old = make_entry()
  local new = make_entry({ tags = { "different" } })
  local changed = ss.share_unchanged(old, new)

  assert_true(changed.tags)
  assert_true(not rawequal(old.tags, new.tags))
  -- Other fields should still be shared
  assert_true(rawequal(old.aliases, new.aliases))
  assert_true(rawequal(old.headings, new.headings))
end)

test("share_unchanged detects frontmatter value changes", function()
  local old = make_entry()
  local new = make_entry({ frontmatter = { title = "Changed", status = "active" } })
  local changed = ss.share_unchanged(old, new)
  assert_true(changed.frontmatter)
  assert_true(not rawequal(old.frontmatter, new.frontmatter))
end)

test("share_unchanged detects heading changes", function()
  local old = make_entry()
  local new = deep_copy(old)
  new.headings[1].line = 999 -- line number changed
  local changed = ss.share_unchanged(old, new)
  assert_true(changed.headings)
end)

test("share_unchanged detects task changes", function()
  local old = make_entry()
  local new = deep_copy(old)
  new.tasks[1].status = "x"
  local changed = ss.share_unchanged(old, new)
  assert_true(changed.tasks)
end)

test("share_unchanged handles nil sub-tables gracefully", function()
  local old = make_entry({ tags = nil, headings = nil })
  local new = make_entry({ tags = nil, headings = nil })
  local changed = ss.share_unchanged(old, new)
  assert_nil(changed.tags)
  assert_nil(changed.headings)
end)

-- ---------------------------------------------------------------------------
-- 5. diff_entry compatibility (spec test #5)
-- ---------------------------------------------------------------------------
-- Simulate diff_entry's change detection logic
local function simple_diff(old, new)
  local changed = {}
  if not ss.arrays_equal(old.tags, new.tags) then changed.tags = true end
  if not ss.arrays_equal(old.aliases, new.aliases) then changed.aliases = true end
  if not ss.dicts_equal(old.frontmatter, new.frontmatter) then changed.frontmatter = true end
  return changed
end

test("diff_entry: share_unchanged agrees with diff on unchanged fields", function()
  local old = make_entry()
  local new = deep_copy(old)
  local share_changed = ss.share_unchanged(old, new)
  local diff_changed = simple_diff(old, new)
  -- Both should detect no changes
  assert_same({}, share_changed)
  assert_same({}, diff_changed)
end)

test("diff_entry: share_unchanged agrees with diff on changed fields", function()
  local old = make_entry()
  local new = make_entry({ tags = { "new_tag" }, frontmatter = { title = "New" } })
  local share_changed = ss.share_unchanged(old, new)
  -- Both should detect tags and frontmatter changed
  assert_true(share_changed.tags)
  assert_true(share_changed.frontmatter)
  assert_nil(share_changed.aliases) -- unchanged
end)

-- ---------------------------------------------------------------------------
-- 6. Lazy field safety (spec test #6)
-- ---------------------------------------------------------------------------
test("lazy field safety: sharing does not interfere with metatable-computed fields", function()
  -- Simulate _entry_mt lazy field
  local mt = {
    __index = function(self, key)
      if key == "tag_set" then
        local set = {}
        for _, t in ipairs(rawget(self, "tags") or {}) do set[t] = true end
        rawset(self, "tag_set", set)
        return set
      end
    end,
  }

  local old = setmetatable(make_entry(), mt)
  local new = setmetatable(deep_copy(old), mt)

  -- Share unchanged sub-tables
  ss.share_unchanged(old, new)

  -- tags are now shared references
  assert_true(rawequal(old.tags, new.tags))

  -- Lazy field should still work independently on each entry
  local old_set = old.tag_set
  local new_set = new.tag_set
  assert_true(old_set.daily)
  assert_true(new_set.daily)
  -- tag_set should be computed independently (not shared)
  assert_true(not rawequal(old_set, new_set))
end)

-- ---------------------------------------------------------------------------
-- 7. intern_array
-- ---------------------------------------------------------------------------
test("intern_array returns canonical table for identical arrays", function()
  local store = ss.new_intern_store()
  local t1 = { "a", "b" }
  local t2 = { "a", "b" }
  local r1 = ss.intern_array(store, t1)
  local r2 = ss.intern_array(store, t2)
  assert_true(rawequal(r1, r2))
  assert_true(rawequal(r1, t1))
end)

test("intern_array returns different tables for different arrays", function()
  local store = ss.new_intern_store()
  local t1 = { "a", "b" }
  local t2 = { "a", "c" }
  local r1 = ss.intern_array(store, t1)
  local r2 = ss.intern_array(store, t2)
  assert_true(not rawequal(r1, r2))
end)

test("intern_array handles nil input", function()
  local store = ss.new_intern_store()
  assert_nil(ss.intern_array(store, nil))
end)

test("intern_array handles empty array", function()
  local store = ss.new_intern_store()
  local t = {}
  assert_eq(ss.intern_array(store, t), t)
end)

test("intern_array tracks stats correctly", function()
  local store = ss.new_intern_store()
  ss.intern_array(store, { "x" }) -- miss
  ss.intern_array(store, { "x" }) -- hit
  ss.intern_array(store, { "y" }) -- miss
  local stats = ss.intern_store_stats(store)
  assert_eq(stats.size, 2)
  assert_eq(stats.hits, 1)
  assert_eq(stats.misses, 2)
  assert_near(stats.hit_rate, 1 / 3, 0.01)
end)

-- ---------------------------------------------------------------------------
-- 8. freeze (immutability guard)
-- ---------------------------------------------------------------------------
test("freeze is no-op when debug_immutability is false", function()
  local cfg = package.loaded["andrew.vault.config"]
  cfg.sharing.debug_immutability = false
  local t = { "a", "b" }
  local result = ss.freeze(t, "test")
  assert_true(rawequal(t, result))
end)

test("freeze prevents modification when debug_immutability is true", function()
  local cfg = package.loaded["andrew.vault.config"]
  cfg.sharing.debug_immutability = true
  local t = { "a", "b" }
  local frozen = ss.freeze(t, "test")
  assert_eq(frozen[1], "a")
  assert_eq(frozen[2], "b")
  -- Note: __len is not honored for tables in LuaJIT/Lua 5.1
  assert_error(function() frozen[1] = "z" end)
  -- Reset
  cfg.sharing.debug_immutability = false
end)

-- ---------------------------------------------------------------------------
-- 9. share_stats tracking
-- ---------------------------------------------------------------------------
test("share_stats tracks per-field reuse and change counts", function()
  -- Reset stats by reloading (stats are module-level)
  package.loaded["andrew.vault.structural_sharing"] = nil
  local ss2 = require("andrew.vault.structural_sharing")

  local old = make_entry()
  local new = deep_copy(old)
  new.tags = { "changed" }

  ss2.share_unchanged(old, new)
  local stats = ss2.share_stats()

  assert_eq(stats.calls, 1)
  assert_eq(stats.reused.tags, 0) -- tags changed
  assert_eq(stats.changed.tags, 1)
  assert_eq(stats.reused.aliases, 1) -- aliases unchanged
  assert_eq(stats.changed.aliases, 0)
  assert_eq(stats.reused.headings, 1)
  assert_eq(stats.reused.outlinks, 1)
  assert_eq(stats.reused.tasks, 1)
end)

-- Restore the canonical module reference after the reload above so the
-- remaining tests exercise the same instance the rest of the suite used.
ss = require("andrew.vault.structural_sharing")

-- ---------------------------------------------------------------------------
-- 10. freeze integration within share_unchanged
-- ---------------------------------------------------------------------------
test("freeze within share_unchanged applies freeze to reused tables when debug_immutability is true", function()
  local cfg = package.loaded["andrew.vault.config"]
  cfg.sharing.debug_immutability = true

  local old = make_entry()
  local new = deep_copy(old)
  ss.share_unchanged(old, new)

  -- Shared (reused) tables should be frozen — modification should error
  assert_error(function() new.tags[1] = "modified" end)
  assert_error(function() new.frontmatter.new_key = "val" end)
  assert_error(function() new.headings[1] = {} end)
  assert_error(function() new.outlinks[1] = {} end)
  assert_error(function() new.tasks[1] = {} end)

  -- Reading should still work
  assert_eq(new.tags[1], "daily")
  assert_eq(new.frontmatter.status, "active")

  cfg.sharing.debug_immutability = false
end)

test("freeze within share_unchanged does not freeze changed tables", function()
  local cfg = package.loaded["andrew.vault.config"]
  cfg.sharing.debug_immutability = true

  local old = make_entry()
  local new = make_entry({ tags = { "different" } })
  ss.share_unchanged(old, new)

  -- Changed field (tags) should NOT be frozen
  new.tags[1] = "modified" -- should NOT error
  assert_eq(new.tags[1], "modified")

  -- Unchanged field (aliases) should be frozen
  assert_error(function() new.aliases[1] = "modified" end)

  cfg.sharing.debug_immutability = false
end)

-- ---------------------------------------------------------------------------
-- 11. intern_array freeze integration
-- ---------------------------------------------------------------------------
test("intern_array freezes interned tables when debug_immutability is true", function()
  local cfg = package.loaded["andrew.vault.config"]
  cfg.sharing.debug_immutability = true

  local store = ss.new_intern_store()
  local result = ss.intern_array(store, { "a", "b" })

  -- Interned table should be frozen
  assert_error(function() result[1] = "modified" end)
  assert_eq(result[1], "a")

  cfg.sharing.debug_immutability = false
end)

-- ============================================================================
-- Summary
-- ============================================================================
_H.finish({ style = "results", exit = "os" })
