-- Perf + correctness regression spec for andrew.vault.engine M.is_vault_buf.
--
-- On every insert-mode keystroke the consolidated TextChanged autocmd calls
-- engine.is_vault_buf(bufnr) (event_dispatch.lua), which goes through the
-- `_is_vault_check` memoize. The memo's version_fn USED to build a fresh
-- composite string per call:
--     vim.api.nvim_buf_get_name(bufnr) .. "|" .. (M.vault_path or "")
-- That string concat allocates a new (absolute-path-length) string every
-- keystroke just to compare for cache-hit equality -> GC pressure on
-- TextChangedI. The fix returns ONLY the buffer name as the version; vault
-- switches still invalidate correctly because switch_vault ->
-- invalidate_caches{scope="all"} clears this cache (both via its registered
-- invalidate AND memoize.clear_all()).
--
-- This spec drives the REAL engine + memoize modules against temp vaults
-- (no mocks):
--   Test 1 (load-bearing): vault-switch invalidation -- the invariant that
--           makes dropping vault_path from the version key SAFE. A buffer in
--           vault A is a vault buf; after switch_vault("B") it must NOT be,
--           and a buffer in vault B must flip false->true. Reintroducing a
--           broken variant (constant version + no clear-on-switch) makes the
--           post-switch assertions fail.
--   Test 2: hit-rate -- N repeated calls at a fixed (unchanged) buffer name
--           produce exactly one miss + (N-1) hits, proving the bare-name
--           version is a STABLE equal key. A non-stable version_fn (fresh
--           table / os.clock) would yield 0 hits and fail.
--   Test 3: per-buffer rename invalidation preserved -- renaming the buffer
--           to a new in-vault path produces a fresh miss (name is still the
--           version).

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

-- Require the real modules headless.
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local engine = require("andrew.vault.engine")
local memo = require("andrew.vault.memoize")

-- Two distinct temp vault roots.
local VAULT_A = vim.fn.tempname()
local VAULT_B = vim.fn.tempname()
vim.fn.mkdir(VAULT_A, "p")
vim.fn.mkdir(VAULT_B, "p")
engine.vaults.A = VAULT_A
engine.vaults.B = VAULT_B

-- Make a listed buffer whose name lives under `dir`. Returns the bufnr.
local function make_named_buf(dir, fname)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, dir .. "/" .. fname)
  return buf
end

-- Pull the named memo entry's stats ({hits, misses, ...}).
local function memo_stats()
  for _, s in ipairs(memo.stats()) do
    if s.name == "is_vault_buf" then
      return s
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Test 1 (load-bearing): switch_vault invalidation makes the bare-name
-- version safe. is_vault_buf flips with the active vault.
-- ---------------------------------------------------------------------------
test("is_vault_buf: flips correctly across switch_vault (cache cleared)", function()
  -- Create both buffers up front so we can prove A->false and B->true across
  -- the same switch.
  local buf_a = make_named_buf(VAULT_A, "note.md")
  local buf_b = make_named_buf(VAULT_B, "x.md")

  engine.switch_vault("A")
  assert_eq(engine.is_vault_buf(buf_a), true, "buf in active vault A must be a vault buf")
  -- Call again at the same buffer/name: cached, still true.
  assert_eq(engine.is_vault_buf(buf_a), true, "repeat call must remain true (cache hit)")
  assert_eq(engine.is_vault_buf(buf_b), false, "buf in vault B is not a vault buf while A active")

  engine.switch_vault("B")
  -- The cache was cleared on switch; the bare-name version cannot tell vaults
  -- apart on its own, so correctness depends entirely on the clear.
  assert_eq(engine.is_vault_buf(buf_a), false, "buf in A must NOT be a vault buf after switching to B")
  assert_eq(engine.is_vault_buf(buf_b), true, "buf in B must become a vault buf after switching to B")
end)

-- ---------------------------------------------------------------------------
-- Test 2: hit-rate -- bare-name version is a stable equal key.
-- ---------------------------------------------------------------------------
test("is_vault_buf: repeated calls at unchanged buffer are cache hits", function()
  engine.switch_vault("A") -- clears cache fresh
  local buf = make_named_buf(VAULT_A, "hot.md")

  local before = memo_stats()
  assert_true(before ~= nil, "is_vault_buf memo entry must be registered")

  local N = 50
  for _ = 1, N do
    engine.is_vault_buf(buf)
  end

  local after = memo_stats()
  local d_hits = after.hits - before.hits
  local d_misses = after.misses - before.misses

  -- Exactly one miss (first call populates), the rest hit the stable key.
  assert_eq(d_misses, 1, "first call misses, rest must hit (got " .. d_misses .. " misses)")
  assert_eq(d_hits, N - 1, "N-1 calls must be hits (got " .. d_hits .. " hits)")
end)

-- ---------------------------------------------------------------------------
-- Test 3: per-buffer rename still invalidates (name is the version).
-- ---------------------------------------------------------------------------
test("is_vault_buf: renaming the buffer busts the memo (name is version)", function()
  engine.switch_vault("A")
  local buf = make_named_buf(VAULT_A, "before.md")

  engine.is_vault_buf(buf) -- prime
  local before = memo_stats()

  vim.api.nvim_buf_set_name(buf, VAULT_A .. "/after.md")
  engine.is_vault_buf(buf)
  local after = memo_stats()

  assert_eq(after.misses - before.misses, 1,
    "rename must produce a fresh miss (version changed with the name)")
end)

_H.finish({ style = "results", exit = "os" })
