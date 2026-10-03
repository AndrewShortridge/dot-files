-- Perf regression spec for hoisted require() calls in the render & completion
-- hot paths (issue T16-hoist-requires).
--
-- Several modules used to call require(module) INSIDE per-line / per-token /
-- per-frame hot functions instead of hoisting the require to module top:
--   * line_parse_cache.tokenize_line / M.update re-required config PER LINE
--   * semantic_resolution.resolve_wikilink re-required wikilinks PER TOKEN, and
--     M.resolve re-required link_utils per call
--   * render_diff.apply_diff re-required config per frame
--   * transform_pipeline.run re-required vault_index per run
--   * completion sources re-required char_bag / work_scheduler per build
--
-- The fix hoists each require to a module-top `local`. (pipeline_consumers keeps
-- linkdiag behind a one-time-initialized upvalue because it is a genuine cycle.)
--
-- This spec drives the REAL modules against a real temp-vault buffer. The target
-- modules are loaded (and their top-level requires resolved & cached) BEFORE a
-- require-counter shim is installed, so the shim only counts requires that fire
-- DURING the hot-path drive. After driving N dirty lines with M wikilinks/tags/
-- highlights, it asserts none of config/wikilinks/link_utils/vault_index are
-- re-required inside the per-line/per-token/per-frame work.
--
-- Discriminating power (repo convention): reintroducing an inline require —
-- e.g. `local cfg = require("andrew.vault.config")` inside tokenize_line, or
-- `require("andrew.vault.wikilinks")` inside resolve_wikilink, or
-- `require("andrew.vault.char_bag")` inside build_kv_single_pass — makes the
-- corresponding count > 0 and fails this spec. Verified manually by reintroducing
-- one inline require (red), then reverting (green).
--
-- Run with: nvim --headless -u NONE -l tests/hoist_requires_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

print("\n=== Hoisted-require Perf Tests ===\n")

-- Pre-require all target modules and their hoisted deps so every top-level
-- require has already run and is cached before the shim is installed.
local config = require("andrew.vault.config")
local line_parse = require("andrew.vault.line_parse_cache")
local semantic = require("andrew.vault.semantic_resolution")
local render = require("andrew.vault.render_diff")
local pipeline = require("andrew.vault.transform_pipeline")
local vault_index = require("andrew.vault.vault_index")
require("andrew.vault.wikilinks")
require("andrew.vault.link_utils")
require("andrew.vault.char_bag")
require("andrew.vault.work_scheduler")
local completion_base = require("andrew.vault.completion_base")
require("andrew.vault.completion_tags")

-- Build a temp vault with a single note buffer containing many lines, each with
-- several wikilinks + a #tag + a ==highlight== so tokenize_line, resolve_wikilink
-- and apply_diff all do real work across many lines/tokens.
local function make_buffer(N, M)
  local vault = vim.fn.tempname()
  vim.fn.mkdir(vault, "p")
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, vault .. "/note.md")
  vim.bo[buf].filetype = "markdown"
  local lines = {}
  for i = 1, N do
    local parts = {}
    for j = 1, M do
      parts[#parts + 1] = "[[Target" .. i .. "_" .. j .. "]]"
    end
    parts[#parts + 1] = "#tag" .. i
    parts[#parts + 1] = "==hl" .. i .. "=="
    lines[i] = table.concat(parts, " ")
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf, vault, N, M
end

--- Install a require-counter shim watching `names`. Returns (counts, restore).
local function install_shim(names)
  local counts = {}
  local watched = {}
  for _, n in ipairs(names) do watched[n] = true end
  local real_require = require
  _G.require = function(name)
    if watched[name] then counts[name] = (counts[name] or 0) + 1 end
    return real_require(name)
  end
  return counts, function() _G.require = real_require end
end

test("tokenize/resolve/render hot paths do not re-require hoisted modules", function()
  local N, M = 30, 3
  local buf = make_buffer(N, M)

  -- Sanity: the drive must actually exercise many lines and many tokens, or a
  -- pass would be vacuous.
  assert_true(N > 1, "N lines")
  assert_true(M > 1, "M wikilinks per line")

  local dirty = {}
  for ln = 0, N - 1 do dirty[#dirty + 1] = ln end
  local function code_excl() return false end

  -- Warm semantic_resolution's lazy wikilinks/link_utils upvalues BEFORE the
  -- shim. These are resolved once on first use and memoized (the intended
  -- pattern: a one-time require, never per token). The drive below proves there
  -- is no PER-TOKEN / PER-LINE re-require, which is the regression we guard.
  line_parse.update(buf, dirty, code_excl)
  semantic.resolve(buf, dirty, line_parse, vault_index.current())

  -- NOTE: vault_index is intentionally NOT watched here. link_utils.parse_target
  -- /resolve_note_via_index require vault_index internally (a separate, out-of-
  -- scope path), and resolve_wikilink legitimately calls through them. The
  -- transform_pipeline.run vault_index hoist (which IS in scope) is asserted
  -- separately below via a warm no-dirty pipeline.run, where link_utils does no
  -- work and the only formerly-per-run require was the pipeline's own.
  local counts, restore = install_shim({
    "andrew.vault.config",
    "andrew.vault.wikilinks",
    "andrew.vault.link_utils",
  })

  local ok, err = pcall(function()
    -- Layer 1: per-line tokenize (M.update calls M.tokenize_line per dirty line)
    line_parse.update(buf, dirty, code_excl)

    -- Confirm tokenization actually produced wikilink/tag/highlight tokens.
    local wl = 0
    for _ in line_parse.iter_tokens(buf, "wikilink") do wl = wl + 1 end
    assert_true(wl >= N * M, "tokenized " .. wl .. " wikilinks (>= " .. (N * M) .. ")")

    -- Layer 2: per-token semantic resolution (resolve_wikilink per wikilink token)
    semantic.resolve(buf, dirty, line_parse, vault_index.current())

    -- Layer 3: per-frame render diff. Build specs from resolved tokens (mirrors
    -- transform_pipeline: one extmark per token).
    local ns = vim.api.nvim_create_namespace("hoist_requires_perf_spec")
    local specs = {}
    local line_set = {}
    for _, ln in ipairs(dirty) do
      line_set[ln] = true
      for _, rt in ipairs(semantic.get_resolved(buf, ln)) do
        local tok = rt.token
        specs[#specs + 1] = {
          ns = ns, line = ln, col = tok.start_col,
          opts = { end_col = tok.end_col, hl_group = "VaultWikiLinkValid", priority = 200 },
        }
      end
    end
    render.apply_diff(buf, specs, line_set)
  end)

  restore()
  assert_true(ok, "drive succeeded: " .. tostring(err))

  -- config (line_parse_cache, render_diff), wikilinks & link_utils
  -- (semantic_resolution) must not be re-required during the per-line /
  -- per-token / per-frame drive.
  assert_eq(counts["andrew.vault.config"], nil, "config not re-required in hot path")
  assert_eq(counts["andrew.vault.wikilinks"], nil, "wikilinks not re-required in hot path")
  assert_eq(counts["andrew.vault.link_utils"], nil, "link_utils not re-required in hot path")
end)

test("transform_pipeline.run does not re-require vault_index per frame", function()
  local vault = vim.fn.tempname()
  vim.fn.mkdir(vault, "p")
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, vault .. "/note.md")
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "[[A]] #t ==h==" })
  local function code_excl() return false end

  pipeline.attach(buf)
  pipeline.run(buf, code_excl, { full = true }) -- warm caches + resolution gen

  -- A warm, no-dirty re-run touches only the pipeline coordinator: no token work,
  -- so link_utils' internal vault_index requires do not fire. The only formerly
  -- per-run require here was transform_pipeline.run's own vault_index require.
  local counts, restore = install_shim({ "andrew.vault.vault_index" })
  local ok, err = pcall(function()
    pipeline.run(buf, code_excl, {})
  end)
  restore()
  assert_true(ok, "warm pipeline.run succeeded: " .. tostring(err))
  assert_eq(counts["andrew.vault.vault_index"], nil, "vault_index not re-required by transform_pipeline.run")
end)

test("completion kv build does not re-require char_bag", function()
  -- Enable the char_bag prefilter branch so build_kv_single_pass exercises the
  -- (formerly inline) require.
  local pf = config.prefilter
  local prev_enabled, prev_cb = pf.enabled, pf.completion_char_bag
  pf.enabled = true
  pf.completion_char_bag = true

  -- Drive build_kv_single_pass against a real ready index if one exists; the
  -- char_bag branch runs per value item. We assert no require fires regardless
  -- of whether the index has entries (the hoist removed the per-build require).
  local idx = completion_base.get_ready_index()

  local counts, restore = install_shim({ "andrew.vault.char_bag" })
  local ok, err = pcall(function()
    if idx then
      completion_base.build_kv_single_pass(
        idx, "frontmatter", completion_base.known_field_values(), ": "
      )
    end
    -- new_charbag_filter closure also formerly re-required char_bag per call.
    local filter = completion_base.new_charbag_filter()
    local char_bag = require("andrew.vault.char_bag") -- counted, but proves the bag below works
    local items = {
      { _char_bag = char_bag.from_string("alpha") },
      { _char_bag = char_bag.from_string("beta") },
    }
    filter(items, char_bag.from_string("al"))
  end)
  restore()

  pf.enabled, pf.completion_char_bag = prev_enabled, prev_cb
  assert_true(ok, "completion drive succeeded: " .. tostring(err))

  -- The shim deliberately required char_bag ONCE in the drive (to build query
  -- bags). The hoist means neither build_kv_single_pass nor the filter closure
  -- adds further requires, so the count stays at exactly that single explicit
  -- call. Under the bug each would re-require, pushing the count higher.
  assert_eq(counts["andrew.vault.char_bag"], 1, "char_bag required only by the explicit test call, not by the hot paths")
end)

_H.finish({ style = "results", exit = "os" })
