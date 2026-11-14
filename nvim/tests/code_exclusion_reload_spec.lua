-- Regression spec for build_code_exclusion across a buffer RELOAD.
--
-- BUG (reported): editing in a markdown vault buffer that had been reloaded
-- (`:edit!`, external-change auto-reload, or a filesystem-watcher-driven refresh)
-- crashed with:
--   link_scan.lua:327: Invalid 'start': Number is not integral
-- via has_indented_create -> nvim_buf_get_lines(bufnr, dmin - 1, ...).
--
-- ROOT CAUSE: a reload advances the buffer's changedtick but fires NO on_bytes
-- (it fires on_reload instead, which the private attach did not handle). So the
-- dirty accumulator stayed empty (dmin = math.huge, dmax = -1) while the cached
-- range set's tick no longer matched. build_code_exclusion's memo-hit fast path
-- requires entry.tick == tick (false after reload), and its full-rebuild path
-- only fired on a cold cache or d.full — so execution fell into the INCREMENTAL
-- path with dmin = math.huge, feeding inf into nvim_buf_get_lines.
--
-- FIX (two complementary guards):
--   1. on_reload handler sets d.full = true -> next build does a full rescan.
--   2. build_code_exclusion treats an empty dirty span (d.dmax < d.dmin) on a
--      tick mismatch as a full rebuild, covering ANY tick advance with no
--      on_bytes (not just reload).
--
-- DISCRIMINATING POWER (verified manually): revert either guard and the first
-- post-reload build_code_exclusion call raises the non-integral error -> the
-- "no crash" assertion below fails. Parity against a fresh whole-buffer
-- recompute guards against the reload silently retaining stale ranges.
--
-- Run with: nvim --headless -u NONE -l tests/code_exclusion_reload_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_true, assert_eq = _H.test, _H.assert_true, _H.assert_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local link_scan = require("andrew.vault.link_scan")

print("\n=== Code-Exclusion Reload Regression ===\n")

-- Assert two closures agree on every row (and representative cols) of the buffer.
local function assert_closures_agree(buf, got, want)
  local n = vim.api.nvim_buf_line_count(buf)
  for row = 0, n - 1 do
    local line = (vim.api.nvim_buf_get_lines(buf, row, row + 1, false))[1] or ""
    local cols = { 0, 1, math.max(0, #line - 1), #line + 5 }
    for _, col in ipairs(cols) do
      assert_eq(
        got(row, col),
        want(row, col),
        string.format("mismatch at row %d col %d", row, col)
      )
    end
  end
end

local function write_file(path, lines)
  local fh = assert(io.open(path, "w"))
  fh:write(table.concat(lines, "\n") .. "\n")
  fh:close()
end

-- ---------------------------------------------------------------------------
-- The reported crash: edit a file, seed the cache, change the file on disk,
-- then an autoread `:checktime` reload (fires on_reload ONLY — no on_detach, no
-- on_bytes — so the dirty accumulator stays alive AND empty while changedtick
-- advances), then rebuild. This is the exact path the filesystem watcher hits
-- (`:edit!` instead fires on_detach, which masks the bug by forcing a re-attach).
-- ---------------------------------------------------------------------------
test("rebuild after autoread reload does not crash and matches recompute", function()
  vim.o.autoread = true
  local path = vim.fn.tempname() .. ".md"

  local initial = {
    "# Title",
    "intro prose with a `code span`",
    "",
    "before fence",
    "```lua",
    "local x = 1",
    "local y = 2",
    "```",
    "after prose line",
    "more prose `another span` here",
  }
  write_file(path, initial)

  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  pcall(vim.treesitter.get_parser, buf, "markdown")

  -- Seed the incremental cache (records entry.tick).
  link_scan.build_code_exclusion(buf)

  -- Change the file on disk (different line count + shifted fence) so the
  -- reload genuinely replaces buffer content.
  local reloaded = {
    "# Title (edited externally)",
    "added a brand new intro line",
    "intro prose with a `code span`",
    "",
    "before fence",
    "```python",
    "x = 1",
    "y = 2",
    "z = 3",
    "```",
    "after prose line",
    "more prose `another span` here",
    "trailing prose line",
  }
  -- A newer mtime is required for :checktime to notice the external change.
  vim.fn.system({ "sleep", "1" })
  write_file(path, reloaded)

  -- Reload from disk via autoread: fires on_reload (NOT on_bytes / on_detach),
  -- advancing changedtick while the dirty accumulator stays alive and empty.
  vim.cmd("checktime")
  pcall(vim.treesitter.get_parser, buf, "markdown")

  -- The reported crash happened HERE. Must not raise.
  local ok, result = pcall(link_scan.build_code_exclusion, buf)
  assert_true(ok, "build_code_exclusion crashed after reload: " .. tostring(result))
  assert_true(type(result) == "function", "build returned a closure after reload")

  -- Parity: the post-reload closure must match a fresh whole-buffer recompute
  -- everywhere (no stale pre-reload ranges retained).
  link_scan.clear_cache(buf)
  local reference = link_scan.build_code_exclusion(buf)
  assert_closures_agree(buf, result, reference)

  -- The reloaded fence body (0-indexed rows 5..9) must read as in-code; a far
  -- prose row must not.
  assert_true(result(6, 0), "reloaded fence body row not excluded")
  assert_true(not result(0, 0), "reloaded heading row wrongly excluded")

  vim.cmd("bwipeout!")
  os.remove(path)
end)

_H.finish({ style = "results", exit = "os" })
