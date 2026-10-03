-- Perf regression spec for M._diff_entry closure hoisting.
--
-- diff_entry's comparison helpers (string_set_equal, keyed_set_equal,
-- keyed_list_equal, keys_equal) and key-extractors (heading_key, outlink_key,
-- block_id_key) are STATELESS — they capture no upvalue from diff_entry. They
-- are now declared at module scope, so they are allocated ONCE instead of seven
-- closures per diff_entry call (i.e. per modified file per save).
--
-- DISCRIMINATING POWER: a hot loop of N calls to vi._diff_entry allocates ~0
-- new closures with the hoisted version, but 7*N closures if the definitions
-- are moved back inside diff_entry. We measure the GC heap delta across a large
-- loop and assert it stays well below what the in-body (per-call closure)
-- version would produce. Reintroducing the in-body closures pushes the delta
-- far past the threshold and this spec fails.
--
-- A behavioral pin (output unchanged) backs the perf check; the comprehensive
-- equivalence matrix lives in compute_change_types_spec.lua.
--
-- Run with: nvim --headless -u NONE -l tests/diff_entry_closure_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true =
  _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vi = require("andrew.vault.vault_index")
local diff_entry = vi._diff_entry

--- Build a fully-specified entry; override any field via opts.
local function entry(opts)
  opts = opts or {}
  return {
    frontmatter = opts.frontmatter or { title = "T" },
    tags = opts.tags or { "a" },
    headings = opts.headings or { { slug = "h1", level = 1 } },
    outlinks = opts.outlinks or { { _name_lower = "beta" } },
    tasks = opts.tasks or { { text = "x" } },
    aliases = opts.aliases or { "A1" },
    block_ids = opts.block_ids or { { id = "b1" } },
  }
end

test("diff_entry output is unchanged after hoist (behavioral pin)", function()
  local old = entry()
  local same = diff_entry(old, entry())
  for _, k in ipairs({ "frontmatter", "tags", "headings", "outlinks", "tasks", "aliases", "block_ids" }) do
    assert_eq(same[k], false, "no change for identical entry: " .. k)
  end
  -- A genuine change still detected.
  local ct = diff_entry(old, entry({ tags = { "a", "b" } }))
  assert_eq(ct.tags, true, "tag set change detected")
  assert_eq(ct.headings, false, "unrelated field unchanged")
end)

test("diff_entry allocates no per-call closures (hoisted helpers)", function()
  local old = entry()
  local new = entry()
  -- Warm up: trigger any one-time allocations outside the measured window.
  for _ = 1, 100 do diff_entry(old, new) end

  local N = 50000
  collectgarbage("collect")
  collectgarbage("stop")
  local kb0 = collectgarbage("count")
  for _ = 1, N do
    diff_entry(old, new)
  end
  local kb1 = collectgarbage("count")
  collectgarbage("restart")

  local per_call_bytes = (kb1 - kb0) * 1024 / N
  -- Baseline cost per call is the return table + the per-heading key strings
  -- (identical in both versions). MEASURED on this LuaJIT/Lua build: the
  -- hoisted version is ~704 bytes/call; moving the seven helpers back inside
  -- diff_entry adds the 7 closures per call and pushes it to ~1048 bytes/call.
  -- A 900-byte threshold sits clearly between the two: hoisted passes with
  -- margin, the in-body (bug) version fails. This is the discriminator.
  assert_true(per_call_bytes < 900,
    string.format("per-call alloc %.1f bytes should be < 900 (in-body 7-closure version is ~1048)", per_call_bytes))
end)

_H.finish({ style = "results", exit = "os" })
