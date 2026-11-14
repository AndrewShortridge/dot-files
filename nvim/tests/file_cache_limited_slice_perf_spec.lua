-- Perf/correctness spec for lua/andrew/vault/file_cache.lua M.read
-- A cached UNLIMITED read must also serve a subsequent LIMITED read by
-- slicing the cached array (no redundant disk read), returning a FRESH
-- table so downstream truncated-marker appends never mutate the cache.
-- Run with: nvim --headless -u NONE -l tests/file_cache_limited_slice_perf_spec.lua
--
-- DISCRIMINATING POWER: revert M.read's cache check to
--   `if cached and cached.mtime == mtime and not max_lines then`
-- and the "limited read served from cache" io.open-count assertion fails
-- (the count climbs to 2), proving this spec catches the regression.

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local file_cache = require("andrew.vault.file_cache")

print("\n=== file_cache limited-slice perf Tests ===\n")

local N = 30
local LIMIT = 20

local function write_file(path, n, marker)
  local lines = {}
  for i = 1, n do
    lines[i] = (marker or "line") .. "-" .. i
  end
  vim.fn.writefile(lines, path)
end

local path = vim.fn.tempname()
write_file(path, N)

-- io.open counter shim (cited measurement method; no source introspection).
local real_open = io.open
local open_count = 0
io.open = function(p, ...)
  if p == path then
    open_count = open_count + 1
  end
  return real_open(p, ...)
end

test("warm unlimited read populates cache with full array (1 io.open)", function()
  file_cache.clear()
  open_count = 0
  local full = file_cache.read(path)
  assert_true(full ~= nil, "warm unlimited read returned content")
  assert_eq(#full, N, "warm read has all N lines")
  assert_eq(open_count, 1, "warm read opened the file exactly once")
end)

test("limited read is served from cached full entry — no new io.open", function()
  -- CORE assertion. Pre-fix this falls through to io.open (count becomes 2).
  local limited = file_cache.read(path, LIMIT)
  assert_eq(#limited, LIMIT, "limited read returns exactly LIMIT lines")
  assert_eq(open_count, 1, "limited read served from cache, no new io.open")
end)

test("slice is the correct prefix of the full content", function()
  local limited = file_cache.read(path, LIMIT)
  assert_eq(limited[1], "line-1", "limited[1] is first line")
  assert_eq(limited[LIMIT], "line-" .. LIMIT, "limited[LIMIT] is the LIMIT-th line")
  assert_eq(open_count, 1, "second limited read also served from cache")
end)

test("slice mutation does not corrupt the cached full array", function()
  local limited = file_cache.read(path, LIMIT)
  limited[#limited + 1] = "(truncated)"
  local full2 = file_cache.read(path)
  assert_eq(#full2, N, "cached full array unaffected by slice mutation")
  assert_eq(open_count, 1, "re-reading unlimited still served from cache")
end)

test("limit larger than file returns all lines, still from cache", function()
  local big = file_cache.read(path, N + 100)
  assert_eq(#big, N, "limit larger than file returns all N lines")
  assert_eq(open_count, 1, "oversized-limit read still served from cache")
end)

test("mtime change invalidates and forces a fresh disk read", function()
  write_file(path, N, "v2")
  local st = vim.uv.fs_stat(path)
  vim.uv.fs_utime(path, st.atime.sec + 5, st.mtime.sec + 5)
  local after = file_cache.read(path, LIMIT)
  assert_eq(open_count, 2, "mtime change forces a fresh disk read")
  assert_eq(after[1], "v2-1", "re-read reflects new file contents")
end)

-- Restore io.open and remove the temp file.
io.open = real_open
os.remove(path)

_H.finish({ style = "plain", exit = "os" })
