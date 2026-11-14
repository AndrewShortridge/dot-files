-- Perf regression spec: semantic_resolution reuses resolved-token wrappers on
-- unchanged token-array OBJECT IDENTITY (plus index generation for wikilink
-- lines), so a FULL resolve (per save / cold open) no longer re-wraps every
-- token into fresh ResolvedToken tables for lines whose text did not change.
--
-- line_parse_cache.get_line_tokens hands back the IDENTICAL table object for an
-- unchanged line on a full parse (content_dedup), so semantic_resolution keys
-- a per-buffer wrapper cache on that object identity:
--   - pure-passthrough lines (no wikilink) never read the index => reuse on
--     identity UNCONDITIONALLY.
--   - wikilink-bearing lines also require the index generation to match (link
--     targets can change without the line text changing).
--
-- Drives the REAL semantic_resolution + line_parse_cache modules against a real
-- temp-vault buffer (no mocks, no source-introspection).
--
-- Discriminating power (repo convention):
--   1. PARITY/REUSE: revert the reuse guard (always rebuild) => the same-object
--      identity assertion in test 1 fails (a fresh list each run).
--   3. GEN SENSITIVITY: drop the `lg == cur_gen` condition (reuse link lines
--      across a gen bump) => the link-line rebuild assertion in test 3 fails.
-- Verified manually: reintroducing either bug turns the corresponding
-- assertion red, then reverting restores green.
--
-- Run with: nvim --headless -u NONE -l tests/semantic_resolution_wrapper_reuse_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, deep_equal =
  _H.test, _H.assert_eq, _H.assert_true, _H.deep_equal

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

print("\n=== semantic_resolution wrapper-reuse Perf Tests ===\n")

local parse_cache = require("andrew.vault.line_parse_cache")
local semantic = require("andrew.vault.semantic_resolution")

local function code_excl() return false end

--- Build a real markdown buffer in a temp vault with a mix of:
---   row 0: prose only (no wikilink/tag)               -> passthrough, no link
---   row 1: wikilink-heavy                             -> link-bearing
---   row 2: tag + highlight + inline field (no link)   -> passthrough/tag-only
local function make_buffer()
  local vault = vim.fn.tempname()
  vim.fn.mkdir(vault, "p")
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, vault .. "/note.md")
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "just some prose with no links here",
    "see [[Target A]] and [[Target B|alias]] for details",
    "#topic ==important== [status:: open]",
  })
  return buf
end

-- A minimal index stub carrying just the _generation that semantic.resolve
-- reads (link resolution itself goes through wikilinks.resolve_link).
local function fake_index(gen) return { _generation = gen } end

--- Deep-snapshot the resolved list for a line: status/target/metadata + token
--- type so a parity comparison is structural, not identity-based.
local function snapshot(list)
  local out = {}
  for i, rt in ipairs(list) do
    out[i] = {
      status = rt.status,
      target = rt.target,
      line_nr = rt.line_nr,
      metadata = rt.metadata,
      token_type = rt.token and rt.token.type,
    }
  end
  return out
end

-- --------------------------------------------------------------------------
-- 1. PARITY + REUSE: a second full resolve with NO change yields a
--    structurally identical snapshot AND reuses the EXACT prior list object
--    for every (non-empty) line.
-- --------------------------------------------------------------------------
test("warm full resolve reuses prior wrappers verbatim (identity) with identical output", function()
  local buf = make_buffer()
  parse_cache.update(buf, nil, code_excl)
  local idx = fake_index(1)

  semantic.resolve(buf, nil, parse_cache, idx)
  local snaps, lists = {}, {}
  for ln = 0, 2 do
    local r = semantic.get_resolved(buf, ln)
    snaps[ln] = snapshot(r)
    lists[ln] = r
  end
  -- The wikilink row and the tag/highlight/field row must produce real tokens.
  assert_true(#lists[1] >= 1, "wikilink row resolved at least one token")
  assert_true(#lists[2] >= 1, "tag/highlight/field row resolved at least one token")

  -- Second full resolve, no edit, same generation.
  semantic.resolve(buf, nil, parse_cache, idx)
  for ln = 0, 2 do
    local r2 = semantic.get_resolved(buf, ln)
    assert_true(deep_equal(snapshot(r2), snaps[ln]),
      "row " .. ln .. " output is structurally identical across warm full resolves")
    assert_true(r2 == lists[ln],
      "row " .. ln .. " resolved list is the SAME object (wrappers reused, not re-allocated)")
  end

  vim.api.nvim_buf_delete(buf, { force = true })
  semantic.invalidate(buf)
  parse_cache.invalidate(buf)
end)

-- --------------------------------------------------------------------------
-- 2. MISS AFTER EDIT: editing one line's text rebuilds THAT line (new object)
--    while untouched lines keep their reused object.
-- --------------------------------------------------------------------------
test("edited line is rebuilt (new object); untouched lines are reused (same object)", function()
  local buf = make_buffer()
  parse_cache.update(buf, nil, code_excl)
  local idx = fake_index(1)
  semantic.resolve(buf, nil, parse_cache, idx)

  local prose0 = semantic.get_resolved(buf, 0)
  local link1 = semantic.get_resolved(buf, 1)

  -- Edit row 0's text, reparse just that line (incremental), re-resolve full.
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "prose changed entirely now" })
  parse_cache.update(buf, { 0 }, code_excl)
  semantic.resolve(buf, nil, parse_cache, idx)

  local prose0_after = semantic.get_resolved(buf, 0)
  local link1_after = semantic.get_resolved(buf, 1)

  assert_true(prose0_after ~= prose0,
    "edited row 0 was rebuilt (token array is a new object => cache miss)")
  assert_true(link1_after == link1,
    "untouched row 1 was reused (same object => cache hit)")

  vim.api.nvim_buf_delete(buf, { force = true })
  semantic.invalidate(buf)
  parse_cache.invalidate(buf)
end)

-- --------------------------------------------------------------------------
-- 3. MISS AFTER GEN BUMP: a wikilink-bearing line is REBUILT across a
--    generation bump (link targets may have changed) while a pure-prose line
--    (no link) is REUSED — proving link lines are gen-sensitive and
--    passthrough lines are not.
-- --------------------------------------------------------------------------
test("gen bump rebuilds link lines but reuses passthrough lines", function()
  local buf = make_buffer()
  parse_cache.update(buf, nil, code_excl)

  semantic.resolve(buf, nil, parse_cache, fake_index(1))
  local prose0 = semantic.get_resolved(buf, 0) -- no link
  local link1 = semantic.get_resolved(buf, 1) -- has wikilinks
  local tag2 = semantic.get_resolved(buf, 2) -- tag/highlight/field, no link

  -- Bump the generation; token arrays are unchanged (no edit/reparse).
  semantic.resolve(buf, nil, parse_cache, fake_index(2))
  local prose0_after = semantic.get_resolved(buf, 0)
  local link1_after = semantic.get_resolved(buf, 1)
  local tag2_after = semantic.get_resolved(buf, 2)

  assert_true(link1_after ~= link1,
    "wikilink-bearing row 1 was REBUILT across the gen bump (gen-sensitive)")
  assert_true(prose0_after == prose0,
    "pure-prose row 0 was REUSED across the gen bump (gen-insensitive)")
  assert_true(tag2_after == tag2,
    "tag/highlight/field row 2 (no link) was REUSED across the gen bump")

  vim.api.nvim_buf_delete(buf, { force = true })
  semantic.invalidate(buf)
  parse_cache.invalidate(buf)
end)

_H.finish({ style = "results", exit = "os" })
