-- Behavioral spec for M._compute_change_types / M._diff_entry.
--
-- _compute_change_types ORs 7 change flags across modified/added/deleted files
-- and now early-exits once all 7 saturate. The early-exit must be exactly
-- equivalent to the exhaustive version: it decrements its counter ONLY on a
-- genuine false->true transition, so a flag is never dropped and the cross-file
-- OR stays complete. These tests pin that equivalence — especially the case
-- where two different files each contribute a different single flag.
--
-- Drives the REAL module (M._compute_change_types / M._diff_entry are exported).
-- Run with: nvim --headless -u NONE -l tests/compute_change_types_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vi = require("andrew.vault.vault_index")
local cct = vi._compute_change_types

local ALL_KEYS = { "frontmatter", "tags", "headings", "outlinks", "tasks", "aliases", "block_ids" }

--- Build a fully-specified entry; override any field via opts.
local function entry(opts)
  opts = opts or {}
  return {
    frontmatter = opts.frontmatter or { title = "T" },
    tags = opts.tags or { "a" },
    headings = opts.headings or { { slug = "h1", level = 1 } },
    outlinks = opts.outlinks or { { _name_lower = "beta" } },
    tasks = opts.tasks or { { text = "x" } },
    aliases = opts.aliases or { "A1" },
    block_ids = opts.block_ids or { { id = "b1" } },
  }
end

--- Assert change_types has exactly `expected_true` keys set to true.
local function assert_only_true(ct, expected_true, msg)
  local want = {}
  for _, k in ipairs(expected_true) do want[k] = true end
  for _, k in ipairs(ALL_KEYS) do
    assert_eq(ct[k], want[k] == true, (msg or "") .. " key=" .. k)
  end
end

print("\n=== _compute_change_types Tests ===\n")

test("no files changed returns nil", function()
  assert_nil(cct({}, {}, {}, {}, {}), "empty change set -> nil")
end)

test("modified with identical content sets no flags", function()
  local e = entry()
  local ct = cct({ ["a.md"] = e }, { ["a.md"] = e }, { "a.md" }, {}, {})
  assert_only_true(ct, {}, "identical entry")
end)

test("modified: only tags differ", function()
  local old = entry({ tags = { "a" } })
  local new = entry({ tags = { "a", "b" } })
  local ct = cct({ ["a.md"] = old }, { ["a.md"] = new }, { "a.md" }, {}, {})
  assert_only_true(ct, { "tags" }, "tags only")
end)

test("modified: frontmatter key added (value-agnostic)", function()
  local old = entry({ frontmatter = { title = "T" } })
  local new = entry({ frontmatter = { title = "T", extra = 1 } })
  local ct = cct({ ["a.md"] = old }, { ["a.md"] = new }, { "a.md" }, {}, {})
  assert_only_true(ct, { "frontmatter" }, "frontmatter key add")
end)

test("modified: frontmatter value change with same keys is NOT a change", function()
  -- diff_entry compares KEY presence, not values (intentional). Pin it.
  local old = entry({ frontmatter = { title = "Old" } })
  local new = entry({ frontmatter = { title = "New" } })
  local ct = cct({ ["a.md"] = old }, { ["a.md"] = new }, { "a.md" }, {}, {})
  assert_only_true(ct, {}, "same keys, different value")
end)

test("modified: headings reordered IS a change (positional compare)", function()
  local h = { { slug = "one", level = 1 }, { slug = "two", level = 2 } }
  local h_rev = { { slug = "two", level = 2 }, { slug = "one", level = 1 } }
  local ct = cct({ ["a.md"] = entry({ headings = h }) },
    { ["a.md"] = entry({ headings = h_rev }) }, { "a.md" }, {}, {})
  assert_only_true(ct, { "headings" }, "reordered headings")
end)

test("modified: outlinks reordered (same set) is NOT a change", function()
  local o = { { _name_lower = "x" }, { _name_lower = "y" } }
  local o_rev = { { _name_lower = "y" }, { _name_lower = "x" } }
  local ct = cct({ ["a.md"] = entry({ outlinks = o }) },
    { ["a.md"] = entry({ outlinks = o_rev }) }, { "a.md" }, {}, {})
  assert_only_true(ct, {}, "reordered same-set outlinks")
end)

test("modified: task count change", function()
  local old = entry({ tasks = { { text = "x" } } })
  local new = entry({ tasks = { { text = "x" }, { text = "y" } } })
  local ct = cct({ ["a.md"] = old }, { ["a.md"] = new }, { "a.md" }, {}, {})
  assert_only_true(ct, { "tasks" }, "task count")
end)

test("modified: task checkbox toggled (same count) IS a change", function()
  local old = entry({ tasks = { { status = " ", line = 1, text = "do x" } } })
  local new = entry({ tasks = { { status = "x", line = 1, text = "do x" } } })
  local ct = cct({ ["a.md"] = old }, { ["a.md"] = new }, { "a.md" }, {}, {})
  assert_only_true(ct, { "tasks" }, "checkbox toggle")
end)

test("modified: task due/priority edited (same status+count+text) IS a change", function()
  local old = entry({ tasks = { { status = " ", line = 1, text = "do x", due = "2026-01-01", priority = 3 } } })
  local new = entry({ tasks = { { status = " ", line = 1, text = "do x", due = "2026-02-01", priority = 1 } } })
  local ct = cct({ ["a.md"] = old }, { ["a.md"] = new }, { "a.md" }, {}, {})
  assert_only_true(ct, { "tasks" }, "task metadata edit")
end)

test("modified: identical tasks (same count) is NOT a change", function()
  local t = { { status = "x", line = 2, text = "done", due = "2026-03-03" } }
  local ct = cct({ ["a.md"] = entry({ tasks = t }) },
    { ["a.md"] = entry({ tasks = t }) }, { "a.md" }, {}, {})
  assert_only_true(ct, {}, "identical tasks")
end)

-- CRITICAL: two files each contribute a DIFFERENT single flag. The early-exit
-- must NOT stop after the first file — both flags must end up true.
test("cross-file OR: file A tags + file B outlinks both reported", function()
  local a_old = entry({ tags = { "a" } })
  local a_new = entry({ tags = { "a", "b" } })           -- A: tags differ
  local b_old = entry({ outlinks = { { _name_lower = "x" } } })
  local b_new = entry({ outlinks = { { _name_lower = "x" }, { _name_lower = "y" } } }) -- B: outlinks differ
  local ct = cct(
    { ["a.md"] = a_old, ["b.md"] = b_old },
    { ["a.md"] = a_new, ["b.md"] = b_new },
    { "a.md", "b.md" }, {}, {})
  assert_only_true(ct, { "tags", "outlinks" }, "cross-file OR")
end)

test("added file sets all flags (saturation path)", function()
  local ct = cct({}, { ["new.md"] = entry() }, {}, { "new.md" }, {})
  assert_only_true(ct, ALL_KEYS, "added -> all true")
end)

test("deleted file sets all flags", function()
  local ct = cct({ ["gone.md"] = entry() }, {}, {}, {}, { "gone.md" })
  assert_only_true(ct, ALL_KEYS, "deleted -> all true")
end)

-- Saturation then a later distinct-but-redundant file: result stays all-true.
test("saturation early-exit still returns complete all-true table", function()
  local ct = cct(
    { ["b.md"] = entry({ tags = { "a" } }) },
    { ["new.md"] = entry(), ["b.md"] = entry({ tags = { "a", "z" } }) },
    { "b.md" }, { "new.md" }, {})
  assert_only_true(ct, ALL_KEYS, "saturated all-true")
end)

-- Discriminating guard for the early-exit's transition condition: redundant
-- repeats of already-set flags must NOT count toward saturation, or a later
-- file carrying the only occurrence of a still-unset flag would be skipped.
-- Here A+B cover 6 flags, C redundantly repeats one, and D carries the sole
-- 'outlinks' change. A buggy counter (decrement without the transition guard)
-- saturates at C and drops D's outlinks -> this asserts all 7 end up true.
test("redundant repeats do not trigger premature saturation (D not skipped)", function()
  local A_old = entry()
  local A_new = entry({
    tags = { "a", "b" },                              -- tags
    headings = { { slug = "z", level = 1 } },         -- headings
    tasks = { { text = "x" }, { text = "y" } },       -- tasks
  })
  local B_old = entry()
  local B_new = entry({
    aliases = { "A1", "A2" },                         -- aliases
    block_ids = { { id = "b1" }, { id = "b2" } },     -- block_ids
    frontmatter = { title = "T", k = 1 },             -- frontmatter
  })
  local C_old = entry()
  local C_new = entry({ tags = { "a", "b" } })        -- redundant: tags again
  local D_old = entry()
  local D_new = entry({ outlinks = { { _name_lower = "beta" }, { _name_lower = "gamma" } } }) -- ONLY outlinks
  local ct = cct(
    { ["a.md"] = A_old, ["b.md"] = B_old, ["c.md"] = C_old, ["d.md"] = D_old },
    { ["a.md"] = A_new, ["b.md"] = B_new, ["c.md"] = C_new, ["d.md"] = D_new },
    { "a.md", "b.md", "c.md", "d.md" }, {}, {})
  assert_only_true(ct, ALL_KEYS, "all 7 flags incl. outlinks from D")
end)

-- ---------------------------------------------------------------------------
-- _has_interest_subscribers gate: the diff is skipped (nil change_types) when
-- no subscriber declares interests. interests_overlap(nil-interests, nil) is
-- true, so a nil-interests subscriber still fires — proving the skip is
-- behavior-preserving. Drives the REAL index instance / subscribe API.
-- ---------------------------------------------------------------------------
print("\n=== _has_interest_subscribers gate Tests ===\n")

local idx = vi.VaultIndex.new(vim.fn.tempname())

test("no subscribers -> _has_interest_subscribers is false", function()
  assert_eq(idx:_has_interest_subscribers(), false, "empty subscriber list")
end)

test("plain-function (nil interests) subscriber -> still false", function()
  local unsub = idx:subscribe(function() end)
  assert_eq(idx:_has_interest_subscribers(), false, "nil-interests subscriber")
  unsub()
end)

test("subscriber with interests -> true; removed -> false again", function()
  local unsub = idx:subscribe({ fn = function() end, interests = { "tags" } })
  assert_eq(idx:_has_interest_subscribers(), true, "declared interests")
  unsub()
  assert_eq(idx:_has_interest_subscribers(), false, "back to nil-only")
end)

test("nil-interests subscriber fires even with nil change_types (skip is safe)", function()
  local fired = false
  local unsub = idx:subscribe(function() fired = true end)
  -- Simulate the skipped-diff save path: change_types passed as nil.
  idx:_notify_update({
    changed_paths = { "a.md" },
    change_types = nil,
  })
  assert_true(fired, "nil-interests subscriber fired with nil change_types")
  unsub()
end)

_H.finish({ style = "results", exit = "os" })
