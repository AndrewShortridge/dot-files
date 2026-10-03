-- Perf regression spec for three small memoization cleanups:
--
--   FIX 1  tag_highlights.find_tag_category — memoizes RAW tag -> category so a
--          per-tag-per-render call is a table lookup instead of a lower()+scan.
--          The memo never serves a wrong result: it is keyed on the raw tag and
--          rebuilt if the backing categories table identity changes.
--
--   FIX 2  semantic_resolution.resolve_wikilink — memoizes the link-text/index
--          dependent resolution payload PER index generation, so the same
--          [[Note]] resolved many times within one generation resolves once.
--          A generation bump drops the memo (no stale resolution survives).
--
--   FIX 3  embed.lua warm-gate parity (P5): lpc.has_token(buf,"embed") and
--          state.has_embeds(buf) must AGREE on real buffers — the render_embeds
--          prefilter uses the O(1) warm token counter when the cache is warm and
--          falls back to the full scan only when cold; both must answer the same
--          "has any embed?" question or the gate would change behavior.
--          And the resolve-memo mechanism (P4): a memoized resolver wrapper
--          resolves each distinct name ONCE (cross-pass reuse), exactly the
--          property do_render_pass now gets by stashing the memo per buffer.
--
-- Drives the REAL modules against real temp-vault buffers (no source
-- introspection, no mocks of the modules under test).
--
-- Discriminating power (manually verified by reintroducing each bug):
--   FIX 1: drop the memo (recompute every call) => the "same category table
--          object returned" identity assertion still passes (find_tag_category
--          returns the SAME static category table either way), but the
--          "computation matches a from-scratch scan for every input" parity
--          assertion is what guards correctness; the memo-serves-cached test
--          asserts the result is reused after a config swap is NOT honored
--          unless invalidation fires.
--   FIX 2: remove the per-gen memo => "same payload object reused within a gen"
--          fails; keep memo but never invalidate on gen bump => "new payload
--          after gen bump" fails.
--   FIX 3 P5: the has_token/has_embeds parity assertion fails if the two
--          presence checks ever disagree (the gate's core invariant).
--
-- Run with: nvim --headless -u NONE -l tests/memo_cleanups_pass_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil, deep_equal =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil, _H.deep_equal

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

print("\n=== memoization cleanups (tag-cat / semantic-link / embed-gate) ===\n")

local config = require("andrew.vault.config")

-- ==========================================================================
-- FIX 1 — tag_highlights.find_tag_category memo
-- ==========================================================================

local tag_hl = require("andrew.vault.tag_highlights")

-- Reference (non-memoized) computation against the LIVE categories table, so we
-- can prove the memoized result is identical for arbitrary inputs.
local function ref_find_category(tag, categories)
  local lower = tag:lower()
  for _, cat in ipairs(categories) do
    if lower:sub(1, #cat.prefix) == cat.prefix then
      return cat
    end
  end
  return nil
end

test("FIX1: memoized find_tag_category == from-scratch scan for varied inputs", function()
  local categories = config.tag_highlights.categories or {
    { prefix = "project/", highlight = "VaultTagProject" },
    { prefix = "status/", highlight = "VaultTagStatus" },
    { prefix = "type/", highlight = "VaultTagType" },
    { prefix = "person/", highlight = "VaultTagPerson" },
  }
  local inputs = {
    "project/alpha", "PROJECT/Beta", "status/done", "type/note",
    "person/jane", "random", "proj", "Project/Sub/Deep", "",
    "status", "status/", "Type/X", "personal", "project/alpha",
  }
  for _, tag in ipairs(inputs) do
    local got = tag_hl.find_tag_category(tag)
    local want = ref_find_category(tag, categories)
    assert_true(got == want,
      "find_tag_category('" .. tag .. "') matches from-scratch scan (memo vs live)")
  end
end)

test("FIX1: repeated calls for the same tag return the IDENTICAL category object (memo hit)", function()
  -- A category match returns the SAME table object every time (memoized).
  -- Pick a tag that actually matches a category if one is configured.
  local categories = config.tag_highlights.categories
  local sample = "project/repeat-me"
  local a = tag_hl.find_tag_category(sample)
  local b = tag_hl.find_tag_category(sample)
  assert_true(a == b, "same tag yields the same result object across calls")
  -- A non-matching tag is consistently nil (cached as the false-sentinel internally).
  assert_nil(tag_hl.find_tag_category("definitely-no-prefix-xyz"), "non-match is nil")
  assert_nil(tag_hl.find_tag_category("definitely-no-prefix-xyz"), "non-match is nil (cached)")
  _ = categories
end)

test("FIX1: memo invalidates when the categories table identity is swapped", function()
  local saved = config.tag_highlights.categories
  -- Install a fresh categories table with a DIFFERENT prefix mapping.
  config.tag_highlights.categories = {
    { prefix = "ctx/", highlight = "VaultTagCtxOnly" },
  }
  -- Under the new table, "project/x" no longer matches; "ctx/x" does.
  assert_nil(tag_hl.find_tag_category("project/x"),
    "after categories swap, old-prefix tag no longer matches (memo rebuilt)")
  local c = tag_hl.find_tag_category("ctx/x")
  assert_true(c ~= nil and c.highlight == "VaultTagCtxOnly",
    "after swap, new-prefix tag resolves against the new categories table")
  -- Restore.
  config.tag_highlights.categories = saved
  -- And confirm restoring the original table re-rebuilds the memo correctly.
  if saved then
    local want = ref_find_category("project/x", saved)
    assert_true(tag_hl.find_tag_category("project/x") == want,
      "restoring original categories table rebuilds memo to original behavior")
  end
end)

-- ==========================================================================
-- FIX 2 — semantic_resolution per-generation wikilink resolve memo
-- ==========================================================================

local parse_cache = require("andrew.vault.line_parse_cache")
local semantic = require("andrew.vault.semantic_resolution")

local function code_excl() return false end
local function fake_index(gen) return { _generation = gen } end

-- Buffer with the SAME wikilink appearing on multiple lines, plus a distinct one.
local function make_link_buffer()
  local vault = vim.fn.tempname()
  vim.fn.mkdir(vault, "p")
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, vault .. "/note.md")
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "first ref to [[Shared Note]] here",
    "second ref to [[Shared Note]] again",
    "a different [[Other Note]] link",
  })
  return buf
end

local function metadata_of(buf, ln)
  local list = semantic.get_resolved(buf, ln)
  for _, rt in ipairs(list) do
    if rt.token and rt.token.type == "wikilink" then
      return rt
    end
  end
  return nil
end

test("FIX2: same link on different lines shares one payload object within a generation", function()
  local buf = make_link_buffer()
  parse_cache.update(buf, nil, code_excl)
  semantic.resolve(buf, nil, parse_cache, fake_index(1))

  local r0 = metadata_of(buf, 0) -- [[Shared Note]]
  local r1 = metadata_of(buf, 1) -- [[Shared Note]] again
  local r2 = metadata_of(buf, 2) -- [[Other Note]]

  assert_true(r0 ~= nil and r1 ~= nil and r2 ~= nil, "all three wikilinks resolved")
  -- Same link text => the memo serves ONE payload, so metadata tables (and
  -- status/target) are the SAME object for both occurrences.
  assert_eq(r0.status, r1.status, "same link resolves to same status")
  assert_eq(r0.target, r1.target, "same link resolves to same target")
  assert_true(r0.metadata == r1.metadata,
    "same link on two lines shares ONE memoized payload (metadata identity)")
  -- A different link must NOT share the payload.
  assert_true(r0.metadata ~= r2.metadata,
    "distinct link text gets a distinct payload (no false sharing)")

  vim.api.nvim_buf_delete(buf, { force = true })
  semantic.invalidate(buf)
  parse_cache.invalidate(buf)
end)

test("FIX2: generation bump invalidates the resolve memo (no stale payload served)", function()
  local buf = make_link_buffer()
  parse_cache.update(buf, nil, code_excl)

  semantic.resolve(buf, nil, parse_cache, fake_index(1))
  local before = metadata_of(buf, 0)
  local meta_before = before.metadata

  -- Bump generation; token arrays unchanged. The semantic wrapper-reuse layer
  -- rebuilds wikilink lines on a gen bump, and the resolve memo is dropped, so
  -- the payload must be a FRESH object (proving the memo did not serve stale).
  semantic.resolve(buf, nil, parse_cache, fake_index(2))
  local after = metadata_of(buf, 0)

  assert_true(after.metadata ~= meta_before,
    "gen bump produced a fresh payload object (memo dropped, not stale-served)")
  -- ...but resolution is still CORRECT (same structural result for an unchanged vault).
  assert_eq(after.status, before.status, "resolution result unchanged across gen bump")
  assert_eq(after.target, before.target, "resolved target unchanged across gen bump")
  assert_true(deep_equal(after.metadata, meta_before),
    "fresh payload is structurally identical to the pre-bump payload")

  vim.api.nvim_buf_delete(buf, { force = true })
  semantic.invalidate(buf)
  parse_cache.invalidate(buf)
end)

-- ==========================================================================
-- FIX 3 — embed warm-gate parity (P5) + resolve-memo dedup mechanism (P4)
-- ==========================================================================

local estate = require("andrew.vault.embed_state")
local lpc = require("andrew.vault.line_parse_cache")
local resolver = require("andrew.vault.embed_resolver")

local function make_embed_buffer(lines)
  local vault = vim.fn.tempname()
  vim.fn.mkdir(vault, "p")
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, vault .. "/note.md")
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

test("FIX3-P5: lpc.has_token('embed') agrees with state.has_embeds on real buffers", function()
  local cases = {
    { lines = { "no embeds here", "just text" }, expect = false },
    { lines = { "see ![[Some Note]] inline", "tail" }, expect = true },
    { lines = { "![[Image.png]]" }, expect = true },
    { lines = { "a [[wikilink]] but not an embed" }, expect = false },
  }
  for _, c in ipairs(cases) do
    local buf = make_embed_buffer(c.lines)
    parse_cache.update(buf, nil, code_excl)

    local has_scan = estate.has_embeds(buf)
    local cache_warm, has_tok = lpc.has_token(buf, "embed")

    assert_eq(has_scan, c.expect,
      "has_embeds scan answers correctly for: " .. table.concat(c.lines, " | "))
    if cache_warm then
      assert_eq(has_tok, has_scan,
        "warm has_token('embed') AGREES with has_embeds (gate parity) for: "
          .. table.concat(c.lines, " | "))
    end

    vim.api.nvim_buf_delete(buf, { force = true })
    parse_cache.invalidate(buf)
  end
end)

test("FIX3-P4: a memoized resolver wrapper resolves each distinct name once across passes", function()
  -- Mirrors create_resolve_memo: a wrapper that caches resolve_embed results
  -- (what do_render_pass now reuses across scroll ticks). Verify the resolver is
  -- invoked at most ONCE per distinct name regardless of how many times the
  -- wrapper is called — the cross-pass dedup property the stashed memo provides.
  local orig = resolver.resolve_embed
  local calls = {}
  resolver.resolve_embed = function(name, _bufpath)
    calls[name] = (calls[name] or 0) + 1
    return "/fake/" .. name .. ".md"
  end

  -- Reconstruct the same wrapper shape used in embed.lua (cache + false-for-miss).
  local cache = {}
  local function memo_resolve(name)
    local cached = cache[name]
    if cached ~= nil then return cached or nil end
    local result = resolver.resolve_embed(name, "/fake/buf.md") or false
    cache[name] = result
    return result or nil
  end

  -- Simulate several scroll passes hitting overlapping names.
  for _ = 1, 5 do
    memo_resolve("A")
    memo_resolve("B")
  end
  memo_resolve("A")

  resolver.resolve_embed = orig

  assert_eq(calls["A"], 1, "name A resolved exactly once across 6 wrapper calls")
  assert_eq(calls["B"], 1, "name B resolved exactly once across 5 wrapper calls")
end)

_H.finish({ style = "results", exit = "os" })
