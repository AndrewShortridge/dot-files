-- Perf regression spec for the embed build_descriptors has_token gate.
--
-- render_embeds() runs on every BufEnter/TextChanged for the current buffer.
-- build_descriptors() iterates the pipeline parse cache (lpc.pipeline_token_iter,
-- which lazily builds a sorted line-number list via vim.tbl_keys + table.sort)
-- to find embed tokens. On a buffer that has NO embeds — but whose embed state
-- is already `visible` (e.g. embeds were removed after a prior render) — the
-- upstream state.has_embeds() prefilter is bypassed, so build_descriptors used
-- to run the full token iteration (and its sort) every render even though the
-- warm parse cache already knows there are zero embed tokens.
--
-- The fix adds an O(1) has_token("embed") gate inside build_descriptors: when
-- the parse cache is warm and reports zero embed tokens, the iteration (and its
-- sort) is skipped entirely. Output is byte-identical (no embed tokens => no
-- descriptors either way).
--
-- This drives the REAL embed.render_embeds against a temp vault buffer whose
-- parse cache has been warmed via the REAL line_parse_cache.update(), and
-- asserts at the lpc seam that:
--   * embed-FREE warm buffer  -> pipeline_token_iter("embed") called 0 times,
--                                table.sort observed 0 times for the warm cache.
--   * embed-bearing warm buffer -> pipeline_token_iter("embed") IS called
--                                (proves the gate does not over-skip, and that
--                                the iter/sort seam is actually exercised — i.e.
--                                the "0 times" assertion has discriminating
--                                power).
-- Reintroducing the bug (removing the gate) makes the embed-free case call
-- pipeline_token_iter >= 1 time, failing this spec.
--
-- Run with: nvim --headless -u NONE -l tests/embed_has_token_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local lpc = require("andrew.vault.line_parse_cache")
local embed = require("andrew.vault.embed")
local embed_state = require("andrew.vault.embed_state")
local engine = require("andrew.vault.engine")

print("\n=== Embed has_token Gate Perf Tests ===\n")

-- A trivial code-exclusion predicate: nothing is inside a code span/block.
local function no_code_excl() return false end

-- Create a scratch buffer named inside a temp "vault" so engine.is_vault_buf
-- returns true, seed it with `lines`, and warm the REAL pipeline parse cache
-- for it via line_parse_cache.update (the same store lpc.has_token /
-- lpc.pipeline_token_iter read through pipeline.get_parse_cache()).
local function make_warm_vault_buf(lines)
  local vault = vim.fn.tempname()
  vim.fn.mkdir(vault, "p")
  engine.vault_path = vault

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, vault .. "/note.md")
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Warm the parse cache with a full parse (token_counters populated).
  lpc.update(buf, nil, no_code_excl)
  return buf
end

-- Run embed.render_embeds({ force = true }) on `buf` while counting how many
-- times lpc.iter_tokens is invoked for the "embed" token type (via the
-- pipeline_token_iter seam build_descriptors uses) and how many of those
-- invocations had to run table.sort on the lazily-built sorted line list.
-- The render's operation_fn runs synchronously (request_coalescer pcalls it
-- inline), so the counts are observed after the call returns. All spies are
-- restored in every path.
local function render_and_count(buf)
  -- Bypass the upstream state.has_embeds() regex prefilter so execution always
  -- reaches build_descriptors: mark the buffer's embed state visible. This is
  -- exactly the "previously had embeds, now has none" hot path the fix targets.
  local bst = embed_state.get_buf_state(buf)
  bst.visible = true

  local iter_calls = 0
  local sort_calls_in_iter = 0

  local orig_iter = lpc.iter_tokens
  local orig_sort = table.sort

  -- Scope the table.sort spy to only the dynamic extent of iter_tokens so it
  -- observes the sorted-line-number build inside iter_tokens (the work the fix
  -- elides) and ignores unrelated sorts elsewhere in the render path.
  local in_iter = false
  table.sort = function(...)
    if in_iter then sort_calls_in_iter = sort_calls_in_iter + 1 end
    return orig_sort(...)
  end

  lpc.iter_tokens = function(b, ttype)
    if b == buf and ttype == "embed" then
      iter_calls = iter_calls + 1
    end
    in_iter = true
    local ok_i, r1 = pcall(orig_iter, b, ttype)
    in_iter = false
    if not ok_i then error(r1) end
    return r1
  end

  local ok, err = pcall(embed.render_embeds, { force = true })

  table.sort = orig_sort
  lpc.iter_tokens = orig_iter

  if not ok then error(err) end
  return iter_calls, sort_calls_in_iter
end

-- ---------------------------------------------------------------------------
-- Embed-FREE warm buffer: the gate must skip pipeline_token_iter entirely
-- (and therefore never reach the tbl_keys + table.sort inside iter_tokens).
-- ---------------------------------------------------------------------------
test("warm embed-free buffer skips pipeline_token_iter (and its sort)", function()
  local buf = make_warm_vault_buf({
    "Just some plain prose.",
    "A [[wikilink]] and a #tag, but no embeds at all.",
    "More prose here.",
  })

  -- Sanity: the warm cache really does report zero embed tokens (O(1) gate input).
  local cache_warm, has_embed = lpc.has_token(buf, "embed")
  assert_true(cache_warm, "expected parse cache to be warm after update()")
  assert_eq(has_embed, false, "expected zero embed tokens in an embed-free buffer")

  local iter_calls, sort_calls = render_and_count(buf)

  assert_eq(iter_calls, 0, "build_descriptors must not iterate embed tokens on a warm embed-free buffer")
  assert_eq(sort_calls, 0, "build_descriptors must not sort cached line numbers on a warm embed-free buffer")
end)

-- ---------------------------------------------------------------------------
-- Companion: a warm embed-BEARING buffer whose sorted line-number cache was
-- invalidated by the full parse DOES run table.sort inside iter_tokens. This
-- proves the table.sort-inside-iter_tokens spy is wired correctly, so the
-- "0 sorts" assertion above has real discriminating power.
-- ---------------------------------------------------------------------------
test("warm buffer with embeds runs the iter_tokens sort (spy is wired)", function()
  local buf = make_warm_vault_buf({
    "Intro prose.",
    "![[Some Note]]",
    "Outro prose.",
  })
  local iter_calls, sort_calls = render_and_count(buf)
  assert_true(iter_calls >= 1, "expected iter_tokens to be entered for an embed-bearing buffer")
  assert_true(sort_calls >= 1, "expected the lazy sorted-line build (table.sort) inside iter_tokens")
end)

-- ---------------------------------------------------------------------------
-- Embed-bearing warm buffer: the gate must NOT over-skip — pipeline_token_iter
-- IS called. This proves the seam is actually exercised by render_embeds, so
-- the "0 calls" assertion above has real discriminating power.
-- ---------------------------------------------------------------------------
test("warm buffer with embeds still iterates embed tokens", function()
  local buf = make_warm_vault_buf({
    "Intro prose.",
    "![[Some Note]]",
    "Outro prose.",
  })

  local cache_warm, has_embed = lpc.has_token(buf, "embed")
  assert_true(cache_warm, "expected parse cache to be warm after update()")
  assert_eq(has_embed, true, "expected the embed token to be counted")

  local iter_calls = render_and_count(buf)
  assert_true(iter_calls >= 1, "build_descriptors must iterate embed tokens when the buffer has embeds")
end)

_H.finish({ style = "results", exit = "os" })
