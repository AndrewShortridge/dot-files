-- Spec for the async, batched WAL append in vault_index:_persist_delta.
--
-- Regression for the per-save WAL cost: _persist_delta used to do, on the UI
-- thread, a BLOCKING io.open("a") + a SEPARATE f:write(line.."\n") per record +
-- a blocking f:close(). The fix buffers the whole batch into ONE payload and
-- issues a SINGLE async vim.uv.fs_open/fs_write/fs_close. Behavior/output (the
-- on-disk WAL bytes and replay result) must stay identical.
--
-- This drives the REAL vault_index module against a temp vault (no mock).
-- Assertions are observable behavior only:
--   * ONE fs_open on the WAL per batch (not one per file) -- the discriminator
--   * the WAL holds exactly one newline-terminated JSON record per path
--   * the async batched WAL still replays correctly into a fresh index
--
-- Run with: nvim --headless -u NONE -l tests/vault_index_wal_async_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true =
  _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vi = require("andrew.vault.vault_index")

print("\n=== Vault Index WAL Async/Batched Tests ===\n")

local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

local function make_vault()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir, "notes/alpha.md", {
    "---", "title: Alpha", "---", "", "# Alpha", "", "Links to [[beta]].",
    "", "- [ ] do a thing #urgent [due:: 2026-02-01]",
  })
  write_file(dir, "notes/beta.md", {
    "---", "title: Beta", "---", "", "# Beta", "", "Back to [[alpha]].",
  })
  write_file(dir, "notes/gamma.md", {
    "---", "title: Gamma", "---", "", "# Gamma",
  })
  write_file(dir, "notes/delta.md", {
    "---", "title: Delta", "---", "", "# Delta",
  })
  return dir
end

local ALPHA = "notes/alpha.md"
local BETA = "notes/beta.md"
local GAMMA = "notes/gamma.md"
local DELTA = "notes/delta.md"

-- Wrap vim.uv.fs_open and count opens that target the given WAL path.
local function with_wal_open_counter(wal_path, fn)
  local orig = vim.uv.fs_open
  local count = 0
  vim.uv.fs_open = function(path, ...)
    if path == wal_path then count = count + 1 end
    return orig(path, ...)
  end
  local ok, err = pcall(fn, function() return count end)
  vim.uv.fs_open = orig
  if not ok then error(err) end
  return count
end

-- Poll the loop until `pred()` is true or timeout (writes are now async).
local function wait_until(pred, timeout_ms)
  local deadline = vim.uv.now() + (timeout_ms or 500)
  while vim.uv.now() < deadline do
    vim.uv.run("nowait")
    if pred() then return true end
    vim.wait(10, function() return false end)
  end
  return pred()
end

local function read_wal_lines(wal_path)
  local f = io.open(wal_path, "r")
  if not f then return {} end
  local raw = f:read("*a")
  f:close()
  local lines = {}
  for line in (raw):gmatch("([^\n]+)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

-- ===========================================================================
-- 1. DISCRIMINATOR: one WAL fs_open per batch, not one per file; the WAL holds
--    exactly one JSON record per path.
-- ===========================================================================
test("WAL append opens the file once per batch and writes one record per path", function()
  local dir = make_vault()
  local idx = vi.VaultIndex.new(dir)
  idx:build_sync()
  idx:persist_now() -- truncate WAL to empty (authoritative full index written)

  local wal_path = idx:_wal_path()
  assert_eq(#read_wal_lines(wal_path), 0, "WAL empty after persist_now")

  local open_count
  with_wal_open_counter(wal_path, function(get_count)
    -- One batch covering 3 changed paths + 1 deleted path.
    idx:_persist_delta({ ALPHA, BETA, GAMMA }, { DELTA })
    -- Pump the loop so the async open fires and the write/close complete.
    wait_until(function() return #read_wal_lines(wal_path) >= 4 end, 1000)
    open_count = get_count()
  end)

  -- THE FIX: exactly one open for the whole batch. Reintroducing a per-file
  -- blocking open/write/close makes this 4 (3 changed + 1 deleted) and fails.
  assert_eq(open_count, 1, "exactly one fs_open on the WAL for the whole batch")

  local lines = read_wal_lines(wal_path)
  assert_eq(#lines, 4, "WAL holds exactly 4 newline-terminated records")

  -- Every record decodes to a complete WAL op (byte format unchanged).
  local ops = {}
  for _, line in ipairs(lines) do
    local ok, rec = pcall(vim.json.decode, line)
    assert_true(ok and type(rec) == "table", "WAL record decodes to a table")
    ops[rec.path] = rec.op
  end
  assert_eq(ops[ALPHA], "set", "alpha is a set op")
  assert_eq(ops[BETA], "set", "beta is a set op")
  assert_eq(ops[GAMMA], "set", "gamma is a set op")
  assert_eq(ops[DELTA], "del", "delta is a del op")
end)

-- ===========================================================================
-- 2. REPLAY CORRECTNESS: the async batched WAL replays into a fresh index.
-- ===========================================================================
test("async batched WAL still replays into a fresh index with derived fields", function()
  local dir = make_vault()
  local idx = vi.VaultIndex.new(dir)
  idx:build_sync()
  idx:persist_now() -- truncate WAL

  local wal_path = idx:_wal_path()

  -- Mutate alpha on disk, then re-index it (single-file update -> WAL delta).
  write_file(dir, "notes/alpha.md", {
    "---", "title: Alpha Edited", "---", "", "# Alpha", "",
    "Links to [[beta]] and [[gamma]].",
  })
  idx:update_file(dir .. "/" .. ALPHA)

  -- Wait for the async WAL flush to land.
  assert_true(
    wait_until(function() return #read_wal_lines(wal_path) >= 1 end, 1000),
    "WAL delta flushed to disk"
  )

  -- Fresh index replays the WAL on top of the full index.
  local idx2 = vi.VaultIndex.new(dir)
  assert_true(idx2:load(), "load() succeeds")

  assert_true(idx2.files[ALPHA] ~= nil, "alpha present after replay")
  assert_eq(idx2.files[ALPHA].frontmatter.title, "Alpha Edited", "WAL mutation replayed")
  assert_eq(idx2.files[ALPHA].rel_stem, "notes/alpha", "derived rel_stem rebuilt after replay")

  -- Live entry keeps derived fields after the WAL delta (no mutation).
  assert_eq(idx.files[ALPHA].rel_stem, "notes/alpha", "live rel_stem intact after WAL delta")
end)

_H.finish({ style = "results", exit = "os" })
