-- Perf regression spec for chunked re-parse reuse (T4-chunk-reparse).
--
-- BUG: process_chunks() in vault_index_build.lua used to re-parse EVERY chunk on
-- every incremental update, even when diff_chunks reported only one changed
-- chunk. parsed_data is not persisted (strip_derived drops it), but it IS
-- retained in-memory on the live entry's _chunks; the old code discarded it and
-- called parser.parse_chunk for all N chunks. Editing one paragraph in a
-- 10-heading note re-parsed all 10 chunks.
--
-- FIX: process_chunks reuses the prior entry's per-chunk parsed_data for
-- unchanged chunks (digest match), sharing by reference when the position is
-- unchanged or re-applying a line delta when the chunk merely shifted. Only
-- changed chunks are re-parsed.
--
-- This drives the REAL vault_index against a temp vault (no mock) and wraps the
-- public parser.parse_chunk with a call counter (counting real invocations, not
-- source introspection).
--
-- Discriminating power: revert the reuse guard in process_chunks (always call
-- parse_chunk) and Test A's "exactly one chunk re-parsed" assertion fails
-- (calls == N).
--
-- Run with: nvim --headless -u NONE -l tests/chunk_reparse_reuse_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_deep_eq =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vi = require("andrew.vault.vault_index")
local parser = require("andrew.vault.vault_index_parser")

print("\n=== Chunk Re-Parse Reuse Tests ===\n")

-- Instrument the real parser: count actual parse_chunk invocations.
local parse_chunk_calls = 0
local orig_parse_chunk = parser.parse_chunk
parser.parse_chunk = function(...)
  parse_chunk_calls = parse_chunk_calls + 1
  return orig_parse_chunk(...)
end

local NOTE = "note.md"

local function write_note(dir, body)
  local abs = dir .. "/" .. NOTE
  local f = assert(io.open(abs, "w"))
  f:write(body)
  f:close()
  return abs
end

-- Build a many-chunk note: frontmatter + N headings, each with a task, a link,
-- an inline field and a block id. >= min_chunk_lines (20) and >1 chunk.
local N_HEADINGS = 10
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
    -- Optionally insert an extra line under an early heading to SHIFT all
    -- later chunks' start_line (exercises the line-delta reuse path).
    if opts.insert_line_after == i then
      lines[#lines + 1] = "Extra inserted paragraph line."
      lines[#lines + 1] = ""
    end
  end
  return table.concat(lines, "\n")
end

-- Compare two parse-derived entries field by field. The reference is a
-- full-chunked-reparse of the SAME content (every chunk re-parsed), so this
-- proves the reuse path is byte-identical to "reparse everything". (We compare
-- against the chunked path, NOT parser.parse_content, because the chunked path
-- normalizes all line numbers to absolute while parse_content uses body-relative
-- task lines — a pre-existing parser quirk, out of scope for this perf fix.)
local function assert_entries_equal(entry, ref, label)
  -- Strip metatable / derived noise: compare only the parse-derived arrays.
  local function plain_headings(arr)
    local out = {}
    for i, h in ipairs(arr or {}) do out[i] = { text = h.text, line = h.line, level = h.level } end
    return out
  end
  local function plain_blocks(arr)
    local out = {}
    for i, b in ipairs(arr or {}) do out[i] = { id = b.id, line = b.line } end
    return out
  end
  local function plain_tasks(arr)
    local out = {}
    for i, t in ipairs(arr or {}) do out[i] = { text = t.text, line = t.line, checked = t.checked } end
    return out
  end
  local function plain_links(arr)
    local out = {}
    for i, l in ipairs(arr or {}) do out[i] = { path = l.path, display = l.display, embed = l.embed } end
    return out
  end
  label = label or ""
  assert_deep_eq(plain_headings(entry.headings), plain_headings(ref.headings), label .. " headings match")
  assert_deep_eq(plain_blocks(entry.block_ids), plain_blocks(ref.block_ids), label .. " block_ids match")
  assert_deep_eq(plain_tasks(entry.tasks), plain_tasks(ref.tasks), label .. " tasks match")
  assert_deep_eq(plain_links(entry.outlinks), plain_links(ref.outlinks), label .. " outlinks match")
  assert_deep_eq(entry.inline_fields, ref.inline_fields, label .. " inline_fields match")
  assert_deep_eq(entry.tags, ref.tags, label .. " tags match")
end

-- Build a reference entry for `final` content using a FULL chunked reparse of
-- every chunk. Achieved by stripping cached parsed_data off the seeded entry's
-- chunks before the update: the reuse guard requires cached.parsed_data, so with
-- it absent process_chunks re-parses ALL chunks (identical to the old behavior
-- and to the post-load path). This is the correct "reparse everything" baseline.
local function full_reparse_reference(seed_content, final_content)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local abs = write_note(dir, seed_content)
  local idx = vi.VaultIndex.new(dir)
  idx:build_sync()
  idx:update_file(abs)               -- builds _chunks cache (with parsed_data)
  -- Drop cached parsed_data -> forces full chunk reparse on the next update.
  for _, c in ipairs(idx.files[NOTE]._chunks) do c.parsed_data = nil end
  write_note(dir, final_content)
  idx:update_file(abs)
  return idx.files[NOTE]
end

-- Seed an index whose note.md entry carries a populated _chunks cache.
-- build_sync uses parser.parse_file (no _chunks); the FIRST update_file builds
-- the chunk cache, the SECOND is the genuine incremental diff. So seed by
-- running update_file once after build_sync.
local function seed_index(content)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local abs = write_note(dir, content)
  local idx = vi.VaultIndex.new(dir)
  idx:build_sync()
  idx:update_file(abs)            -- builds _chunks cache
  assert_true(idx.files[NOTE]._chunks ~= nil, "chunk cache seeded")
  assert_true(#idx.files[NOTE]._chunks > 1, "more than one chunk")
  return idx, dir, abs
end

-- ===========================================================================
-- Test A: editing one chunk re-parses exactly one chunk (discriminating).
-- ===========================================================================
test("editing one chunk re-parses exactly one chunk", function()
  local v1 = build_content()
  local idx, _, abs = seed_index(v1)

  -- Edit ONE chunk's body (heading 5's task text), keeping line count identical
  -- so no later chunk shifts. Only chunk for heading 5 should re-parse.
  local v2 = build_content({ edit_heading = 5, edited_task = true })
  write_note((abs:gsub("/" .. NOTE .. "$", "")), v2)

  parse_chunk_calls = 0
  idx:update_file(abs)

  assert_eq(parse_chunk_calls, 1, "exactly one chunk re-parsed (others reuse cached parsed_data)")
end)

-- ===========================================================================
-- Test B: incremental entry is byte-identical to a full parse, including the
--         line-delta reuse path (a shift in an early chunk moves later chunks).
-- ===========================================================================
test("incremental entry matches full chunked reparse after edit + line shift", function()
  local v1 = build_content()
  local idx, dir, abs = seed_index(v1)

  -- Insert a line under heading 2: this changes chunk 3 (heading 2's body)
  -- AND shifts the start_line of every chunk after it. The shifted-but-
  -- digest-identical chunks exercise offset_parsed_data.
  local v2 = build_content({ insert_line_after = 2 })
  write_note(dir, v2)
  idx:update_file(abs)

  local ref = full_reparse_reference(v1, v2)
  assert_entries_equal(idx.files[NOTE], ref, "shift")

  -- Specifically assert a downstream chunk's line numbers shifted correctly:
  -- heading 10 lives 2 lines later in v2 than v1 (proves the line-delta math).
  local function find_heading(e, text)
    for _, h in ipairs(e.headings) do if h.text == text then return h end end
  end
  local h10 = find_heading(idx.files[NOTE], "Heading 10")
  local ref_h10 = find_heading(ref, "Heading 10")
  assert_true(h10 ~= nil and ref_h10 ~= nil, "heading 10 present")
  assert_eq(h10.line, ref_h10.line, "shifted heading line matches full reparse")
end)

-- ===========================================================================
-- Test C: post-load safety — chunks loaded from disk carry no parsed_data, so
--         even "unchanged" chunks must be re-parsed (not silently emptied).
-- ===========================================================================
test("post-load unchanged chunks still produce a correct entry", function()
  local v1 = build_content()
  local _, dir, _ = seed_index(v1)

  -- Fresh index loading the persisted JSON: _chunks have {start_line, end_line,
  -- digest} only, no parsed_data.
  local idx2 = vi.VaultIndex.new(dir)
  -- Persist the seeded index first so there is JSON to load.
  local idx1 = vi.VaultIndex.new(dir)
  idx1:build_sync()
  idx1:update_file(dir .. "/" .. NOTE)
  idx1:persist_now()
  assert_true(idx2:load(), "load() succeeds")
  local loaded = idx2.files[NOTE]
  assert_true(loaded._chunks ~= nil, "loaded chunks present")
  assert_true(loaded._chunks[2] == nil or loaded._chunks[2].parsed_data == nil,
    "loaded chunks carry no parsed_data")

  -- Edit one chunk and update against the loaded (parsed_data-less) cache.
  local v2 = build_content({ edit_heading = 3, edited_task = true })
  write_note(dir, v2)
  idx2:update_file(dir .. "/" .. NOTE)

  -- Despite cached parsed_data being absent, the merged entry must match a full
  -- chunked reparse (unchanged-but-uncached chunks were re-parsed, not dropped).
  local ref = full_reparse_reference(v1, v2)
  assert_entries_equal(idx2.files[NOTE], ref, "post-load")
end)

-- ===========================================================================
-- Test D: post-load WARM — warming a loaded entry's chunk cache makes the first
--         save re-parse only the touched chunk (discriminating).
-- ===========================================================================
test("warm_chunk_cache makes post-load first save re-parse only the touched chunk", function()
  local v1 = build_content()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local abs = write_note(dir, v1)

  -- Seed + persist so there is JSON to load.
  local idx1 = vi.VaultIndex.new(dir)
  idx1:build_sync()
  idx1:update_file(abs)
  idx1:persist_now()

  -- Fresh index loading the persisted JSON: slim chunks, no parsed_data.
  local idx2 = vi.VaultIndex.new(dir)
  assert_true(idx2:load(), "load() succeeds")
  local loaded = idx2.files[NOTE]
  assert_true(loaded._chunks ~= nil and #loaded._chunks > 1, "loaded chunks present")
  assert_true(loaded._chunks[2].parsed_data == nil, "loaded chunk carries no parsed_data")
  local digests_before = {}
  for i, c in ipairs(loaded._chunks) do digests_before[i] = c.digest end

  -- Warm the chunk cache (what the BufReadPost IDLE job does).
  idx2:warm_chunk_cache(abs)
  assert_true(loaded._chunks[1].parsed_data ~= nil, "chunk 1 parsed_data warmed")
  assert_true(loaded._chunks[2].parsed_data ~= nil, "chunk 2 parsed_data warmed")
  for i, c in ipairs(loaded._chunks) do
    assert_eq(c.digest, digests_before[i], "warm leaves chunk digest unchanged")
  end

  -- Edit ONE chunk's body (line count unchanged so no shift) and save.
  local v2 = build_content({ edit_heading = 4, edited_task = true })
  write_note(dir, v2)
  parse_chunk_calls = 0
  idx2:update_file(abs)
  -- Discriminating: with warming, exactly one chunk re-parses; without it (or if
  -- the per-chunk parsed_data copy is reverted) all N chunks re-parse.
  assert_eq(parse_chunk_calls, 1, "post-load warmed first save re-parses exactly one chunk")

  -- Byte-identity: warmed first save matches a full chunked reparse.
  local ref = full_reparse_reference(v1, v2)
  assert_entries_equal(idx2.files[NOTE], ref, "post-load-warm")
end)

-- ===========================================================================
-- Test E: alignment guard — warming a file whose disk content diverged from the
--         loaded chunks is a no-op, and a subsequent update is still correct.
-- ===========================================================================
test("warm_chunk_cache skips when disk content diverged from loaded chunks", function()
  local v1 = build_content()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local abs = write_note(dir, v1)

  local idx1 = vi.VaultIndex.new(dir)
  idx1:build_sync()
  idx1:update_file(abs)
  idx1:persist_now()

  local idx2 = vi.VaultIndex.new(dir)
  assert_true(idx2:load(), "load() succeeds")
  local loaded = idx2.files[NOTE]
  assert_true(loaded._chunks ~= nil and #loaded._chunks > 1, "loaded chunks present")

  -- Diverge the on-disk content (insert a heading -> chunk count differs).
  local v2 = build_content({ insert_line_after = 2 })
  v2 = v2 .. "\n# Heading 11\n\n- [ ] task 11\n"
  write_note(dir, v2)

  -- Warming must be a no-op: digests/count no longer align.
  idx2:warm_chunk_cache(abs)
  assert_true(loaded._chunks[1].parsed_data == nil, "diverged warm leaves parsed_data nil")

  -- A subsequent update_file must still produce the correct entry.
  idx2:update_file(abs)
  local ref = full_reparse_reference(v1, v2)
  assert_entries_equal(idx2.files[NOTE], ref, "diverged-then-update")
end)

parser.parse_chunk = orig_parse_chunk

_H.finish({ style = "results", exit = "os" })
