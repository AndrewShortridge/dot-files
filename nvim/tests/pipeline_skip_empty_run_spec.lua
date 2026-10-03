-- Perf regression spec for issue: idle scroll dispatches a no-op full
-- pipeline.run that still scans line_set and calls apply_diff.
--
-- On scroll with no edit, line_tracker.consume returns an EMPTY (non-nil) dirty
-- list and nil shifts. The old code treated `{}` as truthy at
-- `if dirty_lines then`, fell through, and still paid for line_parse.update,
-- semantic.resolve and render.apply_diff — every O(N) walks that render nothing
-- (newly-visible regions on large buffers come from run_prefetch, not here).
--
-- The fix adds an early-return guard in transform_pipeline.M.run, gated by
-- config.pipeline.skip_empty_runs (default true):
--   not opts.full AND dirty_lines ~= nil AND #dirty_lines == 0 AND shifts == nil
--   AND not semantic.is_stale(buf, gen)  =>  stop() and return.
--
-- This spec drives the REAL transform_pipeline / semantic_resolution /
-- line_parse_cache / render_diff / line_tracker modules against a real temp-vault
-- buffer (no mocks, no source-introspection).
--
-- Discriminating power (repo convention):
--   A. Default flag on, no-edit warm run => line_parse.update AND
--      render.apply_diff both stay at 0 calls (guard short-circuits).
--      Reverting the guard makes both fire => assertion A fails.
--   B. Guard is not over-eager: a {full=true} run still calls line_parse.update.
--   C. config.pipeline.skip_empty_runs = false restores the old behavior:
--      a no-edit run fires line_parse.update again.
--   D. Semantic-stale bypass: when the index generation changes (is_stale true),
--      a no-edit run MUST still re-resolve+render (line_parse.update fires), so
--      dropping the `not semantic.is_stale` clause is caught.
-- Verified manually: reverting the guard turns assertion A red, then restoring
-- it makes the suite green again.
--
-- Run with: nvim --headless -u NONE -l tests/pipeline_skip_empty_run_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

print("\n=== Pipeline skip-empty-run Perf Tests ===\n")

local pipeline = require("andrew.vault.transform_pipeline")
local semantic = require("andrew.vault.semantic_resolution")
local line_parse = require("andrew.vault.line_parse_cache")
local render = require("andrew.vault.render_diff")
local config = require("andrew.vault.config")

local function code_excl() return false end

-- Build a real markdown buffer in a temp vault with a wikilink/#tag/==hl==/[k:: v].
local function make_buffer(n)
  local vault = vim.fn.tempname()
  vim.fn.mkdir(vault, "p")
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, vault .. "/note.md")
  vim.bo[buf].filetype = "markdown"
  local lines = {}
  for i = 1, n do
    lines[#lines + 1] =
      "[[Target" .. i .. "]] #tag" .. i .. " ==hl" .. i .. "== [key" .. i .. ":: val]"
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- Warm a buffer so the NEXT line_tracker.consume returns an empty (non-nil)
-- dirty list with nil shifts, and the semantic cache is current.
--   1) attach -> first consume returns nil,nil (state.full) -> full render.
--   2) one {full=false} run drains; with no edits the following consume yields
--      {} , nil -- the exact no-op-scroll condition the guard targets.
local function warm(buf)
  pipeline.attach(buf)
  pipeline.run(buf, code_excl, { full = true })   -- full: nil dirty, renders
  pipeline.run(buf, code_excl, { full = false })  -- drains residual dirty
end

-- Counter-wrap line_parse.update and render.apply_diff; returns a restore fn and
-- a getter for the counts.
local function wrap_counters()
  local n_update, n_diff = 0, 0
  local real_update = line_parse.update
  local real_diff = render.apply_diff
  line_parse.update = function(...) n_update = n_update + 1; return real_update(...) end
  render.apply_diff = function(...) n_diff = n_diff + 1; return real_diff(...) end
  return function() line_parse.update = real_update; render.apply_diff = real_diff end,
         function() return n_update, n_diff end
end

local function cleanup(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  pipeline.detach(buf)
end

-- --------------------------------------------------------------------------
-- A. Default flag on: a no-edit run short-circuits before line_parse.update
--    and render.apply_diff.
-- --------------------------------------------------------------------------
test("no-op scroll run skips line_parse.update and render.apply_diff", function()
  local prev = config.pipeline.skip_empty_runs
  config.pipeline.skip_empty_runs = true
  local buf = make_buffer(6)
  warm(buf)

  local restore, counts = wrap_counters()
  local ok, err = pcall(function()
    pipeline.run(buf, code_excl, { full = false }) -- NO edit in between
  end)
  restore()
  assert_true(ok, "no-edit pipeline.run succeeded: " .. tostring(err))

  local n_update, n_diff = counts()
  assert_eq(n_update, 0, "line_parse.update NOT called on a no-op scroll run")
  assert_eq(n_diff, 0, "render.apply_diff NOT called on a no-op scroll run")

  cleanup(buf)
  config.pipeline.skip_empty_runs = prev
end)

-- --------------------------------------------------------------------------
-- B. Guard is not over-eager: a {full=true} run still renders.
-- --------------------------------------------------------------------------
test("full run is NOT skipped by the guard", function()
  local prev = config.pipeline.skip_empty_runs
  config.pipeline.skip_empty_runs = true
  local buf = make_buffer(6)
  warm(buf)

  local restore, counts = wrap_counters()
  pipeline.run(buf, code_excl, { full = true })
  restore()

  local n_update = counts()
  assert_true(n_update >= 1, "line_parse.update fired on a full run")

  cleanup(buf)
  config.pipeline.skip_empty_runs = prev
end)

-- --------------------------------------------------------------------------
-- C. Kill switch: disabling the gate restores the old (always-run) behavior.
-- --------------------------------------------------------------------------
test("skip_empty_runs=false restores the full no-op pipeline run", function()
  local prev = config.pipeline.skip_empty_runs
  local buf = make_buffer(6)
  config.pipeline.skip_empty_runs = true
  warm(buf)

  config.pipeline.skip_empty_runs = false
  local restore, counts = wrap_counters()
  pipeline.run(buf, code_excl, { full = false }) -- NO edit
  restore()

  local n_update = counts()
  assert_true(n_update >= 1,
    "with the gate off, line_parse.update fires even on a no-op run")

  cleanup(buf)
  config.pipeline.skip_empty_runs = prev
end)

-- --------------------------------------------------------------------------
-- D. Semantic-stale bypass: when the index generation changes, a no-edit run
--    MUST still re-resolve + render so links re-resolve after an index rebuild.
-- --------------------------------------------------------------------------
test("semantic-stale (index changed) is NOT short-circuited", function()
  local prev = config.pipeline.skip_empty_runs
  config.pipeline.skip_empty_runs = true
  local buf = make_buffer(6)
  warm(buf)

  -- Force staleness: invalidate the semantic cache for this buffer so
  -- is_stale(buf, gen) returns true on the next run.
  semantic.invalidate(buf)

  local restore, counts = wrap_counters()
  pipeline.run(buf, code_excl, { full = false }) -- NO edit, but stale
  restore()

  local n_update = counts()
  assert_true(n_update >= 1,
    "a stale (index-changed) no-edit run still re-parses/re-resolves")

  cleanup(buf)
  config.pipeline.skip_empty_runs = prev
end)

_H.finish({ style = "results", exit = "os" })
