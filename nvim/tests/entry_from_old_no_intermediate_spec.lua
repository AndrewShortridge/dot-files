-- Perf regression spec for entry_from_old's intermediate copy (T18-entry_from_old).
--
-- BUG: entry_from_old() in vault_index_build.lua used to pairs()-copy the entire
-- old_entry into a fresh `fields` table, then make_entry constructed ANOTHER
-- table copying ~19 named fields. Two allocations + two full copies per
-- incremental save. Worse, the pairs() copy forwarded the lazy metatable-
-- derived keys (abs_path, tag_set, basename, …) that had been materialized on
-- the live entry — keys that _apply_entry_mt recomputes anyway.
--
-- FIX: make_entry accepts an optional second arg old_entry and, per named key,
-- uses fields[k] when non-nil else old_entry[k]. entry_from_old now passes its
-- stat updates + overrides straight to make_entry(overrides, old_entry) with no
-- intermediate copy. Only the enumerated stored keys are read, so the lazy
-- derived keys are never forwarded.
--
-- This drives the REAL vault_index against a temp vault (no mock) and wraps the
-- public parser.make_entry to capture the first-arg `fields` table it receives
-- on the incremental-update path (real invocation, not source introspection).
--
-- Discriminating power: revert make_entry+entry_from_old to the double-copy and
-- Test A fails — the pairs() copy forwards the materialized abs_path/tag_set/
-- basename keys into the `fields` table passed to make_entry, tripping the
-- "derived keys absent" assertions.
--
-- Run with: nvim --headless -u NONE -l tests/entry_from_old_no_intermediate_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_deep_eq =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vi = require("andrew.vault.vault_index")
local parser = require("andrew.vault.vault_index_parser")

print("\n=== entry_from_old No-Intermediate-Copy Tests ===\n")

local NOTE = "note.md"
local N_HEADINGS = 4

local function write_note(dir, body)
  local abs = dir .. "/" .. NOTE
  local f = assert(io.open(abs, "w"))
  f:write(body)
  f:close()
  return abs
end

-- Multi-chunk note: frontmatter + N headings (>= min_chunk_lines, >1 chunk),
-- modeled on chunk_reparse_reuse_spec's build_content.
local function build_content(opts)
  opts = opts or {}
  local lines = { "---", "title: Note", "tags: [base]", "---", "" }
  for i = 1, N_HEADINGS do
    lines[#lines + 1] = "# Heading " .. i
    lines[#lines + 1] = ""
    local task = "- [ ] task " .. i .. " #t" .. i
    if opts.edit_heading == i and opts.edited_task then
      task = "- [ ] EDITED task " .. i .. " #t" .. i
    end
    lines[#lines + 1] = task
    lines[#lines + 1] = "Links to [[target" .. i .. "]] [key" .. i .. ":: val" .. i .. "]"
    lines[#lines + 1] = "A para. ^blk-" .. string.format("%03d", i)
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

-- Seed an index whose note.md entry carries a populated _chunks cache. The
-- first update_file builds the chunk cache; the second is the genuine
-- incremental diff (the path that calls entry_from_old).
local function seed_index(content)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local abs = write_note(dir, content)
  local idx = vi.VaultIndex.new(dir)
  idx:build_sync()
  idx:update_file(abs)
  assert_true(idx.files[NOTE]._chunks ~= nil, "chunk cache seeded")
  assert_true(#idx.files[NOTE]._chunks > 1, "more than one chunk")
  return idx, dir, abs
end

-- ===========================================================================
-- Test A: the incremental update must NOT forward lazy metatable-derived keys
--         into make_entry's fields table (discriminating).
-- ===========================================================================
test("incremental make_entry receives no derived keys from old_entry", function()
  local idx, dir, abs = seed_index(build_content())

  -- Force derived keys to materialize (rawset) on the LIVE old entry.
  local old = idx.files[NOTE]
  local _ = old.abs_path
  local _ = old.tag_set
  local _ = old.basename
  -- Sanity: they are now stored on the live entry table (rawget visible).
  assert_true(rawget(old, "abs_path") ~= nil, "abs_path materialized on live entry")
  assert_true(rawget(old, "tag_set") ~= nil, "tag_set materialized on live entry")
  assert_true(rawget(old, "basename") ~= nil, "basename materialized on live entry")

  -- Capture the fields table make_entry receives on the next (incremental) call.
  local captured = nil
  local orig_make_entry = parser.make_entry
  parser.make_entry = function(fields, old_entry)
    captured = fields
    return orig_make_entry(fields, old_entry)
  end

  -- Edit one heading's body so exactly one chunk's digest changes -> incremental
  -- entry_from_old path (FM unchanged branch).
  write_note(dir, build_content({ edit_heading = 2, edited_task = true }))
  idx:update_file(abs)

  parser.make_entry = orig_make_entry

  assert_true(captured ~= nil, "make_entry was invoked on the incremental update")
  assert_eq(captured.abs_path, nil, "abs_path not forwarded into make_entry fields")
  assert_eq(captured.tag_set, nil, "tag_set not forwarded into make_entry fields")
  assert_eq(captured.basename, nil, "basename not forwarded into make_entry fields")
  assert_eq(captured.basename_lower, nil, "basename_lower not forwarded")
  assert_eq(captured.folder, nil, "folder not forwarded")
  assert_eq(captured.heading_slugs, nil, "heading_slugs not forwarded")
  assert_eq(captured.block_id_set, nil, "block_id_set not forwarded")
end)

-- ===========================================================================
-- Test B: behavioral equivalence — the entry resulting from the incremental
--         update has identical named-field values to a full parse, and derived
--         fields still resolve via the metatable.
-- ===========================================================================
test("incremental entry shape matches full parse + derived fields resolve", function()
  local idx, dir, abs = seed_index(build_content())

  local v2 = build_content({ edit_heading = 3, edited_task = true })
  write_note(dir, v2)
  idx:update_file(abs)
  local entry = idx.files[NOTE]

  -- Full parse of the same content as the reference shape.
  local content = parser.read_file(abs)
  local stat = vim.uv.fs_stat(abs)
  local ref = parser.parse_content(content, NOTE, stat)
  assert_true(ref ~= nil, "reference full parse succeeded")

  -- Deep-eq on the parse-derived structured fields.
  assert_deep_eq(entry.frontmatter, ref.frontmatter, "frontmatter matches")
  assert_deep_eq(entry.aliases, ref.aliases, "aliases match")
  assert_deep_eq(entry.tags, ref.tags, "tags match")
  assert_deep_eq(entry.headings, ref.headings, "headings match")
  assert_deep_eq(entry.block_ids, ref.block_ids, "block_ids match")
  assert_deep_eq(entry.outlinks, ref.outlinks, "outlinks match")
  assert_deep_eq(entry.inline_fields, ref.inline_fields, "inline_fields match")
  -- tasks: chunked path normalizes task line numbers to absolute while
  -- parse_content uses body-relative lines (a pre-existing parser quirk). Compare
  -- text/checked, not line, to stay byte-equivalent on the perf-relevant content.
  local function plain_tasks(arr)
    local out = {}
    for i, t in ipairs(arr or {}) do out[i] = { text = t.text, checked = t.checked } end
    return out
  end
  assert_deep_eq(plain_tasks(entry.tasks), plain_tasks(ref.tasks), "tasks match")

  -- Scalar named fields.
  assert_eq(entry.rel_path, ref.rel_path, "rel_path matches")
  assert_eq(entry.rel_stem, ref.rel_stem, "rel_stem matches")
  assert_eq(entry.day, ref.day, "day matches")
  assert_eq(entry.day_ts, ref.day_ts, "day_ts matches")
  assert_eq(entry.created_ts, ref.created_ts, "created_ts matches")
  assert_eq(entry.modified_ts, ref.modified_ts, "modified_ts matches")
  assert_eq(entry.mtime, stat.mtime.sec, "mtime updated from stat")
  assert_eq(entry.size, stat.size, "size updated from stat")

  -- Derived fields still resolve via the metatable.
  assert_eq(entry.abs_path, dir .. "/" .. NOTE, "abs_path resolves via metatable")
  assert_true(entry.tag_set ~= nil and entry.tag_set["base"] == true, "tag_set resolves correctly")
end)

-- ===========================================================================
-- Test C: the no-change path (mtime/size touch only) still inherits all old
--         fields and overwrites content_hash correctly.
-- ===========================================================================
test("no-change touch path inherits old fields", function()
  local idx, dir, abs = seed_index(build_content())
  local before = idx.files[NOTE]
  local before_tags = vim.deepcopy(before.tags)
  local before_headings = #before.headings

  -- Touch the file (rewrite identical content) -> content unchanged, only stat
  -- updates. Bump mtime so the file is re-examined.
  os.execute("touch -d '+1 hour' " .. vim.fn.shellescape(abs))
  idx:update_file(abs)
  local after = idx.files[NOTE]

  assert_deep_eq(after.tags, before_tags, "tags carried forward unchanged")
  assert_eq(#after.headings, before_headings, "headings carried forward unchanged")
  assert_true(after._chunks ~= nil, "chunk cache carried forward")
  assert_eq(after.abs_path, dir .. "/" .. NOTE, "abs_path still resolves")
end)

-- Optional micro note (not an assertion): pre-fix, each incremental update
-- allocated TWO tables and ran TWO full copies (pairs(old_entry) + 19 named
-- assigns); post-fix only the single make_entry table is allocated. A
-- collectgarbage("count") delta over a loop of N updates is measurably lower.

_H.finish({ style = "results", exit = "os" })
