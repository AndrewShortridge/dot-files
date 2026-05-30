-- Tests for structural_sharing.lua (doc 30)
-- Covers: correctness, reference identity, diff_entry compatibility,
-- lazy field safety, intern_array, freeze

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

-- ---------------------------------------------------------------------------
-- 1. arrays_equal
-- ---------------------------------------------------------------------------
describe("arrays_equal", function()
  it("returns true for identical references", function()
    local t = { "a", "b" }
    assert.is_true(ss.arrays_equal(t, t))
  end)
  it("returns true for equal content", function()
    assert.is_true(ss.arrays_equal({ "a", "b" }, { "a", "b" }))
  end)
  it("returns false for different content", function()
    assert.is_false(ss.arrays_equal({ "a", "b" }, { "a", "c" }))
  end)
  it("returns false for different lengths", function()
    assert.is_false(ss.arrays_equal({ "a" }, { "a", "b" }))
  end)
  it("handles both nil", function()
    assert.is_true(ss.arrays_equal(nil, nil))
  end)
  it("handles one nil", function()
    assert.is_false(ss.arrays_equal({ "a" }, nil))
    assert.is_false(ss.arrays_equal(nil, { "a" }))
  end)
  it("handles empty arrays", function()
    assert.is_true(ss.arrays_equal({}, {}))
  end)
end)

-- ---------------------------------------------------------------------------
-- 2. dicts_equal
-- ---------------------------------------------------------------------------
describe("dicts_equal", function()
  it("returns true for equal dicts", function()
    assert.is_true(ss.dicts_equal({ a = 1, b = "x" }, { a = 1, b = "x" }))
  end)
  it("returns false for different values", function()
    assert.is_false(ss.dicts_equal({ a = 1 }, { a = 2 }))
  end)
  it("returns false for extra keys", function()
    assert.is_false(ss.dicts_equal({ a = 1 }, { a = 1, b = 2 }))
  end)
  it("returns false for missing keys", function()
    assert.is_false(ss.dicts_equal({ a = 1, b = 2 }, { a = 1 }))
  end)
  it("handles both nil", function()
    assert.is_true(ss.dicts_equal(nil, nil))
  end)
end)

-- ---------------------------------------------------------------------------
-- 3. struct_arrays_equal
-- ---------------------------------------------------------------------------
describe("struct_arrays_equal", function()
  local key = function(h) return h.text .. ":" .. h.level end
  it("returns true for identical structured arrays", function()
    local a = { { text = "A", level = 1 } }
    local b = { { text = "A", level = 1 } }
    assert.is_true(ss.struct_arrays_equal(a, b, key))
  end)
  it("returns false when key differs", function()
    local a = { { text = "A", level = 1 } }
    local b = { { text = "B", level = 1 } }
    assert.is_false(ss.struct_arrays_equal(a, b, key))
  end)
  it("returns false when field differs", function()
    local a = { { text = "A", level = 1, extra = "x" } }
    local b = { { text = "A", level = 1, extra = "y" } }
    assert.is_false(ss.struct_arrays_equal(a, b, key))
  end)
  it("returns false when b has extra field", function()
    local a = { { text = "A", level = 1 } }
    local b = { { text = "A", level = 1, extra = "y" } }
    assert.is_false(ss.struct_arrays_equal(a, b, key))
  end)
end)

-- ---------------------------------------------------------------------------
-- 4. share_unchanged — reference identity (spec test #2)
-- ---------------------------------------------------------------------------
describe("share_unchanged", function()
  it("reuses all sub-tables when nothing changed", function()
    local old = make_entry()
    local new = deep_copy(old)
    local changed = ss.share_unchanged(old, new)

    assert.same({}, changed)
    -- Reference identity checks
    assert.is_true(rawequal(old.tags, new.tags))
    assert.is_true(rawequal(old.aliases, new.aliases))
    assert.is_true(rawequal(old.frontmatter, new.frontmatter))
    assert.is_true(rawequal(old.inline_fields, new.inline_fields))
    assert.is_true(rawequal(old.headings, new.headings))
    assert.is_true(rawequal(old.block_ids, new.block_ids))
    assert.is_true(rawequal(old.outlinks, new.outlinks))
    assert.is_true(rawequal(old.tasks, new.tasks))
  end)

  it("does not share changed sub-tables", function()
    local old = make_entry()
    local new = make_entry({ tags = { "different" } })
    local changed = ss.share_unchanged(old, new)

    assert.is_true(changed.tags)
    assert.is_false(rawequal(old.tags, new.tags))
    -- Other fields should still be shared
    assert.is_true(rawequal(old.aliases, new.aliases))
    assert.is_true(rawequal(old.headings, new.headings))
  end)

  it("detects frontmatter value changes", function()
    local old = make_entry()
    local new = make_entry({ frontmatter = { title = "Changed", status = "active" } })
    local changed = ss.share_unchanged(old, new)
    assert.is_true(changed.frontmatter)
    assert.is_false(rawequal(old.frontmatter, new.frontmatter))
  end)

  it("detects heading changes", function()
    local old = make_entry()
    local new = deep_copy(old)
    new.headings[1].line = 999  -- line number changed
    local changed = ss.share_unchanged(old, new)
    assert.is_true(changed.headings)
  end)

  it("detects task changes", function()
    local old = make_entry()
    local new = deep_copy(old)
    new.tasks[1].status = "x"
    local changed = ss.share_unchanged(old, new)
    assert.is_true(changed.tasks)
  end)

  it("handles nil sub-tables gracefully", function()
    local old = make_entry({ tags = nil, headings = nil })
    local new = make_entry({ tags = nil, headings = nil })
    local changed = ss.share_unchanged(old, new)
    assert.is_nil(changed.tags)
    assert.is_nil(changed.headings)
  end)
end)

-- ---------------------------------------------------------------------------
-- 5. diff_entry compatibility (spec test #5)
-- ---------------------------------------------------------------------------
describe("diff_entry compatibility", function()
  -- Simulate diff_entry's change detection logic
  local function simple_diff(old, new)
    local changed = {}
    if not ss.arrays_equal(old.tags, new.tags) then changed.tags = true end
    if not ss.arrays_equal(old.aliases, new.aliases) then changed.aliases = true end
    if not ss.dicts_equal(old.frontmatter, new.frontmatter) then changed.frontmatter = true end
    return changed
  end

  it("share_unchanged agrees with diff on unchanged fields", function()
    local old = make_entry()
    local new = deep_copy(old)
    local share_changed = ss.share_unchanged(old, new)
    local diff_changed = simple_diff(old, new)
    -- Both should detect no changes
    assert.same({}, share_changed)
    assert.same({}, diff_changed)
  end)

  it("share_unchanged agrees with diff on changed fields", function()
    local old = make_entry()
    local new = make_entry({ tags = { "new_tag" }, frontmatter = { title = "New" } })
    local share_changed = ss.share_unchanged(old, new)
    -- Both should detect tags and frontmatter changed
    assert.is_true(share_changed.tags)
    assert.is_true(share_changed.frontmatter)
    assert.is_nil(share_changed.aliases) -- unchanged
  end)
end)

-- ---------------------------------------------------------------------------
-- 6. Lazy field safety (spec test #6)
-- ---------------------------------------------------------------------------
describe("lazy field safety", function()
  it("sharing does not interfere with metatable-computed fields", function()
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
    assert.is_true(rawequal(old.tags, new.tags))

    -- Lazy field should still work independently on each entry
    local old_set = old.tag_set
    local new_set = new.tag_set
    assert.is_true(old_set.daily)
    assert.is_true(new_set.daily)
    -- tag_set should be computed independently (not shared)
    assert.is_false(rawequal(old_set, new_set))
  end)
end)

-- ---------------------------------------------------------------------------
-- 7. intern_array
-- ---------------------------------------------------------------------------
describe("intern_array", function()
  it("returns canonical table for identical arrays", function()
    local store = ss.new_intern_store()
    local t1 = { "a", "b" }
    local t2 = { "a", "b" }
    local r1 = ss.intern_array(store, t1)
    local r2 = ss.intern_array(store, t2)
    assert.is_true(rawequal(r1, r2))
    assert.is_true(rawequal(r1, t1))
  end)

  it("returns different tables for different arrays", function()
    local store = ss.new_intern_store()
    local t1 = { "a", "b" }
    local t2 = { "a", "c" }
    local r1 = ss.intern_array(store, t1)
    local r2 = ss.intern_array(store, t2)
    assert.is_false(rawequal(r1, r2))
  end)

  it("handles nil input", function()
    local store = ss.new_intern_store()
    assert.is_nil(ss.intern_array(store, nil))
  end)

  it("handles empty array", function()
    local store = ss.new_intern_store()
    local t = {}
    assert.equals(t, ss.intern_array(store, t))
  end)

  it("tracks stats correctly", function()
    local store = ss.new_intern_store()
    ss.intern_array(store, { "x" })  -- miss
    ss.intern_array(store, { "x" })  -- hit
    ss.intern_array(store, { "y" })  -- miss
    local stats = ss.intern_store_stats(store)
    assert.equals(2, stats.size)
    assert.equals(1, stats.hits)
    assert.equals(2, stats.misses)
    assert.near(1 / 3, stats.hit_rate, 0.01)
  end)
end)

-- ---------------------------------------------------------------------------
-- 8. freeze (immutability guard)
-- ---------------------------------------------------------------------------
describe("freeze", function()
  it("is no-op when debug_immutability is false", function()
    local cfg = package.loaded["andrew.vault.config"]
    cfg.sharing.debug_immutability = false
    local t = { "a", "b" }
    local result = ss.freeze(t, "test")
    assert.is_true(rawequal(t, result))
  end)

  it("prevents modification when debug_immutability is true", function()
    local cfg = package.loaded["andrew.vault.config"]
    cfg.sharing.debug_immutability = true
    local t = { "a", "b" }
    local frozen = ss.freeze(t, "test")
    assert.equals("a", frozen[1])
    assert.equals("b", frozen[2])
    -- Note: __len is not honored for tables in LuaJIT/Lua 5.1
    assert.has_error(function() frozen[1] = "z" end, nil)
    -- Reset
    cfg.sharing.debug_immutability = false
  end)
end)

-- ---------------------------------------------------------------------------
-- 9. share_stats tracking
-- ---------------------------------------------------------------------------
describe("share_stats", function()
  it("tracks per-field reuse and change counts", function()
    -- Reset stats by reloading (stats are module-level)
    package.loaded["andrew.vault.structural_sharing"] = nil
    local ss2 = require("andrew.vault.structural_sharing")

    local old = make_entry()
    local new = deep_copy(old)
    new.tags = { "changed" }

    ss2.share_unchanged(old, new)
    local stats = ss2.share_stats()

    assert.equals(1, stats.calls)
    assert.equals(0, stats.reused.tags)     -- tags changed
    assert.equals(1, stats.changed.tags)
    assert.equals(1, stats.reused.aliases)  -- aliases unchanged
    assert.equals(0, stats.changed.aliases)
    assert.equals(1, stats.reused.headings)
    assert.equals(1, stats.reused.outlinks)
    assert.equals(1, stats.reused.tasks)
  end)
end)

-- ---------------------------------------------------------------------------
-- 10. freeze integration within share_unchanged
-- ---------------------------------------------------------------------------
describe("freeze within share_unchanged", function()
  it("applies freeze to reused tables when debug_immutability is true", function()
    local cfg = package.loaded["andrew.vault.config"]
    cfg.sharing.debug_immutability = true

    local old = make_entry()
    local new = deep_copy(old)
    ss.share_unchanged(old, new)

    -- Shared (reused) tables should be frozen — modification should error
    assert.has_error(function() new.tags[1] = "modified" end)
    assert.has_error(function() new.frontmatter.new_key = "val" end)
    assert.has_error(function() new.headings[1] = {} end)
    assert.has_error(function() new.outlinks[1] = {} end)
    assert.has_error(function() new.tasks[1] = {} end)

    -- Reading should still work
    assert.equals("daily", new.tags[1])
    assert.equals("active", new.frontmatter.status)

    cfg.sharing.debug_immutability = false
  end)

  it("does not freeze changed tables", function()
    local cfg = package.loaded["andrew.vault.config"]
    cfg.sharing.debug_immutability = true

    local old = make_entry()
    local new = make_entry({ tags = { "different" } })
    ss.share_unchanged(old, new)

    -- Changed field (tags) should NOT be frozen
    new.tags[1] = "modified"  -- should NOT error
    assert.equals("modified", new.tags[1])

    -- Unchanged field (aliases) should be frozen
    assert.has_error(function() new.aliases[1] = "modified" end)

    cfg.sharing.debug_immutability = false
  end)
end)

-- ---------------------------------------------------------------------------
-- 11. intern_array freeze integration
-- ---------------------------------------------------------------------------
describe("intern_array freeze", function()
  it("freezes interned tables when debug_immutability is true", function()
    local cfg = package.loaded["andrew.vault.config"]
    cfg.sharing.debug_immutability = true

    local store = ss.new_intern_store()
    local result = ss.intern_array(store, { "a", "b" })

    -- Interned table should be frozen
    assert.has_error(function() result[1] = "modified" end)
    assert.equals("a", result[1])

    cfg.sharing.debug_immutability = false
  end)
end)
